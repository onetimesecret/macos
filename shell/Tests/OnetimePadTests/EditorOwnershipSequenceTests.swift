import AppKit
import CompanionCore
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// Two windows over one model, walked through the events that move the
/// page content between them (ADR-0033, issue #198): a summon, a rest,
/// the editor window taking the keyboard, the keyboard going to
/// Settings, the editor window closing and opening again. After every
/// one of them each page's storage has at most one layout manager, and
/// once SwiftUI has had its pass the selected page has exactly one, the
/// owner's.
///
/// No window controller is built, because both of them order real
/// windows and take the keyboard. The events are the calls their
/// delegates make on `BackdropModel`, and the mounts are the calls the
/// representables make on the shared factory (`InkEditorView.makePage`
/// and `updatePage`, `DayScrollView.makeRoll` and `updateRoll`), so
/// what is walked is the shipping code on both sides of the seam with
/// SwiftUI's part played by `render`.
///
/// SwiftUI is free to build the new mount before or after it takes the
/// old one down, and to let several events pass before it renders at
/// all. The harness does both orders and skips passes, since those are
/// the freedoms the hand off must not depend on.
///
/// Every `PageModel` names its seams: a temporary state directory and
/// an ephemeral core handle. A presentation write the model declines
/// fails the test that caused it, so a walk also proves that no mount
/// site wrote without asking.
@MainActor
final class EditorOwnershipSequenceTests: XCTestCase {

    // MARK: The harness

    private func makeDefaults(named suite: String) -> UserDefaults {
        let name = "onetimepad.test.\(suite).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func ephemeralPages(defaults: UserDefaults, tag: String) -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ownership-sequence-\(UUID().uuidString)", isDirectory: true)
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

    /// One thing that can happen to the two windows.
    private enum Event: CaseIterable {
        case summon
        case rest
        case editorWindowTakesKeys
        case keysGoToSettings
        case editorWindowCloses
        case editorWindowOpens
        case anotherPageIsSelected
    }

    /// One window's mount: the scroller SwiftUI was handed, its
    /// coordinator, and the window holding it.
    @MainActor
    private struct Mount {
        let scroll: NSScrollView
        let coordinator: InkEditorView.Coordinator
        let window: NSWindow

        var editor: InkTextView? {
            (scroll.documentView as? InkTextView)
                ?? (scroll.documentView as? DayStackView)?.editor
        }
    }

    /// The two windows and SwiftUI's part in them.
    @MainActor
    private final class TwoWindows {
        let model: BackdropModel
        let asRoll: Bool
        let panelMayOwn: Bool
        var mounts: [PresentationOwner: Mount] = [:]
        /// Every editor either window ever had, kept so that a layout
        /// manager count is the hand off's doing and never ARC's.
        var everyEditor: [InkTextView] = []

        var pages: PageModel { model.pages }

        init(model: BackdropModel, asRoll: Bool, panelMayOwn: Bool) {
            self.model = model
            self.asRoll = asRoll
            self.panelMayOwn = panelMayOwn
            model.pages.showsTimeUnits = asRoll
        }

        func apply(_ event: Event) {
            switch event {
            case .summon:
                model.raise(.summon)
                if model.editorWindowOpen {
                    model.keyStatusChanged(of: .editorWindow, keyed: false)
                }
                model.keyStatusChanged(of: .panel, keyed: true)
            case .rest:
                model.rest()
                model.keyStatusChanged(of: .panel, keyed: false)
            case .editorWindowTakesKeys:
                guard model.editorWindowOpen else { return }
                model.keyStatusChanged(of: .panel, keyed: false)
                model.keyStatusChanged(of: .editorWindow, keyed: true)
            case .keysGoToSettings:
                // A content window is never told who took the keyboard,
                // so Settings, About and an open panel are one event.
                model.keyStatusChanged(of: .panel, keyed: false)
                if model.editorWindowOpen {
                    model.keyStatusChanged(of: .editorWindow, keyed: false)
                }
            case .editorWindowCloses:
                guard model.editorWindowOpen else { return }
                // The controller tells the model and then drops the
                // window's content (`windowWillClose`). When the
                // hosting view dismantles what it held is AppKit's to
                // decide, so the mount is left for the next pass, which
                // takes it down before or after the panel's is built.
                model.editorWindowClosed()
            case .editorWindowOpens:
                guard !model.editorWindowOpen else { return }
                // A window opened again is a new window with a new
                // hosting view, never the closed one's mount revived.
                dismantle(.editorWindow)
                model.editorWindowOpened()
            case .anotherPageIsSelected:
                let others = pages.tabs.filter { $0.hasPage && $0.id != pages.selection }
                guard let next = others.first else { return }
                pages.select(next.id)
            }
        }

        /// A SwiftUI pass. Each root view mounts the page only while its
        /// window owns, so the window that does not own loses its mount
        /// and the owner's is made or updated, in either order.
        func render(newMountFirst: Bool) {
            let owner = pages.owner
            let other: PresentationOwner = owner == .panel ? .editorWindow : .panel
            if newMountFirst {
                show(owner)
                dismantle(other)
            } else {
                dismantle(other)
                show(owner)
            }
        }

        /// A root view that forgot to ask, mounting the page in its
        /// window whoever owns, and running a pass over it. Answers
        /// whether an editor came of it.
        func mountWithoutAsking(in surface: PresentationOwner) -> Bool {
            let mount = make(in: surface)
            update(mount)
            let built = mount.editor != nil
            if let editor = mount.editor { everyEditor.append(editor) }
            take(down: mount)
            return built
        }

        private func show(_ surface: PresentationOwner) {
            if surface == .editorWindow, !model.editorWindowOpen {
                // Only the never grant policy names a closed window as
                // the owner. There is nothing to show in it, and what
                // its hosting view still held comes down on this pass.
                dismantle(.editorWindow)
                return
            }
            if let standing = mounts[surface] {
                update(standing)
            } else {
                let mount = make(in: surface)
                mounts[surface] = mount
                update(mount)
            }
            if let editor = mounts[surface]?.editor,
               !everyEditor.contains(where: { $0 === editor }) {
                everyEditor.append(editor)
            }
        }

        private func make(in surface: PresentationOwner) -> Mount {
            let coordinator = InkEditorView.Coordinator(model: pages)
            coordinator.surface = surface
            let scroll: NSScrollView
            if asRoll {
                scroll = DayScrollView.makeRoll(
                    model: pages, coordinator: coordinator, emptyHint: ""
                )
            } else {
                scroll = InkEditorView.makePage(
                    model: pages, sheetID: pages.selectedPageID ?? 0, readOnly: false,
                    coordinator: coordinator
                )
            }
            // The card is narrower than the editor window, as it is in
            // the app.
            let frame = surface == .panel
                ? NSRect(x: 0, y: 0, width: 420, height: 320)
                : NSRect(x: 0, y: 0, width: 640, height: 720)
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scroll)
            scroll.frame = frame
            scroll.layoutSubtreeIfNeeded()
            return Mount(scroll: scroll, coordinator: coordinator, window: window)
        }

        private func update(_ mount: Mount) {
            let readOnly = mount.coordinator.surface == .panel && model.stance == .resting
            if asRoll {
                DayScrollView.updateRoll(
                    mount.scroll, model: pages, readOnly: readOnly, coordinator: mount.coordinator
                )
            } else {
                InkEditorView.updatePage(
                    mount.scroll, model: pages, sheetID: pages.selectedPageID ?? 0,
                    readOnly: readOnly, coordinator: mount.coordinator
                )
            }
        }

        func dismantle(_ surface: PresentationOwner) {
            guard let mount = mounts.removeValue(forKey: surface) else { return }
            take(down: mount)
        }

        private func take(down mount: Mount) {
            mount.scroll.removeFromSuperview()
            if asRoll {
                DayScrollView.dismantleNSView(mount.scroll, coordinator: mount.coordinator)
            } else {
                InkEditorView.dismantleNSView(mount.scroll, coordinator: mount.coordinator)
            }
        }
    }

    private func makeWindows(
        named name: String, asRoll: Bool = false, panelMayOwn: Bool = true
    ) throws -> TwoWindows {
        let defaults = makeDefaults(named: name)
        let model = BackdropModel(
            defaults: defaults,
            pages: ephemeralPages(defaults: defaults, tag: name),
            panelMayOwn: panelMayOwn
        )
        let windows = TwoWindows(model: model, asRoll: asRoll, panelMayOwn: panelMayOwn)
        // Two pages, so a selection made in either window has somewhere
        // to go and "every storage" is more than one.
        model.pages.newPage()
        model.pages.newPage()
        XCTAssertEqual(model.pages.tabs.filter(\.hasPage).count, 2)
        return windows
    }

    /// At most one layout manager on every page's storage, whatever
    /// SwiftUI has or has not done yet.
    private func assertNoPageIsLaidOutTwice(
        _ windows: TwoWindows, _ context: String, line: UInt = #line
    ) {
        for tab in windows.pages.tabs {
            guard let page = tab.pageID else { continue }
            XCTAssertLessThanOrEqual(
                windows.pages.storage(for: page).layoutManagers.count, 1,
                "two editors are laying page \(page) out \(context)", line: line
            )
        }
    }

    /// After a pass: the selected page has exactly one layout manager
    /// and it is the owner's editor's, every other page has none, and
    /// the window that does not own has no mount at all.
    ///
    /// One state has no editor to find: the never grant policy with the
    /// editor window shut, where the owner is a window that is not
    /// there. Then the page is mounted nowhere, and that is asserted
    /// in its place. The shipped rule never reaches it, and a walk
    /// under the shipped rule that did would fail here.
    private func assertTheOwnerAloneIsMounted(
        _ windows: TwoWindows, _ context: String, line: UInt = #line
    ) throws {
        let pages = windows.pages
        let owner = pages.owner
        if owner == .editorWindow, !windows.model.editorWindowOpen {
            XCTAssertFalse(
                windows.panelMayOwn, "a closed editor window owns \(context)", line: line
            )
            XCTAssertTrue(windows.mounts.isEmpty, "something is mounted \(context)", line: line)
            XCTAssertNil(pages.activeEditor, context, line: line)
            for tab in pages.tabs {
                guard let page = tab.pageID else { continue }
                XCTAssertEqual(
                    pages.storage(for: page).layoutManagers.count, 0,
                    "page \(page) is laid out with nothing mounted \(context)", line: line
                )
            }
            return
        }
        let other: PresentationOwner = owner == .panel ? .editorWindow : .panel
        let selected = try XCTUnwrap(pages.selectedPageID, line: line)
        let editor = try XCTUnwrap(
            windows.mounts[owner]?.editor, "the owner has no editor \(context)", line: line
        )
        XCTAssertNil(windows.mounts[other], line: line)
        for tab in pages.tabs {
            guard let page = tab.pageID else { continue }
            let managers = pages.storage(for: page).layoutManagers
            if page == selected {
                XCTAssertEqual(managers.count, 1, "page \(page) \(context)", line: line)
                XCTAssertTrue(
                    managers.first === editor.layoutManager,
                    "the selected page is laid out by an editor that is not the owner's \(context)",
                    line: line
                )
            } else {
                XCTAssertEqual(
                    managers.count, 0, "a background page kept a layout manager \(context)",
                    line: line
                )
            }
        }
        XCTAssertTrue(
            pages.storage(for: selected).delegate === windows.mounts[owner]?.coordinator,
            "ops for the page would be emitted by the wrong coordinator \(context)", line: line
        )
        XCTAssertTrue(pages.activeEditor === editor, context, line: line)
    }

    /// A small fixed generator, so a walk is long and varied and the
    /// same on every run.
    private struct Walk {
        var state: UInt64
        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    // MARK: Named sequences

    func testSummonRestEditorKeyAndCloseEachLeaveOneEditorOnThePage() throws {
        let windows = try makeWindows(named: "sequence-named")
        let sequence: [Event] = [
            .summon, .rest, .editorWindowOpens, .editorWindowTakesKeys, .summon,
            .editorWindowTakesKeys, .summon, .rest, .keysGoToSettings, .editorWindowTakesKeys,
            .editorWindowCloses, .summon, .editorWindowOpens, .editorWindowCloses, .rest,
        ]
        windows.render(newMountFirst: true)
        try assertTheOwnerAloneIsMounted(windows, "at launch")
        for (index, event) in sequence.enumerated() {
            windows.apply(event)
            assertNoPageIsLaidOutTwice(windows, "after \(event), before SwiftUI's pass")
            // Alternate the two orders SwiftUI may take.
            windows.render(newMountFirst: index.isMultiple(of: 2))
            try assertTheOwnerAloneIsMounted(windows, "after \(event) at step \(index)")
        }
    }

    func testKeyLossToSettingsMovesNoEditor() throws {
        let windows = try makeWindows(named: "sequence-settings")
        windows.apply(.editorWindowOpens)
        windows.apply(.editorWindowTakesKeys)
        windows.render(newMountFirst: true)
        let before = try XCTUnwrap(windows.mounts[.editorWindow]?.editor)

        windows.apply(.keysGoToSettings)
        windows.render(newMountFirst: true)

        XCTAssertEqual(windows.pages.owner, .editorWindow)
        XCTAssertTrue(windows.pages.activeEditor === before, "issue 201 reads the menus from this")
        XCTAssertTrue(windows.mounts[.editorWindow]?.editor === before, "the editor was rebuilt")
        try assertTheOwnerAloneIsMounted(windows, "after the keyboard went to Settings")
    }

    /// A close is a hand off like any other, and the person's place is
    /// the model's before the window's content has gone anywhere: the
    /// controller tells the model first, so the transfer reads the
    /// place off an editor still standing in its window, whenever the
    /// hosting view gets round to dismantling it.
    func testClosingTheEditorWindowLeavesItsPlaceForThePanel() throws {
        let windows = try makeWindows(named: "sequence-close-place")
        windows.apply(.editorWindowOpens)
        windows.render(newMountFirst: true)
        let page = try XCTUnwrap(windows.pages.selectedPageID)
        let editor = try XCTUnwrap(windows.mounts[.editorWindow]?.editor)
        editor.insertText(
            "a page worth a place", replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let caret = NSRange(location: 7, length: 5)
        editor.setSelectedRange(caret)

        windows.apply(.editorWindowCloses)

        XCTAssertNotNil(windows.mounts[.editorWindow], "the hosting view has dismantled nothing yet")
        XCTAssertEqual(windows.pages.viewStates.carets[page], caret)
        windows.render(newMountFirst: true)
        XCTAssertEqual(windows.mounts[.panel]?.editor?.selectedRange(), caret)
        try assertTheOwnerAloneIsMounted(windows, "after the close")
    }

    // MARK: The keyboard follows the page

    /// Long enough for `focusEditorWhenMounted` to find the editor, and
    /// no longer than it polls for.
    private func letTheHandOffLand() async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    /// A hotkey summon beside an open editor window makes the panel key
    /// before SwiftUI has built the panel's editor. The window holds
    /// the keys with nothing in it to type into, so the hand off owes
    /// the editor the keyboard when it arrives.
    func testASummonBesideTheEditorWindowHandsThePanelsEditorTheKeyboard() async throws {
        let windows = try makeWindows(named: "focus-summon")
        windows.apply(.editorWindowOpens)
        windows.apply(.editorWindowTakesKeys)
        windows.render(newMountFirst: true)

        windows.apply(.summon)
        XCTAssertNil(windows.mounts[.panel], "the panel is keyed before its editor exists")
        windows.render(newMountFirst: false)
        try await letTheHandOffLand()

        let mount = try XCTUnwrap(windows.mounts[.panel])
        let editor = try XCTUnwrap(mount.editor)
        XCTAssertTrue(windows.pages.holdsKeys)
        XCTAssertTrue(
            mount.window.firstResponder === editor,
            "the panel holds the keys and its editor was never handed them"
        )
    }

    /// The mirror route: the person clicks the editor window while a
    /// raised panel owns. The window is key already when the page
    /// comes to it, so nothing reorders, and the editor that mounts a
    /// pass later is still owed the keyboard.
    func testTheEditorWindowTakingThePageWhileKeyHandsItsEditorTheKeyboard() async throws {
        let windows = try makeWindows(named: "focus-editor-key")
        windows.apply(.editorWindowOpens)
        windows.apply(.summon)
        windows.render(newMountFirst: true)

        windows.apply(.editorWindowTakesKeys)
        XCTAssertEqual(windows.pages.owner, .editorWindow)
        XCTAssertNil(windows.mounts[.editorWindow], "the window is keyed before its editor exists")
        windows.render(newMountFirst: true)
        try await letTheHandOffLand()

        let mount = try XCTUnwrap(windows.mounts[.editorWindow])
        let editor = try XCTUnwrap(mount.editor)
        XCTAssertTrue(windows.pages.holdsKeys)
        XCTAssertTrue(
            mount.window.firstResponder === editor,
            "the editor window holds the keys and its editor was never handed them"
        )
    }

    /// The keyboard coming back from Settings follows no hand off, and
    /// the window's own first responder is AppKit's to restore. Focus
    /// only ever accepts (ADR-0005), so nothing is taken here.
    func testTheKeysComingBackFromSettingsTakeNothing() throws {
        let windows = try makeWindows(named: "focus-settings")
        windows.apply(.summon)
        windows.render(newMountFirst: true)
        windows.apply(.keysGoToSettings)
        let before = windows.pages.keyboardHandoffs

        windows.model.keyStatusChanged(of: .panel, keyed: true)

        XCTAssertTrue(windows.pages.holdsKeys)
        XCTAssertEqual(windows.pages.keyboardHandoffs, before)
    }

    /// A hand off into a window that is not key owes the editor
    /// nothing until the keys arrive: focusing there would be taking.
    func testAHandOffIntoAnUnkeyedWindowWaitsForTheKeys() throws {
        let windows = try makeWindows(named: "focus-unkeyed")
        let before = windows.pages.keyboardHandoffs

        windows.apply(.editorWindowOpens)
        XCTAssertEqual(windows.pages.owner, .editorWindow)
        XCTAssertEqual(windows.pages.keyboardHandoffs, before)

        windows.model.keyStatusChanged(of: .editorWindow, keyed: true)
        XCTAssertEqual(windows.pages.keyboardHandoffs, before + 1)
    }

    // MARK: Any sequence

    private func walk(
        _ windows: TwoWindows, seed: UInt64, steps: Int,
        over events: [Event] = Event.allCases,
        afterEach check: (_ context: String) throws -> Void = { _ in }
    ) throws {
        var walk = Walk(state: seed)
        windows.render(newMountFirst: true)
        var trail: [Event] = []
        for step in 0..<steps {
            let event = events[walk.next(below: events.count)]
            trail.append(event)
            let recent = trail.suffix(6).map { "\($0)" }.joined(separator: ", ")
            windows.apply(event)
            assertNoPageIsLaidOutTwice(windows, "at step \(step), after \(recent)")
            try check("at step \(step), after \(recent)")
            // One time in four SwiftUI has not rendered yet when the
            // next event arrives.
            guard walk.next(below: 4) != 0 else { continue }
            windows.render(newMountFirst: walk.next(below: 2) == 0)
            try assertTheOwnerAloneIsMounted(windows, "at step \(step), after \(recent)")
        }
        windows.render(newMountFirst: true)
        try assertTheOwnerAloneIsMounted(windows, "at the end of the walk")
    }

    func testAnySequenceLeavesEveryPageWithOneEditorAtMost() throws {
        try walk(try makeWindows(named: "sequence-walk-page"), seed: 198, steps: 400)
    }

    func testAnySequenceOverTheRollLeavesEveryPageWithOneEditorAtMost() throws {
        try walk(try makeWindows(named: "sequence-walk-roll", asRoll: true), seed: 33, steps: 400)
    }

    // MARK: The never grant policy

    /// ADR-0033 keeps a second design in reserve: a panel that is
    /// never granted the page content, raised or not, beside the
    /// editor window or with it shut. It ships off (`panelMayOwn`
    /// defaults to true and no call site passes false), and it is
    /// proved here against the same model, the same factory and the
    /// same sequences as the shipped rule, so turning it on would be
    /// one argument and not a second architecture.
    ///
    /// What is proved is the mount and not only the owner. After every
    /// event the panel tries to mount the page without asking, as a
    /// root view with a defect would, and no editor comes of it, the
    /// editor window's editor is still the only one on the page while
    /// that window is open, no editor is on it at all while it is
    /// shut, and the model declined nothing, because the factory asked
    /// first.
    private func assertThePanelCannotMount(
        _ windows: TwoWindows, _ context: String, line: UInt = #line
    ) throws {
        XCTAssertEqual(windows.pages.owner, .editorWindow, context, line: line)
        XCTAssertNil(windows.mounts[.panel], "the panel has a mount \(context)", line: line)
        XCTAssertFalse(
            windows.mountWithoutAsking(in: .panel),
            "the panel built an editor beside the editor window's \(context)", line: line
        )
        assertNoPageIsLaidOutTwice(windows, context, line: line)
    }

    func testUnderTheNeverGrantPolicyThePanelNeverMountsAnEditor() throws {
        let windows = try makeWindows(named: "policy-named", panelMayOwn: false)
        // With the editor window shut the page is mounted nowhere: the
        // card is a glance at launch and a glance when summoned. A
        // policy that left these rows to the panel would be a panel
        // that edits whenever the other window happens to be closed.
        windows.render(newMountFirst: true)
        try assertThePanelCannotMount(windows, "at launch, the editor window shut")
        windows.apply(.summon)
        windows.render(newMountFirst: true)
        try assertThePanelCannotMount(windows, "summoned, the editor window shut")
        try assertTheOwnerAloneIsMounted(windows, "summoned, the editor window shut")
        windows.apply(.rest)

        windows.apply(.editorWindowOpens)
        windows.render(newMountFirst: true)
        try assertThePanelCannotMount(windows, "after the editor window opened")

        let sequence: [Event] = [
            .summon, .summon, .rest, .editorWindowTakesKeys, .summon, .keysGoToSettings,
            .anotherPageIsSelected, .summon, .editorWindowTakesKeys, .rest,
        ]
        for (index, event) in sequence.enumerated() {
            windows.apply(event)
            try assertThePanelCannotMount(windows, "after \(event), before SwiftUI's pass")
            windows.render(newMountFirst: index.isMultiple(of: 2))
            try assertThePanelCannotMount(windows, "after \(event) at step \(index)")
            try assertTheOwnerAloneIsMounted(windows, "after \(event) at step \(index)")
        }

        // The policy has no boundary: the window closing hands the
        // panel nothing, and the editor that was in it comes off the
        // page with its window.
        windows.apply(.editorWindowCloses)
        try assertThePanelCannotMount(windows, "after the close, before SwiftUI's pass")
        windows.render(newMountFirst: true)
        try assertThePanelCannotMount(windows, "after the editor window closed")
        try assertTheOwnerAloneIsMounted(windows, "after the editor window closed")
    }

    func testUnderTheNeverGrantPolicyNoSequenceGetsThePanelAnEditor() throws {
        for asRoll in [false, true] {
            let windows = try makeWindows(
                named: "policy-walk-\(asRoll ? "roll" : "page")", asRoll: asRoll,
                panelMayOwn: false
            )
            // Every event, the window closing and opening among them.
            try walk(windows, seed: asRoll ? 0x33 : 0x198, steps: 250) { context in
                try assertThePanelCannotMount(windows, context)
            }
        }
    }

    /// The control for the two cases above: under the shipped rule the
    /// same summon does get the panel an editor, so what they show is
    /// the policy and not a harness that cannot mount a panel at all.
    func testUnderTheShippedRuleTheSameSummonDoesGetThePanelAnEditor() throws {
        let windows = try makeWindows(named: "policy-control")
        windows.apply(.editorWindowOpens)
        windows.render(newMountFirst: true)

        windows.apply(.summon)
        windows.render(newMountFirst: true)

        XCTAssertEqual(windows.pages.owner, .panel)
        XCTAssertNotNil(windows.mounts[.panel]?.editor)
        try assertTheOwnerAloneIsMounted(windows, "after a summon under the shipped rule")
    }
}
