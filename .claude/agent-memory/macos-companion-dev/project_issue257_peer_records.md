---
name: project-issue257-peer-records
description: Issue #257 units 1 and 2 (2026-10-23) made a sealed record with no value a chip state and made sync admit and reconcile it; SealedChip availability, OTSSNAP5, the peer seam, admission and the value-follows rules
metadata:
  type: project
---

`SealedChip.availability` is `Availability::Local(LocalValue)` or `Availability::Peer { kind, size }`; `meta()` is `Option`, `excerpt()` and `size_label()` are empty for a peer, `duplicate()` is `Option`. `OTSSNAP5` puts an availability tag ahead of the value; `OTSSNAP4` is still read through `ChipLayout::Valued`. v5 is unshipped, so units 2 and 3 extend the chip record in place.

Unit 2: `import_update` returns the identities a batch stands that the page lacks; `ChipRoster` is gone from both refusal enums (no restore or local path used it). The store's `admit`, `follow_sentinels` (inside `settle_document`), `rehome_values` (inside `entomb`) and `take_out_standings` do ADR-0058 points 1 to 3 and 8.

**Why:** ADR-0058 (proposed) lets a peer keep a record whose value lives on another device, so a sync never stalls on an object it cannot import.

**How to apply:**
- Loro's `to_delta` coalesces two adjacent sentinels with the same chip mark into one piece; `runs_of` now splits an all-sentinel marked piece into one `DocRun::Chip` per sentinel. Any position math over runs depends on that.
- A record moves only between readable pages, and the page it leaves forgets its undo (a step there could stand the sentinel with no record). A detached record replaces a standing record with no value; a detached record with no value drops where a value stands.
- `entomb` mutates its page now, so its old `#[expect(clippy::needless_pass_by_value)]` had to go.
- A core helper an ffi test needs must be `#[cfg(any(test, feature = "test-util"))] pub`; a `#[cfg(test)]` helper in core is invisible to ffi tests. `SheetStore::stand_peer_record` mints a random identity, so a test needing a peer record for a real object builds it by shipping a batch.
- Two restores of equivalent snapshots re-snapshot byte for byte (Loro's export is deterministic), so `assert_eq!(a.snapshot(0), b.snapshot(0))` is a usable equivalence check.
- `copy_out_chip` reads attached chips only; read a detached chip's bytes in a core test through `local().unwrap().bytes`.
- The Swift conceal error allow list (`readerReason(forCoreRefusal:)`) does not yet know the two new refusal strings; unit 3 owes that.

Related: [[project-issue241-243-core]], [[project-adr0018-gated-seams]]
