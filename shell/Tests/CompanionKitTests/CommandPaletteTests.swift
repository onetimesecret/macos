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
        XCTAssertEqual(entries.map(\.command), [
            .appOpenTimeline, .appSwitchToTabs, .pageReopenDated, .pageReopenLast,
            .pageNew, .fileOpen, .appSettings, .appHelp, .windowClose,
            .stateSaveNow, .fileSaveAs, .pageClose, .pagePrevious, .pageNext, .editorToggleWrap,
            .clipboardSeal, .clipboardSealSelection, .chipCopyDecrypted, .editorUndo, .editorRedo,
            .editorDetectCodeLanguage, .noteToggleExpanded
        ])
        XCTAssertEqual(Set(entries.map(\.command)), Set(CommandID.allCases.filter { $0.paletteDefinition != nil }))
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
        XCTAssertEqual(map.menuKeystroke(for: .pageClose), try Keystroke.parse("cmd-w").get())
    }

    func testWindowOnlyCommandsDoNotAdvertiseUninstalledMenuChords() {
        let map = Keymap.resolve(defaultText:
            #"[{"context":"Editor","use_key_equivalents":false,"bindings":{"cmd-h":"app::Help","cmd-shift-w":"window::Close","cmd-n":"page::New"}}]"#,
            overrideText: nil)
        let entries = CommandPaletteCatalog.entries(keymap: map)
        XCTAssertNil(entries.first { $0.command == .appHelp }?.shortcut)
        XCTAssertNil(entries.first { $0.command == .windowClose }?.shortcut)
        XCTAssertEqual(entries.first { $0.command == .pageNew }?.shortcut, "⌘N")
    }

    func testContextualCloseTitleRetainsPageAndTabSearchAliases() throws {
        let map = Keymap.resolve(defaultText: try XCTUnwrap(Keymap.bundledDefaultText()), overrideText: nil)
        let close = try XCTUnwrap(CommandPaletteCatalog.entries(keymap: map).first { $0.command == .pageClose })
        XCTAssertTrue(close.matches("close tab", title: "Close Page"))
        XCTAssertTrue(close.matches("close page", title: "Close File"))
    }

    func testReopenDatedDispatchReportsWhetherItsCallbackExists() throws {
        let tag = "palette-dispatch-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: tag))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: tag)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = PageModel(formFactor: .panel, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: tag)))
        XCTAssertFalse(model.perform(.pageReopenDated))
        var requests = 0
        model.onReopenDatedTabs = { requests += 1 }
        XCTAssertTrue(model.perform(.pageReopenDated))
        XCTAssertEqual(requests, 1)
        model.onReopenDatedTabs = nil
        XCTAssertFalse(model.perform(.pageReopenDated))
        XCTAssertEqual(requests, 1)
    }

}
