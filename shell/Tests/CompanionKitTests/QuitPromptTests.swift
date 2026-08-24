import AppKit
import XCTest

@testable import CompanionKit

/// A model that answers the flush without owning any pages, so the quit
/// decision can be driven over each outcome in turn. It counts its
/// calls because "the reply came from a flush" is half of what the quit
/// path promises: a terminate that decided without asking the model
/// would be free to answer `.terminateNow` over unwritten work.
@MainActor
private final class FlushSpy: QuitFlushable {
    private let outcome: QuitSaveOutcome
    private(set) var flushes = 0

    init(_ outcome: QuitSaveOutcome) {
        self.outcome = outcome
    }

    func saveStateForQuit() -> QuitSaveOutcome {
        flushes += 1
        return outcome
    }
}

/// The terminate path, as the decision it is: flush, then either quit
/// silently or say what quitting costs. Pins ADR-0016 §1's clean-quit
/// row (the quit flushes, and a refused write reaches the user while
/// the choice is still theirs) and §2's two loud outcomes, without an
/// `NSAlert` on screen. The alert's own appearance stays hand-tested.
@MainActor
final class QuitPromptTests: XCTestCase {
    // MARK: The mapping from outcome to what the user is told

    func testASettledFlushSaysNothing() {
        XCTAssertEqual(QuitPrompt.forOutcome(.settled), .quitSilently)
    }

    func testARefusedWriteTellsTheUserTheFileWasNotWritten() {
        guard case .warn(let warning) = QuitPrompt.forOutcome(.refused) else {
            return XCTFail("a refused write must warn")
        }
        XCTAssertEqual(warning.messageText, "This page could not be saved")
        // The reassurance that makes Quit Anyway a decision rather than
        // a gamble: whatever was on disk before is still there.
        XCTAssertTrue(warning.informativeText.contains("previous file, if any, is untouched"))
    }

    func testAWithheldLicenceOverRealContentPointsAtTheDiscard() {
        guard case .warn(let warning) = QuitPrompt.forOutcome(.unsavableWithContent) else {
            return XCTFail("an unsavable session holding content must warn")
        }
        XCTAssertEqual(warning.messageText, "This session was never being saved")
        // Unlike the refused case there is no write to retry, so the
        // only thing Cancel is good for is the discard on the page
        // (ADR-0016 §7). The text has to say so.
        XCTAssertTrue(warning.informativeText.contains("discard it and start saving"))
    }

    func testTheTwoLoudOutcomesTellDifferentStories() {
        // Both warn, and a mapping that collapsed them would still pass
        // a test that only asked whether an alert appears.
        XCTAssertNotEqual(
            QuitPrompt.forOutcome(.refused),
            QuitPrompt.forOutcome(.unsavableWithContent)
        )
    }

    // MARK: The reply, and the flush it hangs off

    func testASettledFlushQuitsWithoutInterruption() {
        let model = FlushSpy(.settled)
        var presented = 0
        let reply = QuitPrompt.terminateReply(flushing: model) { _ in
            presented += 1
            return true
        }
        XCTAssertEqual(reply, .terminateNow)
        // The ordinary quit: one flush, no alert. An outcome that
        // warned here would put a dialogue in front of every ⌘Q.
        XCTAssertEqual(model.flushes, 1)
        XCTAssertEqual(presented, 0)
    }

    func testTheReplyIsTakenFromTheModelsOwnFlush() {
        // The whole point of intercepting the terminate: the write is
        // attempted before the answer is given, so the answer can be
        // about what actually happened (ADR-0016 §1).
        for outcome in [QuitSaveOutcome.settled, .refused, .unsavableWithContent] {
            let model = FlushSpy(outcome)
            _ = QuitPrompt.terminateReply(flushing: model) { _ in true }
            XCTAssertEqual(model.flushes, 1, "\(outcome) must be flushed exactly once")
        }
    }

    func testARefusedWriteKeepsTheAppRunningWhenTheUserCancels() {
        let model = FlushSpy(.refused)
        var seen: QuitPrompt.Warning?
        var presented = 0
        let reply = QuitPrompt.terminateReply(flushing: model) { warning in
            presented += 1
            seen = warning
            return false
        }
        // Cancel is the retry: staying alive is what gives the pages a
        // second chance at the disk.
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(seen?.messageText, "This page could not be saved")
        // Never a retry loop (ADR-0016 §1, the clean-quit row): the
        // alert offers Quit Anyway or Cancel once, and Cancel is
        // answered by returning to the surface, not by asking again.
        // A decision that re-presented on Cancel would trap the user in
        // the dialogue with no way out but quitting.
        XCTAssertEqual(presented, 1)
    }

    func testARefusedWriteStillQuitsWhenTheUserInsists() {
        // Quit Anyway means the loss is accepted and the app goes.
        let model = FlushSpy(.refused)
        let reply = QuitPrompt.terminateReply(flushing: model) { _ in true }
        XCTAssertEqual(reply, .terminateNow)
    }

    func testAnUnsavableSessionCancelsBackToTheSurface() {
        let model = FlushSpy(.unsavableWithContent)
        var seen: QuitPrompt.Warning?
        var presented = 0
        let reply = QuitPrompt.terminateReply(flushing: model) { warning in
            presented += 1
            seen = warning
            return false
        }
        // Cancelling here buys the user the discard, which is the only
        // way this session's content ever reaches disk. It has to buy it
        // immediately: asking a second time would put the alert between
        // the user and the very page they cancelled to reach
        // (ADR-0016 §1, the clean-quit row).
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(seen?.messageText, "This session was never being saved")
        XCTAssertEqual(presented, 1)
    }

    func testAnUnsavableSessionQuitsWhenTheUserInsists() {
        let model = FlushSpy(.unsavableWithContent)
        let reply = QuitPrompt.terminateReply(flushing: model) { _ in true }
        XCTAssertEqual(reply, .terminateNow)
    }
}
