# Sealed row, note and handles

Historical presentation, replaced by the [2026-10-31 UX revision](../../../plans/sealed-content-ux-2026-10-31.md).
The older interaction details below describe the previous implementation.

Status: details as built on `feature/editing-seals`, 2026-10-14, and the
move handle of issue #255, 2026-10-16. Nothing in this file has been
ratified.

Scope: the product and interaction details of a sealed block's named
bottom row, its note's popover, the clipboard slot and the two handles on
its top row, the move handle and the decrypted drag handle: looks,
lengths, words, timings and order. The behaviour they
serve is [Law 0001](../../../law/0001-sealed-object.md)'s, and the name's
field is [Law 0007](../../../law/0007-edit-in-place.md)'s; a law row says
what happens, and this file says how it looks. The decisions under them
were accepted 2026-10-16:
[ADR-0042](../../../adr/0042-a-sealed-name-is-a-shell-identifier.md)
(the name's charset),
[ADR-0047](../../../adr/0047-name-value-copies-the-value-unquoted.md)
(`NAME=value` unquoted),
[ADR-0043](../../../adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md)
(where the name and note live) and
[ADR-0044](../../../adr/0044-a-sealed-objects-note-is-edited-on-the-pages-own-surface.md)
(the note on the page's own surface). How the core and the shell carry
them is in the
[sealed objects core interface](../../../development/sealed-objects-core-interface.md).

Sources: the drafts ADR-0042, ADR-0044, ADR-0047, ADR-0051 and ADR-0055
(*The decrypted drag handle shows an open hand*, not the accepted
ADR-0055 on menu wording),
written 2026-10-13 and 2026-10-14 and withdrawn on 2026-10-14 without
ratification. They
took these details from the
[name and note mockup](../../../mockups/sealed-name-and-note.md), its
[drawing](../../../mockups/sealed-name-and-note.svg) and the build. The
mockup calls itself "a lead, not a source". A detail changes here, and the
law row it serves changes only if the behaviour does.

Lengths are in points. The drawing is in dark appearance; a fill other
than ember is given as drawn, and the light fills are the build's.

## The named row

### Row

- The name in the excerpt's face, semibold; `=` in the secondary colour;
  then the excerpt as before naming. No space is added either side of
  `=`. A named object that is not text reads `NAME=excerpt` like any
  other.
- A row too long for the block cuts the name first, down to four
  characters and an ellipsis, then the value. `=` is never cut, and the
  row leaves room for the seat's widest words, so a hover moves nothing.

### Zones

- The name and value zones are their own glyph runs. The `=` zone is the
  glyph's advance and 2 either side, taken from the runs beside it.
- A zone answers in the block's lower half, across its run.
- On an object that is not text, the `=` is no zone, and the name and
  value zones are their runs.
- An unnamed row has no zones.

### Hover pill and seat words

- Under the hovered zone: 15 high, 4 radius, 3 past the run each side.
  Dark: filled `#3B3B40` on the block's `#2A2A2D`. Light: `#E4E4E9`
  (`Theme.sealedZonePill`).
- Over `=`, one pill spans the whole line, name to value.
- The size class's seat reads the zone's words: `copies the name`,
  `copies name=value, decrypted` or `copies the value, decrypted`.
- Nothing moves.

### Ember beat

- After a copy, the clicked zone's pill takes a 1 point ember stroke
  (`#DC4A22`, `Theme.ember`, the same in both appearances) over an ember
  tint (dark `#4A2F27`, light `#F8DED5`, `Theme.sealedZoneEmberTint`),
  the seat reads `copied`, and then the row rests.
- The beat lasts one second and fades in and out over 0.15 s at each
  end. Under Reduce Motion the stroke and the tint come and go without a
  fade (D-10 of the
  [2026-0915 record](../../design/2026-0915-ui-ux-decisions.md)).

### Doorway

Once a note exists the seat reads `small · note`, the size class first.
`note` is underlined by a 0.8 point rule 2.5 under the baseline; a click
on it opens the note.

### The page's line

- After the value or `=` zone: D-42's confirmation as it stands. The
  mockup says "the page's line reads as it does today".
- After *Copy Name*: `copied the name.`, arming no clear, since the name
  is ambient ink.

### The object's menu

Named and with a note, in
[ADR-0055](../../../adr/0055-menus-and-buttons-use-the-platforms-wording.md)'s
title case:

```text
Copy Name
Copy Decrypted Contents              ⇧⌘C
Copy Name=Value, Decrypted
Create One-Time Link…
────────────────────────
Rename
Edit Note…
────────────────────────
Remove Sealed Content
```

Unnamed, *Copy Name* and *Copy Name=Value, Decrypted* are absent and
*Name* stands for *Rename*. Without a note, *Note…* stands for *Edit
Note…*. On an object that is not text, *Copy Name=Value, Decrypted* is
absent. Law 0001's presentation invariants hold the same list.

## The note's popover

### Header

- `NOTE · <NAME>` in the face of the tracked `SEALED CONTENT` label,
  after a three line note glyph, with `esc closes` trailing, and
  `esc contracts` once expanded.
- An unnamed object's note is headed `NOTE` alone.
- The diagonal arrows sit at the popover's bottom right with `⇧esc`
  beside them.

### Placement

- A 10 point radius, its arrow under the doorway, at the block's measure.
- The popover's minimum width is 320 (`NotePopoverLayout.minimumWidth`).
  A block narrower than that puts the note across the card's content
  width, 8 in from each edge (`NotePopoverLayout.edgeInset`), the margin
  the expanded note keeps too.

## The clipboard slot

The slot is a standing line under the page (D-14) while the active cut
stands (Law 0001's lifecycle states). It names the cut objects by their
faces, never their contents, and stands under the page the cut came from
alone. Its inline button places the objects at the caret, as a paste of
the cut's envelope would. No mockup draws it.

## The handles

Two handles stand on the block's top row before the actions seat, the
move handle inner and the decrypted drag handle outer, reading from the
classification towards `···`. Both are drawn while the block is hovered
or selected, as the actions glyph is, and keep their seats when they are
not, so nothing on the block moves when they appear. Hover shows only in
the window holding the keys, so elsewhere the handles show only on a
selected block. The 2026-0915 record's block section asks for the pair
(issue #255 records the maintainer's direction of 2026-10-14), and
D-29's acceptance that the two be visually distinct is met by look and
by words: one is a bare glyph in the block's quiet ink, the other
outlined words in ember.

### The decrypted drag handle: seat and look

- The words `drag decrypted` in an ember outline, ending 8 before the
  actions seat, 16 high, the words inset 5 from the outline each side.
- Where the row cannot hold it 8 clear of the classification, none is
  drawn, and a press there does what a press on the block does.

### The move handle: seat and look

- The glyph `⠿` (U+283F) alone, in the system face at 11, with no
  outline and no words, in the block's quiet ink: the secondary colour
  at rest and the label colour on a selected block, the ink the actions
  glyph and the classification wear. Never ember.
- Its seat ends 8 before the decrypted drag handle, 16 high on the same
  row, the glyph inset 5 each side.
- Where the row has no room for both, the move handle gives way first: once
  the decrypted drag handle has gone, the move handle does not return
  to the seat it left. The decrypted drag handle is the one labelled
  declassification seat on the block and D-29 asks that it stay
  recognisable, while the move stays available by dragging the selected
  object, so losing the move handle loses no capability.
- On an object whose kind has no decrypted drag handle, the move handle
  sits where that one would, 8 before the actions seat.

### Press

- A first plain press on a drawn handle begins its drag once it travels
  3; a press that lifts first selects the object.
- A modified or repeated press does what a press on the block does.
- The decrypted drag handle's drag is the decrypted drag. While a name or
  the note holds the keys, its press starts nothing and the page's line
  says why.
- The move handle's drag is the page's own drag, by the same session, of
  the selection the object is in, or of the object alone when the
  selection does not include it, as a drag from the block's face is. It
  includes the copy's fragment and never plaintext, goes wherever a drag
  of the selection goes, and a destination that takes that drag takes
  this one with no further work.

### Pointer and image

- The pointer is an open hand over the visible part of either drawn
  handle wherever a first plain press would start its drag, and the text
  view's own cursor everywhere else: over a block too narrow for a
  handle, and while a name or the note holds the keys. During a drag the
  pointer is AppKit's, a closed hand.
- The decrypted drag's image is the handle as drawn, never the block's
  face. The move drag's image is the page drag's own, the block's face
  without its excerpt.

### VoiceOver

- Each drawn handle is one element under the text view, with the role of
  a handle, at the handle's seat: the move handle is *Move*, the
  decrypted drag handle is *Drag decrypted*. A block at rest offers
  none. VoiceOver cannot drag, so *Copy Decrypted Contents* in the
  object's menu remains the decrypted path, and cut and paste the move.

## Open

Observations that would change a detail above, carried from the
withdrawn drafts' eject triggers:

- Dogfood records a decrypted copy from a mis-aimed first click on a
  named row, or a lost copy from the click that brought a window forward.
- Dogfood finds the handle taken for a copy button or a move handle, or
  the open hand read as a move of the object rather than a drag of its
  plaintext.
- Cards narrow enough to lose the handle turn out to be common.
- A note needs more room than the card's content area.
- Dogfood puts the clipboard slot anywhere but the line under the page.
