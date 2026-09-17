# Locked keychain and denied ACL: refusal without erasure or overwrite

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 10, case 6 (unavailable encryption key), and section 7's
binding rule that a failed restore never replaces prior state with empty
state. Every automated test runs against `InMemoryCredentialStore` or a
double (`crates/credentials/src/lib.rs`) and the one real keychain
test is `#[ignore]`d (`crates/credentials/src/lib.rs`), so CI
cannot reach this.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Prerequisite: rebuild and reinstall first

The envelope went `OTSSEAL2` to `OTSSEAL3`
(`crates/ffi/src/persist.rs`) and the ledger payload went
`OTSLEDR1` to `OTSLEDR2` (`crates/core/src/persist.rs`). An
older installed copy cannot read the files this build writes.

```sh
pgrep -fl "\.build/.*OnetimePad"
scripts/install.sh
```

## Which keychain is under test

No build this tree produces carries the keychain access group
entitlement, so the halves are ordinary login keychain items: the
`DefaultFile` add scope sets no `kSecAttrAccessible`
(`crates/credentials/src/lib.rs`), and the lock gate is the
login keychain's own. The item is a generic password with service equal
to the bundle id and account `state-key`
(`crates/ffi/src/persist.rs`; the ledger's is `ledger-key`; the dictionaries are built from `kSecClass`, `kSecAttrService`
and `kSecAttrAccount` alone, `crates/credentials/src/lib.rs`).

```sh
STATE=~/Library/Application\ Support/com.onetimesecret.pad.noindex
LOGIN=~/Library/Keychains/login.keychain-db
security find-generic-password -s com.onetimesecret.pad -a state-key
log stream --style compact --predicate \
  'subsystem == "com.onetimesecret.pad" && (category == "core" || category == "persistence")'
```

## What the code must do in both cases

`load_key_for` loads and never mints
(`crates/ffi/src/persist.rs`). A backend that refuses is logged
as "companion-ffi: the state-key item would not load (...)" and
returns `None`. The key closure then fails inside `open_state`, which
logs "the state file carries this build's envelope, but its content key
could not be assembled" and returns `Opened::Refused`. The
seam maps that to a failed restore and leaves the file exactly where it
is (`crates/ffi/src/lib.rs`). The shell probes the file after the
restore, finds it present, and withholds the save licence
(`shell/Sources/CompanionKit/PageModel.swift`), so nothing is
written over it for the whole session.

## Case 1: the keychain is locked when the app loads

1. With the installed app, create two pages, one with a sealed chip.
   Quit with ⌘Q.
2. Record what must not change:

   ```sh
   ls -la "$STATE"
   shasum -a 256 "$STATE/state.sealed" "$STATE/ledger.sealed"
   ls "$STATE"/ots-companion-key-half-*
   ```

3. Lock the login keychain and confirm it is locked:

   ```sh
   security lock-keychain "$LOGIN"
   security show-keychain-info "$LOGIN"   # reports the keychain is locked
   ```

4. Launch the app. macOS presents the unlock prompt for the login
   keychain. **Cancel it.** Cancelling is the case under test.
5. Type a line on the page that opens, wait past the debounce, then
   press ⌘Q. Confirm the app stays running, no alert or other app-owned
   surface appears, the surface is raised, and a second ember line
   stands under the recovery line: "nothing typed this session is on
   disk, so its pages will not survive the quit" with a "quit anyway
   (⌘Q)" button. Press ⌘Q again. Confirm the app quits without a save
   licence having been granted. Clicking the button instead of the
   second ⌘Q is the same path.
6. Re read the evidence from step 2.

**Pass:**

- The pad opens on one empty page. Nothing crashes and no dialog claims
  data was destroyed.
- The log carries "companion-ffi: the state-key item would not load
  (...)" and then "companion-ffi: the state file carries this build's
  envelope, but its content key could not be assembled ... the file
  stays and this session will not write one".
- The shell logs "restore failed over an existing state file;
  withholding the save licence"
  (`shell/Sources/CompanionKit/PageModel.swift`), and the ledger's
  own line about not recording to the audit trail if the
  ledger key was refused too.
- Both sha256 values are **identical** to step 2, after the typing and
  after the quit. No overwrite.
- `state.sealed`, `ledger.sealed` and the `ots-companion-key-half-<32 hex>`
  file are all still present, with the same names. No erase, and no
  rotation: rotation deletes the keychain half
  (`crates/ffi/src/persist.rs`) and must not run on this path.
- The `state-key` item still exists once the keychain is unlocked.
- The first ⌘Q performs one synchronous flush, cancels termination,
  presents no alert, and puts the quit anyway line under the page
  (`shell/Sources/CompanionKit/QuitPrompt.swift`, called by
  `shell/Sources/OnetimePad/BackdropApp.swift`). The inline recovery
  state remains available beside it. The second ⌘Q quits and leaves
  the unreadable file untouched.

**Fail:** any change to either sha256, a missing file, a missing key
half, a missing keychain item, a superseded disposal line
(`crates/ffi/src/lib.rs`), an alert or other app-owned quit surface, or
⌘Q terminating the unsavable session instead of cancelling it.

7. Recover:

   ```sh
   security unlock-keychain "$LOGIN"
   ```

   Quit and relaunch the app.

**Pass:** both pages come back with their chips, drained by the elapsed
wall clock. The withholding lasted the session and no longer, which is
what ADR-0016 section 7 promises and prices.

## Case 2: the ACL prompt is denied

An unlocked keychain with an item the app may not read is a different
failure with the same required outcome.

1. Unlock the keychain and confirm the app restores normally, so the
   starting state is known good. Quit.
2. Record the sha256 values again as in case 1 step 2.
3. Open Keychain Access, select the login keychain, find the generic
   password whose Name is `com.onetimesecret.pad` and
   whose Account is `state-key`. On the Access Control tab, select
   "Confirm before allowing access" and remove OnetimePad from the list
   of applications that always have access. Save the change.
4. Launch the app. macOS asks whether OnetimePad may use the item.
   **Click Deny.**
5. Type a line, wait past the debounce, quit.
6. Re read the sha256 values and the directory listing.

**Pass:** identical to case 1's pass list. The refusal is logged, the
files are untouched, the key half and the keychain item both survive,
and no rotation ran.

**Fail:** the same list as case 1. In particular, a `state.sealed` that
changed size or hash after a denied prompt is the exact defect this
procedure exists to catch.

7. Relaunch and click Allow, or restore the always allow entry in
   Keychain Access.

**Pass:** the pages come back.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-08-22.

| Date | Machine and macOS | Case | Prompt answered | Pass or fail | Notes |
|---|---|---|---|---|---|
| | | | | | |
