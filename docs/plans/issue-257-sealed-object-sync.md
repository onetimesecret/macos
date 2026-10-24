---
documentation_status: needs-review
---

# Issue #257: sealed-object sync plan

**Status:** implementation plan for [ADR-0058](../adr/0058-a-sealed-object-never-stalls-a-pages-sync.md)
as rewritten on 2026-10-23. ADR-0058 stays proposed; this plan is not an
accepted spec. Branch `design/257-sealed-object-sync`.

## 1. Gate answers

The 2026-10-16 review (section 6) left six gates. The maintainer answered
three on 2026-10-23; the plan takes the other three as defaults, each
reopenable.

| Gate | Question | Answer |
| --- | --- | --- |
| Q1 | Which metadata travels? | Maintainer: kind, size class and name, in a bounded patch envelope beside the ops. |
| Q2 | How does a note sync? | Maintainer: as a CRDT in this change. ADR-0058 point 6. |
| Q3 | Does a burn travel? | Maintainer: not in this change. ADR-0058 point 8. |
| Q4 | Format at rest and mixed builds | Default: a new snapshot version with a tag ahead of payload bytes; this build reads the previous one; an earlier build refuses the new one and keeps the file. No sync capability negotiation before the relay ships. |
| Q5 | Ownership after a peer's move; duplicates | Default: the value follows its standing sentinel and takes that page's clock (ADR-0057's direction); one standing per identity, the first in body order, later ones taken out at settle. |
| Q6 | Who accepts? | The maintainer, per the [ADR conventions](../adr/README.md). Agents write proposed records only. |

## 2. Foundations from #256

`fe03c8cb` is an ancestor of `main` (`0494641a`), merged into this branch
at `a7b93de4`. #256 itself stays open for Law 0004 and the decode
blockers SYNC-256-B1 and B2 in [`crates/sync/FOUNDATIONS.md`](../../crates/sync/FOUNDATIONS.md).
New #257 code uses these owners:

- `ByteBlob` owns `Zeroizing<Vec<u8>>`; build it with `ByteBlob::from`,
  read it with `as_slice()`.
- `DeltaEnvelope::encode()` returns `Zeroizing<Vec<u8>>` through
  `companion_sync::secret_json::to_zeroizing_vec`. Every new envelope
  encodes through it; content fields (name, note ops) use zeroizing
  owners and redacted `Debug`.
- `publish_request_with` (`crates/ffi/src/sync_session.rs:667`) publishes
  the rest of a batch when one envelope fails to encode and returns failed
  `Ops` to the driver for a cursor rewind; a seal refusal still drops the
  whole request. `NoteOps` follows the `Ops` rewind; `Metadata` is
  restated, not rewound.
- FFI JSON goes through `content_json::to_c_json`; Swift decodes with
  `decodeOwnedJSON` before the owner is freed.
- `SealedChip` (`crates/core/src/sheet.rs:266`) keeps the excerpt and name
  in `Zeroizing<String>`; a restored note rests in a wiping owner until its
  first edit (C31).

## 3. Code that changes

| Area | Today | Change |
| --- | --- | --- |
| `crates/core/src/document.rs:737` `import_update` | Refuses an unknown or doubled identity with `ChipRoster` | Returns the identities the batch stands that the page lacks; no identity refusal |
| `crates/core/src/store.rs:1029, 1047` `apply_remote_update`, `adopt_key_frame` | Pass `owned_uuids`, settle | Create a record with no value per new identity, then settle; settle takes out later standings and burned identities, outside undo |
| `crates/core/src/sheet.rs:266` `SealedChip` | Payload, exact meta, excerpt, size label always present | Payload, meta, excerpt and receipt move into a `Local` variant; a `Peer` variant has optional kind and size class |
| `crates/core/src/persist.rs:28, 454, 873` | `OTSSNAP4`; payload before trailing name and note; restore calls the sealing constructors | `OTSSNAP5`: availability tag first, name version, note operation log; `OTSSNAP4` still read |
| `crates/core/src/transfer.rs:422, 503` | `resolve` may clone any live record; `terminal_cause` reads the ledger | A record with no value moves by identity and never clones; a clone places the unavailable placeholder with its cause |
| `crates/core/src/store.rs:1455` and the value routes | Copy, Name=Value, link, drag, conceal read the bytes | Each refuses a record with no value in the core |
| `crates/sync/src/envelope.rs:46` | Ops, Expiry, Hold, Terminal, Control | Adds `Metadata` and `NoteOps` |
| `crates/ffi/src/sync_driver.rs`, `sync_session.rs` | One cursor per page; frame is the raw page rebuild | Note cursors; metadata dirty set and restate; a versioned frame with note rebuilds and metadata |
| `shell/Sources/CompanionKit/CompanionClient.swift:462` `ChipInfo` | Kind, excerpt, size label | Adds availability; the face, menu, drag handle and page conceal read it |

## 4. Increments

Each increment compiles, passes its targeted tests and is committed on its
own. CI runs the full suites. No build ships between increments 1 and 3:
`OTSSNAP5`'s chip record gains fields in each.

1. **Peer records (fixes the stall).** `SealedChip` availability, admission,
   one standing per identity, burned identities taken out, value follows
   its sentinel, core refusals of value routes, transfer placeholder,
   `OTSSNAP5`, FFI availability and the Swift face. Invert the two
   `sync_carries_no_object_*` tests; split
   `sync_rejects_foreign_and_duplicate_chips`.
2. **Metadata.** Name versions in the core, the `Metadata` envelope, the
   driver's dirty set, restate at attach and epoch, the pending cache.
3. **Notes.** Note history at rest, note cursors, `NoteOps`, compaction
   with the page, the versioned frame.
4. **Records.** Client protocol row 10.31 and section 6, the core
   interface, Law 0001's lifecycle row proposed for ratification,
   versions and the changelog.

## 5. Tests owed

| Group | Scenarios |
| --- | --- |
| Admission | Seal on an enrolled page; a peer imports it and a later dependent edit; malformed bytes and missing history stay refusals |
| Regressions | The two `sync_carries_no_object_*` tests inverted, source and destination batches in both orders |
| Duplicates | Two devices stand one identity concurrently; both converge on one standing; a crafted fragment naming one twice is refused before mutation |
| Value follows | A peer moves an object between pages; the holding device ends with the value on the destination page and no copy; the source page's end leaves it alive |
| Routes | Every value route refuses a record with no value with no write and no ledger event; the page conceal refuses while one stands; a detached one does not block it |
| Transfer | Cut and first paste keep the identity; copy, later paste and option drag place the unavailable placeholder |
| Burn | A burned identity standing again on the sealing device is taken out and the delete reaches the peer |
| At rest | `OTSSNAP4` restores unchanged; a record with no value round trips; an earlier reader refuses `OTSSNAP5` and the file is untouched |
| Metadata | Concurrent renames converge in both delivery orders; a cleared name wins by version; a failing metadata envelope leaves ops applied; an entry before its sentinel waits and applies |
| Notes | Concurrent note edits merge; a relaunch keeps shared history; compaction sheds deleted note text; a note op naming a chip is refused; a frame join receives each note's rebuild |
| Payload boundary | Unique payload markers absent from every envelope, frame and peer FFI result |

## 6. Review history

The 2026-10-16 design review at `bc1bc4e4` found nine issues (C1 to C9):
an unbounded full roster table, empty payload bytes misread by older
readers, an unsigned absorbing burn with a payload device exception,
unordered per field clocks, transfer without ownership rules, note loss
under last writer wins, unclear authority, scope confusion with #267, and
the #256 integration point. ADR-0058's 2026-10-23 text answers C1, C2,
C4, C5 and C9 directly, removes C3 by keeping burns on the device, and
replaces C6's note proposal with the CRDT the maintainer chose. Section 1
records C7. The full review text is in this file's history at `b6c5be87`.
