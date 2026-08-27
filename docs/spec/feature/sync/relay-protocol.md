# The relay protocol, and what the relay is allowed to hold

**Status:** specified, not built. This document is issue
[#99](https://github.com/onetimesecret/macos/issues/99)'s deliverable:
the protocol written down before it is implemented, with the storage
contract as a numbered section ADR-0021 can cite. The client seams it
drives already exist and are named where they appear; the server side
implements the interface in §9 and is filed in the onetimesecret repo.

Sections are numbered so issues and ADRs can cite "relay protocol §4".
The constraints this document lives inside are decided elsewhere and
are not renegotiated here: the storage bound and join rule
(ADR-0021 §1, §5), structural purge (§2), account-is-not-the-device
(§3), the metadata admission (§4), the expiry rule (§6), and the
network boundary of at most two outbound destinations, TLS-only
(`docs/spec/design/05-technical-direction.md:107-117`,
`crates/transport/src/lib.rs:44`).

## 1. The channel model

**One channel per account.** A device attaches to its account's one
channel; every page the user has shared to their own devices rides
inside it. What the user shares is still chosen per page — enrolment is
per page, off by default — but the relay never sees page boundaries:
every stored byte is ciphertext sealed under the channel's current GOP
key (`crates/ffi/src/gop.rs`), and which page a delta belongs to is
plaintext structure *inside* that seal.

**Rejected: a channel per page.** It would leak page count, per-page
edit rhythm and per-page lifetime to the relay — three channels
ADR-0021 §4 does not admit, and §4 is explicit that a protocol choice
widening the admission "amends it or does not ship." One channel per
account keeps "page count" in the structurally-cannot-learn column.

**Rejected: a channel per device pair.** It multiplies stored copies of
the same ciphertext, and the ceremony would have to purge N buffers
atomically instead of one.

## 2. The ceremony is channel-wide

ADR-0021 §1 fixes the relay's holding at one GOP of deltas plus exactly
one sealed key frame per channel. One frame and one key per channel
mean one epoch per channel, so: **when a ceremony runs, every enrolled
page compacts**, not only the page whose rung transition proposed it.
The confirmed ceremony (issue #101, `PageChannel` in
`crates/core/src/sync.rs`) performs, on every device: compact each
enrolled page (`SheetStore::perform_ceremony`), rotate the channel's
GOP key (`GopKeyChain::advance`), and seal one composite key frame —
every enrolled page's post-compaction snapshot, one blob. The proposer
publishes it (§5); its acceptance at epoch n+1 is what purges epoch n.

This is more forgetting than a solo page gets, never less: a page
enrolled in sync sheds its history at every channel ceremony rather
than only at its own rung transitions. ADR-0013 already priced extra
ceremonies at "nothing this design has not already priced", and the
alternative — per-page epochs — is a per-page frame, which is the
rejected channel-per-page model wearing a different name.

## 3. The storage contract

Per channel, the relay holds, and is allowed to hold, exactly:

1. **The current epoch number**, a counter it echoes but never
   interprets beyond "a frame at epoch n+1 supersedes everything at
   epoch n".
2. **One sealed key frame**, the composite of §2, written at each
   ceremony, superseding its predecessor (ADR-0021 §1, §5).
3. **The sealed deltas published since that frame**, in arrival order
   under a per-channel sequence number: one GOP and never more.
4. **The pairing mailbox** (§7): the ceremony messages of at most one
   pairing in flight. No message in it contains a secret
   (`crates/ffi/src/pairing.rs` proves this by byte-scan); the mailbox
   is dropped when the pairing completes, is abandoned, or ages out
   after one hour.
5. **Attachment metadata**: which account, which device fingerprints,
   when each attached, and the key package each device published at
   attach (§6 — public material, served back in the attach answer;
   amended 2026-08-27) — the admission of ADR-0021 §4, not a new
   channel.

It holds nothing else, and it never holds a content key, a GOP key, a
pairing secret, or anything it could merge, compact or read. Bounds and
lifetimes:

- **The delta buffer is capped**: 8 MiB or 4096 blobs, whichever comes
  first. At the cap the relay refuses further publishes with
  `ceremony_required`; it never drops from the middle or the front,
  because a silent gap forces every follower into a rejoin the relay
  caused. A refused publisher proposes a size-triggered ceremony, the
  remedy ADR-0013's eject triggers already name.
- **Everything expires**: a channel with no authenticated write for
  8 days (the 7-day ceiling rung plus the 24-hour hold ceiling) is
  dropped whole — frame, deltas, mailbox. A page kept alive longer than
  that is being kept alive by a device that is awake, and a device that
  is awake writes. This is hygiene under §2's rule that the security
  boundary is key rotation, and it is what makes "holds nothing past
  the page's own TTL"
  (`docs/spec/design/05-technical-direction.md:107-117`) true at the
  relay without trusting it.

## 4. The message set

Transport is HTTPS request/response against the second — and last —
entry in `crates/transport`'s allowlist. No WebSocket and no custom
framing: the long-lived connection a relay wants is a **long-poll**,
which lives inside the existing constraint instead of amending it. All
bodies are JSON; every sealed blob travels base64.

| Message | Shape | Answer |
| --- | --- | --- |
| Attach | `POST /channel/attach` `{device, key_package}` | `{epoch, frame_present, next_seq, peers: [{device, key_package, attached_ms}]}` |
| Fetch frame | `GET /channel/frame` | `{epoch, frame}` or `404` |
| Publish frame | `PUT /channel/frame` `{epoch, frame}` | `204`; `409` unless `epoch` is exactly current+1 |
| Publish deltas | `POST /channel/deltas` `{epoch, blobs[]}` | `{seq}`; `409` on epoch mismatch; `413 ceremony_required` at the cap |
| Fetch deltas | `GET /channel/deltas?since=seq&wait=25` | `{epoch, blobs[], next_seq}`, long-polling up to `wait` seconds; `410 rejoin` when `since` predates the buffer |
| Pairing | `POST /channel/pairing`, `GET /channel/pairing?since=` | the mailbox of §7 |
| Detach | `POST /channel/detach` | `204` |

Rules the shapes encode:

- **Attach is gated by the account** (issue #98) and grants exactly
  channel access; it proves nothing about device trust (ADR-0021 §3).
  `device` is the Ed25519 identity fingerprint; `key_package` is the
  signed static X25519 key of §6. A device that has passed account auth
  but not pairing fetches blobs it cannot open (ADR-0021 §5).
- **The attach answer serves the roster** (amended 2026-08-27, the
  first #99 follow-up): every other device the relay knows on the
  channel, with the key package each published at its own attach and
  the attach time — the metadata §3 item 5 already admits, echoed to
  the channel's own devices. This is what a proposer seals ceremony
  entropy to (§5) without an out-of-band delivery, and what issue
  #102's device list renders. Key packages are public material (§6);
  the roster is attach-list truth, never device trust — a client seals
  to a served package only after verifying it against its pairing
  records, so a relay that substitutes one wins ciphertext it cannot
  cause to be opened.
- **The frame supersession is the purge.** Accepting a frame at epoch
  n+1 atomically drops the old frame and every delta of epoch ≤ n.
  There is no separate purge message, so there is no state in which the
  purge was requested and not performed, and a proposer that dies
  before publishing the frame has changed nothing at the relay:
  everyone stays on the old GOP, which is issue #101's rule arriving by
  construction.
- **`410 rejoin` is the whole recovery story.** A device offline for
  longer than one GOP asks for a sequence the buffer no longer starts
  at; the relay says rejoin, and the device drops its stale copy and
  adopts the current frame (`SheetStore::adopt_key_frame`,
  `PageChannel::rejoin_at_epoch`). It never asks for history, and the
  relay has none to give (ADR-0021 §1).
- **Everything inside a delta blob is sealed**: the page id, the ops
  (`SheetStore::export_document_updates`), the expiry policy and hold
  register (`crates/core/src/sync.rs`), terminal markers, and the
  ceremony ballots of §5. Control and content share the stream so the
  relay cannot distinguish them.

## 5. The ceremony on the wire

A proposal is a sealed control payload in the delta stream:

```
propose  { ballot_id, page, entropy_sealed: {device_fingerprint: blob, …} }
accept   { ballot_id, device_fingerprint }
```

The proposer mints the ceremony entropy and seals it per surviving
device to that device's static key package (§6) — never under the
current GOP key, which a just-revoked device still holds. `page` names
the page whose transition proposed the compaction (amended 2026-08-27,
the second #99 follow-up: the shape shipped without it while one page
was ever in play, and a follower had to infer the scope); every
enrolled page still compacts (§2), and a follower that does not hold
the named page stays out, which fails the ballot as the all-attached
rule requires. Acceptance
rides the same stream. When every attached device has accepted
(`PageChannel::ceremony_confirmed`; attachment per §4's attach list at
proposal time), each device runs the one event — compact, advance,
reseal (`gop::ceremony_commit`) — and the proposer publishes the frame,
which purges. A ballot not confirmed within 60 seconds is abandoned
(`PageChannel::abandon_ceremony`): every device stays on the old GOP,
and the next transition proposes again.

A device that accepted and then slept still holds the sealed entropy in
its fetched stream: on waking it advances its chain and opens the new
epoch. A device that slept through the proposal entirely wakes to
`410 rejoin` or to blobs it cannot open, and takes the rejoin path;
its pre-ceremony history is dropped, never merged
(`RemoteRefusal::NotFresh` is the store refusing the alternative).

**Terminal markers propose.** After publishing a page's signed terminal
marker (ADR-0021 §6), the publisher immediately proposes a ceremony, so
the dead page's ciphertext in the relay buffer stops being decryptable
at the earliest boundary the channel can reach — key destruction doing
the work deletion cannot be trusted to do.

## 6. Key packages

At attach, each device publishes a **key package**: a static X25519
public key signed by its Ed25519 identity key. It is what ceremony
entropy (§5) and any future per-device delivery is sealed to — the
MLS-welcome shape (RFC 9420) at one-channel scale, and the reason two
devices that never paired directly (both paired with a third) can still
run ceremonies together. A key package is public material; the relay
storing it is not escrow. Devices verify the signature against the
identity fingerprints in their pairing records before sealing anything
to it, so the relay substituting a key package wins ciphertext it
cannot cause to be opened.

## 7. Pairing over the mailbox

The pairing ceremony (`crates/ffi/src/pairing.rs`, issue #97) needs a
rendezvous before the joiner can read the channel; the mailbox is that
rendezvous and nothing more. Commitment, offer, reveal, acceptance and
grant travel as `POST /channel/pairing` bodies, fetched by polling
`GET /channel/pairing?since=`. Every field is public-key material,
commitments, signatures, or AEAD ciphertext sealed to the exchange; the
byte-scan test in `pairing.rs` is the standing proof, and the human SAS
comparison is what defeats a relay that substitutes messages. The
mailbox holds one pairing at a time and evaporates on completion,
abandonment, or after an hour.

## 8. Batching, padding, and what the timing says

`set_change_merge_interval(0)` keeps every commit its own change
(`crates/core/src/document.rs`), so publishing on commit boundaries
would hand the relay typing rhythm at keystroke grade. ADR-0021 §4
requires batching on a clock, and this document owns the number:

- **Publish at most every 2 seconds** per channel, coalescing
  everything since the last publish into one `blobs[]` entry per page
  touched. An idle page publishes nothing: no keepalives, no
  heartbeats, matching the no-polling frugality discipline
  (`crates/core/src/store.rs`).
- **Pad every sealed blob** to the next power-of-two size, 256 bytes
  minimum, 64 KiB maximum bucket — the ledger's `SizeClass` discipline
  (`crates/core/src/ledger.rs:61-75`) applied to the wire: the exact
  length is a weak fingerprint of content, so the relay gets buckets.
- Long-poll `wait` is 25 seconds, inside ordinary LB idle timeouts, and
  a fetch returning empty re-polls immediately: delivery latency is
  bounded by the publish clock, not the poll.

Checked against ADR-0021 §4 as specified, not as imagined: the relay
learns account identity (attach), device count and attachment times
(attach list), delta timing at 2-second grain (publish clock), delta
sizes in buckets (padding), ceremony times (frame supersessions), and
the frame's existence and bucketed size. That is the six-channel
admission exactly; nothing here adds a seventh, and page count stays
structurally unlearnable because §1 put every page behind one seal.

## 9. What the server implements

The relay is these behaviours and no others; the server-side issue in
the onetimesecret repo implements this section against the message
table in §4.

1. Authenticate attach against the account (issue #98) and scope every
   route to the account's one channel; answer attach with the channel
   position and the roster of §4 — each known device's fingerprint,
   key package, and attach time (amended 2026-08-27).
2. Store blobs; never parse one. There is nothing to parse: every
   payload is ciphertext by §4.
3. Sequence deltas per channel; serve `since`; answer pre-buffer
   `since` with `410 rejoin`.
4. Accept a frame only at epoch current+1, atomically superseding the
   old frame and dropping every older delta.
5. Refuse publishes past the §3 cap with `413 ceremony_required`.
6. Drop the channel whole after 8 idle days.
7. Hold the pairing mailbox of §7, one pairing at a time, one hour at
   most.

What it must never do, restated from ADR-0021 so the server issue
cannot lose it: hold any key, merge or compact anything, read a delta,
retain data past a supersession or the idle bound, or answer any
request with another account's bytes. The deletion behaviours are
hygiene; the security claim stays the key rotation (ADR-0021 §2), and
no server document may promise otherwise (ADR-0007).
