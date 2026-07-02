# BM25-Zig

Implementation of the BM25 search ranking algorithms in
[Zig](https://ziglang.org/). Inspired by the popular
[Python](https://www.python.org/) library
[rank_bm25](https://github.com/dorianbrown/rank_bm25).
It has the same scoring logic and a similar interface.

I have attempted to keep it as performant as I'm able to,
but there are still improvements to be made. It is single
threaded, but seems to be relatively fast.

## Performance
Here is a quick benchmark of indexing a folder on my machine:
```txt
Loaded 68089 documents (1016.88 MB) from disk in 1675.00 ms (607.09 MB/s)

=== BM25 Okapi Indexing Benchmark Results ===
Total Docs:            68089
Total Size:            1016.88 MB
Total Tokens (Words):  135402821
Unique Words (Vocab):  1058574
Pure Indexing Time:    11235.00 ms
Pure Indexing Speed:   90.51 MB/s
Throughput (Docs/sec): 6060.44 docs/s
Throughput (Toks/sec): 12051875.48 tokens/s
=============================================
```
The benchmark above was executed with the following hardware specifications:
| Component | Specification |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 5700X3D (8 Cores / 16 Threads) |
| **Memory** | 48 GB (46 GiB) RAM |
| **Storage** | Kingston NV1 1TB NVMe PCIe SSD (`KINGSTON SNVS1000G`) |
| **OS** | Linux |

Benchmarking script is in [src/benchmark.zig](src/benchmark.zig). The folder
which was indexed contains mostly software projects, some small and some
large.

## Features

- **Streaming Iterator Interface**: `DocIter` and `WordIter` abstractions allow indexing large corpora without loading files all at once.
- **Low-Allocation Scoring**: Scoring allocates a single return slice for scores, with zero dynamic allocations inside the core loop.
- **Implementation Parity**: Offers the same algorithms, defaults and scoring output as the `rank_bm25` library.
- **Zero Third-Party Dependencies**: Written entirely in `Zig`.

## Implemented Algorithms
- **OkapiBM25** (`BM25Okapi`)
- **BM25L** (`BM25L`)
- **BM25+** (`BM25Plus`)

## Install

First, add `bm25` to your package dependencies in `build.zig.zon` by fetching the library:

```sh
zig fetch --save git+https://github.com/thomashn/bm25-zig#v1.0.0
```

Next, expose the module to your target in `build.zig`:

```zig
const bm25_dep = b.dependency("bm25", .{
    .target = target,
    .optimize = optimize,
});

// Import the module into your executable/library root module
your_compilation.root_module.addImport("bm25", bm25_dep.module("bm25"));
```

## Example usage

Here is BM25 indexing, using a tokenizers on an in-memory corpus. The
usage of iterators might seem a bit daunting, but I think any serious
usage would require them eventually, both for performance and
flexibility. You are expected to copy and paste these tokenizers and
modify them for your own use case.

```zig
const std = @import("std");
const bm25 = @import("bm25");
const WordIter = bm25.WordIter;
const DocIter = bm25.DocIter;

const WordTokenizer = struct {
    split_iter: std.mem.SplitIterator(u8, .any),

    pub fn init(doc: []const u8) WordTokenizer {
        return .{ .split_iter = std.mem.splitAny(u8, doc, " ") };
    }

    fn next(base: WordIter) !?[]const u8 {
        const self: *WordTokenizer = @ptrCast(@alignCast(base.ctx));
        return self.split_iter.next();
    }

    pub fn iterator(self: *WordTokenizer) WordIter {
        return WordIter{ .ctx = self, .nextFn = WordTokenizer.next };
    }
};

const CorpusTokenizer = struct {
    corpus_idx: usize = 0,
    corpus: []const []const u8,
    word_tokenizer: ?WordTokenizer = null,

    pub fn init(corpus: []const []const u8) CorpusTokenizer {
        return CorpusTokenizer{ .corpus = corpus };
    }

    fn next(base: DocIter) !?WordIter {
        const self: *CorpusTokenizer = @ptrCast(@alignCast(base.ctx));
        if (self.corpus_idx >= self.corpus.len) return null;
        self.word_tokenizer = .init(self.corpus[self.corpus_idx]);
        self.corpus_idx += 1;
        return self.word_tokenizer.?.iterator();
    }

    pub fn iterator(self: *CorpusTokenizer) DocIter {
        return DocIter{ .ctx = self, .nextFn = CorpusTokenizer.next };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const allocator = gpa.allocator();

    const corpus: []const []const u8 = &.{
        "Hello there good man!",
        "It is quite windy in London",
        "How is the weather today?",
    };
    var corpus_tokenizer = CorpusTokenizer.init(corpus);
    var alg = try bm25.BM25Okapi.init(allocator, corpus_tokenizer.iterator(), .{});
    defer alg.deinit();

    const query = "windy london";
    var query_tokenizer = WordTokenizer.init(query);
    const scores = try alg.getScores(allocator, query_tokenizer.iterator());
    defer allocator.free(scores);

    std.debug.print("Scores: {any}\n", .{scores});
}
```

## Implementing tokenizers

The above example uses the same tokenizers that are used in unittests, a more
realistic implementation can be found in the cli tool under [src/main.zig](src/main.zig).
Predicting tokenizer usage is impossible, so users are required to
implement their own, these examples are a good starting point.

In the above example, obvious improvements to the WordTokenizer
and DocTokenizer would be introduction of case insensitive
tokenization and reading from a file instead of an in memory
structure.

Based on my experience, so far, tokenizers performance is very
important to the overall indexing time, so keep that in mind if
you feel indexing is slow.

## Command line tool

You can build a command line tool that can index all files in a directory
and output a score.
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/bm25 ~/some/folder 'hello world'
```
To get propper speed, build with `-Doptimize=ReleaseFast`, or else you might
get slowed down by memory poison detection. Also, this is a
toy program I made to polish the interface, so there is still performance
left on the table. I think tokenization could easily be made multi-threaded,
and that the exclude logic could be made to work like ripgrep and
so on.

## Running Tests

Test cases are run against the output of `rank_bm25` in order to
verify the implementation. The example text is also taken from
`rank_bm25`.

```sh
zig build test
```

## Credits

* **[rank_bm25](https://github.com/dorianbrown/rank_bm25)** - The popular Python implementation on which the scoring algorithms, parameter defaults, and verification test cases in this project are based.

## License

This project is licensed under the [MIT License](LICENSE).
