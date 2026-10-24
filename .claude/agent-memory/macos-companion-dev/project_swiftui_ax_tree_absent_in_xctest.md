---
name: swiftui-ax-tree-absent-in-xctest
description: an NSHostingView in xctest exposes no SwiftUI accessibility children or custom actions, so test named actions through the pure builder the view reads
metadata:
  type: project
---

Under `swift test`, `NSHostingView.accessibilityChildren()` answers nothing for SwiftUI content (seen 2026-10-23 on the rail, PR #327), so `.accessibilityActions` and labels cannot be walked from a test.

**Why:** SwiftUI builds its accessibility tree for an assistive client; xctest has none. AppKit views (InkTextView, sealed handles) do answer, which is why other suites walk them.

**How to apply:** put action names and their effect in a pure type the view reads (`PadSortSection.actionName` and `apply`), test that, and leave the modifier wiring to a hardware VoiceOver check.
