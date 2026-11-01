# Markdown corpus and table-budget coverage

The GFM mismatch count describes this crate's test HTML writer as well as the
parser. Five entries (140, 141, 142, 145 and 147) reflect the writer's tagfilter
against corpus examples with unfiltered blocks. The document AST retains raw
HTML in distinct HTML cases; the mismatch total is not an AST-only conformance
score or an HTML-execution policy.

`the_table_cell_bound_covers_every_gfm_example` compares the pre-scan bound with
comrak's actual table-cell count for all 677 examples, after source normalization.
The generated-page test uses splitmix64 seed 332 and 4,000 pages by default. To
run a longer, reproducible sample or choose another decimal seed:

```sh
COMPANION_MARKDOWN_TABLE_FUZZ_PAGES=1400000 \
COMPANION_MARKDOWN_TABLE_FUZZ_SEED=332 \
cargo test -p companion-markdown no_generated_page_makes_more_cells_than_its_bound --release
```

A failure reports the seed, zero-based page index and generated text. This command
defines a repeatable run; it does not attest to the earlier offline experiment.
