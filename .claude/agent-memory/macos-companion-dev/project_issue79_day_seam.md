# Issue #79: the day seam (branch 2 of the vertical-time-tabs stack)

Landed 2026-08-25 on `claude/79-2-day-seam-ymyi7n`, over the docs-only
spec branch. ADR-0020 required-work items 1 to 6.

## What exists now

- `companion_core::local_day(wall_ms, utc_offset_seconds) -> i64`
  (crates/core/src/sheet.rs), hoisted out of `placeholder_title`, which
  now calls it. A private `local_seconds` holds the epoch conversion the
  day and the clock face share. **Never write the `div_euclid(86_400)`
  again anywhere**: the point of the hoist is that a tab's `MMDD` stamp
  and the day it buckets into cannot disagree at a DST change.
- `Sheet::has_content()`: non-whitespace ink or at least one chip. It
  is the ledger's bar: `SheetStore::entomb` calls it, and a store test
  puts both readers over one matrix of pages.
- `Sheet::local_day(offset)` and `SheetStore::wall_ms()`.
- `companion_tabs_json` summaries carry two new keys, `page_has_content`
  (bool) and `page_day_offset` (i64 or null, 0 = today, -1 = yesterday,
  null exactly when `has_page` is false). The wall stamp is read once
  per call, before the walk. `TabSummary` decodes them as
  `pageHasContent: Bool` and `pageDayOffset: Int?`.

## Two things that cost time

- **A new non-optional field on a Codable DTO breaks the hand-written
  JSON fixtures.** `shell/Tests/CompanionKitTests/CompanionClientTests.swift`
  decodes four literal summary payloads; a missing key throws
  `keyNotFound` for a non-optional property (an `Int?` survives, because
  synthesis uses `decodeIfPresent`). Update every fixture in the same
  commit as the field: Swift does not build on Linux, so CI is the
  first place this shows up.
- **`age_by` / `companion_test_age_ms` cannot move a page's birthday.**
  It snapshots and restores at a later wall stamp, and restore carries
  every `created_wall_ms` through untouched
  (crates/core/src/persist.rs asserts it). To reach the far side of a
  local midnight, move *today*: hand `summary_json` a later
  `now_wall_ms`. Ageing still works for reaching an expiry.

## Environment note (sandbox, not the project)

`cargo test -p companion-ffi` fails two tests when the suite runs as
uid 0: `a_drop_that_could_not_touch_the_half_keeps_the_content_file` and
`a_reseal_that_could_not_touch_the_half_leaves_the_old_generation_alone`.
Both install 0o400/0o500 modes that do not stop root, so the half really
is unlinked and `std::fs::metadata(half).unwrap()` panics before the
tests' own "running as root, this branch is unreachable" guard. Verified
identical at the base commit; skip the pair or run unprivileged.
