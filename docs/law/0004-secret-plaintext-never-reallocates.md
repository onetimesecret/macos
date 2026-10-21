---
id: 0004-secret-plaintext-never-reallocates
title: Secret plaintext never reallocates
status: draft
dated: 2026-10-12
governs: A buffer that holds secret-bearing plaintext never grows in place; it is allocated at its final size, or, when that size is unknown until a read ends, each growth moves into a fresh zeroizing allocation.
decisions: none numbered; proposed allocation discipline informed by ADR-0001 Context
consumed-by:
  - docs/adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md (accepted; the name and the note at rest)
  - docs/adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md (accepted; the envelope and its public text)
  - docs/development/sealed-objects-core-interface.md
  - docs/development/content-buffer-handling.md (implementation inventory and remaining work)
sources:
  - docs/adr/0001-rust-core-thin-shell.md (accepted, Context)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (proposed, not acceptance authority)
  - crates/core/src/persist.rs, crates/core/src/file_persist.rs, crates/core/src/store.rs, crates/ffi/src/persist.rs
  - crates/ots-client/src/api.rs, crates/transport/src/lib.rs, crates/ffi/src/files.rs
  - crates/ffi/src/content_json.rs, crates/sync/src/secret_json.rs, crates/sync/src/envelope.rs
---

# Law 0004: Secret plaintext never reallocates

**Draft, not ratified.** Under the [behaviour law conventions](README.md), this
is not an accepted law. Its original rows were recovered from code comments at
`087d682`; those comments are non-authoritative provenance. Issue #256's Rust
boundary/outbox changes implement part of the proposed discipline, not the
whole law or whole issue.

The [content buffer handling guide](../development/content-buffer-handling.md)
records a disposition for every entry in issue comment 6210863783, source
inspection, test limits, and remaining work. That guide is an implementation
reference, not an additional source of normative authority.

## The rule

Proposed governing wording, unchanged:

> A buffer that holds secret-bearing plaintext never grows in place. It is
> allocated at its final size, or, when that size is unknown until a read
> ends, each growth moves into a fresh zeroizing allocation.

Implementation interpretation: a final `Zeroizing<Vec<u8>>` does not erase
allocations released by earlier growth. A growth that moves bytes into a new
allocation can release the old storage unwiped. Likewise, wiping a serialized
result does not erase its source models, parser scratch, decoded values, or
other owners. The proposed scope includes page ink, excerpts, names, notes,
titles, origin URLs, fragments, file text/drafts, serialized sync ops, and
secrets such as keys or tokens. It is not a statement that all these paths
currently conform.

## Authority and rationale

[ADR-0001](../adr/0001-rust-core-thin-shell.md), **accepted**, Context, states:

> the security posture — deterministic zeroization of secret buffers — must not depend on the outcome

This is authority for the posture within that ADR's scope, not evidence that
the current code implements every allocation rule proposed here.

[ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md) is
**proposed**. Its Persistence model proposes:

> `zeroize` the in-memory buffer.

Its Context also says:

> Swift `String` cannot be reliably zeroed: immutable, ARC-copied, backing store scattered.

Neither that proposed text nor this draft authorizes an exception for retained
Swift content. The finer allocation discipline here remains a proposal.
Code observations and tests below describe implementation, not acceptance.

## Proposed operation classes

- **Two-pass serialization.** Count an encoding, then write into a destination
  allocated to that count. Capture changing values, including document exports,
  once before both passes. Review serializer-internal allocations separately.
- **Known-size copy.** Allocate the final destination before writing content;
  use a wiping owner from the first write.
- **Wiping growth.** Read through a zeroizing chunk. When space is insufficient,
  copy into a fresh zeroizing allocation and wipe the previous owner.
- **Narrow payload.** Remove content from a boundary or cache when identifiers,
  ranges, counts or borrowed views suffice.
- **Content-free storage.** Metadata-only headers, public data and ciphertext
  need no content wipe under this proposed rule. Encoded ops and base64 of
  plaintext remain content. URLs, labels and ceremony data need field-specific
  classification; the metadata label is not an erasure exception.

## Implementation and outstanding contract rows

Tests listed here exist in source. A test name does not imply it ran during
this amendment; the guide records the exact executed subset. Capacity and byte
checks do not prove that every dependency allocation was wiped.

| Interaction | Class / implemented portion | Test evidence and remaining work |
| --- | --- | --- |
| State and ledger snapshot | Two-pass zeroizing application output | `crates/core/src/persist.rs::snapshot_size_is_exact`; resident titles and Loro export construction remain separate blockers. |
| Materialized block section | Two-pass zeroizing application output | `crates/core/src/persist.rs::the_block_section_is_written_at_its_exact_size`; empty section behavior included. |
| Drafts file | Two-pass zeroizing application output; exports captured once | `crates/core/src/file_persist.rs::the_drafts_buffer_is_written_at_its_exact_size`; upstream export scratch is not covered. |
| Seal/decrypt work buffer | Known-size zeroizing owner | `crates/ffi/src/persist.rs::the_seal_work_buffer_is_exact_and_self_wiping`; not proof about earlier source allocations. |
| Page conceal payload | Known-size zeroizing result | `crates/core/src/store.rs::the_conceal_payload_is_written_at_its_exact_size` (UTF-8 chips); segment owners now wipe at `09901309`, while upstream Loro allocations remain separate. |
| Conceal request body | Two-pass zeroizing output, no content Value intermediate | `crates/ots-client/src/api.rs::the_conceal_body_is_written_at_its_exact_size` checks capacity; borrowed-field construction is source-inspected. |
| HTTP response body | Wiping-growth implementation | `crates/transport/src/lib.rs::a_body_read_past_its_reservation_arrives_whole_and_in_order`, `a_read_that_fails_partway_returns_the_error` check bytes/error. Allocator-level growth/drop wipe instrumentation remains owed; no dedicated issue yet. |
| Key file half | Known-size intent; reader still needs review | Owed: growth/error-path test and wiping-reader decision; stat sizing alone does not handle a file changing during read. No dedicated issue yet. |
| Opened file read and normalization | Exact zeroizing normalization implemented; wiping reader planned | `09901309`: `core/src/files.rs::normalize_newlines` counts before writing; `normalization_and_file_projections_are_exact_zeroizing_text` checks it. `crates/ffi/src/files.rs::read_regular` still returns a plain vector and uses `read_to_end`; reader growth/error cleanup remains unresolved. |
| Fragment envelope | Two-pass zeroizing output | `crates/core/src/fragment.rs::the_envelope_is_written_at_its_exact_size`; WireRef name clone remains unwiped. |
| Fragment public text | Known-size zeroizing result | `crates/core/src/fragment.rs::the_public_text_puts_a_size_class_placeholder_where_each_object_stood`. |
| Copy decrypted / decrypted drag / `NAME=` result | Known-size zeroizing result | `crates/core/src/store.rs::a_copy_out_is_written_at_its_exact_size`; AppKit bridge storage is not this owner. |
| Pasted fragment and edit-batch parsing | Planned wiped typed owners and parser scratch | Issue #256: serde_json 1.0.150 has growing, non-wiping escaped-string scratch; names, Value intermediates and refusal cleanup remain. Source-inspected software blocker, not a machine-only check. |
| Page, note, fragment, chip, active-cut, tab, ledger and file JSON for Swift | Implemented two-pass output and borrowed/zeroizing projections | `crates/ffi/src/content_json.rs` tests below; final allocation is boxed JSON bytes plus NUL, wiped by `companion_string_free`. Resident excerpt/name/title/origin owners, Loro sources, lossy fallback construction and decoded Swift values remain unresolved. Scope is established by the #256 task direction; implementation is partial. |
| Other owned C-string returns | Implemented exact boxed final owner and wiping free | `ordinary_strings_share_the_exact_box_layout_and_free_path`, `free_takes_back_only_what_this_module_handed_out`; the free takes back only buffers `content_json.rs` recorded, at their recorded length. Earlier metadata/ceremony String/Value construction is not retroactively wiped. Static versions and diagnostic callback are borrowed. |
| Sync ByteBlob, base64, envelope encode and pad | Implemented zeroizing owners and fixed-size output | `crates/sync/src/envelope.rs`, `b64.rs`, `secret_json.rs`, `pad.rs` tests below; inbound escaped-string scratch remains. |
| Queue, withdraw, publish and inbound dispatch | Implemented per-Ops owner; publish encode/pad temporaries wipe | `crates/ffi/src/sync_session.rs` tests below; queue removal is tested, not freed-memory inspection. Loro import and parser scratch remain separate. |
| Swift JSON boundary borrow | Implemented | Every JSON route calls `decodeOwnedJSON`: synchronous `Data(bytesNoCopy:count:deallocator: .none)` borrow and deferred release defaulting to `companion_string_free`; other owned strings go through `ownedString`. `ContentJSONDecodingTests` covers both helpers and checks they are the only release sites in `shell/Sources`. Explicit intermediate JSON String/Data copies are removed; Foundation internal copies and decoded-string erasure are not established. |
| Core run/text/file projections and simulated UTF-16 | Wiping owners implemented at `09901309` | DocRun uses Zeroizing and exact coalescing; Segment wipes on drop and receives the allocation by transfer; `text_of` and file text APIs return Zeroizing; SimUnits reserve for all inserts before copying. Six regression tests below; upstream Loro construction remains unresolved. |
| Resident excerpts, names, notes, titles, origins and edit parsing | Planned wiped owners or narrower projections | Ordinary EditOp/Value, excerpt/name/title/origin/restore and fragment wire-name copies remain; Note's Loro storage remains blocked. The guide records each entry. |
| Loro state/history/import/export | Dependency-level wiped storage or representation change needed | Pinned source confirms non-wiping arena growth and growing update output. Shared/static/inline allocations and snapshot scratch need further source work. Wrapping returned vectors is only a partial implementation. |
| Pasteboard/drag input, refusal and bridge | Planned early wiping owners and narrow intentional egress | Issue #256: refused images drop ordinary vectors; MemoryPasteboard read/origin copies remain. Objective-C constructors copy; `clearContents` is not evidence of a storage wipe. |

## Proposed restrictions and review rubric

For this draft, reject guessed-capacity growing plaintext writers, ordinary
content Value/String intermediates without wiping ownership, and wrapping only
a final result while ignoring earlier growth. A zeroizing destructor is not
sufficient when growth already released plaintext storage.

The new FFI and sync writers use fixed destinations: both directions of length
drift fail rather than extending the output, including in release code. Older
serializers using a growing vector and only a `debug_assert` of the final size
still require review; tests of the new writers do not change those paths.

For a new interaction:

1. Classify each field and every owner, including errors/refusals, decoded
   values, parser scratch and derived text. Do not classify all JSON together.
2. Prefer a narrow payload or a bounded borrow when the consumer needs no copy.
3. If output size is known, allocate it before writing. Otherwise count twice
   over captured values, or use wiping growth for a stream.
4. Review dependency allocations and resident source models independently.
5. Test bytes/shape, size drift/errors, ownership transfer and observable wipe
   on a live allocation. Record what those tests do not establish.

## Tests for the implemented portion of issue #256

Source baseline: `7384bff1`, `9a2d14e4`, `09901309` and `fe03c8cb`.
These are implementation tests, not normative authority or a statement that
the entire issue is complete.

- Core at `09901309`: `document.rs::projected_ink_coalesces_marked_pieces_at_exact_capacity`,
  `sheet.rs::segment_ink_and_its_clone_have_independent_wiping_owners`,
  `ink.rs::text_projection_is_exact_and_zeroizing_including_sentinels`,
  `files.rs::normalization_and_file_projections_are_exact_zeroizing_text`,
  `store.rs::simulated_ink_uses_one_reserved_wiping_allocation`,
  `store.rs::a_late_surrogate_refusal_leaves_the_document_unchanged`.
  All six passed in focused all-features runs during this documentation update.
- `crates/ffi/src/content_json.rs`:
  `exact_nul_encoding_matches_serde_and_wipes_the_live_allocation`,
  `chip_and_cut_fields_match_the_previous_sorted_json_bytes`,
  `copied_envelope_stays_a_string_with_the_same_lossy_utf8_semantics`,
  `raw_transfer_and_reconstruction_use_the_same_pointer_and_full_slice_length`,
  `ordinary_strings_share_the_exact_box_layout_and_free_path`,
  `errors_and_size_drift_return_null_instead_of_transferring_a_partial_buffer`.
- `crates/ffi/src/lib.rs`:
  `content_routes_preserve_escaped_text_and_sorted_json_shapes`,
  `tab_projection_matches_the_previous_json_bytes_for_each_label_source`.
- `crates/ffi/src/files.rs`:
  `file_runs_match_previous_json_bytes_for_empty_escaped_and_large_text`.
- `crates/sync/src/secret_json.rs`:
  `escaped_json_matches_serde_at_exact_capacity`,
  `both_directions_of_size_drift_are_errors`,
  `errors_in_either_pass_are_returned`, `count_refuses_overflow`.
- `crates/sync/src/envelope.rs` / `b64.rs` / `pad.rs`:
  `blob_clones_are_independent_zeroizing_owners_with_redacted_debug`,
  `escaped_fields_and_base64_still_decode`,
  `invalid_base64_and_truncated_envelopes_are_refused`,
  `zeroizing_buffers_match_public_encoding_across_chunk_boundaries`,
  `round_trips_and_pads_to_the_bucket`.
- `crates/ffi/src/sync_session.rs`:
  `withdrawn_ops_leave_the_page_s_expiry_and_every_other_page_queued`,
  `withdrawal_after_a_partial_seal_failure_publishes_only_the_surviving_ops`,
  `a_refused_seal_keeps_the_queue_for_the_next_tick`,
  `sealed_blobs_reach_the_wire_in_power_of_two_buckets`.
- [ContentJSONDecodingTests.swift](../../shell/Tests/CompanionKitTests/ContentJSONDecodingTests.swift)
  is source-inspected: seven tests cover nil, success/error, invalid UTF-8,
  exactly-once release, synchronous pointer alias, long escaped Unicode and real
  FFI release. Parent reports **7 passed within 221 focused Swift tests**.

The full local gate passed at `fe03c8cb`: formatting, workspace clippy, workspace
tests with and without `test-util`, the universal test-util core build, Swift
build and the full Swift suite. The [handling guide](../development/content-buffer-handling.md#tests-and-validation-limits)
records commands, counts, the ignored credential test and limits. These results
do not establish Foundation-internal no-copy behavior or process-wide erasure.

## Why this remains draft

The issue permits recording blockers instead of ratification. The remaining
blockers are explicit:

- **Core/application software:** resident excerpts and origin/name/title/restore
  copies, EditOp/fragment/test-wire parsing, fragment wire names, the FFI file
  reader and image-refusal cleanup still need implementation and regression
  tests. C02–C05, C07 and C06 normalization are implemented; their upstream
  Loro allocations remain separate.
- **Dependency software:** serde_json escaped-string scratch; Loro arena,
  history/fork/import/export allocations; snapshot intermediates; shared and
  static string storage. Source inspection confirms specific non-wiping paths;
  the complete allocation graph remains unverified.
- **Swift/AppKit architecture:** the boundary helper and tests are implemented;
  decoded models, NSTextStorage, cached renderings, attachments, composition
  fragments, and Foundation/Objective-C copies are not erased by that helper.
  No Foundation-internal no-copy or decoded-string-erasure result is asserted.
- **Evidence gaps:** transport wipe instrumentation and key-file growth/error
  coverage remain outstanding. Existing size/byte tests do not substitute for
  these checks. No test covers every planned inventory entry yet.

These are blockers to accepting this proposed rule, not grounds for omitting
the affected entries. The guide's register separates remaining software work
from machine observations; B4's explicit boundary validation is resolved.

## What needs a person at the machine

Observe actual pasteboard/drag delivery, advertised types/markers, clear timing
and competing writes on the deployed macOS version. Inspect actual memory-lock
results under that machine's resource limits. This amendment did not perform
those checks.

These observations cannot settle parser scratch, dependency/static allocation
behavior, software ownership, or all Foundation/system-storage copies. Those
questions require source/architecture work or remain unverified OS details.
A successful drop or clear is not proof of byte erasure in the pasteboard
server, destination app, window server, compression/swap, or prior copies.

## Amendments

- 2026-10-12: Drafted from an ADR proposal withdrawn before acceptance in
  onetimesecret/macos#237, in favour of this law.
- 2026-10-12: Review in #237 recorded two-pass conceal output, block and payload
  tests, wiping-growth transport reads, and remaining key/open-file readers.
- 2026-10-13: Issue #170 added sealed-fragment output/copy rows and recorded
  pasted-envelope parsing and shell JSON as unresolved paths.
- 2026-10-16: ADR-0043 and ADR-0045 acceptance was recorded in `consumed-by`;
  that did not accept this law.
- 2026-10-16: Issue #256 added exact-size wiping Rust FFI output, sync owners,
  test references, the per-entry handling guide, and explicit parser/core/AppKit
  blockers. Replaced the stale outgoing-JSON scope question with implementation
  status; this law remains draft.
- 2026-10-16: Core `09901309` implemented wiping run/segment/text/file projections,
  exact newline normalization and reserved zeroizing simulation. Inspected the
  Swift boundary helper/tests and recorded parent-reported results separately
  from direct checks. Reader, resident-content, parser/dependency and AppKit
  limits remain; the full final gate is pending.
