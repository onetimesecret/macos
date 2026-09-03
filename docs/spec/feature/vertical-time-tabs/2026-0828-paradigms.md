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

## Why re-bucketing is architecturally cheap

ADR-0020's projection is the cheap part: a unit of time is a query
over the pages' own birth stamps, computed on every read and stored
nowhere. Changing the time-tab buckets therefore requires no page
data migration and does not rewrite a page.

Paradigm-specific TTL ladders are separate work and are not free.
ADR-0017 stores the rung on a durable tab, so a second paradigm needs
the tab-mapping, persistence, gauge and click decisions that ADR-0011
section 6 deliberately leaves for that implementation. Re-bucketing
can ship only after those choices preserve every live deadline.

## The TTL ladder is the daily paradigm's instance
(updated 2026-08-29 after re-reading `docs/tenets.md`;
graduated 2026-09-01 into ADR-0011, accepted)

**This section has graduated.** ADR-0011 is now accepted and carries
the rule (section 1), the per-ladder ceiling (section 2), the default
rung (section 3), grace (section 4) and the live-deadline invariant
(section 6). What follows is the argument that got it there, kept for
its reasoning. Where the two differ, the ADR governs. In particular,
the default for a new durable tab is the ceiling rather than 8h,
grace is a bounded boundary snap under a setting rather than padding
inside a rung, and mapping an existing tab to another ladder remains
future work.

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
  (`ttl.rs` tests this today), so each ladder preserves the gesture.
  How an existing tab moves between ladders remains open below.
- **The default rung is paradigm-relative.** Each ladder names the
  default assigned to a new durable tab. This note said 8h ("a
  working day"); ADR-0011 section 3 decided that default is the
  ladder's ceiling, so on the daily ladder it is 7d. A replacement
  page in an existing tab uses that tab's retained rung, per
  ADR-0017.
- **Switching paradigms rewrites no live deadline.** The page owns its
  clock and deadline; the durable tab owns its rung. ADR-0011 section
  6 preserves the live deadline but deliberately leaves the existing
  tab's ladder mapping to the work that introduces a second paradigm.
  Sync remains sound because devices exchange ADR-0021's
  `(anchor_wall_ms, ttl_ms)` expiry policy and apply its never-extend
  minimum rule; they do not exchange or infer a paradigm.
- **The artifact's contract scales, and must be checked, not
  assumed** (tenet №2). Nothing in ADR-0016's current persistence,
  expiry and key-rotation story is duration-dependent in principle,
  but a month-long page holds its keys and, under ADR-0025, its
  history for its actual lifetime; the op-log size budget is the
  named bound and gets measured against month-scale pages before a
  long ladder ships.

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
- How a durable tab's stored rung moves between ladders: retain the
  originating ladder or map into the new one, including the first
  click, gauge denominator, persistence and sync behavior. ADR-0011
  section 6 requires that either answer leave a live deadline alone.

## Status

Concept only. The daily paradigm is the shipped behavior and stays
the default. Open when vertical time tabs graduate from prototype
and a second tempo shows up in dogfood.
