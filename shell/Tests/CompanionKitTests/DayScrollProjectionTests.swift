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

    // MARK: A quiet day that changed anyway

    /// The cache behind the quiet regions is sound only while what it
    /// holds is what the core holds, and a page can change while the
    /// editor is standing on another day: an edit that reached it in the
    /// other mode, a chip burned out of it, a composition settling as
    /// the editor left. The model therefore drops a page's reading at
    /// the mutation rather than on the roll's way past — and the roll
    /// re-reads on the ordinary pass, since none of those changes moves
    /// a bucket, a page id or the selection, and so none of them
    /// assembles anything.
    func testAnEditThatNeverWentThroughTheRollStillReachesTheDayItChanged() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today")
        let yesterday = try page(in: model, saying: "yesterday")
        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: today),
            selectedPage: today,
            readOnly: false
        )
        let quiet = try XCTUnwrap(roll.stack.quietRegions[yesterday])
        XCTAssertEqual(quiet.textStorage?.string, "yesterday", "the fixture never reached the roll")

        // The edit path a keystroke takes with the strip showing, over a
        // page this roll is drawing quietly and never receives the
        // editor for.
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: "later, ")]))
        model.applyOps(sheet: yesterday, opsJSON: ops)

        let before = roll.stack.rebuilds
        roll.stack.update(
            projection: spreadOverDays(model, selecting: today),
            selectedPage: today,
            readOnly: false
        )

        XCTAssertEqual(roll.stack.rebuilds, before, "the day was re-read by rebuilding the roll")
        XCTAssertTrue(
            roll.stack.quietRegions[yesterday] === quiet,
            "the region was replaced rather than re-read, taking its layout with it"
        )
        XCTAssertEqual(
            quiet.textStorage?.string, "later, yesterday",
            "the roll went on showing the day as it stood before the edit"
        )
    }

    /// The same law where the user can see it fastest: a chip burned
    /// after its page went quiet. The burn is a core delete of a chip
    /// standing in a day the editor has left, so nothing about the roll
    /// changes shape — and the sealed thing the user just asked to be
    /// rid of must not go on being drawn there (ADR-0009).
    func testAChipBurnedOutOfAQuietDayStopsBeingDrawnOnIt() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today")
        let yesterday = try page(in: model, saying: "yesterday")
        let todayTab = try XCTUnwrap(model.tabs.first { $0.pageID == today }?.id)
        model.select(todayTab)
        let chip = try XCTUnwrap(
            model.sealText("n0ts3cr3t", replacing: NSRange(location: 0, length: 0))
        )
        model.refresh()

        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: yesterday),
            selectedPage: yesterday,
            readOnly: false
        )
        let quiet = try XCTUnwrap(roll.stack.quietRegions[today])
        XCTAssertTrue(
            quiet.textStorage?.string.contains("\u{FFFC}") ?? false,
            "the chip never reached the day's rendering"
        )

        // The state a promoted chip leaves: a receipt in hand and the
        // offer to be rid of the local copy, taken while the editor is
        // standing on another day.
        var draft = PromotionDraft(target: .chip(chip.chipId), ttlSecs: 3600)
        draft.receiptId = "receipt-for-the-chip"
        model.promotion = draft
        model.burnPromotedCopy()

        roll.stack.update(
            projection: spreadOverDays(model, selecting: yesterday),
            selectedPage: yesterday,
            readOnly: false
        )

        XCTAssertFalse(
            quiet.textStorage?.string.contains("\u{FFFC}") ?? false,
            "the burned chip is still drawn on the day it was sealed into"
        )
    }

    /// A composition in flight is provisional text the emission gate
    /// keeps out of the core until it settles, and the swap that settles
    /// it used to happen after the outgoing day's rendering had already
    /// been built. The roll therefore has to finish with the page it is
    /// leaving before it draws it.
    func testACompositionSettlesBeforeTheDayItWasTypedOnIsDrawn() throws {
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
        editor.setMarkedText(
            "ka", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText(), "nothing was composed, so nothing is at stake")

        roll.stack.update(
            projection: spreadOverDays(model, selecting: yesterday),
            selectedPage: yesterday,
            readOnly: false
        )

        XCTAssertFalse(
            editor.hasMarkedText(),
            "the composition crossed the perforation into another page's offsets"
        )
        let quiet = try XCTUnwrap(roll.stack.quietRegions[today])
        XCTAssertTrue(
            quiet.textStorage?.string.contains("ka") ?? false,
            "the day was drawn before the composition it was still holding had settled"
        )
    }

    /// The roll's very first mount is the pass that *builds* the editor,
    /// and the factory sets `currentSheet` itself, so the swap the
    /// invalidation used to hang off is never taken there. The page the
    /// editor lands on must lose its quiet reading all the same: from
    /// that moment it can be typed into.
    func testTheDayTheEditorIsBuiltOverLosesItsQuietReading() throws {
        let model = try makeModel()
        let today = try page(in: model, saying: "today")
        try page(in: model, saying: "yesterday")
        let before = model.quietRendering(for: today)

        let roll = try mountRoll(model: model)
        roll.stack.update(
            projection: spreadOverDays(model, selecting: today),
            selectedPage: today,
            readOnly: false
        )

        XCTAssertEqual(roll.coordinator.currentSheet, today, "the editor was never built")
        XCTAssertFalse(
            model.quietRendering(for: today) === before,
            "the page the editor was built over kept the reading it had before"
        )
    }
}
