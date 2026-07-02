// This file has been entirely LLM generated, but has been
// manually inspected.
const std = @import("std");
const bm25 = @import("bm25");
const WordTokenizer = @import("main.zig").WordTokenizer;

const InMemoryDoc = struct {
    name: []const u8,
    content: []const u8,
};

const InMemoryDocIter = struct {
    docs: []const InMemoryDoc,
    index: usize = 0,
    current_tokenizer: ?WordTokenizer = null,

    pub fn init(docs: []const InMemoryDoc) InMemoryDocIter {
        return .{ .docs = docs };
    }

    pub fn next(base: bm25.DocIter) !?bm25.WordIter {
        const self: *InMemoryDocIter = @ptrCast(@alignCast(base.ctx));
        if (self.index >= self.docs.len) return null;
        self.current_tokenizer = WordTokenizer.init(self.docs[self.index].content);
        self.index += 1;
        return self.current_tokenizer.?.iterator();
    }

    pub fn iterator(self: *InMemoryDocIter) bm25.DocIter {
        return .{ .ctx = self, .nextFn = InMemoryDocIter.next };
    }
};

fn isTokenizableFile(file_path: []const u8) bool {
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();

    // The first argument is normally the binary path
    _ = args_iter.next();
    const target_dir_path = args_iter.next() orelse ".";

    std.debug.print("Benchmarking BM25 indexing in directory: '{s}'\n", .{target_dir_path});

    // 1. Walk and Load all files into memory to isolate parsing/indexing from Disk I/O
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var docs_list = std.ArrayList(InMemoryDoc).empty;
    defer docs_list.deinit(allocator);

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, target_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var total_bytes: usize = 0;

    var clock: std.Io.Clock = .real;
    const io_start_time = clock.now(io);

    while (try walker.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.basename, ".") or std.mem.indexOf(u8, entry.path, "/.") != null) {
            continue;
        }
        if (entry.kind == .file) {
            if (!isTokenizableFile(entry.path)) continue;

            const buf = allocator.alloc(u8, 1000000) catch continue;
            const content = dir.readFile(io, entry.path, buf) catch |err| {
                if (err != error.StreamTooLong) {
                    std.debug.print("Failed to read file {s}: {}\n", .{ entry.path, err });
                }
                continue;
            };

            total_bytes += content.len;
            try docs_list.append(allocator, .{
                .name = try allocator.dupe(u8, entry.path),
                .content = content,
            });
        }
    }

    const io_duration_ms = @as(f64, @floatFromInt(io_start_time.untilNow(io, clock).toMilliseconds()));

    std.debug.print("Loaded {} documents ({d:.2} MB) from disk in {d:.2} ms ({d:.2} MB/s)\n", .{
        docs_list.items.len,
        @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0),
        io_duration_ms,
        (@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)) / (io_duration_ms / 1000.0),
    });

    if (docs_list.items.len == 0) {
        std.debug.print("No documents found to index.\n", .{});
        return;
    }

    // 2. Measure BM25 Okapi pure indexing speed (includes word-level tokenization + BM25Okapi statistics build)
    const index_start_time = clock.now(io);

    var doc_iter = InMemoryDocIter.init(docs_list.items);
    var alg = try bm25.BM25Okapi.init(allocator, doc_iter.iterator(), .{});
    defer alg.deinit();

    const index_duration_ms = @as(f64, @floatFromInt(index_start_time.untilNow(io, clock).toMilliseconds()));

    // Calculate vocabulary statistics
    const unique_words = alg.bm25.word_to_id.count();
    var total_tokens: usize = 0;
    for (alg.bm25.doc_len.items) |len| {
        total_tokens += @intFromFloat(len);
    }

    std.debug.print("\n=== BM25 Okapi Indexing Benchmark Results ===\n", .{});
    std.debug.print("Total Docs:            {}\n", .{docs_list.items.len});
    std.debug.print("Total Size:            {d:.2} MB\n", .{@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)});
    std.debug.print("Total Tokens (Words):  {}\n", .{total_tokens});
    std.debug.print("Unique Words (Vocab):  {}\n", .{unique_words});
    std.debug.print("Pure Indexing Time:    {d:.2} ms\n", .{index_duration_ms});
    std.debug.print("Pure Indexing Speed:   {d:.2} MB/s\n", .{
        (@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)) / (index_duration_ms / 1000.0),
    });
    std.debug.print("Throughput (Docs/sec): {d:.2} docs/s\n", .{
        @as(f64, @floatFromInt(docs_list.items.len)) / (index_duration_ms / 1000.0),
    });
    std.debug.print("Throughput (Toks/sec): {d:.2} tokens/s\n", .{
        @as(f64, @floatFromInt(total_tokens)) / (index_duration_ms / 1000.0),
    });
    std.debug.print("=============================================\n", .{});
}
