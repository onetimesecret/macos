# ADR-0010: Form factors are sibling shell targets over the one core

- **Status:** accepted
- **Date:** 2026-07-16

## Context

Research into what macOS makes possible for ambient, non-focus-stealing
surfaces (docs/spec/feature/background-surface/research.md) confirmed
two things: the summoned non-activating panel — which the alpha-stage
CompanionApp already is — remains the right primary architecture, and
there is a second, genuinely different posture worth exploring: the
**desktop-canvas background surface** (the Plash/Übersicht model — a
window at desktop level, glanceable and passive, promoted to a floating
editor on demand).

We want that exploration without disturbing or destabilizing the panel
app, whose alpha behaviour we like. Three shapes were considered:

1. **A long-lived branch.** Free of risk to `main`, but the exploration
   rots out of sight, diverges from the core's seam, and never gets CI.
2. **Restructuring now** — extract the shared Swift (client wrapper,
   theme) into a `CompanionKit` library target both form factors import.
   The clean end state, but it rewrites the panel app's imports and
   build during its alpha, which is exactly the disturbance we ruled out
   — and it makes the exploration's cost of failure a revert across
   product code.
3. **A sibling executable target** in the existing Swift package: its
   own source directory, its own bundle id, its own bundle script,
   sharing only the Rust core through the already-multi-consumer C-ABI
   seam (`crates/ffi` → `CompanionCore.xcframework`).

The architecture already decided the hard part: ADR-0001 put every
secret-touching behaviour in the Rust core precisely so shells are thin
and replaceable. A form factor *is* a shell.

## Decision

Form factors live as sibling executable targets in `shell/`, each with
its own sources, tests, `Info.plist`, and bundle id, all linking the one
`CompanionCore` binary target. The panel app's sources are not modified
to host a sibling. While a sibling is an exploration, it may duplicate
the thin Swift it needs (a scoped seam wrapper, an accent colour) rather
than force a shared-library extraction; the duplication is the fee for
leaving alpha code untouched, and it is paid knowingly.

The first sibling is **CompanionBackdrop**
(`com.onetimesecret.companion.backdrop`), the background surface —
scoped by docs/spec/feature/background-surface/README.md.

An exploration target starts with strictly less authority than the
panel app: no persistence, no Keychain items, no network. Each of those
arrives only by an argued amendment to its feature spec.

## Consequences

- The panel app is untouched: no source edits, no import changes, no
  behaviour risk. Killing a failed exploration is `git rm -r` of one
  directory plus two Package.swift entries.
- Both form factors ride the existing CI shell lane for free —
  `swift build` / `swift test` cover the whole package — so the
  exploration cannot silently rot the way a branch would.
- Separate bundle ids keep the two apps separately addressable by TCC,
  capture pickers, and LaunchServices, and let both run at once during
  the exploration.
- We accept bounded duplication (~150 lines of seam wrapper today) and
  the risk it drifts. The bound is the point: the wrapper is a window
  onto the core, not logic — logic added to a shell twice belongs in
  the core once.
- Two running form factors are two core instances with two stores;
  they do not see each other's pages. Sharing live state across
  processes is deliberately unsolved here (see the feature spec's open
  questions) — any solution belongs core-side, never in shell code.

## Eject triggers

- **A sibling graduates from exploration to product** (gets persistence,
  promotion, or a release artifact): extract the shared `CompanionKit`
  library target then, as its own change, and both form factors move
  onto it together.
- **A third form factor appears**: three copies of the seam wrapper is
  two too many; same extraction, whatever the maturity.
- **The duplicated wrapper drifts** — a seam change lands in one copy
  and not the other and CI stays green: the duplication has become a
  trap rather than a fee, and the extraction stops being deferrable.
- **Users ask for the same pages in both form factors**: state sharing
  becomes a core-level design problem (single daemon process, or a
  shared sealed store with locking) and this ADR's
  two-instances-two-stores stance is superseded.
