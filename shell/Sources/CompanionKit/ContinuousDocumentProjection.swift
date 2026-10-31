import Foundation

struct ContinuousDocumentProjection: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let id: UInt64
        let uuid: String
        var text: String {
            didSet { utf16Length = text.utf16.count }
        }
        private(set) var utf16Length: Int
        var joinedNextUUID: String?
        var version: [UInt8]?

        init(id: UInt64, uuid: String, text: String, joinedNextUUID: String? = nil, version: [UInt8]? = nil) {
            self.id = id
            self.uuid = uuid
            self.text = text
            self.utf16Length = text.utf16.count
            self.joinedNextUUID = joinedNextUUID
            self.version = version
        }
    }

    struct Segment: Equatable, Sendable {
        let page: Page
        let bodyRange: NSRange
        let separatorRange: NSRange?
    }

    enum JoinChange: Equatable, Sendable {
        case unchanged
        case set(String?)
    }

    struct PageEdit: Equatable, Sendable {
        let pageID: UInt64
        let pageUUID: String
        var ops: [DocumentEditOp]
        var join: JoinChange
        var expectedVersion: [UInt8]? = nil
    }

    struct Plan: Equatable, Sendable {
        let projection: ContinuousDocumentProjection
        let edits: [PageEdit]
    }

    enum PlanningError: Error, Equatable {
        case invalidPages
        case invalidRange
        case splitUnicodeScalar
        case noPage
    }

    let pages: [Page]
    let segments: [Segment]

    init(pages: [Page]) {
        self.pages = pages
        var offset = 0
        segments = pages.enumerated().map { index, page in
            let body = NSRange(location: offset, length: page.utf16Length)
            offset += body.length
            let next = index + 1
            let separates = pages.indices.contains(next) && page.joinedNextUUID != pages[next].uuid
            let separator = separates ? NSRange(location: offset, length: 1) : nil
            if separates { offset += 1 }
            return Segment(page: page, bodyRange: body, separatorRange: separator)
        }
    }

    var text: String {
        segments.map { $0.page.text + ($0.separatorRange == nil ? "" : "\n") }.joined()
    }

    var length: Int { segments.last.map { NSMaxRange($0.bodyRange) } ?? 0 }

    // Shared offsets at a joined edge belong to the following page.
    func page(at index: Int) -> Segment? {
        let ranges = segments
        guard index >= 0, index <= (ranges.last.map { NSMaxRange($0.bodyRange) } ?? 0) else { return nil }
        return ranges.last {
            index >= $0.bodyRange.location && index <= NSMaxRange($0.bodyRange)
        }
    }

    func plan(_ operations: [DocumentEditOp]) throws -> Plan {
        guard Set(pages.map(\.id)).count == pages.count,
              Set(pages.map(\.uuid)).count == pages.count,
              pages.allSatisfy({ $0.id != 0 && !$0.uuid.isEmpty }) else {
            throw PlanningError.invalidPages
        }
        var updated = pages
        var edits = pages.map {
            PageEdit(pageID: $0.id, pageUUID: $0.uuid, ops: [], join: .unchanged, expectedVersion: $0.version)
        }
        var replacementOrigin: (global: Int, page: Int, offset: Int)?
        for operation in operations {
            let projection = Self(pages: updated)
            switch operation {
            case .ins(let at, let text):
                try projection.validate(NSRange(location: at, length: 0))
                let origin = replacementOrigin
                replacementOrigin = nil
                guard !text.isEmpty else { continue }
                let destination: (page: Int, offset: Int) = try origin.flatMap {
                    $0.global == at ? ($0.page, $0.offset) : nil
                }
                    ?? Self.destination(at: at, in: projection)
                updated[destination.page].text = Self.replacing(
                    NSRange(location: destination.offset, length: 0),
                    in: updated[destination.page].text, with: text)
                edits[destination.page].ops.append(.ins(at: destination.offset, text: text))
            case .chip(let at, let id):
                try projection.validate(NSRange(location: at, length: 0))
                let origin = replacementOrigin
                replacementOrigin = nil
                let destination: (page: Int, offset: Int) = try origin.flatMap {
                    $0.global == at ? ($0.page, $0.offset) : nil
                }
                    ?? Self.destination(at: at, in: projection)
                updated[destination.page].text = Self.replacing(
                    NSRange(location: destination.offset, length: 0),
                    in: updated[destination.page].text, with: "\u{fffc}")
                edits[destination.page].ops.append(.chip(at: destination.offset, id: id))
            case .del(let at, let count):
                let range = NSRange(location: at, length: count)
                try projection.validate(range)
                replacementOrigin = nil
                guard count > 0 else { continue }
                let origin = try Self.destination(at: at, in: projection)
                replacementOrigin = (at, origin.page, origin.offset)
                for (index, segment) in projection.segments.enumerated() {
                    let removed = NSIntersectionRange(range, segment.bodyRange)
                    if removed.length > 0 {
                        let local = NSRange(
                            location: removed.location - segment.bodyRange.location,
                            length: removed.length)
                        updated[index].text = Self.replacing(local, in: updated[index].text, with: "")
                        edits[index].ops.append(.del(at: local.location, len: local.length))
                    }
                    if let separator = segment.separatorRange,
                       NSIntersectionRange(range, separator).length > 0 {
                        let nextUUID = updated[index + 1].uuid
                        updated[index].joinedNextUUID = nextUUID
                        edits[index].join = .set(nextUUID)
                    }
                }
            }
        }
        return Plan(projection: Self(pages: updated), edits: edits.filter {
            !$0.ops.isEmpty || $0.join != .unchanged
        })
    }

    private static func destination(at index: Int, in projection: Self) throws -> (page: Int, offset: Int) {
        guard let page = projection.segments.lastIndex(where: {
            index >= $0.bodyRange.location && index <= NSMaxRange($0.bodyRange)
        }) else {
            throw PlanningError.noPage
        }
        return (page, index - projection.segments[page].bodyRange.location)
    }

    private func validate(_ range: NSRange) throws {
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else {
            throw PlanningError.invalidRange
        }
        for offset in [range.location, range.location + range.length] {
            guard let segment = segments.first(where: {
                offset > $0.bodyRange.location && offset < NSMaxRange($0.bodyRange)
            }) else { continue }
            let units = segment.page.text.utf16
            let index = units.index(units.startIndex, offsetBy: offset - segment.bodyRange.location)
            if (0xD800...0xDBFF).contains(units[units.index(before: index)]),
               (0xDC00...0xDFFF).contains(units[index]) {
                throw PlanningError.splitUnicodeScalar
            }
        }
    }

    private static func replacing(_ range: NSRange, in text: String, with replacement: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
