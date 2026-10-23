import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

@MainActor
final class FindMenuTests: XCTestCase {
    private func withApplication(_ test: (BackdropAppDelegate) throws -> Void) rethrows {
        _ = NSApplication.shared
        let suite = "onetimepad.find-menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let oldMain = NSApp.mainMenu
        let oldWindows = NSApp.windowsMenu
        let oldHelp = NSApp.helpMenu
        let oldServices = NSApp.servicesMenu
        let oldServicesItem = oldServices?.supermenu?.items.first { $0.submenu === oldServices }
        defer {
            oldServices?.supermenu?.items.first { $0.submenu === oldServices }?.submenu = nil
            oldServicesItem?.submenu = oldServices
            NSApp.mainMenu = oldMain
            NSApp.windowsMenu = oldWindows
            NSApp.helpMenu = oldHelp
            NSApp.servicesMenu = oldServices
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        companion_init()
        let handle = suite.withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle)))
        let app = BackdropAppDelegate(model: BackdropModel(defaults: defaults, pages: pages))
        try test(app)
        withExtendedLifetime(app) {}
    }

    func testFindCommandsRetainNativeActionsAndShortcuts() throws {
        try withApplication { app in
            let menus = MainMenuController(app: app)
            menus.install()
            let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
            let find = try XCTUnwrap(edit.items.first { $0.title == "Find" }?.submenu)
            let expected: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
                ("Find…", "f", .command, .showFindInterface),
                ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
                ("Find Next", "g", .command, .nextMatch),
                ("Find Previous", "g", [.command, .shift], .previousMatch),
                ("Use Selection for Find", "e", .command, .setSearchString)
            ]
            for (title, key, modifiers, action) in expected {
                let item = try XCTUnwrap(find.items.first { $0.title == title })
                XCTAssertNil(item.target, title)
                XCTAssertEqual(item.action, #selector(NSTextView.performTextFinderAction(_:)), title)
                XCTAssertEqual(item.tag, action.rawValue, title)
                XCTAssertEqual(item.keyEquivalent, key, title)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, title)
            }
            withExtendedLifetime((app, menus)) {}
        }
    }

    func testJumpToSelectionUsesTheNativeResponderAction() throws {
        try withApplication { app in
            let menus = MainMenuController(app: app)
            menus.install()
            let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
            let find = try XCTUnwrap(edit.items.first { $0.title == "Find" }?.submenu)
            let jump = try XCTUnwrap(find.items.first { $0.title == "Jump to Selection" })
            XCTAssertEqual(jump.action, #selector(NSResponder.centerSelectionInVisibleArea(_:)))
            XCTAssertNil(jump.target)
            XCTAssertEqual(jump.keyEquivalent, "j")
            XCTAssertEqual(jump.keyEquivalentModifierMask, .command)
            withExtendedLifetime(menus) {}
        }
    }

    func testCharacterPaletteUsesThePublicNativeAction() throws {
        try withApplication { app in
            let menus = MainMenuController(app: app)
            menus.install()
            let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
            let palette = try XCTUnwrap(edit.items.first { $0.title == "Emoji & Symbols" })
            XCTAssertEqual(palette.action, #selector(NSApplication.orderFrontCharacterPalette(_:)))
            XCTAssertNil(palette.target)
            XCTAssertEqual(palette.keyEquivalent, "")
            withExtendedLifetime(menus) {}
        }
    }

    func testArchivedActionItemDecodesAsDisabledNoOp() throws {
        try withApplication { app in
            let menus = MainMenuController(app: app)
            menus.install()
            let application = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
            let settings = try XCTUnwrap(application.items.first { $0.title == "Settings…" })
            let data = try NSKeyedArchiver.archivedData(withRootObject: settings, requiringSecureCoding: false)
            let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSMenuItem)
            XCTAssertEqual(decoded.title, settings.title)
            XCTAssertEqual(decoded.keyEquivalent, settings.keyEquivalent)
            XCTAssertFalse(decoded.isEnabled)
            let validation = try XCTUnwrap(decoded as? NSMenuItemValidation)
            XCTAssertFalse(validation.validateMenuItem(decoded))
            let action = try XCTUnwrap(decoded.action)
            XCTAssertTrue(NSApp.sendAction(action, to: decoded.target, from: decoded))
            XCTAssertNil(app.madeSettings)
            withExtendedLifetime(menus) {}
        }
    }

    func testReleasedMenuControllerCanBeValidatedAndReinstalled() throws {
        try withApplication { app in
            weak var released: MainMenuController?
            do {
                let menus = MainMenuController(app: app)
                released = menus
                menus.install()
            }
            XCTAssertNil(released)
            let oldMain = try XCTUnwrap(NSApp.mainMenu)
            let file = try XCTUnwrap(oldMain.items.first { $0.title == "File" }?.submenu)
            file.update()
            let close = try XCTUnwrap(file.items.first { $0.title == "Close" })
            XCTAssertFalse(close.isEnabled)
            let edit = try XCTUnwrap(oldMain.items.first { $0.title == "Edit" }?.submenu)
            edit.update()
            let choose = edit.items.first { $0.title == "Choose Language" }
            if let choose {
                XCTAssertFalse(choose.isEnabled)
                if let language = choose.submenu?.items.last, let action = language.action {
                    XCTAssertTrue(NSApp.sendAction(action, to: language.target, from: language))
                }
            }
            let replacement = MainMenuController(app: app)
            replacement.install()
            let newMain = try XCTUnwrap(NSApp.mainMenu)
            XCTAssertFalse(newMain === oldMain)
            let application = try XCTUnwrap(newMain.items.first?.submenu)
            let services = try XCTUnwrap(application.items.first { $0.title == "Services" }?.submenu)
            let windows = try XCTUnwrap(newMain.items.first { $0.title == "Window" }?.submenu)
            XCTAssertTrue(NSApp.servicesMenu === services)
            XCTAssertTrue(NSApp.windowsMenu === windows)
            file.update()
            edit.update()
            withExtendedLifetime(replacement) {}
        }
    }
}
