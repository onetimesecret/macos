import AppKit
import SwiftUI

/// The page: a little text file of **ink** (visible, editable text) and
/// **sealed chips** (opaque tokens whose bytes live core-side and never
/// render). The editor owns the live document; the core mirrors it via
/// `sync_document` for tab titles, the ledger, and chip liveness.
///
/// The gesture routes (docs/spec/04): ⌘V pastes plain ink like every
/// text editor on the machine; ⇧⌘V seals from the pasteboard; ⌘↩ seals
/// the selection or the current line; a drop from outside seals from
/// the drag pasteboard. Nothing is sealed without a gesture, and
/// nothing sealed ever renders.
struct InkEditorView: NSViewRepresentable {
    @ObservedObject var model: WindowModel
    let sheetID: UInt64

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 1 stack: chips render through
        // NSTextAttachmentCell, and swapping pages swaps the storage
        // under one layout manager (`replaceTextStorage`).
        // A fresh editor mount follows a teardown (a ledger round trip,
        // or the empty state after the last page died). Every cached
        // undo manager still holds operations bound to the torn-down
        // view; shed them before this view registers its own, so ⌘Z
        // rewrites live text instead of firing at a zombie (issue #23).
        model.discardUndoHistory()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        let storage = model.storage(for: sheetID)
        // The page's storage outlives any one editor instance — the
        // ledger and the empty state unmount the editor, even though
        // page↔page switches no longer do (ADR-0006). Detach layout
        // managers a torn-down editor left behind so exactly one
        // drives this storage.
        for stale in storage.layoutManagers {
            storage.removeLayoutManager(stale)
        }
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = InkTextView(frame: .zero, textContainer: container)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        // Rich text stays on so chip attachments survive editing; the
        // user-facing surface is still plain — ⌘V pastes plain text and
        // no ruler/font UI exists. Styling is ours alone (restyle()).
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.typingAttributes = [
            .font: InkStyle.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.currentSheet = sheetID
        context.coordinator.restyle()
        model.activeEditor = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = scroll.documentView as? InkTextView else { return }
        model.activeEditor = textView
        // Dead pages take their saved view state with them — the same
        // pruning `refresh()` applies to the storage cache.
        coordinator.pruneViewState(keeping: Set(model.sheets.map(\.id)))
        guard coordinator.currentSheet != sheetID else { return }
        // A page switch reaches this editor as data, not identity
        // (ADR-0006): the view — and with it first responder, and the
        // ember — persists, while the page's storage is swapped in
        // underneath. Caret and scroll are saved for the page on its
        // way out and restored for the one coming in; undo history
        // follows `currentSheet` through the delegate's per-page
        // manager and needs no hand-off here.
        // An in-progress IME composition is anchored to the outgoing
        // page's offsets. The dropped `.id(selection)` used to discard
        // it by tearing the view down; the persistent view must do it by
        // hand, or the pending marked text commits into the incoming
        // page's storage — the wrong page — or leaves the input context
        // pointing at a stale range (ADR-0006 eject-trigger #3, issue
        // #23). Discard before the swap so nothing crosses the boundary.
        if textView.hasMarkedText() {
            textView.inputContext?.discardMarkedText()
            textView.unmarkText()
        }
        coordinator.saveViewState(textView: textView, scrollView: scroll)
        let incoming = model.storage(for: sheetID)
        // The one-layout-manager-per-storage invariant rests on this
        // path now; makeNSView's detach loop runs only at mount. The
        // incoming storage may still carry a layout manager some
        // torn-down editor (a ledger round trip) left behind — shed
        // those before wiring ours to it. `replaceTextStorage` then
        // moves this editor's layout manager off the outgoing storage,
        // leaving both sides with exactly the managers they should
        // have: one here, none on the page going to the background.
        for stale in incoming.layoutManagers where stale !== textView.layoutManager {
            incoming.removeLayoutManager(stale)
        }
        textView.layoutManager?.replaceTextStorage(incoming)
        coordinator.currentSheet = sheetID
        coordinator.restyle()
        coordinator.restoreViewState(textView: textView, scrollView: scroll, for: sheetID)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: WindowModel
        weak var textView: InkTextView?
        var currentSheet: UInt64?

        /// Caret and scroll are view state. With one editor serving
        /// every page (ADR-0006) they no longer die with a torn-down
        /// view — they must be carried per page by hand: saved before
        /// the storage swap takes the page away, restored after its
        /// return.
        private var savedCarets: [UInt64: NSRange] = [:]
        private var savedScrolls: [UInt64: NSPoint] = [:]

        init(model: WindowModel) {
            self.model = model
        }

        // MARK: Per-page view state (ADR-0006)

        /// Remember the outgoing page's caret and scroll before the
        /// swap. The pending typing group settles first, so half a
        /// word is not left open in a page that is going away.
        func saveViewState(textView: InkTextView, scrollView: NSScrollView) {
            guard let sheet = currentSheet else { return }
            textView.breakUndoCoalescing()
            savedCarets[sheet] = textView.selectedRange()
            savedScrolls[sheet] = scrollView.contentView.bounds.origin
        }

        /// Return the incoming page's caret and scroll after the swap.
        /// The caret is clamped — content can change while a page is
        /// in the background (a burn, a restore) — and lands
        /// synchronously, being character offsets that owe layout
        /// nothing. The scroll cannot: the layout manager re-lays the
        /// new storage out asynchronously, and a synchronous restore
        /// is clobbered by the pass that follows. One main-queue hop
        /// later the geometry is real — ADR-0005's timing discipline,
        /// applied to scrolling.
        func restoreViewState(textView: InkTextView, scrollView: NSScrollView, for sheet: UInt64) {
            let caret = Self.clamped(
                savedCarets[sheet] ?? NSRange(location: 0, length: 0),
                to: textView.textStorage?.length ?? 0
            )
            textView.setSelectedRange(caret)
            let offset = savedScrolls[sheet] ?? .zero
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView else { return }
                scrollView.contentView.scroll(to: offset)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Dead pages take their view state with them — the same
        /// pruning `refresh()` applies to the storage cache.
        func pruneViewState(keeping live: Set<UInt64>) {
            savedCarets = savedCarets.filter { live.contains($0.key) }
            savedScrolls = savedScrolls.filter { live.contains($0.key) }
        }

        /// A caret saved against yesterday's content may overhang
        /// today's. Clamp to what exists, so a shrunken page seats the
        /// caret at its end instead of out of bounds.
        nonisolated static func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(range.location, 0), length)
            let span = min(max(range.length, 0), length - location)
            return NSRange(location: location, length: span)
        }

        /// One undo history per page, from the model's cache: the text
        /// view asks its delegate on every undo touch, so history
        /// simply follows `currentSheet` across storage swaps — ⌘Z
        /// after a switch rewrites the page it was typed on, never a
        /// neighbour (ADR-0006).
        func undoManager(for view: NSTextView) -> UndoManager? {
            guard let sheet = currentSheet else { return nil }
            return model.undoManager(for: sheet)
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            restyle()
            pushSync()
        }

        /// Mirror the document to the core. Runs on every edit — the
        /// document is small by design (a staging area, not a corpus),
        /// and the mirror is what keeps chip liveness authoritative.
        func pushSync() {
            guard let sheet = currentSheet, let storage = textView?.textStorage else { return }
            model.syncDocument(sheet: sheet, runs: Self.runs(of: storage))
        }

        /// The document as runs, in order: contiguous ink between chips.
        static func runs(of storage: NSTextStorage) -> [DocumentRun] {
            var runs: [DocumentRun] = []
            let text = storage.string as NSString
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
                if let chip = value as? ChipAttachment {
                    runs.append(.chip(chip.info.chipId))
                } else if range.length > 0 {
                    runs.append(.ink(text.substring(with: range)))
                }
            }
            return runs
        }

        // MARK: The seal gestures

        /// ⇧⌘V: the core reads the pasteboard itself; the chip lands at
        /// the caret. This process never sees the pasted bytes.
        func sealedPaste() {
            guard let chip = model.sealPasteboard() else { return }
            insertChip(chip)
        }

        /// A drop from outside: the core reads the drag pasteboard
        /// itself while the session's data is still on it.
        func sealDrop(at characterIndex: Int) -> Bool {
            guard let textView else { return false }
            textView.setSelectedRange(NSRange(location: characterIndex, length: 0))
            guard let chip = model.sealDrag() else { return false }
            insertChip(chip)
            return true
        }

        /// ⌘↩: seal the selection, or the current line if it holds
        /// content. A line already holding a chip refuses with an
        /// explanation; an empty line does nothing (docs/spec/04).
        func sealSelectionOrLine() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            var range = textView.selectedRange()
            if range.length == 0 {
                range = text.lineRange(for: range)
                // Seal the line's content, not its terminator.
                while range.length > 0 {
                    let last = text.character(at: NSMaxRange(range) - 1)
                    guard last == 0x0A || last == 0x0D else { break }
                    range.length -= 1
                }
            }
            guard range.length > 0 else { return }
            if Self.containsChip(storage, in: range) {
                model.flash("already sealed — a chip has no plaintext to seal")
                return
            }
            let ink = text.substring(with: range)
            guard !ink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let chip = model.sealText(ink) else { return }
            // The ink is in core custody now: replace the shell's copy
            // with the chip and make sure undo cannot resurrect it —
            // undo never un-seals (doc 06 №5).
            if textView.shouldChangeText(in: range, replacementString: nil) {
                storage.replaceCharacters(in: range, with: Self.chipString(chip))
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            textView.undoManager?.removeAllActions()
        }

        static func containsChip(_ storage: NSTextStorage, in range: NSRange) -> Bool {
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value is ChipAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        /// Place a freshly sealed chip at the caret.
        private func insertChip(_ chip: ChipInfo) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: nil) {
                storage.replaceCharacters(in: range, with: Self.chipString(chip))
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            // ⇧⌘V undo would delete the chip (fine) — but a ⌘↩ in the
            // same group must never come back as plaintext; clearing
            // here keeps the rule uniform: sealing is not undoable.
            textView.undoManager?.removeAllActions()
        }

        static func chipString(_ chip: ChipInfo) -> NSAttributedString {
            NSAttributedString(attachment: ChipAttachment(info: chip))
        }

        // MARK: Chip actions — hover/click reveals actions, never content

        func textView(
            _ view: NSTextView,
            clickedOn cell: NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            guard let chipCell = cell as? ChipCell else { return }
            let chipID = chipCell.info.chipId
            let menu = NSMenu()
            let copy = NSMenuItem(
                title: "Copy out — stays sealed",
                action: #selector(copyOutChip(_:)),
                keyEquivalent: ""
            )
            copy.target = self
            copy.representedObject = chipID as NSNumber
            menu.addItem(copy)
            let promote = NSMenuItem(
                title: "Promote to one-time link…",
                action: #selector(promoteChip(_:)),
                keyEquivalent: ""
            )
            promote.target = self
            promote.representedObject = chipID as NSNumber
            menu.addItem(promote)
            let remove = NSMenuItem(
                title: "Remove chip",
                action: #selector(removeChip(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = charIndex as NSNumber
            menu.addItem(remove)
            menu.popUp(positioning: nil, at: NSPoint(x: cellFrame.minX, y: cellFrame.maxY), in: view)
        }

        @objc private func copyOutChip(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.uint64Value else { return }
            model.copyOutChip(id)
        }

        /// The chip's ↗: open the inline confirmation. The bytes stay
        /// core-side; promotion moves them core → client → network.
        @objc private func promoteChip(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.uint64Value else { return }
            model.beginPromotion(.chip(id))
        }

        @objc private func removeChip(_ sender: NSMenuItem) {
            guard let textView, let storage = textView.textStorage,
                  let index = (sender.representedObject as? NSNumber)?.intValue,
                  index < storage.length
            else { return }
            let range = NSRange(location: index, length: 1)
            if textView.shouldChangeText(in: range, replacementString: "") {
                storage.replaceCharacters(in: range, with: "")
                textView.didChangeText() // sync omits the chip → zeroized
            }
        }

        // MARK: Markdown — styled, never rewritten

        /// Display-only, markup-preserving (docs/spec/04): a heading
        /// line renders at heading weight with its `#`s dimmed in
        /// place. Attributes only; the bytes of the page never change.
        func restyle() {
            guard let storage = textView?.textStorage else { return }
            let text = storage.string as NSString
            storage.beginEditing()
            var location = 0
            while location < text.length {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                styleParagraph(paragraph, of: storage, text: text)
                if paragraph.length == 0 { break }
                location = NSMaxRange(paragraph)
            }
            storage.endEditing()
        }

        private func styleParagraph(_ range: NSRange, of storage: NSTextStorage, text: NSString) {
            guard range.length > 0 else { return }
            storage.addAttributes(
                [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor],
                range: range
            )
            let line = text.substring(with: range)
            guard let marker = InkStyle.headingMarker(of: line) else { return }
            storage.addAttribute(
                .font,
                value: InkStyle.headingFont(level: marker.level),
                range: range
            )
            // The `### ` stays on screen, dimmed, exactly where typed.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: range.location, length: marker.length)
            )
        }
    }
}

// MARK: - The text view

/// The page's text view: routes the seal gestures, keeps ⌘V plain,
/// hands Esc back, and seals external drops through the core's drag
/// route. Chips are atomic under the caret by construction — an
/// attachment is one character: arrows step over it, one ⌫ removes it
/// whole, selection cannot reach inside it.
final class InkTextView: NSTextView {
    weak var coordinator: InkEditorView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⇧⌘V — the sealed paste.
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            coordinator?.sealedPaste()
            return true
        }
        // ⌘↩ — seal the selection or the current line.
        if modifiers == .command, event.keyCode == 36 {
            coordinator?.sealSelectionOrLine()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘V behaves like every text editor on the machine — plain text,
    /// no surprises (docs/spec/04).
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Esc hands the keyboard back (docs/spec/04, the focus law).
    override func cancelOperation(_ sender: Any?) {
        coordinator?.model.escape()
    }

    // MARK: Drop-to-seal

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isExternalDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isExternalDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    /// Dragging content to a secrecy tool is already the "stage this"
    /// gesture: an external drop seals. The core reads the drag
    /// pasteboard itself — the dropped bytes never enter this process.
    /// Internal drags (moving ink within the page) stay ordinary text
    /// editing.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isExternalDrag(sender) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        return coordinator?.sealDrop(at: index) ?? false
    }

    private func isExternalDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView) !== self
    }
}

// MARK: - The chip, rendered

/// A sealed chip's place in the document: an attachment character
/// carrying only the chip's id and mechanical face. There is no
/// affordance — and no data — to reveal what it stands for.
final class ChipAttachment: NSTextAttachment {
    let info: ChipInfo

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = ChipCell(info: info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }
}

/// Draws the chip: `[ excerpt · size ]`, a quiet capsule of exactly the
/// mechanical excerpt the seal route returned — recognizable to the
/// person who pasted it, opaque to a stranger.
final class ChipCell: NSTextAttachmentCell {
    let info: ChipInfo

    private nonisolated static let padding = NSSize(width: 9, height: 3)

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }

    private nonisolated var label: NSAttributedString {
        NSAttributedString(
            string: "\(info.excerpt) · \(info.sizeLabel)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    override func cellSize() -> NSSize {
        let text = label.size()
        return NSSize(
            width: text.width.rounded(.up) + Self.padding.width * 2,
            height: text.height.rounded(.up) + Self.padding.height * 2
        )
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -(Self.padding.height + 2))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let capsule = NSBezierPath(
            roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5,
            yRadius: 5
        )
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        capsule.fill()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(
            x: cellFrame.minX + Self.padding.width,
            y: cellFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Type

/// The page's type ramp: monospaced ink; headings by weight and size,
/// their markup dimmed in place (docs/spec/04).
@MainActor
enum InkStyle {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        case 2: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        case 3: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        default: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        }
    }

    /// `### deploy friday` → (level 3, markerLength 4). Scope for rev C
    /// is headings only; inline emphasis is deliberately deferred.
    static func headingMarker(of line: String) -> (level: Int, length: Int)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard level >= 1, index < line.endIndex, line[index] == " " else { return nil }
        return (level, level + 1)
    }
}
