import AppKit

/// Where a sealed object's note stands over the page (Law 0001, ADR-0042
/// points 7 and 8), in the overlay's flipped space; pure so the rule is an assertion.
enum NotePopoverLayout {
    /// The popover's least width, ADR-0042 point 7's threshold: a block
    /// narrower than this puts the note across the card's content width.
    static let minimumWidth: CGFloat = 320
    static let height: CGFloat = 176
    /// The least height the note keeps when neither side of the block has room.
    static let minimumHeight: CGFloat = 96
    static let arrowHeight: CGFloat = 7
    static let arrowHalfWidth: CGFloat = 7
    static let cornerRadius: CGFloat = 10
    /// The margin the note keeps from the content area's edges when it spans it.
    static let edgeInset: CGFloat = 8

    struct Placement: Equatable {
        let frame: CGRect
        /// The arrow's centre in the popover's own space; nil when expanded.
        let arrowX: CGFloat?
        /// Whether the popover hangs below the block, its arrow on top.
        let below: Bool
    }

    /// Under the block at its measure, or across `content` when the block
    /// is narrower than `minimumWidth`; over all of `content` expanded.
    static func placement(
        block: CGRect, doorwayX: CGFloat, content: CGRect, expanded: Bool
    ) -> Placement {
        let span = content.insetBy(dx: edgeInset, dy: edgeInset)
        guard !expanded else { return Placement(frame: span, arrowX: nil, below: true) }
        let narrow = block.width < minimumWidth
        let x = narrow ? span.minX : block.minX
        let width = narrow ? span.width : block.width
        let wanted = height + arrowHeight
        let roomBelow = content.maxY - block.maxY
        let roomAbove = block.minY - content.minY
        let below = roomBelow >= wanted || roomBelow >= roomAbove
        let total = min(wanted, max(below ? roomBelow : roomAbove, minimumHeight))
        let inner = cornerRadius + arrowHalfWidth
        return Placement(
            frame: CGRect(x: x, y: below ? block.maxY : block.minY - total, width: width, height: total),
            arrowX: min(max(doorwayX - x, inner), max(inner, width - inner)),
            below: below
        )
    }

    /// The popover's outline: a rounded body with its arrow at `arrowX`.
    static func shape(in bounds: CGRect, placement: Placement) -> NSBezierPath {
        var body = bounds
        if placement.arrowX != nil {
            body.size.height -= arrowHeight
            if placement.below { body.origin.y += arrowHeight }
        }
        let path = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)
        guard let arrowX = placement.arrowX else { return path }
        let base = placement.below ? body.minY : body.maxY
        let tip = placement.below ? bounds.minY : bounds.maxY
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - arrowHalfWidth, y: base))
        arrow.line(to: NSPoint(x: arrowX, y: tip))
        arrow.line(to: NSPoint(x: arrowX + arrowHalfWidth, y: base))
        arrow.close()
        path.append(arrow)
        return path
    }
}

/// A transparent, flipped layer over the page's scroller that holds the
/// note; it takes no click of its own.
final class NoteOverlayView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The note's popover: its header, the writing surface and the arrows.
final class NotePopoverView: NSView {
    override var isFlipped: Bool { true }

    var placement = NotePopoverLayout.Placement(frame: .zero, arrowX: nil, below: true) {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    let glyph = NSImageView()
    let title = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    let expand = NSButton()
    let expandHint = NSTextField(labelWithString: "")

    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 22
    static let sideInset: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        glyph.contentTintColor = .secondaryLabelColor
        title.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        title.textColor = .secondaryLabelColor
        for label in [hint, expandHint] {
            label.font = NSFont.systemFont(ofSize: 9)
            label.textColor = .tertiaryLabelColor
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        expand.isBordered = false
        expand.refusesFirstResponder = true
        expand.imagePosition = .imageOnly
        expand.contentTintColor = .secondaryLabelColor
        for view in [glyph, title, hint, scroll, expand, expandHint] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the note's popover is never unarchived")
    }

    /// The body: the bounds less the arrow.
    var body: NSRect {
        var body = bounds
        guard placement.arrowX != nil else { return body }
        body.size.height -= NotePopoverLayout.arrowHeight
        if placement.below { body.origin.y += NotePopoverLayout.arrowHeight }
        return body
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NotePopoverLayout.shape(in: bounds.insetBy(dx: 0.5, dy: 0.5), placement: placement)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        let body = self.body
        let inset = Self.sideInset
        let header = NSRect(x: body.minX, y: body.minY, width: body.width, height: Self.headerHeight)
        glyph.frame = NSRect(x: header.minX + inset, y: header.midY - 6, width: 12, height: 12)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(
            x: header.maxX - inset - hint.frame.width, y: header.midY - hint.frame.height / 2)
        title.sizeToFit()
        title.frame = NSRect(
            x: glyph.frame.maxX + 6, y: header.midY - title.frame.height / 2,
            width: max(0, hint.frame.minX - glyph.frame.maxX - 12), height: title.frame.height)
        let footer = NSRect(
            x: body.minX, y: body.maxY - Self.footerHeight, width: body.width,
            height: Self.footerHeight)
        expand.frame = NSRect(x: footer.maxX - inset - 16, y: footer.midY - 8, width: 16, height: 16)
        expandHint.sizeToFit()
        expandHint.frame.origin = NSPoint(
            x: expand.frame.minX - 4 - expandHint.frame.width,
            y: footer.midY - expandHint.frame.height / 2)
        scroll.frame = NSRect(
            x: body.minX + inset - 4, y: header.maxY, width: body.width - (inset - 4) * 2,
            height: max(0, footer.minY - header.maxY))
    }
}

/// The note's writing surface: the page's face, the keymap's undo chords
/// on the note's own stack, plain paste, and ink only.
final class NoteTextView: NSTextView {
    weak var editor: SealedNoteEditor?
    /// The gesture behind the edit in flight, when it is not typing.
    var pendingIntent: EditorEditIntent?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let command = editor?.command(for: event)
        else { return super.performKeyEquivalent(with: event) }
        switch command {
        case .editorUndo, .editorRedo:
            editor?.step(back: command == .editorUndo)
            return true
        case .clipboardSeal, .clipboardSealSelection:
            // Sealed objects do not nest (ADR-0043 point 3); the page must not take it either.
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if editor?.command(for: event) == .noteToggleExpanded {
            editor?.toggleExpanded()
            return
        }
        super.keyDown(with: event)
    }

    /// Esc contracts an expanded note and closes one that is not.
    override func cancelOperation(_ sender: Any?) {
        editor?.escape()
    }

    @objc func undo(_ sender: Any?) {
        editor?.step(back: true)
    }

    @objc func redo(_ sender: Any?) {
        editor?.step(back: false)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)):
            let back = item.action == #selector(undo(_:))
            let verb = back ? "Undo" : "Redo"
            item.title = editor?.stepName(back: back).map { "\(verb) \($0)" } ?? verb
            return editor?.canStep(back: back) ?? false
        default:
            return super.validateMenuItem(item)
        }
    }

    override func paste(_ sender: Any?) {
        pendingIntent = .paste
        defer { pendingIntent = nil }
        pasteAsPlainText(sender)
    }

    override func cut(_ sender: Any?) {
        pendingIntent = .cut
        defer { pendingIntent = nil }
        super.cut(sender)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { editor?.keysMayHaveLeft() }
        return resigned
    }

    override func unmarkText() {
        super.unmarkText()
        editor?.sync()
    }
}

/// Opens, places, edits and closes one sealed object's note over the page;
/// its edits and steps go to the note's routes, keyed by chip (ADR-0043 point 4).
@MainActor
final class SealedNoteEditor: NSObject, NSTextViewDelegate {
    let model: PageModel
    weak var pageView: InkTextView?
    private(set) var chip: UInt64?
    private(set) var sheet: UInt64?
    private(set) var isExpanded = false
    let overlay = NoteOverlayView()
    let popover = NotePopoverView()
    let textView: NoteTextView
    /// The note's text as the core last took it.
    private var synced = ""
    private var selectionBefore: NSRange?
    private var restating = false
    // nonisolated(unsafe): deinit is nonisolated and the tokens are not Sendable;
    // every other touch is on the main actor.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    init(model: PageModel) {
        self.model = model
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = NoteTextView(frame: .zero, textContainer: container)
        super.init()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.editor = self
        popover.scroll.documentView = textView
        popover.expand.target = self
        popover.expand.action = #selector(expandClicked(_:))
        overlay.autoresizingMask = [.width, .height]
        overlay.addSubview(popover)
    }

    var isOpen: Bool { chip != nil }
    var holdsKeys: Bool { textView.window?.firstResponder === textView }

    /// Opens the note of the block at `index` on page `sheet` under the
    /// block, its text loaded and the keys in it.
    func open(chipAt index: Int, sheet: UInt64) {
        guard let pageView, let face = pageView.chipCell(at: index)?.info,
              let scroll = pageView.enclosingScrollView
        else { return }
        if isOpen { close(returningKeys: false) }
        chip = face.chipId
        self.sheet = sheet
        isExpanded = false
        popover.title.attributedStringValue = NSAttributedString(
            string: face.name.map { "NOTE · \($0)" } ?? "NOTE",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor, .kern: 1.15,
            ])
        restate()
        overlay.frame = scroll.bounds
        scroll.addSubview(overlay)
        watch(scroll)
        updateChrome()
        follow()
        pageView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Closes the note; its edits are already the core's.
    func close(returningKeys: Bool) {
        guard let chip, let sheet else { return }
        let gaveKeys = returningKeys && holdsKeys
        self.chip = nil
        self.sheet = nil
        isExpanded = false
        unwatch()
        overlay.removeFromSuperview()
        model.finishNoteEditingGroup(chip: chip)
        model.restateChipFace(chip, sheet: sheet)
        if gaveKeys, let pageView { pageView.window?.makeFirstResponder(pageView) }
    }

    /// Esc: an expanded note contracts, one that is not closes.
    func escape() {
        if isExpanded { toggleExpanded() } else { close(returningKeys: true) }
    }

    /// The arrows or ⇧Esc: the note grows to the card's content area or comes back.
    func toggleExpanded() {
        guard isOpen else { return }
        isExpanded.toggle()
        updateChrome()
        follow()
    }

    @objc private func expandClicked(_ sender: Any?) {
        toggleExpanded()
    }

    /// Stands the popover under its block, or over the content expanded;
    /// closes it when the object or its page has gone.
    func follow() {
        guard let chip, let pageView else { return }
        guard pageView.coordinator?.currentSheet == sheet,
              let index = pageView.chipIndex(ofChip: chip),
              let frame = pageView.chipFrame(at: index),
              let cell = pageView.chipCell(at: index),
              overlay.superview != nil
        else { return close(returningKeys: holdsKeys) }
        let layout = SealedBlockCell.contentLayout(in: frame)
        let doorway = cell.doorwayRect(in: frame)
            ?? NSRect(x: layout.metadataRight - 12, y: layout.metadataY, width: 0, height: 0)
        let placement = NotePopoverLayout.placement(
            block: overlay.convert(frame, from: pageView),
            doorwayX: overlay.convert(NSPoint(x: doorway.midX, y: doorway.midY), from: pageView).x,
            content: overlay.bounds,
            expanded: isExpanded
        )
        popover.frame = placement.frame
        popover.placement = placement
    }

    /// The note gave up the keys: a click elsewhere closes it, on the next turn.
    func keysMayHaveLeft() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen, !self.holdsKeys else { return }
            self.close(returningKeys: false)
        }
    }

    /// The keymap's editor command for `event`, if one is bound.
    func command(for event: NSEvent) -> CommandID? {
        model.keymap.bindings(in: .editor, dispatch: .editor)
            .first { $0.keystroke.matches(event: event) }?.command
    }

    // MARK: The note's own stack

    func step(back: Bool) {
        guard let chip else { return }
        let outcome = model.stepNote(chip: chip, back: back)
        guard outcome.applied else { return }
        restate()
        if let selection = outcome.selection {
            textView.setSelectedRange(InkEditorView.Coordinator.clamped(
                selection, to: (textView.string as NSString).length))
        }
        refreshDoorway()
    }

    func canStep(back: Bool) -> Bool {
        chip.map { model.canStepNote(chip: $0, back: back) } ?? false
    }

    func stepName(back: Bool) -> String? {
        chip.flatMap { model.noteStepName(chip: $0, back: back) }
    }

    // MARK: Editing

    /// Hands the core the one replace that turns its text into the view's.
    func sync() {
        guard let chip, !restating, !textView.hasMarkedText() else { return }
        let text = textView.string
        guard text != synced else { return }
        let ops = InkEditorView.Coordinator.minimalReplace(at: 0, old: synced, new: text)
        guard let json = DocumentEditOp.wireJSON(ops) else { return }
        let after = textView.selectedRange()
        let selection = EditorEditSelection(before: selectionBefore ?? after, after: after)
        selectionBefore = nil
        let intent = textView.pendingIntent ?? Self.intent(for: ops)
        if model.applyNoteOps(chip: chip, json: json, intent: intent, selection: selection) {
            synced = text
            refreshDoorway()
        } else {
            restate()
        }
    }

    nonisolated static func intent(for ops: [DocumentEditOp]) -> EditorEditIntent {
        let inserts = ops.contains { if case .ins = $0 { true } else { false } }
        let deletes = ops.contains { if case .del = $0 { true } else { false } }
        switch (inserts, deletes) {
        case (true, false): return .typing
        case (false, true): return .deletion
        default: return .replacement
        }
    }

    /// The view's text from the core's, with no edit crossing for it.
    private func restate() {
        guard let chip else { return }
        let text = model.noteText(chip: chip)
        restating = true
        textView.string = text
        textView.font = InkStyle.baseFont
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]
        restating = false
        synced = text
    }

    /// The block's doorway follows the note's first and last ink.
    private func refreshDoorway() {
        guard let chip, let sheet, let pageView, let index = pageView.chipIndex(ofChip: chip)
        else { return }
        let hasNote = !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard pageView.chipCell(at: index)?.info.hasNote != hasNote else { return }
        model.restateChipFace(chip, sheet: sheet)
        follow()
    }

    private func updateChrome() {
        popover.hint.stringValue = isExpanded ? "esc contracts" : "esc closes"
        popover.expand.image = NSImage(
            systemSymbolName: isExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: isExpanded ? "Contract note" : "Expand note")
        popover.expandHint.stringValue = model.keymap.hintKeystroke(for: .noteToggleExpanded)
            .map { $0.displaySymbol.replacingOccurrences(of: "⎋", with: "esc") } ?? ""
        popover.needsLayout = true
    }

    private func watch(_ scroll: NSScrollView) {
        unwatch()
        scroll.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView as NSView),
            (NSView.frameDidChangeNotification, scroll as NSView),
        ] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            })
        }
    }

    private func unwatch() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: NSTextViewDelegate

    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        if !restating, selectionBefore == nil { selectionBefore = textView.selectedRange() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        sync()
    }
}
