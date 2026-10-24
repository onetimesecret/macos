# docs/spec/design/README.md
---

# macOS Companion — Design Spec

An open-source, Rust-based macOS desktop companion to Onetime Secret.
Working title: **CompanionApp** (see naming note below).

This directory holds the milestone-1 design and later dated decision
records. The milestone-1 interaction model reached **revision C**, with a
working HTML prototype alongside. Later records below amend parts of that
design; the original documents are not a consolidated current specification.

## Reading historical security claims

**Publication clarification, 2026-10-14:** the foundational documents retain
historical proposals and amendments. Their disappearance, memory-only,
non-reading, capture, and runtime-hardening assertions are not a statement
of validated current product guarantees.

- **Persistence and disappearance.** Accepted
  [ADR-0016, Decision](../../adr/0016-content-persists-across-restart.md#decision)
  states:

  > Unexpired staged content survives ordinary process termination, crash, force
  > termination, logout, restart, shutdown, and compatible app updates.

  Its [Consequences](../../adr/0016-content-persists-across-restart.md#consequences)
  also state:

  > A copied ciphertext plus both copied halves can remain decryptable after the
  > live app rotates its copies. APFS snapshots and rollback of an older authentic
  > state file remain accepted residual exposures.

  Earlier memory-only, quit-amnesia, and universal-disappearance language
  must not be read as the accepted persistence model or an erasure guarantee.
- **Excerpts and non-reading.** Accepted
  [Law 0001](../../law/0001-sealed-object.md#why-this-rule) states:

  > the shell never receives the sealed
  > payload from the core. It may hold visible ink before sealing, and the
  > policy-approved mechanical excerpt and the object's name and note
  > afterward.

  Earlier claims that content is never read or rendered are design shorthand,
  not literal claims that no content-derived characters reach the UI.
- **Capture and runtime hardening.** Naming `sharingType = .none`, locked
  memory, or Hardened Runtime does not validate universal screenshot
  prevention, absence of residual copies, or immunity to privileged memory
  access. Absolute guarantees of that kind are unsupported by this collection.
- **Relay retention and destinations.** The foundational no-retention wording
  must not be read as proof of server-side deletion. Accepted
  [ADR-0021, Eject triggers](../../adr/0021-multi-device-sync-over-a-blind-relay.md#eject-triggers)
  explicitly lists:

  > The design starts relying on server-side deletion rather than key rotation for
  > confidentiality.

  The technical survey's fixed destination count also coexists with a release-feed
  check. It is not a verified inventory of current network traffic.
  The accepted [October 16 UI/UX successor](2026-1016-ui-ux-decisions.md#d-09--concealment-and-separately-authorized-resources)
  replaces D-09's app-wide action count, and
  [ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md)
  adds a separate image-resource route. This is policy authority, not proof of
  implemented request isolation or approval of unresolved feedback/release routes.

These qualifications document limits and point to accepted decisions; they
are not implementation tests or new security guarantees.

## Milestone-1 summary

A menu-bar-resident staging area for content in transition. Summoning the
non-activating window shows a **sheet** — a little text file of visible
**ink** and opaque **sealed chips**. Typing and ⌘V land as ink; a
deliberate gesture (⇧⌘V, a drop, or ⌘↩ on a selection) seals content into
a chip whose bytes never render. One countdown governs each sheet — like
a CPU's L1/L2 cache, the value is in being small, close, and evicted by
policy, never in being a system of record. Zero means zeroized, silently.
Secondarily, a chip or a whole page can be concealed into a Onetime Secret
link (v3 API) when the content needs to travel to another person or
machine.

## Foundational design: reading order

Design Markdown filenames use `YYYY-MMDD-subject.md`. The seven foundational
documents use `2026-0707`, their first-added date in Git history, not an
acceptance or last-revised date. Their former `01`–`07` prefixes expressed
only the reading order preserved below. Statuses in this table describe the
milestone-1 documents; consult the later decision records for amendments.

| Doc | Contents | Original status |
| --- | --- | --- |
| [2026-0707-problem-space.md](2026-0707-problem-space.md) | Restatement of the problem, the cache analogy taken seriously, anti-goals | **Core deliverable** |
| [2026-0707-overlooked-opportunities.md](2026-0707-overlooked-opportunities.md) | Landscape of neighbouring apps and the gaps they leave | **Core deliverable** |
| [2026-0707-design-principles.md](2026-0707-design-principles.md) | The principles that follow from the problem space and overlooked opportunities | Binding within scope, with recorded amendments including October 16's preview/resource exception |
| [2026-0707-interaction-model.md](2026-0707-interaction-model.md) | Sheets, ink and sealed chips, the window, tabs, the ledger, the keyboard map | **Revision C** — consolidates design rounds v7–v10 and the 12 Jul 2026 decision rounds |
| [2026-0707-technical-direction.md](2026-0707-technical-direction.md) | Rust framework survey, v3 API integration, security posture, a11y | Supporting — draft, amended by rev C |
| [2026-0707-open-questions.md](2026-0707-open-questions.md) | Everything unresolved, honestly | Supporting — updated for rev C |
| [2026-0707-repo-skeleton.md](2026-0707-repo-skeleton.md) | Prescription for initializing the app repository | Executed |

## Accepted dated decisions

These records carry `status: accepted`. Follow their amendment links;
acceptance does not mean every original passage remains unchanged.

| Record | Scope | Relationship |
| --- | --- | --- |
| [2026-1016-ui-ux-decisions.md](2026-1016-ui-ux-decisions.md) | Background-surface decisions with explicit preview resources, scoped D-09 and source/preview distinction | Supersedes the September 15 record in full by explicit incorporation with intervening accepted amendments |
| [2026-0916-clipboard-clear-interval.md](2026-0916-clipboard-clear-interval.md) | General-pasteboard clear interval and incorporated navigator/capsule decisions | Supersedes the stream-navigator record in full, incorporating D-34–D-41 and amending D-42–D-43 |
| [2026-0916-rail-redundancy.md](2026-0916-rail-redundancy.md) | Rail marks, timestamps, gutters, and derived titles | Amends the preceding records; carries later amendment links |

## Draft proposals

| Record | Scope | Status |
| --- | --- | --- |
| [2026-0930-file-conflict-locate.md](2026-0930-file-conflict-locate.md) | Locate actions, unavailable-file banners, and held-file wording | Draft; not an accepted amendment to D-17 |

## Agreed feature plans

These plans record agreed scope, not delivered behavior. Technical details
and open decisions remain subject to review.

| Plan | Scope | Status |
| --- | --- | --- |
| [2026-1016-markdown-dialects-and-preview.md](2026-1016-markdown-dialects-and-preview.md) | CommonMark/GFM setting, restricted HTML, and click-to-load remote images | Scope and R0 policy reconciliation accepted; technical plan draft, R1–R6 remain open |

## Superseded decision history

| Record | Successor |
| --- | --- |
| [2026-0914-ui-ux-decisions.md](2026-0914-ui-ux-decisions.md) | [September 15 UI/UX decisions](2026-0915-ui-ux-decisions.md), in turn superseded by the October 16 record |
| [2026-0915-ui-ux-decisions.md](2026-0915-ui-ux-decisions.md) | [October 16 UI/UX decisions](2026-1016-ui-ux-decisions.md), with surviving provisions incorporated by reference |
| [2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) | [September 16 clear-interval record](2026-0916-clipboard-clear-interval.md), which incorporates its navigator/capsule decisions |

The [rail wireframe](2026-0916-rail-redundancy-wireframe.svg) accompanies
the rail-redundancy record. The illustrated
[UI/UX decision record](UI-UX%20Decision%20Record%20-%20Sealed%20Content.html)
accompanies the UI/UX Markdown records; consult the dated records for status
and amendments.

## Feature specifications

Specifications for individual features live under
[`docs/spec/feature/`](../feature/):

| Feature | Contents | Status |
| --- | --- | --- |
| [feature/byoe](../feature/byoe/README.md) | Bring Your Own Encryption on the conceal path: envelope construction, key custody, wire changes | Draft |
| [feature/background-surface](../feature/background-surface/README.md) | A second form factor: an ambient desktop-level surface, raised to edit — with the research on what macOS permits | Exploration (ADR-0010) |

## Design rounds and prototype

The interaction model's revisions live as rendered documents in
[`docs/archive/airlock-prototype/`](../../archive/airlock-prototype/):

- `Airlock Spec.dc.html` — **rev C**, the milestone-1 interaction
  model; [Interaction model](2026-0707-interaction-model.md) is its markdown consolidation (including the rev B
  material it references).
- `Airlock Prototype.dc.html` — interactive HTML prototype implementing
  rev C against a real clipboard (excerpt rule, sealing gestures, tabs,
  pause, ledger, markdown headings; capture exclusion and zeroization
  simulated, as the medium requires).
- `Airlock Panel v7` … `Airlock Sheet v10` — the design rounds that got
  there, kept for the arguments, not the conclusions.

## Naming note

**CompanionApp** is a deliberately generic working title. It replaced
the earlier working title **Airlock** — a small chamber between two
environments that things pass through but never live in, which is the
product in one image — because that name collides with at least one
existing security vendor (Airlock Digital) and would not survive to
release without a trademark check. The old name remains only in the
design-history documents under
[`docs/archive/airlock-prototype/`](../../archive/airlock-prototype/).
Alternatives considered: Layover, Vestibule, Foyer, Waypoint, Holdover.
The name matters less than the metaphor; every candidate is a word for
*a place you pass through*. (Rev B retired the earlier "SleeperCell"
name for staged items along with the cell model itself; the units are
now sheets and sealed chips.)

## Relationship to the web application

The companion is open source and standalone-useful: the core loop (type
or paste, hold briefly, copy out, forget) requires no account and no
network. The Onetime Secret v3 API appears only at the conceal step,
turning local ephemeral content into a one-time link. Authentication
starts with HTTP Basic (organization `extid` + API token pair) and
migrates to PASETO when the v3 auth work lands. See
[2026-0707-technical-direction.md](2026-0707-technical-direction.md).
