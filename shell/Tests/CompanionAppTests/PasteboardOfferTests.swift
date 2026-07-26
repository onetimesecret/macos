import XCTest

@testable import CompanionApp

/// The summon-time offer's truth table (ADR-0007 Amendment 1). The
/// board's state comes from the core's probe at reveal time; the row
/// shows only where a take could land: a page, not the ledger.
final class PasteboardOfferTests: XCTestCase {
    func testContentAndAPageShowTheOffer() {
        XCTAssertTrue(
            WindowModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: true, ledgerShowing: false))
    }

    func testAnEmptyBoardOffersNothing() {
        XCTAssertFalse(
            WindowModel.shouldShowPasteboardOffer(
                boardHolds: false, hasPage: true, ledgerShowing: false))
    }

    func testNoPageMeansNowhereToLand() {
        XCTAssertFalse(
            WindowModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: false, ledgerShowing: false))
    }

    func testTheLedgerIsAReadingSurface() {
        XCTAssertFalse(
            WindowModel.shouldShowPasteboardOffer(
                boardHolds: true, hasPage: true, ledgerShowing: true))
    }
}
