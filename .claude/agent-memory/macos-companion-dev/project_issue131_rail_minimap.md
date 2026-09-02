---
name: issue131-rail-minimap
description: Issue #131 landed on feature/131-time-rail, the rail says words while the roll's gutter keeps "-3d", and the minimap's two inks are uncalibrated
metadata:
  type: project
---

Issue #131 (time rail word labels plus a faint minimap) landed as four
commits on `feature/131-time-rail`, pushed 2026-09-01, PR #140.

**Why:** the rail abbreviated ("-3d") only because the column was 56pt,
and its flat background gave a scrolled reader no sense of place in the
roll.

**How to apply:**

- Two vocabularies on one card are deliberate, not an oversight. The
  rail says "2 days ago" (`TimeUnit.railLabel`, the spoken phrase with
  one capital) and the roll's day gutter keeps `TimeUnit.label` ("-2d"),
  because the gutter shares its line with a title and a countdown. Spec
  open question 12 holds that decision. Do not "fix" the mismatch
  without reopening it.
- The minimap's inks (`RailMinimapView.dayInk` 0.10,
  `viewportInk` 0.06) are guesses awaiting the dogfood pass, QA case 10
  in `docs/qa/verification-procedures/vertical-time-tabs.md` and spec
  open question 11. "Too faint to be worth having" retires the band
  rather than darkening it.
- The measurement crosses to the rail as rectangles only
  (`RollGeometry`), and it is published through a coalescing hop on the
  main actor because `DayStackView.relayout` runs inside `updateNSView`.
  Anything that wants to publish more from a layout pass must take the
  same hop.

Related: [[project_issue79_time_rail]], [[project_issue79_perforated_roll]].
