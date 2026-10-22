import CompanionKit
import XCTest

@testable import OnetimePad

/// The File menu's ⌘W item's truth table (issue #201).
final class CloseMenuItemTests: XCTestCase {
    private func resolve(
        _ target: CloseChordTarget, _ showing: SurfaceTarget, ledger: Bool = false, canClose: Bool
    ) -> CloseMenuItem {
        CloseMenuItem.resolve(
            target: target, showing: showing, ledgerShowing: ledger, keyWindowCanClose: canClose)
    }

    func testOnTheSurfaceItNamesTheFileOrThePage() {
        XCTAssertEqual(resolve(.surface, .file(7), canClose: true), .closeFile)
        XCTAssertEqual(
            resolve(.surface, .tab(3), canClose: false),
            .closePage(enabled: true), "the page's own ⌘W, so the item is enabled")
        XCTAssertEqual(
            resolve(.surface, .today, canClose: true),
            .closePage(enabled: false), "today with no page has nothing to close")
    }

    /// With the ledger up, ⌘W hides the ledger and closes no page, so the
    /// row names the ledger; a file still comes first, as in `perform`.
    func testWithTheLedgerShowingItIsCloseLedger() {
        XCTAssertEqual(resolve(.surface, .tab(3), ledger: true, canClose: true), .closeLedger)
        XCTAssertEqual(resolve(.surface, .today, ledger: true, canClose: true), .closeLedger)
        XCTAssertEqual(resolve(.surface, .file(7), ledger: true, canClose: true), .closeFile)
        XCTAssertEqual(
            resolve(.companionWindow, .tab(3), ledger: true, canClose: true), .closeWindow(enabled: true))
    }

    func testInACompanionWindowItIsCloseWindowEnabledOnlyWhenItCanClose() {
        XCTAssertEqual(resolve(.companionWindow, .file(7), canClose: true), .closeWindow(enabled: true))
        XCTAssertEqual(resolve(.companionWindow, .tab(3), canClose: false), .closeWindow(enabled: false))
    }

    /// A sheet, a save panel or an alert with the keys, or no key window:
    /// dimmed even over a file the surface would close.
    func testWithNothingToCloseItIsDimmed() {
        XCTAssertEqual(resolve(.nothing, .file(7), canClose: true), .closeWindow(enabled: false))
        XCTAssertEqual(resolve(.nothing, .tab(3), ledger: true, canClose: false), .closeWindow(enabled: false))
    }

    func testTheTitlesAndEnablementRead() {
        XCTAssertEqual(CloseMenuItem.closeLedger.title, "Close Ledger")
        XCTAssertTrue(CloseMenuItem.closeLedger.isEnabled)
        XCTAssertEqual(CloseMenuItem.closeFile.title, "Close File")
        XCTAssertEqual(CloseMenuItem.closePage(enabled: true).title, "Close Page")
        XCTAssertEqual(CloseMenuItem.closeWindow(enabled: true).title, "Close Window")
        XCTAssertTrue(CloseMenuItem.closeFile.isEnabled)
        XCTAssertFalse(CloseMenuItem.closePage(enabled: false).isEnabled)
        XCTAssertTrue(CloseMenuItem.closeWindow(enabled: true).isEnabled)
    }
}
