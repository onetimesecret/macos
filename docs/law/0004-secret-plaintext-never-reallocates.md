---
id: 0004-secret-plaintext-never-reallocates
title: Secret plaintext never reallocates
status: draft
dated: 2026-10-12
governs: A buffer that holds secret-bearing plaintext never grows in place; it is allocated at its final size, or, when that size is unknown until a read ends, each growth moves into a fresh zeroizing allocation.
decisions: none numbered; the rule serves ADR-0001's zeroization posture
consumed-by:
  - docs/adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md (the note's persisted text and the composed `NAME=` buffer)
sources:
  - docs/adr/0001-rust-core-thin-shell.md (accepted, Context)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (proposed, persistence buffers)
  - docs/qa/audits/2026-0928-code-audit.md (conceal request body finding)
  - crates/core/src/persist.rs, crates/core/src/file_persist.rs, crates/core/src/store.rs, crates/ffi/src/persist.rs
  - crates/ots-client/src/api.rs, crates/transport/src/lib.rs, crates/ffi/src/files.rs
---

# Law 0004: Secret plaintext never reallocates

Draft under [behaviour law conventions](README.md); do not build against it as
an accepted law. The rows were recovered from code comments at commit
`087d682`, which are non-authoritative provenance.

## The rule

Proposed governing wording:

> A buffer that holds secret-bearing plaintext never grows in place. It is
> allocated at its final size, or, when that size is unknown until a read
> ends, each growth moves into a fresh zeroizing allocation.

A `Zeroizing<Vec<u8>>` wipes only the allocation it holds when it drops. A
vector that grows copies its contents into a larger block and frees the old one
unwiped. The rule answers, for any serializer of page content, block sections,
ledger titles, file drafts or seal input, and for any reader of a response
that carries a link key or a token, how its buffer is built.

## Why this rule

The Context section of [ADR-0001](../adr/0001-rust-core-thin-shell.md)
(accepted) names the posture: "the security posture — deterministic
zeroization of secret buffers — must not depend on the outcome". [ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md)
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
  write (the seal work buffer: plaintext plus tag; a page's conceal payload:
  the sum of its runs) reserves it directly.
- **Wiping growth.** A buffer whose final size is known only when a read ends
  (an HTTP response body) reads through a zeroizing chunk. When the next chunk
  will not fit, it copies into a fresh zeroizing allocation and drops the old
  one, which wipes it.
- **Exempt.** Buffers that hold only metadata, ciphertext or public data.

## The contract

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| State snapshot | two-pass | Capacity equals length | `crates/core/src/persist.rs` `snapshot_size_is_exact` |
| Ledger snapshot | two-pass | Capacity equals length | `crates/core/src/persist.rs` `snapshot_size_is_exact` |
| A page's materialized block section | two-pass | Capacity equals length; nothing frozen or grouped encodes to empty | `crates/core/src/persist.rs` `the_block_section_is_written_at_its_exact_size` |
| Drafts file | two-pass | Capacity equals length; exports taken once before the walk | `crates/core/src/file_persist.rs` `the_drafts_buffer_is_written_at_its_exact_size` |
| Seal work buffer | known-size copy | Capacity is plaintext plus tag; sealing writes no further | `crates/ffi/src/persist.rs` `the_seal_work_buffer_is_exact_and_self_wiping` |
| A page's conceal payload | known-size copy | Reserved at the sum of its runs and never grows; capacity equals length when every text chip is UTF-8 | `crates/core/src/store.rs` `the_conceal_payload_is_written_at_its_exact_size` (UTF-8 chips only) |
| Conceal request body | two-pass | Capacity equals length; no `serde_json::Value` intermediate | `crates/ots-client/src/api.rs` `the_conceal_body_is_written_at_its_exact_size` (capacity only; the absence of a `Value` is read from the code) |
| HTTP response body | wiping growth | Every byte arrives in order across growths; a failed read returns its error | `crates/transport/src/lib.rs` `a_body_read_past_its_reservation_arrives_whole_and_in_order`, `a_read_that_fails_partway_returns_the_error` (bytes only) |
| HTTP response body | wiping growth | No allocation holding body bytes is reallocated or freed unwiped | owed: no issue yet; needs a counting global allocator in transport's tests, an `unsafe` allowance the workspace lint rule does not grant today |
| Key file half | known-size copy | `fs::read` sizes the buffer from the stat; it grows only if the file grows during the read | owed: no issue yet |
| An opened file's text | unclassified | `read_regular` presizes a plain `Vec` from the stat and `read_to_end` grows it if the file grows during the read | owed: owner decision on whether file backed text is in scope |

## What the rule forbids

- `Vec::new()` or `Vec::with_capacity` with a guessed size, followed by writes
  of secret-bearing plaintext that grow it in place.
- `serde_json::to_vec`, `format!`, `String` building, `read_to_end` or any
  other growing writer on a path that carries page content, a link key or a
  token.
- An intermediate owned copy of a secret (a `serde_json::Value`, a cloned
  `String`) that is dropped without zeroizing.
- A walk body that is not a pure function of what it captures. Drift between
  the passes trips a `debug_assert` only; a release build would grow.

## The rubric for a new interaction

1. Does the buffer ever hold page content, a chip, a draft, a ledger title,
   key material, a link key or a token? If not, it is exempt.
2. Is its final size known before the first write? Known-size copy.
3. Otherwise, can the encoding run twice over the same captured values?
   Two-pass. If a value cannot be reproduced, take it once outside the walk.
4. Is the size unknown until a read ends? Wiping growth.

## Acceptance and tests

- Core: `snapshot_size_is_exact`, `the_drafts_buffer_is_written_at_its_exact_size`,
  `the_block_section_is_written_at_its_exact_size`,
  `the_conceal_payload_is_written_at_its_exact_size`.
- Client and transport: `the_conceal_body_is_written_at_its_exact_size`,
  `a_body_read_past_its_reservation_arrives_whole_and_in_order`,
  `a_read_that_fails_partway_returns_the_error`.
- Seam: `the_seal_work_buffer_is_exact_and_self_wiping`.
- Owed: the response body wipe, the key file half, and a scope decision on an
  opened file's text.

## Amendments

- 2026-10-12: Drafted from an ADR proposal withdrawn before acceptance in
  onetimesecret/macos#237, in favour of this law.
- 2026-10-12: Review on onetimesecret/macos#237. The conceal body row was
  stale: the build already sized it in two passes; a test now pins it. The
  block section and conceal payload rows gained tests. The transport read
  response bodies past its 64 KiB reservation by growing in place, so the
  wiping growth class and its rows were added and the rule widened to cover
  it. The key file half and opened file rows record two readers the review
  found outside the table.
