---
name: pr271-reading-place
description: PR 271 (fix/editor-preference) roll reading place rules; readingPlace survives restoring passes, RollPlace knows source vs preview and the top edge, dismantle must unpick the editor's frame watch, a whole range edit keeps the place only when the projection wrote it, remote sync restates all but the mounted storage, AppKit widens a styled insertion's edited range to the paragraph end
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
  index by proportion (`mappedAnchor(into:text:)`), since no source to rendered
  position map exists. Defaults keep `RollPlace(page:anchor:)` compiling. Since #290 the
  text is an autoclosure (restore runs every relayout pass) and the result is snapped
  with `scalarBoundary`, the helper #283 added for the exhausted rebase.
- A reseed of the reading page's region rebases the index by common suffix then prefix
  (`RollPlace.rebased`); suffix first so text arriving at the anchor goes above it.
- `DayScrollView.dismantleNSView` calls `stack.unobserveEditor()` (2026-10-20, was a blanket
  `removeObserver(stack)`): it takes off the mounted storage watch and the editor's frame and
  text watches. The editor's frame watch is the one that matters: `leavePage` resizes the
  editor while the dismantled roll stands, and with that watch left on
  `testTheRollAnswersAJumpFromTheRailUntilItIsDismantled` fails (clip 120 to 40). The clip and
  model registrations from `observeRoll` stay; they are zeroing.
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
- Fourth round (2026-10-20): a styled insertion on a page of ONE paragraph with no newline is
  reported as (0, whole length), the restate's shape, so `RollPlace.rebased` now takes
  `byProjection` (read from `PageModel.isApplyingProjection` inside `mountedStorageEdited`) and
  keeps the index only for a projection write of the whole text. Every whole restate of an
  editor storage runs inside `applyingProjection` (restateStorage: undo, redo, sync, file
  recovery; showNote). A test through `insertText` cannot see the rebase: the reveal of the caret
  moves the clip afterwards, so the test inserts through the storage.
- Typing with the caret scrolled out of view: the reveal wins without help, because the clip
  moving outside a pass recaptures `readingPlace` in `rollScrolled`
  (`testTypingWithTheCaretScrolledOutOfViewRevealsTheCaret` pins it).
- With legacy scrollers, setting `hasHorizontalScroller` tiles the clip synchronously and its
  frame notification runs a whole `relayout` (measured), which is why the toggle stays inside
  the `isLayingOut` gate. Overlay scrollers start no pass.
- Block pills are placed again on a clip bounds change only when `blockAffordanceMeasure`
  moved (`placedBlockMeasure`); not gated on minX, because the editor's visibleRect is empty
  while it is scrolled out of view on the roll.
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
