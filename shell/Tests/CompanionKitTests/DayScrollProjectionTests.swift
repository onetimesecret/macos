import AppKit
import XCTest

@testable import CompanionKit

/// What the roll must not do to the pages it draws (issue #79).
///
/// The claim "perforations are chrome" is only worth making if it can be
/// checked, and the check is this: mounting several days, and moving the
/// editor between them, leaves every one of those days' documents byte
/// for byte as it found them. Nothing the roll draws is a character in
/// anybody's storage, so nothing it draws can cross the seam as an op.
///
/// The other two claims here are about entanglement. A quiet day renders
/// over a storage of its own, so the model's own map never learns of it;
/// and undo follows the page the editor is standing on, so ⌘Z after a
/// day switch cannot reach across a perforation into a document it was
/// never typed into (ADR-0006, ADR-0009).
@MainActor
final class DayScrollProjectionTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-day-projection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = isolatedModel(defaults: defaults)
        model.showsTimeUnits = true
        return model
    }

    @discardableResult
    private func page(in model: PageModel, saying ink: String) throws -> UInt64 {
        model.newPage()
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(model.coreClient.syncDocument(sheet: page, json: "[{\"ink\": \"\(ink)\"}]"))
        model.refresh()
        return page
    }

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

    private func spreadOverDays(_ model: PageModel, selecting page: UInt64?) -> TimeUnitProjection {
        var tabs: [TabSummary] = []
        for (index, tab) in model.tabs.enumerated() {
            tabs.append(onDay(tab, -index))
        }
        return TimeUnitProjection.project(tabs: tabs, selectedPageID: page, unit: .day)
    }

    /// A page's document as the core holds it, flattened to something two
    /// readings can be compared as. `RestoredRun` carries no equality of
    /// its own, and what matters here is that the ink and the chips are
    /// the same ones in the same order.
    private func document(of page: UInt64, in model: PageModel) -> String {
        model.coreClient.documentRuns(sheet: page).map { (run: RestoredRun) -> String in
            switch run {
            case .ink(let text):
                return "ink:\(text)"
            case .chip(let info):
                return "chip:\(info.chipId)"
            }
        }
        .joined(separator: "|")
    }

    /// Everything the mount is made of, held together so that one local
    /// keeps all of it alive: the stack is a subview of a scroll view
    /// that is a subview of the window, so a window nobody holds takes
    /// the roll's own superview chain down with it.
    private struct Roll {
        let window: NSWindow
        let stack: DayStackView
        let coordinator: InkEditorView.Coordinator
    }

    private func mountRoll(model: PageModel) throws -> Roll {
        let coordinator = InkEditorView.Coordinator(model: model)
        let scroll = DayScrollView.makeRoll(
            model: model, coordinator: coordinator, emptyHint: "⌃⌥Space to raise the card"
        )
        let card = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: card, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(scroll)
        scroll.frame = card
        scroll.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(scroll.documentView as? DayStackView)
        return Roll(window: window, stack: stack, coordinator: coordinator)
    }

    // MARK: The chrome claim

    /// Mounting the roll, and moving the editor across two perforations,
    /// writes nothing to any day. This is what makes "perforations are
    /// chrome" an assertion rather than a promise: a separator that was a
    /// character would arrive in a document as an insert op, and this
    /// would fail on the day it did.
    func testMountingTheRollEmitsNoOpsToAnyPage() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today's writing")
        let yesterday = try page(in: model, saying: "yesterday's writing")
        let before = try page(in: model, saying: "the day before that")
        let pages = [today, yesterday, before]
        let documentsBefore = pages.map { document(of: $0, in: model) }
        XCTAssertFalse(documentsBefore.contains(""), "the fixture pages have to hold something")

        let roll = try mountRoll(model: model)
        for selected in pages {
            roll.stack.update(
                projection: spreadOverDays(model, selecting: selected),
                selectedPage: selected,
                readOnly: false
            )
        }

        XCTAssertEqual(
            pages.map { document(of: $0, in: model) },
            documentsBefore,
            "drawing the days changed one of them"
        )
    }

    // MARK: The storage map

    /// The roll draws every visible day, and the model's storage map
    /// learns only about the one the editor is standing on. That is the
    /// whole of how the one-layout-manager-per-storage invariant survives
    /// a surface showing several pages at once (ADR-0006).
    func testAQuietDayNeverEntersTheModelsStorageMap() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today")
        let yesterday = try page(in: model, saying: "yesterday")
        try page(in: model, saying: "the day before")
        let roll = try mountRoll(model: model)

        roll.stack.update(
            projection: spreadOverDays(model, selecting: today),
            selectedPage: today,
            readOnly: false
        )

        XCTAssertEqual(
            model.pagesWithStorage, [today],
            "a quiet day borrowed the editor's storage instead of rendering its own"
        )
        XCTAssertEqual(roll.stack.quietRegions.count, 2)
        for region in roll.stack.quietRegions.values {
            XCTAssertFalse(
                region.textStorage === model.storage(for: today),
                "two views over one storage is two layout managers over one storage"
            )
        }

        // And the day the editor moves onto joins the map, because from
        // then on it is the page being typed into.
        roll.stack.update(
            projection: spreadOverDays(model, selecting: yesterday),
            selectedPage: yesterday,
            readOnly: false
        )
        XCTAssertEqual(model.pagesWithStorage, [today, yesterday])
    }

    // MARK: Undo across a perforation

    /// ⌘Z after the editor has moved rewrites the day it is standing on
    /// and cannot reach the one it left. Undo is as document-scoped as
    /// the storage it rewrites: the editor asks its delegate for a
    /// manager on every touch, and the delegate answers with the current
    /// page's. An undo that crossed a page boundary is how a zeroized
    /// chip's glyph comes back (ADR-0009).
    func testUndoAfterTheEditorMovesDoesNotCrossAPageBoundary() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today")
        let yesterday = try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: today),
            selectedPage: today,
            readOnly: false
        )
        let editor = try XCTUnwrap(roll.stack.editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        let todayAfterTyping = document(of: today, in: model)
        XCTAssertTrue(todayAfterTyping.contains("A"), "the fixture never reached the core")

        roll.stack.update(
            projection: spreadOverDays(model, selecting: yesterday),
            selectedPage: yesterday,
            readOnly: false
        )

        XCTAssertEqual(roll.coordinator.currentSheet, yesterday)
        XCTAssertTrue(
            editor.undoManager === model.undoManager(for: yesterday),
            "the editor is answering undo with the page it left"
        )
        XCTAssertFalse(editor.undoManager === model.undoManager(for: today))

        // Whatever the manager on this side has to say, it says it about
        // this side. The page across the perforation is untouched.
        editor.undoManager?.undo()

        XCTAssertEqual(
            document(of: today, in: model), todayAfterTyping,
            "an undo on one day rewrote the day next to it"
        )
    }

    // MARK: What a header says, without a header

    /// The perforation is the mark of a day boundary. The roll's first
    /// header has no boundary above it, a day's first header is the tear,
    /// and a second page born on the same day is joined by a hairline
    /// rather than torn from the first.
    func testTheMarkOnAHeaderFollowsWhereItSitsOnTheRoll() {
        XCTAssertEqual(
            DayHeaderView.mark(isFirstOnRoll: true, isFirstOfDay: true), DayHeaderView.Mark.none
        )
        XCTAssertEqual(
            DayHeaderView.mark(isFirstOnRoll: false, isFirstOfDay: true), DayHeaderView.Mark.tear
        )
        XCTAssertEqual(
            DayHeaderView.mark(isFirstOnRoll: false, isFirstOfDay: false),
            DayHeaderView.Mark.hairline
        )
    }

    /// Only a day's first page carries the day's label. Repeating it over
    /// the second page born that day would read as two days rather than
    /// as one day's two pages.
    func testOnlyTheFirstPageOfADayCarriesItsLabel() {
        XCTAssertEqual(DayHeaderView.dayText(unitLabel: "-3d", isFirstOfDay: true), "-3d")
        XCTAssertEqual(DayHeaderView.dayText(unitLabel: "-3d", isFirstOfDay: false), "")
        XCTAssertEqual(DayHeaderView.dayText(unitLabel: "Today", isFirstOfDay: true), "Today")
    }

    /// What VoiceOver hears at a perforation: the day in full words, the
    /// page's name, and how long it has left. The rail speaks the day and
    /// deliberately carries no page, so this is where the page is said.
    func testAHeaderSpeaksItsDayItsPageAndItsCountdown() {
        XCTAssertEqual(
            DayHeaderView.spokenHeader(
                spokenLabel: "yesterday", title: "deploy notes", remainingLabel: "4h"
            ),
            "yesterday, deploy notes, 4h left"
        )
        XCTAssertEqual(
            DayHeaderView.spokenHeader(
                spokenLabel: "yesterday", title: "deploy notes", remainingLabel: ""
            ),
            "yesterday, deploy notes",
            "a slot with no clock has no countdown to speak, as the strip already says"
        )
        XCTAssertEqual(
            DayHeaderView.spokenHeader(spokenLabel: "today", title: "", remainingLabel: ""),
            "today",
            "today with nothing on it is a place, and a place has only its name"
        )
    }
}
