import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testThePaletteShortcutComesFromJSONAndCanBeReboundOrRemoved() throws {
        let text = try XCTUnwrap(Keymap.bundledDefaultText())
        let standard = Keymap.resolve(defaultText: text, overrideText: nil)
        XCTAssertEqual(standard.command(for: try Keystroke.parse("cmd-shift-p").get(), in: .editor), .appCommandPalette)
        XCTAssertEqual(CommandID.appCommandPalette.dispatch, .window)
        let changed = Keymap.resolve(defaultText: text, overrideText:
            #"[{ "context": "Editor", "use_key_equivalents": true, "bindings": { "cmd-shift-p": null, "cmd-alt-p": "app::CommandPalette" } }]"#)
        XCTAssertNil(changed.command(for: try Keystroke.parse("cmd-shift-p").get(), in: .editor))
        XCTAssertEqual(changed.menuKeystroke(for: .appCommandPalette)?.displaySymbol, "⌥⌘P")
    }

    func testApplicationCommandsPrecedePageAndSelectionCommands() throws {
        let map = Keymap.resolve(defaultText: try XCTUnwrap(Keymap.bundledDefaultText()), overrideText: nil)
        let entries = CommandPaletteCatalog.entries(keymap: map)
        XCTAssertEqual(entries.map(\.scope.rawValue), entries.map(\.scope.rawValue).sorted())
        XCTAssertEqual(Set(entries.map(\.command)).count, entries.count)
        for command in [CommandID.appOpenTimeline, .appSwitchToTabs, .pageReopenLast, .pageReopenDated] {
            XCTAssertEqual(entries.first { $0.command == command }?.scope, .application)
        }
    }

    func testSearchMatchesWordsAcrossTitleAndCommandWithoutChangingOrder() throws {
        let map = Keymap.resolve(defaultText: try XCTUnwrap(Keymap.bundledDefaultText()), overrideText: nil)
        let entries = CommandPaletteCatalog.entries(keymap: map)
        XCTAssertEqual(entries.filter { $0.matches("reopen dated") }.map(\.command), [.pageReopenDated])
        XCTAssertEqual(entries.filter { $0.matches("re-open dated") }.map(\.command), [.pageReopenDated])
        XCTAssertEqual(entries.filter { $0.matches("clipboard seal") }.map(\.command), [.clipboardSeal, .clipboardSealSelection])
        XCTAssertTrue(entries.allSatisfy { $0.matches("  ") })
        XCTAssertTrue(entries.filter { $0.matches("unavailable-zebra") }.isEmpty)
    }

    func testControlWAndCommandWResolveToPageCloseWhileShiftCommandWClosesTheWindow() throws {
        let map = Keymap.resolve(defaultText: try XCTUnwrap(Keymap.bundledDefaultText()), overrideText: nil)
        for chord in ["ctrl-w", "cmd-w"] {
            XCTAssertEqual(map.command(for: try Keystroke.parse(chord).get(), in: .editor), .pageClose)
        }
        XCTAssertEqual(map.command(for: try Keystroke.parse("cmd-shift-w").get(), in: .editor), .windowClose)
    }
}
