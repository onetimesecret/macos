# Comment guarantee audit (73ee23c..7544943)

The comment trim in PR #237 removed comments that asserted guarantees, on the trimming agents' word that a test already covered each one. This audit checks that word for the trimmed crates: `crates/core`, `crates/ffi`, `crates/credentials`, `crates/ots-client` and `crates/pasteboard`. The sync files (`crates/sync`, `crates/core/src/sync.rs`, `crates/ffi/src/sync_*.rs`, `crates/ffi/src/pairing.rs`) and the sync, pairing, relay and account-auth items in `crates/ffi/src/lib.rs` are out of scope.

The removed comments are leads, not evidence. Each claim below is a paraphrase of a deleted comment and not a statement of project policy. Whether an ADR backs a claim was not checked. A covered row means a named test exercises the behaviour the comment described. It does not mean the behaviour is an accepted guarantee.

## Method

1. `git diff -U0 73ee23c..7544943` over the in-scope paths found 9,309 deleted comment lines. Of those, 1,750 contain never, always, must, only, refuse(s/d), wipe(d), zeroize(d), before, after, cannot, until, at most or exactly. They form 992 contiguous blocks.
2. The blocks were read file by file. Claims about security, privacy, persistence or data loss were kept, and the rest were dropped. A claim whose substance still sits in a remaining comment was normally dropped too. It was kept when a test was added for it, and the Status column says so.
3. Each kept claim was mapped to a test by name, after reading the test or its assertions. Where no test could be found, the row says none.

Status values:

- **covered**: a test from before this audit checks the claim.
- **added**: this audit adds the test named.
- **none**: no test was found.
- **structural**: the type system, a compile-time assertion or a `cfg` gate enforces the claim; no runtime test.
- **macOS only**: only a macOS keychain or pasteboard can exercise it. A test exists but is `#[ignore]` or gated to macOS, so the Linux CI lanes do not run it.

## crates/credentials

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/lib.rs | The key material store is the data-protection store for the caller's own service, one per service per process, never the default service | `one_data_protection_store_per_service`; `key_material_crosses_to_the_same_service` | covered (second test macOS only) |
| src/lib.rs | Off macOS, the key material store is the same map, so a key written through it is found by the matching restore | `the_in_memory_key_store_shares_one_map` | covered |
| src/lib.rs | Only a missing-entitlement status demotes a gate to the login keychain | `only_a_missing_entitlement_means_fallback` | covered |
| src/lib.rs | The tier is probed at most once per gate, and the degradation is announced once | `the_tier_is_probed_once_and_then_cached`; `a_probe_that_lacks_the_entitlement_degrades_and_says_so_once`; `a_real_operation_can_demote_a_gate_that_probed_clean` | covered |
| src/lib.rs | Reads and deletes reach both keychain tiers, so an unentitled build still finds and removes what it wrote | `data_protection_items_are_invisible_to_the_login_keychain` | macOS only (ignored, run by hand) |
| src/lib.rs | `exists` is answered from attributes only and never decrypts, so it cannot raise the ACL prompt | none | macOS only, untested |
| src/lib.rs | Error messages never embed secret material | none; `CredentialError::Backend` holds a `BackendFailure`, which is a status code or a `&'static str` (tightened in review; it held a `String` before) | structural |

## crates/core

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/secret.rs | A `SecretBuffer` cannot be cloned, copied, debug-printed, displayed or (de)serialized | `assert_not_impl_any!` in the test module | structural |
| src/secret.rs | The wipe zeroes every byte, spare capacity included, and a second wipe is harmless | `wipe_zeroes_every_byte`; `the_wipe_reaches_the_spare_capacity_a_vector_arrives_with`; `wipe_is_idempotent_and_drop_is_safe` | covered |
| src/secret.rs | A page shared by two locked buffers is unlocked only when the last one drops; an empty buffer is never locked | `a_page_two_buffers_share_is_unlocked_only_when_the_last_goes`; `empty_buffer_never_claims_a_lock` | covered |
| src/harden.rs | Hardening disables core dumps and is safe to call repeatedly | `hardening_leaves_no_core_dump_allowance_and_runs_twice_harmlessly` | added (wording survives) |
| src/persist.rs | A refused restore leaves the store exactly as it was | `a_dangling_chip_mark_is_malformed_and_the_store_is_untouched`; `truncation_at_every_offset_rejects_without_panicking`; `a_blob_that_does_not_import_is_malformed_and_the_store_is_untouched` | covered |
| src/persist.rs | Bytes after the last record are damage, even though trailing fields inside a record are skipped | `wrong_magic_is_unknown_format_and_damage_is_malformed`; `a_trailing_field_on_a_*_record_is_skipped_not_refused` (five tests) | covered |
| src/persist.rs | A count or length the buffer cannot cover is rejected before allocating | `a_hostile_length_is_rejected_before_it_allocates` | covered |
| src/persist.rs | The snapshot is written into one exact-size buffer, so no growth strands sealed bytes | `snapshot_size_is_exact` | covered |
| src/persist.rs | Every earlier or unknown magic refuses with the store untouched; only the replaced ledger magic is named Superseded | `superseded_and_unknown_magics_all_refuse_as_unknown_format`; `a_superseded_ledger_magic_refuses_as_superseded_with_the_ledger_untouched` | covered |
| src/persist.rs | No sequential counter, and no document peer id, reaches either snapshot | `no_sequential_counter_appears_in_either_snapshot` | covered |
| src/persist.rs | The ledger snapshot carries no ink, no deleted text and no origin URL; the derived page title is never written | `the_ledger_snapshot_never_contains_page_ink`; `the_origin_message_survives_the_round_trip`; `a_tab_name_is_written_down_and_the_pages_own_title_is_not` | covered |
| src/persist.rs | A restored page holds no more life than its rung's longest life, and a restored hold no more than the pause gesture's ceiling | `no_restored_page_comes_back_holding_more_life_than_its_rung`; `no_restored_hold_freezes_more_life_than_its_rung`; `no_restored_hold_outlasts_the_ceiling_the_pause_gesture_sets` | covered |
| src/persist.rs | A wall clock that moved backwards while away grants no life | `a_backwards_wall_clock_grants_no_extra_life` | covered |
| src/persist.rs | A ledger load merges with records already in memory, as a multiset union | `a_ledger_restore_keeps_the_records_the_store_already_holds`; `a_ledger_restore_unions_duplicate_records_as_a_multiset` | covered |
| src/persist.rs | Aged ledger records drop on load and on the write path, not only on append | `records_past_the_retention_window_drop_on_load`; `the_write_path_evicts_an_aged_title_with_no_new_event_recorded` | covered |
| src/ledger.rs | Retention is 90 days inclusive, and a clock read before every record evicts nothing | `retention_is_a_ninety_day_window_not_a_count`; `a_wall_clock_that_stepped_backwards_evicts_nothing` | covered |
| src/clock.rs | The sleep-inclusive reading never runs backwards | `the_sleep_inclusive_reading_never_runs_backwards` | covered (sleep itself cannot run in CI) |
| src/file_persist.rs | A drafts restore decodes and replays every record before touching the store, so a refusal leaves it as it was | `every_truncation_is_refused_and_leaves_the_store_alone`; `a_record_whose_draft_will_not_import_leaves_the_store_as_it_was` | covered |
| src/file_persist.rs | A tail past the record list is refused | `a_tail_past_the_record_list_is_refused` | covered |
| src/file_persist.rs | An over-bound draft is left out, the file still comes back, and the record goes back out as it came in | `a_draft_over_the_bound_is_left_out_and_the_file_still_comes_back`; `a_pending_record_goes_back_out_exactly_as_it_came_in` | covered |
| src/file_persist.rs | The drafts buffer is sized exactly by a sizing pass, so no growth strands unsaved typing in unwiped heap | `the_drafts_buffer_is_written_at_its_exact_size` (added in 4e1983a, Law 0004) | covered |
| src/files.rs | A save the platform refuses leaves the file on disk untouched and the buffer dirty | `only_write_access_denial_at_current_path_sets_access_refused` | covered |
| src/files.rs | A save never makes a file where none is; a keep mine licenses exactly one save and is withdrawn when the path changes state | `a_save_of_a_clean_file_that_is_gone_is_refused_and_nothing_is_recreated`; `the_consent_is_spent_by_the_save_it_was_given_for`; `keep_mine_over_a_changed_copy_does_not_license_recreating_a_file_deleted_afterwards`; `keep_mine_over_a_missing_file_does_not_license_overwriting_one_that_appears` | covered |
| src/files.rs | A file rewritten faster than it can be read is refused rather than opened with a mismatched witness | `a_file_rewritten_faster_than_it_reads_is_refused_rather_than_opened`; `a_write_between_the_read_and_the_stat_is_never_invisible` | covered |
| src/files.rs | An oversized file is refused before any of it is read | `an_oversized_file_is_refused_before_a_byte_of_it_is_read` | covered |
| src/files.rs | A refused batch stamps no edit time | `a_refused_batch_stamps_no_edit_time` | covered |
| src/files.rs | Closing drops the draft, and reopening the file never brings old edits back | `a_closed_files_draft_does_not_come_back_when_it_is_reopened` | added |
| src/files.rs | A refused reload leaves the buffer as it was | `a_refused_reload_marks_a_clean_file_and_absence_is_the_other_state` (clean buffer only); `a_refused_reload_keeps_a_dirty_buffers_draft` | added (wording survives) |
| src/files.rs | A pending (restored, unhydrated) file refuses every route that would move or write it | `a_pending_file_refuses_every_route_that_would_move_it` (in file_persist.rs) | covered |

### Gaps in store.rs, document.rs and sheet.rs

Another agent owns tests in these files. Most of their removed guarantees are covered, for example: undo never un-seals (`a_seal_cannot_be_stepped_back`, `a_deleted_chip_leaves_no_step_that_would_stand_it_again`); a seal over a standing chip refuses (`a_range_seal_over_a_selected_chip_is_refused`); a due page is not resurrected (`cycling_or_setting_a_due_page_refuses_instead_of_resurrecting`, `pausing_a_due_page_refuses`); a peer expiry only shortens (`a_peer_expiry_can_only_shorten_and_the_hold_ignores_it`); remote refusals are whole (`a_remote_chip_the_page_does_not_own_refuses_whole`, `a_delta_missing_its_dependencies_is_refused_not_queued`); compaction sheds the old peer id (`compaction_rebuilds_under_a_fresh_peer_and_sheds_the_trail`, `no_peer_id_crosses_a_ceremony_boundary_in_a_delta`). No test was found for these; the first gained one in review:

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/store.rs | `sheet_payload` preallocates the whole conceal payload, so no regrowth strands sealed bytes in unwiped heap | `the_conceal_payload_is_written_at_its_exact_size` (added in review, Law 0004) | added |
| src/store.rs | If the document refuses a chip placement after the chip was minted, the settle reaps that chip (zeroized, with its record) and the call fails closed | none (the refusal cannot be injected) | none |
| src/sheet.rs | The segments projection drops a sentinel whose identity matches no owned chip, so an unresolvable chip never renders | none (`a_sentinel_with_an_unreadable_mark_reads_as_ink` covers an unreadable mark, not an unowned one) | none |
| src/document.rs | If a chip's mark cannot be applied, its sentinel is removed rather than left standing | none (the failure cannot be injected) | none |

## crates/pasteboard

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/lib.rs | The clear after a copy runs only while the board still holds our own write | `clear_after_copy_only_clears_our_own_write` | covered |
| src/lib.rs | The offer probe answers yes only for external content, never for our own transient write | `external_content_is_offered_and_our_own_write_is_not` | covered |
| src/lib.rs | An origin URL is read only when the writer declared one, and our own write never carries one | `read_captures_the_origin_url_when_present_and_none_otherwise` | covered |

## crates/ots-client

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/api.rs | The guest conceal request never carries credentials | `guest_request_is_unauthenticated_on_the_guest_route` | covered |
| src/api.rs | A requested TTL snaps down, never up | `snap_ttl_snaps_down_never_up` | covered |
| src/api.rs | The conceal body is serialized straight into an exact-size zeroizing buffer, with no intermediate JSON tree holding the secret | `the_conceal_body_is_written_at_its_exact_size` (added in review, Law 0004; checks the size, not the absence of a JSON tree) | added |
| src/http.rs | Transports must enforce TLS | `refuses_a_plaintext_url_before_any_socket_opens` (crates/transport) | covered |

## crates/ffi

| File | Removed claim (paraphrase) | Covering test | Status |
| --- | --- | --- | --- |
| src/conceal.rs | Authenticated only when a token and an extid are both present; guest otherwise | `authenticated_when_token_and_extid_present`; `guest_route_when_a_token_has_no_extid` | covered |
| src/conceal.rs | A link's default TTL is exactly seven days and takes nothing from the page clock | `ttl_defaults_to_seven_days_when_unnamed` | covered |
| src/conceal.rs | The stub wire's record holds no payload and no passphrase | `wire_stub_records_the_conceal_without_its_secret` (test-util) | covered |
| src/conceal.rs, src/lib.rs | A failed conceal changes nothing: the chip stays, nothing is written to the board, nothing is recorded | `a_conceal_that_fails_leaves_the_chip_the_board_and_the_ledger_alone` (test-util) | added |
| src/diagnostics.rs | A NUL inside a line does not truncate it at the ABI; clearing the sink returns lines to stderr | `a_message_carrying_a_nul_arrives_whole`; `a_registered_sink_takes_the_line_and_stops_taking_it_when_cleared` | covered |
| src/diagnostics.rs | Only metadata crosses the diagnostic sink, never ink, chips or key material | none; proposed as a rule in ADR-0040, not tested; a one line restatement that survived the trim was removed in review | none |
| src/gop.rs | Ciphertext sealed under a rotated-out key never opens under the next; an excluded device cannot follow the chain | `ciphertext_sealed_under_the_outgoing_key_does_not_open_under_the_incoming`; `a_device_excluded_from_a_ceremony_cannot_follow_the_chain` | covered |
| src/gop.rs | A GOP rotation never touches the ledger key or the content halves; a refused ceremony rotates nothing | `a_gop_rotation_never_touches_the_ledger_key_or_the_content_halves`; `the_ceremony_rotates_and_rebuilds_as_one_event_or_not_at_all` | covered |
| src/persist.rs | Only ciphertext reaches disk, and both header fields are authenticated | `the_file_never_contains_the_plaintext`; `header_fields_are_authenticated`; `tampering_anywhere_fails_authentication` | covered |
| src/persist.rs | State and ledger envelopes cannot be swapped, even under the right key | `a_ledger_file_cannot_be_opened_as_a_state_file`; `the_ledger_envelope_is_its_own` | covered |
| src/persist.rs | Restore loads both halves and mints neither | `ensure_is_stable_and_load_never_mints`; `a_missing_file_half_is_never_minted_on_restore` | covered |
| src/persist.rs | A file half of the wrong length counts as absent, so a restore refuses | `a_file_half_of_the_wrong_length_is_refused_on_restore_and_left_alone` | added (wording survives) |
| src/persist.rs | A keychain that will not answer means no key and no save, never a save under a newly minted key | `a_keychain_that_will_not_answer_yields_no_save_key_and_no_half` | added (wording survives in part, on `ensure_key_for`) |
| src/persist.rs | A wrongly sized keychain item is refused and left in place | `a_wrongly_sized_keychain_item_is_refused_not_replaced` | covered |
| src/persist.rs | Two credential stores never share a file half | `changing_either_half_changes_the_derived_key` | covered |
| src/persist.rs | Rotation never touches the ledger key | `rotation_leaves_the_ledger_key_intact`; `rotating_and_dropping_the_content_key_leave_the_ledger_key_alone` (lib.rs) | covered |
| src/persist.rs | Rotation never reads the keychain, and erases the half even when the keychain answers nothing or refuses the delete | `a_rotation_against_a_keychain_that_answers_nothing_still_erases_the_half`; `a_rotation_the_keychain_refused_still_forgot_the_content` | covered |
| src/persist.rs | A half zeroed but not unlinked counts as forgotten; a half that could not be zeroed counts as survived | `a_half_that_cannot_be_unlinked_is_still_zeroed_and_says_so`; `a_half_that_cannot_even_be_zeroed_reports_survival` | covered |
| src/persist.rs | A superseded envelope is disposed of without asking for the key; `OTSSEAL1` and unknown magics are refused and kept | `a_superseded_file_is_disposed_of_rather_than_refused`; `a_v1_file_is_refused`; `an_unreadable_envelope_costs_no_keychain_access` | covered |
| src/persist.rs | Adding a superseded magic must reopen the rotation question | `the_superseded_set_predates_the_key_half_move` | covered |
| src/persist.rs | The erase never follows a final symlink and never blocks on a FIFO | `erase_never_follows_a_symlink_planted_at_the_state_path`; `erase_never_blocks_on_a_fifo_planted_at_the_state_path` | covered |
| src/persist.rs | A stat that will not answer counts as not erased | none (needs a stat fault the filesystem will not give on demand) | none |
| src/persist.rs | The launch sweep takes stranded temp generations and nothing else | `the_sweep_takes_stranded_temp_generations_and_nothing_else` | covered |
| src/persist.rs | A drop rotates only for the content file, decided by name and then magic; a ledger clear never rotates | `the_content_drop_is_decided_by_name_then_magic`; `clearing_the_ledger_file_leaves_the_content_halves_alone` (lib.rs) | covered |
| src/persist.rs | The seal work buffer is exact-size and self-wiping | `the_seal_work_buffer_is_exact_and_self_wiping` | covered |
| src/persist.rs | Private writes are atomic and owner-only, never follow a planted name, and never land torn | `write_private_replaces_whole_and_cleans_up`; `the_state_file_is_owner_only`; `a_planted_symlink_beside_the_target_is_never_followed`; `concurrent_saves_never_land_a_torn_file` | covered |
| src/persist.rs | A release build off macOS does not compile | none (`compile_error!` under `cfg`) | structural |
| src/lib.rs | Sealed bytes never appear in any output | `sealed_bytes_never_appear_in_any_output` | covered |
| src/lib.rs | A sealed paste clears the board in the same operation, and a refused seal (unknown page) clears nothing | `sealed_paste_drains_the_board_in_the_same_operation`; `a_refused_seal_leaves_the_board_alone` | covered |
| src/lib.rs | A seal over a range the page does not have, or over a standing chip, takes nothing from the board | `a_seal_over_a_range_the_page_does_not_have_takes_nothing_from_the_board` | added (wording survives in general form) |
| src/lib.rs | When another writer moves the board between the read and the clear, the guarded clear stands down and `cleared_out` says so | none (the memory board has no hook between read and clear) | none |
| src/lib.rs | Copy-out is marked transient and concealed, and each egress retires the previous receipt | `copy_out_writes_the_pasteboard_in_core_marked_nspasteboard_concealed`; `a_second_egress_retires_the_first_receipt` | covered |
| src/lib.rs | An origin URL persists only in the sealed snapshot and appears on no JSON surface or ledger | `a_url_bearing_paste_persists_its_origin_and_shows_it_nowhere` | covered |
| src/lib.rs | Ledger JSON carries no ink | `ledger_json_reports_events_uuids_and_never_ink` | covered |
| src/lib.rs | The Settings read answers `has_token` from existence and never reads the token | `the_settings_read_answers_has_token_without_reading_the_token` | added (wording survives) |
| src/lib.rs | Configuration refuses non-https URLs, and the token never comes back in JSON | `connection_config_and_offline_conceal_refusals` | covered |
| src/lib.rs | A restore never destroys a file it cannot open | `a_file_that_will_not_open_is_left_exactly_where_it_is`; `a_locked_keychain_refuses_the_restore_and_leaves_the_directory_alone`; `an_unknown_envelope_is_refused_and_kept` | covered |
| src/lib.rs | A save stamp from the future counts as no time away | `a_stamp_from_the_future_reads_as_no_time_away`; `a_stamp_from_the_future_freezes_the_countdown_rather_than_draining_it` | covered |
| src/lib.rs | The ledger save sweeps the retention window before it snapshots | `the_ledger_save_path_evicts_before_it_snapshots` | covered |
| src/lib.rs | Rotate-and-reseal: a surviving half cancels the write, a neutralized half proceeds, and a non-content path is refused | `a_reseal_that_could_not_touch_the_half_leaves_the_old_generation_alone`; `a_reseal_that_could_not_unlink_the_half_has_still_forgotten`; `a_reseal_refuses_every_path_that_is_not_the_content_file` | covered |
| src/lib.rs | A drop whose half survived keeps the ciphertext | `a_drop_that_could_not_touch_the_half_keeps_the_content_file` | covered |
| src/lib.rs | Freeing a handle wipes every sealed byte it holds | none at the seam; relies on the `SecretBuffer` drop path | structural |
| src/lib.rs, src/files.rs | A file id never addresses a page, and a page id never addresses a file | `page_routes_refuse_a_file_id`; `a_sheet_id_is_refused_by_every_file_route` | covered |
| src/files.rs | A save never makes a file where none is | `a_save_never_recreates_a_file_that_is_gone_from_its_path` | covered |
| src/files.rs | A staging directory that will not serve fails the save without falling back, and a failed rename takes its temp file back | `a_staging_directory_that_is_not_there_fails_the_save_without_falling_back`; `a_staged_write_whose_rename_fails_takes_its_temp_file_back`; `cross_filesystem_staging_is_rejected_before_creating_a_temp_file` | covered |
| src/files.rs | A save keeps the file's mode, and its group where it can | `a_save_keeps_the_mode_the_file_already_had`; `a_staged_write_keeps_the_mode_and_the_group_the_file_already_had` | covered |
| src/files.rs | A FIFO at a file path is refused, not blocked on; a read stops one byte past the limit | `a_fifo_is_refused_rather_than_blocked_on`; `a_file_read_takes_no_more_than_one_byte_past_the_limit` | covered |
| src/files.rs | Draft plaintext is never on disk, and a drafts file handed to the state restore never lands in the sheet store | `drafts_round_trip_through_the_seal` | covered |
| src/files.rs | A state file handed to the drafts restore is refused and left where it is | `a_state_file_handed_to_the_drafts_restore_is_refused_and_kept` | added |
| src/files.rs | A pending file refuses saves and edits; one file that will not hydrate costs no other | `a_pending_file_refuses_a_save_and_an_edit_until_it_is_hydrated`; `one_file_that_will_not_hydrate_costs_no_other_file_anything` | covered |
| src/files.rs | Rotation reseals drafts under the new key; with no drafts file it writes none | `a_rotation_leaves_the_drafts_readable_under_the_new_key`; `a_rotation_with_no_drafts_file_writes_none` | covered |
| src/files.rs | Dropping the content file keeps an open file's draft; a ledger clear leaves drafts alone | `dropping_the_content_file_keeps_an_open_file_s_draft`; `a_ledger_clear_leaves_the_drafts_alone` | covered |

## Contradictions

None. Every added test passed against the code at 7544943 without a code change, and the two added in review passed against the code they pin.

Found while writing the invariant tests in 23a0da9, not by this audit's tests, and not fixed here:

- **Chip removal and D-30.** The accepted [UI/UX decisions](../spec/design/2026-0915-ui-ux-decisions.md) record, D-30, reads: "Removing a sealed object is **structural and undoable**: the first backspace beside it selects, the second removes, and ⌘Z puts the object back." In the core, deleting a sentinel zeroizes the chip and clears the undo stack, and `store::a_deleted_chip_leaves_no_step_that_would_stand_it_again` and `deleting_a_sentinel_by_op_zeroizes_the_chip` pin that. Reproduction: `seal_text_at(id, "sealed", 0, 0)`, insert ink at 1, delete one character at 0; the chip is gone and `can_undo` is false. Whether the shell restores the object some other way is not established.
- **Same-second commits merge.** The comment in `SheetDocument::new` (`crates/core/src/document.rs`) says every commit is its own change, so a block's modified stamp is never up to 1000 s stale. loro's `can_merge_right` merges changes whose timestamps differ by at most the merge interval, which is 0, so commits within the same second still merge. Not verified by a test.

One observation, not a contradiction: on the save path, `ensure_file_half` treats a wrong-length file half as absent by minting a fresh half over it. That matches the removed claim. It does mean a damaged half is replaced silently rather than reported. The state file it keyed was already unreadable.

## Totals

- Claims mapped: 105. That is 99 table rows plus the 6 covered claims named in the store, document and sheet summary.
- Covered by a test from before this audit: 82 (76 table rows plus those 6).
- Covered by a test added here: 11 claims, 11 tests (9 by the audit, 2 in review).
- Structural (4), or macOS only and not run by Linux CI (2): 6.
- No test: 6, of which 3 are in store.rs, document.rs and sheet.rs.

## Since this audit

The audit above reads the tree at 7544943 and is left as it was. On
2026-10-13, under issue #170 and draft ADR-0047, whose detached store is
now [ADR-0046](../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md)
(accepted 2026-10-16), a removed chip became detached rather than zeroized, which settles the
chip removal contradiction in favour of D-30. Two tests named above
were rewritten to pin the new behaviour:

- `a_deleted_chip_leaves_no_step_that_would_stand_it_again` is now
  `undo_stands_a_removed_chip_again_from_the_detached_store`. It no
  longer covers the claim that undo never un-seals;
  `a_seal_cannot_be_stepped_back` and
  `a_seal_finished_through_ops_cannot_be_stepped_back_to_its_ink` do.
- `deleting_a_sentinel_by_op_zeroizes_the_chip` is now
  `deleting_a_sentinel_by_op_detaches_the_chip_and_records_nothing`.
