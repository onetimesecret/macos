---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0044: Ledger restore merges the file into the live ledger as a multiset union

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/core/src/persist.rs`, `SheetStore::restore_ledger`). Those comments
are non-authoritative provenance; this record proposes the decision they
describe.

[ADR-0016](0016-content-persists-across-restart.md) (accepted) drains each
restored countdown by the time away: "On restore, wall time measures only the
unobserved gap since the last sealed write." The shell restores the content file
before the ledger file, and pages that fell due while the app was closed expire
during the content restore, which writes their ledger records into the live
ledger. When the ledger file is read next, the live ledger can already hold
records no file has seen. Replacing the live ledger with the file would drop
them, and an expiry while the app was closed is the one the user never saw.

The live ledger and the file can also both hold the same record, for example
when one file is read twice or a file saved after a merge is read again.

## Decision

`restore_ledger` merges rather than replaces. It appends the file's records
after the live ones without sorting, cancels each file record against at most
one identical live record (whole-record equality), and keeps every file record
that finds no match. The file is never deduplicated against itself.

Retention eviction runs on the merged result.

## Consequences

- Records written by the content restore before the ledger file loads survive.
- Reading the same file twice, or a file written after this merge, yields one
  trail, for records whose stamps were not clamped.
- Two identical records in one file are kept as two events. Pinned by
  `a_ledger_restore_unions_duplicate_records_as_a_multiset`.
- A future stamp clamps to the clock of each load
  ([ADR-0043](0043-ledger-stamp-clamp-stands-aside-below-a-clock-floor.md)),
  so the same record clamped at two different loads does not match itself and
  can appear twice.
- No sort means a file written under a stepped clock keeps its recorded order.

## Eject triggers

- Ledger records gain a unique identifier, which would make identity, not
  equality, the right merge key.
- The shell's launch order changes so the ledger loads before any restore can
  write to it, removing the case the merge exists for.
- Duplicate rows from clamped records are observed in the ledger view.
