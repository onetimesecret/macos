import XCTest

@testable import CompanionKit

/// Issue #102's first acceptance criterion, held against the code
/// rather than against the intention: sync is off by default, and the
/// app with sync off is the app that shipped before sync existed.
///
/// The proof is two sided. The shell side is that a controller nobody
/// switched on publishes nothing at all, which is what the surface
/// draws from. The core side is the gate: `off` means the core was
/// never configured, so no endpoint was ever resolved and no socket
/// could have been opened. Any sync route that ran would have to leave
/// one of the two changed, since every one of them either configures,
/// signs in, attaches or pumps, and the gate reports all four.
///
/// Constructed straight over an ephemeral client (ADR-0018) rather
/// than through a model: the controller needs no state directory, and
/// building one here would put a `PageModel` under the runner for no
/// reason. The defaults suite is per test and removed at teardown, so
/// no installed copy's switch is read or written.
@MainActor
final class SyncOffSwitchTests: XCTestCase {
    private func controller(enabled: Bool? = nil) throws -> (SyncController, CompanionClient) {
        let suiteName = "companion-sync-off-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        if let enabled { defaults.set(enabled, forKey: "sync.enabled") }
        let client = CompanionClient.ephemeral(tag: "sync-off-\(UUID().uuidString)")
        return (SyncController(client: client, defaults: defaults), client)
    }

    func testSyncIsOffUntilSomebodyTurnsItOn() throws {
        let (sync, client) = try controller()
        XCTAssertFalse(sync.enabled, "no default may be an opt-in to the network")
        XCTAssertEqual(client.syncGate(), .off)
    }

    func testAControllerNobodySwitchedOnTouchesTheSeamAtAll() throws {
        let (sync, client) = try controller()
        sync.start()

        // Shell side: nothing was read, so nothing can be drawn. Each
        // of these is set by `refreshState`, and `refreshState` is on
        // the far side of the guard the launch hook returns through.
        XCTAssertNil(sync.status, "a disabled controller never even asks the core where it stands")
        XCTAssertTrue(sync.devices.isEmpty)
        XCTAssertNil(sync.standingSentence, "off is silence")
        XCTAssertNil(sync.headerWord, "and the header shows what it showed before sync existed")
        XCTAssertNil(sync.settingsLine)
        XCTAssertNil(sync.pairingStage)
        XCTAssertTrue(sync.editedElsewhere.isEmpty)

        // Core side: the gate is the whole ladder in one word. Only a
        // configure can move it off `off`, and configure is the first
        // thing every other sync route needs.
        XCTAssertEqual(client.syncGate(), .off)
        let status = try XCTUnwrap(client.syncStatus())
        XCTAssertFalse(status.configured, "no endpoint was resolved, so no host was ever named")
        XCTAssertFalse(status.signedIn)
        XCTAssertFalse(status.signinPending, "no browser was opened")
        XCTAssertFalse(status.attached)
        XCTAssertEqual(status.enrolled, 0, "no page was enrolled into anything")
    }

    func testAnEnabledFlagAloneStartsNothing() throws {
        // The flag is read at init and acted on at `start()`, after the
        // state restore, so sync never races the pages it would
        // publish. Constructing the controller must therefore be inert
        // even when the switch was left on.
        let (sync, client) = try controller(enabled: true)
        XCTAssertTrue(sync.enabled)
        XCTAssertNil(sync.status, "construction is not a launch")
        XCTAssertEqual(client.syncGate(), .off)
    }

    func testTurningItOnWithNoRelayNamesNoHostAndSaysSo() throws {
        let (sync, client) = try controller()
        // No server URL and no relay override: there is nothing to
        // resolve, and a relay this app invented would be a claim.
        sync.enabled = true

        XCTAssertEqual(
            sync.standingSentence,
            "sync is on but has no relay configured; nothing leaves this Mac",
            "a switch that did nothing must say why, not sit there looking on")
        XCTAssertEqual(
            client.syncGate(), .off,
            "the configure was refused, so the core is where it began")
        XCTAssertNil(
            sync.headerWord,
            "the gate says off, and off owes the header nothing; the page carries the reason")
    }

    /// A controller over a configured core, without the browser: the
    /// ceremony is begun through the seam directly, since `signIn()`
    /// opens the system browser and no test may.
    private func configured() throws -> (SyncController, CompanionClient) {
        let suiteName = "companion-sync-off-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("https://relay.example", forKey: "sync.relayURL")
        defaults.set("https://account.example/oauth/authorize", forKey: "sync.authorizeURL")
        defaults.set("https://account.example/oauth/token", forKey: "sync.tokenURL")
        let client = CompanionClient.ephemeral(tag: "sync-cancel-\(UUID().uuidString)")
        let sync = SyncController(client: client, defaults: defaults)
        sync.serverUrlProvider = { "https://account.example" }
        sync.enabled = true
        return (sync, client)
    }

    func testACancelBeforeTheFinishIsNeverAServerRefusal() throws {
        let (sync, client) = try configured()
        XCTAssertTrue(client.syncSigninBegin().ok)
        XCTAssertEqual(client.syncGate(), .signingIn)

        // The race the surface makes easy: the gate reads signing_in
        // the instant the ceremony is begun, so the way out is drawn
        // before the background task has called finish at all.
        sync.giveUpSignin()
        let outcome = client.syncSigninFinish(patienceMs: 0)

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(
            outcome.reason, "abandoned",
            "a ceremony the user ended is ended, not refused by a server nobody asked")
        XCTAssertNotEqual(
            SyncController.signinSentence(reason: outcome.reason ?? ""),
            SyncController.signinSentence(reason: "refused"),
            "no silence may be reported as a no")
        XCTAssertEqual(client.syncGate(), .signedOut)
    }

    func testAFinishWithNoCeremonyBehindItSaysSoInItsOwnWords() throws {
        // Nobody began anything and nobody cancelled anything: this is
        // the shell calling finish out of order, and it is still not
        // the server refusing a sign in.
        let (_, client) = try configured()
        let outcome = client.syncSigninFinish(patienceMs: 0)
        XCTAssertEqual(outcome.reason, "no_ceremony")
        XCTAssertNotEqual(
            SyncController.signinSentence(reason: "no_ceremony"),
            SyncController.signinSentence(reason: "refused"))
    }

    func testTurningItOffAgainLeavesNothingStanding() throws {
        let (sync, client) = try controller()
        sync.enabled = true
        XCTAssertNotNil(sync.standingSentence)

        sync.enabled = false
        XCTAssertNil(sync.standingSentence, "the sentence goes with the switch")
        XCTAssertNil(sync.headerWord)
        XCTAssertNil(sync.settingsLine)
        XCTAssertTrue(sync.editedElsewhere.isEmpty)
        XCTAssertEqual(client.syncGate(), .off)
    }
}
