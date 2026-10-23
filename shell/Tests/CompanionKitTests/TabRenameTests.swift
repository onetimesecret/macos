import XCTest

@testable import CompanionKit

/// The rename's decisions (D-14, issue #172), apart from the fields that ask
/// them, and `TabRename.Field`, the state the strip's SwiftUI field runs on.
final class TabRenameTests: XCTestCase {
    func testReturnOverANewNameRenames() {
        XCTAssertEqual(
            TabRename.outcome(draft: "payroll", current: "notes", committed: true),
            .rename("payroll"))
    }

    func testEscapeAndFocusLossKeepWhateverTheDraftSays() {
        XCTAssertEqual(
            TabRename.outcome(draft: "payroll", current: "notes", committed: false), .keep)
        XCTAssertEqual(TabRename.outcome(draft: "", current: "notes", committed: false), .keep)
    }

    func testReturnOverAnUntouchedDraftKeeps() {
        // The title the field opened on may be the page's own first
        // line; freezing it into an override would be a change the
        // user never made.
        XCTAssertEqual(TabRename.outcome(draft: "notes", current: "notes", committed: true), .keep)
    }

    func testAnEmptyNameIsARenameNotACancel() {
        // Empty drops the override and lets the title derive again.
        XCTAssertEqual(
            TabRename.outcome(draft: "", current: "notes", committed: true), .rename(""))
    }

    func testTheNameIsTrimmedBeforeItIsJudged() {
        XCTAssertEqual(TabRename.name(from: "  payroll \n"), "payroll")
        XCTAssertEqual(
            TabRename.outcome(draft: "   ", current: "notes", committed: true), .rename(""),
            "a name of only spaces is the empty name")
        XCTAssertEqual(
            TabRename.outcome(draft: " notes ", current: "notes", committed: true), .keep,
            "and spaces around the current title change nothing")
    }

    // MARK: The strip's field (issue #250)

    func testTheFieldOpensOnTheCurrentTitle() {
        var field = TabRename.Field()
        XCTAssertFalse(field.isOpen)
        field.open(on: "deploy notes")
        XCTAssertTrue(field.isOpen)
        XCTAssertEqual(field.draft, "deploy notes")
        XCTAssertEqual(field.opened, "deploy notes")

        field.draft = "payr"
        field.open(on: "a later title")
        XCTAssertEqual(field.draft, "payr", "a second opening wrote over the draft")
        XCTAssertEqual(field.opened, "deploy notes")
    }

    func testTheFieldsReturnKeepsAnUntouchedDraftAndRenamesAChangedOne() {
        var field = TabRename.Field()
        field.open(on: "deploy notes")
        XCTAssertEqual(field.end(committed: true), .keep)
        XCTAssertFalse(field.isOpen)

        field.open(on: "deploy notes")
        field.draft = "Payroll"
        XCTAssertEqual(field.end(committed: true), .rename("Payroll"))
    }

    func testTheFieldKeepsTheTitleOnEscapeAndEndsOnce() {
        var field = TabRename.Field()
        field.open(on: "deploy notes")
        field.draft = "Payroll"
        XCTAssertEqual(field.end(committed: false), .keep)
        XCTAssertNil(
            field.end(committed: false),
            "the focus loss that follows the field going away ended it a second time")

        field.open(on: "deploy notes")
        field.draft = "Payroll"
        XCTAssertEqual(field.end(committed: true), .rename("Payroll"))
        XCTAssertNil(field.end(committed: false), "a focus loss after Return undid nothing, and said so")
    }
}
