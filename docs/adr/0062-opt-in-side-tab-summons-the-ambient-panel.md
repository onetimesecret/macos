---
documentation_status: needs-review
---

# ADR-0062: An opt-in side tab summons the ambient panel

- **Status:** accepted
- **Date:** 2026-11-03
- **Supersedes in part:** [ADR-0015](0015-resting-backdrop-is-mouse-transparent.md), only its enumeration of summon routes
- **Depends on:** [ADR-0036](0036-editing-presentations-are-mutually-exclusive.md), [ADR-0059](0059-appkit-owns-window-presentation.md)

## Context

The maintainer requested an opt-in side tab with direct click-to-open and
deferred hover expansion. The [reveal research](../spec/design/2026-1013-ambient-panel-reveal-research.md)
and [Reveal Lab](../../tools/reveal-lab/README.md) explore broader gestures;
neither establishes a measured best gesture.

ADR-0015 states: "Raising is never a click on the resting card." Its
mouse-transparent resting window remains distinct from the new tab.
ADR-0036 states: "Show at most one content presentation at a time".
ADR-0059 states: "Ordinary activation creates no editor and does not change
the selected presentation or anchor."

## Decision

Offer a separate, small side tab that is disabled by default. One click summons
the ambient panel through an explicit activation route, with the same Today
anchor as the existing card-click summon. Hover does not expand the tab.

- General Settings selects a display, left or right edge, and vertical position.
  Remember the choice with the local window preferences, using a display UUID.
  A disconnected selection produces no tab on another display.
- Place the entire tab on an exposed edge within AppKit's visible frame and away
  from corners. Reject a side inset by that frame, an overlap with another
  display, or a partial seam.
- Show it only with the ambient panel enabled, resting, unpinned, and owning
  the page, while the primary editor is closed. Suppress it during the app's
  menus and sheets, session suspension, and reported fullscreen presentation.
- The tab is a nonactivating panel that refuses key and main status. Its input
  rectangle matches its visible bounds. Recheck eligibility and placement on
  the explicit click before dispatching the summon.
- The tab contains an inward chevron and an accessible Open ambient panel
  action. It contains no page preview or editor. The existing keyboard and
  menu summon routes remain available.

This extends the summon-route list in ADR-0015. It does not change that
record's resting-window mouse behavior, or ADR-0036's content presentation
selection. Hover cards, invisible edge dwell, corner triggers, and drag/drop
remain outside this decision.

## Consequences

A visible target provides direct pointer access without a dwell threshold.
It occupies a small input region above ordinary windows, so placement can
compete with scrollbars or window controls. The opt-in setting and explicit
placement let the person choose whether that cost is useful.

Suppressing the tab while the primary editor is open, including minimized,
keeps the initial interaction specific to the resting ambient panel. A
selected edge may be unavailable until its placement or display arrangement
changes. Fullscreen, Spaces, Stage Manager, and external typing behavior need
platform execution checks; this record is not a verification report.

Dock exclusion uses [NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe).
The implementation rejects a side inset from the physical edge; it does not
query Dock orientation or auto-hide preferences. If an auto-hidden Dock's
reveal area is absent from that inset, a conflict is possible. Check both side
placements with Dock auto-hide enabled before release. This interaction has
not been validated on a physical desktop.

## Eject triggers

- Maintainer use finds repeated accidental tab clicks during ordinary window
  interaction: revisit target dimensions and placement before enabling it
  by default.
- The tab appears at an unintended display edge after a topology change:
  repair display selection and placement before expanding the interaction.
- A later request requires a preview or hover expansion: make a separate
  decision about reveal states and click delivery.

## Decision history

- 2026-11-03: Accepted from the maintainer's explicit implementation request;
  hover expansion deferred.
