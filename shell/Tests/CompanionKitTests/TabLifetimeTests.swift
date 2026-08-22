import XCTest

@testable import CompanionKit

/// What a tab does when its page dies (ADR-0017), driven against the
/// live core through a real `PageModel`. Every state here is on the far
/// side of a countdown, so each test ages the store the way a relaunch
/// after a night away ages it (`ageForTests(byMs:)`) and then settles
/// the clock through the same `expireDue()` the armed timer calls.
///
/// Nothing touches a real state file or the login Keychain: the model
/// is built over a temporary directory with an ephemeral credential
/// store, which is the issue #53 seam.
@MainActor
final class TabLifetimeTests: XCTestCase {
    private func makeModel() throws -> PageModel {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-tabs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        return PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir,
                client: .ephemeral(tag: "tabs-\(UUID().uuidString)"),
                saveDebounce: 0.05
            )
        )
    }

    /// Let every page's countdown run out, without waiting for it: age
    /// past the longest rung, then settle the clock through the shell's
    /// own path.
    private func expireEverything(in model: PageModel) {
        model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
    }

    /// The user visible outcome the whole split exists for: the tab
    /// stays on the strip, empty and named, and nothing is minted to
    /// replace the page that died.
    func testAnExpiredPageLeavesItsTabStandingAndEmpty() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let tab = try XCTUnwrap(model.selection)
        model.renameTab(tab, to: "payroll")
        XCTAssertNotNil(model.selectedPageID)

        expireEverything(in: model)

        XCTAssertEqual(model.tabs.count, 1, "the slot kept its place on the strip")
        XCTAssertEqual(model.selection, tab, "and kept the selection")
        XCTAssertFalse(try XCTUnwrap(model.tabs.first).hasPage)
        XCTAssertNil(model.selectedPageID, "the page is gone, and nothing replaced it")
        XCTAssertEqual(model.tabs.first?.title, "payroll", "the name outlived the page")

        // A refresh is not a gesture: reconciling the selection over an
        // empty tab must never mint, or a page expiring under the
        // user's cursor would start a fresh countdown on nothing.
        model.refresh()
        model.refresh()
        XCTAssertNil(model.selectedPageID)
    }

    /// The re-key, which is the split's one real correctness trap. A
    /// reused tab must not hand its new page the dead one's text
    /// storage or undo stack: an attachment character for a zeroized
    /// chip within reach of ⌘Z is the resurrection ADR-0009 closed.
    func testAReusedTabGivesItsNextPageAFreshStorageAndUndoStack() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let tab = try XCTUnwrap(model.selection)
        let firstPage = try XCTUnwrap(model.selectedPageID)

        let storage = model.storage(for: firstPage)
        storage.append(NSAttributedString(string: "rotate the deploy key"))
        let undo = model.undoManager(for: firstPage)
        XCTAssertFalse(storage.string.isEmpty)

        expireEverything(in: model)

        // Selecting the empty slot is one of the three gestures that
        // mint, so the tab is reused here rather than replaced.
        model.select(tab)
        let secondPage = try XCTUnwrap(model.selectedPageID)
        XCTAssertNotEqual(secondPage, firstPage, "a reused slot holds a new page")
        XCTAssertEqual(model.tabs.count, 1, "and no new slot")
        XCTAssertTrue(
            model.storage(for: secondPage).string.isEmpty,
            "the replacement page inherited the dead page's ink"
        )
        XCTAssertFalse(
            model.undoManager(for: secondPage) === undo,
            "the replacement page inherited the dead page's undo stack"
        )
    }

    /// Burning the local copy after a promotion names the page and
    /// nothing else. The slot it travelled from is the arrangement the
    /// user built, and only a close and the cap end a tab (ADR-0017),
    /// so the burn leaves the same empty named slot an expiry leaves.
    func testBurningAPromotedPageLeavesItsTabNamedAndEmpty() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        let tab = try XCTUnwrap(model.selection)
        let page = try XCTUnwrap(model.selectedPageID)
        model.renameTab(tab, to: "payroll")
        XCTAssertTrue(
            model.coreClient.syncDocument(
                sheet: page, json: #"[{"ink": "the credentials"}]"#))

        // The state a successful promotion leaves: a receipt in hand
        // and the offer to be rid of the copy that travelled.
        var draft = PromotionDraft(target: .page(page), ttlSecs: 3600)
        draft.receiptId = "receipt-for-the-burn"
        model.promotion = draft
        model.burnPromotedCopy()

        XCTAssertNil(model.promotion, "the offer is spent")
        XCTAssertEqual(model.tabs.count, 2, "the strip kept its width")
        XCTAssertEqual(model.selection, tab, "and its selection")
        XCTAssertFalse(try XCTUnwrap(model.tabs.last).hasPage, "the page burned")
        XCTAssertEqual(model.tabs.last?.title, "payroll", "the name outlived it")
        XCTAssertNil(model.selectedPageID)

        // The burn is a discard, recorded as one.
        XCTAssertEqual(model.coreClient.ledger().first?.event, "discarded")
        XCTAssertEqual(model.coreClient.ledger().first?.title, "payroll")
    }

    /// ⌘1 through ⌘9 index slots, not live pages, so ⌘2 means the same
    /// slot next week and lands on it whether or not it holds a page.
    func testCommandNumberIndexesSlotsAndOpensIntoAnEmptyOne() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        XCTAssertEqual(model.tabs.count, 3)

        expireEverything(in: model)
        XCTAssertEqual(model.tabs.count, 3, "three slots, none of them holding a page")
        XCTAssertTrue(model.tabs.allSatisfy { !$0.hasPage })

        let second = model.tabs[1].id
        model.select(index: 1)
        XCTAssertEqual(model.selection, second)
        XCTAssertNotNil(model.selectedPageID, "⌘2 on an empty slot opens a page into it")
        XCTAssertEqual(model.tabs.count, 3, "and does not widen the strip")
        XCTAssertFalse(model.tabs[0].hasPage, "the other slots are untouched")
        XCTAssertFalse(model.tabs[2].hasPage)

        // ⌥⌘→ steps slots the same way, and mints into the one it lands
        // on. An index past the end is a no-op rather than a mint.
        model.step(1)
        XCTAssertEqual(model.selection, model.tabs[2].id)
        XCTAssertNotNil(model.selectedPageID)
        model.select(index: 7)
        XCTAssertEqual(model.selection, model.tabs[2].id, "no such slot, no move")
        XCTAssertEqual(model.tabs.count, 3)
    }

    /// The create grant follows the selection: a selected empty slot
    /// offers the create surface while another slot holds a page, and
    /// Return opens a page into that slot rather than widening the
    /// strip.
    func testTheCreateGrantFollowsTheSelectedTab() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        expireEverything(in: model)
        model.select(model.tabs[0].id) // mints into the first slot only

        model.selection = model.tabs[1].id
        XCTAssertTrue(
            model.selectedTabHoldsNoPage,
            "the strip holds a page, but the selected slot does not"
        )
        XCTAssertTrue(
            PageModel.shouldOfferEnterCreate(
                selectedTabHoldsNoPage: model.selectedTabHoldsNoPage, holdsKeys: true))

        model.createPageAndFocus(in: nil)
        XCTAssertEqual(model.tabs.count, 2, "Return opened a page, it did not add a slot")
        XCTAssertNotNil(model.selectedPageID)
        XCTAssertFalse(model.selectedTabHoldsNoPage)
    }

    /// The restore path is the one that would make a relaunch mint. It
    /// takes "no tabs remain" and never "no tab holds a page", so the
    /// morning after an overnight expiry opens on the strip the user
    /// left, empty and named, rather than on a fresh countdown in a
    /// slot nobody selected.
    func testRelaunchAfterAnOvernightExpiryMintsNothing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-tabs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tag = "tabs-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        func launch() -> PageModel {
            PageModel(
                formFactor: .panel,
                defaults: defaults,
                seams: .init(
                    stateDirectory: tempDir, client: .ephemeral(tag: tag), saveDebounce: 0.05
                )
            )
        }

        let evening = launch()
        evening.loadStateIfNeeded()
        evening.renameTab(try XCTUnwrap(evening.selection), to: "payroll")
        expireEverything(in: evening)
        XCTAssertTrue(evening.saveState(), "the empty strip is sealed, not dropped")

        let stateFile = FormFactor.stateFileURL(in: tempDir)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.path),
            "a strip with tabs left has names, rungs and an order to reseal"
        )

        let morning = launch()
        morning.loadStateIfNeeded()
        XCTAssertEqual(morning.tabs.count, 1, "the tab came back")
        XCTAssertEqual(morning.tabs.first?.title, "payroll", "with its name")
        XCTAssertFalse(
            try XCTUnwrap(morning.tabs.first).hasPage,
            "a relaunch minted a page into a tab the user never selected"
        )
        XCTAssertNil(morning.selectedPageID)
        XCTAssertEqual(morning.selection, morning.tabs.first?.id, "and it is selected")
    }

    /// The other predicate's write, and the one that keeps the
    /// forgetting claim true (ADR-0016 section 6, ADR-0017). When the
    /// last page expires and tabs remain, the save rotates both content
    /// key halves and reseals the strip under new ones, so every
    /// ciphertext generation the pages lived in stops being decryptable
    /// at that moment rather than resting beside the new one under the
    /// same key.
    func testAnEmptiedPadRotatesItsKeyAndReselsTheStrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suiteName = "companion-tabs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tag = "tabs-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        // The 0600 file half rests beside the ciphertext under a name
        // derived from its keychain partner, so a new name is a rotation
        // that actually happened rather than one the shell reported.
        func fileHalfName() throws -> String? {
            try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                .first { $0.hasPrefix("ots-companion-key-half-") }
        }

        let model = PageModel(
            formFactor: .panel,
            defaults: defaults,
            seams: .init(
                stateDirectory: tempDir, client: .ephemeral(tag: tag), saveDebounce: 0.05
            )
        )
        model.loadStateIfNeeded()
        let page = try XCTUnwrap(model.selectedPageID)
        model.renameTab(try XCTUnwrap(model.selection), to: "payroll")
        XCTAssertTrue(
            model.coreClient.syncDocument(sheet: page, json: #"[{"ink": "the credentials"}]"#))
        XCTAssertTrue(model.saveState())

        let stateFile = FormFactor.stateFileURL(in: tempDir)
        let generationHoldingThePage = try Data(contentsOf: stateFile)
        let halfBefore = try XCTUnwrap(fileHalfName())

        expireEverything(in: model)
        XCTAssertTrue(model.saveState(), "the strip is resealed, not dropped")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.path),
            "the names, rungs and order have to live somewhere"
        )
        XCTAssertNotEqual(
            try XCTUnwrap(fileHalfName()), halfBefore,
            "the emptied pad stayed on the halves its pages were sealed under"
        )

        // What the rotation bought: put the generation the page lived in
        // back at the path and nothing can open it, in this session or
        // any later one.
        try generationHoldingThePage.write(to: stateFile)
        let ghost = CompanionClient.ephemeral(tag: tag)
        XCTAssertFalse(
            ghost.persistRestore(from: stateFile.path),
            "a generation sealed before the rotation opened after it"
        )
    }

    /// Double-clicking a slot whose page expired overnight: the first
    /// tap mints a page and the second must not freeze the countdown of
    /// the page it just made. Selecting mints (ADR-0017), so the tap
    /// that used to be harmless now creates the thing the next tap
    /// would hold.
    func testADoubleClickOnAnEmptySlotLeavesTheFreshPageRunning() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let tab = try XCTUnwrap(model.selection)

        // The control: a hold on a page the gesture did not mint lands.
        model.pause(tab)
        XCTAssertTrue(try XCTUnwrap(model.tabs.first).paused)
        model.pause(tab)
        model.pause(tab) // topped up, then released
        XCTAssertFalse(try XCTUnwrap(model.tabs.first).paused)

        expireEverything(in: model)
        model.select(tab) // the first tap
        model.pause(tab) // the second tap, on a page a moment old
        XCTAssertNotNil(model.selectedPageID, "the first tap opened a page")
        XCTAssertFalse(
            try XCTUnwrap(model.tabs.first).paused,
            "a double-click on an empty slot held the page it had just minted"
        )
    }

    /// Closing the last tab is what empties the strip, and only then is
    /// there nothing left to seal. The two predicates disagree in
    /// between, which is the whole reason they are separate.
    func testOnlyClosingEveryTabLeavesNothingToReseal() throws {
        let model = try makeModel()
        model.loadStateIfNeeded()
        let tab = try XCTUnwrap(model.selection)

        expireEverything(in: model)
        let afterExpiry = try XCTUnwrap(model.coreClient.emptiness())
        XCTAssertTrue(afterExpiry.holdsNoPage, "no page is staged")
        XCTAssertFalse(afterExpiry.hasNoTabs, "but the slot is still there")
        XCTAssertFalse(
            PageModel.erasesContentFile(
                loaded: true, contentLicence: true, noTabsRemain: afterExpiry.hasNoTabs),
            "an expiry must not drop the file the strip lives in"
        )
        XCTAssertTrue(
            PageModel.rotatesContentKey(
                loaded: true, contentLicence: true, holdsNoPage: afterExpiry.holdsNoPage,
                noTabsRemain: afterExpiry.hasNoTabs),
            "and it must rotate the halves the dead pages were sealed under"
        )

        model.close(tab)
        let afterClose = try XCTUnwrap(model.coreClient.emptiness())
        XCTAssertTrue(afterClose.holdsNoPage)
        XCTAssertTrue(afterClose.hasNoTabs)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertTrue(
            PageModel.erasesContentFile(
                loaded: true, contentLicence: true, noTabsRemain: afterClose.hasNoTabs))
        XCTAssertFalse(
            PageModel.rotatesContentKey(
                loaded: true, contentLicence: true, holdsNoPage: afterClose.holdsNoPage,
                noTabsRemain: afterClose.hasNoTabs),
            "with no strip left to reseal the file goes instead"
        )
    }
}

/// What an empty slot offers, and what it must not. A tab whose page
/// expired keeps every gesture that belongs to the slot (select,
/// rename, re-rung, close) and none that belongs to a clock it no
/// longer has (ADR-0017).
@MainActor
final class EmptySlotGestureTests: XCTestCase {
    func testTheHoldItemNamesTheTurnOfTheCycleItWillTake() {
        XCTAssertEqual(
            SheetTab.holdMenuTitle(paused: false, toppedUp: false), "Hold the clock for 1h")
        XCTAssertEqual(
            SheetTab.holdMenuTitle(paused: true, toppedUp: false), "Top the hold up to 24h")
        XCTAssertEqual(SheetTab.holdMenuTitle(paused: true, toppedUp: true), "Release the hold")
    }

    /// On an empty slot the gesture sets the rung the next page is born
    /// at, which is not a countdown being shortened.
    func testTheRungItemSaysWhichClockItShortens() {
        XCTAssertEqual(SheetTab.rungMenuTitle(hasPage: true), "Shorten the countdown")
        XCTAssertEqual(
            SheetTab.rungMenuTitle(hasPage: false), "Shorten the next page's countdown")
    }

    /// The double-click on an empty slot, in the model where the
    /// refusal lives: the first tap mints, and the hold the second tap
    /// would put on that fresh page is not the user's intent.
    func testAHoldIsRefusedOnThePageTheTapBeforeItMinted() {
        XCTAssertTrue(
            PageModel.holdWouldStrikeItsOwnMint(
                tab: 7, mintedTab: 7, elapsed: 0.1, within: 0.5))
        // A different slot, a deliberate hold seconds later, and a
        // gesture that minted nothing all go through.
        XCTAssertFalse(
            PageModel.holdWouldStrikeItsOwnMint(
                tab: 7, mintedTab: 8, elapsed: 0.1, within: 0.5))
        XCTAssertFalse(
            PageModel.holdWouldStrikeItsOwnMint(
                tab: 7, mintedTab: 7, elapsed: 4.0, within: 0.5))
        XCTAssertFalse(
            PageModel.holdWouldStrikeItsOwnMint(
                tab: 7, mintedTab: nil, elapsed: 0.1, within: 0.5))
    }
}
