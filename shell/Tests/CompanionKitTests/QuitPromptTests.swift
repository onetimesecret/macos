import AppKit
import XCTest

@testable import CompanionKit

@MainActor
private final class FlushSpy: QuitFlushable {
    private let outcome: QuitSaveOutcome
    private(set) var flushes = 0
    private(set) var offered: QuitSaveOutcome?

    init(_ outcome: QuitSaveOutcome, offered: QuitSaveOutcome? = nil) {
        self.outcome = outcome
        self.offered = offered
    }

    func saveStateForQuit() -> QuitSaveOutcome {
        flushes += 1
        return outcome
    }

    func quitAnywayAnswers(_ outcome: QuitSaveOutcome) -> Bool { offered == outcome }

    func offerQuitAnyway(after outcome: QuitSaveOutcome) {
        offered = outcome
    }
}

/// The nonmodal terminate policy: one synchronous flush per request, then
/// a deterministic reply with no presentation callback or user-file save
/// path. A refused or unsavable flush cancels the first request and puts
/// the quit anyway line up; the second request terminates, so ⌘Q is never
/// inert.
@MainActor
final class QuitPromptTests: XCTestCase {
    func testASettledFlushTerminatesAfterExactlyOneFlush() {
        let model = FlushSpy(.settled)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow)
        XCTAssertEqual(model.flushes, 1)
    }

    func testDirtyDraftsDoNotChangeASettledReply() throws {
        let suiteName = "companion-quit-draft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-quit-\(UUID().uuidString).txt")
        try Data("disk\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        model.openFile(at: url)
        let id = try XCTUnwrap(model.activeFile?.id)
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "draft ")]))
        model.applyOps(sheet: id, opsJSON: ops)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: url), as: UTF8.self), "disk\n",
            "quit flushes shell state but does not implicitly save the user file"
        )
    }

    func testARefusedFlushCancelsTheFirstQuitAndOffersQuitAnyway() {
        let model = FlushSpy(.refused)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel)
        XCTAssertEqual(model.flushes, 1)
        XCTAssertEqual(model.offered, .refused, "the surface learns why the quit was cancelled")
    }

    func testAnUnsavableFlushCancelsTheFirstQuitAndOffersQuitAnyway() {
        let model = FlushSpy(.unsavableWithContent)

        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel)
        XCTAssertEqual(model.flushes, 1)
        XCTAssertEqual(model.offered, .unsavableWithContent)
    }

    func testTheSecondQuitTerminatesWhileTheOfferStands() {
        for outcome in [QuitSaveOutcome.refused, .unsavableWithContent, .unsavableWithDrafts] {
            let model = FlushSpy(outcome)
            XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel, "\(outcome)")
            XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow, "\(outcome)")
            XCTAssertEqual(model.flushes, 2, "the second request is still a chance for the write to land")
        }
    }

    func testASettledFlushNeverOffersAndTerminatesOverAStandingOffer() {
        let fresh = FlushSpy(.settled)
        XCTAssertEqual(QuitPrompt.terminateReply(flushing: fresh), .terminateNow)
        XCTAssertNil(fresh.offered)

        let recovered = FlushSpy(.settled, offered: .refused)
        XCTAssertEqual(QuitPrompt.terminateReply(flushing: recovered), .terminateNow)
    }

    func testEveryOutcomeFlushesExactlyOncePerRequest() {
        for outcome in [
            QuitSaveOutcome.settled, .refused, .unsavableWithContent, .unsavableWithDrafts,
        ] {
            let model = FlushSpy(outcome)
            _ = QuitPrompt.terminateReply(flushing: model)
            XCTAssertEqual(model.flushes, 1, "\(outcome)")
        }
    }

    // MARK: The standing line's policy, as pure functions

    func testTheSentenceNamesTheLossForEachCancelledOutcome() {
        XCTAssertNil(PageModel.quitRefusalSentence(.settled))
        XCTAssertEqual(
            PageModel.quitRefusalSentence(.refused),
            "the sealed state file was not written, so this session's pages will not survive the quit")
        XCTAssertEqual(
            PageModel.quitRefusalSentence(.unsavableWithContent),
            "nothing typed this session is on disk, so its pages will not survive the quit")
        // The drafts arm names the files alone: the pages are on disk.
        let dirty = FileSummary(
            id: CompanionClient.fileIDTag | 1, name: "a.txt", path: "/tmp/a.txt",
            isDirty: true, conflict: .none, lineEnding: .lf, hasBOM: false,
            lastEditedAt: 0, restoredFromDraft: false)
        XCTAssertEqual(
            PageModel.quitRefusalSentence(.unsavableWithDrafts, files: [dirty], draftsUnwritten: true),
            "the drafts file would not open and was not written over, so the unsaved changes to a.txt will not survive the quit")
        // A file saved since the cancel retires the drafts line: nothing is held.
        XCTAssertNil(PageModel.quitOfferAfterFiles(offer: .unsavableWithDrafts, draftsHeld: false))
        XCTAssertEqual(
            PageModel.quitOfferAfterFiles(offer: .unsavableWithDrafts, draftsHeld: true),
            .unsavableWithDrafts)
        XCTAssertEqual(
            PageModel.quitOfferAfterFiles(offer: .unsavableWithContent, draftsHeld: false),
            .unsavableWithContent, "the content arm's condition is not the files'")
        XCTAssertEqual(
            PageModel.quitRefusalSentence(.unsavableWithDrafts),
            "the drafts file would not open and was not written over, so unsaved changes to open files will not survive the quit",
            "the sentence is never empty")
        XCTAssertNil(PageModel.quitOfferAfterDraftsClear(offer: .unsavableWithDrafts))
        XCTAssertEqual(PageModel.quitOfferAfterDraftsClear(offer: .refused), .refused)
    }

    func testTheQuitAnywayHelpNamesTheLossItsLineNames() {
        let dirty = FileSummary(
            id: CompanionClient.fileIDTag | 1, name: "a.txt", path: "/tmp/a.txt",
            isDirty: true, conflict: .none, lineEnding: .lf, hasBOM: false,
            lastEditedAt: 0, restoredFromDraft: false)
        XCTAssertEqual(
            PageModel.quitAnywayHelp(.unsavableWithDrafts, files: [dirty], draftsUnwritten: true),
            "Quits now. Unsaved changes to a.txt are lost.")
        XCTAssertEqual(
            PageModel.quitAnywayHelp(.unsavableWithDrafts, files: [], draftsUnwritten: true),
            "Quits now.")
        XCTAssertEqual(
            PageModel.quitAnywayHelp(.refused, files: [], draftsUnwritten: false),
            "Quits now. This session's pages are lost.")
        // The drafts are on disk, so the line names the pages alone, and so does its button.
        XCTAssertEqual(
            PageModel.quitAnywayHelp(.unsavableWithContent, files: [dirty], draftsUnwritten: false),
            "Quits now. This session's pages are lost.")
        XCTAssertEqual(
            PageModel.quitAnywayHelp(.unsavableWithContent, files: [dirty], draftsUnwritten: true),
            "Quits now. This session's pages and the unsaved changes to a.txt are lost.")
    }

    func testAChangedOutcomeRestatesTheLineAndTheNextRequestQuits() {
        // A refusal supersedes a drafts line: the line names it before any quit does.
        let model = FlushSpy(.refused, offered: .unsavableWithDrafts)
        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateCancel)
        XCTAssertEqual(model.offered, .refused)
        XCTAssertEqual(QuitPrompt.terminateReply(flushing: model), .terminateNow)
    }

    func testARefusalsOfferComesDownOnASettledWriteOnly() {
        XCTAssertNil(PageModel.quitOfferAfterWrite(offer: .refused, settled: true))
        XCTAssertEqual(PageModel.quitOfferAfterWrite(offer: .refused, settled: false), .refused)
        // The withheld leg settles without writing the pages, so a
        // settle says nothing about an unsavable session's offer.
        XCTAssertEqual(
            PageModel.quitOfferAfterWrite(offer: .unsavableWithContent, settled: true),
            .unsavableWithContent)
        XCTAssertNil(PageModel.quitOfferAfterWrite(offer: nil, settled: true))
    }

    func testAnUnsavableOfferComesDownOnTheDiscardOnly() {
        XCTAssertNil(PageModel.quitOfferAfterContentClear(offer: .unsavableWithContent))
        XCTAssertEqual(PageModel.quitOfferAfterContentClear(offer: .refused), .refused)
        XCTAssertNil(PageModel.quitOfferAfterContentClear(offer: nil))
    }

    func testTheModelRecordsOnlyCancelledOutcomes() throws {
        let suiteName = "companion-quit-offer-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)

        model.offerQuitAnyway(after: .settled)
        XCTAssertNil(model.quitRefusal)
        XCTAssertFalse(model.quitAnywayAnswers(.settled))

        model.offerQuitAnyway(after: .unsavableWithContent)
        XCTAssertEqual(model.quitRefusal, .unsavableWithContent)
        XCTAssertTrue(model.quitAnywayAnswers(.unsavableWithContent))
        XCTAssertFalse(model.quitAnywayAnswers(.refused), "a changed outcome is not answered")
    }
}
