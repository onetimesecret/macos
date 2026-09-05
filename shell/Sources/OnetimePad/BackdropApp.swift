import AppKit
import CompanionKit
import SwiftUI

/// OnetimePad, the background-surface form factor
/// (docs/spec/feature/background-surface): an ambient pane resting at
/// desktop level, raised to a floating editor by ⌃⌥Space, ⌘Tab, the
/// Dock icon, or the menu-bar item. It began as a sibling of the panel
/// app (ADR-0010), same Rust core through the same seam, different
/// posture; the panel was archived once this form factor reached
/// parity (ADR-0014), and its state file and Keychain items remain
/// untouched by this target.
@main
struct BackdropApp: App {
    @NSApplicationDelegateAdaptor(BackdropAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scene renders anything; the status item + window
        // (built in the delegate) are the entire UI. A placeholder scene
        // is required by the `App` protocol.
        Settings {}
            .commands {
                // ⌘F and its neighbours. The editor answers
                // `performTextFinderAction:` (its find bar is on), but
                // nothing sends it without menu items to send it: the
                // card is borderless and this app's only declared scene
                // is the Settings placeholder, so the standard Edit menu
                // is asked for by name rather than assumed.
                TextEditingCommands()
                // The app's first File menu (ADR-0028). Every item
                // dispatches the same command id the chord does, so
                // there is one implementation of each verb and the menu
                // cannot drift from the keyboard; the chords are read
                // out of the keymap for the reason ⌘, is, so a person
                // who rebound one sees their own chord here.
                CommandMenu("File") {
                    FileMenuItems(
                        pages: appDelegate.pages,
                        openShortcut: appDelegate.shortcut(for: .fileOpen),
                        saveShortcut: appDelegate.shortcut(for: .stateSaveNow),
                        saveAsShortcut: appDelegate.shortcut(for: .fileSaveAs),
                        closeShortcut: appDelegate.shortcut(for: .pageClose)
                    )
                }
                // Undo is the core's stack (issue #132), so the menu
                // has to send the same action the chord does rather
                // than SwiftUI's own undo command, which drives the
                // environment's `UndoManager` and knows nothing about
                // the document. Both items post `undo:`/`redo:` down
                // the responder chain, where the page's text view
                // answers them. With no page holding the keyboard
                // nothing responds, and the click is a no-op rather
                // than a second history moving.
                //
                // The chords come from the keymap, like every other
                // chord this app advertises: nil means the file unbound
                // them, and then the items stay and lose the shortcut.
                CommandGroup(replacing: .undoRedo) {
                    UndoRedoItems(
                        steps: appDelegate.editSteps,
                        undoShortcut: appDelegate.undoShortcut,
                        redoShortcut: appDelegate.redoShortcut,
                        send: appDelegate.sendToResponder
                    )
                }
                // The scene's automatic "Settings…" (⌘,) item would open
                // the empty placeholder as a blank window. Repoint it so
                // every ⌘, in the app lands on the one real Settings
                // window the delegate owns.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(appDelegate.settingsShortcut)
                }
                // Repointed for the same reason and with more at stake.
                // The synthesized item calls AppKit's own
                // `orderFrontStandardAboutPanel:`, which builds the
                // panel with default collection behavior; the delegate's
                // route is what puts `.moveToActiveSpace` on it
                // (ADR-0019), and a panel left open on the desktop it
                // was first shown on carries the user back there on the
                // next ⌘Tab. The app is `.regular`, so this menu is on
                // screen whenever the app is active and the route is not
                // hypothetical. It also carries the version the core
                // reports, which the standard item cannot know.
                CommandGroup(replacing: .appInfo) {
                    Button("About \(BackdropAppDelegate.productName)") {
                        appDelegate.showAbout()
                    }
                }
            }
    }
}

/// The File menu: Open, Save, Save As and Close File (ADR-0028).
///
/// A view of its own for `UndoRedoItems`' reason: a `CommandMenu`'s
/// content is a view, and a view is what can observe the model whose
/// state greys three of these four out.
///
/// Every item goes through `perform`, the same route the chord takes,
/// so each verb has one implementation. Save, Save As and Close File
/// are dimmed while a page rather than a file is showing, because on a
/// page those chords mean something else entirely and a menu that
/// offered them under a file's names would be lying about what the
/// click does.
///
/// Enablement is display and never a gate: the model's own arms decide
/// what happens, and a click that arrives anyway lands on the page
/// reading of the chord rather than on nothing.
@MainActor
private struct FileMenuItems: View {
    @ObservedObject var pages: PageModel
    let openShortcut: KeyboardShortcut?
    let saveShortcut: KeyboardShortcut?
    let saveAsShortcut: KeyboardShortcut?
    let closeShortcut: KeyboardShortcut?

    /// Whether the surface is showing a file, which is what the three
    /// file verbs need to be true.
    private var onAFile: Bool {
        if case .file = pages.activeTarget { return true }
        return false
    }

    var body: some View {
        Button("Open…") { pages.perform(.fileOpen) }
            .keyboardShortcut(openShortcut)
        Divider()
        Button("Save") { pages.perform(.stateSaveNow) }
            .keyboardShortcut(saveShortcut)
            .disabled(!onAFile)
        Button("Save As…") { pages.perform(.fileSaveAs) }
            .keyboardShortcut(saveAsShortcut)
            .disabled(!onAFile)
        Divider()
        Button("Close File") { pages.perform(.pageClose) }
            .keyboardShortcut(closeShortcut)
            .disabled(!onAFile)
    }
}

/// The Edit menu's Undo and Redo.
///
/// A view of its own because a `CommandGroup`'s content is a view, and
/// a view is what can observe. The greying out has to be driven from
/// here: a SwiftUI menu item is not the nil-targeted `NSMenuItem` the
/// responder chain validates, it carries SwiftUI's own target, so
/// `InkTextView.validateMenuItem` is never asked about these two and
/// `.disabled` is the only thing that can dim them. What it reads is
/// still the core's own answer, re-asked by the model whenever the
/// page, its editability or its history can have moved; the text view
/// keeps its validation for any other route that arrives nil-targeted.
///
/// Enablement is display, never a gate. Both ends fail closed on their
/// own: the click posts an action nobody answers when no page holds the
/// keyboard, and the page refuses the step outright when it is shown
/// read-only.
@MainActor
private struct UndoRedoItems: View {
    @ObservedObject var steps: EditStepAvailability
    let undoShortcut: KeyboardShortcut?
    let redoShortcut: KeyboardShortcut?
    let send: (Selector) -> Void

    var body: some View {
        Button("Undo") { send(#selector(EditStepResponder.undo(_:))) }
            .keyboardShortcut(undoShortcut)
            .disabled(!steps.canUndo)
        Button("Redo") { send(#selector(EditStepResponder.redo(_:))) }
            .keyboardShortcut(redoShortcut)
            .disabled(!steps.canRedo)
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

        // The Dock and the ⌘Tab card draw from `applicationIconImage`.
        // Re-publish the bundled icon here rather than leaving AppKit to
        // resolve CFBundleIconFile, because LaunchServices can otherwise
        // keep the previous image in the switcher after an icon-only
        // update. A bare `swift run` has no bundle icon, so it keeps the
        // coloured maruhi fallback. The menu-bar item gets the monochrome
        // template below either way.
        NSApp.applicationIconImage = Self.bundledIconImage() ?? Self.maruhiColorImage(side: 256)

        let controller = BackdropWindowController(model: model)
        self.controller = controller
        // Esc, and every other hand-back route, rests the surface: the
        // backdrop's way of giving the keyboard back is to step behind
        // everything again.
        model.pages.onHandBackKeys = { [weak model] in model?.rest() }
        model.pages.onOpenSettings = { [weak self] in self?.openSettings() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.trayImage()
        item.button?.setAccessibilityLabel(Self.productName)
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

    /// Quit flushes whatever the debounce still holds; the debounced
    /// mutation write is what actually gets the page onto disk
    /// (ADR-0012). Intercepted here rather than in
    /// `applicationWillTerminate` so a refused save reaches the user
    /// while there is still a choice to make: accept the loss, or stay
    /// and try again. Never a retry loop; cancelling simply returns to
    /// the surface. Which outcome warns, with which story, and what the
    /// system is answered with belongs to `QuitPrompt`; what stays here
    /// is the alert itself.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitPrompt.terminateReply(flushing: model) { warning in
            let alert = NSAlert()
            alert.messageText = warning.messageText
            alert.informativeText = warning.informativeText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// ⌘Tab (or the Dock icon) landing on this app raises the surface:
    /// the user came here, so bring it, pulled to their Space and keyed,
    /// unconditionally, never a rest, because activation only ever
    /// means "bring it to me". The launch's own activation (and
    /// `showAbout`'s) is exempt: the backdrop starts resting, present
    /// but not summoned.
    ///
    /// Raised as an **activation** and not as a summon: the user named
    /// the app, not this surface, and someone who ⌘Tabbed away from a
    /// sentence in an older day is coming back to that sentence. What
    /// hangs off the distinction is the roll's anchor, see
    /// `BackdropRaise`.
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
        model.raise(.activation)
    }

    /// The Dock icon's click while the app is already active reaches
    /// here instead of `applicationDidBecomeActive`: the same raise, and
    /// the same activation, so that one gesture cannot mean two things
    /// depending on which of these two it happened to arrive at.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        model.raise(.activation)
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
                withTitle: "About \(Self.productName)",
                action: #selector(showAbout),
                keyEquivalent: ""
            ).target = self
            let settingsItem = menu.addItem(
                withTitle: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: settingsKeystroke?.menuKeyEquivalent ?? ""
            )
            settingsItem.keyEquivalentModifierMask = settingsKeystroke?.menuModifierMask ?? []
            settingsItem.target = self
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

    /// The chord Settings advertises, taken from the keymap
    /// (`app::Settings`) rather than spelled here.
    ///
    /// A menu key equivalent is an app-wide claim, live even while a
    /// Settings text field holds the keyboard, so only a keymap section
    /// that opted into `use_key_equivalents` can hand one out; the
    /// bundled default does. Nil means the file took the binding away,
    /// and then the menu shows the item without a chord, which is the
    /// right answer to "unbind Settings" and not a reason to put the
    /// old chord back.
    var settingsKeystroke: Keystroke? {
        model.pages.keymap.menuKeystroke(for: .appSettings)
    }

    /// The same chord for the SwiftUI command group, and nil for the
    /// same reason: a main-menu shortcut is the app-wide half of the
    /// claim, so restoring ⌘, here would hand back most of what the
    /// unbinding took away. Both menu items stay, and stay clickable;
    /// what a nil costs is the chord, which is what was asked for.
    ///
    /// The keymap has nothing to say only when the file took the
    /// binding away or moved it into a section that does not advertise
    /// chords. An override that cannot be read leaves the bundled
    /// default standing, and the bundled default binds ⌘, in a section
    /// that does; a bundled default this build lost binds nothing at
    /// all, and quietly keeping one chord out of the twenty would be
    /// the surprise, not the honesty.
    var settingsShortcut: KeyboardShortcut? {
        settingsKeystroke?.keyboardShortcut
    }

    /// The Edit menu's two undo chords, read from the keymap for the
    /// same reason ⌘, is: the file is the authoritative list of what
    /// the keyboard does, and a chord spelled in Swift here would
    /// survive a user unbinding it in their own keymap.
    ///
    /// The page's text view claims the same chord first, because a key
    /// equivalent reaches the key window's view chain before the main
    /// menu. The menu carries it to show what the item costs, not to be
    /// the thing that fires.
    var undoShortcut: KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: .editorUndo)?.keyboardShortcut
    }

    var redoShortcut: KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: .editorRedo)?.keyboardShortcut
    }

    /// Any command's advertised chord, on the same terms as the three
    /// above: the keymap decides, and nil means the file took the
    /// binding away and the item keeps its place without a chord.
    ///
    /// General rather than one property per command because the File
    /// menu needs four of them and four near-identical properties would
    /// be four places for the same rule to be written differently.
    func shortcut(for command: CommandID) -> KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: command)?.keyboardShortcut
    }

    /// The model the File menu reads its enablement from.
    var pages: PageModel { model.pages }

    /// What the two items grey themselves out on: the core's answer for
    /// the page under the editor, published by the model.
    var editSteps: EditStepAvailability { model.pages.editSteps }

    /// Post an action down the responder chain, which is how a menu
    /// item reaches whoever is first responder. Nothing happens when
    /// nothing answers, which is the fail-closed shape the whole seam
    /// keeps: a menu click with no page holding the keyboard moves no
    /// history at all.
    ///
    /// A `Selector` rather than a string: `undo:` misspelled would send
    /// nothing and look exactly like the honest case of nobody
    /// answering, which is the one failure this route cannot report.
    /// `EditStepResponder` is what lets the compiler check the pairing
    /// from a target that cannot see the page's text view.
    func sendToResponder(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
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

    /// The standard About panel. The version it leads with is the app's
    /// own, `CFBundleShortVersionString`, which since issue #89 is the
    /// product's number rather than the Rust seam's, with the stamped
    /// `CFBundleVersion` behind it in the panel's build slot: "Version
    /// 0.13.0 (0.13.0+ab12cd3)". A bare `swift run` binary has no
    /// Info.plist to read either key from, and there the core is the only
    /// version the process can honestly claim, so it stands alone as it
    /// did before. `AboutVersion.fields` holds that resolution, tested
    /// without a bundle or a panel.
    ///
    /// Every route to the panel goes through here, the tray menu and the
    /// app menu's own item alike, because what happens after the panel
    /// is up is load-bearing and AppKit's synthesized item skips it.
    @objc func showAbout() {
        let versions = AboutVersion.fields(
            core: CompanionClient.version,
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: Self.productName,
            .applicationVersion: versions.applicationVersion,
        ]
        // The build in parentheses, when there is one to show. Absent
        // rather than empty: an empty string would print bare
        // parentheses, which reads as a build the app failed to name.
        if let build = versions.build {
            aboutOptions[.version] = build
        }
        // A bare `swift run` has no bundle icon to fall back on; the
        // bundled app shows its AppIcon.icns without help.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            aboutOptions[.applicationIcon] = Self.maruhiColorImage(side: 256)
        }
        NSApp.orderFrontStandardAboutPanel(options: aboutOptions)
        // AppKit builds one About panel and reuses it for the life of
        // the process, and it is an ordinary window: left open, or
        // merely built, on another desktop, it is something of this app
        // to reveal, so the next activation carries the user's screen
        // there. That is exactly the defect ADR-0019 removed from the
        // surface, and Settings takes the same bit at creation. This
        // panel is not ours to construct, so the bit goes on after
        // AppKit has put it up.
        Self.standardAboutPanel()?.collectionBehavior.insert(.moveToActiveSpace)
        // The app is usually inactive when About is chosen from the
        // status item; without activation the panel appears behind
        // whatever is frontmost. This activation is About's, not a
        // summon — flag it so the raise is skipped (only when the
        // activation will actually happen; an already-active app fires
        // no notification to consume the flag).
        aboutActivation = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel `orderFrontStandardAboutPanel` has just put up. AppKit
    /// hands back no reference to it, so it is picked out of the app's
    /// windows by what it is: on screen, titled, and carrying no title
    /// text. Settings has a title, and the surface and its key relay are
    /// borderless, so none of ours can be mistaken for it. If a future
    /// macOS builds the panel differently the lookup finds nothing and
    /// the panel keeps the behavior it had before this existed.
    private static func standardAboutPanel() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.styleMask.contains(.titled) && window.title.isEmpty
        }
    }

    /// What this app calls itself to the user, for the places a bundle
    /// cannot answer: a bare `swift run` has no Info.plist, so the
    /// About panel, the tray menu and the status item's accessibility
    /// label would otherwise fall back to the executable name. The
    /// bundled app takes the same name from CFBundleName /
    /// CFBundleDisplayName in shell/OnetimePad-Info.plist, and the two
    /// must agree. Neither is the bundle id, which never changes.
    static let productName = "OnetimePad"

    /// Loads the icon named by CFBundleIconFile, which package-app.sh
    /// changes when the rendered artwork changes. Assigning this image to
    /// NSApp at launch keeps the current process's ⌘Tab presentation in
    /// step with Finder's bundle icon.
    private static func bundledIconImage() -> NSImage? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: name, withExtension: "icns")
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// What sits in the menu bar: the onetimesecret.com logo mark, the
    /// same art the app icon is built from, so the tray and the Dock
    /// tile read as one app. Template images are tinted by the menu bar
    /// for its appearance and for selection, which is why the mark goes
    /// up as a flat silhouette rather than as brand colour.
    ///
    /// The maruhi stands in if the mark cannot be read, since a menu bar
    /// with nothing in it leaves no way back to the surface.
    private static func trayImage() -> NSImage {
        LogoMark.templateImage(side: 18) ?? maruhiTemplateImage()
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
