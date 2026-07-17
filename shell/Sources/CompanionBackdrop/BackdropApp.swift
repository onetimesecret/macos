import AppKit
import SwiftUI

/// The background-surface form factor (docs/spec/feature/background-surface):
/// an ambient pane resting at desktop level, raised to a floating editor
/// by ⌃⌥Space, ⌘Tab, the Dock icon, or the menu-bar item. A sibling of
/// the panel app — same Rust core through the same seam, different
/// posture (ADR-0010). This target never touches the panel's code,
/// state file, or Keychain items.
@main
struct BackdropApp: App {
    @NSApplicationDelegateAdaptor(BackdropAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scene renders anything; the status item + window
        // (built in the delegate) are the entire UI. A placeholder scene
        // is required by the `App` protocol.
        Settings {}
            .commands {
                // The scene's automatic "Settings…" (⌘,) item would open
                // the empty placeholder as a blank window; the backdrop
                // has no Settings surface yet, so remove the item.
                CommandGroup(replacing: .appSettings) {}
            }
    }
}

@MainActor
final class BackdropAppDelegate: NSObject, NSApplicationDelegate {
    private let model = BackdropModel()
    private var controller: BackdropWindowController?
    private var statusItem: NSStatusItem?
    private var summonKey: BackdropHotKey?

    /// Not every activation is a summon. The launch's own arrives
    /// within moments of `applicationDidFinishLaunching` — and a
    /// login-item or background launch may never activate at all,
    /// which is why this is recency rather than a skip-one counter
    /// that would swallow the first real ⌘Tab hours later. About's
    /// activation is flagged by `showAbout`. Every other activation —
    /// ⌘Tab, the Dock icon — is the user choosing this app, and
    /// answers with a raise.
    private var launchedAt = Date.distantPast
    private var aboutActivation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAt = Date()
        // A regular app, deliberately — the panel's accessory posture
        // (menu bar only, docs/spec/03 §2) is amended for this form
        // factor: living in ⌘Tab is what makes flipping between the
        // work window and the surface (copy from one, paste into the
        // other) a reflex instead of a remembered chord. The Dock icon
        // is the fee; whether it makes the surface too central is the
        // feature spec's open question №7.
        NSApp.setActivationPolicy(.regular)

        let controller = BackdropWindowController(model: model)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: "CompanionBackdrop"
        ) {
            item.button?.image = image
        } else {
            item.button?.title = "◳"
        }
        item.button?.setAccessibilityLabel("CompanionBackdrop")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // ⌃⌥Space, system-wide. Registration can fail (another app
        // holds the combination); the menu-bar item still summons.
        summonKey = BackdropHotKey.controlOptionSpace { [weak self] in
            Task { @MainActor in self?.model.summon() }
        }

        // The backdrop exists by being there: it takes its place at the
        // desktop on launch, resting. No Keychain, no state file — so
        // launching (even at login) can never raise a prompt.
        controller.show()
    }

    /// ⌘Tab (or the Dock icon) landing on this app is a summon: the
    /// user chose the surface, so raise it, pulled to their Space and
    /// keyed — unconditionally, never a rest, because activation only
    /// ever means "bring it to me". The launch's own activation (and
    /// `showAbout`'s) is exempt: the backdrop starts resting, present
    /// but not summoned.
    func applicationDidBecomeActive(_ notification: Notification) {
        if Date().timeIntervalSince(launchedAt) < 2 { return }
        if aboutActivation {
            aboutActivation = false
            return
        }
        model.raise()
    }

    /// The Dock icon's click while the app is already active reaches
    /// here instead of `applicationDidBecomeActive`: same summon.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        model.raise()
        return false
    }

    /// Left click summons (raise, or re-key, or rest — the summon
    /// decision); right click gets the boring
    /// necessities (About, Quit — not features).
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(
                withTitle: "About CompanionBackdrop",
                action: #selector(showAbout),
                keyEquivalent: ""
            ).target = self
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ).target = NSApp
            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
        } else {
            model.summon()
        }
    }

    /// The standard About panel; the version comes from the core (the
    /// same source the bundle's plist is stamped from), because a bare
    /// `swift run` binary has no Info.plist to read it from.
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CompanionBackdrop",
            .applicationVersion: BackdropCore.version,
        ])
        // The app is usually inactive when About is chosen from the
        // status item; without activation the panel appears behind
        // whatever is frontmost. This activation is About's, not a
        // summon — flag it so the raise is skipped (only when the
        // activation will actually happen; an already-active app fires
        // no notification to consume the flag).
        aboutActivation = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
    }
}
