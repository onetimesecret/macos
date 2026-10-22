---
name: issue310-deadline-writes
description: Issue #310 (PR 313, core 0.34.3, ffi 0.43.2, app 0.40.9, 2026-10-21); chip_mut reads through readable_sheets_mut, so note batches, steps, run end and renames refuse a due page; the note chord skips menu validation; the C header is hand kept; page ink is still ungated
metadata:
  type: project
---

PR 313 (fix/310-note-edits-past-deadline) gates `SheetStore::chip_mut` through
a new `readable_sheets_mut`, the mutable twin of `readable_sheets`, so
`apply_note_ops` (even an empty batch), `undo_note`/`redo_note`,
`finish_note_editing_group` and `set_chip_name` refuse a page past its
deadline. Law 0001's expiry row has the 2026-10-21 note and name amendment.

**Why:** since #307 a restored note rests as a wiping string until its first
accepted batch builds a Loro document, so a write on a due page would copy it
into storage that never wipes.

**How to apply:**
- `delete_chip` and `mark_chip_concealed` walk `tabs` themselves and stay
  ungated on purpose (burn destroys; a late conceal receipt is the row's case).
- Shell: `PageModel.setChipName` and `stepNote` call
  `settleRefusal(chip:otherwise: nil)` on refusal; `Coordinator.step` closes a
  note whose `noteText` is now nil through `restateNote`, as a refused batch's
  restate does. `stepNote` returns `.nothing` for both a refusal and an empty
  stack, so the coordinator re-reads rather than reading the answer.
- The note's ⌘Z/⇧⌘Z go `performKeyEquivalent` → `dispatch(.editorUndo)` →
  `Coordinator.step` with no `canStepEdit` check; only the menu item is
  validated. Two review bots assumed otherwise. Test the chord, not the model.
- `crates/ffi/include/companion_ffi.h` is hand maintained (ADR-0003); a doc
  change in `lib.rs` must be mirrored there and in `CompanionClient.swift`.
- Open: typing the page's own ink on a due page is still accepted
  (`apply_batch`, `undo`, `redo` use `sheet_mut`). The row does not name it;
  left for the maintainer, no rationale written into the law.
- Declined review points: settling on every name refusal (only due pages
  settle, `otherwise: nil` shows nothing), `countEdit` before the note batch's
  core call (pre-existing, counts edits sent).

Related: [[issue256-c31-resting-note]], [[issue170-247-sealed-fragment-core]].
