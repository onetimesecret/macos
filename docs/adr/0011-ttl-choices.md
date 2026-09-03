---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0011: TTL rungs are intuitive durations at the surface's tempo

- **Status:** accepted
- **Date:** 2026-09-01

## Context

The countdown label on a live page is also its only time-to-live
(TTL) control: clicking it steps to the next rung of a fixed ladder
and resets the clock to that value (`crates/core/src/ttl.rs`). One
affordance replaces a preferences pane and a date picker. That design
puts all of the weight on the rung set, because the rungs are the
entire vocabulary a person has for saying how long something should
live.

Three things came due at once and forced the decision:

- **ADR-0026** (accepted) ejected the page's clock as an input to a
  concealed link's TTL and deferred the replacement default here.
  Issue #139 cannot start until this document names one.
- **The paradigms concept note**
  (`docs/spec/feature/vertical-time-tabs/2026-0828-paradigms.md`)
  argued that the ladder is not a universal set but the daily
  paradigm's instance of a general rule, and named this ADR as the
  home for that rule.
- **The draft contradicted the code.** The draft said the default is
  seven days; `DEFAULT_RUNG` is the 8h rung. The draft's durations
  (24h plus 8h, 72h plus 16h, 7d plus 1d) are on no rung of the
  shipped ladder. The module doc in `ttl.rs` says "a page opens at
  the top of the ladder", which agrees with the draft and not with
  the constant directly below it.

The original draft's substance, which survives: Backdrop's TTLs are
not the OTS set, and they are chosen to be understood rather than
computed. Eight hours is harder to hold in the head than one day.
One week is easy because a person can ask themselves a question with
a yes or no answer: will I still need this next week at this time.

## Decision

### 1. A rung is an intuitive duration at the surface's tempo

The rule the ladder is an instance of: every rung is a duration the
user can rationalize against their own schedule, drawn from a fixed
legible set, never an arbitrary number. What counts as legible is
tempo-relative, so the rung set belongs to the paradigm, not to the
product.

The shipped `1h, 3h, 8h, 24h, 3d, 7d` durations are the **daily
paradigm's** nominal rungs. This ADR does not change those six values;
it changes the default and defines how applying a rung may calculate a
deadline. Other paradigms, when they build, get their own ladders under
the same rule: an hourly ladder reaches shorter, a weekly or monthly
ladder reaches longer.

Three properties are per-ladder invariants, so every ladder preserves
the same gesture: the same rung count, the same wrap, and the same
distance from the default to the most precarious rung. Section 6 keeps
the mapping between ladders separate.

### 2. "No forever" is a per-ladder ceiling, not a seven-day rule

There is no unbounded rung on any ladder. The ceiling is roughly a
few units of that paradigm's tempo. Seven days is the daily ladder's
ceiling and was never the product's; reading it as the product's
would make a monthly-tempo page die against the user's schedule,
which is tenet 1's "one misunderstanding away from feeling like
loss".

### 3. The default rung is the ceiling

The default used when a new durable tab is created is the top of its
ladder: **seven days** on the daily ladder. A page opened in that tab
uses the rung stored by the tab. A replacement page in an existing
tab therefore keeps that tab's rung rather than consulting the global
default again, as required by ADR-0017. This resolves the
draft-versus-code contradiction in the draft's favor and against
`DEFAULT_RUNG` without assigning the rung to the page.

The click only shortens (`Ttl::shorter`, ADR ordering preserved). From
a 7d default, reaching the most precarious 1h rung takes five
deliberate clicks. From an 8h default it takes only two, and the third
click wraps back to 7d. Starting at the ceiling therefore makes every
shortening deliberate and keeps the wrap on the non-destructive
`1h → 7d` edge.

`ttl.rs` must change: `DEFAULT_RUNG` becomes `TTL_LADDER.len() - 1`,
its "open question №1" comment is answered by this section, and
`default_is_a_working_day` is renamed and rewritten against seven
days. Its module documentation must describe this as the default for
a new tab, not as a rule that every replacement page starts at the
top.

### 4. Grace is a boundary snap at creation, never a reprieve at expiry

The draft's padding (one day means 24h plus 8h, one week means 7d
plus 1d) is real intuition and is adopted, but not as padded rungs
and not as a forgiveness window after the deadline.

A rung names a nominal duration. Applying it at instant `applied_at`
calculates its deadline once:

1. `nominal = applied_at + rung_duration`.
2. Find the first boundary at or after `nominal` in the boundary
   schedule associated with the rung's paradigm.
3. Let `max_extension` be the smaller of the paradigm unit and the
   rung duration. Use the boundary only when
   `boundary - nominal <= max_extension`; otherwise use `nominal`.

For the daily paradigm, the unit is 24 elapsed hours. Rungs shorter
than 24h use whole local clock hours as their boundaries; the 24h, 3d
and 7d rungs use local midnight. Thus a 24h rung applied at 4pm has a
nominal deadline of 4pm the next day and snaps to the midnight ending
that next calendar day, an eight-hour extension. Weekends and holidays
receive no special treatment. The device's timezone at application
time supplies the calendar boundaries; a later timezone change does
not recalculate an existing deadline. Across daylight-saving changes,
the extension bound is measured as elapsed time, not by subtracting
wall-clock labels. Every future paradigm must define its unit and
boundary schedule before it can ship.

Two constraints make this honest rather than a lie about the clock:

- **Display and enforcement use the same deadline.** The page's
  remaining label and its expiry timer are both derived from the one
  stored deadline. `human_remaining` only formats the duration that
  deadline calculation supplies; testing the formatter alone does not
  establish this constraint.
- **Grace acts once, when the rung is applied.** It is part of
  computing the deadline, not a period during which an expired page is
  still readable. Nothing survives its displayed expiry by any margin.
  ADR-0016's current persistence, expiry and key-rotation contract is
  unchanged; ADR-0012 applies only where its Supersession section says
  it still stands.

The snap is a persisted setting, **enabled by default**, in the local
form factor's settings domain. Turning it off makes subsequently
applied rungs use `nominal` exactly. The setting is consulted when a
new page receives its tab's rung and whenever a rung gesture resets a
live page. Toggling it never recalculates a deadline that already
exists.

Rejected on the way here: padding the rungs themselves. A padded rung
has to be labelled, and both labels are bad. "1 day" while the clock
holds 32h is a lying label; "32h" is not a duration anyone
rationalizes, which forfeits section 1.

### 5. A link's default TTL is fixed and is not paradigm-relative

Per ADR-0026 a link's TTL is chosen as a link's TTL. When the person
does not choose one, the default is **exactly seven days**. An explicit
link TTL replaces that default.

It does not follow the paradigm. A paradigm is the sender's editing
tempo, and the recipient is on their own schedule and cannot see the
sender's setting. Letting an hourly note-taker's paradigm silently
shorten a recipient's window is the same error ADR-0026 ejected when
it removed the page clock: a fact about the sender's surface standing
in for a fact about the link.

The link default is therefore not a rung of any ladder. It is a
number this ADR names, and the ladder is a page concept. Section 4's
calendar-boundary snap and its local setting do not apply to links.

If the server begins reporting an allowed TTL set per ADR-0026's
second eject trigger, that list becomes authoritative. This ADR does
not choose whether an unavailable seven-day value should be rejected,
rounded up or rounded down. A follow-up decision must choose that rule
against the server's list; the app must not silently reuse either the
page ladder or section 4's boundary snap.

### 6. A paradigm switch never rewrites a live deadline

The daily paradigm is the only implementation today. A future
paradigm switch must not change any live page's deadline. Under
ADR-0017 the rung belongs to the durable tab, while the page owns the
clock and deadline. A new tab starts at the active paradigm's default;
a page opened in an existing tab starts from that tab's retained rung.

This ADR does not silently choose how an existing durable tab moves
from one paradigm's ladder to another. Before a second paradigm ships,
a follow-up decision must say whether that tab retains its original
ladder or maps its rung into the new ladder, and must define the first
click, the gauge denominator, persistence and sync behavior. The equal
rung count and click-distance invariants constrain that choice but do
not resolve it. No implementation may reinterpret a stored rung in a
way that changes a live deadline as a side effect of switching.

ADR-0021's sync rule is unchanged. Devices exchange an expiry policy
as `(anchor_wall_ms, ttl_ms)` and apply its never-extend minimum rule;
they do not exchange a paradigm or infer one from a rung.

## Consequences

- `crates/core/src/ttl.rs` changes per section 3: the default rung, its
  comment, module wording that predates durable tabs, and affected
  tests that pin 8h.
- The boundary snap of section 4 is new work with no code today. It
  needs calendar-aware daily boundary calculation, the elapsed-time
  bound, a persisted boolean setting defaulting to enabled, and one
  deadline path shared by display and enforcement. Tests cover the
  setting in both positions, exact boundaries, short rungs, weekends,
  timezone changes and both daylight-saving transitions.
- A snapped deadline honestly exceeds its rung's nominal duration, so
  the restore clamp of ADR-0016 bounds a persisted span by the rung's
  longest life, nominal plus the largest extension section 4 allows
  (`Ttl::longest_life` in `crates/core/src/ttl.rs`), rather than by
  the rung alone: eight days on the 7d rung, two hours on the 1h rung.
  The ladder's ceiling is unchanged, so ADR-0016's eject trigger on a
  ceiling above seven days is not tripped.
- #139 is unblocked. Its step 1 sources the conceal default from
  section 5's exact seven days instead of `sheet.remaining(now)`, and
  `ladder_snapped_ttl` loses its last caller.
- The paradigms note's ladder section is now a restatement of an
  accepted ADR rather than an argument against a draft. Its open
  questions include the durable-tab mapping required by section 6;
  no second paradigm may ship before that mapping is decided.
- Under ADR-0025 a long-ladder page holds its history for its actual
  lifetime, including any section 4 snap. The op-log size budget is
  the named bound and gets measured against month-scale pages before
  any ladder longer than the daily one ships (tenet 2: the artifact's
  contract scales, and must be checked rather than assumed).

## Eject triggers

- The server reports an allowed link-TTL set that excludes the seven-day
  default. The app needs a separately decided selection rule against that
  authoritative set; it must not reuse the page ladder.
- A proposed paradigm cannot preserve its legible nominal durations, equal
  rung count, wrap, and click-distance invariants without displaying a
  misleading duration. Reopen the ladder decision rather than ship a ladder
  whose labels misrepresent its deadlines.
- Hardware verification finds the displayed remaining time and the enforced
  expiry disagree across a timezone or daylight-saving transition. The one
  stored-deadline rule then needs to be re-examined before the boundary snap
  remains enabled by default.

## Decision history

- **2026-07-15:** Drafted as a page of notes and left in draft.
- **2026-09-01:** Accepted, resolving the draft-versus-code contradiction in
  the draft's favor.
- **2026-09-02:** Sections 3 and 4 implemented for the daily paradigm
  (issue #146): the default rung is the ceiling, the boundary snap
  calculates one stored deadline per application from the device zone
  at that moment, and the setting is a persisted shell preference,
  on by default, with a Settings toggle.
