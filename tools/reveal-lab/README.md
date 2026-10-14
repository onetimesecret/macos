# Reveal Lab

Twelve selectable, standalone AppKit interaction prototypes based on the
[ambient reveal research](../../docs/spec/design/2026-1013-ambient-panel-reveal-research.md).
This is a throwaway mechanics harness, not an implementation in OnetimePad.

## Run

From the repository root, with Xcode / Swift installed:

```sh
sh tools/reveal-lab/run.sh
```

The script builds a small `.app` under this directory's ignored `.build/`,
then opens it. No Rust framework, CompanionApp checkout, package download,
or main-app build is needed. The **RL** menu-bar item brings the controls back.
Close the controls to get them out of the way; **Quit lab** exits the process.
Quit an existing lab before rebuilding/relaunching it.

## Start here: see your first interaction

The controls window is a setup panel, **not the surface you hover over**.
Selecting an item in the dropdown immediately enables that gesture; you do not
need to press Start. The other gestures are inactive.

1. Select **Edge · dwell**. Leave the edge set to **Right** and the slider in
   the middle. Make sure **Pause triggers** is unchecked and close any mock
   editor window.
2. Find the **orange outlined strip on the actual right edge of the selected
   display**, halfway up the screen. Move your pointer into that strip. Do not
   click or drag; hold it there for about half a second.
3. A narrow **RL** peek should appear, then expand into a card. Move the pointer
   toward the inside of the card, then click the card or **Open mock editor**.
   You do not need to leave and re-enter it. To dismiss without opening, move
   farther away from the card.

The orange strip is a location guide, not a button. Uncheck **Show orange target
marker on screen** once you know where to aim and want to test an invisible
trigger. The guide moves when you change the display, edge, or slider.

If the chosen edge meets another display, choose an outside edge instead. The
location label warns when the target's center is on a shared boundary. If no
card appears, use **Show card (fallback)** to see what the result should look
like; that button bypasses the gesture.

## Try the other gestures

Choose a different dropdown item, then perform the action below **on your actual
desktop**. For example, menu-bar hover means moving the pointer to **RL in the
macOS menu bar**, not to the dropdown. Keyboard modes mean physically pressing
the named keys, not clicking a control.

The display, edge, and slider locate the edge-based targets (and the held
shortcut's card). Irrelevant settings are disabled for the other modes. For
edge gestures, the target is a short stretch of the screen boundary, not the
whole edge. The slider moves it up/down a side edge or left/right a horizontal
edge; the midpoint means halfway along that edge.

| Mode                | Manual action                                                                                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Edge dwell          | Move the pointer into the orange edge strip and wait half a second without clicking.                                                                                                                  |
| Two proximity bands | Move into the orange edge strip, pause briefly, then move all the way to the screen boundary.                                                                                |
| Outward delta probe | Move into the orange strip, then keep moving your mouse or trackpad finger outward against the boundary. Waiting alone will not expand the peek.              |
| Bottom-right corner | Move to the actual bottom-right corner of the chosen display and wait half a second. System Hot Corners may also respond.                                                                                          |
| Option + edge       | Hold Option, move into the orange strip, and wait half a second. Release Option to dismiss.                                                                                                        |
| Menu-bar hover      | Hover over **RL**; continue hovering or enter the peek to expand it. Clicking RL opens controls.                                                                       |
| Visible tab         | Hover the small colored edge handle; click it to open the mock editor directly.                                                                                        |
| Held shortcut       | Hold **⌘⌥G** to show the card; release to dismiss. While held, move into the card and click Open to commit.                                                            |
| Pointer-local       | Press **⌘⌥P**; the card appears beside the pointer and stays at that location.                                                                                         |
| Drag destination    | Drag text or a file toward the edge handle; enter the card and drop. A successful drop logs the item count and opens the dummy editor; it does not import the payload. |
| Mouse shake         | Move your mouse or trackpad finger quickly left-right-left-right several times; look for a card beside the pointer.                                                                                                  |
| Double Shift        | Tap/release Shift twice within 400 ms, with taps under 300 ms. Sampled at 30 Hz, so very fast taps may be missed.                                                      |

The narrow peek passes clicks through, so clicking it can trigger your system's
click-desktop-to-show-desktop action. Wait for the full card before clicking.

A full card catches clicks immediately, including clicks before opening is
armed. Those early clicks do not open the editor. After the card settles for
120 ms, entering it or moving at least 4 points inside it enables opening.
Click its background, title, or **Open mock editor** to open; **×** dismisses.
If it expanded beneath your stationary pointer, move a little toward its center
first—no leave-and-re-enter step is needed. The card's text and enabled Open
button indicate when opening is armed. Drag cards accept a drop as soon as
they expand. Edge/tab/menu modes use a connected reach corridor and 200 ms exit
grace. Held glance lasts until release; pointer-local/shake/double-Shift cards
dismiss on retreat from a 45 pt padded card region.

Open means a conventional **mock editor**, not the real pad. Close that window
to resume reveal. **Show card** and **Open mock editor** are fallback controls
for a shortcut conflict or unavailable trigger. Pause stops trigger behavior;
it does not unregister the two global shortcuts.

## A short comparison session

1. After completing the first interaction above, select **Edge dwell**, close
   the controls, and type in another app's scratch document. Move your pointer
   into the orange edge strip without clicking. Does typing still go to
   that document during both stages? Does the foreground app stay unchanged?
2. Retreat, traverse quickly, approach slowly, and jitter around the boundary.
   Try reaching the card. After a dismissal with ×, leave the source before
   trying again. No automatic stage opens the mock editor.
3. Repeat with **Menu-bar hover**, **Visible tab**, then **Held shortcut**.
   Compare accidental appearance, pointer travel, and ease of dismissal.
4. Try proximity vs delta-push with both mouse and trackpad. Reopen controls
   to inspect the **outward Δ** and **push** readouts. Zero deltas at the clamped
   edge are a useful negative result, not a reason to grant more permissions.
5. Try drag/drop from TextEdit and Finder. Check the other app's drag isn't
   redirected until you deliberately enter the receiving card.
6. Try different display edges, especially a shared monitor seam. Geometry
   rejects points whose outward neighbor lies on another display.

The controls show a six-entry, in-memory transition log and foreground app name.
They do not display keyboard destination; the typing check above is manual.

## Deliberate shortcuts and limits

- These are content-free affordances and a dummy text view. No real document,
  ownership, roll position, clipboard offer, or activation route is exercised.
- Ordinary geometry uses a 30 Hz pointer/modifier polling timer, including a
  pressed-button veto. Mouse-only local/global monitors supply deltas for the
  push and shake probes; status/tab hover uses `NSTrackingArea`. This is not an
  energy-efficiency experiment or a production reducer.
- The reveal panels refuse key/main status and use `orderFront`, while explicit
  editor opening uses activation. This setup still needs cross-app typing tests;
  the build and smoke tests do not establish a system-wide focus guarantee.
- Both Carbon shortcuts are registered exclusively for the process lifetime,
  even in other modes or while paused. A registration failure disables both
  and is reported in the controls log. Quit the lab to release them. Letters
  use physical G/P key positions, which can differ on non-US keyboard layouts.
- There is no permission-request code, event tap, screen capture, system Hot
  Corner modification, pointer warping, or keyboard-event recording. Actual
  input delivery and TCC behavior have **not** been checked on a clean machine.
  Do not grant new permissions merely to make this prototype work.
- Fullscreen suppression, Mission Control, Stage Manager, auto-hidden menu bars,
  locked sessions, and drag-session differences between apps are not implemented
  as production policies. Test normal desktop windows first. Space changes,
  sleep, and display changes cancel a reveal; runtime edge cases remain manual.
- The visible tab/card occupies a real input target. Its interference with Dock,
  resizing, scrollbars, and other windows is part of what this test should reveal.
- Reduced Motion removes frame animation. No claim of capture exclusion,
  secure erasure, or persistence behavior for real pad content is made here.
- Clipboard/selection/app-switch/idle-triggered offers are intentionally omitted,
  consistent with the research's initial-experiment scope. Arbitrary system-wide
  trackpad gestures are omitted: AppKit recognizers are not a global registration
  API, and lower-level input machinery is outside this time-boxed pass.

## Checks

From the repository root:

```sh
swift build --package-path tools/reveal-lab
swift run --package-path tools/reveal-lab RevealLab --self-test
swift run --package-path tools/reveal-lab RevealLab --smoke-test
sh tools/reveal-lab/run.sh --build-only
```

The self-test checks geometry, target-marker placement, negative screen origins,
shared/partial seams, and card clamping. The smoke test briefly creates real
AppKit windows, checks the per-mode instructions and target-guide visibility,
cycles all mode render/reset paths, checks that reveal leaves the lab's current key
window unchanged, and simulates held press/release callbacks. It exits itself.
Neither test generates physical gestures, verifies OS shortcut delivery,
performs real external drag/drop, or checks typing in another app.
