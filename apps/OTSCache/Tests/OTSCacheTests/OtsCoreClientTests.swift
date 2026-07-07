import XCTest

@testable import OTSCache

/// These decode the core's non-secret JSON and check the rung mapping — no live
/// cache needed, so they run wherever the package builds. Behaviour that needs
/// the FFI + VoiceOver is exercised in the on-device vertical slice (docs/01
/// §10 step 7).
final class OtsCoreClientTests: XCTestCase {
    func testSummaryDecoding() throws {
        let json = """
        [{
            "id": 7,
            "kind": "text",
            "rung": "three_hours",
            "rung_label": "3h",
            "remaining_ms": 10800000,
            "remaining_label": "about 3 hours remaining",
            "byte_len": 30,
            "preview": "sk-liv…"
        }]
        """
        let cells = try JSONDecoder().decode([CellSummary].self, from: Data(json.utf8))
        XCTAssertEqual(cells.count, 1)
        let cell = cells[0]
        XCTAssertEqual(cell.id, 7)
        XCTAssertEqual(cell.kind, "text")
        XCTAssertEqual(cell.rungLabel, "3h")
        XCTAssertEqual(cell.remainingLabel, "about 3 hours remaining")
        XCTAssertEqual(cell.preview, "sk-liv…")
        // The raw secret never appears — only the redacted preview.
        XCTAssertFalse(cell.preview.contains("live_"))
    }

    func testRungMappingRoundTrips() {
        XCTAssertEqual(Rung(apiString: "one_hour"), .oneHour)
        XCTAssertEqual(Rung(apiString: "seven_days"), .sevenDays)
        XCTAssertNil(Rung(apiString: "fortnight"))
        // Codes match the C ABI (docs/01 §5).
        XCTAssertEqual(Rung.oneHour.rawValue, 0)
        XCTAssertEqual(Rung.sevenDays.rawValue, 5)
    }

    func testShareLinkDecoding() throws {
        let json = """
        {
            "ok": true,
            "share_url": "https://onetimesecret.com/secret/abc",
            "metadata_url": "https://onetimesecret.com/private/def",
            "secret_key": "abc",
            "metadata_key": "def",
            "ttl_secs": 3600
        }
        """
        let link = try JSONDecoder().decode(ShareLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.shareURL, "https://onetimesecret.com/secret/abc")
        XCTAssertEqual(link.metadataKey, "def")
        XCTAssertEqual(link.ttlSecs, 3600)
    }
}
