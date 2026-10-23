import CMarkCommonMark
import CMarkGFM

/// Why the parser adapter refused a page; the preview then shows the page as plain text.
enum MarkdownParseError: Error, Equatable {
    case inputLimit
    case depthLimit
    case tableCellLimit
    /// No run of plane 16 scalars, one per object, avoids the page's own plane 16 scalars and
    /// numeric character reference values.
    case noPlaceholderWindow
    /// An object offset out of ascending order, or at no U+FFFC of the page.
    case objectOffset
    case parserFailure
    case duplicateObject(String)
}

/// A page read by its dialect's pinned parser (plan R1): CommonMark by cmark 0.31.2, GFM by
/// cmark-gfm 0.29.0.gfm.13, each sealed object a plane 16 placeholder scalar while it parses.
enum MarkdownParser {
    /// `text` read under `dialect`; `objects` are the UTF-16 offsets in `text` of the U+FFFC characters
    /// that are sealed objects, in ascending order. Identity of object i is String(i).
    static func parse(
        _ text: String, objects: [Int] = [], dialect: PreviewDialect,
        limits: CompositionLimits = CompositionLimits()
    ) throws -> MarkdownDocument {
        let source = try PlaceholderSource(text, objects: objects, limits: limits)
        let library = dialect == .gfm ? CMarkLibrary.gfm : CMarkLibrary.commonMark
        let parsed = source.bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                library.parse($0.baseAddress, $0.count, Int64(limits.maximumTableCells))
            }
        }
        guard let parsed else { throw MarkdownParseError.parserFailure }
        defer { library.free(parsed) }
        guard !library.tableCellsExhausted(parsed) else { throw MarkdownParseError.tableCellLimit }
        let walker = TreeWalker(library: library, document: parsed, source: source, limits: limits)
        return MarkdownDocument(blocks: try walker.walk(), atoms: source.atoms)
    }
}

/// cmark's block source position: a 1-based line and a 1-based byte column.
private struct SourcePosition: Comparable {
    let line: Int
    let column: Int

    static func < (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// Literal bytes split at this page's placeholders.
private enum Piece {
    case text(String)
    case atom(Int)
}

/// The page as the parser reads it: LF line endings, and object k the scalar `base + k`.
private struct PlaceholderSource {
    private static let plane16 = UInt32(0x10_0000)...UInt32(0x10_FFFD)

    let base: UInt32
    let objectCount: Int
    private(set) var bytes: [UInt8] = []
    private(set) var atoms: [MarkdownAtom] = []
    /// Where each object's placeholder starts in `bytes`.
    private(set) var positions: [SourcePosition] = []

    init(_ text: String, objects: [Int], limits: CompositionLimits) throws {
        var scalars = 0
        var taken: [UInt32] = []
        for scalar in text.unicodeScalars {
            scalars += 1
            guard scalars <= limits.maximumInputScalars else { throw MarkdownParseError.inputLimit }
            if Self.plane16.contains(scalar.value) { taken.append(scalar.value) }
        }
        guard objects.first.map({ $0 >= 0 }) ?? true, zip(objects, objects.dropFirst()).allSatisfy({ $0 < $1 })
        else { throw MarkdownParseError.objectOffset }
        taken += Self.numericReferenceValues(in: text).filter { Self.plane16.contains($0) }
        objectCount = objects.count
        base = try Self.window(of: objects.count, avoiding: taken)
        try build(text, objects: objects)
    }

    /// The lowest base whose `count` scalars are all plane 16 and none of them `taken`.
    private static func window(of count: Int, avoiding taken: [UInt32]) throws -> UInt32 {
        var base = UInt64(plane16.lowerBound)
        for value in taken.sorted().map(UInt64.init) {
            if value >= base + UInt64(count) { break }
            if value >= base { base = value + 1 }
        }
        guard count == 0 || base + UInt64(count) - 1 <= UInt64(plane16.upperBound) else {
            throw MarkdownParseError.noPlaceholderWindow
        }
        return UInt32(base)
    }

    /// The value of every terminated `&#digits;` and `&#xhex;` in `text`, any digit count, up to U+10FFFF.
    private static func numericReferenceValues(in text: String) -> [UInt32] {
        let bytes = Array(text.utf8)
        var values: [UInt32] = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == UInt8(ascii: "&"), bytes[index + 1] == UInt8(ascii: "#") else {
                index += 1
                continue
            }
            var cursor = index + 2
            let hex = (bytes[cursor] | 0x20) == UInt8(ascii: "x")
            if hex { cursor += 1 }
            let digits = cursor
            var value: UInt32 = 0
            var inRange = true
            while cursor < bytes.count, let digit = Self.digit(bytes[cursor], hex: hex) {
                if inRange {
                    value = value * (hex ? 16 : 10) + digit
                    inRange = value <= 0x10_FFFF
                }
                cursor += 1
            }
            if cursor > digits, cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";"), inRange {
                values.append(value)
            }
            index = cursor
        }
        return values
    }

    private static func digit(_ byte: UInt8, hex: Bool) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where hex: return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where hex: return UInt32(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    /// CR and CRLF become LF, NUL becomes U+FFFD and a leading byte order mark is dropped, as
    /// cmark treats each, before any column is counted.
    private mutating func build(_ text: String, objects: [Int]) throws {
        bytes.reserveCapacity(text.utf8.count + 4 * objects.count)
        var line = 1
        var column = 1
        var offset = 0
        var next = 0
        var afterCarriageReturn = false
        func append(_ scalar: Unicode.Scalar) {
            UTF8.encode(scalar) { bytes.append($0) }
            column += UTF8.width(scalar)
        }
        for scalar in text.unicodeScalars {
            defer { offset += scalar.value > 0xFFFF ? 2 : 1 }
            let newline = afterCarriageReturn
            afterCarriageReturn = false
            if next < objects.count, objects[next] <= offset {
                guard objects[next] == offset, scalar == "\u{FFFC}" else { throw MarkdownParseError.objectOffset }
                atoms.append(MarkdownAtom(identity: String(next), offset: offset))
                positions.append(SourcePosition(line: line, column: column))
                append(Unicode.Scalar(base + UInt32(next))!)
                next += 1
                continue
            }
            switch scalar {
            case "\r", "\n":
                if scalar == "\n", newline { continue }
                bytes.append(0x0A)
                line += 1
                column = 1
                afterCarriageReturn = scalar == "\r"
            case "\u{0}": append("\u{FFFD}")
            case "\u{FEFF}" where offset == 0: continue
            default: append(scalar)
            }
        }
        guard next == objects.count else { throw MarkdownParseError.objectOffset }
    }

    func atom(_ value: UInt32) -> Int? {
        value >= base && value - base < UInt32(objectCount) ? Int(value - base) : nil
    }

    func pieces(_ bytes: UnsafeRawBufferPointer) -> [Piece] {
        var pieces: [Piece] = []
        var start = 0
        var index = 0
        func flush(to end: Int) {
            guard start < end else { return }
            pieces.append(.text(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)))
        }
        while index < bytes.count {
            if bytes[index] == 0xF4, index + 3 < bytes.count {
                let value = UInt32(bytes[index] & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12
                    | UInt32(bytes[index + 2] & 0x3F) << 6 | UInt32(bytes[index + 3] & 0x3F)
                if let atom = atom(value) {
                    flush(to: index)
                    pieces.append(.atom(atom))
                    index += 4
                    start = index
                    continue
                }
            }
            index += 1
        }
        flush(to: bytes.count)
        return pieces
    }
}

/// One parser's shim (ots_commonmark.h or ots_gfm.h), so one walker reads either tree.
private struct CMarkLibrary {
    typealias Bytes = (UnsafeRawPointer?, UnsafeMutablePointer<Int>?) -> UnsafePointer<CChar>?
    typealias Number = (UnsafeRawPointer?) -> Int32

    /// Text, its length and the table cell budget, which only cmark-gfm has tables to spend.
    let parse: (UnsafePointer<CChar>?, Int, Int64) -> OpaquePointer?
    let free: (OpaquePointer?) -> Void
    let tableCellsExhausted: (OpaquePointer?) -> Bool
    let root: (OpaquePointer?) -> UnsafeRawPointer?
    let referenceCount: (OpaquePointer?) -> Int
    let referencePart: (OpaquePointer?, Int, Int32, UnsafeMutablePointer<Int>?) -> UnsafePointer<CChar>?
    let firstChild: (UnsafeRawPointer?) -> UnsafeRawPointer?
    let next: (UnsafeRawPointer?) -> UnsafeRawPointer?
    let kind: Number
    let literal: Bytes
    let url: Bytes
    let title: Bytes
    let fenceInfo: Bytes
    let headingLevel: Number
    let listOrdered: Number
    let listStart: Number
    let listTight: Number
    let startLine: Number
    let startColumn: Number
    let endLine: Number
    let endColumn: Number
    let taskState: Number
    let tableColumnCount: Number
    let tableAlignment: (UnsafeRawPointer?, Int32) -> Int32
    let tableRowIsHeader: Number

    static var commonMark: CMarkLibrary {
        CMarkLibrary(
            parse: { text, length, _ in otscm_parse(text, length) }, free: otscm_document_free,
            tableCellsExhausted: { _ in false }, root: otscm_document_root,
            referenceCount: otscm_reference_count, referencePart: otscm_reference_part,
            firstChild: otscm_node_first_child, next: otscm_node_next, kind: otscm_node_kind,
            literal: otscm_node_literal, url: otscm_node_url, title: otscm_node_title,
            fenceInfo: otscm_node_fence_info, headingLevel: otscm_node_heading_level,
            listOrdered: otscm_node_list_ordered, listStart: otscm_node_list_start,
            listTight: otscm_node_list_tight, startLine: otscm_node_start_line,
            startColumn: otscm_node_start_column, endLine: otscm_node_end_line,
            endColumn: otscm_node_end_column,
            taskState: { _ in -1 }, tableColumnCount: { _ in 0 }, tableAlignment: { _, _ in -1 },
            tableRowIsHeader: { _ in -1 }
        )
    }

    static var gfm: CMarkLibrary {
        CMarkLibrary(
            parse: otsgfm_parse, free: otsgfm_document_free,
            tableCellsExhausted: { otsgfm_document_table_cells_exhausted($0) != 0 }, root: otsgfm_document_root,
            referenceCount: otsgfm_reference_count, referencePart: otsgfm_reference_part,
            firstChild: otsgfm_node_first_child, next: otsgfm_node_next, kind: otsgfm_node_kind,
            literal: otsgfm_node_literal, url: otsgfm_node_url, title: otsgfm_node_title,
            fenceInfo: otsgfm_node_fence_info, headingLevel: otsgfm_node_heading_level,
            listOrdered: otsgfm_node_list_ordered, listStart: otsgfm_node_list_start,
            listTight: otsgfm_node_list_tight, startLine: otsgfm_node_start_line,
            startColumn: otsgfm_node_start_column, endLine: otsgfm_node_end_line,
            endColumn: otsgfm_node_end_column,
            taskState: otsgfm_node_task_state, tableColumnCount: otsgfm_table_column_count,
            tableAlignment: otsgfm_table_alignment, tableRowIsHeader: otsgfm_table_row_is_header
        )
    }
}

/// The shims' node kinds; ots_commonmark.h and ots_gfm.h give both libraries the same numbers.
private enum NodeKind {
    case document, blockQuote, list, item, codeBlock, htmlBlock, paragraph, heading, thematicBreak
    case table, tableRow, tableCell
    case text, softBreak, lineBreak, code, htmlInline, emphasis, strong, link, image, strikethrough
    case other

    init(_ raw: Int32) {
        switch Int(raw) {
        case Int(OTSCM_KIND_DOCUMENT): self = .document
        case Int(OTSCM_KIND_BLOCK_QUOTE): self = .blockQuote
        case Int(OTSCM_KIND_LIST): self = .list
        case Int(OTSCM_KIND_ITEM): self = .item
        case Int(OTSCM_KIND_CODE_BLOCK): self = .codeBlock
        case Int(OTSCM_KIND_HTML_BLOCK): self = .htmlBlock
        case Int(OTSCM_KIND_PARAGRAPH): self = .paragraph
        case Int(OTSCM_KIND_HEADING): self = .heading
        case Int(OTSCM_KIND_THEMATIC_BREAK): self = .thematicBreak
        case Int(OTSCM_KIND_TABLE): self = .table
        case Int(OTSCM_KIND_TABLE_ROW): self = .tableRow
        case Int(OTSCM_KIND_TABLE_CELL): self = .tableCell
        case Int(OTSCM_KIND_TEXT): self = .text
        case Int(OTSCM_KIND_SOFTBREAK): self = .softBreak
        case Int(OTSCM_KIND_LINEBREAK): self = .lineBreak
        case Int(OTSCM_KIND_CODE): self = .code
        case Int(OTSCM_KIND_HTML_INLINE): self = .htmlInline
        case Int(OTSCM_KIND_EMPH): self = .emphasis
        case Int(OTSCM_KIND_STRONG): self = .strong
        case Int(OTSCM_KIND_LINK): self = .link
        case Int(OTSCM_KIND_IMAGE): self = .image
        case Int(OTSCM_KIND_STRIKETHROUGH): self = .strikethrough
        default: self = .other
        }
    }
}

/// A block and its source span, kept until every object the walk left out has a place.
private struct PlacedBlock {
    enum Shape {
        case leaf(MarkdownBlock)
        case quote([PlacedBlock])
        case list(ordered: Bool, start: Int, tight: Bool, items: [PlacedItem])
        /// `rows` are the source lines of `body`'s rows.
        case table(
            alignments: [MarkdownAlignment?], header: [[PreviewEvent]], body: [[[PreviewEvent]]],
            rows: [ClosedRange<Int>]
        )
    }

    var shape: Shape
    let start: SourcePosition
    let end: SourcePosition

    var block: MarkdownBlock {
        switch shape {
        case .leaf(let block): return block
        case .quote(let children): return .quote(children.map(\.block))
        case .list(let ordered, let start, let tight, let items):
            return .list(ordered: ordered, start: start, tight: tight, items: items.map {
                MarkdownListItem(task: $0.task, blocks: $0.blocks.map(\.block))
            })
        case .table(let alignments, let header, let body, _):
            return .table(alignments: alignments, header: header, body: body)
        }
    }
}

private struct PlacedItem {
    let task: Bool?
    var blocks: [PlacedBlock]
    let start: SourcePosition
    let end: SourcePosition
}

/// One walk over a parsed document: it emits each object where plan R1's ownership rules put it,
/// then places the objects it never emitted by block position.
private final class TreeWalker {
    private let library: CMarkLibrary
    private let document: OpaquePointer
    private let source: PlaceholderSource
    private let limits: CompositionLimits
    /// Objects named in a reference definition's label, destination or title.
    private var definitions: Set<Int> = []
    private var emitted: [Bool]
    /// Emitted objects in walk order, so an element can tell which its own text showed.
    private var log: [Int] = []
    private var depth = 0

    init(library: CMarkLibrary, document: OpaquePointer, source: PlaceholderSource, limits: CompositionLimits) {
        self.library = library
        self.document = document
        self.source = source
        self.limits = limits
        emitted = Array(repeating: false, count: source.objectCount)
    }

    func walk() throws -> [MarkdownBlock] {
        definitions = referenceAtoms()
        guard let root = library.root(document) else { throw MarkdownParseError.parserFailure }
        var blocks = try self.blocks(of: root)
        let unplaced = emitted.indices.filter { !emitted[$0] }.map {
            Unplaced(identity: String($0), position: source.positions[$0], definition: definitions.contains($0))
        }
        Self.place(unplaced[...], in: &blocks)
        return blocks.map(\.block)
    }

    private func referenceAtoms() -> Set<Int> {
        var atoms: Set<Int> = []
        for index in 0..<library.referenceCount(document) {
            for part in [OTSCM_REFERENCE_LABEL, OTSCM_REFERENCE_URL, OTSCM_REFERENCE_TITLE] {
                var length = 0
                guard let bytes = library.referencePart(document, index, Int32(part), &length), length > 0
                else { continue }
                for case .atom(let atom) in source.pieces(UnsafeRawBufferPointer(start: bytes, count: length)) {
                    atoms.insert(atom)
                }
            }
        }
        return atoms
    }

    // MARK: Nesting and emission

    /// Each block quote, list and inline container is one level; a list's items share its level.
    private func enter() throws {
        depth += 1
        guard depth <= limits.maximumDepth else { throw MarkdownParseError.depthLimit }
    }

    private func leave() {
        depth -= 1
    }

    private func emit(_ atom: Int) throws {
        guard !emitted[atom] else { throw MarkdownParseError.duplicateObject(String(atom)) }
        emitted[atom] = true
        log.append(atom)
    }

    private func pieces(_ field: CMarkLibrary.Bytes, of node: UnsafeRawPointer) -> [Piece] {
        var length = 0
        guard let bytes = field(node, &length), length > 0 else { return [] }
        return source.pieces(UnsafeRawBufferPointer(start: bytes, count: length))
    }

    /// Text-like content: every object in it is emitted here.
    private func parts(_ field: CMarkLibrary.Bytes, of node: UnsafeRawPointer) throws -> [HTMLPart] {
        var parts: [HTMLPart] = []
        for piece in pieces(field, of: node) {
            switch piece {
            case .text(let text): parts.appendText(text)
            case .atom(let atom):
                try emit(atom)
                parts.append(.object(String(atom)))
            }
        }
        return parts
    }

    /// A destination or title. An object its definition or its element's own text shows is the
    /// stand-in U+FFFC, which the composer refuses as an address; any other is emitted here.
    private func address(
        _ field: CMarkLibrary.Bytes, of node: UnsafeRawPointer, shown: Set<Int>
    ) throws -> [HTMLPart] {
        var parts: [HTMLPart] = []
        for piece in pieces(field, of: node) {
            switch piece {
            case .text(let text): parts.appendText(text)
            case .atom(let atom) where definitions.contains(atom) || shown.contains(atom):
                parts.appendText("\u{FFFC}")
            case .atom(let atom):
                try emit(atom)
                parts.append(.object(String(atom)))
            }
        }
        return parts
    }

    private func span(_ node: UnsafeRawPointer) -> (SourcePosition, SourcePosition) {
        (SourcePosition(line: Int(library.startLine(node)), column: Int(library.startColumn(node))),
         SourcePosition(line: Int(library.endLine(node)), column: Int(library.endColumn(node))))
    }

    // MARK: Blocks

    private func blocks(of parent: UnsafeRawPointer) throws -> [PlacedBlock] {
        var blocks: [PlacedBlock] = []
        var child = library.firstChild(parent)
        while let node = child {
            blocks += try block(node)
            child = library.next(node)
        }
        return blocks
    }

    private func block(_ node: UnsafeRawPointer) throws -> [PlacedBlock] {
        let (start, end) = span(node)
        let shape: PlacedBlock.Shape
        switch NodeKind(library.kind(node)) {
        case .paragraph: shape = .leaf(.paragraph(try inlines(of: node)))
        case .heading: shape = .leaf(.heading(level: Int(library.headingLevel(node)), try inlines(of: node)))
        case .codeBlock:
            // The info string's objects belong to the block and open it.
            let info = try parts(library.fenceInfo, of: node)
            shape = .leaf(.codeBlock(info: info, literal: try parts(library.literal, of: node)))
        case .htmlBlock: shape = .leaf(.html(try parts(library.literal, of: node)))
        case .thematicBreak: shape = .leaf(.thematicBreak)
        case .table: shape = try table(node)
        case .blockQuote:
            try enter()
            defer { leave() }
            shape = .quote(try blocks(of: node))
        case .list:
            try enter()
            defer { leave() }
            shape = .list(
                ordered: library.listOrdered(node) == 1, start: Int(library.listStart(node)),
                tight: library.listTight(node) == 1, items: try items(of: node)
            )
        default:
            try enter()
            defer { leave() }
            return try blocks(of: node)
        }
        return [PlacedBlock(shape: shape, start: start, end: end)]
    }

    private func items(of list: UnsafeRawPointer) throws -> [PlacedItem] {
        var items: [PlacedItem] = []
        var child = library.firstChild(list)
        while let node = child {
            if NodeKind(library.kind(node)) == .item {
                let (start, end) = span(node)
                let state = library.taskState(node)
                items.append(PlacedItem(
                    task: state < 0 ? nil : state == 1, blocks: try blocks(of: node), start: start, end: end
                ))
            }
            child = library.next(node)
        }
        return items
    }

    /// Cells as cmark-gfm keeps them: one per column, a row's excess cells dropped.
    private func table(_ node: UnsafeRawPointer) throws -> PlacedBlock.Shape {
        let alignments: [MarkdownAlignment?] = (0..<max(0, Int(library.tableColumnCount(node)))).map { column in
            // ots_gfm.h: 1 left, 2 center, 3 right.
            switch library.tableAlignment(node, Int32(column)) {
            case 1: return .left
            case 2: return .center
            case 3: return .right
            default: return nil
            }
        }
        var header: [[PreviewEvent]]?
        var body: [[[PreviewEvent]]] = []
        var rows: [ClosedRange<Int>] = []
        var row = library.firstChild(node)
        while let current = row {
            if NodeKind(library.kind(current)) == .tableRow {
                var cells: [[PreviewEvent]] = []
                var cell = library.firstChild(current)
                while let each = cell {
                    if NodeKind(library.kind(each)) == .tableCell { cells.append(try inlines(of: each)) }
                    cell = library.next(each)
                }
                if header == nil, library.tableRowIsHeader(current) == 1 {
                    header = cells
                } else {
                    body.append(cells)
                    let (start, end) = span(current)
                    rows.append(start.line...max(start.line, end.line))
                }
            }
            row = library.next(current)
        }
        return .table(alignments: alignments, header: header ?? [], body: body, rows: rows)
    }

    // MARK: Inlines

    private func inlines(of parent: UnsafeRawPointer) throws -> [PreviewEvent] {
        var events: [PreviewEvent] = []
        try appendInlines(of: parent, to: &events)
        return events
    }

    private func appendInlines(of parent: UnsafeRawPointer, to events: inout [PreviewEvent]) throws {
        var child = library.firstChild(parent)
        while let node = child {
            try inline(node, into: &events)
            child = library.next(node)
        }
    }

    private func inline(_ node: UnsafeRawPointer, into events: inout [PreviewEvent]) throws {
        switch NodeKind(library.kind(node)) {
        case .text: events.appendParts(try parts(library.literal, of: node))
        case .softBreak: events.append(.softBreak)
        case .lineBreak: events.append(.hardBreak)
        case .code:
            events.append(.enterMarkdown(.code))
            events.appendParts(try parts(library.literal, of: node))
            events.append(.leaveMarkdown(.code))
        case .htmlInline: events.append(.rawHTML(try parts(library.literal, of: node)))
        case .emphasis: try trait(.emphasis, node, into: &events)
        case .strong: try trait(.strong, node, into: &events)
        case .strikethrough: try trait(.deletion, node, into: &events)
        case .link:
            try enter()
            defer { leave() }
            let mark = log.count
            var label: [PreviewEvent] = []
            try appendInlines(of: node, to: &label)
            let shown = Set(log[mark...])
            let destination = try address(library.url, of: node, shown: shown)
            let title = try address(library.title, of: node, shown: shown)
            events.append(.enterLink(destination: destination, title: title))
            events += label
            events.append(.leaveLink)
        case .image:
            try enter()
            defer { leave() }
            let mark = log.count
            var alt: [HTMLPart] = []
            try appendAlt(of: node, to: &alt)
            let shown = Set(log[mark...])
            let destination = try address(library.url, of: node, shown: shown)
            events.append(.markdownImage(
                alt: alt, destination: destination, title: try address(library.title, of: node, shown: shown)
            ))
        default:
            try enter()
            defer { leave() }
            try appendInlines(of: node, to: &events)
        }
    }

    private func trait(_ trait: PreviewTrait, _ node: UnsafeRawPointer, into events: inout [PreviewEvent]) throws {
        try enter()
        defer { leave() }
        events.append(.enterMarkdown(trait))
        try appendInlines(of: node, to: &events)
        events.append(.leaveMarkdown(trait))
    }

    /// An image description as cmark's HTML writer gives it: text, code and raw HTML literals,
    /// each break a space. A nested link or image's own address objects stand where it opens.
    private func appendAlt(of parent: UnsafeRawPointer, to alt: inout [HTMLPart]) throws {
        var child = library.firstChild(parent)
        while let node = child {
            switch NodeKind(library.kind(node)) {
            case .text, .code, .htmlInline: alt.appendParts(try parts(library.literal, of: node))
            case .softBreak, .lineBreak: alt.appendText(" ")
            case .link, .image:
                try enter()
                defer { leave() }
                let mark = log.count
                var inner: [HTMLPart] = []
                try appendAlt(of: node, to: &inner)
                let shown = Set(log[mark...])
                let own = try address(library.url, of: node, shown: shown)
                    + address(library.title, of: node, shown: shown)
                alt.appendParts(own.objectIdentities.map(HTMLPart.object))
                alt.appendParts(inner)
            default:
                try enter()
                defer { leave() }
                try appendAlt(of: node, to: &alt)
            }
            child = library.next(node)
        }
    }

    // MARK: Placement

    private struct Unplaced {
        let identity: String
        let position: SourcePosition
        let definition: Bool
    }

    /// Puts each object the walk never emitted inside the deepest container whose span covers
    /// it, before the first child after it; inside a leaf, before it for a definition's object.
    /// A table row's dropped cell gives its object to the row's last kept cell.
    /// `unplaced` is in source order, as siblings are, so each is found by binary search.
    private static func place(_ unplaced: ArraySlice<Unplaced>, in blocks: inout [PlacedBlock]) {
        guard !unplaced.isEmpty else { return }
        var insertions: [(index: Int, object: Unplaced)] = []
        var nested: [Int: [Unplaced]] = [:]
        for object in unplaced {
            let after = firstIndex(in: blocks.count) { object.position < blocks[$0].start }
            guard after > 0, object.position <= blocks[after - 1].end else {
                insertions.append((after, object))
                continue
            }
            switch blocks[after - 1].shape {
            case .quote: nested[after - 1, default: []].append(object)
            case .list(_, _, _, let items) where !items.isEmpty: nested[after - 1, default: []].append(object)
            case .table(_, _, let body, let rows) where row(of: object.position.line, in: rows, body) != nil:
                nested[after - 1, default: []].append(object)
            default: insertions.append((object.definition ? after - 1 : after, object))
            }
        }
        for (index, objects) in nested {
            switch blocks[index].shape {
            case .quote(var children):
                place(objects[...], in: &children)
                blocks[index].shape = .quote(children)
            case .list(let ordered, let start, let tight, var items):
                // Between two items, the earlier one takes it.
                var byItem: [Int: [Unplaced]] = [:]
                for object in objects {
                    let after = firstIndex(in: items.count) { object.position < items[$0].start }
                    byItem[max(0, after - 1), default: []].append(object)
                }
                for (item, objects) in byItem { place(objects[...], in: &items[item].blocks) }
                blocks[index].shape = .list(ordered: ordered, start: start, tight: tight, items: items)
            case .table(let alignments, let header, var body, let rows):
                for object in objects {
                    guard let row = row(of: object.position.line, in: rows, body) else { continue }
                    body[row][body[row].count - 1].append(.object(object.identity))
                }
                blocks[index].shape = .table(alignments: alignments, header: header, body: body, rows: rows)
            case .leaf: break
            }
        }
        guard !insertions.isEmpty else { return }
        // Stable, so objects at one index keep source order.
        let queue = insertions.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element)
        var result: [PlacedBlock] = []
        result.reserveCapacity(blocks.count + queue.count)
        var next = 0
        for index in 0...blocks.count {
            var objects: [Unplaced] = []
            while next < queue.count, queue[next].index == index {
                objects.append(queue[next].object)
                next += 1
            }
            if let first = objects.first {
                result.append(PlacedBlock(
                    shape: .leaf(.objects(objects.map(\.identity))), start: first.position, end: first.position
                ))
            }
            if index < blocks.count { result.append(blocks[index]) }
        }
        blocks = result
    }

    /// The body row on `line`, when it has a cell to take an object.
    private static func row(of line: Int, in rows: [ClosedRange<Int>], _ body: [[[PreviewEvent]]]) -> Int? {
        let after = firstIndex(in: rows.count) { line < rows[$0].lowerBound }
        guard after > 0, rows[after - 1].contains(line), !body[after - 1].isEmpty else { return nil }
        return after - 1
    }

    /// The first index in `0..<count` where `isPast` turns true, for a predicate false then true.
    private static func firstIndex(in count: Int, where isPast: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isPast(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

private extension Array where Element == HTMLPart {
    /// Joins adjacent text in place; cmark splits text at entities and delimiter runs.
    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(var joined)? = last {
            removeLast()
            joined += text
            append(.text(joined))
        } else {
            append(.text(text))
        }
    }

    mutating func appendParts(_ parts: [HTMLPart]) {
        for part in parts {
            switch part {
            case .text(let text): appendText(text)
            case .object: append(part)
            }
        }
    }
}

private extension Array where Element == PreviewEvent {
    /// Text parts as text events, joined in place as `[HTMLPart].appendText` joins them.
    mutating func appendParts(_ parts: [HTMLPart]) {
        for part in parts {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if case .text(var joined)? = last {
                    removeLast()
                    joined += text
                    append(.text(joined))
                } else {
                    append(.text(text))
                }
            case .object(let identity): append(.object(identity))
            }
        }
    }
}
