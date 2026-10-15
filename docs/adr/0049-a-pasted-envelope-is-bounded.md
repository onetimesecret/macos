---
documentation_status: needs-review
---

# ADR-0049: A pasted envelope is bounded

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), whose point 3 says what an unreadable envelope pastes.
- **Superseded in part by:** [ADR-0053](0053-a-copy-or-cut-past-an-envelope-cap-composes-nothing.md), which replaces the consequence that a selection past a cap still copies and cuts. The decision and the other consequences stand.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0047 point 3 makes an envelope unreadable for "another version, an
unknown key, a malformed UUID or bytes that are not UTF-8". It sets no
bound on the envelope's length or on how many references it names, and
point 6 clones every reference to a live object, each clone "a core-side
copy of the payload".

Any app can write the private type to the general pasteboard. An
envelope naming one live object a thousand times clones it a thousand
times in one paste, and an image's payload has no size ceiling; the
ledger's largest size class begins at one megabyte. The UUIDs it needs
are in every envelope the app has written there.

The core's own envelope never names an object twice: it is one walk of
one selection, and a body stands each object once.

## Decision

An envelope is unreadable, and pastes as ADR-0047 point 3 says, when it
is longer than 8 MiB, names more than 1024 references, or names one
object twice.

- 8 MiB is twice `FILE_SIZE_LIMIT`, the largest file this build opens,
  which leaves room for JSON's escapes over a page that large. The length
  is checked before the bytes are parsed.
- 1024 references and a repeated object are checked as the nodes are
  read, before anything resolves.

## Consequences

- One paste clones a live object at most once, as a copy of a whole page
  would.
- A selection longer than 8 MiB or holding more than 1024 objects still
  copies and cuts, and pastes in the app as its public text with the
  unreadable line. A cut that large cannot be placed from the slot, which
  carries no public text, and its active cut does not survive a relaunch;
  ⌘Z on its page brings its objects back.
- A crafted envelope naming up to 1024 unknown UUIDs places as many
  `[sealed content · unavailable]` placeholders.

## Eject triggers

- A person's own page holds more than 1024 objects or writes an envelope
  longer than 8 MiB.
- A fragment needs to name one object twice.

## Decision history

- 2026-10-13: Accepted for issue #170, before its code.
- 2026-10-13: Superseded in part by
  [ADR-0053](0053-a-copy-or-cut-past-an-envelope-cap-composes-nothing.md).
  Its second consequence, that a selection longer than 8 MiB or holding
  more than 1024 objects still copies and cuts, is replaced: a copy or a
  cut past either cap now composes nothing and changes nothing.
