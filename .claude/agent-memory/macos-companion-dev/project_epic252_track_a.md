---
name: epic252-track-a
description: Epic 252 on feature/editing-seals, Track A (#248, #250, #249) and the phase 4 close at app 0.35.0 on 2026-10-14; where the SwiftUI fields' state lives, the held notice #245 must reuse, where the owed hand checks are written, and what the close left open
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
  A field holds its refusal through `PageModel.HeldRefusal`, which
  re-holds only on new words via `holdNotice(_:replacing:)`, so a
  keystroke never cuts a flash in front (fixed 2026-10-13, app 0.31.5).
- The pad list's popover height is `PadListLayout.maxHeight`, fed by
  `PageStatusStack`'s top through `keepsThePadListAboveTheNoticeLine()`
  on both roots; a root without it leaves the list 620 points tall.
- A pad cell's ending passes its pad id to `PadRename.keep`, because the
  cell a field left loses focus after the field has moved to another.

- The phase's last issues, #170 and #247 (the sealed fragment and the
  name and note in it), finished on the same branch at app 0.34.0; see
  [[issue170-247-sealed-fragment-core]]. Every new editor route stands
  aside on `answersChords` while a rename field or the note holds the
  keys (ADR-0046). None of the epic's hand procedures (rename in place,
  sealed zones and note, sealed fragment) has been run.

- Phase 4 (security review F1 to F3, critic W01 to W26) closed on
  2026-10-14 at app 0.35.0, companion-core 0.32.0, companion-ffi 0.40.0,
  with ADR-0052 to ADR-0054. Every unrun hand check in a law row reads
  `owed: hand check, [procedure]`; keep that form. Still open at the
  close: the Linux CI lane was audited by reading only (ring needs a
  Linux C compiler here; `cargo clippy --target x86_64-unknown-linux-gnu
  -p companion-core` passes), the yank defect in [[w03-removal-routes]],
  the sync controller's `onRemoteChange` mark is counted by no suite,
  and the PR body owes "closes #170, #240 to #252".
- An earlier re-aim sweep shifted document.rs citations by a fixed
  offset without reading them back, so five were wrong for weeks. Read
  each cited line back against what it read when its doc line was
  written (git blame the doc line, git show that commit's file).

**Why:** these are the non-obvious seams; the focus, selection and
popover behaviour of the SwiftUI fields was reasoned, not seen.

**How to apply:** before touching any rename field, reuse these types.
The owed hardware checks are written in
docs/qa/verification-procedures/rename-in-place.md, which Law 0007's
rows cite; add a check there rather than writing "checked by hand" in a
law row. Version bumps for shell only work go in the plist, not
crates/ffi, whatever a workflow prompt says ([[two-version-numbers]]).
