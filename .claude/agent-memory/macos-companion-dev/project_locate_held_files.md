---
name: locate-held-files
description: Locate and held file facts from 2026-09-30 that the code does not make obvious; read before touching file restore, the conflict banner or FileCoordinator panels
metadata:
  type: project
---

Locate landed on feature/sandbox-file-access on 2026-09-30 (core `FileStore::relocate`, `companion_file_relocate`, roster key `accessRefused`, `HydrationFate::Held`). The roster key was `unreadable` for a few hours the same day and was renamed: `unreadable` is now only the drafts notice reason (bytes read, will not open as text), and the two words must never stand for each other.

**Why:** a sandboxed build can lose a file's grant, and a clean record used to be dropped at launch with no way for the person to say where the file is.

**How to apply:**

- A held row can read `isDirty` with an empty buffer (its draft was over the snapshot bound). Anything that asks "is there unsaved work" reads `FileSummary.holdsUnsavedEdits`, never `isDirty` alone, or a held tab gets a dirty close decision about nothing.
- The core's `save` stats the path itself and answers `SaveError::NotFound` unless a keep mine stands, so no shell route can recreate a deleted file. The seam still returns only false; the shell tells the refusals apart from the roster row read after it. Save As onto the file's own name goes down the save as route when nothing is at the path.
- A held row is `pendingHydration && accessRefused` (`FileSummary.isHeld`). It is the one pending row the surface ever publishes. Pending alone still means a wait, so any new roster consumer must tell the two apart.
- `PageModel.samePath` cannot compare a path with nothing at it: `resolvingSymlinksInPath` only strips `/private` when the file exists. Tests that assert a record kept a path whose file moved compare the directories and the names instead (`stillRecorded` in FileAccessTests).
- `ModalSessionTests.testOnlyOpenAndSavePanelsEnterTheModalBracket` counts the literal `ModalSession.run` in FileCoordinator.swift and pins it at 2. A new panel goes through `SystemFilePanels.runOpenPanel`, not a third call site.
- `applyCheck` returned early on `.unchanged` without restating the roster. Anything the core's check can change besides the conflict (today the access refused and not found marks) needs a `refreshOpenFiles()` in that arm.
- The core's notice list is drained only by reading it, and drafts saves append to it outside a launch. Any new reader calls `discardStaleDraftNotices()` first or it reports old oversize notices as its own.
- A second mark, `notFound`, says nothing is at the path. It is the only standing sign for a clean file, which never enters a conflict. `FileSummary.isUnavailable` (no conflict, either mark) is what `FileUnavailableBanner` stands for, and that includes a dirty file after keep mine.
- A dirty access refused file stays in `changed` through every check even when the stat matches the witness. Before that rule the first activation cleared the conflict hydration had set, and the save overwrote a copy nobody had read (seen in a test with a mode 000 file).
- `settle_over` keeps the document when a live clean file meets its own text, so a rebind does not empty the undo stack. `adopt` is for a pending record or a text that differs.
- `checkOpenFilesOnActivate` is put off while a file panel gesture runs (`duringFilePanel`). A test that needs an activation under a panel uses a `FilePanels` that answers from inside `ModalSession.run` with its own notification centre.
- The swapped files tie break (`settleCrossedFiles`) reads every tied file with all their scopes open. Reading across scopes has not been run under a sandbox.
- Design record D-17 still says three actions in the conflict banner. Locate is a fourth, first in reading order, with Save As kept last, and like the other three it has no chord. Related: [[bookmark-resolution-facts]].
