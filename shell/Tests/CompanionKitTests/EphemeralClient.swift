import CompanionCore

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
}
