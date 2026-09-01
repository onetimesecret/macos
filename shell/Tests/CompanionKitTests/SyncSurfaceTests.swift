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

    // MARK: The header word (issue #102, criterion 4)

    private func word(
        gate: SyncGate?, trouble: SyncController.Trouble? = nil, peers: Int? = 1,
        enrolled: Int = 1, enabled: Bool = true
    ) -> SyncHeaderWord? {
        SyncController.headerWord(
            enabled: enabled,
            status: status(attached: gate == .attached, enrolled: enrolled, gate: gate),
            trouble: trouble,
            peers: peers
        )
    }

    func testTheHeaderSaysNothingAboutSyncWhileItIsOff() {
        XCTAssertNil(word(gate: .attached, enabled: false))
        XCTAssertNil(
            word(gate: .refused, trouble: .refused, enabled: false),
            "off is silence even when the last thing sync heard was a refusal")
        XCTAssertNil(word(gate: .off), "and a switch over no relay owes the header nothing")
    }

    func testEveryGateStateThatSpeaksHasItsOwnHeaderWord() {
        let speaking: [SyncGate] = [.signedOut, .signingIn, .refused, .unreachable, .ready, .attached]
        let words = speaking.map { word(gate: $0)?.text }
        for (gate, text) in zip(speaking, words) {
            XCTAssertNotNil(text, "\(gate) may not be silent in the header")
        }
        XCTAssertEqual(
            Set(words.compactMap { $0 }).count, speaking.count,
            "no two gate states share a word")
        XCTAssertEqual(word(gate: .signedOut)?.text, "sync signed out")
        XCTAssertEqual(word(gate: .signingIn)?.text, "signing in")
        XCTAssertEqual(word(gate: .refused)?.text, "sync refused")
        XCTAssertEqual(word(gate: .unreachable)?.text, "sync offline")
        XCTAssertEqual(word(gate: .ready)?.text, "reaching")
        XCTAssertEqual(word(gate: .attached)?.text, "synced")
    }

    func testTheLoudWordsAreTheOnesAUserMustActOn() {
        XCTAssertEqual(word(gate: .refused)?.tone, .loud)
        XCTAssertEqual(word(gate: .unreachable)?.tone, .loud)
        XCTAssertEqual(
            word(gate: .attached, trouble: .behind)?.tone, .loud,
            "falling behind is not a gate state and still has to be loud")
        // A working channel is not news, so it is drawn as quietly as
        // the persistence word's `saved`.
        XCTAssertEqual(word(gate: .attached)?.tone, .quiet)
        XCTAssertEqual(word(gate: .ready)?.tone, .plain)
        XCTAssertEqual(word(gate: .signingIn)?.tone, .plain)
    }

    func testFallingBehindOutranksTheGatesGoodNews() {
        XCTAssertEqual(word(gate: .attached, trouble: .behind)?.text, "sync behind")
        XCTAssertEqual(word(gate: .ready, trouble: .behind)?.text, "sync behind")
        // But the account axis still wins over it where the gate names
        // a condition of its own: a refused account is why nothing is
        // arriving, and rejoining cannot be attempted through it.
        XCTAssertEqual(word(gate: .attached, trouble: .refused)?.text, "synced")
    }

    func testAttachedWithNobodyAwakeDoesNotClaimToBeSynced() {
        XCTAssertEqual(word(gate: .attached, peers: 0, enrolled: 2)?.text, "sync waiting")
        // With nothing enrolled there is nothing waiting: an empty
        // channel is genuinely up to date.
        XCTAssertEqual(word(gate: .attached, peers: 0, enrolled: 0)?.text, "synced")
    }

    func testACoreWithNoGateLeavesTheShellsOwnReadingStanding() {
        // A core built before the gate existed, or one a version ahead
        // naming a state this build never heard of.
        XCTAssertEqual(word(gate: nil, trouble: .unreachable)?.text, "sync offline")
        XCTAssertEqual(word(gate: nil, trouble: .signedOut)?.text, "sync signed out")
        XCTAssertNil(word(gate: nil, trouble: nil), "and it invents nothing to say")
    }

    func testTheHeaderWordAndTheStandingSentenceNeverDisagree() {
        // Every degraded condition that earns a sentence earns a word,
        // so the page and the header can never be caught telling a user
        // two different things about one channel.
        let troubles: [SyncController.Trouble] = [.signedOut, .refused, .unreachable, .behind]
        for trouble in troubles {
            let gate = SyncController.reconciled(trouble: trouble, gate: nil)
            XCTAssertNotNil(
                SyncController.sentence(
                    enabled: true, status: status(gate: nil), trouble: gate, peers: 1))
            XCTAssertNotNil(
                SyncController.headerWord(
                    enabled: true, status: status(gate: nil), trouble: gate, peers: 1),
                "\(trouble) speaks on the page and must speak in the header too")
        }
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
                {"kind": "applied", "page": "0011", "page_id": 7},
                {"kind": "applied", "page": "0022", "page_id": null},
                {"kind": "rejoin_required", "page": null}
            ],
            "state": null
        }
        """
        let outcome = try JSONDecoder().decode(SyncPumpOutcome.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.events.count, 3)
        XCTAssertEqual(outcome.events[0].kind, "applied")
        XCTAssertEqual(outcome.events[0].page, "0011")
        XCTAssertEqual(
            outcome.events[0].pageID, 7,
            "the local id is what a surface can point a mark at")
        XCTAssertNil(
            outcome.events[1].pageID,
            "a page this device no longer keeps is named honestly as none")
        XCTAssertNil(outcome.events[2].page)
    }

    func testAnEventFromACoreWithNoLocalPageIdStillDecodes() throws {
        // A core built before the local id joined the event: the whole
        // pump answer may not be lost over one absent field.
        let json = """
        {"ok": true, "reason": null, "state": null,
         "events": [{"kind": "applied", "page": "0011"}]}
        """
        let outcome = try JSONDecoder().decode(SyncPumpOutcome.self, from: Data(json.utf8))
        XCTAssertEqual(outcome.events.count, 1)
        XCTAssertNil(outcome.events[0].pageID)
    }
}
