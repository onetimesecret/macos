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
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-day-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        return model
    }

    /// A page with something on it, minted by the shipped gesture. The
    /// ink goes in through the core's own restate rather than through a
    /// keystroke, because what these tests need is a document with a
    /// known length, not an emitter under test.
    @discardableResult
    private func page(in model: PageModel, saying ink: String) throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        let escaped = ink.replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(model.coreClient.syncDocument(
            sheet: page, json: "[{\"ink\": \"\(escaped)\"}]"
        ))
        model.refresh()
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

    /// The roll in a card-sized window, built exactly as the surface
    /// builds it.
    private func mountRoll(model: PageModel, height: CGFloat = 320) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        coordinator.surface = model.owner
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator,
            emptyHint: "click, ⌃⌥Space, or ↩ to start one"
        )
        let card = NSRect(x: 0, y: 0, width: 420, height: height)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
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

    // MARK: The shape of the stack

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

    private func leftClick(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
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
        model.newPage()
        let firstID = try XCTUnwrap(model.selection)
        model.renameTab(firstID, to: "first page")
        model.newPage()
        let secondID = try XCTUnwrap(model.selection)
        model.renameTab(secondID, to: "second page")
        let first = try XCTUnwrap(model.tabs.first { $0.id == firstID })
        let second = try XCTUnwrap(model.tabs.first { $0.id == secondID })
        let header = DayHeaderView(model: model)
        header.show(dayText: "today", spokenLabel: "today", mark: .none, summary: first)

        header.beginRename()
        header.renameDraft = "draft for first"
        header.refresh(summary: second)
        header.endRename(committed: true)

        XCTAssertEqual(model.tabs.first { $0.id == firstID }?.title, "first page")
        XCTAssertEqual(model.tabs.first { $0.id == secondID }?.title, "second page")
        XCTAssertEqual(header.renameDraft, "second page")
    }

    /// A gutter's title field is drawn for a typed name and for the
    /// length of a rename, and for nothing else: a placeholder and a
    /// first line are both said already, beside or under the gutter.
    /// The gauge that stood at the gutter's trailing edge is gone; the
    /// countdown is still spoken.
    func testAGutterDrawsATypedNameAndNoGauge() throws {
        let model = try makeModel()
        model.newPage()
        let tabID = try XCTUnwrap(model.selection)
        let placeholder = try XCTUnwrap(model.tabs.first { $0.id == tabID })
        XCTAssertEqual(placeholder.titleSource, .placeholder)
        let header = DayHeaderView(model: model)
        header.show(dayText: "today · 11:39", spokenLabel: "today", mark: .none, summary: placeholder)
        XCTAssertFalse(header.titleIsDrawn, "a placeholder title was drawn beside its own stamp")
        XCTAssertTrue(
            header.subviews.allSatisfy { $0 is NSTextField },
            "the gutter hosts something besides its words: \(header.subviews)")
        XCTAssertEqual(
            header.accessibilityLabel(),
            DayHeaderView.spokenHeader(
                spokenLabel: "today", title: placeholder.title,
                remainingLabel: placeholder.remainingLabel),
            "the countdown stopped being spoken when the gauge went")

        try page(in: model, saying: "deploy notes\nthe rest")
        let derived = try XCTUnwrap(model.tabs.first { $0.id == model.selection })
        XCTAssertEqual(derived.titleSource, .derived)
        header.show(dayText: "11:40", spokenLabel: "today", mark: .hairline, summary: derived)
        XCTAssertFalse(header.titleIsDrawn, "a first line was drawn above itself")

        header.beginRename()
        XCTAssertTrue(header.titleIsDrawn, "the rename had no field to type into")
        XCTAssertEqual(header.renameDraft, "deploy notes")
        header.endRename(committed: false)
        XCTAssertFalse(header.titleIsDrawn, "a let-go rename left the field up")

        model.renameTab(derived.id, to: "the vault")
        let named = try XCTUnwrap(model.tabs.first { $0.id == derived.id })
        XCTAssertEqual(named.titleSource, .name)
        header.refresh(summary: named)
        XCTAssertTrue(header.titleIsDrawn, "a typed name was not drawn")
        XCTAssertEqual(header.renameDraft, "the vault")
    }

    func testAHeaderAccessibilityLabelUsesTheVisibleRenameDraft() throws {
        let model = try makeModel()
        model.newPage()
        let tabID = try XCTUnwrap(model.selection)
        model.renameTab(tabID, to: "original title")
        let summary = try XCTUnwrap(model.tabs.first { $0.id == tabID })
        let header = DayHeaderView(model: model)
        header.show(dayText: "today", spokenLabel: "today", mark: .none, summary: summary)

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
    /// the assembly pass is where the old code put dayText. The
    /// ordinary pass has to move it now.
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
        let before = header.dayText
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
            header.dayText, before,
            "the mounted gutter kept the old pattern's stamp across a settings edit"
        )
        XCTAssertTrue(
            header.dayText.hasSuffix("AM") || header.dayText.hasSuffix("PM"),
            "the new pattern's meridiem is missing from the gutter: \(header.dayText)"
        )
    }

    /// The titles the strip's context menu offers a slot with a page,
    /// in its order (TabStripView.swift, `SheetTab.contextMenu`). That
    /// menu is SwiftUI and cannot be walked, so its literal titles are
    /// restated here; a verb added to one side and not the other fails
    /// this list rather than going unnoticed.
    private func stripMenuTitles(model: PageModel, tab: TabSummary) -> [String] {
        var titles = [
            "Rename tab…",
            SheetTab.holdMenuTitle(paused: tab.paused, toppedUp: tab.holdToppedUp),
            SheetTab.rungMenuTitle(hasPage: tab.hasPage),
        ]
        if model.sync.enabled, let pageID = tab.pageID {
            titles.append(SheetTab.syncMenuTitle(enrolled: model.sync.isEnrolled(pageID)))
        }
        titles.append("Close tab")
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
                gutter.contains { $0.contains("tab") },
                "a day gutter that says tab is naming the strip's object, not its own: \(gutter)"
            )
            XCTAssertEqual(
                gutter.map { $0.replacingOccurrences(of: "page…", with: "tab…") }
                    .map { $0 == "Close page" ? "Close tab" : $0 },
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
