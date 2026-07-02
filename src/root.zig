// Copyright (c) 2026 Thomas Hanssen Nornes
// Licensed under the MIT License.
const std = @import("std");

const TokenizerFn = *const fn (*std.Io.Reader, *std.Io.Writer) anyerror!?[]const u8;
const WordFreqMap = std.StringHashMap(f64);
const IdfFn = *const fn (*BM25, *Id2Freq) anyerror!void;
const ScoresFn = *const fn (*BM25, std.mem.Allocator, WordIter) anyerror![]f64;
const Posting = struct {
    doc_id: usize,
    freq: f64,
};

const InvertedIndex = std.HashMap(u32, []const Posting, U32Context, std.hash_map.default_max_load_percentage);

fn getScoresGeneric(self: anytype, allocator: std.mem.Allocator, query: WordIter) ![]f64 {
    const T = @TypeOf(self.*);
    const parent: *BM25 = &self.bm25;

    var score = try allocator.alloc(f64, parent.corpus_size);
    errdefer allocator.free(score);
    @memset(score, 0);

    while (try query.next()) |w| {
        const word_id: u32 = parent.word_to_id.get(w) orelse continue;
        const idf: f64 = parent.idf.get(word_id) orelse continue;
        const word_stats = parent.doc_freqs.get(word_id) orelse continue;

        var word_doc_idx: usize = 0;
        for (0..parent.corpus_size) |i| {
            var q_freq: f64 = 0;
            if (word_stats[word_doc_idx].doc_id == i) {
                q_freq = word_stats[word_doc_idx].freq;
                if (word_doc_idx < word_stats.len - 1)
                    word_doc_idx += 1;
            }
            const doc_len = parent.doc_len.items[i];
            score[i] += T.scoreFormula(self.param, q_freq, doc_len, parent.avgdl, idf);
        }
    }
    return score;
}

fn getBatchScoresGeneric(self: anytype, allocator: std.mem.Allocator, query: WordIter, doc_ids: []const usize) ![]f64 {
    const T = @TypeOf(self.*);
    const parent: *BM25 = &self.bm25;

    // Subset/Batch search mode: Query document IDs might be out of order or sparse,
    // so we use binary search on word_stats (which is sorted by doc_id).
    var score = try allocator.alloc(f64, doc_ids.len);
    errdefer allocator.free(score);
    @memset(score, 0);

    while (try query.next()) |w| {
        const word_id: u32 = parent.word_to_id.get(w) orelse continue;
        const idf: f64 = parent.idf.get(word_id) orelse continue;
        const word_stats = parent.doc_freqs.get(word_id) orelse continue;

        for (doc_ids, 0..) |doc_idx, i| {
            var q_freq: f64 = 0;
            var left: usize = 0;
            var right: usize = word_stats.len;
            while (left < right) {
                const mid = left + (right + left) / 2;
                if (word_stats[mid].doc_id == doc_idx) {
                    q_freq = word_stats[mid].freq;
                    break;
                } else if (word_stats[mid].doc_id < doc_idx) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            const doc_len = parent.doc_len.items[doc_idx];
            score[i] += T.scoreFormula(self.param, q_freq, doc_len, parent.avgdl, idf);
        }
    }
    return score;
}

fn getTopNGeneric(self: anytype, allocator: std.mem.Allocator, query: WordIter, documents: anytype, n: usize) ![]const @TypeOf(documents[0]) {
    const T = @TypeOf(documents[0]);
    std.debug.assert(self.bm25.corpus_size == documents.len);

    const scores = try self.getScores(allocator, query);
    defer allocator.free(scores);

    const Entry = struct {
        item: T,
        score: f64,
    };

    var entries = try allocator.alloc(Entry, documents.len);
    defer allocator.free(entries);

    for (documents, 0..) |doc, i| {
        entries[i] = .{ .item = doc, .score = scores[i] };
    }

    const SortFn = struct {
        pub fn sort(_: void, a: Entry, b: Entry) bool {
            return a.score > b.score;
        }
    }.sort;

    std.mem.sortUnstable(Entry, entries, {}, SortFn);

    const count = @min(n, documents.len);
    const result = try allocator.alloc(T, count);
    for (0..count) |i| {
        result[i] = entries[i].item;
    }
    return result;
}

pub const DocIter = struct {
    ctx: *anyopaque,
    nextFn: *const fn (DocIter) anyerror!?WordIter,

    pub fn next(self: DocIter) !?WordIter {
        return self.nextFn(self);
    }
};

pub const WordIter = struct {
    ctx: *anyopaque,
    nextFn: *const fn (WordIter) anyerror!?[]const u8,

    pub fn next(self: WordIter) !?[]const u8 {
        return self.nextFn(self);
    }
};

const U32Context = struct {
    pub fn hash(self: @This(), key: u32) u64 {
        _ = self;
        return @as(u64, key); // Zero overhead hashing
    }
    pub fn eql(self: @This(), a: u32, b: u32) bool {
        _ = self;
        return a == b;
    }
};

const Id2Freq = std.HashMap(u32, f64, U32Context, std.hash_map.default_max_load_percentage);
const Word2Id = std.StringHashMap(u32);

const BM25 = struct {
    corpus_size: usize,
    avgdl: f64,
    doc_freqs: InvertedIndex,
    idf: Id2Freq,
    doc_len: std.ArrayList(f64),
    allocator: std.mem.Allocator,
    calcIdf: IdfFn,
    getScores: ScoresFn,
    arena: std.heap.ArenaAllocator,
    word_to_id: Word2Id,

    pub fn init(self: *BM25, allocator: std.mem.Allocator, doc_iter: DocIter, idf_fn: IdfFn, scores_fn: ScoresFn) !void {
        self.* = BM25{
            .corpus_size = 0,
            .avgdl = 0,
            .idf = .init(allocator),
            .doc_len = .empty,
            .allocator = allocator,
            .calcIdf = idf_fn,
            .getScores = scores_fn,
            .arena = .init(allocator),
            .word_to_id = .init(allocator),
            .doc_freqs = .init(allocator),
        };
        var nd = try self.initialize(doc_iter);
        defer nd.deinit();
        try self.calcIdf(self, &nd);
    }

    fn deinit(self: *BM25) void {
        self.idf.deinit();
        self.doc_len.deinit(self.allocator);
        self.word_to_id.deinit();
        self.doc_freqs.deinit();
        _ = self.arena.deinit();
    }

    const RawPosting = struct {
        doc_id: usize,
        word_id: u32,
        freq: f64,
    };

    fn initialize(self: *BM25, documents: DocIter) !Id2Freq {
        var num_doc: f64 = 0;

        var next_word_id: u32 = 0;
        errdefer self.word_to_id.deinit();
        errdefer self.doc_freqs.deinit();
        errdefer _ = self.arena.deinit();

        var nd = Id2Freq.init(self.allocator);
        errdefer nd.deinit();
        var frequencies = Id2Freq.init(self.allocator);
        defer frequencies.deinit();
        var all_raw_postings = std.ArrayList(RawPosting).empty;
        defer all_raw_postings.deinit(self.allocator);

        while (try documents.next()) |word_iter| {
            var itera = word_iter;

            // TODO Consider
            frequencies.clearRetainingCapacity();

            var token_count: usize = 0;
            while (try itera.next()) |word| {
                var word_id: u32 = undefined;
                token_count += 1;

                // Create word -> u32 lookup
                {
                    const result = try self.word_to_id.getOrPut(word);
                    if (!result.found_existing) {
                        result.value_ptr.* = next_word_id;
                        result.key_ptr.* = try self.arena.allocator().dupe(u8, word);
                        word_id = next_word_id;
                        if (word_id == std.math.maxInt(u32)) {
                            return error.too_many_unique_words;
                        }
                        next_word_id += 1;
                    } else {
                        word_id = result.value_ptr.*;
                    }
                }

                // Use the u32 id for the actual frequency counting
                {
                    const result = try frequencies.getOrPut(word_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = 0;
                    }
                    result.value_ptr.* += 1.0;
                }
            }
            try self.doc_len.append(self.allocator, @floatFromInt(token_count));
            num_doc += @floatFromInt(token_count);

            try all_raw_postings.ensureUnusedCapacity(self.allocator, frequencies.count());
            var iter = frequencies.iterator();
            while (iter.next()) |entry| {
                const word_id = entry.key_ptr.*;
                const word_freq = entry.value_ptr.*;

                all_raw_postings.appendAssumeCapacity(.{
                    .doc_id = self.corpus_size,
                    .word_id = word_id,
                    .freq = word_freq,
                });

                const result = try nd.getOrPut(word_id);
                if (result.found_existing) {
                    result.value_ptr.* += 1.0;
                } else {
                    result.value_ptr.* = 1.0;
                }
            }

            self.corpus_size += 1;
        }

        try self.doc_freqs.ensureUnusedCapacity(nd.count());

        // Pre-allocate the arrays holding the word id stats. I first
        // implemented this with ArrayList, but doing it like this avoids
        // a lot of allocation calls.
        var nd_iter = nd.iterator();
        while (nd_iter.next()) |entry| {
            const word_id = entry.key_ptr.*;
            const doc_count = @as(usize, @intFromFloat(entry.value_ptr.*));
            const postings_slice = try self.arena.allocator().alloc(Posting, doc_count);
            try self.doc_freqs.putNoClobber(word_id, postings_slice);
        }

        // Since we are not using ArrayList structures, we will need to
        // manually keep track of where we are in each array.
        const write_indices = try self.allocator.alloc(usize, next_word_id);
        defer self.allocator.free(write_indices);
        @memset(write_indices, 0);

        for (all_raw_postings.items) |raw| {
            const postings_slice = @constCast(self.doc_freqs.get(raw.word_id).?);
            const idx = write_indices[raw.word_id];
            postings_slice[idx] = .{ .doc_id = raw.doc_id, .freq = raw.freq };
            write_indices[raw.word_id] = idx + 1;
        }

        const corpus_size: f64 = @floatFromInt(self.corpus_size);
        self.avgdl = num_doc / corpus_size;
        return nd;
    }
};

pub const BM25Okapi = struct {
    const Self = @This();
    const Params = struct {
        b: f64 = 0.75,
        k1: f64 = 1.5,
        epsilon: f64 = 0.25,
    };

    average_idf: f64 = undefined,
    param: Params,
    bm25: BM25,

    pub fn init(allocator: std.mem.Allocator, doc_iter: DocIter, params: Params) !Self {
        var self = Self{
            .param = params,
            .bm25 = undefined,
        };
        // Due to parent pointer
        try self.bm25.init(allocator, doc_iter, Self.calcIdf, Self._getScores);
        return self;
    }

    fn calcIdf(parent: *BM25, nd: *Id2Freq) !void {
        var self: *Self = @alignCast(@fieldParentPtr("bm25", parent));
        var idf_sum: f64 = 0;
        var negative_idfs = std.ArrayList(u32).empty;
        defer negative_idfs.deinit(parent.allocator);

        var iter = nd.iterator();
        while (iter.next()) |entry| {
            const word_id = entry.key_ptr.*;
            const freq = entry.value_ptr.*;
            const corpus_size: f64 = @floatFromInt(parent.corpus_size);

            const idf = @log(corpus_size - freq + 0.5) - @log(freq + 0.5);
            try parent.idf.putNoClobber(word_id, idf);
            idf_sum += idf;
            if (idf < 0) {
                try negative_idfs.append(parent.allocator, word_id);
            }
        }
        const idf_count: f64 = @floatFromInt(parent.idf.count());
        self.average_idf = idf_sum / idf_count;

        const eps = self.param.epsilon * self.average_idf;
        for (negative_idfs.items) |word_id| {
            try parent.idf.put(word_id, eps);
        }
    }

    fn _getScores(parent: *BM25, alloc: std.mem.Allocator, query: WordIter) ![]f64 {
        const self: *Self = @alignCast(@fieldParentPtr("bm25", parent));
        return try self.getScores(alloc, query);
    }

    pub fn scoreFormula(param: Params, q_freq: f64, doc_len: f64, avgdl: f64, idf: f64) f64 {
        if (q_freq <= 0) return 0; // Match Python's guard
        return idf * (q_freq * (param.k1 + 1) / (q_freq + param.k1 * (1 - param.b + param.b * doc_len / avgdl)));
    }

    pub fn getScores(self: *Self, allocator: std.mem.Allocator, query: WordIter) ![]f64 {
        return getScoresGeneric(self, allocator, query);
    }

    pub fn getBatchScores(self: *Self, allocator: std.mem.Allocator, query: WordIter, doc_ids: []const usize) ![]f64 {
        return getBatchScoresGeneric(self, allocator, query, doc_ids);
    }

    pub fn getTopN(self: *Self, allocator: std.mem.Allocator, query: WordIter, documents: anytype, n: usize) ![]const @TypeOf(documents[0]) {
        return getTopNGeneric(self, allocator, query, documents, n);
    }

    pub fn deinit(self: *Self) void {
        self.bm25.deinit();
    }
};

pub const BM25L = struct {
    const Self = @This();
    const Params = struct {
        b: f64 = 0.75,
        k1: f64 = 1.5,
        delta: f64 = 0.5,
    };

    param: Params,
    bm25: BM25,

    pub fn init(allocator: std.mem.Allocator, doc_iter: DocIter, params: Params) !Self {
        var self = Self{
            .param = params,
            .bm25 = undefined,
        };
        // Due to parent pointer
        try self.bm25.init(allocator, doc_iter, Self.calcIdf, Self._getScores);
        return self;
    }

    fn calcIdf(parent: *BM25, nd: *Id2Freq) !void {
        var iter = nd.iterator();
        while (iter.next()) |entry| {
            const freq = entry.value_ptr.*;
            const corpus_size: f64 = @floatFromInt(parent.corpus_size);
            const idf = @log(corpus_size + 1) - @log(freq + 0.5);
            try parent.idf.putNoClobber(entry.key_ptr.*, idf);
        }
    }

    fn _getScores(parent: *BM25, alloc: std.mem.Allocator, query: WordIter) ![]f64 {
        const self: *Self = @alignCast(@fieldParentPtr("bm25", parent));
        return self.getScores(alloc, query);
    }

    pub fn scoreFormula(param: Params, q_freq: f64, doc_len: f64, avgdl: f64, idf: f64) f64 {
        if (q_freq <= 0) return 0; // Match Python's guard
        const ctd = q_freq / (1.0 - param.b + param.b * doc_len / avgdl);
        return idf * (param.k1 + 1.0) * (ctd + param.delta) / (param.k1 + ctd + param.delta);
    }

    pub fn getScores(self: *Self, allocator: std.mem.Allocator, query: WordIter) ![]f64 {
        return getScoresGeneric(self, allocator, query);
    }

    pub fn getBatchScores(self: *Self, allocator: std.mem.Allocator, query: WordIter, doc_ids: []const usize) ![]f64 {
        return getBatchScoresGeneric(self, allocator, query, doc_ids);
    }

    pub fn getTopN(self: *Self, allocator: std.mem.Allocator, query: WordIter, documents: anytype, n: usize) ![]const @TypeOf(documents[0]) {
        return getTopNGeneric(self, allocator, query, documents, n);
    }

    pub fn deinit(self: *Self) void {
        self.bm25.deinit();
    }
};

pub const BM25Plus = struct {
    const Self = @This();
    const Params = struct {
        b: f64 = 0.75,
        k1: f64 = 1.5,
        delta: f64 = 1.0,
    };

    param: Params,
    bm25: BM25,

    pub fn init(allocator: std.mem.Allocator, doc_iter: DocIter, params: Params) !Self {
        var self = Self{
            .param = params,
            .bm25 = undefined,
        };
        // Due to parent pointer
        try self.bm25.init(allocator, doc_iter, Self.calcIdf, Self._getScores);
        return self;
    }

    fn calcIdf(parent: *BM25, nd: *Id2Freq) !void {
        var iter = nd.iterator();
        while (iter.next()) |entry| {
            const word_id = entry.key_ptr.*;
            const freq = entry.value_ptr.*;

            const corpus_size: f64 = @floatFromInt(parent.corpus_size);
            const idf = @log(corpus_size + 1) - @log(freq);
            try parent.idf.putNoClobber(word_id, idf);
        }
    }

    fn _getScores(parent: *BM25, alloc: std.mem.Allocator, query: WordIter) ![]f64 {
        const self: *Self = @alignCast(@fieldParentPtr("bm25", parent));
        return self.getScores(alloc, query);
    }

    pub fn scoreFormula(param: Params, q_freq: f64, doc_len: f64, avgdl: f64, idf: f64) f64 {
        return idf * (param.delta + (q_freq * (param.k1 + 1.0)) / (param.k1 * (1.0 - param.b + param.b * doc_len / avgdl) + q_freq));
    }

    pub fn getScores(self: *Self, allocator: std.mem.Allocator, query: WordIter) ![]f64 {
        return getScoresGeneric(self, allocator, query);
    }

    pub fn getBatchScores(self: *Self, allocator: std.mem.Allocator, query: WordIter, doc_ids: []const usize) ![]f64 {
        return getBatchScoresGeneric(self, allocator, query, doc_ids);
    }

    pub fn getTopN(self: *Self, allocator: std.mem.Allocator, query: WordIter, documents: anytype, n: usize) ![]const @TypeOf(documents[0]) {
        return getTopNGeneric(self, allocator, query, documents, n);
    }

    pub fn deinit(self: *Self) void {
        self.bm25.deinit();
    }
};

/// Erases any pointer to a type-safe custom struct with a `next() !?[]const u8`
/// method into a standard `WordIter`.
pub fn wordIterator(ptr: anytype) WordIter {
    const T = @TypeOf(ptr);
    const Gen = struct {
        fn next(base: WordIter) anyerror!?[]const u8 {
            const self: T = @ptrCast(@alignCast(base.ctx));
            return self.next();
        }
    };
    return WordIter{
        .ctx = ptr,
        .nextFn = Gen.next,
    };
}

/// Erases any pointer to a type-safe custom struct with a `next() !?WordIter`
/// method into a standard `DocIter`.
pub fn docIterator(ptr: anytype) DocIter {
    const T = @TypeOf(ptr);
    const Gen = struct {
        fn next(base: DocIter) anyerror!?WordIter {
            const self: T = @ptrCast(@alignCast(base.ctx));
            return self.next();
        }
    };
    return DocIter{
        .ctx = ptr,
        .nextFn = Gen.next,
    };
}

/// A generic, stateful document iterator over an in-memory slice of documents.
/// It uses a custom `Tokenizer` to transform each document of type `Doc` into words.
pub fn SliceIterator(comptime Doc: type, comptime Tokenizer: type) type {
    return struct {
        const Self = @This();

        corpus: []const Doc,
        idx: usize = 0,
        current_tokenizer: Tokenizer = undefined,

        pub fn init(corpus: []const Doc) Self {
            return .{ .corpus = corpus };
        }

        pub fn next(self: *Self) anyerror!?WordIter {
            if (self.idx >= self.corpus.len) return null;

            const doc = self.corpus[self.idx];
            self.idx += 1;

            self.current_tokenizer = Tokenizer.init(doc);
            return wordIterator(&self.current_tokenizer);
        }

        pub fn iterator(self: *Self) DocIter {
            return docIterator(self);
        }
    };
}

const WordTokenizer = struct {
    split_iter: std.mem.SplitIterator(u8, .any),

    pub fn init(doc: []const u8) WordTokenizer {
        return .{ .split_iter = std.mem.splitAny(u8, doc, " ") };
    }

    fn next(self: *WordTokenizer) !?[]const u8 {
        return self.split_iter.next();
    }

    pub fn iterator(self: *WordTokenizer) WordIter {
        return wordIterator(self);
    }
};

const test_corpus: []const []const u8 = &.{
    "Hello there good man!",
    "It is quite windy in London",
    "How is the weather today?",
};

const query_matrix: []const []const u8 = &.{
    "Hello World",
    "Windy weather",
    "is today?",
    "is today? good",
};

// Generated by rank_bm25
const score_matrix: []const []const []const f64 = &.{
    &.{
        // BM25Okapi
        &.{
            // ['Hello', 'World']
            0.5613468393032865,
            0.0,
            0.0,
        },
        &.{
            // ['Windy', 'weather']
            0.0,
            0.0,
            0.5108256237659907,
        },
        &.{
            // ['is', 'today?']
            0.0,
            0.10042443455425767,
            0.6202882574301316,
        },
        &.{
            // ['is', 'today?', 'good']
            0.5613468393032865,
            0.10042443455425767,
            0.6202882574301316,
        },
    },
    &.{
        // BM25L
        &.{
            // ['Hello', 'World']
            1.2941497088349163,
            0.0,
            0.0,
        },
        &.{
            // ['Windy', 'weather']
            0.0,
            0.0,
            1.2260365662646577,
        },
        &.{
            // ['is', 'today?']
            0.0,
            0.5607997848954799,
            1.8135411028218271,
        },
        &.{
            // ['is', 'today?', 'good']
            1.2941497088349163,
            0.5607997848954799,
            1.8135411028218271,
        },
    },
    &.{
        // BM25Plus
        &.{
            // ['Hello', 'World']
            2.9096947579549353,
            1.3862943611198906,
            1.3862943611198906,
        },
        &.{
            // ['Windy', 'weather']
            1.3862943611198906,
            1.3862943611198906,
            2.772588722239781,
        },
        &.{
            // ['is', 'today?']
            2.0794415416798357,
            2.7153563862302446,
            4.1588830833596715,
        },
        &.{
            // ['is', 'today?', 'good']
            4.989136299634771,
            4.101650747350135,
            5.545177444479562,
        },
    },
};

test "score_matrix" {
    const algorithms = .{ BM25Okapi, BM25L, BM25Plus };
    inline for (algorithms, 0..) |Algorithm, alg_idx| {
        var corpus_iter = SliceIterator([]const u8, WordTokenizer).init(test_corpus);
        var alg = try Algorithm.init(std.testing.allocator, corpus_iter.iterator(), .{});
        defer alg.deinit();

        try std.testing.expectEqual(3, alg.bm25.corpus_size);
        try std.testing.expectEqual(5.0, alg.bm25.avgdl);
        try std.testing.expectEqual(3, alg.bm25.doc_len.items.len);

        for (query_matrix, 0..) |query, query_idx| {
            var query_tokenizer = WordTokenizer.init(query);
            const scores = try alg.getScores(std.testing.allocator, query_tokenizer.iterator());
            defer std.testing.allocator.free(scores);

            for (score_matrix[alg_idx][query_idx], 0..) |expected_score, i| {
                try std.testing.expectEqual(expected_score, scores[i]);
            }

            // Test batch scores with a subset/reordered index: [2, 0]
            const batch_indices = [_]usize{ 2, 0 };
            query_tokenizer = WordTokenizer.init(query);
            const batch_scores = try alg.getBatchScores(std.testing.allocator, query_tokenizer.iterator(), &batch_indices);
            defer std.testing.allocator.free(batch_scores);

            try std.testing.expectEqual(score_matrix[alg_idx][query_idx][2], batch_scores[0]);
            try std.testing.expectEqual(score_matrix[alg_idx][query_idx][0], batch_scores[1]);
        }

        // Test getTopN on "is today?" (query_matrix[2])
        var top_n_tokenizer = WordTokenizer.init(query_matrix[2]);
        const top_n = try alg.getTopN(std.testing.allocator, top_n_tokenizer.iterator(), test_corpus, 2);
        defer std.testing.allocator.free(top_n);

        try std.testing.expectEqual(2, top_n.len);
        try std.testing.expectEqualStrings(test_corpus[2], top_n[0]);
        try std.testing.expectEqualStrings(test_corpus[1], top_n[1]);
    }
}
