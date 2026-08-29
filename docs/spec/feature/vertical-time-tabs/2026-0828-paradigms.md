# Paradigms: the duration the UI optimizes for

Side doc to [`README.md`](README.md) · captured 2026-08-28.
A concept note, deliberately unscheduled: nothing here is committed
to build. It names and grows the sentence the spec already carries,
"the unit is configurable and the first one is the day."

## The concept

A paradigm is the duration of time the UI optimizes for: the bucket
unit of the time-tabs projection, and eventually the tempo the whole
surface assumes. The current and default paradigm is **daily**
(ADR-0020's day bucket). Two others motivate the generalization:

- **Hourly**, for someone very busy taking lots of realtime notes.
  The rail markers become now, last hour, 2 hours ago, and so on,
  the same relative-label scheme that keeps Today and -1d true
  without anyone rewriting them.
- **Weekly or monthly**, for a project on a slow roll, where a day
  is too fine a grain and most days would be empty rungs on the
  rail.

## Why it is architecturally cheap

ADR-0020's model does the work already: a unit of time is a query
over the pages' own birth stamps, computed on every read and stored
nowhere. A paradigm switch is a re-bucketing of the same projection.
No data changes, no migration, no page is touched; the sealed
format, the tab model, and the TTL ladder are as untouched by a
paradigm as they are by the existing day view. Flipping paradigms
loses nothing, for the same reason flipping the Settings toggle
loses nothing.

## The tension worth recording now: the TTL ceiling

The paradigm changes the lens; it must not change what lives. The
TTL ladder tops out at 7 days ("there is no forever", ADR-0011), so
a **weekly** paradigm shows at most two meaningful buckets and a
**monthly** paradigm optimizes for pages that mostly cannot exist.
Two honest resolutions, and the choice is a retention argument for
an ADR, not a UI knob:

- Paradigms stop at weekly, and monthly is out of scope while the
  ceiling stands.
- The ceiling becomes paradigm-aware, which reopens ADR-0011's
  "no forever" reasoning and has to be argued there in retention
  terms, not smuggled in as a view preference.

The default answer until someone makes that argument: the lens never
outreaches the ladder.

## Open questions, parked with the concept

- Whether **hourly** strains the one-page-per-unit shape: many small
  pages per day means more tab churn against the existing cap, and
  it may want the bucket anchored to now (rolling hours) rather than
  to clock hours.
- Whether a paradigm tunes defaults, for example the default TTL
  rung (8h, "a working day") reading differently under an hourly
  tempo than a weekly one. Tuning defaults touches retention and
  gets decided deliberately if at all.
- Whether the paradigm is one global setting or per-surface. The
  spec's existing toggle is global; start there.
- What the marker vocabulary is per paradigm (now / -1h / -2h,
  Today / -1d, this week / -1w), kept relative so labels stay true
  by construction.

## Status

Concept only. The daily paradigm is the shipped behavior and stays
the default. Open when vertical time tabs graduate from prototype
and a second tempo shows up in dogfood.
