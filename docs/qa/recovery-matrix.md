# Persistence recovery matrix

The inventory behind issue #48: for each of the seven lifecycle cases,
what is guaranteed, which tests assert it today, which hardware
procedure covers what CI cannot reach, who owns that procedure, and
when it last ran.

[ADR-0016](../adr/0016-content-persists-across-restart.md) holds the
reasoning and this file holds the inventory, so a citation that drifts
drifts in one place that is cheap to re-verify. Tests are named rather
than numbered, because a name that moves is found by `grep` and a line
number that moves is found by a reader who trusts it.

Two rules govern the table. A row may cite an automated test only if a
CI step runs it: the Rust names run in the `logic (ubuntu)` and
`platform (macos)` jobs, the Swift names in `shell (macos)`, and the
packaged-bundle checks in `shell (macos)` and `release packaging
(macos)` (`.github/workflows/ci.yml`). Every hardware cell must resolve
to a file under `docs/qa/verification-procedures/` that carries an
Owner line and a Results table.

| # | Case | Guarantee | Automated tests | Hardware procedure | Owner | Last recorded run |
|---|---|---|---|---|---|---|
| 1 | Clean quit | A quit flushes whatever the debounce still holds, so unexpired content comes back in full, and a flush that cannot write says so before the app goes away (ADR-0016 section 1, section 7). | Rust: `crates/ffi/src/lib.rs` `persist_round_trips_over_the_seam`; `crates/core/src/persist.rs` `round_trip_preserves_pages_chips_and_titles`. Swift: `PersistenceRoundTripTests.testAMutationRoundTripsThroughTheSealedFileOnTheRealDebounce`, `.testTheQuitFlushWritesWhatTheDebounceStillHolds`; `QuitPromptTests.testASettledFlushQuitsWithoutInterruption`, `.testTheReplyIsTakenFromTheModelsOwnFlush`, `.testARefusedWriteKeepsTheAppRunningWhenTheUserCancels`; `RestoreFailureTests.testTheQuitFlushOverAWithheldLicenceNamesTheLoss`, `.testTheQuitFlushOverARefusedWriteSaysRefused`. | None. CI reaches the whole path, including the reply the terminate delegate takes from the flush. | delano | Not applicable, CI |
| 2 | Crash or force termination | Everything sealed before the last burst survives, because each write lands whole or not at all; the loss window is the debounce measured from the first mark of a burst, and every mutation site opens it (ADR-0016 section 2). | Rust: `crates/ffi/src/persist.rs` `write_private_replaces_whole_and_cleans_up`, `concurrent_saves_never_land_a_torn_file`, `the_sweep_takes_stranded_temp_generations_and_nothing_else`; `crates/ffi/src/lib.rs` `launch_sweeps_the_temp_generations_a_crash_stranded`. Swift: `StateLicenceTests.testFirstMarkArmsTheWindow`, `.testABurstKeepsTheWindowItsFirstMarkOpened`, `.testAWriteStandsDownADeferredBodyThatAlreadyFired`, `.testABurstAfterARefusalRidesTheRetrysOwnGeneration`, `.testFailedSaveLeavesTheLatchHeld`, `.testOneWriteDischargesEveryHold`; `MutationArmingTests.testEveryMutationSiteArmsAWrite`; `LedgerAppendArmingTests.testEveryLedgerAppendingMutationArmsAWrite`; `RestoreFailureTests.testARefusedWriteOpensAWindowThatAbsorbsWhatFollows`; `BundleDeclarationTests.testTheShippedPlistDeclaresSuddenTermination`, and the same key read off the assembled bundle in CI. | [`force-termination.md`](verification-procedures/force-termination.md) for the SIGKILL, [`power-loss.md`](verification-procedures/power-loss.md) for the death that also takes the filesystem cache. | delano | Not yet run |
| 3 | macOS restart | A monotonic clock that restarts while wall time advances leaves pages alive; the gap between the last save and the next restore is charged by wall clock and by that gap only, against a live hold first, and no restored span passes its ceiling (ADR-0016 section 4, section 5). | Rust: `crates/ffi/src/lib.rs` `a_restart_leaves_the_pages_alive_and_drains_them_by_the_gap`, `a_gap_past_the_rung_expires_the_page_into_the_ledger`, `hours_of_wall_time_away_drain_hours_of_life`, `no_time_away_drains_nothing`; `crates/core/src/persist.rs` `time_away_drains_the_countdown`, `pages_due_while_away_expire_into_the_ledger_on_restore`, `a_hold_absorbs_time_away_before_the_countdown_drains`, `a_restored_hold_remembers_which_press_comes_next`, `no_restored_page_comes_back_holding_more_life_than_its_rung`, `no_restored_hold_freezes_more_life_than_its_rung`, `no_restored_hold_outlasts_the_ceiling_the_pause_gesture_sets`. Rotation on the emptied pad: `crates/ffi/src/persist.rs` `rotate_key_halves_makes_a_sealed_file_unopenable`, `rotation_leaves_the_ledger_key_intact`; `crates/ffi/src/lib.rs` `resealing_an_emptied_pad_rotates_the_halves_and_keeps_the_strip`. Swift: `TabLifetimeTests.testRelaunchAfterAnOvernightExpiryMintsNothing`, `.testAnEmptiedPadRotatesItsKeyAndReselsTheStrip`. | [`reboot.md`](verification-procedures/reboot.md): a live pad, a pad emptied first so rotation fires, a page paused. | delano | 2026-08-22, case 1 (live pad) passed on Mac14,6 / macOS 27.0. Cases 2 and 3 not yet run |
| 4 | App update or dev rebuild | A superseded format is dropped so the new install can write; an unknown one is refused and kept; a debug rebuild never lands on the release install's state (ADR-0016 section 9, section 7). | Rust: `crates/ffi/src/persist.rs` `a_v1_file_is_refused`, `a_superseded_file_is_disposed_of_rather_than_refused`, `the_superseded_set_predates_the_key_half_move`; `crates/ffi/src/lib.rs` `a_superseded_state_file_is_dropped_so_the_session_can_write`, `a_superseded_ledger_payload_is_dropped_so_the_session_can_record`, `an_unknown_envelope_is_refused_and_kept`; `crates/core/src/persist.rs` `superseded_and_unknown_magics_all_refuse_as_unknown_format`, `a_superseded_ledger_magic_refuses_as_superseded_with_the_ledger_untouched`. Swift: `StateLicenceTests.testADroppedSupersededFileEarnsTheLicence`, `.testAFileThatGenuinelyRefusedIsStillThereWhenTheProbeRuns`; `FormFactorTests.testOnlyTheAppsOwnIdentifierAndOneDotFreeSuffixAreAdopted`, `.testEachFormFactorSealsToItsOwnFile`. | [`re-signed-bundle.md`](verification-procedures/re-signed-bundle.md): a different signing identity, and the `.debug` bundle id beside the release one. | delano | Not yet run |
| 5 | Damaged snapshot | A file that will not open is left exactly where it is, the session's save licence is withheld for the rest of the run, and only the user's own discard hands it back (ADR-0016 section 7). | Rust: `crates/ffi/src/persist.rs` `tampering_anywhere_fails_authentication`, `header_fields_are_authenticated`, `the_wrong_key_opens_nothing`; `crates/ffi/src/lib.rs` `a_file_that_will_not_open_is_left_exactly_where_it_is`; `crates/core/src/persist.rs` `wrong_magic_is_unknown_format_and_damage_is_malformed`, `truncation_at_every_offset_rejects_without_panicking`, `a_hostile_length_is_rejected_before_it_allocates`, `hostile_materialized_stamps_are_clamped_and_dead_anchors_dropped`. Swift: `RestoreFailureTests.testADamagedSnapshotWithholdsTheLicenceWithoutDroppingTheFile`, `.testARefusedRestoreRaisesTheStandingState`, `.testTheDiscardTakesTheStateDownAndTheNextSealLands`, `.testTheDiscardIsANoOpForALicensedSession`; `StateLicenceTests.testRefusedRestoreWithholdsTheLicence`, `.testTheDiscardRegrantsTheContentLicenceUnconditionally`. | None. A byte flipped in the ciphertext is reachable from a test, so this case closes on CI. | delano | Not applicable, CI |
| 6 | Unavailable encryption key | A key that cannot be read refuses the restore, erases nothing and overwrites nothing; a key half is never minted on the restore path; and a rotation the keychain refuses still forgets the content, because the file half decides (ADR-0016 section 3, section 6, section 7). | Rust: `crates/ffi/src/persist.rs` `a_missing_file_half_is_never_minted_on_restore`, `ensure_is_stable_and_load_never_mints`, `a_rotation_the_keychain_refused_still_forgot_the_content`, `a_rotation_against_a_keychain_that_answers_nothing_still_erases_the_half`; `crates/ffi/src/lib.rs` `a_locked_keychain_refuses_the_restore_and_leaves_the_directory_alone`. Swift: `PersistenceRoundTripTests.testAForeignCredentialScopeCannotOpenTheFile`. All of it runs against `InMemoryCredentialStore` or a double; `crates/credentials/src/lib.rs` `data_protection_items_are_invisible_to_the_login_keychain` is the real-keychain test and is `#[ignore]`d. | [`locked-keychain.md`](verification-procedures/locked-keychain.md) for the refusals, and [`hardware-verification.md`](../hardware-verification.md) section C for the real keychain round trip the ignored test delegates to. | delano | Not yet run |
| 7 | TTL expiry | Nothing outlives its TTL, a page due while the app was away expires into the ledger on restore, a clock stepped back grants no extra life, and a stamp from the future freezes the countdown rather than draining it (ADR-0016 section 4). | Rust: `crates/core/src/persist.rs` `a_backwards_wall_clock_grants_no_extra_life`, `time_away_drains_the_countdown`, `pages_due_while_away_expire_into_the_ledger_on_restore`; `crates/ffi/src/lib.rs` `a_stamp_from_the_future_reads_as_no_time_away`, `a_stamp_from_the_future_freezes_the_countdown_rather_than_draining_it`, `a_gap_past_the_rung_expires_the_page_into_the_ledger`; `crates/core/src/store.rs` `expiry_is_scheduled_not_polled`, `a_held_page_expires_only_after_hold_plus_frozen_life`. Swift: `TabLifetimeTests.testAnExpiredPageLeavesItsTabStandingAndEmpty`, `.testRelaunchAfterAnOvernightExpiryMintsNothing`. | [`clock-step-back.md`](verification-procedures/clock-step-back.md): the real system clock stepped back a day, which is the one clock the automated tests are not allowed to touch. | delano | Not yet run |

## What every row has to assert

Issue #48 accepts a case only when both halves are asserted, and a test
that shows one without the other is the shape that has already fooled
this project once. The halves are:

1. **The content came back.** Not that the call returned true: that the
   ink typed before the event is readable after it. A restore that
   returns true over an empty pad reads as a pass to any assertion on
   the return value alone, which is exactly how a drained countdown
   presented as success.
2. **Prior state was not overwritten.** When the recovery fails, the
   file on disk is byte for byte what it was, and the session that
   could not read it may not write over it. `grantsSaveLicence` is the
   mechanism; the assertion is the bytes.

Rows 1, 3 and 7 carry the first half through a second handle or a second
`PageModel` reading back what the first one wrote. Rows 4, 5 and 6 carry
the second half by comparing the file's bytes across a mutation and a
settled debounce. Row 2 is the one case where content is legitimately
lost, so its bound is the window rather than the content, and the
non-overwrite half still holds: a refused write leaves the last good
generation in place.

## Keeping this current

- When a persistence test is added, renamed or deleted, edit the row it
  belongs to in the same commit. The names here are the only citation,
  so `grep -c 'fn <name>'` over the file named in the cell is the whole
  verification, and a renamed test that leaves this file untouched is a
  row that silently stops meaning anything.
- When a hardware procedure runs, record it in that procedure's own
  Status line and Results table first, then copy the date and the
  outcome into the last column here. The procedure file is the record;
  this column is an index to it.
- When a case gains a guarantee, cite the ADR-0016 section that decides
  it rather than restating the reasoning. If no section decides it, the
  ADR needs amending before the row does.
- ADR-0016 section 10 states what coverage each case owes. This file
  states what it has. If the two disagree, one of them is out of date,
  and the fastest way to tell which is to run the `grep` in the first
  bullet.
