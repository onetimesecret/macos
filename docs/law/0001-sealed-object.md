---
id: 0001-sealed-object
title: The sealed object
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
governs: A sealed item occupies one position in the document, but its plaintext is not part of the document's ambient text.
decisions: D-08, D-09, D-10, D-14, D-15, D-27, D-28, D-29, D-30, D-31, D-32, D-33 (docs/spec/design/2026-0915-ui-ux-decisions.md, sections 3 and 5); D-40 and D-41 (docs/spec/design/2026-0915-stream-navigator.md, incorporated by docs/spec/design/2026-0916-clipboard-clear-interval.md); ADR-0042 points 1 to 4, 7 and 8
consumed-by:
  - docs/spec/design/2026-0915-ui-ux-decisions.md (section 3 applies this law to the surface)
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the name's charset, the bottom row's zones, the note popover on a narrow card)
  - docs/adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md (where the name and note live, persist and cross the FFI)
sources:
  - docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md (the points the name and note amendment left open)
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
  - shell/Sources/CompanionKit/InkEditorView.swift (SealedBlockCell, the named row and its zones, the doorway, the chip menu, the seal commands)
  - shell/Sources/CompanionKit/SealedBlockLayout.swift (the named row's zones, pill and allotment)
  - shell/Sources/CompanionKit/SealedNameField.swift (the name's field)
  - shell/Sources/CompanionKit/SealedNotePopover.swift (`NotePopoverLayout.minimumWidth`, the note's popover and writing surface)
  - shell/Sources/CompanionKit/PageModel.swift (`copyChipName`, `copyChipNameValue`, `setChipName`, the note's routes)
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
| arrow keys | ambient observation | the caret crosses the object as one indivisible unit | held by AppKit, a chip is one attachment character; no direct test, owed: no issue yet |
| click, on an unnamed object or outside a named object's bottom row | structural editing | selects the whole object; never places a caret inside it | `DocumentOpsTests.swift` `testAClickOnAChipSelectsItWhole`; off a zone or with a modifier the click takes that path: `SealedCapsuleTests.swift` `testAZoneActsOnTheFirstClickAndAClickOffItSelects` |
| shift selection | structural editing | includes the whole object or none of it | held by AppKit; no direct test, owed: no issue yet |
| select all | structural editing | includes each object structurally, not its payload | no direct test; owed: issue 170 |
| copy, object or mixed selection | structural editing | writes one versioned sealed fragment preserving ordered ink runs and UUID references; the public representation preserves the ink and substitutes one size-class placeholder per reference; neither representation contains payload or ciphertext | owed: issue 170 (`DocumentOpsTests` for ordered mixed and multi-chip selections) |
| cut | structural editing | writes the same fragment, then detaches every referenced object in one core transaction; all selected objects appear together in the app's clipboard slot and retain the page's clock | owed: issue 170 (`store.rs` atomic multi-chip detach coverage) |
| paste, inside OnetimePad | structural editing | inserts the whole fragment as one undoable transaction; the first paste of a cut reattaches all cut objects, while a paste after copy or a later paste of a cut clones every live reference core-side; terminal or unknown references become cause-specific placeholders in their original positions | owed: issue 170 (`store.rs` fragment reattach, clone, rollback and mixed-state coverage) |
| paste, another app | ambient observation | receives ordered ink with `[sealed content · <size class>]` substituted for each live reference; never receives a payload | owed: issue 170; size class: `store.rs` `a_multi_line_chip_reports_a_size_class_not_lines` |
| drag, inside the document | structural editing | moves the selected objects and ink atomically with a clear insertion line; contents never preview | owed: issue 170 and issue 169 |
| ⌥ drag | structural editing | clones all selected sealed objects core-side as one operation, following the macOS copy-drag convention | owed: issue 170 |
| plain drag, outside | ambient observation | exposes only ordered ink and placeholders | owed: issue 170 |
| decrypted drag, from the handle | declassification/egress | a distinct, labelled handle; the core supplies the complete payload lazily when a destination asks and records destination `Drag`; a successful drop never deletes the object | owed: issue 170 |
| backspace beside it | structural editing | the first press selects the object, the second removes it from the page | owed: no issue yet; the contradicting build test is rewritten under issue 170 |
| backspace, selected | structural editing | detaches it immediately, with Undo available; undo reattaches from the detached store | removal as one unit: `DocumentOpsTests.swift` `testDeletingAChipAttachmentEmitsOneDelete`; undo: owed, issue 170 |
| find, word count | ambient observation | does not inspect the payload; may count one protected object | `WrapTests.swift` `testUseSelectionForFindRefusesAChip`; no word count exists |
| expiry | destruction/lifecycle | destroys all of the page's attached and detached payloads; while terminal-cause evidence remains, later references produce an expired placeholder and cannot be undone | no direct lifecycle test; owed: issue 170 |
| explicit burn | destruction/lifecycle | destroys the named local payloads atomically; while terminal-cause evidence remains, later references produce a burned placeholder | owed: issue 170 |
| export, print, share | ambient observation | emits placeholders by default; a plaintext export is separately named declassification/egress | owed when a path exists |
| promote the whole page | declassification/egress | includes sealed payloads; the confirmation says so; the local copy is offered up to burn and is never burned automatically | payload inclusion: `store.rs` `sheet_payload_inlines_chips_in_document_order`; confirmation count: `ConcealWireTests.swift`; receipt marker and retained local payload: `store.rs` `a_conceal_marks_the_chip_and_keeps_only_the_receipt` |
| seal a selection | classification | replaces visible ink in place, keeps whitespace and selects the new object; the result is one-way in the editor | shell and core range-seal tests listed below |
| seal over a sealed object | classification | refused: sealed objects do not nest | `DocumentOpsTests.swift` and `store.rs` refusal tests listed below |
| undo after a seal | classification | refused: ⌘Z does not restore the pre-seal ink | `UndoRerouteTests.swift` `testASealCannotBeSteppedBack`; `store.rs` `a_seal_cannot_be_stepped_back` |
| copy decrypted contents | declassification/egress | offered by name and does not consume the object; the core writes the payload, the shell arms a timer from the core-owned 60-second interval, and the core later clears only if the pasteboard still holds that write | copy-out and shell timer tests listed below; guarded clear: `crates/pasteboard/src/lib.rs` and `crates/pasteboard/src/macos.rs` `clear_after_copy_only_clears_our_own_write`, both of which refuse to erase a newer write |
| name the object (*Name…*, *Rename…*, a double click on an unnamed object's bottom row or a named object's name zone) | structural editing | an inline field in the name's seat per [Law 0007](0007-edit-in-place.md); the name is page-owned text stored with the object core-side, carried in the fragment, never in the ledger; it is 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`, case kept, and the core refuses any other ([ADR-0042](../adr/0042-sealed-names-copy-zones-and-rename-seats.md)); a named object's bottom row reads `NAME=excerpt` | the core's name, its rule and its refusal: `store.rs` `a_name_outside_the_charset_is_refused_and_an_empty_one_clears`, `a_name_survives_a_snapshot_round_trip`, `after_the_page_expires_the_snapshot_holds_no_name`; `lib.rs` `chip_json_carries_the_name`, `the_name_routes_judge_by_one_rule_and_fail_closed` ([ADR-0043](../adr/0043-a-sealed-objects-name-and-note-live-on-its-chip.md)); the field and the redrawn row: `SealedNameFieldTests.swift` `testTheFieldOpensInTheSeatOnTheNameWithTheExcerptToItsRight`, `testReturnNamesTheObjectAndRedrawsItsBlock`, `testARefusalKeepsTheFieldAndTheLine`, with the rest of the field's rows in Law 0007; owed: issue 247 (the fragment) |
| pointer over an unnamed object's bottom row | structural editing | no zones until the object is named: no pill, no seat words, and a click selects as anywhere on the block (D-40) | `SealedBlockTests.swift` `testTheDrawnRowAtAWideAndANarrowMeasure`; `SealedCapsuleTests.swift` `testHoverFindsTheZoneUnderThePointer` |
| click the name zone, the name's glyph run | ambient observation | the first click copies the name; the second of a double click opens the name field; the size class's seat reads `copies the name` while hovered | the zone and its seat: `SealedBlockTests.swift` `testTheZonesAreTheRunsAndTheEqualsTakesTwoPointsEachSide`, `testEachZoneSaysWhatItsClickDoesInTheSeat`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`; the double click: the same press test, and `SealedNameFieldTests.swift` `testADoubleClickOpensTheFieldOnlyWhereTheRuleSays` |
| click the value zone, the value's glyph run | declassification/egress | a handle in D-29's sense: copies the decrypted contents by the copy decrypted route above on the first click and ignores the clicks after it; the seat reads `copies the value, decrypted` before the click | `SealedBlockTests.swift` `testEachZoneSaysWhatItsClickDoesInTheSeat`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAPressOnAZoneCopiesOnceLightsTheBeatAndLeavesTheSelection`, `testAZoneActsOnTheFirstClickAndAClickOffItSelects`, `testAZoneActsOnlyOnceTheSeatHasNamedIt` |
| click the `=` zone, the glyph and 2 points either side | declassification/egress | copies `NAME=<plaintext>`, the value raw and unquoted, by the same route on the first click and ignores the clicks after it; the seat reads `copies name=value, decrypted` before the click | the core's write: `store.rs` `name_value_is_composed_raw_at_its_exact_size`, `name_value_refuses_an_unnamed_an_image_and_an_unknown_chip`; `lib.rs` `copy_name_value_writes_the_pasteboard_in_core_marked_nspasteboard_concealed`, `copy_name_value_refuses_unnamed_image_and_unknown_chips_and_writes_nothing`, `a_name_value_copy_and_a_copy_out_retire_each_others_receipts`, `a_name_value_copy_records_one_sent_and_no_name`; the zone: `SealedBlockTests.swift` `testTheZonesAreTheRunsAndTheEqualsTakesTwoPointsEachSide`; `SealedCapsuleTests.swift` `testEachZoneCallsItsOwnModelRoute`, `testAZoneActsOnTheFirstClickAndAClickOffItSelects`, `testAZoneActsOnlyOnceTheSeatHasNamedIt` |
| the note (*Note…*, *Edit note…*, a click on `note`) | structural editing | the page's own writing surface in a popover at the block's measure, or the card's full content width when the block's measure is narrower than the popover's minimum, expanded to the card by its diagonal arrows or ⇧Esc and contracted the same way; ink stored with the object core-side, carried in the fragment, never in the ledger, on the page's clock | the core's note: `store.rs` `a_note_survives_a_snapshot_round_trip`, `after_the_page_expires_the_snapshot_holds_no_note`, `undo_inside_the_note_is_separate_from_the_pages_undo`, `note_edits_leave_the_ledger_unchanged`, `a_note_takes_no_chip_and_a_refused_first_batch_makes_no_note`; `lib.rs` `note_routes_edit_the_note_and_leave_the_page_alone`, `the_note_and_the_page_keep_separate_undo_stacks_across_the_seam`; the popover: `SealedNoteTests.swift` `testThePopoverHangsUnderTheBlockAtTheBlocksMeasure`, `testANarrowBlockPutsTheNoteAcrossTheContentWidth`, `testExpandedTheNoteCoversTheContentAndWithoutRoomBelowItStandsAbove`, `testTheMenusVerbOpensTheNoteInThePagesOwnWindow`, `testTheDoorwayOpensTheNoteAndEscClosesIt`, `testTheArrowsAndShiftEscExpandAndContractAndEscContracts`, `testTheNoteClosesWhenItsSeatGoes`, `testTheObjectLeavingThePageClosesItsNote`, `testANoteEditLeavesThePagesCaretAndUndoAlone`, `testNoNoteRouteRunsAModalSession`; on the raised card and under a real pointer, owed: hand check, [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md); owed: issue 247 (the fragment) |

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
  note…* (ADR-0042). The chord is the keymap's (`chip::CopyDecrypted`)
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
`snapshot_size_is_exact` over a named chip with a note.

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
`a_name_and_a_note_reach_no_ledger_record_and_no_other_output`.

Shell (`shell/Tests/CompanionKitTests`, `scripts/test-shell.sh`):
`DocumentOpsTests` (`testAClickOnAChipSelectsItWhole`,
`testDeletingAChipAttachmentEmitsOneDelete`,
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
in place), `SealedNameFieldTests` (the name's field, per Law 0007),
`ModalSessionTests.testRenameNeverRunsAModalSession` (naming stays
dialog free), `SealedNoteTests` (the doorway, the popover's placement,
its open, expand, contract and close routes, and its edits on the
note's own routes), `BundledKeymapTests` (`shift-escape`),
`SealedObjectSeamTests` (the name, `name=value` and note wrappers over
the live core).

By hand: the [sealed zones and note](../qa/verification-procedures/sealed-zones-and-note.md)
procedure, for the zones under a real pointer, the beat on a display
and the note on the raised card. It has not been run.

Tests that pin the contradicting build and are rewritten when issue 170
lands (removal detaches, undo reattaches): `store.rs`
`a_sync_that_omits_a_chip_zeroizes_it`,
`deleting_a_sentinel_by_op_zeroizes_the_chip`,
`an_empty_snapshot_is_select_all_delete_and_zeroizes_every_chip`,
`a_select_all_delete_batch_zeroizes_every_chip`,
`a_deleted_chip_leaves_no_step_that_would_stand_it_again`,
`burning_a_chip_takes_the_stack_with_it`; `DocumentOpsTests`
`testAnUndoResurrectingADeadChipIsStrippedSilently`.

Owed: issue 170 (the versioned sealed-fragment model, atomic multi-object
detach/reattach/clone, lifecycle resolution, the lazy decrypted drag and
their tests as named in the rows); issue 247 (the name and note in the
fragment, as named in the rows); a first run of the sealed zones and
note procedure. Issues 169 (`SealedBlockTests`) and 172 (the
interrupting dialogs) are closed; D-14 is strict and the seal, remove,
copy decrypted, naming and note paths must stay dialog free.

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
