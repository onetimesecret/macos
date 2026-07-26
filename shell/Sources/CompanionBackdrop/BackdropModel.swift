import AppKit
import CompanionKit
import Foundation

/// The backdrop's own state: the stance the surface is in and where the
/// card sits within the pane. The pages themselves, with their ink,
/// chips, clocks, ledger and exit ramp, belong to the shared
/// `PageModel`, which is the same behaviour the panel shows; what this
/// type adds is the posture that behaviour is shown in.
///
/// It follows the panel's frugality contract where the form factor
/// allows, expiry being *scheduled* by the shared model at the core's
/// next event, and departs where it must: the surface is always on
/// screen, so the countdown redraw never stops; instead it coarsens to
/// one repaint every 30 s while resting (`BackdropStance.tickInterval`).
@MainActor
final class BackdropModel: ObservableObject {
    /// The surface's posture. The window controller follows this; the
    /// view styles by it.
    @Published private(set) var stance: BackdropStance = .resting

    /// The card's place and measure within the pane, clamped and
    /// persisted. The window controller reports pane sizes; the views
    /// read this and propose changes through `setGeometry(_:)`.
    @Published private(set) var geometry: BackdropGeometry

    /// The pages, their clocks, and everything done to them. Shared
    /// with the panel; scoped to this form factor's own Keychain
    /// service and state file by `FormFactor.backdrop`.
    let pages: PageModel

    /// Whether the resting card floats above other windows (pinned) or
    /// lies at the desktop behind them (the default, the form factor's
    /// native posture). The pin changes altitude and nothing else: a
    /// pinned rest still ignores the mouse and refuses the keyboard,
    /// which is what makes it safe to read beside while writing in
    /// another window. Persisted; the window controller follows it.
    /// The panel's `floatsOnTop` is deliberately not reused: that bool
    /// levels a normal window, this one levels a stance.
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: Self.pinnedKey) }
    }
    private static let pinnedKey = "restingPinned"

    /// Where the surface's own settings (the card's geometry, the pin)
    /// rest between runs, injectable so tests can point at a throwaway
    /// domain.
    private let defaults: UserDefaults

    /// The usable region the controller last reported, in the pane's
    /// own top-leading coordinates: the screen minus the menu bar and
    /// Dock strips, which a floating card cannot outrank. Until the
    /// first fit arrives, an effectively boundless pane means clamping
    /// enforces only the absolute bounds, never a spurious collapse to
    /// zero. The views read this to clamp their live previews by the
    /// same rule that will judge the commit.
    private(set) var pane = CGRect(
        x: 0, y: 0,
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private var started = false

    init(defaults: UserDefaults = FormFactor.settingsDefaults) {
        self.defaults = defaults
        geometry = BackdropGeometry.load(from: defaults)
        pinned = defaults.bool(forKey: Self.pinnedKey)
        pages = PageModel(formFactor: .backdrop, defaults: defaults)
    }

    /// True while the surface holds the keyboard, set by the window
    /// controller from key status and kept on the shared model because
    /// the editor's focus rules read it there. Raised and keyed are
    /// distinct facts: the user can ⌘Tab away to work beside a raised
    /// card.
    var holdsKeys: Bool {
        get { pages.holdsKeys }
        set { pages.holdsKeys = newValue }
    }

    /// Launch: open yesterday's pages, conjure one if there were none,
    /// and start the clocks.
    ///
    /// The panel defers its restore to the first reveal so that
    /// launching at login never raises a Keychain prompt for a window
    /// nobody asked to see (ADR-0004). This surface has no such moment
    /// to defer to: it is on screen from launch, and a resting card
    /// showing an empty page it does not actually hold would be a lie
    /// told at exactly the glance the form factor exists to serve.
    /// Launch and reveal are one act here, so the restore rides it.
    func start() {
        guard !started else { return }
        started = true
        pages.loadStateIfNeeded()
        pages.startRedraw(interval: stance.tickInterval)
    }

    /// Quit: seal the pages into the state file. Returns true when the
    /// file is settled, written or deliberately left alone; false means
    /// the save was attempted and refused.
    @discardableResult
    func saveState() -> Bool {
        pages.saveState()
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
        pages.startRedraw(interval: stance.tickInterval)
        // Each raise looks at the board once, never a poll: coming
        // forward is the moment the offer is worth making (ADR-0007
        // Amendment 1), and it is the same moment the panel picks.
        pages.refreshPasteboardOffer()
    }

    /// Esc, a click outside the card, or a summon from a keyed
    /// surface: back behind everything.
    func rest() {
        stance = .resting
        pages.startRedraw(interval: stance.tickInterval)
        // The offer is a summon-time thing; a resting card makes no
        // offers, and one standing from the last raise would be stale
        // by the next.
        pages.withdrawPasteboardOffer()
    }

    // MARK: Geometry

    /// A drag or resize settled: clamp the proposal to the known pane,
    /// persist, publish.
    func setGeometry(_ proposed: BackdropGeometry) {
        applyGeometry(proposed.clamped(to: pane))
    }

    /// The Settings escape hatch: back to the layout the card shipped
    /// with, still clamped in case the current display is smaller than
    /// the default assumes.
    func resetGeometry() {
        applyGeometry(BackdropGeometry.default.clamped(to: pane))
    }

    /// The controller re-fit the pane: a display disconnect or a
    /// resolution change must pull a now-stranded card back within
    /// reach of the new pane.
    func reclamp(pane: CGRect) {
        self.pane = pane
        applyGeometry(geometry.clamped(to: pane))
    }

    /// Double-click the header: the card takes the pane's full working
    /// height, and a second double-click returns it. The zoom verb
    /// every macOS window has, in the one dimension a card can spend.
    /// The restored geometry is remembered rather than recomputed, so
    /// the return lands exactly where the card was. Working height,
    /// not screen height: the pane starts below the menu bar, so the
    /// zoomed header stays where a double-click can still reach it to
    /// come back down.
    func toggleZoom() {
        if let restored = zoomRestore {
            zoomRestore = nil
            applyGeometry(restored.clamped(to: pane))
            return
        }
        zoomRestore = geometry
        var zoomed = geometry
        zoomed.origin.y = pane.minY
        zoomed.height = pane.height
        applyGeometry(zoomed.clamped(to: pane))
    }

    /// The geometry a zoom is holding for its return trip, if the card
    /// is zoomed right now.
    private var zoomRestore: BackdropGeometry?

    /// Persist and publish, but only a real change: the screen
    /// observer can fire in bursts, and an unchanged geometry should
    /// cost neither a repaint nor a defaults write. A geometry the user
    /// moved themselves ends the zoom's claim on a return trip.
    private func applyGeometry(_ new: BackdropGeometry) {
        guard new != geometry else { return }
        geometry = new
        new.save(to: defaults)
    }

    /// A drag or resize by hand retires the zoom: the card is where the
    /// user just put it, and a later double-click should zoom from
    /// there rather than snap back to a place they have left behind.
    func endZoom() {
        zoomRestore = nil
    }
}
