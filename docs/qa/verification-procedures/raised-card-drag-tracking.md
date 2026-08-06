# Raised card: drag and resize tracking

**Applies to:** `CompanionBackdrop` (OnetimePad), raised stance.
**Raised by:** review of `966ba3c` "Measure the drag and the resize
grips against the screen", on
`feature/reopen-and-backdrop-persistence`, 2026-08-06.
**Status:** open. Not yet run on hardware.

Everything below is captured verbatim from the review exchange, in the
words it was written in. Nothing is paraphrased or condensed.

## The guidance, as given

> Hand-test the drag. The screen-anchored math is right, but whether
> SwiftUI keeps firing onChanged while the window travels under a
> steady pointer is the kind of thing this project's rules say to
> verify on hardware. If the card moves once and stalls, the fix is to
> drive the drag from an NSEvent local monitor instead of the gesture
> value — tell me and I'll do it.

## What that guidance is about

The math in `paneTranslation` is not in question. The question is
whether SwiftUI keeps calling `onChanged` at all once the window starts
moving.

A `DragGesture` value is derived from the pointer's position **in a
view's coordinate space**. The raised window is now the card itself,
and the card follows the pointer, so as far as the view is concerned
the pointer is standing still: mouse-down at local (40, 8), window
moves 5pt right, pointer moves 5pt right, still local (40, 8). If
SwiftUI emits `onChanged` per delivered `mouseDragged` event,
everything works, because the callback ignores `value` and re-reads
`NSEvent.mouseLocation`. If SwiftUI suppresses updates whose computed
value did not change, the callback stops firing and the card freezes
after the first step. This is exactly the class of behavior AppKit does
not document and a unit test cannot reach, hence "verify on hardware".

## How to tell, in about a minute

Quit any running instance first (`swift build` re-signs in place and
SIGKILLs a live one), then
`scripts/build-backdrop.sh && open dist/CompanionBackdrop.app`.

- Raise with ⌃⌥Space, press the header, drag slowly across the screen.
  **Pass:** the card stays glued to the pointer for the whole sweep.
  **Fail:** it jumps once, then sits still while your pointer walks
  away, possibly twitching each time you move fast enough to outrun the
  window.
- Repeat on a resize grip. Same signature.
- Fast flicks matter more than slow ones here: a stalling gesture often
  still limps along under fast motion, because outrunning the window
  creates a local delta again. If slow drags stall and fast ones
  stutter, that is the diagnosis.
- While you are in there: Esc mid-drag should leave the card where it
  settled, not askew; a click on another app's window should activate
  that app and rest the surface in one press.

## The fix if it stalls

Stop taking motion from the gesture. On mouse-down, install
`NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp])`
and drive `proposeGeometry` from each event, tearing the monitor down
on mouse-up or on a mid-drag rest. A local monitor sees every event
delivered to the app regardless of what coordinate space thinks it
changed, so window-follows-pointer cannot starve it. `DragGesture`
stays only as the mouse-down detector and minimum-distance filter.

## Result

Record the outcome here when the session is run: date, machine, macOS
version, pass or fail per bullet, and whether the local-monitor fix was
applied.
