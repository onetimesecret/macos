import AppKit

/// A sealed object's name field from opening to ending (Law 0007), apart
/// from the AppKit field so a test drives the code the field runs.
@MainActor
struct ChipRename {
    private var field = TabRename.Field()
    /// The object whose name the field stands over, and its page; nil while shut.
    private(set) var chip: UInt64?
    private(set) var sheet: UInt64?
    /// The refusal standing in the line under the page, if one is.
    private var refusal = PageModel.HeldRefusal()

    var draft: String { field.draft }
    var isOpen: Bool { chip != nil }
    var isRefusing: Bool { refusal.isStanding }

    /// Opens on the object's name, or on nothing when it has none; a field
    /// open over another object keeps that one's name.
    mutating func open(chip: UInt64, sheet: UInt64, name: String?, in model: PageModel) {
        guard self.chip != chip else { return }
        keep(in: model)
        field.open(on: name ?? "")
        self.chip = chip
        self.sheet = sheet
    }

    /// A keystroke. A refusal already said is judged again, so the line
    /// never describes a draft the field no longer holds.
    mutating func edit(_ draft: String, in model: PageModel) {
        guard isOpen else { return }
        field.draft = draft
        guard refusal.isStanding else { return }
        if let refused = CompanionClient.chipNameRefusal(TabRename.name(from: draft)) {
            refusal.say(Self.words(for: refused), in: model)
        } else {
            refusal.release(in: model)
        }
    }

    /// Return: an untouched draft keeps, a name the core's rule refuses is
    /// said under the page with the field open, and any other names the
    /// object. True when the field shut.
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
            refusal.say(Self.words(for: refused), in: model)
            return false
        }
        // Past the rule, the core refuses only an object no longer there.
        model.setChipName(name, chip: chip, sheet: sheet)
        shut(in: model)
        return true
    }

    /// Escape, the keyboard leaving, or the object leaving the page: the
    /// name stands as it was.
    mutating func keep(in model: PageModel) {
        guard isOpen else { return }
        shut(in: model)
    }

    /// The line under the page for each of the core's refusals.
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
        refusal.release(in: model)
    }
}

/// The name field's editor, which takes only drags of its own text: a drop
/// from elsewhere is the page's to seal, and no seal can stand here (ADR-0044).
final class OwnDragsOnlyTextView: NSTextView {
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
}

/// The name field's cell, which edits through a field editor of its own
/// that takes no drop from elsewhere (ADR-0044).
final class SealedNameFieldCell: NSTextFieldCell {
    private let editor: NSTextView = {
        let editor = OwnDragsOnlyTextView()
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// The field laid over a sealed block's name seat in the page's text view.
final class SealedNameField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SealedNameFieldCell.self }
        set {}
    }

    /// The outline and fill the drawing gives the field (ADR-0042 point 8).
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

/// Opens, places and ends the name field over one sealed block (Law 0007).
@MainActor
final class SealedNameEditor: NSObject, NSTextFieldDelegate {
    let model: PageModel
    weak var textView: InkTextView?
    private(set) var rename = ChipRename()
    let field = SealedNameField()
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
    }

    var isOpen: Bool { rename.isOpen }

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
        rename.open(chip: face.chipId, sheet: sheet, name: face.name, in: model)
        field.font = InkStyle.chipNameFont
        field.placeholderAttributedString = NSAttributedString(
            string: "NAME",
            attributes: [.font: InkStyle.chipNameFont, .foregroundColor: NSColor.placeholderTextColor])
        field.stringValue = rename.draft
        if field.superview !== textView { textView.addSubview(field) }
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

    /// Return. A refused draft keeps the field and the keys.
    func commit() {
        guard rename.isOpen else { return }
        rename.edit(field.stringValue, in: model)
        guard rename.commit(in: model) else { return }
        close(returningKeys: true)
    }

    /// Escape, the keyboard leaving, or the object leaving the page.
    func keep(returningKeys: Bool) {
        guard rename.isOpen else { return }
        rename.keep(in: model)
        close(returningKeys: returningKeys)
    }

    /// Stands the field over the object wherever it now is on the page,
    /// and keeps the name when the object or its page has gone.
    func follow() {
        guard let chip = rename.chip, let textView else { return }
        guard textView.coordinator?.currentSheet == rename.sheet,
              let index = textView.chipIndex(ofChip: chip),
              let frame = textView.chipFrame(at: index),
              let cell = textView.chipCell(at: index)
        else { return keep(returningKeys: holdsKeys) }
        let layout = SealedBlockCell.contentLayout(in: frame)
        let width = fieldWidth(room: cell.nameFieldRoom(in: frame))
        textView.naming = InkTextView.Naming(index: index, chip: chip, width: width)
        let row = cell.namedRow(in: frame, editingWidth: width)?.geometry
        let height = max(field.intrinsicContentSize.height, layout.metrics.pillHeight)
        let midY = row?.equals.midY ?? (layout.bottomRowY + height / 2)
        field.frame = NSRect(
            x: layout.left - Self.textInset, y: midY - height / 2, width: width, height: height)
        textView.redrawChip(at: index)
    }

    private func fieldWidth(room: CGFloat) -> CGFloat {
        let text = field.stringValue.isEmpty ? "NAME" : field.stringValue
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
        keep(returningKeys: false)
    }
}
