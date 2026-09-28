# Spaces, ⌘Tab and the pad

**Applies to:** OnetimePad. Two window roles, since ADR-0033: the
ambient panel (both stances, pinned and not) and the primary editor
window (an ordinary activating `NSWindow`). Each check below is scoped
to one role or the other; nothing here assumes the raised card is the
all Spaces panel.
**Raised by:** issue #74, from the dogfood aberrations log of
2026-08-19.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Scope after ADR-0033

ADR-0033 separated the primary editor from the ambient panel. What the
window server sees is now two windows with different roles:

- **The ambient panel** keeps its all Spaces membership, its stance
  driven level, its outside click rule, and its hotkey and status item
  summons. Every check below marked *panel* is about that window.
- **The primary editor window** is a plain activating `NSWindow` with
  ordinary Space membership, normal window level, AppKit's own full
  screen, key and main behaviour, and participation in ⌘Tab, the
  Window menu, Mission Control and Stage Manager. Every check marked
  *editor* is about that window and the AppKit behaviour it inherits.

A person's launch, a Dock click, a reopen and ⌘Tab select the editor
window (opening it when closed); the hotkey, the status item and the
resting card click stay with the panel. A pinned panel floats above
every ordinary window, editor included; the editor never floats.

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
log stream --predicate 'subsystem == "com.onetimesecret.pad"'
```

## The checks

### The return: panel only, editor window closed

These are the checks issue #74 was filed for. They apply when the
editor window is **closed**, so ⌘Tab has nothing else of ours to select
and ADR-0019 is what decides where the return lands. Close the editor
window (⇧⌘W) before starting each check.

- [ ] **Resting, from another desktop.** *Panel.* With the pad resting
      and the editor window closed, go to Desktop 3, work in another
      app, then ⌘Tab to OnetimePad. **Pass:** the desktop does not
      change and the card raises where you already were. **Fail:** the
      screen slides to Desktop 1.
- [ ] **Raised, from another desktop.** *Panel.* Raise the card on
      Desktop 3 (⌃⌥Space) with the editor window closed, ⌘Tab away to
      another app, ⌘Tab back. Same pass condition, and the card must
      come back keyed: type a character and it lands in the page.
      *ADR-0033 note:* with the editor window **open**, this route
      instead selects the editor window and rests the panel; that is
      the editor case below.
- [ ] **Pinned, across a switch.** *Panel.* Raise the card
      (⌃⌥Space), turn the pin on from the header toggle and rest it
      (Esc), then switch desktops with ⌃→ and ⌃←. The card stays put
      and readable on each, and the log carries no `mouse gate=closed`
      line while it is plainly visible.
- [ ] **The Dock icon, editor closed.** *Panel.* From Desktop 3 with
      the editor window closed, click the Dock tile. The panel raises
      on Desktop 3.
- [ ] **Summoned from another app's full-screen Space.** *Panel.*
      Unpinned, put an app full screen, and from inside it press
      ⌃⌥Space. The card arrives on the full-screen Space, keyed, and
      takes what you type. A single blink as it arrives is correct
      here and not the flicker: an unpinned rest declines full-screen
      Spaces, so the card really was elsewhere and the summon's round
      trip is what brings it. The log carries `summon=round trip
      (surface was off-Space)` for it. **Fail:** the card does not
      appear, or appears and takes no keys.
- [ ] **Settings does not drag the app back.** *Panel companion.* Open
      Settings on Desktop 1, close it, go to Desktop 3, press ⌘, again.
      It opens on Desktop 3.
- [ ] **About does not drag the app back either.** *Panel companion.*
      About is a second ordinary window and AppKit reuses one instance
      of it. With the editor window closed, open About from the tray on
      Desktop 1, leave it open, go to Desktop 3 and ⌘Tab to OnetimePad:
      the desktop must not change, and the panel comes here rather
      than staying behind. Then choose About again from the tray on
      Desktop 3 and confirm it appears on Desktop 3.
- [ ] **The same, from the app menu.** *Panel companion.* Repeat the
      check above, but open About from the menu bar's OnetimePad menu
      rather than the tray. This is the route that used to bypass the
      fix entirely, since SwiftUI synthesizes that item against
      AppKit's own panel call; a pass on the tray route says nothing
      about it. ⌘Tab to the app first, which is what puts the menu on
      screen.

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
      to Desktop 3, work in another app, then ⌘Tab to OnetimePad.
      **Pass:** the screen switches to
      Desktop 1, the editor window comes forward keyed and the panel
      rests (its `holdsKeys` becomes false). **Fail:** either the
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
      Desktop 3 instead (that route is now reserved for the editor
      window per ADR-0033's activation routing table).
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
      window keeps its Space. The click on the resting card, when the
      resting card is visible, must do the same. **Fail:** any of
      those three summons activates the app or switches desktops.

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
- [ ] **Editor never becomes floating.** *Editor.* With the pin off,
      raise the editor window and confirm from `log stream --level
      debug --predicate 'subsystem == "com.onetimesecret.pad"'` that
      no altitude line names the editor window at `.floating`. The
      editor's level rule is AppKit's, not the surface's altitude
      resolver. **Fail:** any writer lifts the editor window off
      normal level.

### Editor window full screen (ADR-0033)

The editor window enters and leaves full screen by AppKit's rules (the
green traffic light, the Window menu's Enter Full Screen item, F11 if
bound). A hotkey summon over an editor window in full screen must land
the panel on that Space, since the panel is all Spaces and its stance
alone decides where it appears.

- [ ] **Enter and leave full screen.** *Editor.* Open the editor
      window, click the green traffic light. **Pass:** it enters full
      screen on its own Space with AppKit's animation and title bar
      autohide behaviour. Click the green light again (revealed by
      moving the mouse to the top of the screen) or press Escape.
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
content (ADR-0033 Restoration). That title is what Mission Control,
Stage Manager and the system window list publish.

- [ ] **Mission Control shows the editor window with the app's
      name.** *Editor.* Open the editor window, invoke Mission Control
      (F3 or the trackpad gesture). **Pass:** the editor window
      appears with the title *OnetimePad* (or the product name the
      bundle carries), never a page title, and the panel does not
      appear as its own tile (the panel is all Spaces and stationary
      furniture, not a Mission Control participant). **Fail:** the
      title bar in Mission Control reveals page content, or the panel
      shows up as its own tile.
- [ ] **Stage Manager groups the editor window under the app's
      name.** *Editor.* Enable Stage Manager. **Pass:** the editor
      window appears in the strip on the left labelled with the app's
      name and its icon; opening the editor window from the strip
      keys it and switches to its Space. The panel is not a Stage
      Manager participant. **Fail:** the strip shows a page title, or
      the panel shows up as a Stage Manager tile that can be pulled
      out on its own.

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
      then ⌘Tab away and back ten times, and count the
      `collectionBehavior write=` lines. Full-screen participation
      follows the altitude (ADR-0034), so the expected count depends on
      what holds the card up:
      - Unpinned with the keep-above preference off: exactly one write
        per key transition, so one on each ⌘Tab away (the value gains
        `.fullScreenNone`) and one on each return (it regains
        `.fullScreenAuxiliary`). Twenty lines for ten round trips. More
        than one per transition means the guard is not holding.
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
- [ ] **Pin outranks both.** With the preference off, raise the card
      and turn the pin on from the header toggle, then ⌘Tab to another
      app; repeat with the card rested (Esc) after pinning. **Pass:**
      the card stays above. Repeat with the preference on and confirm
      the same answer; Pin is the stronger, explicit promise
      (ADR-0032).
- [ ] **Press on a partly covered card takes keys and lifts.** With
      the preference off, raise the card, ⌘Tab to another app whose
      window covers most of the card, and click on the visible sliver
      of the card. **Pass:** the click takes keys, the card lifts to
      floating and types at once. **Fail:** the mouse gate refuses the
      click (a lowered raised surface is a case the exposure gate saw
      rarely before, issue #73) and the press lands in the other app
      instead.

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
`dev.onetimesecret.pad`, so widen the log predicate for these checks to
`subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}`; the
probe itself finds either id. On a desktop Space, start it in `--watch`
mode so it samples 1.5 s after every app activation and Space change:

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

- [ ] **⌘Tab into a full-screen Space.** Put app A full screen. Raise
      the card on a desktop, then ⌘Tab into A. **Pass:** the screen goes
      to A's Space, A alone fills it, and the probe prints `VERDICT PASS
      expect=behind` with `card=absent`. **Fail:** the card is drawn
      over A, or the probe lists it ahead of A's window. That is
      ADR-0034's second eject trigger. Note the exact shape: whether the
      pad is composited over the app, or whether only the status item's
      menu draws there.
- [ ] **Hotkey summon inside A, then ⌘Tab to B on a desktop.** Two
      samples. First the summon, which activates nothing: on the
      desktop start the probe with `--after 8 --expect above`, go back
      into full-screen A, press ⌃⌥Space and leave the card up until the
      sample has fired. **Pass:** the card arrives keyed over A and the
      verdict read afterwards is `VERDICT PASS expect=above`. Then, with
      `--watch --expect behind` running, summon inside A again and ⌘Tab
      to app B on a desktop Space. **Pass:** B's windows cover the card
      and the probe prints `VERDICT PASS expect=behind` for B. ⌘Tab back
      into A: the card is not there, and the verdict for A is PASS with
      `card=absent`.
- [ ] **Hotkey summon inside A, then click in A.** On the desktop start
      the probe with `--after 8 --expect behind`, go back into A, press
      ⌃⌥Space, then click A's content beside the card, all before the
      sample fires. **Pass:** the card rests (the outside click rule is
      unchanged) and leaves A's Space, and the verdict read afterwards
      is `VERDICT PASS expect=behind` with `card=absent` and a `pad=`
      that names the running app.
- [ ] **Return by ⌘Tab from the full-screen Space.** With the card
      raised at normal on a desktop and A full screen in front, ⌘Tab to
      OnetimePad, with the probe on `--expect above`. **Pass:** the card
      ends up keyed and floating in front of the person on the Space
      the switch settles on, what is typed lands in the page, and the
      probe prints `VERDICT PASS expect=above` with `front=OnetimePad`
      (with the pad frontmost there is no target, and the card being on
      screen is the pass). Record which Space it settled on, a desktop
      or A's, and whether `summon=round trip` was logged; one blink with
      that line is the landing. **Fail:** the keyboard goes to a card
      the person cannot see, the probe prints `card=absent`, or the
      screen changes Space twice.
- [ ] **Pinned, and keep above, still follow.** Pin the card and ⌘Tab
      into A. **Pass:** the card is drawn over A and `--expect above`
      prints PASS. Unpin, turn the preference on, and repeat with the
      same answer. Turn the preference off again afterwards.
- [ ] **Our own open panel inside A.** Inferred from the code and not
      yet seen on hardware (ADR-0034, Consequences). Summon the card
      inside full-screen A, press ⌘O, then cancel the panel. The panel
      takes the keyboard, so the card resolves to normal with
      `.fullScreenNone` and is expected to leave A's Space while its own
      panel is up, then float again when the panel returns the keys.
      There is no special case for modals, by decision. Note three
      things: where the panel opens (over A, or on a desktop), whether
      the card leaves while the panel is up, and whether it comes back
      keyed and floating after Cancel with what is typed landing in the
      page. **Fail:** the card does not come back keyed and floating,
      or the panel opens where the person cannot see it.
- [ ] **A refused raise inside A.** If a modal panel of another app
      holds the keyboard when the hotkey is pressed inside A, the card
      may appear and disappear once. That is the reconcile dropping a
      raise that did not take (ADR-0034), and it is correct. A card that
      stays, keyless, over A is a fail.

### Companion windows follow the surface (ADR-0032, issue #188)

- [ ] **About stays in front while Pin and the preference move.** With
      the card resting and unpinned, open About and leave it open.
      Raise the card (⌃⌥Space), turn the pin on from the header toggle
      and rest it (Esc). **Pass:** the card floats and About is
      still in front of it. Raise the card and turn the pin off, open
      Settings and turn **Keep OnetimePad above other apps when
      switching away** on, then off, with About still open. **Pass:**
      About is never left underneath the card at any step. **Fail:**
      About is stranded
      beneath the card after a toggle, which is what a level read only
      once at open produces.

### The drag, which is a decision rather than a fix

- [ ] **Drag the card to the right edge of the screen and hold.**
      Expected: nothing happens; the card stops at the edge, clamped.
      The desktop does not change. If the card instead escapes the
      screen or lands askew, that is a clamping defect and worth its own
      issue; the refusal to change desktops is not.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one. The *Role* column
names which window the row is about, in the split ADR-0033 gives.

| Date | Machine and macOS | Role | Check | Pass or fail | Notes |
|---|---|---|---|---|---|
| | | panel | resting ⌘Tab from another desktop, editor closed | | |
| | | panel | raised ⌘Tab from another desktop, editor closed | | |
| | | panel | pinned across ⌃→ and ⌃← | | |
| | | panel | Dock icon from another desktop, editor closed | | |
| | | panel companion | Settings opens where the user is | | |
| | | panel companion | About opens where the user is, and follows a ⌘Tab | | |
| | | panel companion | the same for About opened from the app menu | | |
| | | panel | summon from a full-screen Space lands and takes keys | | One blink there is the landing, not the flicker. |
| | | panel | ten ⌘Tab returns, unpinned (editor closed) | | Record the shape of any flicker. |
| | | panel | ten ⌘Tab returns, pinned (editor closed) | | |
| | | panel | collectionBehavior writes: one per key transition unpinned with preference off, none pinned or keep above | | Needs `log stream --level debug`. ADR-0034. |
| | | editor | ⌘Tab from another desktop selects the editor window | | ADR-0033. |
| | | editor | Dock icon selects the editor window when open | | ADR-0033. |
| | | editor | reopen selects the editor window, not the panel | | ADR-0033. |
| | | panel | hotkey, status item and resting card click stay with the panel | | ADR-0033. |
| | | both | pinned panel floats above the editor window | | ADR-0033. |
| | | editor | editor window never resolves to floating | | ADR-0033; needs `log stream --level debug`. |
| | | editor | editor enters and leaves full screen | | ADR-0033. |
| | | panel | hotkey summon over the editor window in full screen lands the panel on that Space | | ADR-0033. |
| | | editor | ⌘Tab back to an editor window in full screen | | ADR-0033. |
| | | editor | Mission Control shows the editor window titled with the app's name | | ADR-0033 Restoration. |
| | | editor | Stage Manager groups the editor window under the app's name | | ADR-0033 Restoration. |
| | | panel | ⌘Tab away stacks normally, preference off, editor closed | | ADR-0032, #190. |
| | | panel | hotkey raise then ⌘Tab A→B, no flash | | ADR-0032, #190. |
| | | panel | preference on: raised stays above on ⌘Tab | | ADR-0032, #190. |
| | | panel | Pin outranks preference in both stances | | ADR-0032, #190. |
| | | panel | press on a partly covered card takes keys | | ADR-0032, issue #73 and #190. |
| | | panel | ⌘Tab into a full-screen Space: card absent | | Paste the VERDICT line. ADR-0034, #184. |
| | | panel | hotkey summon inside full-screen A, then ⌘Tab to B on a desktop | | Paste the VERDICT lines for B and for the return to A. ADR-0034. |
| | | panel | hotkey summon inside full-screen A lands keyed | | Paste the VERDICT line (`--after 8 --expect above`). ADR-0034. |
| | | panel | hotkey summon inside full-screen A, then click in A | | Paste the VERDICT line (`--after 8 --expect behind`). ADR-0034. |
| | | panel | hotkey summon inside full-screen A, ⌘O, cancel | | Where the panel opened, whether the card left, and that it returned keyed and floating. Inferred, not yet seen. ADR-0034. |
| | | panel | return by ⌘Tab from the full-screen Space | | Paste the VERDICT line (`--expect above`) and the Space it settled on. ADR-0034. |
| | | panel | pinned and keep above still follow into a full-screen Space | | Paste the VERDICT lines (`--expect above`). ADR-0034. |
| | | panel | refused raise inside A shows one appear and disappear at most | | ADR-0034. |
| | | panel companion | About stays in front while Pin and the preference are toggled | | ADR-0032, #188. |
| | | panel | edge drag stays on this desktop | | The documented decision, ADR-0019. |
