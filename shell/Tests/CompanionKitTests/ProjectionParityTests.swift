import XCTest

@testable import CompanionKit

/// The debug parity check's judgement, which a test run turns into a failure
/// that ends the run with its line rather than a trap that hangs xctest.
final class ProjectionParityTests: XCTestCase {
    private let chip = ChipInfo(
        chipId: 7, kind: "text", excerpt: "", sizeLabel: "tiny", concealed: false)

    func testTheSamePageIsNoBreach() {
        XCTAssertNil(PageModel.parityBreach(
            editor: [.ink("ab "), .chip(7), .ink(" cd")],
            core: [.ink("ab "), .chip(chip), .ink(" cd")]))
        XCTAssertNil(PageModel.parityBreach(editor: [], core: []))
    }

    /// Each way the two can part: other ink, another object, a run more or less.
    func testEveryDifferenceIsABreach() {
        let core: [RestoredRun] = [.ink("ab "), .chip(chip), .ink(" cd")]
        for editor: [DocumentRun] in [
            [.ink("ab "), .chip(7), .ink(" cx")],
            [.ink("ab "), .chip(8), .ink(" cd")],
            [.ink("ab "), .chip(7)],
            [.ink("ab "), .chip(7), .ink(" cd"), .chip(7)],
            [.ink("ab "), .ink(" cd"), .chip(7)],
        ] {
            XCTAssertNotNil(PageModel.parityBreach(editor: editor, core: core), "\(editor)")
        }
    }

    /// The line goes to a log or a crash report, so it names kinds and lengths alone.
    func testTheBreachLineCarriesNoInk() throws {
        let line = try XCTUnwrap(PageModel.parityBreach(
            editor: [.ink("hunter2 "), .chip(7)],
            core: [.ink("hunter3 "), .chip(chip)]))
        XCTAssertFalse(line.contains("hunter"))
        XCTAssertTrue(line.contains("editor ink(8) chip(7), core ink(8) chip(7)"), line)
    }
}
