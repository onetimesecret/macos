---
id: 0004-secret-plaintext-never-reallocates
title: Secret plaintext never reallocates
status: draft
dated: 2026-10-12
governs: A buffer that holds secret-bearing plaintext is allocated once at its final size and never grows.
decisions: none numbered; the rule serves ADR-0001's zeroization posture
consumed-by: []
sources:
  - docs/adr/0001-rust-core-thin-shell.md (accepted, security posture)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (proposed, persistence buffers)
  - docs/qa/audits/2026-0928-code-audit.md (conceal request body finding)
  - crates/core/src/persist.rs, crates/core/src/file_persist.rs, crates/ffi/src/persist.rs
---

# Law 0004: Secret plaintext never reallocates

Draft under [behaviour law conventions](README.md); do not build against it as
an accepted law. The rows were recovered from code comments at commit
`087d682`, which are non-authoritative provenance.

## The rule

Proposed governing wording:

> A buffer that holds secret-bearing plaintext is allocated once at its final
> size and never grows.

A `Zeroizing<Vec<u8>>` wipes only the allocation it holds when it drops. A
vector that grows copies its contents into a larger block and frees the old one
unwiped. The rule answers, for any serializer of page content, block sections,
ledger titles, file drafts or seal input, how its output buffer is built.

## Why this rule

[ADR-0001](../adr/0001-rust-core-thin-shell.md) (accepted) names the posture:
"the security posture — deterministic zeroization of secret buffers — must not
depend on the outcome". [ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md)
(proposed) asks the persistence path to "`zeroize` the in-memory buffer". A
growing buffer satisfies neither, because the copies it abandons are never
zeroized. There is no competing option to weigh, which is why this is a law
and not an ADR.

## Operation classes

- **Two-pass serialization.** One encoding walk runs first into a sizing sink
  that counts bytes, then into a `Zeroizing` buffer preallocated to that count.
  A framed record's length prefix comes from running its body through the
  sizing sink. Values a walk could produce differently on a second call
  (document exports, draft bodies) are produced once, outside the walk, and
  both passes copy from them.
- **Known-size copy.** A buffer whose final size is known before the first
  write (the seal work buffer: plaintext plus tag) reserves it directly.
- **Exempt.** Buffers that hold only metadata, ciphertext or public data.

## The contract

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| State snapshot | two-pass | Capacity equals length | `crates/core/src/persist.rs` `snapshot_size_is_exact` |
| Ledger snapshot | two-pass | Capacity equals length | `crates/core/src/persist.rs` `snapshot_size_is_exact` |
| A page's materialized block section | two-pass | Capacity equals length; nothing frozen or grouped encodes to empty | owed: no issue yet, exact-capacity test on `encode_materialized` |
| Drafts file | two-pass | Capacity equals length; exports taken once before the walk | `crates/core/src/file_persist.rs` `the_drafts_buffer_is_written_at_its_exact_size` |
| Seal work buffer | known-size copy | Capacity is plaintext plus tag; sealing writes no further | `crates/ffi/src/persist.rs` `the_seal_work_buffer_is_exact_and_self_wiping` |
| Conceal request body | two-pass | Built without a `serde_json::Value` intermediate and without reallocation | owed: the 2026-09-28 code audit finding "Conceal request body leaves unwiped plaintext copies"; the build contradicts this row |

## What the rule forbids

- `Vec::new()` or `Vec::with_capacity` with a guessed size, followed by writes
  of secret-bearing plaintext.
- `serde_json::to_vec`, `format!`, `String` building or any other growing
  writer on a path that carries page content.
- An intermediate owned copy of a secret (a `serde_json::Value`, a cloned
  `String`) that is dropped without zeroizing.
- A walk body that is not a pure function of what it captures. Drift between
  the passes trips a `debug_assert` only; a release build would grow.

## The rubric for a new interaction

1. Does the buffer ever hold page content, a chip, a draft, a ledger title or
   key material? If not, it is exempt.
2. Is its final size known before the first write? Known-size copy.
3. Otherwise, can the encoding run twice over the same captured values?
   Two-pass. If a value cannot be reproduced, take it once outside the walk.

## Acceptance and tests

- Core: `snapshot_size_is_exact`, `the_drafts_buffer_is_written_at_its_exact_size`.
- Seam: `the_seal_work_buffer_is_exact_and_self_wiping`.
- Owed: the block section row and the conceal body row.

## Amendments

- 2026-10-12: Drafted from an ADR proposal withdrawn before acceptance in
  onetimesecret/macos#237, in favour of this law.
