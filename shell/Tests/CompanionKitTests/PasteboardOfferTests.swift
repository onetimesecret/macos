import XCTest

@testable import CompanionKit

/// The summon-time offer's truth table (ADR-0007 Amendment 1). The
/// board's state comes from the core's probe at reveal time; the row
/// shows only where a take could land: a page, not the ledger.
final class PasteboardOfferTests: XCTestCase {
    func testContentAndAPageShowTheOffer() {
        XCTAssertTrue(
            PageModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: true, ledgerShowing: false))
    }

    func testAnEmptyBoardOffersNothing() {
        XCTAssertFalse(
            PageModel.shouldShowPasteboardOffer(
                boardHolds: false, hasPage: true, ledgerShowing: false))
    }

    func testNoPageMeansNowhereToLand() {
        XCTAssertFalse(
            PageModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: false, ledgerShowing: false))
    }

    func testTheLedgerIsAReadingSurface() {
        XCTAssertFalse(
            PageModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: true, ledgerShowing: true))
    }
}
