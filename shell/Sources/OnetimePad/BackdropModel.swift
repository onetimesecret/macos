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

    /// Whether a raised card that has lost the keyboard to another
    /// window still floats above other apps. The pin is a stronger
    /// promise (it lifts a resting card too, and shrinks the window
    /// to the card so a click beside it lands where it looks); this
    /// keeps the raised, keyless card visible while the person works
    /// beside it, and rests it the moment a click outside lands (the
    /// outside-click rule is unchanged). Off by default: the release
    /// posture is a card the app the person is working in can cover.
    /// Persisted; the window controller observes and re-applies the
    /// altitude when it flips.
    @Published var keepsAboveWhenInactive: Bool {
        didSet { defaults.set(keepsAboveWhenInactive, forKey: Self.keepsAboveKey) }
    }
    private static let keepsAboveKey = "keepsAboveWhenInactive"

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

    /// Whether the panel may ever own the page content. True in every
    /// shipping construction. False is ADR-0033's read only panel, which
    /// is granted nothing whether the editor window is open or closed,
    /// kept as one input to the rule so the policy can be proved
    /// against the model the app runs; nothing outside a test passes
    /// it.
    ///
    /// Two things stand between this and a shipped setting, both of
    /// them in this type and both the work of whoever ships it. The key
    /// fact is the owner's, so a raised card that never owns is never
    /// known to be keyed, and `summon()` never reads the hotkey as "put
    /// it away": Esc still rests the card and the hotkey only ever
    /// raises it. And `keyTurn` rests the panel on the editor window
    /// taking the keyboard from an owning panel, which under this
    /// policy is no panel at all, so a raised card stays raised beside
    /// an editor window the person has gone to type in. Both want the
    /// panel's own key status kept apart from the owner's, which the
    /// shipped rule has no use for, since a raised panel always owns.
    private let panelMayOwn: Bool

    init(
        defaults: UserDefaults = FormFactor.settingsDefaults,
        pages: PageModel? = nil,
        panelMayOwn: Bool = true
    ) {
        self.defaults = defaults
        self.panelMayOwn = panelMayOwn
        geometry = BackdropGeometry.load(from: defaults)
        pinned = defaults.bool(forKey: Self.pinnedKey)
        keepsAboveWhenInactive = defaults.bool(forKey: Self.keepsAboveKey)
        dockOpensEditorWindow = defaults.bool(forKey: Self.dockOpensEditorKey)
        // The pages seam is nil for every shipping construction, where
        // the model builds the form factor's own `PageModel`. A test
        // has to hand one in (built with `PageModel.Seams` that name a
        // throwaway state directory and an ephemeral core handle),
        // because a default one would touch the installed app's files
        // and Keychain — the PageModel init refuses that under a
        // runner and takes the process down.
        self.pages = pages ?? PageModel(formFactor: .backdrop, defaults: defaults)
        // The shared model starts with the panel owning, which is the
        // shipped rule's answer at launch and so moves nothing. Under
        // the never grant policy it is not the answer, and the panel's
        // root view must not find itself the owner for even one pass.
        // The owner alone: the redraw is `start()`'s to begin.
        self.pages.transferOwnership(
            to: PresentationOwner.resolve(
                panelRaised: false, editorWindowOpen: false, panelMayOwn: panelMayOwn
            )
        )
    }

    /// True while the window that owns the page content holds the
    /// keyboard. Kept on the shared model because the editor's focus
    /// rules read it there, and fed by both window controllers through
    /// `keyStatusChanged(of:keyed:)`. Raised and keyed are distinct
    /// facts: the user can ⌘Tab away to work beside a raised card.
    var holdsKeys: Bool { pages.holdsKeys }

    /// Launch: open yesterday's pages, conjure one if there were none,
    /// and start the clocks.
    ///
    /// The panel defers its restore to the first reveal so that
    /// launching at login never raises a Keychain prompt for a window
    /// nobody asked to see (ADR-0004). This surface has no such moment
    /// to defer to: it is on screen from launch, resting or raised, and
    /// a card showing an empty page it does not actually hold would be
    /// a lie told at exactly the glance the form factor exists to
    /// serve. Launch and reveal are one act here, so the restore rides
    /// it.
    func start() {
        guard !started else { return }
        started = true
        pages.loadStateIfNeeded()
        retime()
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
    /// session. The terminate policy uses the distinction directly.
    func saveStateForQuit() -> QuitSaveOutcome {
        pages.saveStateForQuit()
    }

    /// The cancelled quit's standing line, held by the shared model
    /// because the surface that shows it is the shared one.
    var quitAnywayOffered: Bool { pages.quitAnywayOffered }

    func offerQuitAnyway(after outcome: QuitSaveOutcome) {
        pages.offerQuitAnyway(after: outcome)
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
    ///
    /// A raise gives the panel the page content whether or not the
    /// editor window is open (ADR-0033), and nothing here refuses one.
    /// Which gestures reach this with the editor window open is the
    /// routes' question and not the raise's.
    func raise(_ reason: BackdropRaise) {
        // The owner before the stance. The stance's publication is what
        // the window controller acts on, and its ordering calls bring
        // key delegates of both windows back in here before it returns;
        // each of those is judged against an owner that has already
        // settled.
        panelRaised = true
        settleOwner()
        publish(.raised)
        // Each raise looks at the board once, never a poll: coming
        // forward is the moment the offer is worth making (ADR-0007
        // Amendment 1), and it is the same moment the panel picks. Both
        // reasons take this: an offer is about what is on the board now,
        // and coming forward is when it is worth making however the user
        // got here. The offer stands under the owner's page, so a panel
        // that was not granted the page makes none.
        if pages.owner == .panel { pages.refreshPasteboardOffer(from: .panel) }
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
    ///
    /// With the editor window open this is also where the page content
    /// goes back to it (ADR-0033), and the owner settles before the
    /// stance is published for `raise(_:)`'s reason: the rest hands the
    /// keyboard away from inside the publication, and the window that
    /// receives it has to find itself the owner already.
    func rest() {
        // The offer is a summon-time thing; a resting card makes no
        // offers, and one standing from the last raise would be stale
        // by the next. The panel's own offer only: under the never
        // grant policy a raised panel rests while the editor window
        // owns, and what stands under that window's page is not the
        // panel's to withdraw.
        if pages.owner == .panel { pages.withdrawPasteboardOffer() }
        panelRaised = false
        settleOwner()
        publish(.resting)
    }

    /// Esc with no ledger to leave, from whichever window the page is
    /// in (`PageModel.escape`). The backdrop's way of giving the
    /// keyboard back is to step behind everything again, so over a
    /// raised panel this is a rest. Over a resting one it is nothing:
    /// the key was pressed in the editor window, an ordinary window
    /// that keeps the keyboard until the person takes it elsewhere, and
    /// a rest published over a resting panel would send the window
    /// controller through its whole resting turn, reordering a card
    /// nobody touched.
    func handBackKeys() {
        guard panelRaised else { return }
        rest()
    }

    /// The posture the model has committed to, set before the stance is
    /// published. `stance` cannot serve: a `@Published` tells its
    /// subscribers on willSet, the window controller orders windows
    /// from inside that turn, and a key delegate arriving there reads a
    /// `stance` that still names the posture being left. The window
    /// controller keeps the same kind of record for the same reason
    /// (`BackdropAltitudeKeeper.committedStance`).
    private var panelRaised = false

    /// How many stance publications are on the stack right now. More
    /// than zero means a key event is arriving from inside the window
    /// controller's own ordering, mid transition, where a second stance
    /// change would nest inside the first and leave the two disagreeing
    /// about which came last.
    private var stancePublications = 0

    private func publish(_ new: BackdropStance) {
        stancePublications += 1
        defer { stancePublications -= 1 }
        stance = new
    }

    // MARK: Ownership (ADR-0033)

    /// Resolve who owns the live page content from the two facts that
    /// decide it and hand the answer to the shared model, then give the
    /// redraw the owner's cadence. Called at every event that moves
    /// either fact. A transfer to the window that already owns is
    /// nothing, so nobody asks first whether the answer changed.
    private func settleOwner() {
        pages.transferOwnership(
            to: PresentationOwner.resolve(
                panelRaised: panelRaised,
                editorWindowOpen: editorWindowOpen,
                panelMayOwn: panelMayOwn
            )
        )
        retime()
    }

    /// The countdown redraw, at the cadence of the window showing the
    /// countdowns. The panel coarsens to the resting glance's tick
    /// while it rests. The editor window is an ordinary window a person
    /// is looking at, and ticks by the second. An editor window that
    /// owns while closed is the never grant policy, where the card is
    /// the only thing on screen and the cadence is its posture's.
    private func retime() {
        let posture: BackdropStance = panelRaised ? .raised : .resting
        switch pages.owner {
        case .panel:
            pages.startRedraw(interval: posture.tickInterval, from: .panel)
        case .editorWindow where editorWindowOpen:
            pages.startRedraw(from: .editorWindow)
        case .editorWindow:
            pages.startRedraw(interval: posture.tickInterval, from: .editorWindow)
        }
    }

    /// What a key event from one of the two content windows does.
    enum KeyTurn: Equatable {
        /// The window that does not own gained or lost the keyboard,
        /// which says nothing about whether the page holds it.
        case ignored
        /// The owner's window: `holdsKeys` follows it, and nothing else
        /// moves. This is the whole of what Settings, About or a modal
        /// panel taking the keyboard does.
        case reports(Bool)
        /// The editor window took the keyboard while the panel owned,
        /// which is a raised panel: the panel rests, the page content
        /// goes to the editor window, and then its keys are reported.
        case restsPanel
    }

    /// The key event decision, pure. Ownership moves on exactly one key
    /// event, the other content window taking the keyboard, and only
    /// the editor window can do that to the panel: a resting panel
    /// refuses the keyboard, so it takes ownership by being raised and
    /// never by becoming key. Every loss of the keyboard, to anything,
    /// moves nothing.
    ///
    /// `midTransition` is a stance publication on the stack. The editor
    /// window can be handed the keyboard for a moment from inside the
    /// panel's own raise (the order out that lands the card on this
    /// Space), and resting the panel from there would nest a rest
    /// inside the raise that is about to make the panel key anyway.
    nonisolated static func keyTurn(
        surface: PresentationOwner, keyed: Bool,
        owner: PresentationOwner, midTransition: Bool
    ) -> KeyTurn {
        if surface == owner { return .reports(keyed) }
        if surface == .editorWindow, keyed, !midTransition { return .restsPanel }
        return .ignored
    }

    /// A content window gained or lost the keyboard. Both window
    /// controllers report here and neither writes `holdsKeys` itself.
    ///
    /// The owner read here is the committed one: `settleOwner` runs
    /// before any stance is published, so a delegate turn arriving from
    /// inside `apply(.resting)` finds the owner the rest settled on and
    /// never `stance`, which is halfway at that moment.
    func keyStatusChanged(of surface: PresentationOwner, keyed: Bool) {
        let turn = Self.keyTurn(
            surface: surface, keyed: keyed,
            owner: pages.owner, midTransition: stancePublications > 0
        )
        switch turn {
        case .ignored:
            break
        case .reports(let keyed):
            pages.reportKeys(keyed, from: surface)
        case .restsPanel:
            rest()
            // The rest gave the page content to the editor window,
            // unless the policy or a window closing under this call
            // said otherwise, in which case there is nothing of this
            // window's to report.
            if pages.owner == surface { pages.reportKeys(true, from: surface) }
        }
    }

    // MARK: The editor window

    /// True while the primary editor window is open: one of the two
    /// facts the owner is resolved from, and nothing more than a fact.
    /// It refuses no raise and no view draws by it; the surfaces read
    /// `pages.owner`. Deliberately not published, so that it cannot
    /// grow a subscriber that reads it halfway through a change.
    ///
    /// Three routes outside this type still ask it, and all three are
    /// B4's to replace (issue #200): the reopen
    /// (`applicationShouldHandleReopen`), the activation, which an open
    /// editor window claims as About and Settings do
    /// (`applicationDidBecomeActive`), and the rest's activation hand
    /// back (`BackdropWindowController.apply`). Open is all any of them
    /// knows. A window that is open and miniaturized answers as one the
    /// person can see, so the activation it claims brings nothing
    /// forward, and whichever rule replaces these has to ask about
    /// visibility as `takesKeysWithOwnership` already does.
    private(set) var editorWindowOpen = false

    /// Whether the Dock icon opens the editor window, where it would
    /// otherwise raise the card. Off by default, so a build carrying the
    /// spike behaves as it did before for anyone who has not asked for
    /// the window. It governs the entrance only: a window already open
    /// stays open when this goes off, and the next Dock click still
    /// brings it forward. Persisted beside the pin. This is the spike's
    /// own switch and not ADR-0033's ambient panel preference, which
    /// turns the panel off and belongs to B4.
    @Published var dockOpensEditorWindow: Bool {
        didSet { defaults.set(dockOpensEditorWindow, forKey: Self.dockOpensEditorKey) }
    }
    private static let dockOpensEditorKey = "dockOpensEditorWindow"

    /// What a reopen does, pure: the window when the person asked for
    /// it, and also when one is already up, since a reopen names the
    /// app and the app's window is the editor window (ADR-0033). B4
    /// owns the real routing.
    nonisolated static func reopenOpensEditorWindow(
        preference: Bool, windowOpen: Bool
    ) -> Bool {
        preference || windowOpen
    }

    /// The editor window is about to come up and take the keyboard,
    /// and when the editor window takes the keyboard a raised panel
    /// rests (ADR-0033). The fact goes first, so the rest is already
    /// judged with the window open: the page content goes to the editor
    /// window, and the controller does not hand the activation back
    /// under a window that is about to become key. A resting panel has
    /// no stance to change, and only the owner moves.
    ///
    /// Called before the window's content is built, which is the order
    /// of the hand off: the panel has let go of the page, its place
    /// kept, by the time the editor window's editor mounts.
    func editorWindowOpened() {
        editorWindowOpen = true
        if panelRaised { rest() } else { settleOwner() }
    }

    /// The editor window closed. With it closed the panel owns, resting
    /// or raised, whatever it was doing a moment ago. Under the never
    /// grant policy nothing moves, and the page is mounted nowhere.
    func editorWindowClosed() {
        editorWindowOpen = false
        settleOwner()
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
