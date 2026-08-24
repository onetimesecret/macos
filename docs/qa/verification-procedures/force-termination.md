# Force termination: what a SIGKILL costs, and what it must not cost

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 10, case 2 (crash and force termination). A process cannot
watch itself be killed, so no test in this repository can reach the
scenario: `kill -9` delivers no signal the app can handle, runs no
`atexit`, and gives the quit flush no chance to run.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

This procedure is the other half of
[`power-loss.md`](power-loss.md), which deliberately refuses `kill -9`
because its case is about a death that also takes the filesystem's
caches. Here the kernel survives, so every byte the app handed to the
filesystem is on disk, and the only thing in question is the debounce
window: the interval between the keystroke and the write it schedules.

## Prerequisite: rebuild and reinstall first

Two format breaks landed with ADR-0016: the envelope went `OTSSEAL2` to
`OTSSEAL3` (`crates/ffi/src/persist.rs:154`, `:176`) and the ledger
payload went `OTSLEDR1` to `OTSLEDR2` (`crates/core/src/persist.rs:111`,
`:127`). An older installed copy cannot read the files this build
writes. Start clean:

```sh
pgrep -fl "\.build/.*OnetimePad"   # nothing should be running from .build/
scripts/install.sh
```

## Where to look

```sh
STATE=~/Library/Application\ Support/com.onetimesecret.companion.backdrop.noindex
ls -la "$STATE"
```

The directory is named for the bundle id plus `.noindex`
(`shell/Sources/CompanionKit/FormFactor.swift:155`, `:214`) and holds
`state.sealed` (`FormFactor.swift:79`), `ledger.sealed` (`:84`) and one
`ots-companion-key-half-<32 hex>` (`crates/ffi/src/persist.rs:232`).

Every write goes to `<name>.<16 hex>.tmp` and is renamed over the real
file (`write_private`, `crates/ffi/src/persist.rs:1251`, the rename at
`:1271`), and launch sweeps whatever a death stranded there
(`sweep_stranded_temps`, `crates/ffi/src/persist.rs:883`). A SIGKILL can
strand one just as a power cut can, so the same observable applies here;
`power-loss.md` case 2 is where the sweep itself is made deterministic.

What decides the loss is the debounce. A keystroke marks the model
dirty, which takes a sudden-termination hold and arms a two second
timer (`shell/Sources/CompanionKit/PageModel.swift:472`, `:932`, `:939`);
the write happens at the timer's far end, and the hold is released only
once the write settles. The hold is real rather than decorative because
the bundle declares `NSSupportsSuddenTermination`
(`shell/OnetimePad-Info.plist`), which is what the latch at
`PageModel.swift:101` exists to take back. A `kill -9` ignores the hold
entirely, which is the point of this case: it prices the window the
latch protects against everything except the one death that cannot be
negotiated with.

The core's refusals reach the unified log through the shell's sink,
subsystem equal to the bundle id, category `core`; the shell's own
persistence lines use category `persistence`:

```sh
log show --last 30m --style compact --predicate \
  'subsystem == "com.onetimesecret.companion.backdrop" && (category == "core" || category == "persistence")'
```

## Case 1: a kill inside the debounce window

The scenario the debounce is a stated tradeoff for: the process dies
between the keystroke and the write it armed.

1. Launch the installed app. Create two pages with ink and one sealed
   chip. Wait five seconds so the debounce has landed, and confirm
   `state.sealed` has a recent mtime. Record that mtime, and record the
   exact text on each page.
2. Type a distinctive line of ink, for example `KILLED MID BURST`, and
   within two seconds of the last keystroke run, from a terminal
   prepared in advance:

   ```sh
   pkill -9 -x OnetimePad
   ```

   The `-x` asks for an exact match on the process name, so nothing
   else whose name merely contains the string is caught, and the absence
   of `-f` keeps the pattern off other processes' arguments. Two seconds
   is the whole window, so have the command typed and waiting before you
   start typing into the app.
3. `ls -la "$STATE"` before relaunching. Record every file present, in
   particular anything matching `*.[0-9a-f]*.tmp`.
4. Launch the app.

**Pass:** both pages are back with the text recorded in step 1 and with
the chip. `state.sealed` is still the generation whose mtime was
recorded in step 1, or a newer one, and is never absent. The line typed
in step 2 is the only thing that may be missing, and losing it is the
documented cost of the debounce rather than a failure. Any temp file
recorded in step 3 is gone after launch. No refusal line appears
(`crates/ffi/src/persist.rs:693`, `:700`, `:707`, `:717`) and no
"restore failed over an existing state file; withholding the save
licence" line appears (`shell/Sources/CompanionKit/PageModel.swift:674`).

**Fail:** an empty pad; content older than the last settled write coming
back, which would mean a generation was lost rather than a burst; a temp
file still present after a launch; any refusal line; or `state.sealed`
gone.

## Case 2: a kill after a settled write, which must cost nothing

The control for case 1. If both cases lose the last line, the debounce
is not what is losing it.

1. From case 1's state, type a second distinctive line, for example
   `SETTLED BEFORE THE KILL`, then stop typing and wait ten seconds.
   Confirm `state.sealed`'s mtime moved.
2. `pkill -9 -x OnetimePad`.
3. Launch the app.

**Pass:** every page is back exactly as it stood, including the line
from step 1. Nothing at all is lost, because nothing was pending.

**Fail:** the settled line missing, which would mean the write the mtime
reports did not contain it, or that the restore read an older
generation.

## Case 3: the same death by two other routes

A SIGKILL from a terminal is the cleanest way to reach this case, but it
is not the way a user reaches it. Repeat case 1 twice more, once by each
route, and record the outcome for each:

1. **Force Quit.** With a line typed and unsettled, open the Force Quit
   window (⌥⌘Esc), select OnetimePad, and press Force Quit. Confirm the
   dialog kills it outright rather than routing through
   `applicationShouldTerminate`, that is, no quit warning appears
   (`shell/Sources/OnetimePad/BackdropApp.swift:123`,
   `shell/Sources/CompanionKit/QuitPrompt.swift:83`). If a warning does
   appear you pressed Quit rather than Force Quit, and this is not the
   case under test.
2. **A rebuild over a live dev instance.** Package and launch the debug
   bundle, type an unsettled line into it, then run
   `swift build --package-path shell` from another terminal. The
   in-place re-sign SIGKILLs the running copy. This shape has its own
   state directory,
   `com.onetimesecret.companion.backdrop.debug.noindex`
   (`shell/Sources/CompanionKit/FormFactor.swift:214`), so check that
   one, and confirm the release copy's directory was not touched.

**Pass, for both:** the same result as case 1. At most the unsettled
burst is gone, the prior generation is intact, and the log carries no
refusal and no restore failure. For the second route, the release
bundle's `state.sealed` mtime is unchanged.

**Fail:** any difference in outcome between the three routes, which
would mean something other than the debounce decides what survives.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-08-23.

| Date | Machine and macOS | Case | Pass or fail | What was lost | Notes |
|---|---|---|---|---|---|
| | | | | | |
