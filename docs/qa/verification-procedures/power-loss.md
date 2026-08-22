# Power loss: what survives, and the temp files launch must sweep

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 1 (the Power loss row) and section 10. No test can cut power to
the machine running it.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Prerequisite: rebuild and reinstall first

Two format breaks landed with ADR-0016: the envelope went `OTSSEAL2` to
`OTSSEAL3` (`crates/ffi/src/persist.rs:154`, `:176`) and the ledger
payload went `OTSLEDR1` to `OTSLEDR2` (`crates/core/src/persist.rs:111`,
`:127`). An older installed copy cannot read the files this build
writes. Start clean:

```sh
pgrep -fl "\.build/.*OnetimePad"
scripts/install.sh
```

## Where to look

```sh
STATE=~/Library/Application\ Support/com.onetimesecret.companion.backdrop.noindex
ls -la "$STATE"
```

The directory is named for the bundle id plus `.noindex`
(`shell/Sources/CompanionKit/FormFactor.swift:154`, `:210`) and holds
`state.sealed`, `ledger.sealed` and one
`ots-companion-key-half-<32 hex>` (`crates/ffi/src/persist.rs:232`).

Every write goes to `<name>.<16 hex>.tmp` and is renamed over the real
file (`crates/ffi/src/persist.rs:1144-1146`, the fsync and rename
sequence in `write_private` at `:1139-1165`). A death between the write and the rename
strands that temp file holding a complete sealed generation, or a
complete copy of a key half.

Launch sweeps them. `companion_persist_restore` calls
`sweep_stranded_temps` on the containing directory before it reads the
state file (`crates/ffi/src/lib.rs:1303`, the sweep at
`crates/ffi/src/persist.rs:840-853`), and it erases each one with the
same discipline the ciphertext gets: zero, truncate, unlink, confirm
absent (`crates/ffi/src/persist.rs:790-816`). The shape is matched
exactly, some name, a dot, sixteen hex digits, `.tmp`
(`crates/ffi/src/persist.rs:856-864`).

Log predicate for the launch that follows the cut:

```sh
log show --last 30m --style compact --predicate \
  'subsystem == "com.onetimesecret.companion.backdrop" && (category == "core" || category == "persistence")'
```

## Case 1: hard power cut mid session

1. Launch the installed app. Create two pages with ink and one sealed
   chip. Wait a few seconds so the debounce has landed a write, then
   confirm `state.sealed` has a recent mtime.
2. Type continuously into a page and, while still typing, cut power.
   On a desktop pull the cord; on a laptop hold the power button until
   the machine dies. Do not use Restart, and do not use `kill -9`: this
   case is about a death that also takes the filesystem's caches with
   it.
3. Power on, log in, and before launching the app, look at the
   directory:

   ```sh
   ls -la "$STATE"
   ```

   Record every file present, in particular anything matching
   `*.[0-9a-f][0-9a-f]*.tmp`. A stranded temp is expected here but not
   guaranteed: the cut has to land inside the window between
   `create_new` and `rename`, which is short. Absence of one is not a
   failure of this case; case 2 covers the sweep deterministically.
4. Launch the app.

**Pass:** the pages are back with their chips, minus at most the last
burst of typing inside the debounce window. Countdowns are shorter by
the wall clock time the machine was off. Any temp file recorded in step
3 is gone from the directory after launch. No refusal line appears
(`crates/ffi/src/persist.rs:666`, `:673`, `:680`, `:690`) and no
"restore failed over an existing state file" line appears
(`shell/Sources/CompanionKit/PageModel.swift:552`).

**Fail:** an empty pad; or a temp file that is still there after a
launch; or a refusal, which would mean the rename landed a file the
next launch could not open.

## Case 2: the sweep itself, made deterministic

The cut in case 1 may not strand anything. This case plants the exact
shapes the sweep is written for and confirms launch removes them, and
confirms it removes nothing else.

1. Quit the app.
2. In the state directory, plant four files and one control:

   ```sh
   printf 'ciphertext' > "$STATE/state.sealed.0123456789abcdef.tmp"
   printf 'audit'      > "$STATE/ledger.sealed.fedcba9876543210.tmp"
   printf 'halfbytes'  > "$STATE/ots-companion-key-half-00112233.00112233445566aa.tmp"
   printf 'keepme'     > "$STATE/state.sealed.notsixteenhex.tmp"
   ls -la "$STATE"
   ```

   The first three match the shape exactly. The fourth does not, and it
   is the control: a sweep that takes it is matching on the `.tmp`
   suffix alone, which is the bug the exact match exists to prevent
   (`crates/ffi/src/persist.rs:828-833`, `:856-864`).
3. Launch the app.
4. `ls -la "$STATE"`.

**Pass:** the three shaped files are gone. `state.sealed.notsixteenhex.tmp`
is still there, untouched. `state.sealed`, `ledger.sealed` and the real
`ots-companion-key-half-<32 hex>` are all still there and the pad
restored normally.

**Fail:** any shaped file surviving, or the control being removed, or
the real state file or the real key half being taken by the sweep,
which would present as an empty pad or as
"companion-ffi: the state file carries this build's envelope, but its
content key could not be assembled" in the log
(`crates/ffi/src/persist.rs:680`).

5. Clean up the control file by hand afterwards.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-08-22.

| Date | Machine and macOS | Case | Pass or fail | Stranded temps observed | Notes |
|---|---|---|---|---|---|
| | | | | | |
