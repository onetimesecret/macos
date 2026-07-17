# docs/spec/feature/background-surface/README.md
---

# Feature: the background surface (working name: Backdrop)

- **Status:** exploration — implemented as the `CompanionBackdrop`
  target (ADR-0010); v0 scope below
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

## The stance model

The research's central finding is that "typed into" and "behind
everything" are contradictory window states on macOS — even Plash, the
reference wallpaper app, promotes itself to a floating level to accept
a click. The backdrop therefore does not blur the two; it is always in
exactly one of two stances:

| | **Resting** | **Raised** |
| --- | --- | --- |
| Level | one above the window-server desktop level (clear of the wallpaper's *own window*, below icons) | `.floating` |
| Mouse | ignored — clicks fall through to the desktop | interactive |
| Keyboard | refused outright (`canBecomeKey` = false) | may become key, never main |
| Spaces | stationary desktop furniture; never in a full-screen Space | joins the user's active Space, full-screen included |
| Countdown repaint | every 30 s | 1 Hz |
| Reading | dimmed ink, one comfortable measure (max 640 pt) | the same ink, same measure, editable |

The summon gestures are ⌃⌥Space (two modifiers, deliberately: ⌥Space
belongs to the panel app, and option-only global shortcuts broke
outright on macOS 15.0–15.1), the menu-bar item, and — per the ⌘Tab
amendment below — ⌘Tab and the Dock icon. A summon is a summon first
and a dismissal last: a resting surface raises; a raised surface that
lost the keyboard (the user clicked or ⌘Tabbed away to work beside the
card) gets the keys back and is pulled to the active Space; only a
surface *already holding the keyboard* reads the gesture as "put it
away". Esc and a click outside the card always rest it.

Raising is the deliberate act that entitles the window to the keyboard
— the panel's focus law, unchanged. The window is a
`.nonactivatingPanel` (set at init; the style-mask bit is inert if
toggled later), so the hotkey summon never activates the app or
deactivates the user's frontmost one; ⌘Tab is the one route where the
user chose activation itself, and there the raise is activation's
consequence, not its cause.

A resting surface is exactly as visible as the desktop is: behind every
window, it shows only when the desktop shows (a bare corner of screen,
Show Desktop, Mission Control). That is the form factor, not a defect —
"is ambient actually ambient on a full screen of windows?" is one of
the questions the exploration exists to answer with lived experience.

Mechanics follow Plash's recovered recipe where the postures agree:
`.borderless`, transparent, shadowless; at rest,
`collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]` —
a full-screen Space is another app's room, and a *resting* backdrop
does not follow the user there. A summon does follow: the raised
stance swaps to `[.moveToActiveSpace, .fullScreenAuxiliary]` (the
panel's summon recipe), holding the invariant the stances exist to
protect — **a surface that holds the keyboard is visible where the
user is looking**. The failure mode this forecloses is real: a hotkey
pressed from a full-screen app or another desktop would otherwise key
an off-screen window and silently swallow whatever was typed.

## The ⌘Tab amendment

The backdrop is a **regular app** — Dock icon, ⌘Tab membership — where
the panel is an accessory. First hands-on use found the core loop is
*alternation*: copy in the work window, switch, paste in the surface,
switch back. Mid-loop, muscle memory reaches for ⌘Tab, not a bespoke
chord, and an app absent from the switcher loses half of every
exchange. So activation is a summon route: ⌘Tab or a Dock-icon click
raises the surface, pulled to the user's Space and keyed;
resting from a ⌘Tab summon hands the *activation* back
(`NSApp.deactivate()`), not just key status, so the keyboard returns
to the app the user came from. The launch's own activation is exempt —
the backdrop starts resting, present but not summoned.

This knowingly amends "present, not centre stage": docs/spec/03 §2
settles "Dock icon?" with *No* — for the panel, whose whole posture is
invisibility between uses. The backdrop's posture is presence, and
presence that cannot be switched to is friction. Whether the fee is
too high is open question №7.

## v0 scope — and what is deliberately absent

v0 is **one page of visible ink with the standard TTL ladder**, resting
on the primary screen. It exercises the two things this exploration is
for: the window mechanics macOS makes hard, and a second consumer of
the C-ABI seam (proof the core is as shell-agnostic as ADR-0001
claims).

Absent, each on purpose:

- **No sealed chips, no sealing gestures.** A sealed chip's excerpt on
  an always-visible surface is a standing shoulder-surfing exposure the
  summoned panel never has. Whether any chip face belongs on a backdrop
  is an open question (№3), not a default. Consequence: the boundary
  law holds trivially in this target — no sealed byte exists on either
  side of its seam.
- **No persistence, no Keychain.** The backdrop starts empty; quit is
  total amnesia (the core zeroizes on drop). It stores nothing, so it
  can never raise a prompt, and it cannot fight the panel app over the
  state file. Exploration targets start with less authority (ADR-0010).
- **No promotion, no network.** The exit ramp stays in the panel until
  the backdrop earns it by an amendment here.
- **No ledger.** An expired page is silently replaced by a fresh empty
  one — zero means zeroized (docs/spec/03 §1), and residue on an
  always-visible surface is a different, unargued thing.

## Security posture

- **Capture exclusion is doubly load-bearing.** `sharingType = .none`,
  as everywhere (docs/spec/05) — but the panel is hidden between uses,
  while the backdrop is on screen for every screenshot and screen share.
  The debug-only `COMPANION_ALLOW_CAPTURE` opt-out mirrors the panel's:
  never persisted, compiled out of release.
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
   summoned one appears over them and lands on the active Space; Stage
   Manager neither relays out nor hides it surprisingly.
5. ⌘Tab, both directions: switching to the backdrop raises and keys it
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

## Open questions

1. **Is glanceable-but-capture-excluded coherent?** The surface hides
   from screen sharing but not from the room. Users who present from
   their desktop may find the disappearing card *more* confusing than a
   visible one. Needs lived experience, not argument.
2. **Per-display backdrops.** v0 is primary-screen only. One surface
   per display is mechanical to add and probably right.
3. **Chip faces on the backdrop.** If chips ever appear, is even the
   mechanical excerpt too much standing exposure? A count-only face
   ("3 sealed items, 2h") may be the ceiling.
4. **Shared pages across form factors.** Two apps are two stores
   (ADR-0010). If the backdrop earns persistence, does it share the
   panel's sealed state or keep its own? Core-level question.
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
