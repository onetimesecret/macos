# docs/spec/feature/background-surface/README.md
---

# Feature: the background surface (working name: Backdrop)

- **Status:** graduated from exploration. Implemented as the
  `CompanionBackdrop` target (ADR-0010), at feature parity with the
  panel since the parity amendment below; the v0 scope is kept as the
  record of what was argued first
- **Research:** [research.md](research.md) — what macOS makes possible
  for ambient, non-focus-stealing surfaces, and what it forbids
- **Structure decision:**
  [ADR-0010](../../../adr/0010-form-factors-as-sibling-targets.md)

## Why a second form factor

The panel app is a *summoned* surface: invisible between uses, called
with ⌥Space. The research confirms that is the right primary
architecture — and identifies one genuinely different posture the panel
cannot take: a surface that is **always there**, resting behind every
window at desktop level, glanceable the way a wall calendar is
glanceable, and raised for a moment of editing only by deliberate act.

The product's founding argument applies with full force here. The
alternative Onetime Secret competes with is not end-to-end encryption —
it is *people doing nothing*: pasting sensitive text into the first
surface that comes to mind, usually email or chat. A summoned tool must
be remembered to be used. An ambient one is the first surface that
comes to mind *because it is already in view*. Whether that theory
survives contact with real desks is the question this exploration
exists to answer. The goal is not to replace the panel; it is to have
several form factors and learn from the difference.

## Scope after ADR-0033

Every section below describes the **ambient panel** window role.
[ADR-0033](../../../adr/0033-separate-the-primary-editor-from-the-ambient-panel.md)
separates the primary editor from the ambient panel: OnetimePad now
has two window roles over one in-process document model. The primary
editor is a plain activating `NSWindow` with normal level, ordinary
Space membership, AppKit's own key, main and full screen behaviour
and participation in ⌘Tab, the Window menu, Mission Control and
Stage Manager; its own feature spec is
[primary-editor](../primary-editor/README.md).

Under ADR-0033 the routes leaving the panel for the editor window are:

- **A person's launch, the Dock icon click, a reopen and ⌘Tab.** These
  select the editor window (opening it when closed). The ⌘Tab
  amendment and the launch amendment below documented these as panel
  summons; they are now the editor window's, and both amendments stand
  as history rather than as the current rule. The launch amendment's
  other half stands: a launch the system performs shows the resting
  panel only and opens no editor window.
- **The Window menu and window cycling.** The editor window
  participates; the panel does not.
- **Full screen.** The editor window enters and leaves full screen by
  AppKit's rules. The panel keeps its stance-driven altitude and its
  all Spaces membership, so a hotkey summon over an editor in full
  screen still lands the panel on that Space.

Routes staying with the panel:

- **The hotkey (⌃⌥Space), the status item and a click on the resting
  card.** These raise the panel without activating the app. The panel
  remains the summoned surface for glances and moments of editing.
- **The panel's ownership rule.** The panel owns while it is raised or
  while the editor window is closed; the editor window owns otherwise.
  ADR-0033 records the ownership handoff.
- **Pin, `.canJoinAllSpaces` and the outside click rule.** Panel
  properties; the editor window has none of them.

## The stance model

The research's central finding is that "typed into" and "behind
everything" are contradictory window states on macOS — even Plash, the
reference wallpaper app, raises itself to a floating level to accept
a click. The backdrop therefore does not blur the two; it is always in
exactly one of two stances:

| | **Resting** | **Raised** |
| --- | --- | --- |
| Level | derived from stance and Pin | derived from keyboard ownership, Pin, and the keep-above preference |
| Mouse | ignored — clicks fall through to the desktop | interactive |
| Keyboard | refused outright (`canBecomeKey` = false) | may become key, never main |
| Spaces | on every desktop Space; stationary desktop furniture when unpinned; in a full-screen Space only when pinned | on every desktop Space; in a full-screen Space only while its altitude is floating (ADR-0034) |
| Countdown repaint | every 30 s | 1 Hz |
| Reading | the same page, dimmed, editing refused | the same page, editable |

The mouse row is all-or-nothing per window, not a choice. ADR-0015.

Raised is an interaction stance, not an always-above instruction. Altitude is
derived independently from stance, keyboard ownership, Pin, and the keep-above
preference:

| Surface state | Window level |
| --- | --- |
| Resting and unpinned | one above the window-server desktop level (clear of the wallpaper's *own window*, below icons) |
| Raised and keyed, or about to take keys | `.floating` |
| Raised, keyless, unpinned, with the default preference | `.normal` |
| Raised, keyless, unpinned, with **Keep OnetimePad above other apps when switching away** enabled | `.floating` |
| Pinned, in either stance | `.floating` |

The keep-above preference defaults to off. On an application switch, an
unpinned raised surface that loses the keyboard remains raised at `.normal`;
it stays open but the newly active application's normal windows may cover it.
Pin overrides the preference. ADR-0032 records this altitude decision.

Full screen participation follows the altitude, not the stance (ADR-0034). A
surface carries `.fullScreenAuxiliary` exactly when its altitude is floating
and `.fullScreenNone` otherwise, which is what an ordinary window at the normal
level does. A raised card that has dropped to `.normal` therefore stays out of
another app's full screen Space: ⌘Tab into that app is meant to show the app
alone. ⌘Tab back selects the editor window and rests the card (ADR-0033), and
the [hardware procedure](../../../qa/verification-procedures/spaces-and-cmd-tab.md)
records what the return does. A card that floats, because it holds the
keyboard, is pinned or keeps above, follows the person into those Spaces.
`.canJoinAllSpaces` is constant in every state (ADR-0019).

The summon gestures are ⌃⌥Space (two modifiers, deliberately: ⌥Space
belongs to the panel app, and option-only global shortcuts broke
outright on macOS 15.0 to 15.1), the menu-bar item and a click on the
resting card. ⌘Tab and the Dock icon were summons under the ⌘Tab
amendment below and select the editor window since ADR-0033. A summon
is a summon first and a dismissal last: a resting surface raises; a
raised surface that lost the keyboard (the user clicked or ⌘Tabbed away
to work beside the card) gets the keys back and is pulled to the active
Space; only a surface *already holding the keyboard* reads the gesture
as "put it away". Esc and a click outside the card always rest it.

Raising is the deliberate act that entitles the window to the keyboard
— the panel's focus law, unchanged. The window is a
`.nonactivatingPanel` (set at init; the style-mask bit is inert if
toggled later), so the hotkey summon never activates the app or
deactivates the user's frontmost one. An activation the person
performs (⌘Tab, the Dock icon, a reopen) no longer reaches the panel:
ADR-0033 routes it to the editor window, and the panel is raised as an
activation only when a modal return or a cancelled quit finds it the
owner.

A resting surface is exactly as visible as the desktop is: behind every
window, it shows only when the desktop shows (a bare corner of screen,
Show Desktop, Mission Control). That is the form factor, not a defect —
"is ambient actually ambient on a full screen of windows?" is one of
the questions the exploration exists to answer with lived experience.

Mechanics follow Plash's recovered recipe where the postures agree:
`.borderless`, transparent, shadowless; at rest,
`collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]` —
a full-screen Space is another app's room, and a *resting* backdrop
does not follow the user there. A summon does follow: a raise that
takes the keyboard floats, and a floating surface carries
`.fullScreenAuxiliary` (the membership bit is `.canJoinAllSpaces`
in every state since ADR-0019, and the full screen bit follows the
altitude since ADR-0034), holding the invariant the stances exist to
protect — **a surface that holds the keyboard is visible where the
user is looking**. The failure mode this forecloses is real: a hotkey
pressed from a full-screen app or another desktop would otherwise key
an off-screen window and silently swallow whatever was typed.

## The ⌘Tab amendment

Superseded for ⌘Tab and the Dock icon by ADR-0033, which gives both to
the editor window. Kept as written, as the record of why the app is a
regular app with Dock and switcher membership; that part stands.

The backdrop is a **regular app** — Dock icon, ⌘Tab membership — where
the panel is an accessory. First hands-on use found the core loop is
*alternation*: copy in the work window, switch, paste in the surface,
switch back. Mid-loop, muscle memory reaches for ⌘Tab, not a bespoke
chord, and an app absent from the switcher loses half of every
exchange. So activation is a summon route: ⌘Tab or a Dock-icon click
raises the surface, pulled to the user's Space and keyed;
resting from a ⌘Tab summon hands the *activation* back
(`NSApp.deactivate()`), not just key status, so the keyboard returns
to the app the user came from. The launch's own activation is the
person's launch arriving, and raises as a summon rather than as an
activation (the launch amendment below).

This knowingly amends "present, not centre stage": docs/spec/03 §2
settles "Dock icon?" with *No* — for the panel, whose whole posture is
invisibility between uses. The backdrop's posture is presence, and
presence that cannot be switched to is friction. Whether the fee is
too high is open question №7.

## The launch amendment

Superseded for a person's launch by ADR-0033, which opens the editor
window for it; the login half stands. Kept as written.

The backdrop's stance at launch follows who launched it. A launch the
person performs, from the Finder, the Dock, Spotlight or `open`, comes
up **raised and keyed**, on the Space the user is looking at and
anchored on today, the same posture ⌃⌥Space produces. A launch the
system performs, as a login item or any other background launch, comes
up **resting**, present behind every other window and not summoned,
exactly as the ⌘Tab amendment above had every launch. Dogfood phase 4
found what an always resting launch looks like from the chair: a
person opens the app, the surface takes its place behind every other
window, and they see nothing at all. An ambient surface earns its
ambience after it has been seen once; a login item, by contrast, was
opened by nobody and owes nobody a card in front of their work.

The two launches are told apart by the one fact AppKit already
supplies, not by guessing at the route from Apple Events or parent
processes: a person's launch activates the app moments after
`applicationDidFinishLaunching`, and a background launch never
activates. So the launch itself only places the surface, resting. The
first activation inside the two second launch window is read as the
person's launch and raises as a summon; an activation after the window
is a ⌘Tab or a Dock click and raises as an activation; no activation
leaves the surface resting, which is the login item.

## The persistence amendment

The backdrop **persists its page**, sealed at quit and opened at
launch, in its own state file under its own Keychain service.

The v0 stance below argued amnesia from the exploration's smaller
authority. Dogfooding overturned it on a plainer ground: a surface that
is always on screen is one you write *into*, not one you visit, and
every quit silently threw the writing away. The failure was not
experienced as scoping. It was experienced as a bug, and the closest
neighbouring app losing nothing on quit made it read as a broken app
rather than a deliberate one. An always-visible surface that forgets is
not a smaller product than one that remembers; it is a worse one.

What the amendment grants, and what it holds back:

- **Its own storage, both halves.** A separate state file
  (`~/Library/Application Support/com.onetimesecret.pad.noindex/state.sealed`)
  and a separate Keychain service (`com.onetimesecret.pad`, reached
  through `companion_new_scoped`; both were
  `com.onetimesecret.companion.backdrop` before 0.19.0). Two form factors remain two
  stores, per ADR-0010. Sharing the panel's key would put two signed
  binaries on one Keychain item, where each one's first read is a
  confirmation prompt for the other's key.
- **Restore at launch, not at first summon.** The panel defers its
  restore so that launching at login raises no prompt for a window
  nobody asked to see (ADR-0004). This surface has no later moment to
  defer to: it is on screen from launch, and a resting card showing an
  empty page it does not hold would lie at exactly the glance the form
  factor exists to serve. Launch and reveal are one act here. The cost
  is bounded by the scope above: the key is this app's own, created by
  and granted to this app's code identity, so the prompt arrives once
  per identity rather than once per launch.
- **The same refusal discipline as the panel.** A restore that fails
  over an existing file leaves the surface usable but withholds the
  licence to save, so a bad key or a damaged snapshot cannot overwrite
  yesterday's page with today's empty one. A refused save at quit is an
  alert, not a silent loss.
- **Still no chips, no conceal, no network.** Persistence was the one
  authority argued for here. The rest of the v0 absences stand.

This graduates the backdrop out of exploration, which fires ADR-0010's
first eject trigger: the seam wrapper is extracted to a shared
`CompanionKit` target and both form factors sit on it.

## The parity amendment

The backdrop holds **pages**, not a page, and shows everything the panel
shows: the tab strip and its whole keyboard map, sealed chips and the
gestures that make them, the ledger, and the exit ramp with its own
connection settings. The absences below are reversed, each with its own
argument, and the v0 list is kept underneath as the record of what was
argued before.

The general reason is the one the persistence amendment found, followed
one step further. A surface that is always on screen is one you write
*into*, and once you are writing into it you want the things writing
needs. Every absence was individually defensible and collectively read
as a worse copy of the app sitting next to it, which is not the
difference this exploration exists to learn from. The difference worth
learning from is the posture, and the posture is exactly what this
amendment leaves alone.

Each absence, and why it falls:

- **More than one page.** As many as the person opens: the core has no
  cap since issue #158, and nothing is evicted but by the countdown the
  person chose, as everywhere. One page was a floor set for an
  exploration, and an always-present surface accumulates more than one
  thing by the same logic that a desk does.
- **Chips and the sealing gestures.** The original argument was that a
  chip excerpt on an always-visible surface is standing shoulder-surfing
  exposure the summoned panel never has. True, and it points the other
  way once the surface holds real content: before this, the only way to
  keep something on the backdrop was as **plaintext ink**, fully
  legible to the room. A chip is strictly less exposure than the thing
  it replaces. Refusing to seal did not keep secrets off the surface,
  it kept them on the surface unsealed.
- **The ledger.** "Residue on an always-visible surface" was the worry,
  and it does not describe what the ledger is: a tab you visit, holding
  dead pages, showing nothing until asked. Nothing about it stands on
  the resting glance.
- **Concealing and the network.** The exit ramp was to stay in the panel
  until the backdrop earned it by an amendment here. This is that
  amendment. The backdrop reaches its own connection settings, and a
  token saved there is stored under the backdrop's own Keychain
  service: two form factors, two stores, unchanged.

What this amendment does **not** change is the stance model, the focus
law, or the capture exclusion. A resting surface still refuses the
keyboard outright, still passes clicks through to the desktop, and still
never appears in a screenshot or a screen share. The resting card shows
the same editor over the same page with editing refused, so raising it
reflows nothing.

The shoulder-surfing tradeoff is restated rather than resolved: ink on
this surface is as visible as a paper note taped to the monitor, and
that visibility is the form factor's whole proposition. What changed is
that the surface now offers a way to *stop* content being ink. Whether
the excerpt on a chip is itself too much standing exposure is still open
(question №3 below), and a count-only face remains the fallback if lived
use says so.

Structurally, this fires ADR-0010's eject trigger a second time. The
first firing moved the seam wrapper into `CompanionKit`; parity moves
the page model and every form-factor-neutral view there too, since the
same code touching sealed content must not exist in two targets. What
stays in each target is its window and its posture.

## v0 scope — and what is deliberately absent

**Superseded by the parity amendment above**, and kept because the
arguments are worth having on the record. v0 was **one page of visible
ink with the standard TTL ladder**, resting on the primary screen. It exercises the two things this exploration is
for: the window mechanics macOS makes hard, and a second consumer of
the C-ABI seam (proof the core is as shell-agnostic as ADR-0001
claims).

Absent, each on purpose:

- ~~**No sealed chips, no sealing gestures.**~~ **Superseded by the
  parity amendment: a chip is less exposure than the plaintext it
  replaces.** The original argument: a sealed chip's excerpt on
  an always-visible surface is a standing shoulder-surfing exposure the
  summoned panel never has. Whether any chip face belongs on a backdrop
  is an open question (№3), not a default. Consequence: the boundary
  law holds trivially in this target — no sealed byte exists on either
  side of its seam.
- ~~**No persistence, no Keychain.** The backdrop starts empty; quit is
  total amnesia (the core zeroizes on drop). It stores nothing, so it
  can never raise a prompt, and it cannot fight the panel app over the
  state file. Exploration targets start with less authority
  (ADR-0010).~~ **Superseded by the persistence amendment above.** The
  no-fighting half of the reasoning survives it: the backdrop still
  never touches the panel's state file or its Keychain service.
- ~~**No conceal, no network.**~~ **Superseded by the parity
  amendment, which is the amendment this bullet asked for.** The exit
  ramp was to stay in the panel until the backdrop earned it here.
- ~~**No ledger.**~~ **Superseded by the parity amendment: the ledger
  is a tab you visit, not residue standing on the glance.** The
  original argument: an expired page is silently replaced by a fresh
  empty one, zero means zeroized (docs/spec/03 §1), and residue on an
  always-visible surface is a different, unargued thing.

## Security posture

- **Capture exclusion is doubly load-bearing.** `sharingType = .none`,
  as everywhere (docs/spec/05) — but the panel is hidden between uses,
  while the backdrop is on screen for every screenshot and screen share.
  The `COMPANION_ALLOW_CAPTURE` opt-out mirrors the panel's: never
  persisted, always off at launch unless the variable is set, and
  absent from Settings in a release build that was launched without it.
  While it is on, the header flies a camera indicator.
- **Shoulder surfing is the form factor's own tradeoff.** Ink on the
  backdrop is exactly as visible as ink on a paper note taped to the
  monitor — that visibility is the *feature*, chosen by the user when
  they choose this form factor, and mitigated by what v0 refuses to
  display (no chip excerpts) rather than by pretending a background
  surface can be private. The empty state and the countdown leak
  nothing.
- **A resting surface that cannot hear.** `canBecomeKey` is false while
  resting — the surface cannot receive keystrokes it wasn't raised to
  receive, by construction rather than by discipline.
- **Frugality** (docs/spec/03 §4): expiry is scheduled, never polled —
  one timer at the core's next event, exactly the panel's contract. The
  always-on repaint is the form factor's one standing cost, held to a
  30 s cadence at rest.

## Hardware checklist (before the exploration graduates)

The stance table is unit-tested; the window plumbing is not mockable
and needs the project's hand-verification pass on real hardware:

1. Resting sits above the wallpaper, below desktop icons; icon
   clicks/drags pass through untouched.
2. Raised types without activating the app; the previously frontmost
   app keeps its menu bar; Esc rests and the keyboard returns to it.
3. Neither stance appears in a screenshot, screen share, or the
   screen-capture picker (and `COMPANION_ALLOW_CAPTURE=1` debug builds
   do).
4. Spaces: what `.stationary` actually does across desktop Spaces at
   rest; a resting surface stays out of full-screen Spaces while a
   summoned one appears over them and lands on the active Space; a
   raised card that lost the keyboard, unpinned with the keep-above
   preference off, is absent from another app's full-screen Space
   (ADR-0034); Stage Manager neither relays out nor hides it
   surprisingly.
5. ⌘Tab, both directions. Superseded by ADR-0033: ⌘Tab selects the
   editor window and rests the card, and the current checks are in
   [spaces-and-cmd-tab.md](../../../qa/verification-procedures/spaces-and-cmd-tab.md).
   As written: switching to the backdrop raises and keys it
   wherever the user is (including from a full-screen app); resting
   from a ⌘Tab summon returns activation to the previous app and its
   window regains the keyboard (`NSApp.deactivate()` is doing that
   work — verify it actually lands).
6. Both form factors running at once: hotkeys don't collide, status
   items coexist, and the panel's behaviour is byte-for-byte what it
   was alone.
7. VoiceOver: the raised editor is operable; the resting surface is
   honestly absent from the accessibility hierarchy or honestly present
   — not a phantom.

Added by the parity amendment:

8. Chips: the sealing gestures work from a raised card (⇧⌘V takes the
   clipboard and clears it, ⌘↩ seals the selection or line, an external
   drop seals), and the resting glance draws the resulting sealed
   blocks (D-27 in docs/spec/design/2026-0915-ui-ux-decisions.md; the
   block is owed until the full-measure attachment lands) with no
   affordance to reveal anything.
9. Conceal: a link created from the backdrop reaches the server and
   lands on the clipboard, and a token saved in the backdrop's Settings
   goes under `com.onetimesecret.pad` in the Keychain.
   The panel's own token is untouched and neither app prompts for the
   other's item.
10. Tabs: ⌘1 through ⌘9, ⌘N, ⌥⌘←/→,
    ⌘W, drag to reorder, double-click to hold the clock, and the ledger
    tab, all from a raised card and none of them reachable from a
    resting one.
11. Sizing: the card resizes from each of the eight grips, zooms on a
    header double-click and returns on the next, and its place and
    measure survive quitting and relaunching **the installed copy**
    (the defaults-suite defect made this work under `swift run` and
    nowhere else, so the dev build is not evidence).

## Open questions

1. **Is glanceable-but-capture-excluded coherent?** The surface hides
   from screen sharing but not from the room. Users who present from
   their desktop may find the disappearing card *more* confusing than a
   visible one. Needs lived experience, not argument.
2. **Per-display backdrops.** v0 is primary-screen only. One surface
   per display is mechanical to add and probably right.
3. **Chip faces on the backdrop.** Chips appear now (the parity
   amendment), rendered as the sealed block of D-27 in
   docs/spec/design/2026-0915-ui-ux-decisions.md (owed: `SealedBlockCell`'s
   excerpt pill is the shipping treatment until the block lands).
   What stays open is whether even that mechanical excerpt is too much
   standing exposure on a surface nobody dismisses. A count-only face
   ("3 sealed items, 2h") remains the fallback if lived use says so.
4. ~~**Shared pages across form factors.**~~ **Settled by the
   persistence amendment: its own.** The backdrop seals to its own file
   under its own Keychain service, and two apps remain two stores. What
   stays open is the harder question underneath, which the amendment
   did not touch: whether the *same* page should ever appear in both
   form factors at once. That needs a single owning process or a shared
   store with locking, and it is core-level work, never shell work.
5. **Idle redaction.** Should resting ink dim to illegibility (or to
   first-line-only) after N minutes untouched, as a shoulder-surfing
   backstop? It trades away the entire point of ambience; perhaps a
   setting, perhaps nothing.
6. **The name.** "Backdrop" is a working name held to the same rule as
   the rest (docs/spec/design README): UI string and display name only,
   never an identifier beyond the reserved bundle id.
7. **Is the Dock icon too much presence?** The ⌘Tab amendment trades
   the panel's furniture-like invisibility for switcher membership,
   because alternation is the observed core loop. If the Dock icon
   makes the surface feel like an app to manage rather than a place
   that exists, the amendment reverses (accessory + hotkey only) or
   becomes a setting.
