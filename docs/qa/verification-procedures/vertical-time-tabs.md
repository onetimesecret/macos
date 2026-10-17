# Vertical time tabs: a page per unit of time

**Applies to:** OnetimePad, the prototype mode behind the Settings
toggle **A page a day, with time tabs down the side**. Off by default;
horizontal tabs are what an untouched install shows.
**Raised by:** issue #79, and
[the feature spec](../../spec/feature/vertical-time-tabs/README.md).
**Architectural context:**
[ADR-0020](../../adr/0020-a-day-is-a-projection-of-live-pages.md) remains
**proposed**. Running this procedure does not itself record architectural
acceptance.
**Correction contract:** case 12 checks the user's recommendation/proposal being
implemented in
the [2026-10-16 feature-spec amendment](../../spec/feature/vertical-time-tabs/README.md#amendment-user-directed-wrapping-and-horizontal-scrolling-2026-10-16).
Formal approval status is not independently recorded; tests and agent prose
are not approval.
**Owner:** delano.
**Status:** pending. Not yet run on hardware, including case 12. No hardware
pass is recorded by this documentation correction.

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
to the stream navigator's nodes, viewport band and line slivers is pure
Swift over hand-built measurements (`StreamNavigatorTests.swift`).

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
  is whether the navigator's viewport band and line slivers stay faint
  enough behind its nodes (case 10).

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
STATE=~/Library/Application\ Support/dev.onetimesecret.pad.noindex
ls -la "$STATE"
log stream --predicate 'subsystem == "dev.onetimesecret.pad"'
```

The toggle writes one boolean to `UserDefaults`, and nothing else:

```sh
defaults read dev.onetimesecret.pad showsTimeUnits
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
   right-click that day's gutter and use its **Shorten the Countdown**
   item, which steps the ladder down one press at a time. The countdown
   printed in the gutter is a label and not a button; the menu is the
   only way to step the rung in this mode, since the card header no
   longer carries a countdown (dogfood phase 4, item 6).
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
   rather than a summon. A ⌘Tab return is not a summon: under ADR-0033
   it selects the primary editor window, opening it when it is closed,
   and a raised card rests as that window takes the keyboard. The page
   goes to the editor window with the roll where the reader left it,
   because re-anchoring on that path would move the roll under someone
   who never asked for it, so read the roll in the editor window for
   this step. Then do the same with the Dock icon, which selects the
   editor window as well and is filed the same way for the same reason
   (the anchor rides the gestures that name the panel (⌃⌥Space, the
   menu-bar item, a click on the resting card) and never the ones that
   name the app).

**Pass:** a ⌘Tab return selects the editor window and leaves the scroll
where it was: the roll in the editor window opens at the place the
card's roll was left, and a click on the Dock icon does the same. Both
are activations, and ADR-0033 keeps them off today: "an activation
still never anchors the roll on today". The place itself crosses with
the page, since a transfer of ownership leaves the roll's place for the
roll that mounts in the other window (`PageViewStates.rollPlace`).
⌃⌥Space, the menu-bar item and a click on the resting card all take it
back to today.

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

2. With `wrapsLines` on, resize the card by an edge while a long day is on
   screen.

**Pass:** active and inactive source pages re-wrap to the new viewport width
and the roll stays readable. **Fail:** stale source width or overlapping days.
With `wrapsLines` off, source lines remain unwrapped instead; run case 12 for
horizontal reachability and viewport-aligned headings. Preview layout is not
redefined by this source-wrap check.

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
dies soonest has left, and the selected row announces as selected. On
Today, VoiceOver also offers a **New page** action that mints another
page. Since
issue #131 the row says the same words on screen, so what is heard and
what is read agree apart from the capital. The short form (`-3d`) is
left only in the roll's gutter, whose header announces the phrase, so
nothing anywhere is abbreviation-only. Each perforation announces the
day, the page's name and its remaining time. The hidden-pages line at
the foot of the rail, when it is there, announces the whole sentence and
not just the number.

**Fail:** a row that announces only "-3d"; a row that shows different
words from the ones it speaks; a row with no value; Today with no
**New page** action; a perforation that announces nothing; a decorative
gauge or a minimap bar that VoiceOver reads.

## Case 8: reduced motion

1. System Settings → Accessibility → Display → Reduce motion, on.
2. Summon, scroll, switch days, let a day expire.

**Pass:** nothing anywhere in the mode animates, with the setting on or
off. There is no branch to get wrong because there is no animation to
reduce.

**Fail:** any fade, slide, bounce or parallax in the rail or the roll.

## Case 9: the pad is full of blank old pages

There is no cap any more (issue #158), so this case is the count and
the tenth page, not a refusal.

1. With the mode off, make nine pages over several days and leave at
   least three of the older pages blank. Follow the staging procedure
   above, or use the documented clock-step-back procedure between pages.
   Turn the mode on.

**Pass:** the foot of the rail shows a dimmed count ("3 blank") whose
tooltip says how many live pages the days are not showing and names this
Settings toggle as the way to reach them. Today's blank pages stay on the
Today row and do not contribute to the count.

**Fail:** a count that is wrong, or no count with blank pages standing.

2. Press ⌘N.

**Pass:** today's page opens as a tenth slot. No notice. Nothing was
discarded to make room. Turn the mode off: ten tabs on the strip, the
strip scrolls sideways to hold them, and the new one is in view.
⌘9 selects the ninth; the tenth has no chord and is reached by a click.

**Fail:** a refusal naming a wall; a blank page discarded automatically;
a tenth tab off the edge of the strip with no way to scroll to it.

3. Write **down** whether the count was non-zero in ordinary use. A
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

## Case 11: a second page on today

Issue #158. The keyboard reading has to be felt on hardware because
first press jumps and second press creates, and a test cannot see the
pause a person takes between presses.

1. With the mode on and today empty, press ⌘N. Today's page appears and
   the caret is in it. Press ⌘N again.

**Pass:** a second, blank page appears under Today, below the first in
the roll, and the caret is in it. The rail's Today row still reads
Today, and its gauge follows whichever of the two pages dies soonest.

**Fail:** the press selected the first page instead of minting; the
second page landed under another day; the caret stayed on the first page.

2. Close every page so today is empty again. Press ⌘1 twice, then click
   the Today row twice.

**Pass:** one page. ⌘1 and the row name today as a place: the first
press makes the page, every later one goes to it. Only ⌘N and the +
ask for another.

**Fail:** a chord or a click on the place stacked a page.

3. Scroll to yesterday, or select a file if one is open, and press ⌘N.

**Pass:** a jump back to today's page, no third page.

4. Hover the + on the Today row. Click it once on a blank page, then
   once on a page with a word on it.

**Pass:** the tooltip reads "New page (⌘N)", or the chord the keymap
bound. Both clicks mint: the plus is the strip's + button and takes no
jump-first reading. Nothing else on the rail grows a plus.

**Fail:** a plus beside yesterday; a tooltip that spells a chord the
keymap does not bind; a click that only selects.

5. Turn the mode off. Every page made above is a tab on the strip; turn
   it back on and today lists them all.

## Case 12: user-controlled wrapping and shared horizontal scrolling

**Status: pending hardware verification; not passed.** Expected outcomes below
come from the [implementation contract](../../spec/feature/vertical-time-tabs/README.md#implementation-contract)
for the user's recommendation/proposal being implemented, not formal approval,
an external UI convention, or an accepted architectural decision. Record
observations separately from formal approval, whose status is not independently
recorded. Automated results and agent prose do not close this hardware check.

**Setup:** use a disposable test profile with source pages containing long prose
lines, long unbroken tokens, and fenced source lines wider than the viewport.
Use the multi-day staging above so at least two days contain wide source lines,
one active and one inactive. Include a Markdown preview and a sealed note to
compare their existing presentation and actions before and after the checks.
Do not remove a daily-use profile's saved preference to test the unset default.

1. In a test profile where `wrapsLines` has never been set, open source in tabs
   mode, then days mode. The expected existing default is wrapping on. Record
   the actual setting and layout rather than assuming the default was used.
2. In tabs mode, turn wrapping off in Settings, then toggle it on and off with
   the wrap command (⌥Z in the bundled keymap). Repeat in days mode. Each action
   changes the same preference and source layout; no fixed-wrap refusal occurs.
3. Repeat with wrapping on and off while switching tabs/days modes and selecting
   another day. Active and inactive source pages use the same value. Promotion
   of an inactive page does not change its wrap policy.
4. With wrapping off in days mode, scroll horizontally to a nonzero offset.
   Check that all source regions move together through one document offset,
   including the inactive region. Scroll vertically to another wide day and
   select it: it does not introduce an independent horizontal offset.
5. At that nonzero horizontal offset, check day/page headings and their controls.
   They remain viewport-aligned, readable, and operable while source text moves.
   Repeat after resize and after changing the active day. This does not require
   vertically sticky headings.
6. Reach the end of each wide source line by horizontal scrolling. Resize the
   viewport narrower and wider: source stays unwrapped and reachable, without
   clipping its far end or overlapping the next day.
7. Turn wrapping on while horizontally displaced. Active and inactive source
   pages reflow to the viewport width without stale horizontal displacement.
   Resize again, then turn wrapping off and repeat the reachability check.
8. For each wrap value, quit and relaunch in tabs mode and in days mode. The
   selected value is restored through the existing `wrapsLines` preference.
   Record the mode and value on each run; mode changes do not overwrite it.
9. Compare the Markdown preview and sealed note with the setup observations in
   both modes and with both wrap values. Their presentation and actions remain
   unchanged; do not reinterpret source wrapping as a preview or sealed-note
   redesign.
10. In both modes, make one known edit, then record source text and the logical
    selection/caret position. Toggle wrapping, scroll horizontally, and resize.
    The presentation changes leave that text and selection/caret unchanged. Undo
    reverses the known edit directly and redo restores it: presentation actions
    add no undo step and do not discard or reorder the existing history. Repeat
    on another page and confirm undo remains per page.
11. With wrapping off and a nonzero horizontal offset, exercise each reveal
    target separately: move the caret to the opposite end of a wide line, find
    a match outside the viewport, extend a selection beyond the viewport,
    replace a match, and undo an edit outside the viewport. Each target becomes
    visible in both axes as needed, without a heading obscuring it. In days
    mode the shared scroll view reveals the target; no per-day scroller appears.
    Normal selection changes and text edits from these actions retain their
    existing semantics rather than being treated as geometry-only updates.
12. Grow the widest source line by typing or replacement, then shorten it by
    deletion or undo. After each change, make that page inactive and repeat the
    reachability and clamp checks. Scroll to the far right before each shrink;
    also remove the widest page while inactive and resize wider and narrower.
    Width and offsets update so surviving text remains reachable and
    the offset stays within valid bounds, without stale blank space beyond the
    document edge. Repeat the wrap-on clamp after each scenario.
13. Scroll to a recognizable source position away from the caret and record the
    logical text being read, not just a pixel offset. Toggle wrapping, resize,
    and trigger relayout by changing content above that position. The same
    surviving logical text remains the reading anchor within valid bounds.
    Explicit reveal actions from step 11 and the existing summon anchor take
    precedence; clamping at an edge may adjust the anchor's viewport position.
14. Profile repeated horizontal-only gestures over multiple source days with
    unchanged content, font, wrap value, and viewport size. Record the profiler
    or measurement trace used to distinguish scroll updates from text
    measurement. Horizontal bounds changes alone do not repeatedly measure
    source text or every day, rebuild renderings, or run document-wide layout.
    Then edit content or change a layout input and confirm geometry updates.
    Without measurement evidence, this performance check remains pending even
    if scrolling appears smooth; this procedure adds no source instrumentation.

**Pass criteria:** every applicable outcome above is observed and recorded with
the build, profile, machine, macOS version, mode, and wrap value. Any forced
wrapping, inactive-source mismatch, independent per-page horizontal offset,
heading displaced horizontally, unreachable reveal target or line end,
overwritten preference, geometry-only text/selection/undo change, invalid
post-shrink offset, lost logical reading anchor, repeated text measurement on
horizontal-only scrolling, or preview/sealed-note regression is a failure.
An unrun step remains pending;
a documentation edit or automated test result is not a hardware pass.

## Results

Not yet run; hardware verification remains **pending**, including case 12.
One row per check when a session runs it, and the rows stay: a re-run adds a row
rather than replacing one. `Pass` in a case describes an expected outcome, not
an executed result.

| Date | Machine and macOS | Case | Pass or fail | Notes |
|---|---|---|---|---|
| | | 1 midnight while resting | | Record how long the label was stale. |
| | | 1 no timer fired | | Needs `log stream`. |
| | | 2 middle day expires | | |
| | | 2 tabs still standing with the mode off | | |
| | | 3 summon re-anchors on today | | |
| | | 3 ⌘Tab return selects the editor window and leaves the scroll alone | | ADR-0033. |
| | | 3 Dock icon selects the editor window and leaves the scroll alone | | ADR-0033. |
| | | 4 typing at the bottom of a long Day 0 | | Note any stall with three days mounted. |
| | | 4 resize re-wraps active and inactive source with wrapping on | Pending | |
| | | 5 undo cannot cross a perforation | | |
| | | 6 toggle both ways with content | | Record `state.sealed` mtime before and after. |
| | | 7 VoiceOver down the rail | | |
| | | 7 VoiceOver at a perforation | | |
| | | 8 reduced motion | | |
| | | 9 hidden blank pages counted and named | | Record whether the count is ever non-zero. |
| | | 9 tenth page opens, strip scrolls to it | | Note whether the new tab was in view without a scroll. |
| | | 10 minimap reads as texture, not as a chart | | Record the two inks and the appearance. |
| | | 10 band tracks the scroll and clamps at both ends | | |
| | | 10 nothing legible in the minimap at any size | | |
| | | 10 rail width at the 360pt floor | | Do the day words and Today's + fit without truncation. Does the roll's gutter still hold day, title and countdown on one line. |
| | | 10 rail width on a wide card | | Does 96pt read as generous or as a wasted column. Decision: pin 96, narrow the rail, or raise the card's floor. |
| | | 11 ⌘N on today's page mints a second page | | Note where the caret landed. |
| | | 11 ⌘1 and the Today row make one page, not two | | |
| | | 11 ⌘N from elsewhere jumps, no third page | | |
| | | 11 the Today row's + mints and names the chord | | |
| | | 12 unset default in tabs and days | Pending | Disposable profile only. |
| | | 12 Settings and wrap command in both modes | Pending | Record both wrap values. |
| | | 12 active/inactive source parity and selection changes | Pending | |
| | | 12 shared horizontal document offset across days | Pending | |
| | | 12 viewport-aligned headings and controls | Pending | Include resize and selection at nonzero offset. |
| | | 12 unwrapped line ends reachable after resize | Pending | |
| | | 12 wrap-on reflow clears stale horizontal displacement | Pending | |
| | | 12 preference restored after relaunch in both modes | Pending | Record each mode/value combination. |
| | | 12 preview and sealed note unchanged | Pending | Compare presentation and actions with setup. |
| | | 12 text, logical selection/caret, and undo unchanged by presentation | Pending | Both modes; verify undo and redo order. |
| | | 12 caret/find/selection/replacement/undo reveal targets | Pending | Both axes; shared scroll view in days mode. |
| | | 12 growth/shrink and widest-page removal clamps | Pending | Active/inactive source, resize, and wrapping. |
| | | 12 logical reading anchors through reflow | Pending | Record source position and explicit-reveal exceptions. |
| | | 12 no repeated measurement during horizontal-only scrolling | Pending | Measurement trace required, not visual smoothness alone. |
