---
name: adr0034-altitude-keeper
description: ADR-0034 full screen bit follows altitude; the window controller must not be built under xctest, so BackdropAltitudeKeeper and CompanionLevelFollower are the tested seams
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
global mouse monitor. So the controller is never constructed in tests.
`BackdropAltitudeKeeper` holds the committed stance and the guarded level and
collectionBehavior writes; tests drive it with a deferred, never ordered
`NSWindow` subclass that counts writes through `didSet` overrides.

The pin and preference sinks live in the keeper too (`observe`, with
`willRepin` and `didRepin` hooks for the controller's mouse and frame work),
so nothing rests on the order Combine delivers to separate subscribers. The
follower orders a key companion front a main actor turn after a level change
for the same reason.

**How to apply:** new window decisions go in a small type that takes any
`NSWindow`, not in the controller. `CompanionLevelFollower` is the one
follower for Settings and About; its sinks use the emitted value because
`@Published` emits on willSet (the old Settings sinks read the model back
and saw the stale value). Apple's header documents `.fullScreenNone` only as
"can not be made fullscreen"; staying out of other apps' full screen Spaces
is observed, not documented. ADR-0019's sentence that "the raise" accepts
full screen Spaces stays as written; it carries `Superseded in part by:
ADR-0034` and a Decision history bullet instead.
