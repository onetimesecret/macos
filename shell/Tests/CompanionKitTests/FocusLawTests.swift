import XCTest

@testable import CompanionKit

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

    // MARK: Scroll clamping (issue #24) — a saved offset meets today's geometry

    func testAnOffsetWithinTheDocumentComesBackUntouched() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clampedScrollOffset(
                NSPoint(x: 0, y: 120), documentHeight: 500, clipHeight: 200
            ),
            NSPoint(x: 0, y: 120)
        )
    }

    func testAnOffsetBeyondShrunkenContentIsClampedToTheBottom() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clampedScrollOffset(
                NSPoint(x: 0, y: 400), documentHeight: 300, clipHeight: 200
            ),
            NSPoint(x: 0, y: 100)
        )
    }

    func testANegativeOffsetSeatsAtTheTop() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clampedScrollOffset(
                NSPoint(x: 0, y: -50), documentHeight: 500, clipHeight: 200
            ),
            NSPoint(x: 0, y: 0)
        )
    }

    func testAZeroOffsetStaysAtZero() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clampedScrollOffset(
                .zero, documentHeight: 500, clipHeight: 200
            ),
            .zero
        )
    }

    func testADocumentShorterThanTheClipCannotScrollAtAll() {
        XCTAssertEqual(
            InkEditorView.Coordinator.clampedScrollOffset(
                NSPoint(x: 0, y: 80), documentHeight: 150, clipHeight: 200
            ),
            NSPoint(x: 0, y: 0)
        )
    }

    // MARK: The Return grant (ADR-0005): keyed emptiness offers create

    func testAKeyedWindowKeepsTheKeysWhenTheLastPageDies() {
        // The old policy handed the keyboard back at this moment; the
        // new one keeps it, seats the empty state's catcher as first
        // responder, and lets Return conjure the next page.
        XCTAssertTrue(PageModel.shouldOfferEnterCreate(sheetsEmpty: true, holdsKeys: true))
    }

    func testAnUnkeyedEmptyWindowOffersNoReturnGrant() {
        // Unkeyed emptiness never receives a keystroke; the click or
        // summon stays the price of entry, by design.
        XCTAssertFalse(PageModel.shouldOfferEnterCreate(sheetsEmpty: true, holdsKeys: false))
    }

    func testLivePagesLeaveTheKeyboardToTheEditor() {
        XCTAssertFalse(PageModel.shouldOfferEnterCreate(sheetsEmpty: false, holdsKeys: true))
        XCTAssertFalse(PageModel.shouldOfferEnterCreate(sheetsEmpty: false, holdsKeys: false))
    }

    // MARK: Clearing the promotion draft on close (issue #19)

    func testClosingThePromotedPageClearsTheDraft() {
        XCTAssertTrue(PageModel.shouldClearPromotion(
            target: .page(7), closingSheet: 7, chipsOnSheet: []
        ))
    }

    func testClosingAnotherPageKeepsThePageDraft() {
        XCTAssertFalse(PageModel.shouldClearPromotion(
            target: .page(7), closingSheet: 8, chipsOnSheet: []
        ))
    }

    func testClosingThePageCarryingThePromotedChipClearsTheDraft() {
        XCTAssertTrue(PageModel.shouldClearPromotion(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [41, 42]
        ))
    }

    func testClosingAPageWithoutThePromotedChipKeepsTheDraft() {
        XCTAssertFalse(PageModel.shouldClearPromotion(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [7]
        ))
    }

    // MARK: Clearing the promotion draft on refresh/expiry (issue #19)

    func testExpiringThePromotedPageClearsTheDraft() {
        XCTAssertTrue(PageModel.isRefreshOrphan(
            target: .page(7), liveSheets: [3, 8], liveChips: []
        ))
    }

    func testASurvivingPromotedPageKeepsTheDraft() {
        XCTAssertFalse(PageModel.isRefreshOrphan(
            target: .page(7), liveSheets: [7, 8], liveChips: [42]
        ))
    }

    func testAChipOnALivePageKeepsTheDraft() {
        XCTAssertFalse(PageModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [3, 8], liveChips: [41, 42]
        ))
    }

    func testAChipWhosePageExpiredClearsTheDraftEvenWhileOthersRemain() {
        // The P1 regression: the promoted chip's own page expired, but
        // other pages stayed open. The old `sheets.isEmpty` test left
        // the draft standing so a stray ↩ could fire a network call over
        // a chip whose bytes are gone; the live-chip test clears it.
        XCTAssertTrue(PageModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [3, 8], liveChips: [41]
        ))
    }

    func testAChipDraftClearsWhenEveryPageIsGone() {
        XCTAssertTrue(PageModel.isRefreshOrphan(
            target: .chip(42), liveSheets: [], liveChips: []
        ))
    }

    // MARK: Selection reconciliation after a reload (issue #22 family)

    func testASurvivingSelectionStaysPutAcrossAReload() {
        // The page the user was on is still live; a reload of the world
        // around it must not move the selection.
        XCTAssertEqual(
            PageModel.reconciledSelection(current: 7, live: [3, 7, 8]),
            7
        )
    }

    func testAVanishedSelectionFallsToTheFirstLivePage() {
        // The selected page expired (or was closed, or reordered out).
        // The selection lands on the first live page in tab order: 30
        // here, though not the smallest id, which also proves the
        // fallback follows tab order and not id order.
        XCTAssertEqual(
            PageModel.reconciledSelection(current: 7, live: [30, 10, 20]),
            30
        )
    }

    func testANilSelectionSeatsTheFirstLivePage() {
        // Nothing was selected (a fresh reveal, say); the first live
        // page in tab order takes it.
        XCTAssertEqual(
            PageModel.reconciledSelection(current: nil, live: [30, 10, 20]),
            30
        )
    }

    func testAVanishedSelectionOverAnEmptyModelSelectsNothing() {
        // Every page is gone: the keyed-empty state, selecting nothing.
        XCTAssertNil(PageModel.reconciledSelection(current: 7, live: []))
    }

    func testANilSelectionOverAnEmptyModelStaysNil() {
        // Nothing was selected and nothing is live; still nothing.
        XCTAssertNil(PageModel.reconciledSelection(current: nil, live: []))
    }

    // MARK: Page-step clamp, ⌥⌘←/→ (issue #22 family)

    func testAStepOffTheLastPageStaysOnTheLast() {
        // ⌥⌘→ from the last of five pages holds at the last, never
        // wrapping or running past the end.
        XCTAssertEqual(PageModel.steppedIndex(from: 4, by: 1, within: 5), 4)
    }

    func testAStepOffTheFirstPageStaysOnTheFirst() {
        // ⌥⌘← from the first page holds at the first.
        XCTAssertEqual(PageModel.steppedIndex(from: 0, by: -1, within: 5), 0)
    }

    func testAPlainStepMovesByTheDelta() {
        // A step with room to move lands one tab over, either way.
        XCTAssertEqual(PageModel.steppedIndex(from: 2, by: 1, within: 5), 3)
        XCTAssertEqual(PageModel.steppedIndex(from: 2, by: -1, within: 5), 1)
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
