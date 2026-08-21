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
}
