import XCTest

@testable import CompanionKit

/// The display names walk the detector's registry, so a Betlang
/// upgrade that adds or renames a slug fails here until someone names it.
final class CodeLanguageNameTests: XCTestCase {
    func testEveryRegistrySlugHasAnExplicitName() {
        for slug in CodeInk.detectorLanguageRenderers.keys.sorted() {
            XCTAssertNotNil(
                CodeLanguageName.names[slug],
                "\(slug) has no display name; name it in CodeLanguageName"
            )
        }
    }

    func testEveryNamedSlugIsInTheRegistry() {
        for slug in CodeLanguageName.names.keys.sorted() {
            XCTAssertNotNil(
                CodeInk.detectorLanguageRenderers[slug],
                "\(slug) is named but the detector never emits it"
            )
        }
    }

    func testNamesReadAsTheirCommunitiesWriteThem() {
        XCTAssertEqual(CodeLanguageName.display("javascript"), "JavaScript")
        XCTAssertEqual(CodeLanguageName.display("cs"), "C#")
        XCTAssertEqual(CodeLanguageName.display("objectivec"), "Objective-C")
        XCTAssertEqual(CodeLanguageName.display("yaml"), "YAML")
        XCTAssertEqual(CodeLanguageName.display("Swift"), "Swift")
    }

    func testAFencesOwnSpellingReachesTheRegistryThroughTheAliases() {
        for (alias, slug) in CodeInk.aliases.merging(CodeLanguageName.fenceSpellings, uniquingKeysWith: { a, _ in a }) {
            XCTAssertEqual(
                CodeLanguageName.display(alias), CodeLanguageName.display(slug),
                "\(alias) names what \(slug) names"
            )
            XCTAssertNotNil(CodeLanguageName.names[slug], "\(alias) points at a named slug")
        }
        XCTAssertEqual(CodeLanguageName.display("yml"), "YAML")
        XCTAssertEqual(CodeLanguageName.display("objc"), "Objective-C")
        XCTAssertEqual(CodeLanguageName.display("objective-c"), "Objective-C")
        XCTAssertEqual(CodeLanguageName.display("csharp"), "C#")
    }

    /// The fence words a person types, which must never fall back to
    /// the capitalised guess.
    func testCommonFenceWordsResolve() {
        let expected = [
            "js": "JavaScript", "ts": "TypeScript", "py": "Python", "rb": "Ruby",
            "rs": "Rust", "sh": "Shell", "bash": "Shell", "zsh": "Shell", "yml": "YAML",
            "objc": "Objective-C", "csharp": "C#", "golang": "Go", "psql": "SQL",
        ]
        for (word, name) in expected {
            XCTAssertEqual(CodeLanguageName.display(word), name, word)
        }
    }

    func testAnUnknownIdFallsBackToCapitalised() {
        XCTAssertEqual(CodeLanguageName.display("kotlinscript"), "Kotlinscript")
    }
}
