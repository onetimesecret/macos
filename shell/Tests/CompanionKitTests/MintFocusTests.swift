import XCTest

@testable import CompanionKit

/// Who gets the keyboard when a gesture conjures a page (issue #22).
///
/// The focus law's promise is narrow and absolute: a surface holding
/// the keys, with the ember lit to say so, must type when typed into.
/// Every path that mints a page breaks and rebuilds the mount to keep
/// it, since the empty state's catcher is a different view from the
/// editor that replaces it, and first responder goes with the catcher
/// when it unmounts. So each of those paths has to hand the keys on.
///
/// What a test can see of that is the asking, not the landing: the
/// landing wants a key window with a mounted editor in it, which is
/// AppKit first-responder timing and stays a hardware step
/// (`docs/qa/hardware-verification.md` §F). The asking is a model
/// decision, and these are the cases it has to get right.
///
/// Nothing here touches a real state file or the login Keychain: every
/// model rests in a temporary directory over an ephemeral credential
/// store (the issue #53 seams).
@MainActor
final class MintFocusTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let suiteName = "companion-mint-focus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return isolatedModel(formFactor: .backdrop, defaults: defaults)
    }

    /// Age past the longest rung and settle the clock the way the armed
    /// timer does, which empties every slot on the strip and leaves the
    /// strip standing (ADR-0017) — the overnight state every mint path
    /// below opens from.
    private func expireEverything(in model: PageModel) {
        model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
    }

    /// A strip of two slots, both empty, with the first one selected.
    private func twoEmptySlots(in model: PageModel) throws -> (first: UInt64, second: UInt64) {
        model.loadStateIfNeeded()
        model.newPage()
        XCTAssertEqual(model.tabs.count, 2)
        expireEverything(in: model)
        XCTAssertNil(model.selectedPageID, "the strip stands, and every slot is empty")
        let first = try XCTUnwrap(model.tabs.first?.id)
        let second = try XCTUnwrap(model.tabs.last?.id)
        model.selection = first
        return (first, second)
    }

    // MARK: The mint on a selection gesture (⌘1–⌘9, a click on the strip)

    func testSelectingAnEmptySlotHandsTheMintedPageTheKeys() throws {
        let model = try makeModel()
        let slots = try twoEmptySlots(in: model)
        model.reportKeys(true, from: .panel)
        let before = model.keyboardHandoffs

        model.select(slots.second)

        XCTAssertNotNil(model.selectedPageID, "the gesture minted into the slot it landed on")
        XCTAssertEqual(
            model.keyboardHandoffs, before + 1,
            "the empty state gave way to a fresh editor and nobody handed it the keyboard"
        )
    }

    func testSelectingAnEmptySlotOnAnUnkeyedSurfaceTakesNothing() throws {
        let model = try makeModel()
        let slots = try twoEmptySlots(in: model)
        model.reportKeys(false, from: .panel)
        let before = model.keyboardHandoffs

        model.select(slots.second)

        XCTAssertNotNil(model.selectedPageID, "the page is still minted")
        XCTAssertEqual(
            model.keyboardHandoffs, before,
            "the law accepts keys an earlier act conferred and never seizes them"
        )
    }

    func testSwitchingBetweenTwoLivePagesAsksForNothing() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let first = try XCTUnwrap(model.selection)
        model.newPage()
        let second = try XCTUnwrap(model.selection)
        XCTAssertNotEqual(first, second)
        model.reportKeys(true, from: .panel)
        let before = model.keyboardHandoffs

        model.select(first)

        XCTAssertEqual(
            model.keyboardHandoffs, before,
            """
            a page-to-page switch keeps its one persistent editor and swaps the storage \
            underneath it (ADR-0006), so focus never left and there is nothing to hand back
            """
        )
    }

    // MARK: The mint on the ⌥⌘←/→ walk

    func testSteppingOntoAnEmptySlotHandsTheMintedPageTheKeys() throws {
        let model = try makeModel()
        _ = try twoEmptySlots(in: model)
        model.reportKeys(true, from: .panel)
        let before = model.keyboardHandoffs

        model.step(1)

        XCTAssertNotNil(model.selectedPageID)
        XCTAssertEqual(model.keyboardHandoffs, before + 1)
    }

    func testSteppingOntoAnEmptySlotUnkeyedTakesNothing() throws {
        let model = try makeModel()
        _ = try twoEmptySlots(in: model)
        model.reportKeys(false, from: .panel)
        let before = model.keyboardHandoffs

        model.step(1)

        XCTAssertNotNil(model.selectedPageID)
        XCTAssertEqual(model.keyboardHandoffs, before)
    }

    /// The walk still leaves the ledger the way it always did, and a
    /// step that both leaves the ledger and mints asks once rather than
    /// twice: there is one editor coming, so there is one hand-off.
    func testAStepThatLeavesTheLedgerAndMintsAsksOnce() throws {
        let model = try makeModel()
        _ = try twoEmptySlots(in: model)
        model.reportKeys(true, from: .panel)
        model.showLedger()
        let before = model.keyboardHandoffs

        model.step(1)

        XCTAssertFalse(model.showingLedger)
        XCTAssertNotNil(model.selectedPageID)
        XCTAssertEqual(model.keyboardHandoffs, before + 1)
    }

    // MARK: The paths that were already right, kept honest

    func testConjuringAPageHandsItTheKeys() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.reportKeys(true, from: .panel)
        let before = model.keyboardHandoffs

        model.newPage()

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.keyboardHandoffs, before + 1, "⌥⌘N and the + tab (issue #22)")
    }

    func testConjuringAPageOnAnUnkeyedSurfaceTakesNothing() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.reportKeys(false, from: .panel)
        let before = model.keyboardHandoffs

        model.newPage()

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.keyboardHandoffs, before)
    }

    func testLeavingTheLedgerHandsThePageBackTheKeys() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let tab = try XCTUnwrap(model.selection)
        model.reportKeys(true, from: .panel)
        model.showLedger()
        let before = model.keyboardHandoffs

        model.select(tab)

        XCTAssertFalse(model.showingLedger)
        XCTAssertEqual(
            model.keyboardHandoffs, before + 1,
            "the ledger unmounted the editor; returning rebuilds it, and it mounts unfocused"
        )
    }

    // MARK: The draft a dying page leaves behind (issue #22, second finding)

    /// The live counterpart to `FocusLawTests`'s pure `isRefreshOrphan`
    /// cases: a concealed chip whose own page expires while another page
    /// stays open must not leave the confirmation standing, or a stray
    /// ↩ ("Create link" carries the default action) fires a network
    /// call for bytes that no longer exist.
    func testAConcealedChipOnAnExpiringPageClearsItsDraftWhileOtherPagesRemain() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let doomedTab = try XCTUnwrap(model.selection)
        let chip = try XCTUnwrap(
            model.sealText("hunter2", replacing: NSRange(location: 0, length: 0))
        )
        model.beginConceal(.chip(chip.chipId))
        XCTAssertNotNil(model.concealDraft)

        // A second page, so the strip still holds a live one once the
        // chip's page dies. Both slots open on the form factor's rung,
        // so the doomed one is walked down the ladder to give the two
        // different deaths; the walk resets its clock, and what it has
        // left afterwards is what the ageing has to cover.
        model.newPage()
        let survivor = try XCTUnwrap(model.selectedPageID)
        for _ in 0..<5 { model.cycleRung(doomedTab) }
        let doomedRemaining = try XCTUnwrap(model.tabs.first { $0.id == doomedTab }?.remainingMs)
        let survivorRemaining = try XCTUnwrap(
            model.tabs.first { $0.pageID == survivor }?.remainingMs
        )
        let ageBy = doomedRemaining + 60_000
        XCTAssertGreaterThan(survivorRemaining, ageBy, "the survivor has to outlive the ageing")

        model.coreClient.ageForTests(byMs: ageBy)
        model.coreClient.expireDue()
        model.refresh()

        XCTAssertNil(
            model.tabs.first { $0.id == doomedTab }?.pageID, "the chip's own page is gone"
        )
        XCTAssertEqual(model.selectedPageID, survivor, "and another page is still open")
        XCTAssertNil(
            model.concealDraft,
            "the chip rides on no live page, so its confirmation must not still answer ↩"
        )
    }
}
