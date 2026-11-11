import CompanionKit
import Foundation

/// Explicit presentation requests (ADR-0059).
enum ActivationReason: Equatable, Sendable {
    case launchActivation
    case reopen
    case modalReturn
    case cancelledQuit
    case hotkey
    case statusItem
    case cardClick
    case sideTabClick
    case openEditorPresentation
    case showAmbientPresentation
}

enum ActivationRoute: Equatable, Sendable {
    case openEditorWindow(BackdropRaise)
    case raisePanel(BackdropRaise)
    case summonPanel
    case showAmbientPanel
    case hideApp
    case noop
}

struct ActivationContext: Equatable, Sendable {
    var ambientPanelEnabled: Bool
    var owner: PresentationOwner
    var claimedByAnotherWindow: Bool
    /// The editor window exists, on screen or in the Dock.
    var editorWindowOpen = false
    var editorWindowKey = false
    var appActive = false
    /// A visible ordinary window of ours, companions included (ADR-0063).
    var visibleOrdinaryWindow = false
    var cardRaised = false
    var modalUp = false
}

enum ActivationRouter {
    static func defersForActivation(route: ActivationRoute, appActive: Bool) -> Bool {
        guard case .openEditorWindow = route else { return false }
        return !appActive
    }

    static func routeForActivation(
        pendingSummon: ActivationRoute?, context: ActivationContext
    ) -> ActivationRoute {
        if context.claimedByAnotherWindow { return .noop }
        if let pendingSummon { return pendingSummon }
        if context.modalUp || context.visibleOrdinaryWindow || context.cardRaised { return .noop }
        return .openEditorWindow(.activation)
    }

    static func decide(_ reason: ActivationReason, in context: ActivationContext) -> ActivationRoute {
        switch reason {
        case .openEditorPresentation:
            return .openEditorWindow(.activation)
        case .showAmbientPresentation:
            return context.ambientPanelEnabled ? .showAmbientPanel : .noop
        case .launchActivation:
            return .openEditorWindow(.summon)
        case .reopen:
            return .openEditorWindow(.activation)
        case .modalReturn, .cancelledQuit:
            switch context.owner {
            case .editorWindow: return .openEditorWindow(.activation)
            case .panel: return .raisePanel(.activation)
            }
        case .hotkey, .statusItem:
            if context.editorWindowOpen {
                return context.editorWindowKey && context.appActive
                    ? .hideApp : .openEditorWindow(.activation)
            }
            return context.ambientPanelEnabled ? .summonPanel : .openEditorWindow(.activation)
        case .cardClick:
            return .summonPanel
        case .sideTabClick:
            return context.ambientPanelEnabled ? .summonPanel : .noop
        }
    }
}
