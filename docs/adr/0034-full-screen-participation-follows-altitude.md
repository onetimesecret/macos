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
- 2026-09-18, later the same day: Amendment 1 records the second eject
  trigger firing on hardware. The base Decision governs the same-desktop
  route; ordering reopens for the full screen route.
- 2026-09-28: Amendment 2 records the full screen route passing on
  hardware in the maintainer's run. Ordering does not reopen, and issue 184
  closes.

## Amendment 1: second eject trigger fired, ordering reopens

- **Status:** accepted
- **Date:** 2026-09-18

Appended, not folded in. The base Decision text above is left as written.
This amendment records that the second eject trigger under **Eject
triggers** fired on hardware later the same day and names what stands and
what reopens.

### What the probe saw

The evidence standard is `dist/window-order-probe`, built from
`scripts/window-order-probe.swift` by `scripts/dev.sh --with-probe`. Run
in `--watch --expect behind` on a desktop Space, with the card unpinned
and the keep above preference off, ⌘Tab into an application in its own
full screen Space produced:

```
VERDICT FAIL expect=behind card=2 target=4 pad=3125 front=Zed
```

The card sits at window list index 2, the full screen target at index 4.
The card is drawn ahead of the target. The `layer=0` on the card sample
rules out the raised floating level and the keep above raised level: the
resolver had lowered the card to normal, exactly as the base Decision
prescribes, and the participation write is not what decides the order.

A screen recording of the same route agrees with the probe: OnetimePad
remains onscreen as a floating overlay above Zed's full screen interface
after ⌘Tab into that Space, then goes back into place when the user
returns.

### What stands

The base Decision governs the same-desktop route. Two PASS verdicts in
the same probe run, one before Zed entered full screen and one against
Proton Pass, show the altitude to full screen bit table holding where
both applications share a desktop. Altitude is still the axis the level
and the participation bit read from. `.canJoinAllSpaces` still stays on
every surface in every state. ADR-0019's membership decision is still
untouched. The Settings and About delegate paths still write only the
level and the participation bit.

### What reopens

The full screen route. The base Decision's inferred piece was that a
`.fullScreenNone` window at normal level would stay out of another app's
full screen Space in the same way the unpinned rest does. On hardware
that inference does not hold for a raised card that is lowered to normal
on ⌘Tab into the full screen Space of the newly active app. Either the
transition is happening before the participation write lands, or the
`.fullScreenNone` bit does not by itself remove a window that is already
listed as a participant in the Space it is being sent into. The rejected
alternatives in the base Context (`orderBack`, `order(.below, relativeTo:)`
against the full screen window) come back on the table with this new
data, and so do options the base Context did not weigh: hiding and
reshowing across the transition, and asking the Space machinery for the
membership by an explicit method rather than by the collection behavior
alone.

### Consequences of the amendment

- ⌘Tab into an app in its own full screen Space, with the card unpinned
  and the preference off, leaves the card drawn above the full screen
  app. Until the ordering reopens, this is the observed behavior.
- The base Decision's other consequences continue to hold on the
  same-desktop route.
- Issue 184 does not close on the full screen route. A new spike, or a
  new ADR when a mechanism is chosen, sits between this record and that
  close.
- The hardware procedure at
  `docs/qa/verification-procedures/spaces-and-cmd-tab.md` is unchanged
  as a probe recipe. Its verdicts are what the reopened ordering must
  satisfy.

## Amendment 2: the full screen route passes on hardware

- **Status:** accepted
- **Date:** 2026-09-28

Appended, not folded in. The base Decision and Amendment 1 are left as
written.

### What the run saw

The maintainer ran the full screen route again on hardware on 2026-09-28,
with the card unpinned and the keep above preference off, as part of a run
of every window roles check: issues 184, 190 and 210, and the ADR-0033
checks in `docs/qa/verification-procedures/spaces-and-cmd-tab.md`. Every
route passed, including ⌘Tab into an application in its own full screen
Space. The procedure's Results table records the run. This record carries
the maintainer's report; the probe's verdict lines are not reproduced here.

### What this changes

- Amendment 1's first consequence, that ⌘Tab into an app in its own full
  screen Space "leaves the card drawn above the full screen app", is not
  what this run saw.
- Ordering does not reopen. The base Decision governs the full screen route
  as well as the same desktop route, and no new spike or ADR sits between
  this record and the close of issue 184.
- The alternatives the base Context rejected stay rejected.

### What this does not explain

No change to the collection behavior, the full screen participation bits or
the level writes landed between Amendment 1 (f8f8bdc) and main at 2d73af4.
What did land in that interval is ADR-0033's ownership and activation
routing, B1 to B5. This record does not know which of those changes, if
any, altered the outcome. The second eject trigger stays armed: if the probe
again lists the card ahead of the full screen window after ⌘Tab into that
app's Space, unpinned with the preference off, Amendment 1's reopening
applies again.
