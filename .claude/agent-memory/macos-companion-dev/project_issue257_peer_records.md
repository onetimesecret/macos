---
name: project-issue257-peer-records
description: Issue #257 units 1 to 3 (2026-10-23): a sealed record with no value as a chip state, sync admission and value-follows rules, and the shell face, menu and seam
metadata:
  type: project
---

`SealedChip.availability` is `Availability::Local(LocalValue)` or `Availability::Peer { kind, size }`; `meta()` is `Option`, `excerpt()` and `size_label()` are empty for a peer, `duplicate()` is `Option`. `OTSSNAP5` puts an availability tag ahead of the value; `OTSSNAP4` is still read through `ChipLayout::Valued`. v5 is unshipped, so units 2 and 3 extend the chip record in place.

Unit 2: `import_update` returns the identities a batch stands that the page lacks; `ChipRoster` is gone from both refusal enums (no restore or local path used it). The store's `admit`, `follow_sentinels` (inside `settle_document`), `rehome_values` (inside `entomb`) and `take_out_standings` do ADR-0058 points 1 to 3 and 8.

**Why:** ADR-0058 (proposed) lets a peer keep a record whose value lives on another device, so a sync never stalls on an object it cannot import.

**How to apply:**
- Loro's `to_delta` coalesces two adjacent sentinels with the same chip mark into one piece; `runs_of` (via `split_marked`) reads only a U+FFFC under a chip mark as a chip, one per sentinel; any other marked character is ink. Any position math over runs depends on that.
- A record moves only between readable pages, and the page it leaves forgets its undo (a step there could stand the sentinel with no record). A detached record replaces a standing record with no value; a detached record with no value drops where a value stands.
- `delete_chip` then drops every record with no value for the burned identity on readable pages (no ledger event) and takes out its standings; a dropped detached one forgets its page's undo.
- `entomb` mutates its page now, so its old `#[expect(clippy::needless_pass_by_value)]` had to go.
- A core helper an ffi test needs must be `#[cfg(any(test, feature = "test-util"))] pub`; a `#[cfg(test)]` helper in core is invisible to ffi tests. `SheetStore::stand_peer_record` mints a random identity, so a test needing a peer record for a real object builds it by shipping a batch.
- Two restores of equivalent snapshots re-snapshot byte for byte (Loro's export is deterministic), so `assert_eq!(a.snapshot(0), b.snapshot(0))` is a usable equivalence check.
- `copy_out_chip` reads attached chips only; read a detached chip's bytes in a core test through `local().unwrap().bytes`.
- Unit 3 (shell, 2026-10-23): `stand_peer_record` returns `Result` now (an FFI seam must never panic); the seam `companion_test_stand_peer_record` is named in two seam regexes, `scripts/package-app.sh` and `scripts/verify-release-core.sh`, so a new gated seam needs both.
- `mergeIntoShownStorage` compares objects by chip id only, so a face change under the mounted page (availability, a peer's rename) needs `restateChipFaces(onSheet:)` after it; unmounted pages are rebuilt whole.
- `ChipInfo.available` decodes with `decodeIfPresent ?? true`, so older fixtures still decode. `readerReason` translates both value-elsewhere refusals into sealed content wording (ADR-0055 rule 3).
- The only burn path in the shell is Burn Local Copy after a successful conceal, so hiding Create One-Time Link plus the core's conceal refusal keeps the burn from being offered.

Related: [[project-issue241-243-core]], [[project-adr0018-gated-seams]]
