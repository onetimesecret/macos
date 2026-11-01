import AppKit

/// A sealed object's name field from opening to ending (Law 0007), apart
/// from the AppKit field so a test drives the code the field runs.
@MainActor
struct ChipRename {
    private var field = TabRename.Field()
    /// The object whose name the field stands over, and its page; nil while shut.
    private(set) var chip: UInt64?
    private(set) var sheet: UInt64?
    private(set) var error: String?

    var draft: String { field.draft }
    var isOpen: Bool { chip != nil }
    var isRefusing: Bool { error != nil }

    /// Opens on the object's name, or on nothing when it has none; a field
    /// open over another object keeps that one's name.
    mutating func open(chip: UInt64, sheet: UInt64, name: String?, in model: PageModel) {
        guard self.chip != chip else { return }
        keep(in: model)
        field.open(on: name ?? "")
        self.chip = chip
        self.sheet = sheet
    }

    /// Recheck a refused draft as it changes.
    mutating func edit(_ draft: String, in model: PageModel) {
        guard isOpen else { return }
        field.draft = draft
        guard error != nil else { return }
        if let refused = CompanionClient.chipNameRefusal(TabRename.name(from: draft)) {
            error = Self.words(for: refused)
        } else {
            error = nil
        }
    }

    /// Save a valid change, leaving a refused draft open for correction.
    @discardableResult
    mutating func commit(in model: PageModel) -> Bool {
        guard let chip, let sheet, let opened = field.opened else { return true }
        guard case .rename(let name) = TabRename.outcome(
            draft: field.draft, current: opened, committed: true
        ) else {
            keep(in: model)
            return true
        }
        if let refused = CompanionClient.chipNameRefusal(name) {
            error = Self.words(for: refused)
            return false
        }
        guard model.setChipName(name, chip: chip, sheet: sheet) else {
            if !model.coreClient.chipStands(chip) {
                shut(in: model)
                return true
            }
            error = CompanionL10n.string("chip.name.failed")
            return false
        }
        shut(in: model)
        return true
    }

    /// Cancel or close after the object leaves the page.
    mutating func keep(in model: PageModel) {
        guard isOpen else { return }
        shut(in: model)
    }

    /// Validation beside the variable name field.
    nonisolated static func words(for refusal: ChipNameRefusal) -> String {
        switch refusal {
        case .tooLong: CompanionL10n.string("chip.name.long")
        case .outsideCharset: CompanionL10n.string("chip.name.charset")
        }
    }

    private mutating func shut(in model: PageModel) {
        _ = field.end(committed: false)
        chip = nil
        sheet = nil
        error = nil
    }
}

/// The name field's editor: it takes only drags of its own text (Law 0001, naming row), and
/// its text, part of the object's page, leaves only once that page is asked (Law 0001, expiry row).
final class SealedNameTextView: AskingTextView {
    /// The field over the name, which knows the object's page; with none, nothing leaves.
    weak var owner: SealedNameEditor?

    /// Whether the name may leave by AppKit, asked of the object's page.
    var givesOut: Bool { owner?.givesOutName() ?? false }

    private func isOwn(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView) === self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwn(sender) ? super.draggingEntered(sender) : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwn(sender) ? super.draggingUpdated(sender) : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isOwn(sender) && super.performDragOperation(sender)
    }

    /// Copies onto the model's ambient board, which a test replaces, not the general one.
    override func copy(_ sender: Any?) {
        guard givesOut else { return }
        _ = writeToAmbientBoard()
    }

    /// Writes as copy does, then deletes, so no cut names the general board.
    override func cut(_ sender: Any?) {
        guard givesOut, writeToAmbientBoard() else { return }
        delete(sender)
    }

    private func writeToAmbientBoard() -> Bool {
        guard let board = owner?.model.ambientPasteboard,
              selectedRanges.contains(where: { $0.rangeValue.length > 0 })
        else { return false }
        return super.writeSelection(to: board, types: writablePasteboardTypes)
    }

    override func dragSelection(
        with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool
    ) -> Bool {
        givesOut && super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        givesOut && super.writeSelection(to: pboard, types: types)
    }

    override func writeSelection(
        to pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        givesOut && super.writeSelection(to: pboard, type: type)
    }

    /// AppKit's readers of the name ask its page, as copy does.
    override var mayReadOut: Bool { givesOut }
}

/// The name field's cell, which edits through a field editor of its own
/// that takes no drop from elsewhere (Law 0001, naming row).
final class SealedNameFieldCell: NSTextFieldCell {
    let editor: SealedNameTextView = {
        let editor = SealedNameTextView()
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }

    /// The setup gives a field editor Writing Tools back, so they are refused after it.
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? NSTextView { TextOffers.offerUngatedReaders(false, on: editor) }
        return editor
    }
}

/// The field laid over a sealed block's name seat in the page's text view.
final class SealedNameField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SealedNameFieldCell.self }
        set {}
    }

    /// The outline and fill the drawing gives the field (docs/mockups/sealed-name-and-note.svg).
    override func draw(_ dirtyRect: NSRect) {
        let metrics = SealedBlockLayout.metrics(containerWidth: bounds.width)
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: metrics.pillRadius, yRadius: metrics.pillRadius)
        NSColor.textBackgroundColor.setFill()
        outline.fill()
        NSColor.secondaryLabelColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        super.draw(dirtyRect)
    }
}

final class SealedNameHelpView: NSView {
    override var isFlipped: Bool { true }

    let title = NSTextField(wrappingLabelWithString: CompanionL10n.string("chip.name.title"))
    let help = NSTextField(wrappingLabelWithString: CompanionL10n.string("chip.name.help"))
    let error = NSTextField(wrappingLabelWithString: "")
    let hint = NSTextField(wrappingLabelWithString: CompanionL10n.string("chip.name.hint"))
    let save = NSButton(title: CompanionL10n.string("chip.name.save"), target: nil, action: nil)
    let cancel = NSButton(title: CompanionL10n.string("chip.name.cancel"), target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        for label in [help, error, hint] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        error.textColor = .systemRed
        for button in [save, cancel] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.refusesFirstResponder = true
        }
        save.setAccessibilityHelp(CompanionL10n.string("chip.name.save.help"))
        cancel.setAccessibilityHelp(CompanionL10n.string("chip.name.cancel.help"))
        for view in [title, help, error, hint, save, cancel] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("the variable name helper is created in code") }

    private struct Layout {
        let title: NSRect
        let help: NSRect
        let error: NSRect
        let hint: NSRect
        let save: NSRect
        let cancel: NSRect
        let height: CGFloat
    }

    func preferredHeight(width: CGFloat) -> CGFloat { arrangement(width: width).height }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        max(14, ceil(label.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 14))
    }

    private func arrangement(width: CGFloat) -> Layout {
        let width = max(0, width)
        let inset = min(10, width / 2)
        let textWidth = max(0, width - inset * 2)
        let titleRect = NSRect(x: inset, y: 10, width: textWidth, height: textHeight(title, width: textWidth))
        let helpRect = NSRect(x: inset, y: titleRect.maxY + 6, width: textWidth,
                              height: textHeight(help, width: textWidth))
        let errorRect = NSRect(x: inset, y: helpRect.maxY + 6, width: textWidth,
                               height: error.stringValue.isEmpty ? 0 : textHeight(error, width: textWidth))
        let y = (error.stringValue.isEmpty ? helpRect.maxY : errorRect.maxY) + 8
        let saveWidth = max(56, ceil(save.intrinsicContentSize.width))
        let cancelWidth = max(62, ceil(cancel.intrinsicContentSize.width))
        let buttonWidth = saveWidth + 6 + cancelWidth
        let stacked = textWidth < buttonWidth
        let hintWidth = NSAttributedString(string: hint.stringValue,
            attributes: [.font: hint.font ?? NSFont.systemFont(ofSize: 11)]).size().width
        let separateHint = stacked || textWidth < buttonWidth + 10 + hintWidth
        let hintHeight = textHeight(hint, width: separateHint ? textWidth : max(0, textWidth - buttonWidth - 10))
        let buttonY = y + (separateHint ? hintHeight + 6 : 0)
        let saveRect: NSRect
        let cancelRect: NSRect
        if stacked {
            cancelRect = NSRect(x: inset, y: buttonY, width: textWidth, height: 24)
            saveRect = NSRect(x: inset, y: cancelRect.maxY + 6, width: textWidth, height: 24)
        } else {
            saveRect = NSRect(x: width - inset - saveWidth, y: buttonY, width: saveWidth, height: 24)
            cancelRect = NSRect(x: saveRect.minX - 6 - cancelWidth, y: buttonY, width: cancelWidth, height: 24)
        }
        let hintRect = NSRect(x: inset, y: separateHint ? y : buttonY + (24 - hintHeight) / 2,
                              width: separateHint ? textWidth : max(0, cancelRect.minX - inset - 10),
                              height: hintHeight)
        return Layout(title: titleRect, help: helpRect, error: errorRect, hint: hintRect,
                      save: saveRect, cancel: cancelRect, height: max(saveRect.maxY, cancelRect.maxY) + 10)
    }

    override func layout() {
        super.layout()
        let placed = arrangement(width: bounds.width)
        title.frame = placed.title
        help.frame = placed.help
        error.isHidden = error.stringValue.isEmpty
        error.frame = placed.error
        hint.frame = placed.hint
        save.frame = placed.save
        cancel.frame = placed.cancel
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// The inline variable name and its anchored instructions and validation.
@MainActor
final class SealedNameEditor: NSObject, NSTextFieldDelegate {
    let model: PageModel
    weak var textView: InkTextView?
    private(set) var rename = ChipRename()
    let field = SealedNameField()
    let overlay = NoteOverlayView()
    let helpView = SealedNameHelpView()
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    /// Room past the draft for the caret, and the field's inset before its text.
    static let caretRoom: CGFloat = 8
    static let textInset: CGFloat = 2

    init(model: PageModel) {
        self.model = model
        super.init()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.isHidden = true
        field.delegate = self
        field.setAccessibilityLabel(CompanionL10n.string("chip.name.field"))
        field.setAccessibilityHelp(CompanionL10n.string("chip.name.field.help"))
        (field.cell as? SealedNameFieldCell)?.editor.owner = self
        helpView.save.target = self
        helpView.save.action = #selector(saveClicked(_:))
        helpView.cancel.target = self
        helpView.cancel.action = #selector(cancelClicked(_:))
        overlay.autoresizingMask = [.width, .height]
        overlay.addSubview(helpView)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isOpen: Bool { rename.isOpen }

    /// Whether the draft may leave by AppKit: the object's page is asked, as Copy name
    /// asks it, and a page past its deadline settles and refuses (Law 0001, expiry row).
    func givesOutName() -> Bool {
        guard let sheet = rename.sheet else { return false }
        return model.givesOut(sheet: sheet)
    }

    /// Whether the field's editor holds the keys, so its ending gives them back.
    var holdsKeys: Bool {
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    /// Opens the field over the block at `index` on `sheet`, on its name,
    /// selected whole, and gives it the keys.
    func begin(chipAt index: Int, sheet: UInt64) {
        guard let textView, textView.isEditable, let face = textView.chipCell(at: index)?.info
        else { return }
        if rename.isOpen, rename.chip != face.chipId {
            commit(returningKeys: false)
            guard !rename.isOpen else { return }
        }
        rename.open(chip: face.chipId, sheet: sheet, name: face.name, in: model)
        field.font = InkStyle.chipNameFont
        field.placeholderAttributedString = NSAttributedString(
            string: "API_KEY",
            attributes: [.font: InkStyle.chipNameFont, .foregroundColor: NSColor.placeholderTextColor])
        field.stringValue = rename.draft
        if field.superview !== textView { textView.addSubview(field) }
        if let scroll = textView.enclosingScrollView, overlay.superview !== scroll {
            overlay.frame = scroll.bounds
            scroll.addSubview(overlay)
            observe(scroll)
        }
        // The page's menu actions must not answer for the draft (Law 0007, Drafting).
        field.nextResponder = textView.nextResponder
        field.isHidden = false
        follow()
        textView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The draft as the field holds it; settable so a test stands in for the keys.
    var draft: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            draftChanged()
        }
    }

    /// Return, Save or a valid focus-loss edit commits the draft.
    func commit(returningKeys: Bool = true) {
        guard rename.isOpen else { return }
        rename.edit(field.stringValue, in: model)
        guard rename.commit(in: model) else {
            follow()
            return
        }
        close(returningKeys: returningKeys)
    }

    @discardableResult
    func focusDraft() -> Bool {
        guard rename.isOpen else { return false }
        follow()
        guard rename.isOpen else { return false }
        return field.window?.makeFirstResponder(field) ?? false
    }

    /// Escape or the object leaving the page.
    func keep(returningKeys: Bool) {
        guard rename.isOpen else { return }
        rename.keep(in: model)
        close(returningKeys: returningKeys)
    }

    /// Stands the field over the object wherever it now is on the page,
    /// and keeps the name when the object or its page has gone.
    func follow() {
        guard let chip = rename.chip, let textView else { return }
        guard textView.coordinator?.displaysPage(rename.sheet) == true,
              let index = textView.chipIndex(ofChip: chip),
              let frame = textView.chipFrame(at: index),
              let cell = textView.chipCell(at: index)
        else { return keep(returningKeys: holdsKeys) }
        let layout = SealedBlockCell.contentLayout(in: frame)
        let width = fieldWidth(room: cell.nameFieldRoom(in: frame))
        textView.naming = InkTextView.Naming(index: index, chip: chip, width: width)
        let row = cell.namedRow(in: frame, editingWidth: width)?.geometry
        let height = field.intrinsicContentSize.height
        let midY = row?.equals.midY ?? (layout.identityRowY + height / 2)
        field.frame = NSRect(
            x: layout.left - Self.textInset, y: midY - height / 2, width: width, height: height)
        placeHelp(under: frame)
        textView.redrawChip(at: index)
    }

    private func placeHelp(under block: NSRect) {
        guard let textView else { return }
        let previousError = helpView.error.stringValue
        helpView.error.stringValue = rename.error ?? ""
        if helpView.error.stringValue != previousError, !helpView.error.stringValue.isEmpty {
            NSAccessibility.post(element: helpView.error, notification: .valueChanged)
        }
        field.setAccessibilityHelp(rename.error ?? CompanionL10n.string("chip.name.field.help"))
        let block = textView.convert(block, to: overlay)
        let room = overlay.bounds.insetBy(dx: 8, dy: 8)
        let width = min(440, max(0, room.width))
        let height = helpView.preferredHeight(width: width)
        let below = room.maxY - block.maxY >= height + 4
        let y = below ? block.maxY + 4 : max(room.minY, block.minY - height - 4)
        helpView.frame = NSRect(
            x: min(max(room.minX, block.minX), max(room.minX, room.maxX - width)),
            y: y, width: width, height: height)
        helpView.needsLayout = true
    }

    private func observe(_ scroll: NSScrollView) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
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

    @objc private func saveClicked(_ sender: Any?) { commit() }
    @objc private func cancelClicked(_ sender: Any?) { keep(returningKeys: true) }

    private func fieldWidth(room: CGFloat) -> CGFloat {
        let text = field.stringValue.isEmpty ? "API_KEY" : field.stringValue
        let measured = NSAttributedString(
            string: text, attributes: [.font: InkStyle.chipNameFont]
        ).size().width
        return min(ceil(measured) + Self.textInset * 2 + Self.caretRoom, max(room, 0))
    }

    private func draftChanged() {
        rename.edit(field.stringValue, in: model)
        follow()
    }

    private func close(returningKeys: Bool) {
        defer { field.stringValue = "" }
        let index = textView?.naming?.index
        textView?.naming = nil
        field.isHidden = true
        overlay.removeFromSuperview()
        helpView.error.stringValue = ""
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let index { textView?.redrawChip(at: index) }
        guard returningKeys, let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        draftChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            keep(returningKeys: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit(returningKeys: false)
    }
}
