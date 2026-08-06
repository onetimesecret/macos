import XCTest

@testable import CompanionKit

/// The save licence's truth table. The core folds "no file yet" and
/// "refused" into one false from `companion_persist_restore`; the file's
/// presence on disk is what tells a fresh start from a restore failure,
/// and only the failure may cost the session its licence to write the
/// sealed file at all, debounced write and quit flush alike.
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
        // missing, damaged snapshot. No write in this session may
        // overwrite it with this session's consolation page.
        XCTAssertFalse(PageModel.grantsSaveLicence(fileExists: true, restored: false))
    }
}

/// The debounce's two rules (ADR-0012), without a run loop: the loss
/// window is anchored to the first mutation of a burst, and a deferred
/// write that a later write overtook stands down instead of running
/// twice.
final class SaveScheduleTests: XCTestCase {
    func testFirstMarkArmsTheWindow() {
        var schedule = SaveSchedule()
        XCTAssertNotNil(schedule.arm())
        XCTAssertTrue(schedule.pending)
    }

    func testABurstKeepsTheWindowItsFirstMarkOpened() {
        // The failure this exists to prevent: one mark per typed
        // character, each pushing the write out by another interval, so
        // a long secret typed steadily is never written at all. Only the
        // first mark arms; the rest ride it.
        var schedule = SaveSchedule()
        let first = schedule.arm()
        XCTAssertNotNil(first)
        for _ in 0..<400 {
            XCTAssertNil(schedule.arm())
        }
        XCTAssertTrue(schedule.isCurrent(first!))
    }

    func testAWriteStandsDownADeferredBodyThatAlreadyFired() {
        // Invalidate cannot recall a fired timer, and its body hops to
        // the main actor before writing. A quit-time write landing in
        // that gap must leave the queued body with nothing to do, or
        // quit writes a second identical generation to disk.
        var schedule = SaveSchedule()
        let armed = schedule.arm()!
        schedule.begin() // the quit-time write
        XCTAssertFalse(schedule.isCurrent(armed))
    }

    func testAWriteReopensTheDoorForTheNextBurst() {
        // The window is per dirty span, not once per process: after a
        // write, the next mutation arms a fresh one.
        var schedule = SaveSchedule()
        _ = schedule.arm()
        schedule.begin()
        XCTAssertFalse(schedule.pending)
        let next = schedule.arm()
        XCTAssertNotNil(next)
        XCTAssertTrue(schedule.isCurrent(next!))
    }

    func testARetryArmedAfterAFailedWriteIsItsOwnGeneration() {
        // The refused write closed its window; the retry it arms is a
        // new one, and the body of the write that failed can never come
        // back and run as if it were the retry.
        var schedule = SaveSchedule()
        let original = schedule.arm()!
        schedule.begin()
        let retry = schedule.arm()!
        XCTAssertNotEqual(original, retry)
        XCTAssertFalse(schedule.isCurrent(original))
        XCTAssertTrue(schedule.isCurrent(retry))
    }
}

/// The sudden-termination hold (ADR-0012): while the store differs from
/// the sealed file, the process must not be killable outright at logout
/// or shutdown. The balance matters in both directions: a hold that is
/// never given back leaves the machine waiting on us forever, and one
/// given back early loses the pages it was taken to protect.
///
/// These check the arithmetic only. Neither bundle declares
/// `NSSupportsSuddenTermination` today, so the hold is not what closes
/// the logout window in the shipped apps; see the type's own comment.
/// Adding that key is what makes these tests load-bearing.
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
