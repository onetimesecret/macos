---
documentation_status: needs-review
---

# ADR-0045: The core composes and reads the sealed fragment and writes the decrypted drag; the shell carries both unread

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md) Amendment 1, whose `Drag` destination class the decrypted drag's write records, and [ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md), whose chip carries the name and note a reference carries.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md) (accepted) owes issues #170 and
#247 a versioned fragment of ordered ink runs and UUID references on the
pasteboard, a public text with one placeholder per live reference, a
paste that reattaches or clones in one transaction, and a decrypted drag
whose payload the core supplies when a destination asks. It fixes the
private type's name, the two node kinds, the lifecycle states and the
security invariants, the first of which reads "The shell never receives
a sealed payload from the core."

It leaves open:

- who composes and reads the envelope, and what an envelope this build
  cannot read pastes;
- where a reference is resolved against the live objects and the
  ledger's records;
- how a decrypted drag's payload reaches a destination, when AppKit asks
  the shell's `NSPasteboardItemDataProvider` for it and the shell may not
  hold it.

Draft [Law 0004](../law/0004-secret-plaintext-never-reallocates.md) asks
a buffer of page content to be allocated at its final size. Draft
[Law 0003](../law/0003-paste.md) lets a paste decline data it cannot
read.

The build on `feature/editing-seals` follows this proposal (issues #170
and #247). Acceptance is the maintainer's.

## Decision

The core composes, reads and resolves the sealed fragment and writes a
decrypted drag's payload itself; the shell carries the fragment's bytes
and the drag's pasteboard item without reading either.

1. **The core owns the envelope.** The envelope is composed and parsed
   only in the core. The shell writes its bytes under the private type,
   reads them back from the pasteboard and hands them to the core on a
   paste, never looking inside. The envelope is versioned, and a build
   reads only the version it writes.
2. **One walk, two texts.** The envelope and the public text come from
   one walk of the selection. The public text is the ink with
   `[sealed content · <size class>]` for each reference. A selection
   holding no object yields no envelope, so the shell writes plain text
   and an in-app paste keeps its ordinary path.
3. **An unreadable envelope pastes its public text.** An envelope this
   build cannot read pastes the item's public text as ink, the text any
   other app receives, and the outcome says `unreadable` so the shell
   can say so in a line. With no public text either, the paste is
   refused and nothing changes. Draft Law 0003's decline is not taken
   here: declining would lose the ink the person copied.
4. **The core resolves.** Each reference resolves in the core against
   the store's live objects and the ledger's terminal records, in the
   order Law 0001's sealed fragment representation gives. The shell
   learns what was placed, not what was resolved against.
5. **The core writes the decrypted drag.** The shell's data provider
   hands the pasteboard and item AppKit asks about to the core, which
   composes the payload and writes it into that item. The payload never
   becomes a Swift value; as with copy decrypted, it becomes an AppKit
   object's bytes.

The envelope's layout, its caps, the routes and the refusals are in Law
0001's rows and the
[sealed objects core interface](../development/sealed-objects-core-interface.md).

## Consequences

- The shell holds an envelope's bytes but never parses them, so it
  cannot build one or act on what one names; anything it decides about
  a board holding the private type, it decides from the type alone.
- A fragment from another Mac, by Universal Clipboard, resolves as
  unavailable, since its references name objects this store never held.
- A paste holding an object skips the shell's automatic fencing and
  language detection, which act on a plain paste.
- `serde_json` frees its scratch for an envelope's escaped strings
  unwiped. Those bytes came from a pasteboard any app can read.
- The core's drag write takes the core's lock inside AppKit's ask, so a
  read of the drag pasteboard made under that lock would never return.
  The page and the note therefore refuse the app's own decrypted drag
  before drop to seal reads the board (Law 0001's decrypted drag row;
  the core interface note records the probe).

## Open questions

1. **Wiping what crosses the seam.** The envelope and the public text
   cross the FFI as JSON strings and Swift values that neither side
   wipes, and the parse's scratch is freed unwiped. Issue #256 records
   the maintainer's direction of 2026-10-14 that JSON handed to Swift is
   handled under the app's security model; what that asks of the
   fragment routes is open there.

## Eject triggers

- A fragment needs a node kind beyond ink and a reference, or needs to
  name one object twice.
- A person's own selection meets an envelope cap, 8 MiB or 1024
  objects (Law 0001's copy and paste rows), in ordinary use; that would
  ask for higher caps or a paged envelope, not for a copy the paste
  cannot read.
- The shell needs to read an envelope to decide something the type
  alone cannot tell it.
- AppKit is seen asking a decrypted drag's provider off the main thread
  for a real destination, so the drag arrives empty.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0047 (the sealed fragment, the detached store and decrypted drag) points 1 (the boundary, not the layout), 2, 3 and 11's boundary, written 2026-10-13 and never ratified; its points 4 and 5 are [ADR-0046](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md), and its other points stand in Law 0001's rows, the sealed row spec and the core interface note. The eject triggers for the caps come from drafts ADR-0049 and ADR-0053, and the one for the main thread from draft ADR-0050.
- 2026-10-14: Retitled to name the decrypted drag's write, which point 5 already decided, so the title states the whole decision.
