---
documentation_status: needs-review
---

# ADR-0050: A decrypted drag lands only in another app

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), whose point 11 has the core write a decrypted drag into the item its provider is asked about.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0047 point 11 has the shell's `NSPasteboardItemDataProvider` hand
the pasteboard and item it is asked about to `companion_chip_provide_drag`,
which writes the payload and records one `sent` to `drag`. It does not
say which destinations may ask. The records that bear on it:

- [Law 0001](../law/0001-sealed-object.md)'s decrypted drag row: "the
  core supplies the complete payload lazily when a destination asks and
  records destination `Drag`".
- D-32 of the [2026-0915 record](../spec/design/2026-0915-ui-ux-decisions.md):
  "The decrypted drag is the recommended path into a form field".
- D-31's acceptance: "no sealed payload byte is written to a pasteboard
  except at a named declassification."
- Law 0001's ⌥ drag row: "clones all selected sealed objects core-side
  as one operation".

What the build brought:

- The page takes any drag whose source is not the page itself as drop
  to seal (`InkTextView.performDragOperation`), and
  `companion_sheet_seal_from_drag` reads the system drag pasteboard
  while holding the core's lock. The decrypted drag's source is its own
  object, so it met drop to seal.
- A probe on 2026-10-13, one process and a uniquely named pasteboard,
  saw AppKit ask an item's provider inside the read that wanted the
  data, synchronously and on the main thread. The provider's write takes
  the core's lock too, and Rust documents that `Mutex::lock` does not
  return when the thread already holds the lock.
- Without the lock, the drop would put the payload on the drag
  pasteboard, record a `sent` for a payload that came back into the app,
  and seal it as a new object without its name or note.
- Text fields elsewhere in the app, such as a tab's or a pad's name,
  take dropped plain text as their own.
- A lazily provided item can be asked after its session ends, until the
  drag pasteboard holds another drag.

## Decision

The decrypted drag's payload goes only to a drop in another app.

1. Its source offers `copy` outside the app and no operation inside it;
   a dragging context AppKit adds later is offered none.
2. The page and the note refuse a drag whose source is the app's own
   decrypted drag, in every destination call, before drop to seal reads
   the drag pasteboard. No surface of the app asks the provider, so a
   drop on the app writes, records and seals nothing.
3. Once the session ends with no operation, cancelled or refused, the
   provider refuses every later ask. After a drop another app took, it
   still answers, since a destination may read after the session ends.

## Consequences

- A decrypted drag dropped on the app does nothing and says nothing. A
  copy inside the app is the ⌥ drag, or copy and paste; both clone core
  side and put no payload on a pasteboard.
- Every text field other than the page and the note refuses through the
  empty operation mask alone, which AppKit's text views and SwiftUI's
  drop destinations are trusted to honour. No test runs a real session.
- A decrypted drag dropped on another running OnetimePad, such as a
  debug build beside the installed one, is another app's drop: that one
  seals the plaintext as a new object, and this one records the `sent`.
- An app that took the drop without reading it leaves the provider
  answerable to a later reader of the drag pasteboard, and that ask is
  recorded as a `sent`.
- An ask AppKit makes off the main thread is refused. The probe saw only
  the main thread.

## Eject triggers

- A person asks for a decrypted drag onto the app to land, for example
  to seal a fresh copy of an object on another page.
- A destination is seen to read a drop's data after AppKit reported the
  session ended with no operation.
- AppKit is seen asking the provider off the main thread for a real
  destination, so the drag arrives empty.

## Decision history

- 2026-10-13: Accepted for issue #170, with the handle and its provider.
