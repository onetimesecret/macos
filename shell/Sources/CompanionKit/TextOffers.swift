import AppKit

/// AppKit's offers over a page's, a note's and a sealed name's text that read the
/// selection where no gate sees it (Law 0001, the export, print, share row).
@MainActor
enum TextOffers {
    /// Takes out the items that hold or read the selection for another process from the
    /// menu's building on (Share…, Look Up, Translate, Speech, Spelling and Grammar), then
    /// folds the separators.
    static func removeSelectionReaders(from menu: NSMenu) {
        menu.items.filter {
            isShare($0) || isLookUpOrTranslate($0) || isSpeech($0) || isSpelling($0)
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

    /// Spelling and Grammar, and the guesses, Ignore Spelling and Learn Spelling AppKit
    /// heads the menu with over a misspelled word, which hand the word to the spell server.
    static func isSpelling(_ item: NSMenuItem) -> Bool {
        if let action = item.action.map(NSStringFromSelector), spellingItems.contains(action) {
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

    /// Writing Tools on `textView`, which a file keeps and a page, note or name refuses.
    static func offerWritingTools(_ offers: Bool, on textView: NSTextView) {
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

    // MARK: Spelling, grammar and text checking, which hand the text to the spell server

    /// Check Document Now, and the spelling panel's Find Next, read the text whole.
    override func checkSpelling(_ sender: Any?) {
        guard mayReadOut else { return }
        super.checkSpelling(sender)
    }

    /// Show Spelling and Grammar checks from the selection on as its panel opens.
    override func showGuessPanel(_ sender: Any?) {
        guard mayReadOut else { return }
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
