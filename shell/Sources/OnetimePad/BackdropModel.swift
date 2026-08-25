import AppKit
import CompanionKit
import Foundation

/// Why the card is coming forward.
///
/// The window cannot tell the difference (both end in a raised, keyed
/// surface at the front of the active Space) and what the card is
/// *showing* has to (issue #79).
///
/// A **summon** is the user naming this surface: ⌃⌥Space, the menu-bar
/// item, or a click on the resting card, which the card's own overlay
/// calls "the same deliberate act as any other summon". An
/// **activation** is the user naming the app, with the surface arriving
/// as a consequence: ⌘Tab, the app switcher, the Dock icon. Only a
/// summon takes the roll back to today, because somebody who ⌘Tabbed
/// away from a sentence in an older day came back to that sentence and
/// not to today (ADR-0020 item 13).
///
/// The Dock icon is filed as an activation, and it is the one judgement
/// call here. Clicked while the app is inactive it arrives as
/// `applicationDidBecomeActive` and while it is active as
/// `applicationShouldHandleReopen`; filing those two differently would
/// give one gesture two meanings, decided by a state the user cannot
/// see. So the boundary is drawn where it can be described: the anchor
/// rides the gestures that name the surface, never the ones that name
/// the app.
enum BackdropRaise {
    case summon
    case activation
}

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
final class BackdropModel: ObservableObject, QuitFlushable {
    /// The surface's posture. The window controller follows this; the
    /// view styles by it.
    @Published private(set) var stance: BackdropStance = .resting

    /// The card's place and measure within the pane, clamped and
    /// persisted. The window controller reports pane sizes; the views
    /// read this and propose changes through `setGeometry(_:)`.
    @Published private(set) var geometry: BackdropGeometry

    /// A drag or resize under the pointer right now, clamped but not
    /// yet settled or persisted. Since no stance that takes the mouse
    /// spans the pane, the window *is* the card in every manipulable
    /// posture, so live feedback has to move the window rather than
    /// redraw within a stationary one. Nil whenever nothing is in
    /// flight.
    @Published private(set) var inFlight: BackdropGeometry?

    /// Where the card is drawn right now: the in-flight proposal while
    /// the pointer is down, the settled geometry otherwise.
    var displayedGeometry: BackdropGeometry { inFlight ?? geometry }

    /// The pages, their clocks, and everything done to them. Shared
    /// with the panel; scoped to this form factor's own Keychain
    /// service and state file by `FormFactor.backdrop`.
    let pages: PageModel

    /// Whether the resting card floats above other windows (pinned) or
    /// lies at the desktop behind them (the default, the form factor's
    /// native posture). A pinned rest still refuses the keyboard, which
    /// is what makes it safe to read beside while writing in another
    /// window; the mouse it takes, because a floating card that let
    /// clicks fall through to the window beneath would be a trap, and
    /// a click on it means exactly one thing: raise. The window shrinks
    /// to the card there, so clicks beside it still land where they
    /// look. Persisted; the window controller follows it.
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

    /// The quit path's flush with its verdict: settled, refused, or
    /// settled but over a withheld licence with content still in the
    /// session (issue #49). The delegate's alert text hangs off the
    /// distinction, so it is carried rather than folded into a Bool.
    func saveStateForQuit() -> QuitSaveOutcome {
        pages.saveStateForQuit()
    }

    // MARK: Stance

    /// ⌃⌥Space and the menu-bar item: a summon first, a dismissal only
    /// from a fully summoned state. A raised card that lost the
    /// keyboard — the user clicked or ⌘Tabbed away to work beside it —
    /// summons the keys back rather than resting.
    func summon() {
        if Self.stanceAfterSummon(current: stance, holdsKeys: holdsKeys) == .raised {
            raise(.summon)
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
    ///
    /// Every caller says why it is raising, because one thing here is
    /// not the same on both routes: see `BackdropRaise`.
    func raise(_ reason: BackdropRaise) {
        stance = .raised
        pages.startRedraw(interval: stance.tickInterval)
        // Each raise looks at the board once, never a poll: coming
        // forward is the moment the offer is worth making (ADR-0007
        // Amendment 1), and it is the same moment the panel picks. Both
        // reasons take this: an offer is about what is on the board now,
        // and coming forward is when it is worth making however the user
        // got here.
        pages.refreshPasteboardOffer()
        // The days go back to today on a summon and not on a bare
        // activation (issue #79). Between summons the roll's scroll is
        // the reader's own, and a summon is where the pad goes back to
        // being furniture that presents the current day; a ⌘Tab return
        // re-keys the card without anybody having asked for it to move,
        // and moving the roll under a sentence being read is exactly
        // what the anchor is not for. A no-op with the mode off, where
        // there is one page in the clip and nothing to anchor.
        if Self.anchorsOnToday(raise: reason) { pages.anchorOnToday() }
    }

    /// Which raises take the roll back to today. Pure, so the boundary
    /// between a summon and an activation is an assertion rather than a
    /// comment, it is decided in one place, and the four call sites
    /// name their reason rather than each carrying a copy of the rule.
    nonisolated static func anchorsOnToday(raise reason: BackdropRaise) -> Bool {
        switch reason {
        case .summon: true
        case .activation: false
        }
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

    /// A drag or resize under the pointer: clamp by the same rule that
    /// will judge the commit, so the card never previews a place it
    /// will not be allowed to keep, and publish for the window to
    /// follow. Nothing is persisted until the pointer lifts.
    func proposeGeometry(_ proposed: BackdropGeometry) {
        inFlight = proposed.clamped(to: pane)
    }

    /// The gesture was abandoned (a rest mid-drag, an `onEnded` with no
    /// anchor to measure from): the card returns to where it settled
    /// last, never askew.
    func discardProposal() {
        guard inFlight != nil else { return }
        inFlight = nil
    }

    /// A drag or resize settled: clamp the proposal to the known pane,
    /// persist, publish. The proposal is cleared *after* the settled
    /// value lands, so the window is never framed from a stale
    /// geometry for the moment in between.
    func setGeometry(_ proposed: BackdropGeometry) {
        applyGeometry(proposed.clamped(to: pane))
        inFlight = nil
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
