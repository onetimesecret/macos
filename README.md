# macOS companion for Onetime Secret

**Design-first, pre-alpha, no releases.** What exists today is a
specification, the Rust core it prescribes, and a headless demo. There is
no app to download yet, and no screenshots of vaporware.

A menu-bar-resident staging area for content in transition. Drag or paste
text and images into a small edge-docked panel; each item becomes a
**SleeperCell** with a visible, limited time-to-live. Cells exist to be
copied back out and then forgotten — like a CPU's L1/L2 cache, the value
is in being small, close, and evicted by policy, never in being a system
of record. Secondarily, any cell can be promoted into a
[Onetime Secret](https://onetimesecret.com) link (v3 API) when the
content needs to travel to another person or machine.

The core loop (paste, hold briefly, copy out, forget) requires no account
and no network. Promotion is the app's only outbound action.

## Try the core today

The logic crates are pure Rust and run anywhere:

```sh
cargo test --workspace
cargo run -p companion-core --example demo
```

The demo walks the whole SleeperCell lifecycle in a terminal: staging,
masking of secret-shaped content, the draining ring, TTL cycling,
copy-out with pasteboard hygiene, silent expiry, and a dry run of the
promotion request (nothing is sent).

## Reading order

The spec governs; code follows it. Start at
[docs/spec/README.md](docs/spec/README.md):

| Doc | Contents |
| --- | --- |
| [01-problem-space](docs/spec/01-problem-space.md) | The problem restated, the cache analogy taken seriously, anti-goals |
| [02-overlooked-opportunities](docs/spec/02-overlooked-opportunities.md) | The landscape of neighbouring apps and the gaps they leave |
| [03-design-principles](docs/spec/03-design-principles.md) | Six principles and the arguments they settle |
| [04-interaction-model](docs/spec/04-interaction-model.md) | SleeperCell anatomy, TTL ladder, panel behaviour |
| [05-technical-direction](docs/spec/05-technical-direction.md) | Shell survey, security posture, a11y, frugality budget |
| [06-open-questions](docs/spec/06-open-questions.md) | Everything unresolved, honestly |
| [07-repo-skeleton](docs/spec/07-repo-skeleton.md) | The prescription this repository was initialized from |

Decisions land as ADRs in [docs/adr/](docs/adr/). ADR-0001 (Rust core,
thin shell), ADR-0002 (Swift/AppKit shell, decided on the two-way
spike's evidence), and ADR-0003 (the C-ABI binding mechanism) are
accepted.

## Layout

```
crates/core/         cell store, TTL scheduling, SecretBuffer (page-locked,
                     zeroizing), secret-shape heuristics — no macOS deps
crates/ots-client/   Onetime Secret v3 API client, auth strategies — no macOS deps
crates/credentials/  credential-store contract; macOS Keychain impl (cfg-gated)
crates/pasteboard/   pasteboard hygiene contract; NSPasteboard adapter lands here
crates/ffi/          the C-ABI seam a non-Rust shell calls — plaintext never
                     crosses it, in either direction
shell/               the Swift/AppKit shell (ADR-0002) — links the core only
                     through the xcframework built from crates/ffi
docs/spec/           the governing spec   ·   docs/adr/  decisions
```

## Running

Use the .app (scripts/build-app.sh → dist/CompanionApp.app), especially when testing Keychain behavior and permission prompts.

Reasons:


- Keychain behavior is the thing under test. The state key and API token live in the Keychain, and ACLs key off the app's identity. The bundle carries com.onetimesecret.companion and a signature; a bare swift run binary has no CFBundleIdentifier, so prompts and grants behave differently (and less representatively) than what a real user would see. Since you specifically want to observe when the prompt fires (first reveal, not launch), test the bundle.
- Permission-system citizenship. TCC grants and per-app pickers can't address a bundle-less binary — that's why build-app.sh exists.
- The rebuild hazard. swift build SIGKILLs a live instance running from .build/ (in-place re-sign), and a SIGKILL skips applicationWillTerminate — meaning no state save, pages gone. Running from dist/ keeps the live instance decoupled from builds.

swift run remains fine for quick UI iteration where none of that matters (layout, tab drag, notices). But for the persistence round trip, prompt timing, and the fullscreen/Spaces check: quit the running instance normally (so it saves state), run scripts/build-app.sh, and launch the fresh dist/CompanionApp.app.

## Naming note

**Airlock** is a working title only: a small chamber between two
environments that things pass through but never live in — the product in
one image. It collides with at least one existing security vendor, so it
will not survive to release without a trademark check (open question №8).
The name appears nowhere in identifiers, so the eventual rename is a
one-file change.

## License

MIT — see [LICENSE](LICENSE). Security reports: see
[SECURITY.md](SECURITY.md).
