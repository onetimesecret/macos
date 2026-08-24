import XCTest

@testable import CompanionKit

/// The bundled default keymap itself (issue #76): that this build can
/// find it, that it validates without a single complaint, and that it
/// says exactly what the keyboard has always done.
///
/// The table below is the whole point of the suite. Before the keymap
/// existed, the chords lived in Swift and moving one was a code change
/// nobody could review as a list. Now the list is the file, and this is
/// the assertion that the file and the list agree: an edit that changes
/// what the keyboard does has to change this table too, in the same
/// commit, where a reviewer can see both halves at once.
final class BundledKeymapTests: XCTestCase {
    /// Every chord the app ships with, spelled canonically, with the
    /// command it runs.
    private static let expected: [String: CommandID] = [
        "cmd-1": .pageSelect1,
        "cmd-2": .pageSelect2,
        "cmd-3": .pageSelect3,
        "cmd-4": .pageSelect4,
        "cmd-5": .pageSelect5,
        "cmd-6": .pageSelect6,
        "cmd-7": .pageSelect7,
        "cmd-8": .pageSelect8,
        "cmd-9": .pageSelect9,
        // No cmd-0: the ledger's chord is withdrawn from the default
        // file while its entry points are hidden (issue #78). The
        // command id is still legal and still dispatches, which is what
        // `testTheLedgerCommandStaysBindableByAnOverride` holds.
        "cmd-n": .pageNew,
        "cmd-alt-left": .pagePrevious,
        "cmd-alt-right": .pageNext,
        "cmd-w": .pageClose,
        "cmd-shift-v": .clipboardSeal,
        "cmd-enter": .clipboardSealSelection,
        "alt-z": .editorToggleWrap,
        "cmd-s": .stateSaveNow,
        "cmd-,": .appSettings,
        "escape": .surfaceHandBackKeys,
    ]

    private func bundled() throws -> ResolvedKeymap {
        let text = try XCTUnwrap(
            Keymap.bundledDefaultText(),
            "the bundled default keymap was not found in this build")
        return Keymap.resolve(defaultText: text, overrideText: nil)
    }

    func testTheBundledDefaultIsInThisBuild() throws {
        XCTAssertNotNil(Keymap.bundledDefaultText())
    }

    func testTheBundledDefaultValidatesWithoutComplaint() throws {
        XCTAssertEqual(try bundled().diagnostics, [])
    }

    func testTheBundledDefaultBindsExactlyTheseChords() throws {
        let resolved = try bundled()
        let actual = Dictionary(
            uniqueKeysWithValues: resolved.bindings.map { ($0.keystroke.canonical, $0.command) })
        XCTAssertEqual(actual, Self.expected)
    }

    /// Everything ships on the one surface the app consults today, so
    /// nothing in the default file is inert.
    func testEveryDefaultBindingIsOnTheEditorSurface() throws {
        XCTAssertTrue(try bundled().bindings.allSatisfy { $0.context == .editor })
    }

    /// The nine jump chords are one behaviour, and a gap in the run
    /// would be a typo nobody notices until they press it.
    func testTheNineJumpChordsAreAllThere() throws {
        let resolved = try bundled()
        for number in 1...9 {
            let keystroke = try XCTUnwrap(try? parse("cmd-\(number)"))
            XCTAssertEqual(
                resolved.command(for: keystroke, in: .editor)?.selectsPageNumber, number)
        }
    }

    /// The two seal gestures are the page's, not the surface's: they
    /// act on the caret and the selection, which the text view owns.
    func testTheSealGesturesAreDispatchedByThePage() throws {
        let resolved = try bundled()
        let editorRoute = resolved.bindings(in: .editor, dispatch: .editor).map(\.command)
        XCTAssertEqual(
            Set(editorRoute), [.clipboardSeal, .clipboardSealSelection, .editorToggleWrap])
    }

    /// Everything else is carried by the surface's hidden buttons, and
    /// every one of them has to be installable.
    func testEverySurfaceChordCanBeInstalled() throws {
        let resolved = try bundled()
        XCTAssertEqual(
            resolved.surfaceShortcuts().count,
            resolved.bindings(in: .editor, dispatch: .surface).count)
    }

    /// The ledger is hidden, not withdrawn from the vocabulary (issue
    /// #78): the default file no longer spends a chord on it, and a
    /// user who wants it back gets it back from their own keymap
    /// without a new build. This is the assertion that hiding the entry
    /// points did not quietly delete the command.
    func testTheLedgerCommandStaysBindableByAnOverride() throws {
        let text = try XCTUnwrap(Keymap.bundledDefaultText())
        let resolved = Keymap.resolve(
            defaultText: text,
            overrideText: #"[{ "context": "Editor", "bindings": { "cmd-0": "ledger::Show" } }]"#)
        XCTAssertEqual(resolved.diagnostics, [])
        XCTAssertEqual(resolved.command(for: try parse("cmd-0"), in: .editor), .ledgerShow)
    }

    /// Settings is the one command a menu advertises, and it can only
    /// do so because the section opted into key equivalents.
    func testSettingsOffersItsChordToTheMenu() throws {
        XCTAssertEqual(try bundled().menuKeystroke(for: .appSettings)?.canonical, "cmd-,")
    }

    // MARK: The file has to reach the shipped bundle

    /// SwiftPM never builds the .app, so `Bundle.module` under the test
    /// runner proves nothing about the copy a user launches. The
    /// packaging script is what puts the file where `Bundle.main` will
    /// find it, and a bundle without it has no shortcuts at all, so the
    /// copy is pinned here the way the identity sheet's keys are
    /// (`BundleDeclarationTests`).
    func testThePackagingScriptCarriesTheDefaultIntoTheBundle() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8)
        XCTAssertTrue(
            script.contains(
                "cp shell/Sources/CompanionKit/Resources/"
                    + "\(Keymap.defaultResourceName).\(Keymap.defaultResourceExtension)"),
            "scripts/package-app.sh no longer copies the bundled keymap into the app")
    }

    private func parse(_ text: String) throws -> Keystroke {
        switch Keystroke.parse(text) {
        case .success(let keystroke): return keystroke
        case .failure(let failure): throw failure
        }
    }
}
