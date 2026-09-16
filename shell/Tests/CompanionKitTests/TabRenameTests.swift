import XCTest

@testable import CompanionKit

/// The rename's decisions (D-14, issue #172), pinned apart from the two
/// fields that ask them. The strip's field is SwiftUI and cannot be
/// driven under the runner; the gutter's can, and `ModalSessionTests`
/// drives it. What both fields agree on is here.
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
}
