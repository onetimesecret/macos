---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0024: Automation writes only on the caret's line; syntax color is display only

- **Status:** accepted
- **Date:** 2026-08-27

## Context

Two additions to the ink editor (docs/spec/feature/lists-and-highlighting)
reach past anything the page has done so far, and each wants a law before
it gets code.

List automation is a genuinely new category. Everything the restyle pass
does today is display only: headings gain weight, fence rules dim, a URL
carries `.link`, and not one byte moves. Continuing a list item means the
editor inserts characters the user did not type, the first time ink
appears in the document on the app's initiative. On a page whose whole
posture is "styled, never rewritten" (docs/spec/design/04), an editor
that writes needs its boundary drawn in advance rather than discovered
later from bug reports.

Syntax coloring runs into §3 of the design principles: "no rich previews,
no syntax highlighting, no image zoom. Recognition, not consumption."
Read in its own context that rule governs the recognition surfaces:
chips, the ledger, the roll's quiet renderings, anything that shows a
page without being the page. The editable page is a different surface, already carved out of
§3's absolutism for headings by amendment B, and ADR-0013's
editable-surface rule states the license plainly: "A text file with
syntax highlighting is still a text file."

## Decision

Two clauses, one decision, because they draw the same boundary from
opposite sides: what the editor may write, and what it may only paint.

**Caret-only automation.** Automation may insert or remove text only on
the caret's line, or the line the keystroke creates, only in direct
response to that keystroke, and never anywhere else in the document.

**Display-only color.** Syntax coloring inside fenced code blocks on the
editable page is display-only styling under amendment B's contract: the
bytes never change, select-all-copy returns exactly what was typed, and
chips, the ledger and the roll's quiet renderings stay uncolored.
Recorded against §3 as amendment C.

The resting glance is deliberately not on that list. ADR-0006 gives the
backdrop no second view over the storage: at rest the card mounts the
same editor, read only, so it has shown heading weight and link color
since amendment B and it shows this color too. Nothing is revealed by
that, because the ink at rest is already legible in full; if a glance
should show less, the answer is to show less of the page, not to
selectively uncolor it.

## Consequences

- **No renumbering.** Inserting an item mid-list does not rewrite the
  numbers below it; continuation inserts the previous number plus one and
  stops. Lines the user typed stand as typed, so "styled, never
  rewritten" keeps its full meaning for every line the caret is not on. A
  list whose numbers repeat is the user's to fix, exactly as in any plain
  text file.
- **One keystroke, one undo step.** A continuation, the newline and the
  marker together, is a single undo group: ⌘Z after Return puts the caret
  back where it was with no orphaned marker, so the automation is as
  reversible as the keystroke that caused it.
- **Provenance holds with no special case.** Every inserted character
  travels the ordinary edit route, `insertText` through
  `shouldChangeText`/`didChangeText`, so the core sees ordinary ops and
  ADR-0013's block provenance needs no exception for machine-written
  text. An op the app originated is indistinguishable from one the user
  typed, which is correct: the user pressed the key.
- Color moves nothing but color. The font is unchanged, so metrics,
  wrapping and the fence wash are untouched and the page gains no
  rendering and no hidden markup. §3 keeps its force on the surfaces it
  was written for.
- What is given up, knowingly: a mid-list insertion can leave numbers
  that repeat, and a colored block is only ever as accurate as the
  language its own info string declares.

## Alternatives considered and rejected

- **A full markdown list engine with renumbering.** It would keep ordered
  lists tidy, at the cost of the app rewriting lines the user is not
  looking at on a page whose every other guarantee is that typed bytes
  stay typed. If a list ever needs renumbering, that is a command the
  user invokes, not automation.
- **A third-party grammar highlighter.** §4 (frugal) rules it out: a
  grammar engine is megabytes of binary and a supply chain, taken on for
  four colors inside fenced blocks on a little text file.
- **Guessing a language for a bare fence.** Heuristics are worst on short
  snippets, which is most of what lands here, and wrong color is a
  confident lie where no color is merely plain ink. The info string is
  the only signal, the position ADR-0023 already took on link detection.

## Eject triggers

- Dogfooding shows the strict mid-line split, where Return inside an
  item's content yields a plain continuation rather than a second item,
  is wrong often enough to be noticed. Loosening it stays inside the law:
  the new line is the line the keystroke creates.
- Pages appear whose repeated list numbers actually mislead, at which
  point an explicit renumber command lands with its own undo step and its
  own argument, still without automation touching lines the caret is not
  on.
- Coloring is wanted on a surface that is not the editable page. That is
  a change to amendment C's scope, not a detail, and it comes back here.
