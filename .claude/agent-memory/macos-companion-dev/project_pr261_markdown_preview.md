---
name: project-pr261-markdown-preview
description: PR 261 (fix/checkpoint-preview) review round 2026-10-16; the preview is an AskingTextView, copy goes through companion_sheet_compose_fragment, two ride along fixes were reverted for an Xcode 26.6 IRGen crash, swift-markdown 0.9.0 does not resolve under Xcode 26.0
metadata:
  type: project
---

PR 261 (builtin Markdown preview, `MarkdownPreviewView`) was reworked on 2026-10-16 after three reviewers found it ungated. The view is an `AskingTextView` subclass with `page` and a weak coordinator; `mayReadOut` asks `PageModel.givesOut(sheet:)`; copy composes through the core's `companion_sheet_compose_fragment(handle, sheet, shown_json)` (the synced document JSON shape, `Segment` reused, `Sheet::compose` in fragment.rs); no drag starts; only the selected page's preview is selectable (`isSelectedPage`), a click on another calls `onPromote`. The link menu plumbing (`LinkTarget`, `aimLinkItems`, `openLinkFromMenu`, `copyLinkFromMenu`) lives in `AskingTextView` with `openAimedLink`, `linkBoard`, `aimsLinkItems` hooks that InkTextView overrides.

**Why:** Law 0001's expiry and export rows cover text the shell shows, and the preview is the page's ink rendered. The core composes every fragment (ADR-0045, proposed), so a rendered selection with no source range needed a core route.

**How to apply:** Law 0001's AppKit text routes table ends with five preview rows citing CheckpointMarkdownPreviewTests; a new reader over the preview takes a row there. `NSWindow.makeFirstResponder` returns YES and gives the keys to the window when the responder refuses, so test `firstResponder !== view`, not the return value. Two ride along commits (TextOffers typed Writing Tools selector, TimeRailView `@MainActor @Sendable` sort closure) were reverted: the closure type crashes swift-frontend IRGen on Xcode 26.6 (CI) in TimeRailView's reabstraction thunk, while Xcode 27 builds without them. swift-markdown 0.9.0 cannot be resolved by Xcode 26.0's SwiftPM (Swift 6.2): it rejects the package's windows only unsafeFlags. The release packaging path (`scripts/package-app.sh`, `swift build`) fetches swift-markdown from GitHub with no cache step; an ADR-0002 note is owed to the maintainer.
