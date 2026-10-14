---
name: issue170-247-sealed-fragment-core
description: Issues 170 and 247 built 2026-10-13 under ADR-0047 to ADR-0054, app 0.34.0; the deadline gate (readable_sheets) and the shell's settle on refusal, on wake and before AppKit gives text out; copy and cut refuse past an envelope cap with a line naming the limit; the core move between pages (drop not wired); the seams, all eight units (copy, cut and slot, paste, two press removal, drags, decrypted drag, services), the open ⇧⌘V placeholder trap, and the traps (stood flag, per chip death records, rollback hook, no general pasteboard in tests, in-process provider reentry, legacy pasteboard type names)
metadata:
  type: project
---

Built on feature/editing-seals 2026-10-13: companion-core 0.29.0 (#170)
and 0.30.0 (#247), companion-ffi 0.38.0, companion-pasteboard 0.4.0,
app 0.33.0. Decisions in ADR-0047; Law 0001 rows cite the tests. No
editor UI was built: every row's editor half is owed to issue 170.

Seams for the editor half (all page ids, all refuse a file id):

- `copyFragment(sheet:range:)` / `cutFragment` give `SealedFragment`
  (`envelope: Data?`, `plainText`). Write ONE pasteboard item with the
  envelope under `CompanionClient.sealedFragmentType` and `plainText`
  under `.string`. A nil envelope means ink alone: write plain only, so
  an in-app paste keeps automatic fencing. The cut deleted its range
  already; if the pasteboard write fails, undo the cut.
- Paste: if the item has the private type, `pasteFragment(sheet:range:
  envelope:plainText:)` with the item's string as fallback, then restate
  the page from `documentRuns` (the core edited the body) and put the
  caret at `placed.range` end. `unreadable` true wants a line under the
  page. Otherwise the ordinary plain paste.
- Drags inside one page: `moveRange(sheet:range:to:)` (`to` measured
  before the move; nil inside or at the range's edge) and `cloneRange`
  for ⌥. Between pages: write the copy fragment, the drop pastes it, the
  source's removal detaches.
- Decrypted drag: an `NSPasteboardItem` with a data provider for the
  chip's own type (`public.utf8-plain-text`, or `public.png` for an
  image); in `provideDataForType` call `provideDecryptedDrag(chip:
  pasteboard:item:type:)` with the pasteboard AppKit passes. A nil
  pasteboard means refuse. Never put that item on the general board.
  A decrypted drag dropped on our own page meets drop to seal, which
  reads the drag board core side and fires the provider: decide it.
- Slot: `activeCut()` (page and faces) and `pasteActiveCut(sheet:range:)`;
  ADR-0047 point 12 makes it a standing line under the page with a
  Place button.
- ⌘Z after a removal now reattaches. The two presses and the line's
  Undo are built (shell unit 5, `SealedRemovalTests`): see below.
- Copy is built (shell unit 1): `InkTextView.copy` to
  `PageModel.copySelection`, written by `SealedFragment.write(to:)` onto
  `ambientPasteboard`; pinned in `SealedFragmentEditorTests`. NSTextView's
  `cut:` calls `copy:` then deletes (probed), so the editor's cut must not
  call `super.cut`, or it writes the copy fragment and detaches as a removal.

- Cut and slot are built (shell unit 3): `InkTextView.cut` to
  `Coordinator.cutSelection` to `PageModel.cutSelection` (`CutOutcome`).
  Reuse for paste, move, clone: `PageModel.settleTransfer(sheet:)`
  (restate, quiet rendering, markDirty, refresh) and
  `Coordinator.settleRewrite(selecting:)` (restyle, caret, scroll).
  `activeCut` is read in `refresh()`; the slot line sits in
  `PageStatusStack`, owner only, and its button runs
  `placeActiveCutAtCaret`. A failed write is tested through
  `Seams.writeCutFragment`: NSPasteboard cannot be subclassed
  (allocWithZone throws) and a released board still takes writes.
  Open trap: after our copy or cut, `holds_external_content` sees
  `.string`, so the summon offer would seal the placeholder text.
  Mutation test runs are refused by the auto mode classifier.

- Core guards (unit 2, ADR-0048 and ADR-0049, core 0.31.1, ffi 0.39.0):
  paste, slot, move and clone refuse a page past its deadline (nil,
  nothing changed); a paste naming an object first runs `expire_due`, and
  `PlacedFragment.pagesExpired` counts the pages it took. So every
  paste, move and clone route must `markDirty()` then `refresh()`, as
  `settleCoreEvent` does, or a swept page stays on screen until the
  timer. An envelope over 8 MiB, over 1024 refs, or naming one UUID
  twice is unreadable. ADR-0052 (phase 4, core 0.32.0, ffi 0.40.0)
  replaced ADR-0048's consequence that copy and cut still read a due page.

- Envelope caps (ADR-0053, phase 4): copy and cut ask the parse's own
  `EnvelopeCap::passed` before any buffer and return
  `Result<Copied, CopyRefusal>`; past a cap nothing is written, deleted
  or detached. The FFI answers `{"error": "tooLarge" | "tooManyObjects",
  "limit"}` (every other refusal stays null), and
  `copyFragmentResult`/`cutFragmentResult` give a `FragmentRefusal`. The
  optional `copyFragment`/`cutFragment` still return nil. The editor's
  line is built (phase 4 unit 4): `composeSelection` carries
  `.pastCap(FragmentRefusal)` and one `PageModel.refusalLine(for:_:)`
  words every refused composition for copy, cut, drag and a service
  (so a service now hears the several stretches line too). Sealing 1025
  chips one FFI call at a time takes about 21 s in a debug test, so seam
  tests use the 8 MiB length cap; the store seals 1026 in well under 1 s.

- Deadline gate (ADR-0052): `SheetStore::readable_sheets` is the one
  accessor for any route that gives a page out; it asks `Sheet::is_due`,
  the sweep's own predicate. `chip_home` goes through it, so every
  `chip_home` caller (note undo names, `finish_note_editing_group`)
  refuses a due page too; `chip_mut` and `record_sent` do not, on
  purpose. Reads never sweep. Shell half (phase 4 unit 4): a wake
  (`Seams.wakeNotifications`) runs `settleCoreEvent`; a refused read
  calls `settleIfDue`, which settles only when `nextEventMs() == 0`, so
  a refusal with nothing due arms no write (`LedgerAppendArmingTests`)
  and a late conceal outcome over a fake page id keeps its draft. Paste
  and drop refusals keep the unconditional `settleCoreEvent`, since the
  paste sweeps first. AppKit's ways out (note copy, cut, drag, service;
  ink alone service; ink stretch drag) ask `PageModel.givesOut(sheet:)`,
  which also refuses a page no longer in `tabs`, because a hand mounted
  editor keeps a swept page's storage. `noteRuns` answers nil for a
  refusal. Never call a note's `textView.copy`/`cut` in a test: NSTextView
  writes the general pasteboard; pin through `givesOutShownText()` or
  `writeSelection` on a unique board. `age_by`/`ageForTests` stage a due
  page with no sweep; ids re-mint densely, so a one page fixture keeps
  its ids (assert it). Mutation checks by Edit ran unrefused.

- Move between pages (ADR-0054, phase 4, core and seam only):
  `SheetStore::move_range_to` / `companion_sheet_move_range_to` /
  `client.moveRange(sheet:range:toSheet:at:)`. The source deletes and
  settles first, then the shared `stand_plan` (which `place` also
  uses) stands the plan on the destination and clears the source's
  undo only when an object moved; ink alone keeps it. A destination
  refusal rolls the source back, which clears its undo and rebuilds
  its blocks (provenance resets), as a failed paste does. The drop is
  not wired: the shell must call it under the `PageDrag` stamp,
  restate both pages, and stop `endPageDrag` deleting the source run.
  ⌥ between pages still pastes the copy fragment.

- Paste is built (shell unit 4): `InkTextView.paste`, `pasteAsPlainText`
  and `pasteWithoutDetection` ask `Coordinator.pasteFragment()` first,
  which calls `PageModel.pasteFragment(from:sheet:range:)` (takes any
  board, so a drop can reuse it; `.ordinary` for no fragment or a file
  id). A board holding the type never reaches AppKit's paste on a page,
  even when refused; a note falls through to AppKit's public text.
  Every paste route now guards `answersChords`. Tests that paste must
  hold the fragment on the private board, or AppKit reads the real
  general one. Open trap still unfixed: ⇧⌘V and the summon offer would
  seal our own placeholder text.

- Removal is built (shell unit 5): `InkTextView.deleting` runs ⌫ and ⌦
  on a page; `Coordinator.selectObjectBeside` is the first press, and
  `Coordinator.noteRemoval` ends the editing group (or a later deletion
  merges into the removal's step) and stamps `(document, generation)`.
  The line's Undo (`undoRemoval`) steps back only while the stamp holds;
  `retireRemovalUndo` in `didProcessEditing` and `currentSheet`'s didSet
  calls `PageModel.withdrawRemovalUndo`. Not covered: ⌥⌫, ⌘⌫, Edit >
  Delete and typing over a selected object still remove with no line;
  a torn down coordinator leaves a dead button (weak self).

- Drags are built (shell unit 6, `SealedDragTests`): `InkTextView.
  dragSelection` begins its own session with `Coordinator.beginPageDrag`'s
  one item (`SealedFragment.pasteboardItem()`); the `draggedCell` delegate
  sends a drag starting on an object there. Own drop: `dropPageDrag` to
  `PageModel.dropRange` (core move or clone). Another page: `dropFragment`
  pastes, then tells the source `pageDragMovedAway()`, and only then does
  `endPageDrag(.move)` delete the source run. Both check the
  `(document, generation)` stamp. `dragOperation(for:type:)` feeds
  AppKit's drop caret (unobserved). A drag whose source is the page with
  no `pageDrag` still falls to `super.performDragOperation`; never make
  the page a decrypted drag's source.
  `FakeDrag` stands in for NSDraggingInfo; never pass it to a super call.

- Decrypted drag is built (shell unit 7, `SealedDecryptedDragTests`,
  ADR-0050 and ADR-0051): `DecryptedDrag` is the session's source and
  the item's provider; `Coordinator.beginDecryptedDrag(at:)` makes both;
  `InkTextView.mouseDown` sends a first plain press on a drawn handle
  (`SealedBlockCell.decryptedDragRect`) to `trackDecryptedDrag`. Probed
  2026-10-13 with swiftc: an item retains its provider until the
  promise is met; a standalone item's read asks with a nil pasteboard;
  an in-process read asks synchronously on main inside the read. So
  drop to seal on our own decrypted drag would relock the core's Mutex:
  `isDecryptedDrag` refuses first, and the in-app mask is empty. A test
  of the refusal must assert `draggingEntered` before calling perform,
  or a regression reads the real system drag board.

- Finished (unit 8, app 0.34.0): a service's request goes through
  `InkTextView.writeSelection(to:types:)`, `writablePasteboardTypes` and
  `validRequestor`, which share `PageModel.composeSelection` with the
  copy. NSTextView names its types the legacy way (`NSStringPboardType`,
  `NeXT Rich Text Format v1.0 pasteboard type`), and its own
  `writeSelection` refuses the modern `.string`/`.rtf` names, so a test
  asking AppKit by those names sees false. Still open, no accepted
  record: ⇧⌘V and the summon offer seal our own placeholder text after
  our copy; ⌥⌫, ⌘⌫, Edit > Delete and typing over an object remove it
  with no line; Share's item source is unverified; no hand procedure
  has been run.

**Why:** the next agent builds the editor on these; the contracts are
not visible from the issue bodies, and #170's body is wrong where Law
0001 overrides it (type name, no removed placeholder).

**How to apply:** markDirty after cut, paste, move, clone and a provided
drag; paste clones and the drag append ledger records, so add steps to
`LedgerAppendArmingTests`. Traps: a removal no longer zeroizes or clears
undo, but a chip's FIRST standing (`SealedChip.stood` false, a fresh
seal placed by an `InsertChip` op) still clears undo so a seal stays one
way; a page's death writes one record per chip plus the page's, so tests
counting ledger records after a close see more; rollback is tested with
`SheetDocument::fail_writes_after` (test only, one shot); a drag test
uses `NSPasteboard.withUniqueName()` and a standalone `NSPasteboardItem`,
never the general board. `docs/qa/comment-guarantee-audit.md` still names
two tests rewritten here; it is a snapshot and was left. Residuals left
unclassified in Law 0004: the pasted envelope's serde scratch and every
seam JSON output. Related: [[issue244-246-sealed-shell]],
[[issue241-243-sealed-name-note-core]].
