# ADR-0008: Success is never judged by engagement metrics

- **Status:** proposed
- **Date:** 2026-07-15

## Context

The spec commits the app to being non-sticky and telemetry-free. Doc 01
lists "not sticky" among the anti-goals (no streaks, no counters,
comfortable being forgotten between uses) and names the honest success
metric: seconds of user attention consumed per transfer, minimized. Doc
03 declines analytics outright ("No telemetry, period") and declines
engagement features by default. Doc 02 makes the absence of telemetry
part of the trust story: "it forgets" is auditable partly because
nothing phones home.

Those commitments have a delayed cost that nothing yet governs: the app
will look dead by every standard metric. There is no client-side data
at all, and even if there were, a perfect session is drop, glance,
copy, forget. Daily actives, retention curves, session length, and
feature-usage frequency would all read as failure at exactly the moment
the app is working as designed.

The precedent is Opera Notes. Opera dropped its built-in Notes feature
in the Presto-to-Blink rewrite, citing usage statistics its own users
called flawed. A small constituency used Notes intensely in bursts, and
burst use is invisible to averages, so the feature was rationally
killed on the numbers. Vivaldi, founded by ex-Opera people, rebuilt
Notes as a core feature for exactly that constituency. The lesson:
engagement metrics structurally undervalue burst-use tools, and a kill
decision made on those metrics looks rational at the time it is made.

CompanionApp is maximally exposed to this failure mode, by design.
Unless the measurement policy is written down now, some future
evaluation, made in good faith with standard metrics, reaches the Opera
conclusion.

## Decision

The app's success is never judged by engagement or retention numbers.
Concretely:

1. **Engagement metrics are inadmissible as evidence**, in either
   direction. Daily or monthly actives, session counts, session length,
   retention cohorts, and feature-usage frequency are not inputs to
   keep, kill, or invest decisions about this app, because the design
   guarantees they read as failure.
2. **The one clean quantitative signal is server-side promotion counts
   attributable to the client**, once the v3 promotion call carries a
   client identifier (it does not today; see Consequences). It is a
   floor, not a measure: it counts exits, not dwell. Every session that ends without a promotion, which the spec
   treats as a normal successful session, is invisible to it, and so is
   every promotion to a self-hosted instance.
3. **The measurement gap is never closed with telemetry.** Not knowing
   how the app is used is a purchased property (doc 02, section 5; doc
   03, principle 4), not a bug to fix. Proposals for "just anonymous
   counts" are declined under this ADR, not re-litigated per feature.
4. **Qualitative evidence carries the rest.** Issue and discussion
   activity, direct user reports, and download counts as a coarse
   ceiling. Deprecation decisions require actually asking users, not
   reading a dashboard, because no dashboard exists.

## Consequences

- Roadmap decisions are made with weak quantitative evidence, accepted
  up front. No A/B tests, no funnels, no per-feature usage data. The
  spec's design principles and doc 06's open questions do the work that
  analytics would do elsewhere.
- The promotion count needs attribution plumbing that does not exist
  yet: the client sends no identifier today (`crates/ffi`), and the
  server must count by it. Until both land, there is no quantitative
  signal at all. Even after, it needs honest interpretation: it can
  prove the app is alive, it can never prove the app is dead.
- The app's continued existence must be periodically defended with an
  argument rather than a chart. This ADR is that argument's standing
  first line: looking dead on standard metrics is the designed outcome
  of the anti-goals, not evidence about usage.
- The no-telemetry trust claim stays clean, which keeps ADR-0007's
  positioning intact: the security properties remain things a reader
  can check.

## Eject triggers

- Promotion attribution stops working: the API stops distinguishing
  clients, or self-hosted routing grows to where the counts are no
  longer representative. The decision then needs a replacement signal,
  chosen under the same constraint, never retention.
- A keep-or-kill decision about the app is actually on the table and no
  qualitative evidence exists to decide it with. That is the scenario
  this ADR exists for; if the qualitative channels are empty when it
  arrives, the policy failed and gets redesigned, still without
  telemetry.
- Usage or retention numbers get cited in a decision about this app.
  That is a violation of this decision, not a drift to accommodate.
