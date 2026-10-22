---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0032: Inactive raised surfaces follow normal app stacking

- **Status:** accepted
- **Date:** 2026-09-17
- **Superseded in part by:**
  - [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), specifically the return switch consequence and the reach of the companion window rule over the primary editor window. The three fact model, the altitude table and the preference stand for the ambient panel.
  - [ADR-0034](0034-full-screen-participation-follows-altitude.md), which replaces the full-screen participation half of one clause only.
- **Depends on:** [ADR-0015](0015-resting-backdrop-is-mouse-transparent.md) for the resting surface's click behavior, and [ADR-0019](0019-the-pad-is-on-every-space.md) for constant Space membership.

Read [ADR conventions](README.md) before filing or changing an ADR.

The related product source is the accepted
[background-surface specification](../spec/feature/background-surface/README.md#the-stance-model).
The dogfood investigation that exposed the conflation is
[potentially quirky behaviour](../dogfood/potentially-quirky-behaviour.md).

## Context

The background surface has two stances. Before this decision, the
feature specification made it always either resting or raised and assigned the
raised stance the `.floating` window level. It also says:

> A summon is a summon first and a dismissal last: a resting surface raises; a
> raised surface that lost the keyboard (the user clicked or ⌘Tabbed away to
> work beside the card) gets the keys back and is pulled to the active Space;
> only a surface *already holding the keyboard* reads the gesture as "put it
> away". Esc and a click outside the card always rest it.

The implementation followed those statements literally. `BackdropStance`
made every raised surface floating, whether or not it still held the keyboard,
and `windowDidResignKey` cleared keyboard ownership without changing stance or
level. Consequently, ⌘Tab to another application transferred focus but left
OnetimePad above that application's normal windows. The result looked like Pin
even when Pin was off.

The stance still carries information that must survive an application switch.
A raised surface that loses the keyboard remains the editing surface the person
left, so switching back can re-key it without treating the round trip as a new
summon, changing the visible page, or moving the roll to today. Resting it on
every key loss would also collapse distinct routes: ⌘Tab, a Settings or About
window, an open or save panel, and a hotkey-raised nonactivating panel can all
move key status for different reasons.

The surface is intentionally not a conventional main window. The authoritative
feature specification says:

> The window is a `.nonactivatingPanel` (set at init; the style-mask bit is
> inert if toggled later), so the hotkey summon never activates the app or
> deactivates the user's frontmost one; ⌘Tab is the one route where the user
> chose activation itself, and there the raise is activation's consequence,
> not its cause.

Changing `NSPanel` to a conventional `NSWindow` would reopen that accepted
focus behavior, and would not itself remove the explicit `.floating` level.
Setting `hidesOnDeactivate` would hide the surface rather than give it ordinary
inactive-window stacking. Neither addresses the actual conflation: raised has
been used to mean both "the current editing posture" and "always above other
applications".

## Decision

Treat stance, keyboard ownership, and altitude as independent window facts:

- **Stance** is resting or raised and continues to govern interactivity,
  framing, redraw cadence, and the summon decision.
- **Keyboard ownership** records whether the surface is keyed. A surface about
  to be keyed is treated as keyed for ordering, so a summon does not flash at a
  lower level before coming forward.
- **Altitude** is desktop, normal, or floating and is derived from stance,
  keyboard ownership, Pin, and the app-switching preference.

Use this altitude table:

| State | Window level |
| --- | --- |
| Resting and unpinned | desktop/backdrop |
| Raised and keyed, or about to take keys | floating |
| Raised, keyless, unpinned, default preference | normal |
| Raised, keyless, unpinned, keep-above preference enabled | floating |
| Pinned, in either stance | floating |

Add one persisted surface preference labelled **Keep OnetimePad above other
apps when switching away**. Its default is off. Off gives an unpinned raised
surface normal inactive-window stacking after it loses the keyboard: it remains
open and raised, but the active application's windows may cover it. On preserves
the previous behavior, keeping the keyless raised surface floating. Pin is the
stronger, explicit instruction and keeps the surface floating regardless of the
preference.

Key-window state, not `NSApp.isActive`, decides whether a raised surface is
currently engaged. A global-hotkey summon deliberately keys the nonactivating
panel while another application remains active; using application activity
would lower the surface during the very interaction that summoned it.

Keep `hidesOnDeactivate = false`. Normal switching changes stacking, not
visibility or stance. A portion of an inactive normal-level surface may remain
visible wherever the active application's windows do not cover it.

Keep the outside-click rule unchanged. A click outside the card still rests the
surface under the background-surface specification and ADR-0015. A keyboard
application switch leaves it raised but normally stacked. The difference is
intentional: the click is the existing dismissal gesture; ⌘Tab is navigation
between applications.

When Settings or another ordinary window of OnetimePad takes the keyboard, its
level must be compatible with the surface's resulting inactive altitude. Under
the default preference an ordinary window can remain normal because the
surface lowers to normal. When Pin or the keep-above preference leaves the
surface floating, the ordinary window may also need floating altitude to avoid
opening keyed but underneath the surface. All routes to the same ordinary
window use the same rule.

Do not change the surface's Space membership or full-screen participation.
ADR-0019's `.canJoinAllSpaces` invariant stands, as do the stance-specific
collection behaviors and the off-Space summon safety net.

## Consequences

- With the default preference, ⌘Tab away behaves like switching away from a
  normal application window: the newly active application's windows stack in
  front, while OnetimePad retains the raised page and editing context for the
  return switch.
- People who use the raised card as a visible companion can retain the previous
  always-above behavior without using Pin. Pin remains the unambiguous override
  for keeping the card floating in either stance.
- Raised no longer determines window level by itself. The controller must
  reapply altitude when key ownership, stance, Pin, or the preference changes,
  and tests must cover their matrix rather than only the two stances.
- The raise path must apply engaged altitude before ordering the panel front;
  the key and resign-key delegate paths then keep altitude synchronized with
  actual ownership.
- The preference belongs to the form factor's local window state, alongside
  Pin and geometry. It does not enter the shared page model, core, state file,
  or sync protocol.
- Clicking outside and switching away by keyboard remain visibly different.
  The former rests the card at backdrop level; the latter preserves the raised
  stance at normal level by default.
- A normal-level inactive panel is not guaranteed to be wholly hidden. Empty
  desktop regions may still show it, which is ordinary stacking rather than a
  promise to conceal the surface.
- The custom `NSPanel`, nonactivating hotkey path, all-Spaces membership,
  full-screen behavior, and key relay remain in place. This decision avoids a
  broader window-form conversion that the reported stacking problem does not
  require.

## Eject triggers

- Hardware verification on a supported macOS release shows that lowering the
  keyless panel to `.normal` does not reliably place the newly active
  application's normal windows in front, including under Stage Manager. Reopen
  the ordering mechanism before changing stance or hiding semantics.
- AppKit fails to deliver key or resign-key transitions reliably enough that
  the surface remains normal while accepting input or floating after losing
  input. Reconsider the ownership signal, preserving the three-fact model.
- Repeated dogfood observation finds that people understand ⌘Tab away as a
  dismissal and expect the surface to rest rather than remain raised. Revisit
  the default transition explicitly; do not infer dismissal from every key
  transfer, because Settings and modal panels share that signal.
- A supported requirement needs conventional main-window behavior such as
  title-bar movement, standard window cycling, per-Space placement, or ordinary
  activation for every summon. That requirement warrants a separate ADR and a
  window-form spike because it reopens the nonactivating-panel and all-Spaces
  decisions.

## Decision history

- 2026-09-17: Accepted. Normal inactive stacking is the default; the previous
  always-above behavior remains an opt-in preference, and Pin overrides both.
- 2026-09-18: The fourth eject trigger fired and
  [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md) is its
  answer. Superseded in part: the return ⌘Tab now selects the primary editor
  window and rests a raised panel, so the first consequence's retained raised
  stance no longer applies to that route, and the companion window rule governs
  Settings and About but not the editor window, which stays at normal level.
  Everything else stands for the ambient panel, which now reaches raised and
  keyless only from a hotkey or status item summon.
- 2026-09-18: Superseded in part by
  [ADR-0034](0034-full-screen-participation-follows-altitude.md). Eject trigger
  1 fired for the full screen route in issue 184: after ⌘Tab into an app in its
  own full screen Space, the card at `.normal` was still drawn above that app.
  ADR-0034 replaces the clause "Do not change the surface's Space membership or
  full-screen participation." for full-screen participation only, which now
  follows altitude. The Space membership half of the clause, the altitude
  table, the preference and every other part of this decision stand.
- 2026-10-21: Amendment 1 replaces the companion window paragraph ("When
  Settings or another ordinary window of OnetimePad takes the keyboard, its
  level must be compatible with the surface's resulting inactive altitude...")
  for [issue #293](https://github.com/onetimesecret/macos/issues/293). The
  ordinary windows stay at normal level and the surface lowers under them.
  The altitude table gains one input; everything else stands.

## Amendment 1: ordinary windows stay at normal level, the surface lowers under them

- **Status:** proposed
- **Date:** 2026-10-21

Appended, not folded in. The base Decision text above is left as written.
This amendment replaces one paragraph of it, the companion window rule, for
[issue #293](https://github.com/onetimesecret/macos/issues/293).

### What was observed

With the pin on, or the keep above preference on, Settings, About and Send
Feedback opened at floating level and stayed there while open, so they sat
over every other application's windows and did not go behind when
OnetimePad deactivated. The base rule asked for exactly that: an ordinary
window "may also need floating altitude to avoid opening keyed but
underneath the surface". The HIG audit left in PR #279 named it as a
defect. On macOS an application's Settings, About and feedback windows are
ordinary windows at normal level; floating belongs to palettes and
inspectors, which also hide on deactivate.

### What this replaces

The paragraph beginning "When Settings or another ordinary window of
OnetimePad takes the keyboard" is replaced by the following rule.

Settings, About and Send Feedback are ordinary windows at normal level and
never change level. The keyboard being in a companion window of
OnetimePad's own is a further input to the surface's altitude, beside stance,
keyboard ownership, Pin and the preference. While one of those windows is
key, or a sheet run on one of them is, a surface that the table would float
lowers to normal; a resting unpinned surface stays at desktop level, since
it is below the ordinary window already. The surface returns to the table's
level when that window closes, resigns the keyboard, or the surface takes
the keyboard back. A hand off from one of those windows to another, or to
a sheet run on one, keeps the surface lowered. The surface's own keyboard
ownership wins over the companion's: a raise committed as "about to take
keys" floats, and the companion's resign follows. All routes to the same
ordinary window use the same rule.

The altitude table reads, with the new row first because it governs the
rows below it:

| State | Window level |
| --- | --- |
| A companion window is key and the surface would float | normal |
| Resting and unpinned | desktop/backdrop |
| Raised and keyed, or about to take keys | floating |
| Raised, keyless, unpinned, default preference | normal |
| Raised, keyless, unpinned, keep-above preference enabled | floating |
| Pinned, in either stance | floating |

### Consequences of the amendment

- A pinned or kept above surface is covered by Settings, About or Send
  Feedback while the person works in one of them, and floats again the
  moment that window closes. Pin is still the stronger instruction over the
  preference; it yields only to the app's own ordinary windows.
- Those windows go behind other applications on ⌘Tab like any ordinary
  window, and the surface, keyless after the switch, sits where the table
  puts it.
- Full screen participation still follows altitude (ADR-0034), so a surface
  lowered under a companion window leaves other apps' full screen Spaces for
  as long as it is lowered.
- The one follower that wrote levels onto companion windows is retired. The
  decision lives in the altitude resolver and the keeper that writes the
  surface's level, which is where the rest of the table already lived.
- ADR-0033's narrowing of the companion window rule, that it does not
  govern the primary editor window, stands: the editor window is not a
  companion window and does not lower the surface.
