---
name: issue244-246-sealed-shell
description: Epic 252 Track B shell (#244 zones, #245 name field, #246 note popover) built 2026-10-13 on feature/editing-seals; where the seams are, why the note is not an NSPopover, and the test traps
metadata:
  type: project
---

Built 2026-10-13, app 0.29.0 to 0.31.1, shell only (no FFI change).

- Zones: `SealedBlockLayout.NamedRow` and `rowAllotment` are pure; the
  cell's `namedRow(in:editingWidth:)` measures. A click acts on a zone
  only via `InkTextView.actingZone`, i.e. after the hover named it
  (ADR-0042 history), because a non key window shows no hover.
- Name field: `ChipRename` (state, like `PadRename`) and
  `SealedNameEditor` (AppKit) in SealedNameField.swift; faces change in
  place through `PageModel.restateChipFace`, never a page restate.
- Note: SealedNotePopover.swift. It is an overlay view inside the
  page's enclosing NSScrollView, not an NSPopover: a second window would
  churn the card's key status, skip its capture exclusion and could not
  take ADR-0042's 10 point radius or expand to the card. Minimum width
  320 (`NotePopoverLayout.minimumWidth`, in ADR-0042's history).
  `NoteTextView` is a plain NSTextView with the page's face and the
  note's own undo; it has no markdown restyle or list automation.
- `InkTextView.performKeyEquivalent` runs for every view in the window,
  first responder or not, so `yieldsKeys` must decline while the name
  field's editor or a `NoteTextView` holds the keys.
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

**How to apply:** test traps: a zone press test must hover first
(`hoverRefreshInput` then `refreshHover`); never synthesize a press that
takes the `.select` path, since `super.mouseDown` waits for a mouse up
forever; wait for the note's focus-loss close with `drainMainQueue`, not
`RunLoop.run`; ambient copies go to `Seams.ambientPasteboard`
(`NSPasteboard.withUniqueName`). The user may run install.sh from this
worktree mid-session, which leaves `bindings` release-shaped; rebuild
with `--test-util` when the link fails. Related:
[[issue241-243-sealed-name-note-core]], [[epic252-track-a]].
