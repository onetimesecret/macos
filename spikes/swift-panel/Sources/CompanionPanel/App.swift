import SwiftUI

/// The app's resident presence is the menu-bar item; a click reveals the
/// panel. Present, not centre-stage (docs/spec/03 principle 2).
@main
struct CompanionPanelApp: App {
    @StateObject private var model = PanelModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
                .frame(width: 320)
        } label: {
            // A glanceable indicator; the ember accent stays sparing.
            Image(systemName: "hourglass")
                .accessibilityLabel(Text("Onetime Secret Companion"))
        }
        // A window-style panel, not a menu: it previews cells and shows
        // the countdown. The edge-docked NSPanel (PanelController) is the
        // richer surface this spike also exercises.
        .menuBarExtraStyle(.window)
    }
}

/// The view model: wraps the core client and publishes non-secret
/// summaries. It never holds a secret.
///
/// Frugality contract (docs/spec/05): expiry is *scheduled*, not polled —
/// one timer armed at the core's next deadline, re-armed after it fires.
/// The only periodic work is a 1 Hz countdown redraw, and that runs
/// solely while the panel is visible (see PanelView's onAppear/onDisappear).
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var cells: [CellSummary] = []

    private let client = CompanionClient()
    private var expiryTimer: Timer?
    private var redrawTimer: Timer?

    init() {
        refresh()
    }

    deinit {
        expiryTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    func refresh() {
        cells = client.list()
        armExpiryTimer()
    }

    /// Park whatever is on the pasteboard.
    func ingest() {
        client.ingestPasteboard()
        refresh()
    }

    /// Copy a cell back out (the core writes the pasteboard itself).
    func copyOut(_ id: UInt64) {
        _ = client.copyOut(id: id)
        refresh()
    }

    /// Click the ring/label to cycle the TTL ladder (docs/spec/04).
    func cycle(_ id: UInt64) {
        _ = client.cycleTTL(id: id)
        refresh()
    }

    /// Discard now.
    func discard(_ id: UInt64) {
        _ = client.discard(id: id)
        refresh()
    }

    /// DEV SCAFFOLDING: stage a sample secret-shaped text so the spike
    /// shows a live, draining, masked cell before the NSPasteboard
    /// adapter lands. Deleted with the stand-in (issue #3).
    ///
    /// The PAT-shaped sample is assembled at runtime — it still trips
    /// the core's detection, but the raw pattern never appears in the
    /// repository text (the secret-scan CI job reads the full history).
    func devStageSample() {
        client.devSeedPasteboard("ghp_" + String(repeating: "n0ts3cr3t", count: 4))
        ingest()
    }

    /// The panel became visible: start the 1 Hz countdown redraw.
    func startRedraw() {
        guard redrawTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cells = self?.client.list() ?? [] }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// The panel is hidden: stop redrawing. The armed expiry timer is the
    /// only remaining wakeup.
    func stopRedraw() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    /// Arm exactly one timer, at the core's earliest deadline. When it
    /// fires, expire due cells and re-arm. No deadline → no timer.
    private func armExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let ms = client.nextDeadlineMs()
        guard ms >= 0 else { return }
        let timer = Timer(
            timeInterval: max(0.05, Double(ms) / 1000.0),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.client.expireDue()
                self?.refresh() // re-arms for the next deadline
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }
}
