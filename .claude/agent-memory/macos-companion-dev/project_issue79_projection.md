# Issue #79 — the day projection (branch 3 of the vertical-time-tabs stack)

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
  false, no `markDirty`), `PageModel.timeUnits` (computed — never cache
  it, or the labels stop rolling over at local midnight and the mode
  needs the timer the design exists to avoid), `SurfaceTarget`,
  `visibleTargets`, `select(target:)`, `openToday()`, `capRefusal(
  showsTimeUnits:)` and `reconciledTimeSelection(current:projection:)`.
- `select(index:)` and `step(_:)` route through `visibleTargets`, and
  `step` now calls `select(_:)` instead of repeating its
  ledger-and-focus ceremony. `MintFocusTests` covers that ceremony and
  passed unedited.

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
