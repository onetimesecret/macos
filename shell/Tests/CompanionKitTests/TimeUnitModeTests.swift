import XCTest

@testable import CompanionKit

/// What the time-unit mode does to a live pad and (the larger half of
/// the claim) what it does not (issue #79).
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
    /// these, and a run that happened to straddle local midnight would
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
    /// than as a promise: with the mode off, the list ⌘1 to ⌘9 and ⌥⌘←/→
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
    /// here, one boolean, in `UserDefaults`, and nothing durable
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
    /// through the shipped create path, selected, and exactly one, so
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

    /// And again from elsewhere, which must be a jump. `select(_:)`
    /// cannot mint into an occupied slot, so today's page stays the one
    /// page today has: no mint-target heuristic, and nothing that would
    /// surprise the user who flips back to the strip.
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

    /// First press jumps, second press creates (issue #158). On today's
    /// page, ⌘N mints a second page, the projection files it under
    /// today beside the first in strip order, and the selection moves
    /// onto the new page so the next keystroke lands there. Blank or
    /// written on makes no difference, exactly as on the strip.
    func testOpenTodayOnTodaysPageMintsASecondPageOnToday() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        model.openToday()
        let first = try XCTUnwrap(model.selectedPageID)
        let firstTab = try XCTUnwrap(model.selection)
        XCTAssertEqual(try XCTUnwrap(model.selectedTab).pageHasContent, false)

        model.openToday()

        XCTAssertEqual(model.tabs.count, 2, "⌘N on today's page did not mint")
        let second = try XCTUnwrap(model.selectedPageID)
        XCTAssertNotEqual(second, first, "the selection stayed on the first page")
        XCTAssertNotEqual(model.selection, firstTab)
        XCTAssertEqual(peopledDays(model.timeUnits).count, 1, "the second page landed on another day")
        XCTAssertEqual(
            peopledDays(model.timeUnits).first?.pageIDs, [first, second],
            "today does not list both pages in strip order")
        XCTAssertNil(model.notice, "nothing was refused")

        // Written on, the same: a third page beside the two.
        try type("morning", into: second, on: model)
        model.openToday()
        XCTAssertEqual(model.tabs.count, 3, "⌘N on a written page did not mint")
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs.count, 3)
    }

    /// The same reading under the chord itself, through the dispatch
    /// the keymap uses, and with the strip showing the chord still does
    /// what it always did: a new slot every time.
    func testThePageNewCommandMintsOnTodayAndOnTheStripAlike() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        model.perform(.pageNew)
        model.perform(.pageNew)
        XCTAssertEqual(model.tabs.count, 2, "the chord did not mint on today's page")
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs.count, 2)

        model.showsTimeUnits = false
        model.perform(.pageNew)
        model.perform(.pageNew)
        XCTAssertEqual(model.tabs.count, 4, "the strip's reading of ⌘N changed")
    }

    /// A file or the ledger in front of today's page makes ⌘N a jump
    /// back onto that page, not a second page: the person is not on
    /// today's page when something else is on screen, however the
    /// selection reads underneath.
    func testOpenTodayFromTheLedgerReturnsToTodaysPageWithoutMinting() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        model.openToday()
        let page = try XCTUnwrap(model.selectedPageID)
        try type("evening", into: page, on: model)
        model.showingLedger = true

        model.openToday()

        XCTAssertFalse(model.showingLedger, "⌘N left the ledger up")
        XCTAssertEqual(model.tabs.count, 1, "⌘N from the ledger minted a page")
        XCTAssertEqual(model.selectedPageID, page)
    }

    /// One typed insertion through the seam the editor uses, so the
    /// ledger's content bar is what flips and not a fixture.
    private func type(_ text: String, into page: UInt64, on model: PageModel) throws {
        let ops = try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: text)]))
        model.applyOps(sheet: page, opsJSON: ops)
    }

    /// The trap the cap used to set, sprung (issue #158). Nine empty
    /// slots draw no rows at all, so the strip a tab would have been
    /// closed from is not on screen; today's page opens anyway, as a
    /// tenth slot, and no notice names a wall. Nothing is auto-discarded
    /// to make room, because the nine are still standing afterwards.
    func testNineEmptySlotsDoNotStandBetweenAPersonAndToday() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        for _ in 1..<9 { model.newPage() }
        XCTAssertEqual(model.tabs.count, 9)
        expireEverything(in: model)
        model.showsTimeUnits = true
        XCTAssertEqual(model.timeUnits.units.map(\.bucket), [0], "every slot is empty, so no day")
        XCTAssertEqual(model.timeUnits.hiddenBlankPages, 0, "an empty slot is not a page in hiding")

        model.openToday()

        XCTAssertEqual(model.tabs.count, 10, "a tenth slot was refused")
        let page = try XCTUnwrap(model.selectedPageID, "today's page was not minted")
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs, [page])
        XCTAssertNil(model.notice, "a wall was named")
        XCTAssertEqual(
            model.tabs.filter { !$0.hasPage }.count, 9,
            "an empty slot was discarded to make room")

        // ⌘1 to ⌘9 still count the first nine visible targets, and the
        // strip's reading is a slot per chord whatever the strip's width.
        model.showsTimeUnits = false
        XCTAssertEqual(model.visibleTargets.count, 10)
        model.perform(.pageSelect9)
        XCTAssertEqual(model.selection, model.tabs[8].id, "⌘9 stopped reaching the ninth slot")
    }

    // MARK: The jump chords, in both readings

    /// ⌘1 with the days down the side lands on today, and today is a
    /// place rather than a page: on a pad with nothing on it the chord
    /// takes the shipped create path instead of finding nothing to
    /// select. That is a gesture minting, which is the only kind there
    /// is (ADR-0017), and the second press is a jump, so the chord
    /// cannot stack blank pages up.
    func testTheFirstJumpChordLandsOnTodayAndCreatesWhenTodayIsEmpty() throws {
        let (model, _) = try makeModel()
        model.showsTimeUnits = true
        XCTAssertTrue(model.tabs.isEmpty, "the pad starts with nothing on it")
        XCTAssertEqual(model.visibleTargets, [.today])

        model.perform(.pageSelect1)

        XCTAssertEqual(model.tabs.count, 1, "⌘1 on an empty today made no page")
        let page = try XCTUnwrap(model.selectedPageID)
        XCTAssertEqual(peopledDays(model.timeUnits).first?.pageIDs, [page])
        XCTAssertNil(model.notice, "nothing was refused")

        model.perform(.pageSelect1)
        XCTAssertEqual(model.tabs.count, 1, "a second ⌘1 widened the pad")
        XCTAssertEqual(model.selectedPageID, page)
    }

    /// ⌘2 counts days too, and a pad whose pages were all written today
    /// has one day: the chord has nowhere to go, where with the strip
    /// showing it lands on the second slot. That contrast is the whole
    /// reinterpretation, stated on the only shape a test can build,
    /// no Swift test can move a page across a local midnight, because
    /// the ageing seam restores a snapshot with every creation stamp
    /// intact.
    func testTheSecondJumpChordCountsDaysAndNotSlots() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        let first = try XCTUnwrap(model.tabs.first?.id)
        model.select(first)
        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(peopledDays(model.timeUnits).count, 1, "one session, one day")

        model.showsTimeUnits = true
        model.perform(.pageSelect2)
        XCTAssertEqual(model.selection, first, "⌘2 counted slots while the days were showing")

        model.showsTimeUnits = false
        model.perform(.pageSelect2)
        XCTAssertEqual(
            model.selection, model.tabs[1].id, "⌘2 stopped counting slots with the mode off")
        XCTAssertEqual(model.tabs.count, 3, "a jump minted or closed something")
    }

    /// And ⌥⌘→ walks days rather than slots. On a pad written in one
    /// sitting the walk stays where it is, where the strip's walk moves
    /// along one slot; both readings clamp at the end rather than
    /// wrapping, which is the walk the app has always had.
    func testTheStepChordWalksDaysWhileTheModeIsOn() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        let first = try XCTUnwrap(model.tabs.first?.id)
        model.select(first)

        model.showsTimeUnits = true
        model.perform(.pageNext)
        XCTAssertEqual(model.selection, first, "the walk stepped a slot while the days showed")

        model.showsTimeUnits = false
        model.perform(.pageNext)
        XCTAssertEqual(model.selection, model.tabs[1].id, "the walk stopped stepping slots")
    }

    /// With the mode off all three chords do what they always did: ⌘1
    /// the first slot, ⌘2 the second, ⌥⌘→ the next one along. This is
    /// the identity `visibleTargets` promises, pressed as keystrokes
    /// rather than read off an array.
    func testWithTheModeOffTheThreeChordsLandOnTheStrip() throws {
        let (model, _) = try makeModel()
        model.loadStateIfNeeded()
        model.newPage()
        model.newPage()
        XCTAssertFalse(model.showsTimeUnits, "the prototype must be off unless it is asked for")

        model.perform(.pageSelect1)
        XCTAssertEqual(model.selection, model.tabs[0].id)
        model.perform(.pageSelect2)
        XCTAssertEqual(model.selection, model.tabs[1].id)
        model.perform(.pageNext)
        XCTAssertEqual(model.selection, model.tabs[2].id)
        XCTAssertEqual(model.tabs.count, 3, "a jump minted or closed something")
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
    /// selection falls to the newest page that is visible, and neither
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
    /// is (the page died overnight) and it used to open the mode with
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
    /// falls nothing at all, because the strip draws every slot, the
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

    // MARK: The chord the mode takes away

    /// ⌥Z with the days down the side. The roll wraps every day whatever
    /// the preference says, so the chord cannot do what it is for, and
    /// what it must not do instead is rewrite the stored preference
    /// under a surface that will not honour it, which would leave the
    /// flash claiming one thing while every line went on wrapping and
    /// hand horizontal mode back unwrapped later. It says so instead,
    /// and the same press with the mode off still does exactly what it
    /// always did.
    func testTheWrapChordIsRefusedInTheModeAndLeavesThePreferenceAlone() throws {
        let (model, defaults) = try makeModel()
        model.loadStateIfNeeded()
        let wrapped = model.wrapsLines
        model.showsTimeUnits = true

        model.perform(.editorToggleWrap)

        XCTAssertEqual(model.wrapsLines, wrapped, "⌥Z rewrote a preference the roll does not read")
        XCTAssertEqual(
            isolatedModel(defaults: defaults).wrapsLines, wrapped,
            "the stored preference moved under a surface that ignores it")
        XCTAssertEqual(model.notice, PageModel.wrapIsFixedNotice, "the keystroke went out dead")

        model.showsTimeUnits = false
        model.perform(.editorToggleWrap)
        XCTAssertNotEqual(model.wrapsLines, wrapped, "the chord stayed refused with the mode off")
    }

    /// "Strip" and "rail" are the code names for the two navigations
    /// and never reach the UI (D-26). The caption also owes the reader
    /// the two costs of the mode, and this pins that it names both.
    func testTheDaysCaptionNamesNoCodeWords() {
        let caption = GeneralSettingsView.timeUnitsCaption
        let words = caption.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        XCTAssertFalse(words.contains("strip"), caption)
        XCTAssertFalse(words.contains("rail"), caption)
        XCTAssertTrue(caption.contains("Lines always wrap while days are showing."))
        XCTAssertTrue(caption.contains("counted at the foot of the column"))
    }
}
