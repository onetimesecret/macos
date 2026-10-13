---
documentation_status: needs-review
---

# ADR-0043: A sealed object's name and note live on its chip

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0042](0042-sealed-names-copy-zones-and-rename-seats.md), which fixes the name's charset, and [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md), whose file routes the note's routes follow.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 amendment gives a
sealed object a typed name and a note, "both page-owned ink stored with
the object core-side and carried in the sealed fragment's envelope as two
optional text fields, never in the ledger and never payload". Its rows add
a copy of `NAME=<plaintext>` "by the same route" as copy decrypted, and a
note "on the page's clock". Issues #241, #242 and #243 build the core side.
They leave open where the two live, how they persist, what crosses the
FFI, how a refused name says why, and how the note's ink and undo are
addressed while the shell mounts one editor per model.

Constraints:

- `SealedChip` (`crates/core/src/sheet.rs`) is the one record a chip has.
  `emit_chip` and `read_page` (`crates/core/src/persist.rs`) write and read
  it, and `Reader::framed` reads a record's unread tail as "fields this
  build does not know, not damage".
- `apply_remote_update` (`crates/core/src/store.rs`) admits only chips the
  page already owns, so no chip arrives by sync.
- Issue #170 will detach, reattach and clone chips, and issue #247 will
  carry the two fields in the fragment. Neither should need another format
  change.
- [Law 0004](../law/0004-secret-plaintext-never-reallocates.md) (draft)
  asks every buffer of page content to be allocated at its final size.
- An open file is already a second editable document with its own undo,
  reached by its own routes (`crates/ffi/src/files.rs`).

## Decision

The name and the note are fields of `SealedChip`, persisted as trailing
fields of its chip record and reached over the FFI by chip id.

1. **On the chip.** `name: Option<String>` and `note: Option<Note>`.
   Neither is in the page's document, on the tab or in the ledger.
   Whatever keeps, moves or drops a chip keeps, moves or drops both; a
   clone (#170) copies the name and the note's text, not its undo. No
   chip syncs, so neither field does.
2. **The name's rule, once.** The core trims a draft. An empty draft
   clears the name; any other must pass ADR-0042 point 1, or it is refused
   whole and the name stands. `companion_chip_name_refusal(draft)` judges
   a draft without a handle: 0 takes it, 1 is longer than 64 characters,
   2 is outside the charset, which is checked first; null and non-UTF-8
   answer 2. `companion_chip_set_name(handle, chip, name) -> bool` refuses
   by the same judgement and refuses an unknown chip. The shell owns the
   words for each code (#245) and can judge a draft as it is typed.
3. **The note is a document of its own.** It is the document type a
   page's body and an open file use, holding ink only: an op that would
   stand a chip in it is refused, since sealed objects do not nest. Its
   undo stack is its own, so the page's ⌘Z never reaches the note, nor
   the note's the page. It exists from its first accepted edit, and
   `has_note` is true while it holds a character that is not whitespace.
4. **The note's routes are keyed by chip**, as a file has its own:
   `companion_chip_note_runs_json`, `_apply_ops_with_intent`,
   `_finish_editing_group`, `_can_undo`, `_can_redo`,
   `_undo_action_name`, `_redo_action_name`, and `_undo` and `_redo`,
   which answer the file routes' `StepOutcome`. Page routes take no chip
   id and note routes no page id, so whichever editor the shell mounts for
   the note (#246), its edits and steps cannot reach the page's stack.
5. **On the page's clock.** Neither field has a timer, a rung or a ledger
   record. Both go with their chip, by expiry, discard, close or removal
   (D-33). The shell marks the page dirty after a name is set or a note
   edited, as after any mutation (#245, #246).
6. **Persisted after the payload.** The chip record gains a name flag (0,
   or 1 and the name) and then a note flag (0, or 1 and the note's text).
   `OTSSNAP4` stays. A record that ends before either flag restores
   without it; an older build skips both and drops them at its next save.
   A restored name the rule refuses is dropped, not read as damage; a
   flag other than 0 or 1 is damage, as the page floor's is. The note
   persists as text, not as its operation log: no law row asks for its
   provenance, deleted note text leaves the file at the next save, and
   #247's fragment carries the same text. Restore rebuilds it with an
   empty undo stack, as a page's starts after a relaunch. Each note's
   text is taken once, at its exact size, before the snapshot's two
   passes (Law 0004).
7. **`NAME=value` is composed in the store.**
   `companion_chip_copy_name_value(handle, chip) -> bool` takes the name,
   `=` and the payload in one zeroizing buffer allocated at its final
   size, and refuses an unnamed or image chip. It shares copy decrypted's
   steps with `companion_chip_copy_out`: retire the last receipt, write
   transient and concealed, keep the receipt for the guarded clear, and
   record one `sent` to the clipboard at the payload's size class. The
   composed bytes never cross the FFI.
8. **What the shell receives.** The chip face (`chip_json` and
   `companion_sheet_document_json`) gains `name`, a string or null, and
   `has_note`. The note's text crosses only through
   `companion_chip_note_runs_json`. No summary, meta, blocks or ledger
   output carries either, and neither conceal payload, one chip's or the
   whole page's, includes them.

## Consequences

- #170 and #247 carry the name and note by moving or cloning the chip.
  The fragment's two fields read `name` and the note's text, and a paste
  builds them through the same rule and note constructor. The chip record
  needs no further field for either.
- A file this build writes, opened by an older build, restores without
  names and notes, and that build's next save drops them.
- A name a later build accepts and this rule refuses (ADR-0042's eject
  trigger) is dropped when this build opens the file.
- The note's undo does not survive a relaunch, and its history stays in
  memory until its chip goes, as a page's does. The name and note are
  ink: dropped as a page's body is, not zeroized as a payload is.
- Nine note routes mirror the file routes. The shell routes edits by
  target, page, file or note, and must keep the three apart.
- Naming and note edits leave no ledger record, so the audit trail does
  not show them.

## Eject triggers

- A law row or #246 needs the note's provenance, or an undo that survives
  a relaunch; the note's field would then carry its operation log.
- Chips gain a sync carrier; the name and note then need one too.
- #247 finds a fragment field the chip record cannot supply.

## Decision history

- 2026-10-13: Accepted for issues #241, #242 and #243, before their code.
