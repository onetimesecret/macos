# ADR-0018: Test seams are compiled out of release artifacts

- **Status:** accepted
- **Date:** 2026-08-20

## Context

Issue #53 gave the shell its first real persistence tests by adding
seams: `PageModel` accepts an injected state directory, core client,
and debounce interval, and the FFI gained `companion_new_ephemeral`, a
constructor whose credentials rest in process memory and never reach
the login Keychain. The Swift seams are defaulted init parameters and
cost nothing at runtime. The FFI seam is different in kind: it is an
exported C symbol in a cdylib, present in the shipped binary, whose
only legitimate caller is a test suite.

Two positions were argued. Shipping the symbol keeps one binary for
tests and release, honouring "test what you ship"; the export cannot
reach existing Keychain keys, only mint its own, so it is not an
exfiltration surface. Compiling it out keeps the shipped surface
minimal at the cost of a test build that differs from the release
build. The question was researched rather than left to taste, and the
ecosystem treats it as settled.

What established practice says:

1. **Test-only APIs live behind an explicit, off-by-default cargo
   feature.** Tokio's `test-util` is the canonical case: its
   time-pausing hooks are gated, and the gate is deliberately excluded
   even from the `full` umbrella feature (tokio issue 3395), so no
   production consumer gets the test surface without asking for it by
   name. The same `test-utils` pattern is the accepted answer for
   sharing helpers that touch sensitive state across crates. The Rust
   Book's stated rationale for `#[cfg(test)]` is that test code
   belongs out of the compiled artifact.

2. **A cdylib exports the C interface and nothing else.** That is the
   stated intent of the crate type (rust-lang/rust issue 37530), and
   shared-library hygiene guidance is uniform that exported symbols
   are attack and compatibility surface to be minimized. An exported
   constructor for tests is exactly what that guidance excludes.

3. **The tested-versus-shipped divergence has a standard mitigation,
   not a standing.** Projects with cfg-gated seams verify the release
   artifact by inspection: a packaging step greps the stripped
   binary's symbol table for the seam and fails if it is present.
   When the gated code is purely additive, one extra export and no
   change to any shipping code path, the divergence between the
   tested and the shipped binary reduces to the seam itself, and the
   symbol check pins it.

Two cargo pitfalls bound the implementation. Feature unification can
enable a feature workspace-wide from one member's request, though
resolver v2 keeps dev-dependency features out of the runtime
dependency tree. And `cargo test` does not enable features by itself
(cargo issue 2911), so test invocations must pass the feature
explicitly.

## Decision

Test-only surface in the Rust core and FFI is gated behind an
off-by-default cargo feature named `test-util`, excluded from every
umbrella feature. The dev build of the xcframework enables it so the
Swift suite can link the seams; the release and packaging build does
not, and the packaging path fails if the seam symbols appear in the
artifact it is about to ship. Swift-side seams that are defaulted
init parameters resolving to shipping values may stay in the target;
they export nothing.

`companion_new_ephemeral` moves behind this gate. Future seams of its
kind start behind it.

## Consequences

Easier: the shipped binary's export list stays the C interface the
app actually calls, and a reviewer can hold "the release artifact
contains no test surface" as an invariant checked by machine rather
than by reading doc comments. Adding future test hooks stops being a
per-hook debate.

Harder: two xcframework builds exist, dev and release, and the Swift
suite tests the dev one. The gap between them is exactly the gated
seams, which the symbol check keeps visible. CI and scripts must pass
`--features test-util` explicitly where the seams are needed, and a
contributor who forgets gets a missing-symbol link error rather than
a silent fallback.

Given up: the convenience of one artifact for every purpose, and the
ability to poke the persistence cycle from a release binary in the
field. Field diagnosis goes through the diagnostics channel, not
through test constructors.

## Eject triggers

- A defect ships that the Swift suite missed because the dev and
  release builds diverged beyond the gated seams. That is the "test
  what you ship" risk materializing, and it reopens the trade.
- The seam count or the dual-build cost grows past what the packaging
  check can pin, for example seams that alter shipping code paths
  rather than adding exports.
- Cargo or the toolchain ships first-class test-scoped features
  (cargo issue 2911 resolving), removing the explicit-flag friction
  this ADR accepts.
