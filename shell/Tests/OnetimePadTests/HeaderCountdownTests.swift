import XCTest

@testable import OnetimePad

/// Where the header's countdown shows, tested as the pure decision it
/// is, in the shell's pattern for UI-adjacent logic. The header used to
/// print the selected page's countdown in every mode; the day mode's
/// gutter prints the same number on the page itself, so the header
/// yields it there and keeps it only while the strip is the navigation
/// (docs/dogfood/ABERRATIONS.md, 2026-09-05). These tests pin that the
/// yield is exactly that wide and no wider: the strip mode must not
/// lose the one place its remaining time is written as a number.
final class HeaderCountdownTests: XCTestCase {
    func testTheStripModeKeepsTheHeaderCountdown() {
        XCTAssertTrue(
            BackdropRootView.showsHeaderCountdown(
                showsTimeUnits: false, hasPage: true, showingLedger: false, fileShowing: false))
    }

    func testTheDayModeYieldsTheHeaderCountdownToTheGutter() {
        XCTAssertFalse(
            BackdropRootView.showsHeaderCountdown(
                showsTimeUnits: true, hasPage: true, showingLedger: false, fileShowing: false))
    }

    func testNothingCountingDownMeansNoCountdownInEitherMode() {
        for showsTimeUnits in [false, true] {
            // An empty slot has a rung and no clock (ADR-0017).
            XCTAssertFalse(
                BackdropRootView.showsHeaderCountdown(
                    showsTimeUnits: showsTimeUnits, hasPage: false, showingLedger: false,
                    fileShowing: false))
            // The ledger is not a page.
            XCTAssertFalse(
                BackdropRootView.showsHeaderCountdown(
                    showsTimeUnits: showsTimeUnits, hasPage: true, showingLedger: true,
                    fileShowing: false))
            // A file never expires (ADR-0028).
            XCTAssertFalse(
                BackdropRootView.showsHeaderCountdown(
                    showsTimeUnits: showsTimeUnits, hasPage: true, showingLedger: false,
                    fileShowing: true))
        }
    }
}
