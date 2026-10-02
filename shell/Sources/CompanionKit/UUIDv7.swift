import Foundation
import Security

/// RFC 9562 §5.7: Unix milliseconds followed by 74 random bits.
/// Same-millisecond ordering and clock-rollback monotonicity are not promised.
enum UUIDv7 {
    static func generate() -> UUID {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let status = withUnsafeMutableBytes(of: &bytes) {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "The OS CSPRNG must be available")
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        precondition(milliseconds >= 0 && milliseconds < 281_474_976_710_656)
        return make(unixMilliseconds: UInt64(milliseconds), randomBytes: bytes)
    }

    static func make(unixMilliseconds: UInt64, randomBytes: uuid_t) -> UUID {
        precondition(unixMilliseconds < (1 << 48))
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
