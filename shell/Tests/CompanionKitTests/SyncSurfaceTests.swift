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
        signedIn: Bool = true, attached: Bool = true, enrolled: Int = 0,
        gate: SyncGate? = .attached
    ) -> SyncStatus {
        SyncStatus(
            configured: true, signedIn: signedIn, gateToken: gate?.rawValue, signinPending: false,
            attached: attached, epoch: 0, framePresent: false, enrolled: enrolled, pairing: nil
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
            .notConfigured, .signedOut, .refused, .unreachable, .behind,
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

    func testTheGateIsTheAuthorityOnTheAccountAxis() {
        // A gate that names a condition wins over whatever the shell
        // had inferred from a refusal string.
        XCTAssertEqual(
            SyncController.reconciled(trouble: nil, gate: .refused), .refused)
        XCTAssertEqual(
            SyncController.reconciled(trouble: .unreachable, gate: .signedOut), .signedOut)
        XCTAssertEqual(
            SyncController.reconciled(trouble: .signedOut, gate: .off), .notConfigured)
        // A gate with nothing to report clears the account axis.
        XCTAssertNil(SyncController.reconciled(trouble: .unreachable, gate: .attached))
        XCTAssertNil(SyncController.reconciled(trouble: .signedOut, gate: .ready))
        // Falling behind a rotation is not on that axis: that device
        // passed the gate and is short a key.
        XCTAssertEqual(SyncController.reconciled(trouble: .behind, gate: .attached), .behind)
        // A core too old or too new to name a gate leaves the shell's
        // own reading alone.
        XCTAssertEqual(SyncController.reconciled(trouble: .unreachable, gate: nil), .unreachable)
    }

    func testAnAttachRefusalDefersToTheGateThatKnowsWhy() {
        // The core answers a second 401 on one attach with the reason
        // "signed_out" and a gate of refused. The reason is the coarser
        // of the two, so the gate decides which sentence is shown.
        XCTAssertEqual(
            SyncController.settledTrouble(ok: false, reason: "signed_out", gate: .refused),
            .refused
        )
        XCTAssertEqual(
            SyncController.settledTrouble(ok: false, reason: "signed_out", gate: .signedOut),
            .signedOut
        )
        XCTAssertEqual(
            SyncController.settledTrouble(ok: false, reason: "unreachable", gate: .unreachable),
            .unreachable
        )
        // A core with no gate to report leaves the reason standing.
        XCTAssertEqual(
            SyncController.settledTrouble(ok: false, reason: "unreachable", gate: nil),
            .unreachable
        )
        // An attach that landed says nothing, and a gate naming a
        // condition is heard even then.
        XCTAssertNil(SyncController.settledTrouble(ok: true, reason: nil, gate: .attached))
        XCTAssertEqual(
            SyncController.settledTrouble(ok: true, reason: nil, gate: .unreachable),
            .unreachable
        )
    }

    func testARefusedGateSaysSoAndSpareThePad() {
        XCTAssertEqual(
            SyncController.sentence(
                enabled: true, status: status(signedIn: false, attached: false, gate: .refused),
                trouble: .refused, peers: nil),
            "the account refused this sign-in; sync is off and the pad is unaffected"
        )
        // And the same condition is silent while sync is off.
        XCTAssertNil(
            SyncController.sentence(
                enabled: false, status: status(gate: .refused), trouble: .refused, peers: nil))
    }

    func testSyncStatusDecoding() throws {
        let json = """
        {
            "configured": true,
            "signed_in": true,
            "gate": "attached",
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
        XCTAssertEqual(status.gate, .attached)
        XCTAssertEqual(status.epoch, 3)
        XCTAssertEqual(status.framePresent, false)
        XCTAssertEqual(status.enrolled, 2)
        XCTAssertEqual(status.pairing, "sas")
    }

    func testAStatusWithAnUnreadableGateStillDecodes() throws {
        // A core from before the gate existed, and one a version ahead
        // of this shell: neither may cost the surface its whole status.
        for token in ["", "\"gate\": null,", "\"gate\": \"a_state_from_the_future\","] {
            let json = """
            {
                "configured": true,
                "signed_in": false,
                \(token)
                "signin_pending": false,
                "attached": false,
                "epoch": null,
                "frame_present": null,
                "enrolled": 0,
                "pairing": null
            }
            """
            let status = try JSONDecoder().decode(SyncStatus.self, from: Data(json.utf8))
            XCTAssertNil(status.gate)
            XCTAssertFalse(status.signedIn)
        }
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
