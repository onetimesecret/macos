---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0043: The ledger's future-stamp clamp stands aside below a wall-clock floor

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/core/src/persist.rs`, `WALL_CLOCK_FLOOR_MS` and
`SheetStore::restore_ledger`). Those comments are non-authoritative provenance;
this record proposes the decision they describe.

Ledger retention keys on wall-clock stamps.
[ADR-0012](0012-framing-threat-boundary-and-persistence-model.md) (proposed)
accepts some error from that: "the failure mode of a stepped clock here is a
metadata record living slightly too long or dying slightly early, never a
secret's lifetime being extended."

On load, `restore_ledger` clamps each record's event and creation stamps to the
current wall clock plus two seconds. Without the clamp, a record stamped by a
clock running years ahead would stay inside the retention window for as long as
its stamp stayed ahead, and be rewritten under the long-lived ledger key on
every save. The clamp itself fails when the judging clock is the broken one: a
clock reading 1970 would backdate every record, and the first correct clock
afterwards would evict the whole trail.

## Decision

The ledger restore clamps future stamps only when the wall clock reads at or
above `WALL_CLOCK_FLOOR_MS` (2026-10-01T00:00:00Z). Below it, the clock is
treated as wrong and stamps are kept as written for that load.

The floor is a date no build running this code predates. It is a constant; it
does not move with releases.

## Consequences

- A clock that reads before the floor (an unset or reset RTC) does not destroy
  the trail. Pinned by `a_clock_that_reads_before_the_floor_leaves_ledger_stamps_alone`.
- A load under such a clock keeps genuinely future-stamped records unclamped.
  They are clamped on the next load under a sane clock.
- A clock stepped backwards but still above the floor is trusted, so the clamp
  can backdate records written under the later time, and they age out early.
  This is within the error ADR-0012 accepts.
- Above the floor, the clamp holds. Pinned by
  `a_future_stamped_ledger_record_is_clamped_to_the_clock_on_load`.
- A clamped record's stamp depends on the clock of the load that clamped it,
  which affects how the ledger merge matches records
  ([ADR-0044](0044-ledger-restore-is-a-multiset-union.md)).

## Eject triggers

- A trusted time source the core can consult on load becomes available.
- Field diagnostics show ledgers loaded under clocks below the floor often
  enough that the unclamped future stamps matter.
- Field reports of trails lost to a backwards clock step that stayed above the
  floor.
