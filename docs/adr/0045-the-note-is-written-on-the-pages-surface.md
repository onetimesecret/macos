---
documentation_status: needs-review
---

# ADR-0045: A sealed object's note is written on the page's own surface

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0043](0043-a-sealed-objects-name-and-note-live-on-its-chip.md), whose note routes are keyed by chip and whose note holds no object, and [ADR-0044](0044-sealed-row-and-note-details.md), whose popover holds the note and takes no drop from elsewhere.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

Law 0001's note row asks for "the page's own writing surface in a popover
at the block's measure". Issue #246 says the same of the build: "The
popover holds the writing surface over #243's note storage, with the
page's face, keys and undo."

The first build gave the note a text view of its own, `NoteTextView`,
with the page's base face, the keymap's undo chords on the note's stack
and plain paste. It had none of the rest of the page: the markdown face,
list continuation ([ADR-0024](0024-caret-only-automation-and-display-only-color.md)),
⌘-click links ([ADR-0023](0023-hybrid-link-affordance-cmd-click-opens.md)), code fences
with their highlighting, and language detection with its menu items.
Copying each into the note's view would make two surfaces that drift as
either is changed.

The page's surface is `InkTextView`, driven by
`InkEditorView.Coordinator`, which sends every edit, step and coalescing
group to the core by the page's sheet id. The note's routes take a chip
id instead, a counter that overlaps page ids (ADR-0043 point 4), so a
note's edit sent on a page route would write some page's ink.

Some of the page's surface cannot stand in a note. ADR-0043 point 3
refuses an op that would stand a chip in it, "since sealed objects do not
nest". Block stamps are read from a page route. The page's place, its
editor handle and the summon offer's route belong to the page.

## Decision

The note is written on the page's own surface, over the note's routes.

1. **One surface.** `InkEditorView.makeSurface(over:coordinator:)` builds
   the page's text view and the note's, with one configuration. The note
   has a coordinator of its own; its storage is the note's and nothing
   else's.
2. **Routed by document.** A coordinator's ink edits `InkDocument`: a page
   or file by sheet id, or a note by chip id. Edits, steps, their names
   and availability, coalescing groups and a refused batch's restatement
   go through `PageModel` by that document, which answers a note on the
   note's routes and never on a page's.
3. **What the note shares.** Everything the coordinator and the text view
   do for ink: the markdown face, lists, ⌘-click links, fences and their
   highlighting, automatic paste fencing, Detect Code Language and Choose
   Language, Paste Without Detection, find, the IME gate, and undo and
   redo on the note's own stack.
4. **What stands aside.** A note's coordinator holds no sheet, and every
   page only path keys on the sheet, so in a note:
   - no seal lands: ⌘↩, ⇧⌘V, Seal Selected Content and the context
     menu's Seal Selection seal nothing, and a drop from elsewhere finds
     nowhere to land (ADR-0044 point 4);
   - no chip stands: paste is plain, a drop is refused, and a batch that
     carries one is refused by the core and the note's text is restated;
   - no block stamps are shown, and the page's block route is never asked
     with a chip id;
   - the page's place, editor handle and summon offer route stay the
     page's;
   - ⌥Z, the wrap toggle, is not taken: a note always wraps, and the
     page's setting is not the note's to flip.
5. **Labels last as long as the note is open.** A language chosen for a
   bare fence's display is kept by the open note's surface and goes when
   the note closes, as a page's goes on its next structural rewrite.

## Consequences

- One surface to keep: a change to how ink is styled or typed reaches the
  note with the page.
- Every page only path must key on the page's sheet. A new path that reads
  the coordinator's document instead reaches the note too, so its author
  decides which it means.
- A display label chosen in a note is lost when the note closes; the note
  keeps its text and its undo stack in the core.
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

- 2026-10-13: Accepted for issue #246, before its code.

## Erratum

2026-10-13: Decision point 5 says a page's display label goes on its
next structural rewrite. The surface drops every display label at the
next character edit of its document, a keystroke included, and a note's
goes the same way, as well as when the note closes. The decision is
unchanged: a note's labels are the open note's alone and never a page's.
