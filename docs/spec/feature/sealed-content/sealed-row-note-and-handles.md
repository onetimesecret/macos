# Sealed row, note and handles

Status: details as built on `feature/editing-seals`, 2026-10-14. Nothing
in this file has been ratified.

Scope: the product and interaction details of a sealed block's named
bottom row, its note's popover, the clipboard slot and the decrypted drag
handle: looks, lengths, words, timings and order. The behaviour they
serve is [Law 0001](../../../law/0001-sealed-object.md)'s, and the name's
field is [Law 0007](../../../law/0007-edit-in-place.md)'s; a law row says
what happens, and this file says how it looks. The decisions under them
are proposed:
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

Sources: the drafts ADR-0042, ADR-0044, ADR-0047, ADR-0051 and ADR-0055,
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
- After *Copy name*: `copied the name.`, arming no clear, since the name
  is ambient ink.

### The object's menu

Named and with a note:

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
*Name…* stands for *Rename…*. Without a note, *Note…* stands for *Edit
note…*. On an object that is not text, *Copy name=value, decrypted* is
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

## The decrypted drag handle

### Seat and look

- The words `drag decrypted` in an ember outline on the block's top row,
  ending 8 before the actions seat.
- Drawn while the block is hovered or selected, as the actions glyph is,
  and keeping its seat when it is not. Hover shows only in the window
  holding the keys, so elsewhere the handle shows only on a selected
  block.
- Where the row cannot hold it 8 clear of the classification, none is
  drawn, and a press there does what a press on the block does.

### Press

- A first plain press on a drawn handle begins the drag once it travels
  3; a press that lifts first selects the object.
- A modified or repeated press does what a press on the block does.
- While a name or the note holds the keys, the press starts nothing and
  the page's line says why.

### Pointer and image

- The pointer is an open hand over the visible part of a drawn handle
  wherever a first plain press would start the drag, and the text view's
  own cursor everywhere else: over a block too narrow for a handle, and
  while a name or the note holds the keys.
- The drag's image is the handle as drawn, never the block's face.

### What it lacks

- VoiceOver does not reach the handle; *Copy decrypted contents* in the
  object's menu remains its path.
- No move handle exists, so D-29's "visually distinct" has nothing to be
  distinct from. Issue #255 records the maintainer's direction of
  2026-10-14 that there should be a move handle; its scope asks for the
  handle (⠿) beside this one, visually distinct from it, and leaves open
  which gives way first on a narrow block.

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
