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
/// The model's other `markDirty` sites are pinned elsewhere, each named
/// here with the suite that counts its mark:
///
///   - `clearUnreadableStateFile`: `RestoreFailureTests`, which sees the
///     armed write land as the file that replaces the unreadable one.
///   - `finishConceal`: `ConcealWireTests`, on a stubbed wire.
///   - `newTab`, `close`, `sealText` and `copyOutChip`:
///     `LedgerAppendArmingTests`.
///   - `setChipName` and `applyNoteOps`: `SealedNameFieldTests`.
///   - `provideDecryptedDrag`: `LedgerAppendArmingTests` and
///     `SealedDecryptedDragTests`.
///   - `settleTransfer`, behind the cut, the paste and the slot's place:
///     `SealedFragmentEditorTests`; behind the drag inside a page, the ⌥
///     clone and the move between pages: `SealedDragTests`.
///   - `settleCoreEvent` reached from a wake: `TabLifetimeTests`; from a
///     refused route: `SealedFragmentEditorTests` and
///     `LedgerAppendArmingTests`.
///
/// The sync controller's `onRemoteChange` mark is not counted anywhere:
/// it fires only from a relay session's pump, which no suite stands up.
@MainActor
final class MutationArmingTests: XCTestCase {
    func testEveryMutationSiteArmsAWrite() throws {
        let suite = "companion-kit-mutation-arming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-mutation-arming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }
        // The seams are not a nicety here. No state file is loaded or
        // written by this suite (`loadStateIfNeeded` is never called,
        // and the counter read below is incremented ahead of the
        // licence guard for exactly that reason), but the clearLedger
        // step erases a file by path, unconditionally and with no
        // licence in the way, and a model built on the shipping
        // defaults resolves that path to the installed backdrop's own
        // ledger, the one file ADR-0012 says only the user may end. So
        // the sealed files live in a directory this test owns and dies
        // with, and the core handle keeps its credentials in process
        // memory rather than the login Keychain (ADR-0018).
        // The core's board is in process memory and the model's is the
        // test's own, so no step reads or writes the person's clipboard.
        let client = DragStandIn(tag: "mutation-arming-\(UUID().uuidString)")
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let ambient = NSPasteboard.withUniqueName()
        addTeardownBlock { ambient.releaseGlobally() }
        let model = PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(stateDirectory: tempDir, client: client, ambientPasteboard: ambient)
        )

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
            ("applyOps", {
                model.applyOps(sheet: page, opsJSON: #"[{"ins":{"at":0,"text":"so "}}]"#)
                    && Self.ink(of: client.documentRuns(sheet: page))
                    == "so the deploy key rotates friday"
            }),
            ("undoEdit, through step", {
                model.undoEdit(sheet: page).applied
                    && Self.ink(of: client.documentRuns(sheet: page))
                    == "the deploy key rotates friday"
            }),
            ("sealPasteboard", {
                // A copy out through the client fills the core's memory board.
                guard let held = client.sealText(sheet: page, "n0ts3cr3t", at: 0, length: 0),
                      client.copyOutChip(id: held.chipId)
                else { return false }
                chip = model.sealPasteboard(replacing: NSRange(location: 0, length: 0))
                return chip != nil
            }),
            ("copyChipNameValue", {
                guard let chipId = chip?.chipId, client.setChipName("DEPLOY_KEY", chip: chipId)
                else { return false }
                let before = client.ledger().count
                return model.copyChipNameValue(chipId) && client.ledger().count > before
            }),
            ("stepNote", {
                guard let chipId = chip?.chipId,
                      client.applyNoteOps(
                          chip: chipId, json: #"[{"ins":{"at":0,"text":"rotate monthly"}}]"#)
                else { return false }
                return model.stepNote(chip: chipId, back: true).applied
                    && model.noteText(chip: chipId) == ""
            }),
            ("burnConcealedCopy on a chip, through removeChipFromDocument", {
                guard let chipId = chip?.chipId else { return false }
                let before = summary(tab)?.chipCount ?? 0
                // The state a successful conceal of a chip leaves: a
                // receipt in hand and the offer to be rid of the copy.
                var draft = ConcealDraft(target: .chip(chipId), ttlSecs: 3600)
                draft.receiptId = "receipt-for-the-chip"
                model.concealDraft = draft
                model.burnConcealedCopy()
                return before > 0 && summary(tab)?.chipCount == before - 1
            }),
            ("sealDrag", {
                chip = model.sealDrag(replacing: NSRange(location: 0, length: 0))
                return chip != nil
            }),
            ("burnConcealedCopy on a page", {
                var draft = ConcealDraft(target: .page(page), ttlSecs: 3600)
                draft.receiptId = "receipt-for-the-page"
                model.concealDraft = draft
                model.burnConcealedCopy()
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

    /// A client whose drop to seal stands its object from the test's own
    /// text, so no step reads the system drag board.
    private final class DragStandIn: CompanionClient, @unchecked Sendable {
        init(tag: String) {
            super.init(adopting: CompanionClient.ephemeralHandleForTests(tag: tag))
        }

        override func sealFromDrag(sheet: UInt64, at: UInt32, length: UInt32) -> ChipInfo? {
            sealText(sheet: sheet, "dropped in", at: at, length: length)
        }
    }
}
