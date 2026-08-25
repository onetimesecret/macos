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
            pageDayOffset: day
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
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "⌃⌥Space to raise the card"
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

    private func longPage(lines: Int) -> String {
        (0..<lines).map { "line \($0) of a day that goes on" }.joined(separator: "\n")
    }

    // MARK: The shape of the stack

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
        XCTAssertTrue(parts[0].body is EmptyTodayView)
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
}
