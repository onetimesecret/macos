---
name: close-chord-and-help-menu
description: PRs 301 (#201 cmd-w falls through to performClose) and 302 (#294 Help menu) opened 2026-10-21; both reasoned, neither seen on hardware
metadata:
  type: project
---

PR 301 (app 0.40.5) routes ⌘W by the key window's identity, not by
`PageModel.holdsKeys`: `KeyWindowFacts.closeTarget` is `.surface` for the
panel, its key relay or the editor window, `.companionWindow` for
Settings, Send Feedback or About, and `.nothing` otherwise (a sheet, a
save panel, an alert, no key window). PR 302 (app 0.40.6, stacked on 301)
inserts OnetimePad Help into the SwiftUI-built Help menu from
`applicationDidFinishLaunching`, on the keymap's `app::Help` chord
(`cmd-?`), and assigns `NSApp.helpMenu`.

**Why:** #201's last comment decided ⌘W closes what the key window
shows; #294 is the HIG audit's missing first Help item. The test
requirement (inspect the built item, inject the opener) pushed the Help
item to AppKit insertion rather than a SwiftUI `Button` in the help group.

**How to apply:** two hardware facts are owed. Whether SwiftUI ever
rebuilds the help group and drops the inserted AppKit item, and whether
the File menu's title flips to Close Window promptly when Settings takes
the keys. If either fails, the fix is in `installHelpItem` or
`FileMenuItems`, not in the tests. `PageModel.openURL` is private; every
external link, the editor's and the Help item's, goes through
`openExternal(_:)`.
