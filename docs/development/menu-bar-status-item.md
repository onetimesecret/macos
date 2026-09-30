---
# docs/development/menu-bar-status-item.md
---

# Menu bar status item

The status item is the OnetimePad icon in the system menu bar — the NSStatusItem created in BackdropApp.swift:

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.image = Self.trayImage()
item.button?.action = #selector(statusItemClicked)
item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

It's the app's persistent handle at the right side of the menu bar, and it has three click behaviors (statusItemClicked, BackdropApp.swift):

- Left click → model.summon(): raises the card, or re-keys it if raised but keyboard-less, or rests it if raised and holding keys.
- ⌥-click → opens Settings directly.
- Right click → a small menu with the build version (disabled, informational), About, Settings…, Quit.

It's distinct from the app's menu bar menus (the "OnetimePad"/"Edit"/Find titles on the left side of the menu bar, which come from the SwiftUI Settings {} scene's .commands). Both are menu surfaces, which is why the fix I proposed — gating the outside-click monitor on NSMenu tracking notifications — covers the status item's right-click menu as well as the menu bar.
