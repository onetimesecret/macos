import XCTest

import CompanionKit

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
            "hold_topped_up": false,
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
        XCTAssertFalse(sheet.holdToppedUp)
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
            "hold_topped_up": false,
            "hold_remaining_ms": 3600000,
            "chip_count": 0,
            "last_hour": true
        }]
        """
        let sheets = try JSONDecoder().decode([SheetSummary].self, from: Data(json.utf8))
        XCTAssertTrue(sheets[0].paused)
        XCTAssertFalse(sheets[0].holdToppedUp)
        XCTAssertEqual(sheets[0].holdRemainingMs, 3_600_000)
        XCTAssertTrue(sheets[0].lastHour)
        XCTAssertEqual(sheets[0].fractionRemaining, 0.5, accuracy: 0.0001)
    }

    /// The tier is a separate fact from the hold itself: the tab labels
    /// the next double-click from it, so a summary that dropped it
    /// would leave the gesture lying about what it does.
    func testToppedUpHoldDecoding() throws {
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
            "hold_topped_up": true,
            "hold_remaining_ms": 86400000,
            "chip_count": 0,
            "last_hour": true
        }]
        """
        let sheets = try JSONDecoder().decode([SheetSummary].self, from: Data(json.utf8))
        XCTAssertTrue(sheets[0].paused)
        XCTAssertTrue(sheets[0].holdToppedUp)
        XCTAssertEqual(sheets[0].holdRemainingMs, 86_400_000)
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
        // A record is metadata: a closed vocabulary, a random id, two
        // stamps, and the page's own capped title. There is no field
        // here that could carry ink or an excerpt.
        let json = """
        [{
            "event": "sealed",
            "item": "6a5f9f6e-6b7a-4c1d-9b2e-0f3a7c8d1e42",
            "title": "deploy friday",
            "at_ms": 1762123456789,
            "created_at_ms": 1762123400000,
            "size": "small",
            "destination": "none"
        }, {
            "event": "sent",
            "item": "6a5f9f6e-6b7a-4c1d-9b2e-0f3a7c8d1e42",
            "title": "deploy friday",
            "at_ms": 1762123499999,
            "created_at_ms": 1762123400000,
            "size": "small",
            "destination": "clipboard"
        }]
        """
        let records = try JSONDecoder().decode([LedgerEntry].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 2)

        let sealed = records[0]
        XCTAssertEqual(sealed.event, "sealed")
        XCTAssertEqual(sealed.item, "6a5f9f6e-6b7a-4c1d-9b2e-0f3a7c8d1e42")
        XCTAssertEqual(sealed.item.count, 36)
        XCTAssertEqual(sealed.title, "deploy friday")
        XCTAssertEqual(sealed.atMs, 1_762_123_456_789)
        XCTAssertEqual(sealed.createdAtMs, 1_762_123_400_000)
        XCTAssertEqual(sealed.size, "small")
        XCTAssertEqual(sealed.destination, "none")

        // Copying to the pasteboard is an egress and says so.
        XCTAssertEqual(records[1].event, "sent")
        XCTAssertEqual(records[1].destination, "clipboard")

        // Two events on one item are two rows, not one.
        XCTAssertEqual(sealed.item, records[1].item)
        XCTAssertNotEqual(sealed.id, records[1].id)
    }

    func testLedgerEntryCarriesNoContentField() throws {
        // The guarantee stated on the type, checked mechanically: a
        // round-trip through the encoder shows every key the type can
        // hold, and none of them is a run, an excerpt or a tombstone.
        let json = """
        {
            "event": "discarded",
            "item": "6a5f9f6e-6b7a-4c1d-9b2e-0f3a7c8d1e42",
            "title": "deploy friday",
            "at_ms": 1762123456789,
            "created_at_ms": 1762123400000,
            "size": "huge",
            "destination": "none"
        }
        """
        let record = try JSONDecoder().decode(LedgerEntry.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["event", "item", "title", "at_ms", "created_at_ms", "size", "destination"])

        // Every value is a closed vocabulary, an id, a number, or the
        // capped title. Nothing is free text the core did not bound.
        XCTAssertTrue(
            ["created", "sealed", "sent", "expired", "discarded"].contains(record.event))
        XCTAssertTrue(["tiny", "small", "medium", "large", "huge"].contains(record.size))
        XCTAssertTrue(["none", "clipboard", "link"].contains(record.destination))
        XCTAssertLessThanOrEqual(record.title.count, 80)
    }

    func testRungMappingMatchesTheABI() {
        // Codes match the C ABI (crates/ffi/include/companion_ffi.h).
        XCTAssertEqual(Rung.oneHour.rawValue, 0)
        XCTAssertEqual(Rung.sevenDays.rawValue, 5)
        XCTAssertEqual(Rung(rawValue: 2), .eightHours)
        XCTAssertNil(Rung(rawValue: 6))
    }
}
