import XCTest

@testable import CompanionApp

/// The focus-law decisions of issue #19, extracted pure — the shell's
/// pattern for UI-adjacent logic: test the decision itself, never mock
/// AppKit. The window plumbing these feed (key grants, storage swaps,
/// the ember) is hand-tested per the project's rules.
final class FocusLawTests: XCTestCase {
    // MARK: Caret clamping (ADR-0006) — a saved caret meets today's content

    func testARangeInsideTheStorageComesBackUntouched() {
        let range = NSRange(location: 3, length: 4)
        XCTAssertEqual(InkEditorView.Coordinator.clamped(range, to: 10), range)
    }

    func testACaretPastTheEndLandsAtTheEnd() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clamped(NSRange(location: 25, length: 0), to: 10),
            NSRange(location: 10, length: 0)
        )
    }

    func testASelectionOverhangingTheEndIsTruncated() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clamped(NSRange(location: 8, length: 5), to: 10),
            NSRange(location: 8, length: 2)
        )
    }

    func testAnEmptiedStorageSeatsTheCaretAtZero() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clamped(NSRange(location: 7, length: 3), to: 0),
            NSRange(location: 0, length: 0)
        )
    }

    func testNSNotFoundCannotEscapeTheClamp() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clamped(NSRange(location: NSNotFound, length: 0), to: 10),
            NSRange(location: 10, length: 0)
        )
    }

    // MARK: Handing back the keys (issue #19) — the ember never lies

    func testKeysGoBackWhenTheLastPageDiesWhileKey() {
        XCTAssertTrue(WindowModel.shouldHandBackKeys(sheetsEmpty: true, holdsKeys: true))
    }

    func testAnUnkeyedWindowHasNoKeysToHandBack() {
        XCTAssertFalse(WindowModel.shouldHandBackKeys(sheetsEmpty: true, holdsKeys: false))
    }

    func testLivePagesKeepTheKeys() {
        XCTAssertFalse(WindowModel.shouldHandBackKeys(sheetsEmpty: false, holdsKeys: true))
        XCTAssertFalse(WindowModel.shouldHandBackKeys(sheetsEmpty: false, holdsKeys: false))
    }

    // MARK: Clearing the promotion draft on close (issue #19)

    func testClosingThePromotedPageClearsTheDraft() {
        XCTAssertTrue(WindowModel.shouldClearPromotion(
            target: .page(7), closingSheet: 7, chipsOnSheet: []
        ))
    }

    func testClosingAnotherPageKeepsThePageDraft() {
        XCTAssertFalse(WindowModel.shouldClearPromotion(
            target: .page(7), closingSheet: 8, chipsOnSheet: []
        ))
    }

    func testClosingThePageCarryingThePromotedChipClearsTheDraft() {
        XCTAssertTrue(WindowModel.shouldClearPromotion(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [41, 42]
        ))
    }

    func testClosingAPageWithoutThePromotedChipKeepsTheDraft() {
        XCTAssertFalse(WindowModel.shouldClearPromotion(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [7]
        ))
    }
}
