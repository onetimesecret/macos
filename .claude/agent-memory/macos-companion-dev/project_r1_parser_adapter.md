---
name: project-r1-parser-adapter
description: R1 MarkdownParser adapter facts: plane 16 caps a page at 65,534 objects, depth counting that maximumDepth 1 must survive, link address objects follow the label, a line 0 paragraph above tables, the shared table cell budget
metadata:
  type: project
---

`MarkdownParser.parse` (shell/Sources/CompanionKit/MarkdownParser.swift) replaced swift-markdown on feat/markdown-dialects (PR 328). The plan's R1 Delivery record (docs/spec/design/2026-1016-markdown-dialects-and-preview.md) is the contract; facts the code does not make obvious:

- A page with more than 65,534 objects can never get a placeholder window, so it always renders as the plain fallback.
- Depth counts block quotes, lists (an item shares its list's level) and inline containers, never paragraphs. MarkdownPreviewCompositionTests pins `**a**` rendering formatted at `maximumDepth = 1`, so do not count leaf blocks.
- A link's destination and title objects go out after `leaveLink` as `.object` events, and `enterLink` gets U+FFFC stand-ins instead (2026-10-23, source order, as images already did). The composer still emits objects it finds in an `enterLink` address at the link's opening; the walker just never sends it any.
- A title object never refuses the address; ADR-0059 decision 5 names resource addresses only.
- cmark-gfm gives the paragraph it keeps above a table line 0; `blocks(of:)` gives it the next block's start, or `place` misorders a definition's object.
- Every table of a parse shares one cell budget (patches/0003, `CompositionLimits.maximumTableCells`), set and read under the shim's parse lock.
- Where cmark-gfm 0.29.0.gfm.13 and the published GFM 0.29 page differ, cmark-gfm defines the dialect (maintainer's direction, 2026-10-23); do not patch those departures.

**Why:** these choices were made during the slice, and some reverse what the first working design said.
**How to apply:** check this before changing depth limits, address refusal, link object order, the placeholder scheme or the vendored table code. Related: [[project-r1-corpus-tests]], [[project-r1-vendored-parsers]], [[project-r1-sealed-atom-fixtures]].
