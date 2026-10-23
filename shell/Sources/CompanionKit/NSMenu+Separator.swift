import AppKit

extension NSMenu {
    /// A separator ahead of the next group, unless the menu is empty or
    /// already ends in one.
    func addSeparatorIfNeeded() {
        if let last = items.last, !last.isSeparatorItem {
            addItem(.separator())
        }
    }
}
