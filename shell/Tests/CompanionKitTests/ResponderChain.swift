import AppKit

@testable import CompanionKit

/// The first responder in `window`'s chain that answers `action`, which is
/// where a nil-targeted menu item lands; NSApp is nil in a bare xctest run.
@MainActor
func answerer(of action: Selector, in window: NSWindow) -> NSResponder? {
    var responder = window.firstResponder
    while let current = responder {
        if current.responds(to: action) { return current }
        responder = current.nextResponder
    }
    return nil
}

/// The Edit menu's actions a page's text view answers, by the selectors
/// the app's menu sends (ADR-0046).
@MainActor
let pageMenuActions = [
    #selector(EditStepResponder.undo(_:)), #selector(EditStepResponder.redo(_:)),
    #selector(SealResponder.sealSelectedContent(_:)),
    #selector(LanguageDetectionResponder.pasteWithoutDetection(_:)),
    #selector(LanguageDetectionResponder.detectCodeLanguage(_:)),
    #selector(LanguageDetectionResponder.chooseCodeLanguage(_:)),
]
