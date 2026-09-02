# ADR-0011: TTL rungs are intuitive durations at the surface's tempo

- **Status:** accepted
- **Date:** 2026-07-15, decided 2026-09-01

## Context

The countdown label on a page is also its only TTL control: clicking
it steps to the next rung of a fixed ladder and resets the clock to
that value (`crates/core/src/ttl.rs`). One affordance replaces a
preferences pane and a date picker. That design puts all of the
weight on the rung set, because the rungs are the entire vocabulary a
person has for saying how long something should live.

This ADR sat in draft for six weeks as a page of notes. Three things
came due at once and forced it:

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

The shipped `1h, 3h, 8h, 24h, 3d, 7d` ladder is the **daily
paradigm's** instance and is unchanged by this ADR. Other paradigms,
when they build, get their own ladders under the same rule: an hourly
ladder reaches shorter, a weekly or monthly ladder reaches longer.

Three properties are per-ladder invariants, so the gesture survives a
paradigm switch: the same rung count, the same wrap, and the same
distance from the default to the most precarious rung.

### 2. "No forever" is a per-ladder ceiling, not a seven-day rule

There is no unbounded rung on any ladder. The ceiling is roughly a
few units of that paradigm's tempo. Seven days is the daily ladder's
ceiling and was never the product's; reading it as the product's
would make a monthly-tempo page die against the user's schedule,
which is tenet 1's "one misunderstanding away from feeling like
loss".

### 3. The default rung is the ceiling

A new page opens at the top of its ladder: **seven days** on the
daily ladder. This resolves the draft-versus-code contradiction in
the draft's favor and against `DEFAULT_RUNG`.

The click only shortens (`Ttl::shorter`, ADR ordering preserved), so
opening at the ceiling means the ladder's whole range is reachable by
tapering, and shortening a page's life is always the deliberate act.
Opening at 8h would make the top of the ladder the unconsidered
default in the other direction: the wheel would have to wrap upward
through five rungs to reach the value most staged content actually
wants.

`ttl.rs` must change: `DEFAULT_RUNG` becomes `TTL_LADDER.len() - 1`,
its "open question №1" comment is answered by this section, and
`default_is_a_working_day` is renamed and rewritten against seven
days. The module doc's "a page opens at the top of the ladder"
becomes true rather than aspirational.

### 4. Grace is a boundary snap at creation, never a reprieve at expiry

The draft's padding (one day means 24h plus 8h, one week means 7d
plus 1d) is real intuition and is adopted, but not as padded rungs
and not as a forgiveness window after the deadline.

A rung names a duration. When that duration is applied, the deadline
it produces is **snapped outward to the paradigm's next natural
boundary**, bounded by at most one paradigm unit of movement. On the
daily ladder a rung of 24h chosen at 4pm expires at the end of the
following working day rather than at 4pm sharp, which is the alarm
clock set for "tomorrow at 9:05" understanding that it means the 9:05
nine hours away.

Two constraints make this honest rather than a lie about the clock:

- **The displayed deadline is always the true deadline.** The page
  shows what `human_remaining` computes from the real expiry, snap
  included. Nothing displays a rung's nominal duration while the
  clock holds a different one.
- **Grace acts once, at the moment the rung is applied.** It is part
  of computing the deadline, not a period during which an expired
  page is still readable. Nothing survives its shown expiry by any
  margin, so forgetting stays visibly on schedule (tenet 1) and the
  at-rest contract (ADR-0012 key lifecycle, crypto erasure, refusal
  at next open) is untouched, because that contract only ever sees a
  deadline.

The snap is a setting, **enabled by default**. A person who wants a
rung to mean exactly its own duration turns it off, and every deadline
is then the plain arithmetic. Two people reading the same rung label
can hold different deadlines, which is acceptable precisely because
section 4's first constraint holds: each of them is shown their own
true deadline, so neither is reading a number that is false for them.
The setting is local, and like a paradigm it never rewrites a living
page: it is consulted when a rung is applied, so pages created before
a toggle keep the deadlines they were given.

Rejected on the way here: padding the rungs themselves. A padded rung
has to be labelled, and both labels are bad. "1 day" while the clock
holds 32h is a lying label; "32h" is not a duration anyone
rationalizes, which forfeits section 1.

### 5. A link's default TTL is fixed and is not paradigm-relative

Per ADR-0026 a link's TTL is chosen as a link's TTL. This ADR names
the default it is chosen from: **seven days**, a single fixed value,
plus whatever the person asked for at the moment of sharing.

It does not follow the paradigm. A paradigm is the sender's editing
tempo, and the recipient is on their own schedule and cannot see the
sender's setting. Letting an hourly note-taker's paradigm silently
shorten a recipient's window is the same error ADR-0026 ejected when
it removed the page clock: a fact about the sender's surface standing
in for a fact about the link.

The link default is therefore not a rung of any ladder. It is a
number this ADR names, and the ladder is a page concept.

If the server begins reporting an allowed TTL set per ADR-0026's
second eject trigger, that list is authoritative over this default,
and any snapping answers to the server's list rather than to
`TTL_LADDER`.

### 6. Switching paradigms rewrites no living page

Existing pages keep the rung they were given. New pages take the new
paradigm's default. A page holding a duration that is off the current
ladder still displays honestly as the duration it is, because what a
page stores is a deadline and only the *click ladder* is
paradigm-relative. Devices on different paradigms exchange pages
carrying plain durations, so ADR-0021's expiry-clock rules are
untouched.

## Consequences

- `crates/core/src/ttl.rs` changes per section 3: the default rung,
  its comment, and the two tests that pin 8h.
- The boundary snap of section 4 is new work with no code today. It
  needs a paradigm-boundary function (end of the working day for the
  daily paradigm), the bound of at most one unit, a persisted boolean
  setting defaulting to enabled, and tests that the displayed
  remaining time and the enforced expiry are the same number with the
  setting in either position.
- #139 is unblocked. Its step 1 sources the conceal default from
  section 5's seven days instead of `sheet.remaining(now)`, and
  `ladder_snapped_ttl` loses its last caller.
- The paradigms note's ladder section is now a restatement of an
  accepted ADR rather than an argument against a draft. Its open
  questions (whether hourly strains the one-page-per-unit shape,
  global versus per-surface, marker vocabulary) stay parked there and
  are not settled here.
- Section 4's boundary snap gives the daily ladder's short rungs a
  wrinkle worth measuring in dogfood: a 1h rung snapped to a working
  day boundary would move by more than its own length, so the bound
  in section 4 is one paradigm unit *or* the rung's own duration,
  whichever is smaller. Rungs shorter than the paradigm's unit snap
  to the nearest sub-boundary or not at all.
- Under ADR-0025 a long-ladder page holds its history for the length
  of its rung. The op-log size budget is the named bound and gets
  measured against month-scale pages before any ladder longer than
  the daily one ships (tenet 2: the artifact's contract scales, and
  must be checked rather than assumed).
