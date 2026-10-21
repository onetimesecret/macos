---
name: issue254-tab-drop
description: PR 264 (drop on a time tab) review round of 2026-10-16; the core does not refuse a seal onto a page past its deadline, so the shell settles first; tab gates are readOnly plus presentationSurface
metadata:
  type: project
---

PR 264 made a time tab a drop target (`TabDropTarget`, `TabStripView` placement only). Review round 2026-10-16 fixed items 1 to 10 in eight commits plus a merge of main (PR 263, also app 0.37.0).

**Why:** three facts were not obvious from the code and cost a build cycle each:
- `companion_seal_from_drag` and `sealText` succeed on a page past its deadline (Law 0001 expiry row lists paste, place, move and clone as refusing, not the seal). The shell's `PageModel.sealFromDrag(sheet:replacing:)` therefore calls `settleIfDue(sheet:)` first and refuses with `pageExpiredLine`; a test that expects the core to refuse a seal on a due page fails.
- `transferOwnership(to:)` runs `relinquishPresentation`, which ends a standing page drag, so after a hand off the same drag classifies as a stale fragment (`.copy`), not `.move`. Use a foreign (seal) drag as the owner-side control.
- The tab's gates are `TabDropTarget.readOnly` (from `BackdropRootView`'s `!raised` through `TabStripView(model:readOnly:)`) and `surface` (from the `presentationSurface` environment, read in `TabDropOverlay.updateNSView`); `takesDrops = !readOnly && model.owner == surface`.

**How to apply:** the follow up, issue 267, went to the side Timeline's page nodes, not `SlotRailView` or `TimeStripView`, which no layout draws (ADR-0037); see [[issue267-timeline-node-drops]]. Hand checks owed: a real drag reaching a view whose `hitTest` returns nil, the resting card, ⌥, TextEdit.
