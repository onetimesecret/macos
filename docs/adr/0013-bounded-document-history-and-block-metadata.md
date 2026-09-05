---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0013: Bounded document history and per-block metadata

- **Status:** accepted
- **Date:** 2026-08-05

## Context

Pages and paragraph blocks need stable identity so the core can retain creation,
modification, origin, and interaction metadata across edits. The previous
full-document resync reduced ink to anonymous runs and could not preserve that
identity.

The operation history needed to derive metadata is retained state. Any solution
must keep that history inside the existing security boundary and bound it with
the same retention model as the page. The editor must remain one contiguous text surface rather than become a
collection of independently editable blocks.

Three architectures were considered: a block-tree document, attributed ranges
over a flat stream, and an operation log or conflict-free replicated data type
(CRDT). The supporting analysis and later product-level choices are preserved in
[the document-history design background](../spec/feature/document-history/decision-background.md).
The three numbered architecture sections this record once carried now live in
that design background rather than here.

## Decision

Use an operation-based document implemented with Loro. The core is the document
authority; shell edits arrive as operations rather than full snapshots. Stable
block identity and created/modified/origin metadata derive from changes while
their history exists.

At each compaction boundary, rebuild the current document without its prior
operation history and materialize the block metadata that must survive. This
bounds locally reconstructible deleted content. With peers, compaction is a
coordinated protocol event and the honest claim is that this device forgot and
asked its peers to do the same, not that every copy is known to be gone.

Blocks remain an internal document concept. Every editable surface presents
document order; a differently ordered view is read-only and navigates back to
the block's actual position. Formatting remains in-band Markdown so concurrent
formatting merges as text rather than out-of-band marks.

Loro was selected over Automerge and yrs because this decision weights commit
metadata, movable structure, undo support, Swift bindings, and shallow snapshots
more heavily than ecosystem size. That ordering is revisited if those properties
change.

## Consequences

- Stable identity and derived block metadata move into the core and survive ordinary edits.
- The shell/core seam changes from snapshot replacement to operation delivery.
- Undo and stable-position handling move to the authoritative document layer.
- The operation log retains sensitive history until compaction; compaction is a
  security and storage requirement, not only an optimization.
- Created and modified can derive from operations; interaction counts cannot and
  remain stored fields maintained at interaction sites.
- Multi-device sync becomes an extension of the document model rather than a
  later rewrite, but coordinated forgetting is more complex than local
  compaction.
- TextKit integration must preserve one contiguous editable surface and avoid
  exposing independently editable reordered blocks.

## Eject triggers

- Loro can no longer provide maintained Swift bindings, stable positions,
  movable structure, commit metadata, or usable history truncation.
- Another implementation provides materially better sync-compatible history
  truncation without losing the metadata this decision requires.
- Real page measurements show operation-log growth or compaction cost exceeding
  the product's storage or latency budget.
- The threat model requires a history horizon shorter than the page's current
  compaction schedule.
- A required feature needs an editable surface whose visual order differs from
  document order; that would cross the boundary into a block editor.

## Decision history

- **2026-08-07:** Architecture 3 and Loro were selected. Related interaction and
  retention choices were developed in the linked design background.
- **2026-09-02:** The record was split into this ADR and the linked design
  background, which now carries the three numbered architecture sections.
- **2026-09-04:** The record was retitled from "Document provenance and
  per-block metadata" to its present title, and its vocabulary narrowed from
  "provenance" to bounded document history, to keep it apart from the
  authorship status labels specified for Nerd Fonts. The code it governs
  still uses the older word; references to the old filename resolve only
  through this note.
