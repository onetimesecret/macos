import AppKit
import SwiftUI

/// The app's resident presence is the menu-bar item; a click reveals
/// the window (docs/spec/03 principle 2) and ⌥Space summons it with the
/// keyboard. `WindowController`'s non-activating `NSPanel` — not
/// SwiftUI's stock `MenuBarExtra`, which has its own activation
/// behavior and can't drop capture.
@main
struct CompanionPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scene renders anything; the status item + window
        // (built in AppDelegate) are the entire UI. A placeholder scene
        // is required by the `App` protocol.
        Settings {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = WindowModel()
    private var controller: WindowController?
    private var statusItem: NSStatusItem?
    private var summonKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu — present, not central.
        NSApp.setActivationPolicy(.accessory)

        let controller = WindowController(model: model)
        self.controller = controller
        model.onHandBackKeys = { [weak controller] in controller?.handBackKeys() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // ㊙️ maruhi ("secret") — the menu-bar glyph. An emoji title
        // renders in colour; VoiceOver reads the explicit label, not the
        // emoji's own name.
        item.button?.title = "㊙️"
        item.button?.setAccessibilityLabel("Onetime Secret Companion")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // ⌥Space, system-wide. Registration can fail (another app holds
        // the combination); the menu-bar item still summons.
        summonKey = GlobalHotKey.optionSpace { [weak self] in
            Task { @MainActor in self?.controller?.summon() }
        }

        // Testing aid: show without a click, so the non-activating claim
        // is scriptable (e.g. ADR-0002 measurement runs) rather than
        // needing a synthetic click through Accessibility permissions.
        if ProcessInfo.processInfo.environment["COMPANION_AUTOSHOW"] != nil {
            controller.show()
        }
    }

    /// Left click toggles the window; right click gets the boring
    /// necessities (docs/spec/04: "Settings, About, Quit — not
    /// features"; Settings arrives with its own slice).
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(
                withTitle: "About Onetime Secret Companion",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            ).target = NSApp
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ).target = NSApp
            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
        } else {
            controller?.toggle()
        }
    }

}

/// One run of a page's document, as the shell mirrors it to the core
/// (`companion_sheet_sync_document`): visible ink, or a sealed chip's id.
enum DocumentRun {
    case ink(String)
    case chip(UInt64)
}

/// The view model: wraps the core client and publishes non-secret
/// summaries. It never holds a sealed byte — the page's live ink
/// belongs to the editor's text storage; chips are ids and excerpts.
///
/// Frugality contract (docs/spec/05): expiry is *scheduled*, not polled —
/// one timer armed at the core's next event (page expiry or hold lapse),
/// re-armed after it fires. The only periodic work is a 1 Hz countdown
/// redraw, and that runs solely while the window is visible.
@MainActor
final class WindowModel: ObservableObject {
    @Published private(set) var sheets: [SheetSummary] = []

    /// The visibly selected page — the one the editor shows and the
    /// gestures act on. Nil only when no pages exist.
    @Published var selection: UInt64?

    /// The ledger tab (⌘0) is showing instead of a page.
    @Published var showingLedger = false

    /// Dead pages, refreshed when the ledger is shown or pages die.
    @Published private(set) var ledgerEntries: [LedgerEntry] = []

    /// A refusal or status line the window shows briefly ("the window
    /// holds 9 pages…"). Refuse-don't-evict means the app says so.
    @Published var notice: String?

    /// True while the page holds the keyboard — drives the ember
    /// border. Set by the controller from window key status.
    @Published var holdsKeys = false

    /// The tab currently being drag-reordered, if any.
    @Published var draggingTab: UInt64?

    /// Whether the window floats above other apps' windows
    /// (`.statusBar` level) or behaves like a normal window others can
    /// cover (`.normal`). Persisted; the controller follows it.
    @Published var floatsOnTop: Bool {
        didSet { UserDefaults.standard.set(floatsOnTop, forKey: Self.floatsKey) }
    }
    private static let floatsKey = "floatsOnTop"

    /// The live editor view, so ⌥Space can hand it the keyboard.
    /// Weak and non-published: view plumbing, not state.
    weak var activeEditor: NSTextView?

    /// Set by the app delegate; Esc routes here when no editor holds
    /// the keys (the controller re-keys the frontmost app's window).
    var onHandBackKeys: (() -> Void)?

    private let client = CompanionClient()

    /// Each live page's document, shell-side: the ink is ordinary text
    /// in an `NSTextStorage`; chips appear as attachment characters
    /// carrying only ids and excerpts. Pruned when pages die.
    private var storages: [UInt64: NSTextStorage] = [:]

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var eventTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?

    init() {
        // Unset → float on top, matching the original behavior.
        floatsOnTop = UserDefaults.standard.object(forKey: Self.floatsKey) as? Bool ?? true
        // A fresh sheet awaits: the window never opens onto nothing.
        if client.sheets().isEmpty {
            _ = client.newSheet()
        }
        refresh()
        selection = sheets.first?.id
    }

    deinit {
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    // MARK: State

    var selectedSheet: SheetSummary? {
        sheets.first { $0.id == selection }
    }

    func refresh() {
        sheets = client.sheets()
        let live = Set(sheets.map(\.id))
        // A dead page's ink lives on only in the ledger; drop the
        // editor-side document.
        storages = storages.filter { live.contains($0.key) }
        if let current = selection, !live.contains(current) {
            selection = sheets.first?.id
        }
        if selection == nil { selection = sheets.first?.id }
        ledgerEntries = client.ledger()
        armEventTimer()
    }

    /// The page's document, created on first use.
    func storage(for id: UInt64) -> NSTextStorage {
        if let existing = storages[id] { return existing }
        let created = NSTextStorage()
        storages[id] = created
        return created
    }

    // MARK: Navigation — the keyboard map

    func select(_ id: UInt64) {
        showingLedger = false
        selection = id
    }

    /// ⌘1–⌘9: jump by visible tab order.
    func select(index: Int) {
        guard sheets.indices.contains(index) else { return }
        select(sheets[index].id)
    }

    /// ⌥⌘← / ⌥⌘→.
    func step(_ delta: Int) {
        guard !sheets.isEmpty else { return }
        if showingLedger { showingLedger = false }
        let current = sheets.firstIndex { $0.id == selection } ?? 0
        let next = min(max(current + delta, 0), sheets.count - 1)
        selection = sheets[next].id
    }

    /// ⌘0: the ledger.
    func showLedger() {
        ledgerEntries = client.ledger()
        showingLedger = true
    }

    /// Esc: leave the ledger if it is showing; otherwise hand the
    /// keyboard back.
    func escape() {
        if showingLedger {
            showingLedger = false
        } else {
            onHandBackKeys?()
        }
    }

    // MARK: Pages

    /// A new page (⌥⌘N or the + tab). At the cap the app declines and
    /// says so.
    func newPage() {
        notice = nil
        let created = client.newSheet()
        if created == 0 {
            notice = "the window holds 9 pages — let one expire, or close one"
        }
        refresh()
        if created != 0 { select(created) }
    }

    /// Close the page; it rests in the ledger. Closing also clears any
    /// standing refusal — the cap condition it named may be resolved.
    func close(_ id: UInt64) {
        notice = nil
        _ = client.closeSheet(id: id)
        refresh()
    }

    /// Drag-to-reorder: move `id` to `index` in visible order; the
    /// ⌘-number map follows.
    func move(_ id: UInt64, to index: Int) {
        _ = client.moveSheet(id: id, to: UInt64(max(0, index)))
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

    // MARK: Sealing — called by the editor, which places the chip

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself and
    /// the content lands as an opaque chip. Consent is the gesture.
    func sealPasteboard() -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        let chip = client.sealFromPasteboard(sheet: sheet)
        if chip == nil { notice = "nothing to seal" }
        return chip
    }

    /// Drop-to-seal: the core reads the drag pasteboard itself; the
    /// dropped bytes never transit this process.
    func sealDrag() -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        let chip = client.sealFromDrag(sheet: sheet)
        if chip == nil { notice = "nothing to seal" }
        return chip
    }

    /// ⌘↩: seal visible ink the editor already holds. The editor
    /// deletes its copy the moment this returns.
    func sealText(_ text: String) -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        return client.sealText(sheet: sheet, text)
    }

    /// Copy a chip back out — the core writes the pasteboard itself,
    /// marked transient + concealed; non-consuming.
    func copyOutChip(_ id: UInt64) {
        _ = client.copyOutChip(id: id)
    }

    /// Mirror the page's document to the core (tab titles, the ledger,
    /// promotion) — and authoritative for chip liveness: a chip the
    /// snapshot omits was deleted in the editor and is zeroized there.
    func syncDocument(sheet: UInt64, runs: [DocumentRun]) {
        let objects: [[String: Any]] = runs.map {
            switch $0 {
            case .ink(let text): ["ink": text]
            case .chip(let id): ["chip": id]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let accepted = client.syncDocument(sheet: sheet, json: json)
        assert(accepted, "core rejected a document snapshot")
        refresh()
    }

    // MARK: Timers

    /// The window became visible: start the 1 Hz countdown redraw.
    func startRedraw() {
        guard redrawTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sheets = self?.client.sheets() ?? [] }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// The window is hidden: stop redrawing. The armed event timer is
    /// the only remaining wakeup.
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
