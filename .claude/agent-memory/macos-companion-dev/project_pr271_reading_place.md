---
name: pr271-reading-place
description: PR 271 (fix/editor-preference) roll reading place rules; readingPlace survives restoring passes, RollPlace knows source vs preview and the top edge, dismantle removeObserver is load bearing, remote sync restates all but the mounted storage, AppKit widens a styled insertion's edited range to the paragraph end
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
- Remote sync: `onRemoteChange` now hands over the applied pages, and
  `PageModel.settleRemoteEdits` drops their quiet renderings and restates any storage with
  no layout manager (`testAPeersEditReachesAQuietDayAndThePageTheEditorLeft`). The
  mounted page's storage is still not merged; a peer's edit there diverges from the core.
- Tabs: `Coordinator.applyWrap` captures a `ScrollAnchor` before `setWrap` and scrolls
  back to it; `wrapPlace` reuses the last restored anchor while the clip origin and
  `generation` are unchanged, the tab form of the `readingPlace` rule above.

- Second review round (2026-10-17): TextKit 1's `lineFragmentUsedRect` spans BOTH line
  fragment paddings (measured: pad 5, glyphs 48.2, used 0..58.2), so
  `measuredSourceWidth` adds the insets and no padding; DayScrollTests and
  PageViewStateTests restate that formula. Unwrapped tooltip rects run
  to the text view's bounds.maxX so a sideways scroll keeps their AppKit tags.
- `DayStackView.mountedStorageEdited` rebases `readingPlace` through the mounted
  storage's `editedRange` and `changeInLength`. It is registered for the mounted storage
  only (`observeMountedStorage`, run by a `defer` in `settleEditor`, which every storage
  move inside the roll goes through), and it is nonisolated with a main thread check because
  the `@objc` main actor isolation check would trap on a storage edited off main. The
  notification posts before the storage delegate and the layout managers. A whole storage
  restate (undo, `setAttributedString`) reports (0, new length), so an interior index stays.
- Third review round (2026-10-20), measured: the page storage is NSConcreteTextStorage with
  `fixesAttributesLazily` true, so typing (styled runs, emoji, CJK, Return in a list) reports
  exactly the typed characters. An insertion with another paragraph's style is reported
  from the insertion to the paragraph's end: the list depth nudge (⇥ in a marker, a storage
  level replace at the item start) and `insertText` of an attributed string. Hence the
  rebase moves an index inside an edited span by delta, except a whole restate (the storage
  length is passed in). The emission (`editOps`) then sends del plus ins of that whole span.
- `readingPlace` is restored whenever there is one; `currentPlace` is the only gate. A place
  taken at the top edge (`RollPlace.atTop`) restores only `x`, which keeps Day 0 at the top
  when a day is prepended (`testPrependingAndReorderingAtHorizontalOnlyOffsets...`).
  `relayout()` returns whether it restored or answered a summon, and the assembly pass
  calls `keepStill` only when it did neither; `EditorSizingHost.relayout` returns that Bool.
- `InkLayoutManager.layoutGeneration` keys the cached widest line (`widestUsedMaxX`).
  Measured routing: storage edits and fonts reach `processEditing`; container size,
  padding, exclusion paths, line break mode reach `textContainerChangedGeometry`;
  showsInvisible/hyphenation/orientation reach `invalidateGlyphs`; `typesetter`,
  `glyphGenerator`, `usesFontLeading`, `typesetterBehavior`, non contiguous layout and
  suspicious contents call no public hook, hence their didSet overrides. A new geometry
  route needs a bump there or quiet days in the roll keep a stale width.
- `MainActor.assumeIsolated` cannot capture a non-Sendable `NSTextContainer` that is used
  after the closure (region isolation error); read the `@MainActor` view out first.

**Why:** reviewers (Copilot, Greptile, Claude) flagged each; all verified by failing tests.

**How to apply:** when touching the roll's place logic, run
`testWrapAndWidthRoundTrips...`, `testSyncedTextAround...`, `testTogglingAPreview...`,
`testADepthNudgeAbove...`, `testAFirstDayReaderScrolledOnlySideways...` and
`testPrependingAndReordering...` in DayScrollTests. Related: [[issue79-perforated-roll]], [[issue131-rail-minimap]].
