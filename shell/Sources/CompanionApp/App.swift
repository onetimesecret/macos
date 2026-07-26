import AppKit
import CompanionKit
import SwiftUI
import os

/// The app's resident presence is the menu-bar item; a click reveals
/// the window (docs/spec/03 principle 2) and ⌥Space summons it with the
/// keyboard. `WindowController`'s non-activating `NSPanel` — not
/// SwiftUI's stock `MenuBarExtra`, which has its own activation
/// behavior and can't drop capture.
@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scene renders anything; the status item + window
        // (built in AppDelegate) are the entire UI. A placeholder scene
        // is required by the `App` protocol.
        Settings {}
            .commands {
                // The scene's automatic "Settings…" (⌘,) item would
                // open the empty placeholder as a blank window — the
                // main menu dispatches key equivalents even for an
                // accessory app whenever it is active (e.g. while the
                // real Settings window is key). Repoint it so every ⌘,
                // in the app lands on the one real Settings window.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PageModel(formFactor: .panel)
    private var controller: WindowController?
    private var statusItem: NSStatusItem?
    private var summonKey: GlobalHotKey?
    private lazy var settings = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu — present, not central.
        NSApp.setActivationPolicy(.accessory)

        let controller = WindowController(model: model)
        self.controller = controller
        model.onHandBackKeys = { [weak controller] in controller?.handBackKeys() }
        model.onOpenSettings = { [weak self] in self?.settings.show() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // ㊙ maruhi ("secret") — the menu-bar glyph, drawn as a template
        // image so the system tints it like every other status item:
        // dark in light mode, light in dark mode, dimmed when inactive.
        // VoiceOver reads the explicit label, not the glyph's own name.
        item.button?.image = Self.maruhiTemplateImage()
        item.button?.setAccessibilityLabel("CompanionApp")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // ⌥Space, system-wide. Registration can fail (another app holds
        // the combination); the menu-bar item still summons.
        summonKey = GlobalHotKey.optionSpace { [weak self] in
            Task { @MainActor in self?.controller?.summon() }
        }

        // Testing aid: show without a click, so the non-activating claim
        // is scriptable (e.g. ADR-0002 measurement runs) rather than
        // needing a synthetic click through Accessibility permissions.
        if ProcessInfo.processInfo.environment["COMPANION_AUTOSHOW"] != nil {
            controller.show()
        }
    }

    /// Opening an already-running copy (Finder, Spotlight, the Dock's
    /// recents, `open -a`) arrives here as a reopen event and nothing
    /// else. An accessory app has no Dock icon and no document window
    /// for AppKit to unminiaturize, so without this the launch looks
    /// broken: the process is alive, the event lands, no window appears.
    ///
    /// `show()`, not `summon()`: reopening asks for the window, and a
    /// summon toggles, so a second open would dismiss the very window
    /// the user just asked to see. Showing also matches the menu-bar
    /// click this most resembles, keyboard left where it was.
    ///
    /// False because the reveal is complete: AppKit's normal reopen
    /// tasks would only unminiaturize a window we do not have.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        controller?.show()
        return false
    }

    /// Quit is the one moment state touches disk: seal everything into
    /// the state file so the next launch opens where this one left off.
    /// Intercepted here rather than in `applicationWillTerminate` so a
    /// refused save — Keychain denied, disk full, a failed rename —
    /// still reaches the user while there is time to choose. One alert,
    /// two honest exits: quit anyway and accept the loss, or stay and
    /// try again later. Never a retry loop; cancelling simply returns
    /// to the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.saveState() else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This session could not be saved"
        alert.informativeText =
            "The sealed state file was not written, so this session's pages "
            + "will not survive the quit. The previous file, if any, is untouched."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        // An accessory app's alert would otherwise appear behind
        // whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The ㊙ glyph rendered monochrome (U+FE0E forces text
    /// presentation over emoji) onto a template image: the menu bar
    /// tints template images to match its appearance, which a colour
    /// emoji title never gets.
    private static func maruhiTemplateImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let glyph = "㊙\u{FE0E}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Left click toggles the window; ⌥-click goes straight to
    /// Settings; right click gets the boring necessities
    /// (docs/spec/04: "Settings, About, Quit — not features").
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            // "Which build am I on" answered at a glance: the stamped
            // bundle version (which carries the git SHA on dogfood
            // builds) alongside the core the binary actually linked.
            // No action, so the menu leaves it disabled: it is a fact,
            // not a feature.
            menu.addItem(
                withTitle: BuildVersion.trayTitle(
                    core: CompanionClient.version,
                    bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ),
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "About CompanionApp",
                action: #selector(showAbout),
                keyEquivalent: ""
            ).target = self
            menu.addItem(
                withTitle: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: ","
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
        } else if NSEvent.modifierFlags.contains(.option) {
            // The live hardware state, not the delivered event's flags:
            // the status bar's event can misreport modifiers, and an
            // accessibility press (VoiceOver AXPress) arrives with a
            // stale currentEvent that could still carry .option from
            // earlier keyboard use. ⌥ physically held right now is the
            // one honest signal — that opens Settings; anything else
            // toggles the panel.
            settings.show()
        } else {
            controller?.toggle()
        }
    }

    @objc func openSettings() {
        settings.show()
    }

    /// The standard About panel, dressed up: the colour ㊙️ at icon
    /// size (the menu bar gets the monochrome template; here colour is
    /// the point), the cheeky name, and the core's version — supplied
    /// explicitly because a bare `swift run` has no bundle Info.plist,
    /// and the bundled app (scripts/build-app.sh) stamps its plist from
    /// the same source this version string is baked from.
    @objc func showAbout() {
        var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "CompanionApp",
            .applicationVersion: CompanionClient.version,
        ]
        // A bare `swift run` has no bundle icon to fall back on; the
        // bundled app shows its AppIcon.icns without help.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            aboutOptions[.applicationIcon] = Self.maruhiAboutIcon()
        }
        NSApp.orderFrontStandardAboutPanel(options: aboutOptions)
        // An accessory app's panel would otherwise appear behind
        // whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The ㊙️ emoji (U+FE0F keeps the colour presentation) rendered at
    /// About-panel icon size.
    private static func maruhiAboutIcon() -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let glyph = "㊙\u{FE0F}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 200)
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
            return true
        }
    }
}
