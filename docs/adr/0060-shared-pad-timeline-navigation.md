---
documentation_status: needs-review
---

# ADR-0060: Shared pad timeline navigation

- **Status:** accepted
- **Date:** 2026-10-03

## Context

The maintainer approved multiple pads and requested three implementation steps:
consolidate the sidebar around the existing navigator; fix ordering and drag
invalidation; then add density handling and per-pad reading-position restoration.
The requested verification covers both sort directions, long pages, many
checkpoints, minimum window height, pad switching, and File/Ledger views.

The accepted background-surface
[UI/UX decisions](../spec/design/2026-0915-ui-ux-decisions.md) state:
“Slots are pages you name and close yourself; days group live pages by the day
they were written, newest first, and move no content.” This successor replaces
only the fixed newest-first ordering requirement for Timeline. It leaves page
lifetimes and grouping by local creation day outside the decision's scope.
The accepted [rail redundancy decision](../spec/design/2026-0916-rail-redundancy.md)
states: “One dot. The active node is a filled ember dot, the one dot on the
rail; every other page is a quaternary tick across the track, wider for a day's
first page”. Density handling preserves that selected-node distinction while
allowing checkpoint labels to move into a separate scrollable list.

## Decision

Use one timeline navigator for the active pad in both single-pad and multi-pad
presentations. The existing roll geometry supplies the minimap, viewport band,
and scrubber. The pad picker selects the document context; it does not create a
second timeline rendering path. Preserve the shared Page layout setting from
[ADR-0037](0037-one-page-layout-setting.md).

- Day order is selectable newest-first or oldest-first. Checkpoint order within
  each day is independently selectable in both directions. The roll and sidebar
  use the same ordered projection. Empty-day gaps and the live/retained boundary
  follow the selected order rather than assuming newest-first.
- The navigator has a bounded viewport. Keep sorting and pad controls outside
  scrub gesture capture. Cancel an in-progress drag when the active pad, order,
  document geometry revision, or presentation ownership changes. A later drag
  captures the current mapping.
- When labels cannot fit, retain a full-document minimap and compact checkpoint
  marks, and provide a separately scrollable checkpoint list. Selecting or
  revealing the active checkpoint must remain possible at minimum window height
  and with many checkpoints. Keep checkpoint actions accessible to keyboard and
  assistive technology.
- Remember each pad's reading position transiently for the running session,
  using a page identity and semantic scroll anchor rather than raw document
  pixels. On switching back, restore the remembered anchor if it still resolves;
  otherwise use the pad's available selected page or Today position. Preserve
  the visible page and anchor through a sort change where possible. This is an
  interaction requirement, not a new durable storage policy or a promise to
  restore the position after relaunch.
- File and Ledger views do not expose an active timeline position. Hide or
  disable minimap scrolling there and preserve the pad's last timeline anchor
  for its next timeline visit. Only the presentation that owns the roll can
  drive its scroll state.

## Consequences

A pad change changes the navigator's data and captured scroll mapping, while
one component maintains the timeline interaction. Dense pages trade simultaneous
checkpoint labels for a navigable list; the minimap remains available for long
page orientation. Sorting must be tested independently of date grouping, and
restoration must tolerate absent or unmeasured page geometry.

This record accepts the requested design. It is not evidence that the current
implementation, accessibility behavior, or verification matrix meets it. It
introduces no new catalog persistence, association routing, security, or privacy
guarantee; ADR-0039's remaining review conditions still apply.

## Eject triggers

- At minimum window height, dense checkpoint labels overlap controls or a
  checkpoint cannot be selected. Revisit the density threshold or list layout.
- A pad or sort switch during scrubbing scrolls through the previous mapping.
  Repair invalidation before shipping that interaction.
- Returning to a pad repeatedly moves the reader to a different page despite a
  resolvable anchor. Revisit anchor capture and restoration.
- File or Ledger navigation changes an unrelated pad's timeline position.
  Revisit the timeline ownership boundary.

## Decision history

- 2026-10-03: Accepted from the maintainer's explicit implementation instruction.
  This is the scoped successor to fixed newest-first Timeline ordering and
  extends the rail's density presentation while retaining its active mark rule.
