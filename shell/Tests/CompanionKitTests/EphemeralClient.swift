import CompanionCore
import Foundation

@testable import CompanionKit

// The test suite's constructor for a core handle, kept out of
// CompanionKit on purpose: `companion_new_ephemeral` exists only in
// test-util builds of the core (ADR-0018), so a shipping target that
// referenced it could not link against the release xcframework. Here
// the reference lives with its only caller, and a suite run against a
// release build fails loudly at link time instead of shipping the seam.
extension CompanionClient {
    /// A client whose credentials rest in ordinary process memory
    /// core-side (`companion_new_ephemeral`): keys minted through it
    /// never reach the login Keychain and die with the process. Clients
    /// built over the same `tag` share one store, which is what lets a
    /// file sealed through one be restored through another in the same
    /// test run, the way a relaunch would. A test seam, never a
    /// shipping path: the form factors construct through
    /// `init(credentialService:)`.
    static func ephemeral(tag: String) -> CompanionClient {
        companion_init()
        guard let created = tag.withCString({ companion_new_ephemeral($0) }) else {
            fatalError("the core refused to create an ephemeral handle")
        }
        return CompanionClient(adopting: created)
    }

    /// Age every staged page by `ms` of wall time, the way a relaunch
    /// after a night away ages them (`companion_test_age_ms`, gated
    /// with the seam above). Nothing expires here: the caller follows
    /// with `expireDue()`, which is the call the shell's armed timer
    /// makes, so the path under test stays the shipping one. Both id
    /// counters are re-minted densely as at any restore, so read ids
    /// back from `tabs()` afterwards.
    ///
    /// It is here because the states ADR-0017 describes, a tab
    /// standing empty, a slot reused by a second page, are on the far
    /// side of a countdown, and the shortest rung is an hour.
    @discardableResult
    func ageForTests(byMs ms: UInt64) -> Bool {
        companion_test_age_ms(rawHandleForTests, ms)
    }

    /// Replace the core's transport with a stub that answers every
    /// request with `status` and `body` (`companion_test_wire_stub`,
    /// gated with the seams above). A status of zero answers nothing:
    /// every send fails the way an outage does, which is the shape a
    /// test wants when it must not put a link on the real clipboard.
    /// The shipping wire is TLS-only against one configured host, so
    /// this is the only way a test can drive a conceal to the wire and
    /// read back what its draft became on the way out.
    @discardableResult
    func stubWireForTests(status: UInt16, body: String = "") -> Bool {
        body.withCString { companion_test_wire_stub(rawHandleForTests, status, $0) }
    }

    /// The most recent request the stubbed wire saw
    /// (`companion_test_wire_last_json`): a summary the core made at
    /// send time from the non-secret fields of the body, which it then
    /// dropped. No payload and no passphrase ever sits in it. Nil
    /// before the first send, or when no stub is installed.
    func lastWireForTests() -> WireRecord? {
        guard let ptr = companion_test_wire_last_json(rawHandleForTests) else { return nil }
        defer { companion_string_free(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WireRecord.self, from: data)
    }
}

/// One request as the stubbed wire records it. `ttl`, `shareDomain`,
/// `hasPassphrase` and `recipient` come from a conceal body; a request
/// without one, the Settings status check, carries nil and false.
struct WireRecord: Decodable, Equatable {
    let method: String
    let url: String
    let authorized: Bool
    let ttl: UInt64?
    let shareDomain: String?
    let hasPassphrase: Bool
    let recipient: String?

    enum CodingKeys: String, CodingKey {
        case method, url, authorized, ttl, recipient
        case shareDomain = "share_domain"
        case hasPassphrase = "has_passphrase"
    }
}
