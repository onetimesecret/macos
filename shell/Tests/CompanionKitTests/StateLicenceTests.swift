import XCTest

@testable import CompanionKit

/// The quit-save licence's truth table (App.swift). The core folds
/// "no file yet" and "refused" into one false from
/// `companion_persist_restore`; the file's presence on disk is what
/// tells a fresh start from a restore failure — and only the failure
/// may cost the session its licence to write the sealed file at quit.
final class StateLicenceTests: XCTestCase {
    func testFreshStartEarnsTheLicence() {
        // No file on disk: nothing exists to protect, and the session
        // owns its future.
        XCTAssertTrue(PageModel.grantsSaveLicence(fileExists: false, restored: false))
    }

    func testRestoredSessionKeepsTheLicence() {
        XCTAssertTrue(PageModel.grantsSaveLicence(fileExists: true, restored: true))
    }

    func testRefusedRestoreWithholdsTheLicence() {
        // The file exists but would not open — Keychain key denied or
        // missing, damaged snapshot. Quit must not overwrite it with
        // this session's consolation page.
        XCTAssertFalse(PageModel.grantsSaveLicence(fileExists: true, restored: false))
    }
}

/// The sudden-termination hold (ADR-0012): while the store differs from
/// the sealed file, the process must not be killable outright at logout
/// or shutdown. The balance matters in both directions: a hold that is
/// never given back leaves the machine waiting on us forever, and one
/// given back early loses the pages it was taken to protect.
final class SuddenTerminationLatchTests: XCTestCase {
    /// The injected effects, counted. A class so the latch's escaping
    /// closures and the assertions share one instance.
    private final class EffectLog {
        var disables = 0
        var enables = 0
    }

    private func makeLatch(_ log: EffectLog) -> SuddenTerminationLatch {
        SuddenTerminationLatch(
            disable: { log.disables += 1 },
            enable: { log.enables += 1 }
        )
    }

    func testRepeatedMarksDisableOnce() {
        // A burst of edits is one hold, not one per keystroke.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        latch.acquire()
        latch.acquire()
        XCTAssertEqual(latch.depth, 3)
        XCTAssertEqual(log.disables, 1)
        XCTAssertEqual(log.enables, 0)
    }

    func testOneWriteDischargesEveryHold() {
        // The write flushes the whole buffer, so it answers every mark
        // that asked for the hold; a decrement would strand the rest.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        latch.acquire()
        latch.settle(saved: true)
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 1)
    }

    func testDepthNeverGoesNegative() {
        // Releasing what was never taken is a no-op, not an unbalanced
        // enable that would give away someone else's hold.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.release()
        latch.release()
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 0)

        latch.acquire()
        latch.release()
        latch.release()
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 1)
    }

    func testFailedSaveLeavesTheLatchHeld() {
        // The file was not rewritten: the buffer is still the only copy
        // of those pages, so shutdown keeps waiting on us.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        latch.settle(saved: false)
        XCTAssertEqual(latch.depth, 1)
        XCTAssertEqual(log.enables, 0)

        // And the next write that does settle still gives it back.
        latch.settle(saved: true)
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 1)
    }

    func testANewHoldAfterAWriteDisablesAgain() {
        // The hold is per dirty window, not once per process.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        latch.settle(saved: true)
        latch.acquire()
        XCTAssertEqual(latch.depth, 1)
        XCTAssertEqual(log.disables, 2)
    }
}
