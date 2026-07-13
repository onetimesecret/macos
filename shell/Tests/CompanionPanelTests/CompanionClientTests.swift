import XCTest

@testable import CompanionPanel

/// These decode the core's non-secret JSON and check the rung mapping —
/// no live core needed, so they run wherever the package builds.
/// Behaviour that needs the FFI + VoiceOver is exercised in the
/// on-device vertical slice (issue #4).
final class CompanionClientTests: XCTestCase {
    func testSummaryDecoding() throws {
        let json = """
        [{
            "id": 7,
            "kind": "text",
            "state": "draining",
            "concealed": true,
            "detected_as": "GitHub token",
            "ttl_code": 2,
            "ttl_label": "8h",
            "remaining_ms": 28800000,
            "remaining_label": "8h",
            "spoken_remaining": "about 8 hours remaining",
            "recognition": "••••••••••••",
            "display_size": 40,
            "promoted": false
        }]
        """
        let cells = try JSONDecoder().decode([CellSummary].self, from: Data(json.utf8))
        XCTAssertEqual(cells.count, 1)
        let cell = cells[0]
        XCTAssertEqual(cell.id, 7)
        XCTAssertEqual(cell.kind, "text")
        XCTAssertEqual(cell.state, "draining")
        XCTAssertTrue(cell.concealed)
        XCTAssertEqual(cell.detectedAs, "GitHub token")
        XCTAssertEqual(cell.ttlLabel, "8h")
        XCTAssertEqual(cell.spokenRemaining, "about 8 hours remaining")
        // The raw secret never appears — only the masked recognition line.
        XCTAssertEqual(cell.recognition, String(repeating: "\u{2022}", count: 12))
    }

    func testDetectionIsOptional() throws {
        let json = """
        [{
            "id": 3,
            "kind": "text",
            "state": "staged",
            "concealed": false,
            "detected_as": null,
            "ttl_code": 0,
            "ttl_label": "1h",
            "remaining_ms": 3600000,
            "remaining_label": "1h",
            "spoken_remaining": "about 1 hour remaining",
            "recognition": "meet at noon",
            "display_size": 12,
            "promoted": false
        }]
        """
        let cells = try JSONDecoder().decode([CellSummary].self, from: Data(json.utf8))
        XCTAssertNil(cells[0].detectedAs)
        XCTAssertEqual(cells[0].recognition, "meet at noon")
    }

    func testRungMappingMatchesTheABI() {
        // Codes match the C ABI (crates/ffi/include/companion_ffi.h).
        XCTAssertEqual(Rung.oneHour.rawValue, 0)
        XCTAssertEqual(Rung.sevenDays.rawValue, 5)
        XCTAssertEqual(Rung(rawValue: 2), .eightHours)
        XCTAssertNil(Rung(rawValue: 6))
        XCTAssertEqual(Rung.twentyFourHours.seconds, 24 * 3600)
    }
}
