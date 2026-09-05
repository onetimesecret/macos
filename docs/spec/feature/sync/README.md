# Multi device sync

The same pages on a user's own devices, over a server that cannot read
them. The decisions live in
[ADR-0013](../../../adr/0013-bounded-document-history-and-block-metadata.md)
(broadcast rules, the compaction ceremony, one GOP) and
[ADR-0021](../../../adr/0021-multi-device-sync-over-a-blind-relay.md)
(the relay, pairing, the metadata admission, the join and expiry
rules); the plan is
[docs/plans/multi-device-sync.md](../../../plans/multi-device-sync.md),
and execution status lives in the
[milestone](https://github.com/onetimesecret/macos/milestone/3)'s
issues, not here.

This directory holds the milestone's written specifications:

- [relay-protocol.md](relay-protocol.md) — the channel model, message
  set, storage contract, ceremony wire shape, batching and padding, and
  the interface the server side implements (issue #99).
- [account-auth.md](account-auth.md) — the OAuth flow that gates the
  relay channel, token lifetimes for an app that sleeps for days, and
  the sync/conceal credential separation (issue #98).
- [surface.md](surface.md): what sync looks like in the app. The off
  switch and what off means, enrolment and pairing, the device list
  and its revocations, the header's one word, the sentence every
  degraded state owes, and the mark a page carries while another
  device is writing on it (issue #102).

The client seams these documents drive are in the tree: the delta seam
(`crates/core/src/document.rs`, issue #96), the sync rules and ceremony
state (`crates/core/src/sync.rs`, issues #100 and #101), the per GOP
transport key (`crates/ffi/src/gop.rs`, issue #95), and device pairing
(`crates/ffi/src/pairing.rs`, issue #97). The session layer that joins
them to a wire is built too (`companion-sync` and
`crates/ffi/src/sync_session.rs`, PR #119), as are the shell surface
and its C ABI (`crates/ffi/src/sync_driver.rs` and
`SyncController.swift`, issue #102); what remains is the server side
(onetimesecret/onetimesecret#4303) and ADR-0021 Amendment 1's welcome
work on both sides of the wire.
