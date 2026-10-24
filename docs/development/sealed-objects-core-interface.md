---
# docs/development/sealed-objects-core-interface.md
---

# Sealed objects: the core interface

A map for whoever next touches a sealed object's name, note, fragment,
detached store or decrypted drag in code: the C entry points, the JSON
they answer, the bytes at rest, the type name and the shell's predicates
and constants. The behaviour is [Law 0001](../law/0001-sealed-object.md)'s
and, for the name's field, [Law 0007](../law/0007-edit-in-place.md)'s. The
decisions were accepted 2026-10-16:
[ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
[ADR-0043](../adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md),
[ADR-0044](../adr/0044-a-sealed-objects-note-is-edited-on-the-pages-own-surface.md),
[ADR-0045](../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md),
[ADR-0046](../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md)
and
[ADR-0047](../adr/0047-name-value-copies-the-value-unquoted.md).
The looks and words are in the
[sealed row, note and handles](../spec/feature/sealed-content/sealed-row-note-and-handles.md)
spec.

A record whose value is on another device, a name's version, the
metadata a peer learns and a note's shared history (issue #257) follow
proposed
[ADR-0058](../adr/0058-a-sealed-object-never-stalls-a-pages-sync.md),
which is not accepted; the parts below that cite it map the code, not
an accepted decision.

These notes were first written into the drafts ADR-0043 to ADR-0054 of
2026-10-13, withdrawn on 2026-10-14 without ratification.
Where this file and the code disagree, the code is right and this file
is fixed.

## The pieces, and where they live

```
crates/core/src/sheet.rs      SealedChip (availability, name, note),
                              Availability, PeerKind, judge_name, NAME_CAP,
                              Sheet::is_due
crates/core/src/note.rs       the note's own document and undo, its sync
                              routes and their waiting cache
crates/core/src/metadata.rs   NameVersion, ObjectMetadata, the metadata
                              routes and their waiting cache
crates/core/src/frame.rs      the key frame, OTSFRM02
crates/core/src/store.rs      set_chip_name, copy_out_name_value, the note's
                              routes, readable_sheets, chip_stands, a peer's
                              batch admitted (admit), take_restated_pages
crates/core/src/fragment.rs   the envelope and the public text, VERSION,
                              ENVELOPE_CAP, REFERENCE_CAP, EnvelopeCap
crates/core/src/transfer.rs   cut, paste, the slot, the drags, resolution,
                              the transaction
crates/core/src/persist.rs    OTSSNAP5, the chip record's availability tag,
                              the chip and page records' trailing fields,
                              the ledger's destination tags
crates/ffi/src/lib.rs         the C entry points below, placed_json
crates/ffi/src/content_json.rs  chip_face
crates/pasteboard/src/macos.rs  SystemDragItem, the decrypted drag's write

shell/Sources/CompanionKit/CompanionClient.swift  the wrappers, the type name
shell/Sources/CompanionKit/PageModel.swift        InkDocument, the routes by
                                                  document, boardHoldsOwnCopy
shell/Sources/CompanionKit/InkEditorView.swift    makeSurface, answersChords,
                                                  CodeLanguageChoice,
                                                  SealedBlockCell
shell/Sources/CompanionKit/SealedBlockLayout.swift  the row's zones and the
                                                  handle's clearances
shell/Sources/CompanionKit/SealedNotePopover.swift  NotePopoverLayout
shell/Sources/CompanionKit/DecryptedDrag.swift    the drag's source and its
                                                  data provider
```

## The name

`judge_name` (`sheet.rs`) is the one rule. It trims a draft. An empty
draft clears the name; any other must be at most `NAME_CAP` (64)
characters of `[A-Za-z_][A-Za-z0-9_]*`, the charset checked first, or it
is refused whole and the name stands.

| Entry point | Answer |
| --- | --- |
| `companion_chip_name_refusal(draft) -> u32` | judges a draft without a handle: 0 takes it, an empty draft clearing; 1 is longer than 64 characters; 2 is outside the charset; null and non-UTF-8 answer 2 |
| `companion_chip_set_name(handle, chip, name) -> bool` | false for an unknown chip, a page past its deadline, a refused draft or a spent version, the name then unchanged |

Each write takes a version, `NameVersion` in `metadata.rs`: a counter
one more than the highest known for that name, then the writing
device's fingerprint, 32 bytes, compared in that order
(`name_versions_order_by_counter_then_writer_bytes`,
`a_local_rename_after_a_received_higher_counter_takes_one_more`). A
clear is a versioned empty name
(`a_clear_beats_an_older_name_and_loses_to_a_newer_one`), a rename to
the name already set takes no version (code reading), and a counter
that cannot grow refuses the rename and nothing else
(`NameRefusal::VersionsSpent`,
`a_spent_version_refuses_the_rename_and_nothing_else`). A name restored
from `OTSSNAP4` has no version and compares as counter 0 under this
device's writer
(`a_name_from_before_versions_restates_at_counter_zero_and_any_rename_passes_it`).
The writer is zero until `companion_sync_configure` sets it from the
identity at rest, minting none, or `ensure_engine` from the engine's
(`lib.rs`
`configuring_sync_names_the_identity_at_rest_as_the_name_writer_and_mints_none`,
`sync_driver.rs` `starting_the_engine_names_the_device_as_the_name_writer`).

The shell owns the words for each code, so a field can say why a draft
will not take while it is typed. It marks the page dirty after a name is
set or a note edited, as after any mutation
(`SealedNameFieldTests.testANameOrANoteEditArmsAWriteAndARefusalArmsNone`).

## The note's routes

The note is the document type a page's body and an open file use, holding
ink alone. Since 2026-10-21 (issue #256) a note made by a restore, a paste
or a clone is its text alone until it accepts a batch that changes that
text, which makes that document (At rest, below). Its routes are keyed by
chip id, as a file has its own:

- `companion_chip_note_runs_json`: `[]` without a note, else
  `[{"ink": text}]`; null for an unknown chip or a page past its deadline.
- `companion_chip_note_apply_ops_with_intent`,
  `companion_chip_note_finish_editing_group`.
- `companion_chip_note_can_undo`, `companion_chip_note_can_redo`,
  `companion_chip_note_undo_action_name`,
  `companion_chip_note_redo_action_name`.
- `companion_chip_note_undo`, `companion_chip_note_redo`, which answer the
  file routes' `StepOutcome`.

Page routes take no chip id and note routes no page id. A chip id is a
counter that overlaps page ids, so a note's edit sent on a page route
would write some page's ink. The shell's `InkDocument` is `.sheet(id)` for
a page or a file and `.note(chip:)` for a note, and `PageModel` answers a
note on the note's routes and never on a page's.

A note exists from its first accepted edit, or from a restore, a paste or
a clone that brings its text (issue #256 since 2026-10-21: such a note
rests as its text until an edit). `has_note` is true while it has a
character that is not whitespace
(`store.rs` `a_note_of_only_whitespace_opens_no_doorway`).

Since issue #257 a note's history is shared with its peers (proposed
ADR-0058 point 6: "A note is a Loro text with a history of its own.").
Its sync routes are the store's own, in `note.rs`, keyed by page and the
object's identity rather than a chip id, and no C entry point reaches
them:

- `notes_on(page)`: each record on the page, attached and detached,
  that has a note.
- `note_version(page, object)`: the note's version, opaque bytes; it
  takes `&mut self`, since a note with no operation log has no version
  until its document is made.
- `export_note_updates(page, object, since)`: the note's operations past
  `since`, plaintext for the seam to seal.
- `apply_remote_note_update(page, object, bytes)`: merges a peer's batch
  into the note on the page with that cross-device identity, never its
  body, roster or ledger, a record with no note taking an empty one
  first, and leaves the note's own undo steps as they were. With no
  record on that page, it merges into the object's records on this
  device's other readable pages. It refuses `Malformed` (an empty batch
  included), `MissingHistory`, `NestedObject`, a batch that would stand
  a sealed object in the note, and `UnrelatedHistory`, a batch that
  builds on none of a note's history while the note has text (a note
  restored from its text alone takes one whose text equals its own),
  each leaving the note as it was.

A note's history is shared once any of it has been exported or a
peer's batch or key frame has reached it. Only a shared note writes its
log at rest; one no other device has seen restores from its text alone
(`a_note_no_other_device_has_seen_persists_no_log_and_a_shared_one_persists_its_own`).

Past its deadline a page gives and takes no note
(`a_page_past_its_deadline_gives_no_note_and_takes_none`). A batch for
an identity with no record here waits in `note_pending` (`PendingNotes`),
at most 256 batches (`PENDING_NOTE_BATCHES`) and 256 KiB
(`PENDING_NOTE_BYTES`), the oldest going first, one batch past the byte
bound alone not kept, until the identity's record arrives on any page;
a page's end drops what was held for it (code reading). A page's
compaction keeps a shared note's history whole and rests a note no
other device has seen as its text alone, with no log
(`a_pages_compaction_sheds_only_a_history_no_other_device_has_seen`);
a ceremony rebuilds each standing record's note under a fresh peer id
for the key frame. When a value moves into a standing record, the two
notes merge if their histories share a base (`Note::merge_shared`), and
otherwise the standing note stays. A clone's note starts a history of
its own. Tests in `note.rs`:
`two_devices_editing_one_note_converge_in_either_delivery_order`,
`a_peers_note_edit_leaves_the_local_steps_as_they_were`,
`missing_history_and_bad_bytes_are_refused_and_leave_the_note_as_it_was`,
`a_note_batch_standing_an_object_is_refused_and_moves_nothing`,
`a_note_batch_before_its_record_waits_and_applies_when_it_arrives`,
`the_waiting_cache_evicts_its_oldest_past_256_kib`,
`compaction_sheds_deleted_note_text_under_a_fresh_peer`,
`a_detached_records_note_keeps_its_history_through_its_pages_compaction`,
`a_value_moving_onto_a_record_whose_note_shares_its_base_merges_both_sides`,
`a_value_moving_onto_a_record_with_no_shared_base_keeps_the_standing_note_once`,
`a_clones_note_starts_a_history_of_its_own`,
`a_note_edit_sent_for_the_page_an_object_left_reaches_it_where_it_moved`,
`a_note_batch_held_for_one_page_drains_when_its_object_arrives_on_another`,
`an_empty_note_batch_is_refused_and_nothing_waits`,
`the_waiting_cache_keeps_at_most_256_batches_however_small`,
`a_note_back_from_a_page_that_compacted_never_shows_its_text_twice`,
`a_batch_building_on_none_of_a_notes_history_is_refused_and_leaves_the_note`,
`a_note_restored_from_its_text_alone_takes_a_batch_spelling_it_and_refuses_another`.

## What the shell receives

The chip face (`chip_face` in `content_json.rs`), which the seal routes
and `companion_sheet_document_json` both send, has `available` (false
when the value is on another device), `chip_id`, `kind` (`text` or
`image`, or `unknown` for a record with no value not yet told),
`excerpt` (empty for a record with no value), `size_label` (its told
size class, or empty), `concealed`, `name` (a string or null) and
`has_note` (`lib.rs`
`a_record_with_no_value_crosses_as_a_face_alone_and_every_value_route_refuses_it`).
Swift reads them as `ChipInfo`, whose `available` reads true when the
field is absent.

The note's text crosses only through `companion_chip_note_runs_json`. No
summary, meta, blocks or ledger output carries the name or the note, and
neither conceal payload, one chip's or a whole page's, includes them
(`lib.rs` `a_name_and_a_note_reach_no_ledger_record_and_no_other_output`,
`store.rs` `a_name_and_a_note_are_never_payload`).

## A record with no value

Proposed ADR-0058 point 1: "A batch or key frame that stands an
identity the page does not own creates a record with no value for it
before the page settles." `SealedChip.availability` (`sheet.rs`) is
`Availability::Local(LocalValue)`, the bytes, their meta, the excerpt,
the size label and any conceal receipt, or `Availability::Peer { kind,
size }`, each `None` until the device with the value tells it (Metadata,
below). For a peer record `meta()` is `None`, `excerpt()` is empty,
`size_label()` is the told size class or empty, and `duplicate()` is
`None`, so nothing clones it.

For each identity a batch or key frame stands that the page lacks,
`apply_remote_update` and `adopt_key_frame` move in the record another
page here keeps detached, or else stand a record with no value, and
take out a standing whose end this device's ledger records
(`store.rs` `a_remote_chip_the_page_does_not_own_admits_as_a_record_with_no_value`,
`a_key_frame_standing_an_unknown_identity_admits_a_record_with_no_value`,
`a_burned_identity_a_peer_stands_again_is_taken_out_and_the_peer_converges`).
A value whose record detaches, or whose page ends, while a record with
no value for it stands on another page here moves into that record,
under the standing record's chip id
(`a_source_page_that_ends_leaves_its_value_on_the_page_that_stands_it`,
`a_value_standing_on_two_other_pages_moves_to_the_first_in_page_order_only`);
`moved_chips` maps the value's old id to that one for `record_sent` and
`mark_chip_concealed` alone, at most 64 entries, never persisted
(`a_moved_id_follows_every_move_until_64_newer_push_it_out`,
`a_restore_forgets_moved_ids_since_it_mints_chip_ids_afresh`). A page
these moves change, other than the one the route names, is listed for
`companion_take_restated_pages_json`, which the shell drains at the top
of each refresh
(`lib.rs` `a_page_another_page_s_edit_or_burn_restated_is_drained_once_over_the_seam`).

The routes that refuse it, writing and recording nothing:

| Route | Refusal |
| --- | --- |
| `companion_chip_copy_out`, `companion_chip_copy_name_value`, `companion_chip_provide_drag` | false |
| `companion_chip_conceal` | `{"ok": false, "error": "this chip's value is on another device"}` |
| `companion_sheet_conceal` | while one stands in the body, `PayloadError::ValueElsewhere` as the error, `an object on this page has its value on another device`; a detached one does not stop it |
| `companion_chip_delete` | false, attached or detached, the page's undo kept |
| `SheetStore::record_sent` (clipboard, one-time link, drag), `mark_chip_concealed`, `chip_payload` | false or `None` |

Tests: `store.rs`
`every_value_route_refuses_a_record_whose_value_is_elsewhere_and_records_nothing`,
`the_page_conceal_refuses_while_a_record_with_no_value_stands_and_not_once_it_detaches`,
`a_burn_of_a_record_whose_value_is_elsewhere_is_refused_and_records_nothing`;
`lib.rs`
`a_record_with_no_value_crosses_as_a_face_alone_and_every_value_route_refuses_it`.
A rename, the note, a move, a cut, the cut's first paste and a removal
take it by identity (`store.rs` `a_record_with_no_value_takes_a_name_and_a_note`;
`transfer.rs` `a_cut_and_its_first_paste_keep_a_record_with_no_value_by_identity`,
`a_drag_moves_a_record_with_no_value_keeping_its_identity_inside_a_page_and_between_pages`).
A paste after a copy, a later paste of a cut and an ⌥ drag place
`[sealed content · unavailable]` and count it in the placed JSON's
`elsewhere`, beside `unavailable` and never inside it
(`a_paste_after_copy_places_unavailable_for_a_record_with_no_value_and_counts_elsewhere`,
`a_later_paste_of_a_cut_places_unavailable_for_a_record_with_no_value`,
`an_option_drag_places_unavailable_for_a_record_with_no_value`). A page
whose end takes one records no `expired` or `discarded` for it
(`a_record_with_no_value_ends_with_its_page_and_leaves_no_record_of_its_own`).

`companion_test_stand_peer_record(handle, sheet, pos_u16, kind, size,
of_chip)` stands one for the Swift tests, under the identity `of_chip`
stands or a fresh one for 0. It is `test-util` only
([ADR-0018](../adr/0018-test-seams-compiled-out-of-release.md)),
so the seam checks in `scripts/package-app.sh` and
`scripts/verify-release-core.sh` name it.

## Metadata

`metadata.rs` keeps what a peer learns of an object beside the page's
ops (proposed ADR-0058 point 5: "A `Metadata` envelope beside the
page's `Ops`, under the same seal, padding and epoch, names each changed
object's identity, kind, size class and name."). `ObjectMetadata` is the
identity, the kind and size class when known, and the name with its
version, a clear being a versioned `None`; its `Debug` prints no name
(`no_payload_marker_reaches_a_metadata_debug`). The sync driver alone
calls these routes, and no C entry point reaches them.

| Route | What it does |
| --- | --- |
| `set_writer`, `writer` | this device's fingerprint, the writer of its name versions; setting it gives every version written with the zero writer before sync started this writer and marks its object changed (`names_written_before_a_writer_was_set_converge_once_each_device_sets_one`) |
| `take_metadata_changes(page)` | drains the objects whose metadata changed on the page, as they stand now |
| `all_metadata(page)` | every record on the page, attached and detached, for a restate |
| `mark_metadata_dirty(page, objects)` | marks objects changed again, as a send that failed to encode leaves them |
| `apply_object_metadata(page, entries)` | applies a peer's entries to the page with that cross-device identity and answers how many changed a record |

A seal, a rename and a clone mark their page changed; a restore and an
applied entry mark nothing
(`a_seal_a_rename_and_a_clone_mark_their_page_and_a_restore_marks_nothing`,
`an_applied_entry_marks_nothing_changed`,
`taking_changes_drains_them_and_a_second_take_is_empty`,
`a_restate_lists_detached_records_too`). An applied entry fills a
record with no value's kind or size class once and never a record's
with its value; its name wins by the greater version, and equal
versions keep the local name; a name the rule refuses is skipped and
the rest of its entry applies
(`kind_and_size_fill_a_record_with_no_value_once_and_never_flip`,
`a_record_with_its_value_ignores_a_received_kind_and_size`,
`concurrent_renames_converge_in_both_delivery_orders`,
`equal_versions_with_different_names_keep_the_local_one`,
`an_invalid_received_name_is_skipped_and_the_rest_of_its_entry_applies`).
Past its deadline a page gives and takes none
(`a_page_past_its_deadline_gives_and_takes_no_metadata`). An entry for
an object with no record on its page applies to the object's records on
this device's other readable pages
(`a_rename_sent_for_the_page_an_object_left_reaches_it_where_it_moved`).
One for an identity with no record here waits in `metadata_pending`,
folded into any entry held for the object, the oldest going past 256
(`PENDING_CAP`), until the identity's record arrives on any page
(`an_entry_held_for_one_page_drains_when_its_object_arrives_on_another`);
an entry for a page not held here is not kept, and a page's end drops
what was held for it and what changed
(`an_entry_before_its_sentinel_waits_and_applies_when_the_record_arrives`,
`the_waiting_cache_evicts_its_oldest_past_256`,
`an_entry_for_a_page_with_no_sheet_here_is_not_held`,
`a_held_entry_goes_when_its_page_ends`,
`a_changed_entry_goes_when_its_page_ends`). A record about to drop
folds a newer name into the record standing its identity
(`a_value_that_follows_keeps_the_newer_name_its_stand_in_learned`).
The changed set, the waiting cache and the restated pages are never
persisted.

## `NAME=value`

`companion_chip_copy_name_value(handle, chip) -> bool`. The store
composes the name, `=` and the payload in one zeroizing buffer allocated
at its final size (draft [Law 0004](../law/0004-secret-plaintext-never-reallocates.md)),
and refuses an unnamed chip, an image chip, an unknown chip and a page
past its deadline. It shares copy decrypted's steps with
`companion_chip_copy_out`: retire the last receipt, write transient and
concealed, keep the receipt for the guarded clear, and record one `sent`
to the clipboard at the payload's size class. The composed bytes never
cross the FFI. The shell's `SealedBlockLayout.copiesNameValue(kind:)`
says which kinds the core composes for, and the `=` zone and the menu
item follow it.

## The fragment

### Envelope, version 1

UTF-8 JSON, composed and parsed only in `fragment.rs`:

```json
{"version":1,"cut":"<uuid>","nodes":[{"ink":"text"},{"ref":{"uuid":"<uuid>","name":"API_KEY","note":"text"}}]}
```

- `cut` appears only on a cut's fragment and names that cut.
- `name` and `note` appear only when the object has them.
- Nodes keep the selection's order.
- Another version, an unknown key, a malformed UUID or bytes that are not
  UTF-8 make the envelope unreadable.
- It is encoded twice, sized then written, into a buffer of its final
  size.

The caps: `ENVELOPE_CAP` is twice `FILE_SIZE_LIMIT` (`files.rs`, 4 MiB),
8 MiB or 8388608 bytes, which leaves room for JSON's escapes over a page
that large; `REFERENCE_CAP` is 1024. `EnvelopeCap::passed` is the one
check. The parse checks the length before it reads the bytes, and the
references and a repeated object as it reads the nodes, before anything
resolves. Copy and cut measure the envelope they would write with the
same check, the length from the sizing pass's count before the buffer
exists, a cut's with its `cut` field.

### Entry points

| Entry point | What it does | Answer |
| --- | --- | --- |
| `companion_sheet_copy_fragment(handle, sheet, at_utf16, len_utf16)` | copies a UTF-16 range | `{"envelope": string or null, "plain": string}`; past a cap `{"error": "tooLarge", "limit": 8388608}` or `{"error": "tooManyObjects", "limit": 1024}`; null for a file id, an unknown page, a page past its deadline or a bad range |
| `companion_sheet_cut_fragment` | as the copy, then deletes the range as one undo step, its objects detaching as the active cut | as the copy; a refusal changes nothing |
| `companion_sheet_compose_fragment(handle, sheet, shown)` | composes runs the shell shows of a page, a preview's rendered text between its objects and each object by chip id, in the synced document's JSON shape (`[{"ink": "…"}, {"chip": 7}, …]`); the shown text is the ink | as the copy; null also for an object off the page or `shown` that does not parse |
| `companion_sheet_paste_fragment(handle, sheet, at_utf16, len_utf16, envelope, envelope_len, plain)` | pastes envelope bytes over a range as one undo step, `plain` placed for an envelope the core cannot read | the placed JSON, or null on refusal |
| `companion_sheet_paste_active_cut` | the clipboard slot's place over a range | the placed JSON; null when no cut stands, or as the paste |
| `companion_sheet_move_range` | a drag inside a page, as one step | the placed JSON, or null for a target inside or at the range's edge, or a page past its deadline |
| `companion_sheet_move_range_to` | a drag between pages, as one transaction keeping every object; sweeps nothing | the placed JSON for its run on the destination, or null with neither page changed: for one page at both ends, an unknown page or a file at either end, a range or point outside its body, or a page past its deadline at either end |
| `companion_sheet_clone_range` | the ⌥ drag inside a page, every object cloned, as one step | the placed JSON, or null |
| `companion_active_cut_json` | the clipboard slot | `{"page_id": u64 or null, "objects": [face]}`, null and `[]` with no cut |
| `companion_chip_provide_drag` | the decrypted drag's write into its item | false, writing and recording nothing, on refusal |
| `companion_chip_delete` | the explicit burn, attached or detached | whether the chip existed; false, changing nothing, for a record with no value |
| `companion_chip_stands` | whether a chip stands on a live page, past its deadline or not, for wording a refusal | false for an unknown chip or a null handle |

The placed JSON (`placed_json` in `lib.rs`) carries `location_utf16`,
`length_utf16`, `reattached`, `cloned`, `expired`, `burned`,
`unavailable`, `elsewhere` (placed as unavailable because the value is
on another device), `unreadable` and `pages_expired`, the last counting
the pages the sweep before a paste took. The shell's `CompanionClient`
wrappers decode a cap refusal as `FragmentRefusal.tooLarge(limit:)` or
`.tooManyObjects(limit:)`, so the line can name the core's number.

### Type name

The private pasteboard type is the shell's:
`com.onetimesecret.onetimepad.sealed-fragment`, with `.debug` appended in
a debug build (`CompanionClient.sealedFragmentType`,
`releaseSealedFragmentType`, `debugSealedFragmentType`). The core never
sees it. `PageModel.boardHoldsOwnCopy` knows the type as every build
names it.

## A seal in place

A seal that replaces ink already on the page (`seal_text_at` and its
siblings with a length, through `place_chip`) compacts a solo page at
once and owes an enrolled page its ceremony, since the ink's insert
stays in the op log as deleted text until a rebuild (proposed ADR-0058
point 10; `sealing_ink_in_place_on_a_solo_page_sheds_the_ink_from_its_history`,
`sealing_ink_in_place_on_a_deferred_page_owes_the_ceremony_that_sheds_it`,
`a_seal_at_a_point_compacts_nothing_and_owes_no_ceremony`). On a
channel with no peer the solo ceremony withdraws the turn's queued ops
before they publish
(`a_seal_in_place_on_a_channel_with_no_peer_sends_none_of_its_ink_that_turn_or_the_next`);
with peers, the ink can reach them as page history until the ballot
commits, and each member's rebuild then sheds it
(`after_a_ballot_commits_on_both_devices_neither_keeps_the_ink_a_seal_in_place_replaced`).

## At rest

This build writes `OTSSNAP5` (proposed ADR-0058 point 9: "A new content
snapshot version writes each record's availability as a tag ahead of
any payload bytes, the name's version and the note's operation log.").
It still reads `OTSSNAP4`, every chip record of which has its value, and
refuses every other version as unknown
(`persist.rs` `a_v4_snapshot_restores_as_it_did`,
`superseded_and_unknown_magics_all_refuse_as_unknown_format`). An
earlier build refuses `OTSSNAP5` as unknown, and by ADR-0016 the file is
left untouched (code reading). Within a version the fields after the
payload are trailing, so a record that ends before one restores without
it. Lengths and the name's counter are u64 little endian; flags, tags,
kinds and size classes are one byte each.

- **The chip record**, in `OTSSNAP5`: the identity (16 bytes), then an
  availability tag. Tag 0, a value here, is followed by its kind (0
  text, 1 image), a receipt flag (0, or 1 and the receipt id, length
  prefixed) and the payload, length prefixed. Tag 1, a record with no
  value, is followed by its kind (0 unknown, 1 text, 2 image) and its
  size class (0 unknown, 1 tiny to 5 huge). Any other tag, kind or size
  is damage
  (`a_damaged_availability_record_refuses_the_whole_restore_and_leaves_the_store_untouched`).
  Then a name flag (0, or 1 and the name); a name version flag (0, or 1,
  the counter and the writer's 32 bytes); and a note flag (0, or 1, the
  note's text and its operation log, each length prefixed, the log
  empty for none)
  (`a_record_with_no_value_round_trips_as_one`,
  `a_name_version_round_trips_on_attached_and_detached_records`,
  `an_unknown_or_short_name_version_is_malformed_and_the_store_is_untouched`,
  `an_otssnap5_note_without_its_log_is_malformed_and_the_store_is_untouched`).
  `OTSSNAP4`'s chip record has no tag, version or log: the identity, the
  kind, the receipt flag and the payload, then a name flag and a note
  flag with the text alone. A restored name the rule refuses is
  dropped, not read as damage; a flag other than 0 or 1 is damage, as
  the page floor's is. The note restores with an empty undo stack, its
  history replayed from its log; an `OTSSNAP4` note has none, so its
  first export reaches a peer whole
  (`note.rs` `a_relaunch_keeps_the_shared_history_and_a_later_edit_merges_once`,
  `persist.rs` `a_v4_note_restores_with_no_log_and_its_first_export_reaches_a_peer_whole`).
  Each note's text and log are taken once, at their exact sizes, before
  the snapshot's two passes (draft Law 0004). Since 2026-10-21 (issue
  #256) the restore, a paste and a clone keep the note's text as one
  zeroizing copy, and the note's document is made from it at its first
  edit ([content buffer register](content-buffer-handling.md) C31); a
  restored note rests with its log until then
  (`an_unedited_restored_note_rests_with_its_log_when_only_shown`).
- **The page record**, after the floor: its detached chips, framed as its
  attached chips are, then a cut flag (0, or 1 and the active cut's
  envelope) on the page the cut came from. A cut whose objects are not
  all detached on that page restores as no cut. A detached chip whose
  identity repeats one the page already holds is damage
  (`persist.rs` `a_detached_chip_repeating_an_identity_is_malformed`).
- **The ledger**: the destination class gains tag 3, `drag`. A ledger
  holding a `drag` record is damage to an older build.
- **Not written**: the metadata waiting cache (at most 256 entries),
  the note waiting cache (at most 256 KiB), the changed metadata set,
  the restated pages and the moved chip ids live in memory only, and a
  restore keeps a waiting entry only for a page it brought back (code
  reading).

## The deadline gate

`SheetStore::readable_sheets` holds the live pages whose countdown still
runs. It asks `Sheet::is_due`, the question the sweep asks, so a page
leaves it at the instant it becomes due. Copy decrypted, `NAME=value`,
the decrypted drag, both conceals, the note's text and a fragment's copy
and cut find their page or object through it. Since 2026-10-21
(issue #310) the note's batch, undo, redo and end of its typing run
and a rename find their object through `SheetStore::chip_mut`, which
asks `Sheet::is_due` the same way, so each refuses a page past its
deadline and changes nothing. To word its refusal a
page's conceal asks whether the page still stands, and a chip's conceal
whether any page still holds the chip (`SheetStore::chip_stands`, over
the seam `companion_chip_stands`); neither reads either. The metadata
and note sync routes ask `Sheet::is_due` too, so a page past its
deadline gives and takes neither (Metadata, and The note's routes,
above).

The routes that draw a page do not go through it:
`companion_sheet_document_json` (the ink and the objects' faces),
`companion_sheet_meta_json` and `companion_sheet_blocks_json` read
`SheetStore::sheet` and still answer for a page past its deadline, so the
shell shows the page until it settles and the sweep takes it.

## The keys holder

`InkTextView.answersChords` says whether a surface's chords and Edit menu
actions are its own to answer.

- The page answers unless another text view holds the keys: a field
  editor of any field in its window or in the key window over it (the
  gutter's, the strip's, the pad cell's, the sealed name's, the find
  bar's, a Settings field), or a note's surface. A note answers only
  while it holds the keys itself.
- `performKeyEquivalent` and the page's Edit menu actions (Undo, Redo,
  Seal Selected Content, Detect Code Language, Choose Language, Paste
  Without Detection) consult it, and their validation says no when it
  does. AppKit sends key equivalents to every view in the key window,
  whether or not it holds the keys, which is why the page must ask.
- Choose Language goes down the responder chain as a nil-targeted action
  carrying the language (`CodeLanguageChoice`), so it reaches whoever
  holds the keys. A file's render mode is still chosen on the model when
  no editor selection can take a language.
- The menu's availability follows the holder. A surface that answers
  publishes what it can do; when a field holds the keys the page
  publishes that nothing is available. It is asked again when the keys
  move to or from a surface and when a window becomes key.
- The sealed name field keeps its next responder past the page, so its
  own undo answers its draft.
- A nil-targeted action that finds no answer in the key window goes on
  to the main window's chain, so a field in another window, such as the
  pad list's popover, does not keep it from the page. The pad cell's case
  rests on the key window, which the test runner cannot make.
- `AskingTextView.mayReadOut`, the gate AppKit's readers ask first, is
  built on it (Law 0001's AppKit text routes table).

## The note's surface

`InkEditorView.makeSurface(over:coordinator:)` builds the page's text view
and the note's with one configuration. The note has a coordinator of its
own, holding no sheet, and its storage is the note's alone. Every page
only path keys on the coordinator's sheet; a new path that reads the
coordinator's document instead reaches the note too, so its author
decides which it means.

## The decrypted drag

`DecryptedDrag` (`DecryptedDrag.swift`) is the drag's source and its
`NSPasteboardItemDataProvider`. The provider hands the pasteboard and item
it is asked about to `companion_chip_provide_drag` through
`PageModel.provideDecryptedDrag`. The core composes the payload in a
zeroizing buffer of its final size, writes it into that item by copy
decrypted's content write (`SystemDragItem` in `crates/pasteboard`), and
records one `sent` to `drag`. The types are the chip's own:
`public.utf8-plain-text` for text, `public.png` for an image.

A probe on 2026-10-13, in one process with a uniquely named pasteboard,
saw AppKit ask an item's provider inside the read that wanted the data,
synchronously and on the main thread. The provider's write takes the
core's lock, and `companion_sheet_seal_from_drag` reads the system drag
pasteboard while holding it; Rust documents that `Mutex::lock` does not
return when the thread already holds the lock. That is why the page and
the note refuse the app's own decrypted drag (`isDecryptedDrag`) before
drop to seal reads the board. An ask AppKit makes off the main thread is
refused.

## Shell constants

| Constant | Value | What it sets |
| --- | --- | --- |
| `NotePopoverLayout.minimumWidth` | 320 | below it the note spans the card's content width |
| `NotePopoverLayout.edgeInset` | 8 | the note's margin from the content area's edges |
| `SealedBlockCell.beatDuration` | 1 s | the ember beat |
| `SealedBlockCell.beatFade` | 0.15 s | the beat's fade at each end, dropped under Reduce Motion |
| `SealedBlockCell.decryptedDragWords` | `drag decrypted` | the handle's words |
| `InkTextView.decryptedDragSlop` | 3 | the travel before a press on the handle drags |
| `SealedBlockLayout.Metrics.handleGap` | 8 | the handle's clearance from the actions seat and the classification |
| `PageModel.copiedNameLine` | `copied the name.` | the line after *Copy Name* |
