import XCTest

@testable import CompanionKit

/// A sealed object's name across the seam (ADR-0043), against the live
/// core through an ephemeral handle. Nothing here persists.
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
