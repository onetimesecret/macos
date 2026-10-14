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
            // A paste of a copy clones its object core side (ADR-0047 point 6).
            ("pasteFragment appends sealed for each clone", {
                guard let sheet = model.selectedPageID,
                      let fragment = client.copyFragment(
                          sheet: sheet, range: NSRange(location: 0, length: 1)),
                      fragment.write(to: board)
                else { return }
                model.pasteFragment(
                    from: board, sheet: sheet, range: NSRange(location: 1, length: 0))
            }),
            // The ⌥ drag clones its objects core side (ADR-0047 point 10).
            ("dropRange cloning appends sealed for each clone", {
                guard let sheet = model.selectedPageID else { return }
                model.dropRange(
                    NSRange(location: 0, length: 1), sheet: sheet, at: 0, cloning: true)
            }),
            // A destination's ask of the decrypted drag records a sent (ADR-0047 point 11).
            ("provideDecryptedDrag appends sent to drag", {
                model.provideDecryptedDrag(
                    chip: chip?.chipId ?? 0, pasteboard: board, item: NSPasteboardItem(),
                    type: .string)
            }),
            // A removal in an edit batch detaches and appends nothing
            // (ADR-0047); the close below records the chip's death.
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
}
