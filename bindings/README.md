# bindings/ — the generated seam (build output)

This directory holds the generated Swift ↔ Rust glue. It is a **build output**,
not source: `scripts/build-core.sh` writes `OtsCore.xcframework` and `include/`
here from `crates/ots-ffi`. The `.xcframework` is git-ignored (see
`.gitignore`); the Swift app in `apps/OTSCache` consumes it as a binary
dependency.

Keeping the generated seam in its own directory makes the trust boundary
**visible in the file tree** — you can see exactly what crosses between the
portable Rust core and the Apple-only UI (docs/01 §2, §3).
