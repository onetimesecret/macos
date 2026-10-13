> **Status: Proposal.** Nothing here is implemented or decided. The mockup
> ([sealed-name-and-note.svg](sealed-name-and-note.svg)) draws today's
> block first and the proposed states beside it; the sentences below say
> what each state means and which accepted decisions it reopens.

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
- **What it is.** Page-owned text, like a title: ambient ink that lives
  with the object core-side and travels with it through cut, paste and
  clone in the sealed fragment. It is never payload and never enters the
  ledger, which has no content field to receive it. Proposed shape: up to
  64 characters, letters, digits, underscore, dot and dash, so that
  `name=value` pastes as an environment line. Case is kept as typed.

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

## What this reopens

- **D-40** says a plain click on the block only selects it and that the
  block is not a button. The three zones make the bottom row of a named
  block clickable. Proposed resolution: the rest of the block keeps
  D-40; the row's zones are handles in D-29's sense, a named
  declassification on the object itself with the consequence written
  beside the pointer before the click.
- **D-41's menu** gains four items. The first verb no longer carries the
  only egress, so the chord's line in the record needs a sentence.
- **Law 0001's contract table** needs rows for copy name, copy
  name=value, naming, renaming and the note, plus the fragment's envelope
  growing two optional text fields.

## Open

- Whether the unnamed block's bottom row should also have the value zone,
  or whether clicking it stays select-only until a name exists.
- Whether `copies name=value` should quote the value for a shell when it
  contains spaces, or copy it raw as an IDE does.
- The note's measure when the card is narrower than the popover's
  minimum.
