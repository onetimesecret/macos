---
documentation_status: needs-review
---

# ADR-0044: The sealed row's and the note's details

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0042](0042-sealed-names-copy-zones-and-rename-seats.md), whose open questions and surface this record settles, and [ADR-0043](0043-a-sealed-objects-name-and-note-live-on-its-chip.md), whose core refuses `NAME=value` for an image and nests no object in a note.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0042 was accepted with four open questions, each carrying a
recommendation, and makes the mockup's drawing authoritative for the
surface details point 8 lists. Building issues #244, #245 and #246 met
more the drawing leaves open: the light appearance, the beat's fades,
where a zone answers, which run gives way in a short row, the popover's
minimum and where it stands, and the click that brings a window forward.
Two cases the drawing does not draw at all:

- An image can be named, and ADR-0043 point 7 has the core refuse to
  compose `NAME=value` for one. A row whose `=` copies nothing would say
  `copies name=value, decrypted` and then do nothing.
- A drop onto the window seals
  ([interaction model](../spec/design/04-interaction-model.md), Getting
  content in), and the page takes nothing where a seal cannot land. The
  note and the name field are on the window, and no seal can stand in
  either (ADR-0043 point 3).

These were first written into ADR-0042's Decision and history on
2026-10-13, which the ADR conventions forbid for an accepted record. This
record holds them instead.

## Decision

1. **ADR-0042's open questions**, each settled by its recommendation:
   - The line after *Copy name* reads `copied the name.` and arms no
     clear, since the name is ambient ink.
   - The ember beat lasts one second, then the row rests.
   - The popover's minimum width, point 7's threshold, is one constant
     in the shell, `NotePopoverLayout.minimumWidth`, at 320 points; the
     test of point 7 reads it.
   - An unnamed object's note is headed `NOTE` alone.
2. **The row.**
   - The light appearance's pill is `#E4E4E9` and its ember tint
     `#F8DED5`; the ember stroke is the same in both.
   - The beat fades in and out over 0.15 s at each end of its second.
     Under Reduce Motion the stroke and tint come and go without a fade
     (D-10).
   - A zone answers in the block's lower half, across its run.
   - A row too long for the block cuts the name first, down to four
     characters and an ellipsis, then the value. `=` is never cut, and
     the row leaves room for the seat's widest words, so a hover moves
     nothing.
   - A zone's click copies and leaves the selection as it was.
   - A zone acts on a click only once the seat has named it under the
     pointer, as ADR-0042's Consequences require. A window not holding
     the keys shows no hover, so the click that brings it forward finds
     no zone and selects the block; the next click acts.
   - A named object that is not text reads `NAME=excerpt` like any
     other, but its `=` is no zone, and its menu has no *Copy
     name=value, decrypted*. Its name and value zones are their runs.
3. **The note's popover.** A block narrower than the minimum puts the
   note across the card's content width, 8 points in from each edge, the
   margin the expanded note keeps too. The popover is a view over the
   page inside the card's own window, not a window of its own, which
   would not carry the `sharingType = .none` each card window sets, and
   which the note could not grow from into the card's content area.
4. **No drop from elsewhere.** The note and the name field take only a
   drag of their own text. A drag from another app, or from the page,
   finds nowhere to land there, as over a file.

## Consequences

- In a window that does not hold the keys, a zone takes two clicks: one
  to bring the window forward, one to copy.
- A named image copies its name and its contents, and never
  `NAME=value`. Should the core compose one for another kind, the zone
  and the item follow `SealedBlockLayout.copiesNameValue`.
- Text reaches a note or a name by typing or pasting, never by a drop.
  A drop meant for the page that lands on either is refused, not sealed.
- The popover never reaches past the card's window.
- The light fills are this record's, not the drawing's.

## Eject triggers

- Dogfood records a lost copy from the click that brought a window
  forward, or asks for one click.
- The core composes `NAME=value` for an image or another kind.
- A person asks to drop text into a note or a name.
- A note needs more room than the card's content area.

## Decision history

- 2026-10-13: Accepted. ADR-0042's Open questions are restored, and its
  history points here.
