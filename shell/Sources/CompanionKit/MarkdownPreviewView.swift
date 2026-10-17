import AppKit

/// A page's Markdown, rendered. It is the page's text shown another way, so every
/// AppKit route out of it asks the page first (Law 0001, the preview's rows): copy
/// composes through the core from what it shows, a link opens by the coordinator's
/// `openLink`, the text menu keeps no reader, and no drag starts here.
@MainActor
final class MarkdownPreviewView: AskingTextView {
    /// The page this preview shows and asks.
    let page: UInt64
    private weak var coordinator: InkEditorView.Coordinator?
    private let previewStorage: NSTextStorage
    private var seeded: PageModel.QuietRendering?
    private let links = PreviewLinks()

    /// A click on a preview of a page the roll has not selected promotes it (ADR-0030).
    var onPromote: (() -> Void)?

    /// Only the selected page's preview is selectable and may take the keys (ADR-0030).
    var isSelectedPage = false {
        didSet { isSelectable = isSelectedPage }
    }

    /// Drag sessions this view began; the tests pin it at none.
    private(set) var draggingSessionsBegun = 0

    init(page: UInt64, coordinator: InkEditorView.Coordinator?) {
        self.page = page
        self.coordinator = coordinator
        let storage = NSTextStorage()
        previewStorage = storage
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textContainerInset = NSSize(width: 12, height: InkEditorView.Coordinator.topInset)
        font = InkStyle.baseFont
        textColor = .labelColor
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        isAutomaticLinkDetectionEnabled = false
        TextOffers.offerUngatedReaders(false, on: self)
        links.preview = self
        delegate = links
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Markdown previews are not unarchived")
    }

    // MARK: Focus and the click (ADR-0030)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { isSelectedPage }

    override func becomeFirstResponder() -> Bool {
        isSelectedPage && super.becomeFirstResponder()
    }

    /// On the selected page a click selects; on any other it promotes the page.
    override func mouseDown(with event: NSEvent) {
        guard isSelectedPage else { return promote() }
        super.mouseDown(with: event)
    }

    /// The click itself, apart from the event, as `QuietPageView.clicked(at:)` is.
    func promote() {
        onPromote?()
    }

    // MARK: AppKit's readers of the text (Law 0001, expiry row and the preview's rows)

    /// The page is asked, as the editor asks it; with no page to ask, nothing leaves.
    override var mayReadOut: Bool {
        coordinator?.model.givesOut(sheet: page) ?? false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        aimLinkItems(in: menu, at: convert(event.locationInWindow, from: nil))
        return menu
    }

    /// A ⌘-click and Open Link go to the coordinator's `openLink`, which asks this view first.
    override func openAimedLink(_ link: Any) {
        coordinator?.openLink(link, from: self)
    }

    override var linkBoard: NSPasteboard? { coordinator?.model.ambientPasteboard }

    /// The selection as the core composes it: the rendered text between the objects as
    /// the ink runs and each object by chip id, in rendered order (Law 0001, copy row).
    func shownSelection() -> [[CompanionClient.ShownRun]] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { range in
            var runs: [CompanionClient.ShownRun] = []
            let text = previewStorage.string as NSString
            previewStorage.enumerateAttribute(.attachment, in: range) { value, run, _ in
                guard let chip = value as? ChipAttachment else {
                    if value == nil, run.length > 0 { runs.append(.ink(text.substring(with: run))) }
                    return
                }
                for _ in 0..<run.length { runs.append(.chip(chip.info.chipId)) }
            }
            return runs
        }
    }

    /// Copy composes through the core, which refuses past the deadline (Law 0001, copy row).
    override func copy(_ sender: Any?) {
        guard let coordinator else { return }
        coordinator.model.copyShownSelection(shownSelection(), sheet: page)
    }

    /// A service takes the public text alone (Law 0001, export row).
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string, SealedFragment.legacyStringType]
    }

    /// No service may write back over a preview.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        guard returnType == nil else { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// The composition's public text in whichever public type was asked for, never the envelope.
    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let fragment = composedForRequester(),
              let item = fragment.pasteboardItem(
                  offering: types.filter { $0 != SealedFragment.pasteboardType })
        else { return false }
        pboard.clearContents()
        return pboard.writeObjects([item])
    }

    override func writeSelection(
        to pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string || type == SealedFragment.legacyStringType,
              let fragment = composedForRequester()
        else { return false }
        return pboard.setString(fragment.plainText, forType: .string)
    }

    /// The composition for a service, its refusal told as a copy's is.
    private func composedForRequester() -> SealedFragment? {
        guard let coordinator else { return nil }
        let composition = coordinator.model.composeShownSelection(shownSelection(), sheet: page)
        if let line = PageModel.refusalLine(for: composition, .copy) { coordinator.model.flash(line) }
        guard case .composed(let fragment) = composition else { return nil }
        return fragment
    }

    /// Use Selection for Find hands the text to the finder's board (Law 0001, expiry row).
    override func performFindPanelAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performTextFinderAction(sender)
    }

    private func refusesFinderAction(_ sender: Any?) -> Bool {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSControl)?.tag
        guard tag == NSTextFinder.Action.setSearchString.rawValue else { return false }
        return !mayReadOut
    }

    // MARK: No drag starts here (Law 0001, plain drag row)

    override func dragSelection(
        with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool
    ) -> Bool {
        false
    }

    override func dragImageForSelection(with event: NSEvent, origin: NSPointPointer?) -> NSImage? {
        nil
    }

    override func beginDraggingSession(
        with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource
    ) -> NSDraggingSession {
        draggingSessionsBegun += 1
        return super.beginDraggingSession(with: items, event: event, source: source)
    }

    func reseed(with rendering: PageModel.QuietRendering) {
        guard rendering !== seeded else { return }
        seeded = rendering
        previewStorage.setAttributedString(Self.render(rendering.text))
        needsDisplay = true
    }

    /// `dialect` selects the pinned parser that reads the page (`MarkdownParser`, plan R1) and how
    /// its raw HTML composes (plan R3).
    static func render(
        _ source: NSAttributedString, dialect: PreviewDialect = .gfm,
        limits: CompositionLimits = CompositionLimits()
    ) -> NSAttributedString {
        MarkdownPreviewRenderer(source: source, dialect: dialect, limits: limits).render()
    }
}

extension NSAttributedString.Key {
    /// An image's alt text and objects in a rendered preview, valued by its `PreviewImageDescriptor`.
    static let previewImage = NSAttributedString.Key("CompanionKitPreviewImage")
}

/// An image in one rendering: its ordinal among that rendering's images, and its address as
/// composed. The Load Image control that would read it is plan R5 (ADR-0059).
struct PreviewImageDescriptor: Hashable {
    let occurrence: Int
    let destination: PreviewAddress
}

/// The preview's delegate: a link opens only by `openAimedLink`, and an object's
/// attachment gives AppKit nothing to drag, open or write (Law 0001, link and attachment rows).
@MainActor
private final class PreviewLinks: NSObject, NSTextViewDelegate {
    weak var preview: MarkdownPreviewView?

    /// A ⌘-click opens through the gate; a plain click selects, as on a page.
    func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if NSApp?.currentEvent?.modifierFlags.contains(.command) == true {
            preview?.openAimedLink(link)
        }
        return true
    }

    /// A drag that starts on an object starts nothing here.
    func textView(
        _ view: NSTextView, draggedCell cell: any NSTextAttachmentCellProtocol,
        in rect: NSRect, event: NSEvent, at charIndex: Int
    ) {}
}

@MainActor
private final class MarkdownPreviewRenderer {
    private struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var spacing: CGFloat = 8
    }

    /// A composed identity naming no object of this rendering, a table row with more cells than
    /// the table has columns, or a rendering that showed fewer objects than the page has.
    private enum RenderFailure: Error {
        case unknownObject, rowWiderThanTable, objectMissing
    }

    private let output = NSMutableAttributedString(string: "")
    private let text: String
    private let dialect: PreviewDialect
    private let limits: CompositionLimits
    /// The page's objects in source order, and the UTF-16 offset of each.
    private let attachments: [NSTextAttachment]
    private let offsets: [Int]
    /// One stream for the document, so HTML scope crosses blocks (plan R3).
    private var composer: PreviewCompositionStream
    private var images = 0
    /// Objects shown; the composer refuses a second showing of any one.
    private var shown = 0

    init(source: NSAttributedString, dialect: PreviewDialect, limits: CompositionLimits) {
        let raw = source.string as NSString
        var attachments: [NSTextAttachment] = []
        var offsets: [Int] = []
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for index in range.location..<NSMaxRange(range) where raw.character(at: index) == 0xFFFC {
                attachments.append(attachment)
                offsets.append(index)
            }
        }
        text = source.string
        self.dialect = dialect
        self.limits = limits
        self.attachments = attachments
        self.offsets = offsets
        composer = PreviewComposer(dialect: dialect, limits: limits).start()
    }

    /// The preview, or the page's plain text when parsing or composition refuses the page.
    func render() -> NSAttributedString {
        do {
            let document = try MarkdownParser.parse(text, objects: offsets, dialect: dialect, limits: limits)
            for block in document.blocks { try renderBlock(block, context: Context()) }
            try composer.finish()
            guard shown == attachments.count else { throw RenderFailure.objectMissing }
            return NSAttributedString(attributedString: output)
        } catch {
            return plainText()
        }
    }

    /// The page's text with LF line endings and its objects in place, one unstyled paragraph style.
    private func plainText() -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        for (attachment, offset) in zip(attachments, offsets) {
            result.addAttribute(.attachment, value: attachment, range: NSRange(location: offset, length: 1))
        }
        for ending in ["\r\n", "\r"] {
            result.mutableString.replaceOccurrences(
                of: ending, with: "\n", options: .literal, range: NSRange(location: 0, length: result.length)
            )
        }
        if result.length > 0, !result.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        result.addAttribute(
            .paragraphStyle, value: paragraphStyle(Context()),
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]
    }

    private func paragraphStyle(_ context: Context, marker: String? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = context.indent
        style.firstLineHeadIndent = marker == nil ? context.indent : max(0, context.indent - 28)
        style.paragraphSpacing = context.spacing
        style.lineSpacing = 2
        style.lineBreakMode = .byWordWrapping
        style.textBlocks = context.blocks
        style.tabStops = marker == nil ? [] : [
            NSTextTab(textAlignment: .left, location: context.indent)
        ]
        style.defaultTabInterval = 28
        return style
    }

    private func paragraph(
        _ content: NSAttributedString, context: Context, marker: String? = nil,
        style: NSMutableParagraphStyle? = nil
    ) {
        let text = NSMutableAttributedString(string: "")
        if let marker { text.append(NSAttributedString(string: marker + "\t", attributes: baseAttributes)) }
        text.append(content)
        if !text.string.hasSuffix("\n") {
            text.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        text.addAttribute(
            .paragraphStyle, value: style ?? paragraphStyle(context, marker: marker),
            range: NSRange(location: 0, length: text.length)
        )
        output.append(text)
    }

    private func renderBlock(_ block: MarkdownBlock, context: Context, marker: String? = nil) throws {
        composer.beginBlock()
        switch block {
        case .heading(let level, let events):
            var attributes = baseAttributes
            let scale: [CGFloat] = [1.8, 1.55, 1.35, 1.18, 1.08, 1]
            let size = InkStyle.baseFont.pointSize * scale[min(5, max(0, level - 1))]
            let sized = NSFontManager.shared.convert(InkStyle.baseFont, toSize: size)
            attributes[.font] = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
            let style = paragraphStyle(context, marker: marker)
            style.paragraphSpacingBefore = level <= 2 ? 10 : 6
            style.paragraphSpacing = 6
            paragraph(try inlines(events, attributes: attributes), context: context, marker: marker, style: style)
        case .paragraph(let events):
            paragraph(try inlines(events, attributes: baseAttributes), context: context, marker: marker)
        case .codeBlock(let info, let literal):
            var nested = context
            let block = NSTextBlock()
            block.backgroundColor = .controlBackgroundColor
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            nested.blocks.append(block)
            var attributes = baseAttributes
            attributes[.font] = InkStyle.codeFont
            // The info string shows nothing but its objects, which open the block.
            let content = try parts(info.objectIdentities.map(HTMLPart.object) + literal, attributes: attributes)
            paragraph(content, context: nested, marker: marker)
        case .quote(let children):
            var nested = context
            let block = NSTextBlock()
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.separatorColor)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            nested.blocks.append(block)
            nested.indent += 12
            for child in children { try renderBlock(child, context: nested) }
        case .list(let ordered, let start, _, let items):
            try renderList(items, startingAt: ordered ? start : nil, context: context)
        case .table(let alignments, let header, let body):
            try renderTable(alignments: alignments, rows: [header] + body, context: context)
        case .html(let parts):
            // A block of tags alone, or of a comment, leaves no empty paragraph.
            let content = trimmed(try compose(.rawHTML(parts), attributes: baseAttributes))
            if content.length > 0 || marker != nil {
                paragraph(content, context: context, marker: marker)
            }
        case .thematicBreak:
            var nested = context
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(.separatorColor)
            nested.blocks.append(rule)
            let style = paragraphStyle(nested)
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 12
            paragraph(NSAttributedString(string: "\u{200B}", attributes: baseAttributes), context: nested, style: style)
        case .objects(let identities):
            // Each object with no element of its own is a paragraph of its own.
            for identity in identities {
                composer.beginBlock()
                paragraph(try compose(.object(identity), attributes: baseAttributes), context: context)
            }
        }
    }

    /// An HTML block without the whitespace its source lines leave at either end.
    private func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        let kept = CharacterSet.whitespacesAndNewlines.inverted
        let first = string.rangeOfCharacter(from: kept)
        guard first.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = string.rangeOfCharacter(from: kept, options: .backwards)
        return text.attributedSubstring(from: NSRange(
            location: first.location, length: NSMaxRange(last) - first.location
        ))
    }

    private func renderList(_ items: [MarkdownListItem], startingAt start: Int?, context: Context) throws {
        var nested = context
        nested.indent += 28
        nested.spacing = 3
        for (offset, item) in items.enumerated() {
            let marker: String
            switch item.task {
            case true?: marker = "☑"
            case false?: marker = "☐"
            case nil:
                marker = start.map { "\($0 + offset)." } ?? "•"
            }
            switch item.blocks.first {
            case .paragraph?, .heading?:
                try renderBlock(item.blocks[0], context: nested, marker: marker)
                for block in item.blocks.dropFirst() { try renderBlock(block, context: nested) }
            default:
                paragraph(NSAttributedString(string: ""), context: nested, marker: marker)
                for block in item.blocks { try renderBlock(block, context: nested) }
            }
        }
    }

    /// One native cell per column and row, as published GFM has no spans; a row's missing
    /// trailing cells are empty ones.
    private func renderTable(
        alignments: [MarkdownAlignment?], rows: [[[PreviewEvent]]], context: Context
    ) throws {
        let columnCount = alignments.count
        guard rows.allSatisfy({ $0.count <= columnCount }) else { throw RenderFailure.rowWiderThanTable }
        guard columnCount > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setValue(0, type: .absoluteValueType, for: .minimumWidth)
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columnCount {
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1
                )
                cell.setContentWidth(100 / CGFloat(columnCount), type: .percentageValueType)
                cell.setValue(0, type: .absoluteValueType, for: .minimumWidth)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.verticalAlignment = .topAlignment
                if rowIndex == 0 { cell.backgroundColor = .controlBackgroundColor }
                var nested = context
                nested.indent = 0
                nested.spacing = 0
                nested.blocks.append(cell)
                let style = paragraphStyle(nested)
                switch alignments[column] {
                case .center?: style.alignment = .center
                case .right?: style.alignment = .right
                default: style.alignment = .left
                }
                var attributes = baseAttributes
                if rowIndex == 0 {
                    attributes[.font] = NSFontManager.shared.convert(InkStyle.baseFont, toHaveTrait: .boldFontMask)
                }
                composer.beginBlock()
                let content = column < cells.count
                    ? try inlines(cells[column], attributes: attributes) : NSAttributedString(string: "")
                paragraph(content, context: nested, style: style)
            }
        }
        // End the table with a paragraph outside its cells, including at end of document.
        paragraph(NSAttributedString(string: ""), context: context)
    }

    /// A block's inline events, each composed under the block's `attributes`.
    private func inlines(
        _ events: [PreviewEvent], attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for event in events { text.append(try compose(event, attributes: attributes)) }
        return text
    }

    /// A literal's text and objects, each part its own composer event.
    private func parts(
        _ parts: [HTMLPart], attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for part in parts {
            switch part {
            case .text(let literal): text.append(try compose(.text(literal), attributes: attributes))
            case .object(let identity): text.append(try compose(.object(identity), attributes: attributes))
            }
        }
        return text
    }

    /// The native text of one composer event: `attributes` under the composed style.
    private func compose(
        _ event: PreviewEvent, attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in try composer.consume(event) {
            switch run {
            case .text(let text, let style):
                result.append(NSAttributedString(string: text, attributes: styled(attributes, style)))
            case .object(let identity, _):
                result.append(try object(identity))
            case .image(let image, let style):
                result.append(try inertImage(image, attributes: styled(attributes, style)))
            }
        }
        return result
    }

    /// `attributes` with the composed traits and link; inside a Markdown link the composer
    /// gives that link, accepted or refused, and no HTML link.
    private func styled(
        _ attributes: [NSAttributedString.Key: Any], _ style: PreviewStyle
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let manager = NSFontManager.shared
        var font = attributes[.font] as? NSFont ?? InkStyle.baseFont
        if style.traits.contains(.code) {
            let inherited = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            font = manager.convert(manager.convert(InkStyle.codeFont, toSize: font.pointSize), toHaveTrait: inherited)
            result[.backgroundColor] = NSColor.controlBackgroundColor
        }
        if style.traits.contains(.strong) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if style.traits.contains(.emphasis) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        result[.font] = font
        if style.traits.contains(.deletion) {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if case .unreviewed(let address)? = style.link, let url = safeURL(address) {
            result[.link] = url
            result[.foregroundColor] = NSColor.linkColor
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    /// An image as its alt text and objects in secondary ink, marked with its descriptor and
    /// no link; its Load Image control is plan R5 (ADR-0059).
    private func inertImage(
        _ image: PreviewImage, attributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let descriptor = PreviewImageDescriptor(occurrence: images, destination: image.destination)
        images += 1
        var alt = attributes
        alt.removeValue(forKey: .link)
        alt.removeValue(forKey: .underlineStyle)
        alt[.foregroundColor] = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString(string: "")
        for part in image.fallback {
            switch part {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: alt))
            case .object(let identity): result.append(try object(identity))
            }
        }
        result.addAttribute(.previewImage, value: descriptor, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func safeURL(_ destination: String) -> URL? {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !destination.unicodeScalars.contains(where: { forbidden.contains($0) }),
              var components = URLComponents(string: destination),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        if scheme == "mailto" {
            guard !components.path.isEmpty else { return nil }
            // A mailto query names headers and attachments for the mail client; the address alone opens.
            components.query = nil
            components.fragment = nil
        } else {
            guard let host = components.host, !host.isEmpty else { return nil }
        }
        return components.url
    }

    /// The object a composed identity names, as its attachment character.
    private func object(_ identity: String) throws -> NSAttributedString {
        guard let index = Int(identity), attachments.indices.contains(index) else {
            throw RenderFailure.unknownObject
        }
        shown += 1
        var attributes = baseAttributes
        attributes[.attachment] = attachments[index]
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }
}
