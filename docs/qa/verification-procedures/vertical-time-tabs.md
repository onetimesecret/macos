# Vertical time tabs: a page per unit of time

**Applies to:** OnetimePad, the prototype mode behind the Settings
toggle **A page a day, with time tabs down the side**. Off by default;
horizontal tabs are what an untouched install shows.
**Raised by:** issue #79, and
[the feature spec](../../spec/feature/vertical-time-tabs/README.md).
**Required by:**
[ADR-0020](../../adr/0020-a-day-is-a-projection-of-live-pages.md)
required work item 14, and its acceptance gate: the decision stays
**proposed** until this procedure has been run and the dogfood window
has closed.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Why this needs hardware at all

Almost everything about the model is already pinned automatically. The
day arithmetic is Rust and runs under `cargo test` on Linux
(`crates/core/src/sheet.rs`, `local_day` and its DST case); the grouping
laws are pure Swift over hand-built summaries
(`shell/Tests/CompanionKitTests/TimeUnitProjectionTests.swift`); the
roll's geometry, its one-layout-manager-per-storage invariant, its
refusal to emit an op and its undo boundary are asserted against a real
window and a real TextKit stack
(`shell/Tests/CompanionKitTests/DayScrollTests.swift`,
`DayScrollProjectionTests.swift`); and the map from the roll's geometry
to the rail's minimap, edges included, is pure Swift over hand-built
measurements (`RailMinimapTests.swift`).

Four things are left, and each of them is here because the automated
suite structurally cannot reach it.

- **The calendar.** The ageing seam restores a snapshot at a later wall
  stamp and a restore carries every page's `created_wall_ms` through
  untouched (`crates/core/src/persist.rs`), so **no Swift test can move
  a page across a local midnight**. Every page a test mints is born
  today. Multi-day behaviour is therefore argued over hand-written
  summaries, and only a real machine with real days on it can say
  whether the labels roll over when they should.
- **Focus and the keyboard.** The tests can assert who is first
  responder; they cannot tell you whether typing goes where your eyes
  are.
- **The stance.** Resting, raising and the summon anchor are window
  plumbing, which this project verifies by hand rather than by mocking
  (`docs/qa/hardware-verification.md`).
- **Reading it.** Whether a perforation reads as "a day ago" rather than
  as a bug is not a thing a test can hold an opinion about, and neither
  is whether the minimap behind the rail is faint enough to stay a
  background and strong enough to be worth drawing (case 10).

## Staging, and why it takes three days

**The mode shows only the days the rungs let live.** The ladder tops out
at 7d (`crates/core/src/ttl.rs`), and the backdrop opens tabs at
`.sevenDays` (`shell/Sources/CompanionKit/FormFactor.swift`,
`defaultRung`), so out of the box Day -1 back to Day -6 are reachable,
but a pad re-rung to 8h shows only Day 0, and the mode then reads as
broken when it is merely empty.

So stage before judging, and start at least three days before the
session:

1. Install the build under test: `scripts/quit-app.sh` first (only the
   graceful path saves state), then `scripts/install.sh`.
2. On day one, write two or three lines on a page and leave it at 7d.
   Check the tab's TTL label reads `7d`.
3. On day two, ⌘N and write on the new page. Leave a **blank** page as
   well, made and not written on: it is the one that proves a day with
   nothing on it gets no row.
4. On day three, the same again, and put a sealed chip on one page with
   ⇧⌘V so at least one day has a chip and no ink of its own.
5. On the day of the session, turn the toggle on in Settings.

If three days of waiting is not available, the second-best staging is to
step the system clock forward a day between pages, but read the warning
at the top of
[clock-step-back.md](clock-step-back.md) first, since stepping the clock
is destructive to software that is not under test, and note in the
results that the days were fabricated.

## Where to look

```sh
STATE=~/Library/Application\ Support/com.onetimesecret.pad.noindex
ls -la "$STATE"
log stream --predicate 'subsystem == "com.onetimesecret.pad"'
```

The toggle writes one boolean to `UserDefaults`, and nothing else:

```sh
defaults read com.onetimesecret.pad showsTimeUnits
```

## Case 1: local midnight arrives while the card rests

The mode has no timer of its own and no midnight alarm. The labels are
relative and the offsets behind them are recomputed on every read, so
the ordinary cosmetic redraw rolls them over: 1 Hz while raised, one
repaint every 30 s while resting. The accepted cost is stated in the
spec and is what this case measures: **a label can be up to 30 s stale
at local midnight while the card rests.**

1. Before midnight, with the mode on and at least two days of pages,
   leave the card **resting** and note what the rail reads (Today,
   Yesterday, …) and what the roll's gutters read beside it (Today,
   -1d, …), the two vocabularies being deliberate since issue #131.
2. Watch across midnight without touching the card.

**Pass:** within about half a minute of the hour, every row's label
moves back one, so what was Today reads Yesterday on the rail and -1d in
the gutter, and a new Today row appears
at the top of the rail and the roll with the empty state under it if
nothing has been written yet. Nothing else moves: the tabs, their names
and their rungs are unchanged, no page was created, and the countdowns
carry on from where they were.

**Fail:** a label still wrong a minute later; a page created by the
rollover; a tab renamed, re-ordered or closed by it; the roll jumping to
a different day on its own.

3. In the log, confirm no new timer fired. `companion_expire_due` should
   fire only for pages actually reaching zero, and nothing should
   mention a calendar.

**Fail (and an ADR-0020 eject trigger):** a wakeup at midnight that is
not the redraw.

## Case 2: a middle day's page expires

The decision under test: the scroll **closes up** and the gap lives in
the labels. No ghost row, no placeholder, no renumbering.

1. Stage three days, and give the middle day's page a short rung:
   right-click that day's gutter and use its **Shorten the countdown**
   item, which steps the ladder down one press at a time. The countdown
   printed in the gutter is a label and not a button: the clickable
   countdown is the card header's, and it steps the *selected* page's
   rung, so click into the middle day first if you would rather use that
   one.
2. Wait for it to expire, or leave the card and come back after the
   rung has run out.

**Pass:** the middle day's row leaves the rail and its region leaves the
roll. Its neighbours stay exactly where they were, the labels now read
with a gap in them (Today, Yesterday, 3 days ago on the rail; Today,
-1d, -3d in the gutters), and nothing marks the place where the middle
day was. The minimap's bars close up with the rows: three stretches
become two, still in the same order and still filling the column. Turn the toggle **off**: all three tabs are still on the strip
in their original order, with their names and their rungs, and the
expired one draws the dashed empty treatment. Turn it back on.

**Fail:** a ghost row, a placeholder, a renumbering to 1st/2nd/3rd, a
tab that vanished from the strip, or a tab that was renamed or
re-ordered by the expiry.

## Case 3: summon after scrolling into history

1. With the mode on and three days staged, raise the card and scroll
   down the roll until you are reading the oldest day.
2. Rest the card (Esc), then summon it again (⌃⌥Space).

**Pass:** the pad opens on today. The clip is at the top of the roll,
instantly and with no animation of any kind, and if today holds a page
the caret is in it. If today holds no page, the empty state is there
with its Return grant intact and **no page has been created**.

**Fail:** the roll opens where it was left; the anchor animates or
bounces; a page appears without a gesture asking for one.

3. Repeat with the card pinned, and repeat with a ⌘Tab away and back
   rather than a summon. A ⌘Tab return is not a summon: it re-keys the
   card, and re-anchoring on that path would move the roll under someone
   who never asked for it. Then do the same with the Dock icon, which is
   filed the same way for the same reason (the anchor rides the gestures
   that name this surface (⌃⌥Space, the menu-bar item, a click on the
   resting card) and never the ones that name the app).

**Pass:** a ⌘Tab return leaves the scroll where it was, and so does a
click on the Dock icon; ⌃⌥Space, the menu-bar item and a click on the
resting card all take it back to today.

## Case 4: typing at the bottom of a long Day 0

1. On today's page, type until the writing is longer than the card and
   keep going.

**Pass:** the caret stays visible; the roll does not jump, scroll itself
or lose its place; the days below today move down as today grows and
none of them flickers. Typing stays smooth with three days on screen.
This is the path that re-measures a region on every keystroke, so a stall
here is the thing to write down.

**Fail:** a jump on any keystroke; a caret that leaves the viewport; a
visible re-layout of the days below; typing that lags.

2. Resize the card by an edge while a long day is on screen.

**Pass:** every day re-wraps to the new width and the roll stays
readable. **Fail:** a day that keeps its old width, doubles it, or
overlaps the day under it.

## Case 5: ⌘Z after clicking into an older day

The hazard: undo is per page, and an undo that crossed a page boundary is
how a zeroized chip's glyph comes back (ADR-0009).

1. Type a few words on today's page.
2. Click into an older day's region. The caret should land on the
   character you clicked, and that day becomes the page being written
   on.
3. Type a few words there, then press ⌘Z several times, more times than
   you typed.

**Pass:** the undos rewrite the older day only, and stop when that page
has nothing left to undo. Today's page is untouched: scroll up and read
it. No chip reappears anywhere.

**Fail:** an undo that changes a page you did not type it on; a chip
that comes back; a beep where an undo was expected.

4. With a chip on screen in a quiet day, try to select its text or copy
   it out. Nothing there is selectable by design; click it and it
   becomes the editor, and the chip's own actions are then available.

## Case 6: toggling both ways with content on screen

The safety claim: the toggle moves no content and writes no new sealed
generation.

1. With several pages, one of them held (double-click its tab, or the
   gutter's hold item), note `ls -la "$STATE"` and the mtime of
   `state.sealed`.
2. Flip the toggle off and on again three or four times, with a page
   on screen each time.

**Pass:** every page is still there with the same ink, the same chips
and the same countdowns; the held page is still held with the same tier;
the tabs keep their names, rungs and order in the strip; `state.sealed`
has **not** been rewritten by the flipping. The only defaults key that
moves is `showsTimeUnits`.

**Fail:** a page or chip lost or duplicated; a hold released; a tab
renamed or re-ordered; a new sealed generation written for a flip.

3. Note one expected cost rather than reporting it: flipping the mode
   rebuilds the content area, which spends every page's undo history and
   the caret within the page. Nothing on disk or on screen is lost. It
   is what a deliberate flip in Settings costs and what no keystroke
   pays.
4. And one expected move. Turning the mode **on** while the selected
   tab's page has expired (the state an overnight expiry leaves)
   selects the newest day that is on screen instead, because the rail
   draws no row for a slot holding no page and a selection there would
   name something nobody can see. It creates nothing and it happens in
   that direction only; turning the mode off leaves the selection
   exactly where it is, the strip having a row for every slot.

## Case 7: VoiceOver down the rail and across the roll

1. Turn VoiceOver on (⌘F5) and tab into the card.

**Pass:** each rail row announces its day in full words ("today",
"yesterday", "3 days ago") followed by how long the page on it that
dies soonest has left, and the selected row announces as selected. Since
issue #131 the row says the same words on screen, so what is heard and
what is read agree apart from the capital. The short form (`-3d`) is
left only in the roll's gutter, whose header announces the phrase, so
nothing anywhere is abbreviation-only. Each perforation announces the
day, the page's name and its remaining time. The hidden-pages line at
the foot of the rail, when it is there, announces the whole sentence and
not just the number.

**Fail:** a row that announces only "-3d"; a row that shows different
words from the ones it speaks; a row with no value; a perforation that
announces nothing; a decorative gauge or a minimap bar that VoiceOver
reads.

## Case 8: reduced motion

1. System Settings → Accessibility → Display → Reduce motion, on.
2. Summon, scroll, switch days, let a day expire.

**Pass:** nothing anywhere in the mode animates, with the setting on or
off. There is no branch to get wrong because there is no animation to
reduce.

**Fail:** any fade, slide, bounce or parallax in the rail or the roll.

## Case 9: the pad is full of blank old pages

The honesty valve for the nine-slot cap.

1. Make pages until the pad refuses a tenth, leaving several blank.

**Pass:** the foot of the rail shows a dimmed count ("3 blank") whose
tooltip says how many live pages the days are not showing and names this
Settings toggle as the way to reach them. The refusal notice names the
toggle too, rather than telling you to wait for an expiry that would not
free a slot anyway. Nothing was discarded to make room.

**Fail:** a silent refusal; a page discarded automatically; a count that
is wrong.

2. Write **down** whether the count was non-zero in ordinary use. A
   count that is routinely above zero means the content bar is set wrong,
   which is ADR-0020's fifth eject trigger.

## Case 10: the minimap, and how faint is faint enough

Issue #131 put a faint reading of the roll behind the rail's rows: a bar
per day, as tall a share of the column as that day is of the document,
and a band over the part the viewport has open. The inks are a guess
until this case is run, which is the whole reason it exists.

1. With three days staged and at least one long page, raise the card and
   look at the rail without scrolling.
2. Scroll the roll down and back up, slowly, then flick it so the
   elastic overscroll runs at each end.
3. Rest the card (⎋, or click away) and look again.
4. Put a page with a sealed chip and a page with several paragraphs on
   the same day.

**Pass:** the bars are visible as a texture and never as a chart: the
day's words, its gauge and the selection fill all read first. A day
holding more writing is a taller stretch than a day holding a line, and
two pages born on one day are one stretch rather than two. The bars are
a scaled impression of the roll and not a diagram of the rail, so a
stretch sitting well away from the row for the same day is the design
rather than a bug: the whole document is mapped onto the whole column
while the rows are packed from the top. What the two share is a count
and an order. The band tracks the viewport as the roll moves and stays
inside the column at both ends of an overscroll. Every day with a row
has a stretch you can see: the mapping keeps no bar it cannot draw, and
it only runs out of room on a column with no two points left for a day,
which takes far more days than the rail can draw rows for. A row with no
stretch behind it is therefore a fault and not the floor. A roll that
fits inside the card shows no band at all, deliberately. At rest the
whole rail dims with the card and the minimap dims with it, with no
treatment of its own.

**Fail:** any text legible in the background at any card size; a bar or
a band that overpowers a row; two bars overlapping into a darker seam; a
band that lags a scroll by more than a frame or two; a bar for a day the
rail draws no row for, or a row with no bar; a stretch of the roll drawn
behind the ledger after ⌘L; typing that stutters while three days are
mounted (see case 4).

5. Write **down** whether the two inks were right, too loud or too
   faint, and in which appearance and which contrast setting. This is
   the calibration the spec's open question 11 is waiting on, and "too
   faint to be worth having" is a legitimate answer that retires the
   band rather than darkening it.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one.

| Date | Machine and macOS | Case | Pass or fail | Notes |
|---|---|---|---|---|
| | | 1 midnight while resting | | Record how long the label was stale. |
| | | 1 no timer fired | | Needs `log stream`. |
| | | 2 middle day expires | | |
| | | 2 tabs still standing with the mode off | | |
| | | 3 summon re-anchors on today | | |
| | | 3 ⌘Tab return leaves the scroll alone | | |
| | | 3 Dock icon leaves the scroll alone | | |
| | | 4 typing at the bottom of a long Day 0 | | Note any stall with three days mounted. |
| | | 4 resize re-wraps every day | | |
| | | 5 undo cannot cross a perforation | | |
| | | 6 toggle both ways with content | | Record `state.sealed` mtime before and after. |
| | | 7 VoiceOver down the rail | | |
| | | 7 VoiceOver at a perforation | | |
| | | 8 reduced motion | | |
| | | 9 hidden blank pages counted and named | | Record whether the count is ever non-zero. |
| | | 10 minimap reads as texture, not as a chart | | Record the two inks and the appearance. |
| | | 10 band tracks the scroll and clamps at both ends | | |
| | | 10 nothing legible in the minimap at any size | | |
| | | 10 rail width at the 360pt floor | | Do the day words fit without truncation. Does the roll's gutter still hold day, title and countdown on one line. |
| | | 10 rail width on a wide card | | Does 96pt read as generous or as a wasted column. Decision: pin 96, narrow the rail, or raise the card's floor. |
