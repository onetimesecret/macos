---
id: 0007-edit-in-place
title: Edit in place
status: accepted     # draft → accepted → superseded
dated: 2026-10-13
governs: A name is edited where it is shown, in its own seat; Return commits, Escape keeps, and nothing asks.
decisions: D-14 and D-46 (docs/spec/design/2026-0915-ui-ux-decisions.md and docs/spec/design/2026-0916-rail-redundancy.md); the maintainer's instruction of 2026-10-13, quoted below; ADR-0042 points 1, 3, 5 and 6
consumed-by:
  - docs/law/0001-sealed-object.md (the sealed object's name and note, 2026-10-13 amendment)
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the sealed name's charset, the double click seats, the empty pad name)
  - docs/mockups/sealed-name-and-note.md (the drawn states; not authoritative)
sources:
  - the maintainer's instruction in the 2026-10-13 design conversation (primary)
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the points this law left open)
  - docs/spec/design/2026-0915-ui-ux-decisions.md, D-14 (no dialogs)
  - docs/spec/design/2026-0916-rail-redundancy.md, D-44 and D-46 (the gutter's time and typed name)
  - shell/Sources/CompanionKit/TabRename.swift (one rule for every field's ending)
  - shell/Sources/CompanionKit/DayScrollView.swift (`DayHeaderView.beginRename`, `endRename`, `dayText`, `drawsTitle`)
  - shell/Sources/CompanionKit/TabStripView.swift (`beginRename`, `renameField`, `endRename`)
  - shell/Sources/CompanionKit/PadPickerView.swift (`nameEditor`, the sheet this law retires; `PadNameDraft`)
  - shell/Sources/CompanionKit/PageModel.swift (`renameTab`, `renamePad`)
---

# Law 0007: Edit in place

Read [behaviour law conventions](README.md) before filing or changing a law.

## The rule

> A name is edited where it is shown, in its own seat; Return commits,
> Escape keeps, and nothing asks.

The label becomes a field without moving. Whatever stood in the seat when
the field opened (a typed name, a derived first line, a placeholder, a
time) is the draft the field opens on, selected whole. Return hands the
trimmed draft to the model; Escape, the keyboard going elsewhere and the
slot being reassigned under the field all leave the name as it was. An
empty Return is a commit that clears the typed name and lets the default
stand again; a seat with no default, a pad's, refuses it. No sheet, alert
or panel is involved at any step. Where the
seat shows a default beside the name, the default keeps showing to the
right of the text once a name is typed.

## Why this rule

The maintainer's instruction of 2026-10-13, exactly:

> An inline field in the name's seat, as an IDE renames a symbol. Return
> commits, Esc cancels, no dialog (D-14). Rename… edits it in place. That
> can replace the Rename action in the pad list. It should also be
> possible to add a test description/label to checkpoints, where the time
> is the default, clicking on it allows entering text and the time still
> shows to the right of the text.

The rule generalises what the tab and the gutter already do. D-14 of the
2026-0915 record says "No modals, no interrupting dialogs" and records the
tab rename alert as a defect resolved by renaming in place (issue 172).
D-46 of the 2026-0916 record says the gutter "draws only a typed name" and
that "a rename shows the field for its own length whatever the source,
since the draft is the thing edited". `TabRename` is the one rule both
fields end through. This law names that rule, extends it to the pad list,
which still names through a sheet, and to the sealed object's name
([Law 0001](0001-sealed-object.md)), and adds the click on the gutter's
time as a way in.

The pattern is the IDE's symbol rename: the identifier is edited where it
sits, the surrounding code does not move, and the keys that end it are the
keys that end any field. The failure it prevents is the question nobody
asked for: a panel that takes the keyboard from the page for a name, which
the first tenet (the app is furniture, never interrupts) forbids.

## Operation classes

- **Opening**: a label becomes a field in its own seat, the draft is the
  label's current text, selected whole, and the keyboard moves to it. The
  ways in, per seat: a menu verb (*Rename page…*, *Rename tab…*, *Rename
  pad…*, *Name…* or *Rename…* on a sealed object); a single click where the
  seat has no other click (the gutter's time); a double click where the
  single click is taken (an unnamed sealed object's bottom row, whose
  click selects; a named one's name zone, whose click copies the name).
  Where the double click is already a gesture (the strip, where it holds
  the clock) or cannot arrive (a pad cell, whose click activates the pad
  and closes the list) only the verb opens. A zone whose first click
  copies plaintext ignores the clicks after it
  ([ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md)
  points 3 and 5). Opening is not a mutation.
- **Drafting**: keystrokes change the field and nothing else. The draft is
  what the seat shows and what VoiceOver hears; a periodic pass that
  rewrites the label never writes over a draft. Nothing persists.
- **Committing**: Return. The draft is trimmed and judged by `TabRename`:
  equal to what the field opened on, it keeps; otherwise it renames. An
  empty draft renames to nothing, which clears the typed name and lets the
  default derive again (the page's first line, the placeholder stamp, the
  time, a sealed object's unnamed row). A pad has no default, so an empty
  pad name is refused instead. A commit is a mutation like any other and
  is not undoable through the field; the next rename is the undo.
- **Keeping**: Escape; the keyboard leaving for anywhere else; the slot
  under the field being reassigned. The seat shows what it showed before.
- **Refusing**: a draft a seat cannot take (an empty pad name or one over
  80 characters, said in the line under the page in
  `PadNameDraft.validationMessage`'s words; a sealed name outside its
  charset, 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`, refused
  core-side per [ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md))
  is said beside the seat or in the line under the page, with the field
  still open; it is never a dialog.
- **Showing**: a typed name is drawn in the seat; a default is drawn in
  the default's own shape. Where a default stands beside a name, the name
  takes the seat and the default follows it to the right.

Exemption: creating a pad has no seat to edit in until a new cell exists
for it. It stays as built, a sheet, until a contract row gives it a seat;
the maintainer's instruction names the pad list's Rename only.

## The contract

The table is the test list. Tests are cited by file and function; a row
without a test says what it is owed by.

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| Return over a changed draft | committing | the trimmed draft becomes the name | `TabRenameTests.swift` `testReturnOverANewNameRenames`, `testTheNameIsTrimmedBeforeItIsJudged` |
| Return over an untouched draft | keeping | nothing changes; a default is never frozen into a typed name by a Return | `TabRenameTests.swift` `testReturnOverAnUntouchedDraftKeeps` |
| Return over an empty draft | committing | the typed name is cleared and the default derives again; a pad, which has no default, refuses it (row below) | `TabRenameTests.swift` `testAnEmptyNameIsARenameNotACancel` |
| Escape, or the keyboard leaving | keeping | the seat shows what it showed before | `TabRenameTests.swift` `testEscapeAndFocusLossKeepWhateverTheDraftSays` |
| any opening | opening | no modal session is entered on the way in or out | `ModalSessionTests.swift` `testRenameNeverRunsAModalSession` |
| the draft while open | drafting | VoiceOver hears the draft, not the label it replaced | `DayScrollTests.swift` `testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft` |
| the slot reassigned under the field | keeping | the field ends without renaming the replacement | `DayScrollTests.swift` `testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement` |
| the gutter's hit target while open | opening | the field, not the composed header, takes the click | `DayScrollTests.swift` `testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename` |
| the gutter at rest | showing | the day once, then the time; only a typed name is drawn | `DayScrollProjectionTests.swift` `testADaysFirstGutterCarriesTheDayAndTheRestTheTimeAlone`, `testTheGutterDrawsOnlyATypedName`; `DayScrollTests.swift` `testAGutterDrawsATypedNameAndNoGauge`; `StreamNavigatorTests.swift` `testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage` |
| the gutter's menu | opening | *Rename page…* opens the field in the gutter | `DayScrollTests.swift` `testTheDayGutterOffersTheSameVerbsAsTheStrip` |
| a click on the gutter's time | opening | opens the field in the time's seat; the time slides right of the field and stays there once a name is typed, `today · Deploy notes · 13:00`, `Rotate keys · 13:41` | owed: no issue yet; `DayHeaderView.dayText` and `place` change |
| the strip's *Rename tab…* | opening | opens the field in the tab; double click stays the hold | outcomes through `TabRename` (rows above); the field itself: owed, no issue yet |
| the pad list's *Rename pad…* | opening | opens the field in the pad's cell, the only way in: a click on the cell activates the pad; the *Rename pad* sheet, its Rename and Cancel buttons and the strings `pad.rename.title` and `pad.rename` go | owed: no issue yet; the contradicting build is `PadPickerView.nameEditor` |
| a pad name the catalog refuses, empty or over 80 characters | refusing | said in the line under the page with the field still open, `pad.name.empty`'s words for an empty one | owed: no issue yet; `PadNameDraft.validationMessage` supplies the words |
| a sealed object's *Name…*, *Rename…*, or a double click on an unnamed row or a named row's name zone | opening | opens the field in the name's seat, placeholder `NAME`; the excerpt stays to its right; a double click on the value or `=` zone copies once and opens nothing | owed: no issue yet; Law 0001's 2026-10-13 amendment |
| a sealed name outside 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*` | refusing | the core refuses it and the name stays as it was; the line under the page says why, with the field still open | owed: issue 241 (the core's refusal), issue 245 (the field) |

## What the rule forbids

- A sheet, alert, panel or popover whose purpose is to take a name.
- A field that moves the label, reflows its neighbours or hides the
  default the name sits beside.
- A Return that freezes an untouched default into a typed name.
- A focus loss that commits.
- A periodic pass that writes a label over an open draft.
- A refusal that interrupts: validation is a line, never a dialog.
- A name field with no keyboard route in: every seat has a menu verb, and
  a click or double click is in addition to it, never instead of it.

## The rubric for a new interaction

- **Seat**: is the name edited where it is drawn, in the same seat and
  face? (opening)
- **Draft**: does the field open on the current text, selected whole, and
  does nothing else rewrite it while open? (drafting)
- **Ending**: does Return commit through `TabRename`, and does everything
  else keep? (committing, keeping)
- **Default**: can an empty commit return the seat to its default, and
  does the default stay visible to the right of a typed name? (showing)
- **Interruption**: does any step enter a modal session or ask a question
  in a dialog? (refusing)
- **Route**: is there a menu verb, so the keyboard and VoiceOver can open
  the field without a pointer gesture? (opening)

## Acceptance and tests

Shell (`shell/Tests/CompanionKitTests`): `TabRenameTests` (the five
outcome tests), `ModalSessionTests.testRenameNeverRunsAModalSession`,
`DayScrollTests` (`testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft`,
`testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement`,
`testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename`,
`testAGutterDrawsATypedNameAndNoGauge`,
`testTheDayGutterOffersTheSameVerbsAsTheStrip`),
`DayScrollProjectionTests` (the two gutter tests above),
`StreamNavigatorTests.testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage`.

Core and seam: a name is page-owned text; `companion_tab_set_title`
(`crates/ffi/src/lib.rs`) carries the tab's, capped core-side. The pad's
goes through the catalog (`PadCatalogTests`). The sealed object's is owed
with Law 0001's amendment, refused core-side outside ADR-0042's charset.

Tests that pin the contradicting build and are rewritten when the owed
rows land: none named; `PadPickerView.nameEditor` has no test of its own.

Owed: the gutter's click and the time to the right; the pad cell's field
and the sheet's removal; the sealed object's name field; a test for the
strip's field.

## Amendments

- 2026-10-13: Accepted. Built from the maintainer's instruction of the
  same day and the two records that already held the tab and gutter
  renames. The gutter's click, the pad list's field and the sealed
  object's name are owed rows.
- 2026-10-13: ADR-0042 amendment.
  [ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md)
  settles what this law left open. A pad cell is no longer a double click
  seat, since its first click activates the pad and closes the list; only
  *Rename pad…* opens it, as only *Rename tab…* opens the strip. On a
  named sealed row only the name zone's double click opens the field.
  A pad has no default, so an empty pad name is refused in the line under
  the page, in `pad.name.empty`'s words, with the field open. The sealed
  name's charset is 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`, case
  kept, refused core-side. The paragraph under the rule, the Opening,
  Committing and Refusing classes and four rows change; one row is added.
