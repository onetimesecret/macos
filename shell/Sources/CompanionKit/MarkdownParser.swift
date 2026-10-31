import CompanionCore
import Foundation

enum MarkdownParseError: Error, Equatable, Decodable {
    case inputLimit, depthLimit, tableCellLimit, noPlaceholderWindow, objectOffset, parserFailure
    case duplicateObject(String)
}

enum MarkdownBridgeError: Error, Equatable {
    case invalidLimits, unavailable, invalidResponse
}

enum MarkdownParser {
    struct Timings {
        let bridge: TimeInterval
        let decode: TimeInterval
    }

    static func parse(
        _ text: String, objects: [Int] = [], dialect: PreviewDialect,
        limits: CompositionLimits = CompositionLimits(),
        onTiming: ((Timings) -> Void)? = nil
    ) throws -> MarkdownDocument {
        guard limits.maximumInputScalars >= 0, limits.maximumDepth >= 0,
              limits.maximumTableCells >= 0 else { throw MarkdownBridgeError.invalidLimits }
        guard objects.allSatisfy({ $0 >= 0 }) else { throw MarkdownParseError.objectOffset }
        let dialectCode: Int32 = switch dialect {
        case .commonMark: 0
        case .gfm: 1
        }
        let byteCount = text.utf8.count
        let started = onTiming == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let pointer = text.withCString { bytes in
            objects.withUnsafeBufferPointer { offsets in
                companion_markdown_parse_json(
                    bytes, byteCount, offsets.baseAddress, offsets.count,
                    dialectCode, limits.maximumInputScalars,
                    limits.maximumDepth, UInt64(limits.maximumTableCells)
                )
            }
        }
        let bridged = onTiming == nil ? 0 : ProcessInfo.processInfo.systemUptime
        defer {
            onTiming?(Timings(bridge: bridged - started, decode: ProcessInfo.processInfo.systemUptime - bridged))
        }
        return try decode(pointer, objects: objects)
    }

    static func decode(
        _ pointer: UnsafeMutablePointer<CChar>?,
        objects: [Int] = [],
        release: ((UnsafeMutablePointer<CChar>) -> Void)? = nil
    ) throws -> MarkdownDocument {
        guard let pointer else { throw MarkdownBridgeError.unavailable }
        let decoded: Response?
        if let release {
            decoded = decodeOwnedJSON(Response.self, from: pointer, release: release)
        } else {
            decoded = decodeOwnedJSON(Response.self, from: pointer)
        }
        guard let response = decoded else {
            throw MarkdownBridgeError.invalidResponse
        }
        switch response {
        case .document(let document):
            guard document.atoms.count == objects.count,
                  document.atoms.enumerated().allSatisfy({ index, atom in
                      atom.identity == String(index) && atom.offset == objects[index]
                  }), document.blocks.allSatisfy(hasValidListNumbers)
            else { throw MarkdownBridgeError.invalidResponse }
            return document
        case .refused(let error): throw error
        }
    }

    private static func hasValidListNumbers(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .quote(let blocks):
            return blocks.allSatisfy(hasValidListNumbers)
        case .list(let ordered, let start, _, let items):
            if ordered {
                guard start >= 0, !start.addingReportingOverflow(max(0, items.count - 1)).overflow else { return false }
            }
            return items.allSatisfy { $0.blocks.allSatisfy(hasValidListNumbers) }
        default:
            return true
        }
    }

    private enum Response: Decodable {
        case document(MarkdownDocument)
        case refused(MarkdownParseError)

        private enum CodingKeys: String, CodingKey { case error }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if fields.contains(.error) {
                self = .refused(try fields.decode(MarkdownParseError.self, forKey: .error))
            } else {
                self = .document(try MarkdownDocument(from: decoder))
            }
        }
    }
}

actor MarkdownPreviewParsing {
    static let shared = MarkdownPreviewParsing()

    func parse(_ text: String, objects: [Int], dialect: PreviewDialect, limits: CompositionLimits) throws -> MarkdownDocument {
        try Task.checkCancellation()
        let document = try MarkdownParser.parse(text, objects: objects, dialect: dialect, limits: limits)
        try Task.checkCancellation()
        return document
    }
}
