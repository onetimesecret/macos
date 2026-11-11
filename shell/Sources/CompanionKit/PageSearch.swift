import Foundation

/// One text the palette's search reads: a page's public text or an open file's buffer.
public struct PageSearchSource: Equatable, Sendable {
    /// The tab's id for a page, the file's id for a file.
    public let id: UInt64
    public let title: String
    /// Unix epoch milliseconds, or nil for a source with no stamp.
    public let stamp: UInt64?
    public let text: String

    public init(id: UInt64, title: String, stamp: UInt64?, text: String) {
        self.id = id
        self.title = title
        self.stamp = stamp
        self.text = text
    }
}

/// The texts one search reads, and whether any was left out for its size.
public struct PageSearchSources: Equatable, Sendable {
    public let sources: [PageSearchSource]
    public let skipped: Bool
}

/// One matching line of one source.
public struct PageSearchRow: Equatable, Sendable {
    public let id: UInt64
    public let title: String
    public let stamp: UInt64?
    /// The matching line's zero-based index in the source's text.
    public let line: Int
    public let excerpt: String
}

public enum PageSearch {
    public static let rowCap = 50
    public static let excerptLength = 80
    /// A text past this many UTF-8 bytes waits for Return.
    public static let keystrokeByteLimit = 1 << 20
    private static let excerptLead = 20

    /// Every line holding all of `query`'s words, newest stamp first and then in line order.
    public static func rows(
        for query: String, in sources: [PageSearchSource], cap: Int = rowCap
    ) -> [PageSearchRow] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !words.isEmpty, cap > 0 else { return [] }
        let ordered = sources.enumerated().sorted { lhs, rhs in
            switch (lhs.element.stamp, rhs.element.stamp) {
            case let (a?, b?) where a != b: return a > b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }
        var rows: [PageSearchRow] = []
        for (_, source) in ordered {
            let lines = source.text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            for (index, line) in lines.enumerated() {
                let text = String(line)
                guard words.allSatisfy({ text.localizedStandardContains($0) }) else { continue }
                rows.append(PageSearchRow(id: source.id, title: source.title, stamp: source.stamp,
                    line: index, excerpt: excerpt(of: text, around: words)))
                if rows.count == cap { return rows }
            }
        }
        return rows
    }

    /// `line` cut to `excerptLength` characters around its first matching word.
    static func excerpt(of line: String, around words: [String]) -> String {
        let count = line.count
        guard count > excerptLength else { return line.trimmingCharacters(in: .whitespaces) }
        let first = words.compactMap { line.localizedStandardRange(of: $0)?.lowerBound }.min() ?? line.startIndex
        let match = line.distance(from: line.startIndex, to: first)
        let start = min(max(0, match - excerptLead), count - excerptLength)
        let from = line.index(line.startIndex, offsetBy: start)
        let to = line.index(from, offsetBy: excerptLength)
        let body = line[from..<to].trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + body + (start + excerptLength < count ? "…" : "")
    }

    /// Where line `line` of `text` starts in UTF-16 units, counting lines as `rows` does.
    public static func utf16Offset(ofLine line: Int, in text: String) -> Int? {
        guard line > 0 else { return line == 0 ? 0 : nil }
        var seen = 0
        for index in text.indices where text[index].isNewline {
            seen += 1
            if seen == line { return text.index(after: index).utf16Offset(in: text) }
        }
        return nil
    }
}
