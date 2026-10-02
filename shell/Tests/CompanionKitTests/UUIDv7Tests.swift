import Foundation
import XCTest
@testable import CompanionKit

final class UUIDv7Tests: XCTestCase {
    func testRFC9562VectorAndDistinctMillisecondOrdering() {
        let random: uuid_t = (0, 0, 0, 0, 0, 0, 0xcc, 0xc3, 0x18, 0xc4, 0xdc, 0x0c, 0x0c, 0x07, 0x39, 0x8f)
        let id = UUIDv7.make(unixMilliseconds: 0x017f22e279b0, randomBytes: random)
        XCTAssertEqual(id.uuidString.lowercased(), "017f22e2-79b0-7cc3-98c4-dc0c0c07398f")
        let later = UUIDv7.make(unixMilliseconds: 0x017f22e279b1, randomBytes: random)
        XCTAssertLessThan(id.uuidString, later.uuidString)
    }

    func testGeneratedIDsCarryCurrentMillisecondsVersionAndVariant() {
        let before = UInt64(Date().timeIntervalSince1970 * 1_000)
        let ids = (0..<1_000).map { _ in UUIDv7.generate() }
        let after = UInt64(Date().timeIntervalSince1970 * 1_000)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            var raw = id.uuid
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            let timestamp = bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            XCTAssertTrue((before...after).contains(timestamp))
            XCTAssertEqual(bytes[6] >> 4, 7)
            XCTAssertEqual(bytes[8] >> 6, 2)
        }
    }

    func testClockBoundaryNormalizationIncludingInvalidDates() {
        let maximum: UInt64 = (1 << 48) - 1
        let cases: [(TimeInterval, UInt64)] = [
            (-1, 0), (0, 0), (0.000_5, 0), (1.5, 1_500),
            (Double(maximum) / 1_000 + 1, maximum),
            (.greatestFiniteMagnitude, maximum),
            (.infinity, maximum), (-.infinity, 0), (.nan, 0)
        ]
        for (seconds, expected) in cases {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(UUIDv7.unixMilliseconds(for: date), expected)
            // Exercise the actual secure generator as well as normalization.
            let bytes = rawBytes(UUIDv7.generate(now: date))
            let timestamp = bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            XCTAssertEqual(timestamp, expected)
            XCTAssertEqual(bytes[6] >> 4, 7)
            XCTAssertEqual(bytes[8] >> 6, 2)
        }
    }

    func testEncodingClampsOversizedIntegerWithoutChangingRandomBits() {
        let random: uuid_t = (0, 0, 0, 0, 0, 0, 0xab, 0xab, 0xab, 0xab, 0xab, 0xab, 0xab, 0xab, 0xab, 0xab)
        let earliest = rawBytes(UUIDv7.make(unixMilliseconds: 0, randomBytes: random))
        let maximum = rawBytes(UUIDv7.make(unixMilliseconds: (1 << 48) - 1, randomBytes: random))
        let beyond = rawBytes(UUIDv7.make(unixMilliseconds: UInt64.max, randomBytes: random))
        XCTAssertEqual(Array(earliest.prefix(6)), [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(Array(maximum.prefix(6)), [UInt8](repeating: 255, count: 6))
        XCTAssertEqual(beyond, maximum)
        XCTAssertEqual(Array(earliest.dropFirst(6)), Array(maximum.dropFirst(6)))
    }

    private func rawBytes(_ id: UUID) -> [UInt8] {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
