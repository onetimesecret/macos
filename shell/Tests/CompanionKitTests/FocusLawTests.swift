import AppKit
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

    func testAKeyedWindowKeepsTheKeysWhenTheSelectedPageDies() {
        // The old policy handed the keyboard back at this moment; the
        // new one keeps it, seats the empty state's catcher as first
        // responder, and lets Return conjure the next page. Under
        // ADR-0017 the moment arrives more often: the selected tab's
        // page can expire while the strip stands full.
        XCTAssertTrue(
            PageModel.shouldOfferEnterCreate(selectedTabHoldsNoPage: true, holdsKeys: true))
    }

    func testAnUnkeyedEmptyWindowOffersNoReturnGrant() {
        // Unkeyed emptiness never receives a keystroke; the click or
        // summon stays the price of entry, by design.
        XCTAssertFalse(
            PageModel.shouldOfferEnterCreate(selectedTabHoldsNoPage: true, holdsKeys: false))
    }

    /// The predicate follows the selection and not the strip
    /// (ADR-0017 item 11): what decides the create surface is whether
    /// the tab the user is looking at holds a page, so a strip with
    /// eight live pages and an empty selected slot still offers it, and
    /// a selected slot holding a page never does.
    func testTheGrantFollowsTheSelectedTabAndNotTheStrip() {
        XCTAssertFalse(
            PageModel.shouldOfferEnterCreate(selectedTabHoldsNoPage: false, holdsKeys: true))
        XCTAssertFalse(
            PageModel.shouldOfferEnterCreate(selectedTabHoldsNoPage: false, holdsKeys: false))
    }

    // MARK: Clearing the conceal draft on close (issue #19)

    func testClosingTheConcealedPageClearsTheDraft() {
        XCTAssertTrue(PageModel.shouldClearConcealDraft(
            target: .page(7), closingSheet: 7, chipsOnSheet: []
        ))
    }

    func testClosingAnotherPageKeepsThePageDraft() {
        XCTAssertFalse(PageModel.shouldClearConcealDraft(
            target: .page(7), closingSheet: 8, chipsOnSheet: []
        ))
    }

    func testClosingThePageCarryingTheConcealedChipClearsTheDraft() {
        XCTAssertTrue(PageModel.shouldClearConcealDraft(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [41, 42]
        ))
    }

    func testClosingAPageWithoutTheConcealedChipKeepsTheDraft() {
        XCTAssertFalse(PageModel.shouldClearConcealDraft(
            target: .chip(42), closingSheet: 3, chipsOnSheet: [7]
        ))
    }

    // MARK: Clearing the conceal draft on refresh/expiry (issue #19)

    func testExpiringTheConcealedPageClearsTheDraft() {
        XCTAssertTrue(PageModel.isRefreshOrphan(
            target: .page(7), liveSheets: [3, 8], liveChips: []
        ))
    }

    func testASurvivingConcealedPageKeepsTheDraft() {
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
        // The P1 regression: the concealed chip's own page expired, but
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

    // MARK: One focusable text view in the card (issue #79)

    /// The roll shows several days at once, and every one of them is a
    /// text view. The law is that only one of them can ever hold the
    /// keyboard: the editor. A quiet day refuses first responder, the
    /// window refuses to hand it over, and the model's single handle —
    /// the one every grant and every summon focuses through — names the
    /// editor and nothing else.
    ///
    /// Real AppKit, because what is under test is a view's relationship
    /// to a window, which is not a thing worth modelling twice.
    @MainActor
    func testTheQuietRegionsNeverTakeFirstResponder() throws {
        let suiteName = "companion-focus-law-roll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        // Two pages, which a live core can only make on one day: the
        // roll draws them as one day's two regions, joined by a hairline,
        // and one of the two is the editor.
        model.newPage()
        let mounted = try XCTUnwrap(model.selectedPageID)
        model.newPage()
        let quietPage = try XCTUnwrap(model.selectedPageID)

        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "⌃⌥Space to raise the card"
        )
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        stack.update(
            projection: TimeUnitProjection.project(
                tabs: model.tabs, selectedPageID: mounted, unit: .day
            ),
            selectedPage: mounted,
            readOnly: false
        )

        let editor = try XCTUnwrap(stack.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(model.activeEditor === editor)

        let quiet = try XCTUnwrap(stack.quietRegions[quietPage])
        XCTAssertFalse(quiet.acceptsFirstResponder, "a rendering offered to take the keyboard")
        // The window is asked all the same, and its answer is about
        // itself rather than about this view: AppKit documents
        // `makeFirstResponder` as returning true even when the responder
        // refuses, the window taking the status in its place. So the
        // refusal is read off the window afterwards.
        _ = window.makeFirstResponder(quiet)
        XCTAssertFalse(
            window.firstResponder === quiet,
            "a rendering is holding the keyboard the editor was given"
        )
        XCTAssertFalse(
            model.activeEditor === quiet,
            "the model's one handle names a view that cannot type"
        )
        XCTAssertTrue(
            model.activeEditor === editor,
            "a grant or a summon would hand the keyboard to a day nobody can write on"
        )
    }
}
