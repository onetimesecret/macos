---
name: adr0042-open-questions
description: Drafts ADR-0042 (sealed names, copy zones, rename seats) and ADR-0044 (row and note details) were withdrawn unratified on 2026-10-14; their answers now live in Law 0001 and Law 0007 rows, the sealed row spec and the new ADR-0042 (proposed); never edit an accepted ADR's sections
metadata:
  type: project
---

The draft ADR-0042 (`0042-sealed-names-copy-zones-and-rename-seats`,
epic 252, #240) and the draft ADR-0044 (`0044-sealed-row-and-note-details`)
were written on 2026-10-13, marked accepted, and withdrawn on 2026-10-14
without ratification, with the other drafts up to 0055. Their numbers
now name other records, all proposed: ADR-0042 is the name's charset,
ADR-0047 is `NAME=value` unquoted (split from ADR-0042 the same day),
and ADR-0044 is the note on the page's own surface (draft 0045's). The full map is Law 0001's 2026-10-14 drafts
withdrawn amendment.

Where the two drafts' points went:

- The charset, 1 to 64 of `[A-Za-z_][A-Za-z0-9_]*`: ADR-0042. The value
  copied raw: ADR-0047 point 1.
- No zones on an unnamed row, the name zone's double click, value and
  `=` acting on the first click, the narrow card's note width, a zone's
  click leaving the selection, the zone gate (the seat names a zone
  first; a non key window's forwarding click selects), no `=` zone on an
  object that is not text, the popover inside the card's window, and no
  drop into the note or the name field: Law 0001's unnamed row, zone,
  zone gate, note and naming rows.
- The pad cell opening only by *Rename pad…*, and the empty pad name
  refused: Law 0007's pad list and pad refusal rows.
- The surface details and the four answers (`copied the name.`, a one
  second beat, `NotePopoverLayout.minimumWidth` 320, the `NOTE` header),
  the light fills, fades, zone band and cut order:
  docs/spec/feature/sealed-content/sealed-row-note-and-handles.md.

**Why:** #244/#246 choices were first written into the accepted draft's
history (review F6), against docs/adr/README.md ("Do not silently update
an accepted ADR in place."), and the lint passes either way. The
maintainer then refused to ratify the drafts at all, for topic titles
and implementation detail.

**How to apply:** behaviour goes in a law row, looks in the spec, a
decision in a new ADR written `proposed`; never edit an accepted ADR's
sections. Cite the law row or the spec heading, never the old draft
numbers. Related: [[issue244-246-sealed-shell]],
[[issue241-243-sealed-name-note-core]].
