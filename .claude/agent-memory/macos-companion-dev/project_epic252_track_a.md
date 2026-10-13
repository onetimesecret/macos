---
name: epic252-track-a
description: Epic 252 Track A (#248 gutter, #250 strip, #249 pad list) built 2026-10-13 on feature/editing-seals; where the SwiftUI fields' state lives, the held notice #245 must reuse, and where the owed hand checks are written down
metadata:
  type: project
---

Track A of epic 252 landed on feature/editing-seals on 2026-10-13, app
0.27.0 (#248), 0.27.1 (#250) and 0.28.0 (#249), then 0.28.1 and 0.28.2
for review fixes; shell only.

- The gutter's day and time are `DayHeaderView.Words`; a typed name sits
  between them and is part of the time's seat, so a click on the name or
  the time opens the field (Law 0007 review amendment). The label is the
  tab's name and outlives its page (ADR-0017), so a page minted into a
  named slot reads it; that is recorded, not a bug.
- `beginRename` must never remember a field editor as the responder to
  give the keys back to (`keyboardToReturn`): that editor belongs to the
  field the click is about to end.
- SwiftUI rename fields cannot be driven under xctest, so their state
  lives in plain types the views call: `TabRename.Field` (strip and slot
  rail), `PadRename` (pad cell) and `PadPickerRoutes` (whether the list,
  the create sheet or a cell's field is up). Test those, not the views.
- `PageModel.holdNotice` / `releaseNotice` keep a refusal in the line
  under the page: a flash stands in front of it for its dwell and gives
  it back, and every model clear goes through `clearNotice`, which
  returns to it. Never write `notice = nil` inside PageModel. #245's
  sealed name field needs exactly this; do not build a second mechanism.
- A pad cell's ending passes its pad id to `PadRename.keep`, because the
  cell a field left loses focus after the field has moved to another.

**Why:** these are the non-obvious seams; the focus, selection and
popover behaviour of the SwiftUI fields was reasoned, not seen.

**How to apply:** before touching any rename field, reuse these types.
The owed hardware checks are written in
docs/qa/verification-procedures/rename-in-place.md, which Law 0007's
rows cite; add a check there rather than writing "checked by hand" in a
law row. Version bumps for shell only work go in the plist, not
crates/ffi, whatever a workflow prompt says ([[two-version-numbers]]).
