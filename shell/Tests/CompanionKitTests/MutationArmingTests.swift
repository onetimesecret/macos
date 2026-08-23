import AppKit
import XCTest

@testable import CompanionKit

/// The whole of ADR-0016 section 2's first claim, which is broader than
/// the ledger invariant beside it (`LedgerAppendArmingTests`, issue
/// #52): every mutation site, appending or not, must arm a write. With
/// sudden termination declared, anything that moved the store and armed
/// nothing is lost at the next logout, crash or force quit, and the
/// user is never told, because from the app's side nothing failed.
///
/// The mechanism is the ledger suite's: the DEBUG `dirtyMarks` counter,
/// read before the licence guard, because a test session never loads a
/// state file and the guard inside `markDirty` rightly stands down
/// there. Each step also carries a witness, an observable fact about
/// the core that the step's own mutation produces, so a step whose
/// route stops mutating fails loudly here instead of passing on an
/// arming call that now guards nothing.
///
/// Three of the model's nineteen `markDirty` sites are not steps below,
/// each for a stated reason rather than by omission:
///
///   - `clearUnreadableStateFile` is covered in substance, and more
///     strictly, by `RestoreFailureTests`: the discard's whole point is
///     that this session's own seal replaces the unreadable file inside
///     one debounce with no further gesture, which is the armed write
///     observed at its far end rather than counted at its near one.
///   - `finishPromotion` lands only after a round trip to a live
///     server, which a unit test must not make. Its arming call sits
///     unconditionally ahead of the staleness guard, covering the
///     success and failure arms alike.
///   - `newTab`, `close`, `sealText`, `copyOutChip` and `applyOps` are
///     the five the ledger suite already drives, and are left there
///     rather than asserted twice.
@MainActor
final class MutationArmingTests: XCTestCase {
    func testEveryMutationSiteArmsAWrite() throws {
        let suite = "companion-kit-mutation-arming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // No state file is ever loaded or written: `loadStateIfNeeded`
        // is never called, and the counter this reads is incremented
        // ahead of the licence guard for exactly that reason.
        let model = PageModel(formFactor: .backdrop, defaults: defaults)

        // Two seal routes below write real pasteboards. The general
        // board belongs to whoever is at the keyboard, so hold what
        // they had and give it back; the drag board belongs to a drag
        // session, and none is in flight while tests run.
        let board = NSPasteboard.general
        let held: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        defer {
            board.clearContents()
            if !held.isEmpty { board.writeObjects(held) }
        }

        // Two tabs, because one of the steps is a reorder, and the
        // second is the selected one every page-level step lands on.
        model.newPage()
        model.newPage()
        let tab = try XCTUnwrap(model.selection)
        let page = try XCTUnwrap(model.selectedPageID)
        func summary(_ id: UInt64) -> TabSummary? {
            model.coreClient.tabs().first { $0.id == id }
        }
        var chip: ChipInfo?

        // One entry per mutation site, ordered so each leaves the store
        // in the shape the next one needs: the burn empties the slot the
        // mint then fills, and the clock is aged only at the very end.
        let steps: [(name: String, run: () -> Bool)] = [
            ("renameTab", {
                model.renameTab(tab, to: "payroll")
                return summary(tab)?.title == "payroll"
            }),
            ("cycleRung", {
                let before = summary(tab)?.rungCode
                model.cycleRung(tab)
                return summary(tab)?.rungCode != before
            }),
            ("pause", {
                model.pause(tab)
                return summary(tab)?.paused == true
            }),
            ("move", {
                model.move(tab, to: 0)
                return model.coreClient.tabs().first?.id == tab
            }),
            ("syncDocument", {
                model.syncDocument(sheet: page, runs: [.ink("the deploy key rotates friday")])
                return Self.ink(of: model.coreClient.documentRuns(sheet: page))
                    == "the deploy key rotates friday"
            }),
            ("sealPasteboard", {
                board.clearContents()
                board.setString("n0ts3cr3t", forType: .string)
                chip = model.sealPasteboard(replacing: NSRange(location: 0, length: 0))
                return chip != nil
            }),
            ("burnPromotedCopy on a chip, through removeChipFromDocument", {
                guard let chipId = chip?.chipId else { return false }
                let before = summary(tab)?.chipCount ?? 0
                // The state a successful promotion of a chip leaves: a
                // receipt in hand and the offer to be rid of the copy.
                var draft = PromotionDraft(target: .chip(chipId), ttlSecs: 3600)
                draft.receiptId = "receipt-for-the-chip"
                model.promotion = draft
                model.burnPromotedCopy()
                return before > 0 && summary(tab)?.chipCount == before - 1
            }),
            ("sealDrag", {
                let dragBoard = NSPasteboard(name: .drag)
                dragBoard.clearContents()
                dragBoard.setString("dropped in", forType: .string)
                chip = model.sealDrag(replacing: NSRange(location: 0, length: 0))
                dragBoard.clearContents()
                return chip != nil
            }),
            ("burnPromotedCopy on a page", {
                var draft = PromotionDraft(target: .page(page), ttlSecs: 3600)
                draft.receiptId = "receipt-for-the-page"
                model.promotion = draft
                model.burnPromotedCopy()
                return summary(tab)?.hasPage == false
            }),
            ("openPageIfSlotIsEmpty, through a selection", {
                model.select(tab)
                return summary(tab)?.hasPage == true
            }),
            ("clearLedger", {
                let before = model.coreClient.ledger().count
                model.clearLedger()
                return before > 0 && model.coreClient.ledger().isEmpty
            }),
            ("settleCoreEvent, the event timer's body", {
                // The one mutation nobody typed. Aged past the longest
                // rung, so the settle genuinely entombs the pages that
                // are standing; the site marks on the fire rather than
                // on the count, because a hold lapse changes the store
                // and reports no expired ids at all.
                let before = model.coreClient.tabs().contains { $0.hasPage }
                model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
                model.settleCoreEvent()
                return before && model.coreClient.tabs().allSatisfy { !$0.hasPage }
            }),
        ]

        for step in steps {
            let marks = model.dirtyMarks
            let mutated = step.run()
            XCTAssertTrue(
                mutated,
                "\(step.name): the step no longer moves the store, so it guards nothing")
            XCTAssertGreaterThan(
                model.dirtyMarks, marks,
                "\(step.name): the store moved and no write was armed (ADR-0016 section 2)")
        }
    }

    private static func ink(of runs: [RestoredRun]) -> String {
        runs.compactMap { if case .ink(let text) = $0 { text } else { nil } }.joined()
    }
}
