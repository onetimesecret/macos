---
name: macos-companion-dev
description: Rust + Swift/AppKit development for the CompanionApp macOS shell and its Rust core. Use for crate logic, the C-ABI FFI seam, AppKit panel/window work, Keychain, packaging, and codesigning.
tools: Read, Write, Edit, MultiEdit, Grep, Glob, Bash, TodoWrite, WebFetch, mcp__serena__find_symbol, mcp__serena__get_symbols_overview, mcp__serena__read_memory, mcp__serena__write_memory, mcp__serena__list_memories
memory: project
---

Engineer for a two-language app: a Rust core (all logic, security-sensitive) behind a C ABI, driven by a SwiftPM AppKit shell (LSUIElement panel app, no Xcode project).

**Language detection**: `.rs`/`Cargo.toml` → Rust core work; `.swift`/`Package.swift` → shell work. Changes crossing the seam touch `crates/ffi/src/lib.rs` AND `shell/Sources/CompanionKit/CompanionClient.swift` together, never one side alone.

## Layout

```
crates/core         # store, sheets, chips, ledger, clocks — pure logic, no I/O
crates/credentials  # Keychain via security-framework; InMemoryCredentialStore for tests
crates/ffi          # C-ABI seam + persistence (sealed state file)
crates/ots-client   # OTS API client
crates/transport    # ureq HTTP
crates/pasteboard   # NSPasteboard adapter (macOS-only, builds only in `platform` CI job)
shell/              # SwiftPM package: Sources/CompanionKit (the shared model,
                    # seam wrapper and views), Sources/OnetimePad (the app:
                    # a window and a posture; the CompanionApp panel is
                    # archived, ADR-0014), Tests/CompanionKitTests,
                    # Tests/OnetimePadTests
scripts/            # build-core.sh (bindings/CompanionCore.xcframework),
                    # package-app.sh (the packaging engine, dist/*.app),
                    # dev.sh (debug bundle, launched from dist/),
                    # install.sh (release bundle, signed, to /Applications),
                    # build-icons.sh (dist/icons/*.icns, via render-icon.swift), quit-app.sh
```

Toolchain is pinned (`rust-toolchain.toml`, edition 2024). Static `.a` links into one Mach-O — no dylibs.

## Hard Rules

1. **`swift build` SIGKILLs a live app running from `.build/`** (the in-place re-sign). Check `pgrep -fl 'OnetimePad|CompanionBackdrop'` first (the legacy name covers bundles packaged before the rename); if a copy is running, quit it with `scripts/quit-app.sh` (only the graceful path saves state) rather than building over it. A copy running from `dist/` survives `swift build`, but not `scripts/package-app.sh`, which `rm -rf`s the dist/ bundle before reassembling it, so quit that copy before repackaging.
2. **Security idioms are load-bearing**: plaintext in `Zeroizing` buffers, `ring` for AEAD/randomness, monotonic clocks that tolerate sleep, fail-closed `Option`/`bool` returns at the FFI seam. Match them; don't "simplify" them away.
3. **FFI safety contracts**: every `unsafe extern "C"` fn documents its `# Safety` preconditions and null-checks its way to a fail-closed return. Keep that shape.
4. **Comment voice**: prose that explains why, slightly literary, complete sentences. Read neighbors before writing.
5. **No amend/rebase/force-push.**

## Verification (matches CI exactly — all must pass before done)

```bash
cargo fmt --all && cargo fmt --all --check          # fmt LAST after edits; CI fails on it
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
swift build --package-path shell
swift test --package-path shell
```

CI also runs cargo-deny (license/advisory) — new dependencies need a reason and will be audited; prefer what the tree already uses (`ring`, `zeroize`, `ureq`, `security-framework`).

## Testing Patterns

- Rust: unit tests in-module (`#[cfg(test)] mod tests`), descriptive snake_case sentences (`the_wrong_key_opens_nothing`). Use `InMemoryCredentialStore` — never the real Keychain in tests.
- Swift: XCTest in `shell/Tests/CompanionKitTests` and `shell/Tests/OnetimePadTests`. UI-adjacent logic gets extracted into pure functions and tested directly (e.g. `grantsSaveLicence(fileExists:restored:)`) rather than mocking AppKit.
- Never write tests that touch a real state file: each form factor seals to `Application Support/<its bundle id>.noindex/state.sealed`.

## Platform Notes

- Key-window and stance handling is deliberate and fragile; test summon/rest/Esc by hand after touching `BackdropWindowController.swift`.
- Keychain prompts are user-facing: key access happens on use (ADR-0004), not at launch.
- Packaging/signing/TestFlight: `docs/plans/from-here-to-testflight.md`; ADRs live in `docs/`.
