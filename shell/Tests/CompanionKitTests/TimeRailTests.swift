import XCTest
import SwiftUI

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

    /// Under a File or the Ledger a dense rail keeps every checkpoint's target and installs no
    /// wheel relay, so it drives no roll (ADR-0060); the roll showing is the control.
    func testADenseRailKeepsItsCheckpointsAndDrivesNoRollUnderAFileOrTheLedger() throws {
        let model = try makeModel()
        for _ in 0..<24 { model.newPage() }
        let pages = model.tabs.count
        XCTAssertEqual(pages, 24, "the control")
        let host = NSHostingView(rootView: AnyView(
            TimeRailView(model: model, readOnly: false).environment(\.presentationSurface, .panel)))
        host.frame = NSRect(x: 0, y: 0, width: TimeRailView.width, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }

        /// The views of `type` under the host once it has laid out.
        func mounted<Kind: NSView>(_ type: Kind.Type) -> [Kind] {
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
            host.layoutSubtreeIfNeeded()
            func walk(_ view: NSView) -> [Kind] {
                ((view as? Kind).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return walk(host)
        }
        /// Whether the clip around a target leaves none of it in view: a row past the column's foot.
        func clipped(_ target: TabDropTarget) -> Bool {
            guard let clip = sequence(first: target as NSView, next: { $0.superview })
                .first(where: { $0 is NSClipView }) else { return false }
            return !clip.bounds.intersects(clip.convert(target.bounds, from: target))
        }

        let rolling = mounted(TabDropTarget.self)
        XCTAssertEqual(rolling.count, pages, "the roll showing")
        XCTAssertTrue(rolling.contains(where: clipped), "the control: no row was clipped with the roll showing")
        XCTAssertEqual(mounted(WheelRelayView.self).count, 1, "the control: the roll's rail relays no wheel")

        model.showLedger()
        XCTAssertTrue(model.showingLedger, "the control")
        let ledger = mounted(TabDropTarget.self)
        XCTAssertEqual(ledger.count, pages, "the Ledger hid a checkpoint")
        XCTAssertTrue(ledger.contains(where: clipped), "the control: no row was clipped under the Ledger")
        XCTAssertEqual(mounted(WheelRelayView.self).count, 0, "the Ledger's rail drives the roll")

        model.showingLedger = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("time-rail-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try "a file".write(to: url, atomically: true, encoding: .utf8)
        model.openFile(at: url)
        XCTAssertNotNil(model.selectedFile, "the control")
        let file = mounted(TabDropTarget.self)
        XCTAssertEqual(file.count, pages, "the File hid a checkpoint")
        XCTAssertTrue(file.contains(where: clipped), "the control: no row was clipped under the File")
        XCTAssertEqual(mounted(WheelRelayView.self).count, 0, "the File's rail drives the roll")
    }

    /// A dense column too short for a map gives the list every point and shows the active row whole.
    func testAShortDenseColumnStillShowsTheActiveRow() throws {
        let model = try makeModel()
        for _ in 0..<30 { model.newPage() }
        let checkpoints = StreamNavigator.nodes(
            projection: model.timeUnits, tabs: model.navigationTabs, selection: model.selection)
        let active = try XCTUnwrap(checkpoints.first(where: \.active)?.tab, "the control: no node is active")
        XCTAssertEqual(checkpoints.last?.tab, active, "the control: the active row is not the last")
        for height: CGFloat in [30, 50] {
            let host = NSHostingView(rootView: StreamNavigatorView(
                model: model, roll: RollGeometryModel(), drivesRoll: false, readOnly: false,
                nodes: checkpoints, chords: [:]))
            host.frame = NSRect(x: 0, y: 0, width: TimeRailView.width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            addTeardownBlock { window.close() }
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
            host.layoutSubtreeIfNeeded()

            func targets(_ view: NSView) -> [TabDropTarget] {
                ((view as? TabDropTarget).map { [$0] } ?? []) + view.subviews.flatMap(targets)
            }
            let row = try XCTUnwrap(targets(host).first { $0.slot == active }, "no target at \(height)")
            let clip = try XCTUnwrap(
                sequence(first: row as NSView, next: { $0.superview }).first { $0 is NSClipView } as? NSClipView,
                "the rail is not dense at \(height)")
            XCTAssertTrue(
                clip.bounds.contains(clip.convert(row.bounds, from: row)),
                "the active row is cut short at \(height): \(clip.bounds)")
            XCTAssertEqual(
                clip.bounds.height, height, accuracy: 0.5, "a map too short to draw kept its room at \(height)")
        }
    }

    /// In a short dense column the split between map and list stays put as the selection moves
    /// across rows of every height, and the list shows each active row whole.
    func testTheDenseSplitStaysPutWhicheverCheckpointIsActive() throws {
        let model = try makeModel()
        // Today, yesterday and a retained day, eight pages each.
        let days = [0, -1, -9]
        let tabs: [TabSummary] = (1...24).map { (index: Int) -> TabSummary in
            slot(tab: UInt64(index), page: UInt64(index + 100), day: days[(index - 1) / 8])
        }
        var listHeights: [UInt64: CGFloat] = [:]
        for selection: UInt64 in [1, 2, 9, 17, 24] {
            let checkpoints = StreamNavigator.nodes(projection: project(tabs), tabs: tabs, selection: selection)
            let host = NSHostingView(rootView: StreamNavigatorView(
                model: model, roll: RollGeometryModel(), drivesRoll: false, readOnly: false,
                nodes: checkpoints, chords: [:]))
            host.frame = NSRect(x: 0, y: 0, width: TimeRailView.width, height: 80)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            addTeardownBlock { window.close() }
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
            host.layoutSubtreeIfNeeded()

            func targets(_ view: NSView) -> [TabDropTarget] {
                ((view as? TabDropTarget).map { [$0] } ?? []) + view.subviews.flatMap(targets)
            }
            let row = try XCTUnwrap(targets(host).first { $0.slot == selection }, "no target for \(selection)")
            let clip = try XCTUnwrap(
                sequence(first: row as NSView, next: { $0.superview }).first { $0 is NSClipView } as? NSClipView,
                "the rail is not dense with \(selection) selected")
            XCTAssertTrue(
                clip.bounds.contains(clip.convert(row.bounds, from: row)),
                "the active row \(selection) is cut short: \(clip.bounds)")
            listHeights[selection] = clip.bounds.height
        }
        XCTAssertEqual(Set(listHeights.values).count, 1, "the split moved with the selection: \(listHeights)")
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

    // MARK: Pads

    /// The active page on a pads rail, with the nodes the rail draws for it.
    private func padsModel() throws -> (PageModel, [StreamNavigator.Node], StreamNavigator.Node) {
        let model = try makeModel()
        model.pads.isEnabled = true
        model.newPage()
        let nodes = StreamNavigator.nodes(
            projection: model.timeUnits, tabs: model.navigationTabs, selection: model.selection)
        let active = try XCTUnwrap(nodes.first(where: \.active), "the control: a page is selected")
        XCTAssertFalse(model.dateKey(forDayBucket: active.bucket).isEmpty, "the control: a stable roster date")
        return (model, nodes, active)
    }

    /// The heading menu offers the days' order and the active checkpoint's day order, outside
    /// the navigator's viewport (ADR-0060), and each picker sets the order it names.
    func testTheHeadingMenuSortsTheDaysAndTheActiveCheckpointsDay() throws {
        let (model, nodes, active) = try padsModel()
        let sections = TimeRailView.sortSections(model: model, nodes: nodes)
        XCTAssertEqual(sections.map(\.scope), [.days, .checkpoints(dayBucket: active.bucket)])
        XCTAssertEqual(sections.map(\.subject), [
            CompanionL10n.string("pad.sort.days"),
            CompanionL10n.format("pad.sort.checkpoints", active.spokenDay),
        ])

        let pad = model.pads.activeID
        let date = model.dateKey(forDayBucket: active.bucket)
        for order in PadSortCopy.orders {
            sections[1].apply(order, to: model)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: pad, onDate: date), order)
            sections[0].apply(order, to: model)
            XCTAssertEqual(model.pads.daySortDirection(for: pad), order)
        }

        let ledger = StreamNavigator.nodes(
            projection: model.timeUnits, tabs: model.navigationTabs, selection: nil,
            surfaceShowsRoll: false)
        XCTAssertEqual(
            TimeRailView.sortSections(model: model, nodes: ledger).map(\.scope), [.days],
            "a menu offered a checkpoint order with no checkpoint selected")
    }

    /// A node names the context menu's three orders as actions VoiceOver can reach.
    func testACheckpointNamesItsThreeOrdersAsActions() throws {
        let (model, _, active) = try padsModel()
        let section = PadSortSection.checkpoints(of: active, in: model)
        XCTAssertEqual(PadSortCopy.orders.map(section.actionName), [
            "Sort Checkpoints from Today: Natural Order",
            "Sort Checkpoints from Today: Oldest First",
            "Sort Checkpoints from Today: Newest First",
        ])
        let date = model.dateKey(forDayBucket: active.bucket)
        for order in PadSortCopy.orders.reversed() {
            section.apply(order, to: model)
            XCTAssertEqual(model.pads.checkpointSortDirection(for: model.pads.activeID, onDate: date), order)
        }
    }

    /// Whether `text` is title case as ADR-0055 rule 1 words it: every word capitalised but
    /// articles, coordinating conjunctions and prepositions of four letters or fewer, unless first or last.
    private func isTitleCase(_ text: String) -> Bool {
        let small: Set<String> = [
            "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
            "as", "at", "by", "from", "in", "into", "of", "off", "on", "onto", "over", "to", "up", "upon", "with",
        ]
        let words = text.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
        return words.indices.allSatisfy { index in
            let word = words[index]
            let edge = index == words.startIndex || index == words.index(before: words.endIndex)
            if !edge && small.contains(word.lowercased()) { return word == word.lowercased() }
            return word.first.map { $0.isUppercase || $0.isNumber } ?? true
        }
    }

    /// The sort words for today, yesterday and older days: menu titles, order names and
    /// action names in title case, tooltips in lower case sentences (ADR-0055 rule 1).
    func testTheSortWordsFollowTheMenuCaseRule() throws {
        let (model, _, _) = try padsModel()
        let nodes = StreamNavigator.nodes(
            projection: project([
                slot(tab: 1, page: 11, day: 0), slot(tab: 2, page: 22, day: -1),
                slot(tab: 3, page: 33, day: -3), slot(tab: 4, page: 44, day: -10),
            ]),
            tabs: [], selection: 1)
        let sections = [PadSortSection.days(in: model)] + nodes.map { PadSortSection.checkpoints(of: $0, in: model) }

        XCTAssertEqual(sections.map(\.copy.menuTitle), [
            "Sort Days", "Sort Checkpoints from Today", "Sort Checkpoints from Yesterday",
            "Sort Checkpoints from 3 Days Ago", "Sort Checkpoints from 10 Days Ago",
        ])
        XCTAssertEqual(sections.map(\.copy.help), [
            "sort days: \(sections[0].copy.currentOrder)",
            "sort checkpoints from today: Natural Order",
            "sort checkpoints from yesterday: Natural Order",
            "sort checkpoints from 3 days ago: Natural Order",
            "sort checkpoints from 10 days ago: Natural Order",
        ])
        XCTAssertEqual(PadSortCopy.orders.map { sections[3].copy($0).currentOrder },
                       ["Natural Order", "Oldest First", "Newest First"])
        XCTAssertEqual(sections[3].actionName(.reverseChronological),
                       "Sort Checkpoints from 3 Days Ago: Newest First")
        XCTAssertEqual(
            CompanionL10n.format("pad.sort.title", CompanionL10n.string("pad.timeline.heading")),
            "Sort Timeline", "the heading menu's VoiceOver label")

        for section in sections {
            let titled = [section.copy.menuTitle] + PadSortCopy.orders.flatMap {
                [section.copy($0).currentOrder, section.actionName($0)]
            }
            for title in titled { XCTAssertTrue(isTitleCase(title), "not title case: \(title)") }
            let tooltip = section.copy.help
            XCTAssertEqual(tooltip.first.map(String.init), tooltip.first?.lowercased(), "not lower case: \(tooltip)")
        }
        XCTAssertFalse(isTitleCase("Sort today checkpoints"), "the control: the check refuses a sentence")
        XCTAssertFalse(isTitleCase("Natural order"), "the control")
    }

    /// A checkpoint row offers its sort menu and actions only while pads are on, so a right
    /// click with pads off opens no empty menu.
    func testACheckpointOffersASortMenuOnlyWithPads() throws {
        let (model, _, active) = try padsModel()
        let menu = try XCTUnwrap(PadSortSection.checkpointMenu(of: active, in: model), "pads on offered none")
        XCTAssertEqual(menu, PadSortSection.checkpoints(of: active, in: model))
        model.pads.isEnabled = false
        XCTAssertNil(PadSortSection.checkpointMenu(of: active, in: model), "pads off offered a sort menu")
    }

    /// With pads on, `PadShortcutMonitor` takes ⌘1 to ⌘9 for pads, so a node names no chord
    /// the monitor would take, and still names a binding that reaches its day.
    func testPadsLeaveOutTheDigitChordsThePadMonitorTakes() throws {
        let model = try makeModel()
        for row in 0..<9 {
            XCTAssertEqual(
                TimeRailView.chord(forRowAt: row, keymap: model.keymap, padsEnabled: false)?.displaySymbol,
                "⌘\(row + 1)", "the control: pads off")
            XCTAssertNil(
                TimeRailView.chord(forRowAt: row, keymap: model.keymap, padsEnabled: true),
                "row \(row) named a chord that switches pads")
        }

        let defaults = """
            [{"context":"Editor","bindings":{"cmd-1":"page::Select1","cmd-2":"page::Select2"}}]
            """
        let elsewhere = Keymap.resolve(defaultText: defaults, overrideText: """
            [{"context":"Editor","bindings":{"cmd-1":null,"ctrl-1":"page::Select1"}}]
            """)
        XCTAssertEqual(
            TimeRailView.chord(forRowAt: 0, keymap: elsewhere, padsEnabled: true)?.displaySymbol, "⌃1")
        let remapped = Keymap.resolve(defaultText: defaults, overrideText: """
            [{"context":"Editor","bindings":{"cmd-2":"page::Select1"}}]
            """)
        XCTAssertFalse(PadShortcutMonitor.allows(number: 2, keymap: remapped), "the control")
        XCTAssertEqual(
            TimeRailView.chord(forRowAt: 0, keymap: remapped, padsEnabled: true)?.displaySymbol, "⌘2",
            "a remapped digit the pads leave alone lost its hint")

        // The keymap's own hint, asked to pass over a chord, and with nothing passed over.
        XCTAssertEqual(
            elsewhere.hintKeystroke(for: .pageSelect1, excluding: { _ in false }),
            elsewhere.hintKeystroke(for: .pageSelect1))
        XCTAssertNil(elsewhere.hintKeystroke(for: .pageSelect1, excluding: { _ in true }))
        XCTAssertNil(model.keymap.hintKeystroke(
            for: .pageSelect1, excluding: { TimeRailView.switchesPads($0, keymap: model.keymap) }))
    }

    /// VoiceOver hears a whole percent from 0 to 100, and 0 where nothing scrolls.
    func testTheReadingPositionIsAPercentFromZeroToAHundred() {
        func percent(_ top: CGFloat, _ document: CGFloat, _ viewport: CGFloat) -> Int {
            StreamNavigatorView.readingPercent(
                viewportTop: top, documentHeight: document, viewportHeight: viewport)
        }
        XCTAssertEqual(percent(0, 1000, 200), 0)
        XCTAssertEqual(percent(400, 1000, 200), 50)
        XCTAssertEqual(percent(800, 1000, 200), 100)
        XCTAssertEqual(percent(900, 1000, 200), 100, "scrolled past the end")
        XCTAssertEqual(percent(-40, 1000, 200), 0, "scrolled above the top")
        XCTAssertEqual(percent(30, 100, 200), 0, "a document shorter than its viewport")
        XCTAssertEqual(percent(0, 200, 200), 0, "a document exactly its viewport")
        XCTAssertEqual(percent(0.4, 200.5, 200), 80, "a range under a point")
        XCTAssertEqual(percent(.nan, 1000, 200), 0)
        XCTAssertEqual(percent(.infinity, 1000, 200), 0)
        XCTAssertEqual(percent(10, .infinity, 200), 0)
        XCTAssertEqual(percent(10, .nan, 200), 0)
        XCTAssertEqual(percent(10, 1000, .nan), 0)
    }

    // MARK: The Files shelf

    /// The shelf fits up to two rows and then shows half a third, so a hidden row reads as
    /// one to scroll to; the row is drawn at the height the shelf counts in.
    func testTheFilesShelfShowsTwoRowsAndHalfOfTheNext() throws {
        let model = try makeModel()
        let row = try [false, true].map { dirty in
            let file = FileSummary(
                id: CompanionClient.fileIDTag | 1, name: "README.md", path: "/tmp/README.md",
                isDirty: dirty, conflict: .none, lineEnding: .lf, hasBOM: false, lastEditedAt: 0,
                restoredFromDraft: false, pendingHydration: false, accessRefused: false, notFound: false)
            let height = NSHostingView(
                rootView: FileShelfRow(file: file, selected: false, model: model)).fittingSize.height
            return try XCTUnwrap(height > 0 ? height : nil, "the control: the row measured")
        }.max() ?? 0
        let gap = FileShelfRow.spacing
        XCTAssertEqual(FileShelfRow.shelfHeight(rows: 0, row: row), 0)
        XCTAssertGreaterThanOrEqual(FileShelfRow.shelfHeight(rows: 1, row: row), row)
        XCTAssertGreaterThanOrEqual(FileShelfRow.shelfHeight(rows: 2, row: row), 2 * row)
        XCTAssertEqual(FileShelfRow.shelfHeight(rows: 3, row: row), 2.5 * row + 2 * gap)
        XCTAssertEqual(FileShelfRow.shelfHeight(rows: 40, row: row), 2.5 * row + 2 * gap)

        // The rail sizes its shelf from the row it drew, not from the estimate.
        let host = NSHostingView(rootView: AnyView(
            TimeRailView(model: model, readOnly: false).environment(\.presentationSurface, .panel)))
        host.frame = NSRect(x: 0, y: 0, width: TimeRailView.width, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        func shelf() throws -> NSScrollView {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); drainMainQueue() }
            func walk(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return try XCTUnwrap(walk(host).min { $0.frame.height < $1.frame.height }, "no shelf")
        }
        for count in 1...3 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("time-rail-shelf-\(UUID().uuidString).txt")
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            try "file \(count)".write(to: url, atomically: true, encoding: .utf8)
            model.openFile(at: url)
            XCTAssertEqual(model.navigationFiles.count, count, "the control")
            let scroll = try shelf()
            let document = try XCTUnwrap(scroll.documentView).frame.height
            XCTAssertEqual(
                scroll.contentView.bounds.height, FileShelfRow.shelfHeight(rows: count, row: row),
                accuracy: 0.5, "\(count) rows: the shelf is not in measured rows")
            if count < 3 {
                XCTAssertGreaterThanOrEqual(
                    scroll.contentView.bounds.height + 0.5, document, "\(count) rows: a row is clipped")
            } else {
                XCTAssertLessThan(scroll.contentView.bounds.height, document, "the third row is all shown")
            }
        }
    }
}
