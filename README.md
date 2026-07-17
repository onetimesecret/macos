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

The spec governs; code follows it. The standing design spec lives under
`docs/spec/design/`; feature specs written against it live under
`docs/spec/feature/`. Start at
[docs/spec/design/README.md](docs/spec/design/README.md):

| Doc | Contents |
| --- | --- |
| [01-problem-space](docs/spec/design/01-problem-space.md) | The problem restated, the cache analogy taken seriously, anti-goals |
| [02-overlooked-opportunities](docs/spec/design/02-overlooked-opportunities.md) | The landscape of neighbouring apps and the gaps they leave |
| [03-design-principles](docs/spec/design/03-design-principles.md) | Six principles and the arguments they settle |
| [04-interaction-model](docs/spec/design/04-interaction-model.md) | SleeperCell anatomy, TTL ladder, panel behaviour |
| [05-technical-direction](docs/spec/design/05-technical-direction.md) | Shell survey, security posture, a11y, frugality budget |
| [06-open-questions](docs/spec/design/06-open-questions.md) | Everything unresolved, honestly |
| [07-repo-skeleton](docs/spec/design/07-repo-skeleton.md) | The prescription this repository was initialized from |
| [feature/byoe](docs/spec/feature/byoe/README.md) | Bring Your Own Encryption on the promotion path (draft feature spec) |
| [feature/background-surface](docs/spec/feature/background-surface/README.md) | The background-surface form factor, and the macOS research behind it (exploration) |

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
shell/               the Swift/AppKit shells (ADR-0002) — form factors are
                     sibling targets (ADR-0010) linking the core only through
                     the xcframework built from crates/ffi:
                       Sources/CompanionApp       the panel (alpha)
                       Sources/CompanionBackdrop  the background surface
                                                  (exploration)
docs/spec/design/    the governing spec   ·   docs/spec/feature/  feature specs
docs/adr/            decisions
```

## Running

Use the .app (scripts/build-app.sh → dist/CompanionApp.app), especially when testing Keychain behavior and permission prompts.

Reasons:


- Keychain behavior is the thing under test. The state key and API token live in the Keychain, and ACLs key off the app's identity. The bundle carries com.onetimesecret.companion and a signature; a bare swift run binary has no CFBundleIdentifier, so prompts and grants behave differently (and less representatively) than what a real user would see. Since you specifically want to observe when the prompt fires (first reveal, not launch), test the bundle.
- Permission-system citizenship. TCC grants and per-app pickers can't address a bundle-less binary — that's why build-app.sh exists.
- The rebuild hazard. swift build SIGKILLs a live instance running from .build/ (in-place re-sign), and a SIGKILL skips applicationWillTerminate — meaning no state save, pages gone. Running from dist/ keeps the live instance decoupled from builds.

swift run remains fine for quick UI iteration where none of that matters (layout, tab drag, notices). But for the persistence round trip, prompt timing, and the fullscreen/Spaces check: quit the running instance normally (so it saves state), run scripts/build-app.sh, and launch the fresh dist/CompanionApp.app.


### Summoning

⌥Space (Option-Space). It toggles: one press summons the window and gives it the keyboard (the page is ready to type into), a second press dismisses it. This is documented in docs/spec/design/04-interaction-model.md and implemented in WindowController.summon().

Related: Esc hands the keyboard back to whatever app had it, leaving the window visible. And with the new Spaces behavior in the working tree, if the window is visible on a different Space, ⌥Space brings it to your current Space instead of dismissing it.

### Force close

Use scripts/quit-app.sh

## Form factors

The panel above is the primary form factor. A second one is under
exploration: **the background surface** (`CompanionBackdrop`) — an
ambient pane resting at desktop level behind every window, raised to a
floating editor with ⌃⌥Space and rested again with Esc. Same Rust core
through the same seam; a sibling target that never touches the panel's
code (ADR-0010). It carries deliberately less authority: one page of
ink, no chips, no persistence, no network. Spec and the underlying
macOS research: docs/spec/feature/background-surface/. Build it with
`scripts/build-backdrop.sh` → `dist/CompanionBackdrop.app`; both apps
can run at once.

At rest the card lives *behind* every window — you see it exactly when
you see the desktop (a bare patch of screen, Show Desktop, Mission
Control). Left-click the menu-bar icon or press ⌃⌥Space to raise it
into the floating editor; Esc, ⌃⌥Space again, or a click outside the
card rests it. The surface's mechanics log to the unified log:

```sh
log stream --predicate 'subsystem == "com.onetimesecret.companion.backdrop"'
```


## Naming note

**CompanionApp** is a deliberately generic working title. It replaced
the earlier working title "Airlock" — a small chamber between two
environments that things pass through but never live in, the product in
one image — which collides with at least one existing security vendor
(open question №8). The old name survives only in the design-history
documents under `docs/Airlock Prototype/`. The final name still needs a
shortlist and a trademark pass before any public artifact.

## License

MIT — see [LICENSE](LICENSE). Security reports: see
[SECURITY.md](SECURITY.md).
