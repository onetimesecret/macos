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
/// The one appending path not driven here is the link promotion
/// (`finishPromotion`): its record lands only after a successful round
/// trip to a live server, which a unit test must not make. Its arming
/// call sits unconditionally ahead of the staleness guard, covering
/// success and failure alike.
@MainActor
final class LedgerAppendArmingTests: XCTestCase {
    func testEveryLedgerAppendingMutationArmsAWrite() {
        // A throwaway defaults domain; no state file is ever loaded or
        // written (loadStateIfNeeded is never called).
        let defaults = UserDefaults(suiteName: "companion-kit-arming-tests")!
        defaults.removePersistentDomain(forName: "companion-kit-arming-tests")
        let model = PageModel(formFactor: .backdrop, defaults: defaults)
        let client = model.coreClient

        // The copy-out step writes the real clipboard (concealed and
        // transient, but a write all the same), so hold what the
        // developer had and put it back when the test is done.
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
            ("deleting a chip in an edit batch appends discarded", {
                // The batch also leaves ink behind: a page that dies
                // empty entombs without a record, and the close step
                // needs one to assert on.
                model.applyOps(
                    sheet: model.selection ?? 0,
                    opsJSON: #"[{"del":{"at":0,"len":1}},{"ins":{"at":0,"text":"ink"}}]"#)
            }),
            ("close appends discarded", {
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
