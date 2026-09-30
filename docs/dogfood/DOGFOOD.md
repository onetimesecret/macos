# Dogfooding OnetimePad

This is the guide for running OnetimePad as a real daily tool, not a
dev build you launch from the repo. It replaces the ad hoc habit of
keeping quick snippets in Vivaldi Notes. It is also where operational
guidance lives once it is stable enough to share with other
dogfooders. Raw, surprising, or unresolved observations belong in
[ABERRATIONS.md](ABERRATIONS.md) until they are understood.

## Install and update

```sh
scripts/install.sh
```

Builds the core only if it is stale, builds the app, and installs it
to `/Applications` (override with `APP_DEST`). Running the installed
copy matters for two reasons:

- Rebuilds in the repo never touch it. `swift build` re-signs whatever
  binary is under `.build/`, and a running process whose own signature
  changes gets SIGKILLed by the kernel. `/Applications` is outside that
  blast radius.
- Keychain and TCC grants are tied to code identity. Set
  `LOCAL_CODESIGN_IDENTITY` in `scripts/local.env` (see
  `scripts/local.env.example`) to a stable development certificate. Set
  `LOCAL_PROVISIONING_PROFILE` when the local build must carry the restricted
  entitlements; the packaging preflight checks that the profile authorizes the
  certificate, production bundle identifier, and this Mac.

Re-run `scripts/install.sh` to update. `--no-launch` installs without
opening the app afterward. For a debug build that runs beside the
installed copy, use `scripts/dev.sh`.

## One-time reset when you update to the 0.19.0 build

The bundle identifier changed. The installed app is
`com.onetimesecret.pad` and the dev build is `dev.onetimesecret.pad`;
before this they were `com.onetimesecret.companion.backdrop` and that
string with `.debug` on the end. macOS keys the state directory, the
Keychain items, the keychain access group, the defaults domain and
every TCC grant off the id, so the new build starts from nothing.
Nothing migrates, deliberately. Send or copy out anything you still
need **before** you install.

Where things are now, and where the old ones were left:

- State: `~/Library/Application Support/com.onetimesecret.pad.noindex`
  (dev: `dev.onetimesecret.pad.noindex`). The old
  `com.onetimesecret.companion.backdrop.noindex` and
  `...backdrop.debug.noindex` directories are neither read nor
  deleted; remove them by hand once nothing in them is wanted.
- Keychain: the `state-key`, `ledger-key` and `api-token` items live
  under the service `com.onetimesecret.pad` (dev: `dev.onetimesecret.pad`).
  The first launch creates fresh key items, and Settings shows "paste
  your API token" until you paste it again. The old items under the old
  service names stay in Keychain Access and can be deleted there.
- The user keymap override, if you wrote one, moves with the id: it is
  read from `~/Library/Application Support/com.onetimesecret.pad/keymap.json`
  now (dev: `dev.onetimesecret.pad/keymap.json`). Move the file
  yourself; the app never creates or copies it.
- Defaults, the launch at login registration and any screen recording
  or accessibility grant are under the new id and start unset. Re-grant
  what you use.
- The unified log subsystem is the new id too. Predicates below that
  say `com.onetimesecret.pad` find the installed copy;
  `subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}`
  finds both lanes.

The paths and ids in the two older reset sections below were right for
their builds and are left as written; read them with this one in mind.

## One-time reset when you update to the ADR-0016 build

The sealed envelope takes another version byte, `OTSSEAL2` to
`OTSSEAL3`: the boot session UUID and the monotonic stamp leave the
header, and the whole header is what authenticates the file, so no
existing `state.sealed` can be opened by this build. Whatever is staged
when you install it is gone, once. Send or copy out anything you still
need **before** you install.

Unlike the previous break, the old file does not sit there withholding
your save licence: a `state.sealed` carrying the superseded envelope is
recognised, erased on the spot, and the session writes normally from
there. You lose the pages, not the install.

The ledger file takes the same break, because its records gained a
length prefix (`OTSLEDR1` to `OTSLEDR2`), and the same treatment: the
old `ledger.sealed` is recognised on first launch, erased, and a new
trail starts from there. You lose the retained history, the capped
titles and event records back to the ninety day window, once. Nothing
to clear in Settings.

The second key half also moves, from the per-user temp directory into
the state directory beside `state.sealed`, at mode 0600. That is what
makes content survive a restart at all.

One honest note about the half left behind in the temp directory. This
build never reads it again, and macOS clears that directory at boot, so
it is expected to be gone. Expected is the strongest word available:
nothing here verifies it, and the Keychain half that was its partner is
unchanged by this update and is still in your Keychain. So if someone
took a copy of your old `state.sealed` *and* a copy of that temp half
before you updated, the pair still opens it. Dropping the old file does
not change that either way. If that matters to you, the fix is to
restart the Mac, which clears the directory, before or soon after
installing.

## One-time reset when you updated to the ADR-0012 build

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
- **Staged content is bounded by its TTL and by policy, not by the
  boot session** (ADR-0016, whose own reset section is above).
  This bullet used to read "staged content no longer survives a reboot,
  by design", and that claim is withdrawn rather than quietly dropped.
  The content key is still two halves, one in the Keychain and one in a
  file, but the file half now lives in the state directory at mode 0600
  rather than in the per-user temp directory macOS clears at boot.
  Nothing outlives its TTL, whose ceiling is seven days: a page that
  runs out leaves memory, is not written into the next sealed
  generation, and its death goes in the ledger. Restarting the Mac is no
  longer a clean slate, which is the whole point: accepting a system
  update stops costing you your staged work.

  Be precise about what the key rotation does and does not cover,
  because "rotates" is the word that makes generations already on disk
  unreadable, and it fires in one place only. **Emptying the pad**
  rotates: the last page leaving is what drops the sealed file, and that
  drop erases the file half and deletes the Keychain item, so every
  ciphertext generation this install ever wrote, including the ones a
  rename unlinked and nothing sweeps, stops being decryptable at that
  moment. A page expiring **beside pages that remain** does not rotate,
  and cannot: the file is re-sealed under the same live halves because
  the surviving pages are in it. An explicit content-side Clear does not
  exist yet at all; the ledger has one and content does not. And a
  rotation the filesystem refuses is not silent and not skipped: the app
  keeps the sealed file rather than dropping it, tells you the write
  failed, and tries again.
- **Signed builds carry a new entitlement.** `keychain-access-groups`
  is what the data protection keychain requires, and only a real
  signing identity can carry it. Ad-hoc builds skip it and log a single
  fallback line to the login keychain. The item names did not change,
  so on a stable `LOCAL_CODESIGN_IDENTITY` your Keychain items are still
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
  its token; if the Connection tab of Settings shows "paste your API
  token" instead of "•••• stored in the Keychain", that is the answer.

## Which build am I on

Right-click the tray icon: the version line (disabled, informational)
shows the stamped bundle version next to the core the binary actually
linked against, so a stale `xcframework` shows itself rather than
hiding. The build script appends the short git SHA, with a `.dirty`
marker for an uncommitted tree.

## Launch at login

The General tab of Settings has a toggle backed by
`SMAppService.mainApp`. Only a bundle under `/Applications` can
register, so a dev build never claims the login item by accident. A
refused registration reverts the toggle to whatever the system actually
granted. A login item launch comes up resting, behind every other
window, and opens no editor window, because the system's launch never
activates the app; a launch you perform from the Finder, the Dock,
Spotlight or `open` opens the editor window in front and keyed, with
the roll anchored on today (ADR-0033). The card rests behind it.

## Deadline rounding

The General tab of Settings has "Round a page's deadline up to the
hour, or to midnight", on unless you turn it off, stored as
`snapsToBoundaries` in the app's defaults domain. To exercise it, note
the clock, make a new page, set it to a rung, and read the countdown.

With the toggle on, a rung under a day lands on the next whole local
hour and the 24h, 3d and 7d rungs land on the next local midnight, so
the countdown reads longer than the rung by up to that gap. The
extension is capped at the rung itself or a day, whichever is smaller,
so a 1h rung set at 10:05 runs to 11:00 and a 24h rung set at 4pm runs
to the midnight ending the next day. With it off, the same rung is
exact: a 1h rung set at 10:05 runs to 11:05.

Flipping the toggle changes nothing that already exists. Pages counting
down keep the deadline they were given, and the new setting applies to
the next rung you apply. The timezone read is the one in force when the
rung was applied, so travelling does not move a live deadline either.

## Quitting

Cmd+Q or the tray's Quit item. That flushes whatever write is still
pending, so it is the tidiest way to end a session. It is no longer the
only path that saves anything. If the app is unresponsive,
`scripts/quit-app.sh` escalates AppleScript quit to SIGTERM to SIGKILL,
in that order, and says which level it needed. The first level flushes;
the other two lose at most the last couple of seconds of edits.

## Trusting persistence across a quit and reopen

Trust it, including across a crash and across a restart. Content is
sealed to disk (ChaCha20-Poly1305) on every mutation, debounced by
about two seconds, and written atomically. The debounce is measured
from the first edit of a burst rather than the last, so typing steadily
does not defer the write indefinitely, and the app holds off sudden
termination while the buffer is dirty. A crash, a force quit or a
logout therefore costs you one debounce window, not the session.
Restore runs once, on the first reveal after launch.

Across a reboot, expect your unexpired pages back, with less time on
them: the countdown is charged the wall-clock gap between the last save
and the next launch, and a page that came due while you were away
expires into the ledger at that first launch rather than reappearing.
A page that was held keeps its hold, and the gap shortens the hold
before it reaches the countdown. Nothing outlives its TTL, and the
ceiling is seven days.

Quit performs one synchronous state flush and presents no alert. If the
flush is refused, or the session has content under a withheld save
licence, the first ⌘Q is cancelled and an ember line under the page says
what the quit would lose, with a "quit anyway (⌘Q)" button beside it;
the existing inline save or recovery state remains above it. A second
⌘Q, or the button, quits. A restore failure at
launch also logs to the unified log under the `persistence` category and
withholds that session's ability to overwrite the existing file. See
[ABERRATIONS.md](ABERRATIONS.md) for the historical investigation.

When a page does not come back, the whole story is in the unified log,
however the app was launched:

```bash
log show --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}' --last 1h --style compact
```

Two categories answer two different questions. `persistence` is the
shell's: a restore failed, a save was refused, the licence was
withheld. `core` is why: the step that refused, named. A key half that
would not load, a file that would not authenticate under the key this
session holds, a snapshot the core would not take back, a key half that
could not be erased so the sealed file was kept rather than dropped, or
a Keychain item that outlived the rotation meant to remove it. Metadata
only, and deliberately not redacted: no page content and no key
material passes here, so there is nothing in these lines to hide from
the person reading them.

The core's half used to reach stderr only, which meant it reached
nobody: an app macOS launches for you has no stderr. Running the
binary from a terminal still shows those lines as they happen, and is
still the fastest loop while you are working on the core:

```bash
osascript -e 'tell application "/Applications/OnetimePad.app" to quit'
/Applications/OnetimePad.app/Contents/MacOS/OnetimePad
```

Reach for `log show` for the launch you cannot reproduce, and the
terminal for the one you can.

## Recording what you find

Day-to-day surprises go in [ABERRATIONS.md](ABERRATIONS.md) first.
Record the date, what happened, and the smallest reproduction you can
provide. Then graduate the observation when its disposition is clear:

- **ADR** under `docs/adr/` for a durable decision or security
  tradeoff.
- **GitHub issue** for reproducible incorrect behavior or
  implementation work.
- **Plan** under `docs/plans/` for a milestone-scoped sequence of work.
- **This document** for operational guidance other dogfooders need.

Link the graduated record from the original aberration. Do not delete
the original observation.

## Notes carried here that are not yet graduated

These two came in through this guide rather than through
[ABERRATIONS.md](ABERRATIONS.md), and other documents cite this file as
their origin, so they stay here until they graduate. New observations
go in ABERRATIONS.md.

It might be interesting to track block versions. So if I go back a
couple days later and fix spelling or add another sentence etc, right
now we update the modified time so the block timestamp, created to
modified, is updated. If we kept track of versions of a block that
block timestamp could be a clickable element that reveals the versions.

When it loses focus and switches to backdrop UI, it should blend in a
bit better and also blur the content slightly so that it's not readily
visible. This should be a 0-100 types setting, along with opacity.
