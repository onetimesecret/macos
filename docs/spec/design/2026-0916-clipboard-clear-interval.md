---
id: 2026-0916-clipboard-clear-interval
title: The general-pasteboard clear interval
status: accepted     # draft → accepted → superseded
dated: 2026-09-16
supersedes: docs/spec/design/2026-0915-stream-navigator.md
superseded-by:
reviewed: 2026-09-16
surfaces: OnetimePad (general-pasteboard egress)
sources:
  - docs/spec/design/2026-0915-stream-navigator.md
  - docs/law/0001-sealed-object.md
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md
  - crates/ffi/src/lib.rs
  - crates/pasteboard/src/lib.rs
  - crates/pasteboard/src/macos.rs
  - shell/Sources/CompanionKit/CompanionClient.swift
---

# The general-pasteboard clear interval

This record supersedes the 2026-09-15 stream navigator record in full.
It incorporates D-34 through D-41 from that record without change,
amends D-42 only where its confirmation names the clear interval, and
replaces D-43 in full. This whole-record supersession follows the dated
record convention in [the behaviour law conventions](../../law/README.md).

*Amended 2026-09-16:* D-34's stamp, D-36's marks, D-37's gutter gauge
and D-38's tooltip and gutter paragraph, as incorporated here, are
amended by [2026-0916-rail-redundancy.md](2026-0916-rail-redundancy.md)
(D-44 to D-47).

## D-42 · Confirmation after decrypted copy

After a decrypted copy, the confirmation reads: `copied decrypted
contents — small. the clipboard clears in 60 seconds.` The displayed size
is the object's size class, never a count. The interval is the core's
constant read through the FFI seam. The sentence describes OnetimePad's
guarded clear attempt; it is not a total-retention or erasure guarantee.
The remaining confirmation lines and behavior in D-42 are incorporated
without change.

## D-43 · General-pasteboard clear attempt

After an OnetimePad write to the general pasteboard, the shell arms a
one-shot timer using the core-owned interval of **60 seconds**,
`CLIPBOARD_CLEAR_SECONDS` in `crates/ffi/src/lib.rs`, read through
`companion_clipboard_clear_seconds`.

When the timer fires, the core attempts to clear the general pasteboard
only if its change count still identifies OnetimePad's write. A newer
pasteboard write is left untouched.

The interval bounds only when OnetimePad makes that guarded clear attempt.
It does not bound retention by clipboard managers, Universal Clipboard,
other observers or receiving applications, and it makes no erasure or
retention claim about the drag pasteboard.

Acceptance remains the FFI test `the_clear_interval_is_the_core_constant`,
the guarded-clear tests in `crates/pasteboard`, and the shell pasteboard
offer tests that read the interval through the seam.

## Supersession effect

For the clear interval and its meaning, this record is authoritative over
every 2026-09-15 statement in the superseded stream navigator record and
over references to that record in ADR-0012 and Law 0001. The earlier dated
entries remain part of the decision history; they do not state the rule
after this supersession.
