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
