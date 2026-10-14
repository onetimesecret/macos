import AppKit

/// The sealed fragment on a pasteboard (ADR-0047): the shell writes the
/// core's two representations and never reads the envelope.
extension SealedFragment {
    /// The private type as AppKit names it (ADR-0047 point 13).
    static var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(CompanionClient.sealedFragmentType)
    }

    /// Several selected stretches of ink as one plain text, by line.
    init(joining fragments: [SealedFragment]) {
        self.init(envelope: nil, plainText: fragments.map(\.plainText).joined(separator: "\n"))
    }

    /// One item holding the envelope under the private type beside the
    /// public text, or the text alone for ink. False when the board refused.
    @discardableResult
    func write(to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        if let envelope, !item.setData(envelope, forType: Self.pasteboardType) { return false }
        guard item.setString(plainText, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
