---
documentation_status: needs-review
---

# ADR-0051: The decrypted drag handle sits before the actions glyph

- **Status:** accepted
- **Date:** 2026-10-13
- **Superseded in part by:** [ADR-0055](0055-the-decrypted-drag-handle-shows-an-open-hand.md), which replaces the pointer half of the last consequence: an open hand shows over a drawn handle a press would drag from. The VoiceOver half and the decision stand.
- **Depends on:** [ADR-0050](0050-a-decrypted-drag-lands-only-in-another-app.md), which says where the handle's drag may land.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The block section of the [2026-0915 record](../spec/design/2026-0915-ui-ux-decisions.md)
reads: "A move handle (⠿) appears on hover or selection and never
otherwise; beside it, visually distinct and labelled *drag decrypted*,
the decrypted-drag handle: the one place on the card where a drag
carries plaintext." D-29's acceptance asks that "the decrypted-drag
handle is visually distinct from the move handle". [Law 0001](../law/0001-sealed-object.md)
says "Handles appear on hover or selection without changing layout".

What the build brought:

- No move handle exists. A drag that starts on a selected object moves
  it (Law 0001's drag amendment, issue #170).
- The block's top row holds the lock and the classification at its
  start and the actions glyph at its end, drawn on hover or selection
  and keeping its seat when not drawn.
- The block is the card's measure, so a narrow card leaves the top row
  little room.

## Decision

The handle is the words `drag decrypted` in an ember outline on the
block's top row, ending 8 points before the actions seat.

1. It is drawn while the block is hovered or selected, as the actions
   glyph is, and keeps its seat when it is not.
2. Where the row cannot hold it 8 points clear of the classification,
   none is drawn and a press there does what a press on the block does.
3. A first plain press on a drawn handle begins the drag once it
   travels 3 points; a press that lifts first selects the object. A
   modified or repeated press does what a press on the block does.
4. While a name or the note holds the keys, the press starts nothing
   and the line says so ([ADR-0046](0046-the-keys-holder-answers-the-pages-chords-and-menu.md)).
5. The drag's image is the handle as drawn, never the block's face.

## Consequences

- With no move handle beside it, D-29's "visually distinct" is not yet
  tested; it is judged when a move handle is built.
- A block too narrow for the handle offers no decrypted drag; *Copy
  decrypted contents* in the object's menu remains.
- Hover shows only in the window holding the keys, so elsewhere the
  handle shows only on a selected block.
- VoiceOver does not reach the handle, and the pointer does not change
  over it.

## Eject triggers

- Dogfood finds the handle taken for a copy button or a move handle.
- A move handle is built and needs the seat.
- Cards narrow enough to lose the handle turn out to be common.

## Decision history

- 2026-10-13: Accepted for issue #170, with the handle and its provider.
- 2026-10-14: [Law 0001](../law/0001-sealed-object.md)'s handle pointer
  amendment shows an open hand over a drawn handle a press would drag
  from, so the last consequence's pointer half describes the build at
  acceptance. Its VoiceOver half stands.
- 2026-10-14: Superseded in part by
  [ADR-0055](0055-the-decrypted-drag-handle-shows-an-open-hand.md),
  which replaces the pointer half of the last consequence only. The
  VoiceOver half and points 1 to 5 stand.
