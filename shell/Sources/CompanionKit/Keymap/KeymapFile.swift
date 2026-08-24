import Foundation

/// The file, read as text and turned into sections, before anything has
/// asked whether the bindings inside it mean anything.
///
/// Two jobs live here and neither knows about the app. The first is
/// JSON5 tolerance, which is a fancy name for two conveniences a
/// hand-written config file cannot do without: comments, so a keymap
/// can explain itself, and trailing commas, so adding a line at the
/// bottom is a one line diff. Nothing else from JSON5 is implemented,
/// because nothing else has been needed and a dependency for the rest
/// would have to be justified to `cargo-deny`'s Swift-side equivalent,
/// which is our own judgement. The second job is shape: an array of
/// section objects, optionally preceded by one metadata object that
/// carries the schema version.

// MARK: - JSON5, the two tolerances that matter

enum JSON5 {
    /// Strips comments and trailing commas, leaving text that
    /// `JSONSerialization` will accept.
    ///
    /// The scanner tracks whether it is inside a string literal,
    /// because a `//` inside a quoted keystroke is not a comment and an
    /// escaped quote does not end the string it sits in. Getting that
    /// wrong is how naive strippers corrupt files that were fine.
    static func canonicalise(_ source: String) -> String {
        var output = String()
        output.reserveCapacity(source.count)

        var inString = false
        var escaped = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" {
                    // A line comment runs to the newline, which is kept
                    // so line numbers in any future diagnostic survive.
                    index = next
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                }
                if next < source.endIndex, source[next] == "*" {
                    // A block comment is replaced by the newlines it
                    // spanned, for the same reason.
                    index = source.index(after: next)
                    while index < source.endIndex {
                        if source[index] == "\n" { output.append("\n") }
                        if source[index] == "*" {
                            let after = source.index(after: index)
                            if after < source.endIndex, source[after] == "/" {
                                index = source.index(after: after)
                                break
                            }
                        }
                        index = source.index(after: index)
                    }
                    continue
                }
            }

            output.append(character)
            index = source.index(after: index)
        }

        return stripTrailingCommas(output)
    }

    /// Removes a comma whose only remaining company before a closing
    /// brace or bracket is whitespace. Runs after comments are gone, so
    /// a comma followed by a comment and then a brace is caught too.
    private static func stripTrailingCommas(_ source: String) -> String {
        var characters = Array(source)
        var inString = false
        var escaped = false
        var lastComma: Int?

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                lastComma = nil
            case ",":
                lastComma = index
            case "}", "]":
                if let comma = lastComma { characters[comma] = " " }
                lastComma = nil
            case " ", "\t", "\n", "\r":
                break
            default:
                lastComma = nil
            }
            index += 1
        }

        return String(characters)
    }
}

// MARK: - The file's shape

/// One `{ context, use_key_equivalents, bindings }` object, still in
/// the file's own vocabulary: keystrokes and command ids are strings
/// here, and a null value is an unbinding rather than an omission.
struct KeymapSection {
    /// The named surface, or nil for a section that applies to every
    /// one of them. Zed reads a missing context that way, and so do we.
    let contextName: String?
    let useKeyEquivalents: Bool
    /// Sorted by keystroke, because `JSONSerialization` hands back an
    /// unordered dictionary and a resolution order that varies between
    /// launches would make a duplicate report a coin toss.
    let bindings: [(keystroke: String, command: String?)]
}

/// What a file can be wrong about before any single binding is even
/// looked at. Every case here rejects the whole file, which is what
/// makes the fallback to the previous or default map meaningful.
public enum KeymapFileFailure: Error, Equatable, Sendable {
    case unreadable(String)
    case notJSON(String)
    case notAnArray
    case sectionNotAnObject(index: Int)
    case bindingsNotAnObject(index: Int)
    case contextNotAString(index: Int)
    case unsupportedSchemaVersion(Int)
    /// The version was something other than a whole number, described
    /// as the reader found it.
    case schemaVersionNotAWholeNumber(String)
    case repeatedSchemaVersion
}

enum KeymapFileReader {
    /// The version this build writes and understands. A file may say so
    /// explicitly; a file that says nothing is read as version 1,
    /// because the format shipped before anyone needed to say.
    static let schemaVersion = 1

    /// The key that marks an entry as metadata rather than a section.
    /// It lives in an ordinary array element so the file stays a Zed
    /// keymap: Zed reads an entry with no bindings as a section that
    /// binds nothing, which is exactly the no-op we want it to be over
    /// there.
    static let schemaVersionKey = "schema_version"

    /// The version an entry declares, or nil when the value is not a
    /// whole number at all.
    ///
    /// The boolean is the case that has to be named. `JSONSerialization`
    /// hands `true` back as an `NSNumber` that bridges to `Int` 1, so
    /// asking `as? Int` on its own would read `"schema_version": true`
    /// as a file declaring version 1 and accept it.
    private static func declaredVersion(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    /// What the value was, for a line the author can act on. The old
    /// reading reported every one of these as version -1, which named a
    /// version no file has ever declared.
    private static func describe(_ value: Any) -> String {
        switch value {
        case is String: return "text"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return "true or false"
        case is NSNumber: return "a fractional number"
        case is [Any]: return "a list"
        case is [String: Any]: return "an object"
        case is NSNull: return "null"
        default: return "not a whole number"
        }
    }

    static func read(_ text: String) -> Result<[KeymapSection], KeymapFileFailure> {
        let canonical = JSON5.canonicalise(text)
        guard let data = canonical.data(using: .utf8) else {
            return .failure(.notJSON("the file is not valid UTF-8"))
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.notJSON(error.localizedDescription))
        }

        guard let entries = parsed as? [Any] else { return .failure(.notAnArray) }

        var sections: [KeymapSection] = []
        var sawVersion = false

        for (index, entry) in entries.enumerated() {
            guard let object = entry as? [String: Any] else {
                return .failure(.sectionNotAnObject(index: index))
            }

            if let version = object[schemaVersionKey] {
                if sawVersion { return .failure(.repeatedSchemaVersion) }
                sawVersion = true
                guard let number = declaredVersion(version) else {
                    return .failure(.schemaVersionNotAWholeNumber(describe(version)))
                }
                guard number == schemaVersion else {
                    return .failure(.unsupportedSchemaVersion(number))
                }
                // A metadata entry may also carry bindings, and there
                // is no reason to forbid it, so the entry falls through
                // to the section reading below.
            }

            let contextName: String?
            switch object["context"] {
            case nil: contextName = nil
            case let name as String: contextName = name
            default: return .failure(.contextNotAString(index: index))
            }

            let useKeyEquivalents = object["use_key_equivalents"] as? Bool ?? false

            var bindings: [(keystroke: String, command: String?)] = []
            switch object["bindings"] {
            case nil:
                // A section that binds nothing is legal and inert. The
                // metadata entry is exactly that.
                break
            case let table as [String: Any]:
                for keystroke in table.keys.sorted() {
                    let value = table[keystroke]
                    if value is NSNull {
                        bindings.append((keystroke: keystroke, command: nil))
                    } else if let command = value as? String {
                        bindings.append((keystroke: keystroke, command: command))
                    } else {
                        // A number or a nested object where a command
                        // id belongs is a mistake about this one line,
                        // not about the file, so it is left for the
                        // validator to report and skip.
                        bindings.append((keystroke: keystroke, command: ""))
                    }
                }
            default:
                return .failure(.bindingsNotAnObject(index: index))
            }

            if object["bindings"] == nil, object[schemaVersionKey] != nil, object["context"] == nil {
                // A bare metadata entry contributes no section at all,
                // which keeps the "no context means every context"
                // rule from applying to it.
                continue
            }

            sections.append(
                KeymapSection(
                    contextName: contextName,
                    useKeyEquivalents: useKeyEquivalents,
                    bindings: bindings
                ))
        }

        return .success(sections)
    }
}
