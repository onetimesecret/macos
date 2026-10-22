---
name: issue267-timeline-node-drops
description: PR 269 retargeted 2026-10-20 to TimeRailView page nodes; the side Timeline has two renderings (stream navigator by default, pads rail when the experiment is on); SlotRailView and TimeStripView were drawn by no layout and are deleted (issue 275)
metadata:
  type: project
---

PR 269 (issue 267) first seated `TabDropOverlay` in `SlotRailView` and `TimeStripView`. Maintainer direction of 2026-10-20 moved it to the side Timeline's page nodes, because `PageModel.showsPagesDownSide` is `showsTimeUnits` and ADR-0037 left those two views undrawn; issue 275 deleted them on 2026-10-21. App 0.40.0.

**Why:** the brief pointed at the pads rail's node button only, but `TimeRailView.body` branches on `model.pads.isEnabled`, which defaults off, so the Timeline a person sees is `legacyRail`, drawn by `StreamNavigatorView.node(_:width:)`. Seating the target in one rendering would have repeated the unreachable placement mistake.

**How to apply:**
- Before building on a placement, check that `BackdropRootView` and `PrimaryEditorRootView` draw it.
- Anything per Timeline node goes in both renderings; tests loop `for pads in [false, true]`, setting `model.pads.isEnabled` before making pages.
- A day's first row is drawn a point higher (`StreamNavigator.Metrics.rowLift`); the packing adds that point at a day boundary, so node targets are asserted disjoint. Change the lift in one place only. Since PR 303 (#277) the navigator column scrolls too and every node seats a target; see [[issue277-rail-scrolls]].
- `TimeRailView(model:readOnly:)` and `TabStripView(model:readOnly:)` take no default; the editor window passes false.
- Hand checks owed: sealed-fragment.md, "Drops on the side Timeline's page nodes". Related: [[issue254-tab-drop]].
