---
id: 2026-0916-rail-redundancy
title: The rail and the gutters say each fact once
status: accepted   # draft → accepted → superseded
dated: 2026-09-16
supersedes: docs/spec/design/2026-0916-clipboard-clear-interval.md, on D-34's stamp, D-36's marks, D-37's gutter gauge and D-38's tooltip only; docs/spec/design/2026-0915-ui-ux-decisions.md, on D-12's markup stripping only
superseded-by:
reviewed: 2026-09-16
surfaces: OnetimePad (background surface), Days + side
sources:
  - docs/spec/design/2026-0916-rail-redundancy-wireframe.svg (the maintainer's redundancy pass over the 0916 screenshot, twelve numbered findings)
  - docs/spec/design/2026-0916-clipboard-clear-interval.md
  - docs/spec/design/2026-0915-stream-navigator.md
  - docs/spec/design/2026-0915-ui-ux-decisions.md
  - shell/Sources/CompanionKit/StreamNavigator.swift
  - shell/Sources/CompanionKit/TimeRailView.swift
  - shell/Sources/CompanionKit/DayScrollView.swift
  - shell/Sources/CompanionKit/SettingsSections.swift
  - crates/core/src/sheet.rs
  - crates/ffi/src/lib.rs
---

# The rail and the gutters say each fact once

The maintainer's redundancy pass of 2026-09-16 put the 0916 screenshot
of Days + side beside a proposed drawing and numbered twelve findings.
Eight are changes and four are reviews that kept what stands. This
record is what the build owes for the eight, and the argument for the
four. It amends the stream navigator decisions where section 3 names
them and leaves everything else in the 2026-0915 and 2026-0916 records
standing.

The finding under all eight: the rail and the roll were each saying
the same fact several times over. A node read "0914-1300" under the
words "2 days ago", so the date was said twice on every page; the
gutter said "2 days ago · 0914-1300" and then, as its title, "0914-1300"
again, so the same page said its date three times in one line; twenty
pages drew twenty hollow circles and twenty gauges, so the one node
and the one gauge that mattered stood in a texture of their own shape.
Three pages minted in one minute read as three copies of one page.

## 1 · What changes

- **D-44 (fixed)** A time shown without its date is a time. A node
  and a gutter read the page's birth time as "HH:mm", never "HHmm" and
  never with the "MMDD" the day's words above already say; the core's
  "MMDD-HHmm" placeholder keeps its date because a tab's label stands
  alone on the strip with no day beside it. Two pages on one day born
  in the same minute would read alike, so those, and only those, read
  to the second, "13:00:04 · 13:00:17 · 13:00:41", while the rest of
  the day keeps the minute. The rule is scoped to a day: a page on
  another day sharing the minute is told apart by its day's words.
  Both patterns are the user's, as Unicode date patterns under the Days
  choice in Settings (D-26); an empty pattern reads as the standard.
  The tooltip's second line, the page's title, is absent when the
  title is the placeholder, which would be the stamp again in the
  core's own shape. This amends D-34's stamp and D-38's tooltip.
  *Acceptance:* `StreamNavigator.stamps` is the one rule the rail and
  the roll read; `StreamNavigatorTests.testPagesSharingAMinuteReadToTheSecond`,
  `testTheStampPatternsAreSettingsWithTheStandardBehindThem` and
  `testAPlaceholderTitleIsNotCarriedTwice`; `StampFormatSettingTests`
  pins the two keys and that neither marks content dirty.
  *Amended 2026-10-01:* the Days choice in Settings is now Timeline,
  under Page layout
  ([ADR-0037](../../adr/0037-one-page-layout-setting.md)).
- **D-45 (fixed)** One dot. The active node is a filled ember dot, the
  one dot on the rail; every other page is a quaternary tick across
  the track, wider for a day's first page, so the track reads as a
  ruler with one bead on it; the place today keeps while it holds no
  page stays the dashed ring. Twenty hollow circles read as twenty
  things to look at, and only one of them is where the surface stands.
  Each mark keeps the same seat whichever it is, so a selection moving
  down the rail moves nothing else. This amends D-36's marks; ember is
  still spent on the same three things.
  *Acceptance:* `TimeRailView.marker(for:)`; hardware verification for
  the drawing.
- **D-46 (fixed)** The gutter says the day once and draws only a typed
  name. A day's first gutter reads "2 days ago · 13:00"; the gutters
  under it on the same day read the time alone, "13:17", because the
  day was said once above them and the hairline says these are one
  day's pages. The gutter's title is drawn when the user typed it and
  at no other time: a placeholder repeats the stamp beside it, and a
  derived title repeats the page's first line, which stands directly
  under the gutter, so a first line on screen would be read twice. The
  seam says which of the label's three steps answered
  (`title_source`: name, derived, placeholder), so the shell never
  guesses from the label's shape. A rename shows the field for its own
  length whatever the source, since the draft is the thing edited;
  VoiceOver still hears the title, since it reads the gutter on its
  own. This amends the gutter paragraph under D-38.
  *Acceptance:* `DayHeaderView.dayText(spokenLabel:stamp:firstOfDay:)`
  and `drawsTitle(source:renaming:)` are pure;
  `DayScrollProjectionTests.testADaysFirstGutterCarriesTheDayAndTheRestTheTimeAlone`,
  `testTheGutterDrawsOnlyATypedName`;
  `DayScrollTests.testAGutterDrawsATypedNameAndNoGauge`; the FFI's key
  list test names `title_source`.
- **D-47 (fixed)** No gauge on a gutter. A page's remaining life is
  drawn once, under the active node on the rail, and nowhere on the
  roll. D-37 kept the gutter's gauge because time as geometry is D-11
  and the gauge speaks rounded words; twenty gauges of one shape read
  as a texture and not as time, and the words are still spoken at the
  gutter without the bar. The retained words for a page past the
  window stay on the gutter, since they are words and not a shape. This
  amends D-37.
  *Acceptance:* `DayHeaderView` hosts no `GaugeBar`;
  `DayScrollTests.testAGutterDrawsATypedNameAndNoGauge` pins that and
  that the countdown is still in the spoken header.
- **D-48 (fixed)** A fence's rule is not a name. A page that opens with
  "```ruby" is titled by the first line inside the fence, as typed, and
  never "ruby": the rule is markup, and code carries no markdown to
  strip. A body that is nothing but rules derives nothing, the same as
  a body that is nothing but blank lines. This amends D-12's markup
  stripping.
  *Acceptance:* `sheet::tests::titles_step_over_fence_rules_and_take_the_code_as_typed`.

## 2 · Reviewed and kept

- **Minimap (finding 3).** The slivers beside the track are the
  intended minimap and not a texture block: they are the roll's own
  geometry, darker under the band (D-35). No change.
- **Doc icon (finding 5).** The file row's icon is the file-type cue.
  No change.
- **Fences and wash (finding 11).** Fences keep their backtick rules
  and their wash (D-05, D-06). No change.
- **Sealed chip (finding 12).** The block keeps D-27's shape. No change.

The proposed drawing also writes a page's title on its rail node where
the page has one ("Walk on wild side" beside "3 days ago"). This record
does not adopt it: D-35 keeps glyphs off the rail, D-38 puts the title
in the node's tooltip, and D-10 keeps content out of hover. The finding
that drew it, the fence title, is fixed where the title is made (D-48)
and reads correctly in the tooltip and the strip. This is the one place
the build narrows the drawing.

## 3 · Amended elsewhere

One line per passage, each of which carries a dated note pointing here.

- 2026-0915-stream-navigator.md, section 1: the stamp (D-34), the
  marks (D-36), the gutter gauge (D-37), the tooltip's title and the
  gutter paragraph (D-38). The record is a superseded snapshot; the
  note is at the section head.
- 2026-0916-clipboard-clear-interval.md: the same four decisions as
  incorporated there.
- 2026-0915-ui-ux-decisions.md, D-12: fence rules are markup.
