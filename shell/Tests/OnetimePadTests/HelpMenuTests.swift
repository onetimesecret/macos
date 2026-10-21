import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The Help menu's first item is the app's help (issue #294): its title
/// names the product, its chord is ⌘?, and it opens the docs through the
/// model's `openURL` seam rather than the shared workspace.
@MainActor
final class HelpMenuTests: XCTestCase {
    private final class OpenedLinks {
        var urls: [URL] = []
    }

    private func makeDelegate(opened: OpenedLinks) -> BackdropAppDelegate {
        let suite = "onetimepad.help-menu-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        let handle = "help-menu".withCString { companion_new_ephemeral($0) }!
        let pages = PageModel(
            formFactor: .backdrop, defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: CompanionClient(adopting: handle),
                openURL: { opened.urls.append($0) }))
        let model = BackdropModel(defaults: defaults, pages: pages)
        return BackdropAppDelegate(model: model)
    }

    private func makeMainMenu() -> (main: NSMenu, help: NSMenu) {
        let mainMenu = NSMenu()
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Export Diagnostics…", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        return (mainMenu, helpMenu)
    }

    func testTheHelpItemHeadsTheMenuWithItsChord() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()

        let helpMenu = BackdropAppDelegate.installHelpItem(
            in: menus.main, productName: "OnetimePad", target: delegate)

        XCTAssertTrue(helpMenu === menus.help, "the menu returned is the one for NSApp.helpMenu")
        let item = try XCTUnwrap(menus.help.items.first)
        XCTAssertEqual(item.title, "OnetimePad Help")
        XCTAssertEqual(item.keyEquivalent, "?")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item.action, #selector(BackdropAppDelegate.openHelp(_:)))
        XCTAssertTrue(item.target === delegate)
        XCTAssertTrue(menus.help.items[1].isSeparatorItem)
        XCTAssertEqual(menus.help.items[2].title, "Export Diagnostics…")
    }

    func testASecondInstallAddsNothing() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        BackdropAppDelegate.installHelpItem(
            in: menus.main, productName: "OnetimePad", target: delegate)
        let first = try XCTUnwrap(menus.help.items.first)

        let again = BackdropAppDelegate.installHelpItem(
            in: menus.main, productName: "OnetimePad", target: delegate)

        XCTAssertTrue(again === menus.help)
        XCTAssertEqual(menus.help.numberOfItems, 3)
        XCTAssertTrue(menus.help.items.first === first)
    }

    func testAnEmptyHelpMenuGetsNoSeparator() {
        let delegate = makeDelegate(opened: OpenedLinks())
        let mainMenu = NSMenu()
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = NSMenu(title: "Help")
        mainMenu.addItem(helpItem)

        BackdropAppDelegate.installHelpItem(
            in: mainMenu, productName: "OnetimePad", target: delegate)

        XCTAssertEqual(helpItem.submenu?.items.map(\.title), ["OnetimePad Help"])
    }

    func testTheHelpItemOpensTheDocsThroughTheInjectedOpener() throws {
        let opened = OpenedLinks()
        let delegate = makeDelegate(opened: opened)
        let menus = makeMainMenu()
        BackdropAppDelegate.installHelpItem(
            in: menus.main, productName: "OnetimePad", target: delegate)
        let item = try XCTUnwrap(menus.help.items.first)
        let target = try XCTUnwrap(item.target as? NSObject)
        let action = try XCTUnwrap(item.action)

        _ = target.perform(action, with: item)

        XCTAssertEqual(opened.urls, [URL(string: "https://docs.onetimesecret.dev/macos")!])
    }

    func testNoHelpMenuMeansNothingToInstall() {
        let delegate = makeDelegate(opened: OpenedLinks())
        let mainMenu = NSMenu()
        XCTAssertNil(BackdropAppDelegate.installHelpItem(
            in: mainMenu, productName: "OnetimePad", target: delegate))
        XCTAssertNil(BackdropAppDelegate.installHelpItem(
            in: nil, productName: "OnetimePad", target: delegate))
    }
}
