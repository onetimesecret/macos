import AppKit
import SwiftUI

/// The app's resident presence is the menu-bar item; a click reveals the
/// panel (docs/spec/03 principle 2). This is the ADR-0002 entry point:
/// `PanelController`'s edge-docked, non-activating `NSPanel` — not
/// SwiftUI's stock `MenuBarExtra`, which has its own (less
/// disqualifiable) activation behavior and can't dock to a screen edge
/// or drop capture. Measuring the make-or-break surface means running
/// the surface itself, not a lookalike.
@main
struct CompanionPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scene renders anything; the status item + panel
        // (built in AppDelegate) are the entire UI. A placeholder scene
        // is required by the `App` protocol.
        Settings {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PanelModel()
    private var controller: PanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu — present, not central.
        NSApp.setActivationPolicy(.accessory)

        let controller = PanelController(model: model)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "hourglass",
            accessibilityDescription: "Onetime Secret Companion"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        // Testing aid: show without a click, so the non-activating claim
        // is scriptable (e.g. ADR-0002 measurement runs) rather than
        // needing a synthetic click through Accessibility permissions.
        if ProcessInfo.processInfo.environment["COMPANION_AUTOSHOW"] != nil {
            controller.show()
        }
    }

    @objc private func togglePanel() {
        controller?.toggle()
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
    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var expiryTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?

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
    func devStageSample() {
        client.devSeedPasteboard("ghp_16C7e42F292c6912E7710c838347Ae178B4a")
        ingest()
    }

    /// A real drag landed on the panel. Staged via the same dev-seed
    /// path as `devStageSample` — see the comment at the drop site
    /// (`PanelView.dropZone`) for why this isn't the final ingest path.
    func receiveDrop(_ text: String) {
        client.devSeedPasteboard(text)
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
