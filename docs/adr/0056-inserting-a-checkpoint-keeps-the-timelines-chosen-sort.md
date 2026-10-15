---
documentation_status: draft
---

# ADR-0056: Inserting a checkpoint keeps the timeline's chosen sort

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0039](0039-pad-selection-and-associations.md), whose pads carry the day and checkpoint sort preferences.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

In Timeline mode ⌘N splits the selected page at its caret: the new page is
placed after its source in the tab order and takes the text after the caret
(cd1a3bad). That commit also set today's checkpoint sort to Natural, and when
the source sat on an older day, the pad's day sort and that day's checkpoint
sort as well (`PageModel.newPage()`). Three tests in
`CheckpointInsertionTests.swift` pin the reset.

The heading menus (4bc90ca6) then let a person choose Natural order, Oldest
first or Newest first for the days and for each day's checkpoints. Under the
reset, a choice made there lasts only until the next ⌘N.

The maintainer's direction of 2026-10-14:

> the model's natural order controls where a split is inserted; the timeline
> sort controls how that order is displayed.

## Decision

⌘N inserts the new page after its source in the tab order and changes no
sort preference.

- Natural order shows the new checkpoint beside its source.
- Oldest first and Newest first keep their order; the new checkpoint appears
  where its creation time puts it, and it is selected.

Rejected: resetting to Natural (the build at cd1a3bad), which makes an
explicit menu choice not persist; keeping the reset and saying so in the
menu, which documents the surprise instead of removing it.

## Consequences

- The `setCheckpointSort(.natural, …)` and `setDaySort(.natural, …)` calls
  leave `newPage()`.
- The three reset tests give way to one run of an insertion under each of
  the three orders, asserting that the sort values are unchanged, that the
  source keeps its head and the new page takes the tail, that the tab order
  has the new tab after its source, and that the projected timeline follows
  the kept sort.
- Under a timestamp sort, splitting an older page puts the new checkpoint in
  today, away from its source; only the selection connects them.

## Eject triggers

- A hand check or report shows a person under Oldest first or Newest first
  unable to find the checkpoint ⌘N just made.

## Decision history

- 2026-10-14: Proposed from the maintainer's direction on the review of
  cd1a3bad and 4bc90ca6.
