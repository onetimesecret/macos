import Foundation
import Security

/// RFC 9562 §5.7: Unix milliseconds followed by 74 random bits.
/// Same-millisecond ordering and clock-rollback monotonicity are not promised.
/// Pre-epoch and negative-infinite dates use timestamp zero, dates above the
/// 48-bit limit (including positive infinity) use its maximum, and NaN uses zero.
/// Timestamp normalization never substitutes for secure random bytes.
enum UUIDv7 {
    private static let maximumUnixMilliseconds: UInt64 = (1 << 48) - 1

    static func generate(now: Date = Date()) -> UUID {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let status = withUnsafeMutableBytes(of: &bytes) {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "The OS CSPRNG must be available")
        return make(unixMilliseconds: unixMilliseconds(for: now), randomBytes: bytes)
    }

    static func unixMilliseconds(for date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard !milliseconds.isNaN, milliseconds > 0 else { return 0 }
        guard milliseconds < Double(maximumUnixMilliseconds) else {
            return maximumUnixMilliseconds
        }
        return UInt64(milliseconds)
    }

    static func make(unixMilliseconds: UInt64, randomBytes: uuid_t) -> UUID {
        let unixMilliseconds = min(unixMilliseconds, maximumUnixMilliseconds)
        var bytes = randomBytes
        bytes.0 = UInt8(truncatingIfNeeded: unixMilliseconds >> 40)
        bytes.1 = UInt8(truncatingIfNeeded: unixMilliseconds >> 32)
        bytes.2 = UInt8(truncatingIfNeeded: unixMilliseconds >> 24)
        bytes.3 = UInt8(truncatingIfNeeded: unixMilliseconds >> 16)
        bytes.4 = UInt8(truncatingIfNeeded: unixMilliseconds >> 8)
        bytes.5 = UInt8(truncatingIfNeeded: unixMilliseconds)
        bytes.6 = (bytes.6 & 0x0F) | 0x70
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }
}
