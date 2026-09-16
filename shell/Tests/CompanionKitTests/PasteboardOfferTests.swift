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

/// The clear-after-copy (D-29, D-32): a copy-out arms a one-shot clear
/// and says so with the core's own number. The model here owns
/// everything it touches (a temporary directory, an in-process
/// credential store, the core's in-memory board), and its clear window
/// is shortened through the seam so the timer fires inside a test's
/// patience; the line it flashes still names the core's constant.
@MainActor
final class ClipboardClearTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-clipboard-clear-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-clipboard-clear-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: "clipboard-clear-\(UUID().uuidString)"),
                clipboardClearDebounce: 0.05
            )
        )
    }

    private func sealAChip(on model: PageModel) throws -> UInt64 {
        model.newPage()
        let chip = try XCTUnwrap(
            model.sealText("a copied secret", replacing: NSRange(location: 0, length: 0)))
        return chip.chipId
    }

    func testACopyOutArmsTheClearAndFlashesTheInterval() throws {
        let model = try makeModel()
        let chip = try sealAChip(on: model)
        model.copyOutChip(chip)

        // The line names the core's number, not the shortened window,
        // in the stream navigator design's words.
        XCTAssertEqual(CompanionClient.clipboardClearSeconds(), 60)
        XCTAssertEqual(
            model.notice, "copied decrypted contents. the clipboard clears in 60 seconds.")
        XCTAssertEqual(model.notice, PageModel.copiedLine(clearsIn: 60))
        XCTAssertEqual(
            PageModel.copiedLine(clearsIn: 60, size: "small"),
            "copied decrypted contents — small. the clipboard clears in 60 seconds.")

        // The timer fires, the board is given back, and the guarded
        // clear afterwards has nothing left to answer for.
        let fired = expectation(description: "the clear window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        XCTAssertFalse(
            model.coreClient.clearClipboardIfOurs(),
            "the armed clear should already have taken the board back")
    }

    func testTheBoardStillHoldsTheCopyInsideTheWindow() throws {
        let model = try makeModel()
        let chip = try sealAChip(on: model)
        model.copyOutChip(chip)
        // Inside the window the write stands, so a clear now is ours to
        // make; this is the control the test above rests on.
        XCTAssertTrue(model.coreClient.clearClipboardIfOurs())
    }
}
