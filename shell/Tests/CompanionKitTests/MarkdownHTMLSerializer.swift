@testable import CompanionKit

/// A parsed page written as cmark 0.31.2's HTML writer writes the spec examples (unsafe mode),
/// with cmark-gfm's table, strikethrough and tagfilter output under GFM; each object is U+FFFC.
struct MarkdownHTMLSerializer {
    let dialect: PreviewDialect
    private var html = ""

    private init(dialect: PreviewDialect) {
        self.dialect = dialect
    }

    static func html(_ document: MarkdownDocument, dialect: PreviewDialect) -> String {
        var writer = MarkdownHTMLSerializer(dialect: dialect)
        writer.blocks(document.blocks, tight: false)
        return writer.html
    }

    /// cmark's `cr()`: a newline unless the output is empty or already ends in one.
    private mutating func cr() {
        if let last = html.unicodeScalars.last, last != "\n" { html.unicodeScalars.append("\n") }
    }

    /// `tight` is the enclosing list's, for blocks that are an item's own children.
    private mutating func blocks(_ blocks: [MarkdownBlock], tight: Bool) {
        for block in blocks { self.block(block, tight: tight) }
    }

    private mutating func block(_ block: MarkdownBlock, tight: Bool) {
        switch block {
        case .paragraph(let events):
            if tight {
                inlines(events)
            } else {
                cr()
                html += "<p>"
                inlines(events)
                html += "</p>\n"
            }
        case .heading(let level, let events):
            cr()
            html += "<h\(level)>"
            inlines(events)
            html += "</h\(level)>\n"
        case .codeBlock(let info, let literal):
            cr()
            let info = Self.joined(info)
            if info.isEmpty {
                html += "<pre><code>"
            } else {
                html += "<pre><code class=\""
                // cmark 0.31.2 keeps an info string that already starts `language-`; cmark-gfm always prefixes.
                if dialect == .gfm || !info.utf8.starts(with: "language-".utf8) { html += "language-" }
                let word = info.utf8.prefix { !Self.isSpace($0) }
                html += Self.escapeHTML(String(decoding: word, as: UTF8.self))
                html += "\">"
            }
            html += Self.escapeHTML(Self.joined(literal))
            html += "</code></pre>\n"
        case .html(let parts):
            cr()
            let literal = Self.joined(parts)
            html += dialect == .gfm ? Self.filterBlock(literal) : literal
            cr()
        case .thematicBreak:
            cr()
            html += "<hr />\n"
        case .quote(let children):
            cr()
            html += "<blockquote>\n"
            blocks(children, tight: false)
            cr()
            html += "</blockquote>\n"
        case .list(let ordered, let start, let tight, let items):
            cr()
            html += !ordered ? "<ul>\n" : start == 1 ? "<ol>\n" : "<ol start=\"\(start)\">\n"
            for item in items {
                cr()
                html += "<li>"
                // The GFM spec's form of the box, not cmark-gfm's (examples 279 and 280).
                if let checked = item.task {
                    html += checked ? "<input checked=\"\" disabled=\"\" type=\"checkbox\"> " : "<input disabled=\"\" type=\"checkbox\"> "
                }
                blocks(item.blocks, tight: tight)
                html += "</li>\n"
            }
            html += ordered ? "</ol>\n" : "</ul>\n"
        case .table(let alignments, let header, let body):
            cr()
            html += "<table>"
            row(header, alignments: alignments, isHeader: true, opensBody: false)
            for (index, cells) in body.enumerated() {
                row(cells, alignments: alignments, isHeader: false, opensBody: index == 0)
            }
            if !body.isEmpty {
                cr()
                html += "</tbody>"
                cr()
            }
            cr()
            html += "</table>"
            cr()
        case .objects(let identities):
            html += String(repeating: "\u{FFFC}", count: identities.count)
        }
    }

    private mutating func row(
        _ cells: [[PreviewEvent]], alignments: [MarkdownAlignment?], isHeader: Bool, opensBody: Bool
    ) {
        cr()
        if isHeader {
            html += "<thead>"
            cr()
        } else if opensBody {
            html += "<tbody>"
            cr()
        }
        html += "<tr>"
        for (column, events) in cells.enumerated() {
            cr()
            html += isHeader ? "<th" : "<td"
            switch column < alignments.count ? alignments[column] : nil {
            case .left: html += " align=\"left\""
            case .center: html += " align=\"center\""
            case .right: html += " align=\"right\""
            case nil: break
            }
            html += ">"
            inlines(events)
            html += isHeader ? "</th>" : "</td>"
        }
        cr()
        html += "</tr>"
        if isHeader {
            cr()
            html += "</thead>"
        }
    }

    private mutating func inlines(_ events: [PreviewEvent]) {
        for event in events {
            switch event {
            case .text(let text): html += Self.escapeHTML(text)
            case .object: html += "\u{FFFC}"
            case .enterMarkdown(let trait): html += "<\(Self.tag(trait))>"
            case .leaveMarkdown(let trait): html += "</\(Self.tag(trait))>"
            case .blockBoundary: break
            case .softBreak: html += "\n"
            case .hardBreak: html += "<br />\n"
            case .rawHTML(let parts):
                let literal = Array(Self.joined(parts).utf8)
                if dialect == .gfm, Self.isDisallowedTag(literal, at: 0) {
                    html += "&lt;" + String(decoding: literal.dropFirst(), as: UTF8.self)
                } else {
                    html += String(decoding: literal, as: UTF8.self)
                }
            case .markdownImage(let alt, let destination, let title):
                html += "<img src=\"" + Self.escapeHref(destination ?? []) + "\" alt=\"" + Self.escapeHTML(Self.joined(alt))
                let title = Self.joined(title)
                if !title.isEmpty { html += "\" title=\"" + Self.escapeHTML(title) }
                html += "\" />"
            case .enterLink(let destination, let title):
                html += "<a href=\"" + Self.escapeHref(destination ?? [])
                let title = Self.joined(title)
                if !title.isEmpty { html += "\" title=\"" + Self.escapeHTML(title) }
                html += "\">"
            case .leaveLink: html += "</a>"
            }
        }
    }

    private static func tag(_ trait: PreviewTrait) -> String {
        switch trait {
        case .emphasis: return "em"
        case .strong: return "strong"
        case .deletion: return "del"
        case .code: return "code"
        }
    }

    private static func joined(_ parts: [HTMLPart]) -> String {
        parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .object: return "\u{FFFC}"
            }
        }.joined()
    }

    /// cmark's `cmark_isspace`: tab, line feed, carriage return and space.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }

    /// houdini_escape_html without its secure mode: `'` and `/` pass.
    static func escapeHTML(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped.append(contentsOf: "&amp;".unicodeScalars)
            case "<": escaped.append(contentsOf: "&lt;".unicodeScalars)
            case ">": escaped.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": escaped.append(contentsOf: "&quot;".unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    /// houdini's HREF_SAFE table, byte for byte (src/houdini_href_e.c).
    private static let hrefSafe: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]

    /// houdini_escape_href over each text part's UTF-8; an object part is written as U+FFFC.
    static func escapeHref(_ parts: [HTMLPart]) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var escaped: [UInt8] = []
        for part in parts {
            guard case .text(let text) = part else {
                escaped += Array("\u{FFFC}".utf8)
                continue
            }
            for byte in text.utf8 {
                if hrefSafe[Int(byte)] != 0 {
                    escaped.append(byte)
                } else if byte == UInt8(ascii: "&") {
                    escaped += Array("&amp;".utf8)
                } else if byte == UInt8(ascii: "'") {
                    escaped += Array("&#x27;".utf8)
                } else {
                    escaped += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
                }
            }
        }
        return String(decoding: escaped, as: UTF8.self)
    }

    private static let disallowed = [
        "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext",
    ].map { Array($0.utf8) }

    /// cmark-gfm's `filter_html_block`: every `<` that opens a disallowed tag becomes `&lt;`.
    private static func filterBlock(_ literal: String) -> String {
        let bytes = Array(literal.utf8)
        var filtered: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            if byte == UInt8(ascii: "<"), isDisallowedTag(bytes, at: index) {
                filtered += Array("&lt;".utf8)
            } else {
                filtered.append(byte)
            }
        }
        return String(decoding: filtered, as: UTF8.self)
    }

    private static func isDisallowedTag(_ bytes: [UInt8], at start: Int) -> Bool {
        disallowed.contains { isTag(bytes, at: start, named: $0) }
    }

    /// cmark-gfm tagfilter's `is_tag`, reading `bytes` from `start` to the end.
    private static func isTag(_ bytes: [UInt8], at start: Int, named name: [UInt8]) -> Bool {
        let size = bytes.count - start
        guard size >= 3, bytes[start] == UInt8(ascii: "<") else { return false }
        var index = 1
        if bytes[start + index] == UInt8(ascii: "/") { index += 1 }
        var matched = 0
        while index < size, matched < name.count {
            var byte = bytes[start + index]
            if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
            guard byte == name[matched] else { return false }
            index += 1
            matched += 1
        }
        if index == size { return false }
        let next = bytes[start + index]
        if isSpace(next) || next == UInt8(ascii: ">") { return true }
        return next == UInt8(ascii: "/") && size >= index + 2 && bytes[start + index + 1] == UInt8(ascii: ">")
    }
}
