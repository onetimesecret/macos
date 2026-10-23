---
documentation_status: needs-review
---

# ADR-0047: A copy of `NAME=value` carries the value exactly as sealed, unquoted

- **Status:** accepted
- **Date:** 2026-10-16
- **Depends on:** [ADR-0042](0042-a-sealed-name-is-a-shell-identifier.md), whose charset makes the name a shell variable name, and [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md), whose Amendment 1 counts three egress points; a copy of `NAME=value` is one of them, not a fourth.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 name and note
amendment, which the maintainer affirmed, lets a person copy
`NAME=<plaintext>` from a named object's bottom row by copy decrypted's
route. The [name and note mockup](../mockups/sealed-name-and-note.md),
which calls itself "a lead, not a source", asks "Whether `copies
name=value` should quote the value for a shell when it contains spaces,
or copy it raw as an IDE does." A shell, an `.env` file and a YAML or
TOML file each quote differently, so any quoting the app chose would be
wrong for some of the places a person pastes.

The build on `feature/editing-seals` already follows this proposal: the
store composes `NAME=value` raw (Law 0001's `=` zone row). Acceptance is
the maintainer's.

## Decision

A copy of `NAME=value` carries the value exactly as sealed.

1. **The value unquoted.** `NAME=value` is the name, `=`, then the value
   exactly as stored: no quotes, no escapes, no added space.
2. **The same egress.** Copying `NAME=value` is copy decrypted, composed
   and written core-side with its ledger record and guarded clear, so
   ADR-0012's count of complete payload egress points stays three.

This proposal does not take a quoted form for any one destination.

## Consequences

- A value with spaces, quotes or newlines pastes exactly as stored. A
  shell line built from it may split or run part of it; quoting is the
  person's to add.
- The composed bytes never cross the FFI: the store writes them, as copy
  decrypted writes a payload.

## Eject triggers

- A raw `NAME=value` paste is reported to have run part of a value as a
  command.

## Decision history

- 2026-10-14: Proposed, split from [ADR-0042](0042-a-sealed-name-is-a-shell-identifier.md) the same day so the charset and the value's quoting can be accepted or rejected on their own.
- 2026-10-14: Consolidated from draft ADR-0042 (sealed names, copy zones and rename seats) point 4 with its argument and eject trigger, written 2026-10-13 and never ratified.
- 2026-10-16: Accepted.
