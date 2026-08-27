import XCTest

@testable import CompanionKit

/// The sync surface's decisions, held as pure functions: which
/// sentence each degraded state earns (issue #102's acceptance — every
/// one distinct, none silent, and off saying nothing at all), where
/// the endpoints come from, and what the seam's JSON decodes to. No
/// live core and no network — the engine's own behaviour is proven
/// Rust-side.
final class SyncSurfaceTests: XCTestCase {
    private func status(
        signedIn: Bool = true, attached: Bool = true, enrolled: Int = 0
    ) -> SyncStatus {
        SyncStatus(
            configured: true, signedIn: signedIn, signinPending: false, attached: attached,
            epoch: 0, framePresent: false, enrolled: enrolled, pairing: nil
        )
    }

    func testSyncOffSaysNothingWhateverTheState() {
        XCTAssertNil(
            SyncController.sentence(
                enabled: false, status: nil, trouble: .signedOut, peers: nil))
        XCTAssertNil(
            SyncController.sentence(
                enabled: false, status: status(), trouble: .unreachable, peers: 0))
    }

    func testEveryDegradedStateHasItsOwnSentence() {
        let troubles: [SyncController.Trouble] = [
            .notConfigured, .signedOut, .unreachable, .behind,
        ]
        let sentences = troubles.map {
            SyncController.sentence(enabled: true, status: status(), trouble: $0, peers: 1)
        }
        for sentence in sentences {
            XCTAssertNotNil(sentence, "no degraded state may be silent")
        }
        XCTAssertEqual(
            Set(sentences.compactMap { $0 }).count, troubles.count,
            "each degraded state is a different sentence"
        )
        XCTAssertEqual(
            SyncController.sentence(
                enabled: true, status: status(), trouble: .signedOut, peers: nil),
            "sync is signed out; the pad is unaffected"
        )
    }

    func testQuietAndWellSaysNothing() {
        XCTAssertNil(
            SyncController.sentence(
                enabled: true, status: status(enrolled: 1), trouble: nil, peers: 2))
    }

    func testAnEnrolledPageWithNoPeerAwakeGetsTheWaitingSentence() {
        // Issue #94's device: pages enrolled, nobody to send them to.
        XCTAssertEqual(
            SyncController.sentence(
                enabled: true, status: status(enrolled: 1), trouble: nil, peers: 0),
            "no other device is awake; pages sync when one wakes"
        )
        // With nothing enrolled there is nothing to wait for.
        XCTAssertNil(
            SyncController.sentence(
                enabled: true, status: status(enrolled: 0), trouble: nil, peers: 0))
    }

    func testEverySigninFailureRowHasASentence() {
        let rows = [
            "abandoned", "state_mismatch", "no_code", "unreachable",
            "keychain", "busy", "not_configured", "refused",
        ]
        for row in rows {
            XCTAssertFalse(
                SyncController.signinSentence(reason: row).isEmpty,
                "\(row) may not be silent"
            )
        }
        XCTAssertEqual(
            SyncController.signinSentence(reason: "abandoned"),
            "the browser never returned; sync stays signed out"
        )
    }

    func testPairingStagesReadAsSentences() {
        XCTAssertEqual(
            SyncController.pairingSentence(stage: "waiting", reason: nil),
            "waiting for the other device"
        )
        XCTAssertEqual(
            SyncController.pairingSentence(stage: "failed", reason: "mismatch"),
            "the strings did not match; nothing was stored"
        )
    }

    func testTheSyncMenuItemSaysWhatTheClickWillDo() {
        XCTAssertEqual(
            SheetTab.syncMenuTitle(enrolled: false), "Sync this page to your devices")
        XCTAssertEqual(SheetTab.syncMenuTitle(enrolled: true), "Stop syncing this page")
    }

    func testEndpointsDeriveFromTheServerButNeverInventARelay() {
        let derived = SyncEndpoints.resolve(
            serverUrl: "https://eu.onetimesecret.com/",
            relayOverride: nil, authorizeOverride: nil, tokenOverride: nil, clientOverride: nil
        )
        XCTAssertEqual(derived.authorizeUrl, "https://eu.onetimesecret.com/oauth/authorize")
        XCTAssertEqual(derived.tokenUrl, "https://eu.onetimesecret.com/oauth/token")
        XCTAssertEqual(derived.relayUrl, "", "no relay may be invented")
        XCTAssertFalse(derived.complete)

        let overridden = SyncEndpoints.resolve(
            serverUrl: "https://eu.onetimesecret.com",
            relayOverride: "https://relay.example",
            authorizeOverride: nil, tokenOverride: nil, clientOverride: "companion"
        )
        XCTAssertTrue(overridden.complete)
        XCTAssertEqual(overridden.relayUrl, "https://relay.example")
        XCTAssertEqual(overridden.clientId, "companion")
    }

    func testSyncStatusDecoding() throws {
        let json = """
        {
            "configured": true,
            "signed_in": true,
            "signin_pending": false,
            "attached": true,
            "epoch": 3,
            "frame_present": false,
            "enrolled": 2,
            "pairing": "sas"
        }
        """
        let status = try JSONDecoder().decode(SyncStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.signedIn)
        XCTAssertEqual(status.epoch, 3)
        XCTAssertEqual(status.framePresent, false)
        XCTAssertEqual(status.enrolled, 2)
        XCTAssertEqual(status.pairing, "sas")
    }

    func testDeviceListDecodingTellsVerifiedFromStranger() throws {
        let json = """
        {"devices": [
            {"fingerprint": "aa11", "label": "", "this_device": true,
             "verified": true, "paired_wall_ms": null, "attached_ms": null},
            {"fingerprint": "bb22", "label": "laptop", "this_device": false,
             "verified": true, "paired_wall_ms": 1000, "attached_ms": 2000},
            {"fingerprint": "cc33", "label": "", "this_device": false,
             "verified": false, "paired_wall_ms": null, "attached_ms": 3000}
        ]}
        """
        let list = try JSONDecoder().decode(SyncDeviceList.self, from: Data(json.utf8))
        XCTAssertEqual(list.devices.count, 3)
        XCTAssertTrue(list.devices[0].thisDevice)
        XCTAssertEqual(list.devices[1].label, "laptop")
        XCTAssertEqual(list.devices[1].attachedMs, 2000)
        XCTAssertFalse(list.devices[2].verified, "a stranger reads as one")
    }

    func testPumpOutcomeDecoding() throws {
        let json = """
        {
            "ok": true,
            "reason": null,
            "events": [
                {"kind": "applied", "page": "0011"},
                {"kind": "rejoin_required", "page": null}
            ],
            "state": null
        }
        """
        let outcome = try JSONDecoder().decode(SyncPumpOutcome.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.events.count, 2)
        XCTAssertEqual(outcome.events[0].kind, "applied")
        XCTAssertEqual(outcome.events[0].page, "0011")
        XCTAssertNil(outcome.events[1].page)
    }
}
