import AppKit
import XCTest

/// What the spell checker of the machine running the suite answers, for the tests whose
/// control needs an answer; each skips, saying so, where the machine gives none.
@MainActor
enum SpellCheckerOnTheRunner {
    /// Skips unless the spell checker flags the test's own misspelling.
    static func requireSpelling() throws {
        let found = NSSpellChecker.shared.checkSpelling(of: "wrnog", startingAt: 0)
        try XCTSkipUnless(
            found.location != NSNotFound,
            "this machine's spell checker flags no misspelling, so a check has nothing to find")
    }

    /// Skips unless the spell checker replaces the test's own double hyphen with a dash.
    static func requireDashReplacement() throws {
        let results = NSSpellChecker.shared.check(
            "x -- y", range: NSRange(location: 0, length: 6),
            types: NSTextCheckingResult.CheckingType.dash.rawValue, options: nil,
            inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        try XCTSkipUnless(
            results.contains { $0.resultType == .dash },
            "this machine's spell checker replaces no dashes, so Replace Dashes has nothing to do")
    }
}
