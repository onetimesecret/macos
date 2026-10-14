---
documentation_status: needs-review
---

# ADR-0044: A sealed object's note is edited on the page's own text surface

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md), whose note is a document of its own, keyed by its chip and holding no object.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s note row asks for "the page's
own writing surface in a popover at the block's measure". Issue #246
says the same of the build: "The popover holds the writing surface over
#243's note storage, with the page's face, keys and undo."

The first build gave the note a text view of its own, `NoteTextView`,
with the page's base face, the keymap's undo chords on the note's stack
and plain paste. It had none of the rest of the page: the markdown face,
list continuation
([ADR-0024](0024-caret-only-automation-and-display-only-color.md)),
⌘-click links
([ADR-0023](0023-hybrid-link-affordance-cmd-click-opens.md)), code fences
with their highlighting, and language detection with its menu items.
Copying each into the note's view would make two surfaces that drift as
either is changed.

The page's surface is `InkTextView`, driven by
`InkEditorView.Coordinator`, which sends every edit, step and coalescing
group to the core by the page's sheet id. The note's routes take a chip
id instead, a counter that overlaps page ids, so a note's edit sent on a
page route would write some page's ink.

Some of the page's surface cannot stand in a note: a seal or an object,
since sealed objects do not nest (ADR-0043); block stamps, which are read
from a page route; and the page's place, editor handle and summon offer.

The build on `feature/editing-seals` follows this proposal (issue #246).
Acceptance is the maintainer's.

## Decision

A sealed object's note is written on the page's own text surface, over
the note's own routes.

1. **One surface.** One constructor builds the page's text view and the
   note's, with one configuration. The note has a coordinator of its
   own, whose storage is the note's and nothing else's.
2. **Routed by document.** A coordinator edits a document: a page or a
   file by its sheet id, or a note by its chip id. Edits, steps, their
   names and availability, coalescing groups and a refused batch's
   restatement go through the model by that document, which answers a
   note on the note's routes and never on a page's.
3. **What the note shares.** Everything the coordinator and the text
   view do for ink: the markdown face, lists, ⌘-click links, fences and
   their highlighting, automatic paste fencing, Detect Code Language and
   Choose Language, Paste Without Detection, find, the IME gate, and
   undo and redo on the note's own stack.
4. **Labels are the open note's.** A language chosen for a bare fence's
   display is kept by the open note's surface alone. It goes at the next
   character edit of the note, a keystroke included, as a page's goes at
   the next character edit of the page, and when the note closes.

What stands aside in a note, since its coordinator holds no sheet, is
in Law 0001's two rows for a seal and an object in a note. The names in
the build (`InkEditorView.makeSurface(over:coordinator:)`, `InkDocument`)
are in the
[sealed objects core interface](../development/sealed-objects-core-interface.md).

## Consequences

- One surface to keep: a change to how ink is styled or typed reaches
  the note with the page.
- Every page only path must key on the page's sheet. A new path that
  reads the coordinator's document instead reaches the note too, so its
  author decides which it means.
- A display label chosen in a note is lost at its next edit or when it
  closes; the note keeps its text and its undo stack in the core.
- A change of typeface or highlighting in Settings restyles an open note
  at its next edit, not at once.
- The find bar opens inside the note's popover.

## Eject triggers

- The note needs behaviour the page must not have, or the page gains
  behaviour the note must not have, that cannot key on the sheet.
- The core gives the note a route the page lacks, or the page a route
  that takes a chip id.
- A person asks for a note in another face than the page's.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0045 (the note is written on the page's surface) points 1 to 3 and 5, with point 5 as its erratum corrected it, written 2026-10-13 and never ratified; its point 4, what stands aside in a note, stands in Law 0001's rows.
