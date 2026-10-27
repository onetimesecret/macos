/// Raw source as the composer reads it: text, or a sealed object by occurrence identity,
/// which no tag, name or delimiter can absorb (plan R3).
enum HTMLPart: Equatable, Codable, Sendable {
    case text(String)
    case object(String)
}

struct HTMLAttribute: Equatable {
    let name: String
    let value: [HTMLPart]?
}

struct HTMLTag: Equatable {
    let name: String
    let isClosing: Bool
    let isSelfClosing: Bool
    let attributes: [HTMLAttribute]
    let raw: [HTMLPart]
}

enum HTMLToken: Equatable {
    case text([HTMLPart])
    case tag(HTMLTag)
    case comment([HTMLPart])
    case literal([HTMLPart])
    case rawText([HTMLPart], decodeEntities: Bool)
}

struct HTMLTokenization {
    let tokens: [HTMLToken]
    let rawTextElement: String?
}

enum HTMLTokenizationError: Error, Equatable {
    case inputLimit
    case tokenLimit
}

/// One raw HTML leaf as tokens whose parts reconstruct the leaf exactly. It decodes no entity;
/// raw-text bodies (`script`, `textarea`, ...) are scanned only when the caller recognizes them.
struct HTMLTokenizer {
    let maximumInputScalars: Int
    let maximumTokens: Int

    init(maximumInputScalars: Int = 1_000_000, maximumTokens: Int = 100_000) {
        self.maximumInputScalars = max(0, maximumInputScalars)
        self.maximumTokens = max(0, maximumTokens)
    }

    func tokenize(_ parts: [HTMLPart]) throws -> [HTMLToken] {
        try tokenize(parts, rawTextElement: nil, recognizingRawText: false).tokens
    }

    func tokenize(
        _ parts: [HTMLPart], rawTextElement: String?, recognizingRawText: Bool
    ) throws -> HTMLTokenization {
        let count = try inputCount(parts)
        var mode = rawTextMode(rawTextElement)
        var atoms: [Atom] = []
        atoms.reserveCapacity(count)
        for part in parts {
            switch part {
            case .text(let text):
                for scalar in text.unicodeScalars {
                    atoms.append(.scalar(scalar))
                }
            case .object(let identity):
                atoms.append(.object(identity))
            }
        }

        var tokens: [HTMLToken] = []
        var index = 0
        while index < atoms.count {
            guard tokens.count < maximumTokens else {
                throw HTMLTokenizationError.tokenLimit
            }
            let start = index
            if let activeMode = mode {
                var closingEnd: Int?
                if activeMode == .plaintext {
                    index = atoms.count
                } else {
                    let name = activeMode.rawValue.unicodeScalars.map(\.value)
                    while index < atoms.count {
                        if let end = rawTextClosingEnd(atoms, at: index, name: name) {
                            closingEnd = end
                            break
                        }
                        index += 1
                    }
                }
                if index > start {
                    tokens.append(.rawText(sourceParts(atoms, start..<index), decodeEntities: activeMode.decodeEntities))
                }
                if let closingEnd {
                    guard tokens.count < maximumTokens else {
                        throw HTMLTokenizationError.tokenLimit
                    }
                    tokens.append(.tag(HTMLTag(
                        name: activeMode.rawValue, isClosing: true, isSelfClosing: false,
                        attributes: [], raw: sourceParts(atoms, index..<closingEnd)
                    )))
                    index = closingEnd
                    mode = nil
                }
                continue
            }
            if !isScalar(atoms, index, 0x3C) {
                repeat { index += 1 } while index < atoms.count && !isScalar(atoms, index, 0x3C)
                tokens.append(.text(sourceParts(atoms, start..<index)))
                continue
            }

            if atoms.count - index >= 4,
               isScalar(atoms, index + 1, 0x21),
               isScalar(atoms, index + 2, 0x2D),
               isScalar(atoms, index + 3, 0x2D) {
                index += 4
                var terminated = false
                while atoms.count - index >= 3 {
                    if isScalar(atoms, index, 0x2D),
                       isScalar(atoms, index + 1, 0x2D),
                       isScalar(atoms, index + 2, 0x3E) {
                        index += 3
                        terminated = true
                        break
                    }
                    index += 1
                }
                if !terminated { index = atoms.count }
                let raw = sourceParts(atoms, start..<index)
                let valid = terminated && isCommentContent(atoms, (start + 4)..<(index - 3))
                tokens.append(valid ? .comment(raw) : .literal(raw))
                continue
            }

            index += 1
            var quote: Unicode.Scalar?
            var terminated = false
            while index < atoms.count {
                if case .scalar(let scalar) = atoms[index] {
                    if let activeQuote = quote {
                        if scalar == activeQuote { quote = nil }
                    } else if scalar.value == 0x22 || scalar.value == 0x27 {
                        quote = scalar
                    } else if scalar.value == 0x3E {
                        index += 1
                        terminated = true
                        break
                    }
                }
                index += 1
            }
            let raw = sourceParts(atoms, start..<index)
            if terminated, let tag = parseTag(atoms, start..<index, raw: raw) {
                tokens.append(.tag(tag))
                if recognizingRawText && !tag.isClosing && !tag.isSelfClosing {
                    mode = RawTextMode(rawValue: tag.name)
                }
            } else {
                tokens.append(.literal(raw))
            }
        }
        return HTMLTokenization(tokens: tokens, rawTextElement: mode?.rawValue)
    }

    private enum RawTextMode: String {
        case script, style, xmp, iframe, noembed, noframes, title, textarea, plaintext

        var decodeEntities: Bool { self == .title || self == .textarea }
    }

    private func rawTextMode(_ name: String?) -> RawTextMode? {
        guard let name else { return nil }
        var folded = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            guard folded.count < 9, scalar.value < 0x80 else { return nil }
            let value = scalar.value
            folded.append(Unicode.Scalar(UInt8((0x41...0x5A).contains(value) ? value + 0x20 : value)))
        }
        return RawTextMode(rawValue: String(folded))
    }

    private func rawTextClosingEnd(_ atoms: [Atom], at start: Int, name: [UInt32]) -> Int? {
        guard atoms.count - start >= name.count + 3,
              isScalar(atoms, start, 0x3C), isScalar(atoms, start + 1, 0x2F) else { return nil }
        var index = start + 2
        for expected in name {
            guard case .scalar(let scalar) = atoms[index] else { return nil }
            let value = scalar.value
            let folded = (0x41...0x5A).contains(value) ? value + 0x20 : value
            guard folded == expected else { return nil }
            index += 1
        }
        skipWhitespace(atoms, &index, end: atoms.count)
        guard index < atoms.count, isScalar(atoms, index, 0x3E) else { return nil }
        return index + 1
    }

    private enum Atom {
        case scalar(Unicode.Scalar)
        case object(String)
    }

    private func isCommentContent(_ atoms: [Atom], _ range: Range<Int>) -> Bool {
        let start = range.lowerBound
        let end = range.upperBound
        if start < end && isScalar(atoms, start, 0x3E) { return false }
        if range.count >= 2 && isScalar(atoms, start, 0x2D) && isScalar(atoms, start + 1, 0x3E) {
            return false
        }
        if range.count >= 3,
           isScalar(atoms, end - 3, 0x3C),
           isScalar(atoms, end - 2, 0x21),
           isScalar(atoms, end - 1, 0x2D) {
            return false
        }
        var index = start
        while end - index >= 4 {
            if isScalar(atoms, index, 0x3C),
               isScalar(atoms, index + 1, 0x21),
               isScalar(atoms, index + 2, 0x2D),
               isScalar(atoms, index + 3, 0x2D) {
                return false
            }
            if isScalar(atoms, index, 0x2D),
               isScalar(atoms, index + 1, 0x2D),
               isScalar(atoms, index + 2, 0x21),
               isScalar(atoms, index + 3, 0x3E) {
                return false
            }
            index += 1
        }
        return true
    }

    private func inputCount(_ parts: [HTMLPart]) throws -> Int {
        var count = 0
        for part in parts {
            switch part {
            case .text(let text) where !text.isEmpty:
                for _ in text.unicodeScalars {
                    guard count < maximumInputScalars else {
                        throw HTMLTokenizationError.inputLimit
                    }
                    count += 1
                }
            case .text, .object:
                guard count < maximumInputScalars else {
                    throw HTMLTokenizationError.inputLimit
                }
                count += 1
            }
        }
        return count
    }

    private func parseTag(_ atoms: [Atom], _ range: Range<Int>, raw: [HTMLPart]) -> HTMLTag? {
        let end = range.upperBound - 1
        var index = range.lowerBound + 1
        let closing = index < end && isScalar(atoms, index, 0x2F)
        if closing { index += 1 }
        guard index < end, isLetter(atoms[index]) else { return nil }

        let nameStart = index
        index += 1
        while index < end && isNameContinuation(atoms[index], attribute: false) { index += 1 }
        let name = foldedName(atoms, nameStart..<index)
        if closing {
            skipWhitespace(atoms, &index, end: end)
            guard index == end else { return nil }
            return HTMLTag(name: name, isClosing: true, isSelfClosing: false, attributes: [], raw: raw)
        }

        var attributes: [HTMLAttribute] = []
        var selfClosing = false
        while index < end {
            let beforeWhitespace = index
            skipWhitespace(atoms, &index, end: end)
            if index == end { break }
            if isScalar(atoms, index, 0x2F) {
                index += 1
                guard index == end else { return nil }
                selfClosing = true
                break
            }
            guard index > beforeWhitespace, isAttributeNameStart(atoms[index]) else { return nil }
            let attributeStart = index
            index += 1
            while index < end && isNameContinuation(atoms[index], attribute: true) { index += 1 }
            let attributeName = foldedName(atoms, attributeStart..<index)

            var equalsIndex = index
            skipWhitespace(atoms, &equalsIndex, end: end)
            var value: [HTMLPart]?
            if equalsIndex < end && isScalar(atoms, equalsIndex, 0x3D) {
                index = equalsIndex + 1
                skipWhitespace(atoms, &index, end: end)
                guard index < end else { return nil }
                if isScalar(atoms, index, 0x22) || isScalar(atoms, index, 0x27) {
                    let quote = atoms[index]
                    index += 1
                    let valueStart = index
                    while index < end && !sameScalar(atoms[index], quote) { index += 1 }
                    guard index < end else { return nil }
                    value = sourceParts(atoms, valueStart..<index)
                    index += 1
                } else {
                    let valueStart = index
                    while index < end && !isWhitespace(atoms[index]) {
                        if case .scalar(let scalar) = atoms[index] {
                            switch scalar.value {
                            case 0x22, 0x27, 0x3C, 0x3D, 0x60: return nil
                            default: break
                            }
                        }
                        index += 1
                    }
                    value = sourceParts(atoms, valueStart..<index)
                }
            }
            attributes.append(HTMLAttribute(name: attributeName, value: value))
        }
        return HTMLTag(name: name, isClosing: false, isSelfClosing: selfClosing, attributes: attributes, raw: raw)
    }

    private func sourceParts(_ atoms: [Atom], _ range: Range<Int>) -> [HTMLPart] {
        var result: [HTMLPart] = []
        var text = String.UnicodeScalarView()
        for index in range {
            switch atoms[index] {
            case .scalar(let scalar):
                text.append(scalar)
            case .object(let identity):
                if !text.isEmpty {
                    result.append(.text(String(text)))
                    text = String.UnicodeScalarView()
                }
                result.append(.object(identity))
            }
        }
        if !text.isEmpty { result.append(.text(String(text))) }
        return result
    }

    private func foldedName(_ atoms: [Atom], _ range: Range<Int>) -> String {
        var name = String.UnicodeScalarView()
        for index in range {
            if case .scalar(let scalar) = atoms[index] {
                let value = scalar.value
                name.append(Unicode.Scalar(UInt8((0x41...0x5A).contains(value) ? value + 0x20 : value)))
            }
        }
        return String(name)
    }

    private func isScalar(_ atoms: [Atom], _ index: Int, _ value: UInt32) -> Bool {
        if case .scalar(let scalar) = atoms[index] { return scalar.value == value }
        return false
    }

    private func sameScalar(_ lhs: Atom, _ rhs: Atom) -> Bool {
        if case .scalar(let left) = lhs, case .scalar(let right) = rhs { return left == right }
        return false
    }

    private func isLetter(_ atom: Atom) -> Bool {
        guard case .scalar(let scalar) = atom else { return false }
        return (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private func isAttributeNameStart(_ atom: Atom) -> Bool {
        isLetter(atom) || sameScalar(atom, .scalar("_")) || sameScalar(atom, .scalar(":"))
    }

    private func isNameContinuation(_ atom: Atom, attribute: Bool) -> Bool {
        if isAttributeNameStart(atom) { return true }
        guard case .scalar(let scalar) = atom else { return false }
        return (0x30...0x39).contains(scalar.value) || scalar.value == 0x2D
            || (attribute && scalar.value == 0x2E)
    }

    private func isWhitespace(_ atom: Atom) -> Bool {
        guard case .scalar(let scalar) = atom else { return false }
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
        default: return false
        }
    }

    private func skipWhitespace(_ atoms: [Atom], _ index: inout Int, end: Int) {
        while index < end && isWhitespace(atoms[index]) { index += 1 }
    }
}
