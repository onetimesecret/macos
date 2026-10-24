enum PreviewDialect: CaseIterable {
    case commonMark
    case gfm
}

enum PreviewTrait: Hashable {
    case emphasis, strong, deletion, code
}

enum PreviewAddress: Equatable {
    case unreviewed(String)
    case refused(AddressRefusal)
}

enum AddressRefusal: Equatable {
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

    var objectOrder: [String] {
        runs.flatMap { run in
            switch run {
            case .object(let identity, _): return [identity]
            case .image(let image, _): return image.fallback.objectIdentities
            case .text: return []
            }
        }
    }
}

struct CompositionLimits {
    var maximumInputScalars = 1_000_000
    var maximumEvents = 100_000
    var maximumTokens = 100_000
    var maximumDepth = 64
    var maximumOutputRuns = 100_000
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

struct PreviewComposer {
    let dialect: PreviewDialect
    var limits = CompositionLimits()
    var reservedPlaceholders = ["OTSAttachment", "\u{FFFC}"]

    func compose(_ events: [PreviewEvent]) throws -> PreviewComposition {
        let expectedObjects = try preflight(events)
        var state = State(dialect: dialect, limits: limits, reservedPlaceholders: reservedPlaceholders)
        for event in events { try state.consume(event) }
        guard state.markdown.isEmpty else { throw CompositionError.unbalancedMarkdown }
        let result = PreviewComposition(runs: state.runs, diagnostics: state.diagnostics)
        guard result.objectOrder == expectedObjects else { throw CompositionError.objectOrderMismatch }
        return result
    }

    private func preflight(_ events: [PreviewEvent]) throws -> [String] {
        guard events.count <= limits.maximumEvents else { throw CompositionError.eventLimit }
        var remaining = max(0, limits.maximumInputScalars)
        var objects: [String] = []
        var seen: Set<String> = []
        func count(_ text: String) throws {
            if text.isEmpty {
                guard remaining > 0 else { throw CompositionError.inputLimit }
                remaining -= 1
            }
            for _ in text.unicodeScalars {
                guard remaining > 0 else { throw CompositionError.inputLimit }
                remaining -= 1
            }
        }
        func parts(_ parts: [HTMLPart]) throws {
            for part in parts {
                switch part {
                case .text(let text): try count(text)
                case .object(let identity):
                    guard !identity.isEmpty else { throw CompositionError.emptyObjectIdentity }
                    try count(identity)
                    guard seen.insert(identity).inserted else { throw CompositionError.duplicateObject(identity) }
                    objects.append(identity)
                }
            }
        }
        for event in events {
            switch event {
            case .text(let text): try count(text)
            case .object(let identity): try parts([.object(identity)])
            case .rawHTML(let raw): try parts(raw)
            case .markdownImage(let alt, let destination):
                try parts(alt)
                try parts(destination ?? [])
            case .enterMarkdown, .leaveMarkdown, .blockBoundary: break
            }
        }
        return objects
    }

    private struct Frame {
        let name: String
        let trait: PreviewTrait?
        let link: PreviewAddress?
    }

    private struct State {
        let dialect: PreviewDialect
        let limits: CompositionLimits
        let reservedPlaceholders: [String]
        var runs: [PreviewRun] = []
        var diagnostics: [CompositionDiagnostic] = []
        var markdown: [PreviewTrait] = []
        var html: [Frame] = []
        var tokenCount = 0
        var rawTextElement: String?
        var atBoundary = true

        private static let filtered: Set<String> = [
            "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext",
        ]
        private static let allowed: Set<String> = [
            "em", "i", "strong", "b", "del", "s", "strike", "code", "span", "a", "br", "p", "div", "img",
        ]

        var style: PreviewStyle {
            PreviewStyle(
                traits: Set(markdown).union(html.compactMap(\.trait)),
                link: html.last(where: { $0.link != nil })?.link
            )
        }

        mutating func consume(_ event: PreviewEvent) throws {
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
                    case .text(let parts): try emitParts(parts, decode: true)
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
            if tag.isClosing {
                guard let index = html.lastIndex(where: { $0.name == tag.name }) else {
                    diagnostics.append(.unmatchedClosingTag(tag.name))
                    try emitParts(tag.raw, decode: false)
                    return
                }
                if index != html.count - 1 { diagnostics.append(.recoveredNesting(tag.name)) }
                html.removeSubrange(index...)
                if tag.name == "p" || tag.name == "div" { try boundary() }
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
                try emit(.text("\n", style))
                return
            }
            if tag.name == "p" || tag.name == "div" { try boundary() }
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
            guard runs.count < limits.maximumOutputRuns else { throw CompositionError.outputLimit }
            runs.append(run)
            if case .text(let text, _) = run {
                atBoundary = text.hasSuffix("\n")
            } else {
                atBoundary = false
            }
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
