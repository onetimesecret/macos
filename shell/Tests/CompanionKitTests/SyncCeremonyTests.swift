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
}
