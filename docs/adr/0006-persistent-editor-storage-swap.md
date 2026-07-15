# ADR-0006: One persistent editor — storage swap, not view identity

- **Status:** proposed
- **Date:** 2026-07-14

## Context

`WindowRootView` rendered the editor as `InkEditorView(...).id(selection)`.
Under SwiftUI, an `.id()` change is an identity change: every page
switch (⌘1–⌘9, ⌥⌘←→, tab click) tore down the `NSTextView` and built a
fresh one. Content survived — it lives in the per-sheet `NSTextStorage`
cache on `WindowModel` — but caret, scroll position, and undo history
are view state and died with the view. Nothing re-focused the new
editor either; the window fell back to first responder itself, ember
border lit, typing dead-ending at the window (issue #19).

Meanwhile `updateNSView` carried a `replaceTextStorage` swap path for
exactly this case — dead code, since the identity change meant
`updateNSView` never saw a sheet transition. The file's own comments
disagreed about which mechanism was in effect.

## Decision

Drop `.id(selection)`. One `NSTextView` persists across page↔page
switches; sheet transitions go through `layoutManager.replaceTextStorage`
in `updateNSView`. The coordinator saves caret and scroll per sheet
before the swap and restores them after. First responder survives the
switch because the responder never changes.

## Consequences

- Caret, scroll, undo history, and focus survive page↔page switches.
  Caret and scroll become explicit per-sheet state on the coordinator —
  saved before the swap, restored after — where before they were free
  (and freely lost).
- Scroll restore must run post-layout: the layout manager re-lays out
  asynchronously after `replaceTextStorage`, so a synchronous restore
  gets clobbered. Main-queue hop, same discipline as ADR-0005's focus
  timing.
- This covers page↔page only. The empty↔page transition still unmounts
  the editor (the empty branch renders no `InkEditorView`), so focus on
  that path rests entirely on ADR-0005's explicit grant.
- The one-layout-manager-per-storage invariant now rests on the swap
  path, not on `makeNSView`'s detach loop, which runs only at mount.
- The absent `.id()` is load-bearing. Re-adding it "for correctness"
  silently reverts this decision — the swap path goes dead again and
  every switch quietly starts discarding caret and undo. As with
  ADR-0004's `exists()`/`load()` split, the code comment must say the
  omission is contract, not oversight.

## Eject triggers

- SwiftUI or AppKit ships a first-class way to preserve `NSTextView`
  state across identity changes, making the manual save/restore
  redundant.
- A future feature needs per-sheet view instances — configuration that
  genuinely differs per page and can't be expressed by swapping storage
  into a shared view.
- The persistent view accumulates state that *should* die per switch
  (stale marked text, IME state, layout-manager drift), observed as
  cross-page contamination on hardware.
