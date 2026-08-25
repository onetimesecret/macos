# docs/spec/design/README.md
---

# macOS Companion — Design Spec

An open-source, Rust-based macOS desktop companion to Onetime Secret.
Working title: **CompanionApp** (see naming note below).

This is a *design* spec, produced ahead of implementation. Milestone 1
restated the problem space and mapped the opportunities neighbouring
applications overlook; the interaction model has since been through three
revisions of design rounds and is now at **revision C** (doc 04), with a
working HTML prototype alongside.

## One-paragraph summary

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

## Reading order

| Doc | Contents | Status |
| --- | --- | --- |
| [01-problem-space.md](01-problem-space.md) | Restatement of the problem, the cache analogy taken seriously, anti-goals | **Core deliverable** |
| [02-overlooked-opportunities.md](02-overlooked-opportunities.md) | Landscape of neighbouring apps and the gaps they leave | **Core deliverable** |
| [03-design-principles.md](03-design-principles.md) | The principles that fall out of 01 + 02 | Binding, as amended by rev C |
| [04-interaction-model.md](04-interaction-model.md) | Sheets, ink and sealed chips, the window, tabs, the ledger, the keyboard map | **Revision C** — consolidates design rounds v7–v10 and the 12 Jul 2026 decision rounds |
| [05-technical-direction.md](05-technical-direction.md) | Rust framework survey, v3 API integration, security posture, a11y | Supporting — draft, amended by rev C |
| [06-open-questions.md](06-open-questions.md) | Everything unresolved, honestly | Supporting — updated for rev C |
| [07-repo-skeleton.md](07-repo-skeleton.md) | Prescription for initializing the app repository | Executed |

## Feature specifications

The documents above are the standing *design* spec. Specifications for
individual features, written against it, live under
[`docs/spec/feature/`](../feature/):

| Feature | Contents | Status |
| --- | --- | --- |
| [feature/byoe](../feature/byoe/README.md) | Bring Your Own Encryption on the conceal path: envelope construction, key custody, wire changes | Draft |
| [feature/background-surface](../feature/background-surface/README.md) | A second form factor: an ambient desktop-level surface, raised to edit — with the research on what macOS permits | Exploration (ADR-0010) |

## Design rounds and prototype

The interaction model's revisions live as rendered documents in
[`docs/Airlock Prototype/`](../../Airlock%20Prototype/):

- `Airlock Spec.dc.html` — **rev C**, the authoritative interaction
  model; doc 04 is its markdown consolidation (including the rev B
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
design-history documents under [`docs/Airlock Prototype/`](../../Airlock%20Prototype/).
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
[05-technical-direction.md](05-technical-direction.md).
