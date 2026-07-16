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

    // MARK: Selection reconciliation after a reload (issue #22 family)

    func testASurvivingSelectionStaysPutAcrossAReload() {
        // The page the user was on is still live; a reload of the world
        // around it must not move the selection.
        XCTAssertEqual(
            WindowModel.reconciledSelection(current: 7, live: [3, 7, 8]),
            7
        )
    }

    func testAVanishedSelectionFallsToTheFirstLivePage() {
        // The selected page expired (or was closed, or reordered out).
        // The selection lands on the first live page in tab order: 30
        // here, though not the smallest id, which also proves the
        // fallback follows tab order and not id order.
        XCTAssertEqual(
            WindowModel.reconciledSelection(current: 7, live: [30, 10, 20]),
            30
        )
    }

    func testANilSelectionSeatsTheFirstLivePage() {
        // Nothing was selected (a fresh reveal, say); the first live
        // page in tab order takes it.
        XCTAssertEqual(
            WindowModel.reconciledSelection(current: nil, live: [30, 10, 20]),
            30
        )
    }

    func testAVanishedSelectionOverAnEmptyModelSelectsNothing() {
        // Every page is gone: the keyed-empty state, selecting nothing.
        XCTAssertNil(WindowModel.reconciledSelection(current: 7, live: []))
    }

    func testANilSelectionOverAnEmptyModelStaysNil() {
        // Nothing was selected and nothing is live; still nothing.
        XCTAssertNil(WindowModel.reconciledSelection(current: nil, live: []))
    }

    // MARK: Page-step clamp, ⌥⌘←/→ (issue #22 family)

    func testAStepOffTheLastPageStaysOnTheLast() {
        // ⌥⌘→ from the last of five pages holds at the last, never
        // wrapping or running past the end.
        XCTAssertEqual(WindowModel.steppedIndex(from: 4, by: 1, within: 5), 4)
    }

    func testAStepOffTheFirstPageStaysOnTheFirst() {
        // ⌥⌘← from the first page holds at the first.
        XCTAssertEqual(WindowModel.steppedIndex(from: 0, by: -1, within: 5), 0)
    }

    func testAPlainStepMovesByTheDelta() {
        // A step with room to move lands one tab over, either way.
        XCTAssertEqual(WindowModel.steppedIndex(from: 2, by: 1, within: 5), 3)
        XCTAssertEqual(WindowModel.steppedIndex(from: 2, by: -1, within: 5), 1)
    }

    // MARK: Pruning per-page view state (ADR-0006), the pure half.
    // The MainActor gate in `pruneViewState` (skip when the live set
    // is unchanged) is coordinator state and stays hand-tested.

    func testADeadPagesEntryIsPruned() {
        let table: [UInt64: Int] = [1: 10, 2: 20, 3: 30]
        XCTAssertEqual(
            InkEditorView.Coordinator.pruned(table, keeping: [1, 3]),
            [1: 10, 3: 30]
        )
    }

    func testLivePagesKeepTheirEntriesUntouched() {
        let table: [UInt64: Int] = [1: 10, 2: 20]
        XCTAssertEqual(
            InkEditorView.Coordinator.pruned(table, keeping: [1, 2]),
            table
        )
    }

    func testAnEmptyLiveSetClearsEveryEntry() {
        let table: [UInt64: Int] = [1: 10, 2: 20]
        XCTAssertTrue(InkEditorView.Coordinator.pruned(table, keeping: []).isEmpty)
    }

    func testLiveKeysWithoutEntriesAskNothingOfTheTable() {
        let table: [UInt64: Int] = [1: 10]
        XCTAssertEqual(
            InkEditorView.Coordinator.pruned(table, keeping: [1, 99]),
            table
        )
    }
}
