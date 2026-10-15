---
name: issue241-243-sealed-name-note-core
description: Epic 252 Track B core (#241 name, #242 NAME=value, #243 note) landed 2026-10-13 under draft ADR-0043, now ADR-0043 (proposed) and the sealed objects core interface; where the seams are, what the shell tickets still owe, and the traps in the tests
metadata:
  type: project
---

Built on feature/editing-seals 2026-10-13, companion-core 0.28.0 and
companion-ffi 0.36.0, recorded in draft ADR-0043 (withdrawn 2026-10-14).
Its decision is ADR-0043 (proposed); the routes, refusal codes and
bytes at rest are docs/development/sealed-objects-core-interface.md.

- Name and note live on `SealedChip` (`name`, `note: Option<Note>`,
  `crates/core/src/note.rs`). The rule is `judge_name` in sheet.rs;
  `companion_chip_set_name` refuses by it and the handle free
  `companion_chip_name_refusal` answers 0 takes, 1 too long, 2 charset.
  Swift: `setChipName(_:chip:)`, `CompanionClient.chipNameRefusal(_:)`.
- `companion_chip_copy_name_value` composes in
  `SheetStore::copy_out_name_value` and writes through
  `Companion::write_decrypted`, the same steps as copy out.
- The note's nine routes are keyed by CHIP id and mirror the file
  routes (ink.rs holds the shared chipless batch and step rules). Chip
  ids and page ids are separate counters that overlap numerically, so a
  page id handed to a note route edits chip N's note: the shell must
  route by target (page, file, note), as PageModel already does for
  files with `isFileID`.
- Persistence: trailing chip record fields, name flag then note flag;
  the note persists as text, so its undo is empty after a relaunch.

**Why:** the shell tickets build on these and nothing in PageModel
calls them yet.

**How to apply:** #245 and #246 must call `markDirty` after
`setChipName` and after every note edit (PageModel owns dirtiness, the
core has none), and #245 should reuse `holdNotice` for the refusal
line, judging each keystroke with `chipNameRefusal`. Test traps: a new
trailing chip field breaks `a_trailing_field_on_a_chip_record_is_skipped_not_refused`
unless its tail is prefixed with one 0 per known field; a capacity test
must use a value under 32 bytes with an 11 byte name or a doubling
buffer lands exact; `ChipInfo.hasNote` is a required JSON key, so a
fixture must carry `has_note`. Swift's `copyNameValue` test writes the
real pasteboard and clears it at once. Related:
[[adr0042-open-questions]], [[epic252-track-a]].
