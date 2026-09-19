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
                client: CompanionClient(adopting: handle)
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

    // MARK: The editor window (spike, issue #197)

    func testOpeningTheEditorWindowRestsARaisedPanel() {
        // Crude exclusive ownership: the window opening is what takes
        // the pages away from the panel, whatever the panel was doing.
        let defaults = makeDefaults(named: "editor-window-rests")
        let model = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "editor-window-rests")
        )
        model.raise(.summon)
        model.editorWindowOpened()
        XCTAssertTrue(model.editorWindowOpen)
        XCTAssertEqual(model.stance, .resting)
    }

    func testNoRouteRaisesThePanelWhileTheEditorWindowIsOpen() {
        // The one scenario the guard exists for: a Dock click on an
        // inactive app sends the reopen and an activation, in no
        // promised order, and the activation arriving second must not
        // put a second editor over the pages the window now owns.
        let defaults = makeDefaults(named: "editor-window-refuses")
        let model = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "editor-window-refuses")
        )
        model.editorWindowOpened()
        model.raise(.activation)
        XCTAssertEqual(model.stance, .resting)
        model.summon()
        XCTAssertEqual(model.stance, .resting)
    }

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
        // under an open window, a raise would be refused, and the click
        // must still do something.
        XCTAssertFalse(
            BackdropModel.reopenOpensEditorWindow(preference: false, windowOpen: false))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: false, windowOpen: true))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: true, windowOpen: false))
        XCTAssertTrue(
            BackdropModel.reopenOpensEditorWindow(preference: true, windowOpen: true))
    }

    func testClosingTheEditorWindowGivesThePanelItsRaiseBack() {
        let defaults = makeDefaults(named: "editor-window-closes")
        let model = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: "editor-window-closes")
        )
        model.editorWindowOpened()
        model.editorWindowClosed()
        XCTAssertFalse(model.editorWindowOpen)
        XCTAssertEqual(model.stance, .resting)
        model.raise(.summon)
        XCTAssertEqual(model.stance, .raised)
    }
}
