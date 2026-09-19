docs/dogfood/potentially-quirky-behaviour.md

## Switching to another desktop

During #192 / #184 work.

Resolution, 2026-09-18: [ADR-0034](../adr/0034-full-screen-participation-follows-altitude.md),
then reopened the same day. The fix was not ordering, as the note below
expected. The lowered card was still a full screen auxiliary window, and
those are shown with the full screen window whatever their level. Full
screen participation was made to follow altitude so a card at normal level
would stay out of another app's full screen Space. The hardware run later
that day tripped ADR-0034's second eject trigger: with the card unpinned
and the keep above preference off, `dist/window-order-probe --watch
--expect behind` returned `VERDICT FAIL expect=behind card=2 target=4
front=Zed` after ⌘Tab into Zed's full screen Space, and the screen
recording agrees. The participation bit alone does not remove a raised
card from the full screen Space of the app being switched to. ADR-0034
Amendment 1 records the reopen: the same-desktop route stands, the full
screen route is back on the table. The alternatives named in the base
Context (`orderBack`, `order(.below, relativeTo:)`), together with hide
and reshow across the transition, are the shape of the next spike.

> What macos API is used when command-tabbing to another application that is in another desktop and/or full screen? Currently, unlike
> when the applications are on the same desktop screen which alternate "top-ness", switching to the fullscreen application brings the
> user's screen to that desktop as expected, with the OnetimePad window on top. Is that expected from the implimentation of 192 or is
> there more to do for that?

The manual test confirms the same-Space half of the spike. The cross-Space case is governed by a different axis—Space membership—so I’m
checking whether “visible everywhere” is an intentional invariant or whether fullscreen should be treated specially.

• Command-Tab itself is handled by macOS; OnetimePad does not call a “switch Space” API. The relevant pieces are:

- macOS/AppKit changes application activation.
- OnetimePad observes key-window loss through windowDidResignKey.
- NSWindow.CollectionBehavior.canJoinAllSpaces
  (https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) allows the panel to
  appear across desktops.

- fullScreenAuxiliary (https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
  allows it alongside a full-screen window.

- NSWindow.Level and window ordering determine which participating window is in front.

The destination-Space appearance is expected. Accepted ADR-0019 says exactly:

> “The pad's Space membership is .canJoinAllSpaces, in every posture and either pin state, and it never changes.”

ADR-0032 explicitly preserves that behavior:

> “Do not change the surface's Space membership or full-screen participation.”

However, remaining above the full-screen application after the transition settles is not expected when Pin is off and the keep-above
preference is off. ADR-0032 requires the newly active application’s windows to stack in front.

So your result means:

- Following the user to the full-screen Space: correct.
- Staying visibly above an overlapping full-screen application after the animation settles: the #184 spike fails that route.
- Appearing only in uncovered screen areas: allowed.

This confirms there is more to do, but the fix belongs to ordering—not Space membership. The next #184 experiment should explicitly
order the panel below the newly active application’s window when the bare .normal level change is insufficient. That hardware verdict
must be resolved before proceeding to #185–#190. The relevant implementation is in shell/Sources/OnetimePad/
---


# Potentially resolved (as of Sept 17):

> Why does the main window sometimes disappear when the focus changes to the settings window and sometimes not? WHat would the conventional, idiomatic behaviour be?

## Why it varies

Changing focus alone does **not** dismiss the surface:

- `windowDidResignKey` only sets `holdsKeys = false`; it explicitly does not rest the surface: `shell/Sources/OnetimePad/BackdropWindowController.swift:689`.
- `openSettings()` activates and shows Settings but does not call `model.rest()`: `shell/Sources/OnetimePad/BackdropApp.swift:737`.
- Consequently, opening Settings with `⌘,` can leave the surface raised and visible.

Mouse-driven routes can behave differently:

- While raised, a global outside-click monitor asynchronously calls `model.rest()`: `shell/Sources/OnetimePad/BackdropWindowController.swift:602`.
- The implementation explicitly classifies Settings and About as outside the surface: “Our ordinary windows, Settings and About, are outside by this rule and rest the card”: `shell/Sources/OnetimePad/BackdropWindowController.swift:585`.
- Menu-owned presses are exempt, so opening Settings through a tracked menu may leave the surface raised, while an unclaimed mouse press can rest it.
- Once resting, an unpinned surface moves to desktop level and therefore appears to disappear behind normal windows. A pinned surface remains floating: `shell/Sources/OnetimePad/BackdropStance.swift:24`.

So the result depends on the **input route, timing, current stance, and pin state**, not merely on focus moving to Settings.

## Conventional behavior

For an ordinary macOS document window, the conventional behavior is:

> Settings becomes key; the main window remains visible but inactive.

Focusing another window in the same application does not conventionally hide the main window.

This surface is not an ordinary main window—it explicitly returns `false` from `canBecomeMain` and behaves as a transient floating editor. The authoritative feature specification says:

> “Esc and a click outside the card always rest it.”

`docs/spec/feature/background-surface/README.md:53`

Given that established model, the most coherent behavior here would be:

1. Opening Settings always rests the surface explicitly.
2. Settings becomes the key window.
3. An unpinned surface returns behind normal windows.
4. A pinned surface remains visible but resting and non-key.
5. The outcome is identical whether Settings was opened by `⌘,`, a menu, or the status item.

The alternative—always leaving the surface raised—is also defensible under normal multi-window conventions, but it would require changing the project’s current “click outside always rests it” rule. The present route-dependent mixture is the non-idiomatic part.

> After remove the special windowDidResignKey behaviour for consistency with familiar macos application behaviour, I rebuilt and ran the application with these changes and now it seems to behave like the Pin toggle all the time. So command-tab'ing to another window on the same desktop does not put OnetimePad window behind it; it just stays on top. What other non-standard behaviour is implemented that's causing that?

The cause is the **raised stance**, not the Pin toggle.

### What happens on ⌘Tab

1. Summoning sets `stance = .raised` in `BackdropModel.raise`.
2. A raised surface always uses `.floating` window level:

   ```swift
   case .raised: .floating
   ```

   `shell/Sources/OnetimePad/BackdropStance.swift`

3. When ⌘Tab moves focus elsewhere, `windowDidResignKey` only updates the focus indicator:

   ```swift
   model.holdsKeys = false
   ```

   It does not lower the window level or change the stance.

4. `BackdropPanel` also sets:

   ```swift
   hidesOnDeactivate = false
   ```

   so application deactivation does not hide it.

Consequently, the window remains a floating, always-above-normal-windows panel after losing focus.

### Why it resembles Pin

Pin only changes the level of a **resting** surface:

```swift
case .resting: pinned ? .floating : .backdropDesktop
case .raised: .floating
```

While raised, pinned and unpinned surfaces have the same `.floating` level. Since the new behavior keeps the surface raised until Escape, Pin has no visible stacking effect during that period.

### Other non-standard window behavior

The surface is also:

- An `NSPanel`, not a conventional application window.
- Created with `.nonactivatingPanel`.
- Unable to become the application’s main window.
- Configured with `.canJoinAllSpaces`.
- Allowed over full-screen applications with `.fullScreenAuxiliary`.
- Explicitly prevented from hiding when the app deactivates.
- Kept at floating level even after it resigns key status.
- Accompanied by a Settings window that is also raised to `.floating` whenever the surface is raised or pinned.

The behavior directly responsible here is:

> **Raised means floating regardless of whether the surface still has focus.**

Familiar macOS behavior would require separating **visibility** from **always-on-top**: after resigning key, an unpinned surface should remain raised/visible but drop to normal window level, allowing the newly focused application’s windows to appear above it. A pinned surface could remain floating.

---

Track A of issue #192 implements that separation as ADR-0032: stance, keyboard ownership and altitude are now three independent facts, an unpinned keyless raised surface drops to normal, Pin and the new **Keep OnetimePad above other apps when switching away** preference each lift it back to floating, and the hardware checks belong in [`docs/qa/verification-procedures/spaces-and-cmd-tab.md`](../qa/verification-procedures/spaces-and-cmd-tab.md) under issue #190.
