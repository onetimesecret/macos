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
- **The rendering cache is invalidated at the mutation, not at the
  view's swap.** See below: the first version invalidated on the
  editor's way past and was wrong on four paths at once.

## Six AppKit traps this branch actually hit

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
- **`makeFirstResponder` answers true for a view that refuses.** Apple
  documents it in as many words: a responder that refuses hands the
  status to the window instead, and the call still returns true. Assert
  a refusal off `window.firstResponder` afterwards, never off the
  return. The stack's first CI run failed two tests on this.
- **A header is not a fixed height, so the anchor measures the ink.**
  The page that was first on the roll gains a tear the moment a day
  arrives above it, and its header grows by `tearReserve`. Measured at
  the header's top that growth is invisible and the reader slides down
  twelve points; `topmostPageAnchor` and `keepStill` therefore both
  measure `body.frame.minY`.

## What the adversarial review changed (2026-08-25)

- **Invalidate where the page changes, and let the view see it.** The
  cache was dropped only in `settleEditor`'s swap, which misses: an edit
  made with the strip showing (the map outlives a roll dismantle), the
  pass that *builds* the editor (`makeInkTextView` sets `currentSheet`
  itself, so the swap's guard early-returns), a chip burned out of a day
  the editor had left, and a composition still marked as the editor
  leaves. `PageModel` now drops a page's rendering in `applyOps`
  (accepted), `syncDocument` (accepted) and `removeChipFromDocument` —
  and the chip's host page is looked up **before** the delete, from the
  core, because a chip can stand on a day with a rendering and no
  storage. Model-side correctness is only half: a `QuietPageView` never
  re-read its rendering, so it holds the object it was seeded from and
  `reseed(with:)` compares identity, driven from `quietRegion(for:)` and
  from `refreshQuietRegions()` on the **ordinary** pass — none of these
  changes moves a bucket, a page id or the selection, so none of them
  changes the roll's signature.
- **Settle the composition before `assembleRows`, not inside the swap.**
  The outgoing day's rendering is read from the core during assembly,
  and marked text is deliberately kept out of the core until it settles.
  `settleComposition(before:)` runs first — and inside the `isLayingOut`
  gate, because settling grows the editor and a text view that grows
  posts a frame change.
- **The anchor rides a summon, not an activation.** `BackdropModel.raise`
  is also `applicationDidBecomeActive`'s handler, so hanging
  `anchorOnToday()` on it gave a ⌘Tab return the summon's behaviour —
  contradicting ADR-0020, the spec, and the QA case this same stack
  wrote. `raise(_ reason: BackdropRaise)` now takes its reason and
  `BackdropModel.anchorsOnToday(raise:)` is the pure boundary (with a
  test). Summons: ⌃⌥Space, the menu-bar item, the click on the resting
  card. Activations: ⌘Tab, the app switcher, **the Dock** — filed that
  way because a Dock click arrives at `applicationDidBecomeActive` when
  the app is inactive and `applicationShouldHandleReopen` when it is
  active, and one gesture must not mean two things. The pasteboard
  offer is deliberately *not* split; it rides every raise.
- **⌥Z is 79-6's defect, not 79-3's.** The spec said ⌥Z is inert in the
  mode and the code toggled `wrapsLines` anyway. The gate belongs here
  because `coordinator.applyWrap(true)` is here: on 79-3 and 79-5 the
  mode still mounts `PageContentView`'s ordinary editor, which honours
  the preference, so gating there would have made those branches wrong.
  `KeymapRegistry`'s `.editorToggleWrap` arm branches on the mode and
  flashes `PageModel.wrapIsFixedNotice`; "inert" became "changes
  nothing, and says so", which the spec bullet now states.
- **Cite DayScrollView.swift by symbol, never by line.** Its numbers
  went stale inside the branch that wrote them and again when these
  fixes landed. The spec's change map, ADR-0020 item 13 and this file
  all name types and functions for that file now.
- **A merge on this stack carries a message.** `git merge --no-edit`
  takes git's bare "Merge branch X into Y" and no trailers, and the
  merges that carried the review's fixes up the chain (974102e, 129e3ba,
  b76232c and the three before them) went out that way — they cannot be
  corrected, since the alternative is an amend or a force-push and both
  are refused here. The stack's own convention, set by 82a36b7, is a
  one-sentence body saying what is being carried up plus the two
  trailers. Use `git merge -m` and write it.

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
