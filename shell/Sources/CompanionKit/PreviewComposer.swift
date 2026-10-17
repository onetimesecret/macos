/// The Markdown dialect a rendered page preview composes raw HTML under (plan R1 to R3).
enum PreviewDialect: CaseIterable {
    case commonMark
    case gfm
}

enum PreviewTrait: Hashable {
    case emphasis, strong, deletion, code
}

/// An address as composition leaves it, before any link or request policy (ADR-0059).
enum PreviewAddress: Hashable {
    case unreviewed(String)
    case refused(AddressRefusal)
}

enum AddressRefusal: Hashable {
    case missing
    case sealedObject
}

enum PreviewEvent: Equatable {
    // Text here has already been decoded by the Markdown parser.
    case text(String)
    case object(String)
    case enterMarkdown(PreviewTrait)
    case leaveMarkdown(PreviewTrait)
    case blockBoundary
    case rawHTML([HTMLPart])
    case markdownImage(alt: [HTMLPart], destination: [HTMLPart]?)
}

struct PreviewStyle: Equatable {
    var traits: Set<PreviewTrait> = []
    var link: PreviewAddress?
}

/// An image as composition leaves it: an address and the alt text and objects shown in its place.
struct PreviewImage: Equatable {
    let destination: PreviewAddress
    let fallback: [HTMLPart]
}

enum PreviewRun: Equatable {
    case text(String, PreviewStyle)
    case object(String, PreviewStyle)
    case image(PreviewImage, PreviewStyle)
}

enum CompositionDiagnostic: Equatable {
    case gfmFiltered(String)
    case escapedElement(String)
    case unmatchedClosingTag(String)
    case recoveredNesting(String)
}

struct PreviewComposition: Equatable {
    let runs: [PreviewRun]
    let diagnostics: [CompositionDiagnostic]

    var objectOrder: [String] { runs.objectIdentities }
}

/// Input bounds the work; the other counts sit above what that input can produce in an
/// ordinary page, where Markdown traits cost events but no input.
struct CompositionLimits {
    var maximumInputScalars = 1_000_000
    var maximumEvents = 4_000_000
    var maximumTokens = 1_000_000
    var maximumDepth = 64
    var maximumOutputRuns = 2_000_000
}

enum CompositionError: Error, Equatable {
    case inputLimit
    case eventLimit
    case depthLimit
    case outputLimit
    case duplicateObject(String)
    case emptyObjectIdentity
    case unbalancedMarkdown
    case structuredEventInRawText
    case objectOrderMismatch
}

/// Composes Markdown structure and raw HTML into styled runs, sealed objects and image
/// descriptors (plan R3).
struct PreviewComposer {
    let dialect: PreviewDialect
    var limits = CompositionLimits()
    var reservedPlaceholders = ["OTSAttachment", "\u{FFFC}"]

    /// The whole event sequence at once: every run, or an error and no composition.
    func compose(_ events: [PreviewEvent]) throws -> PreviewComposition {
        var stream = start()
        var runs: [PreviewRun] = []
        for event in events { runs += try stream.consume(event) }
        try stream.finish()
        return PreviewComposition(runs: runs, diagnostics: stream.diagnostics)
    }

    /// A composition fed one event at a time, as the preview's renderer walks its tree.
    func start() -> PreviewCompositionStream {
        PreviewCompositionStream(dialect: dialect, limits: limits, reservedPlaceholders: reservedPlaceholders)
    }
}

/// One document's composition. HTML scope, budgets and object identities span every event,
/// so a document is composed by one stream from its first event to `finish()`.
struct PreviewCompositionStream {
    let dialect: PreviewDialect
    let limits: CompositionLimits
    let reservedPlaceholders: [String]
    private(set) var diagnostics: [CompositionDiagnostic] = []
    private var markdown: [PreviewTrait] = []
    private var html: [Frame] = []
    private var eventCount = 0
    private var remainingInput: Int
    private var seen: Set<String> = []
    private var tokenCount = 0
    private var runCount = 0
    private var rawTextElement: String?
    private var atBoundary = true
    private var atLineStart = true
    private var endsInSpace = false
    private var pending: [PreviewRun] = []

    private static let filtered: Set<String> = [
        "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext",
    ]
    private static let allowed: Set<String> = [
        "em", "i", "strong", "b", "del", "s", "strike", "code", "span", "a", "br", "p", "div", "img",
    ]

    init(dialect: PreviewDialect, limits: CompositionLimits, reservedPlaceholders: [String]) {
        self.dialect = dialect
        self.limits = limits
        self.reservedPlaceholders = reservedPlaceholders
        remainingInput = max(0, limits.maximumInputScalars)
    }

    private struct Frame {
        let name: String
        let trait: PreviewTrait?
        let link: PreviewAddress?
    }

    var style: PreviewStyle {
        PreviewStyle(
            traits: Set(markdown).union(html.compactMap(\.trait)),
            link: html.last(where: { $0.link != nil })?.link
        )
    }

    /// The runs `event` composes to, its objects in the order the event gives them.
    mutating func consume(_ event: PreviewEvent) throws -> [PreviewRun] {
        eventCount += 1
        guard eventCount <= limits.maximumEvents else { throw CompositionError.eventLimit }
        let expected = try charge(event)
        pending = []
        try apply(event)
        let runs = pending
        pending = []
        guard runs.objectIdentities == expected else { throw CompositionError.objectOrderMismatch }
        return runs
    }

    /// The caller has started a native paragraph: block elements add no newline before it.
    mutating func beginBlock() {
        atBoundary = true
        atLineStart = true
        endsInSpace = false
    }

    /// Unclosed HTML ends here; unbalanced Markdown is an error.
    func finish() throws {
        guard markdown.isEmpty else { throw CompositionError.unbalancedMarkdown }
    }

    /// Spends the input budget on `event` and returns its object identities in order.
    private mutating func charge(_ event: PreviewEvent) throws -> [String] {
        var objects: [String] = []
        switch event {
        case .text(let text): try spend(text)
        case .object(let identity): try spend([.object(identity)], into: &objects)
        case .rawHTML(let raw): try spend(raw, into: &objects)
        case .markdownImage(let alt, let destination):
            try spend(alt, into: &objects)
            try spend(destination ?? [], into: &objects)
        case .enterMarkdown, .leaveMarkdown, .blockBoundary: break
        }
        return objects
    }

    /// Every scalar costs one unit, and an empty fragment costs one.
    private mutating func spend(_ text: String) throws {
        if text.isEmpty {
            guard remainingInput > 0 else { throw CompositionError.inputLimit }
            remainingInput -= 1
        }
        for _ in text.unicodeScalars {
            guard remainingInput > 0 else { throw CompositionError.inputLimit }
            remainingInput -= 1
        }
    }

    private mutating func spend(_ parts: [HTMLPart], into objects: inout [String]) throws {
        for part in parts {
            switch part {
            case .text(let text): try spend(text)
            case .object(let identity):
                guard !identity.isEmpty else { throw CompositionError.emptyObjectIdentity }
                try spend(identity)
                guard seen.insert(identity).inserted else { throw CompositionError.duplicateObject(identity) }
                objects.append(identity)
            }
        }
    }

    private mutating func apply(_ event: PreviewEvent) throws {
        switch event {
        case .text(let text): try emit(.text(text, style))
        case .object(let identity): try emit(.object(identity, style))
        case .enterMarkdown(let trait):
            guard rawTextElement == nil else { throw CompositionError.structuredEventInRawText }
            try checkDepth()
            markdown.append(trait)
        case .leaveMarkdown(let trait):
            guard rawTextElement == nil else { throw CompositionError.structuredEventInRawText }
            guard markdown.last == trait else { throw CompositionError.unbalancedMarkdown }
            markdown.removeLast()
        case .blockBoundary: try boundary()
        case .markdownImage(let alt, let destination):
            guard rawTextElement == nil else { throw CompositionError.structuredEventInRawText }
            let fallback = alt + (destination ?? []).objectIdentities.map(HTMLPart.object)
            try emit(.image(PreviewImage(destination: address(destination, decode: false), fallback: fallback), style))
        case .rawHTML(let parts):
            let tokenizer = HTMLTokenizer(
                maximumInputScalars: limits.maximumInputScalars,
                maximumTokens: max(0, limits.maximumTokens - tokenCount)
            )
            let tokenization = try tokenizer.tokenize(
                parts, rawTextElement: rawTextElement, recognizingRawText: dialect == .commonMark
            )
            rawTextElement = tokenization.rawTextElement
            tokenCount += tokenization.tokens.count
            for token in tokenization.tokens {
                switch token {
                case .text(let parts): try emitHTMLText(parts)
                case .literal(let parts): try emitParts(parts, decode: false)
                case .rawText(let parts, let decode): try emitParts(parts, decode: decode)
                case .comment(let parts): try recoverObjects(parts)
                case .tag(let tag): try consume(tag)
                }
            }
        }
    }

    private mutating func consume(_ tag: HTMLTag) throws {
        // Apply the GFM raw-token filter before the native element policy.
        if dialect == .gfm, Self.filtered.contains(tag.name) {
            diagnostics.append(.gfmFiltered(tag.name))
            try emitParts(tag.raw, decode: true)
            return
        }
        guard Self.allowed.contains(tag.name) else {
            diagnostics.append(.escapedElement(tag.name))
            try emitParts(tag.raw, decode: false)
            return
        }
        // Block elements only break the line and open no scope: an omitted `</p>` costs no
        // depth, and `</p>` ends no formatting, as HTML's formatting reconstruction continues it.
        if tag.name == "p" || tag.name == "div" {
            try boundary()
            try recoverObjects(tag.raw)
            return
        }
        if tag.isClosing {
            guard let index = html.lastIndex(where: { $0.name == tag.name }) else {
                diagnostics.append(.unmatchedClosingTag(tag.name))
                try emitParts(tag.raw, decode: false)
                return
            }
            if index != html.count - 1 { diagnostics.append(.recoveredNesting(tag.name)) }
            html.removeSubrange(index...)
            return
        }
        if tag.name == "img" {
            var fallback: [HTMLPart] = []
            var foundAlt = false
            for attribute in tag.attributes {
                let value = attribute.value ?? []
                if attribute.name == "alt", !foundAlt {
                    foundAlt = true
                    fallback += decoded(value)
                } else {
                    fallback += value.objectIdentities.map(HTMLPart.object)
                }
            }
            let sources = tag.attributes.filter { $0.name == "src" }
            let destination: PreviewAddress = sources.contains(where: { address($0.value, decode: true) == .refused(.sealedObject) })
                ? .refused(.sealedObject) : address(sources.first?.value, decode: true)
            try emit(.image(PreviewImage(destination: destination, fallback: fallback), style))
            return
        }
        if tag.name == "br" {
            try recoverObjects(tag.raw)
            try emit(.text("\u{2028}", style))
            return
        }
        if !tag.isSelfClosing {
            try checkDepth()
            let trait: PreviewTrait?
            switch tag.name {
            case "em", "i": trait = .emphasis
            case "strong", "b": trait = .strong
            case "del", "s", "strike": trait = .deletion
            case "code": trait = .code
            default: trait = nil
            }
            let hrefs = tag.attributes.filter { $0.name == "href" }
            let link: PreviewAddress? = tag.name == "a"
                ? (hrefs.contains(where: { address($0.value, decode: true) == .refused(.sealedObject) })
                    ? .refused(.sealedObject) : address(hrefs.first?.value, decode: true))
                : nil
            html.append(Frame(name: tag.name, trait: trait, link: link))
        }
        try recoverObjects(tag.raw)
    }

    private func address(_ parts: [HTMLPart]?, decode: Bool) -> PreviewAddress {
        guard let parts else { return .refused(.missing) }
        guard parts.objectIdentities.isEmpty else { return .refused(.sealedObject) }
        let text = parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
        let value = decode ? HTMLEntities.decode(text) : text
        guard !reservedPlaceholders.contains(where: { !$0.isEmpty && value.contains($0) }) else {
            return .refused(.sealedObject)
        }
        return value.isEmpty ? .refused(.missing) : .unreviewed(value)
    }

    private func decoded(_ parts: [HTMLPart]) -> [HTMLPart] {
        parts.map { part in
            if case .text(let text) = part { return .text(HTMLEntities.decode(text)) }
            return part
        }
    }

    /// HTML text laid out as a browser lays it out: entities decoded once, each run of
    /// whitespace one space, and none at the start of a line or after a space.
    private mutating func emitHTMLText(_ parts: [HTMLPart]) throws {
        for part in parts {
            switch part {
            case .text(let text):
                var collapsed = String.UnicodeScalarView()
                var space = atLineStart || endsInSpace
                for scalar in HTMLEntities.decode(text).unicodeScalars {
                    switch scalar.value {
                    case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                        if !space { collapsed.append(" ") }
                        space = true
                    default:
                        collapsed.append(scalar)
                        space = false
                    }
                }
                try emit(.text(String(collapsed), style))
            case .object(let identity): try emit(.object(identity, style))
            }
        }
    }

    private mutating func emitParts(_ parts: [HTMLPart], decode: Bool) throws {
        for part in parts {
            switch part {
            case .text(let text): try emit(.text(decode ? HTMLEntities.decode(text) : text, style))
            case .object(let identity): try emit(.object(identity, style))
            }
        }
    }

    private mutating func recoverObjects(_ parts: [HTMLPart]) throws {
        for identity in parts.objectIdentities { try emit(.object(identity, style)) }
    }

    private func checkDepth() throws {
        guard html.count + markdown.count < limits.maximumDepth else { throw CompositionError.depthLimit }
    }

    private mutating func boundary() throws {
        if !atBoundary { try emit(.text("\n", style)) }
    }

    private mutating func emit(_ run: PreviewRun) throws {
        if case .text(let text, _) = run, text.isEmpty { return }
        guard runCount < limits.maximumOutputRuns else { throw CompositionError.outputLimit }
        runCount += 1
        pending.append(run)
        if case .text(let text, _) = run {
            atBoundary = text.hasSuffix("\n")
            atLineStart = atBoundary || text.hasSuffix("\u{2028}")
            endsInSpace = text.hasSuffix(" ")
        } else {
            atBoundary = false
            atLineStart = false
            endsInSpace = false
        }
    }
}

extension Array where Element == HTMLPart {
    var objectIdentities: [String] {
        compactMap { part in
            if case .object(let identity) = part { return identity }
            return nil
        }
    }
}

extension Array where Element == PreviewRun {
    var objectIdentities: [String] {
        flatMap { run -> [String] in
            switch run {
            case .object(let identity, _): return [identity]
            case .image(let image, _): return image.fallback.objectIdentities
            case .text: return []
            }
        }
    }
}
