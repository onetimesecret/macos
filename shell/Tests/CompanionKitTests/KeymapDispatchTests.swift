import XCTest

@testable import CompanionKit

/// The registry: that every command id the keymap may name is a thing
/// this build actually does, and that the two dispatch routes divide
/// the work between them without a gap (issue #76).
///
/// The model here owns everything it touches: a temporary directory
/// and an in-process credential store, through `isolatedModel`. A
/// model built without seams under the test runner resolves the
/// installed app's own pages and ledger, and these tests run commands
/// that create, close and save.
@MainActor
final class KeymapDispatchTests: XCTestCase {
    private func makeModel(keymapOverride: URL? = nil) throws -> PageModel {
        let suiteName = "companion-keymap-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-keymap-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: "keymap-\(UUID().uuidString)"),
                keymapOverride: keymapOverride
            )
        )
    }

    /// The exhaustive switch in `PageModel.perform` is checked by the
    /// compiler, but "there is an arm for it" is not the same as "the
    /// arm belongs to this route". This is the second half.
    func testEverySurfaceCommandIsTheModelsToRun() throws {
        let model = try makeModel()
        for command in CommandID.allCases where command.dispatch == .surface {
            XCTAssertTrue(
                model.perform(command),
                "\(command.rawValue) is dispatched by the surface but the model refused it")
        }
    }

    /// The seal gestures are refused by the model on purpose: the caret
    /// and the selection they act on belong to the page's text view.
    func testTheSealGesturesAreNotTheModelsToRun() throws {
        let model = try makeModel()
        XCTAssertFalse(model.perform(.clipboardSeal))
        XCTAssertFalse(model.perform(.clipboardSealSelection))
    }

    func testAJumpCommandSelectsThatPlaceInTheTabOrder() throws {
        let model = try makeModel()
        model.perform(.pageNew)
        model.perform(.pageNew)
        let first = try XCTUnwrap(model.tabs.first?.id)
        model.perform(.pageSelect2)
        XCTAssertNotEqual(model.selection, first)
        model.perform(.pageSelect1)
        XCTAssertEqual(model.selection, first)
    }

    func testANewPageCommandOpensOne() throws {
        let model = try makeModel()
        XCTAssertTrue(model.tabs.isEmpty)
        model.perform(.pageNew)
        XCTAssertEqual(model.tabs.count, 1)
    }

    /// The surface installs the chords it carries and leaves the page's
    /// alone, whatever the file happens to say.
    func testTheSurfaceInstallsOnlyItsOwnHalfOfTheMap() throws {
        let model = try makeModel()
        let installed = model.keymap.surfaceShortcuts().map(\.command)
        XCTAssertFalse(installed.contains(.clipboardSeal))
        XCTAssertFalse(installed.contains(.clipboardSealSelection))
        XCTAssertFalse(installed.contains(.editorToggleWrap))
        XCTAssertTrue(installed.contains(.pageNew))
    }

    // MARK: What the buttons say you can press

    /// The + button's tooltip is the one place the app spells a chord
    /// out in prose, so it has to be reading the same map the chord came
    /// from. It used to say ⌘N because someone typed ⌘N.
    func testTheNewPageTooltipFollowsTheMap() throws {
        let model = try makeModel()
        XCTAssertEqual(
            TabStripView.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)),
            "New page (⌘N)")
    }

    func testTheNewPageTooltipFollowsAnOverrideThatMovedTheChord() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-\(UUID().uuidString).json")
        try #"[{ "context": "Editor", "bindings": { "cmd-n": null, "ctrl-alt-k": "page::New" } }]"#
            .write(to: override, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: override) }

        let model = try makeModel(keymapOverride: override)
        XCTAssertEqual(
            TabStripView.newPageHelp(chord: model.keymap.hintKeystroke(for: .pageNew)),
            "New page (⌃⌥K)")
    }

    /// A tooltip must not go on advertising a chord the file took away.
    func testTheNewPageTooltipSaysNothingWhenNothingIsBound() {
        XCTAssertEqual(TabStripView.newPageHelp(chord: nil), "New page")
    }

    /// The ledger tab is the case that actually happened: the bundled
    /// keymap withdrew ⌘0 (issue #78) and the tooltip went on offering
    /// it. With nothing bound, it says only what the tab does.
    func testTheLedgerTooltipDropsTheChordTheDefaultWithdrew() throws {
        let model = try makeModel()
        XCTAssertNil(model.keymap.hintKeystroke(for: .ledgerShow))
        XCTAssertFalse(
            TabStripView.ledgerHelp(chord: model.keymap.hintKeystroke(for: .ledgerShow))
                .contains("("))
    }

    /// And an override that puts the ledger back on a chord gets a
    /// tooltip that names it.
    func testTheLedgerTooltipNamesAChordAnOverrideRestored() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-\(UUID().uuidString).json")
        try #"[{ "context": "Editor", "bindings": { "cmd-0": "ledger::Show" } }]"#
            .write(to: override, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: override) }

        let model = try makeModel(keymapOverride: override)
        XCTAssertTrue(
            TabStripView.ledgerHelp(chord: model.keymap.hintKeystroke(for: .ledgerShow))
                .hasSuffix("(⌘0)"))
    }

    /// The hint is not the menu equivalent: a section that declined key
    /// equivalents still bound the chord, and the tooltip still says so.
    func testAHintIsOfferedEvenWithoutKeyEquivalents() throws {
        let keymap = Keymap.resolve(
            defaultText: #"[{ "context": "Editor", "bindings": { "cmd-k": "page::New" } }]"#,
            overrideText: nil)
        XCTAssertNil(keymap.menuKeystroke(for: .pageNew))
        XCTAssertEqual(keymap.hintKeystroke(for: .pageNew)?.displaySymbol, "⌘K")
    }

    // MARK: The user's file, read from disk

    func testAModelReadsTheOverrideItWasPointedAt() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-\(UUID().uuidString).json")
        try """
            // A file with a comment in it, as a person would write.
            [{ "context": "Editor", "bindings": { "ctrl-alt-n": "page::New" } }]
            """.write(to: override, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: override) }

        let model = try makeModel(keymapOverride: override)
        guard case .success(let keystroke) = Keystroke.parse("ctrl-alt-n") else {
            return XCTFail("the chord under test does not parse")
        }
        XCTAssertEqual(model.keymap.command(for: keystroke, in: .editor), .pageNew)
        // The default is still underneath it: an override adds and
        // reassigns, it does not replace.
        XCTAssertTrue(model.keymap.bindings.contains { $0.command == .pageClose })
    }

    /// Absence is the ordinary case and must be silent.
    func testAMissingOverrideIsNotAComplaint() throws {
        let model = try makeModel(
            keymapOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("keymap-that-was-never-written.json"))
        XCTAssertEqual(model.keymap.faults, [])
        XCTAssertFalse(model.keymap.bindings.isEmpty)
    }
}
