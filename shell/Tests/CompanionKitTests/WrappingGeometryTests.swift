import AppKit
import XCTest

@testable import CompanionKit

@MainActor
final class WrappingGeometryTests: XCTestCase {
    private func makeTextView(ink: Bool = true) -> (
        NSTextView, NSTextStorage, InkLayoutManager, InkTextContainer
    ) {
        let storage = NSTextStorage()
        let layout = InkLayoutManager()
        let container = InkTextContainer(size: NSSize(
            width: 396, height: CGFloat.greatestFiniteMagnitude
        ))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let frame = NSRect(x: 20, y: 30, width: 420, height: 80)
        let text: NSTextView = ink
            ? InkTextView(frame: frame, textContainer: container)
            : NSTextView(frame: frame, textContainer: container)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        text.autoresizingMask = []
        text.minSize = NSSize(width: 5, height: 7)
        text.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        text.textContainerInset = NSSize(width: 12, height: 8)
        return (text, storage, layout, container)
    }

    private func lineRanges(in layout: NSLayoutManager, container: NSTextContainer) -> [NSRange] {
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) {
            _, _, _, range, _ in ranges.append(range)
        }
        return ranges
    }

    func testConfigurationLeavesViewAndScrollerSizingToTheCaller() {
        for ink in [true, false] {
            for wraps in [false, true] {
                let (text, storage, _, container) = makeTextView(ink: ink)
                let scroll = InkEditorView.bareScroller()
                scroll.frame.size = NSSize(width: 640, height: 480)
                scroll.hasHorizontalScroller = true
                let stack = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1_000))
                scroll.documentView = stack
                stack.addSubview(text)
                let frame = text.frame
                let minimum = text.minSize
                let maximum = text.maxSize
                let scroller = scroll.hasHorizontalScroller

                InkEditorView.configureWrapping(wraps, textView: text, viewportWidth: 420)

                XCTAssertEqual(text.frame, frame)
                XCTAssertEqual(text.minSize, minimum)
                XCTAssertEqual(text.maxSize, maximum)
                XCTAssertFalse(text.isHorizontallyResizable)
                XCTAssertFalse(text.isVerticallyResizable)
                XCTAssertEqual(text.autoresizingMask, [])
                XCTAssertEqual(scroll.hasHorizontalScroller, scroller)
                XCTAssertTrue(scroll.documentView === stack)
                XCTAssertEqual(container.widthTracksTextView, wraps)
                XCTAssertEqual(container.size.width, wraps ? 396 : .greatestFiniteMagnitude)
                XCTAssertEqual(container.size.height, .greatestFiniteMagnitude)
                XCTAssertEqual(container.capturedEditorMeasure, 396)
                withExtendedLifetime(storage) {}
            }
        }
    }

    func testUnwrappedUsedRectCanExceedAManuallySizedEditor() {
        for ink in [true, false] {
            let (text, storage, layout, container) = makeTextView(ink: ink)
            storage.setAttributedString(NSAttributedString(
                string: String(repeating: "a long line of ordinary text ", count: 60),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
            ))
            let frame = text.frame
            InkEditorView.configureWrapping(true, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            let wrapped = layout.usedRect(for: container)
            let wrappedLines = lineRanges(in: layout, container: container)
            XCTAssertLessThanOrEqual(wrapped.width, 396)

            InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            let unwrapped = layout.usedRect(for: container)
            XCTAssertGreaterThan(unwrapped.width, frame.width)
            XCTAssertLessThan(unwrapped.height, wrapped.height)
            XCTAssertEqual(text.frame, frame)

            InkEditorView.configureWrapping(true, textView: text, viewportWidth: 420)
            layout.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).width, 396)
            XCTAssertEqual(lineRanges(in: layout, container: container), wrappedLines)
            XCTAssertEqual(layout.usedRect(for: container).height, wrapped.height, accuracy: 0.5)
            XCTAssertEqual(text.frame, frame)
            withExtendedLifetime(storage) {}
        }
    }

    func testUnwrappedViewportResizeRemeasuresAttachmentsWithoutGrowingTheirContainer() {
        let (text, storage, layout, container) = makeTextView()
        storage.setAttributedString(InkEditorView.Coordinator.chipString(ChipInfo(
            chipId: 7, kind: "text", excerpt: "to…en", sizeLabel: "small", concealed: false
        )))
        let frame = text.frame
        for viewport in [CGFloat(420), 300, 540] {
            InkEditorView.configureWrapping(false, textView: text, viewportWidth: viewport)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: 0)
            let measure = viewport - text.textContainerInset.width * 2
            XCTAssertEqual(container.size.width, .greatestFiniteMagnitude)
            XCTAssertEqual(container.capturedEditorMeasure, measure)
            XCTAssertEqual(
                layout.attachmentSize(forGlyphAt: glyph).width,
                floor(measure - container.lineFragmentPadding * 2), accuracy: 0.5
            )
            XCTAssertEqual(text.frame, frame)
        }
        withExtendedLifetime(storage) {}
    }

    func testNestedEditorLayoutKeepsTheStackSuppliedViewportMeasure() {
        let (text, storage, _, container) = makeTextView()
        let scroll = InkEditorView.bareScroller()
        scroll.frame.size = NSSize(width: 640, height: 480)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 1_000))
        scroll.documentView = stack
        stack.addSubview(text)
        text.setFrameSize(NSSize(width: 2_000, height: 80))
        InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)

        text.layout()

        XCTAssertEqual(container.capturedEditorMeasure, 396)
        XCTAssertEqual(container.size.width, .greatestFiniteMagnitude)
        withExtendedLifetime(storage) {}
    }

    func testCoordinatorSkipsStackOwnedEditorWithoutCachingTheSkippedWrap() throws {
        let suite = "wrapping-geometry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let coordinator = InkEditorView.Coordinator(model: isolatedModel(defaults: defaults))
        let (text, storage, _, container) = makeTextView()
        let ink = try XCTUnwrap(text as? InkTextView)
        let scroll = InkEditorView.bareScroller()
        // CI runners show legacy scrollers, which take space from the clip.
        scroll.scrollerStyle = .legacy
        scroll.frame.size = NSSize(width: 640, height: 480)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1_000))
        scroll.documentView = stack
        stack.addSubview(ink)
        coordinator.textView = ink
        coordinator.observeClip(of: scroll)
        InkEditorView.configureWrapping(true, textView: ink, viewportWidth: 420)
        let frame = ink.frame
        let minimum = ink.minSize
        let horizontalScroller = scroll.hasHorizontalScroller

        coordinator.applyWrap(false)

        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertEqual(ink.frame, frame)
        XCTAssertEqual(ink.minSize, minimum)
        XCTAssertFalse(ink.isHorizontallyResizable)
        XCTAssertEqual(ink.autoresizingMask, [])
        XCTAssertEqual(scroll.hasHorizontalScroller, horizontalScroller)

        ink.removeFromSuperview()
        InkEditorView.seat(ink, in: scroll)
        coordinator.applyWrap(false)

        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertTrue(ink.isHorizontallyResizable)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertEqual(ink.minSize, scroll.contentSize)
        withExtendedLifetime(storage) {}
    }

    func testBlockLabelsUseTheVisibleViewportWithAnUnwrappedContainer() {
        let (text, storage, _, container) = makeTextView()
        InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)
        let visible = NSRect(x: 200, y: 0, width: 420, height: 80)
        let measure = InkEditorView.Coordinator.blockAffordanceMeasure(
            containerWidth: container.size.width, visibleRect: visible,
            containerOriginX: text.textContainerOrigin.x
        )
        let origin = InkEditorView.Coordinator.blockAffordanceOrigin(
            firstLine: .zero, containerWidth: measure, containerOrigin: text.textContainerOrigin,
            affordanceSize: NSSize(width: 90, height: 20)
        )
        XCTAssertEqual(origin.x + 90 + InkEditorView.Coordinator.blockLabelTrailingInset, visible.maxX)
        XCTAssertTrue(measure.isFinite)
        withExtendedLifetime(storage) {}
    }

    func testHorizontalDayScrollRepositionsBlockMetadataWithPointerOutsideEditor() throws {
        try assertHorizontalDayScrollRepositionsBlockMetadata(hovering: false)
    }

    func testHorizontalDayScrollRepositionsBlockMetadataWhileHoveringTheSameBlock() throws {
        try assertHorizontalDayScrollRepositionsBlockMetadata(hovering: true)
    }

    private func assertHorizontalDayScrollRepositionsBlockMetadata(hovering: Bool) throws {
        let suite = "wrapping-metadata-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        model.wrapsLines = false
        let tab = model.coreClient.newTab()
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let source = "alpha\n\n" + String(repeating: "ordinary words across a long day ", count: 80)
        let json = try JSONSerialization.data(withJSONObject: [["ink": source]])
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: try XCTUnwrap(String(data: json, encoding: .utf8))
        ))
        model.refresh()
        model.select(tab)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(model: model, coordinator: coordinator, emptyHint: "")
        scroll.scrollerStyle = .legacy
        let card = NSRect(x: 0, y: 0, width: 720, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { DayScrollView.dismantleNSView(scroll, coordinator: coordinator) }
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        DayScrollView.updateRoll(scroll, model: model, readOnly: false, coordinator: coordinator)
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        let editor = try XCTUnwrap(stack.editor)
        XCTAssertTrue(coordinator.textView === editor)
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.layOutBlockLabels(forMetas: [
            BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1),
            BlockInfo(id: "blank", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
            BlockInfo(id: "long", createdS: 1_000, modifiedS: 1_000, paragraphs: 1),
        ])
        scroll.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(editor.subviews.compactMap { $0 as? BlockMetadataField }.first)
        let compact = field.stringValue
        let pointer = hovering
            ? NSPoint(x: editor.visibleRect.maxX - 10, y: field.frame.midY)
            : NSPoint(x: -10_000, y: -10_000)
        XCTAssertEqual(editor.visibleRect.contains(pointer), hovering)
        editor.hoverRefreshInput = (
            window.convertPoint(toScreen: editor.convert(pointer, to: nil)), true, true
        )
        editor.refreshHover()
        XCTAssertEqual(field.stringValue != compact, hovering)
        let reading = field.stringValue
        let labelSize = field.frame.size
        let labelY = field.frame.minY
        let shapeCount = coordinator.blockLabelShapeCount
        let fitCount = coordinator.blockLabelFitCount
        let tooltipRect = try XCTUnwrap(coordinator.blockToolTipRects[0])
        let measurements = stack.measurements
        let rebuilds = stack.rebuilds
        let geometry = stack.measuredGeometry
        let editorFrame = editor.frame
        let containerSize = try XCTUnwrap(editor.textContainer).size
        let clip = scroll.contentView
        let originalY = clip.bounds.minY
        XCTAssertGreaterThan(stack.frame.width - clip.bounds.width, 240)
        XCTAssertEqual(coordinator.blockToolTipTags.count, 1)

        for x: CGFloat in [120, 240, 60, 0] {
            let oldTag = try XCTUnwrap(coordinator.blockToolTipTags.first)
            let tooltip = coordinator.view(editor, stringForToolTip: oldTag, point: .zero, userData: nil)
            clip.scroll(to: NSPoint(x: x, y: originalY))
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()

            XCTAssertEqual(clip.bounds.minX, x, accuracy: 0.5)
            XCTAssertEqual(clip.bounds.minY, originalY, accuracy: 0.5)
            XCTAssertEqual(
                field.frame.maxX + InkEditorView.Coordinator.blockLabelTrailingInset,
                editor.visibleRect.maxX, accuracy: 0.5,
                "the metadata label kept its pre-scroll horizontal position"
            )
            XCTAssertEqual(field.stringValue, reading, "scrolling changed the same block's hover")
            XCTAssertEqual(field.frame.size, labelSize)
            XCTAssertEqual(field.frame.minY, labelY)
            XCTAssertEqual(coordinator.blockToolTipTags.count, 1)
            let newTag = try XCTUnwrap(coordinator.blockToolTipTags.first)
            let newRect = try XCTUnwrap(coordinator.blockToolTipRects[0])
            XCTAssertEqual(newTag, oldTag, "a sideways scroll re-registered the row's tooltip")
            XCTAssertEqual(newRect, tooltipRect)
            XCTAssertGreaterThanOrEqual(newRect.maxX, editor.visibleRect.maxX)
            XCTAssertEqual(coordinator.view(
                editor, stringForToolTip: newTag, point: .zero, userData: nil
            ), tooltip)
            XCTAssertEqual(coordinator.blockLabelShapeCount, shapeCount)
            XCTAssertEqual(coordinator.blockLabelFitCount, fitCount)
            XCTAssertEqual(stack.measurements, measurements)
            XCTAssertEqual(stack.rebuilds, rebuilds)
            XCTAssertEqual(stack.measuredGeometry, geometry)
            XCTAssertEqual(editor.frame, editorFrame)
            XCTAssertEqual(editor.textContainer?.size, containerSize)
        }
        withExtendedLifetime(window) {}
    }

    func testAWrappedRowsTooltipIsTheRowAndAnUnwrappedOneRunsToTheViewsEdge() {
        let row = NSRect(x: 12, y: 40, width: 396, height: 18)
        XCTAssertEqual(InkEditorView.Coordinator.blockToolTipRect(
            row: row, containerWidth: 396, viewMaxX: 2_000
        ), row)
        for unbounded in [CGFloat.greatestFiniteMagnitude, .infinity, 1_000_000] {
            XCTAssertEqual(InkEditorView.Coordinator.blockToolTipRect(
                row: row, containerWidth: unbounded, viewMaxX: 2_000
            ), NSRect(x: 12, y: 40, width: 1_988, height: 18))
        }
    }

    func testASidewaysScrollKeepsAnUnwrappedTabsTooltipsUntilItsContentChanges() throws {
        let suite = "wrapping-tooltip-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.wrapsLines = false
        let tab = model.coreClient.newTab()
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let source = "alpha " + String(repeating: "ordinary words across a long line ", count: 80)
        let json = try JSONSerialization.data(withJSONObject: [["ink": source]])
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: try XCTUnwrap(String(data: json, encoding: .utf8))
        ))
        model.refresh()
        model.select(tab)
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = InkEditorView.makePage(
            model: model, sheetID: page, readOnly: false, coordinator: coordinator
        )
        scroll.scrollerStyle = .legacy
        let card = NSRect(x: 0, y: 0, width: 720, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { InkEditorView.dismantleNSView(scroll, coordinator: coordinator) }
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(scroll.documentView as? InkTextView)
        let stamps = BlockInfo(id: "alpha", createdS: 1_000, modifiedS: 300_000, paragraphs: 1)
        coordinator.layOutBlockLabels(forMetas: [stamps])
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        XCTAssertGreaterThan(editor.frame.width - clip.bounds.width, 240)
        let tags = coordinator.blockToolTipTags
        XCTAssertEqual(tags.count, 1)
        let rect = try XCTUnwrap(coordinator.blockToolTipRects[0])
        let field = try XCTUnwrap(editor.subviews.compactMap { $0 as? BlockMetadataField }.first)

        for x: CGFloat in [120, 240, 60, 0] {
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(clip.bounds.minX, x, accuracy: 0.5)
            XCTAssertEqual(
                field.frame.maxX + InkEditorView.Coordinator.blockLabelTrailingInset,
                editor.visibleRect.maxX, accuracy: 0.5
            )
            XCTAssertEqual(coordinator.blockToolTipTags, tags, "a sideways scroll re-registered")
            XCTAssertEqual(coordinator.blockToolTipRects[0], rect)
            XCTAssertGreaterThanOrEqual(rect.maxX, editor.visibleRect.maxX)
        }

        // New stamps are new tooltip text, and the row registers again.
        coordinator.layOutBlockLabels(forMetas: [BlockInfo(
            id: "alpha", createdS: 1_000, modifiedS: 400_000, paragraphs: 1
        )])
        let restamped = coordinator.blockToolTipTags
        XCTAssertEqual(restamped.count, 1)
        XCTAssertNotEqual(restamped, tags)
        XCTAssertEqual(coordinator.view(
            editor, stringForToolTip: tags[0], point: .zero, userData: nil
        ), "")

        // A longer line widens the page, and the row registers over the new width.
        let width = editor.frame.width
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        editor.insertText(
            String(repeating: "more words ", count: 40),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        coordinator.layOutBlockLabels(forMetas: [stamps])
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.frame.width, width)
        let widened = try XCTUnwrap(coordinator.blockToolTipRects[0])
        XCTAssertEqual(widened.maxX, editor.bounds.maxX, accuracy: 0.5)
        XCTAssertFalse(coordinator.blockToolTipTags.contains(restamped[0]))
        withExtendedLifetime(window) {}
    }

    /// Drawn through the real layout manager: with wrapping off and the
    /// text view sized to its longest line, the wash is under the code
    /// well past the first viewport, and absent under the prose there.
    func testAnUnwrappedFenceWashReachesPastTheViewport() throws {
        let (text, storage, layout, container) = makeTextView()
        text.drawsBackground = false
        text.appearance = NSAppearance(named: .aqua)
        let code = String(repeating: "a", count: 240)
        storage.setAttributedString(NSAttributedString(
            string: "prose\n```\nx\n\(code)\n```\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
        ))
        let fence = (storage.string as NSString).range(of: "```\nx\n\(code)\n```")
        layout.fenceRegions = [fence]

        InkEditorView.configureWrapping(false, textView: text, viewportWidth: 420)
        layout.ensureLayout(for: container)
        // Sized as the roll sizes a row: to the longest line, not the
        // aggregate used rect, which reports the unbounded sentinel.
        let sourceWidth = InkEditorView.measuredSourceWidth(of: text)
        XCTAssertGreaterThan(sourceWidth, 1000, "the case needs a line far wider than the viewport")
        XCTAssertLessThan(sourceWidth, 10000)
        text.setFrameSize(NSSize(
            width: sourceWidth,
            height: ceil(layout.usedRect(for: container).height) + text.textContainerInset.height * 2
        ))
        layout.ensureLayout(for: container)

        let rep = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
        text.cacheDisplay(in: text.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / text.bounds.width
        func alpha(x: CGFloat, line: Int) -> CGFloat {
            let glyph = layout.glyphIndexForCharacter(at: lineStart(line))
            let row = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).midY
                + text.textContainerOrigin.y
            return rep.colorAt(x: Int(x * scale), y: Int(row * scale))?.alphaComponent ?? -1
        }
        func lineStart(_ line: Int) -> Int {
            var location = 0
            for _ in 0..<line {
                location = NSMaxRange((storage.string as NSString)
                    .paragraphRange(for: NSRange(location: location, length: 0)))
            }
            return location
        }
        // Line 2 is the short `x` line inside the fence: no glyph at x=1000.
        XCTAssertGreaterThan(alpha(x: 1000, line: 2), 0, "no wash under the code past the viewport")
        XCTAssertGreaterThan(alpha(x: 100, line: 2), 0, "no wash under the code inside the viewport")
        XCTAssertEqual(alpha(x: 1000, line: 0), 0, "the prose line is washed")
        XCTAssertEqual(alpha(x: sourceWidth - 2, line: 2), 0, "the wash runs past the text view's edge")
        withExtendedLifetime(storage) {}
    }

    func testInvalidEditorMeasuresDoNotReplaceAnExistingCapture() {
        let container = InkTextContainer(size: .zero)
        XCTAssertTrue(container.setEditorMeasure(396))
        for measure in [CGFloat(0), -1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertFalse(container.setEditorMeasure(measure))
            XCTAssertEqual(container.capturedEditorMeasure, 396)
        }
    }

    func testAnUnusableViewportWrapsAtTheCapturedMeasure() {
        let (text, storage, _, container) = makeTextView()
        // Narrower than the text view, so tracking its frame would read 396.
        InkEditorView.configureWrapping(true, textView: text, viewportWidth: 300)
        XCTAssertEqual(container.size.width, 276)
        for viewport in [CGFloat(0), 24, -1, .nan, .infinity, 1_000_024, .greatestFiniteMagnitude] {
            InkEditorView.configureWrapping(true, textView: text, viewportWidth: viewport)
            XCTAssertEqual(container.size.width, 276, "viewport \(viewport)")
            XCTAssertEqual(container.capturedEditorMeasure, 276)
            XCTAssertTrue(container.widthTracksTextView)

            InkEditorView.configureWrapping(false, textView: text, viewportWidth: viewport)
            XCTAssertEqual(container.size.width, .greatestFiniteMagnitude)
            XCTAssertEqual(container.capturedEditorMeasure, 276)
        }
        withExtendedLifetime(storage) {}
    }

    func testAnUnusableViewportBeforeAnyCaptureLeavesTheWrappedWidthAlone() {
        let (text, storage, _, container) = makeTextView()
        InkEditorView.configureWrapping(true, textView: text, viewportWidth: 0)
        XCTAssertNil(container.capturedEditorMeasure)
        XCTAssertEqual(container.size.width, 396)
        withExtendedLifetime(storage) {}
    }
}
