# ADR-0003: Core ⇄ shell binding mechanism

- **Status:** proposed — recommendation below, decision reserved
- **Date:** 2026-07-08

## Context

The seam between the Rust core and a non-Rust shell is a hand-written C
ABI plus a committed header (`crates/ffi/include/companion_ffi.h`),
packaged as a `.xcframework` by `scripts/build-core.sh`. Issue #4 asks
whether a binding generator — `swift-bridge` or UniFFI — earns its keep,
or the C ABI stays. Secrets never cross this seam by construction (the
boundary law, docs/spec/05 and ADR-0001; a test in `crates/ffi` asserts
no plaintext appears in its output), so this is an **ergonomics**
question, not a safety one.

What actually crosses the seam is deliberately narrow and primitive:

- **Out:** cell ids (`u64`), rung/TTL codes (`c_int`), booleans, counts,
  a deadline in milliseconds (`i64`), and one JSON string of non-secret
  cell summaries (masked recognition lines, never the secret).
- **In:** an id to act on; a `bool`/`c_int` back.
- The "rich" data — the cell list — is already serialized to JSON in the
  core, precisely so the boundary carries opaque, auditable values rather
  than a live object graph.

Fifteen functions, all C-primitive or `char*`-JSON. This is the shape a
hand-written C ABI handles best, and the shape a generator adds the least
value to.

## Decision

**Recommendation: keep the hand-written C ABI. Do not adopt a binding
generator.** The final call is the maintainer's — this ADR stays
*proposed*.

Rationale:

1. **The seam is small and primitive-typed.** `swift-bridge`/UniFFI earn
   their keep when a large or fast-evolving interface passes rich
   structured types (nested structs, enums, callbacks, async streams)
   across the boundary. Here the interface is intentionally narrow and the
   structured payload is already JSON. A generator would mostly reproduce
   glue that is currently trivial.
2. **Auditability is this seam's whole job.** The boundary law is
   enforceable by eye: read ~15 functions, confirm none returns secret
   bytes. A committed header is a stable, reviewable contract. A codegen
   layer interposes generated code between the auditor and the boundary —
   more to trust, more to hand-audit, and it dims the very property the
   seam exists to make obvious. For a security boundary, less magic is a
   feature, not a cost.
3. **A generator adds real carrying cost** for little gain at this size: a
   build-time dependency version-coupled to two toolchains, generated
   Swift to vendor or regenerate in CI, and — for UniFFI — its own runtime
   and type system. The current cost is one header and one build script.
4. **It already works and is tested.** The C ABI builds into the
   `.xcframework` cleanly, compiles for both Apple arches, and carries the
   no-plaintext-crosses test.

## Consequences

- The shell (whichever ADR-0002 selects) writes a thin Swift wrapper over
  the C functions by hand, as `spikes/swift-panel`'s `CompanionClient`
  already does. That wrapper is small and stable because the seam is.
- Every new seam function is a manual edit in three places — the Rust
  export, the C header, and the Swift wrapper — kept honest by the header
  as the single source of truth. This is the friction we are accepting in
  exchange for an auditable boundary.
- No new build-time dependency; `scripts/build-core.sh` stays the whole
  toolchain story.

## Eject triggers

- The seam grows rich, evolving structured types crossing in both
  directions (many structs/enums, callbacks, async streams) such that
  hand-maintaining header + Swift wrapper becomes error-prone — then
  UniFFI/`swift-bridge` codegen would pay for itself.
- A second non-Rust shell target appears (e.g. a Windows/Linux port),
  multiplying the hand-written wrappers a generator would unify.
- The JSON-over-the-boundary approach starts leaking structure the shell
  must re-parse fragilely, indicating the boundary wants typed bindings
  after all.
