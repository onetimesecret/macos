# Spaces, ⌘Tab and the pad

**Applies to:** OnetimePad. Two window roles, since ADR-0033: the
ambient panel (both stances, pinned and not) and the primary editor
window (an ordinary activating `NSWindow`). Each check below names the
window it is about: *panel*, *editor*, *both*, or *companion* for
Settings and About. No check assumes that the window a person edits in
is the all Spaces panel.
**Raised by:** issue #74, from the dogfood aberrations log of
2026-08-19.
**Owner:** delano.
**Status:** partly run. On 2026-09-28 the maintainer ran on hardware,
and reported passed, exactly these: the four sections marked ADR-0033
(⌘Tab and the editor window; A pinned panel floats above the editor
window; Editor window full screen; Stage Manager and Mission Control),
the checks of issue #190, two checks of issue #184 (the press on a
partly covered card, and ⌘Tab into a full-screen Space), and the seven
B4 routes of issue #210. The panel-off checks for #215 were added
after that run and remain unverified. Rows with an empty result have
not been run.

## Scope after ADR-0033

ADR-0033 separated the primary editor from the ambient panel. What the
window server sees is now two windows with different roles:

- **The ambient panel** keeps its all Spaces membership, its level
  (which follows stance, key status, Pin and the keep above preference
  together, ADR-0032), its outside click rule, and its hotkey and
  status item summons. Every check below marked *panel* is about that
  window.
- **The primary editor window** is a plain activating `NSWindow` with
  ordinary Space membership, normal window level, AppKit's own full
  screen, key and main behaviour, and participation in ⌘Tab, the
  Window menu, Mission Control and Stage Manager. Every check marked
  *editor* is about that window and the AppKit behaviour it inherits.

A person's launch, a Dock click, a reopen and ⌘Tab select the editor
window (opening it when closed); with the ambient panel preference on,
which is the default, the hotkey, the status item and the resting card
click stay with the panel. With the preference off, ADR-0033 sends the
hotkey and the status item to the editor window as well; except for the
panel-off checks below, every check here assumes it is on. A ⌘Tab that
finds the editor window closed opens it on the desktop the person is on,
and a raised panel rests as the window takes the keyboard; one that finds
it open on another desktop switches there, as it does for any document
application. A pinned panel floats above every ordinary window, editor
included; the editor never floats. *Companion* marks Settings and
About, the ordinary windows ADR-0033 leaves under ADR-0032's companion
window rule.

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
   stance or the altitude changes, because the rest of it does differ:
   `.stationary`, `.ignoresCycle` and full-screen participation, which
   follows the altitude since ADR-0034. What is constant is the
   membership subset, `BackdropStance.spaceMembership(altitude:)`, and
   the guard in `BackdropAltitudeKeeper` skips the write only when the
   whole value matches.) The second candidate was the summon's order-out round
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
log stream --predicate 'subsystem == "dev.onetimesecret.pad"'
```

## The checks

### The return, editor window closed

These are the checks issue #74 was filed for, rerun under ADR-0033.
A ⌘Tab and a Dock click now select the editor window and open it when
it is closed, and the panel is never what they raise. The editor
window has ordinary Space membership, so the desktop promise of
ADR-0019 narrows to one state, which ADR-0033's Consequences put as
"ADR-0019's promise that activation never changes the desktop now
holds only while the editor window is closed." That state is what
these checks exercise: with nothing of ours open on another desktop,
the return must stay on the desktop the person is on and the editor
window must open there. Close the editor window (⇧⌘W) before starting
each check.

- [ ] **Resting, from another desktop.** *Editor.* With the pad resting
      and the editor window closed, go to Desktop 3, work in another
      app, then ⌘Tab to OnetimePad. **Pass:** the desktop does not
      change, the editor window opens keyed on Desktop 3 (the stream
      carries `editor window=open`) and the card stays resting behind
      it. **Fail:** the screen slides to Desktop 1, or the card raises
      instead of the editor window opening; ADR-0033 routes a ⌘Tab to
      the editor window and never to the panel.
- [ ] **Raised, from another desktop.** *Both.* Raise the card on
      Desktop 3 (⌃⌥Space) with the editor window closed, ⌘Tab away to
      another app (the card drops to normal and stays raised), then
      ⌘Tab back. **Pass:** the desktop does not change, the editor
      window opens keyed on Desktop 3 with the page in it, and the
      card rests as the window takes the keyboard: type a character
      and it lands in the editor window's page, and with the time tabs
      mode on and the roll scrolled into history before the ⌘Tab away,
      the roll has not moved to today. ADR-0033: "A raised panel no
      longer survives the return ⌘Tab. The return selects the editor
      window and the panel rests." **Fail:** the card comes back keyed
      instead, the editor window does not open, or the roll snaps to
      today. To re-key the card itself after a ⌘Tab away, press
      ⌃⌥Space from the other app; that route stays with the panel and
      is what the flicker section runs. With the editor window
      **open** on another desktop the same ⌘Tab switches to it; that
      is the editor case below.
- [ ] **Pinned, across a switch.** *Panel.* Raise the card
      (⌃⌥Space), turn the pin on from the header toggle and rest it
      (Esc), then switch desktops with ⌃→ and ⌃←. The card stays put
      and readable on each, and the log carries no `mouse gate=closed`
      line while it is plainly visible.
- [ ] **The Dock icon, editor closed.** *Editor.* From Desktop 3 with
      the editor window closed, click the Dock tile. **Pass:** the
      desktop does not change and the editor window opens keyed on
      Desktop 3; the panel is not raised. This is the reopen check
      below taken from another desktop: ADR-0033 gives the Dock click
      and the reopen the editor window whether it is open or closed.
      **Fail:** the panel raises on Desktop 3, or the screen slides to
      Desktop 1.
- [ ] **Summoned from another app's full-screen Space.** *Panel.*
      Unpinned, put an app full screen, and from inside it press
      ⌃⌥Space. The card arrives on the full-screen Space, keyed, and
      takes what you type. A single blink as it arrives is correct
      here and not the flicker: an unpinned rest declines full-screen
      Spaces, so the card really was elsewhere and the summon's round
      trip is what brings it. The log carries `summon=round trip
      (surface was off-Space)` for it. **Fail:** the card does not
      appear, or appears and takes no keys.
- [ ] **Settings does not drag the app back.** *Companion.* Open
      Settings on Desktop 1, close it, go to Desktop 3 and open it
      again (⌥ click the status item, or ⌘Tab to OnetimePad and press
      ⌘,). It opens on Desktop 3.
- [ ] **About does not drag the app back either.** *Companion.* About
      is a second ordinary window and AppKit reuses one instance of it.
      With the editor window closed, open About from the tray on
      Desktop 1, leave it open, go to Desktop 3 and ⌘Tab to OnetimePad.
      **Pass:** the desktop does not change, About comes to Desktop 3
      (it carries `.moveToActiveSpace`), and the editor window opens
      keyed on Desktop 3 beside it; the card stays resting, since
      ADR-0033 sends the ⌘Tab to the editor window and not to the
      panel. **Fail:** the screen slides to Desktop 1 to reveal About,
      or the panel raises. Then choose About again from the tray on
      Desktop 3 and confirm it appears on Desktop 3.
- [ ] **The same, from the app menu.** *Companion.* Repeat the check
      above, but open About from the menu bar's OnetimePad menu rather
      than the tray. This is the route that used to bypass the fix
      entirely, since SwiftUI synthesizes that item against AppKit's
      own panel call; a pass on the tray route says nothing about it.
      ⌘Tab to the app on Desktop 1 first, which is what puts the menu
      on screen; that ⌘Tab opens the editor window there, which is
      expected. Open About from the OnetimePad menu, then click the
      editor window and close it (⇧⌘W), so that About stays open on
      Desktop 1 and the editor window is closed. ⇧⌘W closes the window
      the keyboard is in, so with About keyed it would close About
      instead. Only then go to Desktop 3 and ⌘Tab to OnetimePad. Left
      open on Desktop 1, the editor window would take that ⌘Tab back to
      Desktop 1, as the editor case below expects. **Pass** and
      **Fail** as above.

### ⌘Tab and the editor window (ADR-0033)

New hand checks the ADR creates. The editor window has ordinary Space
membership, so ⌘Tab from another desktop can carry the person to the
editor window's desktop, as it does for any document application.
Nothing here is issue #74 returning: ADR-0033 records this behaviour
as expected under its Consequences ("The editor window has a desktop.
⌘Tab from another desktop can carry the person to the desktop the
editor window is on, as it does for any document application").

- [ ] **⌘Tab from another desktop selects the editor window and
      changes desktops.** *Editor.* Open the editor window (click the
      Dock tile, or ⌘Tab to OnetimePad; either route opens it when it
      is closed, and no menu item does) and leave it on Desktop 1. Go
      to Desktop 3, raise the card there (⌃⌥Space) and ⌘Tab to another
      app (a click into it would rest the card), then ⌘Tab to
      OnetimePad. **Pass:** the screen switches to Desktop 1, the
      editor window comes forward keyed and the raised panel rests as
      it takes the keyboard (the stream carries `key
      gain=editor-window turn=rests-panel`). **Fail:** either the
      screen does not switch (an editor window that behaves as an all
      Spaces window is not what ADR-0033 asks for) or the panel comes
      forward instead of the editor window. This is not issue #74
      returning: the editor is the primary window and its desktop is
      the person's application desktop.
- [ ] **Dock icon selects the editor window, not the panel.**
      *Editor.* With the editor window open on Desktop 1 and the panel
      resting on Desktop 3, from Desktop 3 click the Dock tile.
      **Pass:** the screen switches to Desktop 1 and the editor window
      comes forward keyed. **Fail:** the Dock tile raises the panel on
      Desktop 3 instead. ADR-0033 sends a Dock click to the editor
      window, and the routing table that implements it,
      `ActivationRouter.decide` in `ActivationRoute.swift`, answers
      both the activation and the reopen with the editor window.
- [ ] **Reopen selects the editor window.** *Editor.* Close the editor
      window (⇧⌘W), then click the Dock tile. **Pass:** the editor
      window reopens keyed; the panel is not summoned. **Fail:** a
      reopen with the panel enabled raises the panel instead of
      opening the editor window.
- [ ] **The panel's own summons stay with the panel.** *Panel.* With
      the editor window open on Desktop 1 and the panel resting on
      Desktop 3, from Desktop 3 press ⌃⌥Space (the hotkey) or click
      the status item. **Pass:** the panel raises on Desktop 3 without
      activating the app; the desktop does not switch and the editor
      window keeps its Space. Then turn the pin on (raise the card, use
      the header toggle, rest it with Esc) and click the resting card:
      it must do the same. The card click is a pinned rest's route
      only, since an unpinned rest lets every click through to the
      desktop (ADR-0015). **Fail:** any of those three summons
      activates the app or switches desktops.
- [ ] **Panel off: hotkey and status item focus the editor (#215).**
      *Both.* Turn the ambient panel off, close the editor window, and
      activate another app with a text field on the same desktop.
      Press ⌃⌥Space. **Pass:** OnetimePad becomes active, its editor
      window opens in front, and typing goes into the editor without a
      second click; the panel stays absent. Repeat with the editor
      already open behind the other app and again with it miniaturized,
      then repeat all three cases using a left click on the status item.
      **Fail:** the window stays miniaturized, typing stays with the
      other app, a second click is needed, or the panel appears.
      Paste the relevant stream lines: `editor window=open` is emitted
      only when the window is created (`PrimaryEditorWindowController.show`);
      `key gain=editor-window` is emitted only when the panel still owns
      the page (`BackdropModel.keyStatusChanged`). Neither line is
      required for an already open or miniaturized editor that owns the
      page; confirm the active app and typing in every case. Accepted
      ADR-0033 states: "With the panel off, the hotkey and the status item
      select the editor window." Turn the panel back on and rerun
      **The panel's own summons stay with the panel** above.
- [ ] **Panel off: summons with the editor on another desktop (#215).**
      *Both.* With the panel off and the editor open on Desktop 1,
      activate another app on Desktop 3. Press ⌃⌥Space, then repeat from
      Desktop 3 using a left click on the status item. **Proposed pass:**
      OnetimePad becomes active, the screen switches to Desktop 1, the
      existing editor comes forward keyed, typing enters it without a
      second click, and the panel stays absent. **Fail against this
      proposed expectation:** the screen stays on Desktop 3, the editor
      does not receive typing, or the panel appears. Record the actual
      desktop and keyboard result, including the conditional stream
      evidence described in the preceding check. Switching desktops for
      these gestures is an implementation interpretation, unverified on
      hardware. Accepted ADR-0033 explicitly names ⌘Tab: "⌘Tab from
      another desktop can carry the person to the desktop the editor
      window is on, as it does for any document application." It does
      not explicitly specify Space switching for panel-off summons.
- [ ] **Content clicks focus at the existing caret (#215).** *Both.*
      In a scratch page, type two short lines and leave the caret in
      the middle of the first. Focus another app, then click in the
      blank content below the lines and type a character. Repeat on
      the horizontal checkpoint and its day label. **Pass:** the first
      click focuses the editor and typing resumes at the saved caret;
      neither the selected page nor the caret changes on that click.
      Repeat in the panel, the editor window, an empty buffer, and an
      unsaved file. Then fill a buffer with several lines and click a
      specific line: the caret must move there and typing must follow.
      Check a checkpoint's right-click menu and inline rename as well.
      **Fail:** a content click needs a second click, typing goes to
      the other app, blank space moves the caret, a line click fails
      to place it, or rename/context-menu input is intercepted.
      This check records the click behavior requested for #215; it
      remains unrun on hardware.

### A pinned panel floats above the editor window (ADR-0033)

- [ ] **Pin the panel, then raise the editor window keyed.** *Both.*
      Raise the panel (⌃⌥Space) and turn the pin on from the pin
      control in the card header, which is the only pin control and
      is workable only while raised, then open the editor window by
      clicking the Dock tile or by ⌘Tab. **Pass:** the panel floats
      above the editor window; typing goes to the editor window and
      the panel stays visible on top. **Fail:** the panel drops beneath the
      editor window when the editor takes keys, or the editor floats
      above the panel. Pin means the panel is above every ordinary
      window, editor included; the editor window itself never floats.
- [ ] **Editor never becomes floating.** *Editor.* The log cannot
      judge this: no line names the editor window's level, and the
      altitude lines are the panel's. The probe's sample list can, since
      it prints every on screen window's `layer=` (build it with
      `scripts/dev.sh --with-probe`, as the full-screen section below
      describes). A normal window shows `layer=0`; a `.floating` one
      shows `layer=3`. The editor window is the pad's window whose
      `window=` number is not the card's, which the surface's
      `stance=... window=N` line gives. With the pin off, open the
      editor window, start `dist/window-order-probe --after 5`, and
      click into the editor window so it is keyed when the sample
      fires. Then start it again and press ⌃⌥Space within the five
      seconds, so the panel is raised and keyed over the editor window
      when it fires. **Pass:** the editor window's line reads `layer=0`
      in both samples, and in the second the card's reads `layer=3`.
      The editor's level rule is AppKit's, not the surface's altitude
      resolver. **Fail:** the editor window shows any layer other than
      0.

### Editor window full screen (ADR-0033)

The editor window enters and leaves full screen by AppKit's rules,
through the green button in its title bar. A hotkey summon over an
editor window in full screen must land the panel on that Space: the
panel is on every Space, and a summoned panel floats, which is when it
carries `.fullScreenAuxiliary` (ADR-0034: "Full screen participation
follows altitude, not stance.").

- [ ] **Enter and leave full screen.** *Editor.* Open the editor
      window, click the green button. **Pass:** it enters full screen
      on its own Space with AppKit's animation and title bar autohide
      behaviour. Move the mouse to the top of the screen to reveal the
      title bar and click the green button again. Escape is not a way
      out: in the editor window it is the page keymap's
      `surface::HandBackKeys`, which leaves the ledger or does nothing.
      **Pass:** it leaves full screen and returns to the desktop it
      was on. **Fail:** the enter or leave animation is broken, the
      title bar does not autohide, or the exit lands on a different
      desktop.
- [ ] **Hotkey summon over an editor window in full screen.**
      *Panel.* Put the editor window in full screen. From inside its
      Space press ⌃⌥Space. **Pass:** the panel raises on the editor's
      full screen Space (all Spaces membership plus
      `.fullScreenAuxiliary` when floating gets it there), the summon
      is a raise not an activation, and typing goes to the panel. Rest
      the panel by clicking outside it in the editor's content.
      **Pass:** the panel rests; the editor keeps the keyboard. The
      full screen Space does not switch during either step.
- [ ] **⌘Tab back to an editor window in full screen.** *Editor.*
      With the editor window full screen, ⌘Tab to another app on a
      desktop and ⌘Tab back. **Pass:** the screen switches to the
      editor's full screen Space and the editor window is keyed.

### Stage Manager and Mission Control (ADR-0033)

The editor window's title is the application's name and never page
content. ADR-0033 gives the reason under Restoration: "a window title
is published to the Window menu, Mission Control and the system window
list". Issue #202 adds Stage Manager to the checks.

- [ ] **Mission Control shows the editor window with the app's
      name.** *Editor.* Leave the panel resting and unpinned. Open the
      editor window, invoke Mission Control (F3 or the trackpad
      gesture). **Pass:** the editor window appears with the title
      *OnetimePad* (or the product name the bundle carries), never a
      page title, and the panel does not appear as its own tile. The
      unpinned rest is the one posture that carries `.stationary`,
      the wallpaper flag that holds it still through a Mission Control
      sweep; a pinned or raised panel does not carry it
      (`BackdropStance.collectionBehavior`), so this check says
      nothing about those. **Fail:** the title bar in Mission Control
      reveals page content, or the panel shows up as its own tile.
- [ ] **Stage Manager groups the editor window under the app's
      name.** *Editor.* Leave the panel resting and unpinned, as
      above. Enable Stage Manager. **Pass:** the editor
      window appears in the strip on the left labelled with the app's
      name and its icon; opening the editor window from the strip
      keys it and switches to its Space. The panel is not a Stage
      Manager participant. **Fail:** the strip shows a page title, or
      the panel shows up as a Stage Manager tile that can be pulled
      out on its own.

### The flicker

Issue #74's flicker was seen on the ⌘Tab return, which raised the
card. ADR-0033 sends that return to the editor window, so the panel no
longer raises on it and the route is retired for this check. Of the
three candidates the membership rewrite is gone; the round trip net and
the resize are still in the code, and two panel routes still run them:
a summon from rest between desktops (the resize and the round trip
net), and a re-key of a raised card that has lost the keyboard (the
round trip net alone). The checks run those.

- [ ] **Summon between desktops, ten times, watching the card.**
      *Panel.* Raise the card on Desktop 1 (⌃⌥Space), rest it (Esc),
      switch to Desktop 3 with ⌃→ and press ⌃⌥Space, watching the card
      itself rather than the screen; rest it, switch back, summon
      again, ten times. **Pass:** the card appears in place. **Fail,
      and the shape of the failure is the diagnosis:**
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
      - The *whole screen* flashes, not the card: that is a Space
        switch, which a hotkey summon never asks for since it activates
        nothing, so the window server moved the window and symptom 1
        has not actually been fixed.
- [ ] **Re-key after a ⌘Tab away, ten times.** *Panel.* Raise the
      card, ⌘Tab to another app on the same desktop (the card drops to
      normal and stays raised), press ⌃⌥Space from there, ten times.
      This is the closest route left to the old return: the card is
      already its own size, so only the round trip net can blink it.
      **Pass:** the card lifts and re-keys in place with no blink.
- [ ] **Pinned, same ten summons.** *Panel.* The pinned rest neither
      resizes nor changes level on a raise, so if the flicker survives
      here it is not the resize.
- [ ] **The write guard, counted.** *Panel.* Restart the stream with
      `--level debug` added, so the altitude lines appear. The key
      transitions counted here are the panel's, so the return has to
      be a route that re-keys the panel: a ⌘Tab back would select the
      editor window and rest the card (ADR-0033). Raise the card
      (⌃⌥Space), then ten times ⌘Tab to another app and press ⌃⌥Space
      from there, and count the `collectionBehavior write=` lines.
      Full-screen participation follows the altitude (ADR-0034), so
      the expected count depends on what holds the card up:
      - Unpinned with the keep-above preference off: exactly one write
        per key transition, so one on each ⌘Tab away (the value gains
        `.fullScreenNone`) and one on each re-key (it regains
        `.fullScreenAuxiliary`). Twenty lines for ten round trips, not
        counting the one the first raise from rest writes. More than
        one per transition means the guard is not holding.
      - Pinned, or with the preference on: no lines at all. The card
        floats on both sides of the transition, the value does not
        change, and any line here is a defect.

      In both cases watch the card while counting: the write names the
      same Space membership as before, so it must cause no flicker and
      no move between desktops. Either one is ADR-0034's first eject
      trigger. A line on a genuine raise or rest, where the posture
      really changed, is expected.

### Normal inactive stacking (ADR-0032, issue #190)

The keyless raised surface now drops to normal window level unless Pin
or the keep-above preference lifts it. What the pure decision returns
is covered by `BackdropAltitudeTests`; what the window server does with
the level under real applications is the part only a person at the
machine can judge.

Two apps beside OnetimePad make the checks cheap: pick two windowed
apps you can ⌘Tab between (Safari and Terminal, say), and leave both
open. Confirm the surface preference **Keep OnetimePad above other apps
when switching away** is off before the first run; the checks that need
it on say so and turn it off again.

Issue #190 lists twelve checks. Eleven are below; the twelfth, About
with Pin on, is the About check under companion windows further down.
Its first check predates ADR-0033 and ended with a ⌘Tab back to a keyed
card; that return now selects the editor window, so the check below
re-keys the card with the hotkey instead.

- [ ] **⌘Tab away stacks normally, preference off.** *Panel.* Raise the
      card (⌃⌥Space), ⌘Tab to another app, and confirm the other app's
      windows cover the card. Then press ⌃⌥Space from that app: the
      card is keyed and floating again, on the same page. **Fail:** the
      card stays above the other app on ⌘Tab away (the previous
      always-above behaviour), or the hotkey does not re-key it. A ⌘Tab
      back to OnetimePad instead selects the editor window and rests
      the card (ADR-0033); that return is the editor window's and is
      checked above.
- [ ] **Hotkey raise, then ⌘Tab between two other apps.** *Panel.*
      With the pad resting, ⌃⌥Space to raise, then ⌘Tab to app A and
      ⌘Tab from A to B without going through OnetimePad. **Pass:** the
      card lowers to normal and each app's windows stack over it in
      turn; no frame shows the card flashing above the newly active
      app.
- [ ] **Preference on: raised stays above.** *Panel.* Open Settings,
      turn **Keep OnetimePad above other apps when switching away** on,
      close Settings. Raise the card, ⌘Tab to another app. **Pass:**
      the card stays above that app's windows. Press ⌃⌥Space from that
      app and confirm the card is still there and takes keys again (a
      ⌘Tab back would select the editor window and rest it, ADR-0033).
      Turn the preference off again before moving on.
- [ ] **Pin outranks both.** *Panel.* With the preference off, raise
      the card and turn the pin on from the header toggle, then ⌘Tab to
      another app; repeat with the card rested (Esc) after pinning.
      **Pass:** the card stays above. Repeat with the preference on and
      confirm the same answer; Pin is the stronger, explicit promise
      (ADR-0032).
- [ ] **Press on a partly covered card takes keys and lifts.** *Panel.*
      With the preference off, raise the card, ⌘Tab to another app whose
      window covers most of the card, and click on the visible sliver of
      the card. **Pass:** the click takes keys, the card lifts to
      floating and types at once. **Fail:** the mouse gate refuses the
      click (a lowered raised surface is a case the exposure gate saw
      rarely before, issue #73) and the press lands in the other app
      instead. Issue #184 lists the same route as its last one.
- [ ] **The first press in another app rests the card, preference on or
      off.** *Panel.* With the preference off, raise the card (⌃⌥Space),
      ⌘Tab to another app, then click once into that app's window.
      Repeat with the preference on. **Pass:** the first press rests
      the card each time (the next `stance=` line reads `resting`),
      and the press lands in the other app. This is the outside click
      rule, unchanged by decision (ADR-0032: "Keep the outside-click
      rule unchanged."). A raised card watches for presses outside it
      whatever its level, and `OutsidePress.rests` spares only a press
      a menu or a modal of ours owns. **Fail:** the card stays raised
      after a press into the other app. A card that rests is not a
      defect here.
- [ ] **Settings from `⌘,`, the app menu and the status item, Pin on and
      off.** *Companion.* Open Settings by each route in turn and close
      it between them: `⌘,` with the card raised and keyed; the app
      menu's Settings… item, with the app active (⌘Tab to it, which
      opens the editor window); and the status item, by ⌥ click or by
      its right click menu's Settings… item. Run all three with the pin
      off, then with the pin on (raise the card, use the header toggle,
      rest it with Esc). **Pass:** every time, Settings opens in front
      of the card, keyed, and what is typed lands in Settings. ADR-0032:
      "When Settings or another ordinary window of OnetimePad takes the
      keyboard, its level must be compatible with the surface's
      resulting inactive altitude." `CompanionLevelFollower` holds
      Settings at the card's keyless altitude for as long as it is open.
      **Fail:** Settings opens beneath the card, or opens without the
      keyboard.
- [ ] **The preference toggled inside Settings over a raised keyless
      card.** *Companion.* With the pin off, raise the card (⌃⌥Space),
      then open Settings with `⌘,`; Settings takes the keyboard, so the
      card is raised and keyless. Turn **Keep OnetimePad above other
      apps when switching away** on, then off, then on, and finish with
      it off. **Pass:** Settings stays in front of the card at every
      toggle. Each toggle moves the card between normal and floating,
      and `CompanionLevelFollower` moves Settings with it. **Fail:**
      Settings is left beneath the card after a toggle.
- [ ] **Open panel round trip on a desktop.** *Panel.* On an ordinary
      desktop, with the pin and the preference off, raise the card
      (⌃⌥Space), press ⌘O, then Cancel. **Pass:** while the open panel
      is up the card is keyless at normal level; after Cancel the card
      is keyed and floating again, and what is typed lands in the page.
      The modal's end is the `.modalReturn` route, which goes back to
      the owner (ADR-0033: "A modal return and a cancelled quit go back
      to the owner."), here the panel, as `.raisePanel(.activation)`.
      **Fail:** the card does not come back keyed and floating. This
      differs from "Our own open panel inside A" below, which runs the
      same round trip inside another app's full-screen Space, where the
      card is expected to leave that Space while the panel is up.
- [ ] **Under Stage Manager, into another app's full-screen Space, and
      on a second display.** *Panel.* Repeat the first two checks of
      this section, ⌘Tab away and the hotkey raise with ⌘Tab between
      two other apps, under each of three conditions: Stage Manager on;
      the other app in its own full-screen Space, judged with the probe
      as the first full-screen check below describes; and a second
      display attached, with the other app's window on the display the
      card is on. **Pass:** under every condition the newly active
      app's windows cover the card, and no frame shows the card above
      them. **Fail:** the card stays drawn above the newly active app
      under any of the three. That is ADR-0032's first eject trigger,
      which names Stage Manager outright: "including under Stage
      Manager".
- [ ] **A summon never flashes at a lower level before coming
      forward.** *Panel.* Put another app's window over the card's
      place. Press ⌃⌥Space and watch the card, rest it (Esc), and
      repeat several times, first unpinned and then pinned. Then raise
      the card, ⌘Tab to the other app so the card drops to normal
      beneath it, and press ⌃⌥Space again. **Pass:** each summon brings
      the card forward above the other window at once; no frame shows
      it beneath that window first. The raise resolves the altitude as
      keyed before the panel is ordered front (ADR-0032: "The raise
      path must apply engaged altitude before ordering the panel
      front"). **Fail:** any frame of the card under the other window
      on its way up.

### Full-screen Spaces (ADR-0034, issue #184)

The observation in `docs/dogfood/potentially-quirky-behaviour.md` was
that ⌘Tab into an app in its own full-screen Space left the card drawn
above that app, although the card had dropped to normal. That was
ADR-0032's first eject trigger firing for this one route. The cause was
not the level: every raised card carried `.fullScreenAuxiliary`, and an
auxiliary window is shown with the full-screen window whatever its
level. ADR-0034 makes full-screen participation follow the altitude, so
a card at normal carries `.fullScreenNone` and stays out of those
Spaces. The checks below are how that is confirmed on hardware.

They are judged by a probe and not by eye.
`scripts/window-order-probe.swift` reads the window server's front to
back list and prints one `VERDICT` line per sample. `scripts/dev.sh
--with-probe` builds it into `dist/window-order-probe` alongside the
debug bundle; the flag is off by default. That bundle runs under
`dev.onetimesecret.pad.debug`, so widen the log predicate for these
checks to
`subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"}`;
the probe itself finds any of the three ids. On a desktop Space, start
it in `--watch` mode so it samples 1.5 s after every app activation and
Space change:

```
dist/window-order-probe --watch --expect behind
```

`--expect behind` passes when the card is absent from the list or
listed after the frontmost app's window. `--expect above` passes when
the card is present and listed before it. If Settings or About is open,
pin the card with `--card-window N`, taking N from the surface's
`stance=... window=N` log line. Record the verdict line in the results
table. Pin and the keep-above preference are off unless a check says
otherwise.

Two routes activate nothing, so `--watch` stays silent for them: a
hotkey summon raises the card without activating OnetimePad, and an
outside click inside A rests it without changing the active app.
Switching to Terminal to sample by hand leaves A's Space, which is the
thing being measured. For those, start a delayed sample on the desktop
and walk back into A before it fires:

```
dist/window-order-probe --after 8 --expect above
```

Start it, go back to A, perform the route within the eight seconds,
wait, and read the verdict in the terminal afterwards. Make the delay
longer if the route needs it.

A `VERDICT SKIP` is never a pass. `pad=not-running` means the probe did
not find the app at all (a dev copy started with a bare `swift run` has
no bundle id; name it with `--pad-pid PID`), and a `reason=card-window`
skip means the `--card-window` number is stale. Fix the cause and sample
again.

- [ ] **⌘Tab into a full-screen Space.** *Panel.* Put app A full screen.
      Raise the card on a desktop, then ⌘Tab into A. **Pass:** the
      screen goes to A's Space, A alone fills it, and the probe prints
      `VERDICT PASS expect=behind` with `card=absent`. **Fail:** the
      card is drawn over A, or the probe lists it ahead of A's window.
      That is ADR-0034's second eject trigger. Note the exact shape:
      whether the pad is composited over the app, or whether only the
      status item's menu draws there.
- [ ] **Hotkey summon inside A, then ⌘Tab to B on a desktop.** *Panel.*
      Two samples. First the summon, which activates nothing: on the
      desktop start the probe with `--after 8 --expect above`, go back
      into full-screen A, press ⌃⌥Space and leave the card up until the
      sample has fired. **Pass:** the card arrives keyed over A and the
      verdict read afterwards is `VERDICT PASS expect=above`. Then, with
      `--watch --expect behind` running, summon inside A again and ⌘Tab
      to app B on a desktop Space. **Pass:** B's windows cover the card
      and the probe prints `VERDICT PASS expect=behind` for B. ⌘Tab back
      into A: the card is not there, and the verdict for A is PASS with
      `card=absent`.
- [ ] **Hotkey summon inside A, then click in A.** *Panel.* On the
      desktop start the probe with `--after 8 --expect behind`, go back
      into A, press ⌃⌥Space, then click A's content beside the card, all
      before the sample fires. **Pass:** the card rests (the outside
      click rule is unchanged) and leaves A's Space, and the verdict
      read afterwards is `VERDICT PASS expect=behind` with `card=absent`
      and a `pad=` that names the running app.
- [ ] **Return by ⌘Tab from the full-screen Space.** *Both.* With the
      card raised at normal on a desktop, the editor window closed, and
      A full screen in front, ⌘Tab to OnetimePad. The probe has no
      verdict for a route that ends with OnetimePad frontmost: with
      `--expect behind` it prints `VERDICT SKIP` with
      `reason=pad-is-frontmost`, and with `--expect above` its card is
      the first window OnetimePad owns, which is now the editor window.
      Judge this one by eye and by the stream. **Pass:** the screen
      leaves A's Space for a desktop, the editor window opens there
      keyed (the stream carries `editor window=open`), what is typed
      lands in its page, and the card rests behind it (the next
      `stance=` line reads `resting`). ADR-0033: "The return selects the
      editor window and the panel rests." Record which desktop it
      settled on. **Fail:** the keyboard goes to a window the person
      cannot see, the card comes forward keyed instead of the editor
      window, or the screen changes Space twice.
- [ ] **Pinned, and keep above, still follow.** *Panel.* Pin the card
      and ⌘Tab into A. **Pass:** the card is drawn over A and `--expect
      above` prints PASS. Unpin, turn the preference on, and repeat with
      the same answer. Turn the preference off again afterwards.
- [ ] **Our own open panel inside A.** *Panel.* Inferred from the code
      and not yet seen on hardware (ADR-0034, Consequences). Summon the
      card inside full-screen A, press ⌘O, then cancel the panel. The
      panel takes the keyboard, so the card resolves to normal with
      `.fullScreenNone` and is expected to leave A's Space while its own
      panel is up, then float again when the panel returns the keys.
      There is no special case for modals, by decision. Note three
      things: where the panel opens (over A, or on a desktop), whether
      the card leaves while the panel is up, and whether it comes back
      keyed and floating after Cancel with what is typed landing in the
      page. **Fail:** the card does not come back keyed and floating, or
      the panel opens where the person cannot see it.
- [ ] **A refused raise inside A.** *Panel.* If a modal panel of another
      app holds the keyboard when the hotkey is pressed inside A, the
      card may appear and disappear once. That is the reconcile dropping
      a raise that did not take (ADR-0034), and it is correct. A card
      that stays, keyless, over A is a fail.

### B4 activation routes (ADR-0033, issue #210)

B4 sent every activation and every summon through one routing table,
`ActivationRouter.decide` in `ActivationRoute.swift`, which carries out
ADR-0033's rule that launch and activation are decided by route. Issue
#210 owes a probe run of each route B4 added or changed, against a dev
build. Build and launch with `scripts/dev.sh --with-probe`, and in a
terminal on a desktop run the command the issue gives:

```
dist/window-order-probe --pad-pid <dev-pid> --watch --expect behind
```

`--pad-pid` adds the dev process to the pads the probe knows and
excludes none, so with the installed copy running as well, pin the dev
card with `--card-window N`, taking N from the dev build's
`stance=... window=N` line. Pin it whenever the editor window is open,
too: without a pin the probe takes the pad's frontmost window of real
size, which can then be the editor window. The card is unpinned and the
keep above preference off unless a route says otherwise.

Each route is judged the same way. While another app is frontmost the
card must be behind its window or absent: `VERDICT PASS
expect=behind`. While OnetimePad is frontmost the probe prints
`VERDICT SKIP` with `reason=pad-is-frontmost`, which is expected there
and judges nothing, so the window outcome is read from the stream. Any
`VERDICT FAIL` fails the route, and issue #210 treats it as a
regression. Paste each route's verdict lines into its row. Issue #210
also asks that ADR-0034 Amendment 1's case, ⌘Tab into a full-screen
Space unpinned with the preference off, has not regressed; that is the
first full-screen check above, and its row records it.

- [ ] **⌘Tab to another app, then back.** *Both.* With OnetimePad
      active and the editor window keyed (⌘Tab to it), raise the card
      with ⌃⌥Space so it owns the page and holds the keyboard. ⌘Tab to
      another app on the same desktop and wait for the sample, then
      ⌘Tab back to OnetimePad and wait for the next. **Pass:** the
      sample on the way out reads `VERDICT PASS expect=behind`, the card
      having dropped to normal behind the other app's window. On the
      way back the editor window comes forward keyed and the raised
      card rests as it takes the keyboard (the stream carries `key
      gain=editor-window turn=rests-panel`), and that sample reads
      `VERDICT SKIP` with `reason=pad-is-frontmost`. The return is a
      `.lateActivation`, which the routing table answers with the
      editor window. **Fail:** any `VERDICT FAIL`, or the return keys
      the card instead of the editor window.
- [ ] **Dock click while the editor window is closed.** *Editor.* Close
      the editor window (⇧⌘W), which hands the activation back (the
      last route below), so another app is frontmost. Click the Dock
      tile. **Pass:** the editor window opens keyed on this desktop
      (the stream carries `editor window=open`), the card is not
      raised, and the sample reads `VERDICT SKIP` with
      `reason=pad-is-frontmost`, with no `VERDICT FAIL` before it. A
      Dock click on an inactive app arrives as an activation and may
      also arrive as a reopen, and the routing table answers both with
      the editor window, opening it when it is closed. **Fail:** the
      panel raises, the editor window does not open, or any `VERDICT
      FAIL`. This differs from "The Dock icon, editor closed" above,
      which starts on another desktop and is judged by eye on whether
      the desktop changes; this one stays on one desktop and is judged
      by the probe and the stream.
- [ ] **Reopen: ⌘H, then click the Dock icon.** *Editor.* With the
      editor window open and keyed, press ⌘H. The app hides, another app
      becomes frontmost, and the sample reads `VERDICT PASS
      expect=behind`. Click the Dock tile. **Pass:** the app comes back,
      the editor window comes forward keyed (the reopen and the
      activation both route to `.openEditorWindow`), the card is back at
      rest, and the sample reads `VERDICT SKIP` with
      `reason=pad-is-frontmost`. **Fail:** the panel raises instead of
      the editor window, the editor window stays hidden, or any `VERDICT
      FAIL`. This differs from "Reopen selects the editor window" above,
      which closes the window rather than hiding the app.
- [ ] **Modal return: open Settings, close it.** *Both.* Settings is
      not a modal session. Its close is read by the key turn rule
      (`BackdropModel.auxiliaryWindowReleasedKeys` and `keyTurn`), which
      sends the keyboard back to the owner as ADR-0033 asks of a modal
      return ("A modal return and a cancelled quit go back to the
      owner."). Run it twice. First, with the editor window open and
      the card raised and keyed (⌃⌥Space), press `⌘,`, then close
      Settings with its close button. **Pass:** the card is still
      raised and has the keyboard again. If AppKit keys the editor
      window on the way out, the stream reads `key gain=editor-window
      turn=returns-keys armed=true` and the card is keyed a turn later.
      Second, with the card resting and the editor window keyed, open
      and close Settings the same way. **Pass:** the editor window has
      the keyboard again. Both times the samples read `VERDICT SKIP`
      with `reason=pad-is-frontmost`. **Fail:** the first run rests the
      card (a `turn=rests-panel` line after the close), the second
      leaves no window of ours keyed, or any `VERDICT FAIL`.
- [ ] **Cancelled quit: a first ⌘Q the flush refuses, back to the
      owner.** *Both.* There is no quit sheet to cancel. The first ⌘Q
      is cancelled only when the flush is refused or the session holds
      work it may not write (`QuitPrompt.terminateReply`,
      `PageModel.quitOutcome`), and the app then puts the quit anyway
      line under the page. The locked keychain procedure produces such
      a session: follow steps 1, 3 and 4 of its Case 1
      ([`locked-keychain.md`](locked-keychain.md)) with the dev build in
      place of the installed app, then type a line on the page. A
      second ⌘Q in the same session quits, so each owner takes a
      session of its own. In the first, with the editor window keyed,
      press ⌘Q once. In the second, with the app active, press ⌃⌥Space
      so the card owns and holds the keyboard, then press ⌘Q once.
      **Pass:** the app keeps running, and the window that owns the
      page comes forward keyed with the quit anyway line under its
      page: the editor window in the first session
      (`.openEditorWindow(.activation)`), the card in the second
      (`.raisePanel(.activation)`). The samples read `VERDICT SKIP`
      with `reason=pad-is-frontmost`, and a second ⌘Q quits. **Fail:**
      the first ⌘Q quits, the window that does not own the page comes
      forward instead, or any `VERDICT FAIL`.
- [ ] **Summon over a full-screen Space, Esc, back to the underlying
      app.** *Panel.* This route activates nothing, so `--watch` stays
      silent; run it with a delayed sample, as issue #210 says. Put app
      A full screen. On a desktop start `dist/window-order-probe
      --pad-pid <dev-pid> --after 8 --expect behind`, with
      `--card-window N` as above, then go into A, press ⌃⌥Space, then
      Esc, all before the sample fires. **Pass:** the card arrives over
      A keyed and then rests, A has the keyboard back (what is typed
      lands in A), and the verdict read afterwards is `VERDICT PASS
      expect=behind`. Record whether it says `card=absent` or gives the
      card an index behind A's window. **Fail:** `VERDICT FAIL`, the
      card left drawn over A, or the keyboard left with a card that has
      rested. This differs from "Summoned from another app's
      full-screen Space" above, which checks that the summon lands and
      takes keys; this one checks the rest that follows, by the probe.
- [ ] **Editor window close hands activation back.** *Editor.* With
      the editor window keyed, the card resting, Settings and About
      closed, and another app's window on the same desktop, press ⇧⌘W.
      **Pass:** the editor window closes (the stream carries `editor
      window=closed`), OnetimePad deactivates and another app takes
      the keyboard, and the sample that activation triggers reads
      `VERDICT PASS expect=behind`. The close hands the activation back
      because no window of ours that can take the keyboard is left
      (`PrimaryEditorWindowController.closeHandsBackActivation`).
      **Fail:** OnetimePad stays active with no window that can take
      the keyboard, so typing goes nowhere, or any `VERDICT FAIL`.

### Companion windows follow the surface (ADR-0032, issue #188)

- [ ] **About stays in front while Pin and the preference move.**
      *Companion.* With the card resting and unpinned, open About and
      leave it open. Raise the card (⌃⌥Space), turn the pin on from the
      header toggle and rest it (Esc). **Pass:** the card floats and
      About is still in front of it. Raise the card and turn the pin
      off, open Settings and turn **Keep OnetimePad above other apps
      when switching away** on, then off, with About still open.
      **Pass:** About is never left underneath the card at any step.
      **Fail:** About is stranded beneath the card after a toggle, which
      is what a level read only once at open produces. Its first pass,
      About in front of the card with the pin on, is also issue #190's
      check About with Pin on.

### The drag, which is a decision rather than a fix

- [ ] **Drag the card to the right edge of the screen and hold.**
      *Panel.* Expected: nothing happens; the card stops at the edge,
      clamped. The desktop does not change. If the card instead escapes
      the screen or lands askew, that is a clamping defect and worth its
      own issue; the refusal to change desktops is not.

## Results

The 2026-09-28 rows record the maintainer's report of that run; the
machine was not recorded and no probe output was pasted. One row per
check when a session runs it, and the rows stay: a re-run adds a row
rather than replacing one. The *Role* column names which window the row
is about, in the split ADR-0033 gives.

| Date | Machine and macOS | Role | Check | Pass or fail | Notes |
|---|---|---|---|---|---|
| | | editor | resting card, ⌘Tab from another desktop with the editor window closed: the editor window opens here | | ADR-0033. |
| | | both | raised card, ⌘Tab from another desktop with the editor window closed: the editor window opens here and the panel rests | | ADR-0033. |
| | | panel | pinned across ⌃→ and ⌃← | | |
| | | editor | Dock icon from another desktop with the editor window closed: the editor window opens here | | ADR-0033. |
| | | companion | Settings opens where the user is | | |
| | | companion | About follows a ⌘Tab to the user's desktop, and the editor window opens beside it | | ADR-0033. |
| | | companion | the same for About opened from the app menu | | |
| | | panel | summon from a full-screen Space lands and takes keys | | One blink there is the landing, not the flicker. |
| | | panel | ten summons between desktops, unpinned | | Record the shape of any flicker. The ⌘Tab return route was retired by ADR-0033. |
| | | panel | ten hotkey re-keys after a ⌘Tab away | | |
| | | panel | ten summons between desktops, pinned | | |
| | | panel | collectionBehavior writes: one per key transition (⌘Tab away, hotkey re-key) unpinned with preference off, none pinned or keep above | | Needs `log stream --level debug`. ADR-0034. |
| 2026-09-28 | not recorded | editor | ⌘Tab from another desktop selects the editor window and changes desktops | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | Dock icon selects the editor window when open | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | reopen selects the editor window, not the panel | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | hotkey, status item and resting card click stay with the panel | pass | ADR-0033. Reported passed by the maintainer. |
| | | both | panel off: hotkey and status item focus the editor, closed, open and miniaturized | | #215. Record active app, typing and conditional stream evidence; rerun panel-on summons. |
| | | both | panel off: hotkey and status item with the editor on another desktop | | #215. Unverified implementation interpretation; record actual desktop and keyboard result against the proposed expectation. |
| | | both | blank content and checkpoint clicks focus at the saved caret; line clicks place it | | #215. Include empty buffers, unsaved files, and checkpoint rename/context menu. |
| 2026-09-28 | not recorded | both | pinned panel floats above the editor window | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | editor window never resolves to floating | pass | ADR-0033. Reported passed by the maintainer under the earlier wording, which read the log; no log line names the editor window's level, so judge a rerun by the probe's `layer=` (0 is normal). |
| 2026-09-28 | not recorded | editor | editor enters and leaves full screen | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | hotkey summon over the editor window in full screen lands the panel on that Space | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | ⌘Tab back to an editor window in full screen | pass | ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | Mission Control shows the editor window titled with the app's name | pass | ADR-0033 Restoration. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | Stage Manager groups the editor window under the app's name | pass | ADR-0033 Restoration. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | ⌘Tab away stacks normally, preference off; the hotkey re-keys | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | hotkey raise then ⌘Tab A→B, no flash | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | preference on: raised stays above on ⌘Tab | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | Pin outranks preference in both stances | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | press on a partly covered card takes keys | pass | ADR-0032, issue #73, #184 and #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | first mouse press in another app rests the card, preference on or off | pass | ADR-0032, #190. The outside click rule, unchanged. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | companion | Settings from `⌘,`, the app menu and the status item, Pin on and off: in front and keyed, never beneath the card | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | companion | preference toggled inside Settings over a raised keyless card: Settings stays in front | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | open panel round trip on a desktop: the card comes back keyed and floating | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | Stage Manager, another app's full-screen Space and a second display: the newly active app covers the card | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | a summon never flashes at a lower level before coming forward | pass | ADR-0032, #190. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | panel | ⌘Tab into a full-screen Space: card absent | pass | Reported passed by the maintainer; the VERDICT line was not pasted. ADR-0034, #184. |
| | | panel | hotkey summon inside full-screen A, then ⌘Tab to B on a desktop | | Paste the VERDICT lines for B and for the return to A. ADR-0034. |
| | | panel | hotkey summon inside full-screen A lands keyed | | Paste the VERDICT line (`--after 8 --expect above`). ADR-0034. |
| | | panel | hotkey summon inside full-screen A, then click in A | | Paste the VERDICT line (`--after 8 --expect behind`). ADR-0034. |
| | | panel | hotkey summon inside full-screen A, ⌘O, cancel | | Where the panel opened, whether the card left, and that it returned keyed and floating. Inferred, not yet seen. ADR-0034. |
| | | both | return by ⌘Tab from the full-screen Space: the editor window opens on a desktop and the card rests | | Record the desktop it settled on and the stance line; the probe skips with OnetimePad frontmost. ADR-0033, ADR-0034. |
| | | panel | pinned and keep above still follow into a full-screen Space | | Paste the VERDICT lines (`--expect above`). ADR-0034. |
| | | panel | refused raise inside A shows one appear and disappear at most | | ADR-0034. |
| 2026-09-28 | not recorded | both | ⌘Tab to another app, then back | pass | B4 probe route, #210. ADR-0033, ADR-0034. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | Dock click while the editor window is closed opens it | pass | B4 probe route, #210. ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | reopen: ⌘H, then click the Dock icon | pass | B4 probe route, #210. ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | both | modal return: open Settings, close it | pass | B4 probe route, #210. ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | both | cancelled quit: a first ⌘Q the flush refuses goes back to the owner | pass | B4 probe route, #210. ADR-0033. Reported passed by the maintainer. Issue #210 words it as cancelling a sheet; the code presents none, see the check. |
| 2026-09-28 | not recorded | panel | summon over a full-screen Space, Esc, back to the underlying app | pass | B4 probe route, #210. ADR-0034. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | editor | editor window close hands activation back | pass | B4 probe route, #210. ADR-0033. Reported passed by the maintainer. |
| 2026-09-28 | not recorded | companion | About stays in front while Pin and the preference are toggled | pass | ADR-0032, #188, and #190 (check 9, About with Pin on). Reported passed by the maintainer. |
| | | panel | edge drag stays on this desktop | | The documented decision, ADR-0019. |
