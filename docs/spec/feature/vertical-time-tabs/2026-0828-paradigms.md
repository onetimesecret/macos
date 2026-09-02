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

## The TTL ladder is the daily paradigm's instance
(updated 2026-08-29 after re-reading `docs/tenets.md`;
graduated 2026-09-01 into ADR-0011, accepted)

**This section has graduated.** ADR-0011 is now accepted and carries
the rule (section 1), the per-ladder ceiling (section 2), the default
rung (section 3), grace (section 4) and the no-rewrite guarantee
(section 6). What follows is the argument that got it there, kept for
its reasoning. Where the two differ, the ADR governs, and it differs
in two places: the default rung is the ceiling rather than 8h, and
grace is a boundary snap at creation under a setting rather than
padding inside a rung.

An earlier version of this note ended the argument with "the lens
never outreaches the ladder." That is the move tenet №3 forbids:
citing the ladder instead of letting the idea argue against it. Run
through the tenets, the paradigm concept wins the argument, and the
ladder is what modifies.

The case in tenet terms. ADR-0011 (a draft when this was written)
grounds the ladder in intuition, not in retention doctrine: a rung must be a duration
the user can rationalize ("will I need this next week at this day
and time"), padded with grace the way an alarm set for "tomorrow"
forgives midnight. That question is tempo-relative. "Will I need
this next week" is the daily paradigm's question; a slow-roll
project asks "will I need this next month," and an hourly
note-taker asks something shorter than the current bottom rung. A
monthly-tempo page dying at 7 days is forgetting against the user's
schedule, which is precisely tenet №1's "one misunderstanding away
from feeling like loss." The 7-day ceiling is not "no forever"
doctrine; it is the daily paradigm's intuitive horizon.

The necessary modifications to the ladder, when paradigms build:

- **One ladder per paradigm, rungs intuitive at that tempo.** The
  existing 1h to 7d ladder is unchanged as the daily instance. An
  hourly ladder reaches shorter; a weekly or monthly ladder reaches
  longer (order of 2 weeks, 1 month, a quarter as its ceiling).
  Rungs stay a fixed legible set, never arbitrary durations, and
  ADR-0011's grace keeps its shape at every tempo (as a boundary
  snap, per that ADR's section 4, not as padding inside a rung).
- **"No forever" survives as the invariant that does generalize.**
  Every paradigm's ladder has a ceiling of roughly a few
  paradigm-units. What was wrong was reading the daily ceiling as
  the product's ceiling.
- **The click mechanics are per-ladder invariants.** Same rung
  count, same wrap, same five-clicks-to-the-cliff distance
  (`ttl.rs` tests this today), so the gesture's muscle memory
  survives a paradigm switch.
- **The default rung is paradigm-relative.** Each ladder names its
  own. This note said 8h ("a working day"); ADR-0011 section 3
  decided the default is the ladder's ceiling instead, so on the
  daily ladder it is 7d.
- **Switching paradigms rewrites no living page.** Tenet №1's
  "never by accident": existing pages keep the rung they were
  given; new pages take the new paradigm's default; a rung that is
  off the current ladder still displays honestly as the duration it
  is, because a rung is a duration on the page, and only the
  *click ladder* is paradigm-relative. This also keeps sync sound:
  devices on different paradigms exchange pages carrying plain
  durations, and ADR-0021's expiry-clock rules are untouched.
- **The artifact's contract scales, and must be checked, not
  assumed** (tenet №2). Nothing in the at-rest story (ADR-0012 key
  lifecycle, crypto erasure, refusal at next open) is
  duration-dependent in principle, but a month-long page holds its
  keys and, under ADR-0025, its history for a month; the op-log
  size budget is the named bound and gets measured against
  month-scale pages before a long ladder ships.

Where this graduated: ADR-0011, accepted 2026-09-01. The principle
landed as written (rungs are intuitive durations at the surface's
tempo; the current ladder is the daily instance). ADR-0011 also
settles two things this note left open by assumption: a link's TTL
does not follow the paradigm at all (section 5, following ADR-0026),
and the default rung is the ceiling rather than the 8h this note
named.

## Open questions, parked with the concept

- Whether **hourly** strains the one-page-per-unit shape: many small
  pages per day means more tab churn against the existing cap, and
  it may want the bucket anchored to now (rolling hours) rather than
  to clock hours.
- Whether the paradigm is one global setting or per-surface. The
  spec's existing toggle is global; start there.
- What the marker vocabulary is per paradigm (now / -1h / -2h,
  Today / -1d, this week / -1w), kept relative so labels stay true
  by construction.

## Status

Concept only. The daily paradigm is the shipped behavior and stays
the default. Open when vertical time tabs graduate from prototype
and a second tempo shows up in dogfood.
