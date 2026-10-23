---
name: project-issue257-peer-records
description: Issue #257 unit 1 (2026-10-23) made a sealed record with no value a chip state; how SealedChip availability, OTSSNAP5 and the peer test seam are shaped
metadata:
  type: project
---

`SealedChip.availability` is `Availability::Local(LocalValue)` or `Availability::Peer { kind, size }`; `meta()` is `Option`, `excerpt()` and `size_label()` are empty for a peer, `duplicate()` is `Option`. `OTSSNAP5` puts an availability tag ahead of the value; `OTSSNAP4` is still read through `ChipLayout::Valued`. v5 is unshipped, so units 2 and 3 extend the chip record in place.

**Why:** ADR-0058 (proposed) lets a peer keep a record whose value lives on another device, so a sync never stalls on an object it cannot import.

**How to apply:**
- A core helper an ffi test needs must be `#[cfg(any(test, feature = "test-util"))] pub`; a `#[cfg(test)]` helper in core is invisible to ffi tests. `SheetStore::stand_peer_record` is the peer seam until unit 2's admission exists, and the ffi test using it runs only under `--features test-util`.
- Two restores of equivalent snapshots re-snapshot byte for byte (Loro's export is deterministic), so `assert_eq!(a.snapshot(0), b.snapshot(0))` is a usable equivalence check.
- `copy_out_chip` reads attached chips only; read a detached chip's bytes in a core test through `local().unwrap().bytes`.
- The Swift conceal error allow list (`readerReason(forCoreRefusal:)`) does not yet know the two new refusal strings; unit 3 owes that.

Related: [[project-issue241-243-core]], [[project-adr0018-gated-seams]]
