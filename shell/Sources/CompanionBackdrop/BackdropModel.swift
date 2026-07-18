import AppKit
import Foundation

/// The backdrop's view model: one page of visible ink, its clock, and
/// the stance the surface is in. It follows the panel's frugality
/// contract where the form factor allows — expiry is *scheduled* (one
/// timer at the core's next event, re-armed after it fires) — and
/// departs where it must: the surface is always on screen, so the
/// countdown redraw never stops; instead it coarsens to one repaint
/// every 30 s while resting (`BackdropStance.tickInterval`).
@MainActor
final class BackdropModel: ObservableObject {
    /// The surface's posture. The window controller follows this; the
    /// view styles by it.
    @Published private(set) var stance: BackdropStance = .resting

    /// The one page's non-secret face — title, countdown, gauge.
    @Published private(set) var sheet: BackdropSheetSummary?

    /// True while the surface holds the keyboard — set by the window
    /// controller from key status. Raised and keyed are distinct
    /// facts: the user can ⌘Tab away to work beside a raised card.
    /// Drives the ember border and the summon decision.
    @Published var holdsKeys = false

    /// The page's visible ink, the editor's binding. One-way mirror:
    /// the editor owns the text; `inkEdited` pushes snapshots to the
    /// core, which owns the title and the lifecycle.
    @Published var ink = ""

    /// The card's place and measure within the pane, clamped and
    /// persisted. The window controller reports pane sizes; the views
    /// read this and propose changes through `setGeometry(_:)`.
    @Published private(set) var geometry: BackdropGeometry

    private let core = BackdropCore()
    private var started = false

    /// The backdrop's own suite (ADR-0010: never CompanionApp's),
    /// injectable so tests can point at a throwaway domain.
    private let geometryDefaults: UserDefaults?

    /// The last pane size the controller reported. Until the first fit
    /// arrives, an effectively boundless pane means clamping enforces
    /// only the absolute bounds, never a spurious collapse to zero.
    private var paneSize = CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    init(
        geometryDefaults: UserDefaults? =
            UserDefaults(suiteName: BackdropGeometry.defaultsSuiteName)
    ) {
        self.geometryDefaults = geometryDefaults
        geometry = BackdropGeometry.load(from: geometryDefaults)
    }

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var eventTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?

    deinit {
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    /// Launch: conjure the page (no Keychain, no state file — the
    /// backdrop starts empty by design) and start the clocks.
    func start() {
        guard !started else { return }
        started = true
        ensureSheet()
        refresh()
        startRedraw()
    }

    // MARK: Stance

    /// ⌃⌥Space and the menu-bar item: a summon first, a dismissal only
    /// from a fully summoned state. A raised card that lost the
    /// keyboard — the user clicked or ⌘Tabbed away to work beside it —
    /// summons the keys back rather than resting.
    func summon() {
        if Self.stanceAfterSummon(current: stance, holdsKeys: holdsKeys) == .raised {
            raise()
        } else {
            rest()
        }
    }

    /// The summon decision, pure: resting always raises; raised
    /// without the keyboard re-keys (stays raised); only raised *and*
    /// holding the keyboard reads the gesture as "put it away".
    nonisolated static func stanceAfterSummon(
        current: BackdropStance, holdsKeys: Bool
    ) -> BackdropStance {
        switch current {
        case .resting: .raised
        case .raised: holdsKeys ? .resting : .raised
        }
    }

    /// Raise the surface for a moment of editing. Summoning by
    /// deliberate act is what entitles the window to the keyboard —
    /// the same law the panel lives by. Setting `.raised` over
    /// `.raised` is meaningful, not a no-op: the publisher emits on
    /// every set, and the controller answers by pulling the surface to
    /// the active Space and re-keying it — the re-summon path.
    func raise() {
        stance = .raised
        startRedraw()
    }

    /// Esc, a click outside the card, or a summon from a keyed
    /// surface: back behind everything.
    func rest() {
        stance = .resting
        startRedraw()
    }

    // MARK: Geometry

    /// A drag or resize settled: clamp the proposal to the known pane,
    /// persist, publish.
    func setGeometry(_ proposed: BackdropGeometry) {
        applyGeometry(proposed.clamped(to: paneSize))
    }

    /// The Settings escape hatch: back to the layout the card shipped
    /// with, still clamped in case the current display is smaller than
    /// the default assumes.
    func resetGeometry() {
        applyGeometry(BackdropGeometry.default.clamped(to: paneSize))
    }

    /// The controller re-fit the pane: a display disconnect or a
    /// resolution change must pull a now-stranded card back within
    /// reach of the new pane.
    func reclamp(paneSize: CGSize) {
        self.paneSize = paneSize
        applyGeometry(geometry.clamped(to: paneSize))
    }

    /// Persist and publish, but only a real change: the screen
    /// observer can fire in bursts, and an unchanged geometry should
    /// cost neither a repaint nor a defaults write.
    private func applyGeometry(_ new: BackdropGeometry) {
        guard new != geometry else { return }
        geometry = new
        new.save(to: geometryDefaults)
    }

    // MARK: The page

    /// The editor changed: mirror the ink to the core. A refused
    /// encoding (it will not happen for a string) skips the sync
    /// rather than mirror a wrongly emptied page.
    func inkEdited(_ text: String) {
        guard let id = sheet?.id, let json = BackdropCore.inkRunsJSON(text) else { return }
        _ = core.syncDocument(sheet: id, json: json)
        refreshSummary()
    }

    /// Click the countdown label: next rung, clock reset (docs/spec/04).
    func cycleRung() {
        guard let id = sheet?.id else { return }
        _ = core.cycleRung(sheet: id)
        refresh()
    }

    private func ensureSheet() {
        if core.sheets().isEmpty {
            _ = core.newSheet()
        }
    }

    private func refresh() {
        refreshSummary()
        armEventTimer()
    }

    private func refreshSummary() {
        sheet = core.sheets().first
    }

    // MARK: Timers

    /// The countdown repaint, at the stance's cadence. Restarted on
    /// every stance change so a raise tightens the tick and a rest
    /// relaxes it.
    private func startRedraw() {
        redrawTimer?.invalidate()
        let timer = Timer(timeInterval: stance.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSummary() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// Arm exactly one timer, at the core's next event. When it fires,
    /// settle the clock and re-arm. No event → no timer.
    private func armEventTimer() {
        eventTimer?.invalidate()
        eventTimer = nil
        let ms = core.nextEventMs()
        guard ms >= 0 else { return }
        let timer = Timer(
            timeInterval: max(0.05, Double(ms) / 1000.0),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.settleClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }

    /// The scheduled instant arrived: expire what is due. The backdrop
    /// keeps no ledger — an expired page is simply gone (zeroized
    /// core-side, silently, per docs/spec/03 §1), and a fresh empty
    /// page takes its place so the surface never shows nothing.
    private func settleClock() {
        _ = core.expireDue()
        if core.sheets().isEmpty {
            // The page died; the editor's mirror of its ink dies too.
            ink = ""
            _ = core.newSheet()
        }
        refresh()
    }
}
