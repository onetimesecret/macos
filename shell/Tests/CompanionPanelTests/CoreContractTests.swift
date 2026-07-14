import XCTest

@testable import CompanionPanel

/// The Rust↔Swift JSON contract, tested against the LIVE core — every
/// assertion here decodes real `companion_*` output through the same
/// Swift types the window renders from, so a drifting field name fails
/// in CI instead of rendering as an empty window. These deliberately
/// avoid the pasteboard routes: the seal-text entry and the document
/// mirror exercise the full JSON surface without touching the real
/// clipboard on a developer's machine.
final class CoreContractTests: XCTestCase {
    // PAT-shaped, assembled at runtime so the raw pattern never appears
    // in the repository text (the secret-scan CI job reads history).
    private let secret = "ghp_" + String(repeating: "n0ts3cr3t", count: 4)

    func testSheetLifecycleRoundTripsThroughTheSeam() throws {
        let client = CompanionClient()

        // A fresh page arrives with the contract's defaults.
        let sheetID = client.newSheet()
        XCTAssertNotEqual(sheetID, 0)
        var sheets = client.sheets()
        XCTAssertEqual(sheets.count, 1)
        var sheet = try XCTUnwrap(sheets.first)
        XCTAssertEqual(sheet.id, sheetID)
        XCTAssertEqual(sheet.title, "untitled")
        XCTAssertEqual(Rung(rawValue: sheet.rungCode), .eightHours) // the default rung
        XCTAssertEqual(sheet.chipCount, 0)
        XCTAssertFalse(sheet.paused)
        XCTAssertFalse(sheet.spokenRemaining.isEmpty)
        XCTAssertGreaterThan(sheet.fractionRemaining, 0.9)

        // Seal ink: the chip's face carries no sealed bytes.
        let chip = try XCTUnwrap(client.sealText(sheet: sheetID, secret))
        XCTAssertEqual(chip.kind, "text")
        XCTAssertFalse(chip.excerpt.isEmpty)
        XCTAssertFalse(chip.excerpt.contains(secret))
        XCTAssertFalse(chip.sizeLabel.isEmpty)

        // Mirror the document: the tab title is the first typed line,
        // markup stripped; the chip count follows the snapshot.
        let document = """
        [{"ink": "### deploy friday\\nin order —\\n"}, {"chip": \(chip.chipId)}]
        """
        XCTAssertTrue(client.syncDocument(sheet: sheetID, json: document))
        sheets = client.sheets()
        sheet = try XCTUnwrap(sheets.first)
        XCTAssertEqual(sheet.title, "deploy friday")
        XCTAssertEqual(sheet.chipCount, 1)

        // The clock: cycling steps the ladder; the pause holds.
        XCTAssertEqual(client.cycleRung(sheet: sheetID), .twentyFourHours)
        XCTAssertTrue(client.pausePress(sheet: sheetID))
        sheet = try XCTUnwrap(client.sheets().first)
        XCTAssertTrue(sheet.paused)
        XCTAssertGreaterThan(sheet.holdRemainingMs, 0)
        XCTAssertGreaterThanOrEqual(client.nextEventMs(), 0)

        // Death: the closed page rests in the ledger — dimmed ink and a
        // tombstone; the excerpt is all that survives of the chip.
        XCTAssertTrue(client.closeSheet(id: sheetID))
        XCTAssertTrue(client.sheets().isEmpty)
        let ledger = client.ledger()
        XCTAssertEqual(ledger.count, 1)
        let record = try XCTUnwrap(ledger.first)
        XCTAssertEqual(record.cause, "closed")
        XCTAssertEqual(record.title, "deploy friday")
        let runs = record.runs
        XCTAssertEqual(runs.count, 2)
        guard case .ink(let ink) = runs[0] else { return XCTFail("first run is ink") }
        XCTAssertTrue(ink.contains("in order"))
        guard case .tombstone(let excerpt) = runs[1] else {
            return XCTFail("second run is a tombstone")
        }
        XCTAssertEqual(excerpt, chip.excerpt)
        XCTAssertFalse(excerpt.contains(secret))
    }

    func testTheCapRefusesTheTenthPage() {
        let client = CompanionClient()
        for _ in 1...9 {
            XCTAssertNotEqual(client.newSheet(), 0)
        }
        // Refuse-don't-evict: the wall is the keyboard map's.
        XCTAssertEqual(client.newSheet(), 0)
        XCTAssertEqual(client.sheets().count, 9)
    }

    /// The connection half of the promotion contract — config only, no
    /// token and no socket: a token here would write the real Keychain
    /// on a developer's machine, and the network paths are covered by
    /// the Rust mock-transport tests.
    func testConnectionConfigRoundTripsAndRefusesPlainHttp() throws {
        let client = CompanionClient()

        // TLS-only from the config step, not the socket.
        XCTAssertFalse(client.configureConnection(
            serverUrl: "http://example.com", shareDomain: "", extid: "", token: nil
        ))

        XCTAssertTrue(client.configureConnection(
            serverUrl: "https://eu.onetimesecret.com/",
            shareDomain: "share.example.com",
            extid: "org_1",
            token: nil
        ))
        let info = try XCTUnwrap(client.connectionInfo())
        XCTAssertTrue(info.configured)
        XCTAssertEqual(info.serverUrl, "https://eu.onetimesecret.com") // trailing slash trimmed
        XCTAssertEqual(info.shareDomain, "share.example.com")
        XCTAssertEqual(info.extid, "org_1")

        // Promotion of a vanished chip refuses inline, before any
        // network — the error is a message, never a crash.
        let outcome = client.promoteChip(id: 424_242, ttlSecs: nil, passphrase: "", recipient: "")
        XCTAssertFalse(outcome.ok)
        XCTAssertNotNil(outcome.error)
    }

    func testSealTextRefusesInteriorNul() {
        let client = CompanionClient()
        let sheetID = client.newSheet()
        // A C string truncates at an interior NUL; the wrapper refuses
        // rather than seal a silently truncated secret.
        XCTAssertNil(client.sealText(sheet: sheetID, "front\0back"))
        XCTAssertEqual(client.sheets().first?.chipCount, 0)
    }
}
