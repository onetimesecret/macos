import Foundation
import XCTest

@testable import CompanionKit

extension XCTestCase {
    /// A model that owns everything it touches: its sealed files rest in
    /// a directory made for this test and removed at teardown, and its
    /// credentials live in process memory rather than the login Keychain
    /// (`CompanionClient.ephemeral(tag:)`, ADR-0018).
    ///
    /// Here so that the isolated construction is the shortest one to
    /// write. `PageModel`'s init refuses the unseamed construction under
    /// the runner outright, since that one resolves to the installed
    /// app's own pages, ledger and Keychain items; this is the sentence
    /// that answers the refusal, for the many suites that want a model
    /// and do not care where it rests. A suite that does care, because
    /// it seals a fixture and reopens it, keeps its own helper: sharing
    /// one tag across two models is what makes a second model a
    /// relaunch rather than a stranger.
    ///
    /// The directory is named, not created. Nothing here writes until a
    /// test asks for a write, and the write path prepares the directory
    /// itself (`FormFactor.prepareStateDirectory(holding:)`), which is
    /// the code the shipping directories go through too.
    @MainActor
    func isolatedModel(
        formFactor: FormFactor = .backdrop,
        defaults: UserDefaults,
        tag: String = UUID().uuidString,
        saveDebounce: TimeInterval? = nil
    ) -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-isolated-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PageModel(
            formFactor: formFactor,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: .ephemeral(tag: tag),
                saveDebounce: saveDebounce
            )
        )
    }
}
