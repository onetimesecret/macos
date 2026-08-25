import XCTest

@testable import CompanionKit

/// What the time-unit mode does to a live pad, and — the larger half of
/// the claim — what it does not (issue #79).
///
/// The mode is a way of looking at the same pages, so the load-bearing
/// assertions here are negative ones: with it off nothing about the
/// existing paths changes, and flipping it in either direction moves no
/// core state, arms no write and buys no fresh sealed generation. Every
/// model below rests in a temporary directory over an ephemeral
/// credential store (the issue #53 seams), so nothing here touches a real
/// state file or the login Keychain.
@MainActor
final class TimeUnitModeTests: XCTestCase {
    private func makeModel() throws -> (model: PageModel, defaults: UserDefaults) {
        let suite = "companion-time-units-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (isolatedModel(defaults: defaults), defaults)
    }

    /// Age past the longest rung and settle the clock the way the armed
    /// timer does: every slot on the strip is emptied and the strip
    /// stands (ADR-0017).
    private func expireEverything(in model: PageModel) {
        model.coreClient.ageForTests(byMs: 8 * 24 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
    }

    /// The days that actually hold pages. Today has a row whether or not
    /// anything is on it, so a claim about grouping is a claim about
    /// these — and a run that happened to straddle local midnight would
    /// otherwise turn one honest day into two rows.
    private func peopledDays(_ projection: TimeUnitProjection) -> [TimeUnitProjection.Unit] {
        projection.units.filter { !$0.pageIDs.isEmpty }
    }

    /// What a reading of the strip says about the pad, minus the
    /// countdowns. The clocks tick between any two readings and that is
    /// the clock doing its job; what a presentation toggle must not move
    /// is the slots, their pages, their names, their rungs and the two
    /// facts the day model reads.
    private func witness(_ tabs: [TabSummary]) -> [String] {
        tabs.map { tab in
            let page = tab.pageID.map(String.init) ?? "none"
            let day = tab.pageDayOffset.map(String.init) ?? "none"
            return "\(tab.id)/\(page)/\(tab.title)/\(tab.rungCode)/\(tab.pageHasContent)/\(day)"
        }
    }

    // MARK: The identity that protects horizontal mode

    /// The branch's load-bearing claim, stated as an assertion rather
    /// than as a promise: with the mode off, the list ⌘1–⌘9 and ⌥⌘←/→
    /// index is the strip, element for element. The two modes share one
    /// routing path instead of two that would have to be kept in step,
    /// and this is what makes the sharing safe.
    func testVisibleTargetsWithTheModeOffEqualTheStripElementForElement() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        XCTAssertFalse(model.showsTimeUnits, "the prototype must be off unless it is asked for")
        XCTAssertEqual(model.visibleTargets, model.tabs.map { SurfaceTarget.tab($0.id) })

        // The same after every slot has been emptied, which is where the
        // two modes disagree most: a slot holding no page is still a
        // target on the strip and no row at all on the rail.
        expireEverything(in: model)
        XCTAssertEqual(model.visibleTargets, model.tabs.map { SurfaceTarget.tab($0.id) })

        // And the gestures still land where they always did.
        model.select(index: 1)
        XCTAssertEqual(model.selection, model.tabs[1].id)
        model.step(1)
        XCTAssertEqual(model.selection, model.tabs[2].id)
        model.step(1)
        XCTAssertEqual(model.selection, model.tabs[2].id, "the walk wrapped instead of holding")
        model.select(index: 7)
        XCTAssertEqual(model.selection, model.tabs[2].id, "no such slot, no move")
    }

    /// And with the mode on the same gestures count days instead. Three
    /// pages made in one session are three slots on the strip and one
    /// day on the rail, which is the whole reinterpretation in one
    /// assertion.
    func testWithTheModeOnTheTargetsAreDaysRatherThanSlots() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        model.showsTimeUnits = true

        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(peopledDays(model.timeUnits).count, 1, "one session, one day")
        XCTAssertEqual(model.visibleTargets, [.tab(model.tabs[0].id)])
        XCTAssertEqual(peopledDays(model.timeUnits).first?.tabIDs, model.tabs.map(\.id))
    }

    // MARK: The toggle moves nothing

    /// The safety claim the whole design rests on: flipping the toggle
    /// is a change of view and not a change of state. It writes one
    /// boolean to the injected defaults and leaves the store, the two
    /// emptiness predicates, the selection and the save status exactly
    /// as they were.
    func testFlippingTheToggleBothWaysLeavesTheCoreUntouched() throws {
        let (model, defaults) = try makeModel()
        model.loadStateIfNeeded()
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertTrue(
            model.coreClient.syncDocument(sheet: page, json: #"[{"ink": "the credentials"}]"#))
        model.refresh()

        let tabs = witness(model.coreClient.tabs())
        let emptiness = try XCTUnwrap(model.coreClient.emptiness())
        let selection = model.selection
        let status = model.saveStatus

        model.showsTimeUnits = true
        XCTAssertTrue(defaults.bool(forKey: "showsTimeUnits"), "the mode did not outlive the flip")
        model.showsTimeUnits = false
        XCTAssertFalse(defaults.bool(forKey: "showsTimeUnits"))

        XCTAssertEqual(witness(model.coreClient.tabs()), tabs, "the toggle moved the strip")
        XCTAssertEqual(model.coreClient.emptiness(), emptiness, "the toggle moved a predicate")
        XCTAssertEqual(model.selection, selection)
        XCTAssertEqual(model.saveStatus, status)
        XCTAssertEqual(
            model.coreClient.documentRuns(sheet: page).count, 1,
            "the toggle went near the page's own document")
    }

    /// And it arms no write. `markDirty` takes the sudden-termination
    /// hold and starts a debounced ciphertext write, so a preference
    /// that moves no core state must not reach it: otherwise looking at
    /// the same pages a second way would buy a fresh sealed generation
    /// every time the user changed their mind. The counter is read where
    /// the arming happens, ahead of the licence guard, which is the only
    /// place the hold is ever taken.
    func testTheToggleMarksNothingDirty() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks

        model.showsTimeUnits = true
        model.refresh()
        model.showsTimeUnits = false
        model.refresh()

        XCTAssertEqual(
            model.dirtyMarks, marks,
            "a presentation preference armed a ciphertext write (ADR-0016 section 6)")
    }

    /// A model built over defaults that already carry the preference
    /// opens in the mode, which is the whole of what "persisted" means
    /// here — one boolean, in `UserDefaults`, and nothing durable
    /// anywhere else.
    func testTheModeIsRememberedInTheDefaultsAndNowhereElse() throws {
        let (first, defaults) = try makeModel()
        XCTAssertFalse(first.showsTimeUnits)
        first.showsTimeUnits = true

        let second = isolatedModel(defaults: defaults)
        XCTAssertTrue(second.showsTimeUnits, "the preference did not survive a relaunch")
    }

    // MARK: Going to today

    /// ⌘N in the mode, on a pad with nothing on it. One page, minted
    /// through the shipped create path, selected — and exactly one, so
    /// the gesture is a jump rather than a stack of blank pages.
    func testOpenTodayOnAnEmptyPadMintsExactlyOnePageAndSelectsIt() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        XCTAssertTrue(model.tabs.isEmpty, "the pad starts with nothing on it")
        XCTAssertEqual(model.timeUnits.units.map(\.bucket), [0], "today is a place all the same")

        model.openToday()

        XCTAssertEqual(model.tabs.count, 1)
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertEqual(peopledDays(model.timeUnits).count, 1)
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs, [page])
        XCTAssertNil(model.notice, "nothing was refused")
    }

    /// And again, which must be a jump. `select(_:)` cannot mint into an
    /// occupied slot, so today's page stays the one page today has: no
    /// mint-target heuristic, and nothing that would surprise the user
    /// who flips back to the strip.
    func testASecondOpenTodayMintsNothingAndSelectsTheSamePage() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        model.openToday()
        let page = try XCTUnwrap(model.selectedPageID)
        let tab = try XCTUnwrap(model.selection)

        model.selection = nil
        model.openToday()

        XCTAssertEqual(model.tabs.count, 1, "a second ⌘N widened the pad")
        XCTAssertEqual(model.selection, tab)
        XCTAssertEqual(model.selectedPageID, page, "today's page was replaced rather than reached")
    }

    /// The cap trap, and the honest answer to it. Nine slots holding old
    /// pages with nothing on them draw no rows at all, so the strip a tab
    /// would be closed from is not on screen; the refusal names the
    /// toggle that brings it back rather than telling the user to wait
    /// for an expiry that frees no slot. Nothing is auto-discarded.
    func testAtTheCapOpenTodayRefusesAndNamesTheToggle() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        for _ in 1..<9 { model.newPage() }
        XCTAssertEqual(model.tabs.count, 9)
        expireEverything(in: model)
        model.showsTimeUnits = true
        XCTAssertEqual(model.timeUnits.units.map(\.bucket), [0], "every slot is empty, so no day")
        XCTAssertEqual(model.timeUnits.hiddenBlankPages, 0, "an empty slot is not a page in hiding")

        model.openToday()

        XCTAssertEqual(model.tabs.count, 9, "the cap gave way")
        XCTAssertNil(model.selectedPageID, "the refusal minted a page anyway")
        XCTAssertEqual(model.notice, PageModel.capRefusal(showsTimeUnits: true))
        XCTAssertTrue(
            try XCTUnwrap(model.notice).contains("Settings"),
            "the refusal did not say where the hidden pages are")
        XCTAssertEqual(
            PageModel.capRefusal(showsTimeUnits: false),
            "the window holds 9 tabs, close one to make room",
            "the sentence the strip has always shown moved")
    }

    // MARK: An expiry under the mode

    /// A page leaving takes its region off the rail and leaves
    /// everything else standing: its neighbours keep their places, and
    /// underneath, every slot is still there, named and empty, because
    /// the calendar ends nothing (ADR-0017). Only the page's own
    /// countdown did.
    func testAnExpiredPageLeavesTheRailWithoutItAndEveryTabStanding() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        model.showsTimeUnits = true
        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs.count, 3)

        // One page on an hour while its neighbours keep the week they
        // were opened at, so the settling below takes that one and no
        // other.
        model.coreClient.setRung(tab: model.tabs[1].id, rung: .oneHour)
        model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()

        XCTAssertEqual(model.tabs.count, 3, "an expiry closed a tab")
        XCTAssertFalse(model.tabs[1].hasPage, "the page that was given an hour outlived it")
        let surviving = [model.tabs[0].pageID, model.tabs[2].pageID].compactMap { $0 }
        XCTAssertEqual(surviving.count, 2, "the neighbours went with it")
        XCTAssertEqual(peopledDays(model.timeUnits).count, 1)
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs, surviving)
    }

    /// Where the selection lands after that expiry, and the fact that
    /// only the mode moves it. The strip keeps the selection on the
    /// emptied slot, because the slot is still on screen and jumping
    /// somebody somewhere they did not ask to go is worse than showing
    /// them an empty state. The rail draws no such slot, so there the
    /// selection falls to the newest page that is visible — and neither
    /// path mints.
    func testOnlyTheModeFallsASelectionOffASlotHoldingNoPage() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.coreClient.setRung(tab: model.tabs[1].id, rung: .oneHour)
        model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        let emptied = model.tabs[1].id
        XCTAssertFalse(model.tabs[1].hasPage)

        model.selection = emptied
        model.refresh()
        XCTAssertEqual(model.selection, emptied, "the strip moved a selection it should have kept")
        XCTAssertNil(model.selectedPageID, "and a refresh minted into it")

        model.showsTimeUnits = true
        model.selection = emptied
        model.refresh()
        XCTAssertEqual(model.selection, model.tabs[0].id, "the rail left the selection off screen")
        XCTAssertEqual(model.tabs.count, 2, "the fall minted or closed something")
        XCTAssertFalse(model.tabs[1].hasPage, "the fall minted into the slot it left")
    }

    /// And the fall applies at the mode's own entrance, not only on the
    /// next refresh to happen along. Turning the toggle on from a
    /// selection standing on an emptied slot is the likeliest flip there
    /// is — the page died overnight — and it used to open the mode with
    /// nothing selected, no editor mounted and no row lit.
    func testTurningTheModeOnFallsASelectionTheRailWouldNotDraw() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.coreClient.setRung(tab: model.tabs[1].id, rung: .oneHour)
        model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        model.selection = model.tabs[1].id
        XCTAssertNil(model.selectedPageID, "the fixture wanted a selection on an emptied slot")
        let marks = model.dirtyMarks

        model.showsTimeUnits = true

        XCTAssertEqual(
            model.selection, model.tabs[0].id,
            "the mode opened on a slot it draws no row for")
        XCTAssertEqual(model.tabs.count, 2, "the toggle minted or closed something")
        XCTAssertFalse(model.tabs[1].hasPage, "the toggle minted into the slot it left")
        XCTAssertEqual(
            model.dirtyMarks, marks,
            "a presentation preference armed a ciphertext write (ADR-0016 section 6)")
    }

    /// The other two directions, which must not move: a selection the
    /// rail does draw is left exactly where it is, and leaving the mode
    /// falls nothing at all, because the strip draws every slot — the
    /// emptied ones included, which is its own deliberate rule.
    func testTheToggleMovesNoSelectionTheSurfaceCanShow() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.coreClient.setRung(tab: model.tabs[1].id, rung: .oneHour)
        model.coreClient.ageForTests(byMs: 2 * 60 * 60 * 1_000)
        model.coreClient.expireDue()
        model.refresh()
        let emptied = model.tabs[1].id
        let peopled = model.tabs[0].id

        model.selection = peopled
        model.showsTimeUnits = true
        XCTAssertEqual(model.selection, peopled, "the toggle moved a selection the rail draws")

        model.selection = emptied
        model.showsTimeUnits = false
        XCTAssertEqual(
            model.selection, emptied,
            "leaving the mode fell a selection the strip draws perfectly well")
    }
}
