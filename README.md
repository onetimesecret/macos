# macOS companion for Onetime Secret

**Design-first, pre-alpha, no releases.** What exists today is a
specification, the Rust core it prescribes, and a headless demo. There is
no app to download yet, and no screenshots of vaporware.

A menu-bar-resident staging area for content in transition. Drag or paste
text and images into a small edge-docked panel; each item becomes a
**SleeperCell** with a visible, limited time-to-live. Cells exist to be
copied back out and then forgotten — like a CPU's L1/L2 cache, the value
is in being small, close, and evicted by policy, never in being a system
of record. Secondarily, any cell can be concealed into a
[Onetime Secret](https://onetimesecret.com) link (v3 API) when the
content needs to travel to another person or machine.

The core loop (paste, hold briefly, copy out, forget) requires no account
and no network. Concealing is the app's explicit outbound action, and any
replication between a person's own devices is opt-in per page and visible
while it is running. Nothing leaves the machine for a destination the
user did not choose.

## Try the core today

The logic crates are pure Rust and run anywhere:

```sh
cargo test --workspace
cargo run -p companion-core --example demo
```

The demo walks the whole SleeperCell lifecycle in a terminal: staging,
masking of secret-shaped content, the draining ring, TTL cycling,
copy-out with pasteboard hygiene, silent expiry, and a dry run of the
conceal request (nothing is sent).

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
| [feature/byoe](docs/spec/feature/byoe/README.md) | Bring Your Own Encryption on the conceal path (draft feature spec) |
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
shell/               the Swift/AppKit shell (ADR-0002), linking the core only
                     through the xcframework built from crates/ffi:
                       Sources/CompanionKit       the shared page model,
                                                  views and seam wrapper
                       Sources/OnetimePad         OnetimePad, the background
                                                  surface (ADR-0010, ADR-0014)
docs/spec/design/    the governing spec   ·   docs/spec/feature/  feature specs
docs/adr/            decisions
```

## Running

Two entry points, both in `scripts/`:

- `scripts/dev.sh` builds the debug bundle and launches it from
  `dist/`. The debug build takes a `.debug` bundle id and a "Dev"
  display name, so it runs beside the installed copy without sharing
  its defaults, keychain items, or state.
- `scripts/install.sh` builds the release bundle, signs it, and
  installs it to `/Applications`. This is the daily dogfood channel;
  see [DOGFOOD.md](DOGFOOD.md).

Both rebuild the Rust core only when it is stale and package through
`scripts/package-app.sh`.

The core builds in two shapes (ADR-0018): the release shape, whose
export list is exactly the C interface the app calls, and the dev
shape (`scripts/build-core.sh --test-util`), which adds the gated test
seams the Swift suite links. **Running `swift test` requires the dev
shape**; against a release build the suite fails at link with a
missing `companion_new_ephemeral`, which is the intended loud failure
rather than a silent fallback. `scripts/dev.sh` keeps `bindings/` in
the dev shape, `scripts/install.sh` rebuilds the release shape, and
each lane rebuilds the other's leftovers automatically; the release
packaging path additionally refuses to ship a binary that exports a
test seam.

Prefer a bundle over `swift run` whenever
Keychain behavior or permission prompts matter:

- Keychain ACLs key off the app's identity. The bundle carries a bundle
  id and a signature; a bare `swift run` binary has no
  CFBundleIdentifier, so prompts and grants behave differently (and
  less representatively) than what a real user would see.
- TCC grants and per-app pickers can't address a bundle-less binary.
- The rebuild hazard: `swift build` SIGKILLs a live instance running
  from `.build/` (in-place re-sign), and a SIGKILL skips
  `applicationWillTerminate`, meaning no state save. Running from
  `dist/` or `/Applications` keeps the live instance decoupled from
  builds.

`swift run OnetimePad` remains fine for quick UI iteration where
none of that matters (layout, tab drag, notices).

### Force close

Use `scripts/quit-app.sh`. It escalates AppleScript quit, then SIGTERM,
then SIGKILL; only the graceful first step saves state.

## The app: OnetimePad

OnetimePad is **the background surface**:
an ambient pane resting at desktop level behind every window, raised to
a floating editor with ⌃⌥Space and rested again with Esc. Spec and the
underlying macOS research: docs/spec/feature/background-surface/.

At rest the card lives *behind* every window: you see it exactly when
you see the desktop (a bare patch of screen, Show Desktop, Mission
Control). Summon it with ⌃⌥Space, a left-click on the menu-bar icon,
⌘Tab, or the Dock icon; the card raises into a floating editor on your
current Space, over full-screen apps included. A summon focuses before
it dismisses: if the card is raised but you're working beside it,
⌃⌥Space brings the keyboard back, and only when it already holds the
keyboard does the gesture rest it. Esc or a click outside the card also
rests it. The surface's mechanics log to the unified log:

```sh
log stream --predicate 'subsystem == "com.onetimesecret.companion.backdrop"'
```

It began as the second form factor (ADR-0010) beside a menu-bar panel,
`CompanionApp`, which carried the project through v0.1. Once the
surface reached feature parity the panel was archived (ADR-0014): its
sources live in git history, and `CompanionKit` keeps everything a
future form factor would share.


## Naming note

**OnetimePad** is the current working name. The bundle id
(`com.onetimesecret.companion.backdrop`) keeps the older "Companion"
working-title lineage on purpose: macOS keys state, Keychain items, and
TCC grants off the id, so the id outlives the names painted over it.
"Companion" itself replaced the earlier working title "Airlock", a
small chamber between two environments that things pass through but
never live in, which collides with at least one existing security
vendor (open question №8). The old name survives only in the
design-history documents under `docs/Airlock Prototype/`. The final
name still needs a shortlist and a trademark pass before any public
artifact.

## License

MIT — see [LICENSE](LICENSE). Security reports: see
[SECURITY.md](SECURITY.md).
