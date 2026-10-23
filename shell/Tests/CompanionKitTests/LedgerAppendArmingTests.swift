import AppKit
import XCTest

@testable import CompanionKit

/// The invariant behind issue #52: every model mutation that reaches a
/// seam function which appends a ledger record must also arm a write.
/// The core appends in memory only, and with sudden termination
/// declared, a record nobody armed a write for is lost silently at
/// logout, crash or force quit. Copy-out was the site that missed this:
/// it looks like a read, but a successful copy leaves a sent record.
///
/// Each step below drives one ledger-appending path against the live
/// core and checks two things: that the step still appends (so the
/// script cannot rot into covering nothing, and a step that stops
/// reaching the ledger fails loudly instead of passing vacuously), and
/// that the model asked for a write. `dirtyMarks` counts the arming
/// calls themselves, because a test session never loads a state file
/// and the licence guard inside `markDirty` rightly stands down there.
///
/// The one appending path not driven here is the conceal into a link
/// (`finishConceal`): its record lands only after a successful round
/// trip to a live server, which a unit test must not make. Its arming
/// call sits unconditionally ahead of the staleness guard, covering
/// success and failure alike.
@MainActor
final class LedgerAppendArmingTests: XCTestCase {
    func testEveryLedgerAppendingMutationArmsAWrite() {
        // A throwaway defaults domain, and a model whose sealed files
        // and credentials are this test's own: no state file is loaded
        // or written here (loadStateIfNeeded is never called), and the
        // steps below still drive routes that write by path.
        let defaults = UserDefaults(suiteName: "companion-kit-arming-tests")!
        defaults.removePersistentDomain(forName: "companion-kit-arming-tests")
        let model = isolatedModel(defaults: defaults)
        let client = model.coreClient
        // The copy-out step writes a board in process memory, not the clipboard.
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        // The paste and decrypted drag steps use a board of their own.
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }

        var chip: ChipInfo?
        // One entry per ledger-appending path the model can drive on
        // its own. Adding a new seam route that appends means adding
        // its step here; a step whose route stops appending is caught
        // by the first assertion below.
        let steps: [(name: String, run: () -> Void)] = [
            ("newPage appends created", {
                model.newPage()
            }),
            ("sealText appends sealed", {
                chip = model.sealText(
                    "n0ts3cr3t", replacing: NSRange(location: 0, length: 0))
            }),
            ("copyOutChip appends sent to clipboard", {
                model.copyOutChip(chip?.chipId ?? 0)
            }),
            // A paste of a copy clones its object core side (Law 0001, sealed fragment representation).
            ("pasteFragment appends sealed for each clone", {
                guard let sheet = model.selectedPageID,
                      let fragment = client.copyFragment(
                          sheet: sheet, range: NSRange(location: 0, length: 1)),
                      fragment.write(to: board)
                else { return }
                model.pasteFragment(
                    from: board, sheet: sheet, ranges: [NSRange(location: 1, length: 0)])
            }),
            // The ⌥ drag clones its objects core side (Law 0001, ⌥ drag row).
            ("dropRange cloning appends sealed for each clone", {
                guard let sheet = model.selectedPageID else { return }
                model.dropRange(
                    NSRange(location: 0, length: 1), sheet: sheet, at: 0, cloning: true)
            }),
            // A destination's ask of the decrypted drag records a sent (Law 0001, decrypted drag row).
            ("provideDecryptedDrag appends sent to drag", {
                model.provideDecryptedDrag(
                    chip: chip?.chipId ?? 0, pasteboard: board, item: NSPasteboardItem(),
                    type: .string)
            }),
            // A removal in an edit batch detaches and appends nothing
            // (ADR-0046 point 1); the close below records the chip's death.
            ("close appends discarded for the chip and the page", {
                if let page = model.selection { model.close(page) }
            }),
        ]
        for step in steps {
            let records = client.ledger().count
            let marks = model.dirtyMarks
            step.run()
            XCTAssertGreaterThan(
                client.ledger().count, records,
                "\(step.name): the step no longer reaches the ledger, so it guards nothing")
            XCTAssertGreaterThan(
                model.dirtyMarks, marks,
                "\(step.name): a ledger record was appended and no write was armed (issue #52)")
        }
    }

    /// A refused read appends nothing and arms nothing. Past a page's deadline it
    /// records no `sent`, and only the settle's sweep appends, with its write armed (Law 0001, expiry row).
    func testARefusedReadArmsNothingAndPastADeadlineOnlyItsSweepAppends() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "companion-kit-refused-read-tests"))
        defaults.removePersistentDomain(forName: "companion-kit-refused-read-tests")
        let model = isolatedModel(defaults: defaults)
        let client = model.coreClient
        XCTAssertTrue(client.useMemoryPasteboardForTests())
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        model.newPage()
        let chip = try XCTUnwrap(
            model.sealText("n0ts3cr3t", replacing: NSRange(location: 0, length: 0))?.chipId)
        XCTAssertTrue(model.setChipName("API_KEY", chip: chip, sheet: model.selectedPageID ?? 0))
        let reads: [(name: String, run: (UInt64) -> Bool)] = [
            ("copyOutChip", { model.copyOutChip($0) }),
            ("copyChipNameValue", { model.copyChipNameValue($0) }),
            ("provideDecryptedDrag", {
                model.provideDecryptedDrag(
                    chip: $0, pasteboard: board, item: NSPasteboardItem(), type: .string)
            }),
        ]

        for read in reads {
            let records = client.ledger().count
            let marks = model.dirtyMarks
            XCTAssertFalse(read.run(4_242), "\(read.name) read an unknown object")
            XCTAssertEqual(client.ledger().count, records, read.name)
            XCTAssertEqual(model.dirtyMarks, marks, "\(read.name): a refusal armed a write")
        }

        let tab = try XCTUnwrap(model.selection)
        XCTAssertTrue(client.setRung(tab: tab, rung: .oneHour))
        XCTAssertTrue(client.ageForTests(byMs: 2 * 60 * 60 * 1_000))
        XCTAssertEqual(client.tabs().first?.hasPage, true, "the control: no sweep ran")
        let records = client.ledger().count
        let marks = model.dirtyMarks
        XCTAssertFalse(reads[0].run(chip), "copy decrypted read a page past its deadline")
        let appended = client.ledger().dropFirst(records)
        XCTAssertFalse(appended.isEmpty, "the settle swept nothing")
        XCTAssertFalse(appended.contains { $0.event == "sent" }, "the refused read recorded a sent")
        XCTAssertGreaterThan(model.dirtyMarks, marks, "the sweep's records armed no write")
    }
}
