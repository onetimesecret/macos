import AppKit
import Combine
import CompanionKit
import SwiftUI
import os

/// The primary editor window (ADR-0033): an ordinary titled, resizable
/// window at normal level over the same pages the panel shows. Its
/// entrances are the routing table's (`ActivationRouter`): a launch the
/// person performs, ⌘Tab, a Dock click and a reopen select it, a
/// cancelled quit selects it while it owns, and the hotkey and the
/// status item select it only with the ambient panel off. The table
/// would send a modal return here too while this window owns, but the
/// delegate asks it only over a raised panel
/// (`BackdropAppDelegate.modalSessionEnded`), and a raised panel always
/// owns, so the keyboard's return to this window after a modal is
/// AppKit's own.
///
/// One store, one model: the root view is handed the panel's own
/// `PageModel`, never a second one. Exactly one of the two windows owns
/// the live page content at a time (`PageModel.owner`). This one owns
/// while it is open and the panel rests, and shows a glance
/// (`GlanceView`) while a raised panel has the page. What it reports to
/// the model is three facts, that it opened or closed, that it gained
/// or lost the keyboard and whether it is on screen, and
/// `BackdropModel` decides what each one moves.
///
/// The window is built on each open and dropped on each close. A closed
/// window keeps its hosting view, and a hosting view keeps its editor
/// mounted, which is exactly the second mount ownership exists to
/// prevent. The frame survives through the autosave name, in defaults.
@MainActor
final class PrimaryEditorWindowController: NSObject, NSWindowDelegate {
    private let model: BackdropModel
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }
    private var switchingToAmbientPanel = false

    func closeForAmbientPanel() {
        switchingToAmbientPanel = true
        window?.close()
        switchingToAmbientPanel = false
    }
    private var captureObserver: AnyCancellable?
    private var ownerObserver: AnyCancellable?

    /// The defaults key the frame rests under between runs. State
    /// restoration is off (`isRestorable`), so this is the only thing
    /// of the window's that outlives the process.
    private static let frameAutosaveName = "PrimaryEditorWindow"

    init(model: BackdropModel) {
        self.model = model
        super.init()
    }

    /// Open the window, or bring the open one forward.
    func show() {
        if let window {
            // Out of the Dock first. The reopen answers false to AppKit,
            // which is what would otherwise have restored a miniaturized
            // window, so bringing it forward is wholly this call's.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            // Ordering the window does not replace a field editor or
            // another responder left by its previous interaction. Wait
            // for this window's editor if key status transfers ownership
            // from the panel and the content has yet to remount.
            model.pages.focusEditorWhenMounted(in: window, requireKeys: true)
            return
        }
        // The fact before the window: the panel has to have let go of
        // the page, its place kept, by the time this window's editor
        // mounts and sheds what it finds on the storage.
        model.editorWindowOpened()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The app's name and nothing else, ever. A title reaches
        // Mission Control and the window list, which is further than
        // `sharingType` covers, so no page title or content goes in it.
        window.title = BackdropAppDelegate.productName
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        // No saved application state: restoration would write a
        // snapshot of the window, ink included, under
        // ~/Library/Saved Application State.
        window.isRestorable = false
        // Capture exclusion (docs/spec/05), on the panel's own terms:
        // closed at creation, and lifted only by the debug opt out, which
        // is observed only when this launch offers it.
        window.sharingType = .none
        if PageModel.captureOptOutOffered {
            captureObserver = model.pages.$allowCapture
                .sink { [weak window] allow in
                    window?.sharingType = allow ? .readOnly : .none
                }
        }
        window.contentView = NSHostingView(
            rootView: PrimaryEditorRootView(pages: model.pages)
        )
        window.delegate = self
        // Centre first, autosave second: setting the name restores a
        // saved frame over the centred one, and a first run keeps the
        // centre.
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window
        observeOwner()

        window.makeKeyAndOrderFront(nil)
        model.pages.focusEditorWhenMounted(in: window)
        Self.logger.info("editor window=open")
    }

    // MARK: NSWindowDelegate

    /// Key status is reported and never written here. Taking the
    /// keyboard is the one key event that moves ownership (a raised
    /// panel rests), and losing it, to Settings, About, a modal panel
    /// or another app, moves nothing; `BackdropModel.keyTurn` holds
    /// both rules.
    ///
    /// The on screen fact goes first. Taking the keyboard can rest a
    /// raised panel, the rest decides whether to hand the activation
    /// back by asking whether this window can take the keyboard, and a
    /// window coming out of the Dock may be key before AppKit has said
    /// it is out.
    func windowDidBecomeKey(_ notification: Notification) {
        reportOnScreen()
        model.keyStatusChanged(of: .editorWindow, keyed: true)
    }

    /// The on screen fact is told here as well, because being key is
    /// one of its two inputs and an input that is only ever reported
    /// rising latches. A key window sent to the Dock can hear that it
    /// is miniaturized while it still holds the keyboard, and the fact
    /// read then says on screen. Without a word at the loss it would go
    /// on saying so from inside the Dock, and the next rest would keep
    /// an activation no window of ours could use.
    ///
    /// This can arrive from inside a stance publication, the panel
    /// taking the keyboard in its own raise. The report reads two flags
    /// of the window's and writes a plain stored fact behind another
    /// (`BackdropModel.editorWindowOnScreenChanged`), so nothing
    /// published is read halfway.
    func windowDidResignKey(_ notification: Notification) {
        reportOnScreen()
        model.keyStatusChanged(of: .editorWindow, keyed: false)
    }

    /// Into the Dock and out of it. Each one reads the window afresh
    /// and tells the model the one fact it keeps; neither moves
    /// ownership, since a miniaturized window is still open
    /// (`BackdropModel.editorWindowOpen`).
    ///
    /// The app being hidden is deliberately no input. ⌘H takes every
    /// window off the screen, and the only word AppKit sends when they
    /// come back is the occlusion callback, which arrives some time
    /// after the activation that brought them. When the activation
    /// still read this fact as a claim, a fact fed from that callback
    /// was false at the one moment it was read: ⌘Tab back with Settings
    /// holding the keys keyed nothing of this window's, the activation
    /// found no claim, and the card was raised over an editor window in
    /// plain view. The activation no longer reads it
    /// (`ActivationRouter`). Nobody asks the fact while the app is
    /// hidden, since the one route that reads it, the rest's activation
    /// hand back, runs in an active app and activating unhides, so a
    /// hidden window answers as the window it is about to be again.
    func windowDidMiniaturize(_ notification: Notification) {
        reportOnScreen()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        reportOnScreen()
    }

    private func reportOnScreen() {
        guard let window else { return }
        model.editorWindowOnScreenChanged(Self.isOnScreen(window))
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        onScreen(miniaturized: window.isMiniaturized, key: window.isKeyWindow)
    }

    /// Whether the window is somewhere the person can see it and type
    /// into it, pure: out of the Dock. A key window is on screen
    /// whatever its flag says, which covers the moment a window leaving
    /// the Dock is handed the keyboard ahead of the flag. Whether the
    /// window is visible is no part of it, because the one thing that
    /// makes an open window invisible is the app being hidden, and that
    /// is over by the time anybody asks. One predicate, read by the
    /// model's fact and by the keyboard's return alike, so the rest's
    /// hand back and the return cannot disagree about the same window.
    nonisolated static func onScreen(miniaturized: Bool, key: Bool) -> Bool {
        key || !miniaturized
    }

    /// The model is told while the window is still whole, and the
    /// content is dropped after. The transfer the close causes is what
    /// takes this window's editor off its page
    /// (`PageModel.transferOwnership(to:)`), and it reads the caret and
    /// the scroll on the way, which are only there to read while the
    /// editor stands in a sized scroller over its own layout. When a
    /// hosting view dismantles what it held is AppKit's to decide, in
    /// this turn or a later one, and with the hand off done first
    /// neither answer loses the person's place: the dismantle finds an
    /// editor that has already left its page and has nothing to add.
    ///
    /// Key status needs no word of its own: if this window owned, the
    /// transfer forgets the keys with everything else the outgoing
    /// owner held, and if the panel owned they were never this
    /// window's.
    func windowWillClose(_ notification: Notification) {
        let closingWindowID = window.map(ObjectIdentifier.init)
        captureObserver = nil
        ownerObserver = nil
        window?.delegate = nil
        model.editorWindowClosed()
        window?.contentView = nil
        window = nil
        Self.logger.info("editor window=closed")
        // Decide after AppKit has finished transferring key status away
        // from the closing window. Settings, About, or any other visible
        // window that can become key keeps the app active; with none, an
        // active app with only a resting card (or no ambient panel) would
        // strand the keyboard. A raised, keyed panel keeps it as before.
        guard !switchingToAmbientPanel else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let anotherVisibleKeyCapableWindow = NSApp.windows.contains { candidate in
                candidate.isVisible
                    && candidate.canBecomeKey
                    && closingWindowID != ObjectIdentifier(candidate)
            }
            if Self.closeHandsBackActivation(
                appActive: NSApp.isActive,
                panelHoldsKeys: model.pages.owner == .panel && model.holdsKeys,
                anotherVisibleKeyCapableWindow: anotherVisibleKeyCapableWindow
            ) {
                NSApp.deactivate()
            }
        }
    }

    /// The close's deferred activation decision, pure so the window-list
    /// qualification can be covered without driving AppKit's close cycle.
    nonisolated static func closeHandsBackActivation(
        appActive: Bool, panelHoldsKeys: Bool, anotherVisibleKeyCapableWindow: Bool
    ) -> Bool {
        !anotherVisibleKeyCapableWindow
            && BackdropModel.editorCloseHandsBackActivation(
                appActive: appActive, panelHoldsKeys: panelHoldsKeys
            )
    }

    // MARK: Ownership coming back

    /// Follow the owner for the one thing a transfer asks of this
    /// window: when a raised panel rests beside it, the page content
    /// comes back here, and the keyboard comes with it if the app is
    /// active (ADR-0033). The panel cannot do that part, since a panel
    /// has no way to hand its key status to a particular window.
    ///
    /// A turn later and never inside the sink. A `@Published` tells its
    /// subscribers on willSet, before the owner has landed, and the
    /// transfer itself runs ahead of the panel's rest; ordering a window
    /// from here would bring its key delegates into a model that is
    /// halfway through both.
    ///
    /// Bringing the window forward is all that happens here. Handing
    /// the editor the keyboard is the model's half, settled when this
    /// window reports the keys (`PageModel.reportKeys(_:from:)`), so a
    /// window that was key already when the page came to it, which has
    /// nothing to reorder, still gets its editor focused.
    private func observeOwner() {
        ownerObserver = model.pages.$owner
            .dropFirst()
            .sink { [weak self] owner in
                guard owner == .editorWindow else { return }
                Task { @MainActor [weak self] in self?.ownershipCameBack() }
            }
    }

    private func ownershipCameBack() {
        guard let window, model.pages.owner == .editorWindow else { return }
        guard Self.takesKeysWithOwnership(
            appActive: NSApp?.isActive ?? false,
            onScreen: Self.isOnScreen(window),
            alreadyKey: window.isKeyWindow,
            modalSessionRunning: ModalSession.isRunning
        ) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Whether the keyboard comes back with the page content, pure.
    /// Only into an active app: the hotkey raises the panel without
    /// activating, and resting it from there returns the keyboard to
    /// the app the person was in, which a window of ours made key would
    /// take away again. Only a window the person can see, never over a
    /// modal panel of ours, and not when there is nothing to do.
    nonisolated static func takesKeysWithOwnership(
        appActive: Bool, onScreen: Bool, alreadyKey: Bool, modalSessionRunning: Bool
    ) -> Bool {
        appActive && onScreen && !alreadyKey && !modalSessionRunning
    }

    /// Mechanics only, never content; the surface's own subsystem.
    private static let logger = Logger(
        subsystem: FormFactor.backdrop.loggerSubsystem, category: "editor-window"
    )
}

/// The editor window's face: the shared page surface in a plain stack,
/// with whichever page picker the person has chosen, where they chose
/// to have it. The archived panel's `WindowRootView` is the skeleton;
/// the title bar stands in for its header.
private struct PrimaryEditorRootView: View {
    @ObservedObject var pages: PageModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if pages.showsPagesDownSide && !pages.isPageExpanded {
                    if pages.showsTimeUnits {
                        TimeRailView(model: pages)
                    } else {
                        SlotRailView(model: pages)
                    }
                    Divider()
                }
                content
            }
            PageStatusStack(model: pages)
            if !pages.showsPagesDownSide && !pages.isPageExpanded {
                Divider()
                if pages.showsTimeUnits {
                    TimeStripView(model: pages)
                } else {
                    TabStripView(model: pages)
                }
            }
        }
        .background(Color.panelBackground)
        .background(PageKeyboardMap(model: pages))
        // Said once, at the root, and read by everything under it that
        // writes to the model: the editor's mount, the roll and the
        // keyboard map all name this window as the one writing.
        .environment(\.presentationSurface, .editorWindow)
    }

    /// Only the selected presentation mounts content. The window is closed
    /// when switching to the ambient panel; it has no duplicate glance.
    @ViewBuilder
    private var content: some View {
        if pages.owner == .editorWindow {
            PageContentView(model: pages, emptyHint: "click or ↩ to start one")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
