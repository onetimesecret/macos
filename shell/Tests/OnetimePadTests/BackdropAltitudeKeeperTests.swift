import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The keeper the window controller delegates to, driven the way the
/// controller drives it and judged by what lands on a real window: its
/// level, its collection behavior, and how many times each was written.
///
/// The window is built deferred and never ordered, so nothing reaches
/// the screen and no key status moves. The controller itself is not
/// built here on purpose. Its first stance sink orders a pane onto the
/// desktop of whoever runs the suite, and a raise takes the keyboard
/// from the app they are typing in; the decisions worth testing are
/// the keeper's, and they need neither.
@MainActor
final class BackdropAltitudeKeeperTests: XCTestCase {

    /// Counts the writes, since a guard that skips a write is invisible
    /// in the value it leaves behind.
    private final class CountingWindow: NSWindow {
        var levelWrites = 0
        var behaviorWrites = 0

        override var level: NSWindow.Level {
            didSet { levelWrites += 1 }
        }

        override var collectionBehavior: NSWindow.CollectionBehavior {
            didSet { behaviorWrites += 1 }
        }

        func forgetWrites() {
            levelWrites = 0
            behaviorWrites = 0
        }
    }

    private func makeWindow() -> CountingWindow {
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The raise as `apply(.raised)` performs it: committed with keyed
    /// true, before the panel is made key, so the summon does not flash
    /// at a lower level.
    private func raise(
        _ keeper: BackdropAltitudeKeeper, pinned: Bool = false, keepsAbove: Bool = false
    ) {
        keeper.commit(.raised, keyed: true, pinned: pinned, keepsAbove: keepsAbove)
    }

    // MARK: The stance a key event is judged against

    func testAResignArrivingInsideTheRestDoesNotParkTheSurfaceAtNormal() {
        // The window server calls `windowDidResignKey` synchronously
        // from inside `apply(.resting)`, after the keeper has committed
        // to the rest. Judged against the raise being left, that resign
        // would resolve to normal and strand desktop furniture among
        // the person's windows.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)

        XCTAssertEqual(keeper.committedStance, .resting)
        XCTAssertEqual(window.level, .backdropDesktop)
        XCTAssertEqual(
            window.collectionBehavior,
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        )
    }

    func testARaiseFloatsAndJoinsFullScreenSpacesBeforeItIsKey() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)

        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    // MARK: The key transitions (ADR-0034)

    func testAResignOnARaisedUnpinnedCardDropsToNormalAndLeavesFullScreenSpaces() {
        // Issue 184: ⌘Tab into an app in its own full screen Space. The
        // card falls to normal and gives up the auxiliary bit in the
        // same turn, in one write each.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        window.forgetWrites()

        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)

        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenNone])
        XCTAssertEqual(window.levelWrites, 1)
        XCTAssertEqual(window.behaviorWrites, 1)
    }

    func testBecomingKeyAgainRestoresBothInOneWriteEach() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)
        window.forgetWrites()

        keeper.reapply(keyed: true, pinned: false, keepsAbove: false)

        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
        XCTAssertEqual(window.levelWrites, 1)
        XCTAssertEqual(window.behaviorWrites, 1)
    }

    func testAKeyTransitionNeverTouchesMembership() {
        // The cost of issue 74 lay in the membership bits. The full
        // screen bit is not one of them, and the value on the window
        // names the same membership on both sides of the transition.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        let membership: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .moveToActiveSpace, .transient,
        ]
        raise(keeper)
        let keyed = window.collectionBehavior.intersection(membership)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)
        let keyless = window.collectionBehavior.intersection(membership)

        XCTAssertEqual(keyed, [.canJoinAllSpaces])
        XCTAssertEqual(keyless, keyed)
    }

    func testAPinnedCardWritesNothingOnAKeyTransition() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper, pinned: true)
        window.forgetWrites()

        keeper.reapply(keyed: false, pinned: true, keepsAbove: false)
        keeper.reapply(keyed: true, pinned: true, keepsAbove: false)

        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func testAKeepAboveCardWritesNothingOnAKeyTransition() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper, keepsAbove: true)
        window.forgetWrites()

        keeper.reapply(keyed: false, pinned: false, keepsAbove: true)
        keeper.reapply(keyed: true, pinned: false, keepsAbove: true)

        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func testAReRaiseOverARaisedKeyedCardWritesNothing() {
        // What a second summon does to a card that already holds the
        // keyboard (before ADR-0033 the ⌘Tab return did this too; it
        // now selects the editor window instead), and the guard issue
        // 74 was closed with.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        window.forgetWrites()

        raise(keeper)

        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
    }

    // MARK: The reconcile after a raise

    func testTheReconcileAfterARefusedRaiseDropsTheCard() {
        // `makeKeyAndOrderFront` can be refused, and a refused raise
        // gets no resign event to drop it. The reconcile a turn later
        // feeds the honest keyless answer.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)

        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)

        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenNone])
    }

    func testAStaleReconcileAfterARestWritesNothing() {
        // A raise and then a rest inside one turn leaves the raise's
        // reconcile to run over a resting surface. It is judged against
        // the committed rest, finds the window already there and leaves
        // it alone; judged against the raise it would lift desktop
        // furniture to normal.
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        window.forgetWrites()

        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)

        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
        XCTAssertEqual(window.level, .backdropDesktop)
    }

    // MARK: The pin and the preference, observed on the model

    /// A model on a throwaway defaults suite, with pages in a directory
    /// made for the test on an ephemeral core handle. Never the
    /// standard suite, never default seams.
    private func makeModel(tag: String) -> BackdropModel {
        let name = "onetimepad.test.keeper.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        companion_init()
        guard let handle = tag.withCString({ companion_new_ephemeral($0) }) else {
            fatalError("the core refused to create an ephemeral handle")
        }
        let pages = PageModel(
            formFactor: .backdrop,
            defaults: defaults,
            seams: .init(
                stateDirectory: directory,
                client: CompanionClient(adopting: handle)
            )
        )
        return BackdropModel(defaults: defaults, pages: pages)
    }

    func testThePinIsReadFromTheEmittedValue() {
        // A @Published emits on willSet. A sink that read the model
        // back would see the pin being left: nothing written on pin,
        // and a floating card left behind on unpin. The window is
        // asserted right after each assignment, with no turn between.
        let model = makeModel(tag: "pin")
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false })

        model.pinned = true
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(
            window.collectionBehavior,
            [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        )

        model.pinned = false
        XCTAssertEqual(window.level, .backdropDesktop)
        XCTAssertEqual(
            window.collectionBehavior,
            [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        )
    }

    func testThePreferenceIsReadFromTheEmittedValue() {
        let model = makeModel(tag: "preference")
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false })

        model.keepsAboveWhenInactive = true
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])

        model.keepsAboveWhenInactive = false
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenNone])
    }

    func testThePreferenceReadsThePinThatHasLanded() {
        // The other input is the model's to answer: a pinned card does
        // not move when the preference is switched off under it.
        let model = makeModel(tag: "preference-under-pin")
        model.pinned = true
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper, pinned: true)
        keeper.reapply(keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false })
        window.forgetWrites()

        model.keepsAboveWhenInactive = true
        model.keepsAboveWhenInactive = false

        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
    }

    /// Whether the window holds the keyboard, as the test says it does.
    @MainActor
    private final class KeyStatus {
        var held = true
    }

    func testKeyStatusIsAskedAtEachChange() {
        // A raised card that holds the keyboard floats whatever the
        // preference says, so switching it off writes nothing; once the
        // keys are gone the same switch drops the card.
        let model = makeModel(tag: "keyed")
        model.keepsAboveWhenInactive = true
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper, keepsAbove: true)
        // A reference, because the closure is a sendable one and a
        // captured variable may not change under it. The keeper asks on
        // the main actor, which is where the answer is changed.
        let keys = KeyStatus()
        keeper.observe(model, keyed: { keys.held })

        model.keepsAboveWhenInactive = false
        XCTAssertEqual(window.level, .floating)

        keys.held = false
        model.keepsAboveWhenInactive = true
        model.keepsAboveWhenInactive = false
        XCTAssertEqual(window.level, .normal)
    }

    func testThePinHooksRunAroundTheWriteWithTheEmittedPin() {
        // The controller's mouse rule goes before the altitude write
        // and its frame after, in one sink, so the order does not rest
        // on how Combine delivers to separate subscribers.
        let model = makeModel(tag: "hooks")
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        var seen: [String] = []
        keeper.observe(
            model,
            keyed: { false },
            willRepin: { seen.append("will \($0) at \(window.level == .floating)") },
            didRepin: { seen.append("did \($0) at \(window.level == .floating)") }
        )

        model.pinned = true

        XCTAssertEqual(seen, ["will true at false", "did true at true"])
    }

    // MARK: The pin and the preference under a stance that stays put

    func testThePreferenceLiftsAKeylessRaiseAndBringsTheFullScreenBitWithIt() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)

        keeper.reapply(keyed: false, pinned: false, keepsAbove: true)

        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func testThePinLiftsARestAndDropsTheWallpaperRecipe() {
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)

        keeper.reapply(keyed: false, pinned: true, keepsAbove: false)

        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(
            window.collectionBehavior,
            [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        )
    }
}
