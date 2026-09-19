import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The shell state the surface model persists on its own (the pin, the
/// keep-above preference). Every test points at a throwaway defaults
/// suite that names itself uniquely — never the standard suite, never
/// one named after the bundle id (memory: a shared name would erase
/// state from a running install). BackdropModel is @MainActor, so the
/// whole suite is too.
@MainActor
final class BackdropModelTests: XCTestCase {

    /// A defaults suite for one test, cleared at teardown. UUID in the
    /// name because a `UserDefaults` suite persists for the life of the
    /// process even after `removePersistentDomain`, so two runs of the
    /// same test would otherwise read each other's writes.
    private func makeDefaults(named suite: String) -> UserDefaults {
        let name = "onetimepad.test.\(suite).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A PageModel that owns everything it touches: sealed files in a
    /// directory made for this test and removed at teardown, an
    /// ephemeral core handle whose credentials never reach the login
    /// Keychain (ADR-0018). PageModel's init refuses the unseamed
    /// construction under the runner outright; this is the sentence
    /// that answers the refusal for a BackdropModel test that only
    /// cares about the surface's own persistence.
    ///
    /// A presentation write the model declines fails the test that
    /// caused it. The shipping answer is a debug assertion, which would
    /// take the whole run down without saying which sequence did it,
    /// and no sequence in this suite is meant to produce one: the
    /// surface model asks who owns before it writes.
    private func ephemeralPages(defaults: UserDefaults, tag: String) -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backdrop-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        guard let handle = tag.withCString({ companion_new_ephemeral($0) }) else {
            fatalError("the core refused to create an ephemeral handle")
        }
        return PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: CompanionClient(adopting: handle),
                declinedPresentationWrite: { field, surface in
                    XCTFail("\(surface) wrote \(field.rawValue) without owning the page content")
                }
            )
        )
    }

    func testKeepsAboveDefaultsOff() {
        // The release posture: a raised card the app the person is
        // working in can cover, so the preference has to start off.
        let defaults = makeDefaults(named: "keeps-above-default")
        let pages = ephemeralPages(defaults: defaults, tag: "keeps-above-default")
        let model = BackdropModel(defaults: defaults, pages: pages)
        XCTAssertFalse(model.keepsAboveWhenInactive)
    }

    func testKeepsAbovePersistsAcrossReload() {
        // The whole point of the didSet write and the init read: a
        // preference set today is the preference the app finds
        // tomorrow. Two models over the same defaults suite stand in
        // for the two launches; each carries its own ephemeral pages
        // because a shared handle would tangle two tests' state.
        let defaults = makeDefaults(named: "keeps-above-roundtrip")
        let first = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "roundtrip-a")
        )
        first.keepsAboveWhenInactive = true

        let second = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "roundtrip-b")
        )
        XCTAssertTrue(second.keepsAboveWhenInactive)
    }

    func testKeepsAbovePersistsWhenTurnedOffAgain() {
        // The other direction, because a preference that only saved
        // one way is a preference that only accepts opting in.
        let defaults = makeDefaults(named: "keeps-above-off-roundtrip")
        let first = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "off-roundtrip-a")
        )
        first.keepsAboveWhenInactive = true
        first.keepsAboveWhenInactive = false

        let second = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "off-roundtrip-b")
        )
        XCTAssertFalse(second.keepsAboveWhenInactive)
    }

    // MARK: The editor window's entrance

    func testDockOpensEditorWindowDefaultsOffAndPersists() {
        // Off is what lets a build carry the spike without changing
        // what the Dock does for anyone who has not asked.
        let defaults = makeDefaults(named: "dock-opens-editor")
        let first = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "dock-opens-editor-a")
        )
        XCTAssertFalse(first.dockOpensEditorWindow)
        first.dockOpensEditorWindow = true

        let second = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "dock-opens-editor-b")
        )
        XCTAssertTrue(second.dockOpensEditorWindow)
    }

    func testReopenRoutingOverTheWholeMatrix() {
        // Off and closed is the old behaviour, a raise. The case worth
        // the function is off and open: the setting was turned off
        // under an open window, and a reopen still names that window.
        XCTAssertFalse(
            BackdropModel.reopenOpensEditorWindow(preference: false, windowOpen: false))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: false, windowOpen: true))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: true, windowOpen: false))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: true, windowOpen: true))
    }

    // MARK: Who owns the page content (ADR-0033, issue #198)

    /// The rule is `PresentationOwner.resolve`, and its matrix is
    /// tested beside it. What is tested here is the feed: that every
    /// event which moves one of the rule's two facts reaches the shared
    /// model as the right owner, that the one key event which moves
    /// ownership does and no other does, and that the surface model
    /// never writes a presentation field for a window that does not
    /// own (`ephemeralPages` fails the test if it tries).
    ///
    /// No window controller is built. Both of them order real windows
    /// and take the keyboard, so what they decide is in the model and
    /// its pure helpers, and these cases call what the delegates call.
    private func makeModel(named name: String, panelMayOwn: Bool = true) -> BackdropModel {
        let defaults = makeDefaults(named: name)
        return BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: name),
            panelMayOwn: panelMayOwn
        )
    }

    func testWithTheEditorWindowClosedThePanelOwnsRestingOrRaised() {
        let model = makeModel(named: "owner-closed")
        XCTAssertEqual(model.pages.owner, .panel)
        model.raise(.summon)
        XCTAssertEqual(model.pages.owner, .panel)
        model.rest()
        XCTAssertEqual(model.pages.owner, .panel)
    }

    func testOpeningTheEditorWindowBesideARestingPanelGivesItThePage() {
        let model = makeModel(named: "owner-opened-resting")
        model.editorWindowOpened()
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertEqual(model.stance, .resting)
    }

    func testOpeningTheEditorWindowRestsARaisedPanelAndTakesThePage() {
        // The window opening takes the keyboard, and when the editor
        // window takes the keyboard a raised panel rests.
        let model = makeModel(named: "owner-opened-raised")
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)

        model.editorWindowOpened()

        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertFalse(model.holdsKeys, "the panel's keys are not the editor window's")
    }

    func testEveryRouteRaisesThePanelBesideAnOpenEditorWindowAndGivesItThePage() {
        // Nothing in the raise refuses. A summon is the person asking
        // to type into the card, and the editor window shows a
        // placeholder for as long as the card is up.
        for reason in [BackdropRaise.summon, .activation] {
            let model = makeModel(named: "owner-raise-beside-\(reason)")
            model.editorWindowOpened()
            model.keyStatusChanged(of: .editorWindow, keyed: true)

            model.raise(reason)

            XCTAssertEqual(model.stance, .raised)
            XCTAssertEqual(model.pages.owner, .panel)
        }
    }

    func testTheHotkeyBesideAKeyedEditorWindowRaisesAndThenRests() {
        let model = makeModel(named: "owner-summon-toggle")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        // The editor window holding the keyboard is not the card
        // holding it, so the first summon raises.
        model.summon()
        XCTAssertEqual(model.stance, .raised)
        XCTAssertEqual(model.pages.owner, .panel)
        XCTAssertFalse(model.holdsKeys, "until the panel's own window reports")

        model.keyStatusChanged(of: .editorWindow, keyed: false)
        model.keyStatusChanged(of: .panel, keyed: true)
        XCTAssertTrue(model.holdsKeys)

        model.summon()
        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertFalse(model.holdsKeys)
    }

    func testRestingBesideAnOpenEditorWindowReturnsThePage() {
        let model = makeModel(named: "owner-rest-returns")
        model.editorWindowOpened()
        model.raise(.summon)
        model.rest()
        XCTAssertEqual(model.pages.owner, .editorWindow)
    }

    func testEscOverARaisedPanelRestsItAndReturnsThePage() {
        let model = makeModel(named: "esc-raised")
        model.editorWindowOpened()
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)

        model.handBackKeys()

        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
    }

    /// Esc pressed in the editor window reaches the same road, and
    /// there is no raised panel for it to rest. A stance published
    /// again is an event to the window controller, which answers every
    /// one by ordering the card, so nothing is published.
    func testEscInTheEditorWindowPublishesNoStance() {
        let model = makeModel(named: "esc-editor-window")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)
        var published: [BackdropStance] = []
        let watch = model.$stance.dropFirst().sink { published.append($0) }
        defer { watch.cancel() }

        model.handBackKeys()

        XCTAssertEqual(published, [])
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertTrue(model.holdsKeys, "the editor window keeps the keyboard it had")
    }

    func testTheEditorWindowTakingTheKeyboardRestsARaisedPanel() {
        let model = makeModel(named: "owner-editor-takes-keys")
        model.editorWindowOpened()
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)

        model.keyStatusChanged(of: .editorWindow, keyed: true)

        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertTrue(model.holdsKeys, "the owner's window has the keyboard")
    }

    func testClosingTheEditorWindowReturnsThePageToThePanel() {
        let model = makeModel(named: "owner-closes")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        model.editorWindowClosed()

        XCTAssertFalse(model.editorWindowOpen)
        XCTAssertEqual(model.pages.owner, .panel)
        XCTAssertEqual(model.stance, .resting)
        XCTAssertFalse(model.holdsKeys, "the keys went with the window that had them")
        model.raise(.summon)
        XCTAssertEqual(model.stance, .raised)
    }

    func testClosingTheEditorWindowUnderARaisedPanelMovesNothing() {
        let model = makeModel(named: "owner-closes-under-raised")
        model.editorWindowOpened()
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)

        model.editorWindowClosed()

        XCTAssertEqual(model.pages.owner, .panel)
        XCTAssertEqual(model.stance, .raised)
        XCTAssertTrue(model.holdsKeys)
    }

    // MARK: Key loss moves nothing

    /// Settings, About and a modal open or save panel are one case to
    /// the model and that is the design: a content window is told that
    /// it lost the keyboard and never to whom, so nothing downstream
    /// can treat one taker differently from another. Each is named here
    /// so the promise reads in the terms the record makes it in.
    private static let keyTakers = ["Settings", "About", "an open panel"]

    func testKeyLossToSettingsAboutOrAnOpenPanelMovesNothingWhileThePanelOwns() {
        for taker in Self.keyTakers {
            let model = makeModel(named: "key-loss-panel-\(taker)")
            let editor = NSTextView()
            model.raise(.summon)
            model.pages.mountEditor(editor, from: .panel)
            model.keyStatusChanged(of: .panel, keyed: true)

            model.keyStatusChanged(of: .panel, keyed: false)

            XCTAssertFalse(model.holdsKeys, taker)
            XCTAssertEqual(model.pages.owner, .panel, taker)
            XCTAssertTrue(model.pages.activeEditor === editor, taker)
            XCTAssertEqual(model.stance, .raised, "losing the keyboard is never a rest")

            model.keyStatusChanged(of: .panel, keyed: true)
            XCTAssertTrue(model.holdsKeys, taker)
            XCTAssertTrue(model.pages.activeEditor === editor, taker)
        }
    }

    func testKeyLossToSettingsAboutOrAnOpenPanelMovesNothingWhileTheEditorWindowOwns() {
        for taker in Self.keyTakers {
            let model = makeModel(named: "key-loss-editor-\(taker)")
            let editor = NSTextView()
            model.editorWindowOpened()
            model.pages.mountEditor(editor, from: .editorWindow)
            model.keyStatusChanged(of: .editorWindow, keyed: true)

            model.keyStatusChanged(of: .editorWindow, keyed: false)

            XCTAssertFalse(model.holdsKeys, taker)
            XCTAssertEqual(model.pages.owner, .editorWindow, taker)
            XCTAssertTrue(model.pages.activeEditor === editor, taker)
            XCTAssertEqual(model.stance, .resting, taker)

            model.keyStatusChanged(of: .editorWindow, keyed: true)
            XCTAssertTrue(model.holdsKeys, taker)
            XCTAssertEqual(model.pages.owner, .editorWindow, taker)
        }
    }

    func testKeyLossBesideTheOtherWindowMovesNothingEither() {
        // Both windows up, the panel raised and owning, and the
        // keyboard goes to Settings. The editor window is right there
        // and still receives nothing.
        let model = makeModel(named: "key-loss-both-windows")
        let editor = NSTextView()
        model.editorWindowOpened()
        model.raise(.summon)
        model.pages.mountEditor(editor, from: .panel)
        model.keyStatusChanged(of: .panel, keyed: true)

        model.keyStatusChanged(of: .panel, keyed: false)

        XCTAssertEqual(model.pages.owner, .panel)
        XCTAssertEqual(model.stance, .raised)
        XCTAssertTrue(model.pages.activeEditor === editor)
        XCTAssertFalse(model.holdsKeys)
    }

    func testTheWindowThatDoesNotOwnSaysNothingAboutTheKeys() {
        let model = makeModel(named: "key-other-window")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        // A resting panel resigning, as it does from inside its own
        // rest, is not the page losing the keyboard.
        model.keyStatusChanged(of: .panel, keyed: false)
        XCTAssertTrue(model.holdsKeys)
        XCTAssertEqual(model.pages.owner, .editorWindow)
    }

    func testTheKeyTurnOverTheWholeMatrix() {
        typealias Turn = BackdropModel.KeyTurn
        func turn(
            _ surface: PresentationOwner, _ keyed: Bool,
            owner: PresentationOwner, mid: Bool = false, returning: Bool = false
        ) -> Turn {
            BackdropModel.keyTurn(
                surface: surface, keyed: keyed, owner: owner,
                midTransition: mid, returningFromAuxiliary: returning
            )
        }
        // The owner's window: the keys follow it and nothing else moves.
        XCTAssertEqual(turn(.panel, true, owner: .panel), .reports(true))
        XCTAssertEqual(turn(.panel, false, owner: .panel), .reports(false))
        XCTAssertEqual(turn(.editorWindow, true, owner: .editorWindow), .reports(true))
        XCTAssertEqual(turn(.editorWindow, false, owner: .editorWindow), .reports(false))
        // The other window: only the editor window taking the keyboard
        // moves anything.
        XCTAssertEqual(turn(.editorWindow, true, owner: .panel), .restsPanel)
        XCTAssertEqual(turn(.editorWindow, false, owner: .panel), .ignored)
        XCTAssertEqual(turn(.panel, true, owner: .editorWindow), .ignored)
        XCTAssertEqual(turn(.panel, false, owner: .editorWindow), .ignored)
        // Mid transition the owner's reports still count and the take
        // over waits.
        XCTAssertEqual(turn(.editorWindow, true, owner: .panel, mid: true), .ignored)
        XCTAssertEqual(turn(.panel, false, owner: .panel, mid: true), .reports(false))
        XCTAssertEqual(
            turn(.editorWindow, true, owner: .editorWindow, mid: true), .reports(true))
        // The keyboard coming back from Settings, About or a modal
        // panel: AppKit keyed the editor window, nobody took it, and
        // the keys go back to the panel that owns.
        XCTAssertEqual(
            turn(.editorWindow, true, owner: .panel, returning: true), .returnsKeysToOwner)
        XCTAssertEqual(
            turn(.editorWindow, true, owner: .panel, mid: true, returning: true), .ignored)
        // To the owner's own window a return is a report like any other.
        XCTAssertEqual(
            turn(.editorWindow, true, owner: .editorWindow, returning: true), .reports(true))
        XCTAssertEqual(turn(.panel, true, owner: .panel, returning: true), .reports(true))
        XCTAssertEqual(turn(.editorWindow, false, owner: .panel, returning: true), .ignored)
        XCTAssertEqual(turn(.panel, true, owner: .editorWindow, returning: true), .ignored)
    }

    // MARK: A modal return goes back to the owner

    /// One turn of the main actor's queue and a little more, which is
    /// how long the model waits before it hands the keys back.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    /// Both windows up, the panel raised, owning and keyed, and the
    /// keyboard gone to a window of ours that is neither of them.
    private func makeModelWithKeysAtAnAuxiliary(named name: String) -> BackdropModel {
        let model = makeModel(named: name)
        model.editorWindowOpened()
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)
        model.keyStatusChanged(of: .panel, keyed: false)
        return model
    }

    func testTheEditorWindowKeyedAsSettingsClosesMovesNothingAndThePanelIsKeyedAgain() async {
        let model = makeModelWithKeysAtAnAuxiliary(named: "return-settings")
        var published: [BackdropStance] = []
        let relay = model.$stance.dropFirst().sink { published.append($0) }
        defer { relay.cancel() }

        // Settings closes while it holds the keyboard, and AppKit picks
        // the app's main window to have it next.
        model.auxiliaryWindowReleasedKeys()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        XCTAssertEqual(model.pages.owner, .panel, "nobody took the editor window")
        XCTAssertEqual(model.stance, .raised)
        XCTAssertEqual(published, [], "and nothing is ordered from inside the key event")

        await settle()

        // The raise over a raise is the window controller's cue to key
        // the panel again.
        XCTAssertEqual(published, [.raised])
        XCTAssertEqual(model.pages.owner, .panel)
    }

    func testAReturnIsOnlyTheTurnTheAuxiliaryWindowClosedIn() async {
        let model = makeModelWithKeysAtAnAuxiliary(named: "return-expires")
        model.auxiliaryWindowReleasedKeys()
        await settle()

        // A later click on the editor window is the person taking it.
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertTrue(model.holdsKeys)
    }

    func testAReturnIsSpentByTheKeyEventItExplains() async {
        let model = makeModelWithKeysAtAnAuxiliary(named: "return-spent")
        model.auxiliaryWindowReleasedKeys()
        model.keyStatusChanged(of: .editorWindow, keyed: true)
        model.keyStatusChanged(of: .editorWindow, keyed: false)

        // Within the same turn, which no person manages, and still.
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        XCTAssertEqual(model.pages.owner, .editorWindow)
        await settle()
        XCTAssertEqual(model.stance, .resting, "the hand back found no raised panel to key")
    }

    func testTheEditorWindowKeyedInsideAModalBracketMovesNothing() async {
        let model = makeModelWithKeysAtAnAuxiliary(named: "return-modal")

        // An open panel orders itself out inside `runModal`, and the
        // editor window is keyed from there.
        ModalSession.run(center: NotificationCenter()) {
            model.keyStatusChanged(of: .editorWindow, keyed: true)
        }

        XCTAssertEqual(model.pages.owner, .panel)
        XCTAssertEqual(
            model.stance, .raised,
            "so the raise the modal's end asks for still finds a raised panel"
        )
        await settle()
        XCTAssertEqual(model.pages.owner, .panel)
    }

    func testARestBeforeTheHandBackLeavesTheKeyedEditorWindowHoldingTheKeys() async {
        let model = makeModelWithKeysAtAnAuxiliary(named: "return-rested")
        model.auxiliaryWindowReleasedKeys()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        // A click outside the card lands before the hand back runs.
        model.rest()
        await settle()

        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertTrue(
            model.holdsKeys,
            "the window was key all along, and its report was set aside as a return"
        )
    }

    func testAHandBackIsDeclinedOverARestingPanelOrAModal() {
        func handsBack(
            raised: Bool = true, owner: PresentationOwner = .panel, modal: Bool = false
        ) -> Bool {
            BackdropModel.handsKeysBackToPanel(
                panelRaised: raised, owner: owner, modalSessionRunning: modal
            )
        }
        XCTAssertTrue(handsBack())
        XCTAssertFalse(handsBack(raised: false))
        XCTAssertFalse(handsBack(owner: .editorWindow))
        XCTAssertFalse(handsBack(modal: true))
    }

    // MARK: Key events from inside a stance change

    /// The window controller orders windows from inside the stance's
    /// publication, and the key delegates those orders fire come back
    /// into the model before `stance` has landed. A subscriber stands
    /// in for the controller here and reports from exactly that turn.
    func testKeyEventsFromInsideARestAreJudgedAgainstTheSettledOwner() {
        let model = makeModel(named: "mid-rest")
        model.editorWindowOpened()
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)
        var stanceSeenFromInside: BackdropStance?
        let relay = model.$stance.dropFirst().sink { [unowned model] _ in
            // The rest hands the keyboard from the panel to the editor
            // window. `stance` still names the raise being left.
            stanceSeenFromInside = model.stance
            model.keyStatusChanged(of: .panel, keyed: false)
            model.keyStatusChanged(of: .editorWindow, keyed: true)
        }
        defer { relay.cancel() }

        model.rest()

        XCTAssertEqual(stanceSeenFromInside, .raised, "the fixture reports from mid transition")
        XCTAssertEqual(model.stance, .resting)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertTrue(model.holdsKeys, "the editor window's report counted")
    }

    func testTheEditorWindowKeyedFromInsideARaiseDoesNotNestARest() {
        let model = makeModel(named: "mid-raise")
        model.editorWindowOpened()
        var published: [BackdropStance] = []
        let relay = model.$stance.dropFirst().sink { [unowned model] stance in
            published.append(stance)
            // The raise's order out can hand the editor window the
            // keyboard for a moment, before the panel takes it.
            if published.count == 1 {
                model.keyStatusChanged(of: .editorWindow, keyed: true)
            }
        }
        defer { relay.cancel() }

        model.raise(.summon)

        XCTAssertEqual(published, [.raised], "no rest was published from inside the raise")
        XCTAssertEqual(model.stance, .raised)
        XCTAssertEqual(model.pages.owner, .panel)
    }

    // MARK: The read only panel, as one policy switch

    func testUnderTheNeverGrantPolicyThePanelIsGrantedNothingInAnyRow() {
        let model = makeModel(named: "policy-never-grant", panelMayOwn: false)
        XCTAssertEqual(
            model.pages.owner, .editorWindow,
            "the panel's root view must not find itself the owner for even its first pass"
        )

        // Closed rows: a summon raises a glance. The card takes the
        // keyboard and the page does not hold it, since no editor is
        // mounted for the keys to reach.
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)
        XCTAssertEqual(model.stance, .raised)
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertFalse(model.holdsKeys)
        model.rest()
        model.keyStatusChanged(of: .panel, keyed: false)
        XCTAssertEqual(model.pages.owner, .editorWindow)

        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)
        XCTAssertEqual(model.pages.owner, .editorWindow)

        // The panel comes forward and is granted nothing, and asks for
        // nothing either: no offer, no cadence, no keys.
        model.raise(.summon)
        model.keyStatusChanged(of: .editorWindow, keyed: false)
        model.keyStatusChanged(of: .panel, keyed: true)
        XCTAssertEqual(model.stance, .raised)
        XCTAssertEqual(model.pages.owner, .editorWindow)

        model.rest()
        XCTAssertEqual(model.pages.owner, .editorWindow)

        model.editorWindowClosed()
        XCTAssertEqual(model.pages.owner, .editorWindow, "never means with the window shut too")
    }

    /// What the policy still owes, held as a fact so that the comment
    /// on `panelMayOwn` cannot drift from it again. Esc reaches the
    /// model through the editor, the empty state's catcher or the
    /// keymap, and a raised card that owns nothing mounts none of the
    /// three. Whoever ships the policy gives the panel an Esc of its
    /// own and turns this test over.
    func testUnderTheNeverGrantPolicyARaisedCardMountsNoRouteForEsc() {
        let model = makeModel(named: "policy-never-grant-esc", panelMayOwn: false)
        model.raise(.summon)
        model.keyStatusChanged(of: .panel, keyed: true)
        XCTAssertEqual(model.stance, .raised)

        // The editor and the catcher both live inside the content area.
        XCTAssertFalse(PageContentView.mounts(surface: .panel, owner: model.pages.owner))
        XCTAssertFalse(PageKeyboardMap.installs(surface: .panel, owner: model.pages.owner))

        // The shipped rule beside it: the same raise mounts all three.
        let shipped = makeModel(named: "policy-shipped-esc")
        shipped.raise(.summon)
        XCTAssertTrue(PageContentView.mounts(surface: .panel, owner: shipped.pages.owner))
        XCTAssertTrue(PageKeyboardMap.installs(surface: .panel, owner: shipped.pages.owner))
    }

    // MARK: The keyboard coming back with the page

    func testTheKeyboardComesBackWithThePageOnlyIntoAnActiveApp() {
        func takes(
            active: Bool = true, onScreen: Bool = true,
            alreadyKey: Bool = false, modal: Bool = false
        ) -> Bool {
            PrimaryEditorWindowController.takesKeysWithOwnership(
                appActive: active, onScreen: onScreen,
                alreadyKey: alreadyKey, modalSessionRunning: modal
            )
        }
        XCTAssertTrue(takes())
        // The hotkey path: the app never activated, and the keyboard
        // goes back to the app the person was in.
        XCTAssertFalse(takes(active: false))
        XCTAssertFalse(takes(onScreen: false))
        XCTAssertFalse(takes(alreadyKey: true))
        XCTAssertFalse(takes(modal: true))
    }

    // MARK: An editor window the person cannot see

    func testAWindowIsOnScreenWhileItIsOutOfTheDockOrWhileItIsKey() {
        func onScreen(miniaturized: Bool, key: Bool) -> Bool {
            PrimaryEditorWindowController.onScreen(miniaturized: miniaturized, key: key)
        }
        XCTAssertTrue(onScreen(miniaturized: false, key: false))
        XCTAssertTrue(onScreen(miniaturized: false, key: true))
        XCTAssertFalse(onScreen(miniaturized: true, key: false))
        // A window coming out of the Dock can be key before the flag
        // drops, and a key window has the keyboard whatever else it
        // says about itself.
        XCTAssertTrue(onScreen(miniaturized: true, key: true))
    }

    func testAHiddenAppLeavesTheEditorWindowAbleToClaimTheActivation() {
        // Settings holds the keys, ⌘H, ⌘Tab back. Hiding sends the
        // model nothing, and neither does coming back, since the editor
        // window is keyed by neither. The activation is judged on the
        // fact as it stood before the hide, which is the window the
        // unhide is putting back.
        let model = makeModel(named: "hidden-app")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)
        model.keyStatusChanged(of: .editorWindow, keyed: false)

        XCTAssertTrue(model.editorWindowCanTakeKeys)
        XCTAssertNil(
            BackdropAppDelegate.activationRaises(
                sinceLaunch: 60, claimedByAnotherWindow: model.editorWindowCanTakeKeys
            ),
            "the card is not raised over an editor window in plain view"
        )
    }

    func testOnlyAnOpenEditorWindowOnScreenCanTakeTheKeyboard() {
        XCTAssertTrue(BackdropModel.editorWindowCanTakeKeys(open: true, onScreen: true))
        XCTAssertFalse(BackdropModel.editorWindowCanTakeKeys(open: true, onScreen: false))
        XCTAssertFalse(BackdropModel.editorWindowCanTakeKeys(open: false, onScreen: true))
        XCTAssertFalse(BackdropModel.editorWindowCanTakeKeys(open: false, onScreen: false))
    }

    func testARestHandsTheActivationBackUnlessTheEditorWindowCanTakeTheKeyboard() {
        XCTAssertTrue(
            BackdropModel.restHandsBackActivation(appActive: true, editorWindowCanTakeKeys: false))
        XCTAssertFalse(
            BackdropModel.restHandsBackActivation(appActive: true, editorWindowCanTakeKeys: true))
        // The hotkey path: there is no activation to hand back.
        XCTAssertFalse(
            BackdropModel.restHandsBackActivation(appActive: false, editorWindowCanTakeKeys: false))
        XCTAssertFalse(
            BackdropModel.restHandsBackActivation(appActive: false, editorWindowCanTakeKeys: true))
    }

    func testAnEditorWindowIsTakenToBeOnScreenFromTheMomentItOpens() {
        // The rest that opening the window causes runs before the
        // window exists, and it must not hand back the activation the
        // window is about to take.
        let model = makeModel(named: "on-screen-at-open")
        XCTAssertFalse(model.editorWindowCanTakeKeys)
        model.raise(.summon)
        var canTakeKeysSeenFromInsideTheRest: Bool?
        let relay = model.$stance.dropFirst().sink { [unowned model] _ in
            canTakeKeysSeenFromInsideTheRest = model.editorWindowCanTakeKeys
        }
        defer { relay.cancel() }

        model.editorWindowOpened()

        XCTAssertEqual(canTakeKeysSeenFromInsideTheRest, true)
        XCTAssertTrue(model.editorWindowCanTakeKeys)
    }

    func testAMiniaturizedEditorWindowStillOwnsAndCannotTakeTheKeyboard() {
        let model = makeModel(named: "miniaturized")
        model.editorWindowOpened()
        model.keyStatusChanged(of: .editorWindow, keyed: true)

        model.keyStatusChanged(of: .editorWindow, keyed: false)
        model.editorWindowOnScreenChanged(false)

        // Open is what ownership is resolved from (ADR-0033), so the
        // page stays where it was and nothing is published.
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertEqual(model.stance, .resting)
        XCTAssertFalse(model.editorWindowCanTakeKeys)

        // The panel is raised beside it and rested again: the page goes
        // to the panel and comes back, and the rest finds a window that
        // cannot take the keyboard, so the activation is handed back.
        model.raise(.summon)
        XCTAssertEqual(model.pages.owner, .panel)
        var canTakeKeysSeenFromInsideTheRest: Bool?
        let relay = model.$stance.dropFirst().sink { [unowned model] _ in
            canTakeKeysSeenFromInsideTheRest = model.editorWindowCanTakeKeys
        }
        defer { relay.cancel() }
        model.rest()
        XCTAssertEqual(model.pages.owner, .editorWindow)
        XCTAssertEqual(canTakeKeysSeenFromInsideTheRest, false)

        // Back out of the Dock.
        model.editorWindowOnScreenChanged(true)
        XCTAssertTrue(model.editorWindowCanTakeKeys)
    }

    func testAClosedEditorWindowIsNotOnScreen() {
        let model = makeModel(named: "closed-not-on-screen")
        model.editorWindowOpened()
        model.editorWindowClosed()
        XCTAssertFalse(model.editorWindowCanTakeKeys)

        // A report that arrives after the close, from a window on its
        // way out, makes nothing of a closed window.
        model.editorWindowOnScreenChanged(true)
        XCTAssertFalse(model.editorWindowCanTakeKeys)
    }
}
