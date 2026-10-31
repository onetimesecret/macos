import AppKit
import SwiftUI

public struct ContinuousPadView: NSViewRepresentable {
    @ObservedObject var model: PageModel
    let readOnly: Bool

    public init(model: PageModel, readOnly: Bool = false) {
        self.model = model
        self.readOnly = readOnly
    }

    public func makeCoordinator() -> InkEditorView.Coordinator {
        InkEditorView.Coordinator(model: model)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.surface = context.environment.presentationSurface
        return Self.makeSurface(model: model, coordinator: context.coordinator, readOnly: readOnly)
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.updateSurface(scroll, model: model, readOnly: readOnly, coordinator: context.coordinator)
    }

    static func makeSurface(
        model: PageModel, coordinator: InkEditorView.Coordinator, readOnly: Bool = false
    ) -> NSScrollView {
        let scroll = InkEditorView.bareScroller()
        updateSurface(scroll, model: model, readOnly: readOnly, coordinator: coordinator)
        return scroll
    }

    static func updateSurface(
        _ scroll: NSScrollView, model: PageModel, readOnly: Bool,
        coordinator: InkEditorView.Coordinator
    ) {
        guard model.owner == coordinator.surface else { return }
        let canvas: ContinuousPadCanvas
        let mounting = !(scroll.documentView is ContinuousPadCanvas)
        if let mounted = scroll.documentView as? ContinuousPadCanvas {
            canvas = mounted
        } else {
            canvas = ContinuousPadCanvas(model: model, coordinator: coordinator,
                document: model.continuousPadDocument())
            scroll.documentView = canvas
            canvas.observe(scroll)
            coordinator.observeClip(of: scroll)
        }
        canvas.update(document: model.continuousPadDocument(), readOnly: readOnly)
        if !model.rollGeometry.holdsClaim(canvas) {
            model.claimRollGeometry(by: canvas,
                scroller: { [weak canvas] in canvas?.scroll(to: NSPoint(x: 0, y: $0)) },
                scrubber: { [weak canvas] in canvas?.scroll(to: NSPoint(x: 0, y: $0)) },
                wheel: { [weak scroll] in scroll?.scrollWheel(with: $0) },
                place: { [weak canvas] in canvas?.readingPlace },
                pad: { [weak canvas] in canvas?.padID }, from: coordinator.surface)
        }
        if mounting || model.onAnchorToday == nil {
            model.installTodayAnchor({ [weak canvas] in canvas?.scrollToToday() }, from: coordinator.surface)
        }
        if let place = model.viewStates.takeRollPlace() { canvas.restore(place) }
        switch model.takeRollRequest() {
        case .today: canvas.scrollToToday()
        case .page(let page): canvas.open(page: page)
        case nil: break
        }
        canvas.measure()
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: InkEditorView.Coordinator) {
        guard let canvas = scroll.documentView as? ContinuousPadCanvas else { return }
        canvas.savePosition()
        if coordinator.model.rollGeometry.holdsClaim(canvas) {
            if let pad = canvas.padID {
                coordinator.model.rememberPadReadingPlace(canvas.readingPlace, for: pad)
            }
            coordinator.model.rollGeometry.reset(from: canvas)
        }
        if canvas.editor.textStorage === canvas.document.storage { canvas.document.onChange = nil }
        coordinator.invalidateOrdinaryPasteMeasurement()
        coordinator.leavePage(canvas.editor, scrollView: nil)
        coordinator.model.retireEditor(canvas.editor)
        if (coordinator.model.activeEditor as? InkTextView)?.coordinator?.continuousDocument !== canvas.document {
            canvas.document.suspend()
        }
        canvas.stopObserving()
    }
}

@MainActor
final class ContinuousPadCanvas: NSView {
    static let gutterWidth: CGFloat = 84
    let editor: InkTextView
    let coordinator: InkEditorView.Coordinator
    let model: PageModel
    private(set) var document: ContinuousPadDocument
    private(set) var padID: UUID?
    private(set) var extents: [RollGeometry.Extent] = []
    private(set) var checkpointLabels: [NSTextField] = []
    private weak var observedScroll: NSScrollView?
    private var selectedPage: UInt64?
    private var pendingOffset: NSPoint?
    private var pendingPlace: RollPlace?
    private var measuring = false
    private var needsMeasurement = true
    private var measuredViewport = NSSize.zero
    private var measuredTypeface: InkStyle.Typeface?
    private var measuredPreview: PreviewRenderingScope?
    private var measuredSyntax: Bool?
    private struct CheckpointMetadata: Equatable {
        let page: UInt64
        let day: Int?
        let created: UInt64?
    }
    private var measuredCheckpoints: [CheckpointMetadata] = []
    private var measuredStampFormat: StreamNavigator.StampFormat?
    private var appliedWrap: Bool?
    private let geometryID = UUID()
    private var geometryRevision: UInt64 = 0
    private var geometryHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { editor.isEditable }

    init(model: PageModel, coordinator: InkEditorView.Coordinator, document: ContinuousPadDocument) {
        self.model = model
        self.coordinator = coordinator
        self.document = document
        self.padID = model.pads.isEnabled ? model.pads.activeID : nil
        coordinator.continuousDocument = document
        coordinator.currentSheet = nil
        InkEditorView.Coordinator.shedLayoutManagers(from: document.storage, keeping: nil)
        editor = InkEditorView.makeSurface(over: document.storage, coordinator: coordinator)
        super.init(frame: .zero)
        editor.textContainerInset = NSSize(width: 12, height: InkEditorView.Coordinator.topInset)
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.postsFrameChangedNotifications = true
        addSubview(editor)
        bindDocument()
        coordinator.restyle()
        restoreSelection()
        pendingOffset = document.savedOffset
        selectedPage = model.selectedPageID
        coordinator.announce(editor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func bindDocument() {
        document.onChange = { [weak self] in
            self?.needsMeasurement = true
            self?.needsLayout = true
            self?.needsDisplay = true
        }
    }

    func observe(_ scroll: NSScrollView) {
        stopObserving()
        observedScroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportScrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(editorResized),
            name: NSView.frameDidChangeNotification, object: editor)
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        observedScroll = nil
    }

    @objc private func viewportChanged(_ notification: Notification) { measure() }

    @objc private func viewportScrolled(_ notification: Notification) {
        if !measuring { savePosition(); publishGeometry() }
    }

    @objc private func editorResized(_ notification: Notification) {
        if !measuring { needsMeasurement = true; needsLayout = true }
    }

    override func layout() {
        super.layout()
        measure()
    }

    func update(document incoming: ContinuousPadDocument, readOnly: Bool) {
        if incoming !== document || editor.textStorage !== incoming.storage {
            savePosition()
            let outgoing = document
            document.onChange = nil
            coordinator.keepNaming()
            coordinator.closeNote()
            InkEditorView.discardComposition(in: editor)
            editor.textStorage?.delegate = nil
            InkEditorView.Coordinator.shedLayoutManagers(from: incoming.storage, keeping: editor.layoutManager)
            editor.layoutManager?.replaceTextStorage(incoming.storage)
            if outgoing !== incoming { outgoing.suspend() }
            incoming.storage.delegate = coordinator
            document = incoming
            needsMeasurement = true
            padID = model.pads.isEnabled ? model.pads.activeID : nil
            coordinator.continuousDocument = incoming
            coordinator.currentSheet = nil
            bindDocument()
            pendingOffset = incoming.savedOffset
            selectedPage = model.selectedPageID
            coordinator.restyle()
            restoreSelection()
            coordinator.announce(editor)
        }
        if document.refresh() {
            restoreSelection()
            coordinator.restyle()
        }
        coordinator.announce(editor)
        coordinator.updateEditability(of: editor, to: !readOnly && !document.projection.pages.isEmpty)
        let checkpoints = model.navigationTabs.compactMap { tab in
            tab.pageID.map { CheckpointMetadata(page: $0, day: tab.pageDayOffset, created: tab.pageCreatedMs) }
        }
        if measuredCheckpoints != checkpoints || measuredStampFormat != model.stampFormat {
            measuredCheckpoints = checkpoints
            measuredStampFormat = model.stampFormat
            needsMeasurement = true
        }
        if measuredTypeface != model.typeface || measuredPreview != model.previewRendering
            || measuredSyntax != model.syntaxHighlightingEnabled {
            needsMeasurement = true
            measuredTypeface = model.typeface
            measuredPreview = model.previewRendering
            measuredSyntax = model.syntaxHighlightingEnabled
        }
        coordinator.applyTypeface(model.typeface)
        coordinator.applySyntaxHighlighting(model.syntaxHighlightingEnabled)
        coordinator.applyPreviewRendering(model.previewRendering)
        coordinator.applyLanguageDetection(model.languageDetectionEnabled)
        model.scheduleEditStepsRefresh()
        measure()
        if let page = model.selectedPageID, page != selectedPage {
            selectedPage = page
            if document.projection.page(at: editor.selectedRange().location)?.page.id != page {
                open(page: page)
            }
        }
    }

    private func restoreSelection() {
        let saved = document.savedSelection
        let start = min(max(0, saved.location == NSNotFound ? 0 : saved.location), document.storage.length)
        editor.setSelectedRange(NSRange(location: start, length: min(max(0, saved.length), document.storage.length - start)))
    }

    func savePosition() {
        guard editor.textStorage === document.storage, !document.isSuspended else { return }
        document.savedSelection = editor.selectedRange()
        if let scroll = observedScroll { document.savedOffset = scroll.contentView.bounds.origin }
    }

    func measure() {
        guard !measuring, let scroll = observedScroll,
              let layout = editor.layoutManager, let container = editor.textContainer,
              scroll.contentSize.width > 0 else { return }
        guard needsMeasurement || measuredViewport != scroll.contentSize || appliedWrap != model.wrapsLines
            || pendingOffset != nil || pendingPlace != nil else { return }
        measuring = true
        defer { measuring = false }
        let viewport = scroll.contentSize
        needsMeasurement = false
        measuredViewport = viewport
        let width = max(1, viewport.width - Self.gutterWidth)
        let wraps = model.wrapsLines
        let reading = appliedWrap != nil && appliedWrap != wraps ? readingPlace : nil
        appliedWrap = wraps
        scroll.hasHorizontalScroller = !wraps
        editor.isHorizontallyResizable = !wraps
        editor.minSize = NSSize(width: width, height: max(1, viewport.height))
        editor.setFrameOrigin(NSPoint(x: Self.gutterWidth, y: 0))
        if wraps || editor.frame.width < width {
            editor.setFrameSize(NSSize(width: width, height: max(1, editor.frame.height)))
        }
        InkEditorView.configureWrapping(wraps, textView: editor, viewportWidth: width)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let origin = editor.textContainerOrigin
        let extra = layout.extraLineFragmentTextContainer === container ? layout.extraLineFragmentRect.maxY : 0
        let height = max(viewport.height, max(used.maxY, extra) + origin.y + 32)
        let editorWidth = wraps ? width : max(width, used.maxX + origin.x * 2)
        editor.setFrameSize(NSSize(width: editorWidth, height: height))
        setFrameSize(NSSize(width: editorWidth + Self.gutterWidth, height: height))
        let nextExtents = measureExtents()
        if nextExtents != extents || height != geometryHeight {
            extents = nextExtents
            geometryHeight = height
            geometryRevision &+= 1
        }
        placeLabels()
        if let reading { pendingPlace = reading }
        if let place = pendingPlace {
            pendingPlace = nil
            restore(place)
            pendingOffset = nil
        } else if let offset = pendingOffset {
            pendingOffset = nil
            self.scroll(to: offset)
        }
        publishGeometry()
    }

    private func lineRect(at index: Int) -> NSRect {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return .zero }
        let length = document.storage.length
        let offset = min(max(0, index), length)
        let rect: NSRect
        if (offset == length || length == 0), layout.extraLineFragmentTextContainer === container,
           layout.extraLineFragmentRect.height > 0 {
            rect = layout.extraLineFragmentRect
        } else if layout.numberOfGlyphs > 0 {
            let glyph = layout.glyphIndexForCharacter(at: min(offset, max(0, length - 1)))
            rect = layout.lineFragmentRect(forGlyphAt: min(glyph, layout.numberOfGlyphs - 1), effectiveRange: nil)
        } else {
            rect = NSRect(x: 0, y: 0, width: 0, height: InkStyle.baseFont.pointSize * 1.3)
        }
        return rect.offsetBy(dx: editor.frame.minX + editor.textContainerOrigin.x,
            dy: editor.frame.minY + editor.textContainerOrigin.y)
    }

    private func measureExtents() -> [RollGeometry.Extent] {
        guard let layout = editor.layoutManager else { return [] }
        let buckets = Dictionary(uniqueKeysWithValues: model.navigationTabs.compactMap { tab in
            tab.pageID.map { ($0, tab.pageDayOffset ?? 0) }
        })
        return document.projection.segments.map { segment in
            let first = lineRect(at: segment.bodyRange.location)
            let last = lineRect(at: max(segment.bodyRange.location, NSMaxRange(segment.bodyRange) - 1))
            var lines: [RollGeometry.LineMark] = []
            if segment.bodyRange.length > 0 {
                let glyphs = layout.glyphRange(forCharacterRange: segment.bodyRange, actualCharacterRange: nil)
                layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                    lines.append(.init(y: rect.minY + self.editor.textContainerOrigin.y,
                        width: min(1, max(0, used.width / max(1, rect.width)))))
                }
            }
            return .init(bucket: buckets[segment.page.id] ?? 0, page: segment.page.id,
                top: first.minY, height: max(first.height, last.maxY - first.minY), lines: lines)
        }
    }

    private func placeLabels() {
        let summaries = Dictionary(uniqueKeysWithValues: model.navigationTabs.compactMap { tab in
            tab.pageID.map { ($0, tab) }
        })
        let groups = Dictionary(grouping: Array(summaries.values)) {
            TimeUnit.day.bucket(dayOffset: $0.pageDayOffset ?? 0)
        }
        var stamps: [UInt64: String] = [:]
        for group in groups.values {
            let readings = StreamNavigator.stamps(createdMs: group.map(\.pageCreatedMs), format: model.stampFormat)
            for (summary, reading) in zip(group, readings) {
                if let page = summary.pageID { stamps[page] = reading }
            }
        }
        var previousY: CGFloat?
        var usedLabels = 0
        for extent in extents {
            guard let page = extent.page, summaries[page] != nil else { continue }
            if let previousY, abs(previousY - extent.top) < 1 {
                checkpointLabels[usedLabels - 1].stringValue = "•••"
                checkpointLabels[usedLabels - 1].setAccessibilityLabel("Checkpoints on this line")
                continue
            }
            let stamp = stamps[page] ?? ""
            let value = stamp.isEmpty ? "•" : stamp
            let label: NSTextField
            if usedLabels < checkpointLabels.count { label = checkpointLabels[usedLabels] }
            else {
                label = NSTextField(labelWithString: value)
                checkpointLabels.append(label)
                addSubview(label)
            }
            label.stringValue = value
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.alignment = .right
            label.frame = NSRect(x: 8, y: extent.top + 2, width: Self.gutterWidth - 22, height: 16)
            label.setAccessibilityLabel("Checkpoint, \(label.stringValue)")
            usedLabels += 1
            previousY = extent.top
        }
        while checkpointLabels.count > usedLabels { checkpointLabels.removeLast().removeFromSuperview() }
    }

    private func publishGeometry() {
        guard let scroll = observedScroll else { return }
        model.rollGeometry.publish(.init(document: .init(extents: extents, height: frame.height,
            identity: geometryID, revision: geometryRevision),
            viewportTop: scroll.contentView.bounds.minY, viewportHeight: scroll.contentView.bounds.height), from: self)
    }

    var readingPlace: RollPlace? {
        guard let scroll = observedScroll,
              var anchor = ScrollAnchor(topOf: editor, clipOrigin: NSPoint(
                x: scroll.contentView.bounds.minX - editor.frame.minX,
                y: scroll.contentView.bounds.minY - editor.frame.minY)),
              let segment = document.projection.page(at: anchor.characterIndex) else { return nil }
        anchor.characterIndex -= segment.bodyRange.location
        anchor.x = scroll.contentView.bounds.minX
        return RollPlace(page: segment.page.id, anchor: anchor, length: segment.bodyRange.length,
            atTop: scroll.contentView.bounds.minY <= 0)
    }

    func restore(_ place: RollPlace) {
        guard let segment = document.projection.segments.first(where: { $0.page.id == place.page }) else { return }
        guard let scroll = observedScroll, scroll.contentSize.width > 0 else {
            pendingPlace = place
            return
        }
        var anchor = place.anchor
        anchor.characterIndex = segment.bodyRange.location + min(max(0, anchor.characterIndex), segment.bodyRange.length)
        if let point = anchor.offset(in: editor) {
            self.scroll(to: NSPoint(x: point.x, y: place.atTop ? 0 : point.y + editor.frame.minY))
        }
    }

    func open(page: UInt64) {
        guard let segment = document.projection.segments.first(where: { $0.page.id == page }) else { return }
        editor.setSelectedRange(NSRange(location: segment.bodyRange.location, length: 0))
        document.selectionChanged(editor.selectedRange())
        selectedPage = page
        measure()
        scroll(to: NSPoint(x: observedScroll?.contentView.bounds.minX ?? 0,
            y: max(0, lineRect(at: segment.bodyRange.location).minY - 20)))
    }

    func scrollToToday() {
        if let page = document.projection.pages.first(where: { page in
            model.navigationTabs.contains { $0.pageID == page.id && $0.pageDayOffset == 0 }
        }) { open(page: page.id) }
        else { scroll(to: .zero) }
    }

    func scroll(to offset: NSPoint) {
        guard let scroll = observedScroll else { return }
        let clip = scroll.contentView
        let point = NSPoint(x: model.wrapsLines ? 0 : min(max(0, offset.x), max(0, frame.width - clip.bounds.width)),
            y: min(max(0, offset.y), max(0, frame.height - clip.bounds.height)))
        clip.scroll(to: point)
        scroll.reflectScrolledClipView(clip)
        document.savedOffset = point
        publishGeometry()
    }
}
