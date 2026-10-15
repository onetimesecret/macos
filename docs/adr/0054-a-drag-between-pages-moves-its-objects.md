---
documentation_status: needs-review
---

# ADR-0054: A drag between pages moves its objects

- **Status:** accepted
- **Date:** 2026-10-13
- **Supersedes in part:** [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), specifically point 10's last sentence, "A drag between pages carries the copy fragment: the drop pastes it, and the source's removal detaches." Its other points stand.
- **Depends on:** [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), whose point 8 makes a transfer one transaction, and [ADR-0052](0052-a-page-past-its-deadline-gives-nothing-out.md), whose gate refuses a page past its deadline.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

Under ADR-0047 point 10 a drag between pages is two acts. The
destination pastes the copy fragment, which clones each object (point
6): a new identity, the envelope's name and note, and a `sealed`
record. When the drag ends as a move, the source deletes its run, which
detaches the originals, and keeps that deletion as an undo step.

So a move leaves a clone where the person dropped it and the original in
the source's detached store, and ⌘Z on the source stands the original
again beside the clone: two objects where the person moved one. A cut
pasted onto another page keeps identity and clears the source page's
undo (point 8); a drag did neither.

## Decision

A drag between pages moves its range as one core transaction that keeps
every object's identity.

1. `companion_sheet_move_range_to` deletes a range on the source page
   and stands it at a point on the destination page. Each object keeps
   its identity, payload, name and note, and the move records nothing in
   the ledger.
2. It is one transaction (ADR-0047 point 8). If either body refuses its
   edit, the core reverts both and leaves chips, the active cut and the
   ledger as they were. The destination takes the move as one undo step.
3. A move that carries an object clears the source page's undo, as a
   cut's reattach onto another page does. A move of ink alone keeps it.
4. It refuses, changing neither page, when source and destination are
   one page, when either is unknown or a file, when the range or the
   point falls outside its body, and when either page is past its
   deadline, swept or not (ADR-0052). It sweeps nothing.
5. The destination's drop calls it only while the source page's own
   drag still stands on the page and state it began on. Any other drop
   pastes the drag's copy fragment and removes nothing.
6. The ⌥ drag between pages stays a copy: its drop pastes the copy
   fragment, cloning every object (ADR-0047 point 6).

## Consequences

- One object stands for each one moved, at every step. ⌘Z on the
  destination detaches the moved objects there; the source has no step
  to take back.
- A move between pages makes no clone and writes no `sealed` record. The
  moved objects end with the page they landed on.
- The drag still writes the copy fragment, for another app and for ⌥,
  so a selection past an envelope cap still cannot be dragged
  (ADR-0053).
- The shell owes the wiring: the destination calls the route and both
  pages restate, and the source deletes nothing when the drag ends.
  Until then a drag between pages still clones.

## Eject triggers

- A person expects a drag between pages to leave the original behind,
  which would ask for a copy by default and ⌥ to move.
- Undo learns to step across pages, so that ⌘Z on the destination could
  stand a move back on its source instead of the source losing its
  undo.

## Decision history

- 2026-10-13: Accepted for issue #170, before its code.
