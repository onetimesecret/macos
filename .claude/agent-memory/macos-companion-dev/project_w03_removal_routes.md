---
name: w03-removal-routes
description: Phase 4 W03 (2026-10-14) put every page deletion through deleting(forward:intent:) and every object removal through the coordinator's shouldChangeTextInRanges watch; AppKit facts the design rests on (no didChange while marked, block objects own their line fragment, the kill buffer holds U+FFFC as text)
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
- AppKit's kill buffer is plain text: ⌃K over an object then ⌃Y writes
  U+FFFC back as ink, not an object. Reported, not fixed.

See [[issue170-247-sealed-fragment-core]].
