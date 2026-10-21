import XCTest

@testable import CompanionKit

/// The sign-in ceremony as the surface actually walks it, over a live
/// core rather than over hand-fed state (issue #102, account-auth
/// decision background §5).
///
/// `SyncSurfaceTests` holds the sentences as pure functions, which is
/// what makes them cheap to state; the risk that leaves is a rule that
/// is right in isolation and never reached, because the code that
/// drives it sets the state some other way. These tests close that by
/// driving the controller itself: the switch goes on, a ceremony
/// begins, and what the header says is compared with what the page
/// says at the same moment.
///
/// The browser is the one thing not driven. `openAuthorizeUrl` is the
/// seam for it, so a test walks the whole ceremony without a consent
/// screen opening on whoever is running the suite. Every controller
/// here is built over an ephemeral client and a per test defaults
/// suite (ADR-0018), so no installed copy's switch, state directory or
/// Keychain service is read or written.
@MainActor
final class SyncCeremonyTests: XCTestCase {
    /// A controller over a configured core, signed out, with the
    /// browser replaced by a recorder.
    private func configured(
        pairingPoll: (@Sendable () async -> SyncPairingStage?)? = nil
    ) throws -> (SyncController, CompanionClient, Box) {
        let suiteName = "companion-sync-ceremony-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("https://relay.example", forKey: "sync.relayURL")
        defaults.set("https://account.example/oauth/authorize", forKey: "sync.authorizeURL")
        defaults.set("https://account.example/oauth/token", forKey: "sync.tokenURL")
        let client = CompanionClient.ephemeral(tag: "sync-ceremony-\(UUID().uuidString)")
        let sync = SyncController(client: client, defaults: defaults, pairingPoll: pairingPoll)
        sync.serverUrlProvider = { "https://account.example" }
        let opened = Box()
        sync.openAuthorizeUrl = { url in opened.url = url }
        return (sync, client, opened)
    }

    /// Where the authorize URL lands instead of a browser.
    private final class Box {
        var url: URL?
    }

    func testTheHeaderAndThePageAgreeThroughABrowserTrip() throws {
        let (sync, client, opened) = try configured()
        sync.enabled = true
        // Signed out is where a browser trip starts, and the two lines
        // agree there already.
        XCTAssertEqual(sync.headerWord?.text, "sync signed out")
        XCTAssertEqual(sync.standingSentence, "sync is signed out; the pad is unaffected")

        sync.signIn()
        XCTAssertNotNil(opened.url, "the ceremony opened the authorize URL")
        XCTAssertEqual(client.syncGate(), .signingIn)

        // The whole of the browser trip is spent here, and for all of
        // it the header and the page have to be describing the same
        // app. The sentence saying the trip is out is the one the
        // surface draws the way out beside.
        XCTAssertEqual(sync.headerWord?.text, "signing in")
        XCTAssertEqual(
            sync.standingSentence,
            "waiting on the browser to finish signing in; Settings can give up on it",
            "the page may not say signed out while the header says signing in"
        )
        XCTAssertFalse(
            sync.standingSentenceIsTrouble,
            "a consent screen that is open is not a condition to act on"
        )

        // End the trip rather than leaving a five minute wait behind
        // this test.
        sync.giveUpSignin()
    }

    func testTurningSyncOffEndsABrowserTripInFlight() throws {
        let (sync, client, _) = try configured()
        sync.enabled = true
        sync.signIn()
        XCTAssertEqual(client.syncGate(), .signingIn)

        // Off means the app you already had. A ceremony left running
        // behind the switch would come back with a grant, and the core
        // persists that grant to the Keychain before it answers, so a
        // shell that only declines to attach has already been signed
        // in by the time it declines.
        sync.enabled = false

        XCTAssertNotEqual(
            client.syncGate(), .signingIn,
            "the switch going off ends the trip rather than leaving it out"
        )
        XCTAssertFalse(
            client.syncSigninCancel(),
            "there is nothing left to give up on, because turning off gave up"
        )
        XCTAssertNil(sync.headerWord, "and off says nothing at all")
    }

    /// One long-poll turn's worth of nothing, so a settling can be
    /// driven without a relay.
    private func quietTurn(events: [SyncPumpEvent] = []) -> SyncPumpOutcome {
        SyncPumpOutcome(ok: true, reason: nil, events: events, state: nil)
    }

    func testFallingBehindSurvivesAnUnreachableBlip() throws {
        let (sync, _, _) = try configured()
        sync.enabled = true

        // The channel rotated past this pad. Nothing here rejoins, so
        // this is true until something does.
        sync.settlePump(
            quietTurn(events: [SyncPumpEvent(kind: "rejoin_required", page: nil, pageID: nil)]),
            session: sync.session)
        XCTAssertEqual(sync.headerWord?.text, "sync behind")

        // The relay blinks. Being unreachable is a fact about the
        // network and being behind is a fact about this pad's keys, so
        // the blip may not stand in for the rotation.
        sync.settlePump(nil, session: sync.session)
        // And the blip passes.
        sync.settlePump(quietTurn(), session: sync.session)

        XCTAssertEqual(
            sync.headerWord?.text, "sync behind",
            "a pad that is still short a key may not be called synced"
        )
        XCTAssertEqual(
            sync.standingSentence,
            "sync fell behind a key rotation; edits stay local until this pad rejoins"
        )
    }

    /// A poll that suspends until released, counting its calls. It
    /// parks on a continuation, not a semaphore, so two held rounds
    /// occupy no cooperative threads.
    private final class HeldPoll: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// A latch, so a round counted but not yet parked when the
        /// release comes resumes at once rather than parking for good.
        private var released = false

        var calls: Int { lock.withLock { count } }

        /// The first call answers as a mismatch, every later one as done,
        /// so a stale answer written into a later ceremony is visible.
        func poll() async -> SyncPairingStage? {
            let n = lock.withLock { count += 1; return count }
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return n == 1
                ? SyncPairingStage(stage: "failed", sas: nil, reason: "stale")
                : SyncPairingStage(stage: "done", sas: nil, reason: nil)
        }

        func release() {
            let held = lock.withLock {
                released = true
                let held = waiters
                waiters = []
                return held
            }
            for continuation in held { continuation.resume() }
        }
    }

    private func spin(until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    func testOnePollInFlightAndACancelledCeremonysAnswerIsDropped() throws {
        let held = HeldPoll()
        let (sync, _, _) = try configured(pairingPoll: { await held.poll() })
        let waiting = SyncPairingStage(stage: "waiting", sas: nil, reason: nil)
        sync.pairingStage = waiting

        // Two ticks while the relay is slow: one round on the wire.
        sync.pollPairing()
        sync.pollPairing()
        spin { held.calls == 1 }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(held.calls, 1, "a slow relay gets one round, not one per tick")

        // The person cancels and starts over before the round returns.
        // The wire is still busy, so the new ceremony's tick waits.
        sync.cancelPairing()
        XCTAssertNil(sync.pairingStage)
        sync.pairingStage = waiting
        sync.pollPairing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(held.calls, 1, "one round on the wire, whichever ceremony opened it")

        // The old round comes back: its mismatch is dropped and the
        // wire is free, so the next tick's round goes out and is taken.
        held.release()
        spin { held.calls == 1 && sync.pairingStage?.stage == "waiting" && !sync.pairingPolling }
        XCTAssertEqual(sync.pairingStage?.stage, "waiting", "the cancelled ceremony's verdict never reached this one")
        sync.pollPairing()
        spin { sync.pairingStage?.stage == "done" }
        XCTAssertEqual(held.calls, 2)
        XCTAssertEqual(sync.pairingStage?.stage, "done")
        XCTAssertNil(sync.pairingStage?.reason)
    }

    func testSigningOutUnderALongPollFreesTheWireWhenTheRoundReturns() throws {
        let (sync, _, _) = try configured()
        sync.enabled = true
        // A long poll is out when the person signs out. Its answer
        // belongs to the old session and is dropped, but the wire is
        // its until it returns: the core's pump has no guard, so a
        // flag freed early would let two rounds share one handle.
        sync.pumping = true
        // A ceremony is up as well.
        sync.pairingStage = SyncPairingStage(stage: "waiting", sas: nil, reason: nil)
        // And an earlier trip's failure still stands on the surface.
        sync.settleSignin(.refused("refused"), session: sync.session)
        XCTAssertNotNil(sync.signinFailure)
        let stale = sync.session
        sync.signOut()
        XCTAssertNotEqual(sync.session, stale, "a sign-out is a new session")
        XCTAssertTrue(sync.pumping, "the round still out keeps the wire")
        XCTAssertNil(sync.signinFailure, "signed out is the whole state")
        sync.settlePump(quietTurn(), session: stale)
        XCTAssertFalse(sync.pumping, "the returning round frees the wire, its answer dropped")
        sync.settleSignin(.refused("abandoned"), session: stale)
        XCTAssertNil(sync.signinFailure, "a sign-out is not a browser that never returned")
        XCTAssertNil(sync.pairingStage, "a pairing ceremony ends with the engine")
    }

    func testATurnFromAStoppedSessionIsNotTheReplacementsTurn() throws {
        let (sync, _, _) = try configured()
        sync.enabled = true
        // A long poll is out, holding the socket open for its
        // twenty-five seconds, when the switch goes off and straight
        // back on.
        let stale = sync.session
        sync.enabled = false
        sync.enabled = true
        XCTAssertNotEqual(sync.session, stale, "off and on again is a new session")

        // The old turn comes back now, carrying a page somebody was
        // writing on and a rotation this pad fell behind, both of them
        // about a channel nobody is attached to any more.
        sync.settlePump(
            quietTurn(events: [
                SyncPumpEvent(kind: "applied", page: "peer-page", pageID: 7),
                SyncPumpEvent(kind: "rejoin_required", page: nil, pageID: nil),
            ]),
            session: stale)

        XCTAssertTrue(
            sync.editedElsewhere.isEmpty,
            "a mark from a session nobody is in may not land on this one's pages"
        )
        XCTAssertNotEqual(
            sync.headerWord?.text, "sync behind",
            "nor may its rotation become the replacement session's trouble"
        )
    }
}
