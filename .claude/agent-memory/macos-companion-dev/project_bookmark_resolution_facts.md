---
name: bookmark-resolution-facts
description: Measured 2026-09-30 unsandboxed on macOS 27.0, how a scoped bookmark resolves after a trash, and when another file sits at its recorded path
metadata:
  type: project
---

Two measured facts about `URL(resolvingBookmarkData:)`, unsandboxed, macOS 27.0, 2026-09-30:

1. A bookmark follows its file into the Trash: after `FileManager.trashItem` it resolves to the `~/.Trash/...` path with the stale flag set. `FileManager.getRelationship(of: .trashDirectory, ...)` answers `.contains` for it and throws for a path with nothing at it.
2. When the file was renamed away and a different file now sits at the bookmark's recorded path, the bookmark resolves to the recorded path (the other file), not to where its own file went.

**Why:** fact 1 is why `hydrateRestoredFile` refuses to follow a bookmark into a Trash (`FileCoordinator.isInTrash`). Fact 2 means a chain of renames (b to old, a to b) cannot be produced in a Swift test by renaming; the tests hand each record the bookmark instead.

**How to apply:** do not write a restore test that expects a bookmark to find its file when the old path is occupied. Neither fact has been seen under the sandbox; see case 15 in docs/qa/verification-procedures/sandbox-file-access.md.
