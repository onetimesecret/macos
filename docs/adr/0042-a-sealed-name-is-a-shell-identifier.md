---
documentation_status: needs-review
---

# ADR-0042: A sealed name is a shell identifier, and `NAME=value` copies the value unquoted

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md), whose Amendment 1 counts three egress points; a copy of `NAME=value` is one of them, not a fourth.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

[Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 name and note
amendment, which the maintainer affirmed, lets a person name a sealed
object and copy `NAME=<plaintext>` from its bottom row by copy
decrypted's route. [Law 0007](../law/0007-edit-in-place.md), as first
accepted that day, refused a sealed name outside its charset without
saying what the charset is. The
[name and note mockup](../mockups/sealed-name-and-note.md), which calls
itself "a lead, not a source", left two questions open:

- **The charset.** Its proposed shape is "up to 64 characters, letters,
  digits, underscore, dot and dash, so that `name=value` pastes as an
  environment line". A POSIX shell takes `[A-Za-z_][A-Za-z0-9_]*` as a
  variable name, so `my.key=value` pasted into a shell runs as a command
  instead of assigning. The mockup's own reason for the format rules out
  the dot and the dash.
- **Quoting.** It asks "Whether `copies name=value` should quote the
  value for a shell when it contains spaces, or copy it raw as an IDE
  does." A shell, an `.env` file and a YAML or TOML file each quote
  differently, so any quoting the app chose would be wrong for some of
  the places a person pastes.

The build on `feature/editing-seals` already follows this proposal:
`judge_name` in `crates/core/src/sheet.rs` holds the charset, and the
store composes `NAME=value` raw (Law 0001's `=` zone row). Acceptance is
the maintainer's.

## Decision

A sealed name is a POSIX shell identifier, and a copy of `NAME=value`
carries the value exactly as sealed.

1. **The charset.** A sealed name is 1 to 64 characters matching
   `[A-Za-z_][A-Za-z0-9_]*`, its case kept as typed. The core trims a
   draft and refuses any other name whole, leaving the name as it
   stood. An empty draft clears the name, as Law 0007's committing class
   says of every seat with a default.
2. **The value unquoted.** `NAME=value` is the name, `=`, then the value
   exactly as stored: no quotes, no escapes, no added space.
3. **The same egress.** Copying `NAME=value` is copy decrypted, composed
   and written core-side with its ledger record and guarded clear, so
   ADR-0012's count of complete payload egress points stays three.

This proposal does not take the mockup's dot and dash, a wider Unicode
charset, or a quoted form for any one destination.

## Consequences

- `NAME=value` assigns in a POSIX shell and an `.env` file. A name with
  a dot or a dash, common in other config formats, is refused, and the
  field says why (Law 0007's refusing row).
- A value with spaces, quotes or newlines pastes exactly as stored. A
  shell line built from it may split or run part of it; quoting is the
  person's to add.
- A name a later build accepts and this rule refuses is dropped when
  this build restores it, not read as damage
  ([ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md)).

## Eject triggers

- A person needs a name with a dot, a dash or a non ASCII letter, for a
  format other than a shell line, and files it or reports it in
  dogfood.
- A raw `NAME=value` paste is reported to have run part of a value as a
  command.

## Decision history

- 2026-10-14: Proposed.
- 2026-10-14: Consolidated from draft ADR-0042 (sealed names, copy zones and rename seats) points 1 and 4 with their argument and eject triggers, written 2026-10-13 and never ratified; its other points stand in Law 0001's and Law 0007's rows and the [sealed row spec](../spec/feature/sealed-content/sealed-row-note-and-handles.md).
