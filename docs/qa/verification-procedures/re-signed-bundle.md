# Re-signed bundle: refusal without erasure, and debug versus release separation

**Applies to:** OnetimePad, installed release bundle and the dev debug
bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 10, case 4 (app update or dev rebuild), and section 7's
unavailable key row. CI runs against an in memory credential store and
cannot reach a real Keychain ACL.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Prerequisite: rebuild and reinstall first

The envelope went `OTSSEAL2` to `OTSSEAL3`
(`crates/ffi/src/persist.rs`) and the ledger payload went
`OTSLEDR1` to `OTSLEDR2` (`crates/core/src/persist.rs`). An
older installed copy cannot read what this build writes.

```sh
pgrep -fl "\.build/.*OnetimePad"
scripts/install.sh
```

Pin `CODESIGN_IDENTITY` in the local environment file
(template: `environments/example/.env.example`) before this run, because
this procedure is about what happens when that identity changes, and an
install that was ad hoc signed to begin with has nothing to change from
(`scripts/install.sh`).

## Where to look

```sh
STATE=~/Library/Application\ Support/dev.onetimesecret.pad.noindex
DEBUG_STATE=~/Library/Application\ Support/dev.onetimesecret.pad.debug.noindex
log stream --style compact --predicate \
  'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"} && (category == "core" || category == "persistence")'
```

The state directory name is the running build's bundle id plus
`.noindex` and the Keychain service is that same id
(`shell/Sources/CompanionKit/FormFactor.swift`), so
the dev lane's own id moves both. The content key is assembled from a
keychain half under account `state-key`
(`crates/ffi/src/persist.rs`) and a file half named
`ots-companion-key-half-<32 hex>` in the state directory.

## Case 1: a different signing identity refuses and erases nothing

The Keychain ACL is derived from the signing identity and the bundle id
(ADR-0012). A bundle signed by someone else is a different caller to
the Keychain, so `load_key_for` gets an error or a denial and returns
`None` (`crates/ffi/src/persist.rs`), the key closure fails, and
`open_state` returns `Opened::Refused` without touching the file
(`crates/ffi/src/persist.rs`). Refusal, not disposal: the
superseded arm is the only destructive one and it fires on a byte string
in `SUPERSEDED_MAGICS`, never on a key failure
(`crates/ffi/src/lib.rs`).

1. With the installed app, create two pages, one with a sealed chip.
   Quit with ⌘Q.
2. Record the evidence that must not change:

   ```sh
   codesign -dv --verbose=4 "/Applications/OnetimePad Local.app" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier'
   ls -la "$STATE"
   shasum -a 256 "$STATE/state.sealed"
   ```

3. Re sign the installed bundle with a different identity. Ad hoc is
   the easiest different identity:

   ```sh
   codesign --force --deep --sign - "/Applications/OnetimePad Local.app"
   codesign --verify --strict "/Applications/OnetimePad Local.app"
   codesign -dv --verbose=4 "/Applications/OnetimePad Local.app" 2>&1 | grep Authority
   ```

   Signing with a second real certificate instead is equally valid and
   closer to the field case; the observable is the same.
4. Launch the app. macOS may present a Keychain prompt asking whether
   the app may use the `state-key` item. **Deny it**, which is the case
   under test; a user faced with an unrecognized app is expected to
   deny.
5. Type a line on the page that opens, wait past the debounce, and press
   ⌘Q. Confirm the app stays running, no alert or other app-owned
   surface appears, and the quit anyway line stands under the recovery
   line. Press ⌘Q again, or click "quit anyway (⌘Q)", and confirm the
   app quits.
6. Re read the evidence from step 2.

**Pass, in this order:**

- The pad opens with one empty page and none of the previous content.
- The log carries a `companion-ffi:` fault naming the assembly failure:
  "the state file carries this build's envelope, but its content key
  could not be assembled. Either the keychain half would not load or the
  file half is missing from the state directory; the file stays and this
  session will not write one" (`crates/ffi/src/persist.rs`).
  When the Keychain answers with an error rather than silence, the
  preceding line is "companion-ffi: the state-key item would not load
  (...)" (`crates/ffi/src/persist.rs`).
- The shell then logs "restore failed over an existing state file;
  withholding the save licence"
  (`shell/Sources/CompanionKit/PageModel.swift`).
- `state.sealed` is still present and its sha256 is **identical** to
  step 2, including after the typing, the cancelled quit and the quit
  anyway: a session without the licence never rewrites the file
  (`shell/Sources/CompanionKit/PageModel.swift`).
- The `ots-companion-key-half-<32 hex>` file is still present and
  unchanged, and the `state-key` keychain item still exists. Nothing
  rotated: rotation has two triggers and a refusal is neither
  (ADR-0016 section 6).
- The first ⌘Q cancels termination and no quit alert appears; the quit
  anyway line stands beside the existing inline recovery state, and the
  second ⌘Q quits.

**Fail:** an erased or rewritten `state.sealed`, a changed sha256, a
missing key half, a missing keychain item, a log line from the
superseded arm (`crates/ffi/src/lib.rs`), an app-owned quit surface, or
⌘Q terminating the unsavable session.

7. Restore the original identity and confirm recovery is real:

   ```sh
   scripts/install.sh
   ```

   With the local lane's `CODESIGN_IDENTITY` back to the pinned value, allow the
   Keychain prompt if one appears.

**Pass:** the two pages from step 1 come back, with their chips, drained
by the elapsed wall clock. That is the whole point of refusing rather
than erasing.

## Case 2: dev and release keep separate state

`package-app.sh --debug` writes the bundle id `dev.onetimesecret.pad.debug`
(`scripts/package-app.sh`), and `resolvedBundleIdentifier` accepts
that identifier and the local lane's `dev.onetimesecret.pad` beside the
App Store id `com.onetimesecret.pad` and nothing else
(`FormFactor.devBundleIdentifier` and `FormFactor.localBundleIdentifier` in
`shell/Sources/CompanionKit/FormFactor.swift`), so the debug copy
resolves its own state directory, its own Keychain service and its own
log subsystem. Two copies that shared them would clobber one another's
`state.sealed` on one debounce.

1. Install and run the release copy. Create a page with recognizable
   text, for example `RELEASE ONE`. Quit.
2. Build and launch the debug copy:

   ```sh
   scripts/dev.sh
   ```

   It packages the debug bundle as `dev.onetimesecret.pad.debug` and launches it
   from `dist/` (`scripts/dev.sh`).
3. In the debug copy, create a page reading `DEBUG ONE`. Quit it.
4. Inspect both directories:

   ```sh
   ls -la "$STATE" "$DEBUG_STATE"
   security find-generic-password -s dev.onetimesecret.pad -a state-key -g 2>&1 | head -3
   security find-generic-password -s dev.onetimesecret.pad.debug -a state-key -g 2>&1 | head -3
   ```

**Pass:** two directories exist, each with its own `state.sealed`, its
own `ledger.sealed` and its own `ots-companion-key-half-<32 hex>` whose
names differ from each other. Two distinct `state-key` items exist, one
per service. Launching the release copy shows `RELEASE ONE` and never
`DEBUG ONE`; launching the debug copy shows the reverse. Neither
launch logs a refusal.

**Fail:** one directory serving both, one page vector visible in both
copies, or a refusal in either copy, which would mean one build opened
the other's file and could not read it.

5. Run both copies at the same time, type in each, quit each, and
   relaunch both. Each must come back with only its own content.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-08-22.

| Date | Machine and macOS | Case | Signing identity used | Pass or fail | Notes |
|---|---|---|---|---|---|
| | | | | | |
