import AppKit

/// AppKit's offers over a page's, a note's and a sealed name's text that read the
/// selection where no gate sees it (Law 0001, the export, print, share row).
@MainActor
enum TextOffers {
    /// Takes out the items that hold or read the selection for another process from the
    /// menu's building on (Share…, Look Up, Translate, Speech, Spelling and Grammar, Search
    /// With, Writing Tools, a link's Open With), then folds the separators.
    static func removeSelectionReaders(from menu: NSMenu) {
        menu.items.filter {
            isShare($0) || isLookUpOrTranslate($0) || isSpeech($0) || isSpelling($0)
                || isWebSearch($0) || isWritingTools($0) || isOpenWith($0)
        }
        .forEach(menu.removeItem)
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousIsSeparator {
                menu.removeItem(item)
            } else {
                previousIsSeparator = item.isSeparatorItem
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    /// AppKit's Share… carries its picker, already holding the selection, on the item.
    static func isShare(_ item: NSMenuItem) -> Bool {
        item.representedObject is NSSharingServicePicker
            || item.action == Selector(("_performStandardShareMenuItem:"))
    }

    /// Look Up “…” and Translate “…”, Reveal items titled with the selection they hold.
    static func isLookUpOrTranslate(_ item: NSMenuItem) -> Bool {
        item.action.map(NSStringFromSelector)?.hasPrefix("_rvMenuItemAction") == true
    }

    /// The Speech submenu, whose Start Speaking reads the selection to the system's voice.
    static func isSpeech(_ item: NSMenuItem) -> Bool {
        item.submenu?.items.contains { $0.action == #selector(NSTextView.startSpeaking(_:)) } == true
    }

    /// Spelling and Grammar, and what AppKit heads the menu with over a misspelled word:
    /// the spell server's guesses, Provide Feedback, Ignore Spelling and Learn Spelling.
    static func isSpelling(_ item: NSMenuItem) -> Bool {
        if let action = item.action.map(NSStringFromSelector),
           spellingItems.contains(action) || action.hasPrefix("_invokeProofreadingFeedback")
        {
            return true
        }
        return item.submenu?.items.contains {
            $0.action == #selector(NSText.checkSpelling(_:))
                || $0.action == #selector(NSText.showGuessPanel(_:))
        } == true
    }

    private static let spellingItems: Set<String> = [
        "_changeSpellingFromMenu:", "_ignoreSpellingFromMenu:", "_learnSpellingFromMenu:",
    ]

    /// Takes out the Transformations AppKit adds past Make Upper Case, Make Lower Case and
    /// Capitalize (Convert to Full Width and its kin), which a page's rewrite does not carry.
    static func removeUncarriedTransformations(from menu: NSMenu) {
        for submenu in menu.items.compactMap(\.submenu)
        where submenu.items.contains(where: { $0.action == #selector(NSResponder.uppercaseWord(_:)) }) {
            submenu.items.filter { item in
                !item.isSeparatorItem && !carriedTransformations.contains { $0 == item.action }
            }
            .forEach(submenu.removeItem)
        }
    }

    private static let carriedTransformations = [
        #selector(NSResponder.uppercaseWord(_:)), #selector(NSResponder.lowercaseWord(_:)),
        #selector(NSResponder.capitalizeWord(_:)),
    ]

    /// Search With Google, which hands the selection to the browser's search.
    static func isWebSearch(_ item: NSMenuItem) -> Bool {
        item.action.map(NSStringFromSelector)?.hasPrefix("_searchWith") == true
    }

    /// Writing Tools' items, should AppKit add them where the view answers Writing Tools with none.
    static func isWritingTools(_ item: NSMenuItem) -> Bool {
        item.action == Selector(("showWritingTools:"))
    }

    /// A link's Open With, whose applications AppKit hands the URL to with no delegate asked.
    static func isOpenWith(_ item: NSMenuItem) -> Bool {
        item.identifier?.rawValue == "__NSTextViewContextSubmenuIdentifierOpenWith"
            || item.submenu?.items.contains {
                ($0.representedObject as? URL)?.pathExtension == "app"
            } == true
    }

    /// AppKit's Open Link over a link, which asks the delegate as a plain click does.
    static let openLinkAction = Selector(("_openLinkFromMenu:"))

    /// AppKit's Copy Link, which writes the link to the general pasteboard.
    static let copyLinkAction = Selector(("copyLink:"))

    /// Whether the spelling panel is up, whose Learn takes the word it shows to the spell
    /// server by `NSSpellChecker` itself, with no text view asked.
    static var spellingPanelShows: Bool {
        NSSpellChecker.sharedSpellCheckerExists && NSSpellChecker.shared.spellingPanel.isVisible
    }

    /// The readers no click gates, which a file keeps and a page, note or name refuses: Writing
    /// Tools, suggestions, predictions and data detectors, whose finds a later click hands out.
    static func offerUngatedReaders(_ offers: Bool, on textView: NSTextView) {
        if !offers { textView.isAutomaticDataDetectionEnabled = false }
        textView.isAutomaticTextCompletionEnabled = offers
        if #available(macOS 14.0, *) { textView.inlinePredictionType = offers ? .default : .no }
        guard #available(macOS 15.0, *) else { return }
        textView.writingToolsBehavior = offers ? .default : .none
    }
}

/// A text view whose AppKit routes that read its text out of the process ask first,
/// and whose text menu holds none that read it from the menu's building on (Law 0001).
class AskingTextView: NSTextView {
    /// Whether AppKit may read this view's text out now; every reader below asks it.
    var mayReadOut: Bool { true }

    /// Whether the text menu keeps the items that hold the selection, as a file's does.
    var keepsSelectionReaders: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        if !keepsSelectionReaders { TextOffers.removeSelectionReaders(from: menu) }
        return menu
    }

    /// Edit > Speech > Start Speaking reads the selection to the system's voice.
    override func startSpeaking(_ sender: Any?) {
        guard mayReadOut else { return }
        super.startSpeaking(sender)
    }

    /// A force click or a three finger tap looks up the word under the pointer.
    override func quickLook(with event: NSEvent) {
        guard mayReadOut else { return }
        super.quickLook(with: event)
    }

    /// Quick Look by key, which AppKit ends in a dictionary look up of the selection.
    override func quickLookPreviewItems(_ sender: Any?) {
        guard mayReadOut else { return }
        super.quickLookPreviewItems(sender)
    }

    /// Where AppKit's look up of this view's text shows its definition.
    override func showDefinition(for attrString: NSAttributedString?, at textBaselineOrigin: NSPoint) {
        guard mayReadOut else { return }
        super.showDefinition(for: attrString, at: textBaselineOrigin)
    }

    /// Where AppKit's look up of a range of this view's text shows its definition.
    override func showDefinition(
        for attrString: NSAttributedString?, range targetRange: NSRange,
        options: [NSView.DefinitionOptionKey: Any]?,
        baselineOriginProvider originProvider: ((NSRange) -> NSPoint)?
    ) {
        guard mayReadOut else { return }
        super.showDefinition(
            for: attrString, range: targetRange, options: options,
            baselineOriginProvider: originProvider)
    }

    /// Quick Look Attachments, which previews what the selection links to.
    override func toggleQuickLookPreviewPanel(_ sender: Any?) {
        guard mayReadOut else { return }
        super.toggleQuickLookPreviewPanel(sender)
    }

    /// ⌥Esc or F5, whose completions the spell server makes from the word at the caret.
    override func complete(_ sender: Any?) {
        guard mayReadOut else { return }
        super.complete(sender)
    }

    /// Copy Style, onto the font board every process reads.
    override func copyFont(_ sender: Any?) {
        guard mayReadOut else { return }
        super.copyFont(sender)
    }

    /// Copy Ruler, onto the ruler board every process reads.
    override func copyRuler(_ sender: Any?) {
        guard mayReadOut else { return }
        super.copyRuler(sender)
    }

    /// AppKit's share picker over the selection, refused where Share… is (Law 0001).
    override func orderFrontSharingServicePicker(_ sender: Any?) {
        guard keepsSelectionReaders else { return }
        super.orderFrontSharingServicePicker(sender)
    }

    /// The typing suggestions `TextOffers.offerUngatedReaders` turned off stay off.
    override func toggleAutomaticTextCompletion(_ sender: Any?) {
        guard keepsSelectionReaders else { return }
        super.toggleAutomaticTextCompletion(sender)
    }

    /// The data detectors `TextOffers.offerUngatedReaders` turned off stay off.
    override func toggleAutomaticDataDetection(_ sender: Any?) {
        guard keepsSelectionReaders else { return }
        super.toggleAutomaticDataDetection(sender)
    }

    /// Edit's Show Spelling and Grammar is unavailable where the panel is never shown.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSText.showGuessPanel(_:)), !keepsSelectionReaders { return false }
        return super.validateMenuItem(item)
    }

    // MARK: Spelling, grammar and text checking, which hand the text to the spell server

    /// Check Document Now, and the spelling panel's Find Next, read the text whole; with the
    /// panel up they would show a word of it there, which `showGuessPanel` refuses.
    override func checkSpelling(_ sender: Any?) {
        guard mayReadOut, keepsSelectionReaders || !TextOffers.spellingPanelShows else { return }
        super.checkSpelling(sender)
        // A hidden panel keeps the word for a later showing over a file; leave it none of ours.
        if !keepsSelectionReaders { NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: "") }
    }

    /// Show Spelling and Grammar, never over a page's, a note's or a name's text: a panel
    /// held open past the deadline gives its word to Learn, which asks nothing (Law 0001).
    override func showGuessPanel(_ sender: Any?) {
        guard keepsSelectionReaders, mayReadOut else { return }
        super.showGuessPanel(sender)
    }

    /// The Substitutions panel's Replace All.
    override func checkTextInDocument(_ sender: Any?) {
        guard mayReadOut else { return }
        super.checkTextInDocument(sender)
    }

    /// The Substitutions panel's Replace in Selection.
    override func checkTextInSelection(_ sender: Any?) {
        guard mayReadOut else { return }
        super.checkTextInSelection(sender)
    }

    /// Check Spelling While Typing, after which AppKit checks every edit.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        guard mayReadOut else { return }
        super.toggleContinuousSpellChecking(sender)
    }

    /// Check Grammar With Spelling, which sends whole sentences with each check.
    override func toggleGrammarChecking(_ sender: Any?) {
        guard mayReadOut else { return }
        super.toggleGrammarChecking(sender)
    }

    /// The spelling panel's Ignore, which hands the word to the spell server.
    override func ignoreSpelling(_ sender: Any?) {
        guard mayReadOut else { return }
        super.ignoreSpelling(sender)
    }

    /// Every check AppKit runs as the text changes (continuous spelling, text replacement,
    /// smart quotes and the rest) and the ones the actions above start come through here.
    override func checkText(
        in range: NSRange, types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:]
    ) {
        guard mayReadOut else { return }
        super.checkText(in: range, types: checkingTypes, options: options)
    }
}
