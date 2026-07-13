import XCTest

@testable import CompanionPanel

/// These decode the core's non-secret JSON and check the rung mapping —
/// no live core needed, so they run wherever the package builds.
/// Behaviour that needs the FFI + VoiceOver is exercised in the
/// on-device hardware sessions (docs/hardware-verification.md).
final class CompanionClientTests: XCTestCase {
    func testSheetSummaryDecoding() throws {
        let json = """
        [{
            "id": 7,
            "title": "deploy friday",
            "rung_code": 2,
            "rung_label": "8h",
            "remaining_ms": 28800000,
            "remaining_label": "8h",
            "spoken_remaining": "about 8 hours remaining",
            "fraction_remaining": 1.0,
            "paused": false,
            "hold_remaining_ms": 0,
            "chip_count": 2,
            "last_hour": false
        }]
        """
        let sheets = try JSONDecoder().decode([SheetSummary].self, from: Data(json.utf8))
        XCTAssertEqual(sheets.count, 1)
        let sheet = sheets[0]
        XCTAssertEqual(sheet.id, 7)
        XCTAssertEqual(sheet.title, "deploy friday")
        XCTAssertEqual(sheet.rungLabel, "8h")
        XCTAssertEqual(sheet.spokenRemaining, "about 8 hours remaining")
        XCTAssertEqual(sheet.chipCount, 2)
        XCTAssertFalse(sheet.paused)
        XCTAssertFalse(sheet.lastHour)
    }

    func testHeldSheetDecoding() throws {
        let json = """
        [{
            "id": 3,
            "title": "errands",
            "rung_code": 0,
            "rung_label": "1h",
            "remaining_ms": 1800000,
            "remaining_label": "30m",
            "spoken_remaining": "about 30 minutes remaining",
            "fraction_remaining": 0.5,
            "paused": true,
            "hold_remaining_ms": 3600000,
            "chip_count": 0,
            "last_hour": true
        }]
        """
        let sheets = try JSONDecoder().decode([SheetSummary].self, from: Data(json.utf8))
        XCTAssertTrue(sheets[0].paused)
        XCTAssertEqual(sheets[0].holdRemainingMs, 3_600_000)
        XCTAssertTrue(sheets[0].lastHour)
        XCTAssertEqual(sheets[0].fractionRemaining, 0.5, accuracy: 0.0001)
    }

    func testChipInfoDecoding() throws {
        // The chip's face is the excerpt and counts — there is no field
        // that could carry the sealed bytes.
        let json = """
        {
            "chip_id": 42,
            "kind": "text",
            "excerpt": "ghp_4kQ9…5jK7a",
            "size_label": "40 ch",
            "promoted": false
        }
        """
        let chip = try JSONDecoder().decode(ChipInfo.self, from: Data(json.utf8))
        XCTAssertEqual(chip.chipId, 42)
        XCTAssertEqual(chip.kind, "text")
        XCTAssertEqual(chip.excerpt, "ghp_4kQ9…5jK7a")
        XCTAssertEqual(chip.sizeLabel, "40 ch")
    }

    func testLedgerDecoding() throws {
        let json = """
        [{
            "cause": "expired",
            "title": "deploy friday",
            "age_ms": 5000,
            "segments": [
                {"ink": "### deploy friday\\nin order —\\n"},
                {"tombstone": "ghp_4kQ9…5jK7a"}
            ]
        }]
        """
        let records = try JSONDecoder().decode([LedgerEntry].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].cause, "expired")
        XCTAssertEqual(records[0].title, "deploy friday")
        let runs = records[0].runs
        XCTAssertEqual(runs.count, 2)
        guard case .ink(let text) = runs[0] else { return XCTFail("first run is ink") }
        XCTAssertTrue(text.contains("in order"))
        guard case .tombstone(let excerpt) = runs[1] else {
            return XCTFail("second run is a tombstone")
        }
        XCTAssertEqual(excerpt, "ghp_4kQ9…5jK7a")
    }

    func testRungMappingMatchesTheABI() {
        // Codes match the C ABI (crates/ffi/include/companion_ffi.h).
        XCTAssertEqual(Rung.oneHour.rawValue, 0)
        XCTAssertEqual(Rung.sevenDays.rawValue, 5)
        XCTAssertEqual(Rung(rawValue: 2), .eightHours)
        XCTAssertNil(Rung(rawValue: 6))
    }
}
