# Dogfooding CompanionApp

This is the guide for running CompanionApp as a real daily tool, not a
dev build you launch from the repo. It replaces the ad hoc habit of
keeping quick snippets in Vivaldi Notes.

## Install and update

```sh
scripts/install-app.sh
```

Builds the core only if it is stale, builds both apps, and installs
them to `/Applications` (override with `APP_DEST`). Running the
installed copy matters for two reasons:

- Rebuilds in the repo never touch it. `swift build` re-signs whatever
  binary is under `.build/`, and a running process whose own signature
  changes gets SIGKILLed by the kernel. `/Applications` is outside that
  blast radius.
- Keychain and TCC grants are tied to code identity. Set
  `CODESIGN_IDENTITY` in `scripts/local.env` (see
  `scripts/local.env.example`) to a stable certificate so those grants
  survive an update instead of resetting every time.

Re-run `install-app.sh` to update. `--no-launch` installs without
opening the apps afterward.

## Which build am I on

Right-click the tray icon: the version line (disabled, informational)
shows the stamped bundle version next to the core the binary actually
linked against, so a stale `xcframework` shows itself rather than
hiding. Both build scripts append the short git SHA, with a `.dirty`
marker for an uncommitted tree.

## Launch at login

Settings has a toggle backed by `SMAppService.mainApp`. Only a bundle
under `/Applications` can register, so a dev build never claims the
login item by accident. A refused registration reverts the toggle to
whatever the system actually granted.

## Quitting

Cmd+Q or the tray's Quit item. That is the only path that saves state,
so it is also the only safe way to end a session you want back
tomorrow. If the app is unresponsive, `scripts/quit-app.sh` escalates
AppleScript quit to SIGTERM to SIGKILL, in that order, and says which
level it needed. Only the first one saves anything.

## Trusting persistence across a quit and reopen

Short version: trust it for a normal quit, do not trust it for
anything else. Content is sealed to disk (ChaCha20-Poly1305, key in
the Keychain) exactly once, at quit, and restored once, on first
reveal after launch. A force quit, a crash, or a kill skips the save
entirely and loses whatever was live at that moment, by design, not by
bug.

If a save at quit fails (locked Keychain, full disk, a failed rename)
you get an alert with the choice to quit anyway or stay and retry.
There is currently no equivalent alert for a restore failure at
launch; it only withholds that session's ability to save over the
existing file and logs to the unified log under the `persistence`
category. See `ABERRATIONS.txt` (local, gitignored) for the running
list of behavior like this that has not yet earned a permanent home.

## Recording what you find

Day-to-day surprises go in the local `ABERRATIONS.txt` first. When one
turns out to be structural, promote it: an ADR under `docs/adr/` for a
decision, a section here for operational guidance, or an issue for
something that should change.
