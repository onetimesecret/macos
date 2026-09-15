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

    func testABrowserTripSaysSoAndOffersTheWayOut() {
        XCTAssertEqual(
            SyncController.sentence(
                enabled: true,
                status: status(signedIn: false, attached: false, gate: .signingIn),
                trouble: nil, peers: nil),
            "waiting on the browser to finish signing in; Settings can give up on it"
        )
        // The control exists exactly while the trip does, which is the
        // gated banner's shape rather than a disabled button.
        XCTAssertTrue(
            SyncController.showsGiveUpSignin(gate: .signingIn, signinPending: true))
        XCTAssertFalse(
            SyncController.showsGiveUpSignin(gate: .signedOut, signinPending: false))
        XCTAssertFalse(
            SyncController.showsGiveUpSignin(gate: .attached, signinPending: true),
            "the gate is the authority; a stale pending flag does not draw a way out")
        // A core that names no gate leaves the pending flag standing.
        XCTAssertTrue(SyncController.showsGiveUpSignin(gate: nil, signinPending: true))
        XCTAssertFalse(SyncController.showsGiveUpSignin(gate: nil, signinPending: false))
    }

    func testGivingUpReadsDifferentlyFromABrowserThatNeverReturned() {
        // The core answers both with `abandoned`, because to it they
        // are one fact. Only the shell knows which the user did.
        XCTAssertEqual(
            SyncController.signinSentence(reason: "cancelled"),
            "the sign-in was given up; nothing was stored"
        )
        XCTAssertNotEqual(
            SyncController.signinSentence(reason: "cancelled"),
            SyncController.signinSentence(reason: "abandoned")
        )
    }

    func testEverySigninFailureRowHasASentence() {
        let rows = [
            "abandoned", "cancelled", "state_mismatch", "no_code", "unreachable",
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

    func testARefusedBearerUnderTheLongPollIsNotAFreeRound() {
        // A 401 under the long poll comes back instantly rather than
        // holding the poll open, so re-entering at once would be a
        // refresh, poll, refuse loop at the speed of the network.
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: true, reason: nil, sawUnreachable: false, sawUnauthorized: true),
            .refused)
        // A quiet round is a free round, and that is the whole point
        // of the long poll.
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: true, reason: nil, sawUnreachable: false, sawUnauthorized: false),
            .again)
        // The coarser outcomes still win: a credential that is gone
        // and an attachment that is gone are not waits.
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: false, reason: "signed_out", sawUnreachable: false, sawUnauthorized: true),
            .signedOut)
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: false, reason: "not_attached", sawUnreachable: false, sawUnauthorized: false),
            .reattach)
        // A relay nobody could reach is reported as itself, never as
        // a refusal.
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: true, reason: nil, sawUnreachable: true, sawUnauthorized: false),
            .unreachable)
        XCTAssertEqual(
            SyncController.pumpTurn(
                ok: false, reason: nil, sawUnreachable: false, sawUnauthorized: false),
            .unreachable)
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
        // With nothing enrolled the channel is still only a channel: a
        // working one is not news until another device is there to
        // receive, so the word waits whether or not pages are enrolled
        // (D-20), and it waits in the plain tone, not the loud one.
        XCTAssertEqual(word(gate: .attached, peers: 0, enrolled: 0)?.text, "sync waiting")
        XCTAssertEqual(word(gate: .attached, peers: 0, enrolled: 0)?.tone, .plain)
        // "synced" is the word for a peer awake, and for nothing else.
        XCTAssertEqual(word(gate: .attached, peers: 1, enrolled: 0)?.text, "synced")
        XCTAssertEqual(word(gate: .attached, peers: 1, enrolled: 2)?.text, "synced")
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

    // MARK: A page being written elsewhere (issue #102, criterion 6)

    func testAPageKeepsItsMarkOnlyWhileTheEditIsRecent() {
        let now = Date()
        let marks: [UInt64: Date] = [
            11: now.addingTimeInterval(-5),
            22: now.addingTimeInterval(-SyncController.elsewhereWindow - 1),
        ]
        XCTAssertEqual(
            SyncController.editedElsewhere(marks: marks, now: now), [11],
            "a peer who stopped writing a while ago is not writing now")
        // And the mark lapses on its own, without another event.
        XCTAssertEqual(
            SyncController.editedElsewhere(
                marks: marks, now: now.addingTimeInterval(SyncController.elsewhereWindow)),
            [],
            "the mark says now, and now passes")
    }

    func testNoMarksMeansNoPagesMarked() {
        XCTAssertEqual(SyncController.editedElsewhere(marks: [:], now: Date()), [])
    }

    func testTheDeviceListSaysWhenEachWasLastSeen() {
        let now: UInt64 = 1_000_000_000_000
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: nil, nowWallMs: now),
            "not seen on this channel",
            "a paired device the roster does not carry is absent, not recent")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 30_000, nowWallMs: now),
            "seen just now")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 5 * 60_000, nowWallMs: now),
            "seen 5 minutes ago")
        // The band the just-now threshold hands to the minutes: ninety
        // seconds through a hundred and nineteen is one minute, and one
        // minute is singular like every other unit here.
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 90_000, nowWallMs: now),
            "seen 1 minute ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 119_000, nowWallMs: now),
            "seen 1 minute ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 120_000, nowWallMs: now),
            "seen 2 minutes ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 3_600_000, nowWallMs: now),
            "seen 1 hour ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 5 * 3_600_000, nowWallMs: now),
            "seen 5 hours ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 24 * 3_600_000, nowWallMs: now),
            "seen 1 day ago")
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now - 9 * 24 * 3_600_000, nowWallMs: now),
            "seen 9 days ago")
    }

    func testADeviceStampedInTheFutureIsAClockNotATimeTraveller() {
        // Two machines, two clocks: the peer's attach stamp can land
        // ahead of this Mac's now, and "seen in -3 minutes" would be
        // the surface reporting the skew as news.
        let now: UInt64 = 1_000_000_000_000
        XCTAssertEqual(
            SyncController.lastSeen(attachedWallMs: now + 90_000, nowWallMs: now),
            "seen just now")
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

    /// The refusal names the one rule the URL has to meet (D-24), so
    /// the sentence is held to the record rather than left to drift
    /// inside `save()`.
    func testARefusedServerURLNamesTheHttpsRule() {
        XCTAssertEqual(
            ConnectionSettingsView.saveStatus(accepted: false),
            "refused: the server URL must be https://…")
        XCTAssertEqual(ConnectionSettingsView.saveStatus(accepted: true), "saved")
    }
}
