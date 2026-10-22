# Content buffer handling

Implementation reference and remaining-work register for issue #256. This is
not an accepted specification, a security exception, or evidence that every
content allocation is zeroized. Law 0004 remains **draft**. Completing the
Rust boundary and outbox work does not complete #256.

## Authority and inspection scope

[ADR-0001](../adr/0001-rust-core-thin-shell.md), **accepted**, Context,
establishes this posture:

> the security posture — deterministic zeroization of secret buffers — must not depend on the outcome

Its Decision establishes the architecture:

> All state and logic live in pure-Rust crates with no UI or platform dependencies (`companion-core`, `ots-client`); platform FFI is isolated in `companion-pasteboard`; whatever shell wins ADR-0002 is a thin layer that renders state and forwards intents.

These quotations do not establish that the current implementation zeroizes all
page text. Source inspection below identifies counterexamples.

[ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md) is
**proposed**, not authority for accepting residual exposure. Its Context says:

> Swift `String` cannot be reliably zeroed: immutable, ARC-copied, backing store scattered.

Its Persistence model proposes, on expiry, send, or discard:

> `zeroize` the in-memory buffer.

[Law 0004](../law/0004-secret-plaintext-never-reallocates.md) is **draft**;
its operation classes are proposals, not a ratified contract. The dispositions
in this guide are implementation choices or proposed follow-up work, not new
normative security promises.

The task input is the inventory in
[issue comment 6210863783](https://github.com/onetimesecret/macos/issues/256#issuecomment-6210863783),
made against `6dcd6518`. That issue discussion is a coverage checklist, not an
authoritative specification. Its stated total is 57 C-string routes; the route
table below accounts for every function named there, without treating that total
as a verified ABI count. An independent scan of current `lib.rs` and `files.rs`
finds 55 named C-string returns (three static, 52 owned), including the additional
compose-fragment route. No unnamed routes are invented to reconcile the total.
The issue's October 14 direction makes boundary content part of this work;
there is no longer an unresolved decision about whether outgoing JSON is in
scope. That task direction does not ratify either proposed document.

Inspection baseline: foundation `7384bff1`, Rust FFI `9a2d14e4`, core
`09901309`, and Swift boundary `fe03c8cb` on `fix/256-content-buffers`,
October 16, 2026. Source inspection and test results are implementation evidence
only. The final gate below ran against `fe03c8cb`; later documentation-only
edits do not change that tested code.

## Disposition vocabulary

Each inventory entry below has one or more selected treatments:

- **Z — zeroizing serialization:** count then serialize into a fixed destination;
  no content-bearing `serde_json::Value` on that output path.
- **W — wiped owner:** put bytes in an owner that zeroizes on release; for known
  sizes allocate before writing, otherwise replace and wipe on each growth.
  For the Swift boundary this means a synchronous borrow of the Rust owner,
  followed by its wiping free, not an assertion that Swift strings are erasable.
- **N — narrow payload:** keep a route content-free, or replace materialized
  content with identifiers, ranges, counts, ciphertext, or a borrowed view.

**Implemented** means the named owner/path is present in inspected source;
**partial** identifies the precise implemented part; **planned** means code and
regression tests are still needed; **blocked** identifies a dependency or
architecture question that remains. No partial row is a completed inventory item.
Metadata classifications here describe inspected fields, not a declaration that
paths, labels, URLs, pairing secrets, or credentials are harmless.

## Outgoing C-string routes

All abbreviated names in this table have the `companion_` prefix. The source is
[`crates/ffi/src/lib.rs`](../../crates/ffi/src/lib.rs), except `file_*` and
`drafts_notices_json` in
[`crates/ffi/src/files.rs`](../../crates/ffi/src/files.rs).

Every **owned** string return now uses the exact boxed-byte layout from
[`content_json.rs`](../../crates/ffi/src/content_json.rs), including metadata
routes still using `into_c_string`. `content_json.rs` records the address and
full length of every buffer it hands out, and `companion_string_free`
reconstructs, zeroizes and releases only a recorded buffer, at its recorded
length. Null, the three static version pointers (`const char *`), and any
pointer not recorded are left alone. The FFI test helpers `take_json` in
`lib.rs` and `files.rs` assert that each owned return they read was recorded,
so a route that bypasses `content_json.rs` fails its tests. The record does not
make a second free safe: once a freed address is reused for a newer string, a
stale pointer to it frees that string, as with plain `malloc` and `free`.
This changes the final allocation; it does not retroactively wipe earlier
`String` growth or `Value` intermediates.

| ID | Routes (all names in the inventory) | Data and selected treatment | Implementation status / residual work |
| --- | --- | --- | --- |
| F01 | `ffi_version`, `version`, `core_version` | Public version strings; **N**, static borrowed pointers | Implemented; no page content, no owned-free call. |
| F02 | `detect_source_language` | Content-derived language slug; **N** output, **W** final owner | Implemented output classification; input bytes remain content, see S03. |
| F03 | `test_wire_last_json` (test-util) | Redacted request summary; **N** output, **W** final owner | Implemented output; its whole-body parser is not zeroizing, see C27. |
| F04 | `sheet_seal_from_pasteboard`, `sheet_seal_text`, `sheet_seal_from_drag` | Excerpt and name, with kind/size/note flags; **Z + W** borrowed `ChipFace` | Implemented Rust output; core excerpt/name owners and Swift `ChipInfo` remain C09–C11 / S01. |
| F05 | `sheet_undo_action_name`, `sheet_redo_action_name`, `chip_note_undo_action_name`, `chip_note_redo_action_name`, `file_undo_action_name`, `file_redo_action_name` | Static action labels copied to owned returns; **N + W** | Implemented; Swift `ownedString` still copies labels, not page text. |
| F06 | `chip_note_runs_json` | Note ink; **Z + W**, borrow `Note::text` through `InkRuns` | Implemented output, not Loro internals or decoded strings. |
| F07 | `chip_note_undo`, `chip_note_redo`, `file_undo`, `file_redo` | Applied flag and UTF-16 caret/selection; **N + W** | Implemented; existing metadata `Value` serializer remains. |
| F08 | `sheet_copy_fragment`, `sheet_cut_fragment` | Envelope JSON as a string, plus public text; **Z + W**, borrowed `Copied` fields | Implemented Rust output; refusal object is metadata. Owned lossy-UTF-8 fallback is wiped after serialization, but its construction is not a wiping-growth implementation. Fragment names/parser and Swift envelope/text remain C19–C22 / S01. |
| F09 | `sheet_paste_fragment`, `sheet_paste_active_cut`, `sheet_move_range`, `sheet_move_range_to`, `sheet_clone_range` | Placement ranges/counts, unreadable/expiry flags; **N + W** output | Implemented output; content input and core temporaries remain separate work. |
| F10 | `active_cut_json` | Object excerpts and names, plus page id; **Z + W**, borrowed faces | Implemented output; core and Swift active-cut storage are not fixed by this. |
| F11 | `tabs_json` | Typed/derived titles and tab metadata; **Z + W** | Implemented output and zeroizing temporary label; upstream title/name construction is C13–C15, implemented 2026-10-21. |
| F12 | `ledger_json` | Titles and event metadata; **Z + W**, borrowed title | Implemented output; the resident and restored title owner is C16, implemented 2026-10-21; the restored chip owners are C31's, implemented 2026-10-21. |
| F13 | `sheet_document_json` | All ink, object excerpts/names; **Z + W**, borrowed `DocumentRuns` | Implemented output without content `Value` copies; projection owners C02/C03 now wipe, while upstream Loro allocations remain C01. |
| F14 | `sheet_meta_json`, `sheet_blocks_json` | Stamps, block ids and counts; **N + W** | Implemented content-free shape as inspected; not permission to add block text to these serializers. |
| F15 | `connection_json`, `connection_test` | Connection state and result/error metadata; **N + W** | Implemented; no page text in the inspected output. |
| F16 | `chip_conceal`, `sheet_conceal` | Receipt id or refusal/error; **N + W** output | Implemented output; concealed link is written separately to pasteboard under a zeroizing Rust owner, with the AppKit limits in C46. |
| F17 | `sync_status_json`, `sync_gate` | State, progress and gate token; **N + W** | Implemented page-content-free output. |
| F18 | `sync_signin_begin`, `sync_signin_finish` | Authorize URL or refusal/result; **N + W** for page content | Implemented output; OAuth URL/state is not a page-origin URL and remains authentication-sensitive. |
| F19 | `sync_attach`, `sync_pump`, `sync_devices_json` | Epochs, event kinds, UUIDs, fingerprints, device labels; **N + W** | Implemented page-content-free output; labels are not reclassified as secret page ink. |
| F20 | `sync_invite_begin`, `sync_join_begin`, `sync_pairing_poll`, `sync_pairing_confirm` | Ceremony stage and SAS; **N** for page content, **W** for ceremony secret | Partial: final Rust return wipes. SAS and metadata `Value`/`String` intermediates and decoded Swift SAS are not covered by the content serializer; dedicated secret-owner work is planned. |
| F21 | `file_open_error_json`, `file_save_error_json` | Error metadata; **N + W** | Implemented; inline Swift reading still copies the error text. |
| F22 | `file_runs_json` | Whole file body; **Z + W** with zeroizing projection and `InkRuns` | Implemented boundary output using the core's zeroizing projection directly, without a redundant FFI wrapper; normalization/projection owners are implemented, while the FFI file reader remains C06. |
| F23 | `file_check`, `file_roster_json`, `drafts_notices_json` | State, names, paths, flags; **N** for file body, **W** final return | Implemented body-free output. Paths/names remain identifying data in ordinary core and Swift owners; proposed **W** follow-up, not a secure-erasure exception. |
| F24 | `file_bookmark_b64` | Bookmark encoding a path; **N** for body, **W** final return | Partial: base64 and Swift copies remain ordinary metadata owners. Planned **W** handling if path erasure is required; no page body is serialized. |
| F25 | `sheet_compose_fragment` (additional current route) | Same envelope/public-text shape as copy; **Z + W** | Implemented via `copy_outcome_json`; same limitations as F08. |

The diagnostic callback is not an owned return. It borrows a CString during the
callback and reports diagnostic text. Selected treatment: **N**, retain
content-free diagnostics. Its source is
[`diagnostics.rs`](../../crates/ffi/src/diagnostics.rs); it is not a route for
page ink or secret values.

## Core and adjacent buffer inventory

Paths in the evidence column are relative to `crates/`. Rows C01–C47 follow
Table 2 of the issue inventory, including metadata-only rows. C48 comes from the
PR 270 review, not from the inventory. Proposed work is explicit rather than
silently exempting an existing content copy.

| ID | Buffer / data | Selected treatment | Status and inspected evidence |
| --- | --- | --- | --- |
| C01 | `SheetDocument` page body and Note's `LoroDoc`, including history/deleted text | **W**, dependency-level owner or alternative representation | **Blocked**: Loro arena growth/deallocation is non-wiping; selected internal string types can use shared/static storage. See dependency evidence below. A wrapper around the final document cannot erase these allocations. |
| C02 | `DocRun::Ink` from `runs_of` | **W**, exact-size coalescing | **Implemented** at `09901309`: inserts enter `Zeroizing<String>` and adjacent ink is coalesced at its exact byte size (`core/src/document.rs`). A run of one piece moves that piece's allocation instead of copying it: loro 1.13.9 `LoroText::to_delta` makes each insert with `String::to_string` (a clone at the string's length), and spare capacity would sit inside the same `Zeroizing` owner either way. Upstream Loro `to_delta` construction remains C01. |
| C03 | `Sheet.segments`, `Segment::Ink` | **W** segment owner | **Implemented** at `09901309`: Segment implements Zeroize/Drop; rebuilding/restoring transfers the DocRun string allocation with `mem::take`, without copying content (`core/src/sheet.rs`, `persist.rs`). Clones have independent wiping owners; inbound parser copies remain C08. |
| C04 | `ink::text_of` result | **W**, exact-size result owner | **Implemented** at `09901309`: returns `Zeroizing<String>` constructed at the summed run size, including sentinel bytes (`core/src/ink.rs`). Loro source construction remains C01. |
| C05 | `OpenFile::text`, `FileStore::text` | **W** projection | **Implemented** at `09901309`: return `Zeroizing<String>` / `Option<Zeroizing<String>>` directly from `text_of` (`core/src/files.rs`); F22 borrows that owner. Adjacent public `OpenFile::bytes_to_write` still returns a plain vector; its in-tree callers are tests, and its API needs follow-up. |
| C06 | File reading and CRLF normalization | **W**, wiping reader and exact normalization | **Partial**: `09901309` adds exact-size `normalize_newlines` into `Zeroizing<String>` (`core/src/files.rs`). **Planned**: `ffi/src/files.rs::read_regular` still uses a plain vector and `read_to_end`; stat size is a hint, and earlier reader growth/error cleanup is not covered. |
| C07 | `sim_units` UTF-16 content | **W**, pre-sized zeroizable storage | **Implemented** at `09901309`: SimUnit zeroizes code units; a zeroizing vector reserves exact room for the body plus every insert before copying content. Insert simulation checks capacity and shifts in place; overflow/allocation failure refuses (`core/src/store.rs`). |
| C08 | `EditOp::Insert.text`, `parse_ops`, `parse_segments` | **W** direct typed parse plus wiping scratch | **Blocked/Planned**: ordinary `String` and content `Value` copies remain in `core/src/store.rs` / `ffi/src/lib.rs`; serde_json escaped-string scratch is non-wiping. A zeroizing visitor alone does not fix scratch. |
| C09 | `SealedChip.excerpt`, `text_face` head/tail | **W**, exact projection, or **N** omit excerpt | **W — implemented** resident owner (2026-10-21): `excerpt` is `Zeroizing<String>`, and `text_face` takes its head and tail as slices of the input and joins them once at the exact size, with no collected copies and no `format!` scratch (`core/src/sheet.rs`). F04/F10/F13 borrow it. |
| C10 | `SealedChip.name` | **W** resident/name-update owner | **W — implemented** resident owner (2026-10-21): `Option<Zeroizing<String>>`, with the name set, the restore and the transfer clone wrapping the judged name as it is copied (`core/src/sheet.rs`, `store.rs`, `transfer.rs`, `persist.rs`). |
| C11 | `SealedChip.note`, `Note` | **W** document and projection | **Partial/Blocked** (2026-10-21): a note made by `Note::holding`, for a restore, a paste or a clone, rests as one `Zeroizing<String>` at its exact size, and `Note::text` copies it at that size; a read, a step, a run's end, an empty batch, a batch of ops that move nothing and a refused batch make no document, and a selection given at a run's end or by a batch that moves nothing is kept for the document and handed to it when it is made (`core/src/note.rs`, C31). **Blocked**: the first batch the note accepts that changes its text inserts the text into a Loro document, as the first edit of a chip with no note does; from then `Note::text` is zeroizing and exact, and underlying Loro has C01's limits. |
| C12 | `SealedChip.bytes` | **W**, fixed `SecretBuffer` | **Implemented** for this owner: `core/src/secret.rs` wipes length and spare capacity on drop; no resizing API. Text attempts page locking; images use the unlocked constructor. This is not evidence of successful OS page locking for every allocation. |
| C13 | `Sheet.derived_title`, `derive_title` / `strip_markdown` | **W**, bounded exact construction | **W — implemented** resident owner (2026-10-21): `derived_title` and `derive_title`'s result are `Zeroizing<String>`; the first line's trimmed copy is wrapped as it is made, `strip_markdown` and `flatten_links` build in wiping owners sized once from the line, and the resident title is `capped_title`'s exact owner, so a long line's intermediate wipes as it drops rather than living on in the title's capacity (`core/src/sheet.rs`). `Sheet` derives no `Debug`; one added later would print the title, since the redaction is `LedgerRecord`'s alone. |
| C14 | `Tab.name` | **W**, bounded exact construction | **W — implemented** resident owner (2026-10-21): `Option<Zeroizing<String>>` on the tab, the set and the restore taking the cap through `capped_title`, one allocation at the exact size with no growing scratch (`core/src/store.rs`, `sheet.rs`, `persist.rs`). `Tab` derives no `Debug`; one added later would print the name. |
| C15 | `Tab::label` result | **W** temporary | **W — implemented** (2026-10-21): `label` returns `Zeroizing<String>`, so every ledger label and F11 are wiping temporaries; `TabSummary.title` takes it without a re-wrap. What remains is the route's, not this owner's: serde_json's writer path and the C string buffer (F11, C28). |
| C16 | `LedgerRecord.title` | **W** resident/restored title | **W — implemented** resident and restored owner (2026-10-21): `Zeroizing<String>` on the record, the restore taking the cap through `capped_title` at the exact size, and the record's `Debug` writing `[REDACTED]` for it (`core/src/ledger.rs`, `store.rs`, `persist.rs`). F12 borrows it; persistence output is separately C28. No new retention policy is established here. |
| C17 | Origin URLs: pasteboard origin, `origin_message`, document/block origin | **W** typed origin and serialized message, or **N** identifier | **Implemented** as **W** owners (2026-10-21). The origin is whatever string the writing app put under `public.url` (`pasteboard/src/macos.rs::read`), query included, so it can bear a token; it is not an app or document identifier, and **N** does not fit. Origin URLs are content for this disposition, unlike F18's authorize URL. A system read has Foundation convert the `NSString` into a zeroed `Zeroizing` buffer of the UTF-8 length it reports (`getBytes:maxLength:usedLength:encoding:options:range:remainingRange:` in `utf8_of`), with no `UTF8String` copy, and keeps it as `PasteboardItem.origin_url`, an `Option<Zeroizing<String>>`, only when the whole string converted; a string with no UTF-8 form, such as one with an unpaired surrogate, is no origin, where `UTF8String` returned NULL and a slice was built from it. The read runs in its own autorelease pool, so the board's autoreleased `NSString` is released when it returns, and type names are compared as `NSString`s (`declares`), so the crate makes no `UTF8String` call. The memory board stores the origin in that owner, and a read clones it into another at the same size (`pasteboard/src/macos.rs`, `lib.rs`). `origin_message` counts `{"origin": url}`, then writes it once into a zeroed wiping owner of that size, with no `Value` and no growth (`ffi/src/content_json.rs`); both seal routes borrow it for the commit, and a message that cannot be written seals without one (`ffi/src/lib.rs`). A block's provenance finds the change that defines created and copies its message once, after the scan, into `SpanProvenance.origin`, and `span_timestamps` reads no message; graduation and a merge move that owner into `MaterializedMeta.origin`, and the restore copies its slice of the decrypted snapshot (C32) once (`core/src/document.rs`, `blocks.rs`, `persist.rs`). `read_captures_the_origin_url_when_present_and_none_otherwise` (both boards), `content_json.rs::the_origin_message_is_its_json_in_one_exact_wiping_owner`, `blocks.rs::a_blocks_origin_is_a_wiping_owner_the_size_of_its_changes_message` and `persist.rs::a_compacted_store_round_trips_materialized_metadata_and_origin` check that each is a wiping owner whose capacity is its length, which does not count copies; `macos.rs::utf8_of_converts_a_whole_string_and_refuses_an_unpaired_surrogate` check the conversion and its refusal, `a_non_ascii_origin_reads_whole_and_a_surrogate_written_as_one_yields_no_origin` a board's read (a test board reads such a string back as empty), and `document.rs::a_spans_origin_is_the_message_of_its_earliest_change_wherever_it_sits` the change the origin comes from. `PasteboardItem` and the memory board's item write `[REDACTED]` for the origin in `Debug` (`lib.rs::debug_output_never_prints_the_origin_url`). The page's own transaction origin, `UNRECORDED_ORIGIN` (`core/src/document.rs`), is a static identifier, **N**. What remains is not these owners': the board's `NSString`, and whatever Foundation allocates inside the conversion, which is not inspected; Loro's copies of the message, the `Arc<str>` a commit makes, those its change store decodes from its encoded blocks, and its exports (C01, C29). |
| C18 | `Node::Ink`, `Reference.note` | **W** final owner | **Implemented** final `Zeroizing<String>` and exact selected-range copy (`core/src/fragment.rs`); parsed escaped input still has C21's scratch/temporary limits. |
| C19 | `Reference.name`, `WireRef.name` in `envelope` | **W**, borrow during encoding | **Partial** (2026-10-21): `Reference.name` is `Option<Zeroizing<String>>`, taken from the chip's own owner and wrapped on parse, and `WireRef.name` borrows it for the encode as the note does. On the parse an escaped name is serde's own `Cow::Owned` before the wrap (`core/src/fragment.rs`); that scratch is C21's. |
| C20 | `Fragment.nodes` | **N** header-only vector, **W** per text owner | **Partial**: vector growth moves headers, not separately allocated ink bytes; it does not exempt C19's name or all variant contents. |
| C21 | `Fragment::parse`, WireFragment fields | **W** direct owners plus wiping parser | **Blocked/Planned**: final ink/note move into zeroizing strings, but parse temporaries, invalid/refused input cleanup, names and serde scratch are not covered. Cut/UUID text can be **N** typed identifiers. |
| C22 | `Copied.envelope`, `Copied.plain` | **Z + W** | **Implemented** exact/two-pass output (`core/src/fragment.rs`); wire-name clone remains C19. F08's lossy fallback construction also needs review for wiping growth. |
| C23 | `ActiveCut.envelope` | **W** | **Implemented** final zeroizing vector (`core/src/transfer.rs`); upstream fragment construction remains C19–C21. |
| C24 | `copy_out_chip`, `copy_out_name_value` (`NAME=`) | **W** exact result | **Implemented** final zeroizing vectors (`core/src/store.rs`); resident source/name is separate. |
| C25 | `sheet_payload`, chip conceal payload | **W** exact result | **Implemented** final zeroizing strings (`core/src/store.rs`, `ffi/src/lib.rs`); segment owners now wipe (C03), while Loro remains C01. |
| C26 | Conceal request body | **Z + W** | **Implemented** two-pass request owner (`ots-client/src/api.rs`, `types.rs`); does not cover transport/library internals. |
| C27 | `StubWire::summarize` (test-util) | **N** redacted direct visitor, **W** scratch | **Planned**: it currently parses the whole secret body into `Value` before redacting (`ffi/src/conceal.rs`). Output redaction alone does not wipe test-process content. |
| C28 | Core snapshot and materialized block section | **Z + W** | **Implemented** application output (`core/src/persist.rs`); Loro exports captured before serialization retain C29's construction limit. |
| C29 | `export_snapshot`, `export_updates_since` | **W** export construction and result | **Partial/Blocked**: `core/src/document.rs` wraps only returned vectors. Loro fast snapshot pre-sizes its outer result, while update export grows a plain vector; intermediate serialization is not established as zeroizing. |
| C30 | Drafts emit | **Z + W** | **Implemented** application output (`core/src/file_persist.rs`); captures Loro exports once, so C29 remains. |
| C31 | `restore`, `read_chip` name/note | **W** restore owners | **Implemented** restore owners (2026-10-21): each name the restore reads, a chip's name, a tab's name and a ledger record's title, is a slice of the decrypted snapshot (C32, I08) copied once into its exact `Zeroizing<String>` (C10, C14, C16), and a chip record's note is copied once into `Note`'s resting owner at its exact size, with no Loro document made for it (`core/src/persist.rs`, `note.rs`, C11). `persist.rs::a_restored_name_and_note_rest_as_wiping_copies_until_the_note_is_edited` and `note.rs::a_restored_note_rests_as_one_wiping_copy_until_its_first_edit` check the owners, and `note.rs::a_resting_note_edits_and_steps_as_the_document_it_becomes` that the steps after the first edit match a document made at once, the selections given at runs' ends before it included. What remains is not these owners': that first edit puts the note's text in a Loro document (C01), and the active cut's envelope is parsed on restore for its identities alone, so its ink, names and notes pass serde's escaped-string scratch before their wiping owners, which then drop (`core/src/transfer.rs::ActiveCut::restored`, C19, C21). |
| C32 | FFI `seal_body`, `open_body`, `Opened::Plaintext` | **W** exact work/decrypt owner | **Implemented** final plaintext owner (`ffi/src/persist.rs`); output of sealing is ciphertext. |
| C33 | `ByteBlob` page ops | **W** zeroizing owner and clones | **Implemented** at `7384bff1` (`sync/src/envelope.rs`): private `Zeroizing<Vec<u8>>`, explicit zeroize interface, redacted Debug. `From<Vec<u8>>` cannot fix the input vector's earlier allocation history. |
| C34 | `ByteBlob` base64 serialize/deserialize | **Z + W** | **Partial**: exact zeroizing encode/decode buffers and visitor exist (`sync/src/b64.rs`, `envelope.rs`); escaped JSON still passes through non-wiping serde scratch. Base64 text of ops is content, not ciphertext. |
| C35 | `DeltaEnvelope::encode` | **Z + W** | **Implemented** fixed destination via `sync/src/secret_json.rs`; errors/size drift cannot extend that destination. `encode` returns the error; the publish path raises a diagnostic fault and publishes the rest. Failed ops are not kept: the driver rewinds the page's export cursor to the acknowledged one and the next sweep exports them again. A failed expiry, hold or terminal envelope stays queued (`sync_session.rs::an_envelope_that_cannot_encode_hands_back_its_ops_and_keeps_its_facts_queued`, `sync_driver.rs::ops_that_fail_to_encode_export_again_on_the_next_sweep`). Serialization-internal allocations remain independently reviewable. |
| C36 | `pad::pad` | **W** exact padded plaintext | **Implemented** zeroizing bucket-size vector (`sync/src/pad.rs`). Padding is not encryption. |
| C37 | `SyncSession.outbox` | **W** per Ops owner; **N** vector of headers | **Implemented** Ops ownership through ByteBlob (`ffi/src/sync_session.rs`). Envelope-vector growth is not a copy of separately allocated op bytes. |
| C38 | `queue_ops`, `withdraw_ops` | **W** | **Implemented** exact slice copy into ByteBlob; retain removal drops the removed owner. Tests cover queue membership and partial-seal failure, not observation of freed memory. |
| C39 | Publish batch encoding/padding/clear | **Z + W** | **Implemented** encode and pad temporaries zeroize; queue remains on a refused seal, clears only after all seals succeed (`ffi/src/sync_session.rs`). |
| C40 | `InFlightBatch.blobs`, `.restate` | **N** ciphertext blobs and control facts; **W** ByteBlob fields | **Implemented**: restate selects Expiry/Hold/Terminal, not Ops. Terminal marker ByteBlob remains zeroizing; it is not described as ciphertext merely because Ops are absent. |
| C41 | Inbound open/decode/dispatch | **W** | **Partial**: opened buffer and decoded ByteBlob zeroize (`ffi/src/gop.rs`, `sync_session.rs`); serde scratch and imported Loro state remain blocked. |
| C42 | Sweep export to outbox | **W** | **Partial**: source export result and queued copy zeroize (`ffi/src/sync_driver.rs`, `core/src/store.rs`); Loro export construction remains C29. |
| C43 | Ceremony rebuild and key frame | **W** plaintext, **N** ciphertext result | **Partial**: zeroizing application snapshot/frame plaintext (`core/src/store.rs`, `ffi/src/gop.rs`); Loro reconstruction/export remains C01/C29. |
| C44 | `PageTracking.frontier`, `.acked` | **N** version-vector bytes | **Implemented** classification (`ffi/src/sync_driver.rs`); no page ink in the inspected version encoding. |
| C45 | Inbound `PasteboardContent::Text` / `::Image` | **W** immediately, before validation | **Partial/Planned**: FFI explicitly wipes text after sealing; accepted image moves to SecretBuffer. Since 2026-10-21 (C17) the system text read has Foundation convert the string through `utf8_of` into a zeroed `Zeroizing` buffer, with no `UTF8String` copy, and `PasteboardContent::Text` takes that `String` out of it without a copy; a text with no UTF-8 form counts as no text, so the read takes the PNG as it does when the board has no text at all, where `UTF8String` returned NULL and a slice was built from it (`pasteboard/src/macos.rs::chosen_content`, `a_non_ascii_text_reads_whole`, `a_text_without_utf8_falls_through_to_the_image_as_no_text_does`). The variant is still an ordinary `String`. Image refusal in `seal_image` or `seal_image_at_with_origin` drops an ordinary vector unwiped (`core/src/store.rs`). Needs early zeroizing ownership and refusal tests. |
| C46 | System pasteboard/drag write | **W** Rust owner; **N** narrow intentional egress | **Blocked** for end-to-end erasure: adapters create NSString/NSData copies; malformed-UTF-8 text may also create an ordinary lossy Rust string (`pasteboard/src/macos.rs::write_content`). Clearing calls `clearContents`, not a wipe of Foundation or system storage. |
| C47 | `MemoryPasteboard`, `MemoryDragItem` | **W** resident and read-copy owners | **Partial/Planned**: stored/provided bytes zeroize, and so do the stored origin and its read copy (2026-10-21, C17); text/image read copies and lossy conversions do not (`pasteboard/src/lib.rs`). Test doubles are not exempt from content ownership work. |
| C48 | `Debug` output of `Segment::Ink` and `DocRun::Ink` (added in the PR 270 review) | **N** redacted `Debug` | **Implemented**: both print `Ink([REDACTED])` (`core/src/sheet.rs`, `document.rs`), as `ByteBlob` prints `ByteBlob([REDACTED])`; `segment_debug_output_never_prints_its_ink` and `doc_run_debug_output_never_prints_its_ink` check that the ink appears in neither `{:?}` nor `{:#?}`. **Planned**: `EditOp::Insert` (`core/src/store.rs`) and `PasteboardContent::Text` (`pasteboard/src/lib.rs`) still derive `Debug` and print their text. `PasteboardItem` and `MemoryPasteboard` write `[REDACTED]` for the origin URL (2026-10-21, C17) and still print their content. |


## Swift residence and input inventory

Source: [`CompanionClient.swift`](../../shell/Sources/CompanionKit/CompanionClient.swift),
[`PageModel.swift`](../../shell/Sources/CompanionKit/PageModel.swift),
[`InkEditorView.swift`](../../shell/Sources/CompanionKit/InkEditorView.swift), and
[`SealedFragmentPasteboard.swift`](../../shell/Sources/CompanionKit/SealedFragmentPasteboard.swift).
The following selected treatments remain proposals except the implemented
boundary borrow in S02.

| ID | Inventory entry | Selected treatment and status |
| --- | --- | --- |
| S01 | `ChipInfo.excerpt/name`, `RestoredRun.ink`, `TabSummary.title`, `LedgerEntry.title`, `FileSummary.name/path`, `ActiveCut.objects`, `SealedFragment.envelope/plainText` | **N** identifiers/borrowed or on-demand views where possible; **W** owned bytes where content must persist. **Blocked/Planned**: ordinary decoded String/Data models remain. Envelope conversion `Data($0.utf8)` is another copy. A synchronous JSON borrow does not erase decoded fields. |
| S02 | `decodeOwnedJSON`, `ownedString` | **W** borrowed Rust owner for content JSON; **N** content-free uses of `ownedString`. **Implemented**: every JSON route calls `decodeOwnedJSON`, which uses `Data(bytesNoCopy:count:deallocator: .none)`, synchronous decoding, and deferred release defaulting to `companion_string_free`; invalid UTF-8 now decodes to nil where `String(cString:)` used to substitute U+FFFD. Every other owned string, the five former inline readers included, goes through `ownedString`. `ContentJSONDecodingTests.testOnlyTheTwoOwnedHelpersReleaseCoreStrings` checks that these two helpers are the only `companion_string_free` callers in `shell/Sources` and that no source uses `UnsafeMutablePointer(mutating:)`. Foundation-internal no-copy behavior and decoded-string erasure are not established. |
| S03 | `sealText` editor input / `withCString`, `pasteFragment` input, `detectSourceLanguage(in: Data)` | **W** explicit bounded input bytes or **N** borrowed input APIs. **Planned**: Swift editor/input values and encoding temporaries are not erased by changing outgoing JSON. |
| S04 | PageModel `tabs`, `openFiles`, `ledgerEntries`, `activeCut` | **N** reduced cached fields, **W** unavoidable content owners. **Planned**: current retained models remain after decoding. |
| S05 | PageModel `storages: [UInt64: NSTextStorage]`, `quietRenderings` | **N** smaller/shorter-lived projections; **W** only where ownership permits. **Blocked** on AppKit/editor architecture for erasure; ordinary text/attributed-string rendering storage remains. Removing cache entries is not byte wiping. |
| S06 | PageModel `fileTextSnapshot`, `noteText` (`+=`) | **N** direct comparison/projection or **W** exact owned bytes. **Planned**: growing Swift strings remain. |
| S07 | PageModel `composeSelection` / `[SealedFragment]` | **N** core-side range composition, **W** result owner. **Planned** for retained Swift fragments; F25's core composition output alone does not remove them. |
| S08 | `ChipAttachment.info`, `SealedBlockCell.info` | **N** identifiers/on-demand display fields. **Planned**: retained ChipInfo copies still include excerpt/name. |
| S09 | `SealedFragmentPasteboard` envelope Data and plainText on NSPasteboardItem | **N** intentional requested representations only, **W** application-side byte owner. **Partial/Blocked**: type filtering exists; Swift Data/String and AppKit copies are not zeroized. |

## Pinned dependency inspection

Versions below are from [`Cargo.lock`](../../Cargo.lock). Files were read in the
local Cargo registry `index.crates.io-1949cf8c6b5b557f`; paths below begin at the
named crate directory. These are source observations, not accepted product
promises or an exhaustive allocator trace.

### serde_json 1.0.150: escaped input remains a software blocker

- `src/de.rs:31–62`: Deserializer owns `scratch: Vec<u8>`, initialized with
  `Vec::new()`. String decoding clears its length and passes it to `parse_str`
  (`1427–1431`); no zeroizing destructor was found in the inspected source.
- `src/read.rs:494–535`: SliceRead borrows unescaped input when possible, but
  escapes append to scratch with `extend_from_slice`; `parse_escape`
  (`874–890`) pushes decoded bytes. Unicode handling calls `reserve(4)`
  (`978–984`). Growth can release earlier plaintext allocations unwiped.
- A visitor receiving `&str`, a `Cow`, or a final `Zeroizing<String>` does not
  replace the parser's scratch owner. This applies to fragment/ops parsing and
  escaped inbound base64 envelopes. Tests accepting escaped input demonstrate
  functionality, not scratch erasure. Planned resolution: a reviewed wiping
  parser/dependency change or a narrower non-JSON content-input representation.

### Loro 1.13.9: final export wrapping is insufficient

- `loro-internal-1.13.9/src/arena.rs:55–79,369–385` stores strings through shared
  `Arc<Mutex<StrArena>>`; `src/arena/str_arena.rs:9–12,51–78` appends text into
  `append_only_bytes::AppendOnlyBytes`.
- Locked transitive dependency `append-only-bytes-0.1.12/src/lib.rs:132–176`
  reserves by allocating a larger block and copying the existing bytes.
  `src/raw_bytes.rs:11–17` frees the old block with
  `Vec::from_raw_parts(self.ptr, 0, self.capacity)` and no wipe. Shared slices
  can prolong the old block's lifetime. This is confirmed non-wiping growth,
  not merely unverified behavior inside Loro.
- `loro-internal-1.13.9/src/container/richtext/richtext_state.rs:2055–2080`
  builds a text projection with `String::new()` and `push_str`.
  `src/lib.rs:177–183` commits/stops on final LoroDoc drop; it does not add a
  content wipe.
- `src/encoding.rs:375–386` pre-sizes the outer fast snapshot result using
  `encoded_len`. In contrast, `399–413,448–465` starts update encoding with
  `MIN_HEADER_SIZE` capacity and writes the body into an ordinary vector.
  Snapshot pre-sizing does not establish zeroizing intermediate scratch in
  `encode_snapshot_inner`; the encoding graph was not exhaustively traced.
- `loro-common-1.13.1/src/value.rs:49–69` uses `Arc<String>` for string values.
  `src/internal_string.rs:117–123,217–251` also has a global string-intern set
  with shared boxed strings and reference-count-based removal, not wiping.
  Reachability of each page field into that intern set is not fully traced;
  it must not be described as either universally used for ink or proven absent.
  Short InternalString values also use inline bytes. A document-level drop test
  alone cannot establish erasure across shared, inline and static allocations.

Planned resolution for C01/C29 requires dependency-level changes or a reviewed
alternative to the current representation, including history, forks, import,
projection and export temporaries. Hardware pasteboard testing cannot answer
these allocation questions.

### objc2-foundation 0.3.2: bridge copy confirmed, OS lifetime unverified

- `src/string.rs:105–140` documents NSString::from_str as copying and sends
  `initWithBytes:length:encoding:` with the Rust slice pointer.
- `src/data.rs:38–42` calls `initWithBytes:length:` for NSData::with_bytes;
  `src/generated/NSData.rs:537–546` binds that initializer, separately from
  `initWithBytesNoCopy:length:`. The installed macOS 27.0 SDK's
  `Foundation.framework/Headers/NSData.h:301–304` describes its bytes as copied
  from the supplied buffer. The adapter does not transfer its zeroizing Rust
  owner into the Objective-C object or install a wiping deallocator.
- `pasteboard/src/macos.rs::write_content` uses these constructors for both
  system pasteboard and drag targets; reads use `.to_string()` / `.to_vec()`.
  Source inspection confirms a separate bridge object and application read
  copies. The exact OS backing allocation, autorelease timing, internal copies,
  pasteboard-server retention, and behavior after `clearContents` were not
  inspected or measured. No system-storage erasure conclusion follows.

## Tests and validation limits

The following tests exist in the inspected source. They check the named
behavior, not every allocation in the process.

| Source | Tests / observation |
| --- | --- |
| `core/src/document.rs`, `sheet.rs` | `projected_ink_coalesces_marked_pieces_at_exact_capacity`, `segment_ink_and_its_clone_have_independent_wiping_owners`: exact coalescing, clone independence and live-allocation wipe. `doc_run_debug_output_never_prints_its_ink`, `segment_debug_output_never_prints_its_ink`: redacted `Debug` (C48). |
| `core/src/ink.rs`, `files.rs` | `text_projection_is_exact_and_zeroizing_including_sentinels`, `normalization_and_file_projections_are_exact_zeroizing_text`: zeroizing result types, exact capacity, Unicode/sentinels and mixed newlines. |
| `core/src/store.rs` | `simulated_ink_uses_one_reserved_wiping_allocation`, `a_late_surrogate_refusal_leaves_the_document_unchanged`: stable allocation through inserts, overflow refusal, code-unit wipe and atomic late refusal. `an_insert_past_the_reserved_room_panics_in_tests_and_refuses_in_release`, `a_chip_past_the_reserved_room_panics_in_tests_and_refuses_in_release`: an accounting drift in `apply_ops` trips a `debug_assert!` under test and refuses without growing in release. |
| `ffi/src/content_json.rs` | `exact_nul_encoding_matches_serde_and_wipes_the_live_allocation`: empty/escaped/Unicode/large output, terminal NUL, explicit live-allocation wipe; not post-free memory inspection. |
| `ffi/src/content_json.rs` | `chip_and_cut_fields_match_the_previous_sorted_json_bytes`, `copied_envelope_stays_a_string_with_the_same_lossy_utf8_semantics`: projection shape and fallback behavior. |
| `ffi/src/content_json.rs` | `raw_transfer_and_reconstruction_use_the_same_pointer_and_full_slice_length`, `ordinary_strings_share_the_exact_box_layout_and_free_path`: ownership layout, null and ordinary-string path. |
| `ffi/src/content_json.rs` | `every_buffer_has_room_for_its_terminal_nul`, `free_takes_back_only_what_this_module_handed_out`: no empty buffer; static version pointers, a `CString::into_raw` pointer and an interior pointer survive a free; a buffer is taken back once. `a_poisoned_registry_still_hands_out_and_takes_back`: a poisoned lock refuses neither. |
| `ffi/src/content_json.rs` | `errors_and_size_drift_return_null_instead_of_transferring_a_partial_buffer`: first/second-pass errors and both directions of length drift. |
| `ffi/src/lib.rs` | `content_routes_preserve_escaped_text_and_sorted_json_shapes`, `tab_projection_matches_the_previous_json_bytes_for_each_label_source`. |
| `ffi/src/files.rs` | `file_runs_match_previous_json_bytes_for_empty_escaped_and_large_text`. |
| `sync/src/secret_json.rs` | `escaped_json_matches_serde_at_exact_capacity`, `both_directions_of_size_drift_are_errors`, `errors_in_either_pass_are_returned`, `count_refuses_overflow`. |
| `sync/src/envelope.rs` | `blob_clones_are_independent_zeroizing_owners_with_redacted_debug`, `escaped_fields_and_base64_still_decode`, `invalid_base64_and_truncated_envelopes_are_refused`, `every_variant_round_trips`. |
| `sync/src/b64.rs`, `pad.rs` | `zeroizing_buffers_match_public_encoding_across_chunk_boundaries`, `round_trips_and_pads_to_the_bucket`, `a_buffer_of_the_wrong_size_is_refused_not_overrun`. |
| `ffi/src/sync_session.rs` | `withdrawn_ops_leave_the_page_s_expiry_and_every_other_page_queued`, `withdrawal_after_a_partial_seal_failure_publishes_only_the_surviving_ops`, `a_refused_seal_keeps_the_queue_for_the_next_tick`, `sealed_blobs_reach_the_wire_in_power_of_two_buckets`. |

**Executed here:** the initial documentation pass ran 51 sync library tests and
13 distinct focused FFI tests before `09901309`. This update ran each of the
six core tests above with `cargo test -p companion-core --all-features --lib`
and its test-name filter; all six passed after `09901309`.

**Swift source-inspected; results parent-reported:**
[ContentJSONDecodingTests.swift](../../shell/Tests/CompanionKitTests/ContentJSONDecodingTests.swift)
has seven tests covering nil, success, malformed/type-mismatched input, invalid
UTF-8, injected failure, long escaped Unicode with pointer alias during decode,
and real FFI release. Parent reports **7 passed**, included in **221 focused
Swift tests passed** with filters `ContentJSONDecodingTests`,
`CompanionClientTests`, `SealedObjectSeamTests`, `SealedFragmentSeamTests`,
`SealedNoteTests`, `FileDocumentTests`, `FileAccessTests`, and
`PersistenceRoundTripTests`. Pointer alias at the injected decoder does not
prove JSONDecoder internals avoid copies or decoded Strings are erased.

**PR 270 review round:** the suite gained
`testRustFreeLeavesStaticAndForeignStringsAlone` and
`testOnlyTheTwoOwnedHelpersReleaseCoreStrings`, nine tests in all. Each
crate's tests and clippy ran on the touched crates, `cargo test -p
companion-ffi` with and without `test-util`, and the focused Swift suites
`ContentJSONDecodingTests`, `CompanionClientTests`,
`CompanionClientLanguageDetectionTests`, `FileAccessTests`,
`SyncCeremonyTests` and `SyncOffSwitchTests` against a fresh test-util core.
The full gate for this round is left to CI on the pushed branch.

**Final gate at `fe03c8cb`:** all commands below passed after the Rust and Swift
changes were committed:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --quiet
cargo test --workspace --features test-util --quiet
scripts/build-core.sh --test-util
swift build --package-path shell
swift test --package-path shell
```

The test-util run included 576 core, 340 FFI and 51 sync tests. The Swift
CompanionKit suite ran 1,631 tests with zero failures; the OnetimePad suite also
passed. Both Rust configurations left the existing credential test
`data_protection_items_are_invisible_to_the_login_keychain` ignored. Tests use
in-memory credential/pasteboard and relay seams where specified; they do not
validate a deployed relay, installed-app entitlements, real-pointer alternate
placements, system-storage erasure, or allocator-wide wipe instrumentation.

## Known tradeoffs

**Each content route serializes twice.** `companion_sheet_document_json`,
`companion_tabs_json`, `companion_file_runs_json` and `companion_ledger_json`
run on UI refresh. `content_json::encode` walks the value once into a byte
counter and once into the fixed buffer, so serde_json escapes every string of
the document body twice, and a third scan over the output looks for an
interior NUL. The single pass it replaced walked once, but grew a `String` and
built `serde_json::Value` copies of the content, each growth leaving an
unwiped allocation behind. This change accepts the extra walks for the fixed
destination. No refresh has been measured; if a profile shows the counting
pass, caching the length per document revision is one option to evaluate.
`DeltaEnvelope::encode` (C35) makes the same trade on each queued envelope.

## Remaining blockers for #256 and Law 0004

B4's explicit Swift boundary validation is resolved by source inspection and
the parent-reported focused results; it is no longer a blocker. C02–C05, C07
and C06 normalization are implemented; C06's FFI reader remains unresolved.
C13–C16 are implemented (2026-10-21): the derived title, the tab name, the
tab label and the ledger title are wiping owners. C31 is implemented
(2026-10-21): the restore copies names and notes into wiping owners, and a
restored note makes no Loro document until its first edit. C17 is implemented
(2026-10-21): the pasteboard origin, the origin message and a block's origin
are wiping owners; Loro's and Foundation's copies of them remain.

1. **B1 — remaining core ownership:** implement and test C08–C10,
   C19–C21 and C27: parser/refusal cleanup, resident excerpt/name
   copies and fragment wire names. Also restrict or return a
   wiping owner from `OpenFile::bytes_to_write`; current in-tree callers are tests.
2. **B2 — dependency storage and parsing:** resolve C01/C29 and escaped-string
   scratch in C08/C21/C34/C41. Review Loro shared/static/inline storage and its
   whole import/export allocation graph. Wrapping returned allocations is not
   sufficient; these are software/source questions, not hardware checks.
3. **B3 — input, refusal and bridge owners:** fix C06's FFI reader, C45/C47,
   lossy fallback
   construction in F08/C46, and review AppKit/Swift residence S01/S03–S09.
   A narrower payload may remove individual copies; no accepted exception for
   the remaining copies is created here. Ceremony SAS intermediates F20 also
   need dedicated secret handling.
4. **B5 — outstanding law evidence:** transport growth/drop wipe instrumentation,
   key-file read growth/error handling, and regression tests for every planned
   owner remain outstanding. Existing byte/capacity tests are not allocator
   erasure tests. See the law's contract rows.
5. **B6 — machine checks:** actual pasteboard/drag delivery, refusal/clear races,
   and deployed macOS behavior still need observation. Such checks can reveal
   behavior but cannot establish erasure of all Foundation/system copies.

## Existing idioms: inventory Table 3

These are implementation options, not evidence that every caller conforms.
Paths are relative to `crates/`.

| ID | Inventory idiom / inspected sites | Disposition and status |
| --- | --- | --- |
| I01 | Custom `SecretBuffer` Drop (`core/src/secret.rs`) | **W — implemented** for its fixed allocation; spare capacity included. C12 describes page-lock limits. |
| I02 | Two-pass Sizer/Writer/Counter/ByteCounter (`core/src/persist.rs`, `fragment.rs`, `file_persist.rs`; `ots-client/src/api.rs`) | **Z + W — implemented** final output. Source/intermediate owners still need independent review. |
| I03 | Known-size `NAME=`, sheet payload, fragment public text, seal work, ink projection (`core/src/store.rs`, `fragment.rs`, `ink.rs`, `files.rs`; `ffi/src/persist.rs`) | **W — implemented** named output/projection owners, including C04/C05 after `09901309`. Upstream dependency construction remains separate. |
| I04 | `read_wiping` (`transport/src/lib.rs`) | **W — implemented** growth strategy; allocator-level wipe instrumentation remains B5. |
| I05 | Explicit temporary `.zeroize()` (`ffi/src/lib.rs`, `sync_driver.rs`; `ots-client/src/api.rs`) | **W — partial** path-local cleanup. It does not erase an earlier released allocation or a clone. |
| I06 | Deserialize into `Zeroizing<String>` (`sync/src/oauth.rs`) | **W — partial**: final field owner, not serde_json scratch. |
| I07 | Exact form encoder (`sync/src/oauth.rs`) | **W — implemented** zeroizing form output. |
| I08 | In-place decrypt and truncate (`ffi/src/persist.rs`) | **W — implemented** plaintext result owner; downstream restored names and notes are C31's, implemented 2026-10-21, and a restored note's document after its first edit is C01's. |
| I09 | Fixed zeroizing read chunk (`transport/src/lib.rs`, `ffi/src/files.rs`) | **W — implemented** chunk/probe owners, not a zeroizing whole-file reader (C06). |
| I10 | `panic = "unwind"` (`Cargo.toml`) | **W — implemented** normal unwind cleanup support, not a buffer owner or evidence of cleanup after abort, kill or power loss. |

These idioms do not resolve hidden dependency scratch by themselves. The
workspace uses zeroize 1.9.0 from the lockfile, without `zeroize_derive`; core,
credentials, ffi, ots-client, pasteboard, sync and transport use it, while
language-detection-policy does not.

## Software work versus checks at the machine

Software review/tests can determine growth strategy, ownership, serialization
shape, refusal cleanup, parser scratch, dependency/static allocation behavior,
and exactly-once FFI release. These do not need a person operating the UI.

A person at the machine can exercise pasteboard and drag consumers, inspect
advertised types/markers, observe change-count clearing and competing writes,
check behavior on the deployed macOS version, and inspect memory-lock failures
under the actual limits. This pass did not perform those checks. UI success,
clipboard clearing, and a clean memory snapshot do not prove absence of earlier
copies, swap/compression artifacts, screenshots, window-server storage, or
other-process retention. Those OS details remain unverified rather than being
used to waive the remaining software blockers.
