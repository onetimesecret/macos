---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0021: Multi-device sync over a blind relay

- **Status:** accepted
- **Date:** 2026-08-25
- **Depends on:** [ADR-0013](0013-document-provenance-and-block-metadata.md).

## Context

Sync must move a Page between a user's enrolled devices without allowing the
relay to read it, without turning the relay into an operation archive, and
without changing the app when sync is disabled. Devices also need a way to join
or recover when no existing peer is awake.

The detailed wire contract belongs in the
[relay protocol specification](../spec/feature/sync/relay-protocol.md), the user
states in the [sync surface specification](../spec/feature/sync/surface.md), and
delivery sequencing in the [multi-device sync plan](../plans/multi-device-sync.md).
Extended security analysis and amendment development are preserved in the
[relay decision background](../spec/feature/sync/relay-decision-background.md).
Numbered sections of this ADR cited elsewhere in the tree, such as "ADR-0021
section 3" or "§6", now live in that relay decision background rather than in
this record.

This decision leaves [ADR-0010](0010-form-factors-as-sibling-targets.md)
standing, unamended, and leaves standing
[ADR-0016](0016-content-persists-across-restart.md)'s `ThisDeviceOnly` key
protection: keys reach a device through pairing rather than through iCloud
Keychain.

## Decision

Use an opt-in, blind, bounded store-and-forward relay. Per channel, it holds at
most one encrypted key frame and the encrypted deltas since that frame. Each
compaction ceremony supersedes the frame and advances a per-GOP transport key.
The relay never receives a content key, transport key, or pairing secret.

Account authentication permits attachment to a channel; it does not establish
device trust. Devices pair directly using device identity keys and a
human-verifiable exchange. Content and transport keys reach a device only through
that cryptographic trust relationship, never through the account or iCloud
Keychain.

A joining device starts at the current key frame and receives no prior history.
Enrollment can complete with peers asleep, but content backfill waits until a
peer publishes current state.

Replicate expiry policy, not machine-local deadlines. Each device computes its
own deadline; the earliest known expiry wins. Expiry is a signed terminal state
and destroys the Page key. A replicated hold is user policy and suspends expiry
for current peers; a stale peer may discard its own copy but may not publish the
terminal marker until current with the hold state.

Persist each device's current GOP chain position. A key frame carries a
per-enrolled-device welcome that seals the incoming epoch key to that device's
verified key package and binds the recipient, issuer, epoch, protocol version,
and frame hash. A device that missed a ceremony adopts the authenticated current
checkpoint rather than deriving missed keys. Lost or possibly copied device
state requires a fresh identity and revocation of the stale fingerprint.

## Consequences

- Sync-off remains the default and opens no sync connection.
- A compromised relay sees account identity, device identifiers and attachment
  times, traffic timing and sizes, ceremony times, and encrypted frame size. It
  cannot read Page or chip content, titles, block structure, or keys.
- Per-GOP rotation limits useful retained ciphertext, but welcome entries trade
  sleeper recovery for exposure if an unspent device key package is later
  compromised.
- Devices with skewed clocks can expire a Page early; they cannot extend it.
- A held Page can reappear on a cautious peer after that peer discarded its local
  copy and rejoined at the current frame.
- An enrolling device can remain empty until another peer wakes; the UI must say
  so rather than imply synchronization is complete.
- Coordinated compaction, canonical frame election, loser adoption, and safe
  re-entry of unpublished local edits become protocol obligations.
- The relay is a second allowed TLS destination. Local sharing between two form
  factors on one Mac remains a local architecture question, not a relay use case.

## Eject triggers

- The authorization system cannot support a desktop app that sleeps for days.
- Authenticated checkpoint adoption cannot be implemented without trusting the
  relay to authorize devices.
- Measured traffic or traffic-analysis leakage exceeds the batching and padding
  bounds in the protocol specification.
- A relay-visible metadata channel appears that is absent from the protocol's
  admission.
- The design starts relying on server-side deletion rather than key rotation for
  confidentiality.
- Users require the same local store across form factors; that reopens ADR-0010,
  not this relay decision.

## Decision history

- **2026-08-25:** Accepted after PR #113 ratified the key-frame join and the rule
  that a paused Page remains paused until unpaused.
- **2026-08-27:** The recovery design added persisted chain position and
  per-device welcomes bound to the canonical frame. The protocol specification
  is the authoritative message-shape record.
- **2026-09-02:** The record was split into this ADR and the linked relay
  decision background, which now carries the numbered sections other documents
  cite.
