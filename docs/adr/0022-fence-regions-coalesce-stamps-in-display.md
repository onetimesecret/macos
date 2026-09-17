---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0022: Fence regions coalesce stamps in display; the core block model is unchanged

- **Status:** accepted
- **Date:** 2026-08-25

## Context

The core splits typed content on the newline: each line the reader
types commits as its own block, with its own created/modified stamps
(ADR-0013). The display stands a stamp label above every block's first
line. A fenced code block typed line by line therefore arrived as one
block per line, and the page showed a stamp between every line of the
fence — a slab the styling renders contiguous (docs/spec/design/04,
issue #75) was chopped up by its own provenance labels.

Two places could fix this. The core could learn to merge blocks that
fall inside a fence, but that would make block identity depend on
markup the reader can edit at any moment: deleting a closing rule would
have to split or re-mint blocks, and provenance is exactly the record
that should not be re-minted. The shell already carries a page-wide
fence scanner through its restyle pass, so it knows where every region
begins and ends without the core learning anything.

## Decision

The display coalesces a fence region — the run of blocks from an
opening fence rule to the rule that answers it, or to the end of the
page when none does — into one labeled unit: a single stamp above the
opening rule, spanning the earliest created and the latest modified
across the blocks the region covers, with no label and no reserved gap
on the interior blocks. The core's block model, and every stamp in it,
is untouched.

## Consequences

- The fence renders as the one slab it reads as, and its stamp still
  tells the truth: when the region was begun, and when it was last
  touched, whichever line the touch landed on.
- Block identity and provenance stay stable under markup edits.
  Deleting the closing rule merely extends the region on screen;
  restoring it splits the display back apart, and no block is minted or
  destroyed either way.
- The grouping lives only in the restyle pass, so the display's notion
  of a region and the core's notion of a block can disagree — which is
  the point, and also the cost: nothing core-side can be asked "which
  blocks share a region", and any future surface that wants the
  grouping must run the same scanner.

## Amendment 1: the region's reading rides its opening line

- **Date:** 2026-09-16

The decision above was written against a display that stood a stamp row
above every block. That row is gone: an untouched block now shows
nothing at all, and an edited one carries a compact `edited` pill at the
trailing edge of its own first line, expanding to the created and edited
reading on hover or when the caret is in the block
([block-history-affordance mockup](../mockups/block-history-affordance.md),
`docs/spec/feature/file-editing/README.md`).

What this amendment changes is where a region's reading sits, not what
it says. A fence region is still coalesced into one labeled unit
spanning the earliest created and the latest modified across the blocks
it covers, and its interior blocks still carry nothing of their own. The
unit's affordance now rides the opening rule's line rather than a row
above it, so a region reserves no vertical space and the slab keeps its
paragraph rhythm. The core's block model, and every stamp in it, remains
untouched.

A line that runs the full measure has no margin to lend: there the wide
reading stands down and the compact pill is kept, so the affordance is
never drawn over the words it describes.

## Eject triggers

- A second read surface (export, sync, the ledger) needs region
  grouping and duplicating the scanner there proves error-prone: the
  grouping moves behind the seam as a derived, display-oriented query.
- The core's block segmentation changes such that a fence commits as
  one block anyway, at which point this coalescing is dead code.

## Decision history

- **2026-08-25:** The region coalescing was accepted, against a display
  that stood a stamp row above every block.
- **2026-09-16:** [Amendment 1](#amendment-1-the-regions-reading-rides-its-opening-line)
  was appended: the stamp row is gone, and a region's reading rides the
  opening rule's own line as a compact affordance that expands on hover
  or caret focus. The coalescing rule itself is unchanged.
