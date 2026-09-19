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
            owner: PresentationOwner, mid: Bool = false
        ) -> Turn {
            BackdropModel.keyTurn(
                surface: surface, keyed: keyed, owner: owner, midTransition: mid
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

    func testUnderTheNeverGrantPolicyTheEditorWindowOwnsWheneverItIsOpen() {
        let model = makeModel(named: "policy-never-grant", panelMayOwn: false)
        XCTAssertEqual(model.pages.owner, .panel, "a closed window has nothing to own")

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
        XCTAssertEqual(model.pages.owner, .panel)
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
}
