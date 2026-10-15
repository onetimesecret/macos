# Ambient panel reveal: peek before summon

- **Date:** 2026-10-13
- **Status:** research and prototype proposal; not an accepted specification
- **Scope:** making OnetimePad reachable without interrupting the foreground task, rather than reproducing Apple Notes
- **Preceding research:** [Quick Note and hot corners](2026-1013-quick-hot-corners.md)

## Conclusion

Separate **revealing the affordance** from **summoning the editor**. A pointer approach can reveal a small **peek**; further intent can reveal a thumbnail-sized card. Neither stage needs keyboard focus. Clicking the card, or using the existing summon shortcut, enters the ambient panel.

The important property is reversible, graduated commitment—not a particular corner. Corners offer a familiar destination and, on an outside display boundary, a target the pointer cannot overshoot. A short edge segment, the existing menu-bar item, and a keyboard-held glance are other candidates.

Prototype an edge-segment reveal and a status-item hover against the existing hotkey baseline. Keep the hotkey's current immediate-edit behavior. Treat physical edge pushing as an optional experiment, not a prerequisite for the first prototype.

## Evidence and limits

Apple documentation is the primary source for the API statements below. Accepted ADRs are the authority for existing project decisions, within their stated scope. Source inspection establishes current implementation only. Proposals and timings in this document are not project guarantees.

Kagi search was attempted but returned HTTP 401 Unauthorized. Apple documentation was fetched directly; no substitute search engine was used. No live Notes experiment, input-device experiment, or OnetimePad runtime test was performed.

### What the Notes example establishes

Apple's [Quick Note guide][notes] says:

> Move the pointer to the bottom-right corner of the screen (the default hot corner for Quick Note), then click the note that appears.

It separately documents reopening the previous Quick Note, and a contextual thumbnail when returning to linked webpage content. Those are distinct behaviors; the screenshot alone cannot identify the content-selection mechanism.

The supplied screenshot shows part of a card at the screen boundary. The user's observation supplies the two-stage movement: a little interaction reveals the peek, more reveals the thumbnail. Neither the image nor the documentation establishes Apple's thresholds, whether movement deltas or dwell drive the transition, or which process owns the window. We can reproduce the interaction idea without claiming to reproduce its internals.

### Corrections to the preceding research

| Finding | Correction and disposition | Evidence |
| --- | --- | --- |
| F1: All global monitoring requires Accessibility permission | Addressed: distinguish mouse monitoring from key monitoring. Do not add a permission request merely to observe mouse movement. Test the actual build on clean permission settings. | Apple's global-monitor documentation explicitly restricts **key-related** events; see below. |
| F2: A system-owned thumbnail means third parties cannot build the interaction | Addressed: ownership of Apple's implementation remains unknown; a separate third-party non-key panel is possible using public AppKit APIs. This does not imply access to Apple's Quick Note UI. | `NSPanel`, `nonactivatingPanel`, `orderFront(_:)`. |
| F3: A last-document snapshot is the natural preview payload | Addressed: a snapshot is optional, not required. Start with a content-free card and review content exposure separately. | Prototype choice; not an assertion about Notes or an existing OnetimePad policy. |
| F4: Raising the existing panel is sufficient for hover | Addressed: current raising has ownership, keyboard and clipboard side effects. Add a distinct reveal path. | Source inspection in “Fit with OnetimePad.” |
| F5: The earlier two-window glance model can be reused unchanged | Addressed: ADR-0036 supersedes simultaneous content presentations. Suppress automatic reveals while the primary editor is open in the first prototype. | Accepted ADR-0036, quoted below. |

## Focus has three different meanings

1. **Application activation:** which application is active, including its menu bar.
2. **Keyboard destination:** which window/responder receives typing.
3. **Attention:** what draws the person's eyes away from their task.

A nonactivating panel addresses the first, not automatically the other two. Apple's [`nonactivatingPanel`][nonactivating] description is:

> The window is a panel or a subclass of NSPanel that does not activate the owning app.

Apple describes [`orderFront(_:)`][orderfront] as:

> Moves the window to the front of its level in the screen list, without changing either the key window or the main window.

By contrast, `makeKeyAndOrderFront(_:)` makes the window key. A nonactivating editor can therefore take typing away from the foreground application. That is appropriate after an explicit summon, not on incidental hover.

**Proposed boundary:** peek and thumbnail never take keys; editing takes keys only after an explicit action. No bounce, sound, recurring pulse, or automatic appearance because unrelated content changed. This is a design target to test, not a measured absence of distraction.

## Interaction candidates

These are alternatives to investigate, not a weighted ranking or a recommendation to ship all of them.

| Trigger | Staged reveal | Practical implementation | Main interruption risk |
| --- | --- | --- | --- |
| **Short outside-edge segment** | Approach → peek; dwell or continue toward boundary → card | Mouse-only observation plus screen geometry; small non-key overlay | Window resizing, scrollbars, Dock or Stage Manager compete for edges |
| **Corner** | Approach → peek; dwell/push → card | Same detector with two boundary distances | Existing Hot Corners, Quick Note, desktop controls; do not claim an occupied corner by default |
| **Existing status-item hover** | Hover briefly → peek; remain/move into card → thumbnail; click → existing summon | `NSTrackingArea` on `NSStatusItem.button`, custom panel | Incidental menu traversal; auto-hidden/crowded menu bars and camera housing |
| **Explicit edge tab** | Small persistent handle; hover expands; click summons | A small owned window with tracking area | Permanent visual footprint and intercepting underlying controls; more discoverable than an invisible region |
| **Keyboard-held glance** | Hold a separately registered chord → card; release → dismiss; click → edit | Extend hotkey handling to press/release, with a distinct glance action | New shortcut to learn; timing ambiguity if overloaded onto existing summon |
| **Modifier + pointer approach** | Only arm the edge while a modifier is held | Read modifier flags from mouse events for an initial experiment | Two-handed action; reliable cancellation when only the modifier changes needs additional design/testing |
| **Pointer-local explicit summon** | Shortcut shows the card near the pointer | Registered shortcut plus `NSEvent.mouseLocation` | Appearing over the working content; location is less predictable, and pointer position may not match visual attention |
| **Drag toward a target** | Show a destination while dragging; drop commits | Owned destination with AppKit drag handling | Can interfere with a drag intended for another app; receiving a drop is a separate content operation |
| **Context events: clipboard change, app switch, selection, idle** | Automatically offer the panel | Different observers/integrations for each event | Weak evidence of intent; recurring unsolicited appearance. Do not use for initial reveal |

A global mouse shake, double modifier tap, or system-wide trackpad gesture could be explored, but each adds recognition and conflict issues. Ordinary AppKit gesture recognizers do not provide an arbitrary system-wide gesture registration mechanism. Avoid expanding input observation just to eliminate one deliberate shortcut.

### Why an edge segment, not the whole edge

A short, user-positioned segment is an address the person can learn without turning every trip to the screen boundary into a request. A corner is one possible address. A side segment farther from the working text can reduce occlusion, but the best side depends on the person's layout; there is no universally empty screen edge.

A shared boundary between two monitors is not a hard stop. Detect exposed portions of the display arrangement, rather than assuming every `NSScreen` edge stops the pointer. Do not warp or confine the pointer to manufacture resistance.

## Two stages without accidental editing

Proposed reveal states are separate from the existing resting/raised editing stance:

```text
idle
  → peek                  approach + brief qualifying dwell
  → thumbnail             continued dwell or deliberate further approach
  → existing summon       explicit click or current summon shortcut

peek / thumbnail
  → idle                  retreat, cancellation, or loss of eligibility
```

- **Peek:** a narrow lip or identifiable pad edge, not a tiny unreadable screenshot. Its job is to say where the pad is available.
- **Thumbnail:** a larger, stable target that identifies OnetimePad and its open action. A thumbnail-sized card need not contain page text.
- **Summon:** the actual editable ambient panel through the existing activation route. Do not automatically progress here because someone waited longer.

Initial tuning values, **not Apple measurements or acceptance thresholds**:

- An approach band roughly 16–24 points deep along a roughly 100–160-point segment.
- About 100–150 ms of qualifying presence before the peek.
- Another 200–350 ms of dwell, or movement into a nearer boundary band, before the card.
- About 150–250 ms of exit grace before dismissal, with an exit region wider than the entry region.

This hysteresis prevents boundary jitter. Keep a connected corridor from the edge to the card so reaching for it does not dismiss it. Require exit and re-entry after cancellation; a stationary pointer should not repeatedly reopen it. Once a card is visible, do not chase the pointer with it.

A click should be accepted only after the pointer has entered the settled card target—not because a card expanded under a click already intended for the application beneath it. Keep the initial peek mouse-transparent. The thumbnail's clickable window should hug its visible bounds; no screen-sized transparent input surface.

### What “push harder” could mean

There are three different mechanisms:

1. **Proximity:** crossing two bands before reaching the physical boundary. Straightforward, but someone moving directly to the boundary may cross both almost immediately; a minimum dwell keeps the stages legible.
2. **Dwell:** spending more time at the target. Consistent across mice and trackpads; it feels like continued intent rather than literal resistance.
3. **Continued outward movement:** accumulate movement toward the edge while the pointer is clamped there. Potentially closest to the observed push, but needs device testing.

Apple documents [`NSEvent.deltaX`][deltax] as:

> The x-coordinate change for scroll wheel, mouse-move, mouse-drag, and swipe events.

That does **not** establish delivery or useful delta values while the cursor is clamped at an edge. If a probe confirms them, accumulate only the outward component within the chosen segment, decay the accumulator, reset on retreat, and require separate thresholds. Do not sum all motion or assume event frequency is constant.

[`NSEvent.pressure`][pressure] concerns pressure-sensitive input devices. It is not a measurement of pushing the pointer against a display edge; ordinary devices report only binary pressure values. Force Touch is therefore not a general solution.

Prefer dwell for the first implementation. Keep delta-based push behind an experiment until mouse, trackpad, acceleration settings and monitor seams have been tested. Do not introduce a lower-level event tap merely because an untested pressure metaphor sounds appealing.

## Public API implementation options

### Detect intention without an invisible input barrier

For an invisible edge target, use local and global `NSEvent` mouse monitors. Apple's [global-monitor documentation][monitor] says:

> Events are delivered asynchronously to your app and you can only observe the event; you cannot modify or otherwise prevent the event from being delivered to its original target application.

It also says:

> Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access

The same page says the handler does not receive events sent to the monitoring application; the [event-handling guide][eventguide] explains why both local and global monitors are needed for coverage. The local monitor should return the original event unchanged.

Start with `.mouseMoved`, not a broad keyboard or all-events mask. Schedule a cancellable one-shot dwell timer and recheck pointer location and eligibility when it fires: a stationary pointer will not generate the next movement event. Use [`pressedMouseButtons`][buttons] as a current-state veto against starting during a drag, not as a reconstruction of drag history. Remove monitors and cancel timers when disabled. Keep per-event work to geometry and state transitions; do not render on every mouse movement.

Alternative: sample [`NSEvent.mouseLocation`][mouselocation] with a modest timer. It reports screen coordinates independently of pending events, but periodic wakeups and sampling latency make it a fallback to measure, not an automatic improvement. It also cannot recover attempted outward movement after coordinates stop changing.

For the menu-bar target or a visible edge tab, use [`NSTrackingArea`][tracking] with `.activeAlways`. Apple documents tracking while the application is inactive. Tracking belongs to an owned view; it is not a subscription to arbitrary screen coordinates or a promise to observe through other windows. [`NSStatusItem.button`][statusbutton] supplies the owned status-bar view.

A [`CGEvent` tap][eventtap] is a lower-level fallback. Its permission/failure behavior depends on the event mask and tap configuration; the fetched documentation includes legacy OS permission language and is not sufficient to promise a particular modern TCC experience. The first prototype does not need to filter, suppress or replace system input.

### Show a non-key surface

Prototype a small borderless `.nonactivatingPanel`, configured at construction, with `canBecomeKey == false` and `canBecomeMain == false`. Use `orderFront(_:)`, not `makeKeyAndOrderFront(_:)`, and do not call `NSApp.activate` for reveal. Start at `.floating`; do not default to `.statusBar` just to overpower system UI.

[`becomesKeyOnlyIfNeeded`][keyonly] can govern an interactive utility panel, but an unconditional refusal to become key is easier to reason about for a reveal-only window. Editing belongs in the existing panel, not in a text field hidden inside the preview.

[`ignoresMouseEvents`][mousepass] applies to the window. The peek can be transparent to clicks; an explicit clickable card cannot simultaneously pass those same clicks through. Keep the input footprint small and deliberate.

Use `NSScreen.frame` for physical boundary detection and [`visibleFrame`][visibleframe] for content placement. Apple says the latter excludes the Dock and menu bar, can change, and may reserve a Dock boundary even with hiding enabled. Recompute on display/layout changes; do not cache one main-screen rectangle. Keep AppKit points and coordinate conventions consistent.

Fullscreen, Spaces, Stage Manager and Mission Control need explicit runtime checks. Do not assume a collection-behavior flag makes every overlay arrangement work. Initially suppress automatic reveal over fullscreen workflows; leave explicit summon unchanged. A later experiment can reuse the app's existing altitude/Space work rather than inventing a second high-level window policy.

Respect [`accessibilityDisplayShouldReduceMotion`][reducemotion]: replace sliding travel with a restrained fade or immediate transition. Retain the existing keyboard/menu path and accessible labels; a timed hover gesture must not be the only route.

## Fit with OnetimePad

### Existing decisions

Accepted [ADR-0033](../../adr/0033-separate-the-primary-editor-from-the-ambient-panel.md) states:

> Keep the ambient behavior in a separate nonactivating `NSPanel`, the existing background surface, over the same in-process document model.

Its closing scope statement says:

> It does not choose the conventional window's visual chrome or the ambient panel's final interaction affordances.

Accepted [ADR-0036](../../adr/0036-editing-presentations-are-mutually-exclusive.md), which supersedes the older simultaneous-glance arrangement, states:

> Show at most one content presentation at a time: the primary editor window or the ambient panel, including the panel's resting desktop and pinned forms.

It also states:

> Deliberate selection of the enabled ambient panel closes an open primary editor window before granting panel ownership and publishing the raised stance.

**Interpretation for the prototype:** automatic hover must not close the primary editor or introduce a second page-content preview beside it. Initially disable automatic reveal while that editor is open or the panel is already raised/pinned. Use a content-free affordance while the panel is eligible. A later content-bearing thumbnail must replace, not accompany, the resting page presentation, or require an ADR amendment. Even a content-free companion affordance should be reviewed against the intent of the one-presentation decision before release.

### Current implementation, inspected rather than executed

| Source | Relevant behavior | Consequence |
| --- | --- | --- |
| [BackdropWindowController.swift](../../../shell/Sources/OnetimePad/BackdropWindowController.swift) | `BackdropPanel` already uses `.nonactivatingPanel`; `canBecomeKey` follows `isInteractive`; raised handling calls `makeKeyAndOrderFront` | Reuse the windowing experience, but do not call raised handling for hover |
| [BackdropModel.swift](../../../shell/Sources/OnetimePad/BackdropModel.swift) | `raise(_:)` changes ownership/stance, refreshes the pasteboard offer, and may anchor on today | Reveal must bypass this until explicit commitment |
| [ActivationRoute.swift](../../../shell/Sources/OnetimePad/ActivationRoute.swift) | Explicit presentation selection and summon are distinguished | Commit through the existing route; choose deliberately whether the new click means summon or position-preserving selection |
| [BackdropHotKey.swift](../../../shell/Sources/OnetimePad/BackdropHotKey.swift) | `RegisterEventHotKey` with a `kEventHotKeyPressed` handler | A held glance needs release handling; it is not available just by changing the action closure |

Proposed implementation boundaries, not existing types:

- **Reveal reducer:** pure idle/peek/thumbnail state, eligibility, dwell deadlines, exit grace and cancellation.
- **Trigger adapters:** pointer geometry, status-item tracking, optional press/release shortcut. All drive the same reducer.
- **Reveal window controller:** render only the affordance; no live editor, page-owner transfer or clipboard inspection on hover.
- **Commit adapter:** remove the affordance and dispatch an explicit summon through the current activation routing.

Keep these outside `BackdropStance` initially. Adding a `.peek` case to the editing stance would otherwise affect altitude, ownership and key-transfer code that currently assumes resting/raised. No Rust/core change or new dependency is indicated for the content-free experiment.

### Preview content is a separate decision

The Notes screenshot offers a useful shape, not a requirement to display the latest text. Start with an OnetimePad mark, card outline and open action. That is enough to measure reachability, staging and interruption.

A page screenshot creates another representation of potentially sensitive text. Proposal: do not introduce it in the first experiment. If content previews are later requested, specify what may appear, how expiry/deletion invalidates the representation, and whether any image or text cache exists before implementing it. Do not use a screen-capture API or a file-backed Quick Look pipeline merely to draw this affordance.

This research establishes no new capture-exclusion, secure-erasure or persistence guarantee. Existing `sharingType` assignments in source are not evidence that every capture mechanism excludes the proposed window. Those claims need their own authoritative scope and runtime evidence.

## Smallest useful experiment

1. **Content-free reveal window:** prove that a card can appear/disappear while typing continues in another app. Check keyboard destination as well as the active application.
2. **Two interchangeable triggers:** one chosen exposed edge segment and hover over the existing status item. Keep only one enabled per trial. Existing hotkey remains the baseline and direct edit path.
3. **Dwell staging:** record transition times and cancellations without page text, clipboard data or persistent pointer trajectories. Test immediate retreat, slow approach, fast traversal, jitter and repeated entry.
4. **Optional movement probe:** temporarily inspect edge-clamped deltas with a mouse and trackpad. Decide whether literal push adds control beyond dwell; discard it if it needs invasive input machinery.
5. **Only then:** consider a held-key glance and content-bearing previews. Neither is required to validate the main idea.

Proposed checks before selecting a trigger:

- Does typing in an unsaved foreground document remain there throughout peek and thumbnail?
- Can a person reach the card without dismissal, and dismiss it just by moving away?
- Does an unrelated click retain its intended destination when the card appears?
- Does hover leave page ownership, roll position and clipboard-offer logic unchanged?
- Can the user reach Dock items, menu items, scrollbars, resize handles and adjacent monitors without unwanted reveals?
- Do disabled ambient mode, an open primary editor, modal dialogs, display removal, sleep/wake and Space changes cancel pending reveals?
- Does an explicit commit still follow the existing ownership and presentation switch rules?
- On clean TCC settings, what permissions—if any—does the exact signed build request? Does declining any request leave the existing summon path usable?
- Does reduced-motion mode remain understandable? Is the existing keyboard route usable without discovering the hover gesture?
- How often does it appear unintentionally, and how long does deliberate access take compared with the current shortcut?

No numerical success threshold is established yet. The first decision is whether the staged affordance makes access easier **without becoming another thing to manage**. If it does not, improving the existing shortcut's discoverability is preferable to shipping a clever trigger.

## Apple sources

Retrieved directly on 2026-10-13. Some API pages retain legacy discussion text; they establish the documented interface, not a tested OS/device matrix.

[notes]: https://support.apple.com/guide/notes/create-a-quick-note-apdf028f7034/mac
[nonactivating]: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
[orderfront]: https://developer.apple.com/documentation/appkit/nswindow/orderfront(_:)
[monitor]: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
[eventguide]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html
[deltax]: https://developer.apple.com/documentation/appkit/nsevent/deltax
[pressure]: https://developer.apple.com/documentation/appkit/nsevent/pressure
[buttons]: https://developer.apple.com/documentation/appkit/nsevent/pressedmousebuttons
[mouselocation]: https://developer.apple.com/documentation/appkit/nsevent/mouselocation
[tracking]: https://developer.apple.com/documentation/appkit/nstrackingarea
[statusbutton]: https://developer.apple.com/documentation/appkit/nsstatusitem/button
[eventtap]: https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)
[keyonly]: https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
[mousepass]: https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
[visibleframe]: https://developer.apple.com/documentation/appkit/nsscreen/visibleframe
[reducemotion]: https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion
