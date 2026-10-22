---
name: issue256-c31-resting-note
description: Issue #256 row C31 (PR 307, companion-core 0.34.2, 2026-10-21); Note rests as Zeroizing<String> until a batch applies; the names were already done by #291/#292; what any later Note change must keep
metadata:
  type: project
---

C31 (restore names and notes) shipped as PR 307 on fix/256-restore-owners.
The names needed no code: #291/#292 had already made chip names, tab names
and ledger titles exact `Zeroizing<String>` copies from slices of the
decrypted snapshot. The real change is in `crates/core/src/note.rs`: `Note`
has an enum body, `Resting(Zeroizing<String>, Option<TextSelection>)` or
`Document(SheetDocument)`. `Note::holding` (used by restore, paste and clone)
starts it resting. Only a batch that `ink::admits` accepts and that moves
text builds the Loro document; a batch of zero width ops answers true and
keeps its after selection (only if before and after are in bounds), as
the document would.

**Why:** Loro's arena never wipes (C01), so a restored note nobody edits
should never enter it.

**How to apply:**
- A run end on a resting note keeps its selection rather than building the
  document, and the document replays that selection when it is built. Loro's
  `snapshot_selection` accepts any position up to the UTF-16 length, a
  position inside a surrogate pair included, so the keep filter is a bounds
  check (`within`) and nothing more. A filter for char boundaries broke parity;
  `a_resting_note_keeps_the_selections_its_document_would` pins the
  bounds check.
- `finish_editing_group` takes `&mut self`, so the store looks the chip up
  with `chip_home` (the deadline gate) and then `chip_mut`.
- ADR-0043 point 2 (accepted) says the note "is the document type a page's
  body and an open file use". PR 307 does not amend it, and points this out.
- Register B1 still lists C09 and C10, although both rows have read
  implemented since #292. PR 307 left that alone.

Related: [[issue241-243-sealed-name-note-core]].
