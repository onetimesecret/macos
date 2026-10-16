---
documentation_status: needs-review
---

# ADR-0046: A sealed object removed from a page stays recoverable until the page ends

- **Status:** accepted
- **Date:** 2026-10-16
- **Depends on:** [ADR-0013](0013-bounded-document-history-and-block-metadata.md), whose Loro document carries each chip's identity as a mark on its sentinel.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md) (accepted) sorts removal as
structural editing: "Removal detaches rather than destroys and remains
undoable (D-30)." It forbids "A removal that destroys bytes the next
undo would need." Its lifecycle states keep an object detached by a cut
or by a removal "on the page's clock", and the first paste of a cut
reattaches the cut objects. It does not say where a detached object
lives, which edits detach and reattach, or when a cut ends.

What the build had before issue #170:

- `settle_document` zeroized every chip whose sentinel left the body,
  recorded `discarded` for it and cleared the page's undo stack, so a
  removal was a burn.
- An `InsertChip` op naming a chip the page no longer held was refused,
  so an editor's move of an attachment, a delete then an insert,
  destroyed the object.
- A page's death recorded one ledger record, under the page's UUID; no
  record named a chip's UUID as `expired`.

What makes the alternative possible: Loro's undo of a deletion stands
the sentinel again with its mark, and `revert_to` restores an earlier
state, marks included.

The build on `feature/editing-seals` follows this proposal (issues #170
and #247). Acceptance is the maintainer's.

## Decision

A page keeps the sealed objects its body no longer shows, on its own
clock, until the page ends or the object is burned.

1. **The detached store.** A page holds the chips its body shows and,
   apart, those it no longer shows. An edit that takes a sentinel out of
   the body (a backspace, a cut, a restate, a peer's update) detaches its
   chip; an edit that stands it again (undo, redo, an editor's
   `InsertChip`, a restate, a paste) reattaches it. Neither records
   anything nor clears the undo stack.
2. **Two ends.** Only a page's death and the explicit burn destroy
   payload. The burn takes an attached or a detached chip, records
   `discarded` and clears its page's undo stack.
3. **The active cut.** A cut deletes its range as one undo step, and the
   objects in it detach as the store's one active cut, kept with its
   envelope. A later cut holding an object replaces it; the earlier
   objects stay detached. The cut ends at its first paste, when any of
   its objects is reattached another way or destroyed, or when its page
   dies.

How a paste resolves a detached object, and what the ledger records
when a page ends, are Law 0001's sealed fragment representation and
lifecycle states. The bytes at rest are in the
[sealed objects core interface](../development/sealed-objects-core-interface.md).

## Consequences

- ⌘Z after a removal brings the object back. A removed object's payload
  stays in memory and at rest until its page dies or it is burned.
- An editor's move of an attachment, in two batches, keeps the object.
- Closing or discarding the page a cut came from burns the cut objects;
  a later paste of its fragment places `[sealed content · burned]`.
- The ledger no longer records a removal; each object's end is recorded
  with its page's, so its terminal record carries its UUID.
- An older build opening the state file drops the detached objects and
  the active cut at its next save.
- A burn is the one way to destroy an object before its page ends, and
  it takes the page's undo with it.

## Open questions

1. **Sync.** A peer's update that takes a sentinel out detaches the
   chip here, and one naming it again reattaches it. Issue #257 records
   the maintainer's direction of 2026-10-14 that a batch never fails to
   sync because of a sealed object, and its scope asks that a peer
   import a batch standing an object it does not hold. Whether such an object detaches
   and reattaches on that peer as it does here, and what a cut made
   there can carry, is open until the successor to
   [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md) that #257
   asks for.

## Eject triggers

- A person loses cut objects to a page they closed, or asks for cut
  objects to outlive their page.
- Loro's undo stops standing a sentinel with its mark, or `revert_to`
  stops restoring a state.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0047 (the sealed fragment, the detached store and decrypted drag) points 4 and 5, written 2026-10-13 and never ratified.
- 2026-10-16: Accepted.
