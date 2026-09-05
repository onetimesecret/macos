# Grace snap on the real zone, and undo across the two boundaries that erase it

**Applies to:** OnetimePad, installed release bundle.
**Required by:** [ADR-0011](../../adr/0011-ttl-choices.md) section 4
(the boundary snap, and its own consequences list, which names
"timezone changes and both daylight-saving transitions" as the risk),
issue #146, and issue #132 with
[ADR-0025](../../adr/0025-block-revision-history.md) for undo. The
arithmetic is already pinned automatically: every case below has a
unit test in `crates/core/src/ttl.rs` that hands `graced_life`
(`crates/core/src/ttl.rs:156`) a synthetic offset function, including
`across_spring_forward_the_bound_is_elapsed_time`
(`crates/core/src/ttl.rs:475`),
`across_fall_back_a_repeated_hour_counts_once`
(`crates/core/src/ttl.rs:506`),
`a_boundary_the_wall_clock_skips_is_never_chosen`
(`crates/core/src/ttl.rs:527`) and
`the_zone_at_application_time_is_the_one_that_counts`
(`crates/core/src/ttl.rs:550`). So this procedure is belt and braces
in the same way [`clock-step-back.md`](clock-step-back.md) is, and its
rationale is the same: what it adds is the real zone database, reached
through `localtime_r` (`crates/core/src/clock.rs:100`) on a real
machine, rather than a table a test wrote. `local_offset_seconds_at`
is the only call in the lifetime math that consults the zone database
at all, and no automated test is allowed to move the machine zone.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Warning, and the way back

Cases B and C step the system clock, so everything
[`clock-step-back.md`](clock-step-back.md) warns about applies here
unchanged: certificates, calendars, backup software and any app
holding a token will misbehave, and any save the app makes under the
fabricated clock stamps a file with a wrong `sealed_wall_ms`, which
the next honest launch reads as a gap and drains every page by. Read
that procedure's warning section before starting this one, and treat
the restore steps at the end of each case as part of the procedure
rather than as cleanup.

Case A changes the machine's time zone, which is milder but not free:
calendar events re-label themselves, and anything caching a formatted
time shows the old one until it refreshes.

Record the state to put back, before touching anything:

```sh
sudo systemsetup -gettimezone
sudo systemsetup -getusingnetworktime
sudo systemsetup -getnetworktimeserver
date
```

## Prerequisite

Run from the installed release bundle, not from `.build/`, and
install fresh so the sealed format matches:

```sh
pgrep -fl "\.build/.*OnetimePad"   # nothing should be running from .build/
scripts/install.sh
```

The snap must be on. Settings, the section headed "A rung names a
duration; this lets the deadline land where the clock does"
(`shell/Sources/CompanionKit/SettingsSections.swift:122`), toggle
"Round a page's deadline up to the hour, or to midnight". It defaults
to on (`shell/Sources/CompanionKit/PageModel.swift:825`) and is
carried to the core by `companion_set_grace_snap`
(`crates/ffi/src/lib.rs:2229`).

## What the code actually promises, so the expectations below are not guesses

- The snap runs **once**, when a rung is applied to a page, in
  `SheetStore::life_for` (`crates/core/src/store.rs:275`). It asks
  `graced_life` (`crates/core/src/ttl.rs:156`) for a **duration**, and
  the store immediately turns that into a monotonic deadline
  (`now + life`, `crates/core/src/store.rs:352`).
- Therefore the stored deadline is an **instant**, not a wall-clock
  label. A later zone change or daylight-saving transition
  recalculates nothing (ADR-0011 section 4, lines 119 to 121; the doc
  comment at `crates/core/src/ttl.rs:145`).
- Every subtraction inside `graced_life` and `next_boundary_ms`
  (`crates/core/src/ttl.rs:185`) is between Unix instants, so the
  extension bound is **elapsed time**, never a difference of wall
  clock labels. The extension may be at most the smaller of a day and
  the rung (`Ttl::max_extension`, `crates/core/src/ttl.rs:88`), which
  is also what bounds a restored page's claimed life
  (`Ttl::longest_life`, `crates/core/src/ttl.rs:83`, used by restore
  at `crates/core/src/persist.rs:896`).
- The surface shows **remaining time**, in words and as the tab gauge
  (`shell/Sources/CompanionKit/TabStripView.swift:473`). There is no
  absolute deadline label anywhere, so the effective deadline is
  observed as "the local wall clock now, plus the remaining time
  shown".
- Undo is the core's stack, bound to the document's peer id
  (`crates/core/src/document.rs:130`), reached through
  `SheetStore::undo` (`crates/core/src/store.rs:923`),
  `companion_sheet_undo` (`crates/ffi/src/lib.rs:1032`) and
  `PageModel.undoEdit` (`shell/Sources/CompanionKit/PageModel.swift:2531`).
  `canUndo` is what greys the Edit menu
  (`shell/Sources/CompanionKit/PageModel.swift:282`).
- Undo **does not survive a relaunch, by design**. Every construction
  path binds a fresh stack to a freshly minted peer
  (`crates/core/src/document.rs:156`, and the comment at
  `crates/core/src/document.rs:189`), and restore reads a snapshot
  into a document minted by that function
  (`crates/core/src/document.rs:398`).
- Undo **does not survive compaction** either: the ceremony rebuilds
  the body into a fresh document and then calls `forget_undo`
  explicitly (`crates/core/src/document.rs:686`,
  `crates/core/src/document.rs:286`), because the rebuild is itself
  typed in as local operations and would otherwise leave one step that
  undoes the whole page to nothing.
- What triggers compaction **today** is a rung transition
  (`crates/core/src/store.rs:1750`) and a pause top-up, which is the
  second press of the pause cycle (`crates/core/src/store.rs:1807`),
  both through `Sheet::compact_or_defer`
  (`crates/core/src/sheet.rs:496`). There is no size-budget trigger
  and no timer in the shipped code: ADR-0025 section 2 proposes moving
  the schedule to a deliberate shed plus a size budget, and it is
  still **proposed**, so case E uses the rung click.

The log predicate for the launches these cases make:

```sh
log show --last 30m --style compact --predicate \
  'subsystem == "com.onetimesecret.companion.backdrop" && (category == "core" || category == "persistence")'
```

## Case A: a zone change moves no deadline already set

Exercises `SheetStore::life_for` (`crates/core/src/store.rs:275`) and
`Clock::local_offset_seconds_at`
(`crates/core/src/clock.rs:88` on to `crates/core/src/clock.rs:100`).
The automated analogue is
`the_zone_at_application_time_is_the_one_that_counts`
(`crates/core/src/ttl.rs:550`).

1. With automatic time on and the machine in its usual zone, set the
   zone explicitly so the arithmetic is known:

   ```sh
   sudo systemsetup -settimezone America/Los_Angeles
   date
   ```

2. Launch the installed app. Create page **P24** and put it on the
   **24h** rung by clicking the tab's TTL label
   (`shell/Sources/CompanionKit/TabStripView.swift`). Create page
   **P1** on the **1h** rung.
3. Note the local wall clock to the minute, and each page's remaining
   time as shown. Compute the effective deadline for each: wall clock
   plus remaining. **P24**'s should land on a local midnight and
   **P1**'s on a whole local hour.
4. Without quitting, change the zone forward by a whole hour and a
   half hour, in two steps, so both a whole-hour and a half-hour
   offset difference are covered:

   ```sh
   sudo systemsetup -settimezone America/Denver     # +1h from LA
   date
   sudo systemsetup -settimezone Asia/Kolkata       # a half hour offset
   date
   ```

5. Read each page's remaining time again after each change.
6. Create a third page **P24b** on the 24h rung while in
   `Asia/Kolkata`, and note its remaining time.

**Pass:**

- **P24** and **P1** show the **same remaining time** after each zone
  change as they did in step 3, allowing for the minutes the procedure
  itself took. The deadline followed the **instant**, not the wall
  clock label.
- Consequently their effective deadlines now read at a **shifted local
  label**: in Denver, **P24** expires at 01:00 rather than midnight;
  in Kolkata it expires at a half-hour past some hour. This is correct
  and is what ADR-0011 section 4 chose. It is not a defect to report.
- **P24b**, applied after the change, snaps to **midnight in
  `Asia/Kolkata`**: its remaining time plus the current Kolkata wall
  clock lands on 00:00 local.

**Fail:** any page created before a zone change whose remaining time
**jumped** by the offset difference, which would mean something
recalculated a stored deadline against the new zone; or **P24b**
snapping to a boundary in the old zone, which would mean
`local_offset_seconds_at` is not reaching the zone database.

7. Cleanup: put the zone back.

   ```sh
   sudo systemsetup -settimezone <the zone recorded at the top>
   date
   ```

## Case B: spring forward, where the wall clock skips an hour

Exercises the skipped-label branch of `next_boundary_ms`
(`crates/core/src/ttl.rs:185`, the `here > offset && reading > label`
arm of `strikes`). The automated analogue is
`across_spring_forward_the_bound_is_elapsed_time`
(`crates/core/src/ttl.rs:475`), whose numbers this case reuses
directly, which is why the zone must be `America/Los_Angeles`.

The clock is moved with the same method
[`clock-step-back.md`](clock-step-back.md) uses: automatic time off,
then `sudo date` with the `mmddHHMMyy` format. Check what `date`
prints after every set. A typo lands the machine in a different year.

1. Quit the app with ⌘Q and let the quit flush run.
2. Set the zone and fabricate the clock to **2026-03-08 01:00 PST**,
   one hour before Los Angeles springs forward:

   ```sh
   sudo systemsetup -settimezone America/Los_Angeles
   sudo systemsetup -setusingnetworktime off
   sudo date 0308010026
   date                     # must read Sun Mar  8 01:00 PST 2026
   ```

3. Launch the app. Create page **S1** and put it on the **1h** rung.
   Note its remaining time.
4. Quit, set the clock to **01:30 PST** (`sudo date 0308013026`),
   relaunch, create page **S1b** on the **1h** rung, and note its
   remaining time.
5. Quit, set the clock to **2026-03-07 16:00 PST**
   (`sudo date 0307160026`), relaunch, create page **S24** on the
   **24h** rung, and note its remaining time.

**Pass:**

- **S1**, applied at 01:00 PST: remaining reads **1h**, no extension
  at all. Its nominal deadline is the label 02:00, which no clock
  shows; the boundary chosen is the transition instant itself, the
  moment the clock reads 03:00 PDT.
- **S1b**, applied at 01:30 PST: remaining reads **1h 30m**. Nominal
  is the label 03:30 PDT, and the next whole clock hour is 04:00 PDT,
  thirty elapsed minutes on. The extension is measured on the wire,
  not by subtracting 04:00 from 01:30.
- **S24**, applied Saturday 16:00 PST: remaining reads **31h**.
  Nominal is Sunday 16:00 PDT, which is twenty three elapsed hours
  later on the wall but exactly twenty four by the clock, and the snap
  is to Monday's midnight PDT, eight elapsed hours on, inside the
  one-day bound.

**Fail:** a page whose remaining time is expressed as the difference
of two wall-clock labels, which shows up here as **S24** reading 32h
or **S1b** reading 2h 30m; any page whose deadline lands on the label
02:xx that the wall clock skipped; a remaining time exceeding
`longest_life` for its rung (2h for the 1h rung, 2d for the 24h rung,
`crates/core/src/ttl.rs:83`); or a deadline that never arrives.

6. Cleanup: restore the true time, then expect the drain.

   ```sh
   sudo systemsetup -setusingnetworktime on
   date
   ```

   The next launch reads a gap of months and drains every page created
   under the fabricated clock into the ledger. That is correct
   behaviour (`crates/core/src/persist.rs`, the restore gap
   arithmetic) and is why this case creates throwaway pages with no
   ink worth keeping.

## Case C: fall back, where the wall clock repeats an hour

Exercises the first-occurrence rule in `next_boundary_ms`
(`crates/core/src/ttl.rs:185`). The automated analogue is
`across_fall_back_a_repeated_hour_counts_once`
(`crates/core/src/ttl.rs:506`).

1. Quit the app. Fabricate the clock to **2026-10-31 18:20 PDT**:

   ```sh
   sudo systemsetup -settimezone America/Los_Angeles
   sudo systemsetup -setusingnetworktime off
   sudo date 1031182026
   date
   ```

   Los Angeles goes back from 02:00 PDT to 01:00 PST early on
   2026-11-01.

2. Launch. Create page **F8** on the **8h** rung. Note its remaining
   time.
3. Quit, set the clock to **2026-10-31 16:00 PDT**
   (`sudo date 1031160026`), relaunch, create page **F24** on the
   **24h** rung, and note its remaining time.

**Pass:**

- **F8**, applied 18:20 PDT: remaining reads **8h 40m**. Nominal is
  02:20 by elapsed time, which the wall labels 01:20 PST inside the
  repeated hour, and the next whole clock hour is 02:00 PST, forty
  elapsed minutes on. The snap does **not** stretch to the hour after
  it.
- **F24**, applied Saturday 16:00 PDT: remaining reads **33h**.
  Nominal is Sunday 15:00 PST, which is twenty five elapsed hours
  after the previous 16:00 label and twenty four after application,
  and the snap is to Monday's midnight PST, nine elapsed hours on.

**Fail:** **F8** reading 9h 40m, which would mean the repeated hour
was counted twice; **F24** reading 32h, which would mean the label
arithmetic won over the elapsed arithmetic; a deadline landing on the
**second** occurrence of a repeated label; or any remaining time past
`longest_life`.

4. Cleanup: as case B step 6.

## Case D: undo does not survive a relaunch, and says so

Exercises `SheetDocument::new` (`crates/core/src/document.rs:156`, and
the comment at `crates/core/src/document.rs:189`),
`SheetDocument::import_snapshot`
(`crates/core/src/document.rs:398`), `SheetStore::can_undo`
(`crates/core/src/store.rs:949`) and the Edit menu binding at
`shell/Sources/CompanionKit/PageModel.swift:2543`.

No clock work in this case, so it can be run first, on an honest
machine.

1. Launch the app. Create a page and type three distinct bursts, with
   a pause of a few seconds between each so they cannot merge into one
   step (`UNDO_MERGE_INTERVAL_MS`, `crates/core/src/document.rs:59`):
   `alpha`, then `bravo`, then `charlie`.
2. Press ⌘Z once. The page should read `alpha bravo` in whatever
   spacing was typed, and Edit ▸ Undo should still be enabled.
3. Confirm the depth by eye: Edit ▸ Undo enabled means at least one
   more step is reachable.
4. Quit with ⌘Q and let the quit flush run.
5. Relaunch.

**Pass:** the page comes back with exactly the text that was standing
at quit, `alpha bravo`, with `charlie` gone and **not** recoverable.
Edit ▸ Undo is **greyed out**, and ⌘Z does nothing. Edit ▸ Redo is
greyed out too: the `charlie` that was undone before the quit cannot
be put back.

**Fail:** Undo enabled after relaunch; ⌘Z taking back text that
predates the relaunch; or `charlie` reappearing, which would mean the
restored document carried a live stack into a rebound peer.

6. Cleanup: none. Discard the page if it is in the way.

## Case E: undo does not survive compaction either

Exercises `Sheet::compact` (`crates/core/src/sheet.rs:473`),
`SheetDocument::compact` (`crates/core/src/document.rs:643`) and its
explicit `forget_undo` at `crates/core/src/document.rs:686`, reached
from the rung transition at `crates/core/src/store.rs:1750` through
`Sheet::compact_or_defer` (`crates/core/src/sheet.rs:496`).

Compaction has no dogfood hook and no threshold to wait for. On a solo
page, with no peer attached, the two gestures that run the ceremony
inline are a **rung transition** and a **pause top-up**. Both are one
click, so this case does both. ADR-0025 section 2 proposes replacing
this schedule with a deliberate "shed history now" control and a size
budget; that ADR is **proposed**, not accepted, so nothing in the
shipped build offers it and this case must not look for it.

1. Launch the app. Create a page on the **24h** rung and type three
   bursts as in case D, pausing between each: `alpha`, `bravo`,
   `charlie`.
2. Press ⌘Z once. The page reads `alpha bravo`. Edit ▸ Undo is
   enabled.
3. Click the tab's TTL label once to step the rung. The transition is
   accepted and the ceremony runs on the same click.
4. Look at the page and at the Edit menu.

**Pass:** the page's text is **unchanged**, `alpha bravo`, with its
chip if it had one. Edit ▸ Undo and Edit ▸ Redo are both **greyed
out**: the ceremony destroyed the operations any step pointed into,
and the rebuild's own operations, which would otherwise stand as a
single step that undoes the whole page to nothing, went with them. The
rung change itself sets a new deadline from the new rung
(`crates/core/src/store.rs:1730`), so the remaining time changes; that
is the rung click, not the ceremony.

**Fail:** ⌘Z after the rung click removing the whole page's text in
one step, which is the specific defect `forget_undo` exists to
prevent; ⌘Z reaching text from before the transition; any loss or
reordering of the surviving text; or a chip disappearing.

5. Repeat with the pause top-up instead of the rung click: type three
   bursts on a fresh page, press ⌘Z once, then **double-click the tab
   twice**. The first double-click holds the clock for an hour; the
   second tops the hold up to twenty four hours and is the compaction
   boundary. Expect the same result as step 4: text intact, both Edit
   items greyed.
6. Note for the record that a **release** press, the third
   double-click, is deliberately **not** a boundary
   (`crates/core/src/store.rs:1823`), so undo state after it is
   whatever the top-up left, which is empty.
7. Cleanup: none.

## Results

Not yet run. This procedure has never been executed on hardware as of
2026-09-04.

| Date | Machine and macOS | Case | Pass or fail | Zone and clock used | Remaining times observed | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |
