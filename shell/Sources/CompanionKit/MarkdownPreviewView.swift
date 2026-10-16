import AppKit
import Markdown

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

    static func render(_ source: NSAttributedString) -> NSAttributedString {
        MarkdownPreviewRenderer(source: source).render()
    }
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
    private struct AttachmentToken {
        let attachment: NSTextAttachment
        let location: SourceLocation
    }

    private struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var spacing: CGFloat = 8
    }

    private let output = NSMutableAttributedString(string: "")
    private let markdown: String
    private let tokenPrefix: String
    /// The attachments in source order, which is also the order of `location`.
    private let tokens: [AttachmentToken]
    private var emittedAttachments: Set<Int> = []
    /// Every token below this index is emitted, so a flush never walks them again.
    private var nextToken = 0

    init(source: NSAttributedString) {
        var prefix = "OTSAttachment" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while source.string.contains(prefix) { prefix += "X" }
        tokenPrefix = prefix

        let raw = source.string as NSString
        var replacements: [(NSRange, NSTextAttachment)] = []
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for index in range.location..<NSMaxRange(range) where raw.character(at: index) == 0xFFFC {
                replacements.append((NSRange(location: index, length: 1), attachment))
            }
        }

        var masked = ""
        var cursor = 0
        var captured: [AttachmentToken] = []
        var line = 1
        var column = 1
        func advance(over text: String) {
            for byte in text.utf8 {
                if byte == 10 || byte == 13 {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
            }
        }
        // Normalize line endings before recording the parser's UTF-8 source positions.
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        for (range, attachment) in replacements {
            let preceding = normalized(raw.substring(with: NSRange(
                location: cursor, length: range.location - cursor
            )))
            masked += preceding
            advance(over: preceding)
            let spelling = prefix + String(captured.count) + "Z"
            captured.append(AttachmentToken(
                attachment: attachment,
                location: SourceLocation(line: line, column: column, source: nil)
            ))
            masked += spelling
            advance(over: spelling)
            cursor = NSMaxRange(range)
        }
        masked += normalized(raw.substring(from: cursor))
        markdown = masked
        tokens = captured
    }

    func render() -> NSAttributedString {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        for child in document.children { renderBlock(child, context: Context()) }
        flushAttachments(before: nil, context: Context())
        return NSAttributedString(attributedString: output)
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

    private func renderBlock(_ node: any Markup, context: Context, marker: String? = nil) {
        if let location = node.range?.lowerBound {
            flushAttachments(before: location, context: context)
        }
        switch node {
        case let heading as Heading:
            var attributes = baseAttributes
            let scale: [CGFloat] = [1.8, 1.55, 1.35, 1.18, 1.08, 1]
            let size = InkStyle.baseFont.pointSize * scale[min(5, max(0, heading.level - 1))]
            let sized = NSFontManager.shared.convert(InkStyle.baseFont, toSize: size)
            attributes[.font] = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
            let style = paragraphStyle(context, marker: marker)
            style.paragraphSpacingBefore = heading.level <= 2 ? 10 : 6
            style.paragraphSpacing = 6
            paragraph(inlineChildren(heading, attributes: attributes), context: context, marker: marker, style: style)
        case let prose as Paragraph:
            paragraph(inlineChildren(prose, attributes: baseAttributes), context: context, marker: marker)
        case let code as CodeBlock:
            var nested = context
            let block = NSTextBlock()
            block.backgroundColor = .controlBackgroundColor
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            nested.blocks.append(block)
            var attributes = baseAttributes
            attributes[.font] = InkStyle.codeFont
            paragraph(literal(code.code, attributes: attributes), context: nested, marker: marker)
        case let quote as BlockQuote:
            var nested = context
            let block = NSTextBlock()
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.separatorColor)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            nested.blocks.append(block)
            nested.indent += 12
            for child in quote.children { renderBlock(child, context: nested) }
        case let list as OrderedList:
            renderList(list, startingAt: list.startIndex, context: context)
        case let list as UnorderedList:
            renderList(list, startingAt: nil, context: context)
        case let table as Markdown.Table:
            renderTable(table, context: context)
        case let html as HTMLBlock:
            paragraph(literal(html.rawHTML, attributes: baseAttributes), context: context, marker: marker)
        case is ThematicBreak:
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
        default:
            for child in node.children { renderBlock(child, context: context) }
        }
        if let location = node.range?.upperBound {
            flushAttachments(before: location, context: context)
        }
    }

    private func renderList(_ list: any Markup, startingAt start: UInt?, context: Context) {
        var nested = context
        nested.indent += 28
        nested.spacing = 3
        for (offset, child) in list.children.enumerated() {
            guard let item = child as? ListItem else { continue }
            let marker: String
            switch item.checkbox {
            case .checked?: marker = "☑"
            case .unchecked?: marker = "☐"
            case nil:
                marker = start.map { "\($0 + UInt(offset))." } ?? "•"
            }
            let children = Array(item.children)
            if let first = children.first, first is Paragraph || first is Heading {
                renderBlock(first, context: nested, marker: marker)
                for block in children.dropFirst() { renderBlock(block, context: nested) }
            } else {
                paragraph(NSAttributedString(string: ""), context: nested, marker: marker)
                for block in children { renderBlock(block, context: nested) }
            }
        }
    }

    private func renderTable(_ node: Markdown.Table, context: Context) {
        let columnCount = node.maxColumnCount
        guard columnCount > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setValue(0, type: .absoluteValueType, for: .minimumWidth)
        let rows: [[any Markup]] = [Array(node.head.children)] + node.body.children.map { Array($0.children) }
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columnCount {
                // The parser keeps a cell under a span with a zero span of its own.
                let source = column < cells.count ? cells[column] as? Markdown.Table.Cell : nil
                if let source, source.colspan == 0 || source.rowspan == 0 { continue }
                let columnSpan = min(max(Int(source?.colspan ?? 1), 1), columnCount - column)
                let rowSpan = min(max(Int(source?.rowspan ?? 1), 1), rows.count - rowIndex)
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: rowSpan,
                    startingColumn: column, columnSpan: columnSpan
                )
                cell.setContentWidth(
                    100 * CGFloat(columnSpan) / CGFloat(columnCount), type: .percentageValueType)
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
                switch node.columnAlignments[column] {
                case .center?: style.alignment = .center
                case .right?: style.alignment = .right
                default: style.alignment = .left
                }
                var attributes = baseAttributes
                if rowIndex == 0 {
                    attributes[.font] = NSFontManager.shared.convert(InkStyle.baseFont, toHaveTrait: .boldFontMask)
                }
                let content = source.map { inlineChildren($0, attributes: attributes) }
                    ?? NSAttributedString(string: "")
                paragraph(content, context: nested, style: style)
            }
        }
        // End the table with a paragraph outside its cells, including at end of document.
        paragraph(NSAttributedString(string: ""), context: context)
    }

    private func inlineChildren(
        _ node: any Markup, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        for child in node.children { text.append(inline(child, attributes: attributes)) }
        return text
    }

    private func inline(
        _ node: any Markup, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var styled = attributes
        switch node {
        case let text as Markdown.Text:
            return literal(text.string, attributes: attributes)
        case is Strong:
            let font = attributes[.font] as? NSFont ?? InkStyle.baseFont
            styled[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        case is Emphasis:
            let font = attributes[.font] as? NSFont ?? InkStyle.baseFont
            styled[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case is Strikethrough:
            styled[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case let code as InlineCode:
            let inherited = attributes[.font] as? NSFont ?? InkStyle.baseFont
            let traits = NSFontManager.shared.traits(of: inherited)
                .intersection([.boldFontMask, .italicFontMask])
            let sized = NSFontManager.shared.convert(InkStyle.codeFont, toSize: inherited.pointSize)
            styled[.font] = NSFontManager.shared.convert(sized, toHaveTrait: traits)
            styled[.backgroundColor] = NSColor.controlBackgroundColor
            return literal(code.code, attributes: styled)
        case let link as Markdown.Link:
            if let destination = link.destination, let url = safeURL(destination) {
                styled[.link] = url
                styled[.foregroundColor] = NSColor.linkColor
                styled[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        case is Markdown.Image:
            styled.removeValue(forKey: .link)
            styled.removeValue(forKey: .underlineStyle)
            styled[.foregroundColor] = NSColor.secondaryLabelColor
        case let html as InlineHTML:
            return literal(html.rawHTML, attributes: attributes)
        case is SoftBreak:
            return NSAttributedString(string: " ", attributes: attributes)
        case is LineBreak:
            return NSAttributedString(string: "\u{2028}", attributes: attributes)
        default:
            break
        }
        return inlineChildren(node, attributes: styled)
    }

    private func safeURL(_ destination: String) -> URL? {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !destination.contains(tokenPrefix),
              !destination.unicodeScalars.contains(where: { forbidden.contains($0) }),
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

    private func literal(
        _ string: String, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let raw = string as NSString
        var cursor = 0
        for (range, index) in tokenSpellings(in: raw) {
            result.append(NSAttributedString(string: raw.substring(with: NSRange(
                location: cursor, length: range.location - cursor
            )), attributes: attributes))
            // An object a link destination or a reference hid before this one keeps its place.
            while nextToken < index {
                if !emittedAttachments.contains(nextToken) { result.append(object(nextToken)) }
                nextToken += 1
            }
            if !emittedAttachments.contains(index) { result.append(object(index)) }
            if nextToken == index { nextToken += 1 }
            cursor = NSMaxRange(range)
        }
        result.append(NSAttributedString(string: raw.substring(from: cursor), attributes: attributes))
        return result
    }

    /// Each token spelled in `raw`, `<prefix><digits>Z`, with the index it names.
    private func tokenSpellings(in raw: NSString) -> [(NSRange, Int)] {
        var found: [(NSRange, Int)] = []
        let digits = CharacterSet.decimalDigits
        var search = NSRange(location: 0, length: raw.length)
        while search.length > 0 {
            let prefix = raw.range(of: tokenPrefix, options: .literal, range: search)
            guard prefix.location != NSNotFound else { break }
            var end = NSMaxRange(prefix)
            while end < raw.length, let scalar = Unicode.Scalar(raw.character(at: end)),
                  digits.contains(scalar)
            { end += 1 }
            let number = raw.substring(with: NSRange(location: NSMaxRange(prefix), length: end - NSMaxRange(prefix)))
            if end < raw.length, raw.character(at: end) == 0x5A /* Z */, let index = Int(number),
               tokens.indices.contains(index)
            {
                found.append((NSRange(location: prefix.location, length: end + 1 - prefix.location), index))
                search = NSRange(location: end + 1, length: raw.length - end - 1)
            } else {
                search = NSRange(location: NSMaxRange(prefix), length: raw.length - NSMaxRange(prefix))
            }
        }
        return found
    }

    /// The object at `index`, marked emitted.
    private func object(_ index: Int) -> NSAttributedString {
        emittedAttachments.insert(index)
        var attributes = baseAttributes
        attributes[.attachment] = tokens[index].attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    /// Objects with no visible leaf, in a reference or a link destination, each as a
    /// paragraph of its own before the block at `location`; every token before `nextToken`
    /// is emitted, so the walk is linear over a render.
    private func flushAttachments(before location: SourceLocation?, context: Context) {
        while nextToken < tokens.count {
            if emittedAttachments.contains(nextToken) {
                nextToken += 1
                continue
            }
            if let location, !(tokens[nextToken].location < location) { return }
            paragraph(object(nextToken), context: context)
            nextToken += 1
        }
    }
}
