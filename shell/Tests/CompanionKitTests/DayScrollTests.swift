import AppKit
import XCTest

@testable import CompanionKit

/// The roll, in a real window with a real TextKit stack (issue #79).
///
/// What is under test here is geometry and identity: where the days
/// stand, how tall the stack is, which view is the editor, and what
/// happens to that one view when the selected day moves. None of it is
/// worth modelling twice, so this suite builds the surface the app
/// builds (`DayScrollView.makeRoll` is the same call `makeNSView`
/// makes) and asserts against the frames AppKit actually gave it, in
/// the `PageScrollTests` idiom.
///
/// The days are hand-spread. A live core cannot put two pages on two
/// different days: the ageing seam restores a snapshot at a later wall
/// stamp and a restore carries every page's `created_wall_ms` through
/// untouched, so every page a test mints is born today. The pages, their
/// storages, their documents and their ids are therefore real, and only
/// the day offsets on the summaries are rewritten before the projection
/// is computed.
@MainActor
final class DayScrollTests: XCTestCase {
    private func makeModel(defaults supplied: UserDefaults? = nil) throws -> PageModel {
        let defaults: UserDefaults
        if let supplied {
            defaults = supplied
        } else {
            let suiteName = "companion-day-scroll-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        return model
    }

    /// Seed an independent page through the core, without splitting
    /// the selected page at the editor's caret.
    @discardableResult
    private func page(in model: PageModel, saying ink: String) throws -> UInt64 {
        let tab = model.coreClient.newTab()
        XCTAssertNotEqual(tab, 0)
        let page = try XCTUnwrap(model.coreClient.tabs().first { $0.id == tab }?.pageID)
        let escaped = ink.replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: "[{\"ink\": \"\(escaped)\"}]"
        ))
        model.refresh()
        model.select(tab)
        return page
    }

    /// The same summary, filed under another day. Written out in
    /// declaration order, which is the order the memberwise initializer
    /// takes and the order a new field would have to be added in.
    private func onDay(_ tab: TabSummary, _ day: Int) -> TabSummary {
        TabSummary(
            id: tab.id,
            hasPage: tab.hasPage,
            pageID: tab.pageID,
            title: tab.title,
            titleSource: tab.titleSource,
            rungCode: tab.rungCode,
            rungLabel: tab.rungLabel,
            remainingMs: tab.remainingMs,
            remainingLabel: tab.remainingLabel,
            spokenRemaining: tab.spokenRemaining,
            fractionRemaining: tab.fractionRemaining,
            paused: tab.paused,
            holdToppedUp: tab.holdToppedUp,
            holdRemainingMs: tab.holdRemainingMs,
            chipCount: tab.chipCount,
            lastHour: tab.lastHour,
            pageHasContent: tab.pageHasContent,
            pageDayOffset: day,
            pageCreatedMs: tab.pageCreatedMs
        )
    }

    /// The model's real slots, filed under the days named for them, one
    /// entry per slot, in strip order.
    private func filed(_ model: PageModel, under days: [Int]) -> [TabSummary] {
        var tabs: [TabSummary] = []
        for (index, tab) in model.tabs.enumerated() {
            tabs.append(onDay(tab, index < days.count ? days[index] : 0))
        }
        return tabs
    }

    /// The model's real pages, one to a day, newest first in strip
    /// order.
    private func spreadOverDays(_ model: PageModel, selecting page: UInt64?) -> TimeUnitProjection {
        var days: [Int] = []
        for index in model.tabs.indices { days.append(-index) }
        return TimeUnitProjection.project(
            tabs: filed(model, under: days), selectedPageID: page, unit: .day
        )
    }

    private struct Roll {
        let window: NSWindow
        let scroll: NSScrollView
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    /// The roll in a card-sized window, built as the surface builds it. An ordered
    /// window is visible, so a rail jump animates, and stands off every screen.
    private func mountRoll(
        model: PageModel, width: CGFloat = 420, height: CGFloat = 320, ordered: Bool = false
    ) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator,
            emptyHint: "click, ⌃⌥Space, or ↩ to start one"
        )
        let card = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: card, styleMask: ordered ? [.borderless] : [.titled],
            backing: .buffered, defer: false
        )
        if ordered {
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFront(nil)
            addTeardownBlock { @MainActor in window.orderOut(nil) }
        }
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        return Roll(window: window, scroll: scroll, stack: stack, coordinator: coordinator)
    }

    /// Let the queue turn. The roll hands its measurement to the rail
    /// on a hop, so nothing about the publication is true until the loop
    /// has had one.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    private func longPage(lines: Int) -> String {
        (0..<lines).map { "line \($0) of a day that goes on" }.joined(separator: "\n")
    }

    private func select(_ page: UInt64, in model: PageModel) throws {
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == page }?.id))
    }

    private func longLine(repetitions: Int = 100) -> String {
        String(repeating: "ordinary words across a long day ", count: repetitions)
    }

    private func textMetrics(_ text: NSTextView) throws -> (used: NSRect, lines: Int) {
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        var lines = 0
        var used = NSRect.zero
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) {
            _, line, _, _, _ in
            used = lines == 0 ? line : used.union(line)
            lines += 1
        }
        return (used, lines)
    }

    private func glyphRect(in text: NSTextView, at character: Int) throws -> NSRect {
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: character)
        return manager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: container
        ).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    private func scroll(_ roll: Roll, to point: NSPoint) {
        roll.scroll.contentView.scroll(to: point)
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)
    }

    private func assertGlyphVisible(
        at character: Int, in text: NSTextView, on roll: Roll,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let glyph = text.convert(try glyphRect(in: text, at: character), to: roll.stack)
        let visible = roll.scroll.contentView.bounds
        XCTAssertGreaterThan(glyph.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(glyph.minX, visible.minX - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(glyph.maxX, visible.maxX + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(glyph.maxX, roll.stack.bounds.maxX, file: file, line: line)
        XCTAssertTrue(visible.intersects(glyph), "glyph \(glyph), viewport \(visible)", file: file, line: line)
    }

    private func assertCaretVisible(
        in editor: InkTextView, on roll: Roll,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let screen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let caret = roll.stack.convert(roll.window.convertFromScreen(screen), from: nil)
        let visible = roll.scroll.contentView.bounds
        XCTAssertGreaterThan(caret.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(caret.minX, visible.minX - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(caret.maxX, visible.maxX + 0.5, file: file, line: line)
        XCTAssertGreaterThan(caret.maxY, visible.minY, file: file, line: line)
        XCTAssertLessThan(caret.minY, visible.maxY, file: file, line: line)
    }

    private func finderAction(_ action: NSTextFinder.Action, in editor: InkTextView) {
        let item = NSMenuItem(title: "", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        item.tag = action.rawValue
        editor.performTextFinderAction(item)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func copyFindPasteboardItems() -> [NSPasteboardItem] {
        (NSPasteboard(name: .find).pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: User-selected wrapping

    func testBothWrapChoicesMeasureTheLongestActiveAndInactiveDay() throws {
        for wraps in [true, false] {
            for longestIsActive in [true, false] {
                let model = try makeModel()
                model.wrapsLines = wraps
                let longest = try page(in: model, saying: longLine())
                let short = try page(in: model, saying: "short")
                let selected = longestIsActive ? longest : short
                try select(selected, in: model)
                let roll = try mountRoll(model: model)
                roll.stack.update(projection: spreadOverDays(model, selecting: selected),
                                  selectedPage: selected, readOnly: false)
                let text = try XCTUnwrap(roll.stack.laidOut.first {
                    $0.header.pageIdentity == longest
                }?.body as? NSTextView)
                XCTAssertEqual(text === roll.stack.editor, longestIsActive)
                let metrics = try textMetrics(text)
                let viewport = roll.scroll.contentView.bounds.width
                XCTAssertEqual(roll.scroll.hasHorizontalScroller, !wraps)
                for part in roll.stack.laidOut {
                    let body = try XCTUnwrap(part.body as? NSTextView)
                    XCTAssertEqual(body.textContainer?.widthTracksTextView, wraps)
                    XCTAssertEqual(body.frame.width, roll.stack.frame.width, accuracy: 0.5)
                }
                if wraps {
                    XCTAssertEqual(roll.stack.frame.width, viewport, accuracy: 0.5)
                    XCTAssertLessThanOrEqual(metrics.used.maxX, viewport)
                    XCTAssertGreaterThan(metrics.lines, 1)
                } else {
                    XCTAssertEqual(metrics.lines, 1)
                    XCTAssertGreaterThan(metrics.used.width, viewport)
                    XCTAssertGreaterThanOrEqual(roll.stack.frame.width,
                                                metrics.used.maxX + text.textContainerInset.width * 2)
                    scroll(roll, to: NSPoint(x: roll.stack.frame.width - viewport, y: 0))
                    XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
                    XCTAssertEqual(roll.scroll.contentView.bounds.maxX,
                                   roll.stack.frame.maxX, accuracy: 0.5)
                }
            }
        }
    }

    func testMountedSettingsWrapChangeReflowsTheSameProjectionWithoutReplacingText() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: longLine(repetitions: 60))
        let inactive = try page(in: model, saying: longLine())
        try select(selected, in: model)
        model.wrapsLines = true
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[inactive])
        editor.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        let selection = NSRange(location: 8, length: 4)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let storage = editor.textStorage
        let quietStorage = quiet.textStorage
        let manager = editor.layoutManager
        let undo = editor.undoManager
        let text = editor.string
        let quietText = quiet.string
        let coreText = {
            model.coreClient.documentRuns(sheet: selected).reduce(into: "") {
                if case .ink(let ink) = $1 { $0 += ink }
            }
        }
        let coreTextBefore = coreText()
        let canUndo = model.canUndoEdit(sheet: selected)
        let canRedo = model.canRedoEdit(sheet: selected)
        let undoName = model.undoActionName(sheet: selected)
        let rebuilds = roll.stack.rebuilds
        XCTAssertTrue(canUndo)
        var wrappedHeights: [CGFloat] = []
        for wraps in [true, false, true] {
            model.wrapsLines = wraps
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(roll.stack.quietRegions[inactive] === quiet)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertTrue(quiet.textStorage === quietStorage)
            XCTAssertTrue(editor.layoutManager === manager)
            XCTAssertTrue(editor.undoManager === undo)
            XCTAssertTrue(roll.window.firstResponder === editor)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(quiet.string, quietText)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(coreText(), coreTextBefore)
            XCTAssertEqual(model.canUndoEdit(sheet: selected), canUndo)
            XCTAssertEqual(model.canRedoEdit(sheet: selected), canRedo)
            XCTAssertEqual(model.undoActionName(sheet: selected), undoName)
            XCTAssertEqual(roll.stack.rebuilds, rebuilds)
            let metrics = try textMetrics(editor)
            XCTAssertEqual(metrics.lines == 1, !wraps)
            if wraps {
                wrappedHeights.append(roll.stack.frame.height)
                XCTAssertEqual(roll.stack.frame.width, roll.scroll.contentView.bounds.width, accuracy: 0.5)
                XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
            } else {
                XCTAssertGreaterThan(roll.stack.frame.width, roll.scroll.contentView.bounds.width)
                scroll(roll, to: NSPoint(x: roll.scroll.contentView.bounds.width / 2, y: 0))
                XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
            }
        }
        XCTAssertEqual(wrappedHeights.first, wrappedHeights.last)
        roll.coordinator.step(back: true)
        XCTAssertEqual(editor.string, String(text.dropFirst("edit ".count)))
        roll.coordinator.step(back: false)
        XCTAssertEqual(editor.string, text)
    }

    func testRealDeletionShrinksDayExtentsAndUndoRestoresThemForBothWrapChoices() throws {
        for wraps in [true, false] {
            let model = try makeModel()
            model.wrapsLines = wraps
            let original = longLine() + "\n" + longPage(lines: 40)
            let selected = try page(in: model, saying: original)
            try page(in: model, saying: "short inactive day")
            try select(selected, in: model)
            let roll = try mountRoll(model: model)
            let projection = spreadOverDays(model, selecting: selected)
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            XCTAssertTrue(roll.window.makeFirstResponder(editor))
            let storage = editor.textStorage
            let before = roll.stack.measuredGeometry
            let width = roll.stack.frame.width
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count - 4))
            editor.deleteBackward(nil)
            editor.breakUndoCoalescing()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            let deleted = roll.stack.measuredGeometry

            XCTAssertEqual(editor.string, String(original.suffix(4)))
            XCTAssertLessThan(deleted.extents[0].height, before.extents[0].height)
            XCTAssertLessThan(deleted.extents[1].top, before.extents[1].top)
            XCTAssertLessThan(deleted.documentHeight, before.documentHeight)
            XCTAssertEqual(roll.stack.frame.width, roll.scroll.contentView.bounds.width, accuracy: 0.5)
            XCTAssertTrue(model.canUndoEdit(sheet: selected))
            roll.coordinator.step(back: true)
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertEqual(editor.string, original)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(roll.stack.frame.width, width, accuracy: 0.5)
            XCTAssertEqual(roll.stack.measuredGeometry.extents, before.extents)
            XCTAssertEqual(roll.stack.measuredGeometry.documentHeight, before.documentHeight, accuracy: 0.5)
        }
    }

    func testScrollRangeToVisibleRevealsTheFarRightGlyphOfAnUnwrappedDay() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine())
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: spreadOverDays(model, selecting: selected),
                          selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let last = NSRange(location: editor.string.utf16.count - 2, length: 1)
        let glyph = editor.convert(try glyphRect(in: editor, at: last.location), to: roll.stack)
        XCTAssertGreaterThan(glyph.minX, roll.scroll.contentView.bounds.maxX)
        editor.scrollRangeToVisible(last)
        let visible = roll.scroll.contentView.bounds
        XCTAssertGreaterThan(visible.minX, 0)
        XCTAssertGreaterThanOrEqual(glyph.minX, visible.minX - 0.5)
        XCTAssertLessThanOrEqual(glyph.maxX, visible.maxX + 0.5)
        XCTAssertTrue(visible.intersects(glyph))
    }

    func testInactiveDayClickUsesWindowCoordinatesAfterHorizontalScroll() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine())
        let inactive = try page(in: model, saying: longLine())
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: spreadOverDays(model, selecting: selected),
                          selectedPage: selected, readOnly: false)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[inactive])
        XCTAssertTrue(roll.window.makeFirstResponder(try XCTUnwrap(roll.stack.editor)))
        let glyph = try glyphRect(in: quiet, at: quiet.string.utf16.count / 2)
        let local = NSPoint(x: glyph.midX, y: glyph.midY)
        let document = quiet.convert(local, to: roll.stack)
        scroll(roll, to: NSPoint(x: document.x - roll.scroll.contentView.bounds.width / 2,
                                y: max(0, document.y - roll.scroll.contentView.bounds.height / 2)))
        XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
        XCTAssertTrue(roll.scroll.contentView.bounds.contains(document))
        let expected = quiet.characterIndexForInsertion(at: local)
        XCTAssertGreaterThan(expected, 0)
        let windowPoint = quiet.convert(local, to: nil)
        XCTAssertEqual(quiet.convert(windowPoint, from: nil).x, local.x, accuracy: 0.5)
        quiet.mouseDown(with: try leftClick(in: roll.window, at: windowPoint))
        XCTAssertEqual(model.selectedPageID, inactive)
        roll.stack.update(projection: spreadOverDays(model, selecting: inactive),
                          selectedPage: inactive, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertEqual(roll.coordinator.currentSheet, inactive)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: expected, length: 0))
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
    }

    func testHeadersAndEmptyTodayControlsStayViewportPinnedDuringHorizontalScroll() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine())
        let preview = try page(in: model, saying: "# Preview\nread this day")
        model.toggleMarkdownPreview(for: preview)
        try select(selected, in: model)
        let projection = TimeUnitProjection.project(
            tabs: filed(model, under: [-1, -2]), selectedPageID: selected, unit: .day)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let headers = roll.stack.laidOut.map(\.header)
        let fields = headers.flatMap { $0.subviews.compactMap { $0 as? NSTextField } }
            .filter { !$0.isHidden }
        let buttons = headers.flatMap { $0.subviews.compactMap { $0 as? NSButton } }
            .filter { !$0.isHidden }
        XCTAssertFalse(fields.isEmpty)
        XCTAssertFalse(buttons.isEmpty)
        let empty = try XCTUnwrap(roll.stack.laidOut.first { $0.body is EmptyTodayView }?.body as? EmptyTodayView)
        let renderedPreview = try XCTUnwrap(roll.stack.previewRegions[preview])
        let pinned: [NSView] = headers + fields + buttons + [empty, renderedPreview] + empty.subviews
        let before = pinned.map { $0.convert($0.bounds, to: roll.scroll.contentView) }
        let y = roll.scroll.contentView.bounds.minY
        scroll(roll, to: NSPoint(x: roll.scroll.contentView.bounds.width / 2, y: y))
        XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
        for (view, old) in zip(pinned, before) {
            let now = view.convert(view.bounds, to: roll.scroll.contentView)
            XCTAssertEqual(now.minX - roll.scroll.contentView.bounds.minX, old.minX, accuracy: 0.5)
            XCTAssertEqual(now.width, old.width, accuracy: 0.5)
            XCTAssertEqual(now.minY, old.minY, accuracy: 0.5)
        }
        for header in headers {
            XCTAssertEqual(header.frame.width, roll.scroll.contentView.bounds.width, accuracy: 0.5)
        }
    }

    func testPreviewsKeepTheViewportMeasureWhenSourceWidensTheRoll() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: longLine())
        let preview = try page(in: model, saying: "# Preview\n" + longLine(repetitions: 20))
        model.toggleMarkdownPreview(for: preview)
        try select(selected, in: model)
        let projection = TimeUnitProjection.project(
            tabs: filed(model, under: [-1, -2]), selectedPageID: selected, unit: .day)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let rendered = try XCTUnwrap(roll.stack.previewRegions[preview])
        let wrapped = (frame: rendered.frame, lines: try textMetrics(rendered).lines)

        model.wrapsLines = false
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)

        let clip = roll.scroll.contentView.bounds
        XCTAssertGreaterThan(roll.stack.frame.width, clip.width, "the case needs source wider than the viewport")
        XCTAssertEqual(rendered.frame.width, clip.width, accuracy: 0.5)
        XCTAssertEqual(rendered.frame.height, wrapped.frame.height, accuracy: 0.5)
        XCTAssertEqual(try textMetrics(rendered).lines, wrapped.lines)
    }

    func testWrapAndResizeKeepTheLogicalReadingAnchorInAnOlderDay() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine(repetitions: 30))
        let paragraph = longLine(repetitions: 12)
        let older = try page(in: model, saying: Array(repeating: paragraph, count: 40).joined(separator: "\n"))
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[older])
        let index = (paragraph.utf16.count + 1) * 8
        let glyph = try glyphRect(in: quiet, at: index)
        scroll(roll, to: NSPoint(x: roll.scroll.contentView.bounds.width / 2,
                                y: quiet.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, older)
        XCTAssertEqual(place.anchor.characterIndex, index)
        let editor = try XCTUnwrap(roll.stack.editor)
        let selection = editor.selectedRange()
        for (wraps, width) in [(true, CGFloat(420)), (true, 580), (false, 580), (false, 340), (true, 340)] {
            model.wrapsLines = wraps
            roll.scroll.frame.size.width = width
            roll.scroll.layoutSubtreeIfNeeded()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            let offset = try XCTUnwrap(place.anchor.offset(in: quiet))
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, quiet.frame.minY + offset.y, accuracy: 1)
            XCTAssertEqual(roll.stack.currentPlace?.page, older)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(roll.stack.quietRegions[older] === quiet)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(model.selectedPageID, selected)
            if wraps { XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0, accuracy: 0.5) }
        }
    }

    func testInactiveContentChangesAboveTheReaderKeepTheLogicalPlace() throws {
        for wraps in [false, true] {
            let model = try makeModel()
            model.wrapsLines = wraps
            let above = try page(in: model, saying: longPage(lines: 60))
            let selected = try page(in: model, saying: longPage(lines: 80))
            let roll = try mountRoll(model: model)
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = editor.textStorage
            let index = (editor.string as NSString).range(of: "line 20 ").location
            let glyph = try glyphRect(in: editor, at: index)
            scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
            let place = try XCTUnwrap(roll.stack.currentPlace)
            XCTAssertEqual(place.page, selected)
            XCTAssertEqual(place.anchor.characterIndex, index)
            let selection = editor.selectedRange()
            for lines in [10, 90, 5] {
                let replacement = longPage(lines: lines).replacingOccurrences(of: "\n", with: "\\n")
                XCTAssertTrue(model.coreClient.syncDocument(sheet: above, json: "[{\"ink\":\"\(replacement)\"}]"))
                model.invalidateQuietRendering(for: above)
                model.refresh()
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                let offset = try XCTUnwrap(place.anchor.offset(in: editor))
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, editor.frame.minY + offset.y, accuracy: 0.5)
                XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertTrue(roll.stack.editor === editor)
                XCTAssertTrue(editor.textStorage === storage)
            }
        }
    }

    /// A switch that hands the keys to the editor must not let a scroll the hand off makes
    /// stand in for the reader's own (#278, point 1).
    func testAPageSwitchHandingTheKeysToAnOffscreenCaretKeepsTheReadingPlace() throws {
        let model = try makeModel()
        let top = try page(in: model, saying: longPage(lines: 60))
        let previewed = try page(in: model, saying: "# Preview\n" + longPage(lines: 40))
        let next = try page(in: model, saying: longPage(lines: 80))
        model.toggleMarkdownPreview(for: previewed)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: spreadOverDays(model, selecting: next), selectedPage: next, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let end = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: end, length: 0))
        roll.stack.update(
            projection: spreadOverDays(model, selecting: previewed), selectedPage: previewed, readOnly: false)
        let preview = try XCTUnwrap(roll.stack.previewRegions[previewed])
        XCTAssertTrue(roll.window.makeFirstResponder(preview))
        XCTAssertTrue(editor.isHidden)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[top])
        let index = (quiet.string as NSString).range(of: "line 20 ").location
        XCTAssertNotEqual(index, NSNotFound)
        let glyph = try glyphRect(in: quiet, at: index)
        scroll(roll, to: NSPoint(x: 0, y: quiet.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, top)
        XCTAssertEqual(place.anchor.characterIndex, index)
        let top0 = roll.scroll.contentView.bounds.minY
        // The anchor's glyph, where it stands inside the clip: the invariant, whatever the
        // rows above it do across the switch.
        func glyphInClip() throws -> CGFloat {
            quiet.frame.minY + (try glyphRect(in: quiet, at: index)).minY - roll.scroll.contentView.bounds.minY
        }
        let glyphBefore = try glyphInClip()
        let nextRegion = try XCTUnwrap(roll.stack.quietRegions[next])
        XCTAssertGreaterThan(
            nextRegion.frame.minY, roll.scroll.contentView.bounds.maxY,
            "the case needs the caret's page below the viewport")

        roll.stack.update(projection: spreadOverDays(model, selecting: next), selectedPage: next, readOnly: false)

        XCTAssertTrue(roll.window.firstResponder === editor, "the keys did not pass to the editor")
        XCTAssertEqual(roll.coordinator.currentSheet, next)
        XCTAssertEqual(editor.selectedRange().location, end, "the caret was not put back at the page's end")
        XCTAssertGreaterThan(editor.frame.minY, top0 + roll.scroll.contentView.bounds.height)
        XCTAssertEqual(roll.stack.currentPlace?.page, top)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index)
        XCTAssertTrue(roll.stack.quietRegions[top] === quiet)
        XCTAssertEqual(try glyphInClip(), glyphBefore, accuracy: 0.5, "the anchor's line moved in the clip")
    }

    /// A peer's applied edit restates a quiet page and merges into the page a surface shows, one
    /// stretch at a time, so a selection outside the stretches follows the text and the next
    /// keystroke is read from the merged text (#276); the model's own view of what is mounted
    /// answers which is which (#278, point 4).
    func testAPeersEditRestatesAQuietPageAndMergesIntoTheMountedOne() throws {
        let model = try makeModel()
        let quiet = try page(in: model, saying: "quiet before")
        let mounted = try page(in: model, saying: "alpha beta gamma")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertTrue(storage === model.storage(for: mounted))
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        // The quiet page's storage, minted before the peer's edit so the settle has one to restate,
        // under a manager with no text view, as a torn down editor leaves behind.
        let stale = model.storage(for: quiet)
        let stray = NSLayoutManager()
        stale.addLayoutManager(stray)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: quiet, json: "[{\"ink\":\"quiet after\"}]"))
        XCTAssertEqual(stale.string, "quiet before", "the case needs a stale storage to restate")
        // The peer wrote at both ends of the mounted page, in the core alone.
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 16, text: " delta"), .ins(at: 0, text: "zero ")]))
        XCTAssertTrue(model.coreClient.applyOps(sheet: mounted, json: ops))
        let coreText = {
            model.coreClient.documentRuns(sheet: mounted).reduce(into: "") {
                if case .ink(let ink) = $1 { $0 += ink }
            }
        }
        XCTAssertEqual(coreText(), "zero alpha beta gamma delta")
        XCTAssertEqual(editor.string, "alpha beta gamma", "the case needs the storage behind the core")

        model.settleRemoteEdits(on: [quiet, mounted])
        stale.removeLayoutManager(stray)

        XCTAssertEqual(stale.string, "quiet after", "a stray manager kept the page stale")
        XCTAssertTrue(model.storage(for: quiet) === stale)
        XCTAssertEqual(editor.string, "zero alpha beta gamma delta")
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 11, length: 4),
            "the selection did not follow the peer's text above it")
        editor.insertText("!", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "zero alpha ! gamma delta")
        XCTAssertEqual(coreText(), editor.string, "the keystroke after the merge was read from stale text")
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        XCTAssertEqual(roll.stack.quietRegions[quiet]?.string, "quiet after")
    }

    /// A peer's edit around a sealed object keeps the object's attachment, and a wholesale
    /// rewrite past the diff's limit still ends on the core's text (#276).
    func testAPeersEditAroundASealedObjectKeepsTheObjectAndAWholesaleRewriteEndsOnTheCoresText() throws {
        let model = try makeModel()
        let mounted = try page(in: model, saying: "before secret after")
        XCTAssertNotNil(model.coreClient.sealText(sheet: mounted, "secret", at: 7, length: 6))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(editor.string, "before \u{FFFC} after")
        let chip = try XCTUnwrap(storage.attribute(.attachment, at: 7, effectiveRange: nil) as? ChipAttachment)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 14, text: "wards"), .del(at: 0, len: 2)]))
        XCTAssertTrue(model.coreClient.applyOps(sheet: mounted, json: ops))

        model.settleRemoteEdits(on: [mounted])

        XCTAssertEqual(editor.string, "fore \u{FFFC} afterwards")
        XCTAssertTrue(
            storage.attribute(.attachment, at: 5, effectiveRange: nil) as? ChipAttachment === chip,
            "the object's attachment was rebuilt under the editor")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0))

        let rewrite = String(repeating: "a page rewritten whole by a peer\n", count: 200)
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: mounted, json: "[{\"ink\":\"\(rewrite.replacingOccurrences(of: "\n", with: "\\n"))\"}]"))
        model.settleRemoteEdits(on: [mounted])
        XCTAssertEqual(editor.string, rewrite)
        XCTAssertTrue(editor.textStorage === storage)
    }

    /// A face the core changed under the mounted page, as a peer's batch moving a value here
    /// changes one (ADR-0058 point 3), is stood in on the attachment the block already has.
    func testAPeersSettleRestatesAChangedFaceOnTheMountedPage() throws {
        let model = try makeModel()
        let mounted = try page(in: model, saying: "before secret after")
        let sealed = try XCTUnwrap(
            model.coreClient.sealText(sheet: mounted, "secret", at: 7, length: 6))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let chip = try XCTUnwrap(storage.attribute(.attachment, at: 7, effectiveRange: nil) as? ChipAttachment)
        XCTAssertNil(chip.info.name)
        XCTAssertTrue(model.coreClient.setChipName("PEER_KEY", chip: sealed.chipId))

        model.settleRemoteEdits(on: [mounted])

        XCTAssertTrue(
            storage.attribute(.attachment, at: 7, effectiveRange: nil) as? ChipAttachment === chip,
            "the object's attachment was rebuilt under the editor")
        XCTAssertEqual(chip.info.name, "PEER_KEY", "the block still draws the face it was built with")
        XCTAssertEqual(editor.string, "before \u{FFFC} after")
    }

    /// A peer's edit arriving mid composition drops the composition, provisional text and all,
    /// since the input method's text is not the core's and its commit would be read against a
    /// storage the merge moves; the merge then runs, and the next keystroke is ordinary (#276).
    func testAPeersEditDuringACompositionDropsTheCompositionAndMerges() throws {
        let model = try makeModel()
        let mounted = try page(in: model, saying: "alpha beta")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        editor.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "alpha ka", "the case needs a composition over a selection")
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 10, text: " gamma")]))
        XCTAssertTrue(model.coreClient.applyOps(sheet: mounted, json: ops))

        model.settleRemoteEdits(on: [mounted])

        XCTAssertFalse(editor.hasMarkedText(), "the composition stood through the merge")
        XCTAssertEqual(editor.string, "alpha beta gamma")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 4), "the selection the composition replaced is back")
        XCTAssertNil(PageModel.parityBreach(
            editor: InkEditorView.Coordinator.runs(of: storage),
            core: model.coreClient.documentRuns(sheet: mounted)))
        editor.insertText("\u{304B}", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "alpha \u{304B} gamma")
        XCTAssertNil(PageModel.parityBreach(
            editor: InkEditorView.Coordinator.runs(of: storage),
            core: model.coreClient.documentRuns(sheet: mounted)))
    }

    /// A settle that finds nothing changed leaves a composition standing, and a composition
    /// over a selection holding a sealed object gives the object back when it is dropped (#276).
    func testACompositionStandsThroughAnEchoAndGivesBackTheObjectItReplaced() throws {
        let model = try makeModel()
        let mounted = try page(in: model, saying: "before secret after")
        XCTAssertNotNil(model.coreClient.sealText(sheet: mounted, "secret", at: 7, length: 6))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let chip = try XCTUnwrap(storage.attribute(.attachment, at: 7, effectiveRange: nil) as? ChipAttachment)
        editor.setSelectedRange(NSRange(location: 7, length: 1))
        editor.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "before ka after", "the case needs a composition over the object")

        model.settleRemoteEdits(on: [mounted])

        XCTAssertTrue(editor.hasMarkedText(), "a settle with nothing new dropped the composition")
        XCTAssertEqual(editor.string, "before ka after")

        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 14, text: "wards")]))
        XCTAssertTrue(model.coreClient.applyOps(sheet: mounted, json: ops))
        model.settleRemoteEdits(on: [mounted])

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "before \u{FFFC} afterwards")
        XCTAssertTrue(
            storage.attribute(.attachment, at: 7, effectiveRange: nil) as? ChipAttachment === chip,
            "the object the composition replaced did not come back as itself")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 1))
        XCTAssertNil(PageModel.parityBreach(
            editor: InkEditorView.Coordinator.runs(of: storage),
            core: model.coreClient.documentRuns(sheet: mounted)))
    }

    /// A peer's edit that changes one emoji for another replaces the whole pair, never one of
    /// its halves, and a settle that finds the page current touches the storage not at all (#276).
    func testAPeersEditInsideASurrogatePairReplacesTheWholePairAndAnEchoTouchesNothing() throws {
        let model = try makeModel()
        let mounted = try page(in: model, saying: "a 😀 b")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.del(at: 2, len: 2), .ins(at: 2, text: "😁")]))
        XCTAssertTrue(model.coreClient.applyOps(sheet: mounted, json: ops))
        final class Watch: @unchecked Sendable {
            var edits = 0
            var halves = 0
        }
        let watch = Watch()
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { notification in
            watch.edits += 1
            if let edited = notification.object as? NSTextStorage, Self.holdsHalfAPair(edited.string) {
                watch.halves += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.settleRemoteEdits(on: [mounted])

        XCTAssertEqual(editor.string, "a 😁 b")
        XCTAssertEqual(watch.halves, 0, "an edit left half a surrogate pair standing")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 1))
        XCTAssertNil(PageModel.parityBreach(
            editor: InkEditorView.Coordinator.runs(of: storage),
            core: model.coreClient.documentRuns(sheet: mounted)))

        let edits = watch.edits
        model.settleRemoteEdits(on: [mounted])
        XCTAssertEqual(watch.edits, edits, "a settle with nothing new edited the storage")
    }

    private static func holdsHalfAPair(_ text: String) -> Bool {
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated() {
            if UTF16.isLeadSurrogate(unit), index + 1 >= units.count || !UTF16.isTrailSurrogate(units[index + 1]) {
                return true
            }
            if UTF16.isTrailSurrogate(unit), index == 0 || !UTF16.isLeadSurrogate(units[index - 1]) {
                return true
            }
        }
        return false
    }

    /// A rewrite of a few stretches keeps a selection on the words between them; one of more
    /// stretches than the merge applies singly is replaced whole and ends on the core's text (#276).
    func testAFewStretchesKeepTheWordsBetweenThemAndManyAreReplacedWhole() throws {
        let model = try makeModel()
        let words = (0..<100).map { "x\($0)" }
        let mounted = try page(in: model, saying: words.joined(separator: " "))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: mounted), selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        let island = (editor.string as NSString).range(of: "x50")
        editor.setSelectedRange(island)
        func rewrite(_ changed: Range<Int>) throws {
            let text = words.enumerated().map { changed.contains($0.offset) ? "y\($0.offset)" : $0.element }
                .joined(separator: " ")
            XCTAssertTrue(model.coreClient.syncDocument(sheet: mounted, json: "[{\"ink\":\"\(text)\"}]"))
            model.settleRemoteEdits(on: [mounted])
            XCTAssertEqual(editor.string, text)
            XCTAssertNil(PageModel.parityBreach(
                editor: InkEditorView.Coordinator.runs(of: storage),
                core: model.coreClient.documentRuns(sheet: mounted)))
        }

        try rewrite(10..<20)
        XCTAssertEqual(
            (editor.string as NSString).substring(with: editor.selectedRange()), "x50",
            "a selection between the stretches moved")

        try rewrite(0..<100)
        XCTAssertTrue(editor.textStorage === storage)
    }

    /// A peer's paragraph merged in above the reader on the mounted day keeps the same line at
    /// the top of the clip, as a local paste there does (#276).
    func testAPeersParagraphMergedAboveTheReaderInTheMountedDayKeepsTheSameLineAtTheTop() throws {
        let model = try makeModel()
        model.wrapsLines = true
        _ = try page(in: model, saying: longPage(lines: 10))
        let selected = try page(in: model, saying: longPage(lines: 80))
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let target = "line 40 "
        let index = (editor.string as NSString).range(of: target).location
        let glyph = try glyphRect(in: editor, at: index)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.anchor.characterIndex, index)
        editor.setSelectedRange(NSRange(location: index, length: 0))

        let paragraph = "a paragraph a peer wrote 🧪 above the reader, long enough to wrap at this width\n"
        let above = (editor.string as NSString).range(of: "line 10 ").location
        XCTAssertTrue(model.coreClient.applyOps(
            sheet: selected, json: try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: above, text: paragraph)]))))
        model.settleRemoteEdits(on: [selected])
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

        let moved = (editor.string as NSString).range(of: target).location
        XCTAssertEqual(moved, index + (paragraph as NSString).length)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: moved, length: 0))
        var expected = place.anchor
        expected.characterIndex = moved
        let offset = try XCTUnwrap(expected.offset(in: editor))
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, editor.frame.minY + offset.y, accuracy: 0.5)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, moved)
    }

    func testWrapAndWidthRoundTripsReturnAMidParagraphReaderToTheSameLine() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let selected = try page(in: model, saying: longLine(repetitions: 30))
        let paragraph = longLine(repetitions: 12)
        let older = try page(in: model, saying: Array(repeating: paragraph, count: 40).joined(separator: "\n"))
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        func reflow(wraps: Bool, width: CGFloat) {
            model.wrapsLines = wraps
            roll.scroll.frame.size.width = width
            roll.scroll.layoutSubtreeIfNeeded()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        }
        reflow(wraps: true, width: 420)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[older])
        let paragraphStart = (paragraph.utf16.count + 1) * 8
        let glyph = try glyphRect(in: quiet, at: paragraphStart + paragraph.utf16.count / 2)
        scroll(roll, to: NSPoint(x: 0, y: quiet.frame.minY + glyph.minY + glyph.height / 4))
        let start = try XCTUnwrap(roll.stack.currentPlace)
        let top = roll.scroll.contentView.bounds.minY
        XCTAssertEqual(start.page, older)
        XCTAssertGreaterThan(start.anchor.characterIndex, paragraphStart, "the case needs a continuation line")
        XCTAssertLessThan(start.anchor.characterIndex, paragraphStart + paragraph.utf16.count)
        for away in [(wraps: false, width: CGFloat(420)), (wraps: true, width: 580)] {
            for _ in 0..<2 {
                reflow(wraps: away.wraps, width: away.width)
                XCTAssertEqual(roll.stack.currentPlace?.page, older)
                reflow(wraps: true, width: 420)
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, top, accuracy: 0.5)
                XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, start.anchor.characterIndex)
                XCTAssertTrue(roll.stack.quietRegions[older] === quiet)
            }
        }
    }

    /// A place another window left can name a character inside a line, and the restore's own
    /// scroll must not swap it for that line's first character before the next width change.
    func testAPlaceOpenedFromAnotherWindowKeepsItsCharacterThroughAWidthChange() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let selected = try page(in: model, saying: longLine(repetitions: 30))
        let paragraph = longLine(repetitions: 12)
        let older = try page(in: model, saying: Array(repeating: paragraph, count: 40).joined(separator: "\n"))
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        func reflow(width: CGFloat) {
            roll.scroll.frame.size.width = width
            roll.scroll.layoutSubtreeIfNeeded()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        }
        reflow(width: 420)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[older])
        let manager = try XCTUnwrap(quiet.layoutManager)
        let container = try XCTUnwrap(quiet.textContainer)
        func lines() -> [NSRange] {
            manager.ensureLayout(for: container)
            var lines: [NSRange] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                lines.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            return lines
        }
        func topLine() -> NSRange {
            let y = roll.scroll.contentView.bounds.minY - quiet.frame.minY - quiet.textContainerOrigin.y
            var glyphs = NSRange(location: 0, length: 0)
            manager.lineFragmentRect(
                forGlyphAt: manager.glyphIndex(for: NSPoint(x: 0, y: y + 0.5), in: container),
                effectiveRange: &glyphs)
            return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        let paragraphStart = (paragraph.utf16.count + 1) * 8
        let paragraphEnd = paragraphStart + paragraph.utf16.count
        reflow(width: 580)
        let wide = lines()
        reflow(width: 420)
        // A line at this width whose first and last characters part company at the wider one.
        let line = try XCTUnwrap(lines().first { line in
            guard line.location > paragraphStart, NSMaxRange(line) < paragraphEnd else { return false }
            return wide.firstIndex { NSLocationInRange(line.location, $0) }
                != wide.firstIndex { NSLocationInRange(NSMaxRange(line) - 2, $0) }
        })
        let character = NSMaxRange(line) - 2

        roll.stack.open(at: RollPlace(
            page: older, anchor: ScrollAnchor(characterIndex: character), length: (quiet.string as NSString).length))
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertTrue(NSLocationInRange(character, topLine()), "\(character) is not in \(topLine())")
        reflow(width: 580)
        XCTAssertTrue(NSLocationInRange(character, topLine()), "\(character) is not in \(topLine())")
    }

    func testSyncedTextAroundTheReaderInTheirOwnQuietPageKeepsTheSameLineAtTheTop() throws {
        for wraps in [false, true] {
            let model = try makeModel()
            model.wrapsLines = wraps
            let selected = try page(in: model, saying: longPage(lines: 10))
            let reading = try page(in: model, saying: longPage(lines: 80))
            try select(selected, in: model)
            let roll = try mountRoll(model: model)
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let quiet = try XCTUnwrap(roll.stack.quietRegions[reading])
            let target = "line 40 "
            let index = (quiet.string as NSString).range(of: target).location
            let glyph = try glyphRect(in: quiet, at: index)
            scroll(roll, to: NSPoint(x: 0, y: quiet.frame.minY + glyph.minY + glyph.height / 4))
            let place = try XCTUnwrap(roll.stack.currentPlace)
            XCTAssertEqual(place.page, reading)
            XCTAssertEqual(place.anchor.characterIndex, index)
            let synced = { (count: Int) in (0..<count).map { "synced \($0) from elsewhere\n" }.joined() }
            let lines = longPage(lines: 80).components(separatedBy: "\n")
            for ink in [
                synced(10) + longPage(lines: 80) + "\n" + synced(10),
                synced(10) + longPage(lines: 80),
                synced(30) + longPage(lines: 80),
                lines.dropFirst(25).joined(separator: "\n"),
                lines.dropFirst(25).joined(separator: "\n") + "\n" + synced(20),
                lines.dropFirst(30).dropLast(10).joined(separator: "\n"),
            ] {
                let escaped = ink.replacingOccurrences(of: "\n", with: "\\n")
                XCTAssertTrue(model.coreClient.syncDocument(sheet: reading, json: "[{\"ink\":\"\(escaped)\"}]"))
                model.invalidateQuietRendering(for: reading)
                model.refresh()
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                XCTAssertTrue(roll.stack.quietRegions[reading] === quiet)
                XCTAssertEqual(quiet.string, ink)
                let moved = (ink as NSString).range(of: target).location
                var expected = place.anchor
                expected.characterIndex = moved
                let offset = try XCTUnwrap(expected.offset(in: quiet))
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, quiet.frame.minY + offset.y, accuracy: 0.5)
                XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, moved)
            }
        }
    }

    func testScrollingDuringDeferredPreviewKeepsReadingPositionAndHonorsNavigation() async throws {
        let model = try makeModel()
        model.wrapsLines = true
        let source = (0..<1_200).map { "line \($0) **at a distinct reading position**" }.joined(separator: "\n\n")
        let reading = try page(in: model, saying: source)
        let other = try page(in: model, saying: longPage(lines: 80))
        try select(reading, in: model)
        model.toggleMarkdownPreview(for: reading)
        let projection = TimeUnitProjection.project(
            tabs: model.tabs.map { onDay($0, $0.pageID == reading ? 0 : -1) },
            selectedPageID: reading, unit: .day)
        let roll = try mountRoll(model: model)
        roll.window.isReleasedWhenClosed = false
        defer { roll.window.close() }
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let preview = try XCTUnwrap(roll.stack.previewRegions[reading])
        try await XCTUnwrap(preview.renderingTask).value
        let target = "line 600 "
        let index = (preview.string as NSString).range(of: target).location
        XCTAssertNotEqual(index, NSNotFound)
        let glyph = try glyphRect(in: preview, at: index)
        scroll(roll, to: NSPoint(x: 0, y: preview.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.readingPlace)
        XCTAssertEqual(place.page, reading)
        XCTAssertEqual(place.anchor.characterIndex, index)

        model.syncDocument(sheet: reading, runs: [.ink("new paragraph\n\n" + source)])
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        XCTAssertTrue(preview.isRendering)
        let pending = try XCTUnwrap(preview.renderingTask)
        XCTAssertEqual(roll.stack.readingPlace, place)
        scroll(roll, to: NSPoint(x: 0, y: preview.frame.minY + 3))
        XCTAssertEqual(roll.stack.currentPlace?.page, reading)
        XCTAssertEqual(roll.stack.readingPlace, place)
        await pending.value
        let moved = (preview.string as NSString).range(of: target).location
        XCTAssertEqual(roll.stack.currentPlace?.page, reading)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, moved)

        model.syncDocument(sheet: reading, runs: [.ink("a rail destination\n\n" + source)])
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let railRendering = try XCTUnwrap(preview.renderingTask)
        roll.stack.scroll(toDocumentOffset: preview.frame.minY, animated: false)
        XCTAssertEqual(roll.stack.readingPlace?.anchor.characterIndex, 0)
        await railRendering.value
        XCTAssertEqual(roll.stack.currentPlace?.page, reading)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, 0)

        model.syncDocument(sheet: reading, runs: [.ink("another paragraph\n\n" + source)])
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let next = try XCTUnwrap(preview.renderingTask)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[other])
        let otherIndex = (quiet.string as NSString).range(of: "line 40 ").location
        let otherGlyph = try glyphRect(in: quiet, at: otherIndex)
        scroll(roll, to: NSPoint(x: 0, y: quiet.frame.minY + otherGlyph.minY + otherGlyph.height / 4))
        let otherPlace = try XCTUnwrap(roll.stack.readingPlace)
        XCTAssertEqual(otherPlace.page, other)
        XCTAssertEqual(otherPlace.anchor.characterIndex, otherIndex)
        await next.value
        XCTAssertEqual(roll.stack.currentPlace?.page, other)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, otherIndex)

        model.toggleMarkdownPreview(for: reading)
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let sourceIndex = (editor.string as NSString).range(of: target).location
        let sourceGlyph = try glyphRect(in: editor, at: sourceIndex)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + sourceGlyph.minY + sourceGlyph.height / 4))
        let sourcePlace = try XCTUnwrap(roll.stack.readingPlace)
        XCTAssertEqual(sourcePlace.reading, .source)
        model.toggleMarkdownPreview(for: reading)
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let returningPreview = try XCTUnwrap(roll.stack.previewRegions[reading])
        let returning = try XCTUnwrap(returningPreview.renderingTask)
        scroll(roll, to: NSPoint(x: 0, y: returningPreview.frame.minY + 3))
        XCTAssertEqual(roll.stack.readingPlace, sourcePlace)
        await returning.value
        let expected = try XCTUnwrap(sourcePlace.mappedAnchor(into: .preview, text: returningPreview.string)
            .offset(in: returningPreview))
        XCTAssertEqual(roll.stack.currentPlace?.page, reading)
        XCTAssertEqual(roll.stack.currentPlace?.reading, .preview)
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, returningPreview.frame.minY + expected.y, accuracy: 0.5)
    }

    func testScrollingALoadingPreviewUpdatesItsOriginMarkerWithoutReplacingItsTextAnchor() async throws {
        for moveOffTop in [false, true] {
            let model = try makeModel()
            model.pads.isEnabled = true
            let source = String(repeating: "## Heading **bold**\n\n", count: 900)
            let reading = try page(in: model, saying: source)
            _ = try page(in: model, saying: longPage(lines: 80))
            try select(reading, in: model)
            model.toggleMarkdownPreview(for: reading)
            let projection = TimeUnitProjection.project(
                tabs: model.tabs.map { onDay($0, $0.pageID == reading ? 0 : -1) },
                selectedPageID: reading, unit: .day)
            let roll = try mountRoll(model: model)
            roll.window.isReleasedWhenClosed = false
            defer { roll.window.close() }
            roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
            let preview = try XCTUnwrap(roll.stack.previewRegions[reading])
            try await XCTUnwrap(preview.renderingTask).value
            scroll(roll, to: NSPoint(x: 0, y: 1))
            scroll(roll, to: .zero)
            let place = try XCTUnwrap(roll.stack.readingPlace)
            XCTAssertTrue(place.atTop)
            let previous = preview.string
            let prefix = (0..<20).map { "new paragraph \($0)" }.joined(separator: "\n\n") + "\n\n"
            model.syncDocument(sheet: reading, runs: [.ink(prefix + source)])
            roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
            let pending = try XCTUnwrap(preview.renderingTask)
            if moveOffTop { scroll(roll, to: NSPoint(x: 0, y: preview.frame.minY + 3)) }
            XCTAssertEqual(roll.stack.readingPlace?.atTop, !moveOffTop)
            XCTAssertEqual(roll.stack.readingPlace?.anchor, place.anchor)
            await pending.value
            if moveOffTop {
                let rebased = place.rebased(from: previous, to: preview.string)
                let offset = try XCTUnwrap(rebased.anchor.offset(in: preview))
                let expected = preview.frame.minY + offset.y
                XCTAssertGreaterThan(expected, 0)
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, expected, accuracy: 0.5)
            } else {
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, 0, accuracy: 0.5)
            }
        }
    }

    func testLoadingPreviewsCaptureHorizontalMovementAndKeepItThroughLayoutClamps() async throws {
        for hasSavedPlace in [false, true] {
            let model = try makeModel()
            model.wrapsLines = false
            let source = String(repeating: "## Heading **bold**\n\n", count: 900)
            let reading = try page(in: model, saying: source)
            _ = try page(in: model, saying: longLine())
            try select(reading, in: model)
            model.toggleMarkdownPreview(for: reading)
            let projection = TimeUnitProjection.project(
                tabs: model.tabs.map { onDay($0, $0.pageID == reading ? 0 : -1) },
                selectedPageID: reading, unit: .day)
            let roll = try mountRoll(model: model)
            roll.window.isReleasedWhenClosed = false
            defer { roll.window.close() }
            roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
            let preview = try XCTUnwrap(roll.stack.previewRegions[reading])
            var pending = try XCTUnwrap(preview.renderingTask)
            if hasSavedPlace {
                await pending.value
                scroll(roll, to: NSPoint(x: 120, y: 0))
                XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 120)
                model.syncDocument(sheet: reading, runs: [.ink("new paragraph\n\n" + source)])
                roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
                pending = try XCTUnwrap(preview.renderingTask)
            } else {
                XCTAssertNil(roll.stack.readingPlace)
                roll.scroll.contentView.postsBoundsChangedNotifications = false
                scroll(roll, to: NSPoint(x: 120, y: 0))
                XCTAssertEqual(roll.stack.currentPlace?.anchor.x, 120)
                roll.scroll.contentView.postsBoundsChangedNotifications = true
            }
            XCTAssertTrue(preview.isRendering)
            scroll(roll, to: NSPoint(x: 240, y: 0))
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, 240)
            XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 240)
            model.wrapsLines = true
            roll.stack.relayout()
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0)
            XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 240)
            model.wrapsLines = false
            roll.stack.relayout()
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, 240)
            await pending.value
            XCTAssertEqual(roll.stack.currentPlace?.anchor.x, 240)
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, 240)
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, 0)
        }
    }

    func testAnAnimatedZeroDistanceJumpKeepsTheLoadingPreviewPlaceThroughLayoutClamps() async throws {
        guard StreamNavigator.jumpDuration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) > 0
        else { throw XCTSkip("Animated jump requires motion to be enabled") }
        let model = try makeModel()
        model.wrapsLines = false
        let source = String(repeating: "## Heading **bold**\n\n", count: 900)
        let reading = try page(in: model, saying: source)
        _ = try page(in: model, saying: longLine())
        try select(reading, in: model)
        model.toggleMarkdownPreview(for: reading)
        let projection = TimeUnitProjection.project(
            tabs: model.tabs.map { onDay($0, $0.pageID == reading ? 0 : -1) },
            selectedPageID: reading, unit: .day)
        let roll = try mountRoll(model: model, ordered: true)
        defer { roll.window.close() }
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let preview = try XCTUnwrap(roll.stack.previewRegions[reading])
        try await XCTUnwrap(preview.renderingTask).value
        scroll(roll, to: NSPoint(x: 240, y: 0))
        model.syncDocument(sheet: reading, runs: [.ink("new paragraph\n\n" + source)])
        roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
        let pending = try XCTUnwrap(preview.renderingTask)
        XCTAssertTrue(roll.window.isVisible)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin, NSPoint(x: 240, y: 0))
        roll.stack.scroll(toDocumentOffset: 0, animated: true)
        XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 240)
        XCTAssertEqual(roll.stack.readingPlace?.atTop, true)
        model.wrapsLines = true
        roll.stack.relayout()
        XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0)
        XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 240)
        model.wrapsLines = false
        roll.stack.relayout()
        XCTAssertEqual(roll.scroll.contentView.bounds.minX, 240)
        await pending.value
        XCTAssertEqual(roll.scroll.contentView.bounds.origin, NSPoint(x: 240, y: 0))
        XCTAssertEqual(roll.stack.currentPlace?.anchor.x, 240)
    }

    func testCrossAxisScrollingDoesNotOverwriteALoadingPreviewsCollapsedAxis() async throws {
        for (collapseHeight, returnToOrigin) in [(true, false), (false, false), (true, true), (false, true)] {
            let model = try makeModel()
            model.wrapsLines = false
            let source = (0..<1_200).map { "line \($0) **at a distinct reading position**" }.joined(separator: "\n\n")
            let reading = try page(in: model, saying: source)
            let following = longLine() + (collapseHeight ? "" : "\n" + longPage(lines: 80))
            _ = try page(in: model, saying: following)
            try select(reading, in: model)
            model.toggleMarkdownPreview(for: reading)
            let projection = TimeUnitProjection.project(
                tabs: model.tabs.map { onDay($0, $0.pageID == reading ? 0 : -1) },
                selectedPageID: reading, unit: .day)
            let roll = try mountRoll(model: model)
            roll.window.isReleasedWhenClosed = false
            defer { roll.window.close() }
            roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
            let preview = try XCTUnwrap(roll.stack.previewRegions[reading])
            try await XCTUnwrap(preview.renderingTask).value
            let target = "line 600 "
            let index = (preview.string as NSString).range(of: target).location
            let glyph = try glyphRect(in: preview, at: index)
            scroll(roll, to: NSPoint(x: collapseHeight ? 0 : 240,
                                    y: preview.frame.minY + glyph.minY + glyph.height / 4))
            let place = try XCTUnwrap(roll.stack.readingPlace)
            XCTAssertEqual(place.anchor.characterIndex, index)
            XCTAssertFalse(place.atTop)

            model.syncDocument(sheet: reading, runs: [.ink("new paragraph\n\n" + source)])
            if !collapseHeight { model.wrapsLines = true }
            roll.stack.update(projection: projection, selectedPage: reading, readOnly: false)
            let pending = try XCTUnwrap(preview.renderingTask)
            let clip = roll.scroll.contentView
            if collapseHeight {
                XCTAssertEqual(roll.stack.frame.height, clip.bounds.height, accuracy: 0.5)
                XCTAssertEqual(clip.bounds.minY, 0)
                scroll(roll, to: NSPoint(x: 240, y: 0))
                XCTAssertEqual(clip.bounds.minX, 240)
            } else {
                XCTAssertEqual(roll.stack.frame.width, clip.bounds.width, accuracy: 0.5)
                XCTAssertEqual(clip.bounds.minX, 0)
                let before = clip.bounds.minY
                scroll(roll, to: NSPoint(x: 0, y: preview.frame.minY + 3))
                XCTAssertNotEqual(clip.bounds.minY, before)
            }
            XCTAssertEqual(roll.stack.readingPlace?.anchor.characterIndex, index)
            XCTAssertEqual(roll.stack.readingPlace?.anchor.x, 240)
            XCTAssertEqual(roll.stack.readingPlace?.atTop, false)
            if returnToOrigin { scroll(roll, to: .zero) }
            let expectedX: CGFloat = returnToOrigin && collapseHeight ? 0 : 240
            let expectedAtTop = returnToOrigin && !collapseHeight
            XCTAssertEqual(roll.stack.readingPlace?.anchor.characterIndex, index)
            XCTAssertEqual(roll.stack.readingPlace?.anchor.x, expectedX)
            XCTAssertEqual(roll.stack.readingPlace?.atTop, expectedAtTop)
            model.wrapsLines = false
            roll.stack.relayout()
            await pending.value
            let moved = (preview.string as NSString).range(of: target).location
            XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, expectedAtTop ? 0 : moved)
            XCTAssertEqual(clip.bounds.minX, expectedX)
            if expectedAtTop { XCTAssertEqual(clip.bounds.minY, 0) }
            else { XCTAssertGreaterThan(clip.bounds.minY, 0) }
        }
    }

    /// The pump's own report is the only invalidation here, as it is when a peer writes.
    func testAPeersEditReachesAQuietDayAndThePageTheEditorLeft() throws {
        let model = try makeModel()
        let left = try page(in: model, saying: "before the peer")
        let selected = try page(in: model, saying: longPage(lines: 10))
        try select(left, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: left, readOnly: false)
        try select(selected, in: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[left])
        XCTAssertEqual(quiet.string, "before the peer")
        XCTAssertTrue(model.storage(for: left).layoutManagers.isEmpty, "the editor must have left the page")

        XCTAssertTrue(model.coreClient.syncDocument(sheet: left, json: "[{\"ink\":\"after the peer\"}]"))
        model.sync.enabled = true
        let marks = model.dirtyMarks
        model.sync.settlePump(
            SyncPumpOutcome(ok: true, reason: nil, events: [
                SyncPumpEvent(kind: "applied", page: "peer-page", pageID: left),
            ], state: nil),
            session: model.sync.session)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

        XCTAssertTrue(roll.stack.quietRegions[left] === quiet)
        XCTAssertEqual(quiet.string, "after the peer")
        XCTAssertEqual(model.storage(for: left).string, "after the peer", "the editor would come back to old text")
        XCTAssertEqual(model.dirtyMarks, marks + 1, "the peer's edit must arm a write")
    }

    /// The preview drops each link's address, so its text is a fraction of the source's.
    func testTogglingAPreviewUnderTheReaderKeepsThemOnThePageByProportion() throws {
        for readingIsSelected in [false, true] {
            let model = try makeModel()
            model.wrapsLines = true
            let other = try page(in: model, saying: longPage(lines: 10))
            let address = "https://example.com/" + String(repeating: "a/long/path/", count: 4)
            let source = (0..<120).map { "line \($0) [a link](\(address)\($0))" }.joined(separator: "\n\n")
            let reading = try page(in: model, saying: source)
            let selected = readingIsSelected ? reading : other
            try select(selected, in: model)
            let roll = try mountRoll(model: model)
            let clip = roll.scroll.contentView
            func toggle() throws -> NSTextView {
                model.toggleMarkdownPreview(for: reading)
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                return try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == reading }?.body
                    as? NSTextView)
            }
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let text = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == reading }?.body
                as? NSTextView)
            XCTAssertEqual(text === roll.stack.editor, readingIsSelected)
            let sourceLength = (text.string as NSString).length
            let glyph = try glyphRect(in: text, at: (text.string as NSString).range(of: "line 60 ").location)
            scroll(roll, to: NSPoint(x: 0, y: text.frame.minY + glyph.minY + glyph.height / 4))
            let start = try XCTUnwrap(roll.stack.currentPlace)
            let startTop = clip.bounds.minY
            XCTAssertEqual(start.page, reading)

            // The restore puts the line with the proportional character at the top edge,
            // so the tolerance is that one line, read back off the layout.
            func assertTopLine(
                of text: NSTextView, contains index: Int, file: StaticString = #filePath, line: UInt = #line
            ) throws {
                let manager = try XCTUnwrap(text.layoutManager)
                let container = try XCTUnwrap(text.textContainer)
                let y = clip.bounds.minY - text.frame.minY - text.textContainerOrigin.y
                var glyphs = NSRange(location: 0, length: 0)
                manager.lineFragmentRect(
                    forGlyphAt: manager.glyphIndex(for: NSPoint(x: 0, y: y), in: container),
                    effectiveRange: &glyphs)
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                XCTAssertTrue(NSLocationInRange(index, characters), "\(index) is not in \(characters)",
                              file: file, line: line)
                XCTAssertEqual(roll.stack.currentPlace?.page, reading, file: file, line: line)
                XCTAssertLessThan(clip.bounds.minY, roll.stack.frame.height - clip.bounds.height - 1,
                                  "the reader was sent to the bottom", file: file, line: line)
            }
            func proportional(_ index: Int, from length: Int, to target: Int) -> Int {
                Int((Double(index) * Double(target) / Double(length)).rounded())
            }

            var preview = try toggle()
            XCTAssertTrue(preview is MarkdownPreviewView)
            var previewLength = (preview.string as NSString).length
            XCTAssertLessThan(previewLength * 2, sourceLength, "the case needs a preview much shorter than its source")
            try assertTopLine(of: preview, contains: proportional(
                start.anchor.characterIndex, from: sourceLength, to: previewLength))

            let back = try toggle()
            XCTAssertEqual(back === roll.stack.editor, readingIsSelected)
            XCTAssertEqual(back.string, text.string)
            XCTAssertEqual(clip.bounds.minY, startTop, accuracy: 0.5, "an untouched round trip comes back exactly")
            XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, start.anchor.characterIndex)

            preview = try toggle()
            previewLength = (preview.string as NSString).length
            scroll(roll, to: NSPoint(x: 0, y: clip.bounds.minY + 150))
            let read = try XCTUnwrap(roll.stack.currentPlace)
            XCTAssertEqual(read.page, reading)
            let restored = try toggle()
            XCTAssertEqual(restored === roll.stack.editor, readingIsSelected)
            try assertTopLine(of: restored, contains: proportional(
                read.anchor.characterIndex, from: previewLength, to: sourceLength))
        }
    }

    /// A paste or a programmatic insert that scrolls nothing, through the storage alone
    /// and through the view's own change protocol, which lays the roll out at once.
    func testAParagraphInsertedAboveTheReaderInTheMountedDayKeepsTheSameLineAtTheTop() throws {
        for throughTheView in [false, true] {
            let model = try makeModel()
            model.wrapsLines = true
            _ = try page(in: model, saying: longPage(lines: 10))
            let selected = try page(in: model, saying: longPage(lines: 80))
            let roll = try mountRoll(model: model)
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = try XCTUnwrap(editor.textStorage)
            let target = "line 40 "
            let index = (editor.string as NSString).range(of: target).location
            let glyph = try glyphRect(in: editor, at: index)
            scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
            let place = try XCTUnwrap(roll.stack.currentPlace)
            XCTAssertEqual(place.page, selected)
            XCTAssertEqual(place.anchor.characterIndex, index)

            let paragraph = "a paragraph pasted 🧪 above the reader, long enough to wrap at this width\n"
            let above = NSRange(location: (editor.string as NSString).range(of: "line 10 ").location, length: 0)
            if throughTheView {
                XCTAssertTrue(editor.shouldChangeText(in: above, replacementString: paragraph))
                storage.replaceCharacters(in: above, with: paragraph)
                editor.didChangeText()
            } else {
                storage.replaceCharacters(in: above, with: paragraph)
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            }

            let moved = (editor.string as NSString).range(of: target).location
            XCTAssertEqual(moved, index + (paragraph as NSString).length)
            var expected = place.anchor
            expected.characterIndex = moved
            let offset = try XCTUnwrap(expected.offset(in: editor))
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, editor.frame.minY + offset.y, accuracy: 0.5,
                           "through the view: \(throughTheView)")
            XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, moved)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
        }
    }

    /// Return, or a paste of several lines, with the caret on the first character of the line
    /// at the clip's top edge: the caret stays in view, so no reveal moves the clip afterwards.
    func testTextEnteredAtTheTopLinesFirstCharacterStandsAtTheTop() throws {
        for wraps in [true, false] {
            for pasted in [nil, "pasted one\npasted two\npasted three\n"] {
                let model = try makeModel()
                model.wrapsLines = wraps
                _ = try page(in: model, saying: longPage(lines: 10))
                let selected = try page(in: model, saying: longPage(lines: 80))
                let roll = try mountRoll(model: model)
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                let editor = try XCTUnwrap(roll.stack.editor)
                XCTAssertTrue(roll.window.makeFirstResponder(editor))
                func lineTop(at character: Int) throws -> CGFloat {
                    let manager = try XCTUnwrap(editor.layoutManager)
                    manager.ensureLayout(for: try XCTUnwrap(editor.textContainer))
                    let line = manager.lineFragmentRect(
                        forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil)
                    return editor.frame.minY + editor.textContainerOrigin.y + line.minY
                }
                let index = (editor.string as NSString).range(of: "line 40 ").location
                scroll(roll, to: NSPoint(x: 0, y: try lineTop(at: index)))
                let top = roll.scroll.contentView.bounds.minY
                XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index)

                editor.setSelectedRange(NSRange(location: index, length: 0))
                if let pasted {
                    editor.insertText(pasted, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                }
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

                let entered = pasted ?? "\n"
                let label = "wraps \(wraps), \(pasted == nil ? "Return" : "a paste")"
                XCTAssertTrue((editor.string as NSString).substring(from: index).hasPrefix(entered + "line 40 "), label)
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, top, accuracy: 0.5, label)
                XCTAssertEqual(try lineTop(at: index), top, accuracy: 0.5, "the entered text is at the top: \(label)")
                XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index, label)
            }
        }
    }

    /// The roll watches the storage the editor stands on, so the watch moves with the editor.
    func testAnEditAboveTheReaderFollowsTheEditorToTheDayItMovedTo() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let left = try page(in: model, saying: longPage(lines: 30))
        let reading = try page(in: model, saying: longPage(lines: 80))
        try select(left, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: left, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        try select(reading, in: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: reading, readOnly: false)
        XCTAssertTrue(roll.stack.editor === editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertTrue(storage === model.storage(for: reading), "the case needs the editor on the second day")
        let index = (editor.string as NSString).range(of: "line 40 ").location
        let glyph = try glyphRect(in: editor, at: index)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, reading)
        XCTAssertEqual(place.anchor.characterIndex, index)

        let paragraph = "a paragraph written above the reader on the day the editor moved to\n"
        let above = NSRange(location: (editor.string as NSString).range(of: "line 10 ").location, length: 0)
        storage.replaceCharacters(in: above, with: paragraph)
        roll.stack.update(projection: model.timeUnits, selectedPage: reading, readOnly: false)

        let moved = index + (paragraph as NSString).length
        XCTAssertEqual((editor.string as NSString).range(of: "line 40 ").location, moved)
        var expected = place.anchor
        expected.characterIndex = moved
        let offset = try XCTUnwrap(expected.offset(in: editor))
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, editor.frame.minY + offset.y, accuracy: 0.5)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, moved)
    }

    /// The mounted day's edits rebase a place on that day only.
    func testAnEditAboveInTheMountedDayLeavesAQuietDaysReaderOnTheirLine() throws {
        let model = try makeModel()
        model.wrapsLines = true
        let mounted = try page(in: model, saying: longPage(lines: 30))
        let reading = try page(in: model, saying: longPage(lines: 80))
        try select(mounted, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: mounted, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[reading])
        XCTAssertLessThan(editor.frame.minY, quiet.frame.minY, "the case needs the mounted day above the reader")
        let index = (quiet.string as NSString).range(of: "line 40 ").location
        let glyph = try glyphRect(in: quiet, at: index)
        scroll(roll, to: NSPoint(x: 0, y: quiet.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, reading)
        XCTAssertEqual(place.anchor.characterIndex, index)

        let typed = String(repeating: "new words typed above the reader\n", count: 20)
        let start = NSRange(location: 0, length: 0)
        XCTAssertTrue(editor.shouldChangeText(in: start, replacementString: typed))
        try XCTUnwrap(editor.textStorage).replaceCharacters(in: start, with: typed)
        editor.didChangeText()
        roll.stack.update(projection: model.timeUnits, selectedPage: mounted, readOnly: false)

        XCTAssertTrue(roll.stack.quietRegions[reading] === quiet)
        XCTAssertEqual(quiet.string, longPage(lines: 80))
        let offset = try XCTUnwrap(place.anchor.offset(in: quiet))
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, quiet.frame.minY + offset.y, accuracy: 0.5)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index)
    }

    /// The storage fixes attributes lazily, so a keystroke, in a styled list item too, reports its
    /// own characters and no more; that range is what the reading place is rebased through.
    func testAKeystrokeReportsOnlyItsOwnCharactersEvenInAStyledParagraph() throws {
        final class Reports: @unchecked Sendable { var edits: [(range: NSRange, delta: Int)] = [] }
        let model = try makeModel()
        let text = "# A heading with several words\n\nplain words then **a bold run of words** and "
            + "`inline code span` here\n\n- a list item with words\n\n```swift\nlet value = compute(words)\n```\n"
        let selected = try page(in: model, saying: text)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertTrue(storage.fixesAttributesLazily)
        func attributes(at needle: String) -> NSDictionary {
            storage.attributes(at: (editor.string as NSString).range(of: needle).location, effectiveRange: nil)
                as NSDictionary
        }
        XCTAssertNotEqual(attributes(at: "- a list"), attributes(at: "plain"), "the case needs a styled item")
        let reports = Reports()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { note in
            guard let edited = note.object as? NSTextStorage, edited.editedMask.contains(.editedCharacters)
            else { return }
            reports.edits.append((edited.editedRange, edited.changeInLength))
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for (inside, typed) in [
            ("several", "x"), ("bold run", "x"), ("code span", "x"), ("plain", "🧪"), ("then", "漢"),
            ("compute", "x"), ("# A", "x"), ("- a list", "x"), ("item with words", nil),
        ] as [(String, String?)] {
            let found = (editor.string as NSString).range(of: inside)
            XCTAssertNotEqual(found.location, NSNotFound, inside)
            let location = typed == nil ? NSMaxRange(found) : found.location + 2
            let before = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: location, length: 0))
            reports.edits = []
            if let typed {
                editor.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            }
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let delta = (editor.string as NSString).length - before
            XCTAssertEqual(reports.edits.count, 1, inside)
            XCTAssertEqual(reports.edits.first?.range, NSRange(location: location, length: delta), inside)
            XCTAssertEqual(reports.edits.first?.delta, delta, inside)
            if let typed { XCTAssertEqual(delta, (typed as NSString).length, inside) }
        }
    }

    /// ⇥ in a list marker inserts at the item's start, and the storage reports the edit through
    /// to the item's end; a reader on a later line of that item keeps the same line at the top.
    func testADepthNudgeAboveTheReaderInTheirOwnListItemKeepsTheSameLineAtTheTop() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let item = (0..<40).map { "item line \($0)" }.joined(separator: "\u{2028}")
        let selected = try page(in: model, saying: longPage(lines: 5) + "\n\n- " + item + "\n" + longPage(lines: 40))
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let target = "item line 30"
        let index = (editor.string as NSString).range(of: target).location
        let glyph = try glyphRect(in: editor, at: index)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, selected)
        XCTAssertEqual(place.anchor.characterIndex, index)
        let top = roll.scroll.contentView.bounds.minY

        let marker = (editor.string as NSString).range(of: "- item line 0")
        editor.setSelectedRange(NSRange(location: marker.location + 2, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

        XCTAssertEqual((editor.string as NSString).range(of: "  - item line 0").location, marker.location,
                       "the case needs the depth nudge")
        XCTAssertEqual((editor.string as NSString).range(of: target).location, index + 2)
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, top, accuracy: 0.5)
        XCTAssertEqual(roll.stack.currentPlace?.anchor.characterIndex, index + 2)
    }

    /// A styled insertion at the start of a page of one paragraph with no newline is reported as
    /// the whole text, the shape of a restate; the reader's line still moves down with the text.
    func testAStyledInsertionAtTheStartOfAOneParagraphPageMovesTheReaderDown() throws {
        final class Reported: @unchecked Sendable { var edit: (range: NSRange, delta: Int)? }
        let model = try makeModel()
        model.wrapsLines = true
        let selected = try page(in: model, saying: longLine(repetitions: 60))
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertFalse(editor.string.contains("\n"), "the case needs one paragraph and no newline")
        let glyph = try glyphRect(in: editor, at: storage.length / 2)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, selected)
        XCTAssertGreaterThan(place.anchor.characterIndex, 0)
        let reported = Reported()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { note in
            guard let edited = note.object as? NSTextStorage, edited.editedMask.contains(.editedCharacters)
            else { return }
            reported.edit = (edited.editedRange, edited.changeInLength)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let style = NSMutableParagraphStyle()
        style.headIndent = 24
        let pasted = NSAttributedString(
            string: String(repeating: "pasted words ", count: 40),
            attributes: [.font: InkStyle.baseFont, .paragraphStyle: style])
        storage.insert(pasted, at: 0)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)

        let edit = try XCTUnwrap(reported.edit)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: storage.length),
                       "the case needs the storage to report the whole text")
        XCTAssertEqual(edit.delta, pasted.length)
        var expected = place.anchor
        expected.characterIndex += edit.delta
        let offset = try XCTUnwrap(expected.offset(in: editor))
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, editor.frame.minY + offset.y, accuracy: 0.5)
    }

    /// Typing with the caret scrolled out of view reveals the caret, as an NSTextView does, and the
    /// reading place follows the reveal, so the next pass leaves the clip where the reveal put it.
    func testTypingWithTheCaretScrolledOutOfViewRevealsTheCaret() throws {
        for wraps in [true, false] {
            for (caretLine, readerLine) in [(10, 50), (70, 20)] {
                let label = "wraps \(wraps), caret on line \(caretLine), reader on line \(readerLine)"
                let model = try makeModel()
                model.wrapsLines = wraps
                let selected = try page(in: model, saying: longPage(lines: 80))
                let roll = try mountRoll(model: model)
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                let editor = try XCTUnwrap(roll.stack.editor)
                XCTAssertTrue(roll.window.makeFirstResponder(editor))
                let caret = (editor.string as NSString).range(of: "line \(caretLine) ").location
                editor.setSelectedRange(NSRange(location: caret, length: 0))
                let reader = (editor.string as NSString).range(of: "line \(readerLine) ").location
                scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + (try glyphRect(in: editor, at: reader)).minY))
                let caretGlyph = editor.convert(try glyphRect(in: editor, at: caret), to: roll.stack)
                XCTAssertFalse(roll.scroll.contentView.bounds.intersects(caretGlyph),
                               "the case needs the caret out of view: \(label)")
                let height = editor.frame.height

                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

                XCTAssertGreaterThan(editor.frame.height, height, "the case needs the height to change: \(label)")
                assertCaretVisible(in: editor, on: roll)
                let revealed = roll.scroll.contentView.bounds.minY
                roll.stack.relayout()
                roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
                XCTAssertEqual(roll.scroll.contentView.bounds.minY, revealed, accuracy: 0.5, label)
                assertCaretVisible(in: editor, on: roll)
            }
        }
    }

    func testExpansionAndCollapseRestoreHorizontalOffsetsAtTopAndBelowTop() throws {
        for belowTop in [false, true] {
            let model = try makeModel()
            model.wrapsLines = false
            let selected = try page(in: model, saying: longLine() + "\n" + longPage(lines: 80))
            try page(in: model, saying: "older day")
            try select(selected, in: model)
            let roll = try mountRoll(model: model)
            let projection = spreadOverDays(model, selecting: selected)
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            let storage = editor.textStorage
            let selection = NSRange(location: 5, length: 2)
            editor.setSelectedRange(selection)
            let target = NSPoint(x: roll.scroll.contentView.bounds.width / 2,
                                 y: belowTop ? roll.scroll.contentView.bounds.height / 2 : 0)
            scroll(roll, to: target)
            XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
            let place = try XCTUnwrap(roll.stack.currentPlace)
            XCTAssertEqual(place.page, selected)
            model.togglePageExpansion()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertTrue(model.isPageExpanded)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.frame.minY, 0)
            XCTAssertGreaterThan(roll.stack.frame.width, roll.scroll.contentView.bounds.width)
            scroll(roll, to: NSPoint(x: target.x / 2, y: target.y / 2))
            model.escape()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertFalse(model.isPageExpanded)
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, target.x, accuracy: 0.5)
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, target.y, accuracy: 0.5)
            XCTAssertEqual(editor.selectedRange(), selection)
        }
    }

    func testExpandedOwnershipTransferRestoresBothHorizontalPlacesAtTopAndBelowTop() throws {
        for belowTop in [false, true] {
            let model = try makeModel()
            model.wrapsLines = false
            let selected = try page(in: model, saying: longLine() + "\n" + longPage(lines: 80))
            let source = try mountRoll(model: model)
            DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
            let editor = try XCTUnwrap(source.stack.editor)
            let selection = NSRange(location: 5, length: 2)
            editor.setSelectedRange(selection)
            let original = NSPoint(x: source.scroll.contentView.bounds.width / 2,
                                   y: belowTop ? source.scroll.contentView.bounds.height / 2 : 0)
            scroll(source, to: original)
            XCTAssertNotNil(source.stack.currentPlace)
            model.togglePageExpansion()
            DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
            let expanded = NSPoint(x: original.x / 2, y: belowTop ? original.y * 2 : 0)
            scroll(source, to: expanded)
            XCTAssertGreaterThan(source.scroll.contentView.bounds.minX, 0)
            model.transferOwnership(to: .editorWindow)
            DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
            let destination = try mountRoll(model: model, width: 560)
            DayScrollView.updateRoll(destination.scroll, model: model, readOnly: false,
                                     coordinator: destination.coordinator)
            XCTAssertTrue(model.isPageExpanded)
            XCTAssertEqual(destination.coordinator.currentSheet, selected)
            XCTAssertEqual(destination.stack.editor?.selectedRange(), selection)
            XCTAssertEqual(destination.scroll.contentView.bounds.minX, expanded.x, accuracy: 0.5)
            XCTAssertEqual(destination.scroll.contentView.bounds.minY, expanded.y, accuracy: 0.5)
            model.escape()
            DayScrollView.updateRoll(destination.scroll, model: model, readOnly: false,
                                     coordinator: destination.coordinator)
            XCTAssertFalse(model.isPageExpanded)
            XCTAssertEqual(destination.scroll.contentView.bounds.minX, original.x, accuracy: 0.5)
            XCTAssertEqual(destination.scroll.contentView.bounds.minY, original.y, accuracy: 0.5)
        }
    }

    func testNavigatorWidthsStayFiniteAndHorizontalScrollDoesNotMeasure() async throws {
        for wraps in [true, false] {
            let model = try makeModel()
            model.wrapsLines = wraps
            let selected = try page(in: model, saying: longLine() + "\nshort")
            try page(in: model, saying: longLine(repetitions: 60))
            try select(selected, in: model)
            let roll = try mountRoll(model: model)
            let projection = spreadOverDays(model, selecting: selected)
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            await settle()
            let measured = roll.stack.measuredGeometry
            let lines = measured.extents.flatMap(\.lines)
            XCTAssertFalse(lines.isEmpty)
            for line in lines {
                XCTAssertTrue(line.width.isFinite)
                XCTAssertGreaterThan(line.width, 0)
                XCTAssertLessThanOrEqual(line.width, 1)
            }
            let nodes = StreamNavigator.nodes(projection: projection, tabs: model.tabs, selection: model.selection)
            let layout = StreamNavigator.layout(nodes: nodes, geometry: measured, height: 600, width: 140)
            XCTAssertFalse(layout.slivers.isEmpty)
            for sliver in layout.slivers {
                XCTAssertTrue(sliver.width.isFinite)
                XCTAssertGreaterThan(sliver.width, 0)
            }
            if !wraps {
                let measurements = roll.stack.measurements
                let rebuilds = roll.stack.rebuilds
                for fraction: CGFloat in [0.25, 0.75, 0] {
                    let range = roll.stack.frame.width - roll.scroll.contentView.bounds.width
                    scroll(roll, to: NSPoint(x: range * fraction, y: 0))
                    await settle()
                    XCTAssertEqual(roll.scroll.contentView.bounds.minX, range * fraction, accuracy: 0.5)
                    XCTAssertEqual(roll.stack.measurements, measurements)
                    XCTAssertEqual(roll.stack.rebuilds, rebuilds)
                    XCTAssertEqual(roll.stack.measuredGeometry, measured)
                }
            }
        }
    }

    func testTypingAtTheFarRightRevealsTheCaretAndUndoRedoRevealTheirTargets() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let original = longLine(repetitions: 40)
        let selected = try page(in: model, saying: original)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = editor.textStorage
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        try assertGlyphVisible(at: original.utf16.count - 2, in: editor, on: roll)
        let initialWidth = roll.stack.frame.width
        let addition = longLine(repetitions: 8) + "typed"
        editor.breakUndoCoalescing()
        editor.insertText(addition, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertEqual(editor.string, original + addition)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (original + addition).utf16.count, length: 0))
        XCTAssertGreaterThan(roll.stack.frame.width, initialWidth)
        try assertGlyphVisible(at: editor.string.utf16.count - 1, in: editor, on: roll)
        assertCaretVisible(in: editor, on: roll)
        scroll(roll, to: .zero)
        editor.undo(nil)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: original.utf16.count, length: 0))
        try assertGlyphVisible(at: original.utf16.count - 2, in: editor, on: roll)
        assertCaretVisible(in: editor, on: roll)
        scroll(roll, to: .zero)
        editor.redo(nil)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertEqual(editor.string, original + addition)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (original + addition).utf16.count, length: 0))
        try assertGlyphVisible(at: editor.string.utf16.count - 1, in: editor, on: roll)
        assertCaretVisible(in: editor, on: roll)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
    }

    func testNativeFindNextRevealsTheFarRightMatch() throws {
        let saved = copyFindPasteboardItems()
        defer {
            let board = NSPasteboard(name: .find)
            board.clearContents()
            board.writeObjects(saved)
        }
        let model = try makeModel()
        model.wrapsLines = false
        let needle = "dayneedle"
        let original = longLine(repetitions: 60) + needle
        let selected = try page(in: model, saying: original)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let target = (original as NSString).range(of: needle)
        editor.setSelectedRange(target)
        finderAction(.setSearchString, in: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        scroll(roll, to: .zero)
        XCTAssertGreaterThan(try glyphRect(in: editor, at: target.location).minX,
                             roll.scroll.contentView.bounds.maxX)
        finderAction(.nextMatch, in: editor)
        XCTAssertEqual(editor.selectedRange(), target)
        try assertGlyphVisible(at: target.location, in: editor, on: roll)
        try assertGlyphVisible(at: NSMaxRange(target) - 1, in: editor, on: roll)
        XCTAssertEqual(editor.string, original)
    }

    func testNativeReplaceAndFindRevealsTheNextFarRightMatch() throws {
        let saved = copyFindPasteboardItems()
        defer {
            let board = NSPasteboard(name: .find)
            board.clearContents()
            board.writeObjects(saved)
        }
        let model = try makeModel()
        model.wrapsLines = false
        let needle = "dayreplace"
        let replacement = "changed"
        let prefix = longLine(repetitions: 40)
        let between = longLine(repetitions: 20)
        let original = prefix + needle + between + needle
        let selected = try page(in: model, saying: original)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let first = (original as NSString).range(of: needle)
        editor.setSelectedRange(first)
        finderAction(.setSearchString, in: editor)
        finderAction(.showReplaceInterface, in: editor)
        let bar = try XCTUnwrap(roll.scroll.findBarView, "the native replace action did not install its bar")
        let fields = descendants(of: bar).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let search = try XCTUnwrap(fields.first { $0.stringValue == needle },
                                   "native search fields: \(fields.map(\.stringValue))")
        let replace = try XCTUnwrap(fields.first { $0 !== search }, "the native replacement field is absent")
        replace.selectText(nil)
        let input = try XCTUnwrap(replace.currentEditor() as? NSTextView)
        input.selectAll(nil)
        input.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        finderAction(.nextMatch, in: editor)
        XCTAssertEqual(editor.selectedRange(), first)
        scroll(roll, to: .zero)
        finderAction(.replaceAndFind, in: editor)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let expected = prefix + replacement + between + needle
        XCTAssertEqual(editor.string, expected)
        let target = (expected as NSString).range(of: needle, options: .backwards)
        XCTAssertEqual(editor.selectedRange(), target)
        try assertGlyphVisible(at: target.location, in: editor, on: roll)
        try assertGlyphVisible(at: NSMaxRange(target) - 1, in: editor, on: roll)
        XCTAssertTrue(model.canUndoEdit(sheet: selected))
    }

    func testRemovingTheWidestInactiveDayShrinksAndClampsToReachableActiveInk() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine(repetitions: 15))
        let inactive = try page(in: model, saying: longLine())
        let closing = try XCTUnwrap(model.tabs.first { $0.pageID == inactive }?.id)
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: spreadOverDays(model, selecting: selected),
                          selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = editor.textStorage
        let selection = NSRange(location: 5, length: 2)
        editor.setSelectedRange(selection)
        let width = roll.stack.frame.width
        scroll(roll, to: NSPoint(x: width - roll.scroll.contentView.bounds.width, y: 0))
        XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, editor.textContainerOrigin.x
                             + (try textMetrics(editor)).used.maxX)
        model.close(closing)
        roll.stack.update(projection: spreadOverDays(model, selecting: selected),
                          selectedPage: selected, readOnly: false)
        XCTAssertNil(roll.stack.quietRegions[inactive])
        XCTAssertFalse(roll.stack.laidOut.contains { $0.header.pageIdentity == inactive })
        XCTAssertLessThan(roll.stack.frame.width, width)
        XCTAssertEqual(roll.scroll.contentView.bounds.maxX, roll.stack.frame.maxX, accuracy: 0.5)
        try assertGlyphVisible(at: editor.string.utf16.count - 2, in: editor, on: roll)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(model.selectedPageID, selected)
    }

    func testReseedingTheWidestInactiveDayShrinksAndClampsWithoutReplacingItsView() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: "active")
        let inactive = try page(in: model, saying: longLine())
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[inactive])
        let storage = quiet.textStorage
        let editor = try XCTUnwrap(roll.stack.editor)
        let selection = NSRange(location: 2, length: 0)
        editor.setSelectedRange(selection)
        for replacement in [longLine(repetitions: 25), "tiny"] {
            let width = roll.stack.frame.width
            scroll(roll, to: NSPoint(x: width - roll.scroll.contentView.bounds.width, y: 0))
            XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
            XCTAssertTrue(model.coreClient.syncDocument(sheet: inactive, json: "[{\"ink\":\"\(replacement)\"}]"))
            model.invalidateQuietRendering(for: inactive)
            model.refresh()
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertEqual(quiet.string, replacement)
            XCTAssertTrue(roll.stack.quietRegions[inactive] === quiet)
            XCTAssertTrue(quiet.textStorage === storage)
            XCTAssertLessThan(roll.stack.frame.width, width)
            XCTAssertEqual(roll.scroll.contentView.bounds.maxX, roll.stack.frame.maxX, accuracy: 0.5)
            try assertGlyphVisible(at: replacement.utf16.count - 2, in: quiet, on: roll)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(model.selectedPageID, selected)
        }
        XCTAssertEqual(roll.stack.frame.width, roll.scroll.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
    }

    func testUnwrappedFontAndViewportChangesKeepTheInactiveRightEdgeReachable() throws {
        let previousTypeface = InkStyle.typeface
        defer { InkStyle.typeface = previousTypeface }
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: "active")
        let inactive = try page(in: model, saying: longLine(repetitions: 40))
        try select(selected, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let quiet = try XCTUnwrap(roll.stack.quietRegions[inactive])
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = quiet.textStorage
        let selection = NSRange(location: 2, length: 0)
        editor.setSelectedRange(selection)
        let baseSize = model.fontSize
        let baseViewport = roll.scroll.contentView.bounds.width
        let initial = try textMetrics(quiet).used.width
        for (fontScale, viewportScale) in [(2.0, CGFloat(1.5)), (1.0, 0.75), (0.75, 1.25)] {
            scroll(roll, to: NSPoint(x: roll.stack.frame.width - roll.scroll.contentView.bounds.width, y: 0))
            model.fontSize = baseSize * fontScale
            roll.scroll.frame.size.width = baseViewport * viewportScale
            roll.scroll.layoutSubtreeIfNeeded()
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let metrics = try textMetrics(quiet)
            XCTAssertEqual(metrics.lines, 1)
            XCTAssertEqual(metrics.used.width / initial, CGFloat(fontScale), accuracy: 0.05)
            let expectedWidth = ceil(metrics.used.maxX + quiet.textContainerInset.width * 2)
            XCTAssertEqual(roll.stack.frame.width, expectedWidth, accuracy: 0.5)
            XCTAssertLessThanOrEqual(roll.scroll.contentView.bounds.maxX, roll.stack.frame.maxX + 0.5)
            scroll(roll, to: NSPoint(x: roll.stack.frame.width - roll.scroll.contentView.bounds.width, y: 0))
            try assertGlyphVisible(at: quiet.string.utf16.count - 2, in: quiet, on: roll)
            XCTAssertTrue(roll.stack.quietRegions[inactive] === quiet)
            XCTAssertTrue(quiet.textStorage === storage)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
        }
    }

    func testOptionZOnTheMountedDayUpdatesTheOrdinaryWrapPreferenceAndReachability() throws {
        let suite = "day-scroll-option-z-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = try makeModel(defaults: defaults)
        model.wrapsLines = true
        let selected = try page(in: model, saying: longLine(repetitions: 40))
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = editor.textStorage
        let text = editor.string
        let selection = NSRange(location: 5, length: 2)
        editor.setSelectedRange(selection)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let rebuilds = roll.stack.rebuilds
        for wraps in [false, true] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: roll.window.windowNumber,
                context: nil, characters: "Ω", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            editor.keyDown(with: event)
            XCTAssertEqual(model.wrapsLines, wraps)
            XCTAssertEqual(try makeModel(defaults: defaults).wrapsLines, wraps)
            roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
            XCTAssertEqual(editor.textContainer?.widthTracksTextView, wraps)
            XCTAssertEqual(roll.stack.rebuilds, rebuilds)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selection)
            if wraps {
                XCTAssertEqual(roll.stack.frame.width, roll.scroll.contentView.bounds.width, accuracy: 0.5)
                XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
                try assertGlyphVisible(at: selection.location, in: editor, on: roll)
            } else {
                let target = NSRange(location: editor.string.utf16.count - 2, length: 1)
                editor.scrollRangeToVisible(target)
                try assertGlyphVisible(at: target.location, in: editor, on: roll)
                XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
            }
        }
    }

    func testNativeSelectionDragNearTheUnwrappedRightEdgeSelectsReachableInk() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let selected = try page(in: model, saying: longLine(repetitions: 40) + "finish")
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        let text = editor.string
        let length = text.utf16.count
        editor.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
        XCTAssertGreaterThan(roll.scroll.contentView.bounds.minX, 0)
        let first = try glyphRect(in: editor, at: length - 24)
        let last = try glyphRect(in: editor, at: length - 3)
        let start = NSPoint(x: first.minX + first.width / 4, y: first.midY)
        let end = NSPoint(x: last.minX + last.width / 4, y: last.midY)
        let from = editor.characterIndexForInsertion(at: start)
        let to = editor.characterIndexForInsertion(at: end)
        XCTAssertGreaterThan(to, from)
        try assertGlyphVisible(at: from, in: editor, on: roll)
        try assertGlyphVisible(at: to, in: editor, on: roll)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let timestamp = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: editor.convert(point, to: nil), modifierFlags: [],
                timestamp: timestamp + (type == .leftMouseDown ? 0 : 0.1),
                windowNumber: roll.window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try mouse(.leftMouseDown, at: start)
        nonisolated(unsafe) let moves = try [
            mouse(.leftMouseDragged, at: NSPoint(x: (start.x + end.x) / 2, y: start.y)),
            mouse(.leftMouseDragged, at: end),
            mouse(.leftMouseUp, at: end),
        ]
        let release = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                for event in moves { NSApplication.shared.postEvent(event, atStart: false) }
            }
        }
        RunLoop.main.add(release, forMode: .common)
        RunLoop.main.add(release, forMode: .eventTracking)
        defer { release.invalidate() }
        editor.mouseDown(with: down)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: from, length: to - from))
        try assertGlyphVisible(at: NSMaxRange(editor.selectedRange()) - 1, in: editor, on: roll)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(model.selectedPageID, selected)
    }

    // MARK: The shape of the stack

    func testPadSwitchRestoresVisibleCharacterAndEmptyPadStartsAtToday() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        let pageID = try page(in: model, saying: longPage(lines: 200))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 650, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(original.page, pageID)
        XCTAssertGreaterThan(original.anchor.characterIndex, 0)

        let empty = try XCTUnwrap(model.createPad(named: "Empty"))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertNil(roll.stack.currentPlace)
        model.activatePad(scratch)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.stack.currentPlace, original)

        // Two catalog changes before the roll renders must not label Scratch's
        // position as the intermediate pad's position.
        model.activatePad(empty)
        model.activatePad(scratch)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.stack.currentPlace, original)
    }

    func testReorderingCheckpointsInBothDirectionsPreservesVisibleCharacter() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let first = try page(in: model, saying: longPage(lines: 140))
        _ = try page(in: model, saying: longPage(lines: 140))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let row = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == first })
        roll.stack.scroll(toDocumentOffset: row.body.frame.minY + 500, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        for _ in 0..<2 {
            model.toggleCheckpointSort(dayBucket: 0)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            XCTAssertEqual(roll.stack.currentPlace, original)
        }
    }

    func testTwoPopulatedPadsRetainDistinctReadingAnchors() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        let scratchPage = try page(in: model, saying: longPage(lines: 220))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 550, animated: false)
        let scratchPlace = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(scratchPlace.page, scratchPage)

        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.newPage()
        let otherPage = try XCTUnwrap(model.selectedPageID)
        let ink = longPage(lines: 220).replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(sheet: otherPage, json: "[{\"ink\":\"\(ink)\"}]"))
        model.refresh()
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 1150, animated: false)
        let otherPlace = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(otherPlace.page, otherPage)
        XCTAssertNotEqual(scratchPlace.anchor.characterIndex, otherPlace.anchor.characterIndex)

        for _ in 0..<2 {
            model.activatePad(scratch)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            XCTAssertEqual(roll.stack.currentPlace, scratchPlace)
            model.activatePad(other)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            XCTAssertEqual(roll.stack.currentPlace, otherPlace)
        }
    }

    func testLedgerRoundTripRestoresPadReadingPositionOnNewRoll() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        _ = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 700, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        model.showingLedger = true
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        model.showingLedger = false
        let returned = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(returned.scroll, model: model, readOnly: false, coordinator: returned.coordinator)
        XCTAssertEqual(returned.stack.currentPlace, original)
    }

    /// SwiftUI may take the roll out of its window before dismantling it, and
    /// the pad still keeps the place the roll read last.
    func testARollDismantledOutsideItsWindowRemembersItsPadsPlace() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        _ = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 700, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        model.showingLedger = true
        roll.scroll.removeFromSuperview()
        XCTAssertNil(roll.stack.currentPlace, "the precondition: a roll in no window reads no clip")
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        XCTAssertEqual(model.readingPlace(for: PadCatalog.scratchID), original)
        model.showingLedger = false
        let returned = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(returned.scroll, model: model, readOnly: false, coordinator: returned.coordinator)
        XCTAssertEqual(returned.stack.currentPlace, original)
    }

    /// A hand off keeps the outgoing pad's place, even when another pad becomes
    /// active before the incoming roll mounts and takes the hand off's place.
    func testAPadSwitchBeforeTheIncomingRollMountsKeepsTheOutgoingPadsPlace() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        _ = try page(in: model, saying: longPage(lines: 180))
        let source = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
        source.stack.scroll(toDocumentOffset: 700, animated: false)
        let original = try XCTUnwrap(source.stack.currentPlace)
        model.transferOwnership(to: .editorWindow)
        _ = try XCTUnwrap(model.createPad(named: "Other"))
        DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
        let destination = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(
            destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
        model.activatePad(scratch)
        DayScrollView.updateRoll(
            destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
        XCTAssertEqual(destination.stack.currentPlace, original)
    }

    /// A summon after a hand off finds no roll to move. The roll that mounts
    /// next opens on Today, not on the pad's saved place.
    func testASummonBeforeTheIncomingRollMountsOpensItOnToday() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        _ = try page(in: model, saying: longPage(lines: 180))
        let source = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
        source.stack.scroll(toDocumentOffset: 700, animated: false)
        let saved = try XCTUnwrap(source.stack.currentPlace)
        model.rememberPadReadingPlace(saved, for: PadCatalog.scratchID)
        model.transferOwnership(to: .editorWindow)
        XCTAssertNil(model.onAnchorToday)
        model.anchorOnToday()
        DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
        let destination = try mountRoll(model: model, height: 120)
        for _ in 0..<2 {
            DayScrollView.updateRoll(
                destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
            XCTAssertEqual(destination.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
            XCTAssertEqual(destination.stack.currentPlace?.atTop, true)
        }
    }

    /// A checkpoint picked while a file shows opens the returning roll on that
    /// page ahead of the saved place. Closing the file restores the saved place.
    func testACheckpointPickedOverAFileOpensTheRollOnItAndClosingTheFileRestores() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let older = try page(in: model, saying: longPage(lines: 180))
        let newer = try page(in: model, saying: longPage(lines: 180))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pad-pick-\(UUID()).txt")
        try "File content".write(to: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        func mounted() throws -> Roll {
            let roll = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            return roll
        }
        func top(of page: UInt64, in roll: Roll) throws -> CGFloat {
            try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == page }).header.frame.minY
        }

        let roll = try mounted()
        roll.stack.scroll(toDocumentOffset: try top(of: newer, in: roll) + 500, animated: false)
        let saved = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(saved.page, newer)
        model.openFile(at: path)
        let file = try XCTUnwrap(model.selectedFile)
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        model.select(target: .tab(try XCTUnwrap(model.tabs.first { $0.pageID == older }?.id)))
        XCTAssertNil(model.selectedFile)
        let picked = try mounted()
        XCTAssertEqual(picked.scroll.contentView.bounds.origin.y,
            StreamNavigator.jumpOffset(forDocumentTop: try top(of: older, in: picked)), accuracy: 1)
        XCTAssertEqual(picked.stack.currentPlace?.page, older)

        picked.stack.scroll(toDocumentOffset: try top(of: newer, in: picked) + 500, animated: false)
        let reading = try XCTUnwrap(picked.stack.currentPlace)
        model.selectFile(file)
        XCTAssertNotNil(model.selectedFile)
        DayScrollView.dismantleNSView(picked.scroll, coordinator: picked.coordinator)
        model.closeFile(file)
        XCTAssertNil(model.selectedFile)
        XCTAssertEqual(try mounted().stack.currentPlace, reading)
    }

    private func scratchFile() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pad-roll-\(UUID()).txt")
        try "File content".write(to: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func pageRows(of roll: Roll) -> [(page: UInt64, top: CGFloat)] {
        roll.stack.laidOut.compactMap { row in row.header.pageIdentity.map { ($0, row.header.frame.minY) } }
    }

    private func pickedOffset(of page: UInt64, in roll: Roll) throws -> CGFloat {
        let top = try XCTUnwrap(pageRows(of: roll).first { $0.page == page }).top
        let floor = max(roll.stack.frame.height - roll.scroll.contentView.bounds.height, 0)
        return min(StreamNavigator.jumpOffset(forDocumentTop: top), floor)
    }

    private func assertGutterInView(
        of page: UInt64, in roll: Roll, _ message: String = "", line: UInt = #line
    ) throws {
        let top = try XCTUnwrap(pageRows(of: roll).first { $0.page == page }).top
        let clip = roll.scroll.contentView.bounds
        XCTAssertTrue(top >= clip.minY && top < clip.maxY, message, line: line)
    }

    /// After a hand off while a file shows, the later of a summon and a page pick
    /// decides where the incoming roll opens.
    func testTheLaterOfASummonAndAPickDecidesWhereTheIncomingRollOpens() throws {
        for summonFirst in [true, false] {
            let model = try makeModel()
            model.pads.isEnabled = true
            _ = try page(in: model, saying: longPage(lines: 180))
            _ = try page(in: model, saying: longPage(lines: 180))
            let source = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
            let rows = pageRows(of: source)
            let lower = try XCTUnwrap(rows.last).page
            source.stack.scroll(toDocumentOffset: try XCTUnwrap(rows.first).top + 500, animated: false)
            model.openFile(at: try scratchFile())
            DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
            model.transferOwnership(to: .editorWindow)
            let pick = try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id)
            if summonFirst {
                model.anchorOnToday()
                model.select(target: .tab(pick))
            } else {
                model.select(target: .tab(pick))
                model.anchorOnToday()
            }
            let destination = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(
                destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
            let y = destination.scroll.contentView.bounds.origin.y
            if summonFirst {
                XCTAssertEqual(y, try pickedOffset(of: lower, in: destination), accuracy: 1)
                XCTAssertGreaterThan(y, 0)
                try assertGutterInView(of: lower, in: destination)
            } else {
                XCTAssertEqual(y, 0, accuracy: 1)
                XCTAssertEqual(destination.stack.currentPlace?.atTop, true)
            }
        }
    }

    /// ⌘N over a file or the ledger, and the Today node over a file, open the
    /// returning roll on the selected page rather than the saved place.
    func testPagesMintedOrPickedOverAStandInOpenTheReturningRollOnThem() throws {
        for gesture in ["new page over a file", "new page over the ledger", "today over a file"] {
            let model = try makeModel()
            model.pads.isEnabled = true
            _ = try page(in: model, saying: longPage(lines: 180))
            _ = try page(in: model, saying: longPage(lines: 180))
            let roll = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            let lower = try XCTUnwrap(pageRows(of: roll).last)
            roll.stack.scroll(toDocumentOffset: lower.top + 500, animated: false)
            if gesture.hasSuffix("ledger") { model.showingLedger = true } else { model.openFile(at: try scratchFile()) }
            DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
            if gesture.hasPrefix("today") { model.select(target: .today) } else { model.newPage() }
            XCTAssertNil(model.selectedFile, gesture)
            XCTAssertFalse(model.showingLedger, gesture)
            let selected = try XCTUnwrap(model.selectedPageID)
            XCTAssertNotEqual(selected, lower.page, gesture)
            let returned = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(
                returned.scroll, model: model, readOnly: false, coordinator: returned.coordinator)
            XCTAssertEqual(returned.scroll.contentView.bounds.origin.y,
                try pickedOffset(of: selected, in: returned), accuracy: 1, gesture)
            try assertGutterInView(of: selected, in: returned, gesture)
        }
    }

    /// A summon's request that a file or the Tabs layout overtook does not fire
    /// on a later mount, which opens on the pad's saved place.
    func testAnOvertakenRollRequestDoesNotFireOnALaterMount() throws {
        for overtaken in ["file", "tabs"] {
            let model = try makeModel()
            model.pads.isEnabled = true
            _ = try page(in: model, saying: longPage(lines: 180))
            let source = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
            source.stack.scroll(toDocumentOffset: 700, animated: false)
            let saved = try XCTUnwrap(source.stack.currentPlace)
            model.transferOwnership(to: .editorWindow)
            model.anchorOnToday()
            DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
            if overtaken == "file" {
                model.openFile(at: try scratchFile())
                model.closeFile(try XCTUnwrap(model.selectedFile))
                XCTAssertNil(model.selectedFile)
            } else {
                model.showsTimeUnits = false
                model.showsTimeUnits = true
            }
            let destination = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(
                destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
            XCTAssertEqual(destination.stack.currentPlace, saved, overtaken)
        }
    }

    /// With pads off, a page picked or minted over a file or the Ledger also
    /// opens the returning roll on that page rather than at Day 0.
    func testWithPadsOffAPickOrMintOverAStandInOpensTheReturningRollOnIt() throws {
        for (mint, ledger) in [(false, false), (false, true), (true, false), (true, true)] {
            let label = "\(mint ? "mint" : "pick") over \(ledger ? "the ledger" : "a file")"
            let model = try makeModel()
            model.pads.isEnabled = false
            _ = try page(in: model, saying: longPage(lines: 180))
            _ = try page(in: model, saying: longPage(lines: 180))
            let roll = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            let lower = try XCTUnwrap(pageRows(of: roll).last).page
            if ledger { model.showingLedger = true } else { model.openFile(at: try scratchFile()) }
            DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
            if mint {
                model.newPage()
            } else {
                model.select(target: .tab(try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id)))
            }
            let selected = try XCTUnwrap(model.selectedPageID, label)
            let returned = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(
                returned.scroll, model: model, readOnly: false, coordinator: returned.coordinator)
            let y = returned.scroll.contentView.bounds.origin.y
            XCTAssertEqual(y, try pickedOffset(of: selected, in: returned), accuracy: 1, label)
            XCTAssertGreaterThan(y, 0, label)
            try assertGutterInView(of: selected, in: returned, label)
        }
    }

    /// A pass whose rows dropped the page last read keeps a hand off place
    /// waiting on a page that is still projected.
    func testAHandOffPlaceOutlivesTheExpiryOfThePageLastRead() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let read = try page(in: model, saying: longPage(lines: 180))
        let target = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let rows = pageRows(of: roll)
        roll.stack.scroll(
            toDocumentOffset: try XCTUnwrap(rows.first { $0.page == target }).top + 500, animated: false)
        let handOff = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(handOff.page, target)
        roll.stack.scroll(
            toDocumentOffset: try XCTUnwrap(rows.first { $0.page == read }).top + 500, animated: false)
        XCTAssertEqual(roll.stack.currentPlace?.page, read)

        let expired = TimeUnitProjection.project(
            tabs: model.navigationTabs.filter { $0.pageID != read }, selectedPageID: target, unit: .day)
        roll.stack.open(at: handOff)
        roll.stack.update(projection: expired, selectedPage: target, readOnly: false)
        XCTAssertEqual(roll.stack.currentPlace, handOff)
    }

    /// A bounds change while the roll is out of its window keeps the place it
    /// read last, so the dismantle still remembers it for the pad.
    func testABoundsChangeOutOfTheWindowKeepsTheLastReadingPlace() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        _ = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 700, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        roll.scroll.removeFromSuperview()
        scroll(roll, to: NSPoint(x: 0, y: 100))
        roll.stack.relayout()
        XCTAssertNil(roll.stack.currentPlace)
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        XCTAssertEqual(model.readingPlace(for: PadCatalog.scratchID), original)
    }

    /// A summon or a picked page settled while the roll is out of its window
    /// stays where it moved the clip through the passes that follow.
    func testAMoveOutOfTheWindowIsNotUndoneByTheNextPass() throws {
        for move in ["summon", "picked page"] {
            let model = try makeModel()
            model.pads.isEnabled = true
            _ = try page(in: model, saying: longPage(lines: 180))
            _ = try page(in: model, saying: longPage(lines: 180))
            let roll = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            let rows = pageRows(of: roll)
            let upper = try XCTUnwrap(rows.first).page
            roll.stack.scroll(toDocumentOffset: try XCTUnwrap(rows.last).top + 500, animated: false)
            roll.scroll.removeFromSuperview()
            if move == "summon" {
                roll.stack.scrollToDayZero()
            } else {
                roll.stack.open(onPage: upper)
                roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
            }
            let moved = roll.scroll.contentView.bounds.origin.y
            XCTAssertEqual(moved, move == "summon" ? 0 : try pickedOffset(of: upper, in: roll), accuracy: 1, move)
            roll.stack.relayout()
            XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, moved, accuracy: 1, move)
            roll.window.contentView?.addSubview(roll.scroll)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, moved, accuracy: 1, move)
        }
    }

    /// A pass out of the window while a jump travels skips its restore, and the
    /// pad still remembers the place read last.
    func testAPassOutOfTheWindowDuringAJumpKeepsThePlaceReadLast() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "a reader who asks for less motion gets no animated jump")
        let model = try makeModel()
        model.pads.isEnabled = true
        _ = try page(in: model, saying: longPage(lines: 220))
        let roll = try mountRoll(model: model, height: 120, ordered: true)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 700, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        model.rollGeometry.scroll(toDocumentOffset: 2000)
        XCTAssertTrue(roll.stack.jumpInFlight)
        roll.scroll.removeFromSuperview()
        roll.stack.relayout()
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        XCTAssertEqual(model.readingPlace(for: PadCatalog.scratchID), original)
    }

    /// A row arriving above the reader while a jump travels leaves the clip to
    /// the jump: the pass moves it by no frame of its own.
    func testARowArrivingAboveDuringAJumpMovesNoFrame() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "a reader who asks for less motion gets no animated jump")
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 180))
        let second = try page(in: model, saying: longPage(lines: 180))
        let tabs = filed(model, under: [0, -1])
        let full = TimeUnitProjection.project(tabs: tabs, selectedPageID: second, unit: .day)
        let without = TimeUnitProjection.project(
            tabs: tabs.filter { $0.pageID != first }, selectedPageID: second, unit: .day)
        let roll = try mountRoll(model: model, height: 120, ordered: true)
        roll.stack.update(projection: without, selectedPage: second, readOnly: false)
        roll.stack.scroll(toDocumentOffset: 300, animated: false)
        roll.stack.scroll(toDocumentOffset: 1500)
        XCTAssertTrue(roll.stack.jumpInFlight)

        final class Moves: @unchecked Sendable { var count = 0 }
        let moves = Moves()
        let watch = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: roll.scroll.contentView, queue: nil
        ) { _ in moves.count += 1 }
        roll.stack.update(projection: full, selectedPage: second, readOnly: false)
        NotificationCenter.default.removeObserver(watch)
        XCTAssertGreaterThan(try XCTUnwrap(pageRows(of: roll).first { $0.page == second }).top, 300)
        XCTAssertEqual(moves.count, 0)
        XCTAssertTrue(roll.stack.jumpInFlight)
    }

    /// A pass before a queued page settles leaves the clip and the reading place
    /// where they were, rather than restoring the place the page replaces.
    func testAPassBeforeAQueuedPageSettlesDoesNotRestoreTheOldPlace() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        model.wrapsLines = false
        let ink = Array(repeating: longLine(repetitions: 12), count: 40).joined(separator: "\n")
        _ = try page(in: model, saying: ink)
        _ = try page(in: model, saying: ink)
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let rows = pageRows(of: roll)
        let upper = try XCTUnwrap(rows.first).page
        roll.stack.scroll(toDocumentOffset: try XCTUnwrap(rows.last).top + 200, animated: false)
        let old = try XCTUnwrap(roll.stack.readingPlace)
        let start = roll.scroll.contentView.bounds.origin.y

        roll.stack.open(onPage: upper)
        model.wrapsLines = true
        roll.stack.relayout()
        XCTAssertGreaterThan(try XCTUnwrap(pageRows(of: roll).last).top, start, "the rows above grew")
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, start, accuracy: 0.5)
        XCTAssertNotEqual(roll.stack.readingPlace, old)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y,
            try pickedOffset(of: upper, in: roll), accuracy: 1)
    }

    /// With pads on and days oldest first, a roll parked at origin 0 reads a
    /// place on the oldest day, and a pad switch and back returns to it, not Today.
    func testAnOldestFirstRollAtTheOriginReturnsToTheOldestDayAfterAPadSwitch() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        let today = try page(in: model, saying: longPage(lines: 80))
        _ = try page(in: model, saying: longPage(lines: 80))
        let projected = spreadOverDays(model, selecting: today)
        let oldestFirst = TimeUnitProjection(
            units: Array(projected.units.reversed()), hiddenBlankPages: projected.hiddenBlankPages)
        let roll = try mountRoll(model: model, height: 120)
        roll.stack.update(projection: oldestFirst, selectedPage: today, readOnly: false)
        let rows = pageRows(of: roll)
        let oldest = try XCTUnwrap(rows.first).page
        let todayTop = try XCTUnwrap(rows.first { $0.page == today }).top
        XCTAssertNotEqual(oldest, today)
        XCTAssertGreaterThan(todayTop, 0)
        roll.stack.scroll(toDocumentOffset: 0, animated: false)
        XCTAssertEqual(roll.stack.currentPlace?.page, oldest)

        _ = try XCTUnwrap(model.createPad(named: "Other"))
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        model.activatePad(scratch)
        roll.stack.update(projection: oldestFirst, selectedPage: today, readOnly: false)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(roll.stack.currentPlace?.page, oldest)
    }

    /// A pad of long pages mounted on a short roll, with its pages in roll order.
    private func padWithPages(_ count: Int) throws -> (model: PageModel, roll: Roll, pages: [UInt64]) {
        let model = try makeModel()
        model.pads.isEnabled = true
        for _ in 0..<count { _ = try page(in: model, saying: longPage(lines: 180)) }
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        return (model, roll, pageRows(of: roll).map(\.page))
    }

    private func top(of page: UInt64, in roll: Roll) throws -> CGFloat {
        try XCTUnwrap(pageRows(of: roll).first { $0.page == page }).top
    }

    /// ADR-0060: a pad whose remembered anchor is not on the roll opens on its
    /// selected page when that page is, rather than on Today.
    func testASwitchBackWithNoResolvingAnchorOpensOnTheSelectedPage() throws {
        let (model, roll, pages) = try padWithPages(3)
        let (upper, lower) = (try XCTUnwrap(pages.first), try XCTUnwrap(pages.last))
        let scratch = PadCatalog.scratchID
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: try top(of: upper, in: roll) + 500, animated: false)
        XCTAssertEqual(roll.stack.currentPlace?.page, upper)
        _ = try XCTUnwrap(model.createPad(named: "Other"))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        model.activatePad(scratch)
        XCTAssertEqual(model.selectedPageID, lower)

        let withoutAnchor = TimeUnitProjection.project(
            tabs: model.navigationTabs.filter { $0.pageID != upper }, selectedPageID: lower, unit: .day)
        roll.stack.update(projection: withoutAnchor, selectedPage: lower, readOnly: false)
        let y = roll.scroll.contentView.bounds.origin.y
        XCTAssertEqual(y, try pickedOffset(of: lower, in: roll), accuracy: 1)
        XCTAssertGreaterThan(y, 0, "Today is at the origin")
        try assertGutterInView(of: lower, in: roll)
    }

    /// ADR-0060's selected page step is for switching back, so the first mount of
    /// a pad with its selected page off Today still opens at Today.
    func testTheFirstMountOfAPadOpensAtTodayWhateverItsSelectedPage() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        for _ in 0..<2 { _ = try page(in: model, saying: longPage(lines: 180)) }
        let lower = try XCTUnwrap(model.timeUnits.units.flatMap(\.pageIDs).last)
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id))
        // A launch restores the selection without a gesture, so no pick waits for the roll.
        XCTAssertEqual(model.takeRollRequest(), .page(lower))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(model.selectedPageID, lower)
        XCTAssertGreaterThan(try pickedOffset(of: lower, in: roll), 0, "the selected page is off Today")
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
    }

    /// A return from a file to a shown pad whose anchor page closed meanwhile opens
    /// on the selected page, as a switch back does.
    func testAFileRoundTripWhoseAnchorPageClosedReturnsOnTheSelectedPage() throws {
        let (model, roll, pages) = try padWithPages(3)
        let (middle, lower) = (pages[1], pages[2])
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: try top(of: middle, in: roll) + 500, animated: false)
        XCTAssertEqual(roll.stack.currentPlace?.page, middle)
        model.openFile(at: try scratchFile())
        let file = try XCTUnwrap(model.selectedFile)
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        model.close(try XCTUnwrap(model.tabs.first { $0.pageID == middle }?.id))
        XCTAssertNil(model.readingPlace(for: PadCatalog.scratchID))
        model.closeFile(file)
        XCTAssertNil(model.selectedFile)

        let back = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(back.scroll, model: model, readOnly: false, coordinator: back.coordinator)
        XCTAssertEqual(model.selectedPageID, lower)
        let y = back.scroll.contentView.bounds.origin.y
        XCTAssertEqual(y, try pickedOffset(of: lower, in: back), accuracy: 1)
        XCTAssertGreaterThan(y, 0, "Today is at the origin")
    }

    /// A summon outranks the selected page step: a shown pad with no anchor, an
    /// empty Today and an older page selected opens at Today.
    func testASummonOnARemountOutranksTheSelectedPage() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        for _ in 0..<2 { _ = try page(in: model, saying: longPage(lines: 180)) }
        let olderDays = TimeUnitProjection.project(
            tabs: filed(model, under: [-1, -2]), selectedPageID: nil, unit: .day)
        let older = try XCTUnwrap(olderDays.units.flatMap(\.pageIDs).last)
        let shown = try mountRoll(model: model, height: 120)
        shown.stack.update(projection: olderDays, selectedPage: older, readOnly: false)
        XCTAssertNil(model.readingPlace(for: PadCatalog.scratchID))

        let remount = try mountRoll(model: model, height: 120)
        // What `updateRoll` does with a summon that found no roll to move.
        remount.stack.requestToday()
        remount.stack.update(projection: olderDays, selectedPage: older, readOnly: false)
        XCTAssertGreaterThan(try pickedOffset(of: older, in: remount), 0, "the selected page is off Today")
        XCTAssertEqual(remount.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
    }

    /// A hand off from a roll already out of its window saves the place it read
    /// last for the pad, over an older one, and passes it to the incoming roll.
    func testAHandOffFromARollOutOfItsWindowKeepsTheFreshestPlace() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        _ = try page(in: model, saying: longPage(lines: 180))
        let source = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(source.scroll, model: model, readOnly: false, coordinator: source.coordinator)
        source.stack.scroll(toDocumentOffset: 300, animated: false)
        model.rememberPadReadingPlace(try XCTUnwrap(source.stack.currentPlace), for: scratch)
        source.stack.scroll(toDocumentOffset: 700, animated: false)
        let freshest = try XCTUnwrap(source.stack.currentPlace)

        source.scroll.removeFromSuperview()
        model.transferOwnership(to: .editorWindow)
        DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
        XCTAssertEqual(model.readingPlace(for: scratch), freshest)
        let destination = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(
            destination.scroll, model: model, readOnly: false, coordinator: destination.coordinator)
        XCTAssertEqual(destination.stack.currentPlace, freshest)
    }

    /// A summon that reaches a standing roll as a request, after ownership left and
    /// came back, does not outlive its pass: a later pad switch restores that pad's anchor.
    func testASummonDoesNotOverrideALaterPadSwitch() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        _ = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        func pass() {
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        }
        pass()
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.newPage()
        let otherPage = try XCTUnwrap(model.selectedPageID)
        let ink = longPage(lines: 220).replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(sheet: otherPage, json: "[{\"ink\":\"\(ink)\"}]"))
        model.refresh()
        pass()
        roll.stack.scroll(toDocumentOffset: 1150, animated: false)
        let otherPlace = try XCTUnwrap(roll.stack.currentPlace)
        model.activatePad(scratch)
        pass()

        model.transferOwnership(to: .editorWindow)
        model.transferOwnership(to: .panel)
        XCTAssertNil(model.onAnchorToday, "the summon finds no live anchor, so it waits as a request")
        model.anchorOnToday()
        pass()
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        model.activatePad(other)
        pass()
        XCTAssertEqual(roll.stack.currentPlace, otherPlace)
    }

    /// A page queued while the clip had no size yields to a hand off place from a
    /// later pass, and a pick taken in the same pass as a place still outranks it.
    func testAHandOffPlaceOutranksAPageQueuedBeforeTheClipWasSized() throws {
        let (model, roll, pages) = try padWithPages(3)
        let (upper, lower) = (pages[0], pages[2])
        roll.stack.scroll(toDocumentOffset: try top(of: lower, in: roll) + 500, animated: false)
        let handOff = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(handOff.page, lower)
        func size(height: CGFloat) {
            roll.scroll.frame.size.height = height
            roll.scroll.layoutSubtreeIfNeeded()
        }

        size(height: 0)
        XCTAssertTrue(roll.scroll.contentView.bounds.isEmpty)
        roll.stack.open(onPage: upper)
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false)
        model.viewStates.leaveRollPlace(handOff)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        size(height: 120)
        XCTAssertEqual(roll.stack.currentPlace, handOff)

        model.viewStates.leaveRollPlace(handOff)
        model.openFile(at: try scratchFile())
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == upper }?.id))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, try pickedOffset(of: upper, in: roll), accuracy: 1)
        XCTAssertNotEqual(roll.stack.currentPlace, handOff)
    }

    /// ADR-0060 restores the anchor before the selection: the clip returns to the
    /// page being read while the selection stays on the page the editor left.
    func testASwitchBackRestoresTheAnchorPageAndKeepsADifferentSelection() throws {
        let (model, roll, pages) = try padWithPages(2)
        let (upper, lower) = (try XCTUnwrap(pages.first), try XCTUnwrap(pages.last))
        let scratch = PadCatalog.scratchID
        model.select(try XCTUnwrap(model.tabs.first { $0.pageID == upper }?.id))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: try top(of: lower, in: roll) + 500, animated: false)
        let reading = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(reading.page, lower)
        _ = try XCTUnwrap(model.createPad(named: "Other"))
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        model.activatePad(scratch)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(roll.stack.currentPlace, reading)
        XCTAssertEqual(model.selectedPageID, upper)
    }

    /// A tab picked on another pad opens the roll on the picked page, with the
    /// Timeline showing and with a file showing, ahead of that pad's saved place.
    func testAPickOnAnotherPadOpensTheRollOnThePickedPage() throws {
        for overFile in [false, true] {
            let label = overFile ? "over a file" : "over the Timeline"
            let model = try makeModel()
            model.pads.isEnabled = true
            let scratch = PadCatalog.scratchID
            _ = try page(in: model, saying: longPage(lines: 180))
            let other = try XCTUnwrap(model.createPad(named: "Other"))
            let ink = longPage(lines: 180).replacingOccurrences(of: "\n", with: "\\n")
            for _ in 0..<2 {
                model.newPage()
                let created = try XCTUnwrap(model.selectedPageID)
                XCTAssertTrue(model.coreClient.syncDocument(sheet: created, json: "[{\"ink\":\"\(ink)\"}]"))
                model.refresh()
            }
            var roll = try mountRoll(model: model, height: 120)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            let rows = pageRows(of: roll)
            let upper = try XCTUnwrap(rows.first).page
            let lower = try XCTUnwrap(rows.last).page
            roll.stack.scroll(toDocumentOffset: try top(of: upper, in: roll) + 500, animated: false)
            model.activatePad(scratch)
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            XCTAssertEqual(model.readingPlace(for: other)?.page, upper, label)
            if overFile {
                model.openFile(at: try scratchFile())
                DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
            }

            model.select(try XCTUnwrap(model.tabs.first { $0.pageID == lower }?.id))
            XCTAssertEqual(model.pads.activeID, other, label)
            XCTAssertNil(model.selectedFile, label)
            if overFile { roll = try mountRoll(model: model, height: 120) }
            DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
            let y = roll.scroll.contentView.bounds.origin.y
            XCTAssertEqual(y, try pickedOffset(of: lower, in: roll), accuracy: 1, label)
            XCTAssertGreaterThan(y, 0, label)
            try assertGutterInView(of: lower, in: roll, label)
        }
    }

    /// Wait for the clip to stand at `offset`, asked on every bounds change.
    private func waitForClip(of roll: Roll, at offset: CGFloat, timeout: TimeInterval = 2) {
        let clip = roll.scroll.contentView
        let arrived = XCTNSNotificationExpectation(
            name: NSView.boundsDidChangeNotification, object: clip)
        arrived.handler = { _ in MainActor.assumeIsolated { abs(clip.bounds.origin.y - offset) < 1 } }
        if abs(clip.bounds.origin.y - offset) < 1 { arrived.fulfill() }
        wait(for: [arrived], timeout: timeout)
    }

    /// A rail click selects its page and starts a jump, and the pass that the
    /// selection publishes runs mid-jump. The clip still reaches the target.
    func testThePassARailClickPublishesLeavesItsJumpTravelling() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "a reader who asks for less motion gets no animated jump")
        let model = try makeModel()
        model.pads.isEnabled = true
        let first = try page(in: model, saying: longPage(lines: 200))
        _ = try page(in: model, saying: longPage(lines: 200))
        let roll = try mountRoll(model: model, height: 120, ordered: true)
        XCTAssertTrue(roll.window.isVisible)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let row = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == first })
        let target = row.body.frame.minY + 400
        roll.stack.scroll(toDocumentOffset: target > 1500 ? target - 1500 : target + 1500, animated: false)
        let tab = try XCTUnwrap(model.tabs.first { $0.pageID == first }?.id)

        model.select(target: .tab(tab))
        model.rollGeometry.scroll(toDocumentOffset: target)
        XCTAssertTrue(roll.stack.jumpInFlight)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertTrue(roll.stack.jumpInFlight, "the pass must leave the jump travelling")
        waitForClip(of: roll, at: target)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, target, accuracy: 1)
    }

    /// A pad switch restores the other pad's place in another document order.
    /// A jump still travelling through the pad left behind stops there.
    func testAPadSwitchDuringARailJumpStopsItOnTheRestoredPlace() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "a reader who asks for less motion gets no animated jump")
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        _ = try page(in: model, saying: longPage(lines: 220))
        let roll = try mountRoll(model: model, height: 120, ordered: true)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 550, animated: false)
        let scratchPlace = try XCTUnwrap(roll.stack.currentPlace)

        _ = try XCTUnwrap(model.createPad(named: "Other"))
        model.newPage()
        let otherPage = try XCTUnwrap(model.selectedPageID)
        let ink = longPage(lines: 220).replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(sheet: otherPage, json: "[{\"ink\":\"\(ink)\"}]"))
        model.refresh()
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        model.rollGeometry.scroll(toDocumentOffset: 2000)
        XCTAssertTrue(roll.stack.jumpInFlight)

        model.activatePad(scratch)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        XCTAssertFalse(roll.stack.jumpInFlight)
        XCTAssertEqual(roll.stack.currentPlace, scratchPlace)
        letElapse(0.3)
        XCTAssertEqual(roll.stack.currentPlace, scratchPlace)
    }

    func testDayOrderChangesPreserveVisibleCharacterInLongPage() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let first = try page(in: model, saying: longPage(lines: 180))
        _ = try page(in: model, saying: longPage(lines: 180))
        let reverse = spreadOverDays(model, selecting: first)
        let chronological = TimeUnitProjection(units: Array(reverse.units.reversed()),
            hiddenBlankPages: reverse.hiddenBlankPages)
        let roll = try mountRoll(model: model, height: 120)
        roll.stack.update(projection: reverse, selectedPage: first, readOnly: false)
        roll.stack.scroll(toDocumentOffset: 600, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        for projection in [chronological, reverse] {
            roll.stack.update(projection: projection, selectedPage: first, readOnly: false)
            XCTAssertEqual(roll.stack.currentPlace, original)
        }
    }

    func testReadingAnchorOmittedFromProjectionFallsBackToToday() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let omitted = try page(in: model, saying: longPage(lines: 180))
        let visible = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        let row = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == omitted })
        roll.stack.scroll(toDocumentOffset: row.body.frame.minY + 500, animated: false)
        let place = try XCTUnwrap(roll.stack.currentPlace)
        XCTAssertEqual(place.page, omitted)
        model.rememberPadReadingPlace(place, for: PadCatalog.scratchID)
        let filtered = TimeUnitProjection.project(
            tabs: model.navigationTabs.filter { $0.pageID != omitted }, selectedPageID: visible, unit: .day)

        // The page is still live, but this presentation omits it (for example,
        // an older blank checkpoint). Reusing the stack must reset its clip.
        roll.stack.update(projection: filtered, selectedPage: visible, readOnly: false)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)

        // A newly mounted stack must also reject the remembered hidden page.
        let fresh = try mountRoll(model: model, height: 120)
        fresh.stack.update(projection: filtered, selectedPage: visible, readOnly: false)
        XCTAssertEqual(fresh.scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        fresh.stack.scroll(toDocumentOffset: 400, animated: false)
        fresh.stack.open(at: place)
        fresh.stack.update(projection: filtered, selectedPage: visible, readOnly: false)
        XCTAssertEqual(fresh.scroll.contentView.bounds.origin.y, 0, accuracy: 1,
            "an invalid pending restore must not leave stale document coordinates")
    }

    func testFileViewCannotOverwritePadReadingPositionWhileSwitching() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let scratch = PadCatalog.scratchID
        _ = try page(in: model, saying: longPage(lines: 180))
        let roll = try mountRoll(model: model, height: 120)
        DayScrollView.updateRoll(roll.scroll, model: model, readOnly: false, coordinator: roll.coordinator)
        roll.stack.scroll(toDocumentOffset: 600, animated: false)
        let original = try XCTUnwrap(roll.stack.currentPlace)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pad-read-\(UUID()).txt")
        try "File content".write(to: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        model.openFile(at: path)
        XCTAssertNotNil(model.selectedFile)
        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        let other = try XCTUnwrap(model.createPad(named: "Other"))
        model.activatePad(scratch)
        XCTAssertNotNil(model.selectedFile)
        XCTAssertEqual(model.readingPlace(for: scratch), original)
        XCTAssertNil(model.readingPlace(for: other))
    }

    func testExperimentalChronologicalRollAnchorsTodayInsteadOfDocumentOrigin() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let today = try page(in: model, saying: longPage(lines: 80))
        _ = try page(in: model, saying: longPage(lines: 80))
        let projected = spreadOverDays(model, selecting: today)
        let chronological = TimeUnitProjection(
            units: Array(projected.units.reversed()), hiddenBlankPages: projected.hiddenBlankPages)
        let roll = try mountRoll(model: model)
        // This test explicitly closes the retained window. AppKit's default
        // release-on-close would over-release it when Swift drops the fixture.
        roll.window.isReleasedWhenClosed = false
        roll.stack.update(projection: chronological, selectedPage: today, readOnly: false)
        let checkpoint = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == today })
        XCTAssertGreaterThan(checkpoint.header.frame.minY, 0)
        roll.stack.scrollToDayZero()
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, checkpoint.header.frame.minY, accuracy: 1)
        XCTAssertEqual(roll.stack.laidOut.first?.header.mark, .hairline)
        roll.window.close()
    }

    /// A summon asked before today's row stood on the roll is taken by the pass that
    /// assembles it, and the pass after that finds the reader on today.
    func testASummonThatWaitedForTodayIsWhereTheNextPassFindsTheReader() throws {
        let model = try makeModel()
        model.pads.isEnabled = true
        let today = try page(in: model, saying: longPage(lines: 80))
        let older = try page(in: model, saying: longPage(lines: 80))
        let projected = spreadOverDays(model, selecting: older)
        let chronological = TimeUnitProjection(
            units: Array(projected.units.reversed()), hiddenBlankPages: projected.hiddenBlankPages)
        let withoutToday = TimeUnitProjection(
            units: chronological.units.filter { $0.bucket != 0 },
            hiddenBlankPages: projected.hiddenBlankPages)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: withoutToday, selectedPage: older, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let glyph = try glyphRect(in: editor, at: (editor.string as NSString).range(of: "line 40 ").location)
        scroll(roll, to: NSPoint(x: 0, y: editor.frame.minY + glyph.minY + glyph.height / 4))
        let read = roll.scroll.contentView.bounds.minY
        XCTAssertEqual(roll.stack.currentPlace?.page, older)

        roll.stack.scrollToDayZero()
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, read, "with no today on the roll the summon waits")
        roll.stack.update(projection: chronological, selectedPage: older, readOnly: false)
        let checkpoint = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == today })
        XCTAssertGreaterThan(checkpoint.header.frame.minY, 0)
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, checkpoint.header.frame.minY, accuracy: 1)

        roll.stack.update(projection: chronological, selectedPage: older, readOnly: false)
        XCTAssertEqual(roll.scroll.contentView.bounds.minY, checkpoint.header.frame.minY, accuracy: 1,
                       "the next pass returned the reader to the place the summon left")
        XCTAssertEqual(roll.stack.currentPlace?.page, today)
    }

    func testBlankRollAndCheckpointClicksFocusWithoutMovingTheCaret() async throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "first line\nsecond line")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let caret = NSRange(location: 3, length: 0)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let points = [
            NSPoint(x: 200, y: roll.stack.bounds.maxY - 20),
            NSPoint(x: 200, y: header.frame.maxY - 1),
            NSPoint(x: 20, y: header.frame.minY + 8),
        ]
        for point in points {
            editor.setSelectedRange(caret)
            _ = roll.window.makeFirstResponder(nil)
            let hit = try XCTUnwrap(roll.stack.hitTest(point))
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: roll.stack.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: roll.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            hit.mouseDown(with: event)
            await settle()
            XCTAssertTrue(roll.window.firstResponder === editor, "content click at \(point) did not focus")
            XCTAssertEqual(editor.selectedRange(), caret)
            XCTAssertEqual(model.selectedPageID, selected)
            XCTAssertTrue(hit.needsPanelToBecomeKey)
            XCTAssertTrue(hit.acceptsFirstMouse(for: event))
        }
    }

    private final class ClickResponder: NSResponder {
        var clicks = 0
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    func testBlankViewportBelowTrailingNewlineFocusesAtSeveralWindowSizes() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "short page\n")
        let roll = try mountRoll(model: model)
        let caret = NSRange(location: 2, length: 0)
        for height: CGFloat in [320, 720] {
            roll.scroll.frame.size.height = height
            roll.scroll.layoutSubtreeIfNeeded()
            roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            let visible = roll.stack.visibleRect
            XCTAssertGreaterThanOrEqual(editor.frame.maxY, visible.maxY)
            for y in [editor.frame.minY + 100, (editor.frame.minY + visible.maxY) / 2, visible.maxY - 8] {
                let point = NSPoint(x: visible.midX, y: y)
                let hit = try XCTUnwrap(roll.stack.hitTest(point))
                editor.setSelectedRange(caret)
                _ = roll.window.makeFirstResponder(nil)
                let location = roll.stack.convert(point, to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: roll.window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1))
                XCTAssertTrue(hit === editor, "blank viewport at \(point) hit \(hit)")
                XCTAssertTrue(hit.needsPanelToBecomeKey)
                XCTAssertTrue(hit.acceptsFirstMouse(for: event))
                // The up is queued first, so the click resolves as a focus
                // click rather than on the host's physical button state.
                roll.window.postEvent(try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: roll.window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1)), atStart: true)
                hit.mouseDown(with: event)
                XCTAssertTrue(roll.window.firstResponder === editor)
                XCTAssertEqual(editor.selectedRange(), caret)
            }
        }
    }

    func testLastPageFillsRemainingViewportBeforeSelectionAndKeepsItsSize() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "first\n")
        let second = try page(in: model, saying: "second\n")
        let third = try page(in: model, saying: "third\n")
        let roll = try mountRoll(model: model, height: 720)

        for height: CGFloat in [720, 480, 900] {
            roll.scroll.frame.size.height = height
            roll.scroll.layoutSubtreeIfNeeded()
            var originalFrames: [NSRect]?
            for selected in [first, second, third, first] {
                roll.stack.update(
                    projection: spreadOverDays(model, selecting: selected),
                    selectedPage: selected, readOnly: false
                )
                let parts = roll.stack.laidOut
                let last = try XCTUnwrap(parts.last)
                let viewport = roll.scroll.contentView.bounds.height
                XCTAssertEqual(last.body.frame.maxY, viewport, accuracy: 0.5)
                XCTAssertEqual(roll.stack.frame.height, viewport, accuracy: 0.5)
                let bottom = NSPoint(x: 200, y: viewport - 10)
                XCTAssertTrue(roll.stack.hitTest(bottom) === last.body,
                              "the last page must own the blank area before it is selected")
                for part in parts.dropLast() {
                    let text = try XCTUnwrap(part.body as? NSTextView)
                    XCTAssertEqual(text.frame.height,
                                   DayStackView.measuredHeight(of: text, width: text.frame.width),
                                   accuracy: 0.5, "selection must not expand an earlier page")
                }
                let frames = parts.flatMap { [$0.header.frame, $0.body.frame] }
                if let originalFrames {
                    XCTAssertEqual(frames, originalFrames, "selection must not move checkpoints")
                } else {
                    originalFrames = frames
                }
            }
        }
    }

    func testLongRollDoesNotAddViewportHeightToTheSelectedPage() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 80))
        let last = try page(in: model, saying: "short\n")
        let roll = try mountRoll(model: model)
        for selected in [first, last] {
            roll.stack.update(
                projection: spreadOverDays(model, selecting: selected),
                selectedPage: selected, readOnly: false
            )
            for part in roll.stack.laidOut {
                let text = try XCTUnwrap(part.body as? NSTextView)
                XCTAssertEqual(text.frame.height,
                               DayStackView.measuredHeight(of: text, width: text.frame.width),
                               accuracy: 0.5)
            }
        }
    }

    func testPageExpansionKeepsEditorAndCaretThenRestoresTheRoll() throws {
        let model = try makeModel()
        try page(in: model, saying: longPage(lines: 80))
        let selected = try page(in: model, saying: "short page\n")
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: selected)
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = editor.textStorage
        let undo = editor.undoManager
        let caret = NSRange(location: 3, length: 0)
        editor.setSelectedRange(caret)
        roll.window.makeFirstResponder(editor)
        roll.stack.scroll(toDocumentOffset: 200, animated: false)
        let originalOffset = roll.scroll.contentView.bounds.origin.y
        let originalFrames = roll.stack.laidOut.flatMap { [$0.header.frame, $0.body.frame] }
        var handedBack = false
        model.onHandBackKeys = { handedBack = true }

        model.togglePageExpansion()
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertTrue(model.isPageExpanded)
        XCTAssertTrue(roll.stack.editor === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertEqual(editor.frame.minY, 0)
        XCTAssertEqual(editor.frame.height, roll.scroll.contentView.bounds.height)
        XCTAssertEqual(roll.stack.measuredGeometry.extents.count, 1)
        for part in roll.stack.laidOut {
            XCTAssertTrue(part.header.isHidden)
            XCTAssertEqual(part.body.isHidden, part.body !== editor)
        }
        // A resize changes the typing measure without leaving expansion.
        roll.scroll.frame.size = NSSize(width: 600, height: 600)
        roll.stack.relayout()
        XCTAssertEqual(editor.frame.size, roll.scroll.contentView.bounds.size)
        roll.scroll.frame.size = NSSize(width: 420, height: 320)
        roll.stack.relayout()

        model.escape()
        roll.stack.update(projection: projection, selectedPage: selected, readOnly: false)
        XCTAssertFalse(model.isPageExpanded)
        XCTAssertFalse(handedBack, "the first Escape only collapses the page")
        XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, originalOffset, accuracy: 0.5)
        XCTAssertEqual(roll.stack.laidOut.flatMap { [$0.header.frame, $0.body.frame] }, originalFrames)
        XCTAssertTrue(roll.stack.laidOut.allSatisfy { !$0.header.isHidden && !$0.body.isHidden })
        model.escape()
        XCTAssertTrue(handedBack)
    }

    func testExpansionCarriesBothScrollPositionsAcrossWindowOwnership() throws {
        let model = try makeModel()
        try page(in: model, saying: longPage(lines: 80))
        try page(in: model, saying: longPage(lines: 90))
        let source = try mountRoll(model: model)
        DayScrollView.updateRoll(source.scroll, model: model, readOnly: false,
                                 coordinator: source.coordinator)
        source.stack.scroll(toDocumentOffset: 200, animated: false)
        model.togglePageExpansion()
        DayScrollView.updateRoll(source.scroll, model: model, readOnly: false,
                                 coordinator: source.coordinator)
        source.stack.scroll(toDocumentOffset: 400, animated: false)

        model.transferOwnership(to: .editorWindow)
        DayScrollView.dismantleNSView(source.scroll, coordinator: source.coordinator)
        let destination = try mountRoll(model: model)
        DayScrollView.updateRoll(destination.scroll, model: model, readOnly: false,
                                 coordinator: destination.coordinator)
        XCTAssertTrue(model.isPageExpanded)
        XCTAssertEqual(destination.scroll.contentView.bounds.origin.y, 400, accuracy: 0.5)
        model.escape()
        DayScrollView.updateRoll(destination.scroll, model: model, readOnly: false,
                                 coordinator: destination.coordinator)
        XCTAssertEqual(destination.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5)
    }

    func testCheckpointClickFocusesItsOwnPageAtTheSavedCaret() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "first page\n")
        let second = try page(in: model, saying: "second page\n")
        let roll = try mountRoll(model: model, height: 720)
        roll.stack.update(projection: model.timeUnits, selectedPage: second, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let firstCaret = NSRange(location: 3, length: 0)
        model.viewStates.saveCaret(firstCaret, for: first)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let headerFrame = header.frame
        let point = NSPoint(x: 200, y: header.frame.maxY - 1)
        let hit = try XCTUnwrap(roll.stack.hitTest(point))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: roll.stack.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: roll.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        roll.window.makeFirstResponder(nil)
        hit.mouseDown(with: event)
        // Drive the SwiftUI update that the selection change schedules.
        roll.stack.update(projection: model.timeUnits, selectedPage: model.selectedPageID,
                          readOnly: false)
        XCTAssertEqual(model.selectedPageID, first)
        XCTAssertEqual(roll.coordinator.currentSheet, first)
        XCTAssertEqual(editor.selectedRange(), firstCaret)
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(header.frame, headerFrame)
        XCTAssertEqual(model.viewStates.carets[second], NSRange(location: 5, length: 0))
    }

    func testExpansionRequiresAPageAndEndsWhenSelectionChanges() throws {
        let model = try makeModel()
        XCTAssertFalse(model.canExpandPage)
        model.togglePageExpansion()
        XCTAssertFalse(model.isPageExpanded)
        try page(in: model, saying: "first")
        let firstTab = try XCTUnwrap(model.selection)
        try page(in: model, saying: "second")
        let secondTab = try XCTUnwrap(model.selection)
        model.togglePageExpansion()
        XCTAssertTrue(model.isPageExpanded)
        model.select(firstTab)
        XCTAssertFalse(model.isPageExpanded)
        model.select(secondTab)
        XCTAssertFalse(model.isPageExpanded)
        model.togglePageExpansion()
        model.togglePageExpansion()
        XCTAssertFalse(model.isPageExpanded)
        model.togglePageExpansion()
        model.showingLedger = true
        XCTAssertFalse(model.canExpandPage)
        XCTAssertFalse(model.isPageExpanded)
        model.showingLedger = false
        XCTAssertFalse(model.isPageExpanded)
    }

    private func leftClick(in window: NSWindow, at point: NSPoint = .zero) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1
        ))
    }

    /// The stack itself no longer takes clicks: blank viewport belongs to
    /// the editor's own frame. What remains ours is the header's forward
    /// when there is no editor to focus.
    func testUnavailableRollFocusForwardsHeaderClicksToTheResponderChain() throws {
        let model = try makeModel()
        let roll = try mountRoll(model: model)
        let fallback = ClickResponder()
        let event = try leftClick(in: roll.window)

        // Before the first page there is no editor to receive focus.
        XCTAssertFalse(roll.stack.focusEditor())

        let selected = try page(in: model, saying: "writing")
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: true)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        header.nextResponder = fallback
        XCTAssertFalse(roll.stack.focusEditor())
        header.mouseDown(with: event)
        XCTAssertEqual(fallback.clicks, 1, "read-only content swallowed its click")

        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        roll.scroll.removeFromSuperview()
        XCTAssertFalse(roll.stack.focusEditor(), "a detached roll reported that it focused")
        header.mouseDown(with: event)
        XCTAssertEqual(fallback.clicks, 2)
    }

    func testCheckpointFocusTraversesAnIntermediateContainer() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "writing")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let container = NSView(frame: header.frame)
        roll.stack.addSubview(container)
        header.removeFromSuperview()
        container.addSubview(header)
        header.frame.origin = .zero
        let caret = NSRange(location: 3, length: 0)
        editor.setSelectedRange(caret)
        _ = roll.window.makeFirstResponder(nil)

        XCTAssertTrue(header.needsPanelToBecomeKey)
        header.mouseDown(with: try leftClick(in: roll.window))

        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), caret)
    }

    func testCheckpointAccessibilityHitUsesTheComposedHeaderExceptDuringRename() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "writing")
        let tab = try XCTUnwrap(model.selection)
        model.renameTab(tab, to: "named page")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let fields = header.subviews.compactMap { $0 as? NSTextField }
        let title = try XCTUnwrap(fields.first { $0.stringValue == "named page" })
        let expected = header.accessibilityLabel()
        XCTAssertTrue(
            fields.contains { !$0.isHidden && $0.frame == header.timeFrame }, "the time is not among the hits")

        for field in fields where !field.isHidden {
            let local = NSPoint(x: field.frame.midX, y: field.frame.midY)
            let screen = roll.window.convertPoint(toScreen: header.convert(local, to: nil))
            let target = try XCTUnwrap(header.accessibilityHitTest(screen) as? NSView)
            XCTAssertTrue(target === header)
            XCTAssertEqual(target.accessibilityLabel(), expected)
        }

        header.beginRename()
        let local = NSPoint(x: title.frame.midX, y: title.frame.midY)
        let screen = roll.window.convertPoint(toScreen: header.convert(local, to: nil))
        let target = try XCTUnwrap(header.accessibilityHitTest(screen) as? NSView)
        XCTAssertTrue(target === title, "the editable name lost its accessibility target")
        let time = header.timeFrame
        XCTAssertGreaterThanOrEqual(time.minX, title.frame.maxX, "the time did not slide right of the field")
        let beside = roll.window.convertPoint(toScreen: header.convert(NSPoint(x: time.midX, y: time.midY), to: nil))
        let timeTarget = try XCTUnwrap(header.accessibilityHitTest(beside) as? NSView)
        XCTAssertTrue(timeTarget === header, "the time beside the open field lost the composed header")
        header.endRename(committed: false)
    }

    /// Every row is its header and then its region, and the document is
    /// exactly as tall as the rows it holds, or as tall as the clip,
    /// when there is less writing than card.
    func testTheStackIsItsHeadersAndItsRegionsAndNothingElse() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today's page")
        try page(in: model, saying: "yesterday's page")
        try page(in: model, saying: "the day before")
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        let parts = roll.stack.laidOut
        XCTAssertEqual(parts.count, 3, "three days, three rows")
        var y: CGFloat = 0
        for part in parts {
            XCTAssertEqual(part.header.frame.minY, y, accuracy: 0.5, "a gap opened above a day")
            XCTAssertEqual(part.header.frame.width, roll.scroll.contentView.bounds.width)
            y = part.header.frame.maxY
            XCTAssertEqual(part.body.frame.minY, y, accuracy: 0.5, "a page left its own header")
            y = part.body.frame.maxY
        }
        XCTAssertEqual(
            roll.stack.frame.height,
            max(y, roll.scroll.contentView.bounds.height),
            accuracy: 0.5,
            "the document is not the sum of what is in it"
        )
    }

    /// The perforation is the mark of a day boundary, so it appears
    /// between days and never above the first one: today is where the
    /// roll starts and there is nothing above it to tear away from.
    func testAPerforationSitsBetweenDaysAndNoneAboveTheFirst() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        let marks = roll.stack.laidOut.map { $0.header.mark }
        XCTAssertEqual(marks, [DayHeaderView.Mark.none, .tear])
        XCTAssertEqual(
            roll.stack.laidOut[0].header.frame.height,
            DayHeaderView.gutterHeight,
            "the first header reserved room for a tear it does not draw"
        )
        XCTAssertEqual(
            roll.stack.laidOut[1].header.frame.height,
            DayHeaderView.gutterHeight + DayHeaderView.tearReserve
        )
    }

    /// Two pages born on one day are one day: they are grouped under the
    /// label, and the mark between them is the hairline that says "still
    /// this day" rather than the tear that says "a day ago".
    func testTwoPagesOnOneDayAreJoinedByAHairlineRatherThanATear() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "this morning")
        try page(in: model, saying: "this afternoon")
        try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        // The first two share today; the third is a day back.
        let projection = TimeUnitProjection.project(
            tabs: filed(model, under: [0, 0, -1]), selectedPageID: first, unit: .day
        )

        roll.stack.update(projection: projection, selectedPage: first, readOnly: false)

        XCTAssertEqual(
            roll.stack.laidOut.map { $0.header.mark },
            [DayHeaderView.Mark.none, .hairline, .tear]
        )
    }

    // MARK: What the roll tells the rail

    /// The measurement the rail's navigator is drawn from is read off
    /// the frames this pass set: one extent per page, in the roll's own
    /// order, each running from the top of the page's header to the
    /// bottom of its body, with the document's own height and the
    /// clip's own window beside them (issue #131). Nothing here is
    /// computed a second way, which is the whole reason a node's place
    /// cannot disagree with the pages under the reader's eye.
    func testTheRollMeasuresOneExtentPerPageInDocumentOrder() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 20))
        try page(in: model, saying: longPage(lines: 4))
        try page(in: model, saying: "a line")
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        let measured = roll.stack.measuredGeometry
        XCTAssertEqual(measured.extents.map(\.bucket), [0, -1, -2], "the days lost the roll's order")
        XCTAssertEqual(
            measured.extents.map(\.page), model.tabs.map(\.pageID),
            "the extents did not name the pages under them")
        for (extent, part) in zip(measured.extents, roll.stack.laidOut) {
            XCTAssertEqual(extent.top, part.header.frame.minY, accuracy: 0.5)
            XCTAssertEqual(extent.bottom, part.body.frame.maxY, accuracy: 0.5)
        }
        XCTAssertEqual(measured.documentHeight, roll.stack.frame.height, accuracy: 0.5)
        XCTAssertEqual(
            measured.viewportHeight, roll.scroll.contentView.bounds.height, accuracy: 0.5)
        XCTAssertEqual(measured.viewportTop, 0, accuracy: 0.5)
        // A page holding more writing is a taller stretch of the roll,
        // which is the fact a node's place on the rail is a reading of.
        XCTAssertGreaterThan(
            measured.extents[0].height, measured.extents[2].height,
            "a long page measured no taller than a one line page")
    }

    /// The lines are measured as rectangles: one per laid-out line
    /// fragment, each inside its page's span, and a long line wider
    /// than a short one. No text crosses, which is what lets the rail
    /// draw them without answering for what they say.
    func testTheRollMeasuresEachPagesLinesAsRectangles() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "short\na line that runs on for rather longer than the one above it")
        try page(in: model, saying: longPage(lines: 3))
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        let measured = roll.stack.measuredGeometry
        let today = try XCTUnwrap(measured.extents.first)
        XCTAssertGreaterThanOrEqual(today.lines.count, 2, "two lines of ink, two rectangles")
        XCTAssertLessThan(today.lines[0].width, today.lines[1].width, "the short line drew wider")
        for extent in measured.extents {
            for line in extent.lines {
                XCTAssertGreaterThanOrEqual(line.y, extent.top - 0.5, "a line above its page")
                XCTAssertLessThanOrEqual(line.y, extent.bottom, "a line below its page")
                XCTAssertGreaterThanOrEqual(line.width, 0)
                XCTAssertLessThanOrEqual(line.width, 1)
            }
        }
        XCTAssertGreaterThanOrEqual(measured.extents[1].lines.count, 3)
    }

    /// Two pages born on one day are two extents under one bucket,
    /// because the navigator draws a node per page. Each runs from its
    /// own header, the hairline between them included in the second.
    func testTwoPagesOfOneDayMeasureAsTwoExtents() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "this morning")
        try page(in: model, saying: "this afternoon")
        try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        let projection = TimeUnitProjection.project(
            tabs: filed(model, under: [0, 0, -1]), selectedPageID: first, unit: .day
        )

        roll.stack.update(projection: projection, selectedPage: first, readOnly: false)

        let measured = roll.stack.measuredGeometry
        XCTAssertEqual(roll.stack.laidOut.count, 3, "three pages, three rows")
        XCTAssertEqual(measured.extents.map(\.bucket), [0, 0, -1], "two days, three pages")
        XCTAssertEqual(measured.extents[0].top, 0, accuracy: 0.5)
        XCTAssertEqual(
            measured.extents[0].bottom, roll.stack.laidOut[0].body.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(
            measured.extents[1].top, roll.stack.laidOut[1].header.frame.minY, accuracy: 0.5,
            "today's second page did not start at its own header")
        XCTAssertEqual(
            measured.extents[2].top, roll.stack.laidOut[2].header.frame.minY, accuracy: 0.5)
    }

    /// And the viewport half of it follows the clip, so the band the
    /// rail draws beside the nodes says where the reader actually is.
    /// The scroll moves no frame, which is why the roll watches the
    /// clip's bounds as well as its frame.
    func testTheMeasurementFollowsTheClipDownTheRoll() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 120))
        try page(in: model, saying: longPage(lines: 120))
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )
        let documentRevision = roll.stack.measuredGeometry.document.revision
        XCTAssertGreaterThan(documentRevision, 0)
        roll.scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)

        let measured = roll.stack.measuredGeometry
        XCTAssertEqual(measured.viewportTop, 240, accuracy: 1)
        XCTAssertEqual(
            measured.document.revision, documentRevision,
            "scrolling replaced document geometry instead of reusing it")
        XCTAssertGreaterThan(
            measured.documentHeight, measured.viewportHeight,
            "a roll this long has to outgrow the card for the band to mean anything")
        let nodes = StreamNavigator.nodes(
            projection: spreadOverDays(model, selecting: first), tabs: model.tabs,
            selection: model.selection)
        let layout = StreamNavigator.layout(nodes: nodes, geometry: measured, height: 300, width: 102)
        let band = try XCTUnwrap(layout.band)
        XCTAssertGreaterThan(band.y, StreamNavigator.Metrics.top - 8,
            "the band stayed at the top of a scrolled roll")
    }

    /// The rail's two asks of the roll are answered by the mounted one:
    /// a jump lands the clip on the offset, clamped to the document, and
    /// a roll that has been dismantled answers nothing.
    func testTheRollAnswersAJumpFromTheRailUntilItIsDismantled() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 120))
        try page(in: model, saying: longPage(lines: 120))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        // Instant under test: there is no window on screen to animate
        // in, and the clamp is the claim.
        roll.stack.scroll(toDocumentOffset: 200)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 200, accuracy: 1)
        roll.stack.scroll(toDocumentOffset: 1_000_000)
        let floor = roll.stack.frame.height - roll.scroll.contentView.bounds.height
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, floor, accuracy: 1,
            "a jump past the end left the elastic")
        roll.stack.scroll(toDocumentOffset: -50)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 0, accuracy: 1)

        model.rollGeometry.scroll(toDocumentOffset: 120)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 120, accuracy: 1,
            "the rail's ask did not reach the mounted roll")

        DayScrollView.dismantleNSView(roll.scroll, coordinator: roll.coordinator)
        let replacement = try mountRoll(model: model)
        replacement.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )
        model.rollGeometry.scroll(toDocumentOffset: 60)
        XCTAssertEqual(replacement.scroll.contentView.bounds.origin.y, 60, accuracy: 1)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 120, accuracy: 1,
            "a dismantled roll went on answering the rail")
    }

    /// The measurement stands after the roll it replaced is dismantled
    /// (issue #131). SwiftUI may build and lay out a replacement before
    /// tearing down what it replaces, and both rolls hand their
    /// measurements to the one model, so the surface on the way out must
    /// not blank the surface on the way in. Asserted through the
    /// publication rather than off `measuredGeometry`, because the
    /// blanking would happen on the hop and nowhere else.
    func testATeardownLeavesTheReplacementRollStanding() async throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 20))
        let projection = spreadOverDays(model, selecting: first)
        let outgoing = try mountRoll(model: model)
        outgoing.stack.update(projection: projection, selectedPage: first, readOnly: false)

        let incoming = try mountRoll(model: model)
        incoming.stack.update(projection: projection, selectedPage: first, readOnly: false)
        DayScrollView.dismantleNSView(outgoing.scroll, coordinator: outgoing.coordinator)
        await settle()

        XCTAssertNotEqual(
            model.rollGeometry.geometry, .unmeasured,
            "the outgoing roll's teardown blanked the rail behind a roll that is on screen")
        XCTAssertEqual(
            model.rollGeometry.geometry.documentHeight,
            incoming.stack.measuredGeometry.documentHeight, accuracy: 0.5)
    }

    // MARK: Where the roll opens, and where it stays

    /// Day 0 is the top of the document, and the anchor is an instant
    /// clip move back to it. Nothing else in the mode moves the scroll.
    func testDayZeroIsTheTopAndTheAnchorPutsTheClipBackOnIt() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 120))
        try page(in: model, saying: longPage(lines: 120))
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        XCTAssertEqual(roll.stack.laidOut.first?.header.frame.minY, 0, "today is not at the top")
        roll.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)
        XCTAssertEqual(roll.scroll.contentView.bounds.origin.y, 200, accuracy: 1)

        roll.stack.scrollToDayZero()

        XCTAssertEqual(
            roll.scroll.contentView.bounds.origin.y, 0,
            "a summon has to open the pad on today"
        )
    }

    /// The roll is a document and not a card: several days of writing
    /// outgrow one cardful and the clip travels past it, with the editor
    /// mounted somewhere in the middle rather than at the top.
    func testTheRollOutgrowsOneCardfulWithTheEditorMountedMidRoll() throws {
        let model = try makeModel()
        try page(in: model, saying: longPage(lines: 60))
        let middle = try page(in: model, saying: longPage(lines: 60))
        try page(in: model, saying: longPage(lines: 60))
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: middle),
            selectedPage: middle,
            readOnly: false
        )

        let clipHeight = roll.scroll.contentView.bounds.height
        XCTAssertGreaterThan(
            roll.stack.frame.height, clipHeight * 2,
            "three long days must not fit in one card, or the fixture proves nothing"
        )
        XCTAssertTrue(roll.stack.editor?.superview === roll.stack)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertGreaterThan(
            editor.frame.minY, 0,
            "the editor is the second day, so it cannot be at the top of the roll"
        )
        // The grant `scrollStack` makes to the editor's own clip, which
        // this mount has to make for itself: without it a vertically
        // resizable text view will not grow past a `maxSize` that starts
        // at its frame, and today's page is written past a ceiling of
        // nothing (the silent failure `PageScrollTests` guards).
        XCTAssertEqual(editor.maxSize.height, CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(editor.maxSize.width, CGFloat.greatestFiniteMagnitude)
        XCTAssertTrue(editor.isVerticallyResizable)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertGreaterThan(
            editor.frame.height, 100,
            "a long day is mounted at a height that shows none of it"
        )

        let last = try XCTUnwrap(roll.stack.laidOut.last).body
        roll.scroll.contentView.scroll(to: NSPoint(x: 0, y: roll.stack.frame.height - clipHeight))
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)

        XCTAssertTrue(
            roll.scroll.contentView.bounds.intersects(last.frame),
            "the oldest day is written and cannot be scrolled to"
        )
    }

    /// Local midnight, or a page minted into a day above the one being
    /// read: the rows above grow and the reader's own place must not
    /// move. The clip goes down by exactly what arrived over it.
    func testARowInsertedAboveTheViewportMovesNothingUnderTheReader() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: longPage(lines: 80))
        try page(in: model, saying: longPage(lines: 80))
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )
        // The reader is down in history, looking at the oldest day.
        let oldest = try XCTUnwrap(roll.stack.laidOut.last)
        roll.scroll.contentView.scroll(to: NSPoint(x: 0, y: oldest.header.frame.minY - 40))
        roll.scroll.reflectScrolledClipView(roll.scroll.contentView)
        let onScreenBefore = oldest.body.frame.minY - roll.scroll.contentView.bounds.origin.y

        // A new day arrives over the top of both of them: the third slot
        // in strip order is today's, and the two that were there are a
        // day and two days back.
        try page(in: model, saying: longPage(lines: 30))
        roll.stack.update(
            projection: TimeUnitProjection.project(
                tabs: filed(model, under: [-1, -2, 0]), selectedPageID: first, unit: .day
            ),
            selectedPage: first,
            readOnly: false
        )

        XCTAssertEqual(roll.stack.laidOut.count, 3)
        let moved = try XCTUnwrap(roll.stack.laidOut.last)
        let onScreenAfter = moved.body.frame.minY - roll.scroll.contentView.bounds.origin.y
        XCTAssertEqual(
            onScreenAfter, onScreenBefore, accuracy: 1,
            "the calendar pulled the page the reader was reading out from under them"
        )
    }

    func testPrependingAndReorderingAtHorizontalOnlyOffsetsKeepTheVerticalOrigin() throws {
        let model = try makeModel()
        model.wrapsLines = false
        let first = try page(in: model, saying: longLine(repetitions: 40))
        try page(in: model, saying: longPage(lines: 40))
        try select(first, in: model)
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: spreadOverDays(model, selecting: first),
                          selectedPage: first, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let storage = editor.textStorage
        let offset = NSPoint(x: 200, y: 0)
        scroll(roll, to: offset)
        XCTAssertNotNil(roll.stack.currentPlace)
        try page(in: model, saying: longPage(lines: 30))
        try select(first, in: model)
        for days in [[-1, -2, 0], [-2, 0, -1], [0, -1, -2]] {
            roll.stack.update(
                projection: TimeUnitProjection.project(
                    tabs: filed(model, under: days), selectedPageID: first, unit: .day),
                selectedPage: first, readOnly: false)
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, 0, accuracy: 0.5)
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, offset.x, accuracy: 0.5)
            XCTAssertTrue(roll.stack.editor === editor)
            XCTAssertTrue(editor.textStorage === storage)
        }
    }

    /// The capture and the restore read one rule, so a reader on the first day scrolled only
    /// sideways gets the column back after a wrap round trip, as a reader further down does.
    func testAFirstDayReaderScrolledOnlySidewaysGetsTheColumnBackAfterAWrapRoundTrip() throws {
        for belowTop in [false, true] {
            let model = try makeModel()
            model.wrapsLines = false
            let first = try page(in: model, saying: longLine(repetitions: 40) + "\n" + longPage(lines: 80))
            try page(in: model, saying: longPage(lines: 40))
            try select(first, in: model)
            let roll = try mountRoll(model: model)
            let projection = spreadOverDays(model, selecting: first)
            roll.stack.update(projection: projection, selectedPage: first, readOnly: false)
            let start = NSPoint(x: 200, y: belowTop ? 120 : 0)
            scroll(roll, to: start)
            XCTAssertEqual(roll.stack.currentPlace?.page, first)
            let label = belowTop ? "below the top" : "at the top"
            for wraps in [true, false, true, false] {
                model.wrapsLines = wraps
                roll.stack.update(projection: projection, selectedPage: first, readOnly: false)
                if !belowTop { XCTAssertEqual(roll.scroll.contentView.bounds.minY, 0, accuracy: 0.5, label) }
                if wraps { XCTAssertEqual(roll.scroll.contentView.bounds.minX, 0, accuracy: 0.5, label) }
            }
            XCTAssertEqual(roll.scroll.contentView.bounds.minX, start.x, accuracy: 0.5, label)
            XCTAssertEqual(roll.scroll.contentView.bounds.minY, start.y, accuracy: 0.5, label)
        }
    }

    /// The pure half of that rule, and the one place it deliberately
    /// does nothing: a reader at the origin is looking at the top of the
    /// roll, and the top of the roll is where the new day now is.
    func testTheAnchorArithmeticHoldsTheReaderAndNotTheOrigin() {
        XCTAssertEqual(
            DayStackView.offsetAfterPrepending(
                insertedHeight: 64, current: NSPoint(x: 0, y: 300)
            ),
            NSPoint(x: 0, y: 364)
        )
        XCTAssertEqual(
            DayStackView.offsetAfterPrepending(insertedHeight: 64, current: .zero),
            .zero,
            "a reader at the top of the roll must be shown the day that arrived there"
        )
        XCTAssertEqual(
            DayStackView.offsetAfterPrepending(
                insertedHeight: 0, current: NSPoint(x: 0, y: 300)
            ),
            NSPoint(x: 0, y: 300),
            "nothing arrived, so nothing moves"
        )
        XCTAssertEqual(
            DayStackView.offsetAfterPrepending(
                insertedHeight: -20, current: NSPoint(x: 0, y: 300)
            ),
            NSPoint(x: 0, y: 300),
            "a day that went is not a day that arrived"
        )
    }

    // MARK: What a second pass costs

    /// `refresh()` runs on every accepted edit batch, so the pass that a
    /// keystroke buys has to be a measurement and not an assembly.
    func testTwoIdenticalPassesRebuildNoSubviews() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        let projection = spreadOverDays(model, selecting: first)

        roll.stack.update(projection: projection, selectedPage: first, readOnly: false)
        let assembled = roll.stack.rebuilds
        let subviews = roll.stack.subviews
        roll.stack.update(projection: projection, selectedPage: first, readOnly: false)

        XCTAssertEqual(roll.stack.rebuilds, assembled, "the same days were assembled twice")
        XCTAssertEqual(roll.stack.subviews.count, subviews.count)
        for (before, after) in zip(subviews, roll.stack.subviews) {
            XCTAssertTrue(before === after, "a region was thrown away and re-made for nothing")
        }
    }

    // MARK: One editor, one manager per storage

    /// The invariant ADR-0006 rests on, asserted with three days
    /// mounted and one of them the editor: every storage in the app has
    /// exactly one layout manager, because each has exactly one view.
    func testEveryStorageCarriesExactlyOneLayoutManagerWithThreeDaysMounted() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        try page(in: model, saying: "yesterday")
        try page(in: model, saying: "the day before")
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        XCTAssertEqual(
            model.storage(for: first).layoutManagers.count, 1,
            "a second manager over the live page would let a stale view render it mid-edit"
        )
        XCTAssertEqual(roll.stack.quietRegions.count, 2, "two days are quiet")
        for region in roll.stack.quietRegions.values {
            XCTAssertEqual(region.textStorage?.layoutManagers.count, 1)
            XCTAssertNil(
                region.textStorage?.delegate,
                "a rendering with a delegate would emit ops for a page nobody is typing on"
            )
        }
    }

    // MARK: The day switch

    /// The whole reason the editor is a permanent child: a day switch
    /// moves a frame, not a view. The same instance stays in the stack,
    /// stays first responder, and comes out over the new page.
    func testADaySwitchMovesTheEditorsFrameAndNotTheEditor() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        let second = try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )
        let editor = try XCTUnwrap(roll.stack.editor)
        let wasAt = editor.frame.origin
        XCTAssertTrue(roll.window.makeFirstResponder(editor))

        roll.stack.update(
            projection: spreadOverDays(model, selecting: second),
            selectedPage: second,
            readOnly: false
        )

        XCTAssertTrue(roll.stack.editor === editor, "the editor was re-made for a day switch")
        XCTAssertTrue(editor.superview === roll.stack, "the editor was re-parented")
        XCTAssertTrue(
            roll.window.firstResponder === editor,
            "the keyboard was dropped crossing a perforation (issues #22, #23)"
        )
        XCTAssertNotEqual(editor.frame.origin.y, wasAt.y, "the editor did not move at all")
        XCTAssertEqual(roll.coordinator.currentSheet, second)
        XCTAssertTrue(editor.textStorage === model.storage(for: second))
        XCTAssertEqual(
            Set(roll.stack.quietRegions.keys), [first],
            "the day the editor left is quiet again, and the day it went to is not"
        )
    }

    /// A quiet day is not somewhere the keyboard can go. There is one
    /// focusable text view in the card, and the editor is it.
    func testAQuietDayRefusesFirstResponder() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        let second = try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )

        let quiet = try XCTUnwrap(roll.stack.quietRegions[second])
        XCTAssertFalse(quiet.acceptsFirstResponder)
        XCTAssertFalse(quiet.isEditable, "a quiet day must not take a keystroke")
        XCTAssertFalse(quiet.isSelectable)
        XCTAssertFalse(quiet.becomeFirstResponder(), "a rendering agreed to take the keyboard")

        // And asked anyway, the way a stray hand-off would ask. What the
        // call answers is not the law: AppKit documents
        // `makeFirstResponder` as returning true even when the responder
        // refuses, because the window takes the status itself in that
        // case. Where the keyboard ends up is the law, and it never ends
        // up on a rendering.
        _ = roll.window.makeFirstResponder(quiet)

        XCTAssertFalse(
            roll.window.firstResponder === quiet,
            "the window handed the keyboard to a rendering"
        )
    }

    /// Click into history and you land where you clicked: the page under
    /// the pointer becomes the selected one, and the caret is at the
    /// character the pointer was over rather than at the top of the day.
    func testAClickInAQuietDayPromotesItAndPlacesTheCaretWhereItLanded() throws {
        let model = try makeModel()
        let first = try page(in: model, saying: "today")
        let second = try page(in: model, saying: "yesterday's longer line of writing")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: first),
            selectedPage: first,
            readOnly: false
        )
        let quiet = try XCTUnwrap(roll.stack.quietRegions[second])
        let landing = NSPoint(x: 60, y: quiet.textContainerInset.height + 4)
        let expected = quiet.characterIndexForInsertion(at: landing)
        XCTAssertGreaterThan(expected, 0, "the fixture has to click into the ink, not before it")

        quiet.clicked(at: landing)

        XCTAssertEqual(
            model.selectedPageID, second,
            "a click into an older day did not take the user there"
        )
        // The swap itself happens on the pass the selection publishes.
        roll.stack.update(
            projection: spreadOverDays(model, selecting: second),
            selectedPage: second,
            readOnly: false
        )
        XCTAssertEqual(try XCTUnwrap(roll.stack.editor).selectedRange().location, expected)
    }

    // MARK: Today with nothing on it

    /// Day 0 is a place and not a page: an empty pad draws one row, the
    /// shipped empty state fills the card, and nothing is minted by any
    /// of it (ADR-0017).
    func testAnEmptyTodayDrawsTheEmptyStateAndMintsNothing() throws {
        let model = try makeModel()
        let roll = try mountRoll(model: model)
        XCTAssertTrue(model.tabs.isEmpty)

        roll.stack.update(
            projection: TimeUnitProjection.project(
                tabs: [], selectedPageID: nil, unit: .day
            ),
            selectedPage: nil,
            readOnly: false
        )

        XCTAssertTrue(model.tabs.isEmpty, "drawing today minted a page")
        XCTAssertNil(roll.stack.editor, "there is no page, so there is no editor to build")
        let parts = roll.stack.laidOut
        XCTAssertEqual(parts.count, 1)
        let empty = try XCTUnwrap(parts[0].body as? EmptyTodayView)
        XCTAssertEqual(empty.lead.stringValue, "No page here yet.")
        XCTAssertEqual(empty.hint.stringValue, "click, ⌃⌥Space, or ↩ to start one")
        XCTAssertEqual(parts[0].header.mark, DayHeaderView.Mark.none)
        XCTAssertEqual(
            parts[0].body.frame.maxY,
            roll.scroll.contentView.bounds.height,
            accuracy: 0.5,
            "the empty state is the surface at that moment, not a caption at the top of it"
        )
    }

    /// The one click on the roll that makes anything: today's place is
    /// where today's page starts. It goes through `openToday()`, the
    /// same gesture ⌘N takes in this mode, so a second click finds
    /// today holding a page and selects it rather than stacking a blank
    /// one on top of it (ADR-0017).
    func testClickingTodaysEmptyPlaceStartsTodaysPageAndOnlyOne() throws {
        let model = try makeModel()
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: TimeUnitProjection.project(
                tabs: [], selectedPageID: nil, unit: .day
            ),
            selectedPage: nil,
            readOnly: false
        )
        let place = try XCTUnwrap(roll.stack.laidOut.first?.body as? EmptyTodayView)

        place.grant.onCreate?(roll.window)

        XCTAssertEqual(model.tabs.count, 1, "the click into today made nothing")
        XCTAssertNotNil(model.selectedPageID)

        place.grant.onCreate?(roll.window)

        XCTAssertEqual(model.tabs.count, 1, "a second click stacked a second blank page")
    }

    /// The last page expires and the roll has nothing to show. The
    /// editor stays a child of the stack (it is never re-parented) but
    /// it stops standing over a page, and the ink of the page that died
    /// goes with it.
    func testTheLastPageExpiringLeavesNoInkOnScreen() throws {
        let model = try makeModel()
        let only = try page(in: model, saying: "the credentials")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: only),
            selectedPage: only,
            readOnly: false
        )
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertGreaterThan(editor.textStorage?.length ?? 0, 0)

        model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        roll.stack.update(
            projection: model.timeUnits, selectedPage: model.selectedPageID, readOnly: false
        )

        XCTAssertTrue(roll.stack.editor === editor, "the editor was torn out rather than parked")
        XCTAssertTrue(editor.superview === roll.stack)
        XCTAssertEqual(
            editor.textStorage?.length, 0,
            "the expired page is still legible in a view nobody can see the frame of"
        )
        XCTAssertNil(model.activeEditor, "a hand-off would settle on an editor with no page")
        XCTAssertEqual(editor.frame.height, 0)
    }

    // MARK: The gutter's verbs

    func testReassigningAPooledHeaderCancelsItsRenameWithoutRenamingTheReplacement() throws {
        let model = try makeModel()
        try page(in: model, saying: "")
        let firstID = try XCTUnwrap(model.selection)
        model.renameTab(firstID, to: "first page")
        try page(in: model, saying: "")
        let secondID = try XCTUnwrap(model.selection)
        model.renameTab(secondID, to: "second page")
        let first = try XCTUnwrap(model.tabs.first { $0.id == firstID })
        let second = try XCTUnwrap(model.tabs.first { $0.id == secondID })
        let header = DayHeaderView(model: model)
        header.show(
            words: DayHeaderView.words(spokenLabel: "today", stamp: nil),
            spokenLabel: "today", mark: .none, summary: first)

        header.beginRename()
        header.renameDraft = "draft for first"
        header.refresh(summary: second)
        header.endRename(committed: true)

        XCTAssertEqual(model.tabs.first { $0.id == firstID }?.title, "first page")
        XCTAssertEqual(model.tabs.first { $0.id == secondID }?.title, "second page")
        XCTAssertEqual(header.renameDraft, "second page")
    }

    /// The gutter's day, time and name share one colour: ink on the
    /// active page, the secondary ink elsewhere, so a name never
    /// reads dimmer than its time and none of them wears tertiary.
    func testAGuttersWordsWearInkWhenActiveAndTheSecondaryInkOtherwise() throws {
        let model = try makeModel()
        let header = DayHeaderView(model: model)
        let secondary = Array(repeating: NSColor.secondaryInk as NSColor?, count: 3)
        XCTAssertEqual(header.wordColors, secondary)
        header.isActive = true
        XCTAssertEqual(header.wordColors, Array(repeating: NSColor.labelColor as NSColor?, count: 3))
        header.isActive = false
        XCTAssertEqual(header.wordColors, secondary)
    }

    /// A gutter's title field is drawn for a typed name and for the
    /// length of a rename, and for nothing else: a placeholder and a
    /// first line are both said already, beside or under the gutter.
    /// The gauge that stood at the gutter's trailing edge is gone; the
    /// countdown is still spoken.
    func testAGutterDrawsATypedNameAndNoGauge() throws {
        let model = try makeModel()
        try page(in: model, saying: "")
        let tabID = try XCTUnwrap(model.selection)
        let placeholder = try XCTUnwrap(model.tabs.first { $0.id == tabID })
        XCTAssertEqual(placeholder.titleSource, .placeholder)
        let header = DayHeaderView(model: model)
        header.show(
            words: DayHeaderView.words(spokenLabel: "today", stamp: "11:39"),
            spokenLabel: "today", mark: .none, summary: placeholder)
        XCTAssertFalse(header.titleIsDrawn, "a placeholder title was drawn beside its own stamp")
        XCTAssertTrue(
            header.subviews.allSatisfy { $0 is NSTextField || $0 is NSButton },
            "the gutter hosts something besides its words and preview toggle: \(header.subviews)")
        XCTAssertEqual(
            header.accessibilityLabel(),
            DayHeaderView.spokenHeader(
                spokenLabel: "today", title: placeholder.title,
                remainingLabel: placeholder.remainingLabel),
            "the countdown stopped being spoken when the gauge went")

        try page(in: model, saying: "deploy notes\nthe rest")
        let derived = try XCTUnwrap(model.tabs.first { $0.id == model.selection })
        XCTAssertEqual(derived.titleSource, .derived)
        header.show(
            words: DayHeaderView.words(spokenLabel: "today", stamp: "11:40", firstOfDay: false),
            spokenLabel: "today", mark: .hairline, summary: derived)
        XCTAssertFalse(header.titleIsDrawn, "a first line was drawn above itself")

        header.beginRename()
        XCTAssertTrue(header.titleIsDrawn, "the rename had no field to type into")
        XCTAssertEqual(header.renameDraft, "11:40", "the draft is the time the seat showed")
        header.endRename(committed: false)
        XCTAssertFalse(header.titleIsDrawn, "a let-go rename left the field up")

        model.renameTab(derived.id, to: "the vault")
        let named = try XCTUnwrap(model.tabs.first { $0.id == derived.id })
        XCTAssertEqual(named.titleSource, .name)
        header.refresh(summary: named)
        XCTAssertTrue(header.titleIsDrawn, "a typed name was not drawn")
        XCTAssertEqual(header.renameDraft, "the vault")
    }

    /// One click at a point in a mounted header, routed the way AppKit
    /// routes it: the stack's hit test picks the view, which gets the event.
    private func click(_ header: DayHeaderView, at local: NSPoint, in roll: Roll) throws {
        let inStack = header.convert(local, to: roll.stack)
        let hit = try XCTUnwrap(roll.stack.hitTest(roll.stack.convert(inStack, to: roll.stack.superview)))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: roll.stack.convert(inStack, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: roll.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        hit.mouseDown(with: event)
    }

    /// A click on the time opens the field on the time, selected whole, and
    /// the time slides right; a click on the day focuses the page (Law 0007).
    func testAClickOnTheGutterTimeOpensTheFieldAndOnTheDayFocuses() async throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "first line\nsecond line")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let time = header.timeText
        XCTAssertFalse(time.isEmpty, "the page's gutter has no time to click")
        XCTAssertEqual(header.reading, "today · \(time)")

        _ = roll.window.makeFirstResponder(nil)
        let timeFrame = header.timeFrame
        try click(header, at: NSPoint(x: timeFrame.midX, y: timeFrame.midY), in: roll)
        await settle()
        XCTAssertTrue(header.isRenaming, "a click on the time did not open the field")
        XCTAssertEqual(header.renameDraft, time, "the field did not open on the time the seat showed")
        XCTAssertEqual(header.reading, "today · \(time) · \(time)", "the time did not slide right")
        let field = try XCTUnwrap(roll.window.firstResponder as? NSTextView)
        XCTAssertEqual(
            field.selectedRange(), NSRange(location: 0, length: (time as NSString).length),
            "the draft was not selected whole")

        header.endRename(committed: true)
        XCTAssertEqual(
            model.tabs.first?.titleSource, .derived, "an untouched Return froze the time into a name")
        XCTAssertEqual(header.reading, "today · \(time)")

        try click(header, at: NSPoint(x: 20, y: timeFrame.midY), in: roll)
        await settle()
        XCTAssertFalse(header.isRenaming, "a click on the day opened the field")
        XCTAssertTrue(roll.window.firstResponder === editor, "a click on the day did not focus the page")
    }

    /// A named gutter reads the day, the name and the time on screen, a later
    /// page the name and the time; an empty Return gives the seat back.
    func testANamedGutterReadsTheDayTheNameAndTheTime() throws {
        let model = try makeModel()
        _ = try page(in: model, saying: "one")
        model.renameTab(try XCTUnwrap(model.selection), to: "Deploy notes")
        let second = try page(in: model, saying: "two")
        model.renameTab(try XCTUnwrap(model.selection), to: "Rotate keys")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: second, readOnly: false)
        let headers = roll.stack.laidOut.map(\.header)
        XCTAssertEqual(headers.count, 2)
        let names = try headers.map { header in
            try XCTUnwrap(model.tabs.first { $0.pageID == header.pageIdentity }?.title)
        }
        XCTAssertEqual(headers[0].reading, "today · \(names[0]) · \(headers[0].timeText)")
        XCTAssertEqual(headers[1].reading, "\(names[1]) · \(headers[1].timeText)")

        headers[1].beginRename()
        XCTAssertEqual(headers[1].renameDraft, names[1], "a named seat did not open on its name")
        headers[1].renameDraft = ""
        headers[1].endRename(committed: true)
        XCTAssertNotEqual(
            model.tabs.first { $0.pageID == headers[1].pageIdentity }?.titleSource, .name,
            "an empty Return kept the name")
        XCTAssertEqual(headers[1].reading, headers[1].timeText, "the time does not stand alone again")
    }

    /// A typed name stands in the time's seat, so a click on it or on the
    /// time beside it opens the field on the name (Law 0007, the gutter's row).
    func testAClickOnATypedNameOrItsTimeOpensTheFieldOnTheName() async throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "writing")
        model.renameTab(try XCTUnwrap(model.selection), to: "Deploy notes")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let name = try XCTUnwrap(
            header.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Deploy notes" })
        let time = header.timeFrame

        for point in [NSPoint(x: name.frame.midX, y: name.frame.midY), NSPoint(x: time.midX, y: time.midY)] {
            XCTAssertTrue(roll.window.makeFirstResponder(editor))
            try click(header, at: point, in: roll)
            await settle()
            XCTAssertTrue(header.isRenaming, "a click at \(point) did not open the field")
            XCTAssertEqual(header.renameDraft, "Deploy notes", "the field did not open on the name")
            let fieldEditor = try XCTUnwrap(roll.window.firstResponder as? NSTextView)
            fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            await settle()
            XCTAssertFalse(header.isRenaming)
            XCTAssertEqual(header.reading, "today · Deploy notes · \(header.timeText)")
        }
    }

    /// A long name on a narrow card gives way before the time, which keeps
    /// its whole width inside the gutter, at rest and with the field open.
    func testALongNameOnANarrowGutterLeavesTheTimeWhole() throws {
        let model = try makeModel()
        _ = try page(in: model, saying: "writing")
        let tab = try XCTUnwrap(model.selection)
        model.renameTab(tab, to: String(repeating: "Deploy notes ", count: 6))
        let summary = try XCTUnwrap(model.tabs.first { $0.id == tab })
        let long = summary.title
        let header = DayHeaderView(model: model)
        header.show(
            words: DayHeaderView.words(spokenLabel: "today", stamp: "13:00"),
            spokenLabel: "today", mark: .none, summary: summary)
        let name = try XCTUnwrap(
            header.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == long })

        func laidOut(width: CGFloat) -> (time: NSRect, name: NSRect) {
            header.frame = NSRect(x: 0, y: 0, width: width, height: DayHeaderView.gutterHeight)
            header.place()
            return (header.timeFrame, name.frame)
        }
        let wide = laidOut(width: 2_000)
        XCTAssertGreaterThan(wide.time.width, 0)
        for renaming in [false, true] {
            if renaming { header.beginRename() }
            let narrow = laidOut(width: 240)
            XCTAssertEqual(narrow.time.width, wide.time.width, accuracy: 0.5, "the time was clipped")
            XCTAssertLessThanOrEqual(narrow.time.maxX, header.bounds.maxX, "the time left the gutter")
            XCTAssertLessThan(narrow.name.width, wide.name.width, "the name did not give way")
            XCTAssertLessThanOrEqual(narrow.name.maxX, narrow.time.minX, "the name ran over the time")
        }
        header.endRename(committed: false)
    }

    /// The label is the slot's name, which outlives its page (ADR-0017),
    /// so a page minted into a labelled empty slot reads the label.
    func testAPageMintedIntoALabelledSlotReadsTheSlotsLabel() throws {
        let model = try makeModel()
        _ = try page(in: model, saying: "first")
        let tab = try XCTUnwrap(model.selection)
        model.renameTab(tab, to: "Deploy notes")
        model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        XCTAssertNil(model.selectedPageID, "the page outlived its clock")

        model.select(tab)
        let minted = try XCTUnwrap(model.selectedPageID, "selecting the empty slot minted nothing")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: minted, readOnly: false)
        let header = try XCTUnwrap(roll.stack.laidOut.first { $0.header.pageIdentity == minted }?.header)
        XCTAssertEqual(header.reading, "today · Deploy notes · \(header.timeText)")
    }

    /// A field opened while another field holds the keys gives them back to
    /// the page on Escape and Return, not to the lent field editor (Law 0007).
    func testAFieldOpenedOverAnotherGivesTheKeysBackToThePage() async throws {
        let model = try makeModel()
        try page(in: model, saying: "first")
        let second = try page(in: model, saying: "second")
        let endings = [
            #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:)),
        ]
        for ending in endings {
            let roll = try mountRoll(model: model)
            roll.stack.update(projection: model.timeUnits, selectedPage: second, readOnly: false)
            let editor = try XCTUnwrap(roll.stack.editor)
            XCTAssertTrue(roll.window.makeFirstResponder(editor))
            let headers = roll.stack.laidOut.map(\.header)
            XCTAssertEqual(headers.count, 2)
            for header in headers {
                let time = header.timeFrame
                try click(header, at: NSPoint(x: time.midX, y: time.midY), in: roll)
                await settle()
            }
            XCTAssertFalse(headers[0].isRenaming, "the first field outlived the second's opening")
            XCTAssertTrue(headers[1].isRenaming, "a click on the second time opened nothing")
            let fieldEditor = try XCTUnwrap(roll.window.firstResponder as? NSTextView)
            XCTAssertTrue(fieldEditor.isFieldEditor)

            fieldEditor.doCommand(by: ending)
            await settle()
            XCTAssertFalse(headers[1].isRenaming, "\(ending) left the field open")
            XCTAssertTrue(
                roll.window.firstResponder === editor,
                "\(ending) left the keys with \(String(describing: roll.window.firstResponder))")
        }
    }

    /// While the gutter's field holds the keys the page's ⌘Z and the Edit
    /// menu's actions stand aside for the draft (Law 0007, keys row).
    func testTheGuttersFieldTakesThePagesChordsAndMenuAway() throws {
        let model = try makeModel()
        let selected = try page(in: model, saying: "first line")
        let roll = try mountRoll(model: model)
        roll.stack.update(projection: model.timeUnits, selectedPage: selected, readOnly: false)
        let editor = try XCTUnwrap(roll.stack.editor)
        XCTAssertTrue(roll.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertText(" more", replacementRange: NSRange(location: NSNotFound, length: 0))
        func ink() -> String {
            model.coreClient.documentRuns(sheet: selected).reduce(into: "") {
                if case .ink(let ink) = $1 { $0 += ink }
            }
        }
        XCTAssertEqual(ink(), "first line more")
        XCTAssertTrue(model.canUndoEdit(sheet: selected), "the fixture has nothing to step")
        drainMainQueue()
        XCTAssertTrue(model.languageActions.canPaste, "the control: the page answers the menu")

        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        header.beginRename()
        let fieldEditor = try XCTUnwrap(roll.window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        drainMainQueue()
        XCTAssertFalse(editor.answersChords, "the page kept its chords under the gutter's draft")
        let undo = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: roll.window.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertFalse(editor.performKeyEquivalent(with: undo), "the page took ⌘Z from the gutter")
        XCTAssertEqual(ink(), "first line more", "⌘Z stepped the page under the gutter's draft")
        for action in pageMenuActions {
            XCTAssertFalse(
                answerer(of: action, in: roll.window) is InkTextView,
                "\(action) reached the page from the gutter's field")
        }
        XCTAssertFalse(model.languageActions.canPaste, "the menu offered the page's paste")
        XCTAssertFalse(model.sealActions.canSeal)

        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        drainMainQueue()
        XCTAssertTrue(roll.window.firstResponder === editor)
        XCTAssertTrue(editor.answersChords)
        XCTAssertTrue(model.languageActions.canPaste, "the menu did not come back to the page")
    }

    func testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft() throws {
        let model = try makeModel()
        try page(in: model, saying: "")
        let tabID = try XCTUnwrap(model.selection)
        model.renameTab(tabID, to: "original title")
        let summary = try XCTUnwrap(model.tabs.first { $0.id == tabID })
        let header = DayHeaderView(model: model)
        header.show(
            words: DayHeaderView.words(spokenLabel: "today", stamp: nil),
            spokenLabel: "today", mark: .none, summary: summary)

        header.beginRename()
        header.renameDraft = "visible draft"

        let expected = DayHeaderView.spokenHeader(
            spokenLabel: "today",
            title: "visible draft",
            remainingLabel: summary.remainingLabel
        )
        XCTAssertEqual(header.accessibilityLabel(), expected)

        header.refresh(summary: summary)
        XCTAssertEqual(
            header.accessibilityLabel(), expected,
            "a projection refresh replaced the spoken draft with the saved title"
        )
    }

    /// A pattern edited in Settings publishes back into an unchanged
    /// projection: the roll rebuilds nothing (Greptile P1 #1) but the
    /// mounted headers must still say the new pattern's stamp, because
    /// the assembly pass is where the old code put the gutter's words.
    /// The ordinary pass has to move them now.
    func testAStampFormatEditRolls_MountedGuttersWithoutRebuilding() throws {
        let model = try makeModel()
        let only = try page(in: model, saying: "credentials")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: only),
            selectedPage: only,
            readOnly: false
        )
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let before = header.timeText
        let rebuildsBefore = roll.stack.rebuilds

        model.stampFormat = StreamNavigator.StampFormat(short: "h:mm a", fine: "h:mm:ss a")
        // The same signature is the point: the roll's structure did
        // not change, only the reading of its stamps did.
        roll.stack.update(
            projection: spreadOverDays(model, selecting: only),
            selectedPage: only,
            readOnly: false
        )

        XCTAssertEqual(
            roll.stack.rebuilds, rebuildsBefore,
            "the roll rebuilt when no structural fact changed"
        )
        XCTAssertNotEqual(
            header.timeText, before,
            "the mounted gutter kept the old pattern's stamp across a settings edit"
        )
        XCTAssertTrue(
            header.timeText.hasSuffix("AM") || header.timeText.hasSuffix("PM"),
            "the new pattern's meridiem is missing from the gutter: \(header.timeText)"
        )
        XCTAssertTrue(
            header.reading.hasSuffix(header.timeText),
            "the time is not the last word the gutter draws: \(header.reading)"
        )
    }

    /// The titles the strip's context menu offers a slot with a page,
    /// in its order (TabStripView.swift, `SheetTab.contextMenu`). That
    /// menu is SwiftUI and cannot be walked, so its literal titles are
    /// restated here; a verb added to one side and not the other fails
    /// this list rather than going unnoticed.
    private func stripMenuTitles(model: PageModel, tab: TabSummary) -> [String] {
        var titles = [
            "Rename Tab",
            SheetTab.holdMenuTitle(paused: tab.paused, toppedUp: tab.holdToppedUp),
            SheetTab.rungMenuTitle(hasPage: tab.hasPage),
        ]
        if model.sync.enabled, let pageID = tab.pageID {
            titles.append(SheetTab.syncMenuTitle(enrolled: model.sync.isEnrolled(pageID)))
        }
        titles.append("Close Tab")
        return titles
    }

    /// A right click on the header, which the menu never reads beyond
    /// its arrival.
    private func rightClick(in roll: Roll) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: roll.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    /// The day gutter is the strip's context menu verb for verb (D-13),
    /// with the sync enrol item appearing on both only while the switch
    /// is on. The one difference is the noun: a slot on the strip is a
    /// tab, and on the roll it is a page under a day, so the gutter's
    /// titles are compared with that word put back.
    func testTheDayGutterOffersTheSameVerbsAsTheStrip() throws {
        let model = try makeModel()
        let only = try page(in: model, saying: "the credentials")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: only),
            selectedPage: only,
            readOnly: false
        )
        let header = try XCTUnwrap(roll.stack.laidOut.first?.header)
        let tab = try XCTUnwrap(model.tabs.first)
        let click = try rightClick(in: roll)

        for enabled in [false, true] {
            model.sync.enabled = enabled
            let gutter = try XCTUnwrap(header.menu(for: click)).items.map(\.title)
            XCTAssertFalse(
                gutter.contains { $0.lowercased().contains("tab") },
                "a day gutter that says tab is naming the strip's object, not its own: \(gutter)"
            )
            XCTAssertEqual(
                gutter.map { $0 == "Rename Page" ? "Rename Tab" : $0 }
                    .map { $0 == "Close Page" ? "Close Tab" : $0 },
                stripMenuTitles(model: model, tab: tab),
                "with sync \(enabled ? "on" : "off") the gutter and the strip disagree"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(header.menu(for: click)).items.count, 5,
            "with sync on the gutter carries the four gated verbs and the enrol item"
        )
    }
}
