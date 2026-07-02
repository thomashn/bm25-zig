const std = @import("std");
const bm25 = @import("bm25");
const chilli = @import("chilli");

pub var current_log_level: std.log.Level = .info;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (@intFromEnum(message_level) > @intFromEnum(current_log_level)) return;

    var stderr_buf: [2048]u8 = undefined;
    const fallback_io = std.Options.debug_io;
    var stderr_fw = std.Io.File.stderr().writer(fallback_io, &stderr_buf);
    _ = stderr_fw.interface.print("bm25: " ++ format ++ "\n", args) catch {};
    stderr_fw.flush() catch {};
}

const DocEntry = struct {
    name: []const u8,
    score: f64 = 0,
};

pub const WordTokenizer = struct {
    file_content: []const u8,
    file_seek: usize = 0,
    word_scratch: [126]u8 = undefined,

    pub fn init(file_content: []const u8) WordTokenizer {
        return .{ .file_content = file_content };
    }

    pub fn next(base: bm25.WordIter) !?[]const u8 {
        const self: *WordTokenizer = @ptrCast(@alignCast(base.ctx));
        while (true) {
            if (self.file_seek >= self.file_content.len) return null;
            const start = self.file_seek;
            var end = start;
            while (end < self.file_content.len and std.ascii.isAlphanumeric(self.file_content[end])) {
                end += 1;
            }
            self.file_seek = if (end < self.file_content.len) end + 1 else self.file_content.len;
            const word = self.file_content[start..end];
            if (word.len == 0) continue;
            if (word.len > self.word_scratch.len) return null;
            for (word, 0..) |c, idx| {
                self.word_scratch[idx] = std.ascii.toLower(c);
            }
            return self.word_scratch[0..word.len];
        }
    }

    pub fn iterator(self: *WordTokenizer) bm25.WordIter {
        return .{ .ctx = self, .nextFn = WordTokenizer.next };
    }
};

const DocTokenizer = struct {
    const MaxFileSize = 1000000;
    const MaxConcurrentTasks = 2;
    const ReadTask = struct {
        data_buffer: [MaxFileSize]u8 = undefined,
        data: ?[]u8 = null,
        file_path_buffer: [1024]u8 = undefined,
        file_path: ?[]const u8 = null,
    };
    const SelectUnion = union {
        read: *ReadTask,
    };

    io: std.Io,
    allocator: std.mem.Allocator,

    dir: std.Io.Dir,
    walker: std.Io.Dir.Walker,
    entries: std.ArrayList(DocEntry),
    file_names: std.heap.ArenaAllocator,
    file_tokenizer: ?WordTokenizer = null,
    mutex: std.Io.Mutex = .init,
    select_storage: [10]SelectUnion = undefined,
    select: ?std.Io.Select(SelectUnion) = null,
    tasks: usize = 0,
    docs: usize = 0,
    read_task: ?*const ReadTask = null,
    task_pool: std.heap.MemoryPoolExtra(ReadTask, .{ .growable = false }),
    pub fn init(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !DocTokenizer {

        // Do an initial count
        var file_count: usize = 0;
        var count_walker = try dir.walk(allocator);
        defer count_walker.deinit();
        while (try count_walker.next(io)) |entry| {
            if (entry.kind == .file) file_count += 1;
        }

        return DocTokenizer{
            .io = io,
            .allocator = allocator,
            .dir = dir,
            .walker = try dir.walk(allocator),
            .entries = try .initCapacity(allocator, file_count),
            .file_names = .init(allocator),
            .task_pool = try .initCapacity(allocator, MaxConcurrentTasks),
        };
    }

    pub fn deinit(self: *DocTokenizer) void {
        self.walker.deinit();
        self.file_names.deinit();
        self.entries.deinit(self.allocator);
        self.task_pool.deinit(self.allocator);
    }

    fn isTokanizableFile(file_path: []const u8) bool {
        const valid = &.{
            ".py",
            ".txt",
            ".md",
            ".cpp",
            ".c",
            ".zig",
        };

        inline for (valid) |v| {
            if (std.mem.endsWith(u8, file_path, v)) return true;
        }
        return false;
    }

    fn prepFile(self: *DocTokenizer, read_task: *ReadTask) !*ReadTask {
        read_task.data = self.dir.readFile(self.io, read_task.file_path.?, &read_task.data_buffer) catch |e| blk: {
            if (e == error.StreamTooLong) {
                std.log.warn("The file {s} is too large", .{read_task.file_path.?});
                break :blk null;
            }
            return e;
        };

        if (read_task.data) |f| {
            if (f.len == 0) return error.no_file;
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            try self.entries.append(self.allocator, .{
                .name = try self.file_names.allocator().dupe(u8, read_task.file_path.?),
            });
            return read_task;
        }
        return error.no_file;
    }

    fn prepFileWrapper(self: *DocTokenizer, read_task: *ReadTask) *ReadTask {
        return self.prepFile(read_task) catch {
            read_task.data = null;
            return read_task;
        };
    }

    pub fn next(base: bm25.DocIter) !?bm25.WordIter {
        const self: *DocTokenizer = @ptrCast(@alignCast(base.ctx));

        if (self.select == null) {
            self.select = .init(self.io, &self.select_storage);
        }
        const select = &self.select.?;

        while (true) {
            // Remove any file data from the previous call
            if (self.read_task) |t| {
                self.task_pool.destroy(@alignCast(@constCast(t)));
                self.read_task = null;
            }

            // Schedule as many tasks as the task pool will allow
            while (true) {
                var scheduled = false;
                const task: *ReadTask = self.task_pool.create(self.allocator) catch break;

                while (try self.walker.next(self.io)) |entry| {
                    // Skip hidden files/directories (e.g. .git, .zig-cache)
                    if (std.mem.startsWith(u8, entry.basename, ".") or std.mem.indexOf(u8, entry.path, "/.") != null) {
                        continue;
                    }
                    if (entry.kind == .file) {
                        if (!isTokanizableFile(entry.path)) continue;

                        @memcpy(task.file_path_buffer[0..entry.path.len], entry.path);
                        task.file_path = task.file_path_buffer[0..entry.path.len];
                        task.data = null;
                        select.async(.read, DocTokenizer.prepFileWrapper, .{ self, task });
                        scheduled = true;
                        // Go back to parent while loop, to fetch new task from pool
                        break;
                    }
                }

                if (!scheduled) {
                    self.task_pool.destroy(task);
                    break;
                }
            }

            if (self.task_pool.free_list.len() < MaxConcurrentTasks) {
                std.debug.assert(self.read_task == null);
                const task = try select.await();
                self.read_task = @ptrCast(task.read);
                if (task.read.data == null) {
                    continue;
                }
                self.file_tokenizer = WordTokenizer.init(task.read.data.?);
                self.docs += 1;
                return self.file_tokenizer.?.iterator();
            } else {
                // No tasks running, nothing left to do
                std.debug.assert(self.read_task == null);
                return null;
            }
        }
        unreachable;
    }

    pub fn iterator(self: *DocTokenizer) bm25.DocIter {
        return bm25.DocIter{ .nextFn = DocTokenizer.next, .ctx = self };
    }
};

const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
};

// A function for our command to execute
fn cli(ctx: chilli.CommandContext) !void {
    const log = std.log;
    const exit = std.process.exit;
    const init: *const Env = @ptrCast(@alignCast(ctx.data.?));
    const io = init.io;
    const root_dir = try ctx.getArg("dir", []const u8);
    const cwd = std.Io.Dir.cwd();

    const search = try ctx.getArg("search", []const u8);

    const dir = cwd.openDir(init.io, root_dir, .{ .iterate = true }) catch {
        std.log.err("failed to open directory '{s}'", .{root_dir});
        exit(1);
    };
    defer dir.close(io);

    const verbose = try ctx.getFlag("verbose", bool);
    if (verbose) {
        current_log_level = .debug;
    } else {
        current_log_level = .info;
    }

    var clock: std.Io.Clock = .real;
    var start = clock.now(io);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var doc_tokenizer = try DocTokenizer.init(io, init.gpa, dir);
    defer doc_tokenizer.deinit();

    var alg = try bm25.BM25Okapi.init(init.gpa, doc_tokenizer.iterator(), .{});
    defer alg.deinit();
    log.debug("Indexing took {}ms", .{start.untilNow(io, clock).toMilliseconds()});
    start = clock.now(io);

    var search_tokenizer = WordTokenizer.init(search);

    const scores = try alg.getScores(init.gpa, search_tokenizer.iterator());
    defer init.gpa.free(scores);

    log.debug("Scoring took {}ms", .{start.untilNow(io, clock).toMilliseconds()});
    start = clock.now(io);
    for (scores, 0..) |score, idx| {
        doc_tokenizer.entries.items[idx].score = score;
    }

    const SortFn = struct {
        pub fn sort(_: void, a: DocEntry, b: DocEntry) bool {
            return a.score > b.score;
        }
    }.sort;

    std.mem.sortUnstable(DocEntry, doc_tokenizer.entries.items, {}, SortFn);
    log.debug("Sorting took {}ms", .{start.untilNow(io, clock).toMilliseconds()});

    const limit = try ctx.getFlag("limit", usize);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(init.io, &stdout_buf);

    const print_limit = @min(limit, doc_tokenizer.entries.items.len);
    for (doc_tokenizer.entries.items[0..print_limit]) |entry| {
        _ = stdout_fw.interface.print("{s}: {d}\n", .{ entry.name, entry.score }) catch {};
    }
    stdout_fw.flush() catch {};

    log.info("Total docs {}", .{doc_tokenizer.docs});
}

pub fn main(init: std.process.Init) anyerror!void {
    const io = init.io;
    const gpa = init.gpa;

    // Create the root command for your application
    var root_cmd = try chilli.Command.init(init.gpa, .{
        .name = "bm25",
        .description = "A high-performance command-line search utility that ranks local documents using the BM25 Okapi relevance scoring algorithm.",
        .version = "v1.0.0",
        .exec = cli, // The function to run
    });
    defer root_cmd.deinit();

    try root_cmd.addPositional(.{
        .name = "dir",
        .description = "The root directory containing documents (.py, .txt, .md, .cpp, .c, .zig) to index and search.",
        .is_required = true,
    });

    try root_cmd.addPositional(.{
        .name = "search",
        .description = "The query string or terms to search for.",
        .is_required = true,
        .type = .String,
    });

    try root_cmd.addFlag(.{
        .name = "limit",
        .shortcut = 'n',
        .type = .Int,
        .default_value = .{ .Int = 30 },
        .description = "Limit number of search results",
    });

    try root_cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .type = .Bool,
        .default_value = .{ .Bool = false },
        .description = "Show detailed profiling diagnostics and document count",
    });

    const env = Env{
        .gpa = gpa,
        .io = io,
    };

    // Hand control over to the framework
    try root_cmd.run(init.minimal.args, @ptrCast(@constCast(&env)));
}
