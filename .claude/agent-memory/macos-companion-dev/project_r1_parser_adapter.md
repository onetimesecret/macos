---
name: project-r1-parser-adapter
description: R1 unit B (2026-10-17) MarkdownParser adapter facts: plane 16 caps a page at 65,534 objects, depth counting that maximumDepth 1 must survive, title objects never refuse an address, stale swift-cmark comments left for the vendoring owner
metadata:
  type: project
---

`MarkdownParser.parse` (shell/Sources/CompanionKit/MarkdownParser.swift) replaced swift-markdown on feat/markdown-dialects, uncommitted at hand-off on 2026-10-17. Facts the code does not make obvious:

- A page with more than 65,534 objects can never get a placeholder window, so it always renders as the plain fallback.
- Depth counts block quotes, lists (an item shares its list's level) and inline containers, never paragraphs. MarkdownPreviewCompositionTests pins `**a**` rendering formatted at `maximumDepth = 1`, so do not count leaf blocks.
- The working design says a destination or title object refuses the address "either way", but `PreviewComposer` refuses on destination objects only (`testTitleObjectsAloneDoNotRefuseALinkAddress`). The adapter follows the composer.
- cmark-gfm registers no definition for definition lines in the paragraph a table header splits off, so their objects show as text there.
- `PreviewComposer.reservedPlaceholders` still lists "OTSAttachment", left over from the retired token path.
- prefix.h (both CMark targets) and scripts/vendor-cmark.sh still say the copies "link beside swift-cmark". They belong to the vendoring unit's owner.

**Why:** these choices were made during the unit and do not appear in the design text.
**How to apply:** check this before changing depth limits, address refusal or the placeholder scheme. Related: [[project-r1-corpus-tests]], [[project-r1-vendored-parsers]].
