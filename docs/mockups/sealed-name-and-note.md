> **Status: Affirmed, not implemented.** The maintainer affirmed the two
> decisions under "What this reopens" on 2026-10-13. The naming rule is
> [Law 0007](../law/0007-edit-in-place.md); the sealed rows are owed in
> [Law 0001](../law/0001-sealed-object.md)'s contract under its
> 2026-10-13 amendment. The mockup
> ([sealed-name-and-note.svg](sealed-name-and-note.svg)) draws today's
> block first and the proposed states beside it; this note says what each
> state means. It remains a lead, not a source. Draft ADR-0042, withdrawn
> on 2026-10-14 without ratification, took its surface details from it and
> answered the charset, the double click and the three open points below,
> where its answers are noted. The details now stand in the
> [sealed row spec](../spec/feature/sealed-content/sealed-row-note-and-handles.md),
> and the answers in Law 0001's and Law 0007's rows and in
> [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md), proposed.

# Sealed object: a name and a note

Two additions to the sealed block, both post-hoc, neither touching the
payload:

1. **A name.** `MY_API_KEY`, set after sealing, shown in full before the
   mechanical excerpt: `MY_API_KEY=ghp_4kQ9…e0H5jK`.
2. **A note.** Free text beside the object, such as how to mint a new
   value, written in the page's own surface inside a popover that expands
   to the card and contracts back.

## Baseline

The block as it ships ([SealedBlockLayout.swift](../../shell/Sources/CompanionKit/SealedBlockLayout.swift),
`SealedBlockCell` in [InkEditorView.swift](../../shell/Sources/CompanionKit/InkEditorView.swift)):
full measure, 52 points high, 8 point radius, hairline border, 12 by 8
padding. Top row: lock, tracked `SEALED CONTENT`, and `···` at the
trailing edge while hovered or selected. Bottom row: the excerpt in the
chip face, the size class right aligned in a smaller face. Selected wears
the ember keyline. The mockup keeps every one of those lengths; the
proposal only changes what the bottom row holds and what a pointer over
it does.

## The name

- **Where it shows.** In the excerpt's seat, semibold, then `=` in the
  secondary colour, then the excerpt as today. The top row is untouched:
  state first, identity second, actions third
  ([aesthetic.md](../aesthetic.md)).
- **How it is set.** *Name…* in the object's menu, or a double-click on
  the bottom row. An inline field opens in the name's seat with the
  placeholder `NAME`; Return commits, Esc cancels. No dialog (D-14).
  *Rename…* reopens the same field over the current name.
  *Answered by draft ADR-0042, now Law 0001's zone rows and Law
  0007's Opening class:* on a named row only a double click on the name
  opens the field; the value and `=` copy on the first click.
- **What it is.** Page-owned text, like a title: ambient ink that lives
  with the object core-side and travels with it through cut, paste and
  clone in the sealed fragment. It is never payload and never enters the
  ledger, which has no content field to receive it. Proposed shape: up to
  64 characters, letters, digits, underscore, dot and dash, so that
  `name=value` pastes as an environment line. Case is kept as typed.
  *Proposed by ADR-0042 point 1:* 1 to 64 characters of `[A-Za-z_][A-Za-z0-9_]*`,
  refused core-side, since a dot or a dash does not assign in a shell.

## The three copy zones

The bottom row of a named block has three pointer zones, familiar from
IDE environment editors:

| Zone | Pointer feedback | Click copies | Class (Law 0001) |
| --- | --- | --- | --- |
| the name's glyph run | pill under the name; the size class's seat reads `copies the name` | the name | ambient, no boundary |
| the `=` and a few points either side | pill under the whole line; seat reads `copies name=value, decrypted` | `MY_API_KEY=<plaintext>` | declassification |
| the value's glyph run | pill under the value; seat reads `copies the value, decrypted` | the plaintext | declassification |

Feedback lives in the seat the size class already occupies, the way `···`
appears in a seat it already owns: nothing moves on hover. After a click
the zone wears ember for a beat and the page's line reads as it does
today (`copied decrypted contents · small. the clipboard clears in 60
seconds.`, the core's interval). The two decrypted zones say
"decrypted" before the click, so the boundary is named inline. Outside
the row a click selects the block, as today. Every zone is also a menu
item (D-10).

The menu, named and with a note:

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

Unnamed, the two name items are absent and *Name…* and *Note…* stand in
for *Rename…* and *Edit note…*. D-41's order holds: egress first, the
object's own words next, removal last behind a separator.

## The note

- **Doorway.** `small · note` in the metadata seat once a note exists;
  clicking *note*, or *Note…* in the menu, opens it.
- **Popover.** Anchored under the block at the block's measure, holding
  an instance of the page's writing surface: same face, same keys, same
  undo. A header reads `NOTE · MY_API_KEY`; Esc closes.
- **Expanded.** The diagonal arrows at the popover's bottom right, or
  ⇧Esc, grow the note to the card's content area, as the page's own
  expand does. The arrows keep the bottom right corner and contract it
  back into the popover there; Esc does the same. This is Zed's commit
  message field.
- **What it is.** Ink, never sealed, stored with the object core-side
  beside the name and carried in the sealed fragment. Not in the ledger.
  It expires with the page, on the page's clock (D-33).

## Edit in place, beyond the block

The naming field above is one seat of a general rule, now
[Law 0007](../law/0007-edit-in-place.md): a name is edited where it is
shown, Return commits, Escape keeps, nothing asks. The mockup draws two
more seats the law reaches:

- **Checkpoint label.** The gutter reads the day once and then the time,
  as today. A click on the time opens the field in the time's seat and
  the time slides to its right. Once a label is typed the gutter reads
  `today · Deploy notes · 13:00`; a later page on the day reads the time
  alone, `13:17`, until labelled, `Rotate keys · 13:41`. An empty Return
  drops the label and the time stands alone again.
- **Pad list.** *Rename pad…* opens the field in the pad's own cell. The
  *Rename pad* sheet with its Rename and Cancel buttons goes; the name
  rules (not empty, 80 characters) are said in a line under the page.

## What this reopened, affirmed 2026-10-13

- **D-40** said a plain click on the block only selects it and that the
  block is not a button. The three zones make the bottom row of a named
  block clickable. Affirmed: the rest of the block keeps D-40; the row's
  zones are handles in D-29's sense, a named declassification on the
  object itself with the consequence written beside the pointer before
  the click.
- **D-41's menu** gains four items, in that record's order.
- **Law 0001's contract table** gains rows for naming, the three zones
  and the note, all owed; the fragment's envelope grows two optional text
  fields.

## Open

- Whether the unnamed block's bottom row should also have the value zone,
  or whether clicking it stays select-only until a name exists.
- Whether `copies name=value` should quote the value for a shell when it
  contains spaces, or copy it raw as an IDE does.
- The note's measure when the card is narrower than the popover's
  minimum.

*Answered by draft ADR-0042, now Law 0001's unnamed row and note rows
and ADR-0042 point 2, proposed:* an unnamed row has no zones until the
object is named; the value is copied raw; and on a narrow card the note
takes the card's full content width.
