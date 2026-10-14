import AppKit
import XCTest

@testable import CompanionKit

/// The sealed fragment across the seam (ADR-0047), against the live core;
/// nothing persists, and the drag writes an item on a privately named board.
final class SealedFragmentSeamTests: XCTestCase {
    private let secret = "ghp_" + String(repeating: "n0ts3cr3t", count: 2)

    /// A page reading `ab`, a sealed object, `cd`: five units.
    private func page(_ client: CompanionClient) throws -> (sheet: UInt64, chip: ChipInfo) {
        XCTAssertNotEqual(client.newTab(), 0)
        let sheet = try XCTUnwrap(client.tabs().last?.pageID)
        let chip = try XCTUnwrap(client.sealText(sheet: sheet, secret, at: 0, length: 0))
        XCTAssertTrue(client.applyOps(
            sheet: sheet,
            json: #"[{"ins":{"at":0,"text":"ab"}},{"ins":{"at":3,"text":"cd"}}]"#))
        return (sheet, chip)
    }

    private func chips(_ client: CompanionClient, sheet: UInt64) -> [ChipInfo] {
        client.documentRuns(sheet: sheet).compactMap {
            if case .chip(let chip) = $0 { chip } else { nil }
        }
    }

    private let whole = NSRange(location: 0, length: 5)

    func testACopyHandsBackAnEnvelopeAndThePublicText() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, _) = try page(client)
        let copied = try XCTUnwrap(client.copyFragment(sheet: sheet, range: whole))
        XCTAssertEqual(copied.plainText, "ab[sealed content · tiny]cd")
        let envelope = try XCTUnwrap(copied.envelope)
        let text = try XCTUnwrap(String(data: envelope, encoding: .utf8))
        XCTAssertFalse(text.contains("n0ts3cr3t"), "the envelope never holds payload")
        XCTAssertNil(
            client.copyFragment(sheet: sheet, range: NSRange(location: 0, length: 2))?.envelope,
            "ink alone writes plain text only")
        XCTAssertNil(client.copyFragment(sheet: sheet, range: NSRange(location: 0, length: 0)))
        XCTAssertEqual(chips(client, sheet: sheet).count, 1, "a copy changes nothing")
    }

    func testACutsFirstPasteReattachesAndALaterOneClones() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, chip) = try page(client)
        let cut = try XCTUnwrap(client.cutFragment(sheet: sheet, range: whole))
        XCTAssertTrue(chips(client, sheet: sheet).isEmpty)
        let slot = try XCTUnwrap(client.activeCut())
        XCTAssertEqual(slot.pageID, sheet)
        XCTAssertEqual(slot.objects.map(\.chipId), [chip.chipId])
        XCTAssertEqual(slot.objects.first?.excerpt, chip.excerpt, "a face, never payload")

        let envelope = try XCTUnwrap(cut.envelope)
        let first = try XCTUnwrap(client.pasteFragment(
            sheet: sheet, range: NSRange(location: 0, length: 0), envelope: envelope,
            plainText: cut.plainText))
        XCTAssertEqual(first.reattached, 1)
        XCTAssertEqual(first.range, whole)
        XCTAssertNil(client.activeCut(), "its first paste ended the cut")
        XCTAssertEqual(chips(client, sheet: sheet).map(\.chipId), [chip.chipId])

        let second = try XCTUnwrap(client.pasteFragment(
            sheet: sheet, range: NSRange(location: 5, length: 0), envelope: envelope,
            plainText: nil))
        XCTAssertEqual(second.cloned, 1)
        let after = chips(client, sheet: sheet)
        XCTAssertEqual(after.count, 2)
        XCTAssertNotEqual(after[1].chipId, chip.chipId, "a clone is a new object")
        XCTAssertTrue(client.undo(sheet: sheet), "each paste is one step")
        XCTAssertEqual(chips(client, sheet: sheet).count, 1)
    }

    func testAnUnreadableEnvelopePlacesItsPublicText() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, _) = try page(client)
        let placed = try XCTUnwrap(client.pasteFragment(
            sheet: sheet, range: NSRange(location: 0, length: 0),
            envelope: Data("from another build".utf8), plainText: "plain words"))
        XCTAssertTrue(placed.unreadable)
        XCTAssertEqual(placed.lengthUTF16, 11)
        XCTAssertNil(
            client.pasteFragment(
                sheet: sheet, range: NSRange(location: 0, length: 0), envelope: Data(),
                plainText: nil),
            "nothing to place")
    }

    func testTheSlotTheMoveAndTheCloneRoutes() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (sheet, chip) = try page(client)
        XCTAssertNotNil(client.cutFragment(sheet: sheet, range: NSRange(location: 0, length: 3)))
        let placed = try XCTUnwrap(client.pasteActiveCut(
            sheet: sheet, range: NSRange(location: 2, length: 0)))
        XCTAssertEqual(placed.reattached, 1)
        XCTAssertNil(client.pasteActiveCut(sheet: sheet, range: NSRange(location: 0, length: 0)))

        let moved = try XCTUnwrap(client.moveRange(
            sheet: sheet, range: NSRange(location: 4, length: 1), to: 0))
        XCTAssertEqual(moved.reattached, 1)
        XCTAssertEqual(chips(client, sheet: sheet).map(\.chipId), [chip.chipId])
        XCTAssertNil(client.moveRange(sheet: sheet, range: NSRange(location: 0, length: 1), to: 1))

        let cloned = try XCTUnwrap(client.cloneRange(
            sheet: sheet, range: NSRange(location: 0, length: 1), to: 5))
        XCTAssertEqual(cloned.cloned, 1)
        XCTAssertEqual(chips(client, sheet: sheet).count, 2)
    }

    func testADecryptedDragWritesTheItemCoreSideAndRecordsADrag() throws {
        let client = CompanionClient.ephemeral(tag: #function)
        let (_, chip) = try page(client)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let plain = NSPasteboard.PasteboardType.string.rawValue

        XCTAssertFalse(
            client.provideDecryptedDrag(
                chip: chip.chipId, pasteboard: board, item: item, type: "public.png"),
            "not the chip's own type")
        XCTAssertFalse(
            client.provideDecryptedDrag(
                chip: chip.chipId, pasteboard: item, item: board, type: plain),
            "objects of the wrong class")
        XCTAssertFalse(
            client.provideDecryptedDrag(chip: 4_242, pasteboard: board, item: item, type: plain))
        XCTAssertNil(item.string(forType: .string))
        XCTAssertTrue(client.ledger().filter { $0.event == "sent" }.isEmpty)

        XCTAssertTrue(
            client.provideDecryptedDrag(
                chip: chip.chipId, pasteboard: board, item: item, type: plain))
        XCTAssertEqual(item.string(forType: .string), secret, "the core wrote the item")
        XCTAssertEqual(client.ledger().filter { $0.event == "sent" }.map(\.destination), ["drag"])
        XCTAssertTrue(board.types?.isEmpty ?? true, "the item took it, not its pasteboard")
    }

    func testTheFragmentTypeIsTheLawsWithTheDebugSuffix() {
        // The suite builds in debug, where the suffix keeps the two builds apart.
        XCTAssertEqual(
            CompanionClient.sealedFragmentType,
            "com.onetimesecret.onetimepad.sealed-fragment.debug")
    }
}
