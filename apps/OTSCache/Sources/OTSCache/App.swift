import SwiftUI

/// The app's resident presence is the menu-bar item; a click reveals the panel.
/// This is home base — the app is always here and only here until summoned
/// (docs/00 §6.1).
@main
struct OTSCacheApp: App {
    @StateObject private var model = CacheModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
                .frame(width: 320)
        } label: {
            // A glanceable indicator. The brand flame stays sparing (docs/00 §9).
            Image(systemName: "hourglass")
                .accessibilityLabel(Text("OTS Cache"))
        }
        // A window-style panel, not a menu: it previews cells and shows the
        // countdown. The edge-docked NSPanel (PanelController) is the richer
        // surface for a later step.
        .menuBarExtraStyle(.window)
    }
}

/// The view model: wraps the core client, polls for state on a coarse cadence,
/// and publishes non-secret summaries to the UI. It never holds a secret.
@MainActor
final class CacheModel: ObservableObject {
    @Published private(set) var cells: [CellSummary] = []

    private let client = OtsCoreClient()
    private var timer: Timer?

    init() {
        refresh()
        startTicking()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        cells = client.list()
    }

    /// Park whatever is on the pasteboard.
    func ingest() {
        client.ingestPasteboard()
        refresh()
    }

    /// Click the label to cycle the TTL ladder (docs/00 §6.2).
    func cycle(_ id: UInt64) {
        _ = client.cycleTTL(id: id)
        refresh()
    }

    /// Retrieve → dismiss now.
    func evict(_ id: UInt64) {
        _ = client.evict(id: id)
        refresh()
    }

    private func startTicking() {
        // A visible countdown must not wake the GPU every frame (docs/00 §9):
        // redraw on a coarse ~1 Hz cadence while the panel is visible. A later
        // pass suspends ticking when hidden or on battery.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
