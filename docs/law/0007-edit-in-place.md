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
  - shell/Sources/CompanionKit/TabRename.swift (one rule for every field's ending; `TabRename.Field`, the SwiftUI fields' state)
  - shell/Sources/CompanionKit/DayScrollView.swift (`DayHeaderView.beginRename`, `endRename`, `opensRename`, `keyboardToReturn`, `words`, `seat`, `drawsTitle`)
  - shell/Sources/CompanionKit/TabStripView.swift (`beginRename`, `renameField`, `endRename`)
  - shell/Sources/CompanionKit/PadPickerView.swift (`PadRename`, the cell's field; `PadPickerRoutes`, the list's routes; `PadNameDraft`; `nameEditor`, now the create sheet alone)
  - shell/Sources/CompanionKit/PageModel.swift (`renameTab`, `renamePad`, `setChipName`, `holdNotice`, `releaseNotice`)
  - shell/Sources/CompanionKit/SealedNameField.swift (`ChipRename`, the sealed name field's state; `SealedNameEditor`, its AppKit field)
  - docs/adr/0017-durable-tabs-expiring-pages.md (a tab's name outlives its pages)
  - docs/qa/verification-procedures/rename-in-place.md (the hand checks the runner cannot make)
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
or panel is involved at any step. Where the seat shows a default beside
the name, the default keeps showing to the right of the text once a name
is typed.

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
  seat has no other click (the gutter's time, or the typed name that took
  its seat); a double click where the
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
| a click on the gutter's time, or on the typed name standing in its seat | opening | opens the field in the time's seat on what the seat showed; the time slides right of the field and stays there once a name is typed, `today · Deploy notes · 13:00`, `Rotate keys · 13:41`; a long name gives way before the time does; Return and Escape give the keys back to the page. The name is the slot's (ADR-0017: "Tab identity, order, name, and keyboard position survive every Page that lived in the slot"), so a page minted into a named empty slot reads the name | `DayScrollTests.swift` `testAClickOnTheGutterTimeOpensTheFieldAndOnTheDayFocuses`, `testANamedGutterReadsTheDayTheNameAndTheTime`, `testAClickOnATypedNameOrItsTimeOpensTheFieldOnTheName`, `testALongNameOnANarrowGutterLeavesTheTimeWhole`, `testAFieldOpenedOverAnotherGivesTheKeysBackToThePage`, `testAPageMintedIntoALabelledSlotReadsTheSlotsLabel`; `DayScrollProjectionTests.swift` `testAnUnnamedGuttersDraftIsTheTime`; in a real key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the strip's *Rename tab…* | opening | opens the field in the tab; double click stays the hold | `TabRenameTests.swift` `testTheFieldOpensOnTheCurrentTitle`, `testAnUntouchedReturnIsJudgedAgainstWhatTheFieldOpenedOn`, `testTheFieldKeepsTheTitleOnEscapeAndEndsOnce`, over `TabRename.Field`, which the strip and the slot rail call; the SwiftUI field's focus and its selection on focus, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the pad list's *Rename pad…* | opening | opens the field in the pad's cell, the only way in: a click on the cell activates the pad; the *Rename pad* sheet, its Rename and Cancel buttons and the strings `pad.rename.title` and `pad.rename` go | `PadPickerTests.swift` `testReturnInTheCellRenamesThePadAndShutsTheField`, `testAnUntouchedReturnEscapeAndFocusLossKeepTheName`, `testRenamePadOpensTheCellOverTheOpenListAndRaisesNoSheet`, `testNewPadShutsTheListAndKeepsAnOpenFieldsName`, `testTheRenameSheetsStringsAreGoneAndTheCreateSheetsStay`, over `PadRename` and `PadPickerRoutes`; the menu item reaching that route, and the SwiftUI field's focus, selection and Escape, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a pad name the catalog refuses, empty or over 80 characters | refusing | said in the line under the page with the field still open, `pad.name.empty`'s words for an empty one; another notice stands in front of the line for its own dwell and gives it back | `PadPickerTests.swift` `testARefusalKeepsBothTheFieldAndTheLine`, `testANameTheCatalogRefusesIsSaidWithTheFieldOpen`; `NoticeHoldTests.swift` `testAHeldLineOutlastsTheDwellAndGoesWhenReleased`, `testAHeldLineComesBackWhenAFlashInFrontOfItEnds`, `testTheModelsClearsPutAHeldLineBack`; the SwiftUI field keeping its keys after Return over a refused draft, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a sealed object's *Name…*, *Rename…*, or a double click on an unnamed row or a named row's name zone | opening | opens the field in the name's seat, placeholder `NAME`; the excerpt stays to its right; a double click on the value or `=` zone copies once and opens nothing | the core's setter: `store.rs` `a_name_outside_the_charset_is_refused_and_an_empty_one_clears`; `lib.rs` `chip_json_carries_the_name`; the field: `SealedNameFieldTests.swift` `testTheFieldOpensInTheSeatOnTheNameWithTheExcerptToItsRight`, `testTheMenusVerbOpensTheField`, `testADoubleClickOpensTheFieldOnlyWhereTheRuleSays`, `testAReadOnlyPageOpensNoField`, `testReturnNamesTheObjectAndRedrawsItsBlock`, `testEscapeFocusLossAndAnUntouchedReturnKeepAndAnEmptyReturnClears`, `testTheEndingsAreTabRenamesOutcomes`, `testTheObjectOrItsPageLeavingKeepsTheName`, `testThePagesChordsStandAsideForTheField`, `testThePagesMenuActionsStandAsideForTheField`; `SealedCapsuleTests.swift` `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection` (the name zone's double click through `mouseDown`); the double click's timing and the keys in a real key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a sealed name outside 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*` | refusing | the core refuses it and the name stays as it was; the line under the page says why, with the field still open | the core's refusal and its codes: `store.rs` `a_name_outside_the_charset_is_refused_and_an_empty_one_clears`; `lib.rs` `the_name_routes_judge_by_one_rule_and_fail_closed`; `SealedObjectSeamTests.swift` `testTheRefusalIsTheCoresRule`, `testANameRidesTheFaceAndABlankDraftClearsIt`; the field and its line: `SealedNameFieldTests.swift` `testARefusalKeepsTheFieldAndTheLine`, `testTheRefusalsWordsAreTheFieldsOwn`; `NoticeHoldTests.swift` (the held line); the field keeping the keys after Return over a refused draft, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |

## What the rule forbids

- A sheet, alert, panel or popover whose purpose is to take a name.
- A field that moves the label, reflows its neighbours or hides the
  default the name sits beside. The one neighbour that moves is that
  default, which follows the draft to its right, as the gutter's time
  does while the user types.
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
outcome tests and the three `TabRename.Field` tests),
`ModalSessionTests.testRenameNeverRunsAModalSession`,
`DayScrollTests` (`testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft`,
`testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement`,
`testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename`,
`testAGutterDrawsATypedNameAndNoGauge`,
`testTheDayGutterOffersTheSameVerbsAsTheStrip` and the six gutter click
tests in the row for a click on the gutter's time),
`DayScrollProjectionTests` (the two gutter tests above and
`testAnUnnamedGuttersDraftIsTheTime`),
`StreamNavigatorTests.testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage`,
`PadPickerTests` (the seven pad cell tests in the rows above and
`testAFieldMovedToAnotherCellOutlivesTheFocusLossOfTheOneItLeft`),
`NoticeHoldTests`, `SealedNameFieldTests` (the sealed name's field, its
endings and its refusal),
`SealedCapsuleTests.testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`.

By hand: the [rename in place](../qa/verification-procedures/rename-in-place.md)
procedure, for what the runner cannot drive: the SwiftUI fields' focus
and selection, the pad cell's Return and Escape, the gutter's field in
a real key window, and the sealed name's double click and keys. It has
not been run.

Core and seam: a tab's name belongs to the tab and outlives its pages
(ADR-0017); `companion_tab_set_title` (`crates/ffi/src/lib.rs`) carries
it, capped core-side. The pad's
goes through the catalog (`PadCatalogTests`). The sealed object's is
judged by `judge_name` (`crates/core/src/sheet.rs`), which
`companion_chip_set_name` refuses by and `companion_chip_name_refusal`
answers with, so a field can say why a draft will not take while it is
typed ([ADR-0043](../adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md)).

Tests that pin the contradicting build and are rewritten when the owed
rows land: none.

Owed: a first run of the rename in place procedure.

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
- 2026-10-13: Rows amendment (issue 251). Every owed row, and the owed
  list under the tests, points at its issue in epic 252.
- 2026-10-13: Built rows amendment (issues 248, 249, 250). The gutter's
  click, the strip's field and the pad cell's field are built, and
  their four rows name the tests that pin them. The strip's and the pad
  cell's fields are SwiftUI and are not driven under the runner, so
  their state lives in `TabRename.Field` and `PadRename`, which the
  fields call and the tests drive. The sources list follows the code.
- 2026-10-13: Review amendment (issues 248, 249, 250). The Opening
  class and the gutter's row name the typed name as part of the time's
  seat, since a click on it opens the field as a click on the time
  does, and the row records that the name is the slot's, so a page
  minted into a named empty slot reads it (ADR-0017). The forbidden
  list lets the default beside a name follow the draft to its right,
  which the gutter's row already required. The strip's and the pad
  list's rows no longer claim a hand check nobody made: they cite the
  rename in place procedure as owed, and the pad rows cite the
  `PadPickerRoutes` and held line tests. "a name is page-owned text"
  under Acceptance becomes the tab's own name.
- 2026-10-13: Core amendment (issue 241). The sealed name's two rows
  cite the core and seam tests of its setter and refusal, recorded in
  [ADR-0043](../adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md),
  and stay owed for the field. Acceptance names the one rule the setter
  and the handle free judge share.
- 2026-10-13: Sealed name amendment (issue 245). The sealed object's
  field is built: its opening row and its refusing row cite
  `SealedNameFieldTests` and the zone press test, and the rename in
  place procedure gains the double click's and the keys' checks, which
  both rows cite as owed. The owed list keeps only the procedure's
  first run, and the sources name `ChipRename` and `SealedNameEditor`.
- 2026-10-13: Menu route amendment (issue 245). Drafting held for the
  page's chords but not for the Edit menu, whose Undo stepped the page
  under the sealed name's draft. The sealed object's opening row also
  cites the test that the menu's nil-targeted actions pass the page by
  while the field is open, and the procedure's keys check adds the
  menu's Undo.
