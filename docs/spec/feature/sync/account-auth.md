# Account auth for the relay channel

**Decided in [ADR-0027](../../../adr/0027-account-auth-gates-the-sync-channel.md)**,
which turns this document into a decision, adds the failure modes
for each choice, and settles the three things this spec left implicit:
the gate as a state the core reports rather than the shell infers
(§5's table below), a server that declines to rotate refresh tokens,
and what happens to edits queued for peers when the gate closes mid
session. Where the two disagree, the ADR governs.

**Status:** built, spec first — the order issue
[#98](https://github.com/onetimesecret/macos/issues/98)'s acceptance
criteria require: the flow, its failure modes and the reasons were
written down before any client code, and the client now implements
them (`crates/sync/src/oauth.rs` for §1's ceremony and §2's lifetimes,
`crates/sync/src/loopback.rs` for the redirect, `BearerAuth` in
`crates/ots-client` for §3, driven by `crates/ffi/src/sync_driver.rs`
and `SyncController.swift`). The one job this document covers is
ADR-0021 §3's first gate: prove to the relay that the attaching client
belongs to the account, and nothing else. Device trust is pairing
(issue #97, `crates/ffi/src/pairing.rs`) and is not renegotiated here.

The authorization server is OTS itself. onetimesecret.dev, the v0.27
staging that adds OAuth via rodauth-oauth, issues the codes and the
access and refresh tokens this flow consumes; the relay validates what
OTS issued and mints nothing of its own. Everything below is the
client's side of that arrangement, and the token lifetimes in §2 are
the server's to set.

## 1. The flow: authorization code + PKCE in the system browser

The app authenticates with **OAuth 2.0 authorization code + PKCE, in
the user's default browser, returning on a loopback redirect** — the
native-app BCP, RFC 8252, followed as written: public client, no
client secret, `S256` code challenge, exact-match loopback redirect URI
(`http://127.0.0.1:{ephemeral}/callback`), `state` checked on return.
The app opens the browser, listens once on an ephemeral loopback port,
exchanges the code, and closes the listener.

The issue asks where the browser step lands for an app that "is not a
browser and has no server side to receive a redirect". The BCP's
answer is that a loopback listener is not a server side: it exists for
one redirect, on the local interface, for the seconds the ceremony
takes. The pad itself never embeds a web view.

- RFC 8252: https://www.rfc-editor.org/rfc/rfc8252
- RFC 7636 (PKCE): https://www.rfc-editor.org/rfc/rfc7636

**Rejected: the device authorization grant** (RFC 8628). It is the
right flow for a device without a browser, which a Mac is not; it costs
a polling loop, a worse consent story ("type this code somewhere
else"), and the documented device-code phishing pattern, and buys
nothing here.

**Rejected: an embedded web view.** RFC 8252 §8.12 rejects it for us:
the app could read the credentials, which is exactly the class of claim
this product refuses to have to make.

**Rejected: pasting an API token by hand.** It is a long-lived static
secret moving through the clipboard of a clipboard-hygiene app, and it
makes revocation a support ticket.

## 2. Token lifetime for an app that sleeps for days

The ordinary case is a menu-bar app asleep for days between syncs, so
lifetimes are chosen for that shape:

- **Access token:** short-lived (the server's default, minutes to an
  hour). Never persisted; held in memory for the session.
- **Refresh token:** long idle allowance (90 days without use),
  **rotated on every use** with server-side reuse detection. Waking
  from days of sleep means one refresh before the first attach, which
  is the intended path, not an error path. Rotation is requested and
  never required: RFC 6749 §6 makes the new token optional, so a
  refresh answer carrying an access token and no refresh token is a
  success and the resting token stands (ADR-0027 §2). Requiring one
  would refuse every grant a non-rotating server issues, behind a
  `2xx` the client could not explain.
- **Expiry mid-session:** the relay answers an expired access token
  with `401`; the client refreshes and retries the one request. The
  long-poll (`relay-protocol.md` §4) simply returns on the same `401`
  and re-enters after the refresh. The client never pre-judges expiry
  by its own clock — the server's `401` is the only authority, so clock
  skew cannot invent an outage.
- **Refresh refused** (revoked account-side, rotation reuse tripped,
  or the 90 days ran out): sync stops and says so — issue #102's
  degraded-state sentence, "Sync is signed out; the pad is unaffected"
  — and the pad keeps working untouched. Re-enabling sync is the §1
  ceremony again.

This is the answer to open question 21
(`docs/spec/design/06-open-questions.md:180-183`) fed back into v3
auth while it is unbuilt: the desktop app needs refresh rotation with a
long idle window, and it does not need a device claim inside the token
— the account is not the device (ADR-0021 §3), and putting a device
identity into the account credential would re-entangle the two gates
this design keeps separate. If phase 2 lands PASETO bearer tokens
(`docs/spec/design/05-technical-direction.md:139`), nothing here moves:
the flow and lifetimes above are format-agnostic, and the bearer's
encoding is the server's business.

## 3. Sync credentials are separate from conceal credentials

The conceal path keeps HTTP Basic with the `extid` and API token behind
the `AuthStrategy` trait (`crates/ots-client/src/auth.rs:10-13`),
stored under the `api-token` account. The sync tokens are a different
credential for a different act: a conceal is deliberate and foreground,
sync is background, and one credential serving both would make the
background act as powerful as the deliberate one (ADR-0021 §3).

- The refresh token rests in the credential store under its own
  account, `sync-oauth-refresh` — beside, and never inside, the
  rotating content-key derivation (`crates/ffi/src/persist.rs`): a
  content rotation must not sign the user out of sync, and clearing
  sync must not touch staged pages. The ledger-key comment's rule
  generalizes: not everything belongs under the rotating key.
- Revoking either credential leaves the other standing: deleting
  `sync-oauth-refresh` (or the server revoking the grant) disables sync
  and only sync; deleting `api-token` disables authenticated conceal
  and only that. This is the same independence the pairing accounts
  already test (`crates/ffi/src/pairing.rs`,
  `pairing_secrets_are_separate_from_the_conceal_credentials`), and
  the sync-auth implementation extends that test to its account.
- The swap landed additively: `BearerAuth`
  (`crates/ots-client/src/auth.rs`) is a second `AuthStrategy`
  implementation, with Basic untouched.

## 4. Offline grace

The core loop needs no account and no network
(`docs/design-brief.md`), and this flow cannot change that: every
token here gates the relay channel and nothing else. No token is ever
required to create, edit, seal, copy, or expire a page; an expired,
refused, or absent credential disables sync while the pad runs
undisturbed, and the only visible consequence is the status sentence.
Offline, the client does not refresh preemptively and does not retry
on a timer tighter than its publish clock; it refreshes when the next
attach or publish actually needs the network.

## 5. Failure modes, enumerated

| Failure | Behaviour |
| --- | --- |
| Browser never returns (closed tab, abandoned consent) | The loopback listener times out after 5 minutes and closes; sync stays off; the enrolment surface offers retry. |
| Loopback port hijacked by another local process | The interloper receives a code it cannot exchange: PKCE binds the code to this app's verifier, and `state` mismatch aborts the ceremony client-side. RFC 8252 §8.3's analysis, adopted. |
| Redirect arrives with wrong `state` | Abort, nothing stored, retry offered. |
| `401` mid-session | Refresh once, retry once; on second `401`, treat as refresh refused. |
| Refresh refused or reuse detected | Sync signed out with its sentence; pad untouched; re-enrol via §1. |
| No network at refresh time | Sync degraded with its sentence ("the relay cannot be reached"); retry follows the publish clock, not a hot loop. |
| Token or grant revoked account-side | Indistinguishable from refresh refused, handled identically. |

Every one of these lands on one of ADR-0027 §5's seven gate states,
which the core reports as a machine token in the sync status (`gate`)
and through `companion_sync_gate`. Closing the gate dissolves the
engine, and the dissolve rewinds each enrolled page to what the relay
acknowledged, so an account failure costs the peers a delay and never
an edit (ADR-0027 §7).

Every one of these ends in a state issue #102 owes a sentence, and none
of them may be silent — an expired token disabling sync without a word
would break the promise pass 1 wrote down: no unaccounted behaviour
change, in either direction. Those words are now written down and
built: [surface.md](surface.md) §5 carries the sentence each of these
rows lands on, §4 the header word the gate chooses, and §2 the way out
of a browser trip that is still open, which is what ADR-0027 §5's
`signing_in` row asks the surface for.
