# Pinned pad over another app's full-screen Space

**Applies to:** OnetimePad, the ambient panel only, resting stance with
the pin on. The primary editor window is a plain activating `NSWindow`
under ADR-0033 and does not carry the pin, all Spaces membership or the
mouse gate; nothing here concerns it.
**Raised by:** issue #73, from the dogfood aberrations log of
2026-08-19.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## What was seen, and what the code did about it

Pinned, with Zed full screen on the active Space, the card was not
visible and yet clicks meant for Zed landed in the pad and were acted
on. A window can be in the window server's hit-test path without being
composited, and that is the only shape the report fits.

Two changes answer it, and they are deliberately independent, because
only one of them can be judged without a person at the machine:

1. **The mouse gate** (`SurfaceExposure`,
   `BackdropStance.ignoresMouse(pinned:exposure:)`). The surface reads
   back the two signals the window server publishes about itself,
   `isOnActiveSpace` and `occlusionState`, and refuses the mouse
   whenever either says it is out of sight. That the gate follows the
   reported exposure is fail-closed and unit tested. Whether the report
   is truthful for a window kept in the hit-test path without being
   composited is exactly what nobody can establish from the code, and
   the third check below is where it gets asked. The gate cannot make
   the card visible in any case; it can only stop a card the server
   admits it is not showing from acting.
2. **The collection behavior** (`BackdropStance.collectionBehavior`).
   The pinned rest no longer carries `.stationary`, which belonged to
   the wallpaper recipe the unpinned rest is built from. What is left,
   `.canJoinAllSpaces` with `.fullScreenAuxiliary`, is the overlay
   recipe AppKit documents. If the invisibility came from asking for an
   undefined combination, this is what fixes it.

Both changes rest on something only hardware can decide. Change 2 is a
hypothesis about why the card was invisible. Change 1 holds whether or
not that hypothesis is right, but only so far as the server's own report
is honest: if it says a card it never composited is unoccluded, the gate
believes it and the invisible clicks come back. That is the failure
called out below, and the section after the checks says what to try
next. This procedure is what tells the three outcomes apart.

## Setting up

Quit any running copy first (`scripts/quit-app.sh`; only the graceful
path saves state), then `scripts/package-app.sh && open
dist/OnetimePad.app`.

In a second terminal, watch the surface's own log, which now carries the
gate:

```
log stream --predicate 'subsystem == "com.onetimesecret.pad"'
```

The line to look for is `mouse gate=closed onActiveSpace=… unoccluded=…`
or its `open` counterpart. It is printed only when the gate moves.

Then: raise the card (⌃⌥Space) and turn the pin on from the pin control
in the card header, which is the only pin control and is workable only
while raised, since a click on a resting card means raise; rest the
card (Esc), put Zed (or any app) into full screen on its own Space, and
switch to that Space.

## The checks

- [ ] **The card over the full-screen Space.** Is it visible?
      **Visible** means change 2 worked and the pin now keeps its
      promise. **Not visible** means it did not, and the pin's promise
      over full-screen Spaces is still unkept; that is a separate defect
      to file, not a failure of this procedure.
- [ ] **The acceptance criterion.** Click where the card is, or would
      be. The click must reach the full-screen app and do there what it
      would have done with the pad quit: place a cursor in Zed, hit a
      button, select a line. Nothing may happen in the pad. This is the
      line issue #73 asked for and it must hold in both outcomes of the
      check above.
- [ ] **The log agrees.** If the card is invisible there, the stream
      must carry `mouse gate=closed` with `unoccluded=0` (or
      `onActiveSpace=0`) around the moment of the Space switch. A closed
      gate with an invisible card is the fix working. **An invisible
      card with the gate still open is the important failure**, and see
      below.
- [ ] **Coming back.** Leave the full-screen Space for an ordinary
      desktop. The card is visible again, the stream carries `mouse
      gate=open` within about a second (the Space switch is read once
      promptly and once when the transition has settled, and the settled
      reading is the one that decides), and a click on the card raises it
      as it always did. A card that stays visible but stops answering
      clicks is a gate stuck shut, which is the one regression this
      change can cause. Switch back and forth half a dozen times: the
      gate must come back open every time, not merely the first.
- [ ] **The pin, toggled under a cover.** On an ordinary desktop with
      another app's window covering the card's resting place
      completely, raise the card with ⌃⌥Space (it comes up over the
      cover), turn the pin on and off from the header toggle a few
      times, ending with it on, and rest the card (Esc); then move the
      covering window aside. The card answers a click. The pin writes
      the gate from a settled reading taken after the level and frame
      have moved, so a pin judged from the posture it was leaving would
      show up here as a card that never comes back.
- [ ] **The pin, toggled while raised.** Same full cover, but raise the
      card first with ⌃⌥Space, then toggle the pin from the header
      toggle (a control inside the card, so the raise survives the
      click). Roughly a second later the stream carries `mouse
      gate=closed`. The pin rewrites the gate
      from the stance's own ungated rule, which for a raise is open, and
      the settling reading that follows may not close it over a raise;
      the scheduled reading is the only thing that will. Silence here
      means an invisible card left holding the mouse for as long as the
      raise lasts.
- [ ] **The unpinned rest is untouched.** Raise the card, turn the pin
      off from the header toggle and rest it (Esc), then click over
      the card on a bare desktop: the click still passes through to the
      Finder desktop (ADR-0015). Nothing in this change may hand the
      unpinned rest a click.
- [ ] **The raise still takes its first click.** Pinned, on an ordinary
      desktop, with another app's window covering the card **completely**
      (not merely most of the screen: `occlusionState` reports visible
      while any sliver of the window shows, so a partial cover never
      produces the reading this check is about). ⌃⌥Space to raise, then
      click straight into the card's text. The keystroke lands, and the
      stream carries no `mouse gate=closed` in that moment. This is the
      timing the gate could plausibly get wrong, since the reading is
      taken a turn after the ordering and the occlusion state can still
      be the pre-raise one; a gate closed there would pass the click to
      the app underneath, and the outside click rule would then rest the
      card the raise had just put up. The line to look for if it goes
      wrong is `mouse gate=held open (settling over a raised surface)`,
      which is the guard doing its job.
- [ ] **The raise's own second reading.** Same setup, but wait about two
      seconds after the raise before clicking, and keep watching the
      stream. The raise takes a further reading roughly a second in,
      this time with the authority to close the gate the settling turn
      had to leave open. A card that really is on top must still answer
      the click, so `mouse gate=closed` there would be a card raised
      into view and then made deaf, which is a defect. The reading
      exists for the opposite case, a card the server never brought
      forward, where the gate must end up closed even though no
      occlusion change is ever posted.
- [ ] **Waking and unlocking.** Pinned, on an ordinary desktop. Lock the
      screen with ⌃⌘Q, unlock a few seconds later (before the displays
      sleep, so the wake notification cannot be what answers), and click
      the card. It raises. The stream carries a `mouse gate=` line only
      if the gate actually moved, so silence here with a working click is
      the pass; a visible card that stops answering after a wake is the
      failure this check is for.

      Note what this check does not prove. A gate that was never wrongly
      shut answers the click either way, so a pass here is consistent
      with the unlock going unheard. What it would take to see the
      reading itself is a card whose gate is already shut, which is a
      state nothing can be asked to produce on purpose. Treat the pass
      as the absence of the symptom, and if a card is ever found deaf
      after an unlock, the first thing to establish is whether
      `com.apple.screenIsUnlocked` is still posted under this macOS,
      since it is the only signal an ordinary lock gives.

## If the gate stays open over an invisible card

Then macOS is reporting the surface as on the active Space and
unoccluded while declining to draw it, and neither AppKit signal can see
the difference. The next signal to try is the window server's own list:
`CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` and
whether `panel.windowNumber` appears in it, which answers "is this
window on screen right now" without going through the window's own
opinion of itself. It would slot into `SurfaceExposure` as a third
signal with no change to the decision, which already takes the strictest
reading of everything it is given. Record the log lines here before
making that change, since they are the evidence for it.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | card visible over full screen | | The hypothesis, change 2. |
| | | clicks reach the full-screen app | | The acceptance criterion. |
| | | log shows the gate closing | | |
| | | gate reopens off the full-screen Space | | Every switch, not only the first. |
| | | pin toggled under a full cover | | |
| | | pin toggled while raised under a full cover | | |
| | | unpinned rest still passes clicks through | | |
| | | first click after a raise lands | | |
| | | the raise's second reading leaves a visible card clickable | | |
| | | the card still answers after a wake or an unlock | | |
