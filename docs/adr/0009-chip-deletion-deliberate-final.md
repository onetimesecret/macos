# ADR-0009: Chip removal is deliberate and final

- **Status:** proposed
- **Date:** 2026-07-15

## Context

The persistent-editor work (ADR-0006, issue #23) reopened how undo and
sealed chips interact. In the editor a chip is one attachment character,
atomic under the caret, so a single ⌫ removed it whole. The document
sync is authoritative for chip liveness (`store.rs` `sync_document`): a
chip the snapshot no longer references is zeroized on the spot, and any
later snapshot that re-references it is rejected as malformed.

That combination makes keyboard deletion of a chip unsafe to undo. ⌫
removes the glyph and the following sync destroys the secret; a
subsequent ⌘Z revives the attachment character but not the bytes,
yielding a dead chip and a rejected sync (which trips the shell's
`assert(accepted)`). The design's own open question №5 (doc 06) had left
"undo across a seal" as "needs a felt test," and doc 06 states plainly
that sealed bytes get no tombstone of any kind.

Two forces pulled against each other: a user who deletes a chip by
accident wants it back, while the memory-hygiene contract wants an
omitted chip's bytes gone the instant they leave the document. Keeping a
deleted chip's bytes alive for an undo window (a core-side tombstone)
was scoped and costed, but it lets sealed bytes linger past the moment
the document stops referencing them, and it cannot track a multi-level
undo stack without either capping undo or reconciling dead glyphs after
a rejected sync.

## Decision

A chip cannot be removed by any keyboard or editing gesture: not ⌫, not
forward delete, not cut, not typing over a selection that spans it. The
sole removal is the context menu's **Remove chip**, a deliberate act
that zeroizes the bytes immediately and is not undoable.

Prevention at the source replaces recovery after the fact. Because the
only removal path is a targeted, hover-to-reveal menu action, there is
no accident to undo, and the "sealed bytes get no tombstone" contract
stands unweakened.

## Consequences

- A chip survives every editing gesture around it. Ink deletes freely;
  the chip it abuts does not. Selecting a line and deleting removes the
  ink and leaves the chip in place. The editor vetoes any change whose
  affected range covers a chip attachment (the delegate's
  `shouldChangeText` seam, plus overrides of `deleteBackward`/
  `deleteForward`), and the atomic-attachment comment in `InkTextView`
  inverts: a chip is now immovable by keyboard, not "removed whole by
  one ⌫."
- **Remove chip** stays final. It zeroizes now (the direct
  `delete_chip` path, not a sync that could be reverted) and clears the
  page's undo history, the same discipline sealing already uses. There
  is no dead-chip state and no rejected-sync case to reconcile, so the
  shell keeps its simple "the sync is always accepted" invariant.
- The core tombstone machinery (deferred zeroize, revive-on-reference,
  flush-on-next-edit) is not built. It only earned its complexity if ⌫
  could delete chips; this decision removes that path, so the cost is
  not paid.
- Removing a chip costs one more gesture than a keystroke. This is
  intended: a sealed secret leaving the page is a decision, not a
  reflex. Copy-out (non-consuming) remains for "I want this elsewhere
  and here."
- Open question №5 is answered by narrowing it: ⌘Z after a seal still
  never restores plaintext, and now ⌘Z also has no chip deletion to act
  on, because chips are not deleted through the undoable text path.

## Eject triggers

- Users report the menu-only removal as friction heavy enough that they
  route around it (for example sealing the same content onto a fresh
  page rather than removing a chip), observed in real use.
- A gesture is found where the veto leaks and a chip is removed through
  an editing path, meaning the atomicity guarantee is incomplete and
  either the seam must widen or the deferred-zeroize model returns.
- The product decides accidental removal recovery is worth reopening,
  at which point the immediate-undo tombstone scoped here is the
  starting point, with its cost (sealed bytes surviving until the next
  edit) accepted explicitly rather than by default.
