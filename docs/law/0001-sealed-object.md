---
id: 0001-sealed-object
title: The sealed object
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
governs: A sealed item occupies one position in the document, but its plaintext is not part of the document's ambient text.
decisions: D-08, D-09, D-10, D-27, D-28, D-29, D-30, D-31, D-32, D-33 (docs/spec/design/2026-0915-ui-ux-decisions.md, section 3)
consumed-by:
  - docs/spec/design/2026-0915-ui-ux-decisions.md (section 3 applies this law to the surface)
  - docs/spec/feature/sealed-content/sealed-content.md (the design note upstream of this law)
  - docs/adr/0009-chip-deletion-deliberate-final.md (proposed, never accepted; its finality clause yields to the removal rows below)
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md (the egress discipline this law widens to three points)
sources:
  - the maintainer's sealed object model, 2026-09-15
  - docs/spec/design/2026-0915-ui-ux-decisions.md, section 3
  - docs/spec/design/04-interaction-model.md
  - crates/core/src/sheet.rs (one clock per sheet, no per chip timers)
  - crates/core/src/store.rs (seal, copy out, delete, sync)
  - crates/ffi/src/lib.rs (CLIPBOARD_CLEAR_SECONDS)
  - shell/Sources/CompanionKit/InkEditorView.swift (ChipCell, the chip menu, the seal commands)
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
2. **Explicit declassification**: protected plaintext crosses its boundary
   only through an action that clearly names that consequence, and the
   write is always core side, so the Swift shell never holds plaintext
   (ADR-0012).

The rule serves the first tenet (losing work is unforgivable, even here) by
making every structural edit reversible, and the boundary law (ADR-0002,
ADR-0021) by making every reveal a named act. A sealed object shows one
plaintext only: the mechanical excerpt, head…tail of at most 24 plaintext
characters, computed by the core (`text_face` in `crates/core/src/sheet.rs`),
which only has to be recognised by the person who pasted it (D-27). There
is no reveal affordance at any privilege, so no label may imply one (D-08).

## Operation classes

Every operation on a sealed item is one of two kinds, and the distinction is
the whole design.

- **Structural**: move, select, cut, paste within the app, duplicate,
  delete, expire. They act on the object, never on its payload, and they
  are undoable. Removal is structural: a removed object is detached, not
  destroyed, and undo reattaches it (D-30). Expiry is the one structural
  operation that is not undoable, because nothing remains to restore
  (D-33).
- **Declassification**: copy decrypted contents, decrypted drag from the
  handle, promote to a one time link, plaintext export. Plaintext crosses
  the boundary, the action names it, and the write is core side (D-29,
  D-32).

A third word, **ambient**, marks the page's ordinary text machinery reading
the document without reading the object: the caret, find, the plain text
representation on the pasteboard. Ambient operations treat the object as
one opaque unit.

One exemption from reversibility: **sealing is one way** in the editor
(D-30). An Undo that restored the plaintext would be the one reveal path
that names nothing, and it would keep the plaintext alive in the shell's
undo stack. ⌘Z after sealing is not offered; the content comes back only
through *Copy decrypted contents*.

## Creating one after the fact

With plaintext selected: **Seal Selection** in the context menu, **Edit →
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
| arrow keys | ambient | the caret crosses the object as one indivisible unit | held by AppKit, a chip is one attachment character; no direct test, owed: no issue yet |
| click | structural | selects the whole object; never places a caret inside it | `DocumentOpsTests.swift` `testAClickOnAChipSelectsItWhole` |
| shift selection | structural | includes the whole object or none of it | held by AppKit; no direct test, owed: no issue yet |
| select all | structural | includes the object structurally, not its plaintext | `store.rs` `sheet_payload_inlines_chips_in_document_order` (the page's own payload carries the chip by reference); the shell side has no direct test, owed: no issue yet |
| copy, object or whole page | structural | writes the private type carrying the chip's UUID plus the plain text placeholder; no payload, no ciphertext | owed: issue 170 (`DocumentOpsTests` for the types `writeSelection` writes) |
| cut | structural | writes the same reference, then detaches the chip from the page; a detached chip shows in the app's own clipboard slot, on the page's clock, never an invisible limbo | owed: issue 170 (`store.rs` `a_cut_chip_is_detached_not_reaped`) |
| paste, inside OnetimePad | structural | the core reattaches the chip by id at the new position; a paste after copy, or a second paste of a cut, is a core side clone with a new id and the same payload | owed: issue 170 (`store.rs` `a_pasted_reference_reattaches_by_id`) |
| paste, another app | ambient | the destination gets `[sealed content · small]`, a size class, never a count, never plaintext | owed: issue 170; the size class itself is `store.rs` `a_multi_line_chip_reports_a_size_class_not_lines` |
| drag, inside the document | structural | moves the object atomically with a clear insertion line; contents never preview | owed: issue 170 (the `NSDraggingSource`) and issue 169 (the move handle) |
| ⌥ drag | structural | a core side clone, following the macOS copy drag convention; no pasteboard involvement | owed: issue 170 |
| plain drag, outside | ambient | exposes only the placeholder | owed: issue 170 |
| decrypted drag, from the handle | declassify | a distinct, labelled handle on the block; plaintext is supplied lazily through `NSPasteboardItemDataProvider`, so the core writes it, and the ledger `sent` record with destination `Drag`, only when a destination asks; a successful drop never deletes the chip | owed: issue 170 (ffi seam tests for the lazy write and its ledger record) |
| backspace beside it | structural | the first press selects the object, the second removes it | owed: no issue yet; the build removes on the first press (`DocumentOpsTests.swift` `testAnUndoResurrectingADeadChipIsStrippedSilently` pins that and is rewritten with this row) |
| backspace, selected | structural | removes it immediately, with Undo available; undo reattaches from the detached store | removal as one unit: `DocumentOpsTests.swift` `testDeletingAChipAttachmentEmitsOneDelete`; undo: owed, issue 170 |
| find, word count | ambient | do not inspect the plaintext; optionally count one protected object | find: `WrapTests.swift` `testUseSelectionForFindRefusesAChip`; no word count exists in the build |
| expiry | structural | a page's expiry takes its sealed objects with it, detached ones included; a detached object lives on its page's clock and there is no per chip timer; a reference pasted afterwards resolves to an *expired* placeholder, visibly distinct from a removed one, not undoable; all of it holds at rest under the boot bound key | page clock: `FocusLawTests.swift` `testAChipWhosePageExpiredClearsTheDraftEvenWhileOthersRemain`; the expired placeholder: owed, issue 170 (`store.rs` `a_reference_to_a_gone_chip_yields_a_removed_placeholder`, which must tell expired from removed) |
| export, print, share | ambient | emit the placeholder by default; a decrypting export is a separately named action | no export, print or share path exists in the build; owed when one does |
| promote the whole page | declassify | includes sealed payloads; the inline confirmation says so (`includes 2 sealed items`); the local copy is offered up to burn, never burned automatically | `ConcealWireTests.swift` `testTheSealedItemsLineCountsInTheSingularAndThePlural`, `testTheSealedItemCountIsReadOffThePagesRoster`; `store.rs` `a_conceal_marks_the_chip_and_keeps_only_the_receipt` |
| seal a selection | structural, one way | replaces the selection in place, keeps whitespace, selects the new object | `DocumentOpsTests.swift` `testSealSelectionReplacesTheSelectionCoreSide`, `testSealingSelectsTheNewObject`; `store.rs` `a_range_seal_replaces_the_selection_atomically`, `a_range_seal_across_a_newline_merges_blocks_like_typing_over_it` |
| seal over a sealed object | refused | sealed objects do not nest; ⇧⌘V over a chip refuses with `already sealed · a chip has no plaintext to seal` | `DocumentOpsTests.swift` `testSealedPasteOverAChipIsRefused`, `testTheContextMenuOffersSealSelectionOverInkOnly`; `store.rs` `a_range_seal_over_a_selected_chip_is_refused` |
| undo after a seal | refused | ⌘Z does not restore the plaintext | `UndoRerouteTests.swift` `testASealCannotBeSteppedBack`; `store.rs` `a_seal_cannot_be_stepped_back` |
| copy decrypted contents | declassify | offered by name in the object's menu; does not consume the chip; the line reads `decrypted contents copied · clipboard clears in 60 seconds` and the core arms the clear | `DocumentOpsTests.swift` `testTheChipMenuOffersPlaintextByName`; `store.rs` `copy_out_does_not_consume_the_chip`; `PasteboardOfferTests.swift` `testACopyOutArmsTheClearAndFlashesTheInterval`, `testTheBoardStillHoldsTheCopyInsideTheWindow`; `crates/ffi/src/lib.rs` `the_clear_interval_is_the_core_constant` |
| the ledger | ambient | a sealed chip is content free in the ledger from the moment it exists | `store.rs` `a_sealed_chip_is_content_free_in_the_ledger_from_the_moment_it_exists`, `a_seal_carrying_an_origin_leaves_no_trace_in_the_ledger` |
| the block | structural | full measure, 8 px radius, hairline border, padded 8 by 12; the tracked `SEALED CONTENT` label, the mechanical excerpt, the size class as metadata; nothing pressable; handles appear on hover or selection and keep their seat | excerpt: `store.rs` `sealed_chips_carry_the_mechanical_face`; geometry and handles: owed, issue 169 (`SealedBlockTests`) |

Fixed details the rows rely on:

- The private pasteboard type is `com.onetimesecret.onetimepad.sealed-ref`,
  with the `.debug` suffix on dev builds so dev and prod cannot resolve
  each other's references. It carries the chip's UUID and nothing else
  (D-31). The core already identifies chips by UUID and the ledger records
  the same random id in plain, so the exposure is the ledger's, stated the
  same way. Never the payload, never ciphertext.
- The plain text placeholder is `[sealed content · <size class>]`, a size
  class from `SizeClass` (`crates/core/src/ledger.rs`), never a count.
- Three egress points, all core side writes: copy decrypted, decrypted drag,
  promotion (D-32). A decrypted drag never enters clipboard history or
  Universal Clipboard, so it is the recommended path into a form field;
  copy decrypted on the general pasteboard is the riskier fallback.
- The clear after copy is one core constant, 60 seconds
  (`CLIPBOARD_CLEAR_SECONDS`, `crates/ffi/src/lib.rs`), read through the
  seam `companion_clipboard_clear_seconds`; the confirmation states that
  number and never promises a clear the app does not perform (D-29).
- Time belongs to the page. A detached object takes its page's clock; there
  is no per chip TTL (`sheet.rs` forbids per chip timers; maintainer
  decision 2026-08-07; D-33).
- The object's menu, in the copy register of D-15:

  ```text
  Copy decrypted contents
  Create one-time link…
  ────────────────────────
  Remove protected content
  ```

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
- **Reversibility**: can structural edits be undone? Sealing is the one
  exemption.
- **Safe fallback**: when a destination cannot understand the object, does
  it receive a placeholder rather than plaintext or nothing?

The crucial question is which class the interaction belongs to. Moving,
selecting, duplicating and deleting operate on the sealed object. Revealing,
copying decrypted contents and exporting plaintext cross the security
boundary and must always be explicit.

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
`sync_rejects_foreign_and_duplicate_chips`.

Seam (`crates/ffi/src/lib.rs`): `the_clear_interval_is_the_core_constant`.

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
`FocusLawTests` (the chip draft on an expiring page),
`PageModelPreviewRenderingTests.testChipAttachmentSurvivesEveryScope`.

Tests that pin the contradicting build and are rewritten when issue 170
lands (removal detaches, undo reattaches): `store.rs`
`a_sync_that_omits_a_chip_zeroizes_it`,
`deleting_a_sentinel_by_op_zeroizes_the_chip`,
`an_empty_snapshot_is_select_all_delete_and_zeroizes_every_chip`,
`a_select_all_delete_batch_zeroizes_every_chip`,
`a_deleted_chip_leaves_no_step_that_would_stand_it_again`,
`burning_a_chip_takes_the_stack_with_it`; `DocumentOpsTests`
`testAnUndoResurrectingADeadChipIsStrippedSilently`.

Owed: issue 169 (`SealedBlockTests`), issue 170 (the pasteboard model, the
detached store, the lazy decrypted drag and their tests as named in the
rows), issue 172 (the four interrupting dialogs; none is on a sealed path,
but D-14 is strict and the seal, remove and copy decrypted paths must stay
dialog free).

## Amendments

- 2026-09-15: Accepted. Built from the maintainer's sealed object model and
  section 3 of the 2026-0915 record. Where the two differed the maintainer
  settled it the same day: removal is structural and undoable (ADR-0009's
  finality clause, proposed and never accepted, yields); the private type
  carries the UUID, not a ticket; there is no per chip TTL; the clear after
  copy is 60 seconds as one core constant.
