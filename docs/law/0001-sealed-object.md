---
id: 0001-sealed-object
title: The sealed object
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
governs: A sealed item occupies one position in the document, but its plaintext is not part of the document's ambient text.
decisions: D-08, D-09, D-10, D-14, D-15, D-27, D-28, D-29, D-30, D-31, D-32, D-33 (docs/spec/design/2026-0915-ui-ux-decisions.md, sections 3 and 5); D-40 and D-41 (docs/spec/design/2026-0915-stream-navigator.md, incorporated by docs/spec/design/2026-0916-clipboard-clear-interval.md); ADR-0042 points 1 to 4, 7 and 8; ADR-0044; ADR-0045; ADR-0046; ADR-0047; ADR-0048; ADR-0049; ADR-0052
consumed-by:
  - docs/spec/design/2026-0915-ui-ux-decisions.md (section 3 applies this law to the surface)
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the name's charset, the bottom row's zones, the note popover on a narrow card)
  - docs/adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md (where the name and note live, persist and cross the FFI)
  - docs/adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md (the envelope, the detached store, the active cut, resolution, the decrypted drag's write, the clipboard slot)
  - docs/adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md (a page past its deadline gives no object to a paste, move or clone)
  - docs/adr/0049-a-pasted-envelope-is-bounded.md (the envelope's length and references, and one object named once)
  - docs/adr/0050-a-decrypted-drag-lands-only-in-another-app.md (which asks the decrypted drag's provider answers)
  - docs/adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md (the handle's seat, look and press)
  - docs/adr/0052-a-page-past-its-deadline-gives-nothing-out.md (no route gives a page out past its deadline, swept or not)
sources:
  - docs/adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md (what the fragment, lifecycle and drag rows left open)
  - docs/adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md (the cut row's clock and the expiry row, between a deadline and its sweep)
  - docs/adr/0049-a-pasted-envelope-is-bounded.md (what a crafted envelope can clone)
  - docs/adr/0050-a-decrypted-drag-lands-only-in-another-app.md (what the decrypted drag row left open about its destinations)
  - docs/adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md (where the handle stands with no move handle beside it)
  - docs/adr/0052-a-page-past-its-deadline-gives-nothing-out.md (the expiry row between a deadline and its sweep, for every route that gives a page out)
  - crates/core/src/fragment.rs (the envelope and the public text, from one walk)
  - crates/core/src/transfer.rs (cut, paste, the slot's route, the drags inside a page, resolution and the transaction)
  - crates/pasteboard/src/macos.rs (`SystemDragItem`, the decrypted drag's write into its item)
  - docs/qa/verification-procedures/sealed-fragment.md (what another app and a real drag receive)
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the points the name and note amendment left open)
  - docs/adr/0044-sealed-row-and-note-details.md (ADR-0042's open questions settled; the row's and the note's details; a named object that is not text; no drop from elsewhere into the note or the name field)
  - docs/adr/0045-the-note-is-written-on-the-pages-surface.md (the note on the page's own surface, routed by document; what stands aside in a note)
  - docs/law/0007-edit-in-place.md (the name's field)
  - the maintainer's sealed object model, 2026-09-15
  - docs/spec/design/2026-0915-ui-ux-decisions.md, section 3
  - docs/spec/feature/sealed-content/sealed-content.md (historical design note upstream of this law)
  - docs/spec/design/04-interaction-model.md
  - docs/adr/0009-chip-deletion-deliberate-final.md (proposed removal constraint superseded by D-30)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (egress and clear discipline)
  - crates/core/src/sheet.rs (one clock per sheet, no per chip timers; `judge_name`, the name's rule)
  - crates/core/src/store.rs (seal, copy out, delete, sync; `set_chip_name`, `copy_out_name_value`, the note's routes)
  - crates/core/src/note.rs (the note's own document and undo)
  - crates/ffi/src/lib.rs (CLIPBOARD_CLEAR_SECONDS; chip-face and document JSON projections; the name and note routes)
  - shell/Sources/CompanionKit/CompanionClient.swift (ChipInfo.excerpt, ChipInfo.name, ChipInfo.hasNote)
  - shell/Sources/CompanionKit/InkEditorView.swift (SealedBlockCell, the named row and its zones, the doorway, the chip menu, the seal commands; `makeSurface`, the page's and the note's one writing surface; `selectObjectBeside` and `undoRemoval`, the two presses and the removal line's Undo; `beginPageDrag`, `dropPageDrag`, `dropFragment` and `endPageDrag`, the page's drags; `decryptedDragRect`, `startsDecryptedDrag` and `beginDecryptedDrag`, the decrypted drag's handle, and `isDecryptedDrag`, its refusal)
  - shell/Sources/CompanionKit/DecryptedDrag.swift (the decrypted drag's source and data provider)
  - shell/Sources/CompanionKit/SealedBlockLayout.swift (the named row's zones, pill and allotment; the handle's clearances)
  - shell/Sources/CompanionKit/SealedNameField.swift (the name's field)
  - shell/Sources/CompanionKit/SealedNotePopover.swift (`NotePopoverLayout.minimumWidth`, the note's popover)
  - shell/Sources/CompanionKit/PageModel.swift (`copyChipName`, `copyChipNameValue`, `setChipName`, the note's routes; `InkDocument`, the routes by document; `cutSelection`, `placeActiveCut`, `cutSlotSentence`, the cut and the clipboard slot; `pasteFragment`, the paste; `noteRemoval` and `withdrawRemovalUndo`, the removal line; `provideDecryptedDrag`, the provider's route)
  - shell/Sources/CompanionKit/PageSurface.swift (`PageStatusStack`, the clipboard slot's line)
  - https://developer.apple.com/documentation/appkit/nspasteboard/ (drag and general pasteboard scope)
---

# Law 0001: The sealed object

Read [behaviour law conventions](README.md) before filing or changing a law.

## The rule

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

That single sentence answers most interaction questions. The caret, the
selection, find, copy, drag, delete and expiry all act on a document that
contains the object; none of them can see through it. Plaintext leaves the
object only through an action that names that consequence.

## Why this rule

The model combines two established patterns:

1. **Atomic attachment**: the sealed item behaves like an image, a mention,
   a token or an embedded file in a rich text editor. It is one position,
   one unit, never a run of characters.
2. **Explicit declassification**: the shell never receives the sealed
   payload from the core. It may hold visible ink before sealing, and the
   policy-approved mechanical excerpt and the object's name and note
   afterward. Named egress operations
   write the complete payload core-side (ADR-0012 Amendment 1).

The rule serves the first tenet (losing work is unforgivable, even here) by
making every structural edit reversible, and the boundary law (ADR-0002,
ADR-0021) by making every reveal a named act. A sealed object shows one
plaintext only: the mechanical excerpt, head…tail of at most 24 plaintext
characters, computed by the core (`text_face` in `crates/core/src/sheet.rs`).
The algorithm counts Rust `char` values and is deliberately not
grapheme-aware; the result only has to be recognised by the person who pasted
it (D-27). A name and a note, once typed, are page-owned ink beside the
object, never payload (2026-10-13 amendment). There
is no reveal affordance at any privilege, so no label may imply one (D-08).

## Operation classes

Every interaction involving a sealed item belongs to one of five classes:

- **Ambient observation**: caret movement, find, word count, copying an
  object's name and public fallback representations inspect the document
  without reading a sealed payload. The object remains one opaque unit.
- **Structural editing**: move, select, reference-only copy, cut, in-app
  paste, clone and remove-from-page act on document structure. Removal
  detaches rather than destroys and remains undoable (D-30).
- **Classification**: sealing turns visible ink into a sealed object. It is
  one-way in the editor: ⌘Z does not restore the plaintext (D-30).
- **Declassification/egress**: copy decrypted contents (from the menu, the
  value zone or `name=value`), decrypted drag, promotion to a one-time
  link and plaintext export send the complete payload through a named
  consequence. Payload writes remain core-side (D-29, D-32).
- **Destruction/lifecycle**: page expiry and explicit burn destroy payload
  bytes and are not undoable (D-33).

`refused` is an outcome, not an operation class. For example, attempting to
seal a selection that already contains a sealed object is classification
with a refused outcome.

## Creating one after the fact

With visible ink selected: **Seal Selection** in the context menu, **Edit →
Seal Selected Content** in the menu bar, and optionally the same action in
a command palette. It replaces the selection in place with one sealed
object, keeps the surrounding whitespace, and selects the new object so the
transformation is visible. Sealed objects do not nest, so a selection
containing one is refused. No confirmation dialog (D-14): the visible
collapse into the block is the feedback.

Honest scope: sealing protects the selection **from this point forward**.
The plaintext may already sit in the shell's layout and glyph caches and in
whatever the user pasted from. The copy names those residuals and never
implies historical erasure.

## The contract

The table is the test list. Tests are cited by file and function; a row
without a test says what it is owed by.

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| arrow keys | ambient observation | the caret crosses the object as one indivisible unit | a chip is one attachment character: `SealedCapsuleTests.swift` `testTheCaretCrossesAnObjectAsOneUnitBothWays` |
| click, on an unnamed object or outside a named object's bottom row | structural editing | selects the whole object; never places a caret inside it | `DocumentOpsTests.swift` `testAClickOnAChipSelectsItWhole`; off a zone or with a modifier the click takes that path: `SealedCapsuleTests.swift` `testAZoneActsOnTheFirstClickAndAClickOffItSelects` |
| shift selection | structural editing | includes the whole object or none of it | `SealedCapsuleTests.swift` `testAShiftSelectionHoldsTheWholeObjectOrNoneOfIt` |
| select all | structural editing | includes each object structurally, not its payload | the core's selection of a whole page: `fragment.rs` `a_whole_page_selection_holds_every_object_by_reference` ([ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)); the editor's select all and its copy: `SealedFragmentEditorTests.swift` `testSelectAllHoldsEveryObjectAndItsCopyCarriesEachByReference`, and its standing aside while a field or the note holds the keys, `testCopyAndSelectAllStandAsideWhileAFieldOrTheNoteHoldsTheKeys` |
| copy, object or mixed selection | structural editing | writes one versioned sealed fragment preserving ordered ink runs and UUID references; the public representation preserves the ink and substitutes one size-class placeholder per reference; neither representation contains payload or ciphertext | the core composes both: `fragment.rs` `a_mixed_selection_keeps_its_ink_and_references_in_order`, `the_public_text_puts_a_size_class_placeholder_where_each_object_stood`, `neither_representation_holds_payload_or_ciphertext`, `a_one_object_copy_is_a_one_reference_fragment`, `the_envelope_reads_as_its_documented_shape`, `an_envelope_this_build_cannot_read_is_refused_whole`; `lib.rs` `copy_cut_and_paste_carry_the_envelope_unread_over_the_seam`, `sealed_bytes_never_appear_in_any_output`; `SealedFragmentSeamTests.swift` `testACopyHandsBackAnEnvelopeAndThePublicText` (ADR-0047); the editor's write of both types and no other on the ordinary copy: `SealedFragmentEditorTests.swift` `testACopyOfAMixedSelectionWritesTheFragmentAndThePublicTextAlone`, `testACopyOfOneObjectIsAOneReferenceFragment`, `testACopyOfInkAloneWritesPlainTextOnly`, `testACopyTheCoreDoesNotComposeWritesNothing`, `testSeveralStretchesCopyAsInkOrNotAtAll`, and each reference's name and note, `testEachReferenceCarriesItsObjectsNameAndNote`; what another app receives, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| cut | structural editing | writes the same fragment, then detaches every referenced object in one core transaction; all selected objects appear together in the app's clipboard slot and retain the page's clock | `transfer.rs` `a_cut_chip_is_detached_not_reaped`, `a_cut_detaches_every_object_in_one_step_and_undo_stands_them_all`, `a_later_cut_replaces_the_active_one_and_leaves_its_objects_detached`, `a_cut_the_body_refuses_changes_nothing`; the page's clock past its deadline (ADR-0048): `transfer.rs` `a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired`, and after sleep by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; the slot's faces: `lib.rs` `copy_cut_and_paste_carry_the_envelope_unread_over_the_seam`, `SealedFragmentSeamTests.swift` `testACutsFirstPasteReattachesAndALaterOneClones`; the editor's ⌘X: `SealedFragmentEditorTests.swift` `testACutDetachesItsObjectsAsOneStepAndOneUndoStandsThemAgain`, `testACutOfInkAloneWritesPlainTextAndLeavesTheSlotAlone`, `testSeveralStretchesCutAsInkOrNotAtAll`, a fragment the board refuses put back by the core's undo `testACutTheBoardRefusesIsPutBack`, standing aside while a field or the note holds the keys (ADR-0046) `testCutAndThePlaceStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; the slot's line: `testTheSlotNamesTheCutObjectsByTheirFacesAlone`, `testTheSlotStandsUnderTheOwnersPageAlone`, `testTheSlotPlacesTheSameObjectAtTheCaretAndItsLineGoes`; the line and its button on the raised card under a real pointer, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| paste, inside OnetimePad | structural editing | inserts the whole fragment as one undoable transaction; the first paste of a cut reattaches all cut objects, while a paste after copy or a later paste of a cut clones every live reference core-side; terminal or unknown references become cause-specific placeholders in their original positions | `transfer.rs` `a_pasted_reference_reattaches_by_id`, `the_first_paste_of_a_cut_reattaches_all_and_a_later_one_clones`, `a_fragment_not_naming_the_cut_clones_its_objects_and_the_cut_stands`, `a_cut_pasted_on_another_page_moves_there_and_clears_the_source_undo`, `a_paste_after_copy_clones_every_live_reference_without_its_receipt`, `a_paste_is_one_step_and_replaces_the_selection_it_covers`, `an_unreadable_envelope_pastes_its_public_text_and_says_so`; rollback: `a_paste_the_body_refuses_partway_changes_nothing_on_any_page`, and after a sweep `a_paste_the_body_refuses_after_its_sweep_reverts_the_paste_and_not_the_sweep`; mixed state: `a_mixed_paste_keeps_its_order_with_each_cause_in_position`; a page past its deadline (ADR-0048): `a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired`, `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`, `a_paste_of_ink_alone_sweeps_nothing`, `lib.rs` `a_paste_sweeps_a_due_page_and_says_how_many_over_the_seam`, `SealedFragmentSeamTests.swift` `testAPasteSweepsADuePageAndSaysHowMany`; a crafted envelope (ADR-0049): `fragment.rs` `an_envelope_past_a_cap_or_naming_one_object_twice_is_refused_whole`, `transfer.rs` `a_crafted_envelope_naming_a_live_object_twice_clones_nothing`; `SealedFragmentSeamTests.swift` `testACutsFirstPasteReattachesAndALaterOneClones`, `testAnUnreadableEnvelopePlacesItsPublicText`; the editor's ⌘V, Paste and Match Style and Paste Without Detection: `SealedFragmentEditorTests.swift` `testACutsFirstPasteReattachesItsObjectsAndALaterOneClonesThem` (names and notes kept by the reattach and carried by the clone), `testAPasteAfterACopyClonesEveryObjectAsOneStep`, `testAGoneReferencePastesItsPlaceholderWhereTheObjectStood`, `testAnUnreadableEnvelopePastesItsPublicTextAndSaysSo`, `testEveryPasteCommandTakesAFragmentThroughTheCore`, `testANoteOrAFileLeavesAFragmentToThePublicText`, `testAPasteThatSweepsADuePageSettlesAtOnce`, `testPasteStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`; the write it arms: `LedgerAppendArmingTests.swift` `testEveryLedgerAppendingMutationArmsAWrite`; the paste on the raised card: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| paste, another app | ambient observation | receives ordered ink with `[sealed content · <size class>]` substituted for each live reference; never receives a payload | the public text the core composes: `fragment.rs` `the_public_text_puts_a_size_class_placeholder_where_each_object_stood`; size class: `store.rs` `a_multi_line_chip_reports_a_size_class_not_lines`; the editor's copy writes it: `SealedFragmentEditorTests.swift` `testACopyOfAMixedSelectionWritesTheFragmentAndThePublicTextAlone`; the cut's write: `SealedFragmentEditorTests.swift` `testACutDetachesItsObjectsAsOneStepAndOneUndoStandsThemAgain`; what a rich or plain text reader takes from the board: `SealedFragmentEditorTests.swift` `testAnotherAppReadsThePublicTextAlone`; the plain drag's write: `SealedDragTests.swift` `testThePlainDragCarriesTheCopysFragmentAndNothingElse`; what another app pastes, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| drag, inside the document | structural editing | moves the selected objects and ink atomically with a clear insertion line; contents never preview | the core's move: `transfer.rs` `a_drag_inside_a_page_moves_ink_and_objects_in_one_step_keeping_identity`; `SealedFragmentSeamTests.swift` `testTheSlotTheMoveAndTheCloneRoutes`; an editor's move in two batches keeps the object: `store.rs` `an_editor_move_in_two_batches_detaches_and_then_reattaches_the_chip`; refused on a page past its deadline: `transfer.rs` `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`; the editor's drop on its own page: `SealedDragTests.swift` `testADragInsideThePageMovesInkAndObjectsAsOneStepKeepingThem`, `testADropOntoItsOwnRangeOrAChangedPageChangesNothing`, `testTheViewsDropRoutesAFragmentAndTheOwnDragThroughTheCore`; a drag to another page pastes there and its move removes the source run, which detaches: `testADragToAnotherPagePastesThereAndTheMoveRemovesItsSource`; standing aside while a field or the note holds the keys: `testDragsStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; the gesture under a real pointer, its insertion line and its image: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| ⌥ drag | structural editing | clones all selected sealed objects core-side as one operation, following the macOS copy-drag convention | the core's clone: `transfer.rs` `an_option_drag_clones_every_object_in_one_step`; refused on a page past its deadline: `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`; the editor's ⌥ drop: `SealedDragTests.swift` `testAnOptionDragClonesEveryObjectCoreSide`, `testADragOffersAMoveOnlyInsideTheAppAndOptionNarrowsItToACopy`; its clones arm a write: `LedgerAppendArmingTests.swift`; ⌥ under a real pointer: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| plain drag, outside | ambient observation | exposes only ordered ink and placeholders | the public text it carries is the copy's (the copy row); the drag's one item, the copy's fragment, with nothing else written and the ordinary pasteboard untouched: `SealedDragTests.swift` `testThePlainDragCarriesTheCopysFragmentAndNothingElse`, `testInkAloneDragsAsPlainTextAndSeveralStretchesWithAnObjectDoNot`; only a copy offered outside the app, and no run removed on another app's answer: `testADragOffersAMoveOnlyInsideTheAppAndOptionNarrowsItToACopy`, `testACopiedCancelledOrForeignDragLeavesItsSource`; what another app receives: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| decrypted drag, from the handle | declassification/egress | a distinct, labelled handle; the core supplies the complete payload lazily when a destination asks and records destination `Drag`; a successful drop never deletes the object | the core's write into the drag item, its refusals and its record: `lib.rs` `a_decrypted_drag_writes_its_item_core_side_and_records_one_sent_to_drag`, `a_decrypted_drag_refuses_the_general_pasteboard_a_foreign_type_and_an_unknown_chip`, a chip removed mid drag `a_decrypted_drag_refuses_a_chip_removed_mid_drag`, a page past its deadline (ADR-0052) `a_page_past_its_deadline_gives_nothing_out_over_the_seam`, `the_fragment_routes_fail_closed`; `crates/pasteboard/src/macos.rs` `a_drag_item_takes_the_plaintext_under_its_kinds_type`, `a_drag_item_on_the_general_pasteboard_says_so`, `a_drag_item_refuses_null_and_objects_of_another_class`; `SealedFragmentSeamTests.swift` `testADecryptedDragWritesTheItemCoreSideAndRecordsADrag`; its buffer: `store.rs` `a_copy_out_is_written_at_its_exact_size`; the `Drag` class at rest: `persist.rs` `every_destination_class_round_trips_in_the_ledger`; the handle's seat and press ([ADR-0051](../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md)): `SealedDecryptedDragTests.swift` `testTheHandleSitsBeforeTheActionsSeatAndOnlyWhereItFits`, `testTheHandleDragsTheChipsOwnTypeAndAnUnknownKindHasNone`, `testOnlyAFirstPlainPressOnADrawnHandleStartsTheDrag`; its data provider, the core's write on a destination's ask, its record arming a write and the object left standing: `testADestinationsAskIsWrittenByTheCoreAndRecordsOneDrag`, `LedgerAppendArmingTests`; a cancelled session and a foreign ask refused: `testACancelledDragAndAForeignAskAreRefused`; a copy outside the app and no drop on the page or the note ([ADR-0050](../adr/0050-a-decrypted-drag-lands-only-in-another-app.md)): `testTheDragOffersACopyToAnotherAppAndNothingInsideThisOne`, `testTheDecryptedDragLandsOnNoPageOfThisApp`; standing aside: `testTheDecryptedDragStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`; the handle under a real pointer, a drop into another app, a cancel and the app's other fields: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| backspace beside it | structural editing | the first press selects the object, the second removes it from the page | the editor's two presses, and a forward delete before the object alike: `SealedRemovalTests.swift` `testTheFirstBackspaceBesideAnObjectSelectsItAndTheSecondRemovesIt`, `testTheFirstForwardDeleteBeforeAnObjectSelectsItAndTheSecondRemovesIt`; a press beside ink deletes one character, `testAPressBesideInkDeletesOneCharacter`; standing aside while a field or the note holds the keys (ADR-0046) `testBackspaceAndTheUndoStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; the real keys on the raised card, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| backspace, selected | structural editing | detaches it immediately, with Undo available; undo reattaches from the detached store | removal as one unit: `DocumentOpsTests.swift` `testDeletingAChipAttachmentEmitsOneDelete`; the detach and the undo: `store.rs` `deleting_a_sentinel_by_op_detaches_the_chip_and_records_nothing`, `undo_stands_a_removed_chip_again_from_the_detached_store`; through the editor: `DocumentOpsTests.swift` `testUndoAfterRemovingAChipStandsTheSameObjectAgain`, `testPuttingARemovedChipsAttachmentBackReattachesIt`; the removal line's Undo, which stands the same object again and leaves the line once the page moves past the removal: `SealedRemovalTests.swift` `testTheRemovalLinesUndoStandsTheSameObjectAgain`, `testASelectionHoldingAnObjectGoesInOnePressWithUndo`, `testARemovalIsItsOwnStep`, `testTheUndoGoesOnceThePageMovesPastTheRemoval`, `testTheMenusRemovalOffersTheSameUndo`; `SealedCapsuleTests.swift` `testARemovalFlashesItsLineWithUndoAndAWithdrawalKeepsOnlyTheWords`; the line's button on the raised card, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| find, word count | ambient observation | does not inspect the payload; may count one protected object | `WrapTests.swift` `testUseSelectionForFindRefusesAChip`; no word count exists |
| expiry | destruction/lifecycle | destroys all of the page's attached and detached payloads; while terminal-cause evidence remains, later references produce an expired placeholder and cannot be undone; from its deadline, swept or not, no core route gives the page out: copy decrypted, copy `NAME=value`, the decrypted drag, both conceals, the note's text and the fragment's copy and cut refuse it, writing and recording nothing ([ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)) | `store.rs` `an_expiring_page_destroys_its_detached_chips_and_records_each`; `transfer.rs` `an_expired_reference_says_so_while_evidence_remains_then_is_unavailable`, `the_active_cut_ends_with_its_page`; between the deadline and its sweep (ADR-0048): `a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired`, `a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired`; no route gives it out (ADR-0052): `store.rs` `copy_decrypted_refuses_a_page_past_its_deadline_before_its_sweep`, `copy_name_value_refuses_a_page_past_its_deadline_before_its_sweep`, `conceal_refuses_a_page_past_its_deadline_before_its_sweep`, `the_note_refuses_a_page_past_its_deadline_before_its_sweep`, the gate agreeing with the sweep `the_read_gate_and_the_sweep_agree_on_the_deadline`, `a_held_page_reads_until_its_frozen_life_drains`; `transfer.rs` `a_page_past_its_deadline_gives_no_copy_before_its_sweep`, `a_page_past_its_deadline_gives_no_cut_before_its_sweep`; `lib.rs` `a_page_past_its_deadline_gives_nothing_out_over_the_seam`, `neither_conceal_sends_a_page_past_its_deadline`; `SealedFragmentSeamTests.swift` `testAPagePastItsDeadlineGivesNothingOutAndTheSettleSweepsIt`; the shell settling after a refusal and on wake, and AppKit's copy, cut and drag of the open note's ink and its service and several stretch drag of a page's ink alone, which no core route sees, owed by issue 170's shell half |
| explicit burn | destruction/lifecycle | destroys the named local payloads atomically; while terminal-cause evidence remains, later references produce a burned placeholder | `store.rs` `burning_a_chip_takes_the_stack_with_it`, `burning_a_detached_chip_destroys_it_and_takes_the_stack_with_it`; `transfer.rs` `a_burned_reference_says_so`, `burning_a_clones_source_leaves_the_clone` |
| export, print, share | ambient observation | emits placeholders by default; a plaintext export is separately named declassification/egress | a service asking for the page's selection takes the copy's public text alone, and none that would write back over an object is offered: `SealedFragmentEditorTests.swift` `testAServiceTakesThePublicTextAndNoServiceWritesOverAnObject`, `testAServiceTakesInkAsAppKitWritesItAndSeveralStretchesNotAtAll`, and its standing aside while a field or the note holds the keys (ADR-0046) `testServicesStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; a real service and the text menu's Share: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md); export and print, owed when a path exists |
| promote the whole page | declassification/egress | includes sealed payloads; the confirmation says so; the local copy is offered up to burn and is never burned automatically | payload inclusion: `store.rs` `sheet_payload_inlines_chips_in_document_order`; confirmation count: `ConcealWireTests.swift`; receipt marker and retained local payload: `store.rs` `a_conceal_marks_the_chip_and_keeps_only_the_receipt` |
| seal a selection | classification | replaces visible ink in place, keeps whitespace and selects the new object; the result is one-way in the editor | shell and core range-seal tests listed below |
| seal over a sealed object | classification | refused: sealed objects do not nest | `DocumentOpsTests.swift` and `store.rs` refusal tests listed below |
| undo after a seal | classification | refused: ⌘Z does not restore the pre-seal ink | `UndoRerouteTests.swift` `testASealCannotBeSteppedBack`; `store.rs` `a_seal_cannot_be_stepped_back` |
| copy decrypted contents | declassification/egress | offered by name and does not consume the object; the core writes the payload, the shell arms a timer from the core-owned 60-second interval, and the core later clears only if the pasteboard still holds that write | copy-out and shell timer tests listed below; guarded clear: `crates/pasteboard/src/lib.rs` and `crates/pasteboard/src/macos.rs` `clear_after_copy_only_clears_our_own_write`, both of which refuse to erase a newer write |
| name the object (*Name…*, *Rename…*, a double click on an unnamed object's bottom row or a named object's name zone) | structural editing | an inline field in the name's seat per [Law 0007](0007-edit-in-place.md); the name is page-owned text stored with the object core-side, carried in the fragment, never in the ledger; it is 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`, case kept, and the core refuses any other ([ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md)); a named object's bottom row reads `NAME=excerpt` | the core's name, its rule and its refusal: `store.rs` `a_name_outside_the_charset_is_refused_and_an_empty_one_clears`, `a_name_survives_a_snapshot_round_trip`, `after_the_page_expires_the_snapshot_holds_no_name`; `lib.rs` `chip_json_carries_the_name`, `the_name_routes_judge_by_one_rule_and_fail_closed` ([ADR-0043](../adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md)); the field and the redrawn row: `SealedNameFieldTests.swift` `testTheFieldOpensInTheSeatOnTheNameWithTheExcerptToItsRight`, `testReturnNamesTheObjectAndRedrawsItsBlock`, `testARefusalKeepsTheFieldAndTheLine`, with the rest of the field's rows in Law 0007; the write a name or a note edit arms and a refusal does not (ADR-0043 point 5): `testANameOrANoteEditArmsAWriteAndARefusalArmsNone`; the name in the fragment, a clone judging it and the public text omitting it: `fragment.rs` `the_envelope_round_trips_with_and_without_a_name_and_a_note`, `the_public_text_names_neither_the_name_nor_the_note`, `an_empty_name_or_note_reads_as_none`; `transfer.rs` `a_clone_carries_the_name_and_note_its_fragment_holds`, `a_pasted_name_the_rule_refuses_is_dropped_and_the_object_kept`, `a_reattached_object_keeps_its_own_name_and_note`, `a_placeholder_carries_neither_name_nor_note` (issue 247, ADR-0047) |
| pointer over an unnamed object's bottom row | structural editing | no zones until the object is named: no pill, no seat words, and a click selects as anywhere on the block (D-40) | `SealedBlockTests.swift` `testTheDrawnRowAtAWideAndANarrowMeasure`; `SealedCapsuleTests.swift` `testHoverFindsTheZoneUnderThePointer` |
| click the name zone, the name's glyph run | ambient observation | the first click copies the name; the second of a double click opens the name field; the size class's seat reads `copies the name` while hovered | the zone and its seat: `SealedBlockTests.swift` `testTheZonesAreTheRunsAndTheEqualsTakesTwoPointsEachSide`, `testEachZoneSaysWhatItsClickDoesInTheSeat`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`; the double click: the same press test, and `SealedNameFieldTests.swift` `testADoubleClickOpensTheFieldOnlyWhereTheRuleSays` |
| click the value zone, the value's glyph run | declassification/egress | a handle in D-29's sense: copies the decrypted contents by the copy decrypted route above on the first click and ignores the clicks after it; the seat reads `copies the value, decrypted` before the click | `SealedBlockTests.swift` `testEachZoneSaysWhatItsClickDoesInTheSeat`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`, `testAZoneActsOnTheFirstClickAndAClickOffItSelects`, `testAZoneActsOnlyOnceTheSeatHasNamedIt` |
| click the `=` zone, the glyph and 2 points either side | declassification/egress | copies `NAME=<plaintext>`, the value raw and unquoted, by the same route on the first click and ignores the clicks after it; the seat reads `copies name=value, decrypted` before the click; on an object that is not text the `=` is no zone, since the core composes `NAME=value` for text alone ([ADR-0044](../adr/0044-sealed-row-and-note-details.md)) | the core's write: `store.rs` `name_value_is_composed_raw_at_its_exact_size`, `name_value_refuses_an_unnamed_an_image_and_an_unknown_chip`; `lib.rs` `copy_name_value_writes_the_pasteboard_in_core_marked_nspasteboard_concealed`, `copy_name_value_refuses_unnamed_image_and_unknown_chips_and_writes_nothing`, `a_name_value_copy_and_a_copy_out_retire_each_others_receipts`, `a_name_value_copy_records_one_sent_and_no_name`; the zone: `SealedBlockTests.swift` `testTheZonesAreTheRunsAndTheEqualsTakesTwoPointsEachSide`, `testANamedImagesEqualsIsNoZone`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAZoneActsOnTheFirstClickAndAClickOffItSelects`, `testAZoneActsOnlyOnceTheSeatHasNamedIt` |
| the note (*Note…*, *Edit note…*, a click on `note`) | structural editing | the page's own writing surface in a popover at the block's measure, or the card's full content width when the block's measure is narrower than the popover's minimum, expanded to the card by its diagonal arrows or ⇧Esc and contracted the same way; a drop from elsewhere lands nowhere in it, since no seal can stand in a note ([ADR-0044](../adr/0044-sealed-row-and-note-details.md)), and once closed its view holds none of its ink; ink stored with the object core-side, carried in the fragment, never in the ledger, on the page's clock | the core's note: `store.rs` `a_note_survives_a_snapshot_round_trip`, `after_the_page_expires_the_snapshot_holds_no_note`, `undo_inside_the_note_is_separate_from_the_pages_undo`, `note_edits_leave_the_ledger_unchanged`, `a_note_takes_no_chip_and_a_refused_first_batch_makes_no_note`; `lib.rs` `note_routes_edit_the_note_and_leave_the_page_alone`, `the_note_and_the_page_keep_separate_undo_stacks_across_the_seam`; the popover: `SealedNoteTests.swift` `testThePopoverHangsUnderTheBlockAtTheBlocksMeasure`, `testANarrowBlockPutsTheNoteAcrossTheContentWidth`, `testExpandedTheNoteCoversTheContentAndWithoutRoomBelowItStandsAbove`, `testTheMenusVerbOpensTheNoteInThePagesOwnWindow`, `testTheDoorwayOpensTheNoteAndEscClosesIt`, `testTheArrowsAndShiftEscExpandAndContractAndEscContracts`, `testTheNoteClosesWhenItsSeatGoes`, `testTheObjectLeavingThePageClosesItsNote`, `testANoteEditLeavesThePagesCaretAndUndoAlone`, `testNoNoteRouteRunsAModalSession`, `testTheNoteTakesNoDropFromElsewhere`, `testAClosedNoteLeavesNoInkInTheShell`; the page's own surface ([ADR-0045](../adr/0045-the-note-is-written-on-the-pages-surface.md)): `SealedNoteTests.swift` `testTheNoteWearsThePagesFace`, `testANoteContinuesAndNestsAListAsThePageDoes`, `testChooseLanguageActsOnTheNoteAndItsLabelIsTheNotesOwn`, the Edit menu acting on the note while it holds the keys ([ADR-0046](../adr/0046-the-keys-holder-answers-the-pages-chords-and-menu.md)) `testTheEditMenuActsOnTheNoteWhileItHoldsTheKeys`, and what stands aside in it, `testNoSealLandsInANote`, `testNoObjectStandsInANote`, `testANoteShowsNoBlockStampsAndAsksNoPageForThem`, `testTheWrapToggleStandsAsideInANote`; on the raised card and under a real pointer, and a click and a ⌘-click on a note's link, owed: hand check, [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md); the note in the fragment, carried by a clone with an empty undo stack and kept by a reattach: `fragment.rs` `the_envelope_round_trips_with_and_without_a_name_and_a_note`; `transfer.rs` `a_clone_carries_the_name_and_note_its_fragment_holds`, `a_reattached_object_keeps_its_own_name_and_note`; with its object when removed: `persist.rs` `a_detached_chip_comes_back_detached_with_its_name_and_note` (issue 247, ADR-0047) |

### Sealed-fragment representation

The private type is `com.onetimesecret.onetimepad.sealed-fragment` with the
`.debug` suffix on development builds. Its envelope is versioned and contains
an ordered sequence of only two node kinds: visible ink runs and sealed-object
UUID references. A reference may carry the object's name and note as two
optional text fields, both ink. A one-object copy is a one-reference
fragment. The envelope never contains a sealed payload or ciphertext.

Copy, cut, paste and clone preserve node order for a selection such as
`ink → object A → ink → object B → ink`, and carry each object's name and
note with it. Multi-object detach, reattach and
clone are core transactions: an unexpected failure commits none of the
structural or payload-state changes. Resolution to an expired, burned or
unavailable placeholder is an expected paste result, not a partial failure.

### Lifecycle states

| State | Payload retained? | App clipboard slot | Paste of a referencing fragment |
| --- | --- | --- | --- |
| attached | yes | no | clones the live object unless it is part of the active cut transaction |
| detached by cut | yes, on the page's clock | yes, for the active cut fragment | first paste reattaches all objects from that cut atomically; later pastes clone them |
| detached by removal | yes, on the page's clock | no | clones the retained object; Undo, not paste, reattaches the removed instance |
| expired | no | no | inserts `[sealed content · expired]` while expiry evidence remains |
| explicitly burned | no | no | inserts `[sealed content · burned]` while burn evidence remains |
| unknown or foreign reference | no known payload | no | inserts `[sealed content · unavailable]`; it is never labelled expired without expiry evidence |

Removal never produces a removed placeholder because the retained object is
still resolvable. The non-content lifecycle evidence is the object's UUID,
terminal event and timestamp. An explicit burn uses the ledger's
`discarded` event as burn evidence. ADR-0012 says a ledger record carries
"event type ... timestamps ... [and] the item's random UUID" and that
"Retention is a rolling 90-day window". Expired and burned references therefore remain
distinguishable for that rolling window; after the evidence ages out, they
resolve as unavailable rather than being guessed expired.

### Security invariants

- The shell never receives a sealed payload from the core. Swift may hold
  visible ink before classification and the mechanical excerpt afterward;
  `ChipInfo.excerpt` and `companion_sheet_document_json` make that residual
  explicit. Swift may also hold the object's name and note, which are ink
  and never payload. Complete payload egress remains core-side.
- A sealed object's ledger record contains no payload or excerpt. This is
  pinned by `store.rs`
  `a_sealed_chip_is_content_free_in_the_ledger_from_the_moment_it_exists`
  and `a_seal_carrying_an_origin_leaves_no_trace_in_the_ledger`. Nor does
  it contain the object's name or note, pinned by `store.rs`
  `a_named_chip_is_content_free_in_the_ledger` and
  `note_edits_leave_the_ledger_unchanged` and by `lib.rs`
  `a_name_and_a_note_reach_no_ledger_record_and_no_other_output`. Neither
  is payload: `store.rs` `a_name_and_a_note_are_never_payload` reads both
  conceal payloads.
- OnetimePad does not write decrypted drag data to the general pasteboard.
  Apple's [`NSPasteboard` documentation](https://developer.apple.com/documentation/appkit/nspasteboard/)
  says, "The drag pasteboard is used to
  transfer data that is being dragged by the user," and, separately, "The
  general pasteboard ... automatically participates with the Universal
  Clipboard feature." This law makes no broader claim about clipboard
  history, observation by other software or erasure after a drag ends.
  The core refuses to provide a decrypted drag on an item whose
  pasteboard is the general pasteboard, pinned by `lib.rs`
  `a_decrypted_drag_refuses_the_general_pasteboard_a_foreign_type_and_an_unknown_chip`
  and `crates/pasteboard/src/macos.rs`
  `a_drag_item_on_the_general_pasteboard_says_so`.

### Presentation invariants

The block is full measure, with an 8 px radius, hairline border and 8 by 12
padding. It shows the tracked `SEALED CONTENT` label, the mechanical excerpt
and the size class as metadata. Once named, the bottom row reads
`NAME=excerpt`; once a note exists, the metadata reads `<size class> · note`.
Its body does not press, except a named object's bottom row, whose three
copy zones copy (the rows above); an unnamed object's body does not press
at all. Handles appear on hover or selection without changing
layout, and so does the pill under a hovered zone, whose geometry
[ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md) fixes.
The excerpt is pinned by `store.rs` `sealed_chips_carry_the_mechanical_face`;
the block's geometry by `SealedBlockTests` (issue 169, closed); the name,
the zones and the pill by `SealedBlockTests` (issue 244); the doorway by
`SealedNoteTests.testTheSeatOpensADoorwayOnceANoteExists` and
`testTheDoorwayFollowsTheNotesInk` (issue 246). What a real pointer and
display show is owed to the [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md)
procedure.

Fixed details the rows rely on:

- The private pasteboard type is
  `com.onetimesecret.onetimepad.sealed-fragment`, with the `.debug` suffix
  on development builds so development and production cannot resolve each
  other's references. It carries a version and ordered ink/UUID nodes,
  each UUID node with the object's name and note as two optional text
  fields. Never the payload, never ciphertext (D-31).
- The plain text placeholder is `[sealed content · <size class>]`, a size
  class from `SizeClass` (`crates/core/src/ledger.rs`), never a count.
- Three complete-payload egress points, all core-side writes: copy
  decrypted, decrypted drag and promotion (D-32). Decrypted drag is the
  recommended path into a form field because OnetimePad does not put its
  decrypted data on the general pasteboard; copy decrypted does and is the
  riskier fallback. No claim is made about third-party observation,
  clipboard history or erasure of drag-pasteboard data. Copying the value
  zone or `name=value` is copy decrypted: the core composes
  `NAME=<plaintext>` and writes it by the same route, so the count stays
  three (ADR-0042). Copying the name is ambient observation, not egress.
- Copy-out arms a change-count-guarded clear attempt after the core's
  60-second constant (`CLIPBOARD_CLEAR_SECONDS`, `crates/ffi/src/lib.rs`),
  read through `companion_clipboard_clear_seconds`. The general pasteboard
  is cleared only if it still holds that write; no total-retention or
  clipboard-manager guarantee is made (D-29, D-43 of the accepted
  [2026-09-16 clear-interval record](../spec/design/2026-0916-clipboard-clear-interval.md)).
- Time belongs to the page. A detached object takes its page's clock; there
  is no per chip TTL (`sheet.rs` forbids per chip timers; maintainer
  decision 2026-08-07; D-33).
- The object's menu, in the copy register of D-15, named and with a note:

  ```text
  Copy name
  Copy decrypted contents              ⇧⌘C
  Copy name=value, decrypted
  Create one-time link…
  ────────────────────────
  Rename…
  Edit note…
  ────────────────────────
  Remove protected content
  ```

  Unnamed, *Copy name* and *Copy name=value, decrypted* are absent and
  *Name…* stands for *Rename…*; without a note, *Note…* stands for *Edit
  note…* (ADR-0042). On an object that is not text, *Copy name=value,
  decrypted* is absent (ADR-0044). The chord is the keymap's (`chip::CopyDecrypted`)
  and acts on exactly one selected object; the removal follows a
  separator, uses AppKit's standard menu styling, and stays structural
  and undoable (D-41 of the 2026-0915 stream navigator record, extended
  by ADR-0042). The four new items, in both variants, are pinned by
  `DocumentOpsTests.testTheChipMenuOffersPlaintextByName` and
  `SealedCapsuleTests.testTheMenuExposesTheNamedActionsAndAdvertisesTheCopyChord`;
  the name's verb by `SealedNameFieldTests.testTheMenusVerbOpensTheField`
  and the note's by `SealedNoteTests.testTheMenusVerbOpensTheNoteInThePagesOwnWindow`
  and `testTheDoorwayOpensTheNoteAndEscClosesIt`.

## What the rule forbids

- Any reveal affordance: no eye toggle, no hover preview, no copy to see
  it, no label that implies one (D-08).
- Plaintext or ciphertext on any pasteboard except at a named
  declassification. The ordinary copy path (object, page, select all) never
  offers a plaintext type.
- A caret inside the object, a selection that splits it, a find that
  matches through it.
- A confirmation dialog on seal, on remove or on copy decrypted (D-14); the
  boundary is named inline.
- A per chip timer of any kind. The page's clock is the only clock.
- An undo that reveals plaintext, and an undo that resurrects a chip whose
  page has expired.
- A removal that destroys bytes the next undo would need. Removal detaches;
  only expiry and an explicit burn destroy.

## The rubric for a new interaction

- **Atomicity**: does the sealed item behave as one object?
- **Non disclosure**: can this ordinary action reveal plaintext
  unexpectedly?
- **Fidelity**: can the object move through trusted app operations without
  losing its payload?
- **Legibility**: does the action name what crosses the protection
  boundary?
- **Reversibility**: can structural edits be undone? Classification is a
  separate class, and sealing is one-way.
- **Safe fallback**: when a destination cannot understand the object, does
  it receive a placeholder rather than plaintext or nothing?

The first question is which of the five classes the interaction belongs to.
Moving, selecting, cloning and removing edit structure; sealing classifies;
expiry and burn destroy; copying decrypted contents and exporting plaintext
cross the security boundary and remain explicit. A refusal is the result of
applying a class rule, not a sixth class.

## Acceptance and tests

Core (`crates/core/src/store.rs`, `cargo test -p companion-core`):
`a_range_seal_replaces_the_selection_atomically`,
`a_range_seal_over_a_selected_chip_is_refused`,
`a_range_seal_with_a_bad_range_seals_nothing`,
`a_range_seal_across_a_newline_merges_blocks_like_typing_over_it`,
`a_seal_cannot_be_stepped_back`, `copy_out_does_not_consume_the_chip`,
`sealed_chips_carry_the_mechanical_face`,
`a_multi_line_chip_reports_a_size_class_not_lines`,
`a_sealed_chip_is_content_free_in_the_ledger_from_the_moment_it_exists`,
`a_seal_carrying_an_origin_leaves_no_trace_in_the_ledger`,
`a_conceal_marks_the_chip_and_keeps_only_the_receipt`,
`sheet_payload_inlines_chips_in_document_order`,
`sync_rejects_foreign_and_duplicate_chips`; for the name and note
(ADR-0043), `a_named_chip_is_content_free_in_the_ledger`,
`a_name_survives_a_snapshot_round_trip`,
`after_the_page_expires_the_snapshot_holds_no_name`,
`a_name_outside_the_charset_is_refused_and_an_empty_one_clears`,
`name_value_is_composed_raw_at_its_exact_size`,
`name_value_refuses_an_unnamed_an_image_and_an_unknown_chip`,
`a_note_survives_a_snapshot_round_trip`,
`after_the_page_expires_the_snapshot_holds_no_note`,
`undo_inside_the_note_is_separate_from_the_pages_undo`,
`note_edits_leave_the_ledger_unchanged`,
`a_note_takes_no_chip_and_a_refused_first_batch_makes_no_note`,
`a_note_of_only_whitespace_opens_no_doorway`,
`a_name_and_a_note_are_never_payload`. The chip record's trailing
fields (`crates/core/src/persist.rs`):
`a_chip_written_before_names_existed_restores_unnamed`,
`a_written_name_comes_back_and_one_the_rule_refuses_is_dropped`,
`an_unknown_name_flag_is_malformed_and_the_store_is_untouched`,
`a_chip_written_before_notes_existed_keeps_its_name_and_has_no_note`,
`a_written_note_comes_back_beside_its_name`,
`an_unknown_note_flag_is_malformed_and_the_store_is_untouched`, and
`snapshot_size_is_exact` over a named chip with a note and a detached
chip.

The fragment, the detached store and the transaction (ADR-0047). In
`crates/core/src/fragment.rs`: `a_mixed_selection_keeps_its_ink_and_references_in_order`,
`the_public_text_puts_a_size_class_placeholder_where_each_object_stood`,
`neither_representation_holds_payload_or_ciphertext`,
`a_one_object_copy_is_a_one_reference_fragment`,
`a_whole_page_selection_holds_every_object_by_reference`,
`a_copy_of_ink_alone_offers_its_text_and_no_envelope_and_changes_nothing`,
`a_range_that_splits_a_pair_or_is_empty_selects_nothing`,
`the_envelope_is_written_at_its_exact_size`,
`the_envelope_reads_as_its_documented_shape`,
`an_envelope_this_build_cannot_read_is_refused_whole`,
`an_envelope_past_a_cap_or_naming_one_object_twice_is_refused_whole`
(ADR-0049), and for the name
and note (issue 247) `the_envelope_round_trips_with_and_without_a_name_and_a_note`,
`the_public_text_names_neither_the_name_nor_the_note`,
`an_empty_name_or_note_reads_as_none`. In `crates/core/src/transfer.rs`:
`a_cut_chip_is_detached_not_reaped`,
`a_cut_detaches_every_object_in_one_step_and_undo_stands_them_all`,
`a_cut_of_ink_alone_names_no_cut_and_leaves_the_one_standing`,
`a_later_cut_replaces_the_active_one_and_leaves_its_objects_detached`,
`a_cut_the_body_refuses_changes_nothing`,
`a_pasted_reference_reattaches_by_id`,
`the_first_paste_of_a_cut_reattaches_all_and_a_later_one_clones`,
`a_fragment_not_naming_the_cut_clones_its_objects_and_the_cut_stands`,
`a_cut_pasted_on_another_page_moves_there_and_clears_the_source_undo`,
`a_paste_after_copy_clones_every_live_reference_without_its_receipt`,
`burning_a_clones_source_leaves_the_clone`,
`a_reference_to_a_removed_object_clones_the_retained_one_and_undo_reattaches_it`,
`an_expired_reference_says_so_while_evidence_remains_then_is_unavailable`,
`a_burned_reference_says_so`,
`an_unknown_reference_is_unavailable_and_never_called_expired`,
`an_unreadable_envelope_pastes_its_public_text_and_says_so`,
`a_paste_is_one_step_and_replaces_the_selection_it_covers`,
`a_paste_the_body_refuses_partway_changes_nothing_on_any_page`,
`a_mixed_paste_keeps_its_order_with_each_cause_in_position`,
`the_slot_places_the_active_cut_without_the_pasteboard`,
`the_active_cut_ends_with_its_page`,
`a_drag_inside_a_page_moves_ink_and_objects_in_one_step_keeping_identity`,
`an_option_drag_clones_every_object_in_one_step`,
`the_active_cut_survives_a_relaunch_and_its_first_paste_reattaches`,
`a_cut_whose_objects_are_not_all_detached_restores_as_no_cut`, and for
the name and note `a_clone_carries_the_name_and_note_its_fragment_holds`,
`a_pasted_name_the_rule_refuses_is_dropped_and_the_object_kept`,
`a_reattached_object_keeps_its_own_name_and_note`,
`a_placeholder_carries_neither_name_nor_note`, for a page past its
deadline (ADR-0048) `a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired`,
`a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired`,
`a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`,
`a_paste_the_body_refuses_after_its_sweep_reverts_the_paste_and_not_the_sweep`,
`a_paste_of_ink_alone_sweeps_nothing`, and for a crafted envelope
(ADR-0049) `a_crafted_envelope_naming_a_live_object_twice_clones_nothing`,
and for no route past the deadline (ADR-0052)
`a_page_past_its_deadline_gives_no_copy_before_its_sweep`,
`a_page_past_its_deadline_gives_no_cut_before_its_sweep`. In `store.rs`:
`a_sync_that_omits_a_chip_detaches_it_and_one_naming_it_reattaches_it`,
`deleting_a_sentinel_by_op_detaches_the_chip_and_records_nothing`,
`an_empty_snapshot_is_select_all_delete_and_detaches_every_chip`,
`a_select_all_delete_batch_detaches_every_chip_and_undo_stands_them_again`,
`undo_stands_a_removed_chip_again_from_the_detached_store`,
`undo_after_a_drag_that_carries_a_chip_stands_it_where_it_was`,
`an_editor_move_in_two_batches_detaches_and_then_reattaches_the_chip`,
`a_chip_detached_on_another_page_cannot_be_stood_here`,
`a_seal_finished_through_ops_cannot_be_stepped_back_to_its_ink`,
`standing_a_sentinel_through_the_op_path_takes_the_stack_with_it`,
`burning_a_chip_takes_the_stack_with_it`,
`burning_a_detached_chip_destroys_it_and_takes_the_stack_with_it`,
`an_expiring_page_destroys_its_detached_chips_and_records_each`,
`a_chip_removed_in_the_editor_records_nothing_until_its_page_ends`,
`a_peers_chip_deletion_detaches_it_and_leaves_this_devices_steps`,
`a_copy_out_is_written_at_its_exact_size`, and for no route past the
deadline (ADR-0052)
`copy_decrypted_refuses_a_page_past_its_deadline_before_its_sweep`,
`copy_name_value_refuses_a_page_past_its_deadline_before_its_sweep`,
`conceal_refuses_a_page_past_its_deadline_before_its_sweep`,
`the_note_refuses_a_page_past_its_deadline_before_its_sweep`,
`the_read_gate_and_the_sweep_agree_on_the_deadline`,
`a_held_page_reads_until_its_frozen_life_drains`. In `persist.rs`:
`a_detached_chip_comes_back_detached_with_its_name_and_note`,
`a_page_written_before_detached_chips_existed_restores_with_none`,
`a_detached_chip_repeating_an_identity_is_malformed`,
`every_destination_class_round_trips_in_the_ledger`. In
`crates/pasteboard/src/macos.rs`:
`a_drag_item_takes_the_plaintext_under_its_kinds_type`,
`a_drag_item_on_the_general_pasteboard_says_so`,
`a_drag_item_refuses_null_and_objects_of_another_class`.

Seam (`crates/ffi/src/lib.rs`): `the_clear_interval_is_the_core_constant`,
`sealed_bytes_never_appear_in_any_output`, `chip_json_carries_the_name`,
`the_name_routes_judge_by_one_rule_and_fail_closed`,
`a_name_reaches_no_ledger_record`,
`copy_name_value_writes_the_pasteboard_in_core_marked_nspasteboard_concealed`,
`copy_name_value_refuses_unnamed_image_and_unknown_chips_and_writes_nothing`,
`a_name_value_copy_and_a_copy_out_retire_each_others_receipts`,
`a_name_value_copy_records_one_sent_and_no_name`,
`note_routes_edit_the_note_and_leave_the_page_alone`,
`the_note_and_the_page_keep_separate_undo_stacks_across_the_seam`,
`the_note_routes_fail_closed`,
`a_name_and_a_note_reach_no_ledger_record_and_no_other_output`; for the
fragment (ADR-0047), `copy_cut_and_paste_carry_the_envelope_unread_over_the_seam`,
`an_unreadable_envelope_pastes_its_public_text_over_the_seam`,
`a_paste_sweeps_a_due_page_and_says_how_many_over_the_seam` (ADR-0048),
`the_slot_move_and_clone_routes_cross_the_seam`,
`the_fragment_routes_fail_closed`,
`a_decrypted_drag_writes_its_item_core_side_and_records_one_sent_to_drag`,
`a_decrypted_drag_refuses_the_general_pasteboard_a_foreign_type_and_an_unknown_chip`,
`a_decrypted_drag_refuses_a_chip_removed_mid_drag`, and for no route
past the deadline (ADR-0052)
`a_page_past_its_deadline_gives_nothing_out_over_the_seam`,
`neither_conceal_sends_a_page_past_its_deadline`,
`sync_document_names_the_page_and_detaches_omitted_chips`,
`page_routes_refuse_a_file_id`.

Shell (`shell/Tests/CompanionKitTests`, `scripts/test-shell.sh`):
`DocumentOpsTests` (`testAClickOnAChipSelectsItWhole`,
`testDeletingAChipAttachmentEmitsOneDelete`,
`testUndoAfterRemovingAChipStandsTheSameObjectAgain`,
`testPuttingARemovedChipsAttachmentBackReattachesIt`,
`testSealSelectionReplacesTheSelectionCoreSide`,
`testSealingSelectsTheNewObject`, `testSealedPasteOverAChipIsRefused`,
`testTheChipMenuOffersPlaintextByName`,
`testTheContextMenuOffersSealSelectionOverInkOnly`),
`UndoRerouteTests.testASealCannotBeSteppedBack`,
`WrapTests.testUseSelectionForFindRefusesAChip`,
`PasteboardOfferTests` (`testACopyOutArmsTheClearAndFlashesTheInterval`,
`testTheBoardStillHoldsTheCopyInsideTheWindow`),
`ConcealWireTests` (the sealed items line),
`KeymapDispatchTests.testSealSelectedContentIsWiredToTheSameCommand`,
`BundledKeymapTests.testTheSealGesturesAndUndoAreDispatchedByThePage`,
`FocusLawTests.testAChipWhosePageExpiredClearsTheDraftEvenWhileOthersRemain`
(conceal-draft reconciliation after the target chip disappears; it does not
pin chip expiry or lifecycle),
`PageModelPreviewRenderingTests.testChipAttachmentSurvivesEveryScope`,
`SealedBlockTests` (the block's geometry; the named row, its zones, pill,
seat words and beat, and the block's label), `SealedCapsuleTests` (the
zones' clicks and routes, hover by point, both menus, the face changed
in place, the caret and a shift selection crossing an object whole, the
removal line's Undo and its withdrawal),
`SealedNameFieldTests` (the name's field, per Law 0007, and the write
a name or a note edit arms),
`ModalSessionTests.testRenameNeverRunsAModalSession` (naming stays
dialog free), `SealedNoteTests` (the doorway, the popover's placement,
its open, expand, contract and close routes, its edits on the note's
own routes, the page's own surface in it and what stands aside there),
`BundledKeymapTests` (`shift-escape`),
`SealedObjectSeamTests` (the name, `name=value` and note wrappers over
the live core), `SealedFragmentSeamTests` (the fragment, slot, move,
clone and decrypted drag wrappers over the live core, the drag into an
item on a privately named pasteboard, the count of due pages a paste
swept, and every way out refusing a page past its deadline),
`SealedFragmentEditorTests` (the
editor's copy, cut, paste and select all on a privately named
pasteboard, what a service asking for the selection is written and
offered, the clipboard slot's words, where its line stands and its
place at the caret, and their standing aside while a field or the note
holds the keys), `SealedRemovalTests` (the two presses beside an
object, the removal line's Undo standing the same object again, the
removal as its own step, the Undo leaving the line once the page moves
past the removal, and their standing aside while a field or the note
holds the keys), `SealedDragTests` (the page's drag carrying the copy's
fragment alone, a move offered only inside the app, the drop on its
own page moving or with ⌥ cloning through the core as one step, a drop
on another page pasting there and its move removing the source run,
and their standing aside while a field or the note holds the keys),
`SealedDecryptedDragTests` (the handle's seat and press, the decrypted
drag's one promised type, its provider writing through the core on a
destination's ask and refusing after a cancel, a copy offered only
outside the app and refused by the page and the note, and its standing
aside while a field or the note holds the keys),
`LedgerAppendArmingTests` (a paste's and a ⌥ drag's clones and a
provided decrypted drag's `sent` arm a write).

By hand: the [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md)
procedure, for the zones under a real pointer, the beat on a display,
the note on the raised card and VoiceOver naming a block inside the
page by `SealedBlockCell`'s label; the [sealed fragment](../qa/verification-procedures/sealed-fragment.md)
procedure, for what another app and a real drag receive. Neither has
been run.

The tests that pinned the contradicting build (removal reaped, nothing
reattached) were rewritten under issue 170 as the `store.rs` tests
above that detach and reattach, and `DocumentOpsTests`
`testPuttingARemovedChipsAttachmentBackReattachesIt`. The test that
pinned the removal line without its Undo was rewritten as
`SealedCapsuleTests`
`testARemovalFlashesItsLineWithUndoAndAWithdrawalKeepsOnlyTheWords`.
`burning_a_chip_takes_the_stack_with_it` stands, since a burn is not a
removal.

Owed: a first run of the sealed zones and note procedure and of the
sealed fragment procedure, which alone sees the decrypted drag's handle
under a real pointer and its drop into another app; and the shell's
settle after a route refuses a page past its deadline and on wake
(ADR-0052 point 4), with the AppKit paths over text the shell already
holds that its erratum names. Issues 169
(`SealedBlockTests`) and 172 (the interrupting dialogs) are closed;
D-14 is strict and the seal, remove, copy decrypted, naming and note
paths must stay dialog free.

## Amendments

- 2026-09-15: Accepted. Built from the maintainer's sealed object model and
  section 3 of the 2026-0915 record. Where the two differed the maintainer
  settled it the same day: removal is structural and undoable (ADR-0009's
  finality clause, proposed and never accepted, yields); the private type
  carries UUID references, not tickets; there is no per chip TTL; the clear
  after copy is 60 seconds as one core constant.
- 2026-09-15: Review amendment. Narrowed the shell and drag guarantees to
  what the FFI types and Apple's `NSPasteboard` documentation establish;
  replaced the single-reference pasteboard value with a versioned ordered
  fragment; defined lifecycle states and 90-day terminal-cause evidence;
  renamed reversible removal to *Remove from page*; and replaced the
  two-kind taxonomy with five operation classes. D-31 through D-33 and
  ADR-0012 Amendment 1 are interpreted through this amendment.
- 2026-09-15: Review evidence correction. Added D-14 and D-15 to the decision
  cluster; limited each cited test to the behaviour it directly proves; and
  recorded direct coverage that promotion retains the local payload.
- 2026-09-15: Stream navigator amendment. The maintainer's interactive
  design ([2026-0915-stream-navigator.md](../spec/design/2026-0915-stream-navigator.md))
  renamed the removal item back to *Remove protected content*, put the
  copy decrypted chord beside its verb, reworded the three lines that
  follow the menu's actions, set the clear after copy to 90 seconds, and
  made a plain click, Return and Space over the selected object open its
  menu (the click still selects the whole object first). The interval and
  plain-click statements are superseded by the 2026-09-16 entry below.
  The operation classes, the contract table and the lifecycle are
  untouched; the removal's Undo remains owed to issue 170.
- 2026-09-16: Authority amendment. The accepted
  [general-pasteboard clear-interval record](../spec/design/2026-0916-clipboard-clear-interval.md)
  supersedes the 2026-09-15 stream navigator record in full, incorporates
  D-34 through D-41 without change, amends D-42's interval confirmation,
  and replaces D-43 in full. The law therefore reads its clear-after-copy
  contract through the successor: OnetimePad makes a change-count-guarded
  clear attempt after the core-owned 60-second interval and leaves a newer
  general-pasteboard write untouched. This is not a total-retention or
  erasure guarantee. It also carries D-40's explicit-route correction: a
  plain click selects the object without opening the menu. This amendment
  supersedes the clear-interval and plain-click statements in the preceding
  2026-09-15 entry; its remaining decisions stand.
- 2026-10-13: Name and note amendment. The maintainer affirmed the
  [name and note proposal](../mockups/sealed-name-and-note.md): a sealed
  object may carry a typed name and a note, both page-owned ink stored
  with the object core-side and carried in the sealed fragment's envelope
  as two optional text fields, never in the ledger and never payload. The
  name is edited per [Law 0007](0007-edit-in-place.md). A named object's
  bottom row has three pointer zones (name, `=`, value); the two that copy
  plaintext are handles in D-29's sense, a named declassification on the
  object itself with the consequence written in the size class's seat
  before the click. D-40 is narrowed to the rest of the block: a plain
  click outside the bottom row still only selects. D-41's menu gains
  *Copy name*, *Copy name=value, decrypted*, *Name…* or *Rename…* and
  *Note…* or *Edit note…*, in that record's order. Five contract rows are
  added above, all owed.
- 2026-10-13: ADR-0042 amendment.
  [ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md)
  settles what the name and note amendment left open, and is where this
  law cites the narrowed D-40 and the extended D-41. The name is 1 to 64
  characters of `[A-Za-z_][A-Za-z0-9_]*`, case kept, refused core-side.
  An unnamed object's bottom row has no zones, so D-40 holds for the
  whole of an unnamed block. On a named row only the name zone's double
  click opens the field; the value and `=` zones act on the first click
  and ignore the clicks after it. `name=value` copies the value raw. On a
  card narrower than the popover's minimum, the note takes the card's
  full content width. The click row and the five rows of the preceding
  entry change; one row is added.
- 2026-10-13: Body amendment (issue 251). The body now agrees with the
  name and note amendment: the rule's explanation names the name and note
  as ink; the ambient and egress classes place copying the name, the
  value zone and `name=value`; the fragment's references carry the two
  optional text fields; the shell and the ledger invariants say what
  Swift may hold and what the ledger never does; the presentation
  invariants let a named object's bottom row press; the egress list puts
  `name=value` under copy decrypted, so the count stays three; and the
  menu shows the four new items. Every row the name and note added points
  at its issue in epic 252. The owed list drops the closed issues 169 and
  172, and the shell list names `SealedBlockTests`.
- 2026-10-13: Core amendment (issues 241, 242 and 243).
  [ADR-0043](../adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md)
  records where the name and note live, how they persist and what crosses
  the FFI. The naming row, the `=` zone's row and the note's row cite the
  core and seam tests for their core halves and stay owed for the
  surfaces and the fragment. The ledger invariant names the tests that
  keep the name and note out of it, and a test that keeps both out of the
  conceal payloads. The acceptance lists and sources follow; the owed list
  keeps issues 244 to 247.
- 2026-10-13: Zones amendment (issue 244). The bottom row's zones, their
  seat words and pill, the click outside them and *Copy name* and *Copy
  name=value, decrypted* are built. The click row, the unnamed row's
  row and the three zone rows cite `SealedBlockTests` and
  `SealedCapsuleTests`; the name zone's double click stays owed to issue
  245. The presentation invariants and the menu say which parts are
  pinned and which are owed, and the owed list drops issue 244.
- 2026-10-13: Name field amendment (issue 245). The naming row and the
  name zone's row cite `SealedNameFieldTests` and the zone press test for
  the field and the double click, and Law 0007 carries the field's own
  rows. *Name…* and *Rename…* are pinned with the menu, the shell
  acceptance list names the new suites, and the owed list drops issue
  245.
- 2026-10-13: Note amendment (issue 246). The note's row cites
  `SealedNoteTests` for the popover, its placement on a narrow card at
  ADR-0042's recorded minimum, its routes in and out and its edits on
  the note's own routes, and the sealed zones and note procedure for
  what a real pointer and the raised card show; it stays owed to issue
  247 for the fragment. The presentation invariants pin the doorway,
  the menu pins all four new items, the shell acceptance list names the
  new suite and the procedure, and the owed list keeps issue 247 and
  the procedure's first run.
- 2026-10-13: Seat before the click amendment (issue 244). The value
  and `=` zone rows also cite the test that a zone acts only once the
  seat has named it, which ADR-0042's history records; the click that
  brings a window forward selects.
- 2026-10-13: ADR-0044 amendment (issues 244 and 246).
  [ADR-0044](../adr/0044-sealed-row-and-note-details.md) now holds what
  the two entries above cite from ADR-0042's history, and the cluster's
  decisions and sources name it. On an object that is not text the `=`
  zone's row has no zone and the menu no *Copy name=value, decrypted*,
  pinned by `testANamedImagesEqualsIsNoZone` and the menu's order test.
  The note's row adds that a drop from elsewhere lands nowhere in the
  note and that a closed note's view holds none of its ink, pinned by
  `testTheNoteTakesNoDropFromElsewhere` and
  `testAClosedNoteLeavesNoInkInTheShell`.
- 2026-10-13: Note surface amendment (issue 246). The note's row asks
  for the page's own writing surface, and the build gives the note a
  narrower one: the page's base face, its undo chords on the note's own
  stack and plain paste, without the page's markdown face, list
  continuation, ⌘-click links or code fences. The row's wording stands,
  and its tests no longer read as pinning it: the page's own surface is
  owed to issue 246, with what the note lacks named, and the owed list
  names issue 246 again.
- 2026-10-13: Caret amendment. The arrow keys row and the shift
  selection row said AppKit held them and owed a test to no issue.
  Each now cites its direct test in `SealedCapsuleTests`: one arrow
  press takes the caret over an object either way, and every shift
  extension holds an object whole or leaves it out. The backspace
  beside it row stays owed.
- 2026-10-13: Note's own surface amendment (issue 246).
  [ADR-0045](../adr/0045-the-note-is-written-on-the-pages-surface.md)
  puts the note on the page's own surface, routed by document, and names
  what stands aside in it. The note's row replaces the owed clause of
  the preceding note surface amendment with the tests of the page's face,
  lists, links and fences in the note and of the seals, objects, block
  stamps and wrap toggle that stand aside, and adds a click and a
  ⌘-click on a note's link to the procedure's checks. The cluster, the sources and
  the acceptance list name ADR-0045, and the owed list drops issue 246.
- 2026-10-13: Key holder amendment.
  [ADR-0046](../adr/0046-the-keys-holder-answers-the-pages-chords-and-menu.md)
  gives the Edit menu to whoever holds the keys. The note's row cites
  the test that the menu's actions reach the note and not the page while
  the note holds the keys, and that the menu offers no seal there.
- 2026-10-13: VoiceOver amendment. The by hand paragraph adds the
  procedure's check that VoiceOver names a block inside the page by its
  cell's label, which `SealedBlockTests` pins only as a string.
- 2026-10-13: Fragment amendment (issues 170 and 247, the core's half).
  [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  settles the envelope, the detached store, the active cut, resolution
  by the ledger's terminal records, the transaction and its revert, the
  decrypted drag's write into its item and the clipboard slot. The
  select all, copy, cut, paste, drag, ⌥ drag, plain drag, decrypted
  drag, backspace, expiry and burn rows replace their owed clauses with
  the core, seam and wrapper tests that pin them, and owe the editor's
  half of issue 170 and the new [sealed fragment](../qa/verification-procedures/sealed-fragment.md)
  procedure for the rest. The naming and note rows cite the tests of
  the name and note in the fragment and drop issue 247. The drag
  invariant cites the core's refusal of the general pasteboard. The
  paragraph of contradicting tests names their rewrites, the
  acceptance lists and sources follow, and the owed list keeps the
  editor's half and both procedures' first runs.
- 2026-10-13: Editor copy amendment (issue 170's editor half, issue 247).
  The select all and copy rows replace their owed clauses with
  `SealedFragmentEditorTests`, which drives the page's copy and select
  all onto a privately named pasteboard; the other app paste row cites
  the copy's write and owes the cut's and the plain drag's. A selection
  of several stretches holding an object writes nothing and says so in
  a line, since one envelope holds one range. The owed list drops the
  copy and the select all copy.
- 2026-10-13: Due page and bounded envelope amendment (issue 170).
  [ADR-0048](../adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md)
  refuses a page past its deadline to a paste, move or clone and sweeps
  due pages before a paste resolves an object, so the cut row's clock
  and the expiry row hold between a deadline and its sweep.
  [ADR-0049](../adr/0049-a-pasted-envelope-is-bounded.md) makes an
  envelope past 8 MiB, past 1024 references or naming one object twice
  unreadable. The cut, paste, drag, ⌥ drag and expiry rows cite the
  tests that pin both, the cut row names the procedure's new check of a
  cut that outlives its page's deadline across sleep, the acceptance
  lists and sources follow, and the owed list adds the editor's settle
  after a paste.
- 2026-10-13: Editor cut amendment (issue 170's editor half, issue 247).
  The cut row replaces its owed clause with `SealedFragmentEditorTests`,
  which drives ⌘X through the core as one step and the clipboard slot's
  line (ADR-0047 point 12): the objects' names and size classes, the
  line under the owner's page alone, and its button placing the same
  objects at the caret. Both stand aside while a field or the note holds
  the keys. The line and its button on the raised card go to the sealed
  fragment procedure. The other app paste row cites the cut's write. A
  cut of several stretches holding an object cuts nothing and says so in
  a line, as the copy does. The owed list drops the cut and the slot's
  line.
- 2026-10-13: Editor paste amendment (issue 170's editor half, issue 247).
  The inside paste row replaces its owed clause with
  `SealedFragmentEditorTests`, which drives ⌘V, Paste and Match Style
  and Paste Without Detection through the core: a cut's first paste
  reattaches with each name and note, a later one and a paste after copy
  clone, a burned or unknown reference places its placeholder in
  position, an unreadable envelope places the item's public text with a
  line, a paste that swept a due page settles at once, and the page
  stands aside while a field or the note holds the keys.
  `LedgerAppendArmingTests` gains a paste's clones. A note and a file
  leave a fragment to AppKit's paste, which reads the public text. The
  other app paste row cites what a rich or plain text reader takes from
  the board. The owed list drops the paste and its settle.
- 2026-10-13: Editor removal amendment (issue 170's editor half). The
  backspace beside it row replaces its owed clause with
  `SealedRemovalTests`, which drives the two presses through the
  editor: a backspace after an object, or a forward delete before it,
  selects it whole, and the next press removes it. The backspace,
  selected row cites the removal line's Undo, which stands the same
  object again from the detached store, the removal as its own step,
  and the Undo leaving the line once the page moves past the removal.
  Both stand aside while a field or the note holds the keys. The real
  keys and the line's button on the raised card go to the sealed
  fragment procedure. The acceptance list follows, the paragraph of
  contradicting tests names the rewritten removal line test, and the
  owed list drops the second backspace and the removal line's Undo.
- 2026-10-13: Editor drag amendment (issue 170's editor half, issue 247).
  The drag, ⌥ drag and plain drag rows replace their owed clauses with
  `SealedDragTests`. The page's drag carries one item, the copy's
  fragment, and offers a move only inside the app. Its drop on its own
  page moves the run, or with ⌥ clones it, through the core as one
  step (ADR-0047 point 10), and the page settles as the timer does
  (ADR-0048). A drop on another page pastes the fragment there; when
  that drop is a move, the session's end removes the source run, which
  detaches. Another app's answer removes nothing. A fragment never
  meets drop to seal, and a note, a file or a read only page takes
  none. The page stands aside while a field or the note holds the keys.
  The gesture under a real pointer, its insertion line, its image and
  what another app receives go to the sealed fragment procedure.
  `LedgerAppendArmingTests` gains the ⌥ drag's clones. The owed list
  drops the plain drags and the settle after a move or clone.
- 2026-10-13: Editor decrypted drag amendment (issue 170's editor
  half). The decrypted drag row replaces its owed clause with
  `SealedDecryptedDragTests`. The handle stands on the block's top row
  before the actions glyph ([ADR-0051](../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md)),
  since no move handle exists to stand beside. Its drag carries one
  item promising the chip's own type, and the provider hands each ask
  to the core's write. A decrypted drag dropped on the app's own page
  met drop to seal, whose core read would ask the provider while the
  core held the lock the provider's write takes; it now lands only in
  another app ([ADR-0050](../adr/0050-a-decrypted-drag-lands-only-in-another-app.md)):
  no operation is offered inside the app, the page and the note refuse
  it before drop to seal reads the board, and a cancelled session
  answers no later ask. The handle stands aside while a field or the
  note holds the keys. `LedgerAppendArmingTests` gains the provided
  drag's `sent`. The pointer, another app's drop and the app's other
  fields go to the sealed fragment procedure. The owed list drops the
  handle and its data provider.
- 2026-10-13: Editor finishing amendment (issue 170's editor half,
  issue 247). A service asking for the page's selection went through
  AppKit's own write, which carried an attachment character for each
  object. The export, print and share row now cites
  `SealedFragmentEditorTests` for services: a selection holding an
  object is written as the copy composes it, in the types asked for,
  several stretches holding one write nothing, a service that would
  write back over it is not offered, and the page stands aside while a
  field or the note holds the keys. A real service and the text menu's
  Share go to the sealed fragment procedure; export and print stay
  owed until a path exists. The name row gains
  `testANameOrANoteEditArmsAWriteAndARefusalArmsNone` for ADR-0043
  point 5. Every test this law cites was checked to exist.
- 2026-10-13: Deadline gate amendment (issue 170).
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)
  supersedes ADR-0048's consequence that copy, cut, copy decrypted and
  the decrypted drag still read a page past its deadline. The expiry
  row now says that from its deadline, swept or not, no route gives
  the page out, and cites the core, seam and `CompanionClient` tests
  that pin each route's refusal. The decrypted drag row cites its
  refusal of a chip removed mid drag and of a page past its deadline.
  The acceptance lists and sources follow, and the owed list adds the
  shell's settle after a refusal and on wake.
- 2026-10-13: Deadline gate scope amendment (issue 170). ADR-0052's
  erratum finds that AppKit copies, cuts and drags the open note's ink,
  and serves a page's ink alone to a service or a drag of several
  stretches, from text the shell holds, where no core route sees it.
  The expiry row now says no core route gives the page out and names
  the note's text route; those AppKit paths join its owed clause and
  the owed list, for issue 170's shell half.
