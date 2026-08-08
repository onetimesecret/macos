import XCTest

import CompanionKit

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
        // No ink to derive from yet, so the title is the creation
        // stamp, "MMDD-HHmm" in local time. The exact string depends on
        // the host clock and zone, so assert the shape.
        assertPlaceholderTitle(sheet.title)
        XCTAssertEqual(Rung(rawValue: sheet.rungCode), .eightHours) // the default rung
        XCTAssertEqual(sheet.chipCount, 0)
        XCTAssertFalse(sheet.paused)
        XCTAssertFalse(sheet.spokenRemaining.isEmpty)
        XCTAssertGreaterThan(sheet.fractionRemaining, 0.9)

        // Seal ink: the chip's face carries no sealed bytes.
        let chip = try XCTUnwrap(client.sealText(sheet: sheetID, secret, at: 0, length: 0))
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

        // Death: the page leaves the store and the ledger keeps the
        // account of what happened to it. Metadata only, newest first.
        XCTAssertTrue(client.closeSheet(id: sheetID))
        XCTAssertTrue(client.sheets().isEmpty)
        let ledger = client.ledger()

        // One record per lifecycle step: the page's creation, the seal,
        // the page's discard. Nothing else in this test emits.
        XCTAssertEqual(ledger.map(\.event), ["discarded", "sealed", "created"])
        let discarded = try XCTUnwrap(ledger.first)
        let sealed = ledger[1]
        let created = ledger[2]

        // The page's own records share its item id; the chip has its own.
        XCTAssertEqual(created.item, discarded.item)
        XCTAssertNotEqual(sealed.item, created.item)
        for record in ledger {
            XCTAssertEqual(record.item.count, 36)
            XCTAssertEqual(record.item, record.item.lowercased())
            XCTAssertGreaterThan(record.atMs, 0)
            XCTAssertGreaterThan(record.createdAtMs, 0)
            XCTAssertTrue(
                ["tiny", "small", "medium", "large", "huge"].contains(record.size))
            XCTAssertTrue(["none", "clipboard", "link"].contains(record.destination))
        }

        // The title travels: the page was named by the time it died,
        // and it was still on its placeholder when the chip was sealed.
        XCTAssertEqual(discarded.title, "deploy friday")
        assertPlaceholderTitle(created.title)
        assertPlaceholderTitle(sealed.title)

        // Nothing left the boundary. Not the sealed text, not the
        // excerpt the chip's own face carries, not the page's ink.
        assertFreeOfContent(ledger, chip: chip)
    }

    /// The ledger's guarantee, checked end to end against the live
    /// core: no field of any record carries content.
    private func assertFreeOfContent(
        _ ledger: [LedgerEntry], chip: ChipInfo, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for record in ledger {
            let fields = [
                record.event, record.item, record.title, record.size, record.destination,
                String(record.atMs), String(record.createdAtMs), record.id,
            ]
            for field in fields {
                XCTAssertFalse(field.contains(secret), "a record leaked the secret",
                               file: file, line: line)
                XCTAssertFalse(field.contains("n0ts3cr3t"), "a record leaked a fragment",
                               file: file, line: line)
                XCTAssertFalse(field.contains(chip.excerpt), "a record leaked the excerpt",
                               file: file, line: line)
                XCTAssertFalse(field.contains("in order"), "a record leaked the ink",
                               file: file, line: line)
            }
        }
    }

    /// "MMDD-HHmm": nine characters, digits either side of one hyphen.
    private func assertPlaceholderTitle(
        _ title: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(
            title.range(of: #"^\d{4}-\d{4}$"#, options: .regularExpression),
            "\(title) is not an MMDD-HHmm placeholder", file: file, line: line)
    }

    func testMetaAndBlocksCarryIdentitiesAndStampsOnly() throws {
        let client = CompanionClient()
        let sheetID = client.newSheet()

        // An untouched page: the creation stamp exists, the modified
        // stamp does not, and the empty body is one empty paragraph.
        var meta = try XCTUnwrap(client.sheetMeta(sheet: sheetID))
        XCTAssertGreaterThan(meta.createdMs, 0)
        XCTAssertNil(meta.modifiedS)
        XCTAssertEqual(client.blocks(sheet: sheetID).count, 1)

        // Two typed paragraphs: two blocks, each with a 36-character
        // identity and stamps, and the page's modified stamp appears.
        XCTAssertTrue(
            client.applyOps(
                sheet: sheetID,
                json: #"[{"ins": {"at": 0, "text": "alpha\nbeta"}}]"#))
        meta = try XCTUnwrap(client.sheetMeta(sheet: sheetID))
        let modified = try XCTUnwrap(meta.modifiedS)
        XCTAssertGreaterThan(modified, 0)
        let blocks = client.blocks(sheet: sheetID)
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            XCTAssertEqual(block.id.count, 36)
            XCTAssertGreaterThan(try XCTUnwrap(block.createdS), 0)
            XCTAssertGreaterThan(try XCTUnwrap(block.modifiedS), 0)
        }

        // Identity holds across an intra-paragraph edit, and an
        // unknown page answers nil and empty.
        XCTAssertTrue(
            client.applyOps(
                sheet: sheetID, json: #"[{"ins": {"at": 10, "text": " grew"}}]"#))
        XCTAssertEqual(client.blocks(sheet: sheetID).map(\.id), blocks.map(\.id))
        XCTAssertNil(client.sheetMeta(sheet: 424_242))
        XCTAssertTrue(client.blocks(sheet: 424_242).isEmpty)
    }

    func testAUserSetTitleSticksAcrossASync() throws {
        let client = CompanionClient()
        let sheetID = client.newSheet()

        XCTAssertTrue(client.setTitle(sheet: sheetID, "  incident 4471  "))
        XCTAssertEqual(client.sheets().first?.title, "incident 4471") // trimmed

        // Editing the page no longer touches the name.
        let document = """
        [{"ink": "### deploy friday\\nin order\\n"}]
        """
        XCTAssertTrue(client.syncDocument(sheet: sheetID, json: document))
        XCTAssertEqual(client.sheets().first?.title, "incident 4471")

        // Clearing the override hands the name back to the ink.
        XCTAssertTrue(client.setTitle(sheet: sheetID, "   "))
        XCTAssertEqual(client.sheets().first?.title, "deploy friday")

        // A title is capped core-side, which is what bounds the one
        // piece of page-owned text that reaches the ledger.
        XCTAssertTrue(client.setTitle(sheet: sheetID, String(repeating: "x", count: 200)))
        XCTAssertEqual(client.sheets().first?.title.count, 80)

        // A page that never existed refuses.
        XCTAssertFalse(client.setTitle(sheet: 424_242, "nowhere"))
    }

    func testClearingTheLedgerEmptiesIt() {
        let client = CompanionClient()
        let sheetID = client.newSheet()
        XCTAssertFalse(client.ledger().isEmpty) // the page's creation
        client.clearLedger()
        XCTAssertTrue(client.ledger().isEmpty)
        // The page itself is untouched: this throws away the account,
        // not the content.
        XCTAssertEqual(client.sheets().first?.id, sheetID)
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
        XCTAssertNil(client.sealText(sheet: sheetID, "front\0back", at: 0, length: 0))
        XCTAssertEqual(client.sheets().first?.chipCount, 0)
    }
}
