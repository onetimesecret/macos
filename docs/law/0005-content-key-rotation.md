---
id: 0005-content-key-rotation
title: Content key rotation
status: draft
dated: 2026-10-12
governs: The content key halves rotate while the pad holds no page and on an explicit clear, and a rotation is complete only when the old file half is gone.
decisions: ADR-0016 rotation clause; persistence decision background sections 6 and 9
consumed-by:
  - docs/adr/0041-every-keychain-call-names-its-keychain.md
sources:
  - docs/adr/0016-content-persists-across-restart.md (accepted)
  - docs/plans/trustworthy-persistence-decision-background.md (sections 6 and 9, named by ADR-0016's Context)
  - docs/adr/0028-file-backed-documents-are-a-peer-content-class.md (proposed, drafts under the same key)
  - docs/adr/0004-keychain-prompt-timing.md (accepted)
  - crates/ffi/src/lib.rs, crates/ffi/src/persist.rs, crates/ffi/src/files.rs
---

# Law 0005: Content key rotation

Draft under [behaviour law conventions](README.md); do not build against it as
an accepted law. The drafts-order and superseded-disposal rows were recovered
from code comments at commit `087d682`, which are non-authoritative provenance.

## The rule

[ADR-0016](../adr/0016-content-persists-across-restart.md) (accepted):

> Rotate them when no tab holds a page and when the user explicitly clears
> state. If tabs remain after pages expire, rotate and reseal the tab metadata;
> remove the state file only when no tabs remain.

ADR-0016's Context says its numbered sections "now live in that persistence
decision background rather than in this record". Section 6 of
[that background](../plans/trustworthy-persistence-decision-background.md#6-key-rotation-once-bootmismatch-is-gone)
sets the completion condition: "The rotation has to complete before the
reseal, so that the generation left behind is already undecryptable when it is
unlinked." Whether that pointer counts as explicit incorporation under
AGENTS.md is an open owner decision.

## Why this rule

An emptied pad is a forgetting only if every earlier ciphertext generation,
including unlinked ones, stops being decryptable at that moment. Section 6:
"the sufficient deletion is the file half's". The keychain half "is then
deleted for hygiene, announced but never decisive."

## Operation classes

- **Rotate and reseal.** A save while no tab holds a page: erase the file
  half, then rewrite every file under the content key under fresh halves.
- **Rotate and drop.** No tabs remain, or the user clears: erase the file half,
  then unlink the state file.
- **Dispose without rotating.** A state file in a superseded envelope is
  erased and the save licence granted; no half is touched.
- **Untouched.** The ledger key, which no content rotation reaches.

## The contract

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| Save while no tab holds a page | rotate and reseal | Both halves rotate; tab names, rungs and order reseal under the new key with no content | `crates/ffi/src/lib.rs` `resealing_an_emptied_pad_rotates_the_halves_and_keeps_the_strip` |
| A second save while the pad stays empty | rotate and reseal | Rotates again; the trigger is the state, not the transition | `crates/ffi/src/lib.rs` `a_second_write_over_a_pad_that_is_still_empty_rotates_again` |
| The file half cannot be erased | rotate and reseal | Nothing is resealed; the call reports false and the old generation stays as it was | `crates/ffi/src/lib.rs` `a_reseal_that_could_not_touch_the_half_leaves_the_old_generation_alone` |
| The file half is zeroed but not unlinked | rotate and reseal | Counts as erased; the reseal proceeds | `crates/ffi/src/lib.rs` `a_reseal_that_could_not_unlink_the_half_has_still_forgotten` |
| The keychain refuses or answers nothing | rotate and reseal | The rotation still succeeds on the file half's erasure | `crates/ffi/src/persist.rs` `a_rotation_the_keychain_refused_still_forgot_the_content`, `a_rotation_against_a_keychain_that_answers_nothing_still_erases_the_half` |
| The file half is removed | any rotation | Zeroed, truncated, synced and unlinked, not just unlinked | `crates/ffi/src/persist.rs` `rotation_erases_the_half_rather_than_unlinking_it` |
| Drafts file exists at rotation | rotate and reseal | Rewritten under the new key in the same call | `crates/ffi/src/files.rs` `a_rotation_leaves_the_drafts_readable_under_the_new_key` |
| No drafts file and no open file | rotate and reseal | No drafts file is written | `crates/ffi/src/files.rs` `a_rotation_with_no_drafts_file_writes_none` |
| Order of the two rewrites | rotate and reseal | Drafts before the state file; both attempted, false if either fails. A crash between them loses the tab arrangement, not unsaved typing | owed: no issue yet, an order test with an injected state-write failure |
| No tabs remain | rotate and drop | Halves rotate before the file is unlinked; refuses to unlink if the half survives | `crates/ffi/src/lib.rs` `dropping_the_content_file_rotates_the_halves_with_it` |
| Rotation asked for at a non-content path | refused | Nothing rotated, nothing written | `crates/ffi/src/lib.rs` `a_reseal_refuses_every_path_that_is_not_the_content_file` |
| Superseded state envelope on restore | dispose without rotating | File erased, licence granted, keychain half left in place | `crates/ffi/src/lib.rs` `a_superseded_state_file_is_dropped_so_the_session_can_write` |
| An entry added to `SUPERSEDED_MAGICS` | dispose without rotating | Fails until someone decides whether disposal of that envelope must rotate | `crates/ffi/src/persist.rs` `the_superseded_set_predates_the_key_half_move` |
| Any content rotation or drop | untouched | The ledger key survives | `crates/ffi/src/persist.rs` `rotation_leaves_the_ledger_key_intact`; `crates/ffi/src/lib.rs` `rotating_and_dropping_the_content_key_leave_the_ledger_key_alone` |

The superseded row rests on two sources. Section 9 makes the same choice for
the ledger: "The ledger key is not rotated: the file was authentic under it,
the user's Clear does not rotate it either, and a rotation at launch is the
Keychain prompt ADR-0004 forbids." Extending that to the content envelope is an
interpretation; ADR-0004's Decision is worded for reads. It holds only while
every superseded envelope predates the file half's move into the state
directory, which is what the guard test forces a decision on.

## What the rule forbids

- A latch that remembers whether the last write already rotated.
- Resealing over a file half that could not be erased.
- A rotation that reports success on the keychain delete alone, or failure on
  it alone.
- Writing the state file under the new key before the drafts file.
- A keychain write at launch to dispose of a superseded file.
- A content rotation that reaches the ledger key.

## The rubric for a new interaction

1. Does it write a file sealed under the content key? It joins the rotate and
   reseal class and needs a row for its order relative to the others.
2. Does it run at launch, before the user has asked for anything? It may not
   write the keychain (ADR-0004).
3. Does it delete the state file? It must take the file half with it first.

## Acceptance and tests

- Seam (`crates/ffi`): the tests named in the contract.
- Owed: the drafts-before-state order row.

## Amendments

- 2026-10-12: Drafted from two ADR proposals (drafts before the strip,
  superseded disposal) withdrawn before acceptance in
  onetimesecret/macos#237, in favour of this law.
