import AppKit

/// AppKit's offers over a page's, a note's and a sealed name's text that read the
/// selection where no gate sees it (Law 0001, the export, print, share row).
@MainActor
enum TextOffers {
    /// Takes out the items that hold or read the selection for another process from the
    /// menu's building on (Share…, Look Up, Translate, Speech), then folds the separators.
    static func removeSelectionReaders(from menu: NSMenu) {
        menu.items.filter { isShare($0) || isLookUpOrTranslate($0) || isSpeech($0) }
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

    /// Writing Tools on `textView`, which a file keeps and a page, note or name refuses.
    static func offerWritingTools(_ offers: Bool, on textView: NSTextView) {
        guard #available(macOS 15.0, *) else { return }
        textView.writingToolsBehavior = offers ? .default : .none
    }
}
