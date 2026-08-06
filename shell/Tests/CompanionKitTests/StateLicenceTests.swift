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

    /// What `loadStateIfNeeded` computes at launch, in one call: the two
    /// files are asked the same question independently, and the pair it
    /// returns is what the two writes are then gated on.
    private func licences(
        contentExists: Bool, contentRestored: Bool,
        ledgerExists: Bool, ledgerRestored: Bool
    ) -> (content: Bool, ledger: Bool) {
        (
            PageModel.grantsSaveLicence(fileExists: contentExists, restored: contentRestored),
            PageModel.grantsSaveLicence(fileExists: ledgerExists, restored: ledgerRestored)
        )
    }

    func testARefusedLedgerDoesNotCostTheSessionItsPages() {
        // Two files, two keys, two failure modes. A ledger that will not
        // open says nothing about the state file: the session keeps
        // writing its pages and simply stops extending a trail it can no
        // longer read.
        let granted = licences(
            contentExists: true, contentRestored: true,
            ledgerExists: true, ledgerRestored: false
        )
        XCTAssertTrue(granted.content)
        XCTAssertFalse(granted.ledger)
    }

    func testARefusedStateFileDoesNotCostTheSessionItsTrail() {
        // The other direction, which is the one a single shared licence
        // would get wrong: the pages would not open, the audit trail
        // did, and the trail must not be dropped because something else
        // broke.
        let granted = licences(
            contentExists: true, contentRestored: false,
            ledgerExists: true, ledgerRestored: true
        )
        XCTAssertFalse(granted.content)
        XCTAssertTrue(granted.ledger)
    }

    func testAFirstRunLicensesBothFiles() {
        // Neither file exists yet: nothing on disk to protect, so the
        // session owns both futures. This is the ordinary first launch.
        let granted = licences(
            contentExists: false, contentRestored: false,
            ledgerExists: false, ledgerRestored: false
        )
        XCTAssertTrue(granted.content)
        XCTAssertTrue(granted.ledger)
    }

    func testAMissingLedgerBesideARestoredStateFileIsLicensed() {
        // The first launch after this change, and every launch after the
        // ledger has been cleared: state.sealed opens, ledger.sealed is
        // not there at all. A missing file is a fresh start, not a
        // refusal, so the trail starts recording again immediately.
        let granted = licences(
            contentExists: true, contentRestored: true,
            ledgerExists: false, ledgerRestored: false
        )
        XCTAssertTrue(granted.content)
        XCTAssertTrue(granted.ledger)
    }
}

/// How the two licences meet at the write: `saveState` returns the
/// conjunction of both writes and hands that same value to the latch, so
/// a refused ledger write holds the process open exactly as a refused
/// content write does. The latch is the observable half of that rule, so
/// these drive it directly rather than through a model that would need a
/// core, a Keychain and a real directory.
final class LedgerSaveSettlementTests: XCTestCase {
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

    func testARefusedLedgerWriteKeepsTheHold() {
        // The pages reached disk and the trail did not. The store still
        // differs from what is on disk, so logout must keep waiting: a
        // ledger failure is not a lesser failure, it is the record of
        // what this app did with the user's secrets.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        let contentSaved = true
        let ledgerSaved = false
        latch.settle(saved: contentSaved && ledgerSaved)
        XCTAssertEqual(latch.depth, 1)
        XCTAssertEqual(log.enables, 0)
    }

    func testAWithheldLedgerLicenceStillLetsTheContentWriteSettle() {
        // No licence is not a failure. The ledger file is deliberately
        // left alone, that leg of the write reports true, and the hold
        // turns purely on whether the content write itself succeeded.
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        let ledgerSaved = true // withheld licence: nothing attempted
        latch.settle(saved: true && ledgerSaved)
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 1)

        // And the same withheld licence cannot rescue a content write
        // that was refused.
        latch.acquire()
        latch.settle(saved: false && ledgerSaved)
        XCTAssertEqual(latch.depth, 1)
        XCTAssertEqual(log.enables, 1)
    }

    func testBothWritesLandingIsTheOnlyWayTheHoldComesBack() {
        let log = EffectLog()
        var latch = makeLatch(log)
        latch.acquire()
        latch.settle(saved: false && false)
        latch.settle(saved: false && true)
        latch.settle(saved: true && false)
        XCTAssertEqual(latch.depth, 1)
        latch.settle(saved: true && true)
        XCTAssertEqual(latch.depth, 0)
        XCTAssertEqual(log.enables, 1)
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
