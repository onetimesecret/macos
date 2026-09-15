import Foundation

/// Editor-owned facts needed to decide whether an accepted paste may be fenced.
///
/// `replacementRange` uses the UTF-16 coordinates expected by `NSTextView`.
/// A whole-line insertion is an empty range at the start of a line. A whole-line
/// replacement starts at a line start and ends either at a line boundary or just
/// before that line's terminator. The caller supplies facts that plain text alone
/// cannot represent, such as attachments and marked-text composition.
public struct PasteDestinationContext: Sendable, Hashable {
    public let documentText: String
    public let replacementRange: NSRange
    public let isMarkdownCapable: Bool
    public let intersectsCodeFence: Bool
    public let isInListOrQuoteContainer: Bool
    public let intersectsAttachment: Bool
    public let hasMarkedText: Bool

    public init(
        documentText: String,
        replacementRange: NSRange,
        isMarkdownCapable: Bool,
        intersectsCodeFence: Bool = false,
        isInListOrQuoteContainer: Bool = false,
        intersectsAttachment: Bool = false,
        hasMarkedText: Bool = false
    ) {
        self.documentText = documentText
        self.replacementRange = replacementRange
        self.isMarkdownCapable = isMarkdownCapable
        self.intersectsCodeFence = intersectsCodeFence
        self.isInListOrQuoteContainer = isInListOrQuoteContainer
        self.intersectsAttachment = intersectsAttachment
        self.hasMarkedText = hasMarkedText
    }
}

/// One complete editor replacement and the collapsed selection to apply afterward.
public struct PasteReplacementPlan: Sendable, Hashable {
    public let replacementRange: NSRange
    public let replacementText: String
    public let finalCaretRange: NSRange
}

/// Pure construction of an automatic fenced-paste replacement.
///
/// Language inference and fallback behavior intentionally remain outside this type.
/// `nil` means the caller must not transform the paste.
public enum PasteReplacementPlanner {
    public static func plan(
        payload: String,
        destination: PasteDestinationContext,
        acceptedLanguageLabel: String
    ) -> PasteReplacementPlan? {
        guard destination.isMarkdownCapable,
              !destination.intersectsCodeFence,
              !destination.isInListOrQuoteContainer,
              !destination.intersectsAttachment,
              !destination.hasMarkedText,
              isValid(label: acceptedLanguageLabel),
              acceptedLanguageLabel.caseInsensitiveCompare("markdown") != .orderedSame,
              !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsCompleteFence(in: payload)
        else { return nil }

        let document = destination.documentText as NSString
        let range = destination.replacementRange
        guard isValid(range: range, inUTF16Length: document.length),
              isWholeLine(range: range, in: document)
        else { return nil }

        let newline = preferredNewline(in: destination.documentText, payload: payload)
        let delimiter = String(repeating: "`", count: max(3, longestBacktickRun(in: payload) + 1))

        var replacement = delimiter + acceptedLanguageLabel + newline + payload
        if !endsInLineTerminator(payload) {
            replacement += newline
        }
        replacement += delimiter

        let end = range.location + range.length
        if end < document.length, !isLineTerminator(document.character(at: end)) {
            replacement += newline
        }

        return PasteReplacementPlan(
            replacementRange: range,
            replacementText: replacement,
            finalCaretRange: NSRange(
                location: range.location + replacement.utf16.count,
                length: 0
            )
        )
    }

    private static func isValid(label: String) -> Bool {
        guard !label.isEmpty, label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.contains("`")
        else { return false }
        return label.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isValid(range: NSRange, inUTF16Length length: Int) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length
        else { return false }
        return range.length <= length - range.location
    }

    private static func isWholeLine(range: NSRange, in text: NSString) -> Bool {
        guard isLineStart(range.location, in: text) else { return false }
        if range.length == 0 { return true }

        let end = range.location + range.length
        return isLineStart(end, in: text) || isLineEnd(end, in: text)
    }

    private static func isLineStart(_ location: Int, in text: NSString) -> Bool {
        if location == 0 { return true }
        guard location <= text.length else { return false }

        let previous = text.character(at: location - 1)
        guard isLineTerminator(previous) else { return false }
        if previous == 0x0D, location < text.length, text.character(at: location) == 0x0A {
            return false
        }
        return true
    }

    private static func isLineEnd(_ location: Int, in text: NSString) -> Bool {
        if location == text.length { return true }
        guard location >= 0, location < text.length else { return false }

        let current = text.character(at: location)
        guard isLineTerminator(current) else { return false }
        if current == 0x0A, location > 0, text.character(at: location - 1) == 0x0D {
            return false
        }
        return true
    }

    private static func isLineTerminator(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func endsInLineTerminator(_ text: String) -> Bool {
        guard let last = text.utf16.last else { return false }
        return isLineTerminator(last)
    }

    private static func preferredNewline(in document: String, payload: String) -> String {
        firstNewline(in: document) ?? firstNewline(in: payload) ?? "\n"
    }

    private static func firstNewline(in text: String) -> String? {
        let units = Array(text.utf16)
        for index in units.indices {
            if units[index] == 0x0D {
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    return "\r\n"
                }
                return "\r"
            }
            if units[index] == 0x0A { return "\n" }
            if units[index] == 0x2028 { return "\u{2028}" }
            if units[index] == 0x2029 { return "\u{2029}" }
        }
        return nil
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for unit in text.utf16 {
            if unit == 0x60 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func containsCompleteFence(in payload: String) -> Bool {
        let normalized = payload
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var open: (marker: Character, length: Int)?

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let run = fenceRun(in: trimmed) else { continue }

            if let current = open {
                if run.marker == current.marker, run.length >= current.length, run.info.isEmpty {
                    return true
                }
            } else {
                open = (run.marker, run.length)
            }
        }
        return false
    }

    private static func fenceRun(
        in line: String
    ) -> (marker: Character, length: Int, info: String)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let run = line.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }

        let info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (marker, run.count, info)
    }
}
