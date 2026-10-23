import Foundation

/// What the delegate does with the files the Finder handed over, decided
/// apart from the verbs the way `ActivationRouter` decides routes.
struct FinderOpenPlan: Equatable, Sendable {
    /// File URLs to open now, in the order they arrived.
    var open: [URL] = []
    /// File URLs kept for the next drain: startup completing, a modal ending, a close decision resolving.
    var held: [URL] = []
    /// The model-dependent close decision is read only after startup.
    static func decide(
        queued: [URL],
        startupComplete: Bool,
        modalSessionRunning: Bool,
        modalBracketed: Bool,
        closeDecisionPending: @autoclosure () -> Bool
    ) -> FinderOpenPlan {
        let files = queued.filter(\.isFileURL)
        // Both modal facts, as every other modal gate reads them (`ModalSession`).
        guard startupComplete, !modalSessionRunning, !modalBracketed, !closeDecisionPending() else {
            return FinderOpenPlan(held: files)
        }
        guard !files.isEmpty else { return FinderOpenPlan() }
        return FinderOpenPlan(open: files)
    }
}
