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

[`Markdown corpus and table-budget coverage`](../../../docs/qa/markdown-table-budget.md)
