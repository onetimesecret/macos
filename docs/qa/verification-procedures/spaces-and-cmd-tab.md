# Spaces, ⌘Tab and the pad

**Applies to:** OnetimePad, both stances, pinned and not.
**Raised by:** issue #74, from the dogfood aberrations log of
2026-08-19.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## What was seen, and what the code did about it

Three symptoms were filed together. Two of them share a cause and one
does not.

1. **⌘Tab back landed on Desktop 1.** The resting surface claimed no
   all-Spaces membership, so its window belonged to the desktop it was
   created on, and the window server switches Spaces to reveal an app's
   windows when the app is activated. Every posture now claims every
   desktop (ADR-0019), so there is nothing to reveal elsewhere.
2. **The window could not be dragged to another desktop.** Not a defect
   of the same kind, and not fixed. The card's place is the app's own
   state, proposed by a gesture inside the card and clamped to the
   primary screen; the window server never sees a window drag, so the
   edge gesture has nothing to act on, and a surface on every desktop
   has no other desktop to be moved to. ADR-0019 records this as a
   decision.
3. **A flicker on every ⌘Tab return.** Two candidates were removed. The
   membership bits, whose change is what asks the window server to move
   a window between Spaces, are the same in every posture and either pin
   state, so no raise, rest or pin asks for a reassignment any more.
   (The composite `collectionBehavior` value is still rewritten when a
   stance changes, because the rest of it does differ: `.stationary`,
   `.ignoresCycle` and full-screen participation. What is constant is
   the membership subset, `BackdropStance.spaceMembership(pinned:)`, and
   the guard in `applyAltitude` skips the write only when the whole
   value matches.) The second candidate was the summon's order-out round
   trip, a literal blink, which can no longer fire on a summon between
   desktops. It is not dead code: the unpinned rest declines full-screen
   Spaces, so a summon from another app's full-screen room still finds
   the card off-Space and still round trips it. A third candidate
   remains and this procedure is how we find out whether it is the one
   that mattered: see below.

## Setting up

Quit any running copy first (`scripts/quit-app.sh`; only the graceful
path saves state), then `scripts/package-app.sh && open
dist/OnetimePad.app`.

Have at least three desktops (Mission Control, add two), and close both
Settings and About before starting, since an open ordinary window is the
other thing that can pull an activation across desktops and those two
are the app's only ones. The surface's log is worth a second terminal:

```
log stream --predicate 'subsystem == "com.onetimesecret.pad"'
```

## The checks

### The return

- [ ] **Resting, from another desktop.** With the pad resting, go to
      Desktop 3, work in another app, then ⌘Tab to OnetimePad. **Pass:**
      the desktop does not change and the card raises where you already
      were. **Fail:** the screen slides to Desktop 1.
- [ ] **Raised, from another desktop.** Raise the card on Desktop 3
      (⌃⌥Space), ⌘Tab away to another app, ⌘Tab back. Same pass
      condition, and the card must come back keyed: type a character and
      it lands in the page.
- [ ] **Pinned, across a switch.** Pin the card, then switch desktops
      with ⌃→ and ⌃←. The card stays put and readable on each, and the
      log carries no `mouse gate=closed` line while it is plainly
      visible.
- [ ] **The Dock icon.** From Desktop 3, click the Dock tile. The card
      raises on Desktop 3.
- [ ] **Summoned from another app's full-screen Space.** Unpinned, put
      an app full screen, and from inside it press ⌃⌥Space. The card
      arrives on the full-screen Space, keyed, and takes what you type.
      A single blink as it arrives is correct here and not the flicker:
      an unpinned rest declines full-screen Spaces, so the card really
      was elsewhere and the summon's round trip is what brings it. The
      log carries `summon=round trip (surface was off-Space)` for it.
      **Fail:** the card does not appear, or appears and takes no keys.
- [ ] **Settings does not drag the app back.** Open Settings on Desktop
      1, close it, go to Desktop 3, press ⌘, again. It opens on Desktop
      3.
- [ ] **About does not drag the app back either.** About is a second
      ordinary window and AppKit reuses one instance of it. Open it from
      the tray on Desktop 1, leave it open, go to Desktop 3 and ⌘Tab to
      OnetimePad: the desktop must not change, and the panel comes here
      rather than staying behind. Then choose About again from the tray
      on Desktop 3 and confirm it appears on Desktop 3.
- [ ] **The same, from the app menu.** Repeat the check above, but open
      About from the menu bar's OnetimePad menu rather than the tray.
      This is the route that used to bypass the fix entirely, since
      SwiftUI synthesizes that item against AppKit's own panel call; a
      pass on the tray route says nothing about it. ⌘Tab to the app
      first, which is what puts the menu on screen.

### The flicker

- [ ] **⌘Tab back, ten times, watching the card.** Alternate ⌘Tab away
      and back and watch the card itself rather than the screen.
      **Pass:** the card appears in place. **Fail, and the shape of the
      failure is the diagnosis:**
      - The card *vanishes and returns*: an order-out is still
        happening. The round trip is the only one left in the code, and
        between desktops it should not fire at all, so capture the log
        lines around it and note whether `summon=round trip` is among
        them.
      - The card *changes size or jumps* for a frame: this is the
        remaining candidate. The unpinned resting window spans the whole
        screen and the raised window is the card's own rect (ADR-0015),
        so every raise resizes the window and relays out the hosted view
        inside it. The fix, if this is it, is to let the unpinned rest
        hug the card as well: it is mouse-transparent either way, so the
        pane-wide acreage buys nothing but this resize. That is a change
        to ADR-0015's shape and wants its own issue.
      - The *whole screen* flashes, not the card: that is the Space
        switch itself, which means symptom 1 has not actually been
        fixed.
- [ ] **Pinned, same ten returns.** The pinned rest neither resizes nor
      changes level on a raise, so if the flicker survives here it is
      not the resize.
- [ ] **The write guard, counted.** Restart the stream with `--level
      debug` added, so the altitude lines appear. Leave the card raised,
      then ⌘Tab away and back ten times: each return applies the raised
      stance over an already-raised surface, so `collectionBehavior
      write=` must appear no times at all. One per return means the
      guard is not holding and every activation is asking the window
      server to place the window again, which is the cause the ten
      returns above are looking for. A line on a genuine raise or rest,
      where the posture really changed, is expected.

### Normal inactive stacking (ADR-0032, issue #190)

The keyless raised surface now drops to normal window level unless Pin
or the keep-above preference lifts it. What the pure decision returns
is covered by `BackdropAltitudeTests`; what the window server does with
the level under real applications is the part only a person at the
machine can judge.

Two apps beside OnetimePad make the checks cheap: pick two windowed
apps you can ⌘Tab between (Safari and Terminal, say), and leave both
open. Confirm the surface preference **Keep OnetimePad above other apps
when switching away** is off before the first run; the last two checks
turn it on.

- [ ] **⌘Tab away stacks normally, preference off.** Raise the card
      (⌃⌥Space), ⌘Tab to another app, and confirm the other app's
      windows cover the card. ⌘Tab back to OnetimePad: the card is
      keyed and floating again, on the same page, and the roll has not
      moved to today. **Fail:** the card stays above the other app on
      ⌘Tab away (the previous always-above behaviour), or the return
      does not re-key it, or the roll snaps to today.
- [ ] **Hotkey raise, then ⌘Tab between two other apps.** With the pad
      resting, ⌃⌥Space to raise, then ⌘Tab to app A and ⌘Tab from A to
      B without going through OnetimePad. **Pass:** the card lowers to
      normal and each app's windows stack over it in turn; no frame
      shows the card flashing above the newly active app.
- [ ] **Preference on: raised stays above.** Open Settings, turn **Keep
      OnetimePad above other apps when switching away** on, close
      Settings. Raise the card, ⌘Tab to another app. **Pass:** the
      card stays above that app's windows. ⌘Tab back and confirm the
      card is still there, keyed. Turn the preference off again before
      moving on.
- [ ] **Pin outranks both.** With the preference off, pin the card
      (raised or resting), ⌘Tab to another app. **Pass:** the card
      stays above. Repeat with the preference on and confirm the same
      answer; Pin is the stronger, explicit promise (ADR-0032).
- [ ] **Press on a partly covered card takes keys and lifts.** With
      the preference off, raise the card, ⌘Tab to another app whose
      window covers most of the card, and click on the visible sliver
      of the card. **Pass:** the click takes keys, the card lifts to
      floating and types at once. **Fail:** the mouse gate refuses the
      click (a lowered raised surface is a case the exposure gate saw
      rarely before, issue #73) and the press lands in the other app
      instead.

The observation from `docs/dogfood/potentially-quirky-behaviour.md` on
this branch stands: on a preliminary probe (bdb0cbd) ⌘Tab to a
full-screen application still followed the pad across to the
full-screen Space with the card above it, and the drop to normal after
the transition settled did not read as reliable. Whether the fix in
this branch settles it is one of the checks below; if it does not,
that is the eject trigger ADR-0032 names first.

- [ ] **Full-screen Space, preference off.** Put another app full
      screen and ⌘Tab into it from OnetimePad. **Pass:** the screen
      goes to the full-screen Space, and once the animation settles
      the full-screen app is what fills it; a card visible over
      empty pixels the app leaves uncovered is normal stacking. **Fail:**
      the card sits above the full-screen app's content after the
      transition settles, which was the pre-branch reading and the
      case bdb0cbd could not fully address. Note the exact shape:
      whether the pad is composited over the app, or whether only the
      status item's menu draws there.

### The drag, which is a decision rather than a fix

- [ ] **Drag the card to the right edge of the screen and hold.**
      Expected: nothing happens; the card stops at the edge, clamped.
      The desktop does not change. If the card instead escapes the
      screen or lands askew, that is a clamping defect and worth its own
      issue; the refusal to change desktops is not.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | resting ⌘Tab from another desktop | | |
| | | raised ⌘Tab from another desktop | | |
| | | pinned across ⌃→ and ⌃← | | |
| | | Dock icon from another desktop | | |
| | | Settings opens where the user is | | |
| | | About opens where the user is, and follows a ⌘Tab | | |
| | | the same for About opened from the app menu | | |
| | | summon from a full-screen Space lands and takes keys | | One blink there is the landing, not the flicker. |
| | | ten ⌘Tab returns, unpinned | | Record the shape of any flicker. |
| | | ten ⌘Tab returns, pinned | | |
| | | no collectionBehavior write on a re-raise | | Needs `log stream --level debug`. |
| | | ⌘Tab away stacks normally, preference off | | ADR-0032, #190. |
| | | hotkey raise then ⌘Tab A→B, no flash | | ADR-0032, #190. |
| | | preference on: raised stays above on ⌘Tab | | ADR-0032, #190. |
| | | Pin outranks preference in both stances | | ADR-0032, #190. |
| | | press on a partly covered card takes keys | | ADR-0032, issue #73 and #190. |
| | | full-screen Space, preference off | | Pending; the bdb0cbd probe was insufficient. #190. |
| | | edge drag stays on this desktop | | The documented decision, ADR-0019. |
