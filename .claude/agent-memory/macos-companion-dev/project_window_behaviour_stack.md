---
name: window-behaviour-stack
description: The stacked branch chain 41/22/23/73/74 in the dogfood-a worktree, propagated by plain merges, and the invariants its adversarial review fixed on 2026-08-24
metadata:
  type: project
---

The pad's window-behaviour work lives as a stack of five branches in the
`dogfood-a` worktree, bottom to top: `feature/41-menu-rest` ->
`feature/22-focus-law` -> `feature/23-editor-races` ->
`feature/73-invisible-clicks` -> `feature/74-space-return`. Fixes commit
on the branch that owns the code and then travel upward by plain
`git merge` (41 into 22, 22 into 23, and so on), never by rebase, so
every tip contains everything beneath it.

**Why:** the branches are reviewed and pushed independently, and rebasing
a stack that is already on the remote rewrites branches other people and
other worktrees are looking at. A merge-only chain keeps each branch's
history and lets a fix land once at its true owner.

**How to apply:** find the branch whose diff introduced the code before
fixing anything in this area; a file's content differs between the tips
(the pin sink, `collectionBehavior` and `applyAltitude` all changed
shape between 73 and 74), so read the file after checking out the branch
rather than trusting what an earlier branch showed. Re-merge upward after
every late fix, and expect the pin sink in `BackdropWindowController` to
be the recurring conflict.

Invariants the 2026-08-24 adversarial review established, all now carried
by tests and comments:

- The mouse gate must converge to open for a card the user can see. A
  gate stuck shut is the worst failure that feature can have, so the
  settling turn after a stance or pin change may open the gate but never
  close it on a keyed window, and a Space switch is read twice (prompt
  and settled) because a card on every Space has no later edge to reopen
  it. See `SurfaceExposure.Turn`, `writes(gate:from:isKey:)` and
  `spaceSettleReads`.
- Menu tracking sessions expire: an unbalanced `didBeginTracking` used to
  claim every press for the process's life, silently retiring the outside
  click rule.

Related: [[adversarial-review-for-agent-written-security-code]],
[[claims-that-outran-the-code]].
