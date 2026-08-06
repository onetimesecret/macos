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

## One-time reset when you update to the ADR-0012 build

Everything an existing install kept lands on the floor at once with
this update. Nothing migrates, deliberately: the formats broke and old
files are discarded rather than read. Send or copy out anything you
still need **before** you install, because after the update the old
files are unreadable, not merely inconvenient.

What changes:

- **The state directory moves.** It was
  `~/Library/Application Support/CompanionApp` and
  `.../CompanionBackdrop`. It is now named for the running build's
  bundle id with a `.noindex` suffix, so
  `~/Library/Application Support/com.onetimesecret.companion.noindex`
  and `...companion.backdrop.noindex` (a debug build gets
  `...companion.debug.noindex`). The suffix keeps Spotlight out; the
  directory is also excluded from Time Machine. Nothing copies the old
  directories over, and nothing deletes them either; remove them by
  hand once you accept that what is in them is unreadable.
- **The file format changed twice over.** Both the sealed envelope and
  the snapshot inside it took a new version byte, so an old
  `state.sealed` fails its magic check and is refused rather than
  misparsed. Copying the old file into the new directory does not help
  and actively hurts: a restore that fails over a file that exists
  withholds this session's save licence, so that session cannot write
  either.
- **Staged content no longer survives a reboot, by design.** The
  content key is derived from two halves: one in the Keychain, one in
  the per-user temp directory that macOS clears at boot. Without the
  temp half there is no key, and the sealed record also carries the
  boot session UUID, so a file from an earlier boot is discarded and
  both halves are rotated. Restarting the Mac is now a clean slate for
  staged pages. Quit and reopen inside one boot session still restores.
- **Signed builds carry a new entitlement.** `keychain-access-groups`
  is what the data protection keychain requires, and only a real
  signing identity can carry it. Ad-hoc builds skip it and log a single
  fallback line to the login keychain. The item names did not change,
  so on a stable `CODESIGN_IDENTITY` your Keychain items are still
  reachable; on a changed identity expect confirmation prompts, and
  answering them once is the whole fix.
- **Debug builds live under a `.debug` bundle id**, moved from `.dev`.
  macOS keys almost everything on the bundle id, so the old `.dev`
  defaults domain, its TCC grants (screen recording, accessibility)
  and any login item registered under it are orphaned, not migrated.
  Re-grant what a dev build needs; delete the old `.dev` defaults
  domain and login item entry if they bother you.
- **The ledger is a separate file now**, `ledger.sealed`, beside the
  state file and under its own long-lived key, and it holds metadata
  plus a capped page title only. The old ledger stored page ink
  verbatim; that content is gone with the old file and is not coming
  back. Retention is a rolling 90 days.
- **Re-enter the API token where the Keychain no longer answers.** A
  debug build asks under a new service name, so its token is gone. An
  installed release build whose signing identity did not change keeps
  its token; if Settings shows "paste your API token" instead of
  "•••• stored in the Keychain", that is the answer.

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

Cmd+Q or the tray's Quit item. That flushes whatever write is still
pending, so it is the tidiest way to end a session. It is no longer the
only path that saves anything. If the app is unresponsive,
`scripts/quit-app.sh` escalates AppleScript quit to SIGTERM to SIGKILL,
in that order, and says which level it needed. The first level flushes;
the other two lose at most the last couple of seconds of edits.

## Trusting persistence across a quit and reopen

Trust it within a boot session, including for a crash. Content is
sealed to disk (ChaCha20-Poly1305) on every mutation, debounced by
about two seconds, and written atomically. The debounce is measured
from the first edit of a burst rather than the last, so typing steadily
does not defer the write indefinitely, and the app holds off sudden
termination while the buffer is dirty. A crash, a force quit or a
logout therefore costs you one debounce window, not the session.
Restore runs once, on the first reveal after launch.

Across a reboot, expect nothing back. That is the design, not a bug:
half the content key lives in a temp directory the system clears at
boot. See the one-time reset section above for the mechanism.

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
