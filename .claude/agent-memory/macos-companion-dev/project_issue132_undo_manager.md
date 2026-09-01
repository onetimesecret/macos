---
name: issue132-undo-manager
description: Loro UndoManager landed in the core on feature/132-undo-manager; the merge interval is a step-duration ceiling not a pause detector, and the stack must be forgotten whenever the chip roster moves
metadata:
  type: project
---

Issue #132 delivered 2026-09-01 on `feature/132-undo-manager` (pushed,
PR #142): `loro::UndoManager` lives in `SheetDocument`, exposed
through five FFI seams, and ⌘Z / ⇧⌘Z route to it from the keymap file.
Issue #133's judgments doc landed in the same branch.

**Why:** once remote ops land in live documents (#98, the #102
surface), a shell-level undo can revert another device's text. Loro's
manager is local to the bound peer, which is the fix.

**How to apply:** four findings that are not visible from the code and
cost real debugging time.

1. **The merge interval is a ceiling, not an idle-gap detector.**
   Verified in the vendored `loro-internal-1.13.9/src/undo.rs`:
   `in_merge_interval = now - last_undo_time < merge_interval_in_ms`,
   and `last_undo_time` moves only when a *new* step is pushed. So a
   step absorbs everything within N ms of its own start, whatever the
   writer did. The chosen 2000 ms is defended on that basis in
   `docs/spec/feature/block-revisions/2026-0901-pause-boundaries.md`.
   Do not describe it as pause-aligned undo.
2. **A merged step keeps the first push's metadata.** `push_with_merge`
   extends the span end and leaves the meta alone, so the caret a
   merged step restores is where the *group* began, not the last
   keystroke. A test asserting otherwise will fail and the test is
   wrong.
3. **Record the change START in `set_on_push`, never the end.** The
   library's contract is that the cursor was acquired before the ops
   the step inverts. An end offset is outside the body after undoing an
   insertion, and `convert_pos` then returns nil, so the caret silently
   never restores. Event deltas are unicode scalars outside the wasm
   build, the same unit `Cursor` uses.
4. **Forget the stack wherever the chip roster moves.** A redo that
   stands a sentinel for zeroized bytes produces exactly the document
   shape `persist` restore calls damage. Choke points wired: the seal,
   `delete_chip`, any `settle_document` that reaps a chip, the
   wholesale restate, and `compact`.

Decided explicitly and stated in both the doc and a comment at the
rebind site: **undo does not survive relaunch.** The manager binds
where the document is constructed, so restore and compaction start
empty by construction.

The chords had to go on the text view's `performKeyEquivalent` route,
not the surface's: the key window's view chain sees a key equivalent
before the main menu, and the standard Edit menu's Undo would
otherwise hand ⌘Z to `NSUndoManager`. AppKit's per-page managers are
left in place so list-automation grouping is unchanged; the page's
AppKit history is dropped at each core step.

See [[feedback-test-seams-are-mandatory]] for the fixture rule the new Swift
suite follows.
