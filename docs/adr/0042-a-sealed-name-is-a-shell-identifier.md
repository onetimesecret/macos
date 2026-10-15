---
documentation_status: needs-review
---

# ADR-0042: A sealed name is a POSIX shell identifier

- **Status:** proposed
- **Date:** 2026-10-14

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 name and note
amendment, which the maintainer affirmed, lets a person name a sealed
object and copy `NAME=<plaintext>` from its bottom row by copy
decrypted's route. [Law 0007](../law/0007-edit-in-place.md), as first
accepted that day, refused a sealed name outside its charset without
saying what the charset is. The
[name and note mockup](../mockups/sealed-name-and-note.md), which calls
itself "a lead, not a source", proposes "up to 64 characters, letters,
digits, underscore, dot and dash, so that `name=value` pastes as an
environment line". A POSIX shell takes `[A-Za-z_][A-Za-z0-9_]*` as a
variable name, so `my.key=value` pasted into a shell runs as a command
instead of assigning. The mockup's own reason for the format rules out
the dot and the dash.

The build on `feature/editing-seals` already follows this proposal:
`judge_name` in `crates/core/src/sheet.rs` holds the charset. Acceptance
is the maintainer's. How the value is written after the name is
[ADR-0047](0047-name-value-copies-the-value-unquoted.md).

## Decision

A sealed name is 1 to 64 characters matching `[A-Za-z_][A-Za-z0-9_]*`,
its case kept as typed. The core trims a draft and refuses any other name
whole, leaving the name as it stood. An empty draft clears the name, as
Law 0007's committing class says of every seat with a default.

This proposal does not take the mockup's dot and dash, or a wider
Unicode charset.

## Consequences

- `NAME=value` assigns in a POSIX shell and an `.env` file. A name with
  a dot or a dash, common in other config formats, is refused, and the
  field says why (Law 0007's refusing row).
- A name a later build accepts and this rule refuses is dropped when
  this build restores it, not read as damage
  ([ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md)).

## Eject triggers

- A person needs a name with a dot, a dash or a non ASCII letter, for a
  format other than a shell line, and files it or reports it in
  dogfood.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0042 (sealed names, copy zones and rename seats) point 1 with its argument and eject trigger, written 2026-10-13 and never ratified; its point 4 is [ADR-0047](0047-name-value-copies-the-value-unquoted.md), and its other points stand in Law 0001's and Law 0007's rows and the [sealed row spec](../spec/feature/sealed-content/sealed-row-note-and-handles.md).
- 2026-10-14: The value's quoting, first proposed here as points 2 and 3, moved to ADR-0047 so each can be accepted or rejected on its own.
