---
documentation_status: needs-review
---

# ADR-0058: A sealed object never stalls a page's sync

- **Status:** proposed
- **Date:** 2026-10-16
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md), whose relay, key model and key frame carry everything decided here; [ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md) (accepted 2026-10-16), whose chip holds the name and note this record carries; [ADR-0046](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md) (accepted 2026-10-16), whose detached store a peer's record enters and leaves.

Read [ADR conventions](README.md) before filing or changing an ADR.

This record succeeds ADR-0021 on one point only: what a batch may stand
and what a peer does with an object it does not hold. ADR-0021's relay,
key model, pairing, key frame join, expiry and hold decisions stand.
On acceptance, ADR-0021 gains a `Superseded in part by` line naming this
record; a proposed record cannot claim that link yet, so this one is
written as depending on it.

## Context

A page holding a sealed object stops syncing to every peer, and nobody
is told. [Issue #257](https://github.com/onetimesecret/macos/issues/257)
records the defect and the maintainer's direction; the code and
documents below are what this record reads.

What the build does:

- Sync moves each enrolled page's Loro document and nothing else. The
  one content envelope is `DeltaEnvelope::Ops` in
  `crates/sync/src/envelope.rs`, whose `ops` field is "The exported
  update bytes."; the enum's other shapes (`Expiry`, `Hold`, `Terminal`,
  `Control`) are policy and control, not content. The chip table is
  outside the document: the document
  carries a U+FFFC sentinel per chip, with the chip's identity as a mark
  on it (`CHIP_MARK` in `crates/core/src/document.rs`), and the chip's
  payload, kind, size, name and note live on `SealedChip` in
  `crates/core/src/sheet.rs`.
- `SheetDocument::import_update` (`crates/core/src/document.rs`) trials
  a batch on a fork and refuses it whole. Its `UpdateRefusal::ChipRoster`
  arm is documented as "A chip sentinel names an identity not in the
  roster, or one twice; roster and marks stay one-to-one, as on
  restore." `SheetStore::apply_remote_update` (`crates/core/src/store.rs`)
  passes the page's attached and detached chips as the roster, so a
  sentinel for a chip the page does not hold refuses the batch.
- `UpdateRefusal::MissingHistory` is documented as "The update depends on
  operations this document lacks. Refused, never queued: recovery is
  rejoining at the key frame (ADR-0021)." Client protocol §8 says "No
  rejoin exists (§4.6)".

Client protocol row 10.31 puts the three together: "no envelope carries
a sealed object, and a batch that stands a sentinel the peer's page does
not own is refused whole (`ChipRoster`) and dropped; every later batch of
that page builds on it (`MissingHistory`) and no rejoin exists (§8), so a
page holding an object, sealed there or carried onto it by a move or a
cut's reattach, stops reaching every peer". Two tests in
`crates/core/src/store.rs` pin that outcome:
`sync_carries_no_object_so_a_move_between_pages_stands_none_on_a_peer`
and
`sync_carries_no_object_so_a_cut_reattached_on_another_page_stands_none_on_a_peer`.
[Law 0001](../law/0001-sealed-object.md)'s 2026-10-14 sync move
amendment records the same and says "Whether objects travel between
devices is a decision this law does not make".

No user meets this yet, because the relay is not built. It predates
`feature/editing-seals`; that branch added the move between pages and
the cut's reattach as further routes into it.

What the records say about sync and chips:

- ADR-0021's Context opens "Sync must move a Page between a user's
  enrolled devices without allowing the relay to read it". Its
  Consequences say a compromised relay "cannot read Page or chip content,
  titles, block structure, or keys." Its Decision says "The relay never
  receives a content key, transport key, or pairing secret." Nothing in
  ADR-0021 says a chip stays on one device; the stall is the build's,
  not the ADR's.
- The relay protocol says "every stored byte is ciphertext sealed under
  the channel's current GOP key" and that at a ceremony every device
  seals "one composite key frame", which it describes as every enrolled
  page's snapshot after compaction, in one blob (paraphrase). In the
  build, the frame is the page's rebuild
  (`SheetStore::perform_ceremony`, sealed by `seal_owed_frame` and
  `commit_advance` in `crates/ffi/src/sync_session.rs`).
- ADR-0043 (accepted 2026-10-16) decides "A sealed object's name and note are
  fields of its chip, not ink in the page's document, not on the tab
  and not in the ledger." Its point 1 says "A clone copies the name and
  the note's text, not the note's undo." Its first open question says
  "This proposal decides nothing about sync."
- ADR-0046 (accepted 2026-10-16) decides that "A page keeps the sealed objects its
  body no longer shows, on its own clock, until the page ends or the
  object is burned." Its point 1 names "a peer's update" among the edits
  that detach a chip and its first open question leaves to this record
  "Whether such an object detaches and reattaches on that peer as it
  does here, and what a cut made there can carry".
- Epic [#252](https://github.com/onetimesecret/macos/issues/252)'s
  "Explicitly unchanged" list holds "Chips do not sync, so their names
  and notes do not either." Law 0001's 2026-10-14 consolidation records
  that the draft ADR-0043 sentence "No chip syncs, so neither field
  does." is "not carried" (two quotations from that entry). This record
  changes the epic's line, and says so in Consequences.
- [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)
  Amendment 1 counts the payload's egresses: "The inventory is therefore
  one ingress and three complete-payload egresses, each crossing the FFI
  at a documented point." Sync is not one of them, and this record adds
  none. Law 0001's name and note amendment, as ADR-0043 quotes it, calls
  the two fields "both page-owned ink stored with the object core-side".

The maintainer's direction of 2026-10-14, quoted from issue #257:

> - A batch never fails to sync because of a sealed object or chip.
> - The object's name, note and other metadata, everything except its value, can be synced. Can, not must.
> - Where a technical limit or a product detail keeps that metadata from syncing, the batch still syncs.
> - The value itself does not sync.

The issue says this direction "supersedes any earlier ADR text it
conflicts with, ADR-0021's scope included".

Constraints this record keeps:

- The relay admission in the
  [relay decision background](../spec/feature/sync/relay-decision-background.md):
  "What the relay structurally cannot learn: page content, chip content,
  titles, page count, block structure, and every key."
- A chip's excerpt is made from its value (`text_face` in
  `crates/core/src/sheet.rs` takes the head of the text), and
  `ChipMeta::Text` counts exact characters and lines. The ledger buckets
  sizes into a size class for the reason the relay decision background
  gives for delta sizes: "a weak fingerprint of edit activity".
- Client protocol §6: "unknown shapes are skipped".

## Decision

A sealed object never stalls a page's sync. A peer imports a batch that
stands a sentinel for an object it does not hold and keeps a record for
that object with no value; the object's kind, size class, name and note
travel beside the page's ops, inside the same seal; the value never
travels.

1. **The import.** `import_update` keeps refusing a batch that stands
   one identity twice and stops refusing a batch that stands an identity
   the page does not hold. For each such identity the store creates a
   chip record in a new lifecycle state, **held on another device**: no
   payload, no excerpt, no conceal receipt; its kind, size class, name
   and note as the metadata table supplies them, unknown until it does.
   Such a record is the page's own for every roster purpose: its
   sentinel's leaving the body detaches it into the detached store, undo
   or a peer's update standing the sentinel again reattaches it, and it
   dies with its page (ADR-0046 point 1 and Law 0001's expiry row apply
   unchanged). It never enters the active cut as a payload holder; a
   cut on the peer carries its reference, nothing more. A batch from an
   enrolled peer may create any number of such records; each dies with
   its page, and this record accepts that within ADR-0021's trust model
   (enrolled devices, a sealed channel) rather than capping it.
2. **The face.** On a device that holds the value, nothing changes. On a
   device where the object is held on another device, the face shows the
   kind and size class when known and the line `held on another
   device`, in the place the excerpt takes on the holding device. The
   menu offers *Copy Name*, *Name* or *Rename*, *Note…* or *Edit Note…*
   and *Remove Sealed Content*. It does not offer *Copy Decrypted
   Contents*, *Copy Name=Value, Decrypted* or *Create One-Time Link…*,
   and the row shows no decrypted drag handle: each of those needs the
   value. Removal on that device is structural, as everywhere: the
   sentinel leaves the body and the record detaches; the explicit burn
   is the holding device's act alone. The whole page's conceal from a
   device whose body stands an object held on another device is refused
   and says why, since the link would lack that object's value; an
   object only in the detached store does not refuse it, since the link
   does not need that object's value.
3. **Structural edits keep the identity.** On a peer, a cut, a paste of
   that cut, a move between pages and a drag inside the page carry the
   object's identity unchanged, so a later batch from the holding device
   still matches. A paste that would clone an object held on another
   device (a paste after copy, or a later paste of a cut) has no value
   to clone and places `[sealed content · unavailable]` with the cause
   `held on another device`, as Law 0001's lifecycle states place an
   unknown reference; the outcome names it. A paste that would stand an
   identity twice in one body is refused, as point 1 keeps.
4. **The metadata channel.** A page's chip metadata travels as a table
   beside its ops. The table is a snapshot, never a delta: one entry for
   every chip in the page's roster, attached or detached, with the
   identity, the kind (`text` or `image`), the size class, the name, the
   note's text and, when the object has been burned, that terminal
   state. A device sends the whole table whenever any of that page's
   metadata moves, so a receiver fills an identity it did not know from
   the first table that names it, and a table that was skipped or
   refused is made good by the next one. The table is its own envelope
   shape in the same sealed batch as the page's `Ops`, encoded in
   `crates/sync/src/envelope.rs`, sealed under the channel's GOP key as
   the ops are, and padded with them. The key frame includes the table
   beside the page's rebuild, so a joining device learns the metadata
   with the document. The ops never wait on the table: a batch whose
   table is absent, refused or skipped applies its ops, and the objects
   it stands show as held on another device with what is known until a
   table arrives. What does not travel: the value, the excerpt (made
   from the value), the
   exact character and line counts (finer than the size class the
   ledger admits), the conceal receipt, and the note's undo stack
   (ADR-0043 point 1).
5. **Convergence.** Every field in a table entry has a revision, a
   Lamport clock per field. A field with no local value has revision 0.
   On a local accepted edit the field's revision becomes one more than
   the greater of the local revision and the highest revision received
   for that field. A received entry with a higher revision replaces the
   local field and raises the local revision to it; a lower one is
   ignored; equal revisions break on the editing device's identity
   fingerprint, the same way on every device. The last writer wins, not
   the most frequent editor, so two devices that edited offline converge
   on the same name and note whichever batch each receives first. Wall
   clocks take no part; ADR-0021 already accepts skewed clocks only
   where they can shorten, never decide. A note's text that arrives
   replaces the local note's text as one restate outside the note's
   undo stack, as a peer's edit reaches the page's body outside the
   page's.
6. **Terminal states travel; the hold and the expiry stay the page's.**
   A burn on the holding device travels in the table as that object's
   terminal state. The terminal state is absorbing: it wins every
   revision comparison for that identity; a device that receives it
   drops its record for the object and shows `[sealed content · burned]`
   for any later reference, as a paste of a burned reference does; and
   a later table entry naming that identity is ignored. The device that
   burned the object keeps the terminal state in every table it resends,
   so a device that missed the burn learns it from the next table and
   never rebuilds the object from a stale entry. A received burn acts
   only on a record with no value; the device with the value ignores a
   burn it did not make, since the burn is its act alone (point 2). A
   burn in the table needs no signature where the page's `Terminal`
   envelope has one. That marker destroys the page's key on every
   device and the hold rule gates who may publish it, so it must name
   its sender. A table entry travels inside the same seal as the
   unsigned `Ops` and `Expiry` beside it, from an enrolled device, and
   reaches only a metadata record whose life is already bounded by the
   page's; whoever could forge it could already forge the ops that
   remove every sentinel, and client protocol §7.9 reads a past deadline
   `Expiry` as expiring the page on peers without a live hold. Expiry
   and the hold remain page facts under
   ADR-0021 and Law 0001: the record of an object held on another device
   dies with its page on every device and is recorded in that device's ledger with its
   page's end, as ADR-0046 records every object's end.

What this record does not decide:

- **Payload transfer between devices.** A value reaches a second device
  by no route this record opens. A later record may decide one; until
  then an object is held where it was sealed.
- **Re-sealing on a peer.** A peer cannot seal, re-seal or take over an
  object it holds only as metadata.
- **Pairing and the key model.** Both stand as ADR-0021 decided them.

## Consequences

- A page holding a sealed object syncs. Sealing on an enrolled page,
  moving an object onto one or pasting a cut onto one no longer ends the
  page's sync, and the page converges on every device.
- A second device sees that an object exists, what kind it is, how large
  it is, what it is named and what its note says, and that its value is
  elsewhere. It can rename it, annotate it, move it and remove it. It
  cannot copy, drag, link or burn the value.
- The relay admission does not widen: the table rides inside the same
  seal and padding as the ops. Its bytes do add to each padded delta, so
  a long note raises the bucket a batch lands in; that is the admission's
  existing "Delta sizes" item, not a new one.
- Metadata leaves the device over sync. The name and note are page-owned
  ink, and ADR-0012's egress inventory counts payload egresses, so the
  count stays at three. The size class and kind are the ledger's own
  content-free fields.
- A note converges by whole text last writer wins where the body
  converges by merge. Two devices that edit one note offline keep one
  side's text and lose the other's entirely, and point 5's restate is
  outside the note's undo stack, so nothing recovers it; the body would
  have merged both edits. The name converges the same way and loses at
  most an identifier. This is the sharpest loss the design accepts.
- The note is now the one unbounded free text field that leaves the
  device inside the seal. ADR-0042 bounds the name to 1 to 64 characters
  of a shell identifier's charset; nothing bounds the note, so a person
  who pastes a secret into a note syncs it to every enrolled device,
  sealed from the relay but present on each. That is a decision of this
  record, not a side effect: the direction keeps the value home and
  lets the rest travel. Open question 1 asks whether the table caps the
  note.
- A mixed pair of builds stalls as before until both carry this record:
  an earlier build skips the table (client protocol §6) and still refuses
  the batch on `ChipRoster`. No user meets this before the relay ships.
- Epic #252's line "Chips do not sync, so their names and notes do not
  either." under "Explicitly unchanged" is no longer true once this
  record is accepted; the epic owes a note pointing here.
- ADR-0043's and ADR-0046's first open questions are answered by points 4
  and 1 of this record; on acceptance each gains a `Decision history`
  line saying so.
- A new lifecycle state joins Law 0001's table, and its routes (paste,
  conceal, the decrypted drag, the burn) gain a refusal or a face for it.

Owed work on issue #257, none of it done at this writing:

- `crates/core/src/document.rs`: `import_update` admits unknown
  identities and keeps refusing duplicates; its return type changes
  from `Result<(), UpdateRefusal>` to one that returns the identities
  the batch stands that `owned` lacks, so the store learns what to
  create and `chips_of` stays private to the module;
  `UpdateRefusal::ChipRoster`'s doc comment and arm narrow to the
  duplicate.
- `crates/core/src/store.rs`: `apply_remote_update` and `adopt_key_frame`
  create a record in the state held on another device for each identity
  `import_update` returns, before `settle_document` runs, so the settle
  never projects a body standing a sentinel with no chip in the roster;
  the two tests named in Context
  are inverted to pin the object standing on the peer with no value;
  `sync_rejects_foreign_and_duplicate_chips` splits, since a foreign
  identity is now admitted and a duplicate still refused; a test pins
  each menu refusal, the clone placeholder and the burn's travel.
- `crates/core/src/transfer.rs`: `Placed` gains a counter, beside
  `expired`, `burned` and `unavailable`, for a reference placed because
  its value is on another device, and the word `terminal_cause`'s caller
  chooses gains that cause, so the outcome names it as point 3 requires.
- `crates/sync/src/envelope.rs`: the table's envelope shape, with a
  round trip test; `crates/ffi/src/sync_driver.rs` `sweep_outbound`
  queues the whole table, a snapshot of every chip in the page's roster,
  whenever any of that page's metadata moved since the last table it
  queued, and the frame includes it (`seal_owed_frame`,
  `commit_advance`); `sync_session.rs` applies an arriving table by
  revision, terminal state first.
- `crates/core/src/persist.rs` and the
  [core interface](../development/sealed-objects-core-interface.md): the
  record at rest for a chip with no payload, the revisions, and what an
  older build restoring such a record does; the face gains a field that
  says where the value is held, named there.
- `docs/spec/feature/sync/client-protocol.md`: row 10.31 is replaced by
  a row that cites the inverted tests; §6 gains the table's row,
  unsigned beside Ops, Expiry and Hold.
- `docs/law/0001-sealed-object.md`: the lifecycle states table gains
  held on another device, with a note that this row is read per device
  (the value is not on this device) where the table's other rows are
  facts about the object on every device; the expiry row and the paste,
  drag, conceal, burn and decrypted drag rows gain the peer's refusals
  and faces; the sync move amendment gains a dated successor amendment
  citing this record.
- ADR-0012: a `Decision history` line recording that a sealed object's
  name and note egress over sync under this record, with the payload
  egress inventory unchanged at three.
- Epic #252: the "Explicitly unchanged" line gains a note.
- The shell: the face line, the absent items and handle, the page
  conceal's refusal; `ChipInfo` reads the new face field;
  `SealedCapsuleTests` or its successor pins the menu. The face line's
  wording `held on another device` is design copy: the sealed content
  design record in `docs/spec/design/` blesses or changes it, not this
  record, and ADR-0055's rule reaches menus and buttons, not a face
  line.
- ADR-0021 and this record, in one commit on acceptance: ADR-0021 gains
  a `Superseded in part by` line and a `Decision history` entry naming
  this record and the point replaced, and this record gains
  `Supersedes in part:` naming ADR-0021; `scripts/lint-adrs.py` refuses
  either line without the other.

## Alternatives

**Metadata inside the Loro document, as a map keyed by chip identity
(rejected).** It would converge for free and ride the frame unasked.
It is rejected because ADR-0043 point 1 places the name and note on the
chip, "not ink in the page's document"; a map in the document would put
them back in the document's history, so the page's undo and the
ceremony's history shedding would reach them, against ADR-0043 point 2;
and it would make the ops batch carry fields a product detail may later
keep back, where the direction asks that the batch sync regardless. A
table beside the ops keeps the document what ADR-0013 made it and lets
any field stay home without touching the ops.

**Refuse the sentinel and import the rest of the batch (rejected).** A
Loro update is one dependency graph; dropping one insertion breaks the
operations after it, which is the `MissingHistory` stall by another
route.

**Carry nothing and show a bare placeholder (rejected).** The direction
allows it, since metadata "can" sync, but a second device that shows
`[sealed content · unavailable]` for every object the first device
sealed cannot tell its own objects from a foreign reference, and the
name a person typed is page-owned ink they expect on every page they
enrolled.

## Open questions

1. **The note's size on the wire.** A note has no cap in ADR-0043. A
   long note raises the padded bucket a batch lands in and, past client
   protocol §4.1's transport bounds, could keep a batch from going out.
   Whether the table caps the note's text, or truncates it with a mark,
   is open; the direction allows either, since the batch must sync.
2. **The record at rest for an object with no payload.** Whether an older
   build restoring such a record reads it as a chip with empty bytes, or
   drops it, is the core interface's to settle before the code lands.
3. **Terminal evidence for a burn received over sync.** Whether the
   receiving device records `discarded` for the object in its own ledger,
   or only drops the record, is open; Law 0001's burned placeholder needs
   evidence on the device that shows it.

## Eject triggers

- A measured padded delta or frame size, with the table carried, exceeds
  the batching and padding bounds in the protocol specification; that is
  ADR-0021's own trigger, and the table is the first suspect.
- Two devices, both current with the relay, show different names or
  notes for the same object after a session of edits on each; the per
  field revision does not converge and point 5 is reopened.
- The maintainer withdraws the direction that the value does not sync,
  or a record decides payload transfer between devices; points 1 to 3
  are then read again for a device that can hold a value it did not seal.
- Loro offers a container the page's undo and the ceremony's compaction
  provably leave alone; the channel choice in point 4 is reopened against
  the rejected alternative.
- A relay-visible metadata channel appears that the table creates and
  the admission does not name.

## Decision history

- 2026-10-16: Proposed.
