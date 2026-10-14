---
id: 0001-sealed-object
title: The sealed object
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
governs: A sealed item occupies one position in the document, but its plaintext is not part of the document's ambient text.
decisions: D-08, D-09, D-10, D-14, D-15, D-27, D-28, D-29, D-30, D-31, D-32, D-33 (docs/spec/design/2026-0915-ui-ux-decisions.md, sections 3 and 5); D-40 and D-41 (docs/spec/design/2026-0915-stream-navigator.md, incorporated by docs/spec/design/2026-0916-clipboard-clear-interval.md); ADR-0042 points 1 to 4, 7 and 8; ADR-0043; ADR-0044; ADR-0045; ADR-0046; ADR-0047; ADR-0048; ADR-0049; ADR-0050; ADR-0051; ADR-0052; ADR-0053; ADR-0054; ADR-0055
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
  - docs/adr/0053-a-copy-or-cut-past-an-envelope-cap-composes-nothing.md (a copy or a cut past an envelope cap writes and detaches nothing, and names the cap)
  - docs/adr/0054-a-drag-between-pages-moves-its-objects.md (a drag between pages moves its objects in one transaction and clears the source's undo)
  - docs/adr/0055-the-decrypted-drag-handle-shows-an-open-hand.md (the pointer over the decrypted drag handle)
sources:
  - docs/adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md (what the fragment, lifecycle and drag rows left open)
  - docs/adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md (the cut row's clock and the expiry row, between a deadline and its sweep)
  - docs/adr/0049-a-pasted-envelope-is-bounded.md (what a crafted envelope can clone)
  - docs/adr/0050-a-decrypted-drag-lands-only-in-another-app.md (what the decrypted drag row left open about its destinations)
  - docs/adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md (where the handle stands with no move handle beside it)
  - docs/adr/0052-a-page-past-its-deadline-gives-nothing-out.md (the expiry row between a deadline and its sweep, for every route that gives a page out)
  - docs/adr/0053-a-copy-or-cut-past-an-envelope-cap-composes-nothing.md (the copy and cut rows past an envelope cap)
  - docs/adr/0054-a-drag-between-pages-moves-its-objects.md (the drag row between pages, which cloned and left the original to the source's undo)
  - docs/adr/0055-the-decrypted-drag-handle-shows-an-open-hand.md (the decrypted drag row's pointer, which ADR-0051 left unchanged)
  - crates/core/src/fragment.rs (the envelope and the public text, from one walk)
  - crates/core/src/transfer.rs (cut, paste, the slot's route, the drags inside a page and between pages, resolution and the transaction)
  - crates/ffi/src/sync_driver.rs and crates/ffi/src/sync_session.rs (`sweep_outbound`, what each enrolled page queues for the relay; `withdraw_ops`; the ballot a device joins)
  - docs/spec/feature/sync/client-protocol.md (draft; 10.31, what sync carries between devices)
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
  - shell/Sources/CompanionKit/InkEditorView.swift (SealedBlockCell, the named row and its zones, the doorway, the chip menu, the seal commands; `makeSurface`, the page's and the note's one writing surface; `deleting` and `selectObjectBeside`, the two presses; `textView(_:shouldChangeTextInRanges:replacementStrings:)` and `settleRemovalWatch`, the removal line after any edit that takes an object; `beginPageDrag`, `dropPageDrag`, `dropMovedPageDrag`, `dropFragment` and `endPageDrag`, the page's drags, and `dropRoute`, where each drop goes; `decryptedDragRect`, `startsDecryptedDrag` and `beginDecryptedDrag`, the decrypted drag's handle, and `isDecryptedDrag`, its refusal)
  - shell/Sources/CompanionKit/DecryptedDrag.swift (the decrypted drag's source and data provider)
  - shell/Sources/CompanionKit/SealedBlockLayout.swift (the named row's zones, pill and allotment; the handle's clearances)
  - shell/Sources/CompanionKit/SealedNameField.swift (the name's field; `SealedNameTextView`, its editor, which asks the object's page before the name leaves)
  - shell/Sources/CompanionKit/TextOffers.swift (no Share… or Writing Tools over a page's, a note's or a name's text)
  - shell/Sources/CompanionKit/SealedNotePopover.swift (`NotePopoverLayout.minimumWidth`, the note's popover)
  - shell/Sources/CompanionKit/PageModel.swift (`copyChipName`, `copyChipNameValue`, `setChipName`, the note's routes; `InkDocument`, the routes by document; `cutSelection`, `placeActiveCut`, `cutSlotSentence`, the cut and the clipboard slot; `pasteFragment`, the paste; `boardHoldsOwnCopy`, the board the sealed paste and its offer leave to ⌘V; `noteRemoval`, `undoRemoval` and `withdrawRemovalUndo`, the removal line and its Undo, `countEdit`, the edits sent for each document that retire it, and `surfaceMounted`, a mount of another page that retires it; `provideDecryptedDrag`, the provider's route)
  - shell/Sources/CompanionKit/PageSurface.swift (`PageStatusStack`, the clipboard slot's line)
  - shell/Sources/OnetimePad/BackdropApp.swift (the commands' empty print group)
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
| copy, object or mixed selection | structural editing | writes one versioned sealed fragment preserving ordered ink runs and UUID references; the public representation preserves the ink and substitutes one size-class placeholder per reference; neither representation contains payload or ciphertext; past an envelope cap it writes neither and names the cap; the board it leaves is the app's own and holds nothing to seal, so no summon offer is made over it, nor over a board another build of the app left (2026-10-14 every build's copy amendment) | the core composes both: `fragment.rs` `a_mixed_selection_keeps_its_ink_and_references_in_order`, `the_public_text_puts_a_size_class_placeholder_where_each_object_stood`, `neither_representation_holds_payload_or_ciphertext`, `a_one_object_copy_is_a_one_reference_fragment`, `the_envelope_reads_as_its_documented_shape`, `an_envelope_this_build_cannot_read_is_refused_whole`; `lib.rs` `copy_cut_and_paste_carry_the_envelope_unread_over_the_seam`, `sealed_bytes_never_appear_in_any_output`; `SealedFragmentSeamTests.swift` `testACopyHandsBackAnEnvelopeAndThePublicText` (ADR-0047); the editor's write of both types and no other on the ordinary copy: `SealedFragmentEditorTests.swift` `testACopyOfAMixedSelectionWritesTheFragmentAndThePublicTextAlone`, `testACopyOfOneObjectIsAOneReferenceFragment`, `testACopyOfInkAloneWritesPlainTextOnly`, `testACopyTheCoreDoesNotComposeWritesNothing`, `testSeveralStretchesCopyAsInkOrNotAtAll`, and each reference's name and note, `testEachReferenceCarriesItsObjectsNameAndNote`; a note's and a file's copy, which AppKit writes, carry their text as plain text and never the private type: `testANoteOrAFileCopiesPlainTextAndNeverTheFragment`; past an envelope cap (ADR-0053): `fragment.rs` `an_envelope_composed_at_a_cap_reads_back_and_one_past_composes_nothing`, `transfer.rs` `a_copy_or_cut_naming_past_the_reference_cap_composes_nothing_and_changes_nothing`, `a_copy_or_cut_longer_than_the_length_cap_composes_nothing_and_changes_nothing`, `lib.rs` `a_copy_or_cut_past_an_envelope_cap_names_the_cap_over_the_seam`, `each_cap_crosses_the_seam_as_its_own_token_and_limit`, `SealedFragmentSeamTests.swift` `testACopyOrCutPastAnEnvelopeCapNamesItsLimitAndChangesNothing`, `testTheSeamsCapAnswersDecodeAsTheirRefusals`, and the editor's line naming the cap and its limit, `SealedFragmentEditorTests.swift` `testACopyCutOrDragPastAnEnvelopeCapNamesItsLimitAndChangesNothing`, the object count cap's through a stand in core for the copy, cut, drag and service write `testEveryEditorRoutePastTheObjectCapNamesItsLimitAndChangesNothing`, on a real selection by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; no offer over the board a copy or a cut leaves: `SealedFragmentEditorTests.swift` `testThisAppsOwnCopyOnTheBoardOffersNothingToSeal`, nor over another build's: `testAnotherBuildsCopyOnTheBoardOffersNothingToSeal`, after a summon by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; what another app receives, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| cut | structural editing | writes the same fragment, then detaches every referenced object in one core transaction; all selected objects appear together in the app's clipboard slot and retain the page's clock; past an envelope cap it writes, deletes and detaches nothing, and an earlier cut stands | `transfer.rs` `a_cut_chip_is_detached_not_reaped`, `a_cut_detaches_every_object_in_one_step_and_undo_stands_them_all`, `a_later_cut_replaces_the_active_one_and_leaves_its_objects_detached`, `a_cut_the_body_refuses_changes_nothing`; undo ends the cut and redo detaches its objects as a removal that a later paste of its envelope clones: `undo_ends_a_cut_and_redo_detaches_as_a_removal_whose_objects_a_later_paste_clones`; past an envelope cap (ADR-0053): `transfer.rs` `a_copy_or_cut_naming_past_the_reference_cap_composes_nothing_and_changes_nothing`, `a_copy_or_cut_longer_than_the_length_cap_composes_nothing_and_changes_nothing`, `lib.rs` `a_copy_or_cut_past_an_envelope_cap_names_the_cap_over_the_seam`, `SealedFragmentSeamTests.swift` `testACopyOrCutPastAnEnvelopeCapNamesItsLimitAndChangesNothing`, and the editor's line naming the cap and its limit with an earlier cut left standing, `SealedFragmentEditorTests.swift` `testACopyCutOrDragPastAnEnvelopeCapNamesItsLimitAndChangesNothing`, the object count cap's through a stand in core `testEveryEditorRoutePastTheObjectCapNamesItsLimitAndChangesNothing`; the page's clock past its deadline (ADR-0048): `transfer.rs` `a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired`, and after sleep by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; the slot's faces: `lib.rs` `copy_cut_and_paste_carry_the_envelope_unread_over_the_seam`, `SealedFragmentSeamTests.swift` `testACutsFirstPasteReattachesAndALaterOneClones`; the editor's ⌘X: `SealedFragmentEditorTests.swift` `testACutDetachesItsObjectsAsOneStepAndOneUndoStandsThemAgain`, `testACutOfInkAloneWritesPlainTextAndLeavesTheSlotAlone`, `testSeveralStretchesCutAsInkOrNotAtAll`, a fragment the board refuses put back by the core's undo `testACutTheBoardRefusesIsPutBack`, standing aside while a field or the note holds the keys (ADR-0046) `testCutAndThePlaceStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; the slot's line: `testTheSlotNamesTheCutObjectsByTheirFacesAlone`, `testTheSlotStandsUnderTheOwnersPageAlone`, `testTheSlotPlacesTheSameObjectAtTheCaretAndItsLineGoes`; the line and its button on the raised card under a real pointer, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| paste, inside OnetimePad | structural editing | inserts the whole fragment as one undoable transaction; the first paste of a cut reattaches all cut objects, while a paste after copy or a later paste of a cut clones every live reference core-side; terminal or unknown references become cause-specific placeholders in their original positions; over several selected stretches a fragment or the slot's cut places nothing and a line says so, as copy, cut and drag refuse them; an item naming the private type whose data cannot be read pastes as an unreadable envelope; ⌘V is the paste of a board holding the private type, and ⇧⌘V or the summon offer's button over it takes nothing, leaves the board and the page as they are and says that ⌘V pastes it; ⇧⌘V and the offer treat another build's type the same, while ⌘V reads only this build's envelope and leaves another build's to AppKit's paste (2026-10-14 every build's copy amendment); the offer's button waits while a field or the note holds the keys, as the chord does (ADR-0046) | `transfer.rs` `a_pasted_reference_reattaches_by_id`, `the_first_paste_of_a_cut_reattaches_all_and_a_later_one_clones`, `a_fragment_not_naming_the_cut_clones_its_objects_and_the_cut_stands`, `a_cut_pasted_on_another_page_moves_there_and_clears_the_source_undo`, which reaches no peer as the drag row's move does: `store.rs` `sync_carries_no_object_so_a_cut_reattached_on_another_page_stands_none_on_a_peer`; `transfer.rs` `a_paste_after_copy_clones_every_live_reference_without_its_receipt`, `a_paste_is_one_step_and_replaces_the_selection_it_covers`, `an_unreadable_envelope_pastes_its_public_text_and_says_so`; rollback: `a_paste_the_body_refuses_partway_changes_nothing_on_any_page`, and after a sweep `a_paste_the_body_refuses_after_its_sweep_reverts_the_paste_and_not_the_sweep`; mixed state: `a_mixed_paste_keeps_its_order_with_each_cause_in_position`; a page past its deadline (ADR-0048): `a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired`, `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`, `a_paste_of_ink_alone_sweeps_nothing`, `lib.rs` `a_paste_sweeps_a_due_page_and_says_how_many_over_the_seam`, `SealedFragmentSeamTests.swift` `testAPasteSweepsADuePageAndSaysHowMany`; a crafted envelope (ADR-0049): `fragment.rs` `an_envelope_past_a_cap_or_naming_one_object_twice_is_refused_whole`, `transfer.rs` `a_crafted_envelope_naming_a_live_object_twice_clones_nothing`; `SealedFragmentSeamTests.swift` `testACutsFirstPasteReattachesAndALaterOneClones`, `testAnUnreadableEnvelopePlacesItsPublicText`; the editor's ⌘V, Paste and Match Style and Paste Without Detection: `SealedFragmentEditorTests.swift` `testACutsFirstPasteReattachesItsObjectsAndALaterOneClonesThem` (names and notes kept by the reattach and carried by the clone), `testAPasteAfterACopyClonesEveryObjectAsOneStep`, `testAGoneReferencePastesItsPlaceholderWhereTheObjectStood`, `testAnUnreadableEnvelopePastesItsPublicTextAndSaysSo`, `testEveryPasteCommandTakesAFragmentThroughTheCore`, `testANoteOrAFileLeavesAFragmentToThePublicText`, `testAPasteThatSweepsADuePageSettlesAtOnce`, `testPasteStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`; several stretches: `testAFragmentPastesIntoOneSelectionNotSeveral`; an item whose data cannot be read: `testAnItemWhoseFragmentCannotBeReadPastesItsPublicTextAndSaysSo`; a refusal arms a write only when its settle can sweep: `testARefusedPasteOrPlaceArmsAWriteOnlyWhenItsSettleSweeps`, `testAPasteRefusedAfterItsSweepStillSettles`; ⇧⌘V and the offer's button over the app's own copy or cut: `testThisAppsOwnCopyOnTheBoardOffersNothingToSeal`, over another build's, with ⌘V left to AppKit: `testAnotherBuildsCopyOnTheBoardOffersNothingToSeal`, and the button's wait: `testTheOffersButtonStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`, both by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; the write it arms: `LedgerAppendArmingTests.swift` `testEveryLedgerAppendingMutationArmsAWrite`; the paste on the raised card, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| paste, another app | ambient observation | receives ordered ink with `[sealed content · <size class>]` substituted for each live reference; never receives a payload | the public text the core composes: `fragment.rs` `the_public_text_puts_a_size_class_placeholder_where_each_object_stood`; size class: `store.rs` `a_multi_line_chip_reports_a_size_class_not_lines`; the editor's copy writes it: `SealedFragmentEditorTests.swift` `testACopyOfAMixedSelectionWritesTheFragmentAndThePublicTextAlone`; the cut's write: `SealedFragmentEditorTests.swift` `testACutDetachesItsObjectsAsOneStepAndOneUndoStandsThemAgain`; what a rich or plain text reader takes from the board: `SealedFragmentEditorTests.swift` `testAnotherAppReadsThePublicTextAlone`; the plain drag's write: `SealedDragTests.swift` `testThePlainDragCarriesTheCopysFragmentAndNothingElse`; what another app pastes, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| drag, inside the document | structural editing | moves the selected objects and ink atomically with a clear insertion line; contents never preview; a drag from anywhere in this app never meets drop to seal: ink from a page or note, a field's text and any other source here land as ink where a page takes ink and are refused elsewhere, the decrypted drag excepted (2026-10-14 drags from this app amendment); drop to seal stays for other apps' drags, save one carrying another build's fragment, which lands its public text as ink (2026-10-14 every build's copy amendment); one stretch of page ink dropped on another page moves through the core, while several stretches of page ink, or a note's ink, land as a copy, AppKit's answer between two text views, and their source keeps them (2026-10-14 several stretches drag amendment); sync carries no object to another device, so a peer refuses the batch that stands a moved object on its page and holds the object on no page, while ink moved between pages reaches it in either order (2026-10-14 sync amendment) | the core's move: `transfer.rs` `a_drag_inside_a_page_moves_ink_and_objects_in_one_step_keeping_identity`; `SealedFragmentSeamTests.swift` `testTheSlotTheMoveAndTheCloneRoutes`; an editor's move in two batches keeps the object: `store.rs` `an_editor_move_in_two_batches_detaches_and_then_reattaches_the_chip`; refused on a page past its deadline: `transfer.rs` `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`; the editor's drop on its own page: `SealedDragTests.swift` `testADragInsideThePageMovesInkAndObjectsAsOneStepKeepingThem`, `testADropOntoItsOwnRangeOrAChangedPageChangesNothing`, `testTheViewsDropRoutesAFragmentAndTheOwnDragThroughTheCore`; a drag to another page moves there as one transaction keeping every object, clears the source's undo when it carries one and refuses a page past its deadline at either end ([ADR-0054](../adr/0054-a-drag-between-pages-moves-its-objects.md)): `transfer.rs` `a_drag_between_pages_moves_ink_and_objects_keeping_identity_name_and_note`, `a_drag_between_pages_clears_the_source_undo_so_nothing_stands_a_second_copy`, `a_moved_object_ends_with_the_page_it_landed_on`, `a_drag_of_ink_alone_between_pages_keeps_the_source_undo`, `a_drag_between_pages_refuses_one_page_a_bad_range_or_a_bad_point`, `a_drag_between_pages_refuses_a_page_past_its_deadline_and_changes_neither`, `a_drag_between_pages_either_body_refuses_changes_neither_page`; `lib.rs` `a_drag_between_pages_crosses_the_seam_keeping_its_object`, `a_drag_between_pages_refuses_a_page_past_its_deadline_over_the_seam`; `SealedFragmentSeamTests.swift` `testADragBetweenPagesMovesTheSameObjectAndRefusesADuePage`; the editor's drop on another page through that route, both pages restated, one object after ⌘Z on the source and the source deleting nothing itself: `SealedDragTests.swift` `testADragToAnotherPageMovesTheSameObjectsAndTheSourceUndoLeavesOne`, `testTheViewsDropRoutesAFragmentAndTheOwnDragThroughTheCore`, `testADragNoPageTookLeavesItsSource`; its refusal on a page past its deadline settling with its line: `testAMoveFromAPagePastItsDeadlineSettlesAndChangesNothing`; ⌥ or a stale drag between pages pasting a copy and leaving its source (ADR-0054 point 5): `testAnOptionOrStaleDragToAnotherPagePastesACopyAndLeavesItsSource`; ink from another page or from the note landing as ink, and another app's ink still meeting drop to seal: `testInkFromAnotherPageLandsAsInkAndNeverSeals`, `testInkFromTheNoteLandsAsInkAndNeverSeals`, `testAnotherAppsInkStillMeetsDropToSeal`, every other source here (the shared field editor, the name field's own, a field editor in another window and any view) landing as ink and refused by a read only page and the note `testEveryOtherDragFromThisAppLandsAsInkAndNeverSeals`, a field's own drag landing while it holds the keys and waiting while the note or another field holds them `testADragFromAFieldStandsAsideWhileAnotherHolderHasTheKeys`, another build's fragment landing as its text and standing aside while a field holds the keys `testAnotherBuildsFragmentLandsAsItsTextAndNeverSeals`, several stretches landing as a copy `testSeveralStretchesOfInkDraggedToAnotherPageLandAsACopy`; standing aside while a field or the note other than the drag's own source holds the keys: `testDragsStandAsideWhileAFieldOrTheNoteHoldsTheKeys`, `testInkFromTheNoteLandsAsInkAndNeverSeals`; its image drawing no excerpt (the plain drag row): `testTheDragsImageDrawsInkAndEachFaceButNoExcerpt`; a move between pages against a peer, delivered destination first or source first: `store.rs` `sync_carries_no_object_so_a_move_between_pages_stands_none_on_a_peer`, `a_move_of_ink_between_pages_reaches_a_peer_in_either_order`; the gesture under a real pointer, its insertion line, its image on screen and a drop between the card and the editor window, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| ⌥ drag | structural editing | clones all selected sealed objects core-side as one operation, following the macOS copy-drag convention | the core's clone: `transfer.rs` `an_option_drag_clones_every_object_in_one_step`; refused on a page past its deadline: `a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep`; the editor's ⌥ drop: `SealedDragTests.swift` `testAnOptionDragClonesEveryObjectCoreSide`, `testADragOffersAMoveOnlyInsideTheAppAndOptionNarrowsItToACopy`; its clones arm a write: `LedgerAppendArmingTests.swift`; ⌥ under a real pointer, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| plain drag, outside | ambient observation | exposes only ordered ink and placeholders; its image, which other apps see pass, draws the ink and each object's face with its size class and any name but never its excerpt; a tab, gutter or pad rename field takes the same public text, as it does by paste, and the source keeps its run | the public text it carries is the copy's (the copy row); the drag's one item, the copy's fragment, with nothing else written and the ordinary pasteboard untouched: `SealedDragTests.swift` `testThePlainDragCarriesTheCopysFragmentAndNothingElse`, `testInkAloneDragsAsPlainTextAndSeveralStretchesWithAnObjectDoNot`; its image, rendered offscreen, the same for two objects that differ only in their contents while AppKit's own image of them differs, and still drawing the ink and a name: `testTheDragsImageDrawsInkAndEachFaceButNoExcerpt`; only a copy offered outside the app, and no run removed when another app or a rename field takes it: `testADragOffersAMoveOnlyInsideTheAppAndOptionNarrowsItToACopy`, `testADragNoPageTookLeavesItsSource`; what another app and a rename field receive, and the image as it passes over another app, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| decrypted drag, from the handle | declassification/egress | a distinct, labelled handle, under an open hand pointer wherever a press would start the drag; the core supplies the complete payload lazily when a destination asks and records destination `Drag`; a successful drop never deletes the object | the core's write into the drag item, its refusals and its record: `lib.rs` `a_decrypted_drag_writes_its_item_core_side_and_records_one_sent_to_drag`, `a_decrypted_drag_refuses_the_general_pasteboard_a_foreign_type_and_an_unknown_chip`, a chip removed mid drag `a_decrypted_drag_refuses_a_chip_removed_mid_drag`, a page past its deadline (ADR-0052) `a_page_past_its_deadline_gives_nothing_out_over_the_seam`, settled with no line since a destination asked `SealedDecryptedDragTests.swift` `testAnAskPastThePagesDeadlineIsRefusedAndSettlesWithoutALine`, `the_fragment_routes_fail_closed`; `crates/pasteboard/src/macos.rs` `a_drag_item_takes_the_plaintext_under_its_kinds_type`, `a_drag_item_on_the_general_pasteboard_says_so`, `a_drag_item_refuses_null_and_objects_of_another_class`; `SealedFragmentSeamTests.swift` `testADecryptedDragWritesTheItemCoreSideAndRecordsADrag`; its buffer: `store.rs` `a_copy_out_is_written_at_its_exact_size`; the `Drag` class at rest: `persist.rs` `every_destination_class_round_trips_in_the_ledger`; the handle's seat and press ([ADR-0051](../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md)): `SealedDecryptedDragTests.swift` `testTheHandleSitsBeforeTheActionsSeatAndOnlyWhereItFits`, `testTheHandleDragsTheChipsOwnTypeAndAnUnknownKindHasNone`, `testOnlyAFirstPlainPressOnADrawnHandleStartsTheDrag`; the open hand over a drawn handle and over none while a field or the note holds the keys ([ADR-0055](../adr/0055-the-decrypted-drag-handle-shows-an-open-hand.md)): `testTheHandleShowsAnOpenHandWhereAPressWouldStartTheDrag`; its data provider, the core's write on a destination's ask, its record arming a write and the object left standing: `testADestinationsAskIsWrittenByTheCoreAndRecordsOneDrag`, `LedgerAppendArmingTests`; a cancelled session and a foreign ask refused: `testACancelledDragAndAForeignAskAreRefused`; a copy outside the app and no drop on the page or the note, each step of the drop refusing it with drop to seal never asked ([ADR-0050](../adr/0050-a-decrypted-drag-lands-only-in-another-app.md)): `testTheDragOffersACopyToAnotherAppAndNothingInsideThisOne`, `testTheDecryptedDragLandsOnNoPageOfThisApp`; standing aside: `testTheDecryptedDragStandsAsideWhileAFieldOrTheNoteHoldsTheKeys`; the handle under a real pointer, a drop into another app, a cancel and the app's other fields, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| backspace beside it | structural editing | the first press selects the object, the second removes it from the page; every deletion at a caret whose first character in its direction is the object does the same (⌦, ⌥⌫, ⌥⌦, ⌃⌫, ⌘⌫, ⌃K and their line and paragraph kin), while one whose reach runs past ink takes the objects it reaches in that press, as a step of their own, with the removal line; ⌃T moves an object a place and removes nothing | the editor's two presses, and a forward delete before the object alike: `SealedRemovalTests.swift` `testTheFirstBackspaceBesideAnObjectSelectsItAndTheSecondRemovesIt`, `testTheFirstForwardDeleteBeforeAnObjectSelectsItAndTheSecondRemovesIt`; every other caret deletion, `testEveryCaretDeletionBesideAnObjectSelectsItFirst`; a reach past ink, `testADeletionReachingPastInkTakesItsObjectsWithTheLine`, `testARemovalByReachIsItsOwnStepAfterADeletionRun`; ⌃T, `testATransposeBesideAnObjectKeepsItAndSaysNothing`; a press beside ink deletes one character, `testAPressBesideInkDeletesOneCharacter`; standing aside while a field or the note holds the keys (ADR-0046) `testBackspaceAndTheUndoStandAsideWhileAFieldOrTheNoteHoldsTheKeys`, `testEveryDeletionYankAndTypingStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; the real keys on the raised card, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| backspace, selected | structural editing | detaches it immediately, with Undo available; undo reattaches from the detached store; the same holds when any other deletion, Edit > Delete, ⌃Y, typing, Return, a composition, a board's text as AppKit pastes it, a fragment's paste or the slot's place replaces a selection holding an object, which goes as one step with the removal line; an edit AppKit asks to make and never makes says nothing at a later edit (2026-10-14 removal watch amendment) | removal as one unit: `DocumentOpsTests.swift` `testDeletingAChipAttachmentEmitsOneDelete`; the detach and the undo: `store.rs` `deleting_a_sentinel_by_op_detaches_the_chip_and_records_nothing`, `undo_stands_a_removed_chip_again_from_the_detached_store`; through the editor: `DocumentOpsTests.swift` `testUndoAfterRemovingAChipStandsTheSameObjectAgain`, `testPuttingARemovedChipsAttachmentBackReattachesIt`; the removal line's Undo, which stands the same object again and leaves the line once the page moves past the removal: `SealedRemovalTests.swift` `testTheRemovalLinesUndoStandsTheSameObjectAgain`, `testASelectionHoldingAnObjectGoesInOnePressWithUndo`, `testARemovalIsItsOwnStep`, `testTheUndoGoesOnceThePageMovesPastTheRemoval`, `testTheMenusRemovalOffersTheSameUndo`; the Undo outliving the surface that made the removal, and leaving the line at an edit or a step sent through any surface or with its page: `testTheRemovalLinesUndoOutlivesItsSurface`, `testTheUndoStepsThroughTheSurfaceMountedAfterTheTeardown`, `testTheUndoAfterTheTeardownStandsAsideWhileAFieldHoldsTheKeys`, `testTheUndoWithItsPageShownNowhereWaitsWhileAFieldHoldsTheKeys`, `testAnEditThroughAnotherSurfaceRetiresTheUndo`, `testAStepAfterTheRemovalRetiresTheLinesUndo`, `testTheUndoGoesWithItsPage`; leaving the line when any surface mounts another page, and stepping only through the surface that shows its page, past that surface's editability gate (2026-10-14 removal Undo gates amendment): `testAMountOfAnotherPageRetiresTheUndo`, `testTheUndoRewritesNoPageShownReadOnly`; the other routes over a selected object, `testEditDeleteTakesASelectedObjectWithTheLine`, `testAYankOverASelectedObjectTakesItWithTheLine`, `testTypingOverASelectedObjectTakesItAsOneStepWithTheLine`, `testACompositionOverASelectedObjectTakesItWithTheLineWhenItEnds`, `testABoardsTextReadOverASelectedObjectTakesItWithTheLine`, `testAPasteOrPlaceOverASelectedObjectTakesItWithTheLine`; no line from an ask no edit followed: `testAnAskNoEditFollowedJudgesNoLaterEdit`; `SealedCapsuleTests.swift` `testARemovalFlashesItsLineWithUndoAndAWithdrawalKeepsOnlyTheWords`; the line's button on the raised card and on another surface, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md) |
| text holding U+FFFC: ⌃Y after ⌃K over an object, a paste, drop or service of text, typing, a composition | structural editing | U+FFFC stands for an object only through the object's own mark, so text holding it lands in a page or a note without it, the caret after what landed, and no object stands; the core refuses a page's or a note's batch and the page's recovery mirror that would write it as ink, and a pasted envelope's ink and note and the public text it falls back to lose it; a file keeps it as its own text (2026-10-14 object character amendment) | the editor's ink entry: `SealedRemovalTests.swift` `testAYankOfKilledObjectsLandsTheirInkWithoutTheObjectCharacter`, `testOutsideTextHoldingTheObjectCharacterLandsWithoutIt`, `testACommittedCompositionLandsWithoutTheObjectCharacter`, the recovery dropping one an earlier build wrote `testTheRecoveryDropsAnObjectCharacterNoObjectCarries`, ⌃T still moving an object `testATransposeBesideAnObjectKeepsItAndSaysNothing`; the core: `store.rs` `neither_a_page_nor_a_note_takes_the_chip_sentinel_as_ink`, `fragment.rs` `an_envelopes_ink_and_note_read_without_the_chip_sentinel`, `transfer.rs` `a_paste_places_its_ink_without_the_chip_sentinel`; a file keeping it: `files.rs` `a_file_keeps_the_chip_sentinel_as_its_own_text`, `FileDocumentTests.swift` `testAFileKeepsTheObjectCharacterAPageDrops`; over the seam: `SealedObjectSeamTests.swift` `testNeitherAPageNorANoteTakesTheObjectCharacterAsInk`; ⌃K and ⌃Y on the real keys by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure |
| find, word count | ambient observation | does not inspect the payload; may count one protected object | `WrapTests.swift` `testUseSelectionForFindRefusesAChip`; no word count exists |
| expiry | destruction/lifecycle | destroys all of the page's attached and detached payloads; while terminal-cause evidence remains, later references produce an expired placeholder and cannot be undone; from its deadline, swept or not, no core route gives the page out: copy decrypted, copy `NAME=value`, the decrypted drag, both conceals, the note's text and the fragment's copy and cut refuse it, writing and recording nothing ([ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)); the core's next event is now for it whatever its clock's shape, a peer's hold included, and a hold this device publishes rounds a frozen life under a millisecond up, never to none (2026-10-14 next event amendment); the shell settles after each refusal, telling a person who asked, and on wake, says the page expired over an object's refusal only when that object's own page went (2026-10-14 object refusal amendment) and the object stood before the settle (2026-10-14 unknown object amendment), and AppKit's ways out over text the shell shows ask first, Use Selection for Find and an object's name, by Copy name or by its field, among them (2026-10-14 finder and name amendment); sync gives the relay none of it: the core exports no update and cuts no key frame from it, the sync sweep withdraws its unsealed ops and anchors no rotation on it, a device holding it joins no ballot for it, and its expiry still goes so a peer's copy dies too (2026-10-14 sync deadline amendment); it does not enrol, and ink typed before its deadline that no sweep took before a sleep past it reaches no publish (2026-10-14 sync enrolment amendment) | `store.rs` `an_expiring_page_destroys_its_detached_chips_and_records_each`; `transfer.rs` `an_expired_reference_says_so_while_evidence_remains_then_is_unavailable`, `the_active_cut_ends_with_its_page`; between the deadline and its sweep (ADR-0048): `a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired`, `a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired`; no route gives it out (ADR-0052): `store.rs` `copy_decrypted_refuses_a_page_past_its_deadline_before_its_sweep`, `copy_name_value_refuses_a_page_past_its_deadline_before_its_sweep`, `conceal_refuses_a_page_past_its_deadline_before_its_sweep`, `the_note_refuses_a_page_past_its_deadline_before_its_sweep`, the gate agreeing with the sweep `the_read_gate_and_the_sweep_agree_on_the_deadline`, `a_held_page_reads_until_its_frozen_life_drains`, and with the next event `a_peer_hold_with_no_life_left_settles_the_page_at_once`, a held life under a millisecond rounded up `a_held_life_under_a_millisecond_reaches_a_peer_still_alive`; `transfer.rs` `a_page_past_its_deadline_gives_no_copy_before_its_sweep`, `a_page_past_its_deadline_gives_no_cut_before_its_sweep`; `lib.rs` `a_page_past_its_deadline_gives_nothing_out_over_the_seam`, `neither_conceal_sends_a_page_past_its_deadline`; `SealedFragmentSeamTests.swift` `testAPagePastItsDeadlineGivesNothingOutAndTheSettleSweepsIt`; sync: `store.rs` `sync_exports_no_update_of_a_page_past_its_deadline_before_its_sweep`, `a_page_past_its_deadline_owes_no_ceremony_and_cuts_no_key_frame_before_its_sweep`, `sync_driver.rs` `a_page_past_its_deadline_gives_the_relay_no_ops_queued_or_new`, `a_closed_page_seals_no_queued_ops_and_its_rotation_anchors_before_a_deadline`, `a_sleep_past_the_deadline_publishes_none_of_the_ink_typed_before_it`, `a_page_past_its_deadline_does_not_enrol_and_gives_the_relay_nothing`, `sync_session.rs` `a_proposal_for_a_page_past_its_deadline_here_spends_nothing`, `withdrawn_ops_leave_the_page_s_expiry_and_every_other_page_queued`; the shell settling after each refusal with its line where a person asked: `SealedFragmentEditorTests.swift` `testEveryWayOutOfAPagePastItsDeadlineRefusesAndTheSettleTakesIt`, `testAConcealPastTheDeadlineSendsNothingAndTheSettleTakesThePage`, an object's copy or conceal refused for its own reason while another page comes due `testAnObjectsRefusalSaysExpiredOnlyWhenItsOwnPageWent`, and over an object no page held before the settle `testAnUnknownObjectsRefusalNeverSaysAPageExpired`, with the core's answer, which reads past the deadline gate, `store.rs` `an_object_on_a_page_past_its_deadline_still_stands_until_its_sweep` and `lib.rs` `an_object_stands_over_the_seam_until_its_page_is_swept`; Copy name among the ways out in `testEveryWayOutOfAPagePastItsDeadlineRefusesAndTheSettleTakesIt`; `SealedDecryptedDragTests.swift` `testAnAskPastThePagesDeadlineIsRefusedAndSettlesWithoutALine`, a refusal arming nothing but its sweep `LedgerAppendArmingTests.swift` `testARefusedReadArmsNothingAndPastADeadlineOnlyItsSweepAppends`; on wake: `TabLifetimeTests.swift` `testAWakeSettlesAPageThatCameDueWhileTheMachineSlept`; AppKit's service write and several stretch drag of a page's ink alone and the open note's copy, cut, drag and service asking first: `SealedFragmentEditorTests.swift` `testAppKitsWaysOutOfAPagePastItsDeadlineAskFirstAndSettle`, which drives the note's copy and cut only through the question they ask, since NSTextView writes them to the general pasteboard; Use Selection for Find on the page and in the note asking first, in the same test through its gate alone, since a finder that ran writes the find pasteboard every process reads, and its control `testUseSelectionForFindGoesToTheFinderWhileThePageStands`; the name field's copy, cut and service, and its drag through its gate, `testANamePastItsPagesDeadlineGivesNothingOutAndTheSettleTakesThePage`, and their control with Copy name's `testANameCopiesFromTheZoneAndTheFieldWhileItsPageStands`; a real sleep and wake by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure |
| explicit burn | destruction/lifecycle | destroys the named local payloads atomically; while terminal-cause evidence remains, later references produce a burned placeholder | `store.rs` `burning_a_chip_takes_the_stack_with_it`, `burning_a_detached_chip_destroys_it_and_takes_the_stack_with_it`; `transfer.rs` `a_burned_reference_says_so`, `burning_a_clones_source_leaves_the_clone` |
| export, print, share | ambient observation | emits placeholders by default; a plaintext export is separately named declassification/egress | a service asking for the page's selection takes the copy's public text alone, and none that would write back over an object is offered: `SealedFragmentEditorTests.swift` `testAServiceTakesThePublicTextAndNoServiceWritesOverAnObject`, `testAServiceTakesInkAsAppKitWritesItAndSeveralStretchesNotAtAll`, and its standing aside while a field or the note holds the keys (ADR-0046) `testServicesStandAsideWhileAFieldOrTheNoteHoldsTheKeys`; a real service, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md); share has no path over a page, a note or a sealed name: their text menus hold no Share… and their text views answer Writing Tools with none, while a file keeps both (2026-10-14 share and Writing Tools amendment), `SealedFragmentEditorTests.swift` `testAPageANameAndANoteOfferNoShareAndNoWritingTools`, and the menus and Writing Tools on hardware, owed: hand check, [sealed fragment](../qa/verification-procedures/sealed-fragment.md); print has no path: no menu holds Print… and nothing sends `print:`, and the commands replace the print group with nothing so no later scene brings one; the test runner cannot build the menu bar, so by hand in the [sealed fragment](../qa/verification-procedures/sealed-fragment.md) procedure; export, owed when a path exists |
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
| the note (*Note…*, *Edit note…*, a click on `note`) | structural editing | the page's own writing surface in a popover at the block's measure, or the card's full content width when the block's measure is narrower than the popover's minimum, expanded to the card by its diagonal arrows or ⇧Esc and contracted the same way; a drop from elsewhere lands nowhere in it, since no seal can stand in a note ([ADR-0044](../adr/0044-sealed-row-and-note-details.md)), and once closed its view holds none of its ink; ink stored with the object core-side, carried in the fragment, never in the ledger, on the page's clock; a note whose text the core refuses opens nothing, or closes if open, and settles, never standing empty (2026-10-14 note refusal amendment) | the core's note: `store.rs` `a_note_survives_a_snapshot_round_trip`, `after_the_page_expires_the_snapshot_holds_no_note`, `undo_inside_the_note_is_separate_from_the_pages_undo`, `note_edits_leave_the_ledger_unchanged`, `a_note_takes_no_chip_and_a_refused_first_batch_makes_no_note`; `lib.rs` `note_routes_edit_the_note_and_leave_the_page_alone`, `the_note_and_the_page_keep_separate_undo_stacks_across_the_seam`; the popover: `SealedNoteTests.swift` `testThePopoverHangsUnderTheBlockAtTheBlocksMeasure`, `testANarrowBlockPutsTheNoteAcrossTheContentWidth`, `testExpandedTheNoteCoversTheContentAndWithoutRoomBelowItStandsAbove`, `testTheMenusVerbOpensTheNoteInThePagesOwnWindow`, `testTheDoorwayOpensTheNoteAndEscClosesIt`, `testTheArrowsAndShiftEscExpandAndContractAndEscContracts`, `testTheNoteClosesWhenItsSeatGoes`, `testTheObjectLeavingThePageClosesItsNote`, `testANoteEditLeavesThePagesCaretAndUndoAlone`, `testNoNoteRouteRunsAModalSession`, `testTheNoteTakesNoDropFromElsewhere`, `testAClosedNoteLeavesNoInkInTheShell`; a refused note opening nothing `SealedFragmentEditorTests.swift` `testEveryWayOutOfAPagePastItsDeadlineRefusesAndTheSettleTakesIt` and an open one closing `testAnOpenNoteTheCoreRefusesClosesAndTheSettleTakesItsPage`; the page's own surface ([ADR-0045](../adr/0045-the-note-is-written-on-the-pages-surface.md)): `SealedNoteTests.swift` `testTheNoteWearsThePagesFace`, `testANoteContinuesAndNestsAListAsThePageDoes`, `testChooseLanguageActsOnTheNoteAndItsLabelIsTheNotesOwn`, the Edit menu acting on the note while it holds the keys ([ADR-0046](../adr/0046-the-keys-holder-answers-the-pages-chords-and-menu.md)) `testTheEditMenuActsOnTheNoteWhileItHoldsTheKeys`, and what stands aside in it, `testNoSealLandsInANote`, `testNoObjectStandsInANote`, `testANoteShowsNoBlockStampsAndAsksNoPageForThem`, `testTheWrapToggleStandsAsideInANote`; on the raised card and under a real pointer, and a click and a ⌘-click on a note's link, owed: hand check, [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md); the note in the fragment, carried by a clone with an empty undo stack and kept by a reattach: `fragment.rs` `the_envelope_round_trips_with_and_without_a_name_and_a_note`; `transfer.rs` `a_clone_carries_the_name_and_note_its_fragment_holds`, `a_reattached_object_keeps_its_own_name_and_note`; with its object when removed: `persist.rs` `a_detached_chip_comes_back_detached_with_its_name_and_note` (issue 247, ADR-0047) |

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
(ADR-0049),
`an_envelope_composed_at_a_cap_reads_back_and_one_past_composes_nothing`
(ADR-0053), and for the name
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
`undo_ends_a_cut_and_redo_detaches_as_a_removal_whose_objects_a_later_paste_clones`,
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
`a_page_past_its_deadline_gives_no_cut_before_its_sweep`, and for a
copy or a cut past an envelope cap (ADR-0053)
`a_copy_or_cut_naming_past_the_reference_cap_composes_nothing_and_changes_nothing`,
`a_copy_or_cut_longer_than_the_length_cap_composes_nothing_and_changes_nothing`,
and for a drag between pages (ADR-0054)
`a_drag_between_pages_moves_ink_and_objects_keeping_identity_name_and_note`,
`a_drag_between_pages_clears_the_source_undo_so_nothing_stands_a_second_copy`,
`a_moved_object_ends_with_the_page_it_landed_on`,
`a_drag_of_ink_alone_between_pages_keeps_the_source_undo`,
`a_drag_between_pages_refuses_one_page_a_bad_range_or_a_bad_point`,
`a_drag_between_pages_refuses_a_page_past_its_deadline_and_changes_neither`,
`a_drag_between_pages_either_body_refuses_changes_neither_page`. In `store.rs`:
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
`page_routes_refuse_a_file_id`; for a copy or a cut past an envelope
cap (ADR-0053),
`a_copy_or_cut_past_an_envelope_cap_names_the_cap_over_the_seam`,
`each_cap_crosses_the_seam_as_its_own_token_and_limit`; for a drag
between pages (ADR-0054),
`a_drag_between_pages_crosses_the_seam_keeping_its_object`,
`a_drag_between_pages_refuses_a_page_past_its_deadline_over_the_seam`.

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
swept, every way out refusing a page past its deadline, a copy or a
cut past an envelope cap naming its limit, and a move between pages
keeping its object),
`SealedFragmentEditorTests` (the
editor's copy, cut, paste and select all on a privately named
pasteboard, what a service asking for the selection is written and
offered, the clipboard slot's words, where its line stands and its
place at the caret, and their standing aside while a field or the note
holds the keys; every way out of a page past its deadline refusing and
settling with its line, AppKit's ways out over text the shell shows
asking first, a copy, cut or drag past an envelope cap naming its
limit, a paste or place over several stretches refused with its line,
an item whose fragment cannot be read pasting its public text, a
refused paste or place arming a write only when its settle can sweep,
a note's or a file's copy writing plain text alone, this app's own copy
on the board offering nothing to seal, and the offer's button standing
aside while a field or the note holds the keys), `TabLifetimeTests` (a wake settling a page that came due
asleep), `SealedRemovalTests` (the two presses beside an
object for every caret deletion, a reach past ink taking its objects
with the line, every other route over a selected object saying the
line, the removal line's Undo standing the same object again, the
removal as its own step, the Undo leaving the line once the page moves
past the removal through any surface or goes, the Undo outliving the
surface that made the removal, and their standing aside while a field
or the note holds the keys), `SealedDragTests` (the page's drag carrying the copy's
fragment alone and an image that draws no object's excerpt, a move
offered only inside the app, the drop on its
own page moving or with ⌥ cloning through the core as one step, a drop
on another page moving there through the core keeping every object, ⌥
or a stale drag there pasting a copy, ink from this app's pages and
notes landing as ink while another app's still meets drop to seal, and
their standing aside while a field or the note holds the keys),
`SealedDecryptedDragTests` (the handle's seat, press and open hand, the
decrypted drag's one promised type, its provider writing through the core on a
destination's ask and refusing after a cancel or past the page's
deadline, a copy offered only
outside the app and refused by the page and the note, and its standing
aside while a field or the note holds the keys),
`LedgerAppendArmingTests` (a paste's and a ⌥ drag's clones and a
provided decrypted drag's `sent` arm a write; a refused read arms
nothing, and past a deadline only its settle's sweep appends).

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
and its open hand under a real pointer and its drop into another app,
a page's drag image as it passes over another app, a page that comes
due asleep going at the wake, the cap's line on a real selection, the
removal line after ⌥⌫, ⌘⌫, ⌃K, Edit > Delete and typing over an object
on the real keys, the removal line's Undo clicked on another surface
than the one that made the removal, a drag between the card and the editor window, where the source holds the
key window's keys, a page's drag dropped on a rename field, ⇧⌘V and the
summon offer over this app's own copy, the offer's button while a name
is written, and a menu bar with no Print…. Issues 169
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
- 2026-10-13: Composed envelope cap amendment (issue 170).
  [ADR-0053](../adr/0053-a-copy-or-cut-past-an-envelope-cap-composes-nothing.md)
  supersedes ADR-0049's consequence that a selection past an envelope
  cap still copies and cuts. The copy and cut rows now say that past a
  cap they write nothing, a cut deletes and detaches nothing, and the
  refusal names the cap, and cite the core, seam and `CompanionClient`
  tests that pin it. The cut row also cites the test that undo ends a
  cut and redo detaches its objects as a removal a later paste clones.
  The acceptance lists and sources follow, and the owed list adds the
  editor's line naming the cap.
- 2026-10-13: Move between pages amendment (issue 170).
  [ADR-0054](../adr/0054-a-drag-between-pages-moves-its-objects.md)
  supersedes ADR-0047 point 10's last sentence, under which a drag
  between pages pasted a clone and left the original for the source's
  undo to stand again. The drag row now says such a drag moves its
  range as one transaction keeping every object, clears the source's
  undo when it carries one and refuses a page past its deadline at
  either end, and cites the core, seam and `CompanionClient` tests that
  pin the route. The editor still pastes and removes the source run
  until issue 170's shell half wires its drop to the route; the row and
  the owed list say so. The acceptance lists and sources follow.
- 2026-10-13: Deadline and cap shell amendment (issue 170). The shell
  now settles after each refusal of a page past its deadline, as when
  its timer fires, with the line `this page has expired.` where a
  person asked and none for the decrypted drag's provider; it settles
  on the system's wake; and AppKit's ways out over text it shows ask
  first. The expiry row says so and cites the editor, decrypted drag,
  arming and tab lifetime tests in place of its owed clause. The copy
  and cut rows cite the editor's line naming the cap and its limit,
  and the decrypted drag row its settle. The sealed fragment procedure
  gains a sleep and wake check and a cap check; the acceptance list
  and the owed list follow.
- 2026-10-13: Drop between pages amendment (issue 170's shell half).
  The editor's drop on another page now calls the move between pages
  while the source page's own drag still stands
  ([ADR-0054](../adr/0054-a-drag-between-pages-moves-its-objects.md)
  point 5). Both pages restate, the source deletes nothing at the end
  of its session, and a refusal settles with `this page has expired.`
  when the sweep took either page. A drop with ⌥, or one whose source
  drag no longer stands, pastes the copy fragment and leaves the
  source, and the cursor offers a copy for it. The drag row cites
  `SealedDragTests` in place of its owed clause. A page's drops stand
  aside while a field or note holds the keys, but not for the drag's
  own source, which on hardware holds the key window's keys. The
  sealed fragment procedure's step between pages is rewritten; the
  acceptance list and the owed list follow.
- 2026-10-13: Ink from this app's editors amendment (issue 170,
  following ADR-0054 point 5 and ADR-0047 point 10). A drag whose
  source is a page or a note of this app never meets drop to seal on
  another page. One stretch of a page's ink dropped as a move goes
  through the move between pages. Any other ink from a page or a note,
  a drop with ⌥, several stretches, a drag that no longer stands or
  the note's text, lands as AppKit drops ink. AppKit offers a copy
  between two text views, so the note keeps its ink. That drop stands
  aside while a field or note other than its source holds the keys.
  Drop to seal stays for other apps' drags, and a file, a note or a
  read only page still takes no ink from another editor. The drag row
  says so and cites `SealedDragTests`.
- 2026-10-13: Rename field drop amendment (issue 170, following ADR-0054
  point 5). A page's drag dropped on a tab, gutter or pad rename field
  keeps today's behaviour. The field takes the fragment's public text,
  as it does by paste and as another app would, and the source keeps
  its run, since only a page's drop moves one. The sealed name field
  and the note still take no drop from elsewhere (ADR-0044 point 4).
  The plain drag row says so; the field itself is a hand check in the
  sealed fragment procedure.
- 2026-10-14: Paste over several stretches amendment (issue 170's shell
  half, following the editor copy amendment). A fragment pasted over
  several selected stretches, by ⌘V, Paste and Match Style, Paste
  Without Detection or the slot's Place, places nothing and says
  `sealed objects paste into one selection, not several.`, since the
  core places one range as one envelope holds one. A board without the
  private type still goes to AppKit's paste. The inside paste row says
  so and cites `SealedFragmentEditorTests`; the sealed fragment
  procedure gains a check of the line under a real selection.
- 2026-10-14: Unreadable item amendment (issue 170's shell half,
  following [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 3). A board item that names the private type but gives no data
  under it pastes as an envelope this build cannot read: its public
  text with the line, or the refusal's line when it has no text. Before,
  it went to AppKit's paste with no line. The inside paste row says so
  and cites `SealedFragmentEditorTests`.
- 2026-10-14: Refusal settle amendment (issue 170, following
  [ADR-0048](../adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md)).
  A refused paste, place, drop or move settles as the timer would only
  when an event was due as it began, since the sweep a paste runs
  before it may refuse takes nothing otherwise; a refusal with nothing
  due arms no write. A refused paste or place whose settle took its page says
  `this page has expired.`, as the move between pages does. The inside
  paste row cites the tests.
- 2026-10-14: Note and file copy amendment (issue 170). A note's and a
  file's copy write as AppKit does onto the model's ambient board,
  which is the general pasteboard in the app, so a test can read them.
  The copy row cites the test that they write plain text and never the
  private type. The acceptance list follows.
- 2026-10-14: Drag image amendment (issue 170, following
  [ADR-0051](../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md)
  point 5, which keeps the block's face out of the decrypted drag's
  image). A page's drag used AppKit's drawing of the selection as its
  image, so the head and tail excerpt of each object passed over every
  app the drag crossed, while its public text names each object only by
  its size class ([ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 2). The image is now the ink as drawn and each object as its
  face without the excerpt, showing its classification, its size class
  and any name, with no `=` and no value. The plain drag row says so and the drag row's "contents never
  preview" now covers the image; both cite `SealedDragTests`. How the
  image looks over another app is a hand check in the sealed fragment
  procedure.
- 2026-10-14: Handle pointer amendment (issue 170, following
  [ADR-0051](../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md)
  points 1 and 4). The pointer shows an open hand over a decrypted drag
  handle while it is drawn and a press there would start the drag, and
  not while a field or the note holds the keys, where the press only
  says why. ADR-0051's consequence that "the pointer does not change
  over it" no longer holds, which
  [ADR-0055](../adr/0055-the-decrypted-drag-handle-shows-an-open-hand.md)
  records as superseding that half; VoiceOver still does not reach the
  handle, and *Copy decrypted contents* remains its path. The decrypted drag
  row cites `SealedDecryptedDragTests`, and its landing test now runs
  every step of the drop on a page and a note past a client that
  answers drop to seal, so a regression is counted instead of reading
  the system drag board. Whether AppKit shows the hand over the text
  view's own cursor is a hand check in the sealed fragment procedure.
- 2026-10-14: Every removal amendment (issue 170, applying D-30 and
  [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 4). Only ⌫ and ⌦ took the two presses, and only they and the
  object's menu said the removal line. ⌥⌫ beside an object took it in
  one press; ⌥⌦, ⌃⌫, ⌘⌫, ⌃K, their line and paragraph kin, Edit >
  Delete and ⌃Y ran while a field or the note held the keys; and
  typing, Return, a composition or a paste over a selected object
  detached it with no line. Every page deletion now shares the two
  presses: at a caret whose first character in its direction is an
  object it selects that object, and one whose reach runs past ink
  takes the objects it reaches in that press. Any edit that takes an
  object, made by AppKit or by the core's paste or place, is a step of
  its own and says the removal line with its Undo. deleteToMark, Edit >
  Delete and ⌃Y take no first press, since none deletes in a direction
  from the caret. The two backspace rows say so and cite
  `SealedRemovalTests`; the sealed fragment procedure's two presses
  check gains the other keys.
- 2026-10-14: Removal Undo amendment (issue 170, applying D-30 and
  [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 4). The removal line's Undo lived on the surface that made the
  removal. Once a teardown let that surface go, the button did nothing,
  and an edit to the page through another surface left an Undo that
  would step that edit back. The page model now stamps the removal with
  the count of edits it has sent the core for the page, from any
  surface. The first edit or step past the removal, or the page going,
  takes the Undo off the line. The button steps the page back through a
  surface showing it, or through the model when none does, and waits
  while a field or the note holds the keys (ADR-0046). A surface turning
  to another page still retires the Undo; a teardown does not. The
  backspace, selected row cites the new `SealedRemovalTests`, the
  sources name the model's routes, the owed list adds the button on
  another surface, and the sealed fragment procedure gains that check.
- 2026-10-14: Own copy amendment (issue 170, following
  [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 13, which keeps the private type's name out of the core). After
  a copy or a cut the board carries the fragment beside its public
  text. The core's probe sees only the text, so the summon offer stood,
  and ⇧⌘V or the offer's button sealed the placeholder text and cleared
  the board, losing the fragment. A board on which an item carries the
  private type is now the app's own and holds nothing to seal: the
  shell asks one predicate, `PageModel.boardHoldsOwnCopy`, before the
  offer and before the sealed paste, makes no offer, and refuses the
  paste with a line pointing at ⌘V, leaving the board and the page as
  they are. The copy and paste rows say so and cite the editor's test,
  and the sealed fragment procedure gains the check.
- 2026-10-14: Offer button amendment (issue 170 and epic 252, applying
  [ADR-0046](../adr/0046-the-keys-holder-answers-the-pages-chords-and-menu.md)'s
  predicate). The summon offer's seal button called the owner's route
  straight, so it sealed into the page while a field or the note held
  the keys, where the chord stands aside. It now waits there and says
  why, as the slot's place and the removal line's Undo do. The paste
  row cites the test, Law 0007's keys row lists the button, and the
  sealed fragment procedure gains the check.
- 2026-10-14: Print amendment (issue 170). The export, print, share
  row owed print once a path existed. None does: a probe of this app's
  scene shape listed no Print… or Page Setup… in the main menu or in
  the text view's default menu, and nothing else here sends `print:`,
  which would draw each object's face. The commands now replace the
  print group with nothing, so a later scene cannot bring SwiftUI's
  Print… back until a print that emits placeholders is designed. The
  row says so; the menu bar is a hand check in the sealed fragment
  procedure, since the test runner cannot build it.
- 2026-10-14: Record amendment (issue 170 and epic 252). Six rows
  named their hand check as if made: the paste inside, the drag inside,
  the ⌥ drag, the plain drag out, the decrypted drag and the export,
  print, share rows. None has been run, so every row now reads
  `owed: hand check` with its procedure. `decisions` adds ADR-0043,
  ADR-0050 and ADR-0051, which the name and note, decrypted drag and
  handle rows already build on.
- 2026-10-14: Sync move amendment (issue 170, recording what
  [ADR-0054](../adr/0054-a-drag-between-pages-moves-its-objects.md)'s
  move and a cut's reattach do against a peer). ADR-0021's context
  says "Sync must move a Page between a user's enrolled devices". In
  this build sync carries each enrolled page's document and nothing
  else: no envelope holds a sealed object (`DeltaEnvelope` in
  `crates/sync/src/envelope.rs`), and `SheetStore::apply_remote_update`
  refuses whole any batch that would stand a sentinel the receiving
  page does not own. A move between pages or a cut reattached on
  another page therefore reaches no peer: the destination's batch is
  refused, and the peer holds the object on no page, so never twice.
  Ink moved between pages reaches a peer in either order. The refusal
  costs the page its sync: every later batch of a page holding an
  object builds on the refused one, so that page stops reaching its
  peers, as client protocol 10.31 records. Whether objects travel
  between devices is a decision this law does not make; the drag and
  paste rows cite the tests a build that carries them must change.
- 2026-10-14: Sync deadline amendment (issue 170, applying
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)'s
  decision, "From a page's deadline, whether or not a sweep has taken
  it, the core gives none of it out."). ADR-0052's routes did not name
  sync. Its reads of a page now go through `readable_sheets`:
  `export_document_updates` exports nothing, `perform_ceremony`
  compacts nothing and returns no key frame, and `ceremony_due` owes no
  ceremony, for a page past its deadline. The sync sweep withdraws the unsealed ops of a page past
  its deadline or gone and never makes such a page a ceremony's target
  or a rotation's anchor, and a device holding one stays out of its
  ballot rather than join one it would refuse to commit. Its expiry
  policy still goes, so a peer's copy dies too. A batch or key frame
  sealed before the deadline still goes out on its retry: its read and
  seal happened while the page was readable, as with ADR-0052's
  conceal staged before the deadline, and the frame's PUT is what
  moves the relay's epoch. The expiry row says so and cites the tests.
- 2026-10-14: Object refusal amendment (issue 170, applying
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)
  point 4, "The shell settles after any refusal of these routes, as
  when its timer fires, which sweeps the page and drops it from the
  screen."). Copy decrypted, copy `NAME=value` and an object's conceal
  name no page, so their line said the page expired whenever the
  settle took any page. The line now asks the core whether the object
  still stands on a live page after the settle: `this page has
  expired.` only when it does not, else the route's own failure, which
  for both copies is `the sealed content could not be copied.` and for
  the conceal the draft's error. The expiry row cites the test.
- 2026-10-14: Note refusal amendment (issue 170, applying ADR-0052
  point 4). `CompanionClient.noteRuns` answers nil for the core's
  refusal and an empty list for an object with no note, so the shell
  tells them apart. Opening a refused note already opened nothing and
  settled; an open note restated after a refused batch stood empty
  instead. It now closes, giving the keys back to the page, and
  settles. The note's row cites both tests.
- 2026-10-14: Object character amendment (issue 170, applying this
  law's governing sentence, "A sealed item occupies one position in
  the document",
  and ADR-0047's context, "A page's body is a Loro document whose
  sentinels carry the chip's UUID as a mark (ADR-0013)."). AppKit's
  kill buffer and any board hold U+FFFC as a plain character, so ⌃K
  over an object then ⌃Y wrote a U+FFFC run into the page as ink: a
  position that looked like an object and was none. No U+FFFC now
  enters a page or a note as ink. The editor takes every U+FFFC that
  no object's attachment carries out of a character edit before it is
  sent, so the rest of the edit lands with the caret after it and ⌃T
  still moves an object; a page's recovery drops one a page from an
  earlier build shows. The core refuses a page's or a note's batch,
  and the page's recovery mirror, that would write one as ink, since
  those mirror an edit the editor already shows and a silent strip
  would leave the two apart; it takes the character out of a pasted
  envelope's ink and note and of the public text an unreadable one
  falls back to, which the editor restates. A file's text is its own
  and keeps it. Ink an earlier build already wrote into a page stays
  until it is edited away or the page's recovery runs. A new row
  records it and cites the tests.
- 2026-10-14: Several stretches drag amendment (issue 170, applying
  [ADR-0054](../adr/0054-a-drag-between-pages-moves-its-objects.md)
  point 5, "Any other drop pastes the drag's copy fragment and removes
  nothing."). One stretch of page ink dropped on another page moves
  through the core. Several stretches of page ink, which carry no
  object, start AppKit's own drag with no stamp of the page's, and a
  note's ink does the same; the
  destination answers `.copy`, as AppKit does between two text views,
  so the ink lands and its source keeps it. That one stretch moves and
  several copy is kept on purpose; a drag of several stretches holding
  an object does not start at all. The drag row says so and cites the
  test.
- 2026-10-14: Removal watch amendment (issue 170, applying D-30). The
  removal line follows an edit that took an object, judged against the
  objects in the ranges AppKit asked to change before it. An ask that no
  edit followed left its objects behind, and the next edit judged them:
  once the object went by the core's cut, typing said `protected
  content removed.` with an Undo that would take the typing back. An
  ask's objects now wait for its own edit to reach the storage, and the
  next ask drops them when it never does. The backspace, selected row
  cites the test.
- 2026-10-14: Removal Undo gates amendment (issue 170, applying D-30
  and following the removal Undo amendment). A teardown and then a
  mount of another page kept the Undo, so the button stepped the first
  page back out of sight. And with no surface known to show the page,
  the button stepped it through the model alone, past the editability
  gate `Coordinator.step` keeps, so a surface showing the page read
  only was rewritten. Any surface mounting a page other than the
  removal's now takes the Undo off the line, and the button finds the
  surface whose layout reads the page's storage and steps through it,
  through the model only when no surface shows the page. The
  backspace, selected row cites the two tests, and the sealed fragment
  procedure's check on another surface ends on another page.
- 2026-10-14: Every build's copy amendment (issue 170, following the
  own copy amendment and
  [ADR-0047](../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md)
  point 13). A debug build's private type ends in `.debug`, so a
  release build took a debug build's copy for another app's text: it
  offered to seal it, and ⇧⌘V sealed its placeholder text; a drop of
  one met drop to seal the same way. The check that a board holds the
  app's own copy, and the drop's, now know the type as every build
  names it. Reading an envelope stays with the build that wrote it, so
  ⌘V leaves another build's copy to AppKit's paste and its drop lands
  the public text as ink, standing aside while a field or the note
  holds the keys. The copy, paste and drag rows cite the tests.
- 2026-10-14: Drags from this app amendment (issue 170, widening the
  ink from this app's editors amendment and following ADR-0054 point 5
  and ADR-0047 point 10). That amendment kept drop to seal from drags
  whose source is a page or a note, so a field's text dragged onto a
  page still sealed. AppKit names a drag's source only to a
  destination in the same app, so a page now sends every drag that
  names one to its ordinary route and none to drop to seal. The
  sources here and where each lands on a page: the page's own text
  view, its drag or ink; another page's, the move between pages, the
  copy fragment or ink; the note's and a file's text view, ink; the
  window's shared field editor, which the gutter's, strip's, slot
  rail's and Settings' fields edit through, the name field's own
  editor, and the pad list's field editor in its popover, ink; the
  decrypted drag's handle, refused ([ADR-0050](../adr/0050-a-decrypted-drag-lands-only-in-another-app.md));
  any other view, ink where it carries text. The strip, the slot rail
  and the gutter's day and time move by gesture and start no drag. A
  read only page, a file and the note refuse all of it, and the drop
  waits while a field or the note other than its source holds the
  keys. The drag row cites the tests, and the sealed fragment
  procedure gains a check of a field's text dragged onto a page.
- 2026-10-14: Next event amendment (issue 170, applying
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)
  point 4, "The shell settles after any refusal of these routes, as
  when its timer fires, which sweeps the page and drops it from the
  screen."). A peer's hold register with no frozen life and a hold of
  up to a day left the page past its deadline, so every core read
  refused it, while the core's next event named the hold's lapse. The
  shell settles only when the next event is now, so the page stood on
  screen refusing everything for up to a day. Each page's next event
  now asks `Sheet::is_due`, the question point 1 gives the read gate,
  and answers now for a page past its deadline. A hold this device
  publishes rounded a frozen life under a millisecond down to none,
  which a peer read as past its deadline while the page stood held
  here; it now rounds up. The expiry row says so and cites the tests.
- 2026-10-14: Sync enrolment amendment (issue 170, following the sync
  deadline amendment and applying ADR-0052's decision, "From a page's
  deadline, whether or not a sweep has taken it, the core gives none of
  it out."). A page past its deadline still enrolled, and the next
  sweep sent the relay its expiry, though this device had sent the
  relay nothing of it before. It now does not enrol; a page enrolled before its deadline stays
  enrolled, so its expiry still reaches its peers. Ink typed before
  the deadline that no sweep took before a sleep past it reaches no
  publish, as the core's export gate already refused it; a test now
  holds that case. The expiry row says so and cites the tests.
- 2026-10-14: Unknown object amendment (issue 170, following the
  object refusal amendment and applying
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)
  point 4, "The shell settles after any refusal of these routes, as
  when its timer fires, which sweeps the page and drops it from the
  screen."). That amendment asked only after the settle whether a live
  page held the object, so an object no page held to begin with, as a
  stale menu's would be, read `this page has expired.` whenever another
  page's late timer was due. The shell now asks before the settle too,
  by the check the chip conceal already made to word its error, which
  reads past the deadline gate: `SheetStore::chip_stands`, over the seam
  `companion_chip_stands`. It says the page expired only when the
  object stood and then did not; an object unknown before the settle
  takes the route's own failure. The expiry row cites the tests.
- 2026-10-14: Finder and name amendment (issue 170, applying
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)'s
  eject trigger, "Any route hands a page's plaintext out after its
  deadline, swept or not."). Two ways out over text the shell shows did
  not ask first. Use Selection for Find refused only a selection
  holding an object; over ink, AppKit's finder wrote the selection to
  the find pasteboard, which every process reads. Copy name read the
  name from the drawn face and wrote it with no core route, and the
  name field's own editor copied, cut, dragged and served it the same
  way, while the `=` and value zones on the same row refused and
  settled. A name is part of its page, so both now ask the page first,
  as the note's AppKit routes do, and a page past its deadline refuses,
  settles and says so. There is no Use Selection for Replace to gate:
  AppKit's finder actions name none, and the Find menu SwiftUI builds
  here holds Use Selection for Find and Jump to Selection alone. The
  expiry row says so and cites the tests.
- 2026-10-14: Share and Writing Tools amendment (issue 170, applying
  the export, print, share row, "emits placeholders by default; a
  plaintext export is separately named declassification/egress", as
  the print amendment did, and
  [ADR-0052](../adr/0052-a-page-past-its-deadline-gives-nothing-out.md)'s
  eject trigger). AppKit builds the text menu's Share… with a picker
  that already holds the selection, before any gate is asked, so a
  menu held open across a deadline still shares the page. Writing
  Tools reads a selection past every gate and can rewrite across an
  object without the two presses D-30 asks for its removal. No share
  that emits placeholders exists, so a page's, a note's and a sealed
  name's text offer neither: their menus drop Share…, and their text
  views answer Writing Tools with none, which a field editor's setup
  hands back and the name field refuses again after it. A file's text
  keeps both. The row says so and cites the test, and the sealed
  fragment procedure gains the menus and Writing Tools on hardware.
