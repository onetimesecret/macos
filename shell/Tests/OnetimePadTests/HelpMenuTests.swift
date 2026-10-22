import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The Help menu's product help item (issue #294), first among the app's own: its title
/// names the product, its chord is the keymap's `app::Help`, and it opens
/// the docs through the model's `openExternal` seam, not the shared workspace.
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

    /// The bundled default's `app::Help` chord, read the way the delegate reads it.
    private func helpChord() throws -> Keystroke? {
        let text = try XCTUnwrap(Keymap.bundledDefaultText())
        return Keymap.resolve(defaultText: text, overrideText: nil).menuKeystroke(for: .appHelp)
    }

    @discardableResult
    private func install(
        in mainMenu: NSMenu?, keystroke: Keystroke? = nil, target: BackdropAppDelegate
    ) -> NSMenu? {
        BackdropAppDelegate.installHelpItem(
            in: mainMenu, productName: "OnetimePad", keystroke: keystroke, target: target)
    }

    func testTheHelpItemHeadsTheMenuWithItsChord() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()

        let helpMenu = install(in: menus.main, keystroke: try helpChord(), target: delegate)

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

    /// A keymap that unbinds `app::Help` leaves the item without a chord.
    func testAnUnboundChordLeavesTheItemWithoutOne() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        let text = try XCTUnwrap(Keymap.bundledDefaultText())
        let unbound = Keymap.resolve(
            defaultText: text,
            overrideText: #"[{ "context": "Editor", "bindings": { "cmd-?": null } }]"#)
        XCTAssertEqual(unbound.faults, [])

        install(in: menus.main, keystroke: unbound.menuKeystroke(for: .appHelp), target: delegate)

        let item = try XCTUnwrap(menus.help.items.first)
        XCTAssertEqual(item.title, "OnetimePad Help")
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])
    }

    func testASecondInstallAddsNothing() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        install(in: menus.main, target: delegate)
        let first = try XCTUnwrap(menus.help.items.first)

        let again = install(in: menus.main, target: delegate)

        XCTAssertTrue(again === menus.help)
        XCTAssertEqual(menus.help.numberOfItems, 3)
        XCTAssertTrue(menus.help.items.first === first)
    }

    /// The guard asks whether the item is in the menu, not whether it is
    /// first, so an item put above it does not earn a second copy.
    func testAnItemBelowTheHeadIsNotInstalledTwice() {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        install(in: menus.main, target: delegate)
        menus.help.insertItem(withTitle: "Search", action: nil, keyEquivalent: "", at: 0)
        let count = menus.help.numberOfItems

        install(in: menus.main, target: delegate)

        XCTAssertEqual(menus.help.numberOfItems, count)
        XCTAssertEqual(
            menus.help.items.filter { $0.action == #selector(BackdropAppDelegate.openHelp(_:)) }.count, 1)
    }

    /// The install runs again on every activation, so an item a menu
    /// rebuild dropped comes back, with one separator and no second copy.
    func testInstallingAgainAfterTheItemIsDroppedPutsItBack() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        install(in: menus.main, target: delegate)
        let help = try XCTUnwrap(menus.help.items.first)
        menus.help.removeItem(help)

        install(in: menus.main, target: delegate)

        XCTAssertEqual(
            menus.help.items.map { $0.isSeparatorItem ? "-" : $0.title },
            ["OnetimePad Help", "-", "Export Diagnostics…"])
        install(in: menus.main, target: delegate)
        XCTAssertEqual(menus.help.numberOfItems, 3)
    }

    /// An item drawn by a view of its own stays above ours.
    func testAnItemWithAViewStaysAboveTheHelpItem() throws {
        let delegate = makeDelegate(opened: OpenedLinks())
        let menus = makeMainMenu()
        let viewItem = NSMenuItem()
        viewItem.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        menus.help.insertItem(viewItem, at: 0)

        install(in: menus.main, target: delegate)

        XCTAssertTrue(menus.help.items[0] === viewItem)
        XCTAssertEqual(menus.help.items[1].title, "OnetimePad Help")
        XCTAssertTrue(menus.help.items[2].isSeparatorItem)
    }

    func testAnEmptyHelpMenuGetsNoSeparator() {
        let delegate = makeDelegate(opened: OpenedLinks())
        let mainMenu = NSMenu()
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = NSMenu(title: "Help")
        mainMenu.addItem(helpItem)

        install(in: mainMenu, target: delegate)

        XCTAssertEqual(helpItem.submenu?.items.map(\.title), ["OnetimePad Help"])
    }

    func testTheHelpItemOpensTheDocsThroughTheInjectedOpener() throws {
        let opened = OpenedLinks()
        let delegate = makeDelegate(opened: opened)
        let menus = makeMainMenu()
        install(in: menus.main, target: delegate)
        let item = try XCTUnwrap(menus.help.items.first)
        let target = try XCTUnwrap(item.target as? NSObject)
        let action = try XCTUnwrap(item.action)

        _ = target.perform(action, with: item)

        XCTAssertEqual(opened.urls, [URL(string: "https://docs.onetimesecret.dev/macos")!])
    }

    func testNoHelpMenuMeansNothingToInstall() {
        let delegate = makeDelegate(opened: OpenedLinks())
        let mainMenu = NSMenu()
        XCTAssertNil(install(in: mainMenu, target: delegate))
        XCTAssertNil(install(in: nil, target: delegate))
    }
}
