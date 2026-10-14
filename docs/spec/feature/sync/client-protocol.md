---
documentation_status: draft # draft | needs-review | reviewed | stale
---

# The sync client protocol, as built

**Status:** draft, not accepted; grants itself no authority and changes
no spec. Describes the client at `50044ad`, with the deadline gate that
`4fde3d8`, `ba3d5eb`, `999d011` and `b6600bb` added (§2, §3, §4.4,
§7.1, §7.4, §7.6).
[relay-protocol.md](relay-protocol.md) governs message shapes (ADR-0021:
"The protocol specification is the authoritative message-shape
record."). §7.10 is a proposal. Rules cite code; a named test pins its
rule, and naming none claims nothing either way; "(interpretation)"
marks a consequence reasoned from code. Cite as "client protocol §N".
The code and tests for §5's lifecycle, single-flight attach, the
shell's attach backoff and §4.1's bounds were written during the task
that produced this document. They show behaviour, not project acceptance.

## 1. Scope and owners

Shapes, storage, server: relay-protocol.md §3, §4, §7, §9. Account and
gate: [ADR-0027](../../../adr/0027-account-auth-gates-the-sync-channel.md),
[account-auth.md](account-auth.md). Words: [surface.md](surface.md).
Decisions: [ADR-0021](../../../adr/0021-multi-device-sync-over-a-blind-relay.md).
Relay implementers: §4 (§4.4 no idempotency key; §4.6 and §7.8 a frame
PUT from every committer; §5.4 repeated attaches) and §10 rows marked S.
The driver functions that send have no transport seam and no test.

## 2. Client state

Persisted (key-material): `sync-device-identity`, `sync-channel-secret`,
`sync-peer-records`, `sync-oauth-refresh`. All else is memory only:

| State | Held in |
| --- | --- |
| GOP chain (epoch, key), rebuilt at epoch 0 (§8); standing and pending key package (§5); committed frame not yet accepted | `EngineState` |
| `next_seq`; attach snapshot (epoch, `frame_present`, roster); outbox; in-flight batch and id; ballot scope (page, opened time) and entropy | `SyncSession` |
| Staged batch: each page's export cursor when the batch was sealed | `SyncState.staged_batch` |
| Enrolled pages (enrolling defers compaction and starts the export frontier at the pristine version; a page past its deadline does not enrol, `a_page_past_its_deadline_does_not_enrol_and_gives_the_relay_nothing`), each with its export frontier, acknowledged cursor, last published deadline and hold, terminal sent | `SyncState.enrolled` |
| Per page channel: epoch, current, hold live, terminal, ballot | `PageChannel` |

**Dissolve** (detach, sign-out, refused refresh) drops the engine,
staged batch and pairing, and rewinds each export frontier to its
acknowledged cursor so the next sweep restates the rest
(`a_sign_out_mid_session_keeps_the_unpublished_edits_for_the_next_attach`).

## 3. The turn

`companion_sync_pump` (`sync_driver::pump`); the core mutex is held
only between round trips.

| Step | Code | Rule |
| --- | --- | --- |
| 1 | `ensure_access` | refresh if no access token (§4.2); a failure ends the turn |
| 2 | `sweep_outbound` | queue ops past each export frontier, expiry when its deadline moved over 1 s, hold when changed, a dead page's marker (§6); rotate if owed (§7.1). A page past its deadline (ADR-0052) or gone queues no ops, and its unsealed ops are withdrawn (`a_page_past_its_deadline_gives_the_relay_no_ops_queued_or_new`, `a_closed_page_seals_no_queued_ops_and_its_rotation_anchors_before_a_deadline`); its expiry, hold and marker still queue |
| 3 | `tick` | abandon a ballot open 60 s (`BALLOT_PATIENCE_MS`, relay-protocol §5; §7.7) |
| 4 | `publish_round` | if `PUBLISH_INTERVAL_MS` (2 s, relay-protocol §8) has passed and anything is queued or in flight (§4.4) |
| 5 | `fetch_request` | long poll, `wait` at most 25 s (`LONG_POLL_WAIT_S`, relay-protocol §8; §4.5) |
| 6 | `attach` | if a ceremony committed this turn or a package is owed (§5.4); result discarded |
| 7 | frame PUT | a committed frame not yet accepted (§4.6) |

The engine clock (`SyncState::now_ms`) is an `Instant`, stopped during
sleep on Darwin (interpretation). One pump runs per shell session
(`SyncController.pumping`; §10). Shell retry (`pumpTurn`,
`settledTrouble`, `attachBacksOff`), numbers from no spec:

| Turn outcome, event or attach reason | Trouble | Retry and delay |
| --- | --- | --- |
| `signed_out`, from a turn or an attach | `signedOut` | none |
| turn reason `not_attached` | unchanged | attach at once |
| turn with an `unreachable` event, or `ok` false | `unreachable` | 30 s |
| turn with an `unauthorized` event | from the gate | 30 s |
| any other turn, `protocol` and `ceremony_required` included | unchanged | pump at once |
| event `rejoin_required` or `epoch_conflict` | `behind` | as the turn |
| attach `unreachable`; attach `busy` | `unreachable`; none | 30 s |
| attach `keychain`, `refused`, `not_attached`, any unnamed reason | none, so no sentence; the core logs it | 30 s, doubling to 300 s, no cap |
| attach `not_configured`, `poisoned`, or a null seam answer | `notConfigured` | none |

A status refresh takes the gate's `off`, `signed_out` or `refused` as
the trouble, and `unreachable` unless `behind` stands (`reconciled`).
surface.md §4: "Only a rejoin ends it." Built, only an account-axis
fact (off, signed out, refused, not configured), sync off or sign-out
replaces `behind`, and no rejoin exists (§8).

## 4. Per-message behaviour

Shapes: relay-protocol §4, §7. `relay.rs` `refusal` maps `401`, `409`,
`410`, `413`; anything else, or an unparseable 2xx, is `Protocol`. A
`401` through the session drops the access token (`note_refusal`).

### 4.1 Transport bounds

Each request builds a fresh `UreqTransport::bounded`: DNS 10 s; connect
and TLS, and request headers, 15 s each; first byte 60 s; each body
120 s; whole call 360 s; response body 10 MiB; `https://` only, no
redirect followed, the two allowlisted hosts only
(`the_transport_is_bounded_to_the_two_destinations`). Breaching any is
one transport failure.

### 4.2 Refresh

`ensure_access`, when no access token is held. A 2xx holds it, stores a
rotated refresh token (a refusal is logged) and clears an unreachable
fault. A 4xx naming `invalid_grant`, or no refresh token, signs out:
token deleted, engine dissolved, fault refused, reason `signed_out`.
Anything else keeps the token, with fault and reason `unreachable`
(`only_invalid_grant_pronounces_the_grant_dead`).

### 4.3 Attach

`attach`: `AttachFlight`, `ensure_engine`, `ensure_access`, then the
pending package if one waits, else the standing one (§5). All refusals
but `unreachable` and `busy` are logged; shell handling is §3.

| Answer | Effect | Reason |
| --- | --- | --- |
| before the request | nothing sent; `busy` from `AttachFlight` (`a_second_attach_while_one_is_in_flight_is_refused_as_busy`); `signed_out` also when no access token or configuration remains | `busy`, `poisoned`, `not_configured`, `keychain`, `signed_out`, `not_attached` |
| 2xx | first attach adopts `next_seq`, a re-attach keeps it; roster replaced; `adopt_accepted` (§5.2); unreachable fault cleared | `ok` |
| first `401` | refresh; rebuild with the then-current package; send once more | |
| second `401` | sign-out (§10.2) | `signed_out` |
| any other answer | nothing changes | `refused` |
| transport failure | fault unreachable; pending package kept | `unreachable` |

### 4.4 Publish deltas

Envelopes are padded and sealed under the chain (one seal refusal keeps
the queue); `stage_publish` records each page's export cursor. An
in-flight batch is resent byte for byte at the current epoch before
anything new is sealed; with no idempotency key, §6, §7.4 and §7.5
absorb duplicates.

| Answer | Batch | Cursors and record | Event |
| --- | --- | --- | --- |
| 2xx | cleared | acknowledged cursors move to the recorded ones (`an_answer_to_a_resent_batch_acknowledges_only_what_that_batch_carried`) | |
| `401` | kept; clock reopened | refresh and resend once: a second `401` is only the event, a failed refresh ends the round silently, a failed resend reports `unreachable` without a fault | `unauthorized` |
| `409`, `410` | dropped | record dropped; export frontier not rewound | `epoch_conflict`, `rejoin_required` |
| `413` | kept | `rotate_channel` on the first enrolled page by id held here before its deadline (`live_anchor`) | `ceremony_required` |
| any other answer | kept; resent next tick | | `protocol` |
| transport failure | kept | fault unreachable | `unreachable` |

### 4.5 Fetch deltas

| Answer (from `next_seq`; any answer clears an unreachable fault) | Effect |
| --- | --- |
| 2xx | `next_seq` advances; each blob is opened under the chain, unpadded and decoded, or skipped silently; envelopes dispatch (§6); a batch epoch above the chain's emits `rejoin_required` and marks no channel current, otherwise every channel is marked current |
| `410` | `next_seq` unchanged; `rejoin_required` |
| `401` | access dropped; `unauthorized` |
| any other answer | `protocol` |
| transport failure | fault unreachable; `unreachable` |

### 4.6 Frames

Every committing device PUTs its staged frame at the chain epoch,
without `welcome`, at the end of the turn (§7.8). A 2xx or `409` drops
it; anything else (a `401`, with access kept; a transport failure, with
no fault or event) keeps it for the next turn. Nothing fetches a frame:
`fetch_frame_request` and `absorb_frame` have no caller (§8).

### 4.7 Pairing mailbox

`pairing_poll`: refresh (unreachable reports `waiting`, other failures
`failed`), post, fetch from `since`, advance (§9), post again. Posting
with no token, engine or transport reports `failed`, `signed_out`; a
2xx post drops the head if unchanged, a 2xx fetch moves `since`, other
answers change nothing. No `401` handling, no client deadline.

### 4.8 Detach

`detach` dissolves the engine (an unpublished frame is lost), keeps the
sign-in, and posts a detach if it held a token, ignoring the answer.

## 5. Key packages

### 5.1 Wire forms

A package (role: relay-protocol §6) is `x25519_pub(32) ‖ sig(64)`,
Ed25519 over `signing_domain(KEY_PACKAGE_SIGN_CONTEXT, x25519_pub)`
(contexted because transcript signatures travel in the clear), checked
against this device's pairing record before anything is sealed to it
(`the_attach_roster_becomes_ceremony_peers_only_through_the_pairing_records`).
Sealed entropy: `eph_pub(32) ‖ AEAD body`, HKDF (`ENTROPY_WRAP_INFO`),
`ENTROPY_MAGIC` as associated data. The private half is a ring X25519
ephemeral key, spent by one agreement and never persisted.

### 5.2 Lifecycle

| State | Entered by | Reachable by a proposer | Leaves by |
| --- | --- | --- | --- |
| Standing, unpublished | first engine build | only if the relay took an attach whose answer was lost | the first attach's 2xx publishes it; after a failed first attach, the next mints a pending package instead |
| Standing, published | attach 2xx (`adopt_accepted`, matched by value) | while the proposer's roster names it | any open attempt spends it; a re-attach adds a pending package |
| Standing, spent | an open attempt | no | an accepted replacement |
| Pending | a re-attach with none waiting (reads the Keychain, mints) | only if the relay took an attach whose answer was lost | 2xx: standing, published; opens a proposal: standing, published, spent; tried and failed: dropped; unanswered: kept and resent unchanged, with no Keychain read |
| Lost | relaunch, detach, sign-out | no | the next engine mints |

### 5.3 Try order

`open_proposal_entropy`, follower path only (§7.4): a payload under 32
bytes plus the sealed-body floor spends nothing; the standing package
is tried first (one already spent refuses untried, so the pending one
is tried even if never accepted); a pending one that opens becomes
standing, published and spent, one that fails is dropped; neither
opening spends both
(`a_proposal_neither_package_opens_drops_the_pending_one`). Own echoes
never reach a try; nothing checks the proposer (§7.9).

### 5.4 Republish

`package_needs_republish`: standing spent or unpublished, or a pending
one waiting, with no ballot in flight
(`a_spent_package_with_no_ballot_in_flight_is_owed_a_fresh_attach`);
the turn then attaches once. Peers' packages refresh only at this
device's own accepted attach (§10).

### 5.5 Attach and turn interleaving

`ensure_engine` releases the lock before the request is built. A turn
in that gap may adopt and spend the pending package; the attach then
sends the spent standing one, and §5.4 owes a replacement.

## 6. Inbound envelopes

Encoding: `envelope.rs`; unknown shapes are skipped; page ids are 32
lowercase hex characters. Ops, Expiry and Hold are unsigned (§7.9).

| Envelope | Handling |
| --- | --- |
| Ops | `admit_delta(batch epoch)`: a terminal page refuses; an equal epoch applies to a page held here; any other emits `rejoin_required`. `applied` only if the document version moved, so an echo is not an arrival; store refusals are dropped silently. |
| Expiry | the wall-clock pair read off the live countdown; `observe_peer_expiry` shortens, never extends (ADR-0021: "the earliest known expiry wins"); a held page ignores it |
| Hold | the register's state, never the press, applied in stream order; a live hold suspends the countdown |
| Terminal | `marker_trusted`: exactly `page_id(16) ‖ wall_ms(8) ‖ sig(64)`, the envelope's page id, signed over `signing_domain(TERMINAL_SIGN_CONTEXT, claim)` by this device or a peer record (`trusted_identities`); then the page is entombed (`deltas_round_trip_and_the_terminal_gate_needs_a_current_view`) |
| Control | §7 |
| outbound marker | for an enrolled page no longer held, minted every turn until one queues, once per engine, under `may_publish_terminal` (current, no live hold, not terminal); drains set `current` and nothing clears it (§10) |

## 7. Ceremonies and ballots

### 7.1 Triggers

| Trigger | Target |
| --- | --- |
| a deferred transition is due (`ceremony_due`) | that page |
| this device queued a terminal marker | a due page, else the first live enrolled page by id; with none, no rotation |
| a publish answered `413` | the first live enrolled page by id; with none, no rotation |

A live page here is one held before its deadline: a page past it would
refuse the commit (§7.6), so it is never a target, since `ceremony_due`
answers false for it, or an anchor
(`a_page_past_its_deadline_owes_no_ceremony_and_cuts_no_key_frame_before_its_sweep`,
`a_closed_page_seals_no_queued_ops_and_its_rotation_anchors_before_a_deadline`).
`rotate_channel` proposes (§7.3) or runs solo (§7.2), never during a
ballot, so a page still due proposes again.

### 7.2 Solo ceremony

`solo_ceremony` commits at once as §7.6 does; devices absent from this
device's roster, or without a record, are left behind.

### 7.3 Membership

Proposer: itself (sealing to its own package, never opened) plus
`ceremony_peers`, its last accepted roster minus devices without a
pairing record or with a package failing verification. Follower: the
keys of `entropy_sealed`, unfiltered (untested). Members count as
`ballot_token`, the first 16 bytes of SHA-256 of the fingerprint.

### 7.4 Joining a proposal

A follower stays out at the first failed check, only the last
spending: the ballot id is new; no ballot is in flight (relay-protocol
§5 has no such rule); the page is held, before its deadline and not
terminal (`a_proposal_for_a_page_past_its_deadline_here_spends_nothing`);
`entropy_sealed` names it; its entry opens (§5.3; failure is logged).
It then opens the ballot and queues its accept.

### 7.5 Counting accepts

An accept counts only read back off the stream (own included; the
proposer queues its accept with the proposal), during a ballot, for the
held id and a named member, so devices commit at the same position
(`two_devices_confirm_a_ceremony_at_the_same_stream_position`).

### 7.6 Commit

On the completing accept, `ceremony_commit` compacts the target page
only, advances the chain with the ballot's entropy and seals the
snapshot, unpadded, under the new key; existing page channels take the
new epoch, the frame is staged, and `settle_frontier` moves both
cursors to the rebuild, which travels only as the frame. A store
refusal (page gone, not enrolled or past its deadline; entropy already
consumed) rotates nothing
(`the_ceremony_rotates_and_rebuilds_as_one_event_or_not_at_all`,
`a_page_past_its_deadline_owes_no_ceremony_and_cuts_no_key_frame_before_its_sweep`).
A device that accepted before the page's deadline and meets the
completing accept after it therefore stays on the old epoch while its
peers advance (interpretation). A frame or batch sealed before the
deadline still goes out on its retry: the frame PUT is what moves the
relay's epoch.
A seal refusal leaves the chain advanced but moves no channel and
stages no frame, here and in `solo_ceremony` (interpretation).

### 7.7 Abandonment

`tick`, once per turn: a ballot open 60 s on this device's clock is
abandoned; scope, entropy and the page's ballot clear, the epoch stays,
and a spent package stays spent (§5.4). A follower times from receipt.
Abandonment never goes on the stream (§10).

### 7.8 Frame publication

Every committer PUTs its own frame (§4.6); the first at current+1 wins.
A `409` loser keeps its advanced chain and rebuild; nothing adopts the
winner. Rebuilds mint fresh peer ids, so later ops between two
committers share no history and are refused (interpretation).

### 7.9 Who may propose

- Propose and accept are unsigned and name no sender (`envelope.rs`); a
  follower checks nothing about the proposer, takes the map's keys as
  members and counts an accept for whatever fingerprint it names.
  Pairing records are read only when sending.
- Revocation (`revoke_peer`) deletes the local record, starts no
  ceremony and tells the relay nothing; relay-protocol §4 makes attach
  account-gated ("it proves nothing about device trust (ADR-0021 §3)")
  and serves the roster, so a revoked device that attaches gets every
  peer's package.
- (interpretation) A revoked device with the current key can propose,
  as its own client does when a transition is due; members accept, and
  it derives the next key from its own entropy and stays in. Forged
  accepts or a one-entry map commit without a member; repeated
  unconfirmable ballots spend packages and hold the slot; a
  past-deadline Expiry expires the page on peers without a live hold.
- Only an honest ceremony that excludes it and commits first stops it
  (`a_device_excluded_from_a_ceremony_cannot_follow_the_chain`).
- relay-protocol §5: "never under the current GOP key, which a
  just-revoked device still holds". surface.md §3: "key rotations this
  Mac starts seal nothing new to it" (silent on one the revoked device
  starts) and, of a stranger, as a revoked device is listed, "It can
  open nothing".

### 7.10 Signed ceremony messages (proposed, not accepted)

**Status:** proposed, not accepted; neither binding nor built.
**Date:** 2026-10-12

- Propose would add `proposer` and `sig`: Ed25519 over
  `signing_domain(<new context>, epoch ‖ ballot_id ‖ page ‖ H)`, `H`
  covering every `entropy_sealed` entry in map order (fingerprint, a
  hash of the key it was sealed to, a hash of the blob), so a key holder
  could not swap in its own entropy.
- Accept would add `sig` over `signing_domain(<second context>, epoch ‖
  ballot_id ‖ device_fingerprint)` and carry the signer's identity key.
- Receivers would, before any try, honour only a proposer in their
  pairing records (as `marker_trusted` does), in the map, at the current
  epoch; try only the package the entry names; and honour only accepts
  verifying under the key that hashes to their fingerprint. New
  contexts would not prefix old ones (Appendix A). Client-only: the
  relay would still "Store blobs; never parse one." (relay-protocol §9).

Costs: it refuses a proposer known only through a third device, against
relay-protocol §6's "two devices that never paired directly (both paired
with a third) can still run ceremonies together" (the built client gives
it no seat anyway); a mixed-version channel could not rotate, old
clients ignoring the fields and new ones refusing unsigned proposals. It
would not fix §10's abandoned-ballot split or stale-roster livelock, nor
sign Ops, Expiry or Hold. Open: (1) the membership a receiver would
demand; (2) devices with different records could still disagree; (3) a
prompt ceremony on revocation.

## 8. Rejoin and recovery, as built

Fetch `410`, publish `410`, a batch epoch above the chain's and an Ops
envelope at another epoch emit `rejoin_required`, a publish `409` emits
`epoch_conflict`, and the shell shows `behind` for both (§3). No rejoin
exists (§4.6); a fetch `410` leaves `next_seq`, so every turn asks
again. A relaunch, detach, sign-out, re-enable or pairing grant roots
the memory-only chain at epoch 0, behind for good after the first
ceremony. Designed recovery: relay-protocol §5's welcome, Amendment 1.

## 9. Pairing, the client side

Rendezvous: relay-protocol §7. Inviter A holds the channel secret.

| Step | Message | Client behaviour | Test |
| --- | --- | --- | --- |
| 1 | Commitment, A to B: `SHA-256(eph_A ‖ identity_A ‖ blind)` | queued at `invite_begin`; committing first leaves a machine in the middle one guess at the SAS | |
| 2 | Offer, B to A: identity and ephemeral keys | on a commitment (`Joiner::accept`) | |
| 3 | Reveal, A to B: keys, blind, transcript signature | on the offer (`Inviter::settle`); B checks the commitment and signature | `a_reveal_that_does_not_open_the_commitment_refuses_whole` |
| 4 | Six-digit SAS on both screens | stage `sas`; a mismatch drops that side whole | `a_machine_in_the_middle_moves_the_string_and_opens_nothing` |
| 5 | Acceptance, B to A: transcript signature | only after B's human confirms | |
| 6 | Grant, A to B: the secret sealed under a key from the X25519 secret and the transcript | once the acceptance verified and A's human confirmed (`maybe_grant`) | `no_secret_crosses_the_ceremony_in_the_clear` |

The inviter records the peer before queuing the grant, the joiner before
storing the secret; a refused write fails the step `keychain`. A done
step still posting reports `confirmed`. The grant replaces any founded
secret (§8).

## 10. Known divergences and gaps

Owner questions first; the owner decides which side moves in each.

- **10.1** Amendment 1 is "proposed" (relay-decision-background.md),
  yet ADR-0021's accepted Decision says "Persist each device's current
  GOP chain position." and carries the welcome. Neither is built.
- **10.2** Second `401`: ADR-0027, "sign sync out only when the token
  endpoint reports `invalid_grant`"; account-auth.md §5, "on second
  `401`, treat as refresh refused". Built: attach signs out, publish
  reports, fetch never retries, frame PUT and mailbox ignore it.
- **10.3** ADR-0007 is "proposed", yet relay-protocol §9 relies on it:
  "no server document may promise otherwise (ADR-0007)".

| # | Wording | Built | Consequence (basis) |
| --- | --- | --- | --- |
| 10.4 | relay-protocol §5: "attachment per §4's attach list at proposal time" | §7.3 | attached devices without a record are never members; followers trust the map (code reading) |
| 10.5 | relay-protocol §2: "every enrolled page compacts" | §7.6 | only the target page compacts; other enrolled pages keep their history (code reading) |
| 10.6 S | relay-protocol §5: "the proposer publishes the frame"; a `409` loser "takes the rejoin path itself"; ADR-0021: "loser adoption" | §4.6, §7.8 | every committer PUTs; losers diverge (interpretation) |
| 10.7 | none: §5 states no concurrency rule | §7.4 | a second proposal goes unanswered and fails (code reading) |
| 10.8 | relay-protocol §5: "every device stays on the old GOP"; "on waking it advances its chain" | §7.7, §8 | a sleeper that reads an abandoned ballot confirms alone and its frame wins, leaving the proposer behind; one that accepted then slept finds the remaining accepts purged, gets `410` and stays behind (interpretation) |
| 10.9 | none | §5.4 | after a follower republishes, the proposer seals to the spent package until it re-attaches; the channel cannot rotate (interpretation) |
| 10.10 | relay-protocol §5: "the publisher immediately proposes a ceremony" | §7.1 | with no live page left, no rotation; the dead page stays openable (code reading) |
| 10.11 S | relay-protocol §3: "A refused publisher proposes a size-triggered ceremony"; §4: "Control and content share the stream" | §4.4, §7.1 | the proposal is never sealed while the batch is in flight, so the channel wedges; a dead first page never commits; a solo commit there skips `settle_frontier` and re-exports the rebuild (interpretation) |
| 10.12 S | relay-protocol §4: "`410 rejoin` is the whole recovery story"; account-auth.md §5: "not a hot loop" | §3, §4.5 | a `410` or `protocol` turn re-pumps at once (code reading) |
| 10.13 S | none | §4.4 | a resend carries the new epoch over blobs sealed under the old key; peers cannot open them, yet cursors advance (interpretation) |
| 10.14 | relay-protocol §8: "delivery latency is bounded by the publish clock, not the poll" | §3 | an edit waits up to 25 s (code reading) |
| 10.15 | ADR-0027: "silently discard unpublished work" | §4.4 | a `409` or `410` batch reaches no peer until a dissolve, and after one only if the relay is at epoch 0; a relaunch also drops the enrolment (interpretation) |
| 10.16 S | relay-protocol §8: "64 KiB maximum bucket" | `pad::bucket`, §7.6 | the frame is unpadded; above 64 KiB buckets grow in 64 KiB steps (code reading) |
| 10.17 S | relay-protocol §3: "8 MiB or 4096 blobs" | §4.1 | base64 of 8 MiB exceeds the 10 MiB body limit; an unpaginated full buffer fails every turn (interpretation) |
| 10.18 | none | `PageChannel` default, §7.6 | a channel created after a ceremony starts at epoch 0, so its Ops read as `rejoin_required` (interpretation) |
| 10.19 | ADR-0021: "until current with the hold state" | §6 | after a sleep, an expired page's marker goes out before the first drain (interpretation) |
| 10.20 | relay-protocol §6: "a static X25519 public key" | §5 | the one-shot lifecycle has no spec (code reading) |
| 10.21 S | relay-protocol §3: "is dropped whole" | none | a client past epoch 0 meets a recreated channel with refused publishes (interpretation) |
| 10.22 S | relay-protocol §7: "evaporates on completion, abandonment, or after an hour"; account-auth.md §4: "does not retry on a timer tighter than its publish clock" | §4.7 | no completion message, no client deadline, a 1 s poll (`armPairingPoll`), no `401` handling (code reading) |
| 10.23 | none | §4.2 | a lost rotated refresh answer replays a retired token into reuse detection (interpretation) |
| 10.24 | relay-protocol §2: "never less" | §7.3 | one asleep rostered peer makes every ballot abandon, so history stays (interpretation) |
| 10.25 | relay-protocol §8: "Publish at most every 2 seconds per channel" | §3, §4.4 | the `401` resend reopens the clock (code reading); stopping mid-attach leaves the core attached, with no pump and no detach, until the next enable or quit; with the Keychain locked the owed attach reads it every turn (interpretation) |
| 10.26 | none | §3 | after sync off and on, a new pump can run beside the old turn, which can absorb its fetch into the new engine while the shell drops its events (interpretation) |
| 10.27 | surface.md §4: "Only a rejoin ends it." | §3, §8 | no rejoin exists, so nothing built ends `behind` but an account-axis fact, sync off or sign-out (code reading) |
| 10.28 | none | `settledTrouble` | while the gate still holds an earlier `unreachable`, a `keychain` refusal settles to `.unreachable`, so the sentence blames the server for a locked keychain, for up to the backoff (code reading; `testAQuietRefusalAfterAnUnreachableTurnStillBacksOff`) |
| 10.29 | surface.md §4: "no peer awake reads `sync waiting`"; §5: "the relay cannot be reached", "waiting on your browser" | `currentPeers`, `sentence` | an asleep rostered peer reads `synced`; the built sentences differ (code reading) |
| 10.30 | `companion_sync_pump` documents a `signed_out` event | `SyncEvent::SignedOut` | never constructed outside a test; sign-out arrives as the turn's reason (code reading) |
| 10.31 | ADR-0021: "Sync must move a Page between a user's enrolled devices" | §6, `SheetStore::apply_remote_update` | no envelope carries a sealed object, and a batch that stands a sentinel the peer's page does not own is refused whole (`ChipRoster`) and dropped; every later batch of that page builds on it (`MissingHistory`) and no rejoin exists (§8), so a page holding an object, sealed there or carried onto it by a move or a cut's reattach, stops reaching every peer (`sync_carries_no_object_so_a_move_between_pages_stands_none_on_a_peer`, `sync_carries_no_object_so_a_cut_reattached_on_another_page_stands_none_on_a_peer`) |

## Appendix A. Signing contexts, info strings, magics

`persist::signing_domain(context, payload)` is `context ‖ payload`, no
length prefix; no context below prefixes another.

| Name | Value | Role | In |
| --- | --- | --- | --- |
| `KEY_PACKAGE_SIGN_CONTEXT` | `ots-companion-key-package-v1` | Ed25519, key packages | `sync_session.rs` |
| `TERMINAL_SIGN_CONTEXT` | `ots-companion-terminal-v1` | Ed25519, terminal markers | `sync_session.rs` |
| `TRANSCRIPT_SIGN_CONTEXT` | `ots-companion-pairing-transcript-v1` | Ed25519, pairing transcripts | `pairing.rs` |
| `ENTROPY_WRAP_INFO` | `ots-companion-entropy-wrap-v1` | HKDF salt and info, entropy wrap | `sync_session.rs` |
| `ENTROPY_MAGIC` | `OTSENTR1` | AEAD associated data, entropy | `sync_session.rs` |
| `GOP_KEY_INFO` | `ots-companion-gop-transport-key-v1` | HKDF info, every chain key | `persist.rs` |
| `GOP_ROOT_SALT` | `ots-companion-gop-root-salt-v1` | HKDF salt, root key | `persist.rs` |
| `GOP_MAGIC` | `OTSGOPD1` | sealed delta or frame header | `persist.rs` |

```text
key[0]   = HKDF(salt: GOP_ROOT_SALT, ikm: channel_secret, info: GOP_KEY_INFO)
key[n+1] = HKDF(salt: key[n],        ikm: entropy[n],     info: GOP_KEY_INFO)
```

Without key[n] there is no key[n+1]; HKDF's one-wayness keeps earlier
keys out of reach, so a joiner learns nothing behind its epoch; and
`advance` wipes the old key. Sealed: `magic(8) ‖ epoch(8, BE) ‖ nonce ‖
ciphertext ‖ tag`, header authenticated, any other epoch refused.
