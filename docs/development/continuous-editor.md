---
documentation_status: needs-review
---

# Continuous editor over page documents

This design note describes the implementation proposed in PR #338. It is not an accepted architecture decision.

## Context

The requested writing experience permits cursor movement, selection, replacement,
and undo across checkpoint boundaries. Separate text views make those boundaries
editing obstacles. Combining every checkpoint into a new core document would
also require redesigning each page's identity, expiry, and synchronization.

ADR-0013 states: “Use an operation-based document implemented with Loro.”
This proposal adds a projection over those page documents rather than replacing
their representation. Its multi-page coordination is a proposed extension, not
an existing guarantee inferred from that accepted record.

## Decision

Project the ordered live pages into one TextKit storage. Translate surface
operations into page-local operations and group their history in the core.

Represent a deleted checkpoint separator with an optional `surface.join_next`
UUID in the preceding page's Loro map. Omit the separator only when that UUID
names the immediately following page in the current projection. A missing or
nonadjacent target leaves the separator visible. Sorting changes the projection,
not page content. A tab drop specifies its page and local offset explicitly,
because multiple page positions can share a surface offset at a joined boundary.

Treat a multi-page gesture as one local history group with page identities,
versions, and document undo tokens. Check all participants before applying or
stepping the group. Page-level undo routes through the same group. A changed
roster or external page revision ends the surface's available group history.

## Consequences

Under this proposal, boundary metadata participates in the page document's
snapshots, compaction, and deltas. Concurrent writes to the same boundary use
the Loro map's conflict resolution. The editor interprets the result against
its current page order. Mixed-client rendering and concurrent boundary edits
need explicit compatibility validation; this record does not establish it.

A cross-page move of a sealed record currently clears the source page's earlier
undo stack. Earlier surface groups involving that page consequently become
unavailable after undoing the move. Plain-text movement and cloning do not take
that path. This is an implementation tradeoff to reassess, not an accepted
history policy supplied by ADR-0013.

An empty page joined to its successor has no distinct text position. Ordinary
caret insertion uses the following page at that shared position; commands that
explicitly target a checkpoint must retain its identity separately.

Sealing still requires a selection within one checkpoint. The aggregate
clipboard routes currently accept one contiguous selection. Ambient-panel
presentation is outside this proposal.

## Eject triggers

- A reproducible edit or history step changes only some participants of one
  gesture: revisit admission and rollback before shipping that path.
- A daily-use workload makes typing or navigation visibly lag: measure planner,
  projection refresh, and geometry work before extending the surface.
- Mixed-client use changes boundary rendering unexpectedly: revisit the metadata
  format and its compatibility treatment before enabling that combination.
- Users repeatedly need earlier undo after moving a sealed record: redesign
  object ownership transitions and history together.

## Related records

- [ADR-0013: document history](../adr/0013-bounded-document-history-and-block-metadata.md)
- [ADR-0017: tabs and pages](../adr/0017-durable-tabs-expiring-pages.md)
- [ADR-0060: shared timeline navigation](../adr/0060-shared-pad-timeline-navigation.md)
