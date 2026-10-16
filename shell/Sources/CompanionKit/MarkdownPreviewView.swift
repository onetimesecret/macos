import AppKit
import Markdown

@MainActor
final class MarkdownPreviewView: NSTextView {
    private let previewStorage: NSTextStorage
    private var seeded: PageModel.QuietRendering?
    var onActivate: (() -> Void)?
    private var isActivating = false

    init() {
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
        isSelectable = true
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Markdown previews are not unarchived")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !isActivating {
            isActivating = true
            onActivate?()
            isActivating = false
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
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
    private let tokens: [AttachmentToken]
    private let tokenPattern: NSRegularExpression
    private var emittedAttachments: Set<Int> = []

    init(source: NSAttributedString) {
        var prefix = "OTSAttachment" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while source.string.contains(prefix) { prefix += "X" }
        tokenPrefix = prefix
        tokenPattern = try! NSRegularExpression(pattern: prefix + "([0-9]+)Z")

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
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1
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
                switch node.columnAlignments[column] {
                case .center?: style.alignment = .center
                case .right?: style.alignment = .right
                default: style.alignment = .left
                }
                var attributes = baseAttributes
                if rowIndex == 0 {
                    attributes[.font] = NSFontManager.shared.convert(InkStyle.baseFont, toHaveTrait: .boldFontMask)
                }
                let content = column < cells.count
                    ? inlineChildren(cells[column], attributes: attributes)
                    : NSAttributedString(string: "")
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
              let components = URLComponents(string: destination),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        if scheme == "mailto" {
            guard !components.path.isEmpty else { return nil }
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
        let matches = tokenPattern.matches(in: string, range: NSRange(location: 0, length: raw.length))
        var cursor = 0
        for match in matches {
            result.append(NSAttributedString(string: raw.substring(with: NSRange(
                location: cursor, length: match.range.location - cursor
            )), attributes: attributes))
            if let index = Int(raw.substring(with: match.range(at: 1))), tokens.indices.contains(index),
               emittedAttachments.insert(index).inserted {
                var attachmentAttributes = baseAttributes
                attachmentAttributes[.attachment] = tokens[index].attachment
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: attachmentAttributes))
            }
            cursor = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: raw.substring(from: cursor), attributes: attributes))
        return result
    }

    private func flushAttachments(before location: SourceLocation?, context: Context) {
        // References and link destinations may contain objects that have no visible AST leaf.
        for (index, token) in tokens.enumerated() where !emittedAttachments.contains(index) {
            if let location, !(token.location < location) { continue }
            emittedAttachments.insert(index)
            var attributes = baseAttributes
            attributes[.attachment] = token.attachment
            paragraph(NSAttributedString(string: "\u{FFFC}", attributes: attributes), context: context)
        }
    }
}
