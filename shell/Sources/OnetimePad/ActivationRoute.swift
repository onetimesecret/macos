import CompanionKit
import Foundation

/// Why an activation arrived, filed by the gesture the user performed
/// rather than the AppKit callback that carried it.
///
/// ADR-0033 decides routing by route: how the person arrived, never by
/// last use. `ActivationReason` names the routes and the routing
/// function (`ActivationRoute.decide`) turns each one into the surface
/// to raise.
///
/// Three families sit under this:
///
/// - `.launchActivation`, `.lateActivation` and `.reopen` select the
///   editor window. They arrive through `applicationDidBecomeActive` and
///   `applicationShouldHandleReopen`, which the delegate turns into one
///   of the three by asking how long ago the app launched and whether
///   the app already had visible windows.
/// - `.modalReturn` and `.cancelledQuit` go back to whichever window
///   already owns the page.
/// - `.hotkey`, `.statusItem` and `.cardClick` are summons. With the
///   ambient panel on they select the panel; with it off, the two
///   application-level gestures (hotkey and status item) select the
///   editor window instead, and the card click cannot arrive because no
///   resting card is on screen.
///
/// A login launch never appears here. It arrives with no activation at
/// all, so the routing function is never asked, and nothing is opened.
/// `LaunchStanceTests` pins that by its absence.
enum ActivationReason: Equatable, Sendable {
    /// An activation inside `BackdropAppDelegate.launchWindow` of a
    /// launch the person performed from the Finder, the Dock, Spotlight
    /// or `open`. Selects the editor window with the launch raise, a
    /// summon anchored on today (`BackdropAppDelegate.launchRaise`).
    case launchActivation

    /// A later ⌘Tab or a Dock click on an inactive app. Selects the
    /// editor window; a raised panel is rested when the editor window
    /// takes the keyboard.
    case lateActivation

    /// A Dock click on the frontmost app, or `open -a` on a running
    /// app. Selects the editor window like the two activations; the
    /// distinction from `.lateActivation` is preserved because AppKit
    /// tells them apart and because the reopen alone runs while the app
    /// is already active.
    case reopen

    /// A modal open or save panel of ours returned. The route sends the
    /// activation back to whichever window owned the page content when
    /// the modal went up.
    case modalReturn

    /// The person opened the quit sheet and then cancelled. Same rule
    /// as `.modalReturn`: the surface the quit anyway line is under is
    /// the owner's.
    case cancelledQuit

    /// ⌃⌥Space, the global hotkey. A summon of the ambient panel with
    /// the preference on; with it off, selects the editor window.
    case hotkey

    /// The menu-bar item was left-clicked. Same rule as `.hotkey`.
    case statusItem

    /// The resting card was clicked. A summon of the ambient panel.
    /// Never arrives with the panel off, since no resting card is on
    /// screen to receive the click.
    case cardClick
}

/// The routing function's answer: which surface to bring forward, and
/// under which `BackdropRaise` when the panel is the answer.
///
/// `.openEditorWindow` covers "open it or bring the open one forward":
/// the wiring picks the right verb (`show()` deminiaturizes and orders
/// front). `.raisePanel` unconditionally raises the panel under the
/// named reason; the routes an activation callback answers use it, so
/// no summon toggles by surprise. `.summonPanel` is the deliberate
/// user gesture — hotkey, status item, resting card — that lets the
/// panel's re-summon/rest decision (`BackdropModel.summon`) run.
/// `.noop` is what the routing function says when the current callback
/// should do nothing: an activation another window claimed for itself.
enum ActivationRoute: Equatable, Sendable {
    case openEditorWindow(BackdropRaise)
    case raisePanel(BackdropRaise)
    case summonPanel
    case noop
}

/// The world the routing function reads. All facts, no controllers:
/// this is the seam the tests table-drive.
struct ActivationContext: Equatable, Sendable {
    /// Whether the primary editor window is open right now.
    var editorWindowOpen: Bool
    /// Whether the primary editor window can take the keyboard right
    /// now (open and on screen, so not in the Dock). The rest's
    /// activation hand back reads the same predicate
    /// (`BackdropModel.editorWindowCanTakeKeys`).
    var editorWindowCanTakeKeys: Bool
    /// The ambient panel preference. Off means no panel is shown; the
    /// application-level summon gestures pick the editor window
    /// instead.
    var ambientPanelEnabled: Bool
    /// The presentation owner right now, as `PageModel` last settled
    /// it. Read only by `.modalReturn` and `.cancelledQuit`.
    var owner: PresentationOwner
    /// True while an activation was requested by About or Settings for
    /// itself. Read only by the activation reasons.
    var claimedByAnotherWindow: Bool
}

/// Where each activation reason should route to. Pure and stateless,
/// so the routing table is one place to point at and one thing to
/// test.
///
/// `sinceLaunch` is passed for the caller's benefit: the delegate
/// receives one `applicationDidBecomeActive` and picks between
/// `.launchActivation` and `.lateActivation` by that fact. The
/// classifier is kept out of the routing function so the function
/// itself has one input per row.
enum ActivationRouter {
    /// The routing table. Every combination of `reason` and `context`
    /// resolves to one `ActivationRoute`.
    static func decide(
        _ reason: ActivationReason, in context: ActivationContext
    ) -> ActivationRoute {
        switch reason {
        case .launchActivation:
            // The launch's activation. Claimed by About or Settings
            // means the surface stays where the launch placed it,
            // resting, exactly as `activationRaises(claimedByAnotherWindow:)`
            // used to answer.
            if context.claimedByAnotherWindow { return .noop }
            // ADR-0033: a launch the person performed selects the
            // editor window, opening it when closed. Under the launch
            // raise, so the roll anchors on today.
            return .openEditorWindow(.summon)

        case .lateActivation:
            // ⌘Tab or a Dock click while inactive. About/Settings
            // still keep their claim.
            if context.claimedByAnotherWindow { return .noop }
            // The editor window is the answer whether open or closed:
            // open one is brought forward, closed one is opened. An
            // activation raise (not a summon), so the roll stays where
            // it was.
            return .openEditorWindow(.activation)

        case .reopen:
            // A Dock click on the frontmost app, or `open -a`. Same
            // answer as `.lateActivation`, and same raise: the person
            // named the app.
            if context.claimedByAnotherWindow { return .noop }
            return .openEditorWindow(.activation)

        case .modalReturn, .cancelledQuit:
            // Back to the owner (ADR-0033). The panel raise is an
            // activation: nobody named the surface.
            switch context.owner {
            case .editorWindow: return .openEditorWindow(.activation)
            case .panel: return .raisePanel(.activation)
            }

        case .hotkey, .statusItem:
            // A summon of the ambient panel, with the preference on.
            // The summon dispatch is `.summonPanel` (not a bare
            // raise), so `BackdropModel.summon`'s re-summon and rest
            // decision runs and the second hotkey over a keyed panel
            // still puts it away.
            //
            // With the preference off no panel is shown, and the
            // gesture selects the editor window instead — the same
            // route ⌘Tab takes, for the same reason: nothing else can
            // hold the keyboard.
            if context.ambientPanelEnabled { return .summonPanel }
            return .openEditorWindow(.activation)

        case .cardClick:
            // Only reachable with the ambient panel on. The card is
            // the panel resting, and its click is a summon of the
            // panel it is a face of.
            return .summonPanel
        }
    }

    /// The activation reason for the callback that carries every ⌘Tab
    /// and every real launch activation: an activation inside the
    /// launch window is filed as the launch itself, later ones as
    /// `.lateActivation`. Kept separate so the routing function has
    /// one input per row and this one fact — recency, not a counter —
    /// is decided in the place `LaunchStanceTests` already pins.
    static func activationReason(
        sinceLaunch: TimeInterval, launchWindow: TimeInterval
    ) -> ActivationReason {
        sinceLaunch < launchWindow ? .launchActivation : .lateActivation
    }
}
