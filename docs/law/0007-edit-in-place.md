---
id: 0007-edit-in-place
title: Edit in place
status: accepted     # draft → accepted → superseded
dated: 2026-10-13
governs: A name is edited where it is shown, in its own seat; Return commits, Escape keeps, and nothing asks.
decisions: D-14 and D-46 (docs/spec/design/2026-0915-ui-ux-decisions.md and docs/spec/design/2026-0916-rail-redundancy.md); the maintainer's instruction of 2026-10-13, quoted below; the rows the 2026-10-14 drafts withdrawn amendment names, none numbered and awaiting the maintainer's ratification (the proposed ADR-0042 they cite is under sources, not here)
consumed-by:
  - docs/law/0001-sealed-object.md (the sealed object's name and note, 2026-10-13 amendment; its rows cite this law's keys row)
  - docs/adr/0042-a-sealed-name-is-a-shell-identifier.md (proposed; the sealed name's charset, and an empty draft clearing it)
  - docs/development/sealed-objects-core-interface.md (the name's routes and the keys holder's predicate)
  - docs/mockups/sealed-name-and-note.md (the drawn states; not authoritative)
sources:
  - the maintainer's instruction in the 2026-10-13 design conversation (primary)
  - the drafts ADR-0042, ADR-0043, ADR-0044 and ADR-0046, written 2026-10-13 and withdrawn 2026-10-14 without ratification (the points this law left open, and the page's chords and Edit menu standing aside for any field holding the keys; their content now stands in the rows, in proposed ADR-0042 and ADR-0043, and in the development note)
  - ADR-0042, proposed 2026-10-14 (the sealed name's charset; the rows that cite it rest on a proposal)
  - docs/development/sealed-objects-core-interface.md (`InkTextView.answersChords`, the keys holder's predicate; the name's routes and refusal codes)
  - docs/spec/design/2026-0915-ui-ux-decisions.md, D-14 (no dialogs)
  - docs/spec/design/2026-0916-rail-redundancy.md, D-44 and D-46 (the gutter's time and typed name)
  - shell/Sources/CompanionKit/TabRename.swift (one rule for every field's ending; `TabRename.Field`, the SwiftUI fields' state)
  - shell/Sources/CompanionKit/DayScrollView.swift (`DayHeaderView.beginRename`, `endRename`, `opensRename`, `keyboardToReturn`, `words`, `seat`, `drawsTitle`)
  - shell/Sources/CompanionKit/TabStripView.swift (`beginRename`, `renameField`, `endRename`)
  - shell/Sources/CompanionKit/PadPickerView.swift (`PadRename`, the cell's field; `PadPickerRoutes`, the list's routes; `PadNameDraft`; `nameEditor`, now the create sheet alone)
  - shell/Sources/CompanionKit/PageModel.swift (`renameTab`, `renamePad`, `setChipName`, `holdNotice`, `releaseNotice`, `HeldRefusal`)
  - shell/Sources/CompanionKit/InkEditorView.swift (`InkTextView.answersChords`, whether the page's chords and Edit menu actions are its own to answer)
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
  ([Law 0001](0001-sealed-object.md)'s value and `=` zone rows).
  Opening is not a mutation.
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
  core-side per [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
  proposed)
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
| a chord or an Edit menu item while any seat's field holds the keys | drafting | it acts on the field or on nothing, never on the page: the page's chords, its Undo, Redo, seal and language items stand aside, and the menu greys the page's items until the field closes; any field holds the keys this way, the gutter's, the strip's, the slot rail's, the pad cell's, the sealed name's, the find bar's and a Settings field, in the page's window or in the key window over it, and so does a note's surface, which answers the page's chords and Edit menu only while it holds the keys itself; Choose Language goes to whoever holds the keys; the summon offer's seal button seals nothing and says why (the predicate, `InkTextView.answersChords`, is in the [core interface](../development/sealed-objects-core-interface.md)) | the gutter: `DayScrollTests.swift` `testTheGuttersFieldTakesThePagesChordsAndMenuAway`; the sealed name: `SealedNameFieldTests.swift` `testThePagesChordsStandAsideForTheField`, `testThePagesMenuActionsStandAsideForTheField`; any field in the page's window, the shape the strip's and the pad cell's SwiftUI fields edit through: `KeyHolderTests.swift` `testAFieldHoldingTheKeysTakesThePagesChordsAndMenuAway`; the note holding the keys: `SealedNoteTests.swift` `testTheEditMenuActsOnTheNoteWhileItHoldsTheKeys`; Choose Language sent down the responder chain: `LanguageDetectionMenuTests.swift` `testAChoiceGoesDownTheChainOrToTheFile`; the offer's button under a field and under the note: `SealedFragmentEditorTests.swift` `testTheOffersButtonStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`, on the raised card by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; the strip's and the pad cell's own fields, and the pad cell's popover as the key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the slot reassigned under the field | keeping | the field ends without renaming the replacement | `DayScrollTests.swift` `testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement` |
| the gutter's hit target while open | opening | the field, not the composed header, takes the click | `DayScrollTests.swift` `testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename` |
| the gutter at rest | showing | the day once, then the time; only a typed name is drawn | `DayScrollProjectionTests.swift` `testADaysFirstGutterCarriesTheDayAndTheRestTheTimeAlone`, `testTheGutterDrawsOnlyATypedName`; `DayScrollTests.swift` `testAGutterDrawsATypedNameAndNoGauge`; `StreamNavigatorTests.swift` `testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage` |
| the gutter's menu | opening | *Rename page…* opens the field in the gutter | `DayScrollTests.swift` `testTheDayGutterOffersTheSameVerbsAsTheStrip` |
| a click on the gutter's time, or on the typed name standing in its seat | opening | opens the field in the time's seat on what the seat showed; the time slides right of the field and stays there once a name is typed, `today · Deploy notes · 13:00`, `Rotate keys · 13:41`; a long name gives way before the time does; Return and Escape give the keys back to the page. The name is the slot's (ADR-0017: "Tab identity, order, name, and keyboard position survive every Page that lived in the slot"), so a page minted into a named empty slot reads the name | `DayScrollTests.swift` `testAClickOnTheGutterTimeOpensTheFieldAndOnTheDayFocuses`, `testANamedGutterReadsTheDayTheNameAndTheTime`, `testAClickOnATypedNameOrItsTimeOpensTheFieldOnTheName`, `testALongNameOnANarrowGutterLeavesTheTimeWhole`, `testAFieldOpenedOverAnotherGivesTheKeysBackToThePage`, `testAPageMintedIntoALabelledSlotReadsTheSlotsLabel`; `DayScrollProjectionTests.swift` `testAnUnnamedGuttersDraftIsTheTime`; in a real key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the strip's *Rename tab…* | opening | opens the field in the tab; double click stays the hold | `TabRenameTests.swift` `testTheFieldOpensOnTheCurrentTitle`, `testTheFieldsReturnKeepsAnUntouchedDraftAndRenamesAChangedOne`, `testTheFieldKeepsTheTitleOnEscapeAndEndsOnce`, over `TabRename.Field`, which the strip and the slot rail call, and whose `end` takes no title but the one the field opened on; the SwiftUI field's focus and its selection on focus, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the pad list's *Rename pad…* | opening | opens the field in the pad's cell, the only way in: a click on the cell activates the pad; the *Rename pad* sheet, its Rename and Cancel buttons and the strings `pad.rename.title` and `pad.rename` go | `PadPickerTests.swift` `testReturnInTheCellRenamesThePadAndShutsTheField`, `testAnUntouchedReturnEscapeAndFocusLossKeepTheName`, `testRenamePadOpensTheCellOverTheOpenListAndRaisesNoSheet`, `testNewPadShutsTheListAndKeepsAnOpenFieldsName`, `testTheRenameSheetsStringsAreGoneAndTheCreateSheetsStay`, over `PadRename` and `PadPickerRoutes`; the menu item reaching that route, and the SwiftUI field's focus, selection and Escape, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a pad name the catalog refuses, empty or over 80 characters | refusing | said in the line under the page with the field still open, `pad.name.empty`'s words for an empty one; another notice stands in front of the line for its own dwell and gives it back; the pad list, hung under the picker, ends above the line | `PadPickerTests.swift` `testARefusalKeepsBothTheFieldAndTheLine`, `testANameTheCatalogRefusesIsSaidWithTheFieldOpen`, `testAKeystrokeUnderAFlashLeavesTheFlashStanding`, `testThePadListEndsAboveTheLineUnderThePage`, `testTheRootHandsThePickerTheTopOfTheLineUnderThePage`; `NoticeHoldTests.swift` `testAHeldLineOutlastsTheDwellAndGoesWhenReleased`, `testAHeldLineComesBackWhenAFlashInFrontOfItEnds`, `testTheModelsClearsPutAHeldLineBack`, `testAReHoldUnderAFlashLeavesTheFlashAndItsAction`, `testAReHoldOnScreenChangesTheWordsInPlace`; the SwiftUI field keeping its keys after Return over a refused draft, and the popover on a short card, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a sealed object's *Name…*, *Rename…*, or a double click on an unnamed row or a named row's name zone | opening | opens the field in the name's seat, placeholder `NAME`; the excerpt stays to its right; a double click on the value or `=` zone copies once and opens nothing | the core's setter: `store.rs` `a_name_outside_the_charset_is_refused_and_an_empty_one_clears`; `lib.rs` `chip_json_carries_the_name`; the field: `SealedNameFieldTests.swift` `testTheFieldOpensInTheSeatOnTheNameWithTheExcerptToItsRight`, `testTheMenusVerbOpensTheField`, `testADoubleClickOpensTheFieldOnlyWhereTheRuleSays`, `testAReadOnlyPageOpensNoField`, `testReturnNamesTheObjectAndRedrawsItsBlock`, `testEscapeFocusLossAndAnUntouchedReturnKeepAndAnEmptyReturnClears`, `testTheEndingsAreTabRenamesOutcomes`, `testTheObjectOrItsPageLeavingKeepsTheName`, `testThePagesChordsStandAsideForTheField`, `testThePagesMenuActionsStandAsideForTheField`, `testTheFieldTakesNoDropFromElsewhere`, `testAShutFieldKeepsNoDraft`; `SealedCapsuleTests.swift` `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection` (the name zone's double click through `mouseDown`); the double click's timing and the keys in a real key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
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
`testTheDayGutterOffersTheSameVerbsAsTheStrip`, the six gutter click
tests in the row for a click on the gutter's time and
`testTheGuttersFieldTakesThePagesChordsAndMenuAway`),
`KeyHolderTests.testAFieldHoldingTheKeysTakesThePagesChordsAndMenuAway`,
`DayScrollProjectionTests` (the two gutter tests above and
`testAnUnnamedGuttersDraftIsTheTime`),
`StreamNavigatorTests.testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage`,
`PadPickerTests` (the ten pad cell and pad list tests in the rows above and
`testAFieldMovedToAnotherCellOutlivesTheFocusLossOfTheOneItLeft`),
`NoticeHoldTests`, `SealedNameFieldTests` (the sealed name's field, its
endings and its refusal),
`SealedCapsuleTests.testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`.
App (`shell/Tests/OnetimePadTests`):
`LanguageDetectionMenuTests.testAChoiceGoesDownTheChainOrToTheFile`.

By hand: the [rename in place](../qa/verification-procedures/rename-in-place.md)
procedure, for what the runner cannot drive: the SwiftUI fields' focus
and selection, the pad cell's Return and Escape, the gutter's field in
a real key window, the sealed name's double click and keys, and the
page's chords and Edit menu standing aside for every field. It has not
been run.

Core and seam: a tab's name belongs to the tab and outlives its pages
(ADR-0017); `companion_tab_set_title` (`crates/ffi/src/lib.rs`) carries
it, capped core-side. The pad's
goes through the catalog (`PadCatalogTests`). The sealed object's is
judged by `judge_name` (`crates/core/src/sheet.rs`), which
`companion_chip_set_name` refuses by and `companion_chip_name_refusal`
answers with, so a field can say why a draft will not take while it is
typed ([ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
proposed; the one rule both share, its routes and codes in the
[core interface](../development/sealed-objects-core-interface.md)).

Tests that pin the contradicting build and are rewritten when the owed
rows land: none.

Owed: a first run of the rename in place procedure.

## Amendments

- 2026-10-13: Accepted. Built from the maintainer's instruction of the
  same day and the two records that already held the tab and gutter
  renames. The gutter's click, the pad list's field and the sealed
  object's name are owed rows.
- 2026-10-13: Draft ADR-0042 amendment.
  The draft ADR-0042 (withdrawn 2026-10-14)
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
  draft ADR-0043,
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
- 2026-10-13: Drop and draft amendment (issue 245). A drop from
  elsewhere lands nowhere in the sealed name's field
  (draft ADR-0044), and a
  shut field keeps no draft. The sealed object's opening row cites the
  two tests that pin them.
- 2026-10-13: Held line amendment (issues 245 and 249). A keystroke
  over a draft still refused took down a notice standing in front of
  the refusal, with its action, against the pad row's words. The pad
  row cites the keystroke's test and the two tests of a hold given new
  words under a flash and on screen.
- 2026-10-13: Strip citation amendment (issue 250). The strip's row
  cited a test named for a derived title moving under the field, which
  it never moved and could not fail for: `TabRename.Field.end` takes no
  title to judge against but the one it opened on. The test is renamed
  for what it pins, and the row names that signature.
- 2026-10-13: Key holder amendment (epic 252).
  The draft ADR-0046 (withdrawn 2026-10-14)
  makes the page's chords and Edit menu stand aside for any field that
  holds the keys, where they had stood aside for the sealed name's field
  alone: ⌘Z under a gutter label's draft stepped the page, and Choose
  Language acted on the page whatever held the keys. One row is added
  for Drafting, citing the gutter's, the sealed name's and a plain
  field's tests and the menu's, with the SwiftUI fields and the pad
  cell's popover owed to the procedure, which gains the check. The
  cluster, the sources and the acceptance lists follow, and the sources
  name `HeldRefusal`, the refusal both fields hold.
- 2026-10-13: Short card amendment (issue 249). On a short card the pad
  list's popover, up to 620 points tall under the picker, could stand
  over the line under the page that says a pad name's refusal. The list
  now ends above the status stack's top, and the pad refusal row says so
  and cites the layout rule's test and the test that a root hands the
  picker that top; the popover itself on a short card is owed to the
  procedure, which gains the check.
- 2026-10-14: Offer button amendment (issue 170 and epic 252, applying
  draft ADR-0046's
  predicate, as Law 0001's amendment of this date records). The summon
  offer's seal button is not a chord or a menu item, and it sealed into
  the page while a seat's field held the keys. It now seals nothing
  there and says why. The keys row lists it and cites its test, which
  holds the keys in a field and in the note; the button on the raised
  card is a hand check in the sealed fragment procedure.
- 2026-10-14: Record amendment (epic 252). `decisions` adds draft ADR-0043
  and draft ADR-0044, which the sealed name's rows already build on: the core
  judge and refusal, and no drop from elsewhere into the field.
- 2026-10-14: Drafts withdrawn amendment. The drafts ADR-0042 to ADR-0055,
  written on 2026-10-13 and 2026-10-14, were marked accepted and never
  ratified, and are withdrawn; the entries above name each as a draft.
  The sealed name's charset and an empty draft clearing it rest on
  [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
  proposed; the one rule the setter and the handle free judge share is
  the [core interface](../development/sealed-objects-core-interface.md)'s.
  The rows below carry the drafts' other content on this law itself;
  like every amendment written on this branch, they await the
  maintainer's ratification: a pad cell opening
  only through *Rename pad…* and an empty pad name refused in the line
  (draft ADR-0042 points 5 and 6, already the pad rows); the name zone's
  double click and the zones that ignore the clicks after their first
  (draft ADR-0042 point 3, the Opening class, citing Law 0001's zone
  rows); the field taking no drop from elsewhere (draft ADR-0044 point 4,
  already the sealed object's opening row); and Drafting's keys row,
  which now names every holder, the note's surface among them, and
  Choose Language going to the holder (draft ADR-0046). The predicate's
  name and how the page asks it went to the
  [core interface](../development/sealed-objects-core-interface.md). The
  `decisions`, `consumed-by` and `sources` lists follow.
