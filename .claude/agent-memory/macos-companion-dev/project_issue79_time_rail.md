# Issue #79: the time rail (branch 5 of the vertical-time-tabs stack)

Landed 2026-08-25 on `claude/79-5-time-rail-ymyi7n`, over the editor
factoring. ADR-0020 required-work item 12. The first branch of this
stack a user can see: the rail, the card's branch and the Settings row
that turns them on. The roll is still branch 6's.

## What exists now

- `shell/Sources/CompanionKit/TimeRailView.swift`: `TimeRailView`
  (public, 56pt, `VStack(spacing: 2)` of `TimeUnitTab` over
  `model.timeUnits.units`) and `TimeUnitTab` (internal). Four decisions
  are pure statics with tests and nothing else decides them:
  `TimeUnitTab.target(for:)`, `TimeRailView.selectedBucket(
  projection:selection:)`, `chord(forRowAt:keymap:)` and the footer's
  `hiddenPagesLine`/`hiddenPagesHelp`.
- `TimeUnitProjection.Unit.spokenRemaining`, from the same
  soonest-dying page as the gauge. The rail carries `SheetTab`'s
  accessibility triple and the third had no source; looking it up in
  the summaries would let a row speak one page's clock and draw
  another's.
- `BackdropRootView.card` branches, and `ConnectionSettingsView` has
  the toggle. `TabStripView.swift` takes no diff at all.

## Four contracts a later branch must not re-decide

- **The rail's targets are `visibleTargets`' targets.** Both map a unit
  to its first slot in strip order, `.today` only where a day answers
  to no slot. A click on the second row and ⌘2 must land together; a
  test asserts the two lists element for element on a live pad.
- **The card's two content rows are written out in full**, deliberately,
  so the off path is identical by inspection rather than by trusting a
  wrapper with one child. The cost is a remount of the editor on a
  flip, which is what a deliberate flip should cost and what a
  keystroke must never pay.
- **The lit row is the day the surface is showing, or nothing at all.**
  A selection standing where the rail draws no row (an empty slot, or
  a blank old page the content bar holds back) lights nothing, and an
  empty Today takes the mark only by elimination, on the pad where no
  drawn day holds a page. The stack's first CI run caught
  `selectedBucket` lighting Today for a slot it draws no row for, which
  would have said the surface was somewhere it is not.
- **The rail carries no verb.** No rename, close, rung, hold or
  reorder, and no row for a tab holding no page. `TabFramesKey` is
  never touched, so the two modes cannot contend over one preference
  key's meaning.

## Two testing notes

- **Never hand a View type's static to `map` unapplied.** SwiftUI's
  `View` is `@MainActor`, so a conforming struct's statics are
  main-actor isolated and `units.map(TimeUnitTab.target(for:))` is a
  conversion that loses the isolation. `units.map { TimeUnitTab.target(
  for: $0) }` is a closure formed in an isolated context and inherits
  it, which is the form to write.
- A live core still cannot make two days (the ageing seam restores
  every creation stamp intact), so ⌘2 and ⌥⌘→ are pinned as the
  contrast between the two modes on a one-day pad, and the multi-day
  laws are argued over hand-built summaries.
