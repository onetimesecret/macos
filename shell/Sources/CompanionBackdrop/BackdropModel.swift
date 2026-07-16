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

    /// The page's visible ink, the editor's binding. One-way mirror:
    /// the editor owns the text; `inkEdited` pushes snapshots to the
    /// core, which owns the title and the lifecycle.
    @Published var ink = ""

    private let core = BackdropCore()
    private var started = false

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

    func toggle() {
        if stance == .resting {
            raise()
        } else {
            rest()
        }
    }

    /// Summon the surface for a moment of editing (⌃⌥Space, or the
    /// menu-bar item). Summoning by deliberate act is what entitles the
    /// window to the keyboard — the same law the panel lives by.
    func raise() {
        stance = .raised
        startRedraw()
    }

    /// Esc, or the toggle again: back behind everything.
    func rest() {
        stance = .resting
        startRedraw()
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
