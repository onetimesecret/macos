# Issue #79: the day projection (branch 3 of the vertical-time-tabs stack)

Landed 2026-08-25 on `claude/79-3-day-projection-ymyi7n`, over the day
seam. ADR-0020 required-work items 7 to 10. No pixel: the Settings row
and the rail belong to branch 5, deliberately, so a branch merged alone
cannot show a control that does nothing.

## What exists now

- `shell/Sources/CompanionKit/TimeUnits.swift`: `TimeUnit` (one case,
  `.day`, with `bucket(dayOffset:)`, `label(bucket:)`,
  `spokenLabel(bucket:)`) and `TimeUnitProjection.project(tabs:
  selectedPageID:unit:)`. Value types, `Sendable`, no AppKit, no core
  call. **Every law of the mode goes in `project` and nowhere else.**
- One law the ADR had not written down and the views must not re-decide:
  a day that is drawn draws **every** page on it. The filter is by day,
  never by page, so `hiddenBlankPages` counts pages in days nobody can
  reach and never pages inside a day that is on screen.
- `PageModel.showsTimeUnits` (defaults key `showsTimeUnits`, default
  false, no `markDirty`), `PageModel.timeUnits` (computed, never cache
  it, or the labels stop rolling over at local midnight and the mode
  needs the timer the design exists to avoid), `SurfaceTarget`,
  `visibleTargets`, `select(target:)`, `openToday()`, `capRefusal(
  showsTimeUnits:)` and `reconciledTimeSelection(current:projection:)`.
- `select(index:)` and `step(_:)` route through `visibleTargets`, and
  `step` now calls `select(_:)` instead of repeating its
  ledger-and-focus ceremony. `MintFocusTests` covers that ceremony and
  passed unedited.

## Two laws the adversarial review added (2026-08-25)

- **A bucket is never positive.** `TimeUnit.bucket(dayOffset:)` clamps
  at today (`min(dayOffset, 0)`). `label` already folded a positive
  offset to "Today"; the grouping did not, so a host clock that went
  backwards drew *two* rows named Today (the peopled skewed one and
  the empty bucket 0 the projection always inserts), and every
  `first(where: { $0.bucket == 0 })` lookup found the empty one. ⌘N
  minted a second page beside the visible one and the summon's anchor
  selected nothing. Fold in the one line where an offset becomes a
  bucket rather than hardening each lookup: the skew then cannot be
  observed at all. The two lookups (`openToday`, `anchorOnToday`) are
  unchanged and now correct by construction.
- **The mode's reconciliation runs at the mode's entrance.**
  `reconciledTimeSelection` had one caller, `refresh()`, and the
  `showsTimeUnits` didSet triggers no refresh, so the transition that
  most reliably produces "selection on a slot the rail draws no row for"
  (the selected page expired overnight) was the one transition the rule
  was never applied to. The didSet now applies the fall when the value
  flips **to true only**. Off is deliberately untouched: the strip draws
  every slot, so there is nothing to fall off. It mints nothing and
  marks nothing dirty, and it cannot move a selection the mode it is
  entering would draw, which is what keeps ADR-0020's toggle-safety
  claim. Tests pin all three directions.

## Two things worth knowing before branch 5 or 6

- **Days cannot be staged against a live core from Swift.**
  `ageForTests` snapshots and restores at a later wall stamp, and a
  restore carries every `created_wall_ms` through untouched, so every
  page a Swift test makes is born today. Day-shaped laws are argued over
  hand-built `TabSummary` values (`@testable` reaches the internal
  memberwise init); the live core is for "the tab stands when the page
  goes". Expiring one page and not its neighbours is done with rungs:
  `setRung(tab:rung: .oneHour)` then age two hours.
- **A live-clock assertion about buckets can straddle local midnight.**
  Assert about which pages share a day rather than about the bucket
  number when a live core made the pages.

## Environment note (sandbox, not the project)

The same two `companion-ffi` tests fail here as uid 0 that branch 2
recorded (`a_drop_that_could_not_touch_the_half_keeps_the_content_file`,
`a_reseal_that_could_not_touch_the_half_leaves_the_old_generation_alone`).
No Rust changed on this branch; the pair fails identically at its base.
