---
name: roll-jump-tests
description: How to test the roll's animated rail jump in xctest, and what cancels an NSClipView animator jump
metadata:
  type: project
---

`DayStackView.scroll(toDocumentOffset:)` animates only when `window?.isVisible == true`, so the DayScrollTests windows (never ordered in) always jump instantly. `mountRoll(model:ordered: true)` orders a borderless window at (-20000, -20000): it animates there, and nothing flashes on screen. Measured 2026-10-23 (PR 327):

- A direct `clip.scroll(to:)` mid-jump does not stop the animator jump. Only a zero-duration `runAnimationGroup` on the same property supersedes it.
- `relayout()` restores `readingPlace` on every pass, so any pass that supersedes would cancel a rail click's jump. Only `settlePendingPlace` (another document order) passes `supersedingJump: true`.
- Wait for arrival with an `XCTNSNotificationExpectation` on the clip's boundsDidChange. Skip when reduce motion is on, because the duration is then 0.

**Why:** the review bot caught restore cancelling every rail jump, and no instant-path test could see it.
**How to apply:** for any change to jump, restore or scrollToDayZero, add an `ordered: true` test. Also see [[project_pr271_reading_place]].
