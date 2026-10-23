---
name: issue244-246-sealed-shell
description: Epic 252 Track B shell (#244 zones, #245 name field, #246 note popover) built 2026-10-13 on feature/editing-seals; the note runs the page's InkTextView routed by InkDocument (ADR-0044), one answersChords predicate gives chords and Edit menu to the key holder (Law 0007's keys row), and the test traps
metadata:
  type: project
---

Built 2026-10-13, app 0.29.0 to 0.31.1, shell only (no FFI change);
phase 3 leftovers 0.31.5 to 0.32.3 (held refusal, note surface, key
holder, pad list height).

- Zones: `SealedBlockLayout.NamedRow` and `rowAllotment` are pure; the
  cell's `namedRow(in:editingWidth:)` measures. A click acts on a zone
  only via `InkTextView.actingZone`, i.e. after the hover named it
  (Law 0001's zone gate row), because a non key window shows no hover.
- Name field: `ChipRename` (state, like `PadRename`) and
  `SealedNameEditor` (AppKit) in SealedNameField.swift; faces change in
  place through `PageModel.restateChipFace`, never a page restate.
- Note: SealedNotePopover.swift. It is an overlay view inside the
  page's enclosing NSScrollView, not an NSPopover: a second window would
  churn the card's key status, skip its capture exclusion and could not
  take the sealed row spec's 10 point radius or expand to the card.
  Minimum width 320 (`NotePopoverLayout.minimumWidth`, in the sealed row
  spec's Placement). Since phase 3 (ADR-0044) the note's surface IS an `InkTextView`, built
  by `InkEditorView.makeSurface` with its own `Coordinator`; the
  coordinator edits `InkDocument` (`.sheet` or `.note(chip:)`) and
  `PageModel.applyOps(to:)`/`stepEdit`/`canStepEdit`/`editStepName`/
  `finishEditingGroup(_:)` route it. A note's coordinator never holds a
  `currentSheet`, so page only paths (seals, chips, block stamps, view
  state) stand aside by their existing guards; `writesNote` gates the
  rest (Esc, ⇧Esc, ⌥Z, inset). `NoteTextView` is gone.
- `InkTextView.performKeyEquivalent` runs for every view in the window,
  first responder or not. Since draft ADR-0046, now Law 0007's keys
  row, one predicate decides:
  `answersChords` (page: no other `NSTextView` first responder here or in
  another key window; note: it is first responder). The page's Edit menu
  actions and `refreshLanguageActionAvailability` consult it too, and
  Choose Language goes down the chain with a `CodeLanguageChoice`.
- Review fixes (same day, app 0.31.2 to 0.31.4, ffi 0.37.0): the name
  field is a subview of the page, so `begin` sets its `nextResponder` to
  the page's own; otherwise the Edit menu's nil-targeted undo:, seal and
  language actions reach the page under a draft. Test such routing by
  walking `nextResponder` from `window.firstResponder` (NSApp is nil
  under xctest). The note and the name field edit through
  `OwnDragsOnlyTextView` (the field via `SealedNameFieldCell`'s own field
  editor) and refuse external drops; both empty their text on close;
  `SealedBlockLayout.copiesNameValue(kind:)` (text only) gates the `=`
  zone and the menu item. Law 0001's note row now owes the page's own
  surface (markdown face, lists, links, fences) to #246.
- Clipboard in tests: call `client.useMemoryPasteboardForTests()`
  (`companion_test_memory_pasteboard`) before any copy out or name=value
  through an ephemeral client, or the suite clears the person's real
  clipboard. `DraggingInfoStub` stands in for a drag (needs `@MainActor`
  and `@preconcurrency NSDraggingInfo`).

**Why:** these choices are not visible from the tickets, and the
hardware checks (docs/qa/verification-procedures/sealed-zones-and-note.md,
rename-in-place.md) have not been run.

Phase 3 traps (2026-10-13): never call `Coordinator.textView(_:clickedOnLink:at:)`
in a test, since in a full run `NSApp.currentEvent` can be a stale event
and a ⌘ in its flags would open a real URL; an `NSWindow` made in a test
needs `isReleasedWhenClosed = false` before `close()`, or the run hangs
on the over release; a shift extension over a block also takes the
space after it (same place on screen), so assert the object whole, not
a range; `answerer(of:in:)` and `pageMenuActions` are shared in
`ResponderChain.swift`; any test that sends ⇧⌘V or a seal must give its
client `useMemoryPasteboardForTests()` first, in case the page answers.

Left open after phase 3: the summon offer's button still seals into the
page while a note is open (Law 0001's object in a note row keeps the
offer the page's); the
key window case (`keysHeldInAnotherWindow`, the pad popover) and every
new procedure check were reasoned, not run; edits to this directory were
committed within a minute as bodiless `docs(memory)` commits by
something other than the session, so check `git log` before committing
memory.

**How to apply:** test traps: a zone press test must hover first
(`hoverRefreshInput` then `refreshHover`); never synthesize a press that
takes the `.select` path, since `super.mouseDown` waits for a mouse up
forever; wait for the note's focus-loss close with `drainMainQueue`, not
`RunLoop.run`; ambient copies go to `Seams.ambientPasteboard`
(`NSPasteboard.withUniqueName`). The user may run install.sh from this
worktree mid-session, which leaves `bindings` release-shaped; rebuild
with `--test-util` when the link fails. Related:
[[issue241-243-sealed-name-note-core]], [[epic252-track-a]].
