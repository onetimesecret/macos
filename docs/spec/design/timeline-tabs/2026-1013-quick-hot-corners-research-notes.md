---
# docs/spec/design/2026-1013-quick-hot-corners.md
---

> **Follow-up:** [Ambient panel reveal: peek before summon](2026-1013-ambient-panel-reveal-research.md) examines non-corner triggers, staged reveal, public AppKit APIs, and the current OnetimePad implementation. This earlier research transcript is retained as context, not as an authoritative description of Apple's internals. In particular, its blanket Accessibility requirement for global mouse monitoring is too broad, and Apple's private implementation does not prevent a third-party app from building a similar reveal with its own panel.

## About the follow-up research 

The research clarified how OnetimePad could reproduce the interaction, but did not establish which process, private API, or gesture detector Apple uses.

### What became clearer about the APIs

| API | What it enables |
|---|---|
| `NSPanel` with `.nonactivatingPanel` | Display a panel without activating its application. **This alone does not prevent keyboard-focus changes.** |
| `NSWindow.orderFront(_:)` | Reveal a window without changing the key or main window—the important primitive for peek and thumbnail. |
| `canBecomeKey == false` | Keep a reveal-only panel from taking typing away from the current task. |
| `NSTrackingArea` with `.activeAlways` | Detect hover over an owned view even when the app is inactive. Useful for a menu-bar item or small edge tab. |
| Local/global `NSEvent` mouse monitors | Detect pointer approach without placing an invisible, input-blocking window over the screen. |
| `NSEvent.deltaX` / `deltaY` | Potential inputs for detecting continued outward movement. **Their usefulness at a clamped screen edge remains untested.** |

These are plausible ingredients for similar behavior, **not evidence that Notes uses them**.

`NSUserActivity` remains relevant to Notes’ contextual linking, not to implementing OnetimePad’s reveal. I found no documented third-party hook into the system’s Quick Note thumbnail. I also did not verify a public API for registering OnetimePad as a native Hot Corner action.

### Other mechanics considered

Yes—the research deliberately separates **where the gesture happens** from **how much intent it expresses**.

- **Short side-edge segment:** approach → peek; dwell or move closer → thumbnail. Avoids treating the whole edge as a trigger.
- **Existing menu-bar item:** brief hover → peek; continued hover or movement into the card → thumbnail. Uses familiar, already-visible UI.
- **Small persistent tab:** hover expands it; click opens the panel. More discoverable, but adds visual clutter and occupies an input target.
- **Held keyboard shortcut:** hold to glance, release to dismiss, explicitly commit to edit. Especially relevant when the user’s hands are already on the keyboard.
- **Modifier + pointer approach:** arms a reveal only while a modifier is held, reducing accidental activation.
- **Pointer-local reveal:** an explicit shortcut presents the affordance near the pointer rather than at a fixed edge. Less travel, but potentially more obstruction.
- **Drag toward a destination:** reveals a receiving surface during an intentional transfer. Useful as a separate workflow, but more complicated than general access.

I also considered clipboard changes, selection changes, application switches and idle events. I would not start there: they infer intent and risk interrupting the very task we want to preserve.

**The most useful next comparison is side-edge dwell versus menu-bar hover versus keyboard-held glance.** Each can express the same progression—*available → inspectable → editable*—without depending on a corner or copying Notes’ purpose.

---

> macos software development. What Apple Development Kit, SDKs, or APIs does Apple Notes use to provide the hotcorner functionality?

**Short answer: Apple Notes implements no hot-corner functionality at all.** Hot corners are owned by the Dock/system, not by Notes. Notes only supplies the *Quick Note* UI and the `NSUserActivity` linking API that the system calls into.

## Who actually implements it

| Layer | Owner | Mechanism |
|---|---|---|
| Corner trigger detection | `Dock` process | Watches screen coordinates; maps corners to actions [^1] |
| Configuration storage | `com.apple.dock` prefs | `wvous-{tl,tr,bl,br}-corner` and `wvous-{tl,tr,bl,br}-modifier` integer keys [^2] |
| "Quick Note" action code | Dock prefs | `14` = Quick Note (default is bottom-right) [^3] [^4] |
| Modifier keys | Dock prefs | Bit flags, e.g. `1048576` = Command [^5] |
| Quick Note window + note creation | Apple Notes | System-provided Quick Note surface; private handoff from Dock → Notes (undocumented) |
| Third-party content linking | Foundation / `NSUserActivity` | Public, documented API [^6] |

So for your own app the only supported integration point is the *content* side of Quick Note, not the corner itself:

- Publish an `NSUserActivity` with a stable `webpageURL`, `persistentIdentifier`, or `targetContentIdentifier`, plus a human-readable `title` — the system adds a back-link to your app's content inside the new note [^7].
- Call `becomeCurrent()` on it; the Quick Note system only reads the *current* activity, and you can `resignCurrent()` when nothing is worth capturing [^7].
- Framework: Foundation (macOS + iOS); reference session: WWDC21 "Adopt Quick Note" (10264) [^8].

## What does *not* exist

- No public API to register a custom hot-corner action, and no public API to trigger Quick Note programmatically. The `wvous-*` keys are unsupported implementation detail — they work, need `killall Dock` to take effect [^9], but Apple can change them.
- No Notes-specific "hot corner SDK". If you want a hot corner for your *own* app, you roll it yourself: `NSEvent.addGlobalMonitorForEvents` + `NSEvent.mouseLocation`, a `CGEventTap`, or an `NSTrackingArea` (own-window only) — plus an Accessibility/TCC prompt for the global-monitor route. Notes' own AppleScript/ScriptingBridge dictionary is for automation, not for triggering the corner.

**References**

[^1]: [GitHub - DiegoSalazar/HotCornerShortcuts: Workaround for macOS hot ...](https://github.com/DiegoSalazar/HotCornerShortcuts) (6%)
[^2]: [MacOS HotCorners values · GitHub](https://gist.github.com/rikeoka/331b9cfb25e4a033bdd8) (10%)
[^3]: [nix-darwin/modules/system/defaults/dock.nix at master](https://github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/dock.nix) (3%)
[^4]: [Making macOS Tahoe Usable — aryan's blog](https://blog.ameri.coffee/making-macos-tahoe-usable) (3%)
[^5]: [You're Underutilizing 'Hot Corners' (Hacks Nobody Told ...](https://medium.com/macoclock/youre-underutilizing-hot-corners-hacks-nobody-told-you-before-0c40aac45d15) (2%)
[^6]: [Apple Developer](https://developer.apple.com/documentation/foundation/supporting-the-creation-of-quick-notes.md) (7%)
[^7]: [Supporting the creation of Quick Notes | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/supporting-the-creation-of-quick-notes) (64%)
[^8]: [Adopt Quick Note - WWDC21 - Videos](https://developer.apple.com/videos/play/wwdc2021/10264/) (3%)
[^9]: [My Mac setup](https://amanhimself.dev/blog/mac-setup/) (3%)



---

> Notice that in the screenshot I included, you can see the most recent note that has "slid out" in the bottom right corner as the mouse got close to it. I care less about what owns or manages hotcorners and more about how Apple Notes makes its more recent not available there.

Apple hasn't documented how the corner thumbnail is built, and I found no public source, reverse-engineering write-up or API reference that explains it. What follows separates what Apple documents from what I'm inferring.

**What's documented**
- Apple describes the thumbnail as the "Quick Note Suggestions" UI. It appears in the bottom-right corner when you return to content you previously linked into a note [^1][^2].
- Separately, the bottom-right hot corner shows a clickable note thumbnail. Clicking it opens Quick Note [^2]. By default it reopens your previous Quick Note, controlled by the Notes setting "Always resume to last Quick Note" [^2].
- There is also a plain small square that grows into a "New Quick Note" button as you push into the corner [^3]. That is probably the same mechanism with a different payload.

**What's inferred, not documented**
- The slide-out is a system-owned panel, not something a third-party app can build the same way. Apple's frameworks contain no public API for it. It is most likely a private overlay window shown by system UI or by Notes, but I couldn't confirm which process owns it.
- The most-recent-note content comes from Notes' own data store, not from a public API. The preview is almost certainly a snapshot of the last-opened Quick Note.

**The public API behind the contextual variant**
- The one public hook is `NSUserActivity`. Registered activities are sent to Quick Note, which is how links appear in the "add link" menu and what triggers Quick Note Suggestions [^1].
- The thumbnail reappears when the activity identifier saved in the note's link matches the identifier of the content you're viewing now [^1].
- Quick Note prefers `targetContentIdentifier` or `persistentIdentifier` over `webpageURL`. The identifier needs to be unique, global and stable [^1][^1].

**To copy the behaviour in your own app**
- Build the slide-out yourself. Use a borderless, non-activating `NSPanel` at `.statusBar` or `.floating` level, positioned at the screen corner and animated with `NSAnimationContext`.
- Trigger it with a global mouse monitor, `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)`, or a `CGEventTap` that checks `NSEvent.mouseLocation` against the corner.
- Fill it with a snapshot of your last document, for example from `NSView.bitmapImageRepForCachingDisplay(in:)` or a QuickLook thumbnail.
- This approach is my recommendation, not a description of Apple's implementation.

I couldn't verify the internal process, window level or IPC path. The only way to find them would be inspecting the running system, for example with `Window Server` listings via `CGWindowListCopyWindowInfo` while the thumbnail is showing, which reports the owner process and window layer.

**References**

[^1]: [Adopt Quick Note - WWDC21 - Videos - Apple Developer](https://developer.apple.com/videos/play/wwdc2021/10264/) (73%)
[^2]: [Create a Quick Note on Mac - Apple Support](https://support.apple.com/guide/notes/create-a-quick-note-apdf028f7034/mac) (14%)
[^3]: [How to Turn Off the Quick Note Corner Shortcut on a Mac](https://www.howtogeek.com/764645/how-to-turn-off-the-quick-note-corner-shortcut-on-a-mac/) (13%)
