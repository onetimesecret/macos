# Ambient, Non-Focus-Stealing Note Surfaces on macOS: What's Possible in Swift/SwiftUI

## TL;DR
- **The literal "full-screen app that sits underneath the apps you're actively using" is not achievable on macOS**, because a macOS full-screen window gets its own dedicated Space and, by architecture, cannot have other apps' windows floating over it in that Space. What you actually want (an ambient, always-reachable, type-and-copy surface that never steals focus) IS achievable — just not via the "backdrop app" mental model.
- **The best-fit primary recommendation is a borderless, non-activating `NSPanel` (`.nonactivatingPanel` style mask) summoned by a global hotkey**, hosting your SwiftUI view via `NSHostingView`, with an `.accessory` activation policy (`LSUIElement`) — this is exactly how Antinote, Alfred, Raycast, and Spotlight-style surfaces work, and it delivers typing + copy/paste without activating your app.
- A true "behind the icons" desktop-level canvas (the Plash/Übersicht model) is also possible via `window.level = .desktop` + `collectionBehavior`, but it is essentially non-interactive by default and is the wrong tool for a note surface you type into.

## Key Findings

**1. Why the "underneath" model fails.** macOS window stacking is governed by an integer `NSWindow.level` (`CGWindowLevel`). Normal app windows sit at level 0 (`.normal`). You can place a window *below* that at the desktop level (`CGWindowLevelForKey(.desktopWindow)` = −2,147,483,623, per Jim Fisher's verified debugging table) or desktop-icon level, but a window at that level is, for practical purposes, not usable as a foreground editing surface: it sits behind the icons/desktop and the system does not route normal activation/key events to it. Meanwhile, the "full-screen app you work on top of" is impossible for a *different* reason: macOS's Spaces model gives every full-screen app its own Space, and you cannot drop arbitrary other-app windows into that Space on top of it. So the two halves of the literal request are blocked by two distinct mechanisms (window-level semantics + Spaces isolation).

**2. The winning mechanism: non-activating panels.** `NSPanel` (an `NSWindow` subclass) with the `.nonactivatingPanel` style-mask bit is the canonical macOS tool for "interact without activating the owning app." Apple's own one-line description: *"The window is a panel or a subclass of that does not activate the owning app."* Clicking it does not bring your app frontmost; the user stays in whatever app they were using. This is the mechanism behind Spotlight/Alfred/Raycast command bars.

**3. Typing into a non-activating panel works — with sharp edges.** A non-activating panel can *become key* (receive keyboard/text input) without your app *becoming active* (frontmost). You typically set `becomesKeyOnlyIfNeeded` and call `panel.makeKey()` when you want the text field ready. But there is a well-documented AppKit trap: if you toggle the `.nonactivatingPanel` bit *after* init via `setStyleMask:`, the panel will draw as key yet silently refuse text input, because AppKit only sets the internal `kCGSPreventsActivationTagBit` window-server tag during initialization (reverse-engineered and documented on philz.blog). Set the style mask at init, or apply the documented private-selector workaround.

**4. Reaching over full-screen apps: `collectionBehavior`.** The single most important trick for a note surface that must stay reachable even when the user is in a full-screen app is `NSWindow.CollectionBehavior.fullScreenAuxiliary` — Apple: *"The window displays on the same space as the full screen window."* Combined with `.canJoinAllSpaces` and (optionally) `.stationary`, this lets a floating panel appear on top of another app's full-screen Space. Antinote's user manual confirms this pattern in production: *"Antinote will show over full-screen apps in Pseudo Menu mode and Traditional Menu mode."*

**5. The desktop-canvas (wallpaper) approach and its interactivity ceiling.** Plash and Übersicht place content behind normal windows by setting a desktop-level window. The recovered Plash `DesktopWindow` source (see Details) confirms the pattern precisely and, crucially, shows that such a window is **non-interactive by default** (`ignoresMouseEvents = true`) and only becomes clickable when the app deliberately raises the level and enables mouse events ("Browsing Mode"). This confirms that the desktop level is fundamentally unsuited to a live typing surface.

## Details

### The Spaces / full-screen constraint, precisely
When a macOS window enters true full screen, macOS creates a **new, dedicated Space** for it. Apple's Spaces model treats that Space as isolated: you cannot drag or float another app's normal window on top of a full-screen app in the same Space (Apple Community and AppleVis threads describe this as long-standing, deliberate behavior — "Each full screen application has to have its own space"). This is why a would-be "backdrop" app can never host the user's other apps on top of it: there is no API to make your window the "floor" of someone else's full-screen Space. The only sanctioned way to appear alongside a full-screen app is `fullScreenAuxiliary`, which puts your *auxiliary* window on top of the full-screen app — the opposite of "underneath."

Even outside full screen, the "sits below normal windows but is typed into" idea fights the window-level system: to be typed into comfortably a window needs to be key and near the foreground; to be a persistent backdrop it needs to be at/below `.normal`. Those goals are contradictory, which is why real apps summon a HUD to the front transiently rather than living underneath.

### Window levels reference (verified raw values)
From debugging by Jim Fisher, in true numeric order: `.baseWindow` = −2147483648; `.minimumWindow` = −2147483643; `.desktopWindow` (`.desktop`) = −2147483623; `.desktopIconWindow` = −2147483603; `.normal` = 0; `.floating` = 3 (`.submenu`/`.tornOffMenu` also 3); `.modalPanel` = 8; `.dock` = 20; `.mainMenu` = 24; `.statusBar` = 25; `.popUpMenu` = 101; `NSWindow.Level.screenSaver` also resolves to 101 in Fisher's table (which, notably, differs from `CGWindowLevelForKey(.screenSaverWindow)` — the two "screen saver" constants are not equal). A note HUD should live at `.floating` (or `.modalPanel`) when summoned; a desktop canvas lives at `.desktop`.

### Activation policy
`NSApplication.setActivationPolicy` / the Info.plist `LSUIElement` key controls Dock/menu-bar presence:
- `.regular`: normal app with Dock icon.
- `.accessory` (equivalent to `LSUIElement = true`): no Dock icon, no menu bar, but the app can still show windows and be interacted with. **This is the right policy for an ambient note HUD** — the app runs quietly in the background and its panel can receive input without a Dock-icon "activation" ceremony.
- `.prohibited`: cannot activate at all.
`LSBackgroundOnly` is a stricter, UI-less agent mode. For a menu-bar note app, `MenuBarExtra` with `LSUIElement` set is the standard configuration; Apple notes a menu-bar-only app is auto-terminated if the user removes the extra.

### The canonical non-activating panel recipe (SwiftUI + AppKit bridge)
SwiftUI's own scene types (`WindowGroup`, `Window`, `Settings`, `MenuBarExtra`) **cannot** express `.nonactivatingPanel`, custom window levels, or collection behavior. You must drop to AppKit via `@NSApplicationDelegateAdaptor`, build an `NSPanel` subclass, and host SwiftUI with `NSHostingView`. This is the community-standard pattern (documented by the Fazm and multi.app blogs, among others):

```swift
final class NotePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true          // take key focus only when a text field needs it
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSHostingView(rootView: NoteView())
    }
    override var canBecomeKey: Bool { true }    // allow text editing
    override var canBecomeMain: Bool { false }  // but never become the "main" app window
}
```
Key semantics: a non-activating panel **can become key but should not become main**; when the user types, text goes to your `TextField`/`TextEditor` while the previously frontmost app remains active behind it. Do **not** call `NSApp.activate(ignoringOtherApps:)` when showing it — that is the single most common mistake and it defeats the whole purpose (multi.app documented a real user revolt over exactly this focus-stealing bug).

### Global hotkey to summon/dismiss
Three options, in order of recommendation:
1. **`KeyboardShortcuts` by Sindre Sorhus** (SPM: `github.com/sindresorhus/KeyboardShortcuts`) — the modern, App-Store/sandbox-safe choice. Its README states verbatim: *"It's fully sandboxed and Mac App Store compatible. And it's used in production by Dato, Jiffy, Plash, and Lungo."* It ships a SwiftUI `Recorder` component, persists to `UserDefaults`, and causes no permission dialog. Register a `KeyboardShortcuts.Name`, drop a `Recorder` in Settings, and add `KeyboardShortcuts.onKeyUp(for:)` to toggle the panel. It wraps the still-non-deprecated Carbon `RegisterEventHotKey` internally.
2. **Carbon `RegisterEventHotKey`** directly — works, but low-level and verbose.
3. **`NSEvent.addGlobalMonitorForEvents`** — simplest, but global monitors require Accessibility permission and cannot consume the event. Fine for click-outside-to-dismiss; not ideal as the primary hotkey.

Note an OS caveat that bit Antinote (whose default hotkey is ⌥+A): *"for macOS 15.0 and macOS 15.1, global shortcuts that only have the option key as the modifier [were] disabled. Apple re-enabled it in macOS 15.2+."* Prefer a two-modifier default (e.g. ⌘⇧) or let users record their own.

### The desktop-canvas approach — exactly how Plash does it
The recovered source of Plash's `DesktopWindow` (Plash is no longer open-source as of a recent release, so this reflects the last public version, ~macOS 11–15 era) is the definitive prior art. It is an **`NSWindow` subclass, not an NSPanel**, created `.borderless`, transparent (`isOpaque = false`, `backgroundColor = .clear`), with:
```swift
self.level = .desktop
self.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
```
Note it does **not** use `.canJoinAllSpaces`, and it uses `.fullScreenNone` precisely so that when an app goes full screen (a separate Space) Plash does not try to show behind it. Interactivity is toggled by an `isInteractive` flag:
```swift
override var canBecomeMain: Bool { isInteractive }
override var canBecomeKey: Bool { isInteractive }
override var acceptsFirstResponder: Bool { isInteractive }

var isInteractive = false {
    didSet {
        if isInteractive {
            level = Defaults[.bringBrowsingModeToFront] ? .floating : (.desktopIcon + 1)
            makeKeyAndOrderFront(self)
            ignoresMouseEvents = false
        } else {
            level = .desktop
            orderBack(self)
            ignoresMouseEvents = true
        }
    }
}
```
The critical lesson for your use case: **to actually interact (click/type), Plash raises the window off the desktop level up to `.floating` (or `.desktopIcon + 1`) and calls `makeKeyAndOrderFront`.** (The `+ 1` is Sindre's own workaround for a macOS 11.2.1 quirk where the window was sometimes not interactive.) In other words, even the reference "wallpaper" app cannot be typed into *while remaining at the desktop level* — it temporarily promotes itself to the foreground. That confirms a persistent, behind-the-windows, live-typing note canvas is not a real option; the desktop level is for glanceable, mostly-passive content. Übersicht (desktop widgets) works on the same behind-the-windows principle.

### Menu-bar approach
For a lower-effort, always-available surface, a menu-bar app is the other strong pattern. `MenuBarExtra` (SwiftUI, macOS 13+) with `.menuBarExtraStyle(.window)` gives a popover-like note surface; for full control over size/behavior use `NSStatusItem` + `NSPopover` (`behavior = .transient` to auto-dismiss). Note SwiftUI's `MenuBarExtra` has no first-party API to programmatically open/close or reach the underlying `NSStatusItem`/window (still true as of Xcode 26) — the `MenuBarExtraAccess` library (orchetect) is the common workaround. The `.window` style is also size-limited (~half the screen), which is why apps needing bigger/typed surfaces use `NSStatusItem` + custom panel. Antinote in fact offers Dock, Menu-bar, and "headless" (hotkey-only) modes simultaneously.

### Clipboard / paste convenience
Use `NSPasteboard.general` for copy/paste. `string(forType: .string)` reads; `clearContents()` + `setString(_:forType:)` writes. A non-activating panel is ideal for frictionless copy/paste because the source app never loses focus — the user can select text in the panel and paste elsewhere, or hit the hotkey, paste in, and dismiss, all without a context switch. Antinote leans into this with an "AutoPaste" feature (paste the clipboard the moment the note is summoned) and by stripping formatting on paste.

### Reference apps and their (believed) architecture
- **Antinote** — `.accessory`/menu-bar app; default global hotkey **⌥+A** (show/hide also via ⌘+O); floating pinnable window; explicitly shows over full-screen apps in its menu modes (implying `fullScreenAuxiliary` + a high level). Requires **macOS 14 Sonoma or later**. The closest commercial match to the goal, and $5 one-time.
- **Alfred / Raycast / Spotlight** — non-activating command bar summoned by hotkey; takes key focus transiently without activating a normal app; dismisses on Escape/click-outside. Multi.app's engineering blog documents the exact `NSPanel` + `.nonactivatingPanel` + activation-policy dance these require.
- **Apple Notes "Quick Note"** — triggered by a hot corner or shortcut; floats in a corner and follows you across Spaces (a system-privileged floating panel; not reproducible with identical privilege by third parties, but approximable with `canJoinAllSpaces` + `fullScreenAuxiliary`).
- **Stickies.app / Notes "Float Selected Note"** — plain windows; float only above same-Space normal windows and vanish when you enter a full-screen Space (the exact limitation `fullScreenAuxiliary` exists to solve).
- **Plash / Übersicht** — desktop-level `NSWindow`, behind icons, non-interactive by default (see source above).
- **Tot, SideNotes, Drafts, Ghostnote, nvALT/Notational Velocity, Bear quick-note** — variations on menu-bar-popover or floating-HUD; all summon to the foreground rather than living underneath.

### Constraints, gotchas, OS-version notes
- **Sandbox / Mac App Store:** Setting `window.level = .desktop` and collection behaviors are public AppKit APIs and are allowed in sandboxed, App-Store apps — Plash itself ships on the App Store, sandboxed. `KeyboardShortcuts` is explicitly *"fully sandboxed and Mac App Store compatible."* What the sandbox blocks is cross-app observation/manipulation and system-wide input tricks; a self-contained note panel needs none of that.
- **Accessibility permission** is required for *global event monitoring* (`NSEvent` global monitors) and for anything reading other apps' windows, but **not** for `KeyboardShortcuts`' Carbon-based hotkeys.
- **macOS 26 "Tahoe" (2025–2026):** ships first-party desktop widgets (transparent by default, dimming when windows are open — "Show Widgets" setting under System Settings → Desktop & Dock, controllable via defaults), a redesigned Liquid Glass appearance, and native clipboard history in Spotlight. These raise user expectations for glanceable desktop content but do not change the underlying `NSWindow` level/Spaces semantics your app relies on. Note Plash's current App Store build requires macOS 26.4+.
- **Stage Manager** (Ventura+) adds a wrinkle: it manages/relayouts normal windows. Use `collectionBehavior` to opt your panel out — Apple's newer `canJoinAllApplications`/`.auxiliary` behaviors let a floating window sit with other apps in both Stage Manager and full-screen contexts *without* participating in Stage Manager layout (Apple: "Windows marked with this behavior don't participate in Stage Manager layout but can join the windows of other apps in full screen spaces"). Test with Stage Manager on; panels with `.canJoinAllSpaces`/`.stationary` generally behave, but Stage Manager can hide non-participating windows unexpectedly.
- **SwiftUI limitation recap:** window level, style mask, collection behavior, and non-activating behavior must be set on the real `NSWindow`/`NSPanel`. The robust pattern is an empty `Settings { EmptyView() }` (or a `MenuBarExtra`) scene plus a delegate that owns the panel, with `NSHostingView` hosting your SwiftUI note view.

## Recommendations

**Primary architecture (build this):** A background **`.accessory`/`LSUIElement` app** that owns a **borderless `NSPanel` with `.nonactivatingPanel`**, hosting your SwiftUI note view via `NSHostingView`. Summon/dismiss with a **`KeyboardShortcuts` global hotkey**; set `level = .floating`, `becomesKeyOnlyIfNeeded = true`, `canBecomeKey = true`, `canBecomeMain = false`, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` so it appears on every Space *and over* full-screen apps. Add a menu-bar item (`MenuBarExtra` or `NSStatusItem`) as a discoverable secondary trigger. This satisfies all three goals: (a) never steals focus (non-activating + never becomes main + never call `NSApp.activate`), (b) stays out of the way (hidden until summoned, dismiss on Escape/click-outside via a global monitor), (c) frictionless copy/paste (`NSPasteboard`, optional auto-paste, source app keeps focus).

**Staged plan:**
1. **MVP:** SwiftUI app + `@NSApplicationDelegateAdaptor`; empty `Settings` scene; build the `NotePanel` subclass above; wire one hardcoded hotkey (use a two-modifier default like ⌘⇧ to avoid the macOS 15.0/15.1 option-only limitation). Verify typing works and the previously-active app stays frontmost.
2. **Polish:** add `KeyboardShortcuts.Recorder` in a Settings view; add `fullScreenAuxiliary`; add click-outside dismissal; add a `MenuBarExtra`; strip formatting on paste and add an optional auto-paste.
3. **Harden:** set style mask at init only (avoid the post-init `.nonactivatingPanel` text-input bug); enable App Sandbox and confirm hotkeys + pasteboard still work; test under Stage Manager and with a full-screen app frontmost.

**Only build the desktop-canvas variant if** you want a *glanceable, mostly passive* surface (a persistent dashboard/wallpaper). In that case follow Plash's exact recipe (`level = .desktop`, `collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]`, `ignoresMouseEvents = true`) and accept that "editing" requires promoting the window to `.floating` on demand — i.e., you end up back at the panel model for input anyway.

**Benchmarks that would change the recommendation:** If you need the surface visible *simultaneously with* every app all the time (not summoned), lean toward the desktop-canvas + a separate summon-to-edit panel. If you must support pre-macOS 13, drop `MenuBarExtra` for `NSStatusItem`. If you need to guarantee no Accessibility prompt, stick strictly to `KeyboardShortcuts` (Carbon) and avoid global `NSEvent` monitors.

## Caveats
- Plash's detailed source is reconstructed from the last public open-source version (the repo has since gone closed-source, per its README, "facing challenges with App Store clones"); property names and exact levels reflect that era (~macOS 11–15) and may differ in the current shipping build (which requires macOS 26.4+), though the architecture is stable and corroborated by the app's documented behavior.
- Several implementation specifics (Alfred/Raycast/Apple Quick Note internals) are inferred from documented behavior and third-party engineering write-ups (notably multi.app and Fazm), not official source; treat them as well-supported inference rather than confirmed internals.
- macOS 26 behavior described here is based on 2025–2026 reporting on Tahoe; Apple can adjust widget/window semantics in point releases.
- The `.nonactivatingPanel`-after-init text-input bug is documented via reverse-engineering (philz.blog) and relies on a private selector for its workaround; prefer setting the style mask at initialization to avoid needing it.