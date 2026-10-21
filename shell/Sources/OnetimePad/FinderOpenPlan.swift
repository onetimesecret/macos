import Foundation

/// What the delegate does with the files the Finder handed over, decided
/// apart from the verbs the way `ActivationRouter` decides routes.
struct FinderOpenPlan: Equatable, Sendable {
    /// File URLs to open now, in the order they arrived.
    var open: [URL] = []
    /// URLs kept for the drain that runs once startup completes.
    var held: [URL] = []
    /// The route for an activation already on its way, in place of its own.
    var pendingRoute: ActivationRoute?

    /// `launchActivationOutstanding` is true only at the startup drain, and
    /// only when the replay of an activation during startup did not run.
    static func decide(
        queued: [URL],
        startupComplete: Bool,
        launchActivationOutstanding: Bool,
        appActive: Bool,
        context: ActivationContext
    ) -> FinderOpenPlan {
        guard startupComplete else { return FinderOpenPlan(held: queued) }
        let files = queued.filter(\.isFileURL)
        guard !files.isEmpty else { return FinderOpenPlan() }
        // An inactive app's open defers in `applySummon`, which arms the route itself.
        guard launchActivationOutstanding, appActive else { return FinderOpenPlan(open: files) }
        return FinderOpenPlan(
            open: files,
            pendingRoute: ActivationRouter.decide(.openEditorPresentation, in: context))
    }
}
