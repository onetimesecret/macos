---
id: 0006-ledger-restore
title: Ledger restore
status: draft
dated: 2026-10-12
governs: Restoring the ledger file merges it into the live ledger without losing a record either side holds, and distrusts only the stamps a sane clock can judge.
decisions: none numbered; serves ADR-0016's restore
consumed-by: []
sources:
  - docs/adr/0016-content-persists-across-restart.md (accepted)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (proposed)
  - crates/core/src/persist.rs (`SheetStore::restore_ledger`, `WALL_CLOCK_FLOOR_MS`)
  - crates/core/src/ledger.rs (`LEDGER_RETENTION_MS`, `evict_expired`)
---

# Law 0006: Ledger restore

Draft under [behaviour law conventions](README.md); do not build against it as
an accepted law. The rows were recovered from code comments at commit
`087d682`, which are non-authoritative provenance.

## The rule

Proposed governing wording:

> A ledger restore is a multiset union of the live ledger and the file, after
> clamping the file's future stamps to the wall clock when that clock reads at
> or above a fixed floor.

## Why this rule

[ADR-0016](../adr/0016-content-persists-across-restart.md) (accepted): "On
restore, wall time measures only the unobserved gap since the last sealed
write." The shell restores the content file before the ledger file, so pages
that fell due while the app was closed have already written records into the
live ledger. Replacing it with the file would drop the one expiry the user
never saw.

Retention keys on wall-clock stamps. A record stamped by a clock running years
ahead would stay inside the 90 day window for as long as its stamp stayed
ahead, so stamps are clamped on load. But a clock reading 1970 would backdate
every record and the first correct clock would evict the whole trail, so the
clamp stands aside below `WALL_CLOCK_FLOOR_MS` (2026-10-01T00:00:00Z), a date
no build running this code predates. The floor is a constant and does not move
with releases. [ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md)
(proposed) bounds the remaining error: "the failure mode of a stepped clock
here is a metadata record living slightly too long or dying slightly early,
never a secret's lifetime being extended."

## Operation classes

- **Clamp.** Clock at or above the floor: each record's event and creation
  stamps are capped at the wall clock plus two seconds.
- **Trust as written.** Clock below the floor: stamps are kept for this load.
- **Merge.** File records go after the live ones, unsorted. Each cancels
  against at most one identical live record (whole-record equality); every
  unmatched file record is kept. The file is never deduplicated against itself.
- **Evict.** Retention runs once, on the merged result.
- **Refuse.** A superseded or unknown magic, or damage, leaves the live ledger
  untouched.

## The contract

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| Records written by the content restore before the ledger loads | merge | Survive | `crates/core/src/persist.rs` `a_ledger_restore_keeps_the_records_the_store_already_holds`; `crates/ffi/src/lib.rs` `a_death_while_away_survives_the_ledger_restore_that_follows_it` |
| The same file read twice | merge | One trail, for unclamped stamps | `crates/core/src/persist.rs` `a_ledger_restore_unions_duplicate_records_as_a_multiset` |
| Two identical records in one file | merge | Kept as two events | `crates/core/src/persist.rs` `a_ledger_restore_unions_duplicate_records_as_a_multiset` |
| A record stamped in the future, clock above the floor | clamp | Capped at the clock plus slack | `crates/core/src/persist.rs` `a_future_stamped_ledger_record_is_clamped_to_the_clock_on_load` |
| Clock below the floor | trust as written | Stamps kept; future records are clamped on the next sane load | `crates/core/src/persist.rs` `a_clock_that_reads_before_the_floor_leaves_ledger_stamps_alone` |
| The same future record clamped at two different loads | clamp, merge | Does not match itself and can appear twice | owed: no issue yet, known gap |
| Clock stepped backwards but above the floor | clamp | Trusted; records written under the later time are backdated and age out early, within ADR-0012's bound | owed: no issue yet |
| File written under a stepped clock | merge | Keeps its recorded order | owed: no issue yet |
| Records older than 90 days after the merge | evict | Dropped; a record exactly 90 days old is kept | `crates/core/src/store.rs` `the_window_boundary_keeps_a_record_exactly_ninety_days_old` |
| Superseded ledger magic | refuse | `Superseded`, live ledger untouched | `crates/core/src/persist.rs` `a_superseded_ledger_magic_refuses_as_superseded_with_the_ledger_untouched` |

## What the rule forbids

- Replacing the live ledger with the file.
- Sorting the merged ledger by stamp.
- Deduplicating the file against itself.
- Clamping with a clock that reads below the floor.
- Moving the floor with releases.

## The rubric for a new interaction

1. Does it write to the live ledger before the ledger file is read? The merge
   must keep it.
2. Does it compare or age stamps? It must say what happens under a clock below
   the floor and under a backwards step above it.
3. Does it give records an identity? Then identity, not equality, becomes the
   merge key and this law is amended.

## Acceptance and tests

- Core: the `crates/core/src/persist.rs` and `store.rs` tests named above.
- Seam: `a_death_while_away_survives_the_ledger_restore_that_follows_it`.
- Owed: the double-clamp, backwards-step and order rows.

## Amendments

- 2026-10-12: Drafted from two ADR proposals (clock floor, multiset union)
  withdrawn before acceptance in onetimesecret/macos#237, in favour of this
  law.
