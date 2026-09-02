import XCTest

@testable import CompanionKit

/// The sign-in ceremony as the surface actually walks it, over a live
/// core rather than over hand-fed state (issue #102, ADR-0027 §5).
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
    private func configured() throws -> (SyncController, CompanionClient, Box) {
        let suiteName = "companion-sync-ceremony-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("https://relay.example", forKey: "sync.relayURL")
        defaults.set("https://account.example/oauth/authorize", forKey: "sync.authorizeURL")
        defaults.set("https://account.example/oauth/token", forKey: "sync.tokenURL")
        let client = CompanionClient.ephemeral(tag: "sync-ceremony-\(UUID().uuidString)")
        let sync = SyncController(client: client, defaults: defaults)
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
            "waiting on your browser to finish signing in; Settings can give up on it",
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
