import AppKit

@MainActor
final class ContinuousPadDocument {
    unowned let model: PageModel
    let scope: String
    let storage = NSTextStorage()
    private(set) var projection = ContinuousDocumentProjection(pages: [])
    private var renderedChips: [ChipInfo] = []
    private struct PageBlockMetadata {
        let uuid: String
        let version: [UInt8]?
        let values: [BlockInfo]
    }
    private var pageBlockMetadata: [UInt64: PageBlockMetadata] = [:]
    private(set) var blockMetas: [BlockInfo] = []
    private var localRefreshPages: Set<UInt64> = []
    private struct PageIdentity {
        let id: UInt64
        let uuid: String
        let version: [UInt8]?
    }
    private var suspendedPages: [PageIdentity]?
    private var suspendedAnchor: (page: UInt64, range: NSRange, offset: Int)?
    var savedSelection = NSRange(location: 0, length: 0)
    var savedOffset = NSPoint.zero
    var onChange: (() -> Void)?
    var isApplyingLocalEdit: Bool { !localRefreshPages.isEmpty }
    var isSuspended: Bool { suspendedPages != nil }

    init(model: PageModel, scope: String) {
        self.model = model
        self.scope = scope
    }

    func suspend() {
        guard suspendedPages == nil else { return }
        for container in storage.layoutManagers.flatMap(\.textContainers) {
            if let editor = container.textView as? InkTextView {
                InkEditorView.discardComposition(in: editor)
            }
        }
        suspendedPages = projection.pages.map { .init(id: $0.id, uuid: $0.uuid, version: $0.version) }
        suspendedAnchor = localSelection(savedSelection)
        model.applyingProjection { storage.setAttributedString(NSAttributedString(string: "")) }
        projection = .init(pages: [])
        renderedChips = []
        pageBlockMetadata = [:]
        blockMetas = []
    }

    @discardableResult
    func refresh(force: Bool = false) -> Bool {
        var renderings: [UInt64: NSAttributedString] = [:]
        var chips: [ChipInfo] = []
        let pages = model.continuousTabs(scope: scope).compactMap { tab -> ContinuousDocumentProjection.Page? in
            guard let id = tab.pageID, let uuid = tab.pageUUID,
                  let snapshot = model.coreClient.continuousSnapshot(sheet: id), snapshot.uuid == uuid else { return nil }
            let body = NSMutableAttributedString()
            for run in snapshot.runs {
                switch run {
                case .ink(let text):
                    body.append(NSAttributedString(string: text, attributes: [
                        .font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor,
                    ]))
                case .chip(let info):
                    body.append(NSAttributedString(attachment: ChipAttachment(info: info)))
                }
            }
            renderings[id] = body
            body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
                if let chip = value as? ChipAttachment { chips.append(chip.info) }
            }
            return .init(id: id, uuid: uuid, text: body.string,
                         joinedNextUUID: snapshot.joinNext, version: snapshot.version)
        }
        let next = ContinuousDocumentProjection(pages: pages)
        guard force || suspendedPages != nil || next != projection || chips != renderedChips else { return false }
        let previous = suspendedPages ?? projection.pages.map { .init(id: $0.id, uuid: $0.uuid, version: $0.version) }
        let reordered = previous.map(\.uuid) != next.pages.map(\.uuid)
        let oldVersions = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.version) })
        let externalChange = next.pages.contains { page in
            !localRefreshPages.contains(page.id) && (oldVersions[page.id].map { $0 != page.version } ?? false)
        }
        let resuming = suspendedPages != nil
        let anchor = suspendedAnchor ?? (reordered ? localSelection(savedSelection) : nil)
        for page in next.pages {
            if let previousVersion = oldVersions[page.id], previousVersion != page.version {
                model.clearFenceRenderingLanguages(for: page.id)
            }
        }
        if (reordered || externalChange), !previous.isEmpty {
            model.coreClient.continuousClearHistory(scope: scope)
        }
        suspendedPages = nil
        suspendedAnchor = nil
        projection = next
        renderedChips = chips
        var nextBlockMetadata: [UInt64: PageBlockMetadata] = [:]
        for page in next.pages {
            if let cached = pageBlockMetadata[page.id], page.version != nil,
               cached.uuid == page.uuid, cached.version == page.version {
                nextBlockMetadata[page.id] = cached
            } else {
                nextBlockMetadata[page.id] = .init(uuid: page.uuid, version: page.version,
                                                 values: model.coreClient.blocks(sheet: page.id))
            }
        }
        pageBlockMetadata = nextBlockMetadata
        blockMetas = next.blockMetas { pageBlockMetadata[$0]?.values ?? [] }
        let rebuilt = NSMutableAttributedString()
        for segment in next.segments {
            if let body = renderings[segment.page.id] { rebuilt.append(body) }
            if segment.separatorRange != nil {
                rebuilt.append(NSAttributedString(string: "\n", attributes: [
                    .font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor,
                ]))
            }
        }
        let mounted = (model.activeEditor as? InkTextView).flatMap { $0.textStorage === storage ? $0 : nil }
        if let mounted, mounted.hasMarkedText() {
            _ = model.mergeProjection(rebuilt, into: mounted)
        } else if storage.string == rebuilt.string {
            model.applyingProjection {
                rebuilt.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rebuilt.length)) { value, range, _ in
                    if let value { storage.addAttribute(.attachment, value: value, range: range) }
                }
            }
        } else if let mounted {
            _ = model.mergeProjection(rebuilt, into: mounted)
        } else {
            model.applyingProjection { storage.setAttributedString(rebuilt) }
        }
        if let anchor, let segment = next.segments.first(where: { $0.page.id == anchor.page }) {
            let localStart = min(anchor.range.location, segment.bodyRange.length)
            let length = resuming ? min(anchor.range.length, segment.bodyRange.length - localStart) : 0
            savedSelection = NSRange(location: segment.bodyRange.location + localStart, length: length)
            if let editor = model.activeEditor as? InkTextView, editor.textStorage === storage {
                model.applyingProjection { editor.setSelectedRange(savedSelection) }
            }
        }
        if let mounted { savedSelection = mounted.selectedRange() }
        onChange?()
        return true
    }

    func selectionChanged(_ selection: NSRange) {
        savedSelection = selection
        guard let segment = projection.page(at: selection.location) else { return }
        model.selectContinuousPage(segment.page.id)
        model.viewStates.saveCaret(
            NSRange(location: selection.location - segment.bodyRange.location,
                    length: min(selection.length, NSMaxRange(segment.bodyRange) - selection.location)),
            for: segment.page.id)
    }

    func localSelection(_ selection: NSRange) -> (page: UInt64, range: NSRange, offset: Int)? {
        guard selection.location >= 0, selection.length >= 0,
              let segment = projection.page(at: selection.location),
              selection.length <= NSMaxRange(segment.bodyRange) - selection.location else { return nil }
        return (segment.page.id,
                NSRange(location: selection.location - segment.bodyRange.location, length: selection.length),
                segment.bodyRange.location)
    }

    @discardableResult
    func apply(json: String, intent: EditorEditIntent, selection: EditorEditSelection?) -> Bool {
        guard let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode([WireOperation].self, from: data)
        else { return false }
        return apply(decoded.map(\.operation), intent: intent, selection: selection)
    }

    private struct WireOperation: Decodable {
        let operation: DocumentEditOp
        enum Key: String, CodingKey { case ins, del, chip, at, text, len, id }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Key.self)
            guard root.allKeys.count == 1, let key = root.allKeys.first,
                  [.ins, .del, .chip].contains(key) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid operation"))
            }
            let fields = try root.nestedContainer(keyedBy: Key.self, forKey: key)
            let at = try fields.decode(Int.self, forKey: .at)
            switch key {
            case .ins: operation = .ins(at: at, text: try fields.decode(String.self, forKey: .text))
            case .del: operation = .del(at: at, len: try fields.decode(Int.self, forKey: .len))
            default: operation = .chip(at: at, id: try fields.decode(UInt64.self, forKey: .id))
            }
        }
    }

    @discardableResult
    func apply(_ ops: [DocumentEditOp], intent: EditorEditIntent, selection: EditorEditSelection?) -> Bool {
        guard let plan = try? projection.plan(ops) else {
            refresh(force: true)
            return false
        }
        guard !plan.edits.isEmpty else { return true }
        let positions = selection ?? EditorEditSelection(before: savedSelection, after: savedSelection)
        guard let json = Self.editJSON(plan.edits, intent: intent, selection: positions),
              model.coreClient.continuousApply(scope: scope, json: json) else {
            refresh(force: true)
            return false
        }
        projection = plan.projection
        didEdit(pages: plan.edits.map(\.pageID))
        onChange?()
        return true
    }

    static func editJSON(_ edits: [ContinuousDocumentProjection.PageEdit],
        intent: EditorEditIntent, selection: EditorEditSelection
    ) -> String? {
        let request: [String: Any] = [
            "pages": edits.map { edit -> [String: Any] in
                var entry: [String: Any] = [
                    "page_id": edit.pageID, "expected_uuid": edit.pageUUID,
                    "ops": Self.wireOps(edit.ops),
                ]
                if case .set(let uuid) = edit.join { entry["join_next"] = uuid as Any? ?? NSNull() }
                if let version = edit.expectedVersion { entry["expected_version"] = version }
                return entry
            },
            "intent": intent.rawValue,
            "selection": ["before": Self.wireRange(selection.before),
                          "after": Self.wireRange(selection.after)],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func step(back: Bool) -> PageModel.StepOutcome {
        refresh()
        guard let result = model.coreClient.continuousStep(scope: scope, back: back) else { return .nothing }
        didEdit(pages: result.pages)
        refresh(force: true)
        savedSelection = result.selection
        return .init(applied: true, selection: result.selection)
    }

    func compose(_ ranges: [NSRange]) -> PageModel.SelectionComposition {
        guard let json = selectionJSON(ranges) else { return .refused }
        switch model.coreClient.continuousCopy(json: json) {
        case .success(let fragment): return .composed(fragment)
        case .failure(.refused): return .refused
        case .failure(let refusal): return .pastCap(refusal)
        }
    }

    private func selectionJSON(_ ranges: [NSRange]) -> String? {
        guard ranges.count == 1, let range = ranges.first, range.length > 0,
              range.location >= 0, range.location <= projection.length,
              range.length <= projection.length - range.location else { return nil }
        let parts: [[String: Any]] = projection.segments.compactMap { segment in
            let body = NSIntersectionRange(range, segment.bodyRange)
            let separator = segment.separatorRange.map { NSIntersectionRange(range, $0).length > 0 } ?? false
            guard body.length > 0 || separator else { return nil }
            var part: [String: Any] = ["page_id": segment.page.id, "expected_uuid": segment.page.uuid,
                    "at": body.length > 0 ? body.location - segment.bodyRange.location : segment.bodyRange.length,
                    "len": body.length, "separator_after": separator]
            if let version = segment.page.version { part["expected_version"] = version }
            return part
        }
        guard let data = try? JSONSerialization.data(withJSONObject: parts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func cut(_ range: NSRange) -> PageModel.CutOutcome {
        guard let ranges = selectionJSON([range]),
              let plan = try? projection.plan([.del(at: range.location, len: range.length)]),
              let json = Self.editJSON(plan.edits, intent: .cut,
                selection: .init(before: range, after: NSRange(location: range.location, length: 0)))
        else { return .refused }
        switch model.coreClient.continuousCut(scope: scope, rangesJSON: ranges, editJSON: json) {
        case .failure(let refusal):
            if let line = PageModel.refusalLine(for: .pastCap(refusal), .cut) { model.flash(line) }
            refresh(force: true)
            return .refused
        case .success(let fragment):
            if !model.writeContinuousCut(fragment) {
                let reverted = model.coreClient.continuousStep(scope: scope, back: true)
                didEdit(pages: plan.edits.map(\.pageID))
                refresh(force: true)
                model.flash(reverted == nil ? "the clipboard could not be written and the cut could not be restored"
                    : PageModel.cutPutBackLine, tone: .actionable)
                return .cut(selecting: reverted?.selection ?? NSRange(location: range.location, length: 0))
            }
            didEdit(pages: plan.edits.map(\.pageID))
            return .cut(selecting: NSRange(location: range.location, length: 0))
        }
    }

    func paste(_ range: NSRange, from board: NSPasteboard?, activeCut: Bool = false,
               targetPage: UInt64? = nil) -> NSRange? {
        guard let segment = destination(at: range.location, page: targetPage, in: projection),
              let plan = try? projection.plan([.del(at: range.location, len: range.length)]) else { return nil }
        var edits = plan.edits
        if !edits.contains(where: { $0.pageID == segment.page.id }) {
            edits.append(.init(pageID: segment.page.id, pageUUID: segment.page.uuid, ops: [], join: .unchanged,
                               expectedVersion: segment.page.version))
        }
        let selection = EditorEditSelection(before: range, after: NSRange(location: range.location, length: 0))
        guard let json = Self.editJSON(edits, intent: .paste, selection: selection) else { return nil }
        let at = range.location - segment.bodyRange.location
        let placed: PlacedFragment?
        if activeCut {
            placed = model.coreClient.continuousPlaceActiveCut(scope: scope, json: json, sheet: segment.page.id, at: at)
        } else {
            guard let board, let item = SealedFragment.item(on: board) else { return nil }
            placed = model.coreClient.continuousPaste(scope: scope, json: json, sheet: segment.page.id,
                at: at, envelope: item.data(forType: SealedFragment.pasteboardType) ?? Data(),
                plainText: item.string(forType: .string))
        }
        guard let placed else {
            refresh(force: true)
            model.flash(PageModel.pasteRefusedLine)
            return nil
        }
        didEdit(pages: edits.map(\.pageID))
        refresh(force: true)
        if placed.unreadable { model.flash(PageModel.pastedPublicTextLine) }
        else if placed.elsewhere > 0 { model.flash(PageModel.pastedValueElsewhereLine) }
        return NSRange(location: range.location, length: placed.lengthUTF16)
    }

    func drag(_ range: NSRange, to index: Int, cloning: Bool, targetPage: UInt64? = nil) -> NSRange? {
        guard cloning || !(range.location...NSMaxRange(range)).contains(index),
              destination(at: index, page: targetPage, in: projection) != nil,
              let sources = selectionJSON([range]),
              let plan = try? projection.plan(cloning ? [] : [.del(at: range.location, len: range.length)])
        else { return nil }
        let destination = index - (!cloning && index > NSMaxRange(range) ? range.length : 0)
        guard let segment = self.destination(at: destination, page: targetPage, in: plan.projection) else { return nil }
        var edits = plan.edits
        if !edits.contains(where: { $0.pageID == segment.page.id }) {
            edits.append(.init(pageID: segment.page.id, pageUUID: segment.page.uuid, ops: [], join: .unchanged,
                expectedVersion: segment.page.version))
        }
        guard let json = Self.editJSON(edits, intent: .replacement,
            selection: .init(before: range, after: NSRange(location: destination, length: 0))),
              let placed = model.coreClient.continuousMove(scope: scope, sourceRangesJSON: sources, editJSON: json,
                targetPage: segment.page.id, targetOffset: destination - segment.bodyRange.location, cloning: cloning)
        else { return nil }
        didEdit(pages: edits.map(\.pageID))
        refresh(force: true)
        return NSRange(location: destination, length: placed.lengthUTF16)
    }

    func splitCheckpoint(source: UInt64, at offset: Int, destination: UInt64) -> Bool {
        guard let sourceIndex = projection.pages.firstIndex(where: { $0.id == source }),
              projection.pages.indices.contains(sourceIndex + 1),
              projection.pages[sourceIndex + 1].id == destination,
              let from = projection.segments.first(where: { $0.page.id == source }),
              let to = projection.segments.first(where: { $0.page.id == destination }),
              offset > 0, offset < from.bodyRange.length, to.bodyRange.length == 0 else { return false }
        let range = NSRange(location: from.bodyRange.location + offset, length: from.bodyRange.length - offset)
        guard let sources = selectionJSON([range]),
              let plan = try? projection.plan([.del(at: range.location, len: range.length)]) else { return false }
        var edits = plan.edits
        guard let index = edits.firstIndex(where: { $0.pageID == source }) else { return false }
        edits[index].join = .set(to.page.uuid)
        let successor = from.page.joinedNextUUID == to.page.uuid
            ? to.page.joinedNextUUID : from.page.joinedNextUUID
        edits.append(.init(pageID: destination, pageUUID: to.page.uuid, ops: [],
            join: .set(successor.flatMap { uuid in
                projection.pages.contains { $0.uuid == uuid } ? uuid : nil
            }), expectedVersion: to.page.version))
        let caret = NSRange(location: range.location, length: 0)
        guard let json = Self.editJSON(edits, intent: .replacement, selection: .init(before: caret, after: caret)),
              model.coreClient.continuousMove(scope: scope, sourceRangesJSON: sources, editJSON: json,
                targetPage: destination, targetOffset: 0, cloning: false) != nil else { return false }
        didEdit(pages: [source, destination])
        refresh(force: true)
        return true
    }

    private func destination(at index: Int, page: UInt64?, in projection: ContinuousDocumentProjection)
        -> ContinuousDocumentProjection.Segment? {
        guard let page else { return projection.page(at: index) }
        return projection.segments.first {
            $0.page.id == page && index >= $0.bodyRange.location && index <= NSMaxRange($0.bodyRange)
        }
    }

    static func wireRange(_ range: NSRange) -> [String: Int] {
        ["location": range.location, "length": range.length]
    }

    private func didEdit(pages: [UInt64]) {
        localRefreshPages = Set(pages)
        defer { localRefreshPages = [] }
        model.continuousDidEdit(pages: pages, scope: scope)
    }

    static func wireOps(_ ops: [DocumentEditOp]) -> [[String: Any]] {
        guard let json = DocumentEditOp.wireJSON(ops), let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values
    }
}
