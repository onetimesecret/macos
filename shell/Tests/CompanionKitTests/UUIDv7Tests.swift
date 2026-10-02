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
}
