---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0021: Multi device sync over a blind relay

- **Status:** accepted
- **Date:** 2026-08-25. Drafted with two items flagged for ratification;
  both were decided by the maintainer the same day (PR #113): the
  one-key-frame join stands as drafted, and the fail-closed hold was
  rejected in favor of the rule section 6 now records, a paused page
  stays paused until it is unpaused.
- **Depends on:**
  [ADR-0013](0013-document-provenance-and-block-metadata.md), which
  decided the shape of sync in the abstract: broadcast rules rather than
  archive rules, a device joins at the current key frame and structurally
  never receives the ops behind it, and a relay holds at most one GOP of
  encrypted deltas (ADR-0013:420-431). This ADR decides the relay
  itself: what it stores, how devices come to trust each other, and what
  the relay is admitted to learn.
- **Leaves standing:** [ADR-0010](0010-form-factors-as-sibling-targets.md)'s
  two-instances-two-stores stance, unamended; section 7 says why.
  [ADR-0016](0016-content-persists-across-restart.md) section 3's
  keychain protection class, unamended; section 8 says what that costs
  sync and why the cost is kept.

## Context

Issue #92 settled the doctrine first: the network boundary now reads "at
most two outbound destinations, TLS-only, and no others"
(docs/spec/design/05-technical-direction.md:107-117). The first is the
configured OTS server, reached only on an explicit conceal. The second
is this relay, reached only for a page the user has shared to their own
enrolled devices. This ADR cannot contradict that boundary and does not:
everything below widens `crates/transport`'s allowlist from one entry to
two and changes nothing else about it. The transport still refuses any
non-`https://` URL before a socket opens (crates/transport/src/lib.rs:44).

Nothing below is built. What exists is the CRDT foundation and the local
discipline the relay must not weaken:

- The document module is the only file in the crate that touches Loro
  and it exports exactly one shape: `export_snapshot`, the full document
  with history (crates/core/src/document.rs:214), merged back whole by
  `import_snapshot` (crates/core/src/document.rs:225). Deltas since a
  frontier have no representation anywhere in the tree (issue #96).
- The compaction ceremony is purely local. It fires from an accepted
  `cycle_rung` (crates/core/src/store.rs:1113), an accepted `set_rung`
  (crates/core/src/store.rs:1139) and a pause top-up
  (crates/core/src/store.rs:1196), and the rebuild types the body into a
  fresh document under a freshly minted peer id because a `StateOnly`
  export was measured to keep the old one
  (crates/core/src/document.rs:365-393).
- There is one content key per form factor per state directory,
  `HKDF(keychain_half, file_half)` under one versioned info string
  (crates/ffi/src/persist.rs:204, :448). No per GOP key exists
  (issue #95).
- Expiry deadlines are `Instant` values on a sleep-inclusive monotonic
  clock, comparable only inside one boot session
  (crates/core/src/clock.rs:17-25). The only place wall time touches a
  deadline is the restart gap, `wall_away_ms`
  (crates/ffi/src/lib.rs:1516).
- Account auth is HTTP Basic behind the `AuthStrategy` trait in
  `crates/ots-client`; OAuth is the capability onetimesecret is adding
  (issue #98).

Three disciplines bound the answer. ADR-0007 forbids claims a critic
with a debugger can falsify, and its Amendment 3 fixes the vocabulary:
the exit ramp is conceal, and the retired word is not used here. The
ledger's content-free construction (crates/core/src/ledger.rs:1-16) is
the model for how to admit what a component learns rather than claiming
it learns nothing. And docs/design-brief.md requires that no account is
needed for the core loop, so sync must be strictly additive.

The prior art below is cited because these are standardized problems.
Where a published standard answers a question, this ADR argues from the
standard rather than settling it by preference.

## Decision

The relay is a blind, bounded store-and-forward buffer per channel: at
most one GOP of encrypted deltas plus one sealed key frame, superseded
at each compaction ceremony, undecryptable after it. Devices trust each
other through their own pairing ceremony, never through the account,
and the relay never holds a key. Sync is off by default and the app
with sync off is indistinguishable from today's app (issue #102).

### 1. The relay storage contract

The delta from ADR-0013, stated plainly. ADR-0013:509-511 allowed a
relay to be "at most a store-and-forward buffer of encrypted deltas
since the last key frame, purged by the ceremony". This ADR fixes the
contract as: per channel, the relay holds

1. the encrypted deltas published since the last ceremony, one GOP and
   never more, and
2. exactly one sealed key frame, written at each ceremony and
   superseding its predecessor (section 5 is why it exists and what
   seals it).

It holds nothing else. It never holds a content key, a per GOP key or a
pairing secret; it cannot merge, compact or read a delta, because every
byte it stores is ciphertext sealed by a device (ADR-0013:388-391 is
explicit that end to end encryption makes the relay a store-and-forward
archive rather than a participant, which is why section 2's purge
argument has to be structural). A device that was offline for longer
than one GOP recovers by rejoining at the current key frame, not by
asking for history, which is the join-at-key-frame semantics
ADR-0013:423-426 already decided.

**Rejected: an archive relay.** A relay that retains deltas past the
ceremony is the durable op-log archive ADR-0013:384-391 names as the
thing the ceremony exists to destroy. Retention would make every
deleted character recoverable for the life of the page from a single
server, which inverts the product.

**Rejected: a merging relay.** Letting the server merge or compact
would shrink traffic and it requires the server to read ops. A relay
that can read ops is a peer, and a peer operated by someone else is the
threat model, not the feature.

**Required work.** Issue #99 turns this section into a protocol
(channel model, message set, backpressure, purge on ceremony, transport
inside `crates/transport`'s constraint), and files the server side in
the onetimesecret repo. Issue #96 builds the delta seam the protocol
needs: delta export since a frontier and the matching reject-whole
import, in the crate-private style `document.rs` already enforces, with
the peer id never crossing a ceremony boundary
(crates/core/src/document.rs:369-393).

### 2. Purge is structural, not a promise

Each GOP's deltas are encrypted under a per GOP transport key derived
at the key frame. The compaction ceremony rotates that key and every
device destroys the old one. Whatever ciphertext the relay retains
after the boundary, by bug, by backup or by malice, is undecryptable by
anyone, including the devices that wrote it. The relay's purge is
therefore hygiene that bounds storage, and the security boundary is the
key rotation. This claim must never be phrased as a deletion policy:
per ADR-0007, a promise about a server's disk is a claim a critic can
refute and a derivation is a claim a reader can check.

**Rejected: trusting the relay's deletion.** "The relay deletes on
ceremony" is true and load-bearing for storage bounds, and it is
exactly the class of claim ADR-0007 retired: unverifiable from the
client, falsified by a single snapshot of the server. It is kept as
hygiene and refused as the argument.

**Rejected: one long-lived channel key.** A single transport key per
channel would make every retained delta decryptable for the life of the
channel, so a compromised relay accumulates bounded storage but
unbounded readable history the moment the key leaks. The per GOP
derivation is what makes ADR-0013:430-431's "bounded by one GOP" true
against a relay that lies about purging.

**Required work.** Issue #95 builds the derivation (a third branch
beside `CONTENT_KEY_INFO` and `FILE_HALF_NAME_INFO`,
crates/ffi/src/persist.rs:204, :214, versioned like both), the rotation
at the ceremony, and the destruction of the outgoing key, with the
ledger key untouched throughout. Issue #101 makes the ceremony a
coordinated protocol event, which ADR-0013:411-418 already requires:
proposal, acceptance, confirmation, and the rule that a ceremony not
confirmed by every attached device leaves every device on the old GOP
rather than splitting them across a boundary. Rotating the transport
key and rebuilding the document are two halves of one event and must
not be able to half-happen.

### 3. The account is not the device

Account authentication answers one question: may this client attach to
this channel. OAuth, when onetimesecret ships it, is the right
instrument for exactly that (issue #98). It answers nothing about
whether the device holding the token is one the user meant to enrol.
Device trust is established by a separate pairing ceremony: a per
device identity key, a key exchange between the devices themselves, and
a verification a human performs on both screens, a short authentication
string or a key fingerprint comparison, which the user must be able to
fail (issue #97). Content and transport keys reach a new device only
through that ceremony. The relay never distributes, escrows or ever
holds one.

**Rejected: the account token as device trust.** If holding a valid
token admitted a device to content, then anything that can obtain a
token (a phished session, a leaked refresh token, the provider itself)
can read pages. The account gate and the pairing gate fail
independently, and both must be passed.

**Rejected: iCloud Keychain as the key channel.** Apple ships exactly
this mechanism, and ADR-0016 section 3 deliberately opted the durable
keychain half out of it with `ThisDeviceOnly`
(crates/credentials/src/lib.rs:637-646). Using iCloud Keychain for the
transport key would put key custody inside an ecosystem the threat
model does not include and undo a protection the design already paid
for. Section 8 keeps the class and states the consequence.

Sync credentials stay separate from conceal credentials, and revoking
one does not revoke the other: conceal is a deliberate foreground act
and sync is a background one, and one credential serving both would
make the background act as powerful as the deliberate one.

### 4. The metadata admission

Even blind, the relay learns. This section is the decided admission, in
the spirit of the ledger's content-free discipline
(crates/core/src/ledger.rs:1-16): state what the component holds so the
claim is checkable, rather than claiming it holds nothing.

An honest relay operator, or anyone who compromises one, learns:

1. **Account identity**, because the channel is gated by the account
   (section 3), and with it which accounts use sync at all.
2. **Device count and attachment times** per channel, because each
   device attaches with its own connection.
3. **Delta timing**, which is typing rhythm at the resolution the
   client publishes. `set_change_merge_interval(0)` keeps every commit
   its own change (crates/core/src/document.rs:89), so unbatched
   publishing would make the rhythm nearly keystroke-grade. The
   protocol must batch on a clock, not on commit boundaries, and issue
   #99's backpressure section owns the number.
4. **Delta sizes**, a weak fingerprint of edit activity. The ledger
   buckets sizes for exactly this reason
   (`SizeClass`, crates/core/src/ledger.rs:63-75); the protocol should
   pad or bucket for the same one.
5. **Ceremony times**, because the ceremony purges the buffer and
   supersedes the key frame, and with them the rung-transition rhythm
   of the pages being synced.
6. **The key frame's existence and size** (section 5), which widens
   what a compromised relay holds at any instant from one GOP of deltas
   to one GOP of deltas plus the sealed state they apply to. All of it
   ciphertext, all of it dead at the next rotation, and its size is
   still a coarse fingerprint of how much is staged.

What the relay structurally cannot learn: page content, chip content,
titles, page count, block structure, and every key. The admission above
is the whole surface, and any protocol choice in issue #99 that widens
it (a channel per page, say, which would leak page count and per page
activity) is measured against this section and amends it or does not
ship. The metadata the relay sees is also the metadata a subpoena
reaches; the admission is written with that reader in mind.

### 5. Joining when no peer is awake

A device that joins at the current key frame needs a key frame to join
at, and a pure delta buffer cannot serve a device enrolling while every
peer is asleep. The case that matters is the new laptop opened for the
first time with every other device in a drawer (issue #94).

The relay holds exactly one sealed key frame per channel, written at
each ceremony, superseding its predecessor. This is the shape RFC 9420
standardizes as MLS external commits: the delivery service publishes
one `GroupInfo` object carrying the `external_pub` extension, and a
joining device downloads it and commits itself into the group with no
existing member online. The recommendation on file, one key frame per
channel superseded at each ceremony and useless after rotation, is that
standard's architecture rather than an invention, and OpenMLS is a
usable Rust implementation.

- https://www.rfc-editor.org/rfc/rfc9420.html

Two caveats the standard leaves open, both decided here:

**Authorization is cryptographic, never possession.** RFC 9420 section
3.1 assumes an untrusted delivery service and does not define who may
external-join: anyone holding `GroupInfo` can. A blind relay cannot
authorize, so the stored key frame is encrypted to a secret derived at
the pairing ceremony (section 3), and possession of the frame is never
the credential. A device that has passed account auth but not pairing
downloads bytes it cannot open.

**Enrollment is not backfill.** An external joiner learns the new
epoch's secrets only, never the previous epoch's. The new laptop
therefore joins with every peer asleep and still cannot decrypt a
snapshot sealed under the old epoch: it enrols empty and fills in when
a peer next wakes and publishes against the current epoch. That is the
decision, and it is also why issue #94 as filed is two questions.
Enrollment is answered by the standard; backfill is a product choice,
and the choice is to wait for a peer.

**Rejected: require an online peer to enrol.** The pre-external-commit
model. It fails the exact case the feature is judged by, and RFC 9420's
external commits exist to remove the requirement.

**Rejected: a per epoch re-encrypted backfill snapshot on the relay.**
It would let the new laptop arrive full, and it puts an online device
back in the loop at every rotation to re-encrypt, which recreates the
availability problem one layer down and widens section 4's admission by
a full state snapshot per epoch, held continuously rather than only
between a ceremony and the next wake.

Ratified 2026-08-25 (PR #113), including the enrollment and backfill
split as stated above.

**Required work.** Issue #94 keeps the two details the decision leaves
open: what supersession means when a ceremony fails partway (section
2's ceremony rule is what prevents the half state), and what the
device shows while it waits, which is issue #102's degraded-state
sentence, not a silent spinner.

### 6. Whose clock expires a page

Expiry is the product, and two devices holding one page must agree on
when it dies. What replicates is the policy, `(created_wall_ms,
ttl_ms)`, never the deadline. `Instant` cannot cross a boot session,
let alone a machine (crates/core/src/clock.rs:17-25,
crates/ffi/src/lib.rs:1516), and is not made to try. Each device
computes its own deadline on its own clock. That is Signal's
disappearing-messages model: client-side enforcement, no cross-device
timer synchronization, skew accepted.

- https://support.signal.org/hc/en-us/articles/360007320771-Set-and-manage-disappearing-messages
- https://signal.org/blog/disappearing-messages/

Three rules on top of the replicated policy:

**Failure is one-directional.** The effective deadline is the minimum
across every candidate a device knows: its own computation and every
peer's published expiry. A peer can shorten a page's life and can never
extend one, which is the rule `wall_away_ms` already follows locally
(crates/ffi/src/lib.rs:1516): a restore only ever subtracts. Clock skew
that makes the numbers say a page died before it was created is the
minimum rule working as intended: the page dies. Dying early is
recoverable; living long is the failure this app exists to prevent.

**Expiry is an absorbing terminal state, not a content edit.** Pushing
an empty key frame clears the text and is not terminal on its own: a
lagging replica merges its queued edits back in after the clear, and
expiring on a local wall clock without a terminal marker is a
documented non-convergence pattern
(https://jhellerstein.github.io/blog/crdt-turtles/). The device that
expires a page publishes a signed terminal marker for the page id,
refuses every further op for that id, and destroys the page's key; the
hold rule below is the one gate on who may publish that marker.
Destroying the key kills the relay's buffered ciphertext for that page
for everyone at once, which is stronger than deleting bytes and is the
same structural argument as section 2. Locally, expiry stays
`expire_due`'s entombment (crates/core/src/store.rs:1266, :1364); the
marker is what makes the second device's entombment agree with the
first's, and each device writes its own ledger record, so two wall
stamped ledgers describing one death is expected and correct.

**The hold is a replicated register, and the hold wins.** Ratified
2026-08-25: a paused page stays paused until it is unpaused. The pause
machine (crates/core/src/store.rs:1160; one hour first press,
twenty-four hours topped up, crates/core/src/store.rs:39, :43) becomes
a replicated register on the logical clock, and a live hold suspends
the countdown on every device exactly as it suspends it locally. The
hold is not a clock candidate under the minimum rule; it is policy,
the user's own instruction, the same class of exception ADR-0016
section 4 already grants a deliberate rung click. Two consequences
make that safe to say. A device offline past the original deadline
never saw the hold, so it still entombs its own copy on its own clock,
and its plaintext does not outlive its own belief; what it may not do
is publish the terminal marker, because for a synced page the marker
may be published only by a device whose view of the hold register is
current with the channel. And on reconnecting to a page still alive
under a hold, the early-entombing device holds nothing and rejoins at
the current key frame, which is section 5's recovery path doing double
duty; the cost of its caution is a rejoin, never a divergence. The
exposure is the one the pause gesture already sells locally: a page's
life is its TTL plus the time the user deliberately held it, bounded
per press by the hold ceiling.

**Rejected: fail closed**, this ADR's own first draft, under which the
original deadline governed until every enrolled device had seen the
hold, and an offline device's terminal marker killed a paused page for
everyone. It was rejected because it turns a device in a drawer into a
veto over a live gesture on the machine in front of the user. The
minimum rule exists so a peer's clock cannot extend a page's life; a
hold is not a clock, it is the user, and a held page is not living too
long, it is living exactly as long as it was asked to. What survives
of the fail-closed instinct is the marker gate above: an uninformed
device still cannot extend anything, and it still cannot kill what it
cannot see.

**Required work.** Issue #100 lands the rule with two tests: one
drives two stores through a shared expiry and proves the earlier
deadline fires, and one holds a page on one store while the other
sits out its original deadline, then proves the holder's page
survives and the returning store rejoins rather than killing it. It
also amends `clock.rs`'s module doc in place: the monotonic
discipline survives for every locally observed interval, and the
replicated policy is a second wall-clock reader beside the restart gap,
subject to the same never-extend arithmetic.

### 7. ADR-0010's two stores survive

ADR-0010's stance stands: two running form factors are two core
instances with two stores, and neither reads the other's pages
(ADR-0010:80-83). This ADR does not supersede it and does not use the
relay to join two form factors on one machine. For enrolment purposes a
core instance is a device: the panel and the backdrop on one Mac are
two enrollable peers exactly as a laptop and a desktop are, unusual
only in sharing a keyboard. If users ask for the same pages in both
form factors, that is ADR-0010's own eject trigger (ADR-0010:116-119)
and its answer is core-side and local, a daemon or a shared sealed
store, not a round trip through a server for two processes an IPC apart.
Routing local sharing through the relay would put content on the
network to move it across a process boundary, which the doctrine's
"only for a page the user has shared to their own enrolled devices"
does not license.

### 8. ADR-0016 section 3 and the key that must travel

The keychain half stays `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
(crates/credentials/src/lib.rs:637-646), and ADR-0016 section 3's
observation that `ThisDeviceOnly` "keeps a half that is durable across
boots out of iCloud Keychain" hardens here from a property into a
rule: no key in this design rides iCloud Keychain, ever. The content
key never leaves its device at all; what a second device needs is the
per GOP transport key and the pairing-derived secrets, and those travel
only through section 3's pairing ceremony. The cost is deliberate
friction: enrolling a device takes a human at both screens once,
instead of arriving free with an Apple ID. That is the correct price,
because the Apple ID is an account, and section 3 just spent a page
establishing that the account is not the device.

## Consequences

- Sync arrives as configuration, not rewrite, which is what ADR-0013
  bought by choosing architecture 3. The new work is a delta seam
  (issue #96), a key derivation branch (issue #95), a pairing ceremony
  (issue #97), an auth strategy (issue #98), a protocol (issue #99), a
  coordinated ceremony (issue #101) and a settings surface (issue
  #102). The document model, the store and the persistence format do
  not change shape for sync.
- The network boundary doctrine holds at two destinations and
  `crates/transport`'s allowlist widens by one entry. Every claim in
  docs/spec/design/05-technical-direction.md:107-117 about the relay
  (ciphertext only, opt-in per page, holds nothing past the page's own
  TTL) is made true by sections 1, 2 and 6 rather than asserted.
- A compromised relay is bounded, and the bound is stated: one GOP of
  deltas plus one sealed key frame, all of it dead ciphertext at the
  next ceremony, plus section 4's metadata, which rotation never
  erases. Metadata is the durable residue and the admission is the
  claim.
- Expiry becomes the minimum across devices. A user whose two clocks
  disagree sees pages die at the earlier of the two readings, which
  will occasionally read as a page dying early on the device with the
  slow clock. That is the accepted direction of error.
- A paused page stays paused across devices. A device that was
  offline past the original deadline entombs its local copy on its own
  clock and, on reconnecting, rejoins the still-live page at the
  current key frame. Issue #102's status surface owes that device a
  sentence: the page died here on schedule and came back because a
  hold elsewhere kept it alive. The page's total life is its TTL plus
  the held time, which is what the pause gesture already means on one
  device.
- A new device enrols empty and backfills only when a peer wakes. The
  new-laptop case works with everyone asleep, and shows an empty pad
  with an honest sentence until a peer comes online. Nobody is put in
  the loop at rotation to make it fuller faster.
- Devices that never enrol pay nothing. Sync off is the default and is
  indistinguishable from today's app; the core loop keeps working with
  no account and no network (docs/design-brief.md, issue #102).
- The vocabulary discipline extends to sync: the relay "purges" as
  hygiene, keys "rotate" and "die" as facts, and no document, UI string
  or changelog entry promises what the server's disk does. ADR-0007's
  adversarial-reading rule applies to every sentence this feature
  ships.

## Eject triggers

- OAuth ships in onetimesecret with a shape that cannot serve a desktop
  app (no device-authorization-style flow, or token lifetimes that
  cannot survive the app sleeping for days). Section 3's split survives
  on any account instrument, and issue #98 picks a different one.
- RFC 9420's external-commit model proves unimplementable over a blind
  relay's authorization constraint (section 5's ceremony-derived
  encryption of the key frame). The fallback is the rejected
  online-peer enrolment, taken deliberately and announced as the worse
  answer it is.
- Measured delta traffic under `set_change_merge_interval(0)` blows the
  relay's storage or the metadata admission's timing granularity past
  what issue #99's batching can absorb. The merge interval becomes a
  sync-tuning knob, at the provenance cost ADR-0013 already names for
  merged changes.
- A metadata channel not in section 4's list is demonstrated (traffic
  analysis recovering content classes, say). The admission is amended
  and the protocol re-padded; the admission being wrong is treated as a
  shipped claim being refuted, which is ADR-0007's response, tighten
  the claim.
- Users ask for the same pages in both form factors on one machine.
  That fires ADR-0010's trigger, not this ADR's design: the answer is
  local (ADR-0010:116-119), and reaching for the relay instead is
  evidence this section was forgotten, not that it was wrong.
- The purge argument appears anywhere phrased as a server-side promise.
  That is a violation of section 2 and ADR-0007, not a drift to
  accommodate.

## Amendment 1: the frame carries a welcome, and the chain rests

- **Status:** proposed — flagged for ratification, as the original
  draft's two items were (both decided in PR #113); revised the same
  day to meet the ratification review's conditions (PR #121)
- **Date:** 2026-08-27

### The question

Section 5 decided how a device joins when no peer is awake, and
section 2 decided that the key rotation, not the relay's deletion, is
the purge. Building the session engine (PR #119) surfaced the case the
two sections point at and neither resolves: **a device that slept
through a ceremony entirely.** The sealed entropy that would have
advanced its chain was purged with the superseded deltas — that purge
is the design working — and the frame it wakes to is sealed under the
incoming GOP key, which is exactly the key it lacks.

Three facts sharpen the question before any answer:

1. **Entropy cannot catch a device up.** The chain salts each incoming
   key with the outgoing one (`crates/ffi/src/gop.rs:104-116`), so
   entropy for epoch n is useless without the key for epoch n−1.
   Re-delivering entropy helps only a device exactly one step behind
   that also held the outgoing key — which is nobody the question is
   about.
2. **Re-pairing, as built, does not recover either.** The pairing
   grant delivers the channel secret
   (`crates/ffi/src/pairing.rs:322-327`), and the chain roots from it
   at epoch zero (`gop.rs:82-88`). After the channel's first ceremony
   no root derivation reaches the current epoch. Worse, the chain
   state lives only in memory: a mere relaunch strands a device the
   same way, and the only recovery the built pieces actually offer is
   every device clearing its pairing and founding the channel again.
3. **A proposer can now reach every enrolled device.** The attach
   answer serves each device's key package (relay protocol §4, amended
   2026-08-27), and the pairing records tie fingerprints to
   identities — the same per-device sealed-delivery shape §5 of the
   protocol already uses for ceremony entropy.

### Decision

Three moves, one per fact.

**The chain state rests beside the other keys.** Each device persists
its chain position — the current GOP key and its epoch — in the
key-material store, `ThisDeviceOnly` like everything there (section
8), overwritten at each advance so the outgoing key's destruction
stays the rotation's own act. A relaunch is then a non-event instead
of a stranding. The account sits beside `sync-channel-secret` and is
cleared with the pairing; the ledger key and content halves stay as
untouched by this as by every other rotation.

What the store is asked to hold is exactly what it is built for — one
small secret — and nothing more: document state stays where it lives,
and the keychain is not asked to be a transactional database or to
make two stores advance together. The atomicity is an ordering rule
instead: **the advanced position persists before the first ciphertext
under it publishes.** A crash between the two leaves the device
behind its own channel, never ahead of its own persisted state — and
behind is the case this amendment exists to handle. Nor does the
store defend against a restored backup rolling the position back; no
local store can, and the device cannot always tell a rollback from a
sleep — both read as a persisted epoch behind the relay's, and both
land on the adoption path, where the welcome's bindings, not the
stale state, decide what is adopted. What a rollback *implies* — a
copy of this device's state existed outside it — is the second
door's case in the decision below, and its cure belongs to the user,
not to forensics the design cannot honestly claim.

**The published frame carries a welcome.** Beside the sealed frame —
never inside it, since a device that could open the frame would not
need a welcome — travels a per-device map in the shape §5's
`entropy_sealed` already has: keyed by identity fingerprint, one entry
per enrolled device, each entry sealing the **incoming epoch's GOP
key** to that device's verified key package (protocol §6). The key and
not the entropy, because the welcome exists precisely for the device
the chain math has left behind (fact 1). Enrolment, not attachment,
draws the map's boundary: every device the pairing records name and
the roster serves gets an entry, and revocation stays what the
protocol's §5 made it — omission. This is RFC 9420's Welcome object arriving at
one-channel scale, the same standard section 5 already borrowed for
external commits.

An entry is not a bare key. Inside each sealed entry, beside the key,
ride the claims that make adopting it safe: the channel epoch the key
opens, the hash of the frame it belongs to, the recipient's own
fingerprint, and the protocol version — the whole entry signed by the
proposing device's identity key under its own versioned signing
context, the discipline every other signature in this design follows
(PR #121). The recipient verifies the issuer against its pairing
records and every binding against the frame it actually fetched
before adopting anything, so a replayed or transplanted welcome — an
old entry served beside a different frame, an epoch that does not
match — fails closed, and a forged one fails the signature. Binding
the frame's hash binds the snapshot too: the frame *is* the document
state the epoch opens, so no separate frontier claim travels. And the
sealed key is the epoch's root secret, not an any-purpose key: its
one purpose today is sealing the channel's blobs, and any second
purpose derives from it under its own info tag (`persist.rs`'s
derivation discipline), never by reuse. All of this rides inside the
sealed entries, so section 4's admission gains nothing new by it.

**Recovery is adoption, never derivation — and adoption is three
doors, not one.** The rule, stated carefully: a device that cannot
authenticate and process the intervening chain transition adopts an
authenticated current checkpoint; it never derives missed epoch
secrets from old state; and after adoption, keys derive normally
again. Which door a device takes depends on what it still holds:

- **The sleeper, state intact.** It wakes to `410 rejoin` or to blobs
  that refuse to open, fetches the frame, opens its own welcome
  entry, verifies the issuer and every binding above, adopts the
  epoch and key, opens the frame, and rejoins at it
  (`SheetStore::adopt_key_frame`, `PageChannel::rejoin_at_epoch`).
  This is the ordinary catch-up, and in this design it *is*
  processing the intervening transition: the chain's entropy never
  travels except sealed per device, so the welcome is the
  authenticated form the transition takes for a device that missed
  it live.
- **The device whose state was lost — or may have escaped.** A
  cleared keychain proves nothing; a restored backup proves worse: a
  copy of the identity key and channel secret existed outside the
  device, and resealing to that identity preserves whatever access
  the copy's holder gained. Recovery here is **a fresh incarnation**:
  re-pair under a fresh identity key, let the next ceremony's welcome
  name the fresh package, and revoke the stale fingerprint — struck
  from the pairing records, therefore omitted from every future
  welcome, which is what revocation already is. Because the device
  cannot always tell this door from the first, the door is also the
  user's: the device list names every incarnation, and revoking the
  stale one is one confirmed click (issue #102). The one justified
  reuse of an existing identity is the benign restart with the
  keychain intact: nothing was lost, the persisted chain position is
  the proof — and even then the memory-only package half (rejected
  below as a durable secret) means every welcome such a device opens
  from now on was sealed to a package it minted fresh after the
  restart.
- **The never-enrolled device.** Section 5's external join,
  unchanged: it adopts the current frame and learns nothing behind
  it.

The external-commit property survives every door: a welcome hands a
device the epoch it joins and nothing behind it, because HKDF's
one-wayness keeps every earlier key out of reach of the current one.
A still-trusted device with no openable entry — it restarted and its
published package went stale — waits for the next ceremony, whose
welcome will name its freshly attached package; the waiting is issue
#94's sentence, owed by issue #102's surface. A revoked device waits
forever, which is revocation working.

**The frame is canonical; the user's words are not up for election.**
What supersession elects is the cryptographic rebuild — one frame,
one epoch, one document identity — and what an adopting device drops
is exactly the replicated history the winning frame supersedes, as
section 5 requires (`RemoteRefusal::NotFresh` is the store refusing
the alternative). Its **unpublished local edits are a different
thing**: they exist in no frame, they are the user's work, and
adoption is not licensed to discard them silently. After adopting the
winning frame, a device re-enters what it alone held as new
operations on the adopted document — content-level reconciliation,
since disjoint rebuilds share no history to merge — or, where
re-entry cannot be made safe, preserves them for explicit user
recovery. Convergence without silent loss is the CRDT contract this
feature rides on, and the shell's "edits stay local until this pad
rejoins" is this rule said to the user: local until rejoined, then
carried across, never dropped.

**A welcome exists only beside the frame that won.** Candidate
rebuilds stay provisional until the relay's compare-and-set accepts
exactly one (`PUT /channel/frame`, `409` unless the epoch is exactly
current+1 — protocol §4, the CAS against the expected parent frame):
the welcome travels only inside that `PUT`, so no candidate's welcome
is ever served, honored, or even visible unless its frame became
canonical. A proposer whose `PUT` is refused destroys its candidate
epoch key and welcome map on the spot and takes the adoption path
itself. This is RFC 9420 §14's sequencing rule at one-channel scale:
conflicting commits do not both activate, and the losers join the
epoch they lost to.

### What this admits

Stated plainly, per ADR-0007, because the welcome narrows section 2's
claim. "Whatever ciphertext the relay retains after the boundary is
undecryptable by anyone" becomes: undecryptable by anyone **whose key
package has rotated since**. A retained superseded frame plus a later
compromise of one device's still-unspent package half opens that
frame's welcome entry, its epoch key, and with it that one epoch's
retained deltas. The window is bounded and symmetric: a package spends
and re-mints at every ceremony its device participates in, so what a
stolen key opens is exactly the epochs its device slept through — the
same material the welcome exists to hand that device. Recoverability
for the sleeper and exposure of the sleeper's key are one decision,
priced together, and the standard shape (MLS Welcome) prices it the
same way. Section 4's admission widens, but by no new channel: item 2
widens in kind as well as grain — attach (protocol §4) hands the relay
each device's identity fingerprint and published key package, held for
the attachment's life and served in the roster, a durable per-device
identifier §4's original list never named — and the welcome shows the
enrolled fingerprints and count again at each ceremony rather than
only at attach; the frame's bucketed size now scales with device
count (item 6).

**Rejected: sealing the welcome under the channel secret.** Every
paired device could open it — including a just-revoked one, which
still holds the secret. That breaks the exclusion property the
per-GOP chain exists to provide (section 2), for the convenience of
skipping key packages.

**Rejected: an entropy archive.** Retaining every epoch's sealed
entropy so a sleeper can replay the chain forward is the archive
relay of section 1, one derivation removed: a store that can catch
anyone up can catch an adversary up.

**Rejected: durable key-package private halves.** Persisting the
static X25519 half would let a restarted sleeper open a welcome
minted before its restart, saving it one ceremony of waiting. It
costs a second durable secret in the keychain and a dependency the
one-shot API deliberately resists, to shave a wait the next ceremony
heals unattended. Declined; the restart case takes the waiting
sentence.

### Required work

- `GopKeyChain::adopt(epoch, key)` and the persisted chain position
  (a `sync-gop-chain` account in the key-material store), with the
  rotation-never-touches tests extended to it — and a test pinning
  the ordering rule: the advanced position persists before the first
  publish under it.
- The welcome map built in `gop::ceremony_commit` from the ceremony's
  peers — each entry carrying its bindings (epoch, frame hash,
  recipient fingerprint, protocol version) and the issuer's signature
  under a new versioned context beside `KEY_PACKAGE_SIGN_CONTEXT` and
  its siblings — and walked, verify-before-adopt, in
  `SyncSession::absorb_frame` before the chain opens the frame. Issue
  #102's driver shipped without this half: the driver surfaces
  `rejoin_required` honestly but fetches and adopts nothing yet, so
  it needs its own issue alongside the server's
  (onetimesecret#4303).
- The coordinated commit leaves each participant its own independent
  rebuild; the frame supersession then picks one canonically (the
  publish the relay accepted — a `409` told the others a peer's copy
  won). Every losing participant destroys its candidate epoch key and
  welcome map on the `409` and takes the same adoption path the
  sleeper takes — without that adoption, two rebuilds share no
  history and the winner's later deltas are refused on the losers —
  and then re-enters its unpublished edits on the adopted document,
  per the no-silent-loss rule above.
- The fresh-incarnation path: a device recovering from lost or
  rolled-back state re-pairs under a fresh identity, and the stale
  fingerprint it abandons must leave the peers' pairing records — the
  existing revocation gesture, or the re-pair flow offering it — so
  omission by the records, not habit, decides its welcome entries.
  Which surface owns that offer is issue #102's question. And
  revocation advances the epoch rather than waiting for one: the
  revoking device proposes a ceremony promptly, the terminal-marker
  precedent (protocol §5), so the stale incarnation's access ends at
  the earliest boundary the channel can reach instead of at whenever
  the next rotation happens to fall.
- Protocol: `PUT`/`GET /channel/frame` gain `welcome` beside `frame`
  (relay-protocol.md §4-5, amended 2026-08-27); the server stores it
  opaquely and supersedes it with the frame
  (onetimesecret/onetimesecret#4303).
- Issue #94 keeps two details: the waiting sentence for a device
  whose welcome has not arrived yet, and whether a behind device may
  itself propose the ceremony that rescues it (the size-triggered
  precedent in protocol §3 suggests yes; decided there, not here).
