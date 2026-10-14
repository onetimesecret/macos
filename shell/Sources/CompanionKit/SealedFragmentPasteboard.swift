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

    /// The private type as every build names it, release and debug.
    static let everyBuildsType: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType(CompanionClient.releaseSealedFragmentType),
        NSPasteboard.PasteboardType(CompanionClient.debugSealedFragmentType),
    ]

    /// Whether an item on `pasteboard` carries any build's private type, a copy of this
    /// app's own even where this build cannot read its envelope.
    static func anyBuildsItem(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.pasteboardItems?.contains { !everyBuildsType.isDisjoint(with: $0.types) } ?? false
    }

    /// Several selected stretches of ink as one plain text, by line.
    init(joining fragments: [SealedFragment]) {
        self.init(envelope: nil, plainText: fragments.map(\.plainText).joined(separator: "\n"))
    }

    /// The one item a copy writes and a drag carries: the envelope under the
    /// private type beside the public text, or the text alone for ink.
    func pasteboardItem() -> NSPasteboardItem? {
        pasteboardItem(offering: [Self.pasteboardType, .string])
    }

    /// Plain text by the name a text view's requesters may still ask for it.
    static let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")

    /// That item narrowed to the types a requester such as a service asked
    /// for; nil when it asked for neither or a write was refused.
    func pasteboardItem(offering types: [NSPasteboard.PasteboardType]) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        if let envelope, types.contains(Self.pasteboardType),
           !item.setData(envelope, forType: Self.pasteboardType)
        { return nil }
        if types.contains(.string) || types.contains(Self.legacyStringType),
           !item.setString(plainText, forType: .string)
        { return nil }
        return item.types.isEmpty ? nil : item
    }

    /// The item alone on `pasteboard`. False when the board refused.
    @discardableResult
    func write(to pasteboard: NSPasteboard) -> Bool {
        guard let item = pasteboardItem() else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
