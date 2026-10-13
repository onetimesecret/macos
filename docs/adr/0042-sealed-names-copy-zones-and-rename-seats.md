---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0042: Sealed names, copy zones and rename seats

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md), whose three egress points this record keeps at three.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0007](../law/0007-edit-in-place.md) and the 2026-10-13 name and note
amendment of [Law 0001](../law/0001-sealed-object.md) leave points open, or
state rows that cannot be built as written. Issue #240 lists them:

- Law 0007 refuses "a sealed name outside its charset", and no accepted
  source defines one. The mockup proposes "up to 64 characters, letters,
  digits, underscore, dot and dash, so that `name=value` pastes as an
  environment line". A POSIX shell name is `[A-Za-z_][A-Za-z0-9_]*`, so
  `my.key=value` runs as a command.
- Law 0007 opens a field with "a double click where the single click is
  taken (the sealed object's bottom row, whose click selects or copies; a
  pad cell, whose click activates)". On a named row, the first click of a
  double click has already copied plaintext. A pad cell's first click
  activates the pad and closes the list, so no second click arrives.
- Law 0007 says "An empty draft renames to nothing, which clears the typed
  name and lets the default derive again". A pad has no default, and
  `PadCatalog.validatedName` refuses an empty name.
- The mockup leaves open the unnamed row's zones, quoting in `name=value`,
  and the note popover on a narrow card.
- The hover pill, the ember beat, the zone around `=`, the `small · note`
  doorway and the note's header exist only in
  [the mockup](../mockups/sealed-name-and-note.md), which calls itself "a
  lead, not a source".
- Law 0001's amendment narrows D-40 and extends D-41. The law README says
  a dated record "is superseded whole when any of them changes", so the
  change needs a citable home outside the dated records, as ADR-0037 gave
  D-26.

## Decision

Adopt issue #240's eight recommendations as stated.

1. **Charset.** A sealed name is 1 to 64 characters matching
   `[A-Za-z_][A-Za-z0-9_]*`, case kept as typed. The core refuses any
   other name. An empty draft clears the name, per Law 0007.
2. **Unnamed row.** An unnamed block's bottom row has no zones. D-40
   holds for the whole of an unnamed block.
3. **Double click.** On a named row, only a double click on the name zone
   opens the name field; its first click copies the name, which is
   ambient. The value and `=` zones act on the first click and ignore the
   clicks after it. On an unnamed row, a double click anywhere on the row
   opens the field.
4. **Quoting.** `name=value` copies the value raw: the name, `=`, then the
   value exactly as stored, unquoted.
5. **Pad cell.** A pad cell opens its field only through *Rename pad…*,
   as the strip opens only through *Rename tab…*.
6. **Empty pad name.** Refused. The line under the page shows the
   `pad.name.empty` words and the field stays open.
7. **Narrow card.** When the block's measure is narrower than the note
   popover's minimum width, the popover takes the card's full content
   width.
8. **Surface details.** The details below come from the mockup and its
   [drawing](../mockups/sealed-name-and-note.svg), which this record makes
   authoritative for them only. Lengths are in points. The drawing is in
   dark appearance; a fill other than ember is given as drawn.

   - **Row.** The name in the excerpt's face, semibold; `=` in the
     secondary colour; then the excerpt as today. No space is added
     either side of `=`.
   - **Zones.** The name and value zones are their own glyph runs. The
     `=` zone is the glyph's advance and 2 points either side, taken from
     the runs beside it.
   - **Hover pill.** Under the hovered zone: 15 high, 4 radius, 3 past
     the run each side, filled `#3b3b40` on the block's `#2a2a2d`. Over
     `=` one pill spans the whole line, name to value. The size class's
     seat reads the zone's string: `copies the name`,
     `copies name=value, decrypted` or `copies the value, decrypted`.
     Nothing moves.
   - **Ember beat.** After a copy, the clicked zone's pill takes a
     1 point ember stroke (`#DC4A22`) over an ember tint (`#4a2f27`), the
     seat reads `copied`, and then the row rests.
   - **Doorway.** Once a note exists the seat reads `small · note`, the
     size class first. `note` is underlined by a 0.8 point rule 2.5 under
     the baseline; a click on it opens the note.
   - **Header.** `NOTE · <NAME>` in the face of the tracked
     `SEALED CONTENT` label, after a three line note glyph, with `esc closes`
     trailing and `esc contracts` once expanded. The popover has a 10
     point radius and its arrow under the doorway; the diagonal arrows sit
     at its bottom right with `⇧esc` beside them.
   - **The page's line.** After the value or `=` zone, D-42's
     confirmation as it stands; the mockup says "the page's line reads as
     it does today". The mockup gives no line for *Copy name*; the list
     after the menu settles it.
   - **Menu.** Law 0001's amendment names the four items; the mockup
     gives their order:

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
     *Name…* stands for *Rename…*. Without a note, *Note…* stands for
     *Edit note…*.

   Four details the mockup does not give are decided here, not taken
   from it:

   - **The line after *Copy name*.** `copied the name.`, with no clear
     armed, since the name is ambient ink.
   - **The ember beat's length.** One second, then the row rests. Under
     Reduce Motion the stroke and tint come and go without a fade (D-10).
   - **The popover's minimum width**, point 7's threshold. One named
     constant in the shell. Issue #246 sets its value and records it in
     this record's history, and its test of point 7 reads the constant.
   - **An unnamed object's note header.** `NOTE` alone.

Copying the value or `name=value` is ADR-0012's copy decrypted egress,
written core-side with its ledger record and guarded clear; the count
stays three. This record is where the dated records and Laws 0001 and 0007
cite the narrowed D-40 and the extended D-41.

## Consequences

- `name=value` assigns in a POSIX shell and an `.env` file. A name with a
  dot or a dash, common in other config formats, is refused.
- A value with spaces, quotes or newlines pastes exactly as stored. A
  shell line built from it may split or run part of it; quoting is the
  person's to add.
- A decrypted copy happens on the first click, with no double click
  delay, so a mis-aimed click on a value or `=` zone copies plaintext. The
  seat names that before the click, and the guarded clear follows.
- On a named row the pointer opens the name field only from the name
  zone. Every seat keeps its menu verb, so the keyboard route is
  unchanged.
- An unnamed block copies by menu only. Naming it is what adds zones.
- The pad list renames only through its menu verb, and refuses an empty
  name where the tab and the gutter clear to a default.
- On a narrow card the note covers the card's content width instead of
  overflowing it.
- The light appearance's fills are not drawn.

## Eject triggers

- A person needs a name with a dot, a dash or a non ASCII letter, for a
  format other than a shell line, and files it or reports it in dogfood.
- Dogfood records a decrypted copy from a mis-aimed first click on a
  named row.
- A raw `name=value` paste is reported to have run part of a value as a
  command.
- The pad list stops closing on activation, so a second click can reach
  a cell; reopen point 5.

## Decision history

- 2026-10-13: Accepted, adopting issue #240's eight recommendations as
  stated. The 2026-0915 stream navigator record and its 2026-0916
  successor carry dated notes at D-40 and D-41, and the 2026-0915 UI/UX
  record at D-10, D-27 and section 3's menu. Laws 0001 and 0007 cite this
  record.
- 2026-10-13: The four open questions it was accepted with are settled
  by adopting the recommendation each carried. They now stand after
  point 8's menu, and the Open questions section is removed. The
  popover's minimum width still awaits its value from issue #246.
- 2026-10-13: Issue #244 builds point 8's row, zones, pill and beat, and
  settles what the drawing leaves open. The light appearance's pill is
  `#E4E4E9` and its ember tint `#F8DED5`; the ember stroke is the same
  in both. The beat fades in and out over 0.15 s at each end of its
  second, and Reduce Motion drops both fades. A zone answers in the
  block's lower half, across its run. A row too long for the block
  cuts the name first, down to four characters and an ellipsis, then
  the value; `=` is never cut, and the row leaves room for the seat's
  widest words, so a hover moves nothing. A zone's click copies and
  leaves the selection as it was.
- 2026-10-13: Issue #246 sets the popover's minimum width at 320
  points, the constant `NotePopoverLayout.minimumWidth`; a block
  narrower than that puts the note across the card's content width, 8
  points in from each edge, the margin the expanded note keeps too. The
  popover stands inside the card's own window, over the page, rather
  than in a window of its own.
- 2026-10-13: A zone acts on a click only once the seat has named it
  under the pointer, as the Consequences require. A window not holding
  the keys shows no hover, so the click that brings it forward finds no
  zone and selects the block; the next click acts.
