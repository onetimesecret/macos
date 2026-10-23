---
name: project-r1-corpus-tests
description: R1 Markdown corpus tests (MarkdownCorpusTests, MarkdownHTMLSerializer); compare HTML by utf8 not ==, and how to typecheck test files without swift build
metadata:
  type: project
---

Unit C1 of R1 (2026-10-17, feat/markdown-dialects): `shell/Tests/CompanionKitTests/MarkdownHTMLSerializer.swift` ports cmark 0.31.2 html.c plus cmark-gfm table/strikethrough/tagfilter; task boxes and nested strong follow the GFM spec, not cmark-gfm. `MarkdownCorpusTests.swift` checksums both lab downloads, extracts GFM examples from the HTML page in Swift (matches `gfm-official-examples.json` exactly), and keeps a known-mismatch table per dialect.

**Why:** Swift `String ==` uses canonical equivalence, so exact-HTML comparison must be `a.utf8.elementsEqual(b.utf8)`; the lab compared bytes.

**How to apply:** when `swift build` is owned by another agent, typecheck test files against a stub module: `swiftc -emit-library -static -emit-module -enable-testing -module-name CompanionKit` on copied sources plus a stub, then `swiftc -typecheck -I mod -F $DEV/Library/Frameworks -I $DEV/usr/lib` where DEV is `Xcode.app/.../MacOSX.platform/Developer`; export SDKROOT first ([[xcrun-hangs-without-sdkroot]]). An executable harness links with `-L $DEV/usr/lib` and rpaths to both dirs.
