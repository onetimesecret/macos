import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private func withApplication(keymapOverride: String? = nil, _ test: (BackdropAppDelegate, BackdropModel) throws -> Void) rethrows {
        _ = NSApplication.shared
        let suite = "onetimepad.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        companion_init()
        let handle = suite.withCString { companion_new_ephemeral($0) }!
        var overrideURL: URL?
        if let keymapOverride {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("keymap.json")
            try! keymapOverride.write(to: file, atomically: true, encoding: .utf8)
            overrideURL = file
        }
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle), keymapOverride: overrideURL))
        let model = BackdropModel(defaults: defaults, pages: pages)
        try test(BackdropAppDelegate(model: model), model)
    }

    func testUnbundledAndUnrecognizedLaunchesAreRejected() {
        for identifier in [nil, "", "dev.onetimepad.settings-lifecycle-probe", "com.example.OnetimePad",
                           "dev.onetimesecret.pad.debug.copy", "com.onetimesecret.companion"] as [String?] {
            XCTAssertFalse(AppLaunchIdentity.accepts(identifier))
        }
        for identifier in [FormFactor.backdropBundleIdentifier, FormFactor.localBundleIdentifier,
                           FormFactor.devBundleIdentifier] {
            XCTAssertTrue(AppLaunchIdentity.accepts(identifier))
        }
    }

    func testExplicitSettingsAndRepeatedActivationDoNotCreateAnEditor() throws {
        try withApplication { app, model in
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.openSettings()
            let settings = try XCTUnwrap(app.madeSettings?.window)
            defer { settings.close() }
            for _ in 0..<3 {
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
                XCTAssertFalse(model.editorWindowOpen)
                XCTAssertTrue(app.madeSettings?.window === settings)
            }
            settings.close()
            app.openSettings()
            XCTAssertTrue(app.madeSettings?.window === settings)
        }
    }

    func testBackgroundStartupAndOrdinaryActivationOpenNoSettingsOrEditor() {
        withApplication { app, model in
            var initialOpens = 0
            app.selectInitialEditor = { initialOpens += 1 }
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            for _ in 0..<3 {
                app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            }
            XCTAssertEqual(initialOpens, 0)
            XCTAssertFalse(model.editorWindowOpen)
            XCTAssertNil(app.madeSettings)
        }
    }

    func testForegroundOpenWaitsForStartupAndIsConsumedOnce() {
        withApplication { app, model in
            var opens = 0
            app.selectInitialEditor = { opens += 1 }
            XCTAssertTrue(app.applicationShouldOpenUntitledFile(NSApplication.shared))
            XCTAssertTrue(app.applicationOpenUntitledFile(NSApplication.shared))
            XCTAssertEqual(opens, 0)
            app.completeStartup(Notification(name: NSApplication.didFinishLaunchingNotification))
            XCTAssertEqual(opens, 1)
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            XCTAssertEqual(opens, 1)
            XCTAssertNil(app.madeSettings)
            XCTAssertFalse(model.editorWindowOpen)
        }
    }

    func testMenuInstallationCreatesNoWindowsAndPreservesNativeResponderTargets() throws {
        try withApplication { app, model in
            let oldMain = NSApp.mainMenu
            let oldWindows = NSApp.windowsMenu
            let oldHelp = NSApp.helpMenu
            let oldServices = NSApp.servicesMenu
            defer {
                NSApp.mainMenu = oldMain
                NSApp.windowsMenu = oldWindows
                NSApp.helpMenu = oldHelp
                NSApp.servicesMenu = oldServices
            }
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let menus = MainMenuController(app: app)
            menus.install()
            let main = try XCTUnwrap(NSApp.mainMenu)
            XCTAssertEqual(main.items.map(\.title), [BackdropAppDelegate.productName, "File", "Edit", "View", "Window", "Help"])
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), before)
            XCTAssertNil(app.madeSettings)
            let settings = try XCTUnwrap(main.items[0].submenu?.items.first { $0.title == "Settings…" })
            XCTAssertEqual(settings.keyEquivalent, app.settingsKeystroke?.menuKeyEquivalent ?? "")
            let edit = try XCTUnwrap(main.items.first { $0.title == "Edit" }?.submenu)
            for title in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
                let item = try XCTUnwrap(edit.items.first { $0.title == title })
                XCTAssertNil(item.target)
                XCTAssertNotNil(item.action)
            }
            let window = try XCTUnwrap(main.items.first { $0.title == "Window" }?.submenu)
            XCTAssertTrue(NSApp.windowsMenu === window)
            let ambient = try XCTUnwrap(window.items.first { $0.title == "Show Ambient Panel" })
            model.setAmbientPanelEnabled(false)
            window.update()
            XCTAssertFalse(ambient.isEnabled)
        }
    }

    func testUnboundMenuCommandsKeepTheirItemsWithoutShortcuts() throws {
        let keymap = #"[{"context":"Editor","bindings":{"cmd-,":null,"cmd-shift-w":null}}]"#
        try withApplication(keymapOverride: keymap) { app, _ in
            let oldMain = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldServices = NSApp.servicesMenu
            defer { NSApp.mainMenu = oldMain; NSApp.windowsMenu = oldWindows; NSApp.servicesMenu = oldServices }
            let menus = MainMenuController(app: app)
            menus.install()
            let main = try XCTUnwrap(NSApp.mainMenu)
            for title in ["Settings…", "Close Window"] {
                let item = try XCTUnwrap(main.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == title })
                XCTAssertEqual(item.keyEquivalent, "")
                XCTAssertEqual(item.keyEquivalentModifierMask, [])
                XCTAssertNotNil(item.action)
            }
        }
    }

    func testAVisibleCompanionPanelPreventsEditorReopen() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.orderFront(nil)
        XCTAssertTrue(BackdropAppDelegate.isVisibleOrdinaryWindow(
            panel, isAmbientWindow: false, isCompanion: true))
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(
            panel, isAmbientWindow: true, isCompanion: true))
    }

    func testOnlyVisibleOrdinaryWindowsPreventAnEditorReopen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: false))
        window.orderFront(nil)
        XCTAssertTrue(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: false))
        XCTAssertFalse(BackdropAppDelegate.isVisibleOrdinaryWindow(window, isAmbientWindow: true))
    }
}
