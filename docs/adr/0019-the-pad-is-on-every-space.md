---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0019: The pad is on every Space, and does not travel between them

- **Status:** accepted
- **Date:** 2026-08-24
- **Superseded in part by:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), specifically the reach of the all Spaces rule over the whole application. The rule stands for the ambient panel.

## Context

Issue #74 filed three Space symptoms together: ⌘Tab back always landed
on Desktop 1 rather than the desktop the pad was last used on, the
window could not be dragged to another desktop by the screen edge, and
every ⌘Tab return flickered.

The first and third came from the same place. The resting surface
carried no all-Spaces membership, so its window belonged to the desktop
it was created on, and the window server switches Spaces to reveal an
app's windows when the app is activated. Activating the pad from another
desktop therefore carried the user back to Desktop 1, and the raise that
follows the activation then rewrote the membership bits and, when the
window really was stranded elsewhere, ordered the card out and back in
to land it here. Both of those are recompositions, and a blink is what a
recomposition looks like.

The second is not a defect of the same kind. The card's position is the
app's own state: it is proposed by a drag gesture inside the card,
clamped to the primary screen's visible frame, and persisted
(`BackdropGeometry`). The window server never sees a window drag at all,
because `isMovableByWindowBackground` is false and the frame is set
programmatically, so the edge-of-screen gesture that moves an ordinary
window to the next desktop has nothing to act on. Nor is there a desktop
for it to move to that the pad is not already on.

## Decision

The pad's Space membership is `.canJoinAllSpaces`, in every posture and
either pin state, and it never changes. What varies by posture is only
what the window does once it is on a Space: `.stationary` and
`.ignoresCycle` while resting, neither while raised, and full-screen
participation, which the unpinned rest declines and both the pin and the
raise accept.

`BackdropStance.spaceMembership(pinned:)` names the membership bits
apart from the rest, so the constancy is one unit-tested invariant
rather than four literals that have to agree. The constancy is of that
subset, not of the whole `collectionBehavior` value: the controller
still writes the composite when a stance changes, because the rest of it
genuinely differs by posture. What no longer changes is the part a Space
reassignment would turn on.

The pad does not travel between desktops, and the screen-edge drag is
not implemented. This is a consequence of the decision above rather than
a gap in it: a surface present on every Space has no other desktop to be
moved to. Moving the card is moving it *within* a Space, which the drag
already does.

## Consequences

Activating the pad never changes the user's desktop, because there is
nothing of the app to reveal elsewhere. The app's two ordinary windows,
Settings and the standard About panel, take `.moveToActiveSpace` for the
same reason from the other side: each is built once and shown many
times, so either would otherwise anchor the app to the desktop it was
first opened on and undo the fix from outside the surface. Settings
takes the bit when it is created; About is AppKit's own window, so it
takes the bit each time it is put up. That last is why the app menu's
About item is repointed at the delegate rather than left to SwiftUI: the
synthesized item calls `orderFrontStandardAboutPanel:` directly, and a
panel built by that route never gets the bit at all. A guarantee that
holds only for the tray's route is not one.

The summon's order-out round trip becomes unreachable from any desktop
Space, which is where the flicker was seen: a window on every desktop is
on the one the user is looking at. It is not unreachable outright. The
unpinned rest declines full-screen Spaces, so while another app is full
screen the card is visible on the desktops and absent from the Space in
front of the user, and a summon from there is the stranded case the net
is for; a raise taken mid-transition can read the same way for a moment.
The net is kept and expressed as
`BackdropStance.requiresSpaceRoundTrip(visible: onActiveSpace:)`,
because being wrong about a window stranded off-Space costs the user's
keystrokes. Where it does fire, the blink is the card arriving where the
user is.

One hazard goes away without being aimed at: a window belonging to a
single Space dies with it when that desktop is closed or two displays
are merged, and a window on all of them has no such Space to lose.

The resting card is now visible on every desktop rather than on the one
it launched under. For an ambient surface this is the intended reading:
the wallpaper is on every desktop too. It also means the pad cannot be
used to keep different pages on different desktops, which was never
offered but might have been discovered.

A user who expects the card to follow the ordinary window conventions,
edge-drag to the next desktop, a separate copy per desktop, will find it
does not. The pad is furniture, not a document window.

## Eject triggers

- Per-desktop surfaces are asked for, whether as different cards or as
  the same card in different places per desktop. That is a different
  design and this decision is what stands in its way.
- The all-Spaces membership is observed to cost something measurable
  during Mission Control or Space transitions.
- A macOS release makes `.canJoinAllSpaces` windows behave differently
  over other applications' full-screen Spaces, which is the neighbouring
  question issue #73 turns on.

## See also

`docs/qa/verification-procedures/spaces-and-cmd-tab.md`, the procedure
that confirms or falsifies the three symptoms on hardware. ADR-0015, for
the mouse transparency rule the pin bends. ADR-0014, for why this form
factor is the only one left to have Spaces at all.

## Decision history

- 2026-09-18: Superseded in part by
  [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md).
  "The pad" in this record now means the ambient panel, and the decision stands
  for it unchanged. The primary editor window ADR-0033 adds has ordinary Space
  membership, so the consequence that activating the app never changes the
  user's desktop holds only while that window is closed. Settings and About
  keep `.moveToActiveSpace`.
