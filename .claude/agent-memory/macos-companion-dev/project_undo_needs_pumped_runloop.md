---
name: project_undo_needs_pumped_runloop
description: XCTest has no turning run loop, so NSUndoManager never closes its per-event group and one undo() takes back the whole test fixture unless the loop is pumped
metadata:
  type: project
---

An XCTest case that asserts "one ⌘Z reverses exactly this keystroke"
must pump the run loop between building the fixture and performing the
keystroke:

```swift
textView.breakUndoCoalescing()
RunLoop.current.run(until: Date())
```

**Why:** `NSUndoManager.groupsByEvent` is true, and the group it opens
on first registration is closed by a run loop observer. A test has no
turning run loop, so every edit in the test lands in one open group and
`undo()` reverts the fixture along with the keystroke under test. The
first draft of the list continuation tests failed exactly this way
(storage came back as `""` instead of `"- milk"`), which looked like a
defect in the editor's undo grouping and was not.
`breakUndoCoalescing()` alone is not enough: it fences NSTextView's
typing coalescing, not the manager's event group.

**How to apply:** any view-level suite touching undo in
`shell/Tests/CompanionKitTests`. See the `settleUndo()` helper in
`ListAutomationTests.swift` for the shape.
