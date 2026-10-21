import XCTest

@testable import CompanionKit

/// What the rail says and where a click on it lands (issue #79).
///
/// A rail is a drawing, and drawings are hardware verification's
/// business (docs/qa/hardware-verification.md). What is here is everything
/// that was deliberately kept out of the drawing: the day a node's
/// click lands on beside the keyboard's, the chord a row names and the
/// words in each tooltip are all pure functions, in the idiom
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
            titleSource: .derived,
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
            pageDayOffset: page == nil ? nil : day,
            pageCreatedMs: page == nil ? nil : 1_757_849_940_000
        )
    }

    private func project(_ tabs: [TabSummary]) -> TimeUnitProjection {
        TimeUnitProjection.project(tabs: tabs, selectedPageID: nil, unit: .day)
    }

    private func makeModel() throws -> PageModel {
        let suite = "companion-time-rail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return isolatedModel(defaults: defaults)
    }

    // MARK: The rows, and where they send a click

    /// The rail draws the projection's days in the projection's order,
    /// and each day's first node selects that day's first slot. Today at
    /// the top, then back through whatever is still alive, with the day
    /// that expired showing as a jump in the labels and no node of its own.
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
        let nodes = StreamNavigator.nodes(projection: projection, tabs: [], selection: nil)
        XCTAssertEqual(nodes.filter(\.firstOfDay).map(\.target), [.tab(1), .tab(2), .tab(3)])
    }

    /// A day's first node and the keyboard resolve the day the same way,
    /// which is what keeps a click on the second day's node and ⌘2 from
    /// disagreeing about where the second day is; a later page on the
    /// same day has a node of its own, which ⌘n does not count. Asserted
    /// against a live pad in the mode, on the shapes a live core can
    /// make: a pad with nothing on it, with today's page, and with two.
    func testTheNodesLandWhereTheKeyboardLands() throws {
        let model = try makeModel()
        model.showsTimeUnits = true
        XCTAssertTrue(model.tabs.isEmpty)
        func nodes() -> [StreamNavigator.Node] {
            StreamNavigator.nodes(
                projection: model.timeUnits, tabs: model.navigationTabs, selection: model.selection)
        }
        func firstTargets() -> [SurfaceTarget] { nodes().filter(\.firstOfDay).map(\.target) }
        XCTAssertEqual(
            firstTargets(), model.visibleTargets,
            "an empty pad's node and its ⌘1 went to different places")

        model.newPage()
        XCTAssertEqual(
            firstTargets(), model.visibleTargets,
            "a peopled today's node and its ⌘1 went to different places")

        model.newPage()
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(
            firstTargets(), model.visibleTargets, "a second page on today moved where ⌘1 goes")
        XCTAssertEqual(
            nodes().map(\.target), model.tabs.map { .tab($0.id) },
            "each page's node selects its own slot")
    }

    // MARK: Today, with and without a page

    /// Today is a place, not a page: it has a node either way, and the
    /// two nodes do different things. Holding a page it is a jump like
    /// any other; holding none, a click takes the shipped create path,
    /// which is the one place on the rail where clicking makes
    /// something, and the tooltip says so rather than promising a page
    /// that is not there.
    func testTodayIsANodeWithOrWithoutAPageAndSaysWhich() throws {
        let bare = try XCTUnwrap(
            StreamNavigator.nodes(projection: project([]), tabs: [], selection: nil).first)
        XCTAssertFalse(bare.hasPage)
        XCTAssertEqual(bare.target, .today)
        XCTAssertEqual(StreamNavigator.help(for: bare, chord: nil), "Start today's page")

        let peopled = try XCTUnwrap(
            StreamNavigator.nodes(
                projection: project([slot(tab: 1, page: 11, day: 0)]), tabs: [], selection: nil
            ).first)
        XCTAssertTrue(peopled.hasPage)
        XCTAssertEqual(peopled.target, .tab(1))
        let help = StreamNavigator.help(for: peopled, chord: nil)
        XCTAssertTrue(help.contains(" · "), "a page node's tooltip is its day and stamp: \(help)")
        XCTAssertFalse(help.contains("Start"), "a page node's tooltip promised a page that exists")
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
            TimeUnitTab.todayHelp(chord: TimeRailView.chord(forRowAt: 0, keymap: model.keymap)),
            "Start today's page (⌘1)")
        let yesterday = try XCTUnwrap(
            StreamNavigator.nodes(
                projection: project([slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 22, day: -1)]),
                tabs: [], selection: nil
            ).last)
        XCTAssertTrue(
            StreamNavigator.help(for: yesterday, chord: TimeRailView.chord(forRowAt: 1, keymap: model.keymap))
                .hasSuffix("(⌘2)"))
    }

    /// And says only what the row does when nothing is bound to it, a
    /// tooltip advertising a chord the keymap took away is how the
    /// ledger tab came to offer ⌘0 after ⌘0 was withdrawn (issue #78).
    /// A tenth row has no chord either: the shortcuts count to nine and
    /// the strip does not (issue #158), so the row is reached by a click.
    func testTheTooltipDegradesToThePlainDescription() throws {
        let model = try makeModel()
        XCTAssertNil(TimeRailView.chord(forRowAt: 9, keymap: model.keymap))
        XCTAssertEqual(TimeUnitTab.todayHelp(chord: nil), "Start today's page")
    }

    // MARK: Hidden blank pages

    func testHiddenBlankPagesDoNotAddTimelineNodes() {
        let projection = project([
            slot(tab: 1, page: 11, day: -1, content: false),
            slot(tab: 2, page: 22, day: -2, content: false),
            slot(tab: 3, page: 33, day: -2, content: false),
            slot(tab: 4, page: 44, day: -3, content: true),
            slot(tab: 5),
        ])
        XCTAssertEqual(projection.hiddenBlankPages, 3)
        XCTAssertEqual(projection.units.flatMap(\.pageIDs), [44])
        let nodes = StreamNavigator.nodes(projection: projection, tabs: [], selection: nil,
            surfaceShowsRoll: true, stampFormat: .standard)
        XCTAssertEqual(nodes.compactMap(\.page), [44])
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
