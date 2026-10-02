---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0037: One page layout setting, Tabs or Timeline

- **Status:** accepted
- **Date:** 2026-10-01

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

D-26 in the accepted
[UI/UX decision record](../spec/design/2026-0915-ui-ux-decisions.md)
split page navigation into two settings, Organize pages by (Slots ·
Days) and Show pages (Along the bottom · Down the side), and section 4
says "All four combinations are supported states." D-26 names the
defect it replaced: "The single switch that flips grouping and
orientation together is the defect this replaces: it pushed code names
into user-facing copy and left one axis unreachable." Issue 171 shipped
the split.

c1f4aca went back to one switch without a record. Settings now offers
one picker, Page layout: Tabs or Timeline. `showsPagesDownSide` is
computed from `showsTimeUnits`, and a stored `showsPagesDownSide` is
removed at launch. Slots down the side and Days along the bottom can no
longer be reached. `SlotRailView` and `TimeStripView` still compile, but
no layout draws them.

Section 4 gave only two of the four combinations a role: "Slots,
bottom: the spreadsheet idiom, today's shipping default" and "Days,
side: chronology is vertical, and the intended default."

## Decision

Offer one setting, Page layout: Tabs or Timeline. Tabs is slots along
the bottom; Timeline is days down the side. Placement is never stored
on its own.

- Slots + side and Days + bottom are not supported states.
- The UI says Tabs and Timeline. "Strip" and "rail" stay code names.
- A layout change moves no content and writes nothing new to disk. The
  caption says what each layout does and what it costs. Time-related
  settings appear only under Timeline.
- Tabs stays the default until the prototype label comes off Timeline.

This supersedes D-26 and section 4's four combinations. Section 4's
metrics stand for the two layouts that remain. It replaces D-13's gate,
"the default does not flip before D-26's two settings exist", which can
no longer open; the rest of D-13 stands.

## Consequences

- D-26's first objection is met: no code names reach the UI. Its
  second is accepted: grouping and placement cannot be chosen apart.
- Settings and every navigation change carry two layouts instead of
  four.
- Anyone who had Slots down the side now sees Tabs along the bottom.
  That includes installs from 84a1094 to c1f4aca with no stored
  placement, which defaulted to the side. Anyone who had Days along the
  bottom now sees Timeline down the side. No content moves, and no
  notice is shown.
- `TimeUnitModeTests` covers the stored preference, the computed
  placement, the stored key's removal, the absence of disk writes and
  the caption. No test covers the picker's two choices or the
  Timeline-only settings.

## Open questions

1. The reason for c1f4aca. It has no commit body. A proposed reason:
   the two dropped combinations had no default role, yet each was a
   navigation view kept at parity through every strip or rail change.
2. `SlotRailView` and `TimeStripView`: delete, or keep unreachable.
   Recommendation: delete; git keeps them.
3. A notice for people whose placement moved. Recommendation: none.
   Timeline is a prototype and Settings names both layouts.

## Eject triggers

- Dogfood or TestFlight feedback asks for slots down the side or days
  along the bottom. Reopen as a second setting rather than a third
  layout.

## Decision history

- 2026-10-01: Proposed, recording c1f4aca after the fact.
- 2026-10-01: Accepted. The 2026-0915 record carries dated notes under
  section 4, D-13 and D-26, and the 2026-0916 rail redundancy record
  under D-44.
