import AppKit

/// AppKit's offers over a page's, a note's and a sealed name's text that read the
/// selection where no gate sees it (Law 0001, the export, print, share row).
@MainActor
enum TextOffers {
    /// Takes AppKit's Share… out of a text menu, and the separator it leaves doubled.
    static func removeShare(from menu: NSMenu) {
        while let index = menu.items.firstIndex(where: isShare) {
            menu.removeItem(at: index)
            let items = menu.items
            if index > 0, index < items.count,
               items[index].isSeparatorItem, items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
        }
    }

    /// AppKit's Share… carries its picker, already holding the selection, on the item.
    static func isShare(_ item: NSMenuItem) -> Bool {
        item.representedObject is NSSharingServicePicker
            || item.action == Selector(("_performStandardShareMenuItem:"))
    }

    /// Writing Tools on `textView`, which a file keeps and a page, note or name refuses.
    static func offerWritingTools(_ offers: Bool, on textView: NSTextView) {
        guard #available(macOS 15.0, *) else { return }
        textView.writingToolsBehavior = offers ? .default : .none
    }
}
