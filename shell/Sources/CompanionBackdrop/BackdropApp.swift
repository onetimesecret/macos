import AppKit
import CompanionKit
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
                // the empty placeholder as a blank window. Repoint it so
                // every ⌘, in the app lands on the one real Settings
                // window the delegate owns.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class BackdropAppDelegate: NSObject, NSApplicationDelegate {
    private let model = BackdropModel()
    private var controller: BackdropWindowController?
    private var statusItem: NSStatusItem?
    private var summonKey: BackdropHotKey?
    private lazy var settings = BackdropSettingsWindowController(model: model)

    /// Not every activation is a summon. The launch's own arrives
    /// within moments of `applicationDidFinishLaunching` — and a
    /// login-item or background launch may never activate at all,
    /// which is why this is recency rather than a skip-one counter
    /// that would swallow the first real ⌘Tab hours later. About's
    /// activation is flagged by `showAbout`, and Settings' by
    /// `openSettings`, because those windows need the activation for
    /// themselves without dragging the surface up with them. Every
    /// other activation, whether by ⌘Tab or the Dock icon, is the user
    /// choosing this app, and answers with a raise.
    private var launchedAt = Date.distantPast
    private var aboutActivation = false
    private var settingsActivation = false

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

        // The ㊙️ maruhi ("secret"), shared with the panel app: the Dock
        // icon and the ⌘Tab card both draw from `applicationIconImage`,
        // so one colour rendering serves both. Only for a bare
        // `swift run`, which has no bundle: the bundled app carries
        // AppIcon.icns (scripts/build-icons.sh), and this override
        // would shadow it. The menu-bar item gets the monochrome
        // template below either way.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = Self.maruhiColorImage(side: 256)
        }

        let controller = BackdropWindowController(model: model)
        self.controller = controller
        // Esc, and every other hand-back route, rests the surface: the
        // backdrop's way of giving the keyboard back is to step behind
        // everything again.
        model.pages.onHandBackKeys = { [weak model] in model?.rest() }
        model.pages.onOpenSettings = { [weak self] in self?.openSettings() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.maruhiTemplateImage()
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
        // desktop on launch, resting, opened onto whatever page the last
        // quit sealed (`BackdropModel.start`).
        controller.show()
    }

    /// Quit is the one moment the page touches disk. Intercepted here
    /// rather than in `applicationWillTerminate` so a refused save
    /// reaches the user while there is still a choice to make: accept
    /// the loss, or stay and try again. Never a retry loop; cancelling
    /// simply returns to the surface.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.saveState() else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This page could not be saved"
        alert.informativeText =
            "The sealed state file was not written, so this session's page "
            + "will not survive the quit. The previous file, if any, is untouched."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
        if settingsActivation {
            settingsActivation = false
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
    /// decision); ⌥-click goes straight to Settings; right click gets
    /// the boring necessities (About, Settings, Quit; not features).
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
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
                withTitle: "About CompanionBackdrop",
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
            // a status-bar event can misreport modifiers, and an
            // accessibility press arrives with a stale currentEvent. ⌥
            // physically held right now is the one honest signal: that
            // opens Settings; anything else summons.
            openSettings()
        } else {
            model.summon()
        }
    }

    /// The Settings window, from the menu bar's ⌘, or either of the
    /// tray's routes. Its `show()` activates the app so the window can
    /// take the keyboard, and that activation must not read as a summon:
    /// the user asked for Settings, not the surface. Flag it, mirroring
    /// About, and only when the activation will actually happen, since
    /// an already-active app fires no notification to consume the flag.
    @objc func openSettings() {
        settingsActivation = !NSApp.isActive
        settings.show()
    }

    /// The standard About panel; the version comes from the core (the
    /// same source the bundle's plist is stamped from), because a bare
    /// `swift run` binary has no Info.plist to read it from.
    @objc private func showAbout() {
        var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "CompanionBackdrop",
            .applicationVersion: CompanionClient.version,
        ]
        // A bare `swift run` has no bundle icon to fall back on; the
        // bundled app shows its AppIcon.icns without help.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            aboutOptions[.applicationIcon] = Self.maruhiColorImage(side: 256)
        }
        NSApp.orderFrontStandardAboutPanel(options: aboutOptions)
        // The app is usually inactive when About is chosen from the
        // status item; without activation the panel appears behind
        // whatever is frontmost. This activation is About's, not a
        // summon — flag it so the raise is skipped (only when the
        // activation will actually happen; an already-active app fires
        // no notification to consume the flag).
        aboutActivation = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The ㊙ glyph rendered monochrome (U+FE0E forces text presentation
    /// over emoji) onto a template image: the menu bar tints template
    /// images to match its appearance, which a colour emoji never gets.
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

    /// The ㊙️ emoji (U+FE0F keeps the colour presentation) rendered at
    /// the given side length — the Dock icon, ⌘Tab card, and About panel.
    private static func maruhiColorImage(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let glyph = "㊙\u{FE0F}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.78)
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
