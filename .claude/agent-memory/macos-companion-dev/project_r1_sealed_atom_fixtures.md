---
name: project-r1-sealed-atom-fixtures
description: R1 unit C2 (2026-10-17) MarkdownSealedAtomTests facts; render through a closing **fin** paragraph or the plain fallback passes unseen; cmark-gfm 0.29.0.gfm.13 departs from published GFM 0.29 in four places; an excess table cell's object ends its row's last kept cell
metadata:
  type: project
---

`shell/Tests/CompanionKitTests/MarkdownSealedAtomTests.swift` (29 tests, uncommitted at hand-off 2026-10-17) fixtures P01 to P07 and the R1 row's grammar cases under both dialects.

- For a page with no syntax, the plain fallback and a real rendering give the same string. The file's `render` adds `\n\n**fin**` and requires a bold `fin\n` at the end before it trusts the result.
- cmark-gfm 0.29.0.gfm.13 departs from the published GFM 0.29-gfm page (tools/markdown-preview-lab/parser/results/gfm-0.29-spec.html): `<textarea>` is an HTML block of the first kind, so it stays open across blank lines; `ftp://` gets an extended autolink; `www. x` links `www` to `http://www`; comments follow the CommonMark 0.31 grammar (corpus examples 649 and 650). Only the comments show up in the corpus mismatch table.
- The composer reads `<!-->` and `<!--->` as literal text (HTMLTokenizerTests pins this), although both parsers return them as raw HTML.
- A GFM excess cell's object ends its row's last kept cell (fixed 2026-10-23; it used to stand after the table, out of source order). The adapter finds the row by line, from the shim's row start and end lines.
- An object of a definition in a reference title becomes a stand-in in the title, and the link stays live. The working design says "refused either way", but the adapter follows the composer's title rule. See [[project-r1-parser-adapter]].

**Why:** a later R1 or R3 change to the placement, the title rule or the vendored parser will flip these fixtures, and the reason is not in the code.
**How to apply:** check this before changing those rules or updating cmark-gfm. Related: [[project-r1-corpus-tests]].
