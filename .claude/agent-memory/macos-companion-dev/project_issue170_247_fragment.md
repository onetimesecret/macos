---
name: issue170-247-sealed-fragment-core
description: Issue 170 core half and issue 247 built 2026-10-13 under ADR-0047; the seams the editor half builds on, which shell units (copy, cut and slot, paste) are done, and the traps (stood flag, per chip death records, rollback hook, no general pasteboard in tests)
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
- ⌘Z after a removal now reattaches; the removal line can offer Undo.
  Backspace beside an object must select first (no test pins either).
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
  twice is unreadable. Copy, cut, copy decrypted and the decrypted drag
  still read a due page until its timer fires (left, named in ADR-0048).

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
