---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0045: Core diagnostics go to a shell-registered sink

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0001](0001-rust-core-thin-shell.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/ffi/src/diagnostics.rs`, module header and
`companion_set_diagnostic_sink`) and from the doc comment on `CoreDiagnostics`
in `shell/Sources/CompanionKit/CoreDiagnostics.swift`. Those comments are
non-authoritative provenance; this record proposes the decision they describe.

The core writes a line when a persistence step refuses: a key half that will
not load, a file that will not authenticate, a rotation the keychain refused.
These lines went to stderr. An app launched from Finder or at login gets
`/dev/null` as stderr from `launchd`, so the lines were discarded. Running the
binary from a terminal shows them, but that launch has a different keychain
posture, signature check and environment from the one that failed.

[ADR-0001](0001-rust-core-thin-shell.md) (accepted) decides that "All state and
logic live in pure-Rust crates with no UI or platform dependencies
(`companion-core`, `ots-client`); platform FFI is isolated in
`companion-pasteboard`; whatever shell wins ADR-0002 is a thin layer that
renders state and forwards intents."

## Decision

The FFI crate exposes `companion_set_diagnostic_sink`, a C function pointer the
shell registers; the core sends every diagnostic line to it, and the shell
writes it to the unified log. With no sink registered, lines go to stderr.

The credentials crate's own notices are bridged into the same sink on first
registration. A line carries metadata only: which step refused and the
backend's error text, never ink, a chip or key material. No accepted ADR or
spec states that rule for diagnostics; this record proposes it.

## Consequences

- Refusals from a normal launch are readable after the fact with `log show`,
  beside the shell's own persistence trail.
- The core stays free of `os_log` and any platform logging API; tests and CI
  read stderr as before.
- Lines emitted before registration go to stderr and are lost under `launchd`,
  so the shell must register before the first restore.
- The sink is process-wide, may be called on any thread, and receives a message
  borrowed for the call only. A sink that calls back into the core is not
  deadlocked (the pointer is copied out of the lock) but is unsupported.
- The credentials bridge is installed once and stays installed if the shell
  clears the sink; its notices then fall back to stderr.

## Eject triggers

- A second shell or platform needs diagnostics and cannot register a C callback
  before the first core call.
- Lines are observed missing from the unified log for a launch that refused,
  because they were emitted before registration.
- A diagnostic is found carrying ink, chip bytes or key material.
