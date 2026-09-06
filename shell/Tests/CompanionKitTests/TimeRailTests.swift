import XCTest

@testable import CompanionKit

/// What the rail says and where a click on it lands (issue #79).
///
/// A rail is a drawing, and drawings are hardware verification's
/// business (docs/qa/hardware-verification.md). What is here is everything
/// that was deliberately kept out of the drawing: the target a tap
/// resolves to, the day the selected mark sits on, the words in each
/// tooltip and the footer's count are all pure functions, in the idiom
/// `TabStripView.newPageHelp` and `SheetTab.holdMenuTitle` set. If one
/// of them is wrong the rail sends a click to the wrong page or names a
/// chord that does nothing, and neither needs a window to catch.
@MainActor
final class TimeRailTests: XCTestCase {
    /// One row of the strip, as `companion_tabs_json` would describe it.
    /// A slot holding no page reports no day and no content, which is
    /// the seam's rule rather than this helper's convenience.
    private func slot(
        tab: UInt64,
        page: UInt64? = nil,
        day: Int = 0,
        content: Bool = true
    ) -> TabSummary {
        TabSummary(
            id: tab,
            hasPage: page != nil,
            pageID: page,
            title: "slot \(tab)",
            rungCode: 5,
            rungLabel: "7d",
            remainingMs: page == nil ? 0 : 3_600_000,
            remainingLabel: page == nil ? "" : "1h",
            spokenRemaining: page == nil ? "" : "one hour",
            fractionRemaining: page == nil ? 0 : 0.5,
            paused: false,
            holdToppedUp: false,
            holdRemainingMs: 0,
            chipCount: 0,
            lastHour: false,
            pageHasContent: page == nil ? false : content,
            pageDayOffset: page == nil ? nil : day
        )
    }

    private func project(
        _ tabs: [TabSummary], selecting page: UInt64? = nil
    ) -> TimeUnitProjection {
        TimeUnitProjection.project(tabs: tabs, selectedPageID: page, unit: .day)
    }

    private func makeModel() throws -> PageModel {
        let suite = "companion-time-rail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    // MARK: The rows, and where they send a click

    /// The rail draws the projection's days in the projection's order,
    /// and each row carries its own day's first slot. Today at the top,
    /// then back through whatever is still alive, with the day that
    /// expired showing as a jump in the labels and no row of its own.
    func testTheRowsAreTheProjectionsDaysNewestFirst() {
        let projection = project([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -3),
        ])
        XCTAssertEqual(projection.units.map(\.label), ["Today", "-1d", "-3d"])
        XCTAssertEqual(
            projection.units.map(\.railLabel), ["Today", "Yesterday", "3 days ago"],
            "the rail went back to the abbreviation the wider column retired")
        XCTAssertEqual(
            projection.units.map { TimeUnitTab.target(for: $0) },
            [.tab(1), .tab(2), .tab(3)])
    }

    /// A day holding several pages answers with the first of them in
    /// strip order, one row, one landing, and the rest of the day's
    /// pages reached by scrolling the roll rather than by the rail.
    func testADayHoldingSeveralPagesSendsAClickToItsFirst() throws {
        let projection = project([
            slot(tab: 7, page: 77, day: -1),
            slot(tab: 3, page: 33, day: -1),
        ])
        let day = try XCTUnwrap(projection.units.last)
        XCTAssertEqual(day.tabIDs, [7, 3])
        XCTAssertEqual(TimeUnitTab.target(for: day), .tab(7))
    }

    /// The rail and the keyboard resolve the same units the same way,
    /// which is what keeps a click on the second row and ⌘2 from
    /// disagreeing about where the second day is. Asserted against a
    /// live pad in the mode, on both shapes a live core can make: a pad
    /// with nothing on it, and a pad with today's page on it.
    func testTheRowsLandWhereTheKeyboardLands() throws {
        let model = try makeModel()
        model.showsTimeUnits = true
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(
            model.timeUnits.units.map { TimeUnitTab.target(for: $0) }, model.visibleTargets,
            "an empty pad's row and its ⌘1 went to different places")

        model.newPage()
        XCTAssertEqual(
            model.timeUnits.units.map { TimeUnitTab.target(for: $0) }, model.visibleTargets,
            "a peopled today's row and its ⌘1 went to different places")
    }

    // MARK: Today, with and without a page

    /// Today is a place, not a page: it has a row either way, and the
    /// two rows do different things. Holding a page it is a jump like
    /// any other; holding none, a click takes the shipped create path,
    /// which is the one place on the rail where clicking makes
    /// something, and the tooltip says so rather than promising a page
    /// that is not there.
    func testTodayIsARowWithOrWithoutAPageAndSaysWhich() throws {
        let bare = try XCTUnwrap(project([]).units.first)
        XCTAssertEqual(bare.bucket, 0)
        XCTAssertEqual(bare.pageIDs, [])
        XCTAssertEqual(TimeUnitTab.target(for: bare), .today)
        XCTAssertEqual(TimeUnitTab.todayHelp(hasPage: false, chord: nil), "Start today's page")

        let peopled = try XCTUnwrap(project([slot(tab: 1, page: 11, day: 0)]).units.first)
        XCTAssertEqual(TimeUnitTab.target(for: peopled), .tab(1))
        XCTAssertEqual(TimeUnitTab.todayHelp(hasPage: true, chord: nil), "Go to today")
        XCTAssertEqual(
            TimeUnitTab.todayHelp(hasPage: true, chord: nil),
            TimeUnitTab.dayHelp(spokenLabel: peopled.spokenLabel, chord: nil),
            "today read differently depending on which helper was asked")
    }

    /// The + sits on today and on no other row (issue #158): a page is
    /// minted with the clock's reading of now, so today is the one day
    /// it can land on. Its tooltip is the strip's own, word for word,
    /// so the two buttons that do one thing cannot describe it two ways
    /// and a keymap that moved `page::New` moves both.
    func testOnlyTodayOffersANewPageAndSaysSoInTheStripsWords() throws {
        let model = try makeModel()
        let projection = project([slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 12, day: -1)])
        XCTAssertEqual(projection.units.map(TimeUnitTab.offersNewPage), [true, false])
        XCTAssertTrue(TimeUnitTab.offersNewPage(try XCTUnwrap(project([]).units.first)))

        let chord = model.keymap.hintKeystroke(for: .pageNew)
        XCTAssertEqual(TimeUnitTab.newPageHelp(chord: chord), "New page (⌘N)")
        XCTAssertEqual(
            TimeUnitTab.newPageHelp(chord: chord), TabStripView.newPageHelp(chord: chord))
        XCTAssertEqual(TimeUnitTab.newPageHelp(chord: nil), "New page")
    }

    // MARK: What the tooltips say you can press

    /// The tooltip names the chord the keymap actually bound, the way
    /// the + button's does: a keymap that moved ⌘2 moves this with it.
    /// ⌘1 to ⌘9 count the rail's rows while the mode is on, so the row at
    /// index 1 is the one ⌘2 selects.
    func testTheTooltipNamesTheChordBoundToThatRow() throws {
        let model = try makeModel()
        XCTAssertEqual(TimeRailView.chord(forRowAt: 0, keymap: model.keymap)?.displaySymbol, "⌘1")
        XCTAssertEqual(TimeRailView.chord(forRowAt: 1, keymap: model.keymap)?.displaySymbol, "⌘2")
        XCTAssertEqual(
            TimeUnitTab.dayHelp(
                spokenLabel: "yesterday",
                chord: TimeRailView.chord(forRowAt: 1, keymap: model.keymap)),
            "Go to yesterday (⌘2)")
    }

    /// And says only what the row does when nothing is bound to it, a
    /// tooltip advertising a chord the keymap took away is how the
    /// ledger tab came to offer ⌘0 after ⌘0 was withdrawn (issue #78).
    /// A tenth row has no chord either, and cannot: it would take ten
    /// live pages, one over the cap.
    func testTheTooltipDegradesToThePlainDescription() throws {
        let model = try makeModel()
        XCTAssertNil(TimeRailView.chord(forRowAt: 9, keymap: model.keymap))
        XCTAssertEqual(TimeUnitTab.dayHelp(spokenLabel: "yesterday", chord: nil), "Go to yesterday")
        XCTAssertEqual(TimeUnitTab.todayHelp(hasPage: false, chord: nil), "Start today's page")
    }

    // MARK: The count of what is not shown

    /// The footer's line appears exactly when the projection is holding
    /// something back, and says nothing at all when it is not: a line
    /// reading "0 blank" would be chrome measuring the absence of a
    /// problem. The short form keeps the footer lighter than the days
    /// above it; the sentence behind it names the one place those pages
    /// can be reached from, which is what doc 05's no-abbreviation-only
    /// rule asks for.
    func testTheHiddenPagesLineAppearsExactlyWhenSomethingIsHidden() {
        XCTAssertNil(TimeRailView.hiddenPagesLine(count: 0))
        XCTAssertEqual(TimeRailView.hiddenPagesLine(count: 1), "1 blank")
        XCTAssertEqual(TimeRailView.hiddenPagesLine(count: 3), "3 blank")

        XCTAssertTrue(TimeRailView.hiddenPagesHelp(count: 1).hasPrefix("One live page has"))
        XCTAssertTrue(TimeRailView.hiddenPagesHelp(count: 3).hasPrefix("3 live pages have"))
        XCTAssertTrue(
            TimeRailView.hiddenPagesHelp(count: 3).contains("Settings"),
            "the footer did not say where the hidden pages are")
    }

    /// And it counts what the projection dropped, not what the strip
    /// holds: three blank pages on days nobody can reach, and an empty
    /// slot that is on no day at all and therefore in hiding nowhere.
    func testTheFooterCountsTheProjectionsOwnNumber() {
        let projection = project([
            slot(tab: 1, page: 11, day: -1, content: false),
            slot(tab: 2, page: 22, day: -2, content: false),
            slot(tab: 3, page: 33, day: -2, content: false),
            slot(tab: 4, page: 44, day: -3, content: true),
            slot(tab: 5),
        ])
        XCTAssertEqual(TimeRailView.hiddenPagesLine(count: projection.hiddenBlankPages), "3 blank")
    }

    // MARK: Which row is lit

    /// The mark follows the selected page's day rather than the row
    /// that was last clicked, so a selection the keyboard moved, or one
    /// that fell onto another day after an expiry, moves it too.
    func testTheMarkSitsOnTheSelectedPagesDay() {
        let projection = project([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
        ])
        XCTAssertEqual(TimeRailView.selectedBucket(projection: projection, selection: 2), -1)
        XCTAssertEqual(TimeRailView.selectedBucket(projection: projection, selection: 1), 0)
    }

    /// Today with no page answers to no slot at all, so it takes the
    /// mark exactly when no other day has it: the empty pad, where
    /// today is where the next page would land. A selection sitting on
    /// a slot the rail does not draw lights nothing, which is honest,
    /// the thing on screen is not on the rail.
    func testAnEmptyTodayIsLitOnlyWhenNoDayHoldsTheSelection() {
        let bare = project([slot(tab: 9)])
        XCTAssertEqual(TimeRailView.selectedBucket(projection: bare, selection: nil), 0)
        XCTAssertEqual(TimeRailView.selectedBucket(projection: bare, selection: 9), 0)

        let peopled = project([
            slot(tab: 1, page: 11, day: -1),
            slot(tab: 2),
        ])
        XCTAssertEqual(
            TimeRailView.selectedBucket(projection: peopled, selection: 1), -1,
            "the day holding the selection lost the mark to an empty today")
        XCTAssertNil(
            TimeRailView.selectedBucket(projection: peopled, selection: 2),
            "a slot the rail does not draw lit a row anyway")
    }

    // MARK: How a day reads out loud

    /// VoiceOver gets the phrase, not the abbreviation, and the value
    /// beside it is the countdown of the page the row's gauge is drawn
    /// from, the same triple `SheetTab` hands it for a slot.
    func testEachRowReadsItsDistanceAndItsClockOutLoud() {
        let projection = project([
            slot(tab: 1, page: 11, day: 0),
            slot(tab: 2, page: 22, day: -1),
            slot(tab: 3, page: 33, day: -3),
        ])
        XCTAssertEqual(
            projection.units.map(\.spokenLabel), ["today", "yesterday", "3 days ago"])
        XCTAssertEqual(
            projection.units.map(\.spokenRemaining), ["one hour", "one hour", "one hour"])
        XCTAssertEqual(project([]).units.map(\.spokenRemaining), [""])
    }
}
