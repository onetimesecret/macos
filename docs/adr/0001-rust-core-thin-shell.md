# ADR-0001: UI-agnostic Rust core, thin platform shell

- **Status:** accepted
- **Date:** 2026-07-07

## Context

The framework question for the panel UI (Tauri 2.x vs Swift/AppKit vs
gpui vs others — docs/spec/05) cannot be answered honestly without a
spike on the make-or-break surface: a non-activating, edge-docked panel
that receives drags. Meanwhile the security posture — deterministic
zeroization of secret buffers — must not depend on the outcome, and the
logic must be testable on machines with no macOS SDK.

## Decision

All state and logic live in pure-Rust crates with no UI or platform
dependencies (`companion-core`, `ots-client`); platform FFI is isolated
in `companion-pasteboard`; whatever shell wins ADR-0002 is a thin layer
that renders state and forwards intents.

## Consequences

- The core is testable headless; Linux CI covers everything that thinks.
- The shell decision (ADR-0002) becomes cheap to change: the hedge is
  architectural, not aspirational.
- Plaintext resides at rest only in the zeroizing core; any shell's UI
  layer receives it transiently for display and never retains it
  (rendering vs residence, docs/spec/05).
  *(Superseded by rev C, 2026-07-13: doc 05 hardened this to "sealed
  bytes never reach the UI layer at all" — gesture-only masking means
  sealed content has no display form, so the transient-display allowance
  is gone. The architecture split this ADR decides is unchanged.)*
- Cost: an FFI or IPC boundary between core and shell, designed rather
  than accreted.

## Eject triggers

- A shell framework proves incapable of the panel behaviours *and* the
  native fallback requires logic to migrate into shell code to be
  workable.
- The core/shell boundary forces copying secret buffers in a way that
  defeats zeroization guarantees.
- Two consecutive milestones where the split demonstrably slows shipping
  with no security or portability payoff.
