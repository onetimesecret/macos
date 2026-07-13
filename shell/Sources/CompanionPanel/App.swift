import AppKit
import SwiftUI

/// The app's resident presence is the menu-bar item; a click reveals the
/// panel (docs/spec/03 principle 2). `PanelController`'s non-activating
/// `NSPanel` — not SwiftUI's stock `MenuBarExtra`, which has its own
/// activation behavior and can't drop capture.
///
/// TRANSITIONAL SURFACE: the panel still wears the spike's rev A shape
/// (a docked list) while speaking the rev C core — sheets, chips, the
/// pausable countdown, the ledger. The real rev C window (movable,
/// resizable, bottom tabs, the ink editor) is the next slice; this keeps
/// the seam exercised and CI honest in the meantime.
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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // ㊙️ maruhi ("secret") — the menu-bar glyph. An emoji title
        // renders in colour; VoiceOver reads the explicit label, not the
        // emoji's own name.
        item.button?.title = "㊙️"
        item.button?.setAccessibilityLabel("Onetime Secret Companion")
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
/// summaries. It never holds a sealed byte.
///
/// Frugality contract (docs/spec/05): expiry is *scheduled*, not polled —
/// one timer armed at the core's next event (page expiry or hold lapse),
/// re-armed after it fires. The only periodic work is a 1 Hz countdown
/// redraw, and that runs solely while the panel is visible.
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var sheets: [SheetSummary] = []

    /// A refusal or status line the panel shows briefly ("the window
    /// holds 9 pages…"). Refuse-don't-evict means the app says so.
    @Published var notice: String?

    /// Whether the panel floats above other apps' windows (`.statusBar`
    /// level) or behaves like a normal window other windows can cover
    /// (`.normal`). Persisted, so the choice survives relaunch; the
    /// controller follows it. Default: float on top (original behavior).
    @Published var floatsOnTop: Bool {
        didSet { UserDefaults.standard.set(floatsOnTop, forKey: Self.floatsKey) }
    }
    private static let floatsKey = "floatsOnTop"

    private let client = CompanionClient()
    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var eventTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?

    init() {
        // Unset → float on top, matching the panel's original behavior.
        floatsOnTop = UserDefaults.standard.object(forKey: Self.floatsKey) as? Bool ?? true
        refresh()
    }

    deinit {
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    func refresh() {
        sheets = client.sheets()
        armEventTimer()
    }

    /// The page gestures act on: the first tab, made on demand. The rev C
    /// window will track the visibly selected tab instead.
    private func currentSheet() -> UInt64? {
        if let first = sheets.first { return first.id }
        let created = client.newSheet()
        if created == 0 {
            notice = "the window holds 9 pages — let one expire, or close one"
            return nil
        }
        return created
    }

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself and
    /// the content lands as an opaque chip. Consent is the gesture.
    func sealPaste() {
        guard let sheet = currentSheet() else { refresh(); return }
        if client.sealFromPasteboard(sheet: sheet) == nil {
            notice = "nothing to seal"
        }
        refresh()
    }

    /// A real drag landed on the panel. Interim route: the drop handler
    /// hands the text to the core's seal-text entry (the same call ⌘↩
    /// uses) — dropped content is sealed by gesture (docs/spec/04). The
    /// boundary-lawful end state is the core reading
    /// `NSDraggingInfo.draggingPasteboard` itself
    /// (docs/hardware-verification.md); until that lands, the text
    /// transits this process once, in the ingest direction only.
    func receiveDrop(_ text: String) {
        guard let sheet = currentSheet() else { refresh(); return }
        _ = client.sealText(sheet: sheet, text)
        refresh()
    }

    /// A new page (⌥⌘N). At the cap the app declines and says so.
    func newPage() {
        if client.newSheet() == 0 {
            notice = "the window holds 9 pages — let one expire, or close one"
        }
        refresh()
    }

    /// Click the countdown label: next rung, clock reset (docs/spec/04).
    func cycleRung(_ id: UInt64) {
        _ = client.cycleRung(sheet: id)
        refresh()
    }

    /// Double-click the tab: hold the clock 1h, then top-up to 24h.
    func pause(_ id: UInt64) {
        _ = client.pausePress(sheet: id)
        refresh()
    }

    /// Close the page; it rests in the ledger.
    func close(_ id: UInt64) {
        _ = client.closeSheet(id: id)
        refresh()
    }

    /// The ledger (⌘0), read fresh on demand — dead pages, dimmed ink.
    func ledger() -> [LedgerEntry] {
        client.ledger()
    }

    /// DEV SCAFFOLDING: seed the pasteboard with a sample and seal it,
    /// so the transitional panel shows a live page with a chip. The
    /// sample is assembled at runtime so the raw pattern never appears
    /// in the repository text (the secret-scan CI job reads history).
    func devStageSample() {
        client.devSeedPasteboard("ghp_" + String(repeating: "n0ts3cr3t", count: 4))
        sealPaste()
    }

    /// The panel became visible: start the 1 Hz countdown redraw.
    func startRedraw() {
        guard redrawTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sheets = self?.client.sheets() ?? [] }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// The panel is hidden: stop redrawing. The armed event timer is the
    /// only remaining wakeup.
    func stopRedraw() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    /// Arm exactly one timer, at the core's next event — a page expiry
    /// or a hold lapse, whichever is first. When it fires, settle the
    /// clock and re-arm. No event → no timer.
    private func armEventTimer() {
        eventTimer?.invalidate()
        eventTimer = nil
        let ms = client.nextEventMs()
        guard ms >= 0 else { return }
        let timer = Timer(
            timeInterval: max(0.05, Double(ms) / 1000.0),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.client.expireDue()
                self?.refresh() // re-arms for the next event
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }
}
