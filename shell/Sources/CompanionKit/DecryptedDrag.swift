import AppKit

/// The decrypted drag from a sealed block's handle (ADR-0045 point 5; Law 0001, decrypted drag row):
/// the session's source and its one item's data provider. The core writes the payload.
@MainActor
final class DecryptedDrag: NSObject, NSDraggingSource, NSPasteboardItemDataProvider {
    let chip: UInt64
    let type: NSPasteboard.PasteboardType
    private let provide: (NSPasteboard, NSPasteboardItem, NSPasteboard.PasteboardType) -> Bool

    /// The session ended with no operation, so no later ask is answered.
    private(set) var cancelled = false

    /// Runs once, when the session ends.
    var onEnd: (() -> Void)?

    #if DEBUG
    /// Every ask AppKit made of the provider, answered or not.
    private(set) var asks = 0
    #endif

    init(
        chip: UInt64, type: NSPasteboard.PasteboardType,
        provide: @escaping (NSPasteboard, NSPasteboardItem, NSPasteboard.PasteboardType) -> Bool
    ) {
        self.chip = chip
        self.type = type
        self.provide = provide
    }

    /// The type copy decrypted writes a chip's payload as; nil for a kind this build does not know.
    nonisolated static func pasteboardType(forKind kind: String) -> NSPasteboard.PasteboardType? {
        switch kind {
        case "text": .string
        case "image": .png
        default: nil
        }
    }

    /// A copy to another app, and nothing inside this one (Law 0001, decrypted drag row).
    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// The one item the session carries: a promise of the chip's own type.
    func pasteboardItem() -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        return item.setDataProvider(self, forTypes: [type]) ? item : nil
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        end(with: operation)
    }

    /// The session's end; one that dropped nowhere answers no later ask (Law 0001, decrypted drag row).
    func end(with operation: NSDragOperation) {
        if operation.isEmpty { cancelled = true }
        let ended = onEnd
        onEnd = nil
        ended?()
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // AppKit asks on the main thread; an ask from anywhere else is refused.
        guard Thread.isMainThread else { return }
        nonisolated(unsafe) let pasteboard = pasteboard
        nonisolated(unsafe) let item = item
        MainActor.assumeIsolated { answer(pasteboard, item: item, type: type) }
    }

    private func answer(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, type: NSPasteboard.PasteboardType
    ) {
        #if DEBUG
        asks += 1
        #endif
        guard !cancelled, type == self.type, let pasteboard else { return }
        _ = provide(pasteboard, item, type)
    }
}
