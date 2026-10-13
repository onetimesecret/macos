---
name: epic252-track-a
description: Epic 252 Track A (#248 gutter, #250 strip, #249 pad list) built 2026-10-13 on feature/editing-seals; where the SwiftUI fields' state lives, the held notice #245 must reuse, and what only hardware can confirm
metadata:
  type: project
---

Track A of epic 252 landed on feature/editing-seals on 2026-10-13, app
0.27.0 (#248), 0.27.1 (#250) and 0.28.0 (#249), shell only.

- The gutter's day and time are `DayHeaderView.Words`; a typed name sits
  between them and an unnamed gutter's rename opens on the time, not on
  the hidden derived title (`seat`). `reading` lists the drawn fields by
  frame, so a test pins the order a reader sees.
- SwiftUI rename fields cannot be driven under xctest, so their state
  lives in plain types the views call: `TabRename.Field` (strip and slot
  rail) and `PadRename` (pad cell). Test those, not the views.
- `PageModel.holdNotice` / `releaseNotice` keep a refusal in the line
  under the page with no dwell. #245's sealed name field needs exactly
  this; do not build a second mechanism.
- A pad cell's ending passes its pad id to `PadRename.keep`, because the
  cell a field left loses focus after the field has moved to another.

**Why:** these are the non-obvious seams; the focus, selection and
popover behaviour of the SwiftUI fields was reasoned, not seen.

**How to apply:** before touching any rename field, reuse these types.
Hardware checks still owed: the strip, slot rail and pad cell select
their draft whole on focus; an empty pad Return keeps the field open
(SwiftUI may drop focus on submit); Escape in the pad cell keeps the
popover or closes it with the name kept; the refusal line is visible
beside the pad popover. Version bumps for shell only work go in the
plist, not crates/ffi, whatever a workflow prompt says ([[two-version-numbers]]).
