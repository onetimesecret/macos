---
name: adr0034-altitude-keeper
description: ADR-0034 full screen bit follows altitude; BackdropAltitudeKeeper is the tested seam for the card's level, and since #293 it also lowers the card under a key companion window (Settings, About, Send Feedback), which never change level
metadata:
  type: project
---

Landed uncommitted 2026-09-18 on feature/192 (PR 194): full screen
participation follows altitude (`BackdropAltitude.joinsFullScreenSpaces`),
`BackdropStance.collectionBehavior(altitude:)` replaced the `pinned:` form.

**Why a keeper type:** `BackdropWindowController.init` runs `apply(.resting)`
through the undropped `$stance` sink, which orders a real pane onto the
runner's desktop; a raise calls `makeKeyAndOrderFront` on a nonactivating
panel (takes the keyboard from the person's frontmost app) and installs a
global mouse monitor. So the keeper's own suites never construct the
controller (`EditorOwnershipSequenceTests` does, for the ownership walks).
`BackdropAltitudeKeeper` holds the committed stance and the guarded level and
collectionBehavior writes; tests drive it with a deferred, never ordered
`NSWindow` subclass that counts writes through `didSet` overrides.

The pin and preference sinks live in the keeper too (`observe`, with
`willRepin` and `didRepin` hooks for the controller's mouse and frame work),
so nothing rests on the order Combine delivers to separate subscribers.

**Companion windows (#293, PR 306, 2026-10-21):** `CompanionLevelFollower`,
`keylessAltitude` and `companionLevel` are gone. Settings, About and Send
Feedback stay at `.normal`; `BackdropAltitude.resolve` takes
`companionKeyed:` and lowers a floating card to normal while one of them
(or a sheet on one) is key, a desktop card staying put, and the card's own
`keyed: true` winning. The keeper watches `didBecomeKey`, `didResignKey`
and `willClose` for every window with the delegate's `isCompanionWindow`
predicate, and orders the key companion front one main queue hop after the
card lowers (a level written puts a window at the front of its new level).
Tests post the key notifications by hand on unordered windows and use
`drainMainQueue()` for the hop. A keeper test that commits `pinned: true`
must also set `model.pinned`, since the companion turns reapply from the
model.

**How to apply:** new window decisions go in a small type that takes any
`NSWindow`, not in the controller. `@Published` emits on willSet, so sinks
use the emitted value for the input that is changing. Apple's header
documents `.fullScreenNone` only as "can not be made fullscreen"; staying out
of other apps' full screen Spaces is observed, not documented. ADR-0019's
sentence that "the raise" accepts full screen Spaces stays as written; it
has `Superseded in part by: ADR-0034` and a Decision history bullet instead.
