---
documentation_status: needs-review
---

# ADR-0043: A sealed object's name and note are fields of its chip, outside the page's document and the ledger

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0042](0042-a-sealed-name-is-a-shell-identifier.md), which fixes the name's charset, and [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md), whose open file is already a second document with its own undo.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 name and note
amendment gives a sealed object a typed name and a note, "both
page-owned ink stored with the object core-side and carried in the
sealed fragment's envelope as two optional text fields, never in the
ledger and never payload". It does not say where in the core the two
live, what keeps or drops them, or how the note's ink and undo are kept
apart from the page's.

Constraints:

- `SealedChip` (`crates/core/src/sheet.rs`) is the one record a chip has,
  and a chip is already what a page keeps, moves, clones and drops. Its
  record at rest is length framed, and a reader takes a record's unread
  tail as fields it does not know, not damage (`Reader::framed` in
  `crates/core/src/persist.rs`).
- A page's body is a Loro document. Ink written there is the page's:
  find, copy, the page's undo and sync reach it.
- The ledger records events with no content field
  ([ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)).
- An open file is already a second editable document with its own undo,
  reached by its own routes (ADR-0028).
- Draft [Law 0004](../law/0004-secret-plaintext-never-reallocates.md)
  asks every buffer of page content to be allocated at its final size.

The build on `feature/editing-seals` follows this proposal (issues #241
to #243, #246 and #247). Acceptance is the maintainer's.

## Decision

A sealed object's name and note are fields of its chip, not ink in the
page's document, not on the tab and not in the ledger.

1. **On the chip.** A chip holds an optional name and an optional note.
   Whatever keeps, moves or drops a chip keeps, moves or drops both. A
   clone copies the name and the note's text, not the note's undo.
2. **The note is a document of its own.** It is the document type a
   page's body and an open file use, holding ink alone: an edit that
   would stand a chip in it is refused, since sealed objects do not
   nest. Its undo stack is its own, so the page's ⌘Z never reaches the
   note, nor the note's the page. It exists from its first accepted
   edit.
3. **On the page's clock.** Neither field has a timer, a rung or a
   ledger record. Both go when their chip goes: with its page's death,
   or by the chip's explicit burn. A removal detaches the chip and keeps
   both with it
   ([ADR-0046](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md)).
4. **At rest, after the payload.** Both persist as trailing fields of
   the chip's record, so a build that predates them restores the chip
   without them. The note persists as its text, not its operation log,
   and restores with an empty undo stack, as a page's undo starts empty
   after a relaunch.

The routes, the refusal codes, the chip face's fields and the bytes at
rest are in the
[sealed objects core interface](../development/sealed-objects-core-interface.md).

## Consequences

- The fragment carries a name and a note by moving or cloning the chip,
  and needs no further field on the chip record.
- A file this build writes, opened by an older build, restores without
  names and notes, and that build's next save drops them.
- A name this build's rule refuses is dropped at restore, not read as
  damage, so a name a later build accepts is lost when this build opens
  the file.
- The note's undo does not survive a relaunch, and its history stays in
  memory until its chip goes, as a page's does. Deleted note text leaves
  the file at the next save.
- The name and note are ink: dropped as a page's body is, not zeroized
  as a payload is.
- The shell routes edits by document, page, file or note, and must keep
  the three apart
  ([ADR-0044](0044-a-sealed-objects-note-is-edited-on-the-pages-own-surface.md)).
- Naming and note edits leave no ledger record, so the audit trail does
  not show them.

## Open questions

1. **Sync.** The draft this consolidates said no chip syncs, so neither
   field does. Issue #257 records the maintainer's direction of
   2026-10-14 that a batch never fails to sync because of a sealed
   object, and that its name, note and other metadata other than its
   value "can be synced. Can, not must." Whether the name and note
   travel, and on what carrier, is for the successor to
   [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md) that #257
   asks for. This proposal decides nothing about sync.
2. **Wiping.** The FFI hands the name and the note's text to Swift as
   JSON strings that neither side wipes. Issue #256 records the
   maintainer's direction of 2026-10-14 that JSON handed to Swift is
   handled under the app's security model; whether the two fields move
   to wiped buffers is open there.

## Eject triggers

- A law row or a feature needs the note's provenance, or an undo that
  survives a relaunch; the note's field would then carry its operation
  log.
- A carrier for chips between devices is built; the name and note then
  need a place on it, or a recorded reason they stay home.
- A fragment or a carrier needs a field the chip record cannot supply.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0043 (a sealed object's name and note live on its chip) points 1, 3 and 5 and point 6's compatibility consequence, written 2026-10-13 and never ratified; its sync sentence is left open above, and its routes, codes, JSON fields and framing are in the [core interface](../development/sealed-objects-core-interface.md).
