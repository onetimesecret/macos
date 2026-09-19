---
name: issue-198-presentation-ownership
description: B2 ownership rules that are easy to break, claims are owner guarded and releases identity guarded, the owner settles before any stance publishes, never sink on $owner synchronously
metadata:
  type: project
---

Issue #198 (ADR-0033) gave `PageModel` one `owner` and guarded the presentation fields (2026-09-18, branch feature/198-presentation-ownership).

- A claim names its surface and is declined for a window that does not own. A release (`retireEditor`, `withdrawPasteboardOffer`, the roll geometry reset) is guarded by identity, never by ownership. **Why:** SwiftUI dismantles the old mount after the owner has moved, so an ownership guard on a release would trap in every hand off.
- `BackdropModel` settles the owner before it publishes a stance, and keeps `panelRaised` as the committed posture. **Why:** `@Published` fires on willSet and the window controller orders windows inside that turn, so key delegates of both windows come back in while `stance` still names the posture being left. `owner` is `@Published` too, so never add a subscriber that acts on `$owner` synchronously. `PrimaryEditorWindowController` hops a turn for that reason.
- A declined write is an `assertionFailure` in debug, and the user's dev build is debug. **How to apply:** every new writer asks `model.owner == surface` first, and tests watch a refusal through `Seams.declinedPresentationWrite`. `BackdropModelTests.ephemeralPages` fails the test on any refusal.
- Removing the guard in `BackdropModel.raise` exposed two things it had hidden: ⌘Tab back with the editor window open raised the panel (now claimed in `applicationDidBecomeActive`), and the rest's `editorWindowOpen` branch skipped the key relay on the hotkey path. Related: [[adr-0034-altitude-keeper]].
