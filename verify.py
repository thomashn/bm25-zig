"""Generate verification code using original implementation

We are verifying against the rank_bm25 implementation
https://github.com/dorianbrown/rank_bm25

Create a virtualenv in project root:
python -m venv .venv
source .venv/bin/activate
pip install rank_bm25
python verify.py

It outputs the score matrix used at the end of src/root.zig.
"""
import rank_bm25
from typing import List


def tokenizer(document):
    return document.split(' ')


test_corpus: List[str] = [
    "Hello there good man!",
    "It is quite windy in London",
    "How is the weather today?",
]


query_matrix = [
    ["Hello", "World"],
    ["Windy", "weather"],
    ["is", "today?"],
    ["is", "today?", "good"],
]


def gen_zig_score_matrix():
    algorithms = [rank_bm25.BM25Okapi, rank_bm25.BM25L, rank_bm25.BM25Plus]

    print("const query_matrix: []const []const []const u8 = &.{")
    for query in query_matrix:
        temp = ", ".join([f'"{q}"' for q in query])
        print(f'\t.{{ {temp} }},')
    print("};")
    print("")
    print("const score_matrix : []const []const []const f64 = &.{" )
    for Algorithm in algorithms:
        print("\t&.{")
        print(f"\t\t// {Algorithm.__name__}")
        alg = Algorithm(test_corpus, tokenizer)
        for query in query_matrix:
            scores = alg.get_scores(query)
            print("\t\t&.{")
            print(f"\t\t\t// {query}")
            for score in scores:
                print(f"\t\t\t{score},")
            print("\t\t},")
        print("\t},")
    print("};")
        

if __name__ == "__main__":
    gen_zig_score_matrix()
