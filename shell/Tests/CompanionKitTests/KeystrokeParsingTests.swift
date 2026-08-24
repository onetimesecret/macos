import XCTest

@testable import CompanionKit

/// The parser, which is where a keymap either becomes a set of chords
/// or becomes a complaint (issue #76).
///
/// Everything asserted here is pure. No window, no event, no model:
/// a keystroke is text going in and a value coming out, and holding
/// that still is what lets the layers above assume their input is
/// already sane.
final class KeystrokeParsingTests: XCTestCase {
    private func parsed(_ text: String) throws -> Keystroke {
        switch Keystroke.parse(text) {
        case .success(let keystroke): return keystroke
        case .failure(let failure):
            XCTFail("\(text) should have parsed, and failed with \(failure)")
            throw failure
        }
    }

    private func failure(_ text: String) throws -> Keystroke.ParseFailure {
        switch Keystroke.parse(text) {
        case .success(let keystroke):
            XCTFail("\(text) should have been refused, and parsed as \(keystroke.canonical)")
            throw Keystroke.ParseFailure.empty
        case .failure(let failure): return failure
        }
    }

    func testAModifiedLetterParses() throws {
        let keystroke = try parsed("cmd-shift-v")
        XCTAssertEqual(keystroke.modifiers, [.command, .shift])
        XCTAssertEqual(keystroke.key, .character("v"))
    }

    func testAnUnmodifiedNamedKeyParses() throws {
        XCTAssertEqual(try parsed("escape").key, .named(.escape))
        XCTAssertEqual(try parsed("escape").modifiers, [])
    }

    func testEveryNamedKeyIsSpelledTheWayTheFileSpellsIt() throws {
        for named in NamedKey.allCases {
            XCTAssertEqual(try parsed(named.rawValue).key, .named(named))
        }
    }

    /// Shift is a modifier, never a capital letter, so the two ways of
    /// writing the same chord cannot become two bindings.
    func testCaseIsFoldedAway() throws {
        XCTAssertEqual(try parsed("CMD-Shift-V"), try parsed("cmd-shift-v"))
    }

    /// The order the modifiers are written in is the author's business
    /// and not the app's.
    func testModifierOrderDoesNotMatter() throws {
        XCTAssertEqual(try parsed("alt-cmd-n"), try parsed("cmd-alt-n"))
        XCTAssertEqual(try parsed("alt-cmd-n").canonical, "cmd-alt-n")
    }

    func testTheLongSpellingsOfEachModifierAreAccepted() throws {
        XCTAssertEqual(try parsed("command-option-x"), try parsed("cmd-alt-x"))
        XCTAssertEqual(try parsed("control-opt-x"), try parsed("ctrl-alt-x"))
    }

    /// The one spelling that looks like a separator and is not.
    func testTheHyphenKeyCanBeBound() throws {
        let keystroke = try parsed("cmd--")
        XCTAssertEqual(keystroke.modifiers, [.command])
        XCTAssertEqual(keystroke.key, .character("-"))
        XCTAssertEqual(keystroke.canonical, "cmd--")
    }

    /// The bare hyphen, with nothing in front of it, is still a chord a
    /// file may name.
    func testTheHyphenKeyCanBeBoundOnItsOwn() throws {
        XCTAssertEqual(try parsed("-").key, .character("-"))
        XCTAssertEqual(try parsed("-").modifiers, [])
    }

    /// A spelling that names a modifier and then stops is a typo, and
    /// the one reading that must never be given to it is the hyphen
    /// key: that would drop the modifier the author did write and leave
    /// a command sitting under a character people type into pages.
    func testAModifierWithNoKeyIsRefusedRatherThanReadAsAHyphen() throws {
        XCTAssertEqual(try failure("cmd-"), .unknownKey(""))
        XCTAssertEqual(try failure("shift-"), .unknownKey(""))
        XCTAssertEqual(try failure("cmd-alt-"), .unknownKey(""))
    }

    func testACommaIsAnOrdinaryKey() throws {
        XCTAssertEqual(try parsed("cmd-,").key, .character(","))
    }

    func testAnEmptySpellingIsRefused() throws {
        XCTAssertEqual(try failure("   "), .empty)
    }

    func testAWordThatIsNotAModifierIsRefused() throws {
        XCTAssertEqual(try failure("hyper-v"), .unknownModifier("hyper"))
    }

    /// `fn` is a real key on the board and not a modifier this build can
    /// honour; refusing it out loud beats accepting a chord that could
    /// never fire.
    func testTheFunctionModifierIsRefusedRatherThanIgnored() throws {
        XCTAssertEqual(try failure("fn-v"), .unknownModifier("fn"))
    }

    func testARepeatedModifierIsRefused() throws {
        XCTAssertEqual(try failure("cmd-cmd-v"), .repeatedModifier("cmd"))
    }

    func testAMultiCharacterKeyThatIsNotNamedIsRefused() throws {
        XCTAssertEqual(try failure("cmd-nope"), .unknownKey("nope"))
    }

    /// Function keys have no `KeyEquivalent`, so binding one would
    /// validate and then never install. Refused at the parser instead.
    func testFunctionKeysAreRefused() throws {
        XCTAssertEqual(try failure("f5"), .unknownKey("f5"))
    }

    // MARK: Recognising a real keystroke

    /// A shifted letter arrives as a capital, and the chord that bound
    /// it wrote a lower-case letter and a shift.
    func testAShiftedLetterIsRecognisedByItsUnshiftedCharacter() throws {
        let keystroke = try parsed("cmd-shift-v")
        XCTAssertTrue(
            keystroke.matches(
                charactersIgnoringModifiers: "V", virtualKeyCode: 9,
                modifiers: [.command, .shift]))
    }

    func testTheSameLetterWithoutShiftIsNotThatChord() throws {
        let keystroke = try parsed("cmd-shift-v")
        XCTAssertFalse(
            keystroke.matches(
                charactersIgnoringModifiers: "v", virtualKeyCode: 9, modifiers: [.command]))
    }

    /// Named keys are matched by their place on the board, because the
    /// character Return reports is not something a layout guarantees.
    func testANamedKeyIsRecognisedByItsPosition() throws {
        let keystroke = try parsed("cmd-enter")
        XCTAssertTrue(
            keystroke.matches(
                charactersIgnoringModifiers: "\r", virtualKeyCode: 36, modifiers: [.command]))
        XCTAssertFalse(
            keystroke.matches(
                charactersIgnoringModifiers: "\r", virtualKeyCode: 76, modifiers: [.command]))
    }

    func testAnUnmodifiedChordDoesNotMatchAModifiedPress() throws {
        let keystroke = try parsed("escape")
        XCTAssertTrue(
            keystroke.matches(
                charactersIgnoringModifiers: nil, virtualKeyCode: 0x35, modifiers: []))
        XCTAssertFalse(
            keystroke.matches(
                charactersIgnoringModifiers: nil, virtualKeyCode: 0x35, modifiers: [.command]))
    }

    // MARK: Handing the chord to the frameworks

    /// Bare Escape goes up as the cancel action, which is the shortcut
    /// this surface has always installed for it.
    func testBareEscapeInstallsAsTheCancelAction() throws {
        XCTAssertEqual(try parsed("escape").keyboardShortcut, .cancelAction)
    }

    func testEveryBindableChordCanBeInstalled() throws {
        for named in NamedKey.allCases {
            XCTAssertNotNil(
                try parsed("cmd-\(named.rawValue)").keyboardShortcut,
                "cmd-\(named.rawValue) parsed but could not be installed")
        }
        XCTAssertNotNil(try parsed("cmd-alt-left").keyboardShortcut)
    }

    // MARK: Saying the chord out loud

    /// The symbols go up in Apple's order, which is not the order the
    /// file was written in.
    func testTheDisplaySymbolReadsTheWayAMenuReads() throws {
        XCTAssertEqual(try parsed("cmd-n").displaySymbol, "⌘N")
        XCTAssertEqual(try parsed("cmd-shift-v").displaySymbol, "⇧⌘V")
        XCTAssertEqual(try parsed("cmd-alt-left").displaySymbol, "⌥⌘←")
        XCTAssertEqual(try parsed("ctrl-alt-shift-cmd-a").displaySymbol, "⌃⌥⇧⌘A")
    }

    func testEveryNamedKeyHasSomethingToShow() throws {
        for named in NamedKey.allCases {
            XCTAssertFalse(
                try parsed(named.rawValue).displaySymbol.isEmpty,
                "\(named.rawValue) would render as nothing at all")
        }
        XCTAssertEqual(try parsed("escape").displaySymbol, "⎋")
    }

    func testAMenuEquivalentCarriesTheCharacterAndTheMask() throws {
        let keystroke = try parsed("cmd-,")
        XCTAssertEqual(keystroke.menuKeyEquivalent, ",")
        XCTAssertEqual(keystroke.menuModifierMask, .command)
    }
}
