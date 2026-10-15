import AppKit
import XCTest

@testable import CompanionKit

/// A sealed object's name across the seam (ADR-0043), against the live
/// core through an ephemeral handle. Nothing here persists; the one
/// name=value copy goes to a board in process memory.
final class SealedObjectSeamTests: XCTestCase {
    private func sealedChip(
        _ client: CompanionClient, _ text: String = "hunter2"
    ) throws -> (sheet: UInt64, chip: ChipInfo) {
        XCTAssertNotEqual(client.newTab(), 0)
        let sheet = try XCTUnwrap(client.tabs().last?.pageID)
        let chip = try XCTUnwrap(client.sealText(sheet: sheet, text, at: 0, length: 0))
        return (sheet, chip)
    }

    private func face(_ client: CompanionClient, sheet: UInt64) -> ChipInfo? {
        for run in client.documentRuns(sheet: sheet) {
            if case .chip(let chip) = run { return chip }
        }
        return nil
    }

    func testANameRidesTheFaceAndABlankDraftClearsIt() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, chip) = try sealedChip(client)
        XCTAssertNil(chip.name, "a fresh seal is unnamed")

        XCTAssertTrue(client.setChipName("  DB_PASSWORD ", chip: chip.chipId))
        XCTAssertEqual(face(client, sheet: sheet)?.name, "DB_PASSWORD", "trimmed core-side")

        XCTAssertFalse(client.setChipName("db.password", chip: chip.chipId))
        XCTAssertFalse(client.setChipName("DB\0PASSWORD", chip: chip.chipId))
        XCTAssertEqual(face(client, sheet: sheet)?.name, "DB_PASSWORD", "a refusal kept it")

        XCTAssertTrue(client.setChipName("   ", chip: chip.chipId))
        XCTAssertNil(face(client, sheet: sheet)?.name)
        XCTAssertFalse(client.setChipName("API_KEY", chip: 4_242), "an unknown chip")
    }

    func testTheRefusalIsTheCoresRule() {
        XCTAssertNil(CompanionClient.chipNameRefusal("API_KEY"))
        XCTAssertNil(CompanionClient.chipNameRefusal(""), "a blank draft clears")
        XCTAssertNil(CompanionClient.chipNameRefusal(String(repeating: "A", count: 64)))
        XCTAssertEqual(
            CompanionClient.chipNameRefusal(String(repeating: "A", count: 65)), .tooLong)
        XCTAssertEqual(CompanionClient.chipNameRefusal("my.key"), .outsideCharset)
        XCTAssertEqual(CompanionClient.chipNameRefusal("9lives"), .outsideCharset)
        XCTAssertEqual(
            CompanionClient.chipNameRefusal(String(repeating: "A", count: 70) + "-"),
            .outsideCharset, "the charset is judged first")
        XCTAssertEqual(
            CompanionClient.chipNameRefusal("API\0KEY"), .outsideCharset,
            "a NUL would hand the core less than was typed")
    }

    func testANameValueCopyIsRefusedUnnamedAndClearsLikeACopyOut() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let board = NSPasteboard.general.changeCount
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let (_, chip) = try sealedChip(client)
        XCTAssertFalse(client.copyNameValue(chip: chip.chipId), "an unnamed object")
        XCTAssertFalse(client.clearClipboardIfOurs(), "the refusal wrote nothing of ours")

        XCTAssertTrue(client.setChipName("API_KEY", chip: chip.chipId))
        XCTAssertTrue(client.copyNameValue(chip: chip.chipId))
        // The guarded clear answers for the write and gives the board back.
        XCTAssertTrue(client.clearClipboardIfOurs())
        let sent = client.ledger().filter { $0.event == "sent" }
        XCTAssertEqual(sent.map(\.destination), ["clipboard"])
        XCTAssertFalse(sent.contains { $0.title.contains("API_KEY") })
        XCTAssertEqual(
            NSPasteboard.general.changeCount, board, "the copy reached the general pasteboard")
    }

    private func noteText(_ client: CompanionClient, chip: UInt64) -> String {
        (client.noteRuns(chip: chip) ?? []).reduce(into: "") { text, run in
            if case .ink(let ink) = run { text += ink }
        }
    }

    private func pageInk(_ client: CompanionClient, sheet: UInt64) -> String {
        client.documentRuns(sheet: sheet).reduce(into: "") { text, run in
            if case .ink(let ink) = run { text += ink }
        }
    }

    func testANoteKeepsItsOwnInkAndItsOwnUndo() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, chip) = try sealedChip(client)
        XCTAssertTrue(client.applyOps(sheet: sheet, json: #"[{"ins":{"at":1,"text":" page ink"}}]"#))
        XCTAssertEqual(noteText(client, chip: chip.chipId), "")
        XCTAssertFalse(chip.hasNote)

        XCTAssertTrue(
            client.applyNoteOps(
                chip: chip.chipId, json: #"[{"ins":{"at":0,"text":"note ink"}}]"#))
        XCTAssertEqual(noteText(client, chip: chip.chipId), "note ink")
        XCTAssertEqual(face(client, sheet: sheet)?.hasNote, true)
        XCTAssertEqual(pageInk(client, sheet: sheet), " page ink", "the note rode the page")
        XCTAssertEqual(client.undoNoteActionName(chip: chip.chipId), "Typing")

        XCTAssertEqual(client.undoNote(chip: chip.chipId)?.applied, true)
        XCTAssertEqual(noteText(client, chip: chip.chipId), "")
        XCTAssertEqual(pageInk(client, sheet: sheet), " page ink", "the note's undo reached the page")
        XCTAssertTrue(client.canUndo(sheet: sheet), "the page's step still waits")
        XCTAssertTrue(client.canRedoNote(chip: chip.chipId))

        XCTAssertTrue(client.undo(sheet: sheet))
        XCTAssertEqual(pageInk(client, sheet: sheet), "")
        XCTAssertEqual(client.redoNote(chip: chip.chipId)?.applied, true)
        XCTAssertEqual(noteText(client, chip: chip.chipId), "note ink")
        XCTAssertTrue(client.finishNoteEditingGroup(chip: chip.chipId))

        let chipOp = #"[{"chip":{"at":0,"id":\#(chip.chipId)}}]"#
        XCTAssertFalse(client.applyNoteOps(chip: chip.chipId, json: chipOp), "objects do not nest")
        XCTAssertFalse(client.applyNoteOps(chip: 4_242, json: #"[{"ins":{"at":0,"text":"x"}}]"#))
        XCTAssertNil(client.undoNote(chip: 4_242))
    }

    func testANoteNeverReachesTheLedger() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (_, chip) = try sealedChip(client)
        let before = client.ledger()
        XCTAssertTrue(
            client.applyNoteOps(
                chip: chip.chipId, json: #"[{"ins":{"at":0,"text":"Marmot Burrow"}}]"#,
                intent: .paste))
        XCTAssertEqual(client.undoNote(chip: chip.chipId)?.applied, true)
        XCTAssertEqual(client.ledger(), before, "a note edit recorded something")
    }

    func testANameNeverReachesTheLedger() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (_, chip) = try sealedChip(client)
        let before = client.ledger()
        XCTAssertTrue(client.setChipName("PAGER_ROTA_KEY", chip: chip.chipId))
        XCTAssertEqual(client.ledger(), before, "naming recorded something")
        XCTAssertTrue(client.deleteChip(id: chip.chipId))
        XCTAssertFalse(client.ledger().isEmpty, "the control: the removal is recorded")
        for entry in client.ledger() {
            XCTAssertFalse(entry.title.contains("ROTA"), "\(entry)")
        }
    }
}
