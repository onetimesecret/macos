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

        // A fresh tab arrives holding a page, with the contract's
        // defaults. The two ids are separate from here on: the tab
        // takes the strip's gestures, the page takes the document's.
        let tabID = client.newTab()
        XCTAssertNotEqual(tabID, 0)
        var sheets = client.tabs()
        XCTAssertEqual(sheets.count, 1)
        var sheet = try XCTUnwrap(sheets.first)
        XCTAssertEqual(sheet.id, tabID)
        XCTAssertTrue(sheet.hasPage)
        let sheetID = try XCTUnwrap(sheet.pageID)
        // No ink to derive from yet, so the title is the creation
        // stamp, "MMDD-HHmm" in local time. The exact string depends on
        // the host clock and zone, so assert the shape.
        assertPlaceholderTitle(sheet.title)
        XCTAssertEqual(Rung(rawValue: sheet.rungCode), .sevenDays) // the ceiling, ADR-0011 section 3
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
        sheets = client.tabs()
        sheet = try XCTUnwrap(sheets.first)
        XCTAssertEqual(sheet.title, "deploy friday")
        XCTAssertEqual(sheet.chipCount, 1)

        // The clock: cycling tapers down the ladder from the ceiling;
        // the pause cycles hold → top up → release, and the summary
        // says which press comes next so the tab can label the gesture
        // honestly. The snap is off here so the bound below is the
        // rung's own duration (the snap has its own suite).
        XCTAssertTrue(client.setGraceSnap(false))
        XCTAssertEqual(client.cycleRung(tab: tabID), .threeDays)
        XCTAssertTrue(client.pausePress(tab: tabID))
        sheet = try XCTUnwrap(client.tabs().first)
        XCTAssertTrue(sheet.paused)
        XCTAssertFalse(sheet.holdToppedUp)
        let firstHoldMs = sheet.holdRemainingMs
        XCTAssertGreaterThan(firstHoldMs, 0)
        XCTAssertGreaterThanOrEqual(client.nextEventMs(), 0)

        XCTAssertTrue(client.pausePress(tab: tabID)) // top up to 24h
        sheet = try XCTUnwrap(client.tabs().first)
        XCTAssertTrue(sheet.paused)
        XCTAssertTrue(sheet.holdToppedUp)
        XCTAssertGreaterThan(sheet.holdRemainingMs, firstHoldMs)

        XCTAssertTrue(client.pausePress(tab: tabID)) // release
        sheet = try XCTUnwrap(client.tabs().first)
        XCTAssertFalse(sheet.paused)
        XCTAssertFalse(sheet.holdToppedUp)
        XCTAssertEqual(sheet.holdRemainingMs, 0)
        // The release gives the page back its own countdown, not a
        // longer one: it resumes on the rung the cycling left it.
        XCTAssertEqual(Rung(rawValue: sheet.rungCode), .threeDays)
        XCTAssertLessThanOrEqual(sheet.remainingMs, 3 * 24 * 60 * 60 * 1000)

        // Death: the page leaves the store and the ledger keeps the
        // account of what happened to it. Metadata only, newest first.
        XCTAssertTrue(client.closeTab(id: tabID))
        XCTAssertTrue(client.tabs().isEmpty, "closing the tab took the slot too")
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
        XCTAssertNotEqual(client.newTab(), 0)
        let sheetID = try XCTUnwrap(client.tabs().first?.pageID)

        // An untouched page: the creation stamp exists, the modified
        // stamp does not, and the empty body is one empty paragraph.
        var meta = try XCTUnwrap(client.sheetMeta(sheet: sheetID))
        XCTAssertGreaterThan(meta.createdMs, 0)
        XCTAssertNil(meta.modifiedS)
        XCTAssertEqual(client.blocks(sheet: sheetID).count, 1)

        // Two typed lines: the newline arrives on its own, so this is
        // two blocks, each with a 36-character identity, stamps, and a
        // reach of one paragraph, and the page's modified stamp
        // appears.
        XCTAssertTrue(
            client.applyOps(
                sheet: sheetID,
                json: #"[{"ins": {"at": 0, "text": "alpha\n"}}, {"ins": {"at": 6, "text": "beta"}}]"#
            ))
        meta = try XCTUnwrap(client.sheetMeta(sheet: sheetID))
        let modified = try XCTUnwrap(meta.modifiedS)
        XCTAssertGreaterThan(modified, 0)
        let blocks = client.blocks(sheet: sheetID)
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            XCTAssertEqual(block.id.count, 36)
            XCTAssertGreaterThan(try XCTUnwrap(block.createdS), 0)
            XCTAssertGreaterThan(try XCTUnwrap(block.modifiedS), 0)
            XCTAssertEqual(block.paragraphs, 1)
        }

        // Identity holds across an intra-block edit, and an unknown page
        // answers nil and empty.
        XCTAssertTrue(
            client.applyOps(
                sheet: sheetID, json: #"[{"ins": {"at": 10, "text": " grew"}}]"#))
        XCTAssertEqual(client.blocks(sheet: sheetID).map(\.id), blocks.map(\.id))

        // A paste arrives whole, so it stays whole: one block reaching
        // across the lines it brought, not one block per line.
        XCTAssertTrue(
            client.applyOps(
                sheet: sheetID, json: #"[{"ins": {"at": 15, "text": "\nfrom\nelsewhere"}}]"#))
        let pasted = client.blocks(sheet: sheetID)
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(pasted.map(\.id), blocks.map(\.id))
        XCTAssertEqual(pasted[1].paragraphs, 3)
        XCTAssertNil(client.sheetMeta(sheet: 424_242))
        XCTAssertTrue(client.blocks(sheet: 424_242).isEmpty)
    }

    /// The two facts a projection over days needs, decoded off the live
    /// core: which day the page was born on, relative to today, and
    /// whether anything is on it (ADR-0020). Both are the core's
    /// answers, the day so a shell-side time zone can never disagree
    /// with the stamp on the tab, the content bar so there is one
    /// definition of it and not a second one up here.
    func testTheSummaryCarriesThePagesDayAndWhetherAnythingIsOnIt() throws {
        let client = CompanionClient()
        XCTAssertNotEqual(client.newTab(), 0)
        var tab = try XCTUnwrap(client.tabs().first)
        let sheetID = try XCTUnwrap(tab.pageID)

        // A page made a moment ago was made today, and holds nothing.
        XCTAssertEqual(tab.pageDayOffset, 0)
        XCTAssertFalse(tab.pageHasContent)

        // Whitespace is not content: a stray newline must not conjure a
        // day the user never had.
        XCTAssertTrue(client.syncDocument(sheet: sheetID, json: #"[{"ink": "  \n "}]"#))
        tab = try XCTUnwrap(client.tabs().first)
        XCTAssertFalse(tab.pageHasContent)
        XCTAssertEqual(tab.pageDayOffset, 0, "the page is still there, and still today's")

        // One typed line is.
        XCTAssertTrue(client.syncDocument(sheet: sheetID, json: #"[{"ink": "rotate the key"}]"#))
        tab = try XCTUnwrap(client.tabs().first)
        XCTAssertTrue(tab.pageHasContent)

        // Overnight the page dies and the slot stands (ADR-0017). With
        // no page there is no day: nil rather than 0, because 0 would
        // read as a slot holding a page made today.
        XCTAssertTrue(client.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000))
        XCTAssertEqual(client.expireDue(), 1)
        let survivor = try XCTUnwrap(client.tabs().first)
        XCTAssertFalse(survivor.hasPage, "the page expired")
        XCTAssertNil(survivor.pageDayOffset, "no page, no day")
        XCTAssertFalse(survivor.pageHasContent)
    }

    func testAUserSetNameSticksAcrossASyncAndOutlivesThePage() throws {
        let client = CompanionClient()
        let tabID = client.newTab()
        let sheetID = try XCTUnwrap(client.tabs().first?.pageID)

        XCTAssertTrue(client.setTitle(tab: tabID, "  incident 4471  "))
        XCTAssertEqual(client.tabs().first?.title, "incident 4471") // trimmed

        // Editing the page no longer touches the name.
        let document = """
        [{"ink": "### deploy friday\\nin order\\n"}]
        """
        XCTAssertTrue(client.syncDocument(sheet: sheetID, json: document))
        XCTAssertEqual(client.tabs().first?.title, "incident 4471")

        // Clearing the name hands the label back to the ink.
        XCTAssertTrue(client.setTitle(tab: tabID, "   "))
        XCTAssertEqual(client.tabs().first?.title, "deploy friday")

        // A name is capped core-side, which is what bounds the one
        // piece of user-typed text that reaches the ledger.
        XCTAssertTrue(client.setTitle(tab: tabID, String(repeating: "x", count: 200)))
        XCTAssertEqual(client.tabs().first?.title.count, 80)

        // A tab that never existed refuses.
        XCTAssertFalse(client.setTitle(tab: 424_242, "nowhere"))

        // And the half the name promises: the page dies and the name
        // stays. Age past the longest rung and settle the clock through
        // the call the shell's armed timer makes, which re-mints both id
        // counters, so the tab is read back from the strip afterwards.
        XCTAssertTrue(client.setTitle(tab: tabID, "incident 4471"))
        XCTAssertTrue(client.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000))
        XCTAssertEqual(client.expireDue(), 1)
        let survivor = try XCTUnwrap(client.tabs().first)
        XCTAssertFalse(survivor.hasPage, "the page expired")
        XCTAssertNil(survivor.pageID)
        XCTAssertEqual(survivor.title, "incident 4471", "the name outlived the page")
        // Clearing it now falls the label to the tab's own stamp rather
        // than to a page that is no longer there.
        XCTAssertTrue(client.setTitle(tab: survivor.id, ""))
        let stamp = try XCTUnwrap(client.tabs().first?.title)
        XCTAssertNotNil(
            stamp.range(of: #"^\d{4}-\d{4}$"#, options: .regularExpression),
            "a pageless, unnamed tab reads as its MMDD-HHmm stamp, not \(stamp)")
    }

    func testClearingTheLedgerEmptiesIt() {
        let client = CompanionClient()
        let sheetID = client.newTab()
        XCTAssertFalse(client.ledger().isEmpty) // the page's creation
        client.clearLedger()
        XCTAssertTrue(client.ledger().isEmpty)
        // The page itself is untouched: this throws away the account,
        // not the content.
        XCTAssertEqual(client.tabs().first?.id, sheetID)
    }

    func testATenthTabOpensLikeTheNinth() {
        let client = CompanionClient()
        // No keyboard wall at the seam (issue #158): the shortcuts count
        // to nine, the strip does not, and every ask is a distinct slot.
        let ids = (1...12).map { _ in client.newTab() }
        XCTAssertFalse(ids.contains(0), "a slot was refused")
        XCTAssertEqual(Set(ids).count, 12, "two asks answered with one slot")
        XCTAssertEqual(client.tabs().map(\.id), ids, "the strip is not in ask order")
    }

    /// The connection half of the conceal contract — config only, no
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

        // Concealing a vanished chip refuses inline, before any
        // network — the error is a message, never a crash.
        let outcome = client.concealChip(id: 424_242, ttlSecs: nil, passphrase: "", recipient: "")
        XCTAssertFalse(outcome.ok)
        XCTAssertNotNil(outcome.error)
    }

    func testSealTextRefusesInteriorNul() throws {
        let client = CompanionClient()
        XCTAssertNotEqual(client.newTab(), 0)
        let sheetID = try XCTUnwrap(client.tabs().first?.pageID)
        // A C string truncates at an interior NUL; the wrapper refuses
        // rather than seal a silently truncated secret.
        XCTAssertNil(client.sealText(sheet: sheetID, "front\0back", at: 0, length: 0))
        XCTAssertEqual(client.tabs().first?.chipCount, 0)
    }
}
