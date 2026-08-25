# Issue #79 — the perforated roll (branch 6 of the vertical-time-tabs stack)

Landed 2026-08-25 on `claude/79-6-perforated-roll-ymyi7n`, over the time
rail. ADR-0020 required-work items 13 and 14, which completes the list.
The summit of the stack: the contiguous scroll, the day headers and
their verbs, the quiet regions, the anchor rule, and the hardware
procedure.

## What exists now

- `shell/Sources/CompanionKit/DayScrollView.swift`: `DayScrollView`
  (`NSViewRepresentable`, one `NSScrollView`) over `DayStackView`
  (`isFlipped`, frame layout, no Auto Layout), with `DayHeaderView`,
  `QuietPageView` and `EmptyTodayView`. The representable's coordinator
  **is** an `InkEditorView.Coordinator`, so ops, restyle, chips, seals
  and undo are the shipped paths.
- `PageModel.quietRendering(for:)` + `invalidateQuietRendering(for:)`
  over a private `quietRenderings` map, pruned in `refresh()` on the
  same live-page set as `storages`/`undoManagers`.
- `PageModel.anchorOnToday()` and the `onAnchorToday` closure, called
  from `BackdropModel.raise()`.
- `TabRenamePrompt.newName(for:)` in TabStripView.swift — the one diff
  that file takes in this whole stack.

## Five things a later branch must not re-decide

- **The editor is a permanent child and only its frame origin moves.**
  `removeFromSuperview` is never called on it, which is the whole reason
  focus, marked text and per-page undo survive a day switch. The one
  exception is not an exception: when no live page is visible the editor
  is *parked* (fresh empty storage, zero frame, `activeEditor` dropped)
  rather than removed.
- **A quiet region's storage is its own and the model never learns of
  it.** That is what keeps one view — and therefore one layout manager —
  per storage true by construction. `model.storage(for:)` is for the
  editor alone.
- **The quiet region for the page the editor is moving onto comes out of
  the stack before the swap.** Never two views over one page, not even
  for the length of a call.
- **Perforations are chrome.** Nothing separating two days may be a
  character in a storage; it would cross the seam as an insert op.
- **The rendering cache needs invalidating, not just pruning.** A cached
  day is sound only while the day is quiet, and a page stops being quiet
  the moment the editor arrives on it.

## Five AppKit traps this branch actually hit

- **A TextKit 1 storage nobody retains is freed.** Ownership runs
  storage → layout manager → container → view, and the back references
  are unowned. `QuietPageView` holds its own storage in a `let`; the
  parked editor's empty storage is held by the stack. The model's map is
  what retains the editor's.
- **`autoresizesSubviews` must be off on a stack that places by frame.**
  Otherwise setting the stack's own width re-widens every child by the
  same delta on top of the width the layout just gave it.
- **Setting a frame posts a frame-change notification**, and the
  notifications are what drive the re-layout. One `isLayingOut` flag
  gates both the layout pass and the assembly, or building the editor
  starts a pass over rows that have not been assigned yet.
- **Key paths cannot name tuple elements.** `laidOut.map(\.header.mark)`
  does not compile; `laidOut.map { $0.header.mark }` does. (Branch 5
  suspected this and avoided it; branch 6 confirms it is worth avoiding.)
- **A header is not a fixed height, so the anchor measures the ink.**
  The page that was first on the roll gains a tear the moment a day
  arrives above it, and its header grows by `tearReserve`. Measured at
  the header's top that growth is invisible and the reader slides down
  twelve points; `topmostPageAnchor` and `keepStill` therefore both
  measure `body.frame.minY`.

## Testing notes

- `DayScrollView.makeRoll(model:coordinator:emptyHint:)` is a static so
  the tests build what `makeNSView` builds — a SwiftUI `Context` cannot
  be made in XCTest, so `DayStackView.update(projection:selectedPage:
  readOnly:)` is the seam a test drives instead.
- **Hold the window.** The stack is a subview of a scroll view inside a
  window; a window nobody retains takes the roll's superview chain down
  with it mid-test.
- The days are hand-spread: a live core still cannot make two days, so
  the pages, ids, documents and storages are real and only the
  `pageDayOffset` on each summary is rewritten before
  `TimeUnitProjection.project`. `TabSummary`'s 17-argument memberwise
  init is written out in declaration order in two test files.
- `QuietPageView.clicked(at:)` exists so a click can be asserted without
  a synthesized `NSEvent`.
