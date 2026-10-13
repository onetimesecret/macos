---
documentation_status: needs-review
---

# ADR-0046: Whoever holds the keys answers the page's chords and Edit menu

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0045](0045-the-note-is-written-on-the-pages-surface.md), whose note is a second writing surface in the page's window.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

Law 0007's Drafting class says "keystrokes change the field and nothing
else". The page's text view answers its editor chords (⌘Z, ⇧⌘Z, ⌘↩,
⇧⌘V, ⇧⌘C and Detect Code Language) in `performKeyEquivalent`, which
AppKit sends to every view in the key window, whether or not it holds
the keys. Until now the page stood aside for two holders only: its own
sealed name field and the note. Every other rename seat let the page's
chords through: the gutter's field is a sibling of the page in the roll,
and the strip's, the slot rail's and the pad cell's SwiftUI fields edit
through a field editor that is not the page's. So ⌘Z under a gutter
label's draft stepped the page back.

The Edit menu's items are SwiftUI buttons. Undo and Redo are turned into
nil-targeted AppKit items, so they reach whoever holds the keys. The
other four post nil-targeted actions too, except Choose Language, which
called `chooseCodeLanguage` on the page's editor directly and so acted
on the page while the sealed name or the note held the keys. All four
grey themselves on what the page last published, whoever held the keys.
A nil-targeted action that finds no answer in the key window goes on to
the main window's chain, so a field in another window, such as the pad
list's popover, does not keep it from the page.

## Decision

One predicate, `InkTextView.answersChords`, says whether a surface's
chords and Edit menu actions are its own to answer.

1. **The page** answers unless another text view holds the keys: a field
   editor of any field in its window or in the key window over it (the
   gutter's, the strip's, the slot rail's, the pad cell's, the sealed
   name's, the find bar's, a Settings field), or a note's surface.
   **A note** answers only while it holds the keys itself.
2. `performKeyEquivalent` and the page's Edit menu actions (Undo, Redo,
   Seal Selected Content, Detect Code Language, Choose Language, Paste
   Without Detection) consult the predicate, and their validation says
   no when it does.
3. **Choose Language goes down the responder chain**, as a nil-targeted
   action carrying the language (`CodeLanguageChoice`), so it reaches
   whoever holds the keys. A file's render mode is still chosen on the
   model when no editor selection can take a language.
4. **The menu's availability follows the holder.** A surface that answers
   publishes what it can do; when a field holds the keys the page
   publishes that nothing is available. It is asked again when the keys
   move to or from a surface and when a window becomes key.
5. The sealed name field keeps its next responder past the page, so its
   own undo answers its draft.

## Consequences

- ⌘Z and ⇧⌘Z in any field, the find bar's included, undo that field's
  typing; the seal chords and copy decrypted do nothing while a field
  holds the keys.
- The Edit menu greys its language and seal items while a field holds
  the keys, and in a note shows the note's.
- A new field anywhere in the window needs nothing of its own to keep the
  page's chords out of its draft.
- The pad cell's case rests on the key window, which the test runner
  cannot make; it is a hand check.

## Eject triggers

- A page chord is asked for while a field holds the keys, such as a seal
  from the find bar.
- AppKit stops sending key equivalents to views that do not hold the
  keys, or the Edit menu's items move to AppKit validation in full.

## Decision history

- 2026-10-13: Accepted for epic #252's rename seats and issue #246's
  note, before their code.
