# Clock stepped back: a page ages by zero, never by less

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0016](../../adr/0016-content-persists-across-restart.md)
section 4 (aging across a restart, on two clocks) and section 10, case
7. The arithmetic is already pinned automatically:
`crates/core/src/persist.rs`, `a_backwards_wall_clock_grants_no_extra_life`
(the `saturating_sub` at `crates/core/src/persist.rs`) proves a
backward gap reads as zero rather than as a credit, and
`time_away_drains_the_countdown` proves a forward one drains. So this
procedure is belt and braces, and its rationale is honest about that:
what it adds is the real system clock, reached through the seam and the
shell on a real machine, rather than a number handed to `restore` by a
test. It is the one clock the automated tests are not allowed to touch.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Warning, and the way back

Stepping the system clock is destructive to software that is not under
test. Expect certificate and TLS failures, calendar and reminder
misfires, Time Machine and backup software behaving oddly, and any app
holding a token to consider it expired or not yet valid. Do this on a
machine you can afford to have confused for a few minutes, close what
you can first, and treat the restore step at the end as part of the
procedure rather than as cleanup. Read the whole procedure before
starting so the restore is not the step you improvise.

Two more consequences to expect rather than report as failures:

- While the clock is back a day, anything that writes a timestamp
  writes a wrong one. That includes this app: a save made under the
  fabricated clock stamps the file a day in the past.
- Therefore, once the true time is restored, the next launch reads a gap
  of about a day and drains every page by it, which is correct behaviour
  and will expire short rung pages into the ledger. Step 5 of case 1
  says what to do about it.

## Prerequisite: rebuild and reinstall first

Two format breaks landed with ADR-0016: the envelope went `OTSSEAL2` to
`OTSSEAL3` (`crates/ffi/src/persist.rs`) and the ledger
payload went `OTSLEDR1` to `OTSLEDR2` (`crates/core/src/persist.rs`). An older installed copy cannot read the files this build
writes. Start clean:

```sh
pgrep -fl "\.build/.*OnetimePad"   # nothing should be running from .build/
scripts/install.sh
```

## Where to look

```sh
STATE=~/Library/Application\ Support/dev.onetimesecret.pad.noindex
ls -la "$STATE"
```

The directory is named for the bundle id plus `.noindex`
(`shell/Sources/CompanionKit/FormFactor.swift`). The number
this procedure moves lives in the sealed file's authenticated header:
`sealed_wall_ms`, the wall clock reading at the last save. Restore
computes `away = wall_now.saturating_sub(sealed_wall_ms)` and subtracts
it, and that is the only place in the lifetime math that reads the
calendar clock at all (ADR-0016 section 4). Every interval a running
process observes is charged on the sleep-inclusive monotonic clock
instead (`crates/core/src/clock.rs`), which is not settable, which is
what case 2 below is for.

Record the current time source before touching anything, so the restore
puts back what was there:

```sh
sudo systemsetup -getusingnetworktime
sudo systemsetup -getnetworktimeserver
date
```

The log predicate, for the launches this procedure makes:

```sh
log show --last 30m --style compact --predicate \
  'subsystem == "dev.onetimesecret.pad" && (category == "core" || category == "persistence")'
```

## Case 1: a day backwards across a quit and relaunch

1. Launch the installed app. Create two pages with ink, one of them
   holding a sealed chip. Put both on the 3d or 7d rung, by clicking the
   tab's TTL label to step the ladder or from the tab's context menu
   (`shell/Sources/CompanionKit/TabStripView.swift`,
   `crates/core/src/ttl.rs`), so the fabricated gap in step 5 cannot
   expire them out from under the observation. Note each page's
   remaining time as spoken or shown, to the minute.
2. Quit with ⌘Q and let the quit flush run, so the file carries a stamp
   from the true clock. Confirm `state.sealed`'s mtime is current.
3. Turn off automatic time and step the clock back one day. The date
   format is `mmddHHMMyy`, so put yesterday's date and roughly the
   current time in it:

   ```sh
   sudo systemsetup -setusingnetworktime off
   sudo date "$(date -v-1d +%m%d%H%M%y)"
   date                     # confirm it reads a day earlier
   ```

   Check what `date` prints before continuing. Typing the argument by
   hand instead is easy to get wrong: the format is `mmddHHMMyy`, and a
   slip lands the machine in a different year, which is a much larger
   step than this case is about, though the expected result is the same.
4. Launch the app.

**Pass:** both pages are back with their ink and the chip, and each
one's remaining time is the value recorded in step 1, unchanged to
within the couple of minutes the procedure itself took. The page aged by
zero. No countdown grew, no page came back with more life than its rung
allows, and nothing was revived out of the ledger. No refusal line
appears (`crates/ffi/src/persist.rs`) and no
"restore failed over an existing state file; withholding the save
licence" line appears (`shell/Sources/CompanionKit/PageModel.swift`).

**Fail:** any page whose remaining time went **up**, which is the
never-rewind invariant of ADR-0016 section 4 broken and the reason this
case exists; a countdown showing a negative or absurd value; a page
gone; or a refusal.

5. Restore the true time, then deal with the fabricated gap:

   ```sh
   sudo systemsetup -setusingnetworktime on
   date                     # confirm it reads correctly again
   ```

   If the app wrote at any point while the clock was wrong, the next
   launch will drain every page by about a day. That is correct, and it
   is why step 1 asked for a long rung. Confirm it happens rather than
   being surprised by it: the pages come back a day shorter, and any
   page that ran out lands in the ledger.

## Case 2: a step back mid session buys nothing

Section 4's first bullet: inside a running session the countdown is
charged on a monotonic clock that no `date` call can move
(`crates/core/src/clock.rs`). This case is a minute's work and it is
the one that would catch a regression that put the calendar clock back
into the live timer.

1. With the app running and a page on a short rung, note its remaining
   time.
2. Without quitting, step the clock back an hour:

   ```sh
   sudo systemsetup -setusingnetworktime off
   sudo date $(date -v-1H +%m%d%H%M%y)
   ```

3. Watch the page's countdown for a minute.

**Pass:** the countdown keeps draining at real speed. It does not jump
forward by an hour, does not stall, and does not gain life. A page whose
expiry was due during that minute still expires into the ledger on time.

**Fail:** any jump, stall or gain, which would mean the live timer reads
the calendar clock.

4. Restore the true time as in case 1 step 5.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-08-23.

| Date | Machine and macOS | Case | Pass or fail | Remaining time before and after | Notes |
|---|---|---|---|---|---|
| | | | | | |
