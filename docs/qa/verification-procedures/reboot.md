# Reboot: content survives, rotation fires, a hold comes back held

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 10, case 3 (macOS restart). CI cannot reach a real reboot.
**Owner:** delano.
**Status:** open. Case 1 passed on hardware 2026-08-22; cases 2 and 3
not yet run.

## Prerequisite: rebuild and reinstall first

Two format breaks landed with ADR-0016. The sealed envelope went
`OTSSEAL2` to `OTSSEAL3` (`crates/ffi/src/persist.rs:154`, superseded
set at `:176`) and the ledger payload went `OTSLEDR1` to `OTSLEDR2`
(`crates/core/src/persist.rs:111`, superseded set at `:127`). An older
installed copy cannot read the files this build writes, and this build
disposes of the files that copy wrote. So the run starts from a fresh
install:

```sh
pgrep -fl "\.build/.*OnetimePad"   # nothing should be running from .build/
scripts/install.sh
```

`scripts/install.sh` builds the core, packages the release bundle, asks
a running installed copy to quit gracefully, and installs to
`/Applications/OnetimePad.app`. Pin `CODESIGN_IDENTITY` in
`scripts/local.env` first, or every reinstall resets the Keychain
confirmations this procedure depends on.

## Where to look

The state directory is the form factor's bundle id plus `.noindex`
under Application Support (`shell/Sources/CompanionKit/FormFactor.swift:197`,
`:210`; the release id is at `:154`):

```sh
STATE=~/Library/Application\ Support/com.onetimesecret.companion.backdrop.noindex
ls -la "$STATE"
```

Expect `state.sealed` (`shell/Sources/CompanionKit/FormFactor.swift:79`,
named `STATE_FILE_NAME` in `crates/ffi/src/persist.rs:901`),
`ledger.sealed` (`FormFactor.swift:84`), and one file half named
`ots-companion-key-half-` followed by 32 hex digits
(`crates/ffi/src/persist.rs:232`, `:451`).

The core's refusals reach the unified log through the shell's sink,
subsystem equal to the bundle id, category `core`
(`shell/Sources/CompanionKit/CoreDiagnostics.swift:57`,
`shell/Sources/CompanionKit/PageModel.swift:511`); the shell's own
persistence lines use category `persistence` (`PageModel.swift:520`).
Watch both:

```sh
log stream --style compact --predicate \
  'subsystem == "com.onetimesecret.companion.backdrop" && (category == "core" || category == "persistence")'
```

After the fact, the same predicate under
`log show --last 30m --style compact`.

## Case 1: a real reboot with a live pad

1. Launch the installed app. Create three pages: one with plain ink,
   one holding a sealed chip, one on a short rung. Note each page's
   title and its remaining time.
2. `ls -la "$STATE"` and record the file half's full name and
   `state.sealed`'s size and mtime.
3. Reboot from the Apple menu. Let macOS quit the app; do not force
   quit it.
4. Log back in and launch the app.

**Pass:** all three pages are back with their chips. Each countdown is
shorter by roughly the wall clock time the machine was away, and by no
more than that. No line in the log says the restore failed
(`PageModel.swift:615`, "restore failed over an existing state file;
withholding the save licence"), and no `companion-ffi:` fault appears.
`state.sealed` and the same file half are still in the state directory,
and the half's name is unchanged, because nothing rotated.

**Fail:** an empty pad, or a countdown that moved by something other
than the elapsed wall clock, or any of the four refusal lines from
`crates/ffi/src/persist.rs:666`, `:673`, `:680`, `:690` in the log.

## Case 2: a reboot with the pad emptied first, confirming rotation ran

Rotation now has two triggers and only two (ADR-0016 section 6). This
tests the first: the pad empties. Emptying it drops the state file
through `companion_persist_erase`, which rotates both halves before it
erases (`crates/ffi/src/lib.rs:1479-1480`, `crates/ffi/src/persist.rs:355-370`,
`erase_file_halves` at `:393`).

1. Start from case 1's install, with pages present.
2. Record the current file half name and the keychain half. The
   keychain item is a generic password under service equal to the
   bundle id and account `state-key`
   (`crates/ffi/src/persist.rs:186`):

   ```sh
   ls "$STATE"/ots-companion-key-half-*
   security find-generic-password -s com.onetimesecret.companion.backdrop -a state-key -w
   ```

   The second command may prompt for keychain access. Allow it once;
   the prompt is the ACL working, not a failure.
3. Close every page so no tab holds a page.
4. Quit with ⌘Q, so the quit flush runs
   (`shell/Sources/OnetimePad/BackdropApp.swift:123-134`).
5. `ls -la "$STATE"` again.

   **Pass at this point:** `state.sealed` is gone, no
   `ots-companion-key-half-*` file remains, and
   `security find-generic-password` for `state-key` reports the item is
   not found. `ledger.sealed` is untouched: a ledger clear is a
   different gesture under a different key
   (`crates/ffi/src/persist.rs:196`, `crates/ffi/src/persist.rs:867` on
   why the drop decides from the path).

   **Fail:** either half still present, or the log carries
   "companion-ffi: the content file was left alone because its file
   half could not be erased" (`crates/ffi/src/lib.rs:1490`) or
   "companion-ffi: the rotation erased the file half but could not
   delete the state-key item" (`crates/ffi/src/persist.rs:364`).
6. Reboot. Log back in, launch the app, type one line on the fresh
   page, and wait past the debounce.
7. `ls "$STATE"` once more.

**Pass:** a file half exists again and its 32 hex digit name is
different from the one recorded in step 2, and
`security find-generic-password` finds a `state-key` item again whose
value differs from the one recorded in step 2. That pair of differences
is the whole observable of rotation; nothing logs on the success path.

**Fail:** the same half name comes back, which would mean the keychain
half survived the rotation, since the name is derived from it
(`crates/ffi/src/persist.rs:451-460`).

## Case 3: a reboot with a page paused, confirming it returns paused

A hold takes the gap first, and only the part of the gap beyond the
hold reaches the countdown (ADR-0016 section 4).

1. With a live pad, double click a tab to hold that page's clock at 1h
   (`shell/Sources/CompanionKit/TabStripView.swift:189`,
   `shell/Sources/CompanionKit/PageModel.swift:1485`). The tab shows
   the ⏸1h marking.
2. Note the held page's frozen remaining time and a second, unheld
   page's remaining time.
3. Reboot and come back inside the hold, that is, in well under an
   hour.

**Pass:** the held page is still held, still showing ⏸, and its frozen
remaining time is unchanged. The unheld page has drained by the gap.

4. Repeat with a gap longer than the hold: hold at 1h, reboot, and come
   back more than an hour later.

**Pass:** the page is no longer held and has drained by the excess
beyond the hold only, not by the whole gap.

**Fail:** a held page that comes back counting down, or a held page
whose frozen time moved, or a page that drained by the full gap despite
the hold.

## Results

Record each run below, one row per case, and keep the rows.

| Date | Machine and macOS | Case | Pass or fail | Notes |
|---|---|---|---|---|
| 2026-08-22 | Mac14,6, macOS 27.0 (26A5416b) | 1 | Pass | Run by hand after a rebuild and reinstall. Two pages, both came back with content exact after the restart. No restore failure or refusal lines. Cases 2 and 3 still to run. |
