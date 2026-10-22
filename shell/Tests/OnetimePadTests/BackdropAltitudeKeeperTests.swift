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
        // A raise committed again over a card that is already raised
        // and keyed must write nothing: the guard issue 74 was closed
        // with. A cancelled quit reaches it while the panel owns the
        // page and holds the keyboard, since `.cancelledQuit` goes back
        // to the owner as `.raisePanel(.activation)`. A summon does
        // not: over a keyed card it rests it (`stanceAfterSummon`).
        // Before ADR-0033 the ⌘Tab return reached it too; the return
        // now selects the editor window.
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

    // MARK: The keyboard in a companion window (ADR-0032 Amendment 1, #293)

    /// A stand in for Settings, About or Send Feedback: titled, built
    /// deferred and never ordered. Its key turns are posted by hand,
    /// since a window that never reaches the screen is never keyed.
    private func makeCompanion() -> CountingWindow {
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func becameKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    private func resignedKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    }

    func testAPinnedCardLowersWhileSettingsIsKeyAndFloatsAgainWhenSettingsCloses() {
        let model = makeModel(tag: "pinned-under-settings")
        model.pinned = true
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        XCTAssertEqual(window.level, .floating)

        becameKey(settings)
        XCTAssertTrue(keeper.companionKeyed)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(
            window.collectionBehavior, [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        )

        // A window never on screen resigns nothing, so the close releases,
        // one main queue hop later.
        settings.close()
        XCTAssertEqual(window.level, .normal, "not inside the close")
        drainMainQueue()
        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(
            window.collectionBehavior,
            [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        )
    }

    func testAKeepAboveCardLowersWhileSettingsIsKeyAndFloatsAgainWhenItResigns() {
        // The raised card gave Settings the keyboard, so its own key
        // answer is false; the preference alone would float it.
        let model = makeModel(tag: "keep-above-under-settings")
        model.keepsAboveWhenInactive = true
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper, keepsAbove: true)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: true)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        XCTAssertEqual(window.level, .floating)

        becameKey(settings)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenNone])

        resignedKey(settings)
        drainMainQueue()
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func testClosingTheKeyCompanionReappliesTheTablesLevelAsItIsNow() {
        // The preference turned on inside Settings moves the table, not the
        // card; the close's resign and willClose then write the float once.
        let model = makeModel(tag: "close-reapplies")
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        becameKey(settings)
        model.keepsAboveWhenInactive = true
        XCTAssertEqual(window.level, .normal)
        window.forgetWrites()

        resignedKey(settings)
        settings.close()
        XCTAssertEqual(window.level, .normal, "not inside the close")
        drainMainQueue()

        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
        XCTAssertEqual(window.levelWrites, 1)
        XCTAssertEqual(window.behaviorWrites, 1)
    }

    func testACompanionWindowStaysAtNormalUnderEveryPinAndPreferenceState() {
        // The keeper writes the card and never the companion: no level
        // write reaches it in any row, keyed or not.
        for stance in [BackdropStance.resting, .raised] {
            for pinned in [false, true] {
                for keepsAbove in [false, true] {
                    let model = makeModel(tag: "companion-\(stance)-\(pinned)-\(keepsAbove)")
                    model.pinned = pinned
                    model.keepsAboveWhenInactive = keepsAbove
                    let companion = makeCompanion()
                    let window = makeWindow()
                    let keeper = BackdropAltitudeKeeper(window: window)
                    keeper.commit(stance, keyed: false, pinned: pinned, keepsAbove: keepsAbove)
                    keeper.observe(model, keyed: { false }, companion: { $0 === companion })

                    becameKey(companion)
                    model.pinned.toggle()
                    model.keepsAboveWhenInactive.toggle()
                    resignedKey(companion)

                    let row = "stance=\(stance) pinned=\(pinned) keepsAbove=\(keepsAbove)"
                    XCTAssertEqual(companion.level, .normal, row)
                    XCTAssertEqual(companion.levelWrites, 0, row)
                    XCTAssertEqual(companion.behaviorWrites, 0, row)
                }
            }
        }
    }

    func testCmdTabAwayWithSettingsKeyLeavesBothAtNormal() {
        // Deactivation makes Settings resign without closing; the card,
        // raised and keyless under the default preference, is at normal
        // by the table and stays there.
        let model = makeModel(tag: "cmd-tab-away")
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        raise(keeper)
        keeper.reapply(keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        becameKey(settings)
        window.forgetWrites()

        resignedKey(settings)
        drainMainQueue()

        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(settings.level, .normal)
        XCTAssertEqual(window.levelWrites, 0)
    }

    func testARestingUnpinnedCardStaysOnTheDesktopUnderAKeyCompanion() {
        // Furniture is below the companion already; lifting it to
        // normal would put it among the person's windows.
        let model = makeModel(tag: "desktop-under-companion")
        let companion = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === companion })
        window.forgetWrites()

        becameKey(companion)

        XCTAssertTrue(keeper.companionKeyed)
        XCTAssertEqual(window.level, .backdropDesktop)
        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)
    }

    func testAWindowThatIsNoCompanionMovesNothing() {
        // An open panel, another app's window reported through the
        // same centre, or the editor window: none is the keeper's.
        let model = makeModel(tag: "stranger")
        model.pinned = true
        let stranger = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { _ in false })
        window.forgetWrites()

        becameKey(stranger)
        stranger.close()

        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.levelWrites, 0)
    }

    func testAnotherWindowsResignDoesNotReleaseTheKeyCompanion() {
        let model = makeModel(tag: "other-resign")
        model.pinned = true
        let settings = makeCompanion()
        let other = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        becameKey(settings)

        resignedKey(other)
        other.close()
        drainMainQueue()

        XCTAssertTrue(keeper.companionKeyed)
        XCTAssertEqual(window.level, .normal)
    }

    func testTheCardAboutToTakeKeysFloatsOverAKeyCompanion() {
        // A summon while Settings is key: the raise is committed with
        // keyed true before Settings resigns, and the card must not
        // flash at normal in between. The resign that follows reads
        // the card's own keys and leaves it floating.
        let model = makeModel(tag: "summon-over-settings")
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        let keys = KeyStatus()
        keys.held = false
        keeper.observe(model, keyed: { keys.held }, companion: { $0 === settings })
        becameKey(settings)

        raise(keeper)
        XCTAssertEqual(window.level, .floating)
        keys.held = true
        resignedKey(settings)
        drainMainQueue()

        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .floating)
    }

    func testAHandOffBetweenCompanionsWritesNoFloatInBetween() {
        // AppKit posts Settings' resign before About's key gain; the key
        // gain cancels the waiting release.
        let model = makeModel(tag: "hand-off")
        model.pinned = true
        let settings = makeCompanion()
        let about = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings || $0 === about })
        becameKey(settings)
        window.forgetWrites()

        resignedKey(settings)
        becameKey(about)
        drainMainQueue()

        XCTAssertTrue(keeper.keyedCompanion === about)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.levelWrites, 0)
        XCTAssertEqual(window.behaviorWrites, 0)

        resignedKey(about)
        drainMainQueue()
        XCTAssertFalse(keeper.companionKeyed)
        XCTAssertEqual(window.level, .floating)
    }

    /// A sheet stand in that answers `sheetParent` by hand, since a real
    /// sheet needs a window on screen.
    private final class SheetStandIn: OrderCountingWindow {
        weak var pretendParent: NSWindow?
        override var sheetParent: NSWindow? { pretendParent }
    }

    func testASheetOnACompanionCountsAsTheCompanionAndItsParentIsOrdered() {
        // Export runs a save sheet on Send Feedback. A sheet that lowers
        // the card has its parent ordered front, never itself.
        let model = makeModel(tag: "sheet")
        model.pinned = true
        let feedback = makeOrderCountingCompanion()
        let sheet = SheetStandIn(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        sheet.isReleasedWhenClosed = false
        sheet.pretendsToBeKeyAndVisible = true
        sheet.pretendParent = feedback
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === feedback })

        becameKey(sheet)
        XCTAssertEqual(window.level, .normal)
        drainMainQueue()
        XCTAssertEqual(feedback.orderFrontCalls, 1)
        XCTAssertEqual(sheet.orderFrontCalls, 0)

        // The parent hands the keyboard to its sheet: no write.
        resignedKey(sheet)
        drainMainQueue()
        becameKey(feedback)
        window.forgetWrites()
        resignedKey(feedback)
        becameKey(sheet)
        drainMainQueue()
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.levelWrites, 0)
    }

    func testObservingAgainForgetsTheKeyCompanion() {
        let model = makeModel(tag: "observe-resets")
        model.pinned = true
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        becameKey(settings)

        keeper.observe(model, keyed: { false }, companion: { _ in false })
        XCTAssertFalse(keeper.companionKeyed)

        // The next write reads the table again.
        model.keepsAboveWhenInactive = true
        XCTAssertEqual(window.level, .floating)
    }

    func testObservingAgainKeepsOneWatchOnTheCompanion() {
        let model = makeModel(tag: "observe-twice")
        model.pinned = true
        let settings = makeCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })
        window.forgetWrites()

        becameKey(settings)

        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.levelWrites, 1)
    }

    /// Counts ordering calls and answers the key and visible questions
    /// by hand, so the settle can be asked of a window that is never on
    /// screen. `orderFront` deliberately does not reach AppKit.
    private class OrderCountingWindow: NSWindow {
        var orderFrontCalls = 0
        var pretendsToBeKeyAndVisible = false

        override var isKeyWindow: Bool { pretendsToBeKeyAndVisible }
        override var isVisible: Bool { pretendsToBeKeyAndVisible }
        override func orderFront(_ sender: Any?) { orderFrontCalls += 1 }
    }

    private func makeOrderCountingCompanion() -> OrderCountingWindow {
        let window = OrderCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.pretendsToBeKeyAndVisible = true
        return window
    }

    func testAKeyCompanionIsOrderedFrontOnceTheCardHasLowered() {
        // A level written puts the card at the front of its new level,
        // the companion's. The companion is ordered front a hop later,
        // not inside the key notification, and only when the card moved.
        let model = makeModel(tag: "order-front")
        model.pinned = true
        let settings = makeOrderCountingCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: true, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })

        becameKey(settings)
        XCTAssertEqual(settings.orderFrontCalls, 0, "not inside the key notification")
        drainMainQueue()

        XCTAssertEqual(settings.orderFrontCalls, 1)
    }

    func testAKeyCompanionOverADesktopCardIsNotOrdered() {
        let model = makeModel(tag: "no-order")
        let settings = makeOrderCountingCompanion()
        let window = makeWindow()
        let keeper = BackdropAltitudeKeeper(window: window)
        keeper.commit(.resting, keyed: false, pinned: false, keepsAbove: false)
        keeper.observe(model, keyed: { false }, companion: { $0 === settings })

        becameKey(settings)
        drainMainQueue()

        XCTAssertEqual(settings.orderFrontCalls, 0)
    }
}
