# ADR-0027: Account auth gates the sync channel

- **Status:** proposed. Three items are flagged for ratification and
  named as such in section 1 (the loopback port), section 2 (the
  server's refresh policy) and section 3 (the token's scope). Each is
  a fact the account server owns and this client can only tolerate.
- **Date:** 2026-09-01
- **Depends on:**
  [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md) section 3,
  which decided that the account and the device are two gates and that
  both must be passed. This ADR decides the account gate alone: which
  flow proves the account, how the proof survives an app that sleeps
  for days, where the proof rests, and what the client shows when the
  proof is refused. It grants no device the right to read content;
  that is issue #97's pairing ceremony and is not renegotiated here.
- **Leaves standing:**
  [ADR-0004](0004-keychain-prompt-timing.md)'s rule that key access
  happens on use rather than at launch; section 4 says why a
  background refresh belongs in the key material store rather than
  beside the API token.
  [ADR-0016](0016-content-persists-across-restart.md) section 3's
  `ThisDeviceOnly` protection class, unamended: the refresh token
  takes the same class as every other secret in that store, and rides
  no iCloud Keychain (ADR-0021 section 8).

## Context

Issue #98 asks for one thing: prove to the relay that the attaching
client belongs to the account. ADR-0021 section 3 already fixed what
that proof may and may not buy. It admits a client to a channel. It
says nothing about whether the device holding it was ever enrolled,
and a token that could admit a device to content would collapse the
two gates into one.

Three constraints bound the answer before any flow is chosen.

1. **The core loop needs no account and no network.** That is a
   load bearing exclusion, not an omission
   (docs/design-brief.md:75-80). Every state this ADR names has to
   leave the pad fully usable.
2. **The network boundary is two destinations, TLS only**
   (docs/spec/design/05-technical-direction.md:107-119). Account auth
   adds no third: the token endpoint lives on the configured OTS
   server, which is destination one, and the relay is destination two.
   The driver's transport is built bounded to exactly those two hosts.
3. **Losing work is unforgivable** (docs/tenets.md, tenet 1). An
   account failure is allowed to stop sync. It is not allowed to
   discard an edit the user made, including an edit that was queued
   for peers and never sent.

### What already existed

This ADR is written after the code, which inverts issue #98's stated
order and has to be said plainly rather than papered over. The client
half of the flow landed in PR #119 and PR #121, spec first
(docs/spec/feature/sync/account-auth.md, whose status line says
"built, spec first"), and this document promotes that spec to a
decision with its failure modes, adds the three sections the spec
left implicit, and records what remains unratified.

Standing before this ADR:

- The ceremony: `AuthCeremony::begin` mints the PKCE verifier, the
  `S256` challenge, the `state` and the exact loopback redirect URI
  (crates/sync/src/oauth.rs:81), and `redeem` checks the returned
  `state` before building the token request
  (crates/sync/src/oauth.rs:133). The one shot listener that receives
  the redirect is crates/sync/src/loopback.rs.
- The lifetimes: `TokenKeeper` holds the access token in memory only
  and treats the server's refusal as the only expiry authority
  (crates/sync/src/oauth.rs:221).
- The strategy: `BearerAuth` is a second `AuthStrategy` beside
  `BasicAuth`, added without touching the conceal path
  (crates/ots-client/src/auth.rs:49).
- The resting place: the refresh token rests under its own account,
  `sync-oauth-refresh`, in the key material store
  (crates/ffi/src/sync_driver.rs:44).
- The driver: sign in, refresh, sign out, attach, pump
  (crates/ffi/src/sync_driver.rs), and the shell's states and
  sentences (shell/Sources/CompanionKit/SyncController.swift).

What did not exist, and is what this ADR is actually for: a named
gate state the core reports rather than the shell inferring one from
scattered refusal strings; a client that survives an authorization
server which declines to rotate refresh tokens; and a rule about the
edits queued for peers when the gate closes mid session.

### What the authorization server offers

The authorization server is OTS itself. onetimesecret.dev is the v0.27
staging that adds OAuth through rodauth-oauth, and the relay validates
what OTS issued rather than minting anything of its own. What
rodauth-oauth ships decides which flows are even available:
`oauth_authorization_code_grant` and `oauth_pkce` are shipped features,
the README names RFC 8252's native app recommendations as the shape it
follows, and `oauth_device_code_grant` exists but is off by default,
which makes it a server change to request rather than a capability to
assume. Refresh token rotation and reuse detection are a server side
configuration this client can ask for and must not require; section 2
is written for a server that rotates and a server that does not.

## Decision

The app proves the account with OAuth 2.0 authorization code plus
PKCE in the user's own browser, returning on a loopback redirect, and
the resulting refresh token rests in the key material store under its
own account. The gate this establishes is reported to the shell as one
of seven named states, none of which may touch the pad, and none of
which may discard an edit.

### 1. The flow, and where the browser step lands

**Authorization code plus PKCE, in the system browser, returning to a
loopback listener.** RFC 8252 followed as written: public client, no
client secret, `S256` challenge, exact match redirect URI on
`http://127.0.0.1:{port}/callback`, `state` checked on return, one
redemption per ceremony.

- https://www.rfc-editor.org/rfc/rfc8252
- https://www.rfc-editor.org/rfc/rfc7636

The issue's own framing is that the app "is not a browser and has no
server side to receive a redirect". Both halves are answered by the
BCP rather than by preference. The browser step lands in the user's
default browser, where the session and the password manager already
are and where the app cannot see the credentials. The redirect lands
on a listener that binds one ephemeral port, accepts one request,
and closes: that is not a server side, it is a socket open for the
seconds a consent screen takes. The listener's patience is bounded
(five minutes) and a closed tab is an ordinary outcome, not an error
to recover from.

**Rejected: the device authorization grant (RFC 8628).** It is the
correct flow for a device that cannot open a browser, which a Mac is
not. It costs a polling loop, a worse consent story (read a code here,
type it somewhere else), and the documented device code phishing
pattern, in which an attacker's code is presented to a victim who
authorizes it. It also needs `oauth_device_code_grant` turned on
server side, so it is strictly more work for a weaker result. It stays
on the shelf for a future non macOS sibling with no browser, and only
for that.

**Rejected: a custom URL scheme redirect.** RFC 8252 permits private
use URI schemes, and on macOS any application may register any scheme,
so the operating system will happily hand the redirect to whichever
app claimed it most recently. PKCE means the interloper cannot redeem
the code, but the failure is silent and the user is left with a
ceremony that never returns. The loopback variant fails the same
attack louder: the port is bound by this process, so a competing
listener cannot take it while ours holds it.

**Rejected: an embedded web view.** RFC 8252 section 8.12 rejects it
for exactly our reason. The app could read the credentials as the user
types them, which is a claim this product would then have to make
about itself and could not check.

**Rejected: a pasted API token.** A long lived static secret moving
through the clipboard, in an app whose subject is clipboard hygiene,
with revocation as a support conversation.

**Failure modes.**

| Failure | Behaviour |
| --- | --- |
| The browser never returns | The listener times out and closes; nothing is stored; sync stays signed out; retry is a fresh ceremony. |
| Another local process holds the loopback port | The bind fails and the ceremony never begins (`port`); nothing is stored. |
| A redirect arrives with the wrong `state` | Refused before any redemption, so a stray or forged callback costs one aborted ceremony. |
| A redirect arrives with no code | Refused the same way; the user denied consent, or the server answered with an error. |
| The token endpoint refuses the code | Refused with its status, and the body is not echoed anywhere, since it can carry account identifiers. |
| The token endpoint cannot be reached | Reported as unreachable; the refusal is the network's, not the account's, and nothing is signed out. |

**Flagged for ratification: the loopback port.** RFC 8252 section 7.3
says an authorization server must allow any port for a loopback
redirect at request time, because the client cannot know in advance
which port it will get. Whether rodauth-oauth implements that
allowance, or matches the registered redirect URI including its port,
is a server fact this client cannot discover from here. If it matches
strictly, this client must bind from a small fixed list of registered
ports and fail when all are taken, which is a worse flow, and the
change belongs in `AuthCeremony::begin` and the registration. The
maintainer confirms which it is with the server side before the first
real sign in.

### 2. Lifetime, and an app that sleeps for days

The ordinary case for this app is days asleep between syncs, so the
lifetimes are chosen for that shape rather than for a web session.

- **The access token is never persisted.** It lives in memory for the
  session and dies with the process. A relaunch therefore begins with
  no access token and this is the intended path, not an error path.
- **The refresh token is what rests**, under section 4's account. A
  relaunch resumes signed in without a browser by refreshing once
  before the first attach.
- **The server's refusal is the only expiry authority.** The client
  never pre judges expiry against its own clock, so a skewed clock
  cannot invent an outage and a slow one cannot keep using a token the
  server has already retired. This is the same discipline the expiry
  design follows for the opposite reason (ADR-0021 section 6): where a
  deadline is the product, the client computes it; where a deadline is
  the server's to declare, the client asks.
- **Expiry mid session is one refresh and one retry.** The relay
  answers an expired bearer with `401`; the client refreshes, rebuilds
  the one request, and sends it once. A second `401` on the same round
  is treated as the grant being dead rather than as a loop to keep
  running. The long poll is included: it returns on the `401` like any
  other request and re enters after the refresh.
- **A refused refresh signs sync out and deletes the resting token.**
  Revoked account side, reuse detected, or the idle window elapsed:
  all three are indistinguishable from here and all three are handled
  identically. Re enabling sync is the section 1 ceremony again.
- **An unwell token endpoint is not a refusal.** A `5xx` or a mangled
  body is the endpoint being unwell, not the grant being dead: the
  refresh token stands and the next pump retries. Only the endpoint's
  own `4xx` pronounces a grant dead. Signing a user out because a
  gateway hiccuped would be an outage the client invented, which is
  the same error as pre judging expiry by a clock.
- **A server that declines to rotate keeps its grant.** RFC 6749
  section 6 makes the new refresh token optional in a refresh
  response. A client that requires one refuses every grant from a non
  rotating server, and since the refusal arrives with a `2xx` it is
  not even a refusal the client can explain. So: a `2xx` carrying an
  access token and no refresh token is a success, and the held refresh
  token stays held. Rotation is requested, never required.

**Rejected: a local expiry timer from `expires_in`.** It would let the
client refresh before a request fails, saving one round trip on a wake
from sleep. It costs the one property that makes the ladder honest:
with a timer, a wrong clock produces a client that either refuses to
use a valid token or insists on using a dead one, and the app's own
clock discipline exists because sleeping machines have wrong clocks
(crates/core/src/clock.rs). The `401` costs one round trip and is
never wrong.

**Rejected: keeping the access token across a relaunch.** Persisting
it would save the wake up refresh and would put a bearer token, valid
for minutes to an hour, into a file that outlives the process for no
benefit the refresh token does not already provide.

**Flagged for ratification: the idle window and the rotation policy.**
"90 days idle, rotated on use, with reuse detection" is what the app
wants and is entirely the server's to set. The client tolerates any
window and both policies, and issue #98's answer to open question 21
(docs/spec/design/06-open-questions.md:180-183) is exactly this: the
desktop app's requirement of v3 auth is a long idle refresh window and
nothing else. It does not want a device claim inside the token, which
would re entangle the two gates ADR-0021 section 3 separated.

### 3. Sync credentials are separate from conceal credentials

The conceal path keeps HTTP Basic, an `extid` and an API token behind
the `AuthStrategy` trait (crates/ots-client/src/auth.rs:10-13), under
the `api-token` account. The sync path holds an OAuth refresh token
under `sync-oauth-refresh`. They are two credentials for two acts and
neither revocation reaches the other.

The argument, since separation is the default and defaults still have
to be argued:

- **A conceal is deliberate and foreground; sync is background.** One
  credential serving both would make a background act as powerful as
  the deliberate one, which is ADR-0021 section 3's rule and the whole
  reason a conceal is a gesture rather than a setting.
- **They fail at different times and want different answers.** A
  refused conceal is one gesture failing in front of the user, who can
  retry it. A refused refresh is a background loop that must stop
  quietly and stay stopped until the user comes back to it. A shared
  credential would force one of those behaviours onto the other.
- **They want different keychain tiers.** The API token stays in the
  handed store, where its ACL prompt behaviour is the deliberate act
  ADR-0004 designed the prompt timing for. A refresh happening while
  nobody is looking must never be able to raise that prompt, so it
  rests in the key material store instead (section 4).
- **Revocation is the point.** Deleting `api-token` disables
  authenticated conceal and only that. Deleting `sync-oauth-refresh`,
  or the server revoking the grant, disables sync and only that. This
  is the independence the pairing accounts already hold to, and it is
  tested in both directions rather than asserted.

**Rejected: one credential for both paths.** Cheaper to build and it
makes losing either one lose both, and it puts the strongest
credential the app holds behind the loop that runs unattended.

**Rejected: one credential with two scopes.** Better than the above
and still wrong here: a scope narrows what a token may do, not who may
use it, and the two paths differ in when they run and which keychain
tier that demands, not only in what they touch.

**Flagged for ratification: the scope the client requests.** The
authorize request today names no scope, so the server's default
applies. The client should ask for the least privilege scope the
server defines for the relay, so that a leaked sync token cannot
conceal, read account data, or act as the account anywhere else. That
scope has to exist server side before the client can name it, and
requesting an undefined scope is refused by conformant servers, so the
client stays silent until the server has one. Naming it is required
work on the server side, and this ADR records that a scopeless sync
token is a known temporary width, not the intended end state.

### 4. Where the tokens rest

The refresh token rests in `crates/credentials`' key material store,
under `sync-oauth-refresh`, with the `ThisDeviceOnly` protection class
every secret in that store carries (ADR-0016 section 3, ADR-0021
section 8). The access token rests nowhere.

**Not under the rotating content key**, and the reasons are
independent enough that any one of them decides it:

- **A content rotation must not sign the user out.** The content key
  halves rotate whenever the pad has nothing to hold (ADR-0016), and
  that rotation exists to make old ciphertext dead. A refresh token
  under it would die with the ciphertext, so an ordinary empty pad
  would silently end the user's sync session.
- **Erasing the pad must not revoke the account, and revoking the
  account must not erase the pad.** The state file is the thing the
  erase path destroys. Entangling account access with it would make
  one gesture do two unrelated things, in both directions.
- **The state file travels; the keychain half does not.** A sealed
  state file is copied by backups. A long lived bearer credential
  belongs behind the keychain's protection class, not inside a file
  whose whole security story is a key that is deliberately destroyed
  on a schedule the token knows nothing about.
- **The precedent is already in the tree.** The ledger key sits in the
  same store for the same reason: not everything belongs under the
  rotating content key (crates/credentials/src/lib.rs:149-151).

**Rejected: the login keychain beside the API token.** The refresh
happens in the background, and the login keychain's ACL prompt is a
user facing event that belongs to deliberate acts (ADR-0004). A prompt
raised by a background refresh would be an unexplained interruption
attached to no gesture.

**Rejected: keeping the refresh token in memory only.** It would make
every relaunch a browser ceremony, which for a menu bar app that
relaunches on every update is a flow nobody would leave enabled.

### 5. Offline grace, and the seven states

An expired or refused token disables sync. It may never disable the
pad, and nothing in the pad's routes consults the gate: creating,
editing, sealing, copying, concealing and expiring a page are
untouched by every state below. That is the design brief's exclusion
kept structurally rather than promised.

The client's admission to the channel is one value, reported by the
core as a machine token and turned into words by the shell. Issue #102
owns the words; this ADR owns the states, which are exactly these
seven:

| State | What is true | What the surface owes |
| --- | --- | --- |
| `off` | Sync is not configured. Nothing has been switched on, nothing can leave. | Nothing at all. Off must stay indistinguishable from the app before sync existed. |
| `signed_out` | Configured, and no credential rests on this device. | Sync is signed out; the pad is unaffected. |
| `signing_in` | A browser ceremony is out and has not returned. | Waiting on the browser, with a way to give up. |
| `refused` | A credential rested, the server refused it, and it has been deleted here. | The account refused the sign in; sync is off and the pad is unaffected. |
| `unreachable` | A credential rests and the last attempt to use it could not reach the account server or the relay. | The relay cannot be reached; edits stay local and sync retries. |
| `ready` | A credential rests, nothing has refused it, and no channel is attached. | Reaching the relay. |
| `attached` | The channel admitted this client. | Nothing, unless another condition applies. |

Three rules keep the ladder honest.

**`refused` and `signed_out` are different facts and the same
posture.** The distinction is the cause, and the client keeps it only
for the session in which it happened: the fault is in memory, so a
relaunch after a refusal reads as `signed_out`. That is the truth the
device actually holds, since nothing durable records why the token is
gone, and inventing a durable "you were refused" record would be a
claim about the past that a restored backup could falsify.

**`unreachable` never deletes anything.** A network that did not
answer is not a server that said no. The credential stands, the retry
follows the publish clock rather than a hot loop, and the state clears
itself the moment a request succeeds.

**Falling behind is not a gate state.** A device the channel rotated
past has passed the gate and lacks a key. It is reported on its own
axis and belongs to ADR-0021's amendment 1 and issue #94, not here.
Folding it into the account ladder would say the account refused a
device that the account admitted.

### 6. The gate admits, it never reads

Nothing in this ADR gives any device the right to read content. A
client that passes the account gate and has never paired downloads
ciphertext it cannot open, which is ADR-0021 section 5's rule that
authorization is cryptographic and never possession. The two gates
fail independently and both must be passed. The gate state above is
therefore a report about attachment only, and no key, no key frame and
no welcome entry is ever handed out on the strength of a bearer token.

### 7. Closing the gate must not discard an edit

Tenet 1 applies to the sync boundary as much as to the store. When the
gate closes mid session, the engine dissolves: that is correct, and it
must not take unsent work with it.

The engine tracks, per enrolled page, how far its exports have gone.
That cursor advances when ops are queued for publication, which is
before they are sent, so a session dissolved between the queue and the
acknowledgement would leave the cursor past ops no peer ever received.
The pad would still hold every character, and the peers would have a
hole, permanently: the next export starts after it.

The rule: **an export cursor advances for good only when the relay
acknowledges the batch that carried it.** A dissolving engine rewinds
each page to its last acknowledged position, so a re enrolment
republishes what was queued and never sent. Rewinding stops at the
last acknowledgement rather than going to the beginning of the page,
because a ceremony rebuilds the document under a fresh peer identity
and an export from before that rebuild would arrive at a peer as a
second copy of the text rather than as its own history.

**Rejected: rewinding to the pristine cursor on any dissolution.**
Simpler, and it republishes the whole page every time, which after a
ceremony is the duplicate merge the settled cursor exists to prevent.

## Consequences

- Sign in is a browser trip the app cannot see into, and the app holds
  no password ever. The cost is that sign in cannot happen without a
  browser and cannot be automated, which is the correct shape for a
  credential that gates a network channel.
- Waking from days of sleep costs one refresh round trip before the
  first attach. There is no timer, no preemptive refresh, and no way
  for a wrong clock to produce an outage.
- A user who revokes the app's grant in their account settings sees
  sync stop and the pad continue. A user who deletes the API token
  sees conceal stop and sync continue. Neither gesture reaches the
  other.
- The refresh token is a durable secret this app now keeps. It rests
  in the same tier as the ledger key and the keychain content half,
  under the same protection class, and it is deleted by exactly one
  gesture.
- The shell no longer infers the account's standing from refusal
  strings. One value crosses the seam and one place turns it into a
  sentence, which is what makes "no degraded state is silent"
  checkable rather than aspirational.
- Sync off remains bit for bit today's app: `off` is the default, it
  configures nothing, opens no socket and says nothing.
- Three server side facts remain unratified (the loopback port, the
  refresh policy and the scope). Each has a client behaviour that
  tolerates either answer, so none of them blocks, and each is a
  question the first real sign in against onetimesecret.dev answers.

## Eject triggers

- **rodauth-oauth matches loopback redirect URIs including the port.**
  Section 1's ephemeral bind becomes a fixed port list, with its own
  failure when every port is taken, and the ceremony's registration
  changes with it.
- **The authorization server has no refresh token at all**, or an idle
  window short enough that an app asleep for days is signed out
  routinely. Then the flow survives but the product does not: sign in
  stops being an enrolment and becomes a chore, and issue #98 reopens
  with the device authorization grant and a much longer lived
  credential back on the table. ADR-0021's own eject trigger says the
  same thing from the other side.
- **The relay stops accepting OTS issued tokens** and wants a
  credential of its own. That would make the relay an identity
  provider, which contradicts ADR-0021 section 1's blindness, and the
  right response is to argue the relay back to validation rather than
  to add a second account system.
- **A scope for the relay ships server side.** Section 3's flagged
  item stops being flagged: the client names the scope and the
  scopeless token becomes a migration.
- **The two credentials are asked to merge**, by a support load nobody
  predicted or by a server that issues one token for everything. That
  reopens section 3, which is an argument this ADR expects to win
  again rather than a settled matter to cite.
- **A gate state turns out to be silent in practice**, meaning a user
  reaches a condition the seven states do not name. The ladder is
  amended rather than stretched, because a state that has to be
  inferred from two others is the inference this ADR removed.
