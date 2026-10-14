---
documentation_status: needs-review
---

# ADR-0047: The sealed fragment, the detached store and decrypted drag

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0043](0043-a-sealed-objects-name-and-note-live-on-its-chip.md), whose chip carries the name and note a reference carries, and [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md) Amendment 1, whose `Drag` destination class this record builds.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md) (accepted) owes issues #170 and
#247: a versioned fragment of ordered ink runs and UUID references on the
pasteboard, a public text with one placeholder per live reference, a cut
that detaches, a paste that reattaches or clones in one transaction,
placeholders by lifecycle, a removal that detaches with undo, and a
decrypted drag whose payload the core supplies when a destination asks.
D-29 to D-33 of the [2026-0915 record](../spec/design/2026-0915-ui-ux-decisions.md)
say the same for the surface. The law fixes the type's name, the two node
kinds, the lifecycle table and the security invariants. It leaves open:

- who composes and reads the envelope, its encoding, and what an envelope
  this build cannot read pastes;
- where detached objects live, how an object's death is evidenced, and
  which paste is the first paste of the active cut;
- how the core writes a drag's payload, since "The shell never receives a
  sealed payload from the core";
- what the app's clipboard slot shows and where. The records say cut
  objects "appear together in the app clipboard slot"; no mockup draws it.

What the build brought:

- A page's body is a Loro document whose sentinels carry the chip's UUID
  as a mark (ADR-0013). Loro's undo of a deletion stands the sentinel
  again with its mark, and `revert_to` restores an earlier state, marks
  included.
- `settle_document` zeroized every chip whose sentinel left the body,
  recorded `discarded` for it and cleared the page's undo stack, so a
  removal was a burn. An `InsertChip` op naming a chip the page no longer
  held was refused, so an editor's move of an attachment, a delete then an
  insert, destroyed the object.
- A page's death records one ledger record, under the page's UUID. No
  record names a chip's UUID as `expired`.
- A page record ends in a trailing floor an older build skips past.
- [Law 0004](../law/0004-secret-plaintext-never-reallocates.md) (draft)
  asks a buffer of page content to be allocated at its final size.

## Decision

The core composes, reads and resolves the fragment; a page keeps the
objects its body no longer shows in a detached store on its own clock; and
the core writes a decrypted drag into the drag item the shell hands it.

1. **The envelope** is UTF-8 JSON, composed and parsed only in the core;
   the shell carries its bytes under the private type without reading
   them. Version 1:

   ```json
   {"version":1,"cut":"<uuid>","nodes":[{"ink":"text"},{"ref":{"uuid":"<uuid>","name":"API_KEY","note":"text"}}]}
   ```

   `cut` appears only on a cut's fragment and names that cut. `name` and
   `note` appear only when the object has them. Nodes keep the selection's
   order. Another version, an unknown key, a malformed UUID or bytes that
   are not UTF-8 make the envelope unreadable. It is encoded twice, sized
   then written, into a buffer of its final size.
2. **One walk, two texts.** The envelope and the public text come from one
   walk of the selection. The public text is the ink with
   `[sealed content · <size class>]` for each reference. A selection
   holding no object yields no envelope, so the shell writes plain text
   and an in-app paste keeps its ordinary path.
3. **An unreadable envelope** pastes the item's public text as ink, the
   text any other app receives, and the outcome says `unreadable` so the
   shell can say so in a line. With no public text either, the paste is
   refused and nothing changes. Draft Law 0003's decline is not adopted
   here: declining would lose the ink the person copied.
4. **The detached store.** A page holds the chips its body shows and,
   apart, those it no longer shows. An edit that takes a sentinel out of
   the body (a backspace, a cut, a restate, a peer's update) detaches its
   chip; an edit that stands it again (undo, redo, an editor's
   `InsertChip`, a restate, a paste) reattaches it. Neither records nor
   clears the undo stack. Only a page's death and `companion_chip_delete`,
   the explicit burn, destroy payload. The burn takes an attached or a
   detached chip, records `discarded` and clears its page's undo stack.
5. **The active cut.** A cut deletes its range as one undo step, and the
   objects in it detach as the store's one active cut, kept with its
   envelope. A later cut holding an object replaces it; the earlier
   objects stay detached. The cut ends at its first paste, when any of its
   objects is reattached another way or destroyed, or when its page dies.
6. **Resolution**, reference by reference, in order:
   - an object of the active cut, in an envelope naming that cut: all of
     them reattach in the one paste, on the paste's page;
   - any other live object, attached or detached, on any page: cloned;
   - else the newest `expired` or `discarded` ledger record for the UUID:
     `[sealed content · expired]` or `[sealed content · burned]`;
   - else `[sealed content · unavailable]`.

   A clone takes a new identity, a core-side copy of the payload, the
   envelope's name as `judge_name` judges it (a refused name is dropped)
   and the envelope's note with an empty undo stack. It carries no conceal
   receipt and records one `sealed`. A reattached object keeps its own name
   and note. A placeholder is ink and carries neither.
7. **Evidence.** A page's death records, beside the page's own record, one
   `expired` (expiry, a peer's expiry) or `discarded` (close, discard) for
   each chip it held, attached or detached, so an object's terminal record
   carries its UUID. Records age out with ADR-0012's 90 day window; an aged
   out or unknown UUID resolves as unavailable.
8. **One transaction.** Cut, paste, move and clone validate first, edit the
   body in one commit, then move chips. If the body refuses an edit anyway,
   the core reverts it to the state before, clears that page's undo stack,
   and leaves chips, the active cut and the ledger as they were. A reattach
   onto another page clears the source page's undo stack, which could
   otherwise stand the moved sentinel a second time.
9. **At rest.** `OTSSNAP4` stays. A page record gains two trailing fields
   after the floor: its detached chips, framed as its attached chips are,
   then a cut flag (0, or 1 and the active cut's envelope) on the page the
   cut came from. A cut whose objects are not all detached on that page
   restores as no cut. A detached chip whose UUID stands in the body is
   damage. The ledger's destination gains tag 3, `drag`.
10. **Drags inside a page** are core routes. `companion_sheet_move_range`
    moves a range as one step and keeps every object's identity.
    `companion_sheet_clone_range`, the ⌥ drag, inserts a copy of a range
    with every object cloned, as one step. A drag between pages carries the
    copy fragment: the drop pastes it, and the source's removal detaches.
11. **Decrypted drag.** The shell's `NSPasteboardItemDataProvider` hands
    the pasteboard and item it is asked about to
    `companion_chip_provide_drag`. The core composes the payload in a
    zeroizing buffer of its final size, writes it into that item by copy
    decrypted's content write in `crates/pasteboard`, and records one
    `sent` to `drag`. It refuses, writing and recording nothing, an
    unknown chip, a null pointer, an item that is not an
    `NSPasteboardItem`, a pasteboard that is the general pasteboard, and a
    type other than the chip's own (`public.utf8-plain-text` for text,
    `public.png` for an image, as copy decrypted writes). The payload never
    becomes a Swift value; as with copy decrypted, it becomes an AppKit
    object's bytes.
12. **The clipboard slot** is a standing line under the page (D-14) while
    the active cut stands. It names the cut objects by their faces, never
    their payload, and an inline button places them at the caret by
    `companion_sheet_paste_active_cut`, which resolves as a paste of the
    cut's envelope. `companion_active_cut_json` gives the cut's page and
    its objects' faces.
13. **The type's name** is the shell's:
    `com.onetimesecret.onetimepad.sealed-fragment`, with `.debug` in a
    debug build. The core never sees it.

## Consequences

- ⌘Z after a removal brings the object back. A removed object's payload
  stays in memory and at rest until its page dies or it is burned.
- Closing or discarding the page a cut came from burns the cut objects; a
  later paste of its fragment places `[sealed content · burned]`.
- A cut pasted onto another page leaves the source page with no undo.
- The ledger no longer records a removal; it records each object's death
  with its page. A ledger holding a `drag` record is damage to an older
  build.
- An older build opening the state file drops the detached objects and
  the active cut at its next save.
- A clone shares only the payload's bytes with its source; burning one
  leaves the other.
- serde_json frees its scratch for an envelope's escaped strings unwiped.
  Those bytes came from a pasteboard any app can read.
- A fragment from another Mac, by Universal Clipboard, resolves as
  unavailable.
- A paste holding an object skips the shell's automatic fencing and
  language detection, which act on a plain paste.

## Eject triggers

- A person loses cut objects to a page they closed, or asks for cut
  objects to outlive their page.
- Loro's undo stops standing a sentinel with its mark, or `revert_to`
  stops restoring a state.
- A fragment needs a node kind beyond ink and a reference.
- Dogfood puts the slot anywhere but the line under the page.

## Decision history

- 2026-10-13: Accepted for issues #170 and #247, before their code.
- 2026-10-13: [ADR-0048](0048-a-transfer-sweeps-due-pages-before-it-resolves.md)
  sweeps due pages before point 6 resolves and refuses a due page to a
  paste, move or clone; [ADR-0049](0049-a-pasted-envelope-is-bounded.md)
  bounds the envelope point 3 reads. The decisions above stand.
