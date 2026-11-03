---
id: 0007-edit-in-place
title: Edit in place
status: accepted     # draft → accepted → superseded
dated: 2026-10-13
governs: A name is edited where it is shown, in its own seat; Return commits, Escape keeps, and nothing asks.
decisions: 2026-1031-sealed-content-ux-revision (sealed interface revision); D-14 and D-46 (docs/spec/design/2026-0915-ui-ux-decisions.md and docs/spec/design/2026-0916-rail-redundancy.md); the maintainer's instruction of 2026-10-13, quoted below; the rows the 2026-10-14 drafts withdrawn amendment names, none numbered, ratified by the maintainer 2026-10-16 (ADR-0042, which they cite and which was accepted the same day, is under sources, not here); ADR-0055 point 2
consumed-by:
  - docs/spec/design/2026-1031-sealed-content-ux-revision.md (the sealed interface revision)
  - docs/law/0001-sealed-object.md (the sealed object's name and note, 2026-10-13 amendment; its rows cite this law's keys row)
  - docs/adr/0042-a-sealed-name-is-a-shell-identifier.md (accepted; the sealed name's charset, and an empty draft clearing it)
  - docs/development/sealed-objects-core-interface.md (the name's routes and the keys holder's predicate)
  - docs/mockups/sealed-name-and-note.md (the drawn states; not authoritative)
sources:
  - the maintainer's original 2026-11-03 chat instruction approving implementation of the anchored New Pad form (primary)
  - the maintainer's 2026-10-31 instruction to address the 28-item sealed-content UX audit (quoted in the interface revision)
  - docs/spec/design/2026-1031-sealed-content-ux-revision.md (presentation decisions; unchanged boundary decisions reference their immutable pre-task sources)
  - the maintainer's instruction in the 2026-10-13 design conversation (primary)
  - the drafts ADR-0042, ADR-0043, ADR-0044 and ADR-0046, written 2026-10-13 and withdrawn 2026-10-14 without ratification (the points this law left open, and the page's chords and Edit menu standing aside for any field holding the keys; their content now stands in the rows, in the accepted ADR-0042 and ADR-0043, and in the development note)
  - ADR-0042, proposed 2026-10-14 and accepted 2026-10-16 (the sealed name's charset)
  - docs/development/sealed-objects-core-interface.md (`InkTextView.answersChords`, the keys holder's predicate; the name's routes and refusal codes)
  - docs/spec/design/2026-0915-ui-ux-decisions.md, D-14 (no dialogs)
  - docs/spec/design/2026-0916-rail-redundancy.md, D-44 and D-46 (the gutter's time and typed name)
  - shell/Sources/CompanionKit/TabRename.swift (one rule for every field's ending; `TabRename.Field`, the SwiftUI fields' state)
  - shell/Sources/CompanionKit/DayScrollView.swift (`DayHeaderView.beginRename`, `endRename`, `opensRename`, `keyboardToReturn`, `words`, `seat`, `drawsTitle`)
  - shell/Sources/CompanionKit/TabStripView.swift (`beginRename`, `renameField`, `endRename`)
  - shell/Sources/CompanionKit/PadPickerView.swift (`PadRename`, the row's field; `PadNameDraft`; `PadCreation` and `PadCreateForm`, the anchored creation form)
  - shell/Sources/CompanionKit/PadSettingsView.swift (the Pads tab of Settings; `PadSettingsRoutes`, its routes; the row's field and the refusal under it)
  - shell/Sources/CompanionKit/PageModel.swift (`renameTab`, `renamePad`, `setChipName`)
  - shell/Sources/CompanionKit/InkEditorView.swift (`InkTextView.answersChords`, whether the page's chords and Edit menu actions are its own to answer)
  - shell/Sources/CompanionKit/SealedNameField.swift (`ChipRename`, the sealed name field's state; `SealedNameEditor`, its AppKit field)
  - docs/adr/0017-durable-tabs-expiring-pages.md (a tab's name outlives its pages)
  - docs/qa/verification-procedures/rename-in-place.md (the hand checks the runner cannot make)
---

# Law 0007: Edit in place

Read [behaviour law conventions](README.md) before filing or changing a law.

The [2026-10-31 interface record](../spec/design/2026-1031-sealed-content-ux-revision.md) states the
presentation revision. The operative rows below incorporate that revision;
the dated amendment records its scope. The implementation checklist is a
verification aid, not authority for this law.

## The rule

> A name is edited where it is shown, in its own seat; Return commits,
> Escape keeps, and nothing asks.

The label becomes a field without moving. Whatever stood in the seat when
the field opened (a typed name, a derived first line, a placeholder, a
time) is the draft the field opens on, selected whole. Return hands the
trimmed draft to the model; Escape and the slot being reassigned under the field leave the name as it
was. Focus loss also keeps page, tab and pad drafts. The sealed variable-name
field is the scoped exception: a valid focus loss saves; an invalid draft
stays open for correction, and explicit editor teardown closes it. An
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

- **Opening**: a label becomes a field in its own seat on its current text,
  selected whole. Menu routes include Rename Page, Rename Tab, a pad row's
  Rename, and a sealed object's Set/Edit Variable Name…. The gutter also opens
  by clicking its time or typed name. Sealed identity text has no rename gesture;
  its repeated clicks select. Opening is not a mutation.
- **Drafting**: keystrokes change the field and nothing else. The draft is
  what the seat shows and what VoiceOver hears; a periodic pass that
  rewrites the label never writes over a draft. Nothing persists.
- **Committing**: Return; also Save and valid focus loss for a sealed variable
  name. The draft is trimmed and judged by `TabRename`:
  equal to what the field opened on, it keeps; otherwise it renames. An
  empty draft renames to nothing, which clears the typed name and lets the
  default derive again (the page's first line, the placeholder stamp, the
  time, a sealed object's unnamed row). A pad has no default, so an empty
  pad name is refused instead. A commit is a mutation like any other and
  is not undoable through the field; the next rename is the undo.
- **Keeping**: Escape or Cancel; reassignment or removal of the source. Focus
  loss keeps page, tab and pad drafts. A sealed field saves a valid draft before
  pad navigation or editor handoff; teardown then closes any invalid remainder.
- **Refusing**: a draft a seat cannot take (an empty pad name or one over
  80 characters, said under the pad's field in its row in
  `PadNameDraft.validationMessage`'s words; a sealed name outside its
  charset, 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`, refused
  core-side per [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
  accepted)
  is said beside the field while it remains open. Sealed-name validation uses
  the anchored helper rather than the shared footer; it is never a dialog.
- **Showing**: a typed name is drawn in the seat; a default is drawn in
  the default's own shape. Where a default stands beside a name, the name
  takes the seat and the default follows it to the right.

Exemption: creating a pad has no seat to edit in until a new row exists
for it. T󠄁h󠄁e󠄁 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁1󠄁-󠄁0󠄁3󠄁 a󠄁p󠄁p󠄁r󠄁o󠄁v󠄁a󠄁l󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁s󠄁 i󠄁t󠄁s󠄁 s󠄁h󠄁e󠄁e󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁 a f󠄁o󠄁r󠄁m󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 t󠄁o󠄁
the pad p󠄁i󠄁c󠄁k󠄁e󠄁r󠄁,󠄁 o󠄁r󠄁 t󠄁o󠄁 N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 i󠄁n󠄁 S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁.󠄁 T󠄁h󠄁i󠄁s󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 f󠄁l󠄁o󠄁w󠄁 i󠄁s󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁
f󠄁r󠄁o󠄁m󠄁 r󠄁e󠄁n󠄁a󠄁m󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 p󠄁a󠄁d󠄁 i󠄁n󠄁 i󠄁t󠄁s󠄁 r󠄁o󠄁w󠄁.󠄁

## The contract

The table is the test list. Tests are cited by file and function; a row
without a test says what it is owed by.

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| a󠄁 N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁e󠄁r󠄁'󠄁s󠄁 e󠄁n󠄁a󠄁b󠄁l󠄁e󠄁d󠄁 s󠄁t󠄁a󠄁t󠄁e󠄁 b󠄁e󠄁c󠄁o󠄁m󠄁e󠄁s󠄁 f󠄁a󠄁l󠄁s󠄁e󠄁 | k󠄁e󠄁e󠄁p󠄁i󠄁n󠄁g󠄁 | d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁 t󠄁h󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 f󠄁o󠄁r󠄁m󠄁 p󠄁a󠄁s󠄁s󠄁i󠄁v󠄁e󠄁l󠄁y󠄁,󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁i󠄁n󠄁g󠄁 i󠄁t󠄁s󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 a󠄁n󠄁d󠄁 c󠄁l󠄁e󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 a󠄁t󠄁t󠄁e󠄁m󠄁p󠄁t󠄁e󠄁d󠄁-󠄁s󠄁u󠄁b󠄁m󠄁i󠄁t󠄁/󠄁f󠄁a󠄁i󠄁l󠄁u󠄁r󠄁e󠄁 f󠄁e󠄁e󠄁d󠄁b󠄁a󠄁c󠄁k󠄁;󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁 w󠄁o󠄁r󠄁k󠄁 i󠄁s󠄁 c󠄁a󠄁n󠄁c󠄁e󠄁l󠄁l󠄁e󠄁d󠄁 w󠄁i󠄁t󠄁h󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 a󠄁n󠄁d󠄁 r󠄁e󠄁o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁e󠄁d󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 i󠄁n󠄁 t󠄁h󠄁e󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 | `PadCreateFormTests.swift` `testDisablingThePresenterDismissesTheFormAndRetainsItsDraft`,󠄁 `testNativeOutsideDismissalRetainsTheDraftForReopening`;󠄁 t󠄁h󠄁e󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 c󠄁a󠄁r󠄁d󠄁-󠄁r󠄁e󠄁s󠄁t󠄁 a󠄁n󠄁d󠄁 a󠄁p󠄁p󠄁-󠄁d󠄁e󠄁a󠄁c󠄁t󠄁i󠄁v󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 p󠄁a󠄁t󠄁h󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 o󠄁w󠄁e󠄁d󠄁 i󠄁n󠄁 [r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 i󠄁n󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁](../qa/verification-procedures/rename-in-place.md) |
| a󠄁 p󠄁a󠄁d󠄁-󠄁n󠄁u󠄁m󠄁b󠄁e󠄁r󠄁 s󠄁h󠄁o󠄁r󠄁t󠄁c󠄁u󠄁t󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 i󠄁s󠄁 e󠄁d󠄁i󠄁t󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 a󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁 | d󠄁r󠄁a󠄁f󠄁t󠄁i󠄁n󠄁g󠄁 | c󠄁o󠄁n󠄁s󠄁u󠄁m󠄁e󠄁 a󠄁 p󠄁a󠄁d󠄁-󠄁o󠄁w󠄁n󠄁e󠄁d󠄁 C󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁-󠄁d󠄁i󠄁g󠄁i󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁 c󠄁h󠄁a󠄁n󠄁g󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁d󠄁 o󠄁r󠄁 p󠄁a󠄁g󠄁e󠄁;󠄁 i󠄁n󠄁s󠄁p󠄁e󠄁c󠄁t󠄁 t󠄁h󠄁e󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁'󠄁s󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁,󠄁 f󠄁a󠄁l󠄁l󠄁i󠄁n󠄁g󠄁 b󠄁a󠄁c󠄁k󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 k󠄁e󠄁y󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 o󠄁n󠄁l󠄁y󠄁 w󠄁h󠄁e󠄁n󠄁 t󠄁h󠄁e󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 h󠄁a󠄁s󠄁 n󠄁o󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁;󠄁 t󠄁h󠄁i󠄁s󠄁 a󠄁p󠄁p󠄁l󠄁i󠄁e󠄁s󠄁 t󠄁o󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 a󠄁n󠄁d󠄁 o󠄁t󠄁h󠄁e󠄁r󠄁 t󠄁e󠄁x󠄁t󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁s󠄁;󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁l󠄁y󠄁 u󠄁n󠄁b󠄁o󠄁u󠄁n󠄁d󠄁 a󠄁n󠄁d󠄁 r󠄁e󠄁m󠄁a󠄁p󠄁p󠄁e󠄁d󠄁 c󠄁h󠄁o󠄁r󠄁d󠄁s󠄁 k󠄁e󠄁e󠄁p󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 c󠄁o󠄁n󠄁f󠄁i󠄁g󠄁u󠄁r󠄁e󠄁d󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 | `PadPickerTests.swift` `testClaimedPadDigitsAreConsumedDuringFieldEditingWithoutSwitchingPads`,󠄁 `testPadShortcutFieldDetectionUsesTheEventWindowBeforeItsKeyWindowFallback`,󠄁 `testRemappedAndUnboundDigitsKeepTheirExistingRouteDuringCreation` |
| a󠄁 p󠄁a󠄁d󠄁-󠄁n󠄁u󠄁m󠄁b󠄁e󠄁r󠄁 s󠄁h󠄁o󠄁r󠄁t󠄁c󠄁u󠄁t󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 a󠄁n󠄁y󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 f󠄁o󠄁r󠄁m󠄁 i󠄁s󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁e󠄁d󠄁 | d󠄁r󠄁a󠄁f󠄁t󠄁i󠄁n󠄁g󠄁 | c󠄁o󠄁n󠄁s󠄁u󠄁m󠄁e󠄁 a󠄁 p󠄁a󠄁d󠄁-󠄁o󠄁w󠄁n󠄁e󠄁d󠄁 C󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁-󠄁d󠄁i󠄁g󠄁i󠄁t󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 s󠄁h󠄁a󠄁r󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 f󠄁o󠄁r󠄁m󠄁 i󠄁s󠄁 o󠄁p󠄁e󠄁n󠄁,󠄁 i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁i󠄁n󠄁g󠄁 w󠄁h󠄁e󠄁n󠄁 t󠄁h󠄁e󠄁 n󠄁a󠄁m󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 h󠄁a󠄁s󠄁 l󠄁o󠄁s󠄁t󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁;󠄁 i󠄁n󠄁d󠄁e󠄁p󠄁e󠄁n󠄁d󠄁e󠄁n󠄁t󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 r󠄁e󠄁g󠄁i󠄁s󠄁t󠄁e󠄁r󠄁e󠄁d󠄁 u󠄁n󠄁t󠄁i󠄁l󠄁 e󠄁a󠄁c󠄁h󠄁 c󠄁l󠄁o󠄁s󠄁e󠄁s󠄁 | `PadPickerTests.swift` `testClaimedPadDigitsAreConsumedWhileAnyCreationFormIsPresented`;󠄁 `PadCreateFormTests.swift` `testNativeFormSuspendsPadShortcutsAfterTheNameFieldResignsFocus`;󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 b󠄁u󠄁t󠄁t󠄁o󠄁n󠄁-󠄁f󠄁o󠄁c󠄁u󠄁s󠄁e󠄁d󠄁 a󠄁p󠄁p󠄁-󠄁s󠄁u󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 o󠄁w󠄁e󠄁d󠄁 i󠄁n󠄁 [r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 i󠄁n󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁](../qa/verification-procedures/rename-in-place.md) |
| r󠄁e󠄁t󠄁u󠄁r󠄁n󠄁i󠄁n󠄁g󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁 t󠄁o󠄁 a󠄁n󠄁 a󠄁l󠄁r󠄁e󠄁a󠄁d󠄁y󠄁 o󠄁p󠄁e󠄁n󠄁e󠄁d󠄁 N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 n󠄁a󠄁m󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 | d󠄁r󠄁a󠄁f󠄁t󠄁i󠄁n󠄁g󠄁 | o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 o󠄁r󠄁 r󠄁e󠄁o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 w󠄁h󠄁o󠄁l󠄁e󠄁 i󠄁n󠄁 t󠄁h󠄁e󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁;󠄁 s󠄁u󠄁b󠄁s󠄁e󠄁q󠄁u󠄁e󠄁n󠄁t󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁 c󠄁h󠄁a󠄁n󠄁g󠄁e󠄁s󠄁 d󠄁o󠄁 n󠄁o󠄁t󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁 a󠄁 c󠄁h󠄁o󠄁s󠄁e󠄁n󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 w󠄁i󠄁t󠄁h󠄁 d󠄁e󠄁f󠄁e󠄁r󠄁r󠄁e󠄁d󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁-󠄁a󠄁l󠄁l󠄁 | o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁:󠄁 `PadCreateFormTests.swift` `testNativeOutsideDismissalRetainsTheDraftForReopening`,󠄁 `testDisablingThePresenterDismissesTheFormAndRetainsItsDraft`;󠄁 l󠄁a󠄁t󠄁e󠄁r󠄁 r󠄁e󠄁f󠄁o󠄁c󠄁u󠄁s󠄁 a󠄁n󠄁d󠄁 m󠄁o󠄁u󠄁s󠄁e󠄁 c󠄁a󠄁r󠄁e󠄁t󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁m󠄁e󠄁n󠄁t󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 o󠄁w󠄁e󠄁d󠄁 i󠄁n󠄁 [r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 i󠄁n󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁](../qa/verification-procedures/rename-in-place.md) |
| N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 s󠄁w󠄁i󠄁t󠄁c󠄁h󠄁e󠄁r󠄁 o󠄁r󠄁 S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁 | o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁,󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁i󠄁n󠄁g󠄁,󠄁 c󠄁o󠄁m󠄁m󠄁i󠄁t󠄁t󠄁i󠄁n󠄁g󠄁 o󠄁r󠄁 k󠄁e󠄁e󠄁p󠄁i󠄁n󠄁g󠄁 | a󠄁n󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁m󠄁 o󠄁p󠄁e󠄁n󠄁s󠄁 a󠄁t󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁i󠄁t󠄁i󠄁a󠄁t󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁;󠄁 R󠄁e󠄁t󠄁u󠄁r󠄁n󠄁 o󠄁r󠄁 C󠄁r󠄁e󠄁a󠄁t󠄁e󠄁 P󠄁a󠄁d󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁 a󠄁c󠄁t󠄁i󠄁v󠄁a󠄁t󠄁e󠄁s󠄁 a󠄁 p󠄁a󠄁d󠄁 w󠄁i󠄁t󠄁h󠄁 a󠄁 t󠄁r󠄁i󠄁m󠄁m󠄁e󠄁d󠄁 v󠄁a󠄁l󠄁i󠄁d󠄁 n󠄁a󠄁m󠄁e󠄁;󠄁 i󠄁n󠄁v󠄁a󠄁l󠄁i󠄁d󠄁 n󠄁a󠄁m󠄁e󠄁s󠄁 d󠄁i󠄁s󠄁a󠄁b󠄁l󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 f󠄁e󠄁e󠄁d󠄁b󠄁a󠄁c󠄁k󠄁 s󠄁t󠄁a󠄁y󠄁s󠄁 b󠄁e󠄁s󠄁i󠄁d󠄁e󠄁 t󠄁h󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁;󠄁 a󠄁n󠄁 i󠄁n󠄁i󠄁t󠄁i󠄁a󠄁l󠄁l󠄁y󠄁 e󠄁m󠄁p󠄁t󠄁y󠄁 R󠄁e󠄁t󠄁u󠄁r󠄁n󠄁 e󠄁x󠄁p󠄁l󠄁a󠄁i󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁 m󠄁i󠄁s󠄁s󠄁i󠄁n󠄁g󠄁 n󠄁a󠄁m󠄁e󠄁;󠄁 a󠄁 f󠄁a󠄁i󠄁l󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 l󠄁e󠄁a󠄁v󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 o󠄁p󠄁e󠄁n󠄁 f󠄁o󠄁r󠄁 r󠄁e󠄁t󠄁r󠄁y󠄁;󠄁 a󠄁u󠄁t󠄁o󠄁m󠄁a󠄁t󠄁i󠄁c󠄁 d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁a󠄁l󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 f󠄁o󠄁r󠄁 r󠄁e󠄁o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 c󠄁l󠄁e󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 p󠄁r󠄁i󠄁o󠄁r󠄁 a󠄁t󠄁t󠄁e󠄁m󠄁p󠄁t󠄁e󠄁d󠄁-󠄁s󠄁u󠄁b󠄁m󠄁i󠄁t󠄁 a󠄁n󠄁d󠄁 f󠄁a󠄁i󠄁l󠄁u󠄁r󠄁e󠄁 f󠄁e󠄁e󠄁d󠄁b󠄁a󠄁c󠄁k󠄁;󠄁 E󠄁s󠄁c󠄁a󠄁p󠄁e󠄁 a󠄁n󠄁d󠄁 C󠄁a󠄁n󠄁c󠄁e󠄁l󠄁 c󠄁l󠄁e󠄁a󠄁r󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 | `PadPickerTests.swift` `testCreationTrimsTheNameCreatesOnePadAndClearsTheForm`,󠄁 `testEmptyReturnExplainsTheMissingNameAndCancelClearsTheFeedback`,󠄁 `testInvalidCreationKeepsTheFormOpenWithoutChangingPads`,󠄁 `testAutomaticDismissalRetainsTheDraftWhileCancelDiscardsIt`,󠄁 `testFailedCreationKeepsTheDraftForCorrectionAndRetry`,󠄁 `testNewPadMenuDefersPresentationUntilTheActionReturns`;󠄁 `PadCreateFormTests.swift` `testNativeNameFieldFocusAndReturnCreateThePad`,󠄁 `testNativeEmptyReturnExplainsTheMissingNameWithoutDismissing`,󠄁 `testNativeEscapeClearsTheDraftAndDismissesTheForm`,󠄁 `testNativeOutsideDismissalRetainsTheDraftForReopening`,󠄁 `testNativeAnchorClickClosesTheExistingForm`;󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 c󠄁a󠄁r󠄁d󠄁/󠄁e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁/󠄁S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁m󠄁e󠄁n󠄁t󠄁,󠄁 C󠄁a󠄁n󠄁c󠄁e󠄁l󠄁 c󠄁l󠄁i󠄁c󠄁k󠄁,󠄁 b󠄁u󠄁t󠄁t󠄁o󠄁n󠄁-󠄁f󠄁o󠄁c󠄁u󠄁s󠄁e󠄁d󠄁 E󠄁s󠄁c󠄁a󠄁p󠄁e󠄁,󠄁 a󠄁p󠄁p󠄁e󠄁a󠄁r󠄁a󠄁n󠄁c󠄁e󠄁 a󠄁n󠄁d󠄁 V󠄁o󠄁i󠄁c󠄁e󠄁O󠄁v󠄁e󠄁r󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 o󠄁w󠄁e󠄁d󠄁 i󠄁n󠄁 [r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 i󠄁n󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁](../qa/verification-procedures/rename-in-place.md) |
| Return over a changed draft | committing | the trimmed draft becomes the name | `TabRenameTests.swift` `testReturnOverANewNameRenames`, `testTheNameIsTrimmedBeforeItIsJudged` |
| Return over an untouched draft | keeping | nothing changes; a default is never frozen into a typed name by a Return | `TabRenameTests.swift` `testReturnOverAnUntouchedDraftKeeps` |
| Return over an empty draft | committing | the typed name is cleared and the default derives again; a pad, which has no default, refuses it (row below) | `TabRenameTests.swift` `testAnEmptyNameIsARenameNotACancel` |
| Escape over any name field, or focus loss over a page/tab/pad name | keeping | the seat shows what it showed before; sealed-name focus loss has its own row below | `TabRenameTests.swift` `testEscapeAndFocusLossKeepWhateverTheDraftSays`; `SealedNameFieldTests.swift` `testCancelKeepsWhileFocusLossAndReturnSave` |
| any opening | opening | no modal session is entered on the way in or out | `ModalSessionTests.swift` `testRenameNeverRunsAModalSession` |
| the draft while open | drafting | VoiceOver hears the draft, not the label it replaced | `DayScrollTests.swift` `testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft` |
| a chord or an Edit menu item while any seat's field holds the keys | drafting | it acts on the field or on nothing, never on the page: the page's chords, its Undo, Redo, seal and language items stand aside, and the menu greys the page's items until the field closes; any field holds the keys this way, the gutter's, the strip's, the sealed name's, the find bar's and a Settings field, in the page's window or in the key window over it, and so does a note's surface, which answers the page's chords and Edit menu only while it holds the keys itself; Choose Language goes to whoever holds the keys; the summon offer's seal button seals nothing and says why (the predicate, `InkTextView.answersChords`, is in the [core interface](../development/sealed-objects-core-interface.md)) | the gutter: `DayScrollTests.swift` `testTheGuttersFieldTakesThePagesChordsAndMenuAway`; the sealed name: `SealedNameFieldTests.swift` `testThePagesChordsStandAsideForTheField`, `testThePagesMenuActionsStandAsideForTheField`; any field in the page's window, the shape the strip's and the pad row's SwiftUI fields edit through: `KeyHolderTests.swift` `testAFieldHoldingTheKeysTakesThePagesChordsAndMenuAway`; the note holding the keys: `SealedNoteTests.swift` `testTheEditMenuActsOnTheNoteWhileItHoldsTheKeys`; Choose Language sent down the responder chain: `LanguageDetectionMenuTests.swift` `testAChoiceGoesDownTheChainOrToTheFile`; the offer's button under a field and under the note: `SealedFragmentEditorTests.swift` `testTheOffersButtonStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`, on the raised card by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; the strip's own field, owed: hand check (the pad row's field stands in the Settings window, where the page's chords and menu items do not reach), [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the slot reassigned under the field | keeping | the field ends without renaming the replacement | `DayScrollTests.swift` `testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement` |
| the gutter's hit target while open | opening | the field, not the composed header, takes the click | `DayScrollTests.swift` `testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename` |
| the gutter at rest | showing | the day once, then the time; only a typed name is drawn | `DayScrollProjectionTests.swift` `testADaysFirstGutterCarriesTheDayAndTheRestTheTimeAlone`, `testTheGutterDrawsOnlyATypedName`; `DayScrollTests.swift` `testAGutterDrawsATypedNameAndNoGauge`; `StreamNavigatorTests.swift` `testTheGutterSaysTheDayOnceAndTheTimeOnEveryPage` |
| the gutter's menu | opening | *Rename Page* opens the field in the gutter | `DayScrollTests.swift` `testTheDayGutterOffersTheSameVerbsAsTheStrip` |
| a click on the gutter's time, or on the typed name standing in its seat | opening | opens the field in the time's seat on what the seat showed; the time slides right of the field and stays there once a name is typed, `today · Deploy notes · 13:00`, `Rotate keys · 13:41`; a long name gives way before the time does; Return and Escape give the keys back to the page. The name is the slot's (ADR-0017: "Tab identity, order, name, and keyboard position survive every Page that lived in the slot"), so a page minted into a named empty slot reads the name | `DayScrollTests.swift` `testAClickOnTheGutterTimeOpensTheFieldAndOnTheDayFocuses`, `testANamedGutterReadsTheDayTheNameAndTheTime`, `testAClickOnATypedNameOrItsTimeOpensTheFieldOnTheName`, `testALongNameOnANarrowGutterLeavesTheTimeWhole`, `testAFieldOpenedOverAnotherGivesTheKeysBackToThePage`, `testAPageMintedIntoALabelledSlotReadsTheSlotsLabel`; `DayScrollProjectionTests.swift` `testAnUnnamedGuttersDraftIsTheTime`; in a real key window, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| the strip's *Rename Tab* | opening | opens the field in the tab; double click stays the hold | `TabRenameTests.swift` `testTheFieldOpensOnTheCurrentTitle`, `testTheFieldsReturnKeepsAnUntouchedDraftAndRenamesAChangedOne`, `testTheFieldKeepsTheTitleOnEscapeAndEndsOnce`, over `TabRename.Field`, which the strip calls, and whose `end` takes no title but the one the field opened on; the SwiftUI field's focus and its selection on focus, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a pad row's *Rename*, on its actions menu in the Pads tab of Settings | opening | opens the field in the pad's row, the only way in; the *Rename pad* sheet, its Rename and Cancel buttons and the strings `pad.rename.title` and `pad.rename` go | `PadPickerTests.swift` `testReturnInTheRowRenamesThePadAndShutsTheField`, `testAnUntouchedReturnEscapeAndFocusLossKeepTheName`, `testRenameOpensTheFieldInTheRowAndRaisesNoSheet`, `testNewPadOpensTheFormAndKeepsAnOpenFieldsName`,󠄁 `testTheRenameStringsAreGoneAndTheCreateStringsStay`,󠄁 over `PadRename` and `PadSettingsRoutes`; the menu item reaching that route, and the SwiftUI field's focus, selection and Escape, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a pad name the catalog refuses, empty or over 80 characters | refusing | said under the field in the pad's row with the field still open, `pad.name.empty`'s words for an empty one; nothing is said under a page, which stands in another window | `PadPickerTests.swift` `testARefusalIsSaidUnderTheFieldWithTheFieldOpen`, `testANameTheCatalogRefusesIsSaidWithTheFieldOpen`; the SwiftUI field keeping its keys after Return over a refused draft, owed: hand check, [rename in place](../qa/verification-procedures/rename-in-place.md) |
| a sealed object's Set Variable Name… or Edit Variable Name… | opening | opens the inline field on its name, selected whole, with API_KEY as the example, format guidance and visible Save/Cancel and Return/Esc instructions; identity clicks do not open it | `SealedNameFieldTests.swift` `testTheFieldOpensWithItsVariableNameInstructionsAndActions`, `testTheMenusVerbOpensTheField`, `testAReadOnlyPageOpensNoField`, `testNamingHelpKeepsItsControlsInsideVeryNarrowAndWideBounds`;󠄁 `SealedCapsuleTests.swift` `testTheIdentityRowAlwaysSelectsWithoutCopyingOrRenaming` |
| Return, Save or valid focus loss over a sealed variable-name draft | committing | saves the trimmed draft; an empty draft clears the name; Escape or Cancel discards the draft instead | `SealedNameFieldTests.swift` `testReturnNamesTheObjectAndRedrawsItsBlock`, `testCancelKeepsWhileFocusLossAndReturnSave`, `testTheVisibleSaveAndCancelButtonsEndTheEdit`, `testTheEndingsAreTabRenamesOutcomes` |
| invalid focus loss over a sealed variable-name draft | refusing | retains the draft with local feedback a󠄁n󠄁d󠄁 r󠄁e󠄁t󠄁u󠄁r󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁 k󠄁e󠄁y󠄁b󠄁o󠄁a󠄁r󠄁d󠄁 t󠄁o󠄁 i󠄁t󠄁s󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 s󠄁o󠄁 i󠄁t󠄁 c󠄁a󠄁n󠄁 b󠄁e󠄁 c󠄁o󠄁r󠄁r󠄁e󠄁c󠄁t󠄁e󠄁d󠄁 | `SealedNameFieldTests.swift` `testAnInvalidFocusLossKeepsTheDraftOpenForCorrection`,󠄁 `testInvalidBlurDefersRefocusAndKeepsTheDraftEditable`,󠄁 `testCancelInvalidatesPendingInvalidDraftRefocus`,󠄁 `testWindowTeardownInvalidatesPendingInvalidDraftRefocus` |
| pad navigation, editor handoff or loss of editability with a sealed field open | committing or keeping | saves a valid draft before storage detaches; closes an invalid remainder; does not rename a removed or expired source | `SealedNameFieldTests.swift` `testRemovalCancelsWhileLosingEditabilitySavesTheName`, `testLeavingThePageSavesAValidNameBeforeDetachingItsStorage`, `testTeardownClosesInvalidDraftsWithoutChangingTheName`; `SealedUXIntegrationTests.swift` `testReplacingAContinuousDocumentSavesItsOpenVariableName`, `testPadActivationCreationAndRemovalSaveTheNameBeforeSuspendingTheDocument`; expiry: `SealedNoteTests.swift` `testANoteEditStepOrNamePastItsPagesDeadlineSettlesWithTheExpiredLine` |
| a sealed name outside 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*` | refusing | applies the existing [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md) rule; keeps the name unchanged and shows the error beside the field, updating it as the draft changes | `SealedObjectSeamTests.swift` `testTheRefusalIsTheCoresRule`, `testANameRidesTheFaceAndABlankDraftClearsIt`; `SealedNameFieldTests.swift` `testARefusalStaysBesideTheFieldAndUpdatesAsTheDraftChanges`, `testTheRefusalsWordsAreTheFieldsOwn` |

## What the rule forbids

- A modal or separate window used only to ask for a name. The sealed field
  may show anchored instructions, validation and controls in the existing window.
- A field that moves the label, reflows its neighbours or hides the
  default the name sits beside. The one neighbour that moves is that
  default, which follows the draft to its right, as the gutter's time
  does while the user types.
- A Return that freezes an untouched default into a typed name.
- A focus loss that commits a page, tab or pad name; the sealed variable-name
  exception is explicit in its contract rows.
- A periodic pass that writes a label over an open draft.
- A refusal that interrupts: validation is a line, never a dialog.
- A name field with no keyboard route in: every seat has a menu verb, and
  a click or double click is in addition to it, never instead of it.

## The rubric for a new interaction

- **Seat**: is the name edited where it is drawn, in the same seat and
  face? (opening)
- **Draft**: does the field open on the current text, selected whole, and
  does nothing else rewrite it while open? (drafting)
- **Ending**: does Return commit through `TabRename`, and do page/tab/pad
  fields keep on focus loss, while sealed fields save a valid
  focus-loss draft and keep Escape as cancellation? (committing, keeping)
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
`PadPickerTests` (the seven pad row tests in the rows above and
`testAFieldMovedToAnotherRowOutlivesTheFocusLossOfTheOneItLeft`),
`SealedNameFieldTests` (the sealed field, local validation, endings and
editor teardown), `SealedUXIntegrationTests` (continuous documents and pad
navigation), and `SealedCapsuleTests.testTheIdentityRowAlwaysSelectsWithoutCopyingOrRenaming`.
App (`shell/Tests/OnetimePadTests`):
`LanguageDetectionMenuTests.testAChoiceGoesDownTheChainOrToTheFile`.

By hand: the [rename in place](../qa/verification-procedures/rename-in-place.md)
procedure, for what the runner cannot drive: the SwiftUI fields' focus
and selection, the pad row's Return and Escape, the gutter's field in
a real key window, the sealed field's explicit menu route and keys, and the
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
accepted; the one rule both share, its routes and codes in the
[core interface](../development/sealed-objects-core-interface.md)).

Tests that pin the contradicting build and are rewritten when the owed
rows land: none.

Owed: a first run of the rename in place procedure.

## Amendments

- 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁1󠄁-󠄁0󠄁3󠄁:󠄁 T󠄁h󠄁e󠄁 t󠄁h󠄁i󠄁r󠄁d󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 p󠄁a󠄁s󠄁s󠄁 c󠄁o󠄁n󠄁s󠄁u󠄁m󠄁e󠄁s󠄁 s󠄁u󠄁s󠄁p󠄁e󠄁n󠄁d󠄁e󠄁d󠄁 p󠄁a󠄁d󠄁-󠄁o󠄁w󠄁n󠄁e󠄁d󠄁 d󠄁i󠄁g󠄁i󠄁t󠄁s󠄁
  b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 S󠄁w󠄁i󠄁f󠄁t󠄁U󠄁I󠄁'󠄁s󠄁 p󠄁a󠄁g󠄁e󠄁-󠄁s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 c󠄁a󠄁n󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁e󠄁 t󠄁h󠄁e󠄁m󠄁.󠄁 T󠄁h󠄁e󠄁 s󠄁h󠄁a󠄁r󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁m󠄁
  r󠄁e󠄁g󠄁i󠄁s󠄁t󠄁e󠄁r󠄁s󠄁 e󠄁a󠄁c󠄁h󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 w󠄁i󠄁t󠄁h󠄁 t󠄁h󠄁e󠄁 m󠄁o󠄁d󠄁e󠄁l󠄁,󠄁 s󠄁o󠄁 s󠄁u󠄁s󠄁p󠄁e󠄁n󠄁s󠄁i󠄁o󠄁n󠄁 a󠄁l󠄁s󠄁o󠄁 c󠄁o󠄁v󠄁e󠄁r󠄁s󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁
  o󠄁u󠄁t󠄁s󠄁i󠄁d󠄁e󠄁 i󠄁t󠄁s󠄁 n󠄁a󠄁m󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁.󠄁 I󠄁n󠄁i󠄁t󠄁i󠄁a󠄁l󠄁 w󠄁h󠄁o󠄁l󠄁e󠄁-󠄁d󠄁r󠄁a󠄁f󠄁t󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 r󠄁u󠄁n󠄁s󠄁 o󠄁n󠄁c󠄁e󠄁 p󠄁e󠄁r󠄁 o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁;󠄁
  l󠄁a󠄁t󠄁e󠄁r󠄁 r󠄁e󠄁f󠄁o󠄁c󠄁u󠄁s󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁r󠄁v󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 c󠄁h󠄁o󠄁s󠄁e󠄁n󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁.󠄁 N󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 f󠄁i󠄁x󠄁t󠄁u󠄁r󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁 m󠄁a󠄁n󠄁u󠄁a󠄁l󠄁
  b󠄁u󠄁t󠄁t󠄁o󠄁n󠄁-󠄁f󠄁o󠄁c󠄁u󠄁s󠄁,󠄁 m󠄁o󠄁u󠄁s󠄁e󠄁-󠄁c󠄁a󠄁r󠄁e󠄁t󠄁 a󠄁n󠄁d󠄁 V󠄁o󠄁i󠄁c󠄁e󠄁O󠄁v󠄁e󠄁r󠄁 o󠄁b󠄁s󠄁e󠄁r󠄁v󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 d󠄁i󠄁s󠄁t󠄁i󠄁n󠄁c󠄁t󠄁.󠄁

- 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁1󠄁-󠄁0󠄁3󠄁:󠄁 T󠄁h󠄁e󠄁 s󠄁e󠄁c󠄁o󠄁n󠄁d󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 p󠄁a󠄁s󠄁s󠄁 u󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 f󠄁o󠄁r󠄁 p󠄁a󠄁d󠄁-󠄁d󠄁i󠄁g󠄁i󠄁t󠄁
  r󠄁o󠄁u󠄁t󠄁i󠄁n󠄁g󠄁,󠄁 w󠄁i󠄁t󠄁h󠄁 a󠄁 k󠄁e󠄁y󠄁-󠄁w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 f󠄁a󠄁l󠄁l󠄁b󠄁a󠄁c󠄁k󠄁 o󠄁n󠄁l󠄁y󠄁 f󠄁o󠄁r󠄁 a󠄁n󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁 a󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁.󠄁
  P󠄁a󠄁s󠄁s󠄁i󠄁v󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁a󠄁l󠄁 k󠄁e󠄁e󠄁p󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 b󠄁u󠄁t󠄁 c󠄁l󠄁e󠄁a󠄁r󠄁s󠄁 o󠄁l󠄁d󠄁 a󠄁t󠄁t󠄁e󠄁m󠄁p󠄁t󠄁e󠄁d󠄁-󠄁s󠄁u󠄁b󠄁m󠄁i󠄁t󠄁
  a󠄁n󠄁d󠄁 f󠄁a󠄁i󠄁l󠄁u󠄁r󠄁e󠄁 f󠄁e󠄁e󠄁d󠄁b󠄁a󠄁c󠄁k󠄁.󠄁 A󠄁 d󠄁i󠄁s󠄁a󠄁b󠄁l󠄁e󠄁d󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁e󠄁r󠄁 d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 f󠄁o󠄁r󠄁m󠄁,󠄁 a󠄁n󠄁d󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁 a󠄁n󠄁d󠄁
  s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 u󠄁s󠄁e󠄁 t󠄁h󠄁e󠄁 f󠄁o󠄁r󠄁m󠄁'󠄁s󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 l󠄁i󠄁f󠄁e󠄁t󠄁i󠄁m󠄁e󠄁 a󠄁n󠄁d󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁.󠄁
  T󠄁h󠄁e󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁a󠄁c󠄁t󠄁 d󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁u󠄁i󠄁s󠄁h󠄁e󠄁s󠄁 n󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 f󠄁i󠄁x󠄁t󠄁u󠄁r󠄁e󠄁 c󠄁o󠄁v󠄁e󠄁r󠄁a󠄁g󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 a󠄁p󠄁p󠄁-󠄁s󠄁u󠄁r󠄁f󠄁a󠄁c󠄁e󠄁,󠄁
  a󠄁p󠄁p󠄁e󠄁a󠄁r󠄁a󠄁n󠄁c󠄁e󠄁 a󠄁n󠄁d󠄁 s󠄁p󠄁o󠄁k󠄁e󠄁n󠄁-󠄁a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁i󠄁b󠄁i󠄁l󠄁i󠄁t󠄁y󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁 t󠄁h󠄁a󠄁t󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 m󠄁a󠄁n󠄁u󠄁a󠄁l󠄁.󠄁

- 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁1󠄁-󠄁0󠄁3󠄁:󠄁 R󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 f󠄁o󠄁l󠄁l󠄁o󠄁w󠄁-󠄁u󠄁p󠄁 n󠄁a󠄁m󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 g󠄁e󠄁n󠄁e󠄁r󠄁a󠄁l󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁-󠄁e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁
  s󠄁h󠄁o󠄁r󠄁t󠄁c󠄁u󠄁t󠄁 b󠄁e󠄁h󠄁a󠄁v󠄁i󠄁o󠄁r󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁l󠄁y󠄁 a󠄁n󠄁d󠄁 u󠄁p󠄁d󠄁a󠄁t󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 t󠄁e󠄁s󠄁t󠄁s󠄁.󠄁 T󠄁h󠄁e󠄁 p󠄁r󠄁i󠄁m󠄁a󠄁r󠄁y󠄁
  p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁 i󠄁s󠄁 t󠄁h󠄁e󠄁 m󠄁a󠄁i󠄁n󠄁t󠄁a󠄁i󠄁n󠄁e󠄁r󠄁'󠄁s󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁 c󠄁h󠄁a󠄁t󠄁 i󠄁n󠄁s󠄁t󠄁r󠄁u󠄁c󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 r󠄁a󠄁t󠄁h󠄁e󠄁r󠄁
  t󠄁h󠄁a󠄁n󠄁 t󠄁h󠄁i󠄁s󠄁 a󠄁m󠄁e󠄁n󠄁d󠄁m󠄁e󠄁n󠄁t󠄁 o󠄁r󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 d󠄁e󠄁l󠄁i󠄁v󠄁e󠄁r󠄁y󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁.󠄁 N󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁
  c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 s󠄁t󠄁a󠄁t󠄁e󠄁 t󠄁e󠄁s󠄁t󠄁s󠄁.󠄁

- 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁1󠄁-󠄁0󠄁3󠄁:󠄁 T󠄁h󠄁e󠄁 m󠄁a󠄁i󠄁n󠄁t󠄁a󠄁i󠄁n󠄁e󠄁r󠄁 a󠄁p󠄁p󠄁r󠄁o󠄁v󠄁e󠄁d󠄁 t󠄁h󠄁e󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 p󠄁r󠄁o󠄁p󠄁o󠄁s󠄁a󠄁l󠄁:󠄁
  “󠄁A󠄁g󠄁r󠄁e󠄁e󠄁d󠄁,󠄁 l󠄁e󠄁t󠄁'󠄁s󠄁 g󠄁o󠄁 w󠄁i󠄁t󠄁h󠄁 t󠄁h󠄁e󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁m󠄁.󠄁 P󠄁l󠄁e󠄁a󠄁s󠄁e󠄁 i󠄁m󠄁p󠄁l󠄁e󠄁m󠄁e󠄁n󠄁t󠄁 i󠄁t󠄁.󠄁”󠄁 C󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁
  n󠄁o󠄁w󠄁 u󠄁s󠄁e󠄁s󠄁 a󠄁 p󠄁o󠄁p󠄁o󠄁v󠄁e󠄁r󠄁 a󠄁t󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁i󠄁t󠄁i󠄁a󠄁t󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁.󠄁 T󠄁h󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 e󠄁x󠄁e󠄁m󠄁p󠄁t󠄁i󠄁o󠄁n󠄁,󠄁
  c󠄁o󠄁n󠄁t󠄁r󠄁a󠄁c󠄁t󠄁 r󠄁o󠄁w󠄁 a󠄁n󠄁d󠄁 s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁 r󠄁e󠄁f󠄁e󠄁r󠄁e󠄁n󠄁c󠄁e󠄁s󠄁 d󠄁e󠄁s󠄁c󠄁r󠄁i󠄁b󠄁e󠄁 t󠄁h󠄁a󠄁t󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁;󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁
  p󠄁a󠄁d󠄁 r󠄁e󠄁n󠄁a󠄁m󠄁e󠄁 e󠄁n󠄁d󠄁i󠄁n󠄁g󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁 s󠄁a󠄁m󠄁e󠄁.󠄁

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
- 2026-10-14: Drafts withdrawn amendment. The drafts ADR-0042 to ADR-0055
  (the last *The decrypted drag handle shows an open hand*, not the
  accepted ADR-0055 on menu wording), written on 2026-10-13 and 2026-10-14, were marked accepted and never
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
- 2026-10-14: Wording and Pads tab amendment.
  [ADR-0055](../adr/0055-menus-and-buttons-use-the-platforms-wording.md)
  point 2 takes the ellipsis off every verb that opens a field in its
  seat: *Rename Page*, *Rename Tab*, *Name* and *Rename*. The
  maintainer's instruction above is quoted as said.
  [ADR-0039](../adr/0039-pad-selection-and-associations.md) Amendment 1
  (proposed) makes the pad switcher a menu and moves the pads to a Pads
  tab of Settings, so the pad's field opens in its row there, and its
  refusal is said under the field, since the line under the page is in
  another window. The pad list's popover and its layout rule are gone,
  with the short card amendment's tests. The Opening and Refusing
  classes, the exemption, five rows, the acceptance lists and the
  sources follow.
- 2026-10-16: Record amendment. ADR-0042 was accepted by the maintainer,
  who ratified the rows the 2026-10-14 amendments added in the same
  reading. `decisions`, `sources` and the rows that cited it as a proposal
  now cite accepted text. No behaviour changes.
- 2026-10-21: Undrawn views amendment (issue 275). `SlotRailView`, which
  no layout drew since [ADR-0037](../adr/0037-one-page-layout-setting.md),
  is deleted with its rename field, so the keys row no longer names the
  slot rail's field among the key holders and the *Rename Tab* row
  names the strip as `TabRename.Field`'s one caller. No behaviour
  changes.

- 2026-10-31: Sealed-field ending amendment, authorized by the maintainer's
  instruction quoted in the [interface revision](../spec/design/2026-1031-sealed-content-ux-revision.md).
  Set/Edit Variable Name… replaces the sealed name's text-click opening. Its
  valid focus loss saves, as do pad switches and editor handoffs before teardown;
  Escape and Cancel retain cancellation semantics. Invalid blur remains open
  with an error beside the field; teardown closes an invalid remainder. Removed
  and expired sources do not rename a replacement. The field includes format
  guidance, Save/Cancel and Return/Esc instructions. These are scoped exceptions
  for the sealed variable-name field; page, tab and pad name endings are unchanged.
  Earlier amendment entries above describe the historical zone and held-footer
  designs, rather than the interface after this amendment.
