---
name: w03-removal-routes
description: Phase 4 W03 (2026-10-14) put every page deletion through deleting(forward:intent:) and every object removal through the coordinator's shouldChangeTextInRanges watch; W04 moved the removal Undo's stamp into PageModel (countEdit per document), and phase 5 unit 3 routed its step through the page storage's one surface; AppKit facts the design rests on (no didChange while marked, block objects own their line fragment, the kill buffer holds U+FFFC as text)
metadata:
  type: project
---

Every page edit that takes an object says the removal line through one
watch: `Coordinator.textView(_:shouldChangeTextInRanges:replacementStrings:)`
ends the coalescing run when the ranges hold an object, and
`settleRemovalWatch` (at `textDidChange`, and deferred in
`finishComposition`) says the line if a watched chip no longer stands.
The core's paste and place restate by projection, so they skip the hook
and call `noteRemoval` themselves. Deletion selectors call
`InkTextView.deleting(forward:intent:)`; nil direction (delete:,
deleteToMark, yank) takes no first press.

**Why:** W03 said only ⌫ and ⌦ took the two presses and the line;
the brief asked for one shared path, not a copy per selector.

**How to apply:**
- A new AppKit edit route needs nothing to get the line; a new core
  route that replaces a selection must call `noteRemoval` after its
  restate, as `pasteFragment` and `placeActiveCut` do.
- Do not call `noteRemoval` after an AppKit edit by hand (the menu's
  removal relied on that and now goes through the watch); it would flash twice.
- AppKit posts no `NSText.didChangeNotification` while text is marked,
  and both `shouldChangeText(in:)` and the ranges form reach the
  delegate's ranges method (probed 2026-10-14).
- A sealed block lays out on its own line fragment, so ⌘⌫
  (deleteToBeginningOfLine) never reaches past one; ⌃K and
  deleteToBeginningOfParagraph do. ⌥⌫ after `￼ ` deletes the space and
  the object together.
- AppKit's kill buffer is plain text: ⌃K over an object then ⌃Y wrote
  U+FFFC back as ink, not an object. Fixed 2026-10-14: the editor's
  willProcessEditing strips it and the core refuses it as ink.

W04 (same day) moved the removal's stamp and Undo into PageModel:
`removalStamp` is (page, count of edits the model sent for it), the
count lives in `editGenerations` keyed by `InkDocument`, and `countEdit`
retires the Undo the moment the page's count moves. Since phase 5 unit 3
(2026-10-14) `undoRemoval` asks the page's storage for the one surface
whose layout manager reads it (`surface(showing:)`) and steps through
its `Coordinator.step`, so the editability gate holds; only with no
surface on the page does it call `stepEdit` alone. A parked coordinator
(teardown sets currentSheet nil) keeps the Undo; any coordinator
mounting another page retires it (`surfaceMounted`). The removal watch
holds an ask's objects as `asked` until `didProcessEditing` lands them
outside a projection write; the next ask drops an unlanded ask.
`model.newPage()` clears the notice, so a test that needs a second page
beside a live Undo makes it before the removal.

- Any new model route that changes a page through the core must call
  `countEdit(.sheet(id))`, or a stale line Undo could step that edit back.
- Hand built test coordinators are not `activeEditor`; call
  `model.mountEditor(textView, from: .panel)` when a test needs the model
  to find one. `SealedRemovalTests.mount(_:_:chips:)` builds a second
  surface on the same page; `removeAndTearDown()` proves the coordinator
  deallocates.

See [[issue170-247-sealed-fragment-core]].
