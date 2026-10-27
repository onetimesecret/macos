# Specification examples

The two files here are the official examples that `src/tests/corpus.rs` reads. They are
third party test data, not part of the crate or the app, and the repository's license does
not replace their own.

## commonmark-0.31.2-spec.json

CommonMark Spec, by John MacFarlane, version 0.31.2 (2024-01-28).
Source: <https://spec.commonmark.org/0.31.2/>; this file is the unmodified download of
<https://spec.commonmark.org/0.31.2/spec.json> (652 examples, 140,487 bytes).
SHA-256: `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`.
License: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/),
as the front matter of cmark 0.31.2's `test/spec.txt` gives it.

## gfm-0.29-examples.json

GitHub Flavored Markdown Spec, version 0.29-gfm (2019-04-06).
Source: <https://github.github.com/gfm/>. The page says it is based on the CommonMark Spec
by John MacFarlane and licensed under
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/);
the front matter of cmark-gfm 0.29.0.gfm.0's `test/spec.txt` gives the same license.

This file is an adaptation under the same license: the 677 numbered examples extracted from
the downloaded page (SHA-256
`b153d814fdfc8624bb6da7449162c1cd707a637f7d1c1b636eb44b9cf63fa220`, 508,310 bytes).
Each example is its `example-N` div's markdown and html code blocks, with the
`<span class="space">` wrappers removed, the `&amp;`, `&lt;`, `&gt;` and `&quot;` references
decoded and each shown tab (U+2192) written back as a tab. The section is the last h2 or h3
heading before the example.
The file is `tools/markdown-preview-lab/parser/results/gfm-official-examples.json`, unchanged,
from commit 41266668 on the `feat/markdown-dialects` branch, where the markdown preview lab's
`GFMExamples` extractor wrote it and the shell's `MarkdownCorpusTests` (commit 5b0eed41)
compared it with that test's own extraction of the same page.
SHA-256: `a651225602a1c9789c9dde3eda3a24fcc1151a14f364d77de8fd410f62616310`.

## Changing either file

`the_copied_specifications_are_the_recorded_files` pins both digests. A new download or a
new extraction changes the digest in that test and the entry above together.

## Table-budget coverage

`the_table_cell_bound_covers_every_gfm_example` c󠄁o󠄁m󠄁p󠄁a󠄁r󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁-󠄁s󠄁c󠄁a󠄁n󠄁 b󠄁o󠄁u󠄁n󠄁d󠄁 w󠄁i󠄁t󠄁h󠄁
c󠄁o󠄁m󠄁r󠄁a󠄁k󠄁'󠄁s󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 t󠄁a󠄁b󠄁l󠄁e󠄁-󠄁c󠄁e󠄁l󠄁l󠄁 c󠄁o󠄁u󠄁n󠄁t󠄁 f󠄁o󠄁r󠄁 a󠄁l󠄁l󠄁 6󠄁7󠄁7󠄁 e󠄁x󠄁a󠄁m󠄁p󠄁l󠄁e󠄁s󠄁,󠄁 a󠄁f󠄁t󠄁e󠄁r󠄁 s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁 n󠄁o󠄁r󠄁m󠄁a󠄁l󠄁i󠄁z󠄁a󠄁t󠄁i󠄁o󠄁n󠄁.󠄁
T󠄁h󠄁e󠄁 g󠄁e󠄁n󠄁e󠄁r󠄁a󠄁t󠄁e󠄁d󠄁-󠄁p󠄁a󠄁g󠄁e󠄁 t󠄁e󠄁s󠄁t󠄁 u󠄁s󠄁e󠄁s󠄁 s󠄁p󠄁l󠄁i󠄁t󠄁m󠄁i󠄁x󠄁6󠄁4󠄁 s󠄁e󠄁e󠄁d󠄁 3󠄁3󠄁2󠄁 a󠄁n󠄁d󠄁 4󠄁,󠄁0󠄁0󠄁0󠄁 p󠄁a󠄁g󠄁e󠄁s󠄁 b󠄁y󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁.󠄁 T󠄁o󠄁
r󠄁u󠄁n󠄁 a󠄁 l󠄁o󠄁n󠄁g󠄁e󠄁r󠄁,󠄁 r󠄁e󠄁p󠄁r󠄁o󠄁d󠄁u󠄁c󠄁i󠄁b󠄁l󠄁e󠄁 s󠄁a󠄁m󠄁p󠄁l󠄁e󠄁 o󠄁r󠄁 c󠄁h󠄁o󠄁o󠄁s󠄁e󠄁 a󠄁n󠄁o󠄁t󠄁h󠄁e󠄁r󠄁 d󠄁e󠄁c󠄁i󠄁m󠄁a󠄁l󠄁 s󠄁e󠄁e󠄁d󠄁:󠄁

```sh
COMPANION_MARKDOWN_TABLE_FUZZ_PAGES=1400000 \
COMPANION_MARKDOWN_TABLE_FUZZ_SEED=332 \
cargo test -p companion-markdown no_generated_page_makes_more_cells_than_its_bound --release
```

A󠄁 f󠄁a󠄁i󠄁l󠄁u󠄁r󠄁e󠄁 r󠄁e󠄁p󠄁o󠄁r󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 s󠄁e󠄁e󠄁d󠄁,󠄁 z󠄁e󠄁r󠄁o󠄁-󠄁b󠄁a󠄁s󠄁e󠄁d󠄁 p󠄁a󠄁g󠄁e󠄁 i󠄁n󠄁d󠄁e󠄁x󠄁 a󠄁n󠄁d󠄁 g󠄁e󠄁n󠄁e󠄁r󠄁a󠄁t󠄁e󠄁d󠄁 t󠄁e󠄁x󠄁t󠄁.󠄁 T󠄁h󠄁i󠄁s󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁
d󠄁e󠄁f󠄁i󠄁n󠄁e󠄁s󠄁 a󠄁 r󠄁e󠄁p󠄁e󠄁a󠄁t󠄁a󠄁b󠄁l󠄁e󠄁 r󠄁u󠄁n󠄁;󠄁 i󠄁t󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 a󠄁t󠄁t󠄁e󠄁s󠄁t󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 e󠄁a󠄁r󠄁l󠄁i󠄁e󠄁r󠄁 o󠄁f󠄁f󠄁l󠄁i󠄁n󠄁e󠄁 e󠄁x󠄁p󠄁e󠄁r󠄁i󠄁m󠄁e󠄁n󠄁t󠄁.󠄁
