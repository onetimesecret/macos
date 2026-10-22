---
# docs/development/sealed-objects-core-interface.md
---

# Sealed objects: the core interface

A map for whoever next touches a sealed object's name, note, fragment,
detached store or decrypted drag in code: the C entry points, the JSON
they answer, the bytes at rest, the type name and the shell's predicates
and constants. The behaviour is [Law 0001](../law/0001-sealed-object.md)'s
and, for the name's field, [Law 0007](../law/0007-edit-in-place.md)'s. The
decisions were accepted 2026-10-16:
[ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md),
[ADR-0043](../adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md),
[ADR-0044](../adr/0044-a-sealed-objects-note-is-edited-on-the-pages-own-surface.md),
[ADR-0045](../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md),
[ADR-0046](../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md)
and
[ADR-0047](../adr/0047-name-value-copies-the-value-unquoted.md).
The looks and words are in the
[sealed row, note and handles](../spec/feature/sealed-content/sealed-row-note-and-handles.md)
spec.

These notes were first written into the drafts ADR-0043 to ADR-0054 of
2026-10-13, withdrawn on 2026-10-14 without ratification.
Where this file and the code disagree, the code is right and this file
is fixed.

## The pieces, and where they live

```
crates/core/src/sheet.rs      SealedChip (name, note), judge_name, NAME_CAP,
                              Sheet::is_due
crates/core/src/note.rs       the note's own document and undo
crates/core/src/store.rs      set_chip_name, copy_out_name_value, the note's
                              routes, readable_sheets, chip_stands
crates/core/src/fragment.rs   the envelope and the public text, VERSION,
                              ENVELOPE_CAP, REFERENCE_CAP, EnvelopeCap
crates/core/src/transfer.rs   cut, paste, the slot, the drags, resolution,
                              the transaction
crates/core/src/persist.rs    the chip record's and page record's trailing
                              fields, the ledger's destination tags
crates/ffi/src/lib.rs         the C entry points below, chip_face,
                              placed_json
crates/pasteboard/src/macos.rs  SystemDragItem, the decrypted drag's write

shell/Sources/CompanionKit/CompanionClient.swift  the wrappers, the type name
shell/Sources/CompanionKit/PageModel.swift        InkDocument, the routes by
                                                  document, boardHoldsOwnCopy
shell/Sources/CompanionKit/InkEditorView.swift    makeSurface, answersChords,
                                                  CodeLanguageChoice,
                                                  SealedBlockCell
shell/Sources/CompanionKit/SealedBlockLayout.swift  the row's zones and the
                                                  handle's clearances
shell/Sources/CompanionKit/SealedNotePopover.swift  NotePopoverLayout
shell/Sources/CompanionKit/DecryptedDrag.swift    the drag's source and its
                                                  data provider
```

## The name

`judge_name` (`sheet.rs`) is the one rule. It trims a draft. An empty
draft clears the name; any other must be at most `NAME_CAP` (64)
characters of `[A-Za-z_][A-Za-z0-9_]*`, the charset checked first, or it
is refused whole and the name stands.

| Entry point | Answer |
| --- | --- |
| `companion_chip_name_refusal(draft) -> u32` | judges a draft without a handle: 0 takes it, an empty draft clearing; 1 is longer than 64 characters; 2 is outside the charset; null and non-UTF-8 answer 2 |
| `companion_chip_set_name(handle, chip, name) -> bool` | false for an unknown chip or a refused draft, the name then unchanged |

The shell owns the words for each code, so a field can say why a draft
will not take while it is typed. It marks the page dirty after a name is
set or a note edited, as after any mutation
(`SealedNameFieldTests.testANameOrANoteEditArmsAWriteAndARefusalArmsNone`).

## The note's routes

The note is the document type a page's body and an open file use, holding
ink alone. Since 2026-10-21 (issue #256) a note made by a restore, a paste
or a clone is its text alone until it accepts a batch that changes that
text, which makes that document (At rest, below). Its routes are keyed by
chip id, as a file has its own:

- `companion_chip_note_runs_json`: `[]` without a note, else
  `[{"ink": text}]`; null for an unknown chip or a page past its deadline.
- `companion_chip_note_apply_ops_with_intent`,
  `companion_chip_note_finish_editing_group`.
- `companion_chip_note_can_undo`, `companion_chip_note_can_redo`,
  `companion_chip_note_undo_action_name`,
  `companion_chip_note_redo_action_name`.
- `companion_chip_note_undo`, `companion_chip_note_redo`, which answer the
  file routes' `StepOutcome`.

Page routes take no chip id and note routes no page id. A chip id is a
counter that overlaps page ids, so a note's edit sent on a page route
would write some page's ink. The shell's `InkDocument` is `.sheet(id)` for
a page or a file and `.note(chip:)` for a note, and `PageModel` answers a
note on the note's routes and never on a page's.

A note exists from its first accepted edit, or from a restore, a paste or
a clone that brings its text (issue #256 since 2026-10-21: such a note
rests as its text until an edit). `has_note` is true while it has a
character that is not whitespace
(`store.rs` `a_note_of_only_whitespace_opens_no_doorway`).

## What the shell receives

The chip face (`chip_face` in `lib.rs`), which the seal routes and
`companion_sheet_document_json` both send, carries `chip_id`, `kind`
(`text` or `image`), `excerpt`, `size_label`, `concealed`, `name` (a
string or null) and `has_note`. Swift reads them as `ChipInfo`.

The note's text crosses only through `companion_chip_note_runs_json`. No
summary, meta, blocks or ledger output carries the name or the note, and
neither conceal payload, one chip's or a whole page's, includes them
(`lib.rs` `a_name_and_a_note_reach_no_ledger_record_and_no_other_output`,
`store.rs` `a_name_and_a_note_are_never_payload`).

## `NAME=value`

`companion_chip_copy_name_value(handle, chip) -> bool`. The store
composes the name, `=` and the payload in one zeroizing buffer allocated
at its final size (draft [Law 0004](../law/0004-secret-plaintext-never-reallocates.md)),
and refuses an unnamed chip, an image chip, an unknown chip and a page
past its deadline. It shares copy decrypted's steps with
`companion_chip_copy_out`: retire the last receipt, write transient and
concealed, keep the receipt for the guarded clear, and record one `sent`
to the clipboard at the payload's size class. The composed bytes never
cross the FFI. The shell's `SealedBlockLayout.copiesNameValue(kind:)`
says which kinds the core composes for, and the `=` zone and the menu
item follow it.

## The fragment

### Envelope, version 1

UTF-8 JSON, composed and parsed only in `fragment.rs`:

```json
{"version":1,"cut":"<uuid>","nodes":[{"ink":"text"},{"ref":{"uuid":"<uuid>","name":"API_KEY","note":"text"}}]}
```

- `cut` appears only on a cut's fragment and names that cut.
- `name` and `note` appear only when the object has them.
- Nodes keep the selection's order.
- Another version, an unknown key, a malformed UUID or bytes that are not
  UTF-8 make the envelope unreadable.
- It is encoded twice, sized then written, into a buffer of its final
  size.

The caps: `ENVELOPE_CAP` is twice `FILE_SIZE_LIMIT` (`files.rs`, 4 MiB),
8 MiB or 8388608 bytes, which leaves room for JSON's escapes over a page
that large; `REFERENCE_CAP` is 1024. `EnvelopeCap::passed` is the one
check. The parse checks the length before it reads the bytes, and the
references and a repeated object as it reads the nodes, before anything
resolves. Copy and cut measure the envelope they would write with the
same check, the length from the sizing pass's count before the buffer
exists, a cut's with its `cut` field.

### Entry points

| Entry point | What it does | Answer |
| --- | --- | --- |
| `companion_sheet_copy_fragment(handle, sheet, at_utf16, len_utf16)` | copies a UTF-16 range | `{"envelope": string or null, "plain": string}`; past a cap `{"error": "tooLarge", "limit": 8388608}` or `{"error": "tooManyObjects", "limit": 1024}`; null for a file id, an unknown page, a page past its deadline or a bad range |
| `companion_sheet_cut_fragment` | as the copy, then deletes the range as one undo step, its objects detaching as the active cut | as the copy; a refusal changes nothing |
| `companion_sheet_compose_fragment(handle, sheet, shown)` | composes runs the shell shows of a page, a preview's rendered text between its objects and each object by chip id, in the synced document's JSON shape (`[{"ink": "…"}, {"chip": 7}, …]`); the shown text is the ink | as the copy; null also for an object off the page or `shown` that does not parse |
| `companion_sheet_paste_fragment(handle, sheet, at_utf16, len_utf16, envelope, envelope_len, plain)` | pastes envelope bytes over a range as one undo step, `plain` placed for an envelope the core cannot read | the placed JSON, or null on refusal |
| `companion_sheet_paste_active_cut` | the clipboard slot's place over a range | the placed JSON; null when no cut stands, or as the paste |
| `companion_sheet_move_range` | a drag inside a page, as one step | the placed JSON, or null for a target inside or at the range's edge, or a page past its deadline |
| `companion_sheet_move_range_to` | a drag between pages, as one transaction keeping every object; sweeps nothing | the placed JSON for its run on the destination, or null with neither page changed: for one page at both ends, an unknown page or a file at either end, a range or point outside its body, or a page past its deadline at either end |
| `companion_sheet_clone_range` | the ⌥ drag inside a page, every object cloned, as one step | the placed JSON, or null |
| `companion_active_cut_json` | the clipboard slot | `{"page_id": u64 or null, "objects": [face]}`, null and `[]` with no cut |
| `companion_chip_provide_drag` | the decrypted drag's write into its item | false, writing and recording nothing, on refusal |
| `companion_chip_delete` | the explicit burn, attached or detached | whether the chip existed |
| `companion_chip_stands` | whether a chip stands on a live page, past its deadline or not, for wording a refusal | false for an unknown chip or a null handle |

The placed JSON (`placed_json` in `lib.rs`) carries `location_utf16`,
`length_utf16`, `reattached`, `cloned`, `expired`, `burned`,
`unavailable`, `unreadable` and `pages_expired`, the last counting the
pages the sweep before a paste took. The shell's `CompanionClient`
wrappers decode a cap refusal as `FragmentRefusal.tooLarge(limit:)` or
`.tooManyObjects(limit:)`, so the line can name the core's number.

### Type name

The private pasteboard type is the shell's:
`com.onetimesecret.onetimepad.sealed-fragment`, with `.debug` appended in
a debug build (`CompanionClient.sealedFragmentType`,
`releaseSealedFragmentType`, `debugSealedFragmentType`). The core never
sees it. `PageModel.boardHoldsOwnCopy` knows the type as every build
names it.

## At rest

`OTSSNAP4` stays; every field below is trailing, so an older build reads
it as fields it does not know, not damage, and drops it at its next save.

- **The chip record**, after the payload: a name flag (0, or 1 and the
  name), then a note flag (0, or 1 and the note's text). A record that
  ends before either restores without it. A restored name the rule
  refuses is dropped, not read as damage; a flag other than 0 or 1 is
  damage, as the page floor's is. The note persists as text, not as its
  operation log, and restore rebuilds it with an empty undo stack. Each
  note's text is taken once, at its exact size, before the snapshot's two
  passes (draft Law 0004). Since 2026-10-21 (issue #256) the restore, a
  paste and a clone keep the note's text as one zeroizing copy, and the
  note's document is made from it at its first edit
  ([content buffer register](content-buffer-handling.md) C31).
- **The page record**, after the floor: its detached chips, framed as its
  attached chips are, then a cut flag (0, or 1 and the active cut's
  envelope) on the page the cut came from. A cut whose objects are not
  all detached on that page restores as no cut. A detached chip whose
  identity repeats one the page already holds is damage
  (`persist.rs` `a_detached_chip_repeating_an_identity_is_malformed`).
- **The ledger**: the destination class gains tag 3, `drag`. A ledger
  holding a `drag` record is damage to an older build.

## The deadline gate

`SheetStore::readable_sheets` holds the live pages whose countdown still
runs. It asks `Sheet::is_due`, the question the sweep asks, so a page
leaves it at the instant it becomes due. Copy decrypted, `NAME=value`,
the decrypted drag, both conceals, the note's text and a fragment's copy
and cut find their page or object through it. To word its refusal a
page's conceal asks whether the page still stands, and a chip's conceal
whether any page still holds the chip (`SheetStore::chip_stands`, over
the seam `companion_chip_stands`); neither reads either.

The routes that draw a page do not go through it:
`companion_sheet_document_json` (the ink and the objects' faces),
`companion_sheet_meta_json` and `companion_sheet_blocks_json` read
`SheetStore::sheet` and still answer for a page past its deadline, so the
shell shows the page until it settles and the sweep takes it.

## The keys holder

`InkTextView.answersChords` says whether a surface's chords and Edit menu
actions are its own to answer.

- The page answers unless another text view holds the keys: a field
  editor of any field in its window or in the key window over it (the
  gutter's, the strip's, the pad cell's, the sealed name's, the find
  bar's, a Settings field), or a note's surface. A note answers only
  while it holds the keys itself.
- `performKeyEquivalent` and the page's Edit menu actions (Undo, Redo,
  Seal Selected Content, Detect Code Language, Choose Language, Paste
  Without Detection) consult it, and their validation says no when it
  does. AppKit sends key equivalents to every view in the key window,
  whether or not it holds the keys, which is why the page must ask.
- Choose Language goes down the responder chain as a nil-targeted action
  carrying the language (`CodeLanguageChoice`), so it reaches whoever
  holds the keys. A file's render mode is still chosen on the model when
  no editor selection can take a language.
- The menu's availability follows the holder. A surface that answers
  publishes what it can do; when a field holds the keys the page
  publishes that nothing is available. It is asked again when the keys
  move to or from a surface and when a window becomes key.
- The sealed name field keeps its next responder past the page, so its
  own undo answers its draft.
- A nil-targeted action that finds no answer in the key window goes on
  to the main window's chain, so a field in another window, such as the
  pad list's popover, does not keep it from the page. The pad cell's case
  rests on the key window, which the test runner cannot make.
- `AskingTextView.mayReadOut`, the gate AppKit's readers ask first, is
  built on it (Law 0001's AppKit text routes table).

## The note's surface

`InkEditorView.makeSurface(over:coordinator:)` builds the page's text view
and the note's with one configuration. The note has a coordinator of its
own, holding no sheet, and its storage is the note's alone. Every page
only path keys on the coordinator's sheet; a new path that reads the
coordinator's document instead reaches the note too, so its author
decides which it means.

## The decrypted drag

`DecryptedDrag` (`DecryptedDrag.swift`) is the drag's source and its
`NSPasteboardItemDataProvider`. The provider hands the pasteboard and item
it is asked about to `companion_chip_provide_drag` through
`PageModel.provideDecryptedDrag`. The core composes the payload in a
zeroizing buffer of its final size, writes it into that item by copy
decrypted's content write (`SystemDragItem` in `crates/pasteboard`), and
records one `sent` to `drag`. The types are the chip's own:
`public.utf8-plain-text` for text, `public.png` for an image.

A probe on 2026-10-13, in one process with a uniquely named pasteboard,
saw AppKit ask an item's provider inside the read that wanted the data,
synchronously and on the main thread. The provider's write takes the
core's lock, and `companion_sheet_seal_from_drag` reads the system drag
pasteboard while holding it; Rust documents that `Mutex::lock` does not
return when the thread already holds the lock. That is why the page and
the note refuse the app's own decrypted drag (`isDecryptedDrag`) before
drop to seal reads the board. An ask AppKit makes off the main thread is
refused.

## Shell constants

| Constant | Value | What it sets |
| --- | --- | --- |
| `NotePopoverLayout.minimumWidth` | 320 | below it the note spans the card's content width |
| `NotePopoverLayout.edgeInset` | 8 | the note's margin from the content area's edges |
| `SealedBlockCell.beatDuration` | 1 s | the ember beat |
| `SealedBlockCell.beatFade` | 0.15 s | the beat's fade at each end, dropped under Reduce Motion |
| `SealedBlockCell.decryptedDragWords` | `drag decrypted` | the handle's words |
| `InkTextView.decryptedDragSlop` | 3 | the travel before a press on the handle drags |
| `SealedBlockLayout.Metrics.handleGap` | 8 | the handle's clearance from the actions seat and the classification |
| `PageModel.copiedNameLine` | `copied the name.` | the line after *Copy Name* |
