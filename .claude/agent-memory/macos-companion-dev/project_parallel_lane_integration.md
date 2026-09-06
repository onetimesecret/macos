---
name: parallel-lane-integration
description: How parallel worktree lanes cherry-pick onto an integration branch; MEMORY.md is the one file that conflicts every time, and a lane's own version bump can cover the phase
metadata:
  type: project
---

Dogfood phase 4 (2026-09-05) integrated five worktree lanes onto feature/dogfood-phase-4 by cherry-picking each lane's commits in order, one lane at a time. 19 commits, four conflicts, none in code.

**Why:** Three of the four conflicts were the MEMORY.md index: every lane appends its own line at the end of the same file, so each lane after the first collides there and the resolution is always both lines kept. The fourth was CHANGELOG.md's Unreleased section, where one lane appended to Added and another opened Changed; again both hunks kept. Shared Swift files (BackdropApp, BackdropWindowController, TabStripView, default-keymap.json) auto-merged cleanly because each lane's hunk sat in a different region.

**How to apply:** Expect a MEMORY.md conflict per lane and resolve it by keeping both lines. When one lane bumps the plist version for the phase (identity lane went to 0.19.0), the other lanes' deferred bumps are already covered; do not bump again. Verify the merge by diffing each shared file against its owning lane: the only differences should be the other lane's hunk. See [[stacked-version-bumps]] for the case where two lanes bump the same number.
