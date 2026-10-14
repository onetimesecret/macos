import AppKit

/// The sealed fragment on a pasteboard (ADR-0047): the shell writes the
/// core's two representations and never reads the envelope.
extension SealedFragment {
    /// The private type as AppKit names it (ADR-0047 point 13).
    static var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(CompanionClient.sealedFragmentType)
    }

    /// The first item carrying the private type, the one a paste reads.
    static func item(on pasteboard: NSPasteboard) -> NSPasteboardItem? {
        pasteboard.pasteboardItems?.first { $0.types.contains(pasteboardType) }
    }

    /// Several selected stretches of ink as one plain text, by line.
    init(joining fragments: [SealedFragment]) {
        self.init(envelope: nil, plainText: fragments.map(\.plainText).joined(separator: "\n"))
    }

    /// The one item a copy writes and a drag carries: the envelope under the
    /// private type beside the public text, or the text alone for ink.
    func pasteboardItem() -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        if let envelope, !item.setData(envelope, forType: Self.pasteboardType) { return nil }
        guard item.setString(plainText, forType: .string) else { return nil }
        return item
    }

    /// The item alone on `pasteboard`. False when the board refused.
    @discardableResult
    func write(to pasteboard: NSPasteboard) -> Bool {
        guard let item = pasteboardItem() else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
