---
name: issue33-backdrop-geometry-stages
description: Issue #33 backdrop drag/resize/settings, all stages D0-D3 landed and verified green 2026-07-17; uncommitted on feature/33-backdrop-drag-resize-settings
metadata:
  type: project
---

Issue onetimesecret/macos#33 stages D0-D3 all landed and the combined tree was verified on 2026-07-17: BackdropGeometryTests 13/13, BackdropStanceTests 18/18, CompanionApp 77/77, both products build. All changes are uncommitted in the working tree of `feature/33-backdrop-drag-resize-settings` (no commits ahead of origin/main). Manual summon/dismiss checks and PR remain.

**Why:** The hard invariant is that `BackdropStance.resting.ignoresMouse == true`; the resting surface must never intercept a desktop click. Verification confirmed `ignoresMouseEvents` is set only in `BackdropWindowController.apply(_:)`, `isMovableByWindowBackground` stays false, both `sharingType = .none` sites intact, and the literal 220 editor floor now lives only in `BackdropGeometry.default`. ADR-0010 decoupling holds: geometry persists in the backdrop-only suite `com.onetimesecret.companion.backdrop`; CompanionApp uses `UserDefaults.standard`.

**How to apply:** Geometry flows through `BackdropModel.geometry` / `setGeometry(_:)` / `resetGeometry()`; never write `panel.frame` or defaults from views. When a live instance runs from `dist/`, verify with `swift build`/`swift test --scratch-path <scratchpad>`: it compiles and tests without touching `shell/.build` or the running binary. Backdrop defaults tests must use UUID-suffixed throwaway suites with `removePersistentDomain`. New agent-written prose must avoid em/en dashes even though older backdrop comments use them (three such lines were fixed during verification).
