---
documentation_status: needs-review
---

# ADR-0055: The decrypted drag handle shows an open hand

- **Status:** accepted
- **Date:** 2026-10-14
- **Supersedes in part:** [ADR-0051](0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md), specifically the pointer half of its last consequence, "VoiceOver does not reach the handle, and the pointer does not change over it." Its VoiceOver half and its decision stand.
- **Depends on:** [ADR-0051](0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md) for the handle's seat and press, and [ADR-0046](0046-the-keys-holder-answers-the-pages-chords-and-menu.md) for the keys holder the press waits on.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The handle sits inside the page's text view, whose pointer is the text
cursor. Under ADR-0051 the pointer did not change over it, so a press
that would drag the object's plaintext out of the app looked like a
press that would place the caret or select. Law 0001's decrypted drag
row asks for "a distinct, labelled handle".

## Decision

The pointer is an open hand over a decrypted drag handle wherever a
first plain press would start the drag (ADR-0051 points 1 to 3), and
the text view's own cursor everywhere else.

1. Only the visible part of a drawn handle shows the hand. A block too
   narrow for one (ADR-0051 point 2) shows the text cursor.
2. While a name or the note holds the keys, the press starts nothing
   (ADR-0051 point 4), so the pointer stays the text cursor.

## Consequences

- The pointer tells a press on the handle from a press on the block
  before the press is made.
- AppKit settles the hand against the text view's own cursor, so what
  shows under a real pointer is a hand check.
- VoiceOver still does not reach the handle, and *Copy decrypted
  contents* in the object's menu remains its path.

## Eject triggers

- Dogfood finds the hand read as a move of the object rather than a
  drag of its plaintext.
- A move handle is built and wants the open hand for itself.

## Decision history

- 2026-10-14: Accepted for issue #170, recording the pointer that
  [Law 0001](../law/0001-sealed-object.md)'s handle pointer amendment
  built the same day.
