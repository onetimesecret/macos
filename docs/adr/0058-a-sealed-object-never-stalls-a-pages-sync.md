---
documentation_status: needs-review
---

# ADR-0058: A sealed object never stalls a page's sync

- **Status:** proposed
- **Date:** 2026-10-16
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md), whose relay, key model and key frame this record extends; [ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md) (accepted 2026-10-16), whose name and note travel here; [ADR-0046](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md) (accepted 2026-10-16), whose detached store a peer's record enters and leaves; [ADR-0057](0057-moved-content-lives-as-long-as-the-page-it-lands-on.md) (proposed), whose lifetime rule a moved value follows.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

A page holding a sealed object stops syncing to every peer, and nobody
is told. `SheetDocument::import_update` (`crates/core/src/document.rs`)
trials a peer's batch on a fork and refuses it whole with
`UpdateRefusal::ChipRoster` when a sentinel names an identity the page
does not own, or one twice. `DeltaEnvelope::Ops`
(`crates/sync/src/envelope.rs`) moves only the page's Loro bytes; the
chip's payload, kind, size, name and note live on `SealedChip`
(`crates/core/src/sheet.rs`), outside the document. A peer refuses the
first batch that stands an object sealed elsewhere, and every later
batch of that page fails with `MissingHistory`. Client protocol row
10.31 describes this, and two tests in `crates/core/src/store.rs` pin
it: `sync_carries_no_object_so_a_move_between_pages_stands_none_on_a_peer`
and
`sync_carries_no_object_so_a_cut_reattached_on_another_page_stands_none_on_a_peer`.
No user meets it yet, because the relay is not built.

The maintainer's direction of 2026-10-14, quoted from
[issue #257](https://github.com/onetimesecret/macos/issues/257):

> - A batch never fails to sync because of a sealed object or chip.
> - The object's name, note and other metadata, everything except its value, can be synced. Can, not must.
> - Where a technical limit or a product detail keeps that metadata from syncing, the batch still syncs.
> - The value itself does not sync.

The maintainer's answers of 2026-10-23 to the gates in the
[#257 plan](../plans/issue-257-sealed-object-sync.md) (paraphrase): kind,
size class and name travel; notes merge as a CRDT in this change; a
burn does not travel in this change.

Accepted wording this record keeps:

- ADR-0021: "The relay never receives a content key, transport key, or
  pairing secret." and "A joining device starts at the current key
  frame and receives no prior history."
- ADR-0043: "A sealed object's name and note are fields of its chip,
  not ink in the page's document, not on the tab and not in the
  ledger." Its point 4: "The note persists as its text, not its
  operation log, and restores with an empty undo stack, as a page's
  undo starts empty after a relaunch."
- ADR-0046: "A page keeps the sealed objects its body no longer shows,
  on its own clock, until the page ends or the object is burned." Its
  point 2: "Only a page's death and the explicit burn destroy payload."
- ADR-0016: "A failed restore withholds the save licence and leaves
  the prior file untouched."

ADR-0057 is proposed; its Context quotes the maintainer's answer of
2026-10-14: "Moved text inherits the lifetime of where it arrives to."

## Decision

A peer imports every valid batch, whatever objects it stands. An object
whose value is not on this device is a record with an identity, a kind
and size class when known, a name and a note, and no value. Its kind,
size class and name travel beside the page's ops; its note merges as a
Loro text of its own; its value never travels.

1. **Admission.** A batch or key frame that stands an identity the page
   does not own creates a record with no value for it before the page
   settles. Malformed bytes and missing history stay refusals. The
   record is the page's own for every roster purpose: it detaches,
   reattaches and ends with its page as ADR-0046 says.
2. **One standing per identity.** When a merge, or a local undo or
   redo, leaves an identity standing twice in one body, the page keeps
   the first standing in body order and takes the later ones out,
   outside the undo stack. Every device removes the same element, so the deletes
   converge. A local fragment or restore that names an identity twice
   stays refused.
3. **The value follows its sentinel.** When a record with the value
   detaches from one page, or its page ends, while a record with no
   value for that identity stands on another page of the same device,
   the value moves into the standing record and lives on that page's
   clock, as ADR-0057 proposes for a local move. A batch that stands an
   identity this device keeps detached on another page moves that
   record to the page it stands on. The value is never copied.
4. **The face and its routes.** A record with no value shows its kind
   and size class when known and the line `value on another device`.
   The core refuses Copy Decrypted Contents, Copy Name=Value, the
   one-time link, the decrypted drag and the chip's conceal for it, and
   refuses the whole page's conceal while one stands in the body.
   Rename, the note, a move, a cut, the cut's first paste and removal
   stay available. A paste that would clone it (a paste after a copy,
   or a later paste of a cut) places `[sealed content · unavailable]`,
   and the outcome names the cause.
5. **Metadata.** A `Metadata` envelope beside the page's `Ops`, under
   the same seal, padding and epoch, names each changed object's
   identity, kind, size class and name. The name has a version: a
   counter and the writing device's fingerprint, compared in that
   order; the greater wins, and a clear is a versioned empty name. A
   local rename takes one more than the highest counter known for that
   name. Equal versions with different names keep the local name.
   Versions persist; one written before the device had a fingerprint
   takes it when sync starts. An envelope names at most 128 objects. An
   entry applies to the object's records wherever they stand on this
   device, and one for an identity this device has no record for waits
   in a cache of at most 256 entries until its sentinel arrives. A
   device restates every entry of an enrolled page at attach and at
   each new epoch.
6. **Notes.** A note is a Loro text with a history of its own. Its ops
   travel as a `NoteOps` envelope beside the page's `Ops`, exported,
   acknowledged, rewound and withdrawn by the rules the page's ops
   follow, and a peer imports them with the page's refusals plus one:
   a note never stands a chip, and a note with text refuses ops that
   build on none of its history. A note's history is shared once any
   of it has left this device or come from another. A shared note
   persists its operation log beside its text, and keeps it through a
   page's compaction, since a copy of it elsewhere may still meet it;
   a note no other device has seen persists and compacts as its text
   alone. Each restores with an empty undo stack. A ceremony rebuilds
   each standing record's note under a fresh peer id, and the key
   frame includes each rebuild beside the page's. When a value moves
   into a standing record, the two notes merge if their histories
   share a peer, and otherwise the standing note stays. Note ops apply
   to the object's records wherever they stand on this device, and
   those for an identity this device has no record for wait, as
   metadata entries do, in a cache of at most 256 batches and 256 KiB.
7. **The ops never wait.** A `Metadata` or `NoteOps` envelope that
   fails to encode, is refused or is skipped leaves the page's ops
   applied, and its loss is made good by the next change or restate.
8. **Burns stay on the device.** A burn deletes the sentinel, and that
   delete syncs, so a peer's record detaches and ends with its page. A
   device whose ledger records an identity's end, its burn or the end
   of the page its value stood on, takes out a standing of that
   identity it has no value for, outside the undo stack, when a batch
   or key frame stands it and when the burn is recorded, since no
   device can hold that value again.
9. **At rest.** A new content snapshot version writes each record's
   availability as a tag ahead of any payload bytes, the name's version
   and the note's operation log. This build reads the previous version.
   An earlier build refuses the new one, and by ADR-0016 the file is
   left untouched.
10. **A seal in place sheds its ink.** A seal that replaces ink on the
    page compacts a solo page at once and owes an enrolled page its
    ceremony, so the ink's insert leaves the page's history at the next
    rebuild on each member. Until that ceremony commits, an enrolled
    page's peers can receive the ink as page history, as they receive
    any text typed there.

Never on the wire, except as point 10 says of ink a seal replaces: the
value, the excerpt made from it, the exact character and line counts,
the conceal receipt and the note's undo stack.

## Consequences

- A page holding sealed objects syncs and converges on every device;
  sealing on an enrolled page, a move onto one and a cut's paste onto
  one no longer end its sync.
- A second device sees an object's kind, size class, name and note,
  and can rename it, annotate it, move it and remove it. It cannot
  copy, drag, link, conceal or burn the value.
- The relay learns nothing new: both envelopes ride inside the seal
  and padding. Their bytes raise the padded size of a batch, which is
  the relay admission's existing delta size item.
- The name and the note's text leave the device over sync, sealed. A
  person who writes a secret into a note syncs it to every enrolled
  device.
- A shared note's deleted text now persists at rest until a ceremony
  rebuilds it or its page ends. A note no other device has seen keeps
  no history at rest, as before this record.
- A seal in place compacts its page outside the rung schedule: a solo
  page loses its edit history at that seal, and an enrolled page's
  ceremony rotates the channel's key.
- Two devices that each write an object's first note while apart, and
  two members that both commit one ceremony (client protocol §7.8, as
  for the page's body), refuse each other's later note ops, so their
  notes for that object stay apart.
- A peer can show `value on another device` for an object its sealer
  burned, until the page ends or the sealer's device sees that
  identity stand again.
- An enrolled peer's move can lengthen a value's life on the device
  that has it, as a local move can under ADR-0057: the move is the
  person's instruction, as the hold is under ADR-0021. ADR-0021's
  earliest expiry rule governs a page's deadline, not where a value
  stands.
- A value that moves to another page (point 3) clears the undo stack of
  the page it leaves, since a step there could stand its sentinel a
  second time. A peer's batch can clear the undo of a page the person
  is not editing.
- Two concurrent moves of one object to different pages leave it
  standing on both. The device with the value moves it to the first of
  them in its page order; the other shows `value on another device`
  until its page ends.
- A build released before this change still refuses these batches on
  `ChipRoster` and skips the two new envelopes; no capability
  negotiation exists. No
  user meets this before the relay ships.
- An earlier app build cannot open content this build writes.
- On acceptance: ADR-0043 point 4 is superseded in part (a shared note
  persists its operation log, and the record is no longer readable by
  a build that predates it), and ADR-0043's and ADR-0046's first open
  questions are answered here; each gains a reciprocal line. Client
  protocol row 10.31 is replaced, and Law 0001's lifecycle table gains
  the record with no value, both for ratification.

## Alternatives

- **Metadata in the page's Loro document:** rejected; ADR-0043 puts the
  name and note "not ink in the page's document".
- **A full table of every object on each change:** rejected; its size
  grows with the roster and it can crowd the transport bounds.
- **Whole note text, last writer wins:** rejected; two offline edits
  keep one side's text and lose the other's outside undo.
- **Notes stay on each device:** rejected by the maintainer on
  2026-10-23.
- **Signed burn evidence:** deferred. It needs a signed origin at seal
  time, durable tombstones and a migration for objects sealed before.
- **Import the batch without the sentinel:** rejected; a Loro update is
  one dependency graph, and dropping an insertion breaks the ops after
  it.

## Eject triggers

- A measured padded batch or key frame, with metadata and note ops,
  exceeds the protocol specification's batching and padding bounds.
- Two devices current with the relay show different names or notes for
  one object after edits on each.
- A note's text appears twice after a merge: two histories with no
  shared base met.
- A record decides payload transfer between devices.
- A burned object's value is readable on any device.

## Decision history

- 2026-10-16: Proposed.
- 2026-10-16: Design review at `bc1bc4e4`; the review and its gates are
  in the [#257 plan](../plans/issue-257-sealed-object-sync.md).
- 2026-10-23: Rewritten to the maintainer's gate answers after #256's
  buffers merged: kind, size class and name travel, notes merge as a
  CRDT, burns stay on the device. Still proposed.
- 2026-10-23: Two adversarial reviews of the built branch. Point 10
  added (a seal in place sheds its ink); points 2, 5 and 6 sharpened
  (an undo keeps one standing, entries and note ops follow the object
  across pages, a note's history persists and survives compaction once
  shared, an unrelated note history is refused); two consequences name
  the cases where notes stay apart. Still proposed.
