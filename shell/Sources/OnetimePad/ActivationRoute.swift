import CompanionKit
import Foundation

/// Explicit presentation requests (ADR-0061).
enum ActivationReason: Equatable, Sendable {
    case launchActivation
    case reopen
    case modalReturn
    case cancelledQuit
    case hotkey
    case statusItem
    case cardClick
    case openEditorPresentation
    case showAmbientPresentation
}

enum ActivationRoute: Equatable, Sendable {
    case openEditorWindow(BackdropRaise)
    case raisePanel(BackdropRaise)
    case summonPanel
    case showAmbientPanel
    case noop
}

struct ActivationContext: Equatable, Sendable {
    var ambientPanelEnabled: Bool
    var owner: PresentationOwner
    var claimedByAnotherWindow: Bool
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
        return pendingSummon ?? .noop
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
            return context.ambientPanelEnabled ? .summonPanel : .openEditorWindow(.activation)
        case .cardClick:
            return .summonPanel
        }
    }
}
