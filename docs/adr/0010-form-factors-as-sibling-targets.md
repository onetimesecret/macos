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
arrives only by an argued amendment to its feature spec. (Persistence
and its Keychain item arrived that way on 2026-07-25; the network has
not.)

## Consequences

- The panel app is untouched: no source edits, no import changes, no
  behaviour risk. Killing a failed exploration is `git rm -r` of one
  directory plus two Package.swift entries.
  **Held until 2026-07-25, then spent as designed.** The parity
  amendment moved the panel's model and views into `CompanionKit`, so
  the panel's sources did change: this consequence bought an
  exploration the room to fail cheaply, and it lasted exactly as long
  as the exploration did. What survives it is the shape underneath:
  each form factor still owns its window, its posture, its bundle id,
  its Keychain service and its state file, and killing one is still
  deleting one directory.
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
  **Fired 2026-07-25.** CompanionBackdrop gained persistence (argued in
  docs/spec/feature/background-surface/README.md, "The persistence
  amendment"), so the wrapper moved to a `CompanionKit` target and both
  form factors depend on it. The two-instances-two-stores stance below
  survives the graduation intact: the backdrop seals to its own file
  under its own Keychain service, reached through
  `companion_new_scoped`, and neither app reads the other's.
  **Fired again the same day, wider.** The parity amendment gave the
  backdrop tabs, chips, the ledger and promotion, which would have put
  roughly eighteen hundred lines of secret-touching view code in both
  targets. So the extraction went past the wrapper: the page model
  (`PageModel`) and every form-factor-neutral view moved to
  `CompanionKit` as well, and what varies became a value the shared
  model reads (`FormFactor`: Keychain service, state directory, log
  subsystem, opening rung). The bound in the consequences below was
  "~150 lines of seam wrapper"; parity made the duplication an order of
  magnitude larger and pointed at sealed content, which is the case the
  bound existed to catch. Each target now holds only its window and its
  posture: the delegate, the window controller, the root view, and for
  the backdrop the stance and the card's geometry.
- **A third form factor appears**: three copies of the seam wrapper is
  two too many; same extraction, whatever the maturity.
- **The duplicated wrapper drifts** — a seam change lands in one copy
  and not the other and CI stays green: the duplication has become a
  trap rather than a fee, and the extraction stops being deferrable.
- **Users ask for the same pages in both form factors**: state sharing
  becomes a core-level design problem (single daemon process, or a
  shared sealed store with locking) and this ADR's
  two-instances-two-stores stance is superseded.

## Amendment 1: two apps, not one app with two windows (2026-07-25)

The decision above argues why the second form factor arrived as a
sibling target rather than a branch or a restructuring. It never states
why two postures should keep shipping as two apps now that both are
products, and "one app owning both windows" is the consolidation an
outside reader would reach for. The answer was implicit in the
consequences; this amendment states it once.

A posture is made of per-app properties, and the two postures need
opposite values for each of them:

- **Activation policy is per process.** The panel is an accessory
  app: no Dock icon, no ⌘Tab card, invisible between uses. The
  backdrop is a regular app: Dock icon, ⌘Tab membership, activation as
  a summon route. One process holds one policy at a time. A merged app
  would either flip the policy at runtime as one window or the other
  came forward, making both postures intermittent, or freeze one
  posture out entirely.
- **The permission system addresses bundle ids.** TCC grants, per-app
  capture pickers, and Automation consents accrue to the app, not the
  window. A merged app pools the two surfaces' authority into one
  grant the user cannot inspect or revoke separately. (Capture
  exclusion itself is per window and would survive a merge; the
  separate addressability would not.)
- **Launch stories differ.** The backdrop exists by being at the
  desktop from login; the panel is summoned when wanted. Launch at
  login is a per-app choice, so a merged app imposes one story on both
  surfaces.
- **Lifecycles are independent.** Each app quits, crashes, and updates
  alone: the dogfood channel replaces one while the other keeps
  running, and each runs its own quit-time persistence snapshot. The
  two-instances-two-stores stance (own Keychain service, own state
  file) is enforced by process identity rather than by discipline
  inside a shared process.

The consolidation would also buy almost nothing. After the CompanionKit
extraction each target holds only its window and its posture, so a
merge would deduplicate exactly the part that is genuinely different.
And if state sharing ever fires the last eject trigger above, the
likely answer is still two shells over a core-side store or daemon, not
one app.
