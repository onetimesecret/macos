---
name: pr272-finder-open
description: PR 272 Finder Open With; FinderOpenPlan.decide owns the drain, a modal or a close decision keeps the queue, completeStartup and selectEditorForTests let a delegate test drain without AppKit, and which filenames macOS 27.2 types as text
metadata:
  type: project
---

`FinderOpenPlan.decide` (shell/Sources/OnetimePad/FinderOpenPlan.swift) is the one decision for a Finder open. It keeps the queue's file URLs until startup completes, while `ModalSession.isRunning`, and while `PageModel.openRefusedForCloseDecision` (pads on and a dirty close pending). It arms the pending route only if a file opened, the startup replay did not run and the app is active. The delegate drains again on the deferred turn after a modal ends, and a turn after `pendingFileClose` returns to nil. Round two pushed 2026-10-20 (b5a75de7..53f4171b).

**Why:** two review rounds found the route armed with no file opened, a file opening under the open panel, an open lost to the close decision's refusal, and a delegate test that passed with the URLs thrown away.

**How to apply:** route any new Finder open condition through `decide` and test it in FinderOpenPlanTests. A delegate test calls `completeStartup(_:)` instead of `applicationDidFinishLaunching` and sets `selectEditorForTests`, because the real selection shows the editor window or activates the runner. Act on `$pendingFileClose` a turn late: @Published emits before the store. On macOS 27.2, README and LICENSE resolve to text (Makefile to public.make-source), while .gitignore, .zshrc and Dockerfile resolve to public.data, so Open With leaves them out. The main menu (no New item, ⌘N) is a hand check, QA case 2a step 4, because xctest never assembles the SwiftUI menu. See [[keymap-76-77]].
