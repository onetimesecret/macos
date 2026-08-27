import Foundation

/// Color inside a fenced code block, and nowhere else on the page.
///
/// The page is already monospaced, so a fenced block differs from a
/// paragraph only by the wash behind it, and the fence's info string is
/// parsed and then thrown away. This is what reads that info string and
/// says which spans of each line are keyword, string, comment or
/// number, so `styleParagraph` has something to lay color down on.
///
/// Three commitments, each argued in
/// docs/spec/feature/lists-and-highlighting (part 2) and standing on
/// design principle 4, frugal:
///
/// - **No grammar engine.** A third-party highlighter is megabytes and
///   a supply chain for four colors. What is here is one linear scan
///   over UTF-16 units with no dependency beyond Foundation.
/// - **Languages are table entries, not code.** Adding a language is
///   adding a literal to `specs` and its nicknames to `aliases`. A
///   language that needs new code to be recognized is beyond this
///   file's ceiling and does not belong in the table.
/// - **Guessing is worse than plain ink.** A bare fence, an unknown
///   info string or an unlisted language yields zero tokens and the
///   block renders exactly as it did before highlighting existed. The
///   info string is the only signal; nothing here sniffs content.
///
/// Nothing here changes a byte. This is display-only styling under
/// amendment B's contract: select-all-copy still returns exactly what
/// was typed, and the recognition surfaces (chips, the ledger, the
/// resting glance) stay uncolored.
public enum CodeInk {
    // MARK: - What a token is

    /// The four things a span of code can be. Four is the ceiling, not
    /// a first instalment: types, attributes, operators and string
    /// interpolation are recognition beyond what a little text file
    /// owes its reader, and every one of them costs a grammar.
    public enum TokenKind: String, Equatable, Sendable {
        case keyword
        case string
        case comment
        case number
    }

    /// One colored span of one line. The range is in UTF-16 offsets
    /// into the line it was read from, because `NSTextStorage` counts
    /// in UTF-16 and an accented letter or an emoji makes every other
    /// count wrong by a character or two.
    public struct Token: Equatable, Sendable {
        public let range: NSRange
        public let kind: TokenKind

        public init(range: NSRange, kind: TokenKind) {
            self.range = range
            self.kind = kind
        }
    }

    // MARK: - What a language is

    /// Which number literals a language writes. The distinction earns
    /// its place because the radix prefix is the one number rule that
    /// genuinely differs across this table: `0xff` is a number in Rust
    /// and a malformed word in a shell script.
    public enum NumberLiterals: Sendable {
        /// Digits, a fraction, an exponent. Nothing else is a number.
        case decimal
        /// The above, plus `0x`, `0o` and `0b` radix prefixes and `_`
        /// digit separators.
        case cStyle
    }

    /// Everything the scanner needs to know about one language, as
    /// data. A language that cannot be described by these fields is a
    /// language this file declines to highlight, which is the whole
    /// discipline: the table grows, the scanner does not.
    public struct LanguageSpec: Sendable {
        /// Words that color as keywords when they stand alone. Written
        /// as reserved words only; library names and builtins are
        /// somebody's variable somewhere, and a false purple is worse
        /// than a missing one.
        public let keywords: Set<String>
        /// True where a language's reserved words are case-blind, which
        /// in this table means SQL and only SQL. `SELECT` is how most
        /// people write it, so a case-sensitive SQL entry would color
        /// almost nothing anyone actually types.
        public let foldsKeywordCase: Bool
        /// Openers that turn the rest of the line into a comment.
        public let lineComments: [String]
        /// The pair that opens and closes a comment spanning lines.
        public let blockComment: (open: String, close: String)?
        /// Quotes that open a string ending on the same line.
        public let strings: [String]
        /// Quotes that open a string allowed to run past end of line.
        public let multilineStrings: [String]
        /// Whether a backslash inside a string hides the character
        /// after it. True nearly everywhere; false in SQL, which
        /// doubles the quote instead.
        public let escapesInStrings: Bool
        public let numbers: NumberLiterals

        public init(
            keywords: Set<String>,
            foldsKeywordCase: Bool = false,
            lineComments: [String] = [],
            blockComment: (open: String, close: String)? = nil,
            strings: [String] = [],
            multilineStrings: [String] = [],
            escapesInStrings: Bool = true,
            numbers: NumberLiterals = .decimal
        ) {
            self.keywords = keywords
            self.foldsKeywordCase = foldsKeywordCase
            self.lineComments = lineComments
            self.blockComment = blockComment
            self.strings = strings
            self.multilineStrings = multilineStrings
            self.escapesInStrings = escapesInStrings
            self.numbers = numbers
        }
    }

    /// A keyword list, written as prose and read as a set. Reserved
    /// words are the one place where a wall of text is the clearest
    /// form: the diff when a language gains a word is one word.
    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    // MARK: - The table

    /// The twelve languages of v1, chosen because they are what this
    /// project's own notes and pastes are made of. `c`, `cpp`, `html`
    /// and `css` are deliberately absent: the table makes them a
    /// follow-up commit rather than a design question, and dogfood
    /// gets to vote first.
    public static let specs: [String: LanguageSpec] = [
        "swift": LanguageSpec(
            keywords: words("""
                actor any as associatedtype async await break case catch class continue default
                defer deinit do else enum extension fallthrough false fileprivate final for func
                guard if import in init inout internal is lazy let mutating nil nonisolated open
                operator private protocol public repeat rethrows return self Self some static
                struct subscript super switch throw throws true try typealias unowned var weak
                where while
                """),
            lineComments: ["//"],
            blockComment: ("/*", "*/"),
            strings: ["\""],
            multilineStrings: ["\"\"\""],
            numbers: .cStyle
        ),
        "rust": LanguageSpec(
            keywords: words("""
                as async await break const continue crate dyn else enum extern false fn for if
                impl in let loop match mod move mut pub ref return self Self static struct super
                trait true type union unsafe use where while
                """),
            lineComments: ["//"],
            blockComment: ("/*", "*/"),
            // Only the double quote. Rust spells a lifetime `'a`, so
            // taking the single quote as a string delimiter would paint
            // the rest of every line that holds a borrow.
            strings: ["\""],
            numbers: .cStyle
        ),
        "python": LanguageSpec(
            keywords: words("""
                and as assert async await break class continue def del elif else except False
                finally for from global if import in is lambda None nonlocal not or pass raise
                return self True try while with yield
                """),
            lineComments: ["#"],
            strings: ["\"", "'"],
            multilineStrings: ["\"\"\"", "'''"],
            numbers: .cStyle
        ),
        "ruby": LanguageSpec(
            keywords: words("""
                alias and begin break case class def defined do else elsif end ensure false for
                if in module next nil not or redo rescue retry return self super then true undef
                unless until when while yield
                """),
            lineComments: ["#"],
            // A heredoc is Ruby's multiline string and it names its own
            // terminator, which is a grammar rather than a delimiter.
            // Left out on purpose: a heredoc body renders as plain ink.
            strings: ["\"", "'"],
            numbers: .cStyle
        ),
        "javascript": LanguageSpec(
            keywords: words("""
                async await break case catch class const continue debugger default delete do else
                export extends false finally for from function get if import in instanceof let new
                null of return set static super switch this throw true try typeof undefined var
                void while with yield
                """),
            lineComments: ["//"],
            blockComment: ("/*", "*/"),
            strings: ["\"", "'"],
            multilineStrings: ["`"],
            numbers: .cStyle
        ),
        "typescript": LanguageSpec(
            keywords: words("""
                abstract as asserts async await break case catch class const continue debugger
                declare default delete do else enum export extends false finally for from function
                get if implements import in infer instanceof interface is keyof let namespace new
                null of override private protected public readonly return satisfies set static
                super switch this throw true try type typeof undefined unique var void while with
                yield
                """),
            lineComments: ["//"],
            blockComment: ("/*", "*/"),
            strings: ["\"", "'"],
            multilineStrings: ["`"],
            numbers: .cStyle
        ),
        "go": LanguageSpec(
            keywords: words("""
                break case chan const continue default defer else fallthrough false for func go
                goto if import interface iota map nil package range return select struct switch
                true type var
                """),
            lineComments: ["//"],
            blockComment: ("/*", "*/"),
            strings: ["\"", "'"],
            multilineStrings: ["`"],
            numbers: .cStyle
        ),
        "shell": LanguageSpec(
            keywords: words("""
                alias break case continue declare do done elif else esac eval exec exit export fi
                for function if in local readonly return select set shift source then trap unset
                until while
                """),
            lineComments: ["#"],
            strings: ["\"", "'"]
        ),
        "sql": LanguageSpec(
            keywords: words("""
                add all alter and as asc begin between by case column commit constraint create
                cross default delete desc distinct drop else end exists foreign from full group
                having if in index inner insert into is join key left like limit not null offset
                on or order outer primary references rename returning right rollback select set
                table then transaction truncate union unique update using values view when where
                with
                """),
            foldsKeywordCase: true,
            lineComments: ["--"],
            blockComment: ("/*", "*/"),
            // The double quote spells an identifier in standard SQL,
            // not a string, so the single quote is the only string
            // delimiter here.
            strings: ["'"],
            escapesInStrings: false
        ),
        "json": LanguageSpec(
            keywords: words("true false null"),
            strings: ["\""]
        ),
        "yaml": LanguageSpec(
            // Three words only. A plain YAML scalar is unquoted prose,
            // so every word added here is a word that will one day
            // color in the middle of somebody's sentence.
            keywords: words("true false null"),
            lineComments: ["#"],
            strings: ["\"", "'"]
        ),
        "toml": LanguageSpec(
            keywords: words("true false"),
            lineComments: ["#"],
            strings: ["\"", "'"],
            multilineStrings: ["\"\"\"", "'''"],
            numbers: .cStyle
        ),
    ]

    /// What people actually type in a fence's info string. Kept beside
    /// the table rather than in it so a nickname costs a line and an
    /// argument costs nothing: an alias is a claim that two names mean
    /// the same highlighting, which for `zsh` and `sh` is true at this
    /// resolution even though the shells differ.
    public static let aliases: [String: String] = [
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "node": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "py": "python",
        "python3": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "shell",
        "bash": "shell",
        "zsh": "shell",
        "ksh": "shell",
        "console": "shell",
        "yml": "yaml",
        "golang": "go",
        "psql": "sql",
        "postgres": "sql",
        "postgresql": "sql",
        "mysql": "sql",
        "sqlite": "sql",
    ]

    /// The language a fence's info string names, if this file knows it.
    /// An info string can carry more than a language (` ```js
    /// title=main.js `), so only its first whitespace-delimited token
    /// is read, and it is lowercased before the table is asked: a fence
    /// saying `Swift` means swift.
    public static func canonicalLanguage(ofInfoString info: String?) -> String? {
        guard let token = info?.split(whereSeparator: \.isWhitespace).first else { return nil }
        let name = token.lowercased()
        if specs[name] != nil { return name }
        return aliases[name]
    }

    /// The spec a fence's info string resolves to, or nil for a bare
    /// fence and for every language the table has never heard of.
    public static func spec(forInfoString info: String?) -> LanguageSpec? {
        guard let name = canonicalLanguage(ofInfoString: info) else { return nil }
        return specs[name]
    }

    // MARK: - The scan

    /// Reads a fenced block's lines in order and says which spans of
    /// each are colored, carrying state across the lines the way
    /// `InkStyle.FenceScanner` carries fence state, and for the same
    /// reason: an open `/*` or an open `"""` means the next line is not
    /// what it locally looks like. A line of code can no more be
    /// tokenized alone than a line of a page can be classified alone.
    ///
    /// One tokenizer belongs to one fence region. It is made at the
    /// opening rule, which is where the language is declared, and
    /// `reset()` puts it back to that state, so a comment left open at
    /// the end of one block can never color the block below it.
    public struct Tokenizer {
        private let spec: LanguageSpec?
        private let keywords: Set<String>
        private let foldsKeywordCase: Bool
        private let escapes: Bool
        private let numbers: NumberLiterals
        private let lineComments: [[UInt16]]
        private let blockOpen: [UInt16]
        private let blockClose: [UInt16]
        private let multilineStrings: [[UInt16]]
        private let strings: [[UInt16]]

        /// The two ways a line can arrive already inside something.
        /// These two bits are the tokenizer's whole memory; anything a
        /// language needs beyond them is a grammar.
        private var insideBlockComment = false
        private var openMultiline: [UInt16]?

        /// Built from a fence's info string. Anything unrecognized
        /// gives a tokenizer that returns no tokens at all, which is
        /// the same thing as the block rendering as it always has.
        public init(language: String?) {
            self.init(spec: CodeInk.spec(forInfoString: language))
        }

        public init(spec: LanguageSpec?) {
            self.spec = spec
            keywords = spec?.keywords ?? []
            foldsKeywordCase = spec?.foldsKeywordCase ?? false
            escapes = spec?.escapesInStrings ?? false
            numbers = spec?.numbers ?? .decimal
            lineComments = (spec?.lineComments ?? []).map { Array($0.utf16) }
            blockOpen = Array((spec?.blockComment?.open ?? "").utf16)
            blockClose = Array((spec?.blockComment?.close ?? "").utf16)
            // Longest first, so `"""` is met before the `"` that is its
            // own prefix.
            multilineStrings = (spec?.multilineStrings ?? [])
                .map { Array($0.utf16) }
                .sorted { $0.count > $1.count }
            strings = (spec?.strings ?? [])
                .map { Array($0.utf16) }
                .sorted { $0.count > $1.count }
        }

        /// True when the fence named a language this file knows. A bare
        /// fence can be skipped on this alone.
        public var recognizesLanguage: Bool { spec != nil }

        /// Forgets what earlier lines left open, keeping the language.
        /// Called at an opening fence rule, which is the boundary the
        /// spec asks state never to cross.
        public mutating func reset() {
            insideBlockComment = false
            openMultiline = nil
        }

        /// The colored spans of one line, in document order, left to
        /// right and never overlapping.
        public mutating func tokens(in line: String) -> [Token] {
            guard spec != nil else { return [] }
            let units = Array(line.utf16)
            var tokens: [Token] = []
            var index = 0

            // Whatever an earlier line left open owns the head of this
            // one, no matter what it locally resembles, and so is the
            // first thing answered.
            if insideBlockComment {
                guard let close = Self.firstIndex(of: blockClose, in: units, from: 0) else {
                    return Self.wholeLine(units, kind: .comment)
                }
                index = close + blockClose.count
                tokens.append(Token(range: NSRange(location: 0, length: index), kind: .comment))
                insideBlockComment = false
            } else if let delimiter = openMultiline {
                guard let end = stringEnd(delimiter, in: units, from: 0) else {
                    return Self.wholeLine(units, kind: .string)
                }
                index = end
                tokens.append(Token(range: NSRange(location: 0, length: index), kind: .string))
                openMultiline = nil
            }

            while index < units.count {
                // A comment that may span lines. Nesting is not read:
                // the first close ends it, which is C's rule and one
                // count short of Swift's and Rust's.
                if Self.matches(blockOpen, in: units, at: index) {
                    guard let close = Self.firstIndex(
                        of: blockClose, in: units, from: index + blockOpen.count
                    ) else {
                        tokens.append(Self.token(from: index, to: units.count, kind: .comment))
                        insideBlockComment = true
                        return tokens
                    }
                    let end = close + blockClose.count
                    tokens.append(Self.token(from: index, to: end, kind: .comment))
                    index = end
                    continue
                }
                if opensLineComment(units, at: index) {
                    tokens.append(Self.token(from: index, to: units.count, kind: .comment))
                    return tokens
                }
                // A string allowed to run past end of line, checked
                // before the single-line quote it is usually built out
                // of.
                if let delimiter = Self.matched(multilineStrings, in: units, at: index) {
                    guard let end = stringEnd(
                        delimiter, in: units, from: index + delimiter.count
                    ) else {
                        tokens.append(Self.token(from: index, to: units.count, kind: .string))
                        openMultiline = delimiter
                        return tokens
                    }
                    tokens.append(Self.token(from: index, to: end, kind: .string))
                    index = end
                    continue
                }
                if let delimiter = Self.matched(strings, in: units, at: index) {
                    // A quote left open at end of line closes there. It
                    // is nearly always a typo mid-edit, and carrying it
                    // across the line would paint the rest of the block
                    // red for the length of one keystroke.
                    let end = stringEnd(delimiter, in: units, from: index + delimiter.count)
                        ?? units.count
                    tokens.append(Self.token(from: index, to: end, kind: .string))
                    index = end
                    continue
                }
                // Words and numbers are read only where a word begins,
                // which is what keeps `format` off the keyword `for`
                // and `forEach` off it too: the run is taken whole and
                // then asked, never scanned for a prefix.
                if Self.isWord(units[index]), index == 0 || !Self.isWord(units[index - 1]) {
                    if Self.isDigit(units[index]), let end = numberEnd(units, from: index) {
                        tokens.append(Self.token(from: index, to: end, kind: .number))
                        index = end
                        continue
                    }
                    let end = Self.wordEnd(units, from: index)
                    var word = String(decoding: units[index..<end], as: UTF16.self)
                    if foldsKeywordCase { word = word.lowercased() }
                    if keywords.contains(word) {
                        tokens.append(Self.token(from: index, to: end, kind: .keyword))
                    }
                    index = end
                    continue
                }
                index += 1
            }
            return tokens
        }

        /// Whether a line comment opens at this offset. A
        /// one-character opener is too small to be unambiguous, so `#`
        /// is read as a comment only at the start of a line or after
        /// whitespace: shell and YAML both ask for that space, and
        /// without the rule a URL fragment would take the rest of its
        /// line. `//` and `--` are distinctive enough to stand
        /// anywhere.
        private func opensLineComment(_ units: [UInt16], at index: Int) -> Bool {
            for opener in lineComments where Self.matches(opener, in: units, at: index) {
                if opener.count == 1, index > 0, !Self.isSpace(units[index - 1]) { continue }
                return true
            }
            return false
        }

        /// Where a string opened before `start` ends: just past its
        /// closing delimiter, or nil when the line runs out first.
        private func stringEnd(
            _ delimiter: [UInt16], in units: [UInt16], from start: Int
        ) -> Int? {
            var index = start
            while index < units.count {
                if escapes, units[index] == Self.backslash {
                    index += 2
                    continue
                }
                if Self.matches(delimiter, in: units, at: index) {
                    return index + delimiter.count
                }
                index += 1
            }
            return nil
        }

        /// Where the number literal beginning at `start` ends, or nil
        /// when what begins there only looks like one. `1px` and `0xzz`
        /// are words with a digit in front, and half a colored word
        /// reads as a bug in the editor.
        private func numberEnd(_ units: [UInt16], from start: Int) -> Int? {
            let cStyle = numbers == .cStyle
            var index = start
            if cStyle, units[index] == Self.zero, index + 1 < units.count,
               Self.isRadixMark(units[index + 1])
            {
                index += 2
                var digits = 0
                while index < units.count,
                      Self.isHexDigit(units[index]) || units[index] == Self.underscore
                {
                    if units[index] != Self.underscore { digits += 1 }
                    index += 1
                }
                guard digits > 0 else { return nil }
            } else {
                index = Self.digitsEnd(units, from: index, separators: cStyle)
                // A fraction wants a digit on both sides of the point,
                // so a method call on a literal keeps its dot.
                if index + 1 < units.count, units[index] == Self.dot,
                   Self.isDigit(units[index + 1])
                {
                    index = Self.digitsEnd(units, from: index + 1, separators: cStyle)
                }
                if index < units.count, Self.isExponentMark(units[index]) {
                    var lookahead = index + 1
                    if lookahead < units.count, Self.isSign(units[lookahead]) { lookahead += 1 }
                    if lookahead < units.count, Self.isDigit(units[lookahead]) {
                        index = Self.digitsEnd(units, from: lookahead, separators: cStyle)
                    }
                }
            }
            guard index >= units.count || !Self.isWord(units[index]) else { return nil }
            return index
        }

        // MARK: Units

        // The scan counts in UTF-16 units rather than characters
        // because the ranges it produces are handed to NSTextStorage,
        // which counts the same way. Every delimiter and every keyword
        // in the table is ASCII, so comparing units is exact.

        /// One ASCII character as the unit the scan compares against.
        /// `UInt16` has no `init(ascii:)` of its own, and spelling the
        /// character out beats a table of numbers nobody can read.
        private static func ascii(_ character: Unicode.Scalar) -> UInt16 {
            UInt16(character.value)
        }

        private static let backslash = ascii("\\")
        private static let underscore = ascii("_")
        private static let dot = ascii(".")
        private static let zero = ascii("0")

        private static func isDigit(_ unit: UInt16) -> Bool {
            unit >= ascii("0") && unit <= ascii("9")
        }

        private static func isHexDigit(_ unit: UInt16) -> Bool {
            isDigit(unit)
                || (unit >= ascii("a") && unit <= ascii("f"))
                || (unit >= ascii("A") && unit <= ascii("F"))
        }

        private static func isRadixMark(_ unit: UInt16) -> Bool {
            "xXoObB".utf16.contains(unit)
        }

        private static func isExponentMark(_ unit: UInt16) -> Bool {
            unit == ascii("e") || unit == ascii("E")
        }

        private static func isSign(_ unit: UInt16) -> Bool {
            unit == ascii("+") || unit == ascii("-")
        }

        private static func isSpace(_ unit: UInt16) -> Bool {
            unit == ascii(" ") || unit == ascii("\t")
        }

        /// What counts as part of a word. Everything above ASCII is
        /// included, which is the conservative reading: `café` is one
        /// word rather than the keyword-shaped `caf`, and prose in a
        /// comment cannot break a word open on an accent.
        private static func isWord(_ unit: UInt16) -> Bool {
            isDigit(unit)
                || (unit >= ascii("a") && unit <= ascii("z"))
                || (unit >= ascii("A") && unit <= ascii("Z"))
                || unit == underscore
                || unit == ascii("$")
                || unit >= 0x80
        }

        private static func wordEnd(_ units: [UInt16], from start: Int) -> Int {
            var index = start
            while index < units.count, isWord(units[index]) { index += 1 }
            return index
        }

        private static func digitsEnd(
            _ units: [UInt16], from start: Int, separators: Bool
        ) -> Int {
            var index = start
            while index < units.count,
                  isDigit(units[index]) || (separators && units[index] == underscore)
            {
                index += 1
            }
            return index
        }

        private static func matches(
            _ needle: [UInt16], in units: [UInt16], at index: Int
        ) -> Bool {
            guard !needle.isEmpty, index + needle.count <= units.count else { return false }
            for (offset, unit) in needle.enumerated() where units[index + offset] != unit {
                return false
            }
            return true
        }

        private static func matched(
            _ delimiters: [[UInt16]], in units: [UInt16], at index: Int
        ) -> [UInt16]? {
            delimiters.first { matches($0, in: units, at: index) }
        }

        private static func firstIndex(
            of needle: [UInt16], in units: [UInt16], from start: Int
        ) -> Int? {
            guard !needle.isEmpty else { return nil }
            var index = start
            while index + needle.count <= units.count {
                if matches(needle, in: units, at: index) { return index }
                index += 1
            }
            return nil
        }

        private static func token(from start: Int, to end: Int, kind: TokenKind) -> Token {
            Token(range: NSRange(location: start, length: end - start), kind: kind)
        }

        /// An empty line inside an open comment or string is still
        /// inside it, but it has nothing to color: a zero-length token
        /// is an attribute run over no characters.
        private static func wholeLine(_ units: [UInt16], kind: TokenKind) -> [Token] {
            units.isEmpty ? [] : [token(from: 0, to: units.count, kind: kind)]
        }
    }

    /// A whole fenced block's lines, read in order. The tokenizer is
    /// the working form, the one the restyle walk will hold beside its
    /// fence scanner; this is the one a reader (and a test) can hold in
    /// view, mirroring `InkStyle.classify(lines:)`.
    public static func tokens(language: String?, lines: [String]) -> [[Token]] {
        var tokenizer = Tokenizer(language: language)
        return lines.map { tokenizer.tokens(in: $0) }
    }
}
