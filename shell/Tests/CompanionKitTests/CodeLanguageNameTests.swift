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

    func testAnUnknownIdFallsBackToCapitalised() {
        XCTAssertEqual(CodeLanguageName.display("kotlinscript"), "Kotlinscript")
    }
}
