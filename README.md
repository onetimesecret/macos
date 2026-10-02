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
`docs/spec/feature/`. [docs/README.md](docs/README.md) maps the whole
documentation tree. Start at
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
  `dist/`. The debug build takes its own bundle id
  (`dev.onetimesecret.pad.debug`) and a "Dev" display name, so it runs beside
  the installed copy without sharing its defaults, keychain items, or
  state.
- `scripts/install.sh` builds the release bundle, signs it with the local
  environment's values, and installs it to `/Applications`. This is the daily dogfood
  channel; see [docs/dogfood/DOGFOOD.md](docs/dogfood/DOGFOOD.md).
- `scripts/package-app.sh --app-store` builds the App Store release and
  signed `dist/OnetimePad.pkg`, taking the next build number from a counter
  shared by the clone's worktrees (`--build-number N` sets it). Its application
  identity, installer identity, and provisioning profile come from the staging
  environment file, separate from the dev and local lanes' files.
  Follow [Distributing OnetimePad through TestFlight](docs/development/testflight-distribution.md)
  for account setup, upload, and tester qualification.

Release packaging compiles [artwork/OnetimePad-Glass.icon](artwork/OnetimePad-Glass.icon)
with Xcode's `actool` and bundles both `Assets.car` and the generated `.icns`.
The document enables refractivity; Apple's
[Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
introduce Icon Composer 2.0 with “support for refractivity”. Release packaging
requires Xcode 27 or later; set `DEVELOPER_DIR` or `xcode-select` to select it.
Edit the document in Icon Composer, then run
`scripts/build-icons.sh --glass` to compile just the icon, or use the release
commands above to package it. To regenerate the saved S foreground, matching
cast shadow, and glass preview from the Swift renderer, run
`scripts/build-icons.sh --update-glass-artwork`, then `--glass` to compile.
This keeps the material and appearance settings in `icon.json`.
Debug builds keep the black development icon.
Ad-hoc icons rendered with `build-icons.sh` no longer select the release icon.
See the [exported glass icon preview](artwork/OnetimePad-Glass-CastShadow.png)
for the current composition.

Signing values stay outside the checkout, one environment directory per lane,
so every worktree reads the same ones: `dev/.env` for the dev lane,
`local/.env` for the local lane, and `staging/.env` for the App Store lane,
under `~/.local/appledev/CompanionApp/environments/` or
`$ONETIMEPAD_ENVIRONMENTS_DIR`. `environments/example/` is the checked in
template for one environment directory. Copy it out of the checkout once per
environment and rename `.env.example` to `.env` in each copy. Neither command
overwrites an existing file:

```sh
for environment in dev local staging; do
  target=~/.local/appledev/CompanionApp/environments/$environment
  mkdir -p "$target"
  cp -Rn environments/example/ "$target/"
  mv -n "$target/.env.example" "$target/.env"
done
```

Then uncomment and fill in that environment's section of each `.env`, and run
`direnv allow` in each directory if you use direnv.

All lanes rebuild the Rust core only when it is stale and package through
`scripts/package-app.sh`.

The core builds in two shapes (ADR-0018): the release shape, whose
export list is exactly the C interface the app calls, and the dev
shape (`scripts/build-core.sh --test-util`), which adds the gated test
seams the Swift suite links. Run the Swift tests with
`scripts/test-shell.sh`, which builds the dev shape first and forwards
its arguments to `swift test`; a bare `swift test` against a release
build fails at link with a missing `companion_new_ephemeral`, which is
the intended loud failure rather than a silent fallback, but there is
no reason to meet it. `scripts/dev.sh` keeps `bindings/` in the dev
shape, `scripts/install.sh` rebuilds the release shape, and each lane
rebuilds the other's leftovers automatically; the release packaging
path additionally refuses to ship a binary that exports a test seam.

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

OnetimePad has two windows over one set of pages (ADR-0033). **The
ambient panel** is the background surface: an ambient pane resting at
desktop level behind every window, raised to a floating editor with
⌃⌥Space and rested again with Esc. **The editor window** is an ordinary
macOS window, the one ⌘Tab, the Dock icon and opening the app bring you
to. One of the two holds the live page at a time, and the other shows
a glance of it that cannot be edited, or nothing. Specs: the ambient
panel and the underlying macOS research in
docs/spec/feature/background-surface/, the editor window in
docs/spec/feature/primary-editor/.

At rest the card lives *behind* every window: you see it exactly when
you see the desktop (a bare patch of screen, Show Desktop, Mission
Control). Summon it with ⌃⌥Space, a left-click on the menu-bar icon, or
a click on the card while it is pinned; the card raises into a floating
editor on your current Space, over full-screen apps included. A summon
focuses before it dismisses: if the card is raised but you're working
beside it, ⌃⌥Space brings the keyboard back, and only when it already
holds the keyboard does the gesture rest it. Esc or a click outside the
card also rests it. ⌘Tab, the Dock icon and opening the app select the
editor window instead, opening it if it is closed, and a raised card
rests as the editor window takes the keyboard. Turning off "Show the
ambient panel" in Settings leaves the editor window as the app's only
window, and then ⌃⌥Space and the menu-bar icon select it too. The
surface's mechanics log to the unified log:

```sh
log stream --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"}'
```

It began as the second form factor (ADR-0010) beside a menu-bar panel,
`CompanionApp`, which carried the project through v0.1. Once the
surface reached feature parity the panel was archived (ADR-0014): its
sources live in git history, and `CompanionKit` keeps everything a
future form factor would share.


## Naming note

**OnetimePad** is the current working name. The bundle id is
`com.onetimesecret.pad` for App Store builds, with `dev.onetimesecret.pad`
for the local lane and `dev.onetimesecret.pad.debug` for the dev lane.
Until 0.19.0 it was `com.onetimesecret.companion.backdrop`, the older
"Companion" working-title lineage kept on purpose because macOS keys
state, Keychain items, and TCC grants off the id; leaving it behind cost
every existing install all three at once, which is why the id is not to
move again with the name. "Companion" itself replaced the earlier
working title "Airlock", a
small chamber between two environments that things pass through but
never live in, which collides with at least one existing security
vendor (open question №8). The old name survives only in the
design-history documents under `docs/archive/airlock-prototype/`. The
final
name still needs a shortlist and a trademark pass before any public
artifact.

## License

MIT — see [LICENSE](LICENSE). Security reports: see
[SECURITY.md](SECURITY.md).
