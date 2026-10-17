---
name: pr271-reading-place
description: PR 271 (fix/editor-preference) roll reading place rules; readingPlace survives restoring passes, RollPlace knows source vs preview, dismantle removeObserver is load bearing, remote sync writes no storage
metadata:
  type: project
---

Review round on PR #271 (2026-10-16, committed as 8f16332b), `DayStackView` in
`shell/Sources/CompanionKit/DayScrollView.swift`.

- `readingPlace` is kept as the restored place when `relayout()` restored it; only a
  pass that restored nothing, a user scroll (`rollScrolled` outside a pass), and the
  explicit moves recapture it. Recapturing after a reflow named the visual line's first
  character and drifted a mid paragraph reader backward on every wrap or width trip.
- `RollPlace` gained `reading` (.source or .preview) and `length`; a mismatch maps the
  index by proportion (`mappedAnchor(into:length:)`), since no source to rendered
  position map exists. Defaults keep `RollPlace(page:anchor:)` compiling.
- A reseed of the reading page's region rebases the index by common suffix then prefix
  (`RollPlace.rebased`); suffix first so text arriving at the anchor goes above it.
- `NotificationCenter.default.removeObserver(stack)` in `DayScrollView.dismantleNSView`
  is required: without it `testTheRollAnswersAJumpFromTheRailUntilItIsDismantled` fails
  (the dismantled roll's clip moves from 120 to 32).
- Remote sync (`SyncController.onRemoteChange` calls `markDirty()` and `refresh()`) writes
  no live page storage and invalidates no quiet rendering, so a peer's edit reaches the
  roll only after some invalidation. Not fixed here; flagged to the parent.

**Why:** reviewers (Copilot, Greptile, Claude) flagged each; all verified by failing tests.

**How to apply:** when touching the roll's place logic, run the three tests
`testWrapAndWidthRoundTrips...`, `testSyncedTextAround...`, `testTogglingAPreview...` in
DayScrollTests. Related: [[issue79-perforated-roll]], [[issue131-rail-minimap]].
