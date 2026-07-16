import AppKit
import SwiftUI

/// The background-surface form factor (docs/spec/feature/background-surface):
/// an ambient pane resting at desktop level, raised to a floating editor
/// by ⌃⌥Space or the menu-bar item. A sibling of the panel app — same
/// Rust core through the same seam, different posture (ADR-0010). This
/// target never touches the panel's code, state file, or Keychain items.
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
    private var toggleKey: BackdropHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu — present, not central.
        NSApp.setActivationPolicy(.accessory)

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
        // holds the combination); the menu-bar item still toggles.
        toggleKey = BackdropHotKey.controlOptionSpace { [weak self] in
            Task { @MainActor in self?.model.toggle() }
        }

        // The backdrop exists by being there: it takes its place at the
        // desktop on launch, resting. No Keychain, no state file — so
        // launching (even at login) can never raise a prompt.
        controller.show()
    }

    /// Left click toggles the stance; right click gets the boring
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
            model.toggle()
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
        // An accessory app's panel would otherwise appear behind
        // whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
    }
}
