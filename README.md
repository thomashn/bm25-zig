# BM25-Zig
[![Zig Version](https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Implementation of the BM25 search ranking algorithms in
[Zig](https://ziglang.org/). Inspired by the popular
[Python](https://www.python.org/) library
[rank_bm25](https://github.com/dorianbrown/rank_bm25).

Implements the following algorithms:
- **OkapiBM25** (`BM25Okapi`)
- **BM25L** (`BM25L`)
- **BM25+** (`BM25Plus`)

Has some nice features:
- **Streaming**: Indexing relies on iterators, which allows for indexing of huge corpora.
- **Low-Allocation Scoring**: Only the returned scores array requires an allocator.
- **Similar interface**: Offers the same algorithms, defaults and scoring output as the `rank_bm25` library.
- **No dependencies**: Written entirely in `Zig` with no third party libraries in the module.
- **Reference implementation**: It has a CLI which allows indexing and search in directory.

## Install
First, add `bm25` to your package dependencies in `build.zig.zon` by fetching the library:
```sh
zig fetch --save git+https://github.com/thomashn/bm25-zig#v1.1.0
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
The user needs to provide a basic tokenizer which exposes a **next** function.
```zig
const std = @import("std");
const bm25 = @import("bm25");

const WordTokenizer = struct {
    split_iter: std.mem.SplitIterator(u8, .any),

    pub fn init(doc: []const u8) WordTokenizer {
        return .{ .split_iter = std.mem.splitAny(u8, doc, " ") };
    }

    fn next(self: *WordTokenizer) !?[]const u8 {
        return self.split_iter.next();
    }

    // Utility function for query tokenization
    pub fn iterator(self: *WordTokenizer) bm25.WordIter {
        return bm25.wordIterator(self);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa.allocator();

    // Simple use cases will likely involve a slice of some kind,
    // therefore the module provides a SliceIterator function for convenience.
    const corpus = &[_][]const u8{
        "cherry pie",
        "apple tart",
        "fish chips",
    };
    var corpus_iter = bm25.SliceIterator([]const u8, WordTokenizer).init(corpus);

    // Initialize your preferred version of BM25.
    var ranker = try bm25.BM25Okapi.init(allocator, corpus_iter.iterator(), .{});
    defer ranker.deinit();

    // Searches should go through the same tokenizer as the indexing
    const query = "cherry pie";
    var query_tokenizer = WordTokenizer.init(query);
    const scores = try ranker.getScores(allocator, query_tokenizer.iterator());
    defer allocator.free(scores);

    for (scores, 0..) |score, idx| {
        std.debug.print("idx: {}, score: {d}\n", .{ idx, score });
    }
}
```
## Command line
In order to ensure the module interface made sense and that
the algorithm was performant, I created a reference implementation
in the form of a CLI tool that can index all files in a directory
and output a score.
```bash
zig build -Doptimize=ReleaseFast -- ~/some/folder 'hello world'
```
To get proper speed, build with `-Doptimize=ReleaseFast`, or else you might
get slowed down by memory poison detection.

I would recommend using the CLI code as a reference when
attempting to build more complicated/streaming tokenizers.
The code is located in [src/main.zig](src/main.zig).

## Running Tests
Test cases are run against the output of `rank_bm25` in order to
verify the implementation. The example text is also taken from
`rank_bm25`.
```bash
zig build test
```
## Performance
I attempt to keep it as performant as I can. It seems to
be relatively fast at this point.

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

> [!TIP]
> Based on my experience, so far, tokenizer performance is very
> important to the overall indexing time, so keep that in mind if
> you feel indexing is slow.

## Custom tokenizers
Predicting tokenizer use-cases is really difficult. Therefore,
I've opted to avoid providing ready made tokenizers, and instead
provide a minimum helper in the form of the [SliceIterator](src/root.zig),
[docIterator](src/root.zig) and [wordIterator](src/root.zig) factories.

But, as the corpus expands, you will need a more efficient way
to index huge corpuses. This requires the ability to stream the data
you are indexing on. In [src/main.zig](src/main.zig) the code reads
through all relevant files in a directory, but only holds on to the
data of a couple of files at once, avoiding the huge memory consumption
of a slice based approach.

Creating your own iterator actually requires the creation of two iterators;
**DocIter** and **WordIter**. The former is responsible for
iterating over each document. In the CLI, this is responsible for
reading the files. For each file it will spawn the word iterator,
responsible for presenting words to the indexer.

Here is an expanded example of the one above, implementing a full tokenizer
pipeline:
```zig
const std = @import("std");
const bm25 = @import("bm25");

const WordTokenizer = struct {
    split_iter: std.mem.SplitIterator(u8, .any),

    pub fn init(doc: []const u8) WordTokenizer {
        return .{ .split_iter = std.mem.splitAny(u8, doc, " ") };
    }

    fn next(self: *WordTokenizer) !?[]const u8 {
        return self.split_iter.next();
    }

    pub fn iterator(self: *WordTokenizer) bm25.WordIter {
        return bm25.wordIterator(self);
    }
};

const CorpusTokenizer = struct {
    corpus_idx: usize = 0,
    corpus: []const []const u8,
    word_tokenizer: WordTokenizer = undefined,

    pub fn init(corpus: []const []const u8) CorpusTokenizer {
        return CorpusTokenizer{ .corpus = corpus };
    }

    fn next(self: *CorpusTokenizer) !?bm25.WordIter {
        if (self.corpus_idx >= self.corpus.len) return null;
        self.word_tokenizer = .init(self.corpus[self.corpus_idx]);
        self.corpus_idx += 1;
        return self.word_tokenizer.iterator();
    }

    pub fn iterator(self: *CorpusTokenizer) bm25.DocIter {
        return bm25.docIterator(self);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa.allocator();

    const corpus: []const []const u8 = &.{
        "cherry pie",
        "apple tart",
        "fish chips",
    };
    var corpus_tokenizer = CorpusTokenizer.init(corpus);
    var alg = try bm25.BM25Okapi.init(allocator, corpus_tokenizer.iterator(), .{});
    defer alg.deinit();

    const query = "cherry pie";
    var query_tokenizer = WordTokenizer.init(query);
    const scores = try alg.getScores(allocator, query_tokenizer.iterator());
    defer allocator.free(scores);

    for (scores, 0..) |score, idx| {
        std.debug.print("idx: {}, score: {d}\n", .{ idx, score });
    }
}
```
## Credits

* **[rank_bm25](https://github.com/dorianbrown/rank_bm25)** - The popular Python implementation on which the scoring algorithms, parameter defaults, and verification test cases in this project are based.

## License

This project is licensed under the [MIT License](LICENSE).
