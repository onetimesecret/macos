---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0042: Secret plaintext is serialized in two passes into one exact-size buffer

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0001](0001-rust-core-thin-shell.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/core/src/persist.rs`, the module header, `SheetStore::snapshot` and
`framed`; `crates/core/src/file_persist.rs`, `emit`). Those comments are
non-authoritative provenance; this record proposes the decision they describe.

[ADR-0001](0001-rust-core-thin-shell.md) (accepted) names the posture this
serves: "the security posture — deterministic zeroization of secret buffers —
must not depend on the outcome". [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)
(proposed) asks the persistence path to "`zeroize` the in-memory buffer".

A `Zeroizing<Vec<u8>>` wipes only the allocation it holds when it drops. A
vector that grows while it is written reallocates: it copies what it holds into
a larger block and frees the old one without wiping it. Every serializer that
writes page content, materialized block sections, ledger titles or file drafts
into a plaintext buffer before sealing would leave those intermediate copies in
freed heap.

## Decision

Every core serializer of secret-bearing plaintext runs one encoding walk twice:
first into a sizing sink that only counts bytes, then into a `Zeroizing` buffer
preallocated to exactly that count.

This covers the state snapshot, the ledger snapshot, each page's materialized
block section and the drafts file. A framed record's length prefix comes from
running its body through the sizing sink, not from an intermediate buffer.
Values that a walk could produce differently on a second call (document
exports, draft bodies) are produced once, outside the walk, and both passes copy
from them.

## Consequences

- No reallocation strands a copy of plaintext in unwiped heap on these paths.
- Every encoding body runs twice and must be a pure function of what it
  captures. A body that drifts between passes trips only a `debug_assert`; in a
  release build the buffer would grow.
- Exports are held in memory beside the output buffer. For drafts the recovered
  comment puts the peak at about twice the drafts' size, all of it zeroizing.
- Pinned by `snapshot_size_is_exact` (`crates/core/src/persist.rs`) for the
  state and ledger snapshots, and by `the_drafts_buffer_is_written_at_its_exact_size`
  (`crates/core/src/file_persist.rs`) for drafts.
- Other egress paths do not follow this rule automatically.
  [The 2026-09-28 code audit](../qa/audits/2026-0928-code-audit.md) records the
  conceal request body as one that does not.

## Eject triggers

- A zeroizing allocator, or a buffer type that wipes on every reallocation,
  becomes available and is adopted for these paths, making the second pass
  redundant.
- Measured snapshot time or peak memory on a large pad crosses a budget that
  the double walk or the held exports cause.
