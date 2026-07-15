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

    // MARK: The Return grant (ADR-0005): keyed emptiness offers create

    func testAKeyedWindowKeepsTheKeysWhenTheLastPageDies() {
        // The old policy handed the keyboard back at this moment; the
        // new one keeps it, seats the empty state's catcher as first
        // responder, and lets Return conjure the next page.
        XCTAssertTrue(WindowModel.shouldOfferEnterCreate(sheetsEmpty: true, holdsKeys: true))
    }

    func testAnUnkeyedEmptyWindowOffersNoReturnGrant() {
        // Unkeyed emptiness never receives a keystroke; the click or
        // summon stays the price of entry, by design.
        XCTAssertFalse(WindowModel.shouldOfferEnterCreate(sheetsEmpty: true, holdsKeys: false))
    }

    func testLivePagesLeaveTheKeyboardToTheEditor() {
        XCTAssertFalse(WindowModel.shouldOfferEnterCreate(sheetsEmpty: false, holdsKeys: true))
        XCTAssertFalse(WindowModel.shouldOfferEnterCreate(sheetsEmpty: false, holdsKeys: false))
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

    // MARK: Clearing the promotion draft on refresh/expiry (issue #19)

    func testExpiringThePromotedPageClearsTheDraft() {
        XCTAssertTrue(WindowModel.isRefreshOrphan(
            target: .page(7), liveSheets: [3, 8], liveChips: []
        ))
    }

    func testASurvivingPromotedPageKeepsTheDraft() {
        XCTAssertFalse(WindowModel.isRefreshOrphan(
            target: .page(7), liveSheets: [7, 8], liveChips: [42]
        ))
    }

    func testAChipOnALivePageKeepsTheDraft() {
        XCTAssertFalse(WindowModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [3, 8], liveChips: [41, 42]
        ))
    }

    func testAChipWhosePageExpiredClearsTheDraftEvenWhileOthersRemain() {
        // The P1 regression: the promoted chip's own page expired, but
        // other pages stayed open. The old `sheets.isEmpty` test left
        // the draft standing so a stray ↩ could fire a network call over
        // a chip whose bytes are gone; the live-chip test clears it.
        XCTAssertTrue(WindowModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [3, 8], liveChips: [41]
        ))
    }

    func testAChipDraftClearsWhenEveryPageIsGone() {
        XCTAssertTrue(WindowModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [], liveChips: []
        ))
    }
}
