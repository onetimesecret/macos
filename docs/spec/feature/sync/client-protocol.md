---
documentation_status: draft # draft | needs-review | reviewed | stale
---

# The sync client protocol, as built

**Status:** draft. This document describes the sync client as built at
commit `26761d9` on `agent/determined-newton-nmsp8a`. It is not
accepted and grants itself no authority.
[relay-protocol.md](relay-protocol.md) governs message shapes
(ADR-0021: "The protocol specification is the authoritative
message-shape record."). Where the built client and an authoritative
document disagree, §10 lists the difference; this document corrects
neither side.

Sections are numbered so code can cite "client protocol §N".

Every rule below is stated from the code and its tests. Each names the
code that implements it and the test that pins it, or says
"untested". Comments in the code are not evidence for anything here.
"Interpretation" marks a consequence reasoned from the code that no
test exercises.

## 1. Scope and owners

| Concern | Owner |
| --- | --- |
| Message shapes, storage contract, what the server does | [relay-protocol.md](relay-protocol.md) §3, §4, §7, §9 |
| Account flow, token lifetimes, the seven gate states | [ADR-0027](../../../adr/0027-account-auth-gates-the-sync-channel.md), [account-auth.md](account-auth.md) |
| Words, header word, sentences, marks | [surface.md](surface.md) |
| The decisions sync rests on | [ADR-0021](../../../adr/0021-multi-device-sync-over-a-blind-relay.md), ADR-0027 |
| Client state, turn order, retries, failure handling, ballots, key packages, as built | this document |

Code is cited by file and item. File names are short for:
`sync_session.rs`, `sync_driver.rs`, `gop.rs`, `pairing.rs`,
`persist.rs` and `lib.rs` in `crates/ffi/src/`; `relay.rs`,
`envelope.rs`, `pad.rs` and `oauth.rs` in `crates/sync/src/`;
`core sync.rs` and `store.rs` in `crates/core/src/`; `transport` for
`crates/transport/src/lib.rs`; `SyncController` for
`shell/Sources/CompanionKit/SyncController.swift`. Test names are
unique in the tree.

The driver functions that touch the network (`pump`, `publish_round`,
`attach_in_flight`, `ensure_engine`, `ensure_access`, `pairing_poll`,
`drain_outgoing`, `detach`, all in `sync_driver.rs`) send through
`SyncConfig::transport()`, which builds a real `UreqTransport`. No test
can drive them over a transport, so their retry paths are untested
unless a row says otherwise.

## 2. Client state

| State | Held in | Persisted |
| --- | --- | --- |
| Device identity, Ed25519 PKCS#8 | key-material account `sync-device-identity` (`pairing::ensure_device_identity`) | yes |
| Channel secret | `sync-channel-secret` (`pairing::ensure_channel_secret`, `store_channel_secret`) | yes |
| Peer records: fingerprint, identity key, label, paired time | `sync-peer-records` (`pairing::peer_records`) | yes |
| Refresh token | `sync-oauth-refresh` (`sync_driver::store_refresh`) | yes |
| Access token | `TokenKeeper` (`oauth.rs`) | no |
| GOP chain: epoch and key | `EngineState.chain` (`gop::GopKeyChain`) | no |
| Key packages, standing and pending | `EngineState.packages`, `EngineState.pending_packages` | no (§5) |
| Delta cursor `next_seq` | `SyncSession` | no |
| Attach snapshot: epoch, `frame_present`, roster | `SyncSession` (`AttachSnapshot`) | no |
| Outbox, in-flight batch and its id | `SyncSession` | no |
| Staged batch: each page's export cursor when the batch was sealed | `SyncState.staged_batch` | no |
| Per enrolled page: export frontier, acknowledged cursor, last published deadline and hold, terminal sent | `SyncState.enrolled` (`PageTracking`) | no |
| Per page channel view: epoch, current, hold live, terminal, ballot | `SyncSession` channels (`PageChannel`, core sync.rs) | no |
| Ballot in flight: page and opened time, proposed or received entropy | `SyncSession` | no |
| Committed frame not yet accepted by the relay | `EngineState.unpublished_frame` | no |
| Gate fault: unreachable or refused | `SyncState.fault` | no |
| Attach in flight | `SyncState.attaching` | no |

Enrolment is per page and in memory (`sync_driver::enrol_page`):
enrolling defers the page's compaction to the channel and starts its
export frontier at the pristine version, so the first publish carries
the whole page; withdrawing returns the page to solo compaction. Test:
`enrolment_sweeps_the_whole_page_once_and_then_only_changes`.

The chain is rebuilt from the channel secret at epoch 0 whenever an
engine is built (`ensure_engine`) and when a pairing grant lands
(`absorb_mailbox`). §8 states what that costs.

**Dissolve** (`dissolve_engine`; on detach, sign-out and a refused
refresh) drops the engine (session, chain, packages), the staged batch
and any pairing in flight. It rewinds each page's export frontier to
its acknowledged cursor and forgets the last published deadline, hold
and terminal flag, so the next sweep restates them. Tests:
`a_sign_out_mid_session_keeps_the_unpublished_edits_for_the_next_attach`,
`an_acknowledged_batch_is_not_owed_again_after_a_sign_out`,
`an_answer_to_a_resent_batch_acknowledges_only_what_that_batch_carried`.

**Clock.** The engine's windows (§3) run on `SyncState::now_ms`, a
`std::time::Instant`. The core's `SystemClock` uses a sleep-inclusive
clock instead (`continuous_now`, core `clock.rs`). Interpretation: on
Darwin the 2 s and 60 s windows do not advance while the machine
sleeps.

## 3. The turn

One turn is `companion_sync_pump` (`sync_driver::pump`). The core mutex
is held only between round trips. In order:

1. `ensure_access`: refresh when no access token is held (§4.2). A
   failure ends the turn with its reason.
2. `sweep_outbound`: queue each enrolled page's ops past its export
   frontier; its expiry policy when the deadline moved by more than
   1 s (`DEADLINE_JITTER_MS`); its hold register when it changed
   (`hold_moved`, same jitter on `until_wall_ms`); and, once, the
   signed terminal marker of a page that died here (§6). Rotate when
   a ceremony is owed (§7.1).
3. `SyncSession::tick`: ballot patience (§7.7).
4. Publish if the 2 s clock allows and anything is queued or in flight
   (`publish_due`, `stage_publish`, `publish_round`; §4.4).
5. Long poll (`fetch_request`, `wait` held to 25) and absorb (§4.5).
6. Attach if a ceremony committed this turn or a key package is owed
   (§5.4). The result is discarded.
7. Publish the committed frame, if one is unaccepted (§4.6).

Test for the order: untested.

| Interval | Value | Code | Source | Test |
| --- | --- | --- | --- | --- |
| Publish clock | 2 s | `PUBLISH_INTERVAL_MS` | relay-protocol §8 | `the_publish_clock_coalesces_to_two_second_grain` |
| Long poll `wait` | at most 25 s | `LONG_POLL_WAIT_S`, `SyncSession::fetch_request` | relay-protocol §8 | `a_long_poll_never_asks_the_relay_to_wait_past_the_spec` |
| Ballot patience | 60 s | `BALLOT_PATIENCE_MS` | relay-protocol §5 | `a_ballot_that_outlives_its_patience_abandons_onto_the_old_gop` |
| Shell re-pump after a quiet turn | immediate | `SyncController.pumpTurn` (`.again`) | relay-protocol §8 | `testARefusedBearerUnderTheLongPollIsNotAFreeRound` |
| Shell retry after an unreachable or unauthorized turn | 30 s | `SyncController.armRetry` | account-auth.md §2 "on the retry clock rather than at once" and §5 "retry follows the publish clock, not a hot loop"; neither gives 30 s | same |
| Shell attach retry after a quiet refusal | 30 s, doubling to 300 s, no cap on tries | `attachRetryDelay`, `attachBacksOff` | none: built behaviour with no spec source | `testQuietAttachRefusalsBackOffToAFiveMinuteCeiling`, `testAQuietRefusalAfterAnUnreachableTurnStillBacksOff` (added during the task that wrote this document) |
| Pairing poll | 1 s, repeating | `SyncController.armPairingPoll` | none | untested |
| Editing mark | 90 s | `SyncController.elsewhereWindow` | surface.md §6 | `testAPageKeepsItsMarkOnlyWhileTheEditIsRecent` |

**Single flight.** One pump at a time (`SyncController.pumping`). One
attach at a time: `SyncState.attaching` and `AttachFlight` answer a
second attach `busy`, and the flag clears on every way out, a poisoned
lock included. Test:
`a_second_attach_while_one_is_in_flight_is_refused_as_busy`.

**The shell's verdict on a turn** (`SyncController.settlePump`,
`pumpTurn`):

| Turn outcome | Shell does |
| --- | --- |
| reason `signed_out` | stop pumping; trouble `signedOut` |
| reason `not_attached` | attach again |
| any `unreachable` event, or `ok` false | trouble `unreachable`; retry in 30 s |
| any `unauthorized` event | refresh status; retry in 30 s |
| otherwise | pump again at once |

Events: `rejoin_required` and `epoch_conflict` set trouble `behind`,
which only a rejoin clears (surface.md §4); `applied`,
`countdown_moved` and `terminal` refresh the model; `applied` marks
the page as edited elsewhere; `ceremony_proposed` and
`ceremony_committed` refresh status; `protocol` and
`ceremony_required` change nothing. A turn from a session that has
since ended is dropped whole. Tests:
`testARefusedBearerUnderTheLongPollIsNotAFreeRound`,
`testFallingBehindSurvivesAnUnreachableBlip`,
`testATurnFromAStoppedSessionIsNotTheReplacementsTurn`. Event kinds
are listed in `lib.rs` `companion_sync_pump`.

## 4. Per-message behaviour

Shapes are relay-protocol §4 and §7 and are not restated. Status
mapping (`relay.rs` `refusal`): `401` Unauthorized, `409`
EpochConflict, `410` Rejoin, `413` CeremonyRequired; any other non-2xx,
and a 2xx whose body does not parse, is `Protocol(status)`. Tests:
`the_protocol_statuses_map_to_their_moves`,
`an_attach_answer_without_a_roster_is_refused_not_guessed`,
`frame_404_is_absent_not_an_error`.

### 4.1 Transport bounds

Every sync request uses `SyncConfig::transport()`, a fresh
`UreqTransport::bounded(token host, relay host)` per call.

| Bound | Value |
| --- | --- |
| DNS resolve | 10 s |
| Connect and TLS; send request line and headers | 15 s each |
| First byte of the answer | 60 s |
| Request body; response body | 120 s each, whole body |
| Whole call | 360 s |
| Response body size | 10 MiB (`BODY_LIMIT`) |
| Scheme, redirects, hosts | `https://` only; no redirect followed (a `3xx` is returned as is); the two allowlisted hosts only |

A transport error (any timeout, a refused host, a body over the limit)
reaches the caller as one failure; §4.2 to §4.9 say what each caller
does with it. Tests: `every_phase_of_a_call_is_bounded_and_the_long_poll_fits`,
`the_agent_follows_no_redirect_and_speaks_only_tls`,
`bounded_refuses_a_third_destination_before_any_socket_opens`,
`bounded_compares_hosts_not_prefixes`,
`refuses_a_plaintext_url_before_any_socket_opens`,
`the_transport_is_bounded_to_the_two_destinations`.

### 4.2 Refresh

`sync_driver::ensure_access` runs when no access token is held: at the
top of every turn, at attach, at each pairing poll, and after a `401`
on attach or publish. A `401` on any relay route that goes through the
session drops the access token (`SyncSession::note_refusal`).

| Answer | Effect | Test |
| --- | --- | --- |
| 2xx with an access token | token held; a rotated refresh token is stored (a store refusal is only logged); an unreachable fault clears | `keeper_rotates_the_refresh_token_on_every_use`, `a_server_that_declines_to_rotate_keeps_the_grant_alive` |
| 4xx naming `invalid_grant` | sign-out: refresh token deleted, engine dissolved, fault refused; reason `signed_out` | `only_invalid_grant_pronounces_the_grant_dead`, `refresh_refused_signs_out_and_keeps_nothing`, `a_refused_refresh_names_its_state_and_leaves_the_pad_whole` |
| any other answer: 5xx, 429, 403, another 400, malformed body | refresh token kept; fault unreachable; reason `unreachable` | `a_throttled_token_endpoint_is_not_a_dead_grant`, `a_4xx_that_named_no_error_keeps_the_grant`, `an_unwell_token_endpoint_does_not_sign_the_keeper_out` |
| transport failure | as the row above | untested |
| no refresh token held | sign-out; reason `signed_out` | untested |

ADR-0027 governs: "On a relay `401`, refresh once and retry once.
Delete the refresh token and sign sync out only when the token
endpoint reports `invalid_grant`". A lost refresh answer is §10.28.

### 4.3 Attach

`sync_driver::attach` takes the `AttachFlight`, then `ensure_engine`,
`ensure_access`, and sends the pending package if one waits, else the
standing one (§5).

| Answer | Effect | Reason | Test |
| --- | --- | --- | --- |
| 2xx | first attach adopts `next_seq`; a re-attach keeps the live cursor; the snapshot and roster are replaced; `adopt_accepted` (§5.2); unreachable fault clears | `ok` with `epoch`, `frame_present`, `peers` | `the_attach_roster_becomes_ceremony_peers_only_through_the_pairing_records`; cursor rule untested |
| first `401` | access dropped; refresh; rebuild with the then-current package; send once more | | untested |
| second `401` | `attach_refused`: sign-out as for a refused refresh (§10.2) | `signed_out` | `a_second_401_on_one_attach_deletes_the_grant` (the helper, not the loop) |
| any other answer: `409`, `410`, `413`, 5xx, malformed | nothing changes | `refused` | untested |
| transport failure | fault unreachable; pending package kept | `unreachable` | untested |

Before the request: `busy` (another attach in flight), `poisoned`,
`not_configured`, `keychain` (identity, fingerprint, channel secret or
mint refused), `signed_out` (no sign-in, or no access token after
refresh), `not_attached`. The full set of reasons is these and the
table's. `lib.rs` `companion_sync_attach` logs every refusal except
`unreachable` and `busy` to diagnostics.

**The shell's handling** (`SyncController.settleAttach`,
`settledTrouble`, `attachRetries`, `attachBacksOff`):

| Core reason | Trouble, before the gate | Retried | Delay |
| --- | --- | --- | --- |
| `unreachable` | `unreachable` | yes | 30 s |
| `busy` | none | yes | 30 s |
| `keychain`, `refused`, `not_attached`, anything unnamed | none | yes | 30 s doubling to 300 s, counted by reason |
| `signed_out` | `signedOut` | no | |
| `not_configured`, `poisoned` | `notConfigured` | no | |

The gate then wins where it names a condition (`reconciled`): `off`,
`signed_out`, `refused` and `unreachable` replace the inferred trouble.
A trouble of `signedOut`, `refused` or `notConfigured` arms no retry.
A retried quiet refusal shows no sentence; the core's diagnostics
record it. Success resets the backoff and starts the pump. A null answer from the
seam reads as `not_configured` (`CompanionClient.syncAttach`). Tests:
`testAnAttachRefusalDefersToTheGateThatKnowsWhy`,
`testAnAttachRefusalTheGateCannotExplainIsRetried`,
`testQuietAttachRefusalsBackOffToAFiveMinuteCeiling`,
`testAQuietRefusalAfterAnUnreachableTurnStillBacksOff`.

### 4.4 Publish deltas

`SyncSession::publish_request` seals each queued envelope, padded
(`pad::pad`), under the current chain, borrowing the outbox: one seal
refusal leaves the whole queue for the next tick. Once every seal
succeeds the batch moves in flight with a fresh id, and
`stage_publish` records each enrolled page's export cursor against
that id. An in-flight batch is resent byte for byte before anything
new is sealed. The request carries the chain epoch at send time.

| Answer | Batch | Cursors and record | Event | Test |
| --- | --- | --- | --- | --- |
| 2xx | cleared | acknowledged cursors move to the recorded cursors, never to the live ones; unreachable fault clears | | `an_answer_to_a_resent_batch_acknowledges_only_what_that_batch_carried`, `a_late_acceptance_never_moves_a_settled_cursor_back` |
| `401` | kept; publish clock reopened; access dropped | record kept | after refresh, one resend; a second `401` is an `unauthorized` event | `a_401_keeps_the_batch_for_one_retry_and_a_409_drops_it` (session half); driver loop untested |
| `409`, `410` | dropped | record dropped; acknowledged cursors stay; export frontiers are not rewound (§10.18) | `epoch_conflict` or `rejoin_required` | `a_401_keeps_the_batch_for_one_retry_and_a_409_drops_it` |
| `413` | kept | record kept | `ceremony_required`; `rotate_channel` on the first enrolled page by id (§10.13) | untested |
| other status | kept; resent on the next tick | record kept | `protocol` | untested |
| transport failure | kept | record kept; fault unreachable | `unreachable` | untested |

A resend carries no idempotency key, so the relay may store a batch
twice. Receivers tolerate duplicates: an ops import that moves nothing
is not an arrival (§6), a proposal already held is skipped, and an
accept counts once (§7.5). Test for duplicates:
`deltas_round_trip_and_the_terminal_gate_needs_a_current_view` (the
echo half). Padding: `sealed_blobs_reach_the_wire_in_power_of_two_buckets`,
`buckets_are_powers_of_two_with_a_floor_and_a_linear_tail`.

### 4.5 Fetch deltas

`SyncSession::fetch_request` asks from `next_seq` with `wait` held to
25. Any answer at all clears an unreachable fault (`note_reachable` in
`pump`).

| Answer | Effect | Event | Test |
| --- | --- | --- | --- |
| 2xx | `next_seq` advances; each blob is opened under the current chain, unpadded and decoded, and any that fails is skipped silently; envelopes dispatch (§6) | per envelope; `rejoin_required` when the batch epoch is above the chain's, and then no channel is marked current; otherwise every channel is marked current | `deltas_round_trip_and_the_terminal_gate_needs_a_current_view`, `two_devices_confirm_a_ceremony_at_the_same_stream_position` |
| `410` | `next_seq` unchanged (§10.15) | `rejoin_required` | untested |
| `401` | access dropped | `unauthorized`; the shell waits 30 s and the next turn refreshes | `testARefusedBearerUnderTheLongPollIsNotAFreeRound` (shell); core untested |
| other status, malformed | nothing | `protocol` (§10.15) | untested |
| transport failure | fault unreachable | `unreachable` | untested |

### 4.6 Publish frame

At the end of every turn, the driver moves a frame staged by a commit
into `EngineState.unpublished_frame` and PUTs it at the chain's
epoch, without a welcome. Every committing device does this, not only
the proposer (§7.8).

| Answer | Effect |
| --- | --- |
| 2xx or `409` | frame dropped |
| any other status, `401` included | frame kept; PUT again next turn; a `401` does not drop the access token |
| transport failure | frame kept; no fault noted, no event |

Test: untested. `relay.rs` `parse_publish_frame` exists and has no
caller.

### 4.7 Fetch frame

`SyncSession::fetch_frame_request` and `absorb_frame` have no caller.
§8.

### 4.8 Pairing mailbox

`sync_driver::pairing_poll`: refresh if needed (an unreachable refresh
reports stage `waiting`; any other failure reports `failed` with its
reason), post the queue, fetch the tail, advance, post again, report.

| Message | Answer | Effect |
| --- | --- | --- |
| post (`drain_outgoing`) | 2xx | the head leaves the queue, only if it is still the message posted |
| post | any other answer, transport failure | the queue stays; the round goes on to the fetch |
| fetch `?since=` | 2xx | `since` takes `next_seq`; each message advances the state machine (§9); unknown shapes are skipped |
| fetch | any other answer, transport failure | ignored |

No route here recognises `401`: the access token is not dropped and no
refresh follows (§10.2). Duplicates and this device's own echoes leave
the state machine where it is. There is no client deadline (§10.27).
Tests: untested over a transport; the state machine is §9.

### 4.9 Detach

`sync_driver::detach` dissolves the engine first, hands the keeper
back so the sign-in survives, then posts a detach if an access token
was held. The answer, a `401` and a transport failure are all ignored.
An unpublished frame is dropped with the engine. Test: untested.

## 5. Key packages

### 5.1 Wire forms

The role of a key package is relay-protocol §6.

- Package: `x25519_pub(32) ‖ signature(64)`. The signature is Ed25519
  over `signing_domain(KEY_PACKAGE_SIGN_CONTEXT, x25519_pub)`
  (`KeyPackageKeeper::mint`) and is checked against the identity key
  in this device's pairing record for that fingerprint
  (`KeyPackage::verify`, `SyncSession::ceremony_peers`).
- Sealed entropy: `eph_pub(32) ‖ AEAD body`. The AEAD key is HKDF of
  the X25519 shared secret with `ENTROPY_WRAP_INFO` as salt and info;
  `ENTROPY_MAGIC` is the associated data (`KeyPackage::seal_entropy`,
  `wrap_key_from`).

Tests: `key_packages_verify_seal_and_spend_once`,
`a_transcript_signature_cannot_pose_as_a_key_package`.

### 5.2 Lifecycle

A package's private half is a ring X25519 ephemeral key: it agrees
once and is consumed, and it is never persisted. The engine holds a
standing package and at most one pending package.

| State | Entered by | Reachable by a proposer | Leaves by |
| --- | --- | --- | --- |
| Standing, unpublished | first engine build mints it (`ensure_engine`) | only if the relay took the attach and the answer was lost | the first attach's 2xx publishes it; if that attach fails, the next one mints a pending package rather than resending this one |
| Standing, published | attach 2xx (`adopt_accepted`) | yes, while the proposer's roster names it | any open attempt: spent; a re-attach adds a pending package beside it, which replaces it when accepted |
| Standing, spent | an open attempt took the private half | no; the relay may still name it | an attach carrying a replacement is accepted |
| Pending | a re-attach with no pending package mints one | only if the relay took the attach and the answer was lost | attach 2xx matched by value: standing, published; a proposal opens with it: standing, published, spent; tried and failed: dropped; attach refused or unanswered: stays, and the next attach resends it unchanged |
| Lost | relaunch, detach, sign-out (`dissolve_engine`) | no | the next engine mints afresh |

A re-attach with a pending package waiting mints nothing and reads no
Keychain (`ensure_engine`); that is what makes a retried attach
idempotent. A re-attach with none waiting reads the Keychain and
mints. Tests:
`a_re_attach_keeps_the_standing_package_until_the_relay_takes_its_replacement`,
`a_mint_is_not_a_publication`; the no-mint resend is untested.

### 5.3 Try order and spend rules

`open_proposal_entropy`, called only from a follower's proposal path
(§7.4):

1. A payload shorter than 32 bytes plus the sealed-body floor is
   refused before either key is touched; nothing is spent.
2. The standing package is tried first. If it opens, the pending one
   is left untouched and still owed.
3. Otherwise the pending one is tried. If it opens, it becomes the
   standing package, published and spent. If it fails, it is dropped.
4. If neither opens, both are spent and the device stays out of the
   ballot.

The device's own proposal echo never reaches a try (§7.4). Tests:
`opening_entropy_spends_the_package_whether_or_not_it_opens`,
`a_proposal_sealed_to_the_standing_package_leaves_the_pending_one_owed`,
`a_proposal_sealed_to_the_pending_package_opens_and_adopts_it`,
`a_proposal_neither_package_opens_drops_the_pending_one`,
`a_payload_too_short_to_try_leaves_both_packages_where_they_were`,
`a_device_joins_a_ballot_sealed_to_the_package_it_has_not_heard_accepted`.

Nothing checks the proposer before the try, so any holder of the
current GOP key can spend a device's packages (§7.9).

### 5.4 Republish

`package_needs_republish`: the standing package is spent or
unpublished, or a pending one waits, and no ballot is in flight. The
turn attaches when that holds or when a ceremony committed this turn,
once per turn (§3 step 6). Tests:
`a_spent_package_with_no_ballot_in_flight_is_owed_a_fresh_attach`,
`a_fresh_package_whose_attach_never_landed_is_owed_another`; the
commit trigger is untested.

Republishing refreshes the relay's copy of this device's package. It
does not refresh this device's copy of its peers' packages, which
changes only when this device's own attach is accepted (§10.11).

The one-shot design's rationale is in Amendment 1, which is proposed:
"Rejected: durable key-package private halves." Divergence: §10.25.

### 5.5 Attach and turn interleaving

`ensure_engine` releases the lock before the request is built. A turn
that runs in that gap can open a proposal with the pending package
(§5.3 step 3), and the attach then sends the standing package, now
spent; its acceptance marks it published, and §5.4 owes a replacement
once no ballot is in flight. Turning sync off and on during a long
poll leaves the old turn running in the core beside the new session's
attach; `AttachFlight` serialises the two attaches. Test: untested.

## 6. Inbound envelopes

The plaintext encoding is `envelope.rs` (`DeltaEnvelope`,
`ControlPayload`); an unknown shape is skipped. Page ids travel as 32
lowercase hex characters (`page_wire_id`).

| Envelope | Handling | Test |
| --- | --- | --- |
| Ops | `PageChannel::admit_delta(batch epoch)`: a terminal page refuses; an equal epoch applies; any other epoch emits `rejoin_required`. Applied only to a page held here (`sheet_of`). `applied` is emitted only when the document version moved, so an echo of this device's own publish is not an arrival. An import the store refuses is dropped silently. | `deltas_round_trip_and_the_terminal_gate_needs_a_current_view`, `a_peers_delete_only_batch_is_still_an_arrival`, `deltas_admit_by_epoch_and_a_stale_device_rejoins` |
| Expiry | Published as the wall-clock pair read off the live countdown, anchor now and the remaining life (`SheetStore::expiry_policy`); each receiver computes its own deadline from the sum. `store.rs` `observe_peer_expiry` may shorten a running countdown, never extend it (ADR-0021: "the earliest known expiry wins"); a held page ignores it; `countdown_moved` when it moved | `two_stores_share_an_expiry_and_the_earlier_deadline_fires`, `a_peer_expiry_can_only_shorten_and_the_hold_ignores_it` |
| Hold | The register carries the pause machine's state, never the press. `PageChannel::note_hold` and `observe_peer_hold`, applied in stream order; a live hold suspends the countdown; `countdown_moved` when it moved | `a_live_hold_suspends_the_countdown_on_every_device`, `a_peer_register_extends_the_hold_never_the_life`, `a_hold_survives_a_peers_offline_deadline_and_the_returner_rejoins` |
| Terminal | `marker_trusted`: the marker is exactly `page_id(16) ‖ wall_ms(8) ‖ signature(64)`, its page id equals the envelope's, and the signature verifies over `signing_domain(TERMINAL_SIGN_CONTEXT, claim)` under this device's own identity key or a peer record's (`pairing::trusted_identities`). Then the page is terminal and entombed (`observe_terminal`); `terminal`. | `deltas_round_trip_and_the_terminal_gate_needs_a_current_view` |
| Control | §7 | §7 |

Ops, Expiry and Hold carry no signature (§7.9).

**Publishing a terminal marker.** `sweep_outbound` mints it
(`signed_terminal_marker`) for an enrolled page no longer held here,
once per engine. `SyncSession::queue_terminal` queues it only while
`PageChannel::may_publish_terminal` holds: the view is current, no hold
is live, and the page is not already terminal. Queuing marks the page
terminal locally. Tests: `the_terminal_gate_needs_a_current_view_and_no_live_hold`,
`terminal_is_absorbing`,
`a_page_that_died_here_publishes_its_marker_once_the_view_is_current`.
The view becomes current at the first drain and nothing makes it stale
again (§10.24).

## 7. Ceremonies and ballots

### 7.1 Triggers and target

| Trigger | Target | Code | Test |
| --- | --- | --- | --- |
| An enrolled page's deferred transition is due (`SheetStore::ceremony_due`) | that page | `sweep_outbound` | `the_rotation_targets_the_page_whose_ceremony_is_due` |
| This device queued a terminal marker this sweep | a due page, else the first live enrolled page by id; with no live page, no rotation | `sweep_outbound` | `a_page_that_died_here_publishes_its_marker_once_the_view_is_current` |
| A publish answered `413` | the first enrolled page by id, live or not | `publish_round` | untested |

`rotate_channel` proposes a ballot to the verified peers (§7.3), or
runs a solo ceremony when there are none (§7.2). While a ballot is in
flight both refuse, so a page that stays due proposes again at the
first sweep after the ballot ends.

### 7.2 Solo ceremony

`SyncSession::solo_ceremony`: no ballot. Compact the target page,
advance the chain, stage the frame, and move every page channel to the
new epoch, at once. The sweep then settles the page's cursors (§7.6).
Devices missing from this device's roster, and attached devices
without a record, are left behind. Test:
`a_due_transition_with_an_empty_room_rotates_the_channel_solo`.

### 7.3 Membership

| Side | Members | Code |
| --- | --- | --- |
| Proposer | itself, plus `ceremony_peers`: the roster from this device's last accepted attach, minus itself, minus devices without a pairing record, minus packages that fail verification against the record | `SyncSession::propose_ceremony`, `ceremony_peers` |
| Follower | the keys of the proposal's `entropy_sealed`, unfiltered | `SyncSession::dispatch_control` |

The proposer seals entropy to its own package as well as each peer's;
its own entry is never opened, since it skips its own echo. The ballot
id is a random id in hex. Each member counts as
`ballot_token(fingerprint)`, the first 16 bytes of its SHA-256. Tests:
`the_attach_roster_becomes_ceremony_peers_only_through_the_pairing_records`,
`a_late_attacher_cannot_vote_and_a_second_proposal_cannot_stack`;
follower membership is untested. Divergence: §10.5.

### 7.4 Joining a proposal

A follower handles a proposal in this order and stays out at the first
check that fails. Only step 5 can spend a package.

1. The ballot id is not one this device already holds, as proposer or
   follower.
2. No ballot is in flight here. One ballot at a time is built
   behaviour; relay-protocol §5 states no such rule (§10.8).
3. The page id parses, the page is held here, and its channel is not
   terminal.
4. `entropy_sealed` has an entry for this device's fingerprint.
5. The entry opens (§5.3); if neither package opens, the device stays
   out and logs a fault.

Then it opens the ballot with the members of §7.3, records the page
and the time, keeps the entropy, and queues its accept. Tests:
`a_proposal_for_a_page_this_device_does_not_hold_spends_nothing`,
`a_device_joins_a_ballot_sealed_to_the_package_it_has_not_heard_accepted`,
`two_devices_confirm_a_ceremony_at_the_same_stream_position`.

### 7.5 Counting accepts

An accept counts only when read back off the stream, the device's own
included; the proposer queues its own accept with the proposal. It
counts only while a ballot is in flight, only for the held ballot id,
and only for a named member (`CeremonyBallot::accept`). The relay
orders the stream totally, so every device that sees the same accepts
reaches confirmation at the same position. Tests:
`two_devices_confirm_a_ceremony_at_the_same_stream_position`,
`a_ballot_confirms_only_when_every_attached_device_accepts`.

### 7.6 Commit

On the accept that completes the ballot (`dispatch_control`):

1. `gop::ceremony_commit`: `SheetStore::perform_ceremony` compacts the
   target page only and snapshots it; the chain advances with the
   ballot's entropy; the snapshot is sealed under the new key, unpadded.
   If the store refuses (the page is gone), nothing rotates and the
   ballot waits for its patience.
2. `PageChannel::complete_ceremony`; every page channel moves to the
   new epoch; the frame is staged; `ceremony_committed`.
3. The driver settles the page (`settle_frontier`): export frontier
   and acknowledged cursor move to the rebuilt version, and the page
   leaves any staged batch, so the rebuild travels only as the frame
   and a late acknowledgement cannot lower the cursor.

Tests: `the_ceremony_rotates_and_rebuilds_as_one_event_or_not_at_all`,
`two_devices_confirm_a_ceremony_at_the_same_stream_position`,
`a_late_acceptance_never_moves_a_settled_cursor_back`.

Chain derivation: Appendix A.

### 7.7 Abandonment

`SyncSession::tick`, once per turn before the publish: a ballot open
for 60 s or more on this device's clock is abandoned. Scope, entropy
and the page's ballot clear; the epoch stays. A follower's window runs
from when it took the proposal, not from when it was proposed. A
package spent on the abandoned ballot stays spent (§5.4). Tests:
`a_ballot_that_outlives_its_patience_abandons_onto_the_old_gop`
(proposer), `an_unconfirmed_ceremony_leaves_every_device_on_the_old_gop`;
follower abandonment is untested. Abandonment is local and never goes
on the stream (§10.9).

### 7.8 Frame publication

Every committing device stages its own frame and PUTs it (§4.6). The
first PUT at current+1 wins at the relay; a `409` drops the loser's
frame, and the loser keeps its advanced chain and its own rebuild.
Nothing fetches or adopts the winner's frame. Each rebuild types the
body into a fresh document under a freshly minted peer id
(`document.rs` `compact` path). Interpretation: after a ceremony that
two devices both committed, their later ops share no history and are
refused on the other side. Amendment 1, which is proposed, predicts
the same: "without that adoption, two rebuilds share no history and
the winner's later deltas are refused on the losers". Test: untested
(`two_devices_confirm_a_ceremony_at_the_same_stream_position` stops at
building the PUT). Divergence: §10.7.

### 7.9 Who may propose

Built behaviour:

- `ControlPayload::Propose` and `ControlPayload::Accept` carry no
  signature and no sender (`envelope.rs`). Any holder of the current
  GOP key can seal either.
- A follower checks nothing about who proposed (§7.4). Members are
  whoever the proposal's map names (§7.3). An accept counts for
  whichever fingerprint it names (§7.5).
- Revocation (`pairing::revoke_peer`, `lib.rs`
  `companion_sync_revoke_peer`, `SyncController.revoke`) deletes the
  local record. It starts no ceremony and tells the relay nothing.
- The relay keeps serving a revoked device. Attach is account-gated:
  relay-protocol §4 says "it proves nothing about device trust (ADR-0021
  §3)". The revoked device's own attach hands it every peer's package.
- Pairing records are read only when sending: who this device seals to
  (`ceremony_peers`) and whose terminal markers count
  (`trusted_identities`). Never when receiving a proposal or an accept.

Consequences, all interpretation and untested:

1. A revoked device that still holds the current key can propose. Its
   own unmodified client does so at its next due transition, since its
   records still list the others. Every device that opens its entry
   accepts, the revoker included. The proposer chose the entropy, so
   it derives the next key and stays in. It can also leave any device
   out of the map.
2. A forged accept can confirm a ballot for a member who never
   accepted. A one-entry map makes a single device commit alone. Both
   split the channel.
3. A ballot that cannot confirm (one naming a fingerprint that never
   accepts) holds the one ballot slot for 60 s and spends the members'
   packages. Repeated, no honest rotation starts, and the revoked device
   keeps the key.
4. Ops, Expiry and Hold are unsigned too. An Expiry whose deadline is
   already past makes the page due on every peer
   (`observe_peer_expiry` shortens to it), which bypasses the gate the
   terminal marker's signature exists for.

What does stop it: an honest ceremony that leaves the device out and
commits first (the chain property is pinned by
`a_device_excluded_from_a_ceremony_cannot_follow_the_chain`). Nothing
schedules one on revocation.

Authoritative wording this bounds or contradicts:

- relay-protocol §5 has the proposer seal entropy "never under the
  current GOP key, which a just-revoked device still holds". As built,
  nothing stops the just-revoked device from being the proposer.
- relay-protocol §5, of the welcome, which is not built: "a revoked
  device, omitted from the map, waits forever, which is revocation
  working."
- surface.md §3: "Revoking removes this Mac's trust in that device, so
  key rotations this Mac starts seal nothing new to it; what it already
  holds, it holds, and a device paired from more than one Mac must be
  revoked on each." True as built for rotations this Mac starts; it
  does not cover a rotation the revoked device starts.
- surface.md §3, of an attached stranger: "It can open nothing
  (ADR-0021 section 5)". A revoked device is listed as one (§10.31).

Any statement that a revoked device loses access at the next ceremony
is unsupported for a ceremony that device proposes.

### 7.10 Signed ceremony messages (proposed, not accepted)

**Status:** proposed. Neither binding nor built. It needs the owner's
acceptance before any spec or code adopts it.

The minimal shape, consistent with the signing already in the tree
(`persist::signing_domain`, `marker_trusted`):

- **Propose** gains `proposer` (an identity fingerprint) and `sig`:
  Ed25519 by the proposer's identity key over
  `signing_domain(<new versioned context>, epoch ‖ ballot_id ‖ page ‖ H)`,
  where `H` covers every entry of `entropy_sealed` in map order: the
  fingerprint, a hash of the X25519 key the entry was sealed to, and a
  hash of the sealed blob. The signature must cover every entry, or a
  key holder could keep a valid signature and swap in its own entropy.
- **Accept** gains `sig` over `signing_domain(<second new context>,
  epoch ‖ ballot_id ‖ device_fingerprint)`, and carries the signer's
  identity key so that `device_fingerprint` is checkable as its hash.
- **Receivers**, before trying any package: honour a proposal only from
  a proposer whose identity key is in their own pairing records,
  verified as `marker_trusted` verifies a marker; require the proposer
  to be in the map and the epoch to equal the chain's; use the
  per-entry key hash to try only the package the entry was sealed to.
  Honour an accept only if its signature verifies under the key that
  hashes to its fingerprint.
- A new context must not be a prefix of an existing one, since
  `signing_domain` concatenates without a length (Appendix A).

It is client-only: relay-protocol §9 has the relay "Store blobs; never
parse one.", and both messages ride sealed in the delta stream. No C
ABI change.

Stated costs:

- relay-protocol §6 says key packages are "the reason two devices that
  never paired directly (both paired with a third) can still run
  ceremonies together". Requiring a recorded proposer refuses such a
  device's proposals. The built client already gives such a device no
  ceremony seat and no marker trust (§7.3, §6).
- Mixed versions: old clients ignore the new fields; new clients must
  refuse unsigned proposals, so a channel with both cannot rotate until
  all upgrade.

It fixes neither the split across an abandoned ballot (§10.9) nor the
stale-roster livelock (§10.11), and it leaves Ops, Expiry and Hold
unsigned.

Open questions:

1. What membership a receiver should demand: a record for every member,
   or only for the proposer.
2. Partition: devices whose records differ (a device revoked on one Mac
   and not another) can still disagree about who may propose.
3. Whether revocation should propose a ceremony at once. Amendment 1,
   proposed, asks that "the revoking device proposes a ceremony
   promptly".

## 8. Rejoin and recovery, as built

- Three things emit `rejoin_required`: a `410` on fetch, a batch epoch
  above the chain's, and an Ops envelope at another epoch (§4.5, §6).
  The shell shows `behind`, which only a rejoin clears.
- No rejoin exists: no frame is fetched or adopted (§4.7). A `410`
  leaves `next_seq` where it was, so every turn asks again (§10.15).
- The chain lives only in memory. A relaunch, a detach, a sign-out,
  turning sync off and on, and a pairing grant all root it at epoch 0.
  After the channel's first ceremony, any of them leaves the device
  behind for good (§10.23).
- A device behind the relay's epoch has its publishes refused with
  `409` and dropped (§4.4).
- The designed recovery is relay-protocol §5's welcome paragraph and
  Amendment 1, which is proposed. Neither is restated here.

## 9. Pairing, the client side

The rendezvous is relay-protocol §7. Inviter A holds the channel
secret; joiner B wants it.

| Step | Message | Client behaviour |
| --- | --- | --- |
| 1 | Commitment, A to B: `SHA-256(eph_A ‖ identity_A ‖ blind)` | queued at `invite_begin` |
| 2 | Offer, B to A: B's identity and ephemeral public keys | sent when B's poll finds a commitment (`Joiner::accept`) |
| 3 | Reveal, A to B: A's identity and ephemeral keys, the blind, A's transcript signature | sent when A finds the offer (`Inviter::settle`); B checks the commitment opens and the signature verifies (`Joiner::settle`) |
| 4 | Short authentication string on both screens | stage `sas`; a mismatch on either side drops that side's ceremony whole (`pairing_confirm(false)`) |
| 5 | Acceptance, B to A: B's transcript signature | posted only after B's human confirms |
| 6 | Grant, A to B: the channel secret sealed to the exchange | queued only once the acceptance verified and A's human confirmed, in either order (`maybe_grant`) |

- **Persistence order.** The inviter records the peer before it queues
  the grant; a refused record fails the step `keychain` (`maybe_grant`),
  and a channel secret it minted for the grant stays stored with no
  peer. The joiner records the peer, then stores the secret; either
  refusal fails the step `keychain` (`advance_pairing`), and a record
  left without a secret puts the device on no channel. Either way, no
  device holds the secret while its granter is a stranger to it.
- **Why this order.** The commitment comes before B's contribution,
  so a machine in the middle gets one guess at the string rather than
  a grinding attack; substituted keys move the transcript and the
  string with it. The grant is sealed under a key derived from the
  X25519 shared secret and the transcript, and the ephemeral private
  keys never leave their devices, so the relay carries only
  ciphertext it cannot open.
- **The joiner's secret** replaces any it founded, and the chain
  re-roots at epoch 0 (`absorb_mailbox`; §8).
- **Stage word.** A ceremony whose step is done but which still has a
  post queued reports `confirmed`, so the shell keeps polling until the
  grant is out (`stage_json`).
- **Begin.** Requires an engine (`not_attached`), no ceremony already
  in flight (`busy`), an identity (`keychain`) and entropy
  (`no_entropy`). One ceremony at a time.
- **Fingerprint:** lowercase hex SHA-256 of the identity public key
  (`pairing::identity_fingerprint`).

Tests: `two_devices_pair_over_the_mailbox_and_the_grant_lands`,
`a_confirmation_that_queues_the_grant_does_not_report_done`,
`the_grant_leaves_the_inviter_when_the_shell_polls_by_the_stage_word`,
`a_failed_comparison_aborts_with_nothing_recorded`,
`the_ceremony_agrees_on_one_string_and_delivers_the_channel_secret`,
`a_machine_in_the_middle_moves_the_string_and_opens_nothing`,
`a_reveal_that_does_not_open_the_commitment_refuses_whole`,
`walking_away_leaves_both_devices_unpaired`,
`no_secret_crosses_the_ceremony_in_the_clear`,
`the_ceremony_survives_the_mailbox_wire_form`,
`the_wire_form_carries_no_secret_either`,
`a_recorded_peer_lists_by_fingerprint_and_a_revocation_removes_it`.

## 10. Known divergences and gaps

Each entry quotes the authoritative wording with its location, names
the built code, and gives one line of consequence. Where no
authoritative wording exists, the entry says so. This document moves
neither side.

**Authority questions**

**10.1 Amendment 1: proposed, yet folded in.** relay-decision-background.md
Amendment 1 has the status "proposed". ADR-0021's accepted Decision
says "A key frame carries a per-enrolled-device welcome that seals the
incoming epoch key to that device's verified key package" and "Persist
each device's current GOP chain position.", and relay-protocol §3, §4,
§5 and §8 cite "ADR-0021 Amendment 1". Built: neither
the welcome nor the persisted chain (§8). Consequence: it is unclear
which text binds. Owner decides which side moves.

**10.2 The second `401`.** ADR-0027: "Delete the refresh token and sign
sync out only when the token endpoint reports `invalid_grant`".
account-auth.md §5: "Refresh once, retry once; on second `401`, treat
as refresh refused." account-auth-decision-background.md: "A second
`401` on the same round is treated as the grant being dead rather than
as a loop to keep running." Built, per route: attach signs out on a
second `401` (`attach_refused`); publish reports `unauthorized` and
keeps the token (`publish_round`); fetch never retries within the turn;
frame publish and the pairing mailbox do not recognise `401` at all
(§4.6, §4.8). Consequence: the routes disagree with each other and
with the documents. Owner decides which side moves.

**10.3 ADR-0007 cited as binding.** ADR-0007 has the status
"proposed". relay-protocol §9: "no server document may promise
otherwise (ADR-0007)." Consequence: the rule's authority is unclear. Owner decides which side moves.

**Ceremony**

**10.4 Who may propose; revocation.** relay-protocol §5 has the
proposer seal entropy "never under the current GOP key, which a
just-revoked device still holds". Amendment 1, proposed, asks that "the
revoking device proposes a ceremony promptly". Built: §7.9; propose and
accept are unsigned and unchecked, and revocation starts no ceremony.
Consequence (interpretation): a revoked device that still holds the
current key can author the next epoch's entropy and stay in. Owner
decides which side moves.

**10.5 Membership.** relay-protocol §5: "When every attached device has
accepted (`PageChannel::ceremony_confirmed`; attachment per §4's attach
list at proposal time)". Built: §7.3; attached devices without a
record are never members, and followers trust the proposer's map.
Consequence: a ballot can confirm with attached devices left out. Owner decides which side moves.

**10.6 Composite frame.** relay-protocol §2: "when a ceremony runs,
every enrolled page compacts", and the frame is "every enrolled page's
post-compaction snapshot, one blob". Built: one page compacted and
framed (`gop::ceremony_commit`, `SheetStore::perform_ceremony`).
Consequence: a rejoining device could adopt one page at most; other
pages only take the new epoch. Owner decides which side moves.

**10.7 Who publishes the frame, and the loser.** relay-protocol §5:
"the proposer publishes the frame, which purges", and, in the welcome
paragraph, "a proposer answered `409` destroys its candidate key and
welcome and takes the rejoin path itself". ADR-0021 Consequences:
"Coordinated compaction, canonical frame election, loser adoption, and
safe re-entry of unpublished local edits become protocol obligations."
Built: §7.8. Consequence (interpretation): after a two-device
ceremony, cross-device ops fail. Owner decides which side moves.

**10.8 One ballot at a time.** No authoritative wording: relay-protocol
§5 states no concurrency rule. Built: §7.4 step 2. Consequence: a
second proposal goes unanswered and fails. Owner decides which side moves.

**10.9 Abandonment is local; a sleeper can commit alone.**
relay-protocol §5: "A ballot not confirmed within 60 seconds is
abandoned (`PageChannel::abandon_ceremony`): every device stays on the
old GOP, and the next transition proposes again." Built: §7.7; the
check runs once per turn on a sleep-frozen clock, each device times its
own window, and a still-due page proposes at the next sweep rather than
the next transition. Consequence (interpretation): a device that slept
through a ballot the proposer then abandoned reads the proposal and the
proposer's accept, adds its own, confirms, commits alone and publishes
its frame, which the relay accepts, so the proposer is left behind. Owner decides which side moves.

**10.10 A device that accepted and then slept.** relay-protocol §5: "A
device that accepted and then slept still holds the sealed entropy in
its fetched stream: on waking it advances its chain and opens the new
epoch." Built: entropy is used only inside a ballot that confirms on
this device; once peers commit and the frame purges, the remaining
accepts are gone and the device gets `410` (§8). Consequence
(interpretation): it stays behind. Owner decides which side moves.

**10.11 The stale-roster livelock.** No authoritative wording. Built:
the proposer's roster changes only at its own accepted attach (§5.4),
and a proposer never spends its own package, so it is never owed one.
Consequence (interpretation): after a follower spends a package on an
abandoned ballot and republishes, the proposer's later ballots are
sealed to the spent package, each try spends the follower's new one,
and the channel cannot rotate until the proposer re-attaches for
another reason. Owner decides which side moves.

**10.12 A terminal marker's ceremony.** relay-protocol §5: "After
publishing a page's signed terminal marker (ADR-0021 §6), the publisher
immediately proposes a ceremony". Built: §7.1; the proposal is queued
in the same sweep as the marker and only if a live enrolled page can
anchor it. Consequence: with no live page left, the dead page's
ciphertext stays openable until a later ceremony. Owner decides which side moves.

**10.13 The `413` remedy cannot be published.** relay-protocol §3: "At
the cap the relay refuses further publishes with `ceremony_required`"
and "A refused publisher proposes a size-triggered ceremony"; §4:
"Control and content share the stream so the relay cannot distinguish
them." Built: a `413` keeps the batch in flight, the proposal goes to
the outbox, and nothing new is sealed while a batch is in flight
(§4.4); the target is the first enrolled page by id, live or not.
Consequence (interpretation): a channel with peers at the cap wedges;
with a dead first page, the proposal can never commit. Owner decides which side moves.

**10.14 The solo commit after a `413` skips settling.** No
authoritative wording beyond ADR-0027's "Never rewind across a
compaction boundary or silently discard unpublished work." Built:
`publish_round` discards `rotate_channel`'s result, so a solo commit
there does not call `settle_frontier`, unlike the sweep. Consequence
(interpretation): the next sweep exports the rebuilt body as a delta
from the stale frontier. Owner decides which side moves.

**Wire and timing**

**10.15 `410` recovery, and two hot loops.** relay-protocol §4: "`410
rejoin` is the whole recovery story." account-auth.md §5: "retry
follows the publish clock, not a hot loop." Built: §4.5 and §8; a `410`
leaves `next_seq` unchanged, and a `410` or `protocol` turn still
reports `ok`, so the shell pumps again at once. Consequence
(interpretation): against a relay that answers at once, the client
loops at network speed. Owner decides which side moves.

**10.16 A resent batch takes the new epoch.** No authoritative wording.
Built: a resend carries the chain epoch at send time (§4.4), but its
blobs stay sealed under the key they were sealed with. Consequence
(interpretation): after a commit, peers cannot open the resent blobs,
yet on a 2xx the acknowledged cursors of pages other than the ceremony
page advance past them. Owner decides which side moves.

**10.17 Publish latency.** relay-protocol §8: "a fetch returning empty
re-polls immediately: delivery latency is bounded by the publish clock,
not the poll." Built: publishing happens only at the top of a turn,
after the previous long poll returned (§3). Consequence: an edit made
during a quiet poll waits up to 25 s. Owner decides which side moves.

**10.18 A dropped batch waits for a dissolve.** ADR-0027: "Advance a
Page's export cursor permanently only after relay acknowledgement."
and "Never rewind across a compaction boundary or silently discard
unpublished work." Built: a `409` or `410` drops the batch and leaves
the export frontier advanced; the ops are exported again only after the
engine dissolves (§2, §4.4). Consequence: those edits do not reach
peers until sync is turned off and on, signed out, or relaunched. Owner decides which side moves.

**10.19 Padding.** relay-protocol §8: "to the next power-of-two size,
256 bytes minimum, 64 KiB maximum bucket". Built: plaintext is padded
(`pad::bucket`), above 64 KiB to multiples of 64 KiB; the key frame is
not padded (§7.6). Consequence: the frame's exact size reaches the
relay. Owner decides which side moves.

**10.20 Publish clock on a `401`.** relay-protocol §8: "Publish at most
every 2 seconds per channel". Built: the `401` resend reopens the clock
(§4.4). Consequence: minor; two requests can fall inside 2 s. Owner decides which side moves.

**10.21 The delta cap against the body limit.** relay-protocol §3: the
buffer "is capped: 8 MiB or 4096 blobs, whichever comes first". Built:
a response body over 10 MiB is a transport failure (§4.1), and base64
of 8 MiB exceeds 10 MiB; the spec does not say whether fetch answers
are paginated. Consequence (interpretation): a device fetching a full
buffer in one answer sees `unreachable` on every turn. Owner decides which side moves.

**10.22 Sub-channel epochs.** No authoritative wording. Built: a
`PageChannel` starts at epoch 0 (`Default`), and a commit moves only
the channels that exist at that moment; a channel created later by an
arriving envelope starts at 0. Consequence (interpretation): after a
ceremony, Ops for a page first seen afterwards are refused as
`rejoin_required`. Owner decides which side moves.

**Persistence and state**

**10.23 The chain is not persisted.** ADR-0021: "Persist each device's
current GOP chain position." and "A device that missed a ceremony
adopts the authenticated current checkpoint rather than deriving
missed keys." Built: §2 and §8. Consequence: any relaunch or detach
after the first ceremony leaves the device behind for good. Owner decides which side moves.

**10.24 The current flag never goes stale.** ADR-0021: "a stale peer
may discard its own copy but may not publish the terminal marker until
current with the hold state." Built: `set_current(true)` after each
drain, and no caller ever sets it false. Consequence (interpretation):
after a sleep, a page that expired publishes its marker before the
first post-wake drain. Owner decides which side moves.

**10.25 Key packages are one-shot.** relay-protocol §6: "a static X25519
public key signed by its Ed25519 identity key". Built: §5. Consequence:
the standing and pending lifecycle, republish debt and single-flight
attach have no spec. Owner decides which side moves.

**10.26 The relay drops idle channels.** relay-protocol §3: "a channel
with no authenticated write for 8 days (the 7-day ceiling rung plus the
24-hour hold ceiling) is dropped whole". Built: no client handling.
Consequence (interpretation): a client whose chain is past epoch 0
meets a recreated channel at epoch 0 with refused publishes. Owner decides which side moves.

**10.27 The pairing mailbox.** relay-protocol §7: "The mailbox holds one
pairing at a time and evaporates on completion, abandonment, or after
an hour." account-auth.md §4: "Offline, the client does not refresh
preemptively and does not retry on a timer tighter than its publish
clock". Built: no message tells the relay a pairing ended; the client
has no deadline (a comment in `pairing_confirm` says the peer "times out
on its own patience", and no patience exists); the shell polls every
1 s with no in-flight guard; `401` is not recognised (§4.8).
Consequence: only the relay's hour ends a mailbox, and an offline
device retries every second. Owner decides which side moves.

**10.28 A lost refresh answer.** No authoritative wording. Built: a
transport failure keeps the old refresh token (§4.2). Consequence
(interpretation): if the server had rotated it, the next refresh
replays a retired token, and reuse detection would sign the device
out. Owner decides which side moves.

**10.29 Forgetting while a peer sleeps.** relay-protocol §2: "This is
more forgetting than a solo page gets, never less". Built: a deferred
page compacts only on a confirmed ballot, and every rostered peer with
a record is a member (§7.3). Consequence (interpretation): one asleep
peer makes every ballot abandon, so enrolled pages keep their history,
and the buffer heads for the cap of §10.13. Owner decides which side moves.

**10.30 Small built behaviours with no spec.** The pump's owed attach
discards its answer, so with the Keychain locked it reads the Keychain
every turn (§3 step 6). Turning sync off while an attach is in flight
leaves the core attached until that attach returns (interpretation).
No authoritative wording for either. Owner decides which side moves.

**Surface and docs**

**10.31 A revoked device in the device list.** surface.md §3, of an
attached stranger: "It can open nothing (ADR-0021 section 5)". Built: a
revoked device is listed as an attached stranger
(`sync_driver::devices_json`) and keeps the current key until an
honest rotation excludes it (§7.9). Consequence: the sentence is false
for that device. Owner decides which side moves.

**10.32 Waiting versus awake.** surface.md §4: "A channel attached with
pages enrolled and no peer awake reads `sync waiting` rather than
`synced`". Built: `SyncController.currentPeers` counts roster entries
with an attach time, not awake peers, and `headerWord` shows `sync
waiting` for zero peers with nothing enrolled. Consequence: an asleep
rostered peer reads `synced`; the QA procedure's Check 4 expectation
(`docs/qa/verification-procedures/sync-enrolment.md` Check 4) would
fail. Owner decides which side moves.

**10.33 Built sentences differ from surface.md.** surface.md §5:
"the relay cannot be reached; edits stay local and sync retries" and
"waiting on your browser to finish signing in; Settings can give up on
it". Built (`SyncController.sentence`): "sync could not reach the
server; edits stay local and sync retries" and "waiting on the browser
to finish signing in; Settings can give up on it". account-auth.md §5
uses "sync could not reach the server". Consequence: surface.md owns
the words and does not match the build. Owner decides which side moves.

**10.34 C ABI documentation drift.** The `companion_sync_attach`
documentation in `lib.rs` and `companion_ffi.h` says it will "mint and
publish a fresh key package" and "adopt the relay's cursor"; a re-attach
with a pending package mints nothing, and only the first attach adopts
the cursor (§4.3, §5.2). The `companion_sync_pump` header gives events
as `{"kind", "page"?}`; `lib.rs` and the code add `page_id`. The `lib.rs`
documentation of `companion_sync_signin_finish` omits `busy`, which the
code returns and the header lists. The `signed_out` event kind is
documented, but `SyncEvent::SignedOut` is never constructed; sign-out
reaches the shell as the turn's reason. The `AttachFlight`
documentation bounds its wait by "the transport's whole-call bound",
but one attach can make four sequential calls. No authoritative
wording: these documents are the shell contract. Owner decides which side moves.

## Appendix A. Signing contexts, info strings, magics

`persist::signing_domain(context, payload)` is `context ‖ payload`,
with no length prefix. No context below is a prefix of another.

| Name | Value | Role | Defined in |
| --- | --- | --- | --- |
| `KEY_PACKAGE_SIGN_CONTEXT` | `ots-companion-key-package-v1` | Ed25519 context, key packages | `sync_session.rs` |
| `TERMINAL_SIGN_CONTEXT` | `ots-companion-terminal-v1` | Ed25519 context, terminal markers | `sync_session.rs` |
| `TRANSCRIPT_SIGN_CONTEXT` | `ots-companion-pairing-transcript-v1` | Ed25519 context, pairing transcripts | `pairing.rs` |
| `ENTROPY_WRAP_INFO` | `ots-companion-entropy-wrap-v1` | HKDF salt and info, entropy wrap key | `sync_session.rs` |
| `ENTROPY_MAGIC` | `OTSENTR1` | AEAD associated data, sealed entropy | `sync_session.rs` |
| `PAIRING_SAS_INFO` | `ots-companion-pairing-sas-v1` | HKDF info, short authentication string | `pairing.rs` |
| `PAIRING_WRAP_INFO` | `ots-companion-pairing-wrap-v1` | HKDF info, grant wrap key | `pairing.rs` |
| `PAIRING_GRANT_MAGIC` | `OTSPAIR1` | AEAD associated data, the grant | `pairing.rs` |
| `GOP_KEY_INFO` | `ots-companion-gop-transport-key-v1` | HKDF info, every chain key | `persist.rs` |
| `GOP_ROOT_SALT` | `ots-companion-gop-root-salt-v1` | HKDF salt, the root key | `persist.rs` |
| `GOP_MAGIC` | `OTSGOPD1` | header of a sealed delta or frame | `persist.rs` |

The chain (`gop.rs` `GopKeyChain::root`, `advance`):

```text
key[0]   = HKDF(salt: GOP_ROOT_SALT, ikm: channel_secret, info: GOP_KEY_INFO)
key[n+1] = HKDF(salt: key[n],        ikm: entropy[n],     info: GOP_KEY_INFO)
```

Salting each key with its predecessor means a device without key[n]
cannot derive key[n+1]; the entropy keeps out a device the proposer did
not name, though not the proposer (§7.9). The root comes from the
channel secret, never from the content key, so a paired device that
has never held a page can compute it. `advance` replaces the key, so
the outgoing one is wiped as it drops. A
sealed delta or frame is `magic(8) ‖ epoch(8, big-endian) ‖ nonce ‖
ciphertext ‖ tag`, the header authenticated as associated data
(`GopKeyChain::seal`); `open` refuses anything not sealed at the
chain's current epoch. Tests:
`ciphertext_sealed_under_the_outgoing_key_does_not_open_under_the_incoming`,
`every_paired_device_derives_the_same_chain`,
`a_device_excluded_from_a_ceremony_cannot_follow_the_chain`,
`a_gop_rotation_never_touches_the_ledger_key_or_the_content_halves`.
