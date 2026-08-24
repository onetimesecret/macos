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
        "cmd-0": .ledgerShow,
        "cmd-alt-n": .pageNew,
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

    /// Settings is the one command a menu advertises, and it can only
    /// do so because the section opted into key equivalents.
    func testSettingsOffersItsChordToTheMenu() throws {
        XCTAssertEqual(try bundled().menuKeystroke(for: .appSettings)?.canonical, "cmd-,")
    }

    /// And an override that takes ⌘, away leaves nothing for the menu
    /// to advertise, which is what both Settings items read
    /// (`BackdropAppDelegate.settingsKeystroke`). A nil there is the
    /// unbinding working, so neither item may fall back to the chord
    /// the file just removed.
    func testUnbindingSettingsLeavesTheMenuNothingToAdvertise() throws {
        let text = try XCTUnwrap(Keymap.bundledDefaultText())
        let keymap = Keymap.resolve(
            defaultText: text,
            overrideText: """
                [{ "context": "Editor", "bindings": { "cmd-,": null } }]
                """)
        XCTAssertEqual(keymap.faults, [])
        XCTAssertNil(keymap.menuKeystroke(for: .appSettings))
        XCTAssertFalse(keymap.bindings.contains { $0.command == .appSettings })
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

    /// Under the test runner `Bundle.main` is xctest, which carries no
    /// keymap, so the file is only found at all because the hand-rolled
    /// search below it works. That makes this suite the proof that the
    /// second rung is real rather than decorative.
    func testTheFileIsFoundWithoutBundleMain() throws {
        XCTAssertNil(
            Bundle.main.url(
                forResource: Keymap.defaultResourceName,
                withExtension: Keymap.defaultResourceExtension),
            "the test runner unexpectedly carries a keymap, so this suite proves nothing")
        XCTAssertNotNil(Keymap.defaultURL)
    }

    /// `Bundle.module` must never come back here. SwiftPM's generated
    /// accessor calls `fatalError` when it cannot find its bundle, and
    /// the case where it cannot find it is exactly the packaging fault
    /// `defaultKeymapMissing` exists to survive: an app assembled
    /// without `Contents/Resources/default-keymap.json`. Using the
    /// accessor would turn that diagnostic into a crash inside
    /// `PageModel`'s initialiser. `LogoMark` refuses it for the same
    /// reason and says so in its own comment.
    func testTheLoaderNeverReachesForBundleModule() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CompanionKit/Keymap/Keymap.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for line in text.split(separator: "\n") where line.contains("Bundle.module") {
            XCTAssertTrue(
                line.trimmingCharacters(in: .whitespaces).hasPrefix("///"),
                "Keymap.swift calls Bundle.module, which fatalErrors on a miss: \(line)")
        }
    }

    private func parse(_ text: String) throws -> Keystroke {
        switch Keystroke.parse(text) {
        case .success(let keystroke): return keystroke
        case .failure(let failure): throw failure
        }
    }
}
