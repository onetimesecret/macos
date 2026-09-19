---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0034: Full screen participation follows altitude

- **Status:** accepted
- **Date:** 2026-09-18
- **Supersedes in part:** [ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md), whose clause "Do not change the surface's Space membership or full-screen participation." is replaced for full screen participation only. The Space membership half of that clause stands. Also [ADR-0019](0019-the-pad-is-on-every-space.md), whose Decision describes full-screen participation as something "the unpinned rest declines and both the pin and the raise accept": the raise now accepts it only while it floats. ADR-0019's membership constancy stands.
- **Depends on:** [ADR-0019](0019-the-pad-is-on-every-space.md) for constant Space membership, and [ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md) for the altitude model this decision reads from.

Read [ADR conventions](README.md) before filing or changing an ADR.

The hardware observation behind this record is in
[potentially quirky behaviour](../dogfood/potentially-quirky-behaviour.md),
and the spike that produced it is issue 184. The product source is the
[background-surface specification](../spec/feature/background-surface/README.md#the-stance-model).

## Context

ADR-0032 made altitude a window fact of its own. A raised card that loses the
keyboard, unpinned and with the keep above preference off, drops from
`.floating` to `.normal`, so the app the person switched to can cover it.
Issue 184 checked that on hardware. On one desktop it holds: the newly active
app's windows stack in front of the card.

One route failed. ⌘Tab into an app that occupies its own full screen Space
brought the screen to that Space, as expected, with the OnetimePad card drawn
above the full screen app. ADR-0032's first eject trigger names this outcome:
lowering the keyless panel to `.normal` did not place the newly active
application's windows in front.

The cause is in the collection behavior and not in the level. ADR-0032 said:

> Do not change the surface's Space membership or full-screen participation.

So every raised surface kept `.fullScreenAuxiliary`, whatever its altitude.

What Apple documents, and what is inferred, are kept apart here because the
decision rests on both.

Documented:

- `NSWindow.h` says of `.fullScreenAuxiliary`: "Windows with this collection
  behavior can be shown with the fullscreen window." The reference page says
  "The window displays on the same space as the full screen window."
- The same header allows at most one of `.fullScreenPrimary`,
  `.fullScreenAuxiliary` and `.fullScreenNone` on a window.
- `order(_:relativeTo:)` takes a window number and places the receiver in
  front of or behind that window, or all other windows in its level when the
  number is 0.

Not documented, and therefore inferred or observed:

- Nothing documents the stacking order inside a full screen Space. The
  observation is that an auxiliary window at `.normal` is drawn above the full
  screen window. That is consistent with the purpose of the bit, since an
  auxiliary window placed behind the full screen window could never be seen.
- The header describes `.fullScreenNone` only as a window that "can not be
  made fullscreen". That such a window stays out of another app's full screen
  Space is observed behavior. The unpinned rest has carried that bit since
  ADR-0019 and is absent from those Spaces, and it is the recipe Plash uses.
- The documentation of `order(_:relativeTo:)` says nothing about a window
  number that belongs to another process. AppKit gives an app the numbers of
  its own windows; ordering against another app's full screen window would
  depend on behavior nothing describes.

Two ordering fixes were considered and rejected. `orderBack` sends the card
behind every window in its level, which on a desktop puts it behind the windows
of every app and not only the one just activated. That breaks the same-desktop
behavior ADR-0032 established, where the card stays where it was in the normal
level and only the active app's windows come forward. `order(.below,
relativeTo:)` against the full screen window relies on the undocumented case
above, needs the other app's window number from the window list on every key
transition, and would still leave an auxiliary window in a Space where it has
no business once it has yielded.

## Decision

Full screen participation follows altitude, not stance. A surface carries
`.fullScreenAuxiliary` exactly when its altitude is floating, and
`.fullScreenNone` otherwise. That is what an ordinary window at the normal
level does.

| Altitude | Reached by | Full screen bit |
| --- | --- | --- |
| desktop | Resting and unpinned | `.fullScreenNone` |
| normal | Raised, keyless, unpinned, keep above preference off | `.fullScreenNone` |
| floating | Raised and keyed or about to be; keep above preference on; Pin in either stance | `.fullScreenAuxiliary` |

`.canJoinAllSpaces` stays on every surface in every state. ADR-0019's
membership decision is untouched. ADR-0019 also describes full screen
participation as something "the unpinned rest declines and both the pin and
the raise accept". That one clause is replaced: a raise accepts full screen
participation only while it floats. The helper ADR-0019 names as
`BackdropStance.spaceMembership(pinned:)` is now
`BackdropStance.spaceMembership(altitude:)`, with the same invariant.

The controller resolves the altitude once per change, writes the level first
and the collection behavior second, and writes each only when the value
differs from the window's current one. The key delegate paths write the level
and the full screen bit. They never write the frame, the membership bits or
the window ordering. A raise still resolves with keyed true before the off
Space round trip check and before `makeKeyAndOrderFront`.

## Consequences

- ⌘Tab into an app in its own full screen Space leaves the card out of that
  Space when it is unpinned with the preference off. The card is still raised,
  on the desktops, at normal level, and ⌘Tab back keys it again.
- A pinned card, a keep above card and a card holding the keyboard still
  follow the person into full screen Spaces. A hotkey summon inside a full
  screen app works as before, because the raise floats before it is ordered
  front.
- There is one `collectionBehavior` write per key transition when the card is
  unpinned with the preference off, and none when it is pinned or keeping
  above, because the value does not change there. Before this decision a key
  transition wrote only the level.
- The write touches no membership bit. Issue 74's flicker and its return to
  Desktop 1 came from membership: the window was bound to one Space and the
  membership bits were rewritten on every raise. Commit b2b5aa4 and ADR-0019
  fixed that by making membership constant and guarding the write.
  `BackdropStance.spaceMembership(altitude:)` is tested to be
  `.canJoinAllSpaces` alone across all six stance by altitude cells, so the new
  write cannot ask for a move between desktops.
- A `makeKeyAndOrderFront` that is refused inside a full screen Space shows one
  appear and disappear. The raise floats and joins the Space, the reconcile a
  turn later finds the panel is not key, and the card drops to normal and
  leaves the Space again.
- Inside a full screen Space, the app's own open or save panel takes the
  keyboard from the card. The card then resolves to normal with
  `.fullScreenNone` and leaves that Space while its own panel is up, and floats
  again when the panel returns the keys. This is inferred from the code and has
  not yet been seen on hardware. The resolver gets no special case for it:
  ADR-0032 already says a keyless card is normal, and an exception for modal
  panels is one more policy to carry. The hardware procedure has a check that
  records where the panel opens, whether the card leaves, and that it returns
  keyed and floating.
- A summon from a full screen Space while the card is raised at normal finds
  the card visible on the desktops and absent from the Space in front of the
  person. That is the stranded case the round trip net exists for, as it
  already was for the unpinned rest.
- The stance no longer states collection behavior from the pin. It reads the
  resolved altitude, so level and behavior cannot describe different answers.
- The evidence standard is a probe and not the eye:
  `scripts/window-order-probe.swift` lists the window server's front to back
  order and prints one verdict line per sample.

## Eject triggers

- Hardware shows a flicker, or a move between Spaces, caused by the
  participation write on a key transition. Reopen the mechanism; do not remove
  the write guard or touch the membership bits.
- The probe shows the card still listed ahead of the full screen window after
  ⌘Tab into that app's Space, unpinned with the preference off. The
  participation bit is then not what decides it, and ordering has to be
  reopened.

## Decision history

- 2026-09-18: Accepted. Replaces the full screen participation half of one
  clause of ADR-0032 after that ADR's first eject trigger fired for the full
  screen route in issue 184, and the matching descriptive clause of ADR-0019.
