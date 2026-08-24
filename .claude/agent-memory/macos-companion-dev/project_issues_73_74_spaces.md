---
name: issues-73-74-spaces
description: Issues #73 (invisible pinned card takes clicks) and #74 (cmd-tab Space return) landed 2026-08-24 as stacked branches; both wait on hardware to confirm, and #74's flicker has one candidate left
metadata:
  type: project
---

Issue #73 landed on `feature/73-invisible-clicks` and #74 on
`feature/74-space-return` (stacked on it), both pushed 2026-08-24, both
green on the full Rust and Swift suites.

What is *decided* versus what is *hypothesis*, since the difference is
the whole reason the two hardware procedures exist:

- **#73, decided:** the exposure gate (`SurfaceExposure` plus
  `BackdropStance.ignoresMouse(pinned:exposure:)`) refuses the mouse
  whenever the window server says the surface is off the active Space or
  occluded. Fail-closed, unit tested, holds regardless of anything else.
- **#73, hypothesis:** dropping `.stationary` from the pinned rest makes
  the card actually visible over another app's full-screen Space. If the
  gate stays open over an invisible card on hardware, the next signal to
  try is `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` against
  `panel.windowNumber`, which slots into `SurfaceExposure` as a third
  signal with no change to the decision.
- **#74, decided:** every posture claims every Space and never changes
  membership (ADR-0019), which is the ⌘Tab-to-Desktop-1 fix; the edge
  drag between desktops is a documented refusal, not a defect.
- **#74, open:** the flicker. Two causes were removed (membership
  rewrites on every raise, the order-out round trip). The candidate
  still standing is that the unpinned resting window spans the whole
  screen while the raised window is the card's own rect, so every raise
  resizes the window and relays out the hosted view. Fixing that means
  letting the unpinned rest hug the card too, which touches ADR-0015's
  shape and wants its own issue.

**Why:** the dogfood aberrations log of 2026-08-19 filed all four
symptoms; the milestone is "Dogfood fixes".

**How to apply:** before offering more Space or window-level changes,
check whether
`docs/qa/verification-procedures/spaces-and-cmd-tab.md` and
`pinned-over-fullscreen.md` have Results rows yet. If they are still
empty, the hardware evidence that would decide the next move does not
exist, and guessing at another flag combination is the failure mode
these two procedures were written to prevent. See
[[claims-that-outran-the-code]].
