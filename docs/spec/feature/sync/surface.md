# What sync looks like in the app

**Status:** built (issue
[#102](https://github.com/onetimesecret/macos/issues/102)). The
controls, words and marks below are in the tree:
`shell/Sources/CompanionKit/SyncController.swift` holds every rule as
a pure function, `SyncSettingsSection.swift` draws the controls,
`PageSurface.swift` carries the page's own lines, and
`shell/Sources/OnetimePad/Views/BackdropRootView.swift` carries the
header word. The hardware only checks live in
[docs/qa/verification-procedures/sync-enrolment.md](../../../qa/verification-procedures/sync-enrolment.md).

**Governed by** [ADR-0027](../../../adr/0027-account-auth-gates-the-sync-channel.md)
section 5, which owns the seven gate states, and
[ADR-0021](../../../adr/0021-multi-device-sync-over-a-blind-relay.md)
sections 2 and 3, which own pairing, the short authentication string
and revocation. This document owns the words and where they appear.
Where it disagrees with either ADR, the ADR governs.

Sync is background network in an app that has promised for its whole
life that nothing leaves the machine except on a deliberate act. The
documents can be amended and the promise still broken, if the app
itself does the reaching quietly. So the surface has three jobs: make
the off switch real, make every degraded state say something a user
can act on, and never invent a second vocabulary for what is already
being said elsewhere on the same card.

## 1. Off, and what off means

The switch is `sync.enabled` in the settings defaults, off unless
somebody turned it on, and off is not a quieter version of on. A
controller that is never enabled resolves no endpoint, configures no
core, opens no socket and publishes no sentence, and the core it is
driving reports the gate `off`, which is the state in which no host
has ever been named.

That is checkable rather than promised, and it is checked from both
sides in `SyncOffSwitchTests`. The shell side asserts that a
controller nobody switched on has no status, no devices, no standing
sentence and no header word, which is everything the surface draws
from. The core side asserts the gate, because every sync route needs a
configure first and the gate moves off `off` the moment one lands. An
app that reached the network with the switch off would have to leave
one of the two changed.

Turning the switch on with no relay configured is the one state where
sync is on and nothing can leave. The gate still reads `off`, the
header still says nothing, and the page says why in full.

Turning the switch off ends the sign in ceremony as well as the loop.
A browser trip is part of the session, and one left running behind the
switch comes back with a grant that the core persists before it
answers, so a shell that merely declines to attach has already been
signed in by the time it declines. `stop` cancels the ceremony for
that reason, and the proof is that nothing is left to give up on
afterwards.

## 2. Enrolment

**Signing in** is ADR-0027 section 1's browser trip, begun from the
one button in Settings. The app opens the system browser and the gate
moves to `signing_in` for as long as the trip is out, which is a state
of its own rather than a quieter signed out: a consent screen is open
on the user's screen and the app that opened it should say so.

**Giving up** is drawn beside the waiting line, and only while there
is a trip to end. The core ends the ceremony rather than recording a
wish, and it covers the whole ceremony rather than its first half,
which is where the first attempt at this went wrong.

`companion_sync_signin_cancel` raises the abandon flag of the
ceremony that stands, and the flag belongs to that ceremony rather
than to the sync state, so a cancel can never reach a later trip. It
is read at three points, because a sign in has three places it can be
waiting. The loopback listener watches it while the browser is out,
so a five minute patience collapses to one poll. The finish reads it
again after the token exchange returns, since a landed redirect still
has seconds of network ahead of it and a grant nobody is waiting for
any more is never parsed. And the last read is under the lock that
guards the store, so a cancel either wins outright or arrives to find
nothing in flight and answers false.

Each of those is reported as `abandoned`, which is what actually
happened. A cancel that lands before the finish call has even run is
the ordinary order, since the gate reads `signing_in` from the moment
a ceremony is begun and the way out is on screen well before any
finish starts; that finish finds nothing and answers `no_ceremony`,
because the flag went with the ceremony it ended and there is nothing
honest left to read. `no_ceremony` therefore covers both a caller out
of order and a give up the finish never met, and it has a sentence of
its own: no path here reaches the sentence about a server refusing,
because in none of them was a server asked anything (ADR-0027 §2,
where silence is never a no). A trip the user ended and a trip that
never returned are one fact to the core, so the shell keeps the
difference for the length of one settling and says which it was, and
a settling that arrives after a give up never attaches whatever it
carries.

**Pairing** is issue #97's ceremony on this surface, in the same
section: an invite or a join, a spinner while the mailbox messages
cross, and then the six digits large on both devices with two verdicts
under them. The failing verdict is always offered, because a
comparison that cannot fail verifies nothing (ADR-0021 section 3). A
mismatch aborts whole and stores nothing.

## 3. The device list

Under the sign in, while sync is on and signed in: every device the
channel knows, each labelled as what it is.

- **This Mac**, first, with no time beside it. Saying when the machine
  in front of someone was last seen would be a strange thing to tell
  them.
- **A paired device**, with its label, the head of its fingerprint,
  and when the channel last saw it. The stamp is the attach time the
  relay reported for that peer, which is the one piece of metadata
  ADR-0021 section 4 admits the relay may hold. It says "seen" rather
  than "active" because it is when the device joined the channel, and
  it is coarse because the roster refreshes when this Mac attaches and
  ages between attaches. A stamp from the future is two clocks
  disagreeing and reads as just now.
- **An attached stranger**, a device that passed the account gate and
  no pairing vouches for, marked "attached, never paired" in ember. It
  can open nothing (ADR-0021 section 5) and it is worth showing
  exactly that loudly.

**Revocation** is on each paired row and nowhere else: no revoke
button exists for this Mac or for a device no pairing established.
Revoking removes this Mac's trust in that device, so key rotations
this Mac starts seal nothing new to it; what it already holds, it
holds, and a device paired from more than one Mac must be revoked on
each. The confirmation says all three.

## 4. The header word

The header has carried a persistence word since issue #49: `saving`,
`saved`, `save failed`, absent until a write is owed, quiet when
settled, ember when it needs acting on. Sync says the same kind of
thing about the same session, so it takes the same shape rather than a
vocabulary of its own. One lower case word, beside the persistence
word, chosen by the gate the core reports and by nothing the shell
inferred.

| Gate | Word | Tone |
| --- | --- | --- |
| `off` | none | |
| `signed_out` | `sync signed out` | plain |
| `signing_in` | `signing in` | plain |
| `refused` | `sync refused` | ember |
| `unreachable` | `sync offline` | ember |
| `ready` | `reaching` | plain |
| `attached` | `synced` | quiet |

Two states are not the gate's and are still the header's. A device the
channel rotated past reads `sync behind` in ember: it passed the gate
and lacks a key, which is ADR-0021 amendment 1's axis and not the
account's. That reading outlives a network one. An unreachable turn
and a quiet turn both leave `behind` standing, because a relay that
blinked says nothing about which key this pad holds, and letting the
blip take its place would clear on the next good turn and leave the
header saying `synced` for a pad that is still short a key. Only a
rejoin ends it. Everything else is the newer fact and replaces it,
the account axis included: a pad that is behind and signed out has a
sign in to do before it can rejoin. A channel attached with pages enrolled and no peer awake
reads `sync waiting` rather than `synced`, which is issue #94's state
and the one cheerful lie this word could otherwise tell.

`off` earns no word even with the switch on. The ADR gives that state
nothing to say, and the page's own line says the whole of it in a
place with room for the reason.

## 5. The sentences

One standing line above the tab strip, present only while sync is on
and has something to report. Each condition has its own sentence and
none is silent. The four ADR-0027 section 5 names are its words; the
rest are written in the same voice.

| Condition | Sentence | Tone |
| --- | --- | --- |
| On, no relay configured | sync is on but has no relay configured; nothing leaves this Mac | ember |
| Signed out | sync is signed out; the pad is unaffected | ember |
| Refused | the account refused this sign-in; sync is off and the pad is unaffected | ember |
| Relay unreachable | the relay cannot be reached; edits stay local and sync retries | ember |
| Behind a rotation | sync fell behind a key rotation; edits stay local until this pad rejoins | ember |
| Signing in | waiting on your browser to finish signing in; Settings can give up on it | secondary |
| Attached, nothing awake | no other device is awake; pages sync when one wakes | secondary |

A failed sign in adds its own line in Settings, one sentence per
ADR-0027 section 1 failure row, standing until the next attempt:
the browser never returned, the sign in was given up, there was no
sign in to finish, the sign in came back wrong and was refused, the
server could not be reached, the Keychain refused to store the sign
in, a sign in is already waiting on the browser, sync has no server
configured to sign in against, and the server refused the sign in.
The last of those is the only one that speaks for the server, and it
is reached only when a server actually answered.

## 6. A page being written elsewhere

While a peer's edits are landing on a page, that page carries a line
of its own: **another device is editing this page**. Secondary text,
never a dialog. The edits are merging either way, so there is nothing
to decide and nothing worth interrupting for.

It costs no presence protocol. The engine already applies remote ops
and already reports each as an `applied` event, and since issue #102
that event names the local page as well as the cross device identity,
so the shell can say which of its own pages is meant. Nothing extra is
told to the relay and nothing extra is asked of it.

One thing had to be corrected for the mark to be true. The relay is
blind and its delta stream carries no author, so a device fetches back
what it published itself and imports it again, and the session
reported that as an applied edit. Harmless for a refresh and a lie
here, since a page would say another device was editing it while its
owner typed. An import that leaves the document's frontier where it
was brought nothing, and only something brought is news.

The mark lasts ninety seconds past the last edit that landed: long
enough to cover the pauses in someone's writing and the publish
clock's own two seconds, short enough to mean now rather than today.
One timer is armed at the moment it lapses, rather than a clock
ticking over a set that is empty nearly always. The switch going off
clears every mark, because nothing is arriving from anywhere then.

## 7. What this surface deliberately does not do

- **No second settings window.** Every control is a section of the one
  Settings form, between the day mode toggle and the login item.
- **No `HiddenUI` flag.** Issue #78 hid four affordances that had not
  earned their place; nothing here arrives by reopening that argument.
- **No new shortcut.** The keymap file is the source of any chord this
  app has (issue #76), and this surface asked for none: everything
  here is reached from Settings, which already has one.
- **Controls that exist only while needed appear and leave with the
  condition they answer**, rather than standing there disabled. The
  ledger's clear button is the shape being followed, and three
  controls take it: the give up beside a browser trip that is out, the
  revoke on a paired device, and the failing verdict during a
  comparison.
- **No page enrolment by default.** Which pages travel is still the
  per page choice in the tab's context menu (relay protocol section
  1), and it is shown only while sync is on.

## 8. What the surface cannot answer yet

The relay has not shipped, so no configuration this app can be given
today names one, and the enrolment path beyond the sign in has been
exercised only against the test doubles. What needs two machines, a
real browser trip and a real revocation is written down as a
procedure with a results table rather than assumed: see
[the QA procedure](../../../qa/verification-procedures/sync-enrolment.md).
