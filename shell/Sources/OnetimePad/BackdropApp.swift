import AppKit
import Combine
import Darwin
import CompanionKit
import os

@main
@MainActor
enum BackdropApp {
    static func main() {
        guard AppLaunchIdentity.accepts(Bundle.main.bundleIdentifier) else {
            FileHandle.standardError.write(Data(
                "OnetimePad refused startup (bundle identifier: \(Bundle.main.bundleIdentifier ?? "none")): launch a packaged app with a recognized bundle identifier. Use scripts/dev.sh for development and scripts/test-shell.sh for isolated tests.\n".utf8))
            exit(EXIT_FAILURE)
        }
        let application = NSApplication.shared
        let delegate = BackdropAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

enum CloseMenuItem: Equatable {
    case closeFile
    case closeLedger
    case closePage(enabled: Bool)
    case closeWindow(enabled: Bool)

    static func resolve(
        target: CloseChordTarget, showing: SurfaceTarget, ledgerShowing: Bool,
        keyWindowCanClose: Bool
    ) -> CloseMenuItem {
        switch (target, showing) {
        case (.surface, .file): return .closeFile
        case (.surface, _) where ledgerShowing: return .closeLedger
        case (.surface, .tab): return .closePage(enabled: true)
        case (.surface, .today): return .closePage(enabled: false)
        case (.companionWindow, _): return .closeWindow(enabled: keyWindowCanClose)
        case (.nothing, _): return .closeWindow(enabled: false)
        }
    }

    var title: String {
        switch self {
        case .closeFile: return "Close File"
        case .closeLedger: return "Close Ledger"
        case .closePage: return "Close Page"
        case .closeWindow: return "Close Window"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .closeFile, .closeLedger: return true
        case .closePage(let enabled), .closeWindow(let enabled): return enabled
        }
    }
}

enum ManualLanguageChoiceTarget: Equatable {
    case editor
    case file(UInt64)

    static func resolve(
        editorCanChoose: Bool,
        editorSelectionIsEmpty: Bool?,
        selectedFile: UInt64?
    ) -> Self? {
        if editorCanChoose { return .editor }
        guard editorSelectionIsEmpty == true else { return nil }
        return selectedFile.map(Self.file)
    }

    /// Runs a choice: an editor's goes down the responder chain to whichever
    /// surface holds the keys (Law 0007, keys row), a file's render mode to the model.
    @MainActor
    func choose(
        _ language: String,
        send: (Selector, Any?) -> Void,
        selectFileMode: (FileRenderMode, UInt64) -> Void
    ) {
        switch self {
        case .editor:
            send(
                #selector(LanguageDetectionResponder.chooseCodeLanguage(_:)),
                CodeLanguageChoice(language: language))
        case .file(let id):
            selectFileMode(.source(language), id)
        }
    }
}

@MainActor
final class BackdropAppDelegate: NSObject, NSApplicationDelegate {
    private let model: BackdropModel
    private let applicationIsActive: () -> Bool
    private var startupComplete = false
    private enum PendingApplicationOpen {
        case untitled
        case reopen(hasVisibleWindows: Bool)
    }
    private var pendingApplicationOpen: PendingApplicationOpen?
    private var defaultLaunch = true
    private var initialOpenHandled = false

    override init() {
        model = BackdropModel()
        applicationIsActive = { NSApp.isActive }
        super.init()
    }

    init(model: BackdropModel, applicationIsActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.model = model
        self.applicationIsActive = applicationIsActive
        super.init()
    }
    private var controller: BackdropWindowController?
    private var mainMenu: MainMenuController?
    private lazy var commandPalette = CommandPaletteController(model: pages,
        performWindowCommand: { [weak self] command in
            guard let self else { return }
            if command == .appHelp { self.openHelp(nil) }
            else if command == .windowClose { self.sendToResponder(#selector(NSWindow.performClose(_:))) }
        }, returnToPages: { [weak self] in self?.returnToOwner() })
    private var statusItem: NSStatusItem?
    private var summonKey: BackdropHotKey?
    private var summonKeyFailure: BackdropHotKey.RegistrationFailure?
    private static let logger = Logger(subsystem: FormFactor.backdrop.loggerSubsystem, category: "shortcut")
    /// The Settings and Send Feedback controllers, made on first use.
    /// Backed by optionals rather than `lazy` so that a question about
    /// a window they may not have made yet does not make the controller.
    private(set) var madeSettings: BackdropSettingsWindowController?
    private var settings: BackdropSettingsWindowController {
        if let madeSettings { return madeSettings }
        let made = BackdropSettingsWindowController(model: model)
        madeSettings = made
        return made
    }
    private var madeFeedback: FeedbackWindowController?
    private var feedback: FeedbackWindowController {
        if let madeFeedback { return madeFeedback }
        let made = FeedbackWindowController(model: model) { [unowned self] in
            diagnosticReport()
        }
        madeFeedback = made
        return made
    }

    /// The About panel `showAbout` last put up, by identity. AppKit
    /// reuses the one panel for the life of the process.
    private weak var aboutPanel: NSWindow?


    /// The primary editor window (ADR-0033), the second of the two
    /// content windows over the one model. Optional backed, as Settings is.
    private var madeEditorWindow: PrimaryEditorWindowController?
    private var editorWindow: PrimaryEditorWindowController {
        if let madeEditorWindow { return madeEditorWindow }
        let made = PrimaryEditorWindowController(model: model)
        madeEditorWindow = made
        return made
    }

    /// Whether a window is one of the app's own ordinary windows:
    /// Settings, Send Feedback, or the About panel AppKit put up. ⌘W
    /// closes one of them while it has the keyboard (#201), and the card
    /// lowers under it (#293).
    func isCompanionWindow(_ window: NSWindow) -> Bool {
        Self.isCompanionWindow(
            window, settings: madeSettings?.window, feedback: madeFeedback?.window, about: aboutPanel)
    }

    /// The companion rule, pure so each window is an assertion: identity
    /// against the windows already made, and no scan of `NSApp.windows`.
    static func isCompanionWindow(
        _ window: NSWindow, settings: NSWindow?, feedback: NSWindow?, about: NSWindow?
    ) -> Bool {
        [settings, feedback, about].contains { $0 === window }
    }

    /// Whether a window is the owner's: the panel, its key relay, or the
    /// primary editor window. ⌘W closes the surface's page or file there.
    private func isOwnerWindow(_ window: NSWindow) -> Bool {
        controller?.owns(window) == true || madeEditorWindow?.owns(window) == true
    }

    private var aboutActivation = false
    private var settingsActivation = false
    /// The activation claim for every other window or alert of ours that
    /// is not the surface: Send Feedback, Export Diagnostics, and the
    /// alert that explains an unavailable shortcut.
    private var auxiliaryActivation = false

    /// An inactive app must finish activating before its editor can be key.
    private var pendingEditorSummon: ActivationRoute?

    /// Files the Finder asked to open, waiting for a drain (`FinderOpenPlan`).
    private(set) var finderDocuments: [URL] = []

    /// Selects the editor after a Finder open; a test replaces it so its runner opens no window.
    lazy var selectEditor: () -> Void = { [weak self] in
        self?.applySummon(.openEditorPresentation)
    }

    lazy var selectInitialEditor: () -> Void = { [weak self] in
        self?.applySummon(.launchActivation)
    }

    /// Drains the Finder queue a turn after `pendingFileClose` returns to nil.
    private var closeDecisionObserver: AnyCancellable?

    /// The observation of `ModalSession.didEndNotification`, held for
    /// the life of the delegate, which is the life of the process.
    private var modalEndObserver: NSObjectProtocol?

    /// The observation of every window's close, held as long, which is
    /// how the model learns that the keyboard is coming back from a
    /// window that is neither content window
    /// (`BackdropModel.auxiliaryWindowReleasedKeys`).
    private var windowCloseObserver: NSObjectProtocol?

    /// Which window is key, for the ⌘W and ⇧⌘W items (issue #201).
    /// Starts observing once the app has finished launching.
    private(set) lazy var keyWindow = KeyWindowFacts(
        isOwnerWindow: { [weak self] window in self?.isOwnerWindow(window) ?? false },
        isCompanionWindow: { [weak self] window in self?.isCompanionWindow(window) ?? false }
    )

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard startupComplete else {
            if case nil = pendingApplicationOpen { pendingApplicationOpen = .untitled }
            return true
        }
        guard finderDocuments.isEmpty else {
            initialOpenHandled = true
            return true
        }
        if initialOpenHandled {
            _ = applicationShouldHandleReopen(sender, hasVisibleWindows: false)
            return true
        }
        initialOpenHandled = true
        guard defaultLaunch else { return true }
        selectInitialEditor()
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let mainMenu = MainMenuController(app: self)
        self.mainMenu = mainMenu
        mainMenu.install()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyWindow.observe()

        // The Dock and the ⌘Tab card draw from `applicationIconImage`.
        // Re-publish the bundled icon here rather than leaving AppKit to
        // resolve CFBundleIconFile, because LaunchServices can otherwise
        // keep the previous image in the switcher after an icon-only
        // update. A bare `swift run` has no bundle icon, so it keeps the
        // coloured maruhi fallback. The menu-bar item gets the monochrome
        // template below either way.
        NSApp.applicationIconImage = Self.bundledIconImage() ?? Self.maruhiColorImage(side: 256)

        let controller = BackdropWindowController(
            model: model,
            onCardClick: { [weak self] in
                guard let self else { return }
                self.apply(
                    ActivationRouter.decide(.cardClick, in: self.activationContext())
                )
            },
            isCompanionWindow: { [weak self] window in
                self?.isCompanionWindow(window) ?? false
            }
        )
        self.controller = controller
        // Esc, and every other hand-back route, rests a raised surface:
        // the backdrop's way of giving the keyboard back is to step
        // behind everything again. From the editor window, beside a
        // card already resting, it moves nothing.
        model.pages.onHandBackKeys = { [weak model] in model?.handBackKeys() }
        model.onOpenEditorWindow = { [weak self] in self?.openEditorPresentation() }
        model.pages.onOpenSettings = { [weak self] in self?.openSettings() }
        model.pages.onReopenDatedTabs = { [weak self] in self?.showCommandPalette(reopen: true) }
        model.pages.onOpenSettingsPane = { [weak self] pane in self?.openSettingsTab(SettingsTab(pane)) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.trayImage()
        item.button?.setAccessibilityLabel(Self.productName)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // ⌃⌥Space, system-wide. Registration can fail (another app
        // holds the combination); the menu-bar item still summons.
        registerSummonShortcut()

        // Every modal of ours reports back when it returns
        // (`ModalSession`), and the surface answers by coming forward
        // again. Queue nil: the bracket posts on the main thread, on the
        // turn the panel returned, and the answer is deferred by hand
        // below rather than by the centre.
        modalEndObserver = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.modalSessionEnded() }
        }

        // A window of ours closing while it holds the keyboard leaves
        // AppKit to choose who has it next, and the model needs to know
        // that the choice was nobody's gesture (ADR-0033: a modal
        // return goes back to the owner). The observation is of every
        // window and asks only whether it was key. Settings and About
        // are the ones it is for. The editor window closing arms it
        // too and harmlessly, since no editor window is left to be
        // keyed, and the panel and its key relay are ordered out and
        // never closed. Queue nil: the word has to reach the model
        // ahead of the key event the close is about to cause.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { [weak self] notification in
            // The window's identity crosses into the main actor's
            // isolation and the notification does not, since it is not
            // Sendable. AppKit posts this one on the main thread.
            let closing = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.startupComplete, let closing else { return }
                if NSApp.keyWindow.map(ObjectIdentifier.init) == closing {
                    self.model.auxiliaryWindowReleasedKeys()
                }
                // Once AppKit has removed the closing window, return an
                // otherwise stranded activation. This also covers the
                // last auxiliary window closing after the editor did.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let anotherVisibleKeyCapableWindow = NSApp.windows.contains { candidate in
                        ObjectIdentifier(candidate) != closing
                            && candidate.isVisible
                            && candidate.canBecomeKey
                    }
                    if PrimaryEditorWindowController.closeHandsBackActivation(
                        appActive: NSApp.isActive,
                        panelHoldsKeys: self.model.pages.owner == .panel && self.model.holdsKeys,
                        anotherVisibleKeyCapableWindow: anotherVisibleKeyCapableWindow
                    ) {
                        NSApp.deactivate()
                    }
                }
            }
        }

        // Initial foreground opening arrives through applicationOpenUntitledFile.
        // Background launches only start the configured ambient presentation.
        KeychainIntroduction.showIfNeeded(defaults: FormFactor.settingsDefaults)
        controller.show()
        completeStartup(notification)
    }

    /// Drain queued document and application-open events after model startup.
    func completeStartup(_ notification: Notification) {
        defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool != false
        startupComplete = true
        // @Published emits before the store, so the drain waits a turn to read the decision gone.
        closeDecisionObserver = pages.$pendingFileClose
            .map { $0 == nil }
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.drainFinderDocuments() }
            }
        let openedFinderDocument = drainFinderDocuments()
        if let pendingApplicationOpen {
            self.pendingApplicationOpen = nil
            if !openedFinderDocument && finderDocuments.isEmpty {
                switch pendingApplicationOpen {
                case .untitled:
                    _ = applicationOpenUntitledFile(NSApplication.shared)
                case .reopen(let visible):
                    _ = applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible)
                }
            }
        }
    }


    /// The routing table's world, read straight off the model. Kept in
    /// one place so every route builds it the same way and so the two
    /// activation callbacks that consume the About/Settings claim can
    /// override that one input.
    func activationContext(claimed: Bool = false) -> ActivationContext {
        ActivationContext(
            ambientPanelEnabled: model.ambientPanelEnabled,
            owner: model.pages.owner,
            claimedByAnotherWindow: claimed
        )
    }

    /// Dispatch a routing decision to the surface it names. The verbs
    /// stay here: the routing function is pure, and the wiring between
    /// its answer and the two window controllers is the delegate's.
    /// `.openEditorWindow` uses `show()` because it deminiaturizes and
    /// orders front (the reopen expects both). Its associated raise
    /// still carries the launch's anchoring intent even though no panel
    /// is raised.
    func apply(_ route: ActivationRoute) {
        Self.dispatch(
            route,
            openEditorWindow: { [self] raise in
                if BackdropModel.anchorsOnToday(raise: raise) {
                    model.pages.anchorOnToday()
                }
                editorWindow.show()
            },
            raisePanel: { [model] raise in model.raise(raise) },
            summonPanel: { [model] in model.summon() },
            closeEditorForPanel: { [self] in madeEditorWindow?.closeForAmbientPanel() }
        )
    }

    /// Accepted ADR-0033 says: "With the panel off, the hotkey and the
    /// status item select the editor window." Activating the app for
    /// this case is an implementation interpretation of that selection,
    /// so the ordinary editor window can take keyboard focus. Show it from
    /// that activation callback, which must not route this same gesture
    /// a second time as a launch or ⌘Tab (and possibly anchor on today).
    func applySummon(_ reason: ActivationReason) {
        guard startupComplete else { return }
        aboutActivation = false
        settingsActivation = false
        auxiliaryActivation = false
        let route = ActivationRouter.decide(reason, in: activationContext())
        if ActivationRouter.defersForActivation(route: route, appActive: applicationIsActive()) {
            // Clear pending intent if activation is lost before the command can finish.
            pendingEditorSummon = route
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        apply(route)
    }

    /// Routes one decision to its verb while preserving associated
    /// values. Deliberate panel routes close the editor before raising;
    /// recovery raises only restore the existing panel. Kept pure so tests
    /// pin both that ordering and the launch's summon reason.
    nonisolated static func dispatch(
        _ route: ActivationRoute,
        openEditorWindow: (BackdropRaise) -> Void,
        raisePanel: (BackdropRaise) -> Void,
        summonPanel: () -> Void,
        closeEditorForPanel: () -> Void
    ) {
        switch route {
        case .openEditorWindow(let raise): openEditorWindow(raise)
        case .raisePanel(let raise): raisePanel(raise)
        case .summonPanel:
            closeEditorForPanel()
            summonPanel()
        case .showAmbientPanel:
            closeEditorForPanel()
            raisePanel(.activation)
        case .noop: break
        }
    }

    /// Quit performs one synchronous shell-state flush. A settled flush
    /// terminates, including when the sealed drafts contain unsaved file
    /// buffers. A refused or unsavable flush cancels the first quit and
    /// puts the quit anyway line under the page (`QuitPrompt`); the
    /// surface is raised so that line is on screen, because a ⌘Q that
    /// appears to do nothing over a resting card is the one outcome
    /// worse than a dialog. The raise is an activation, not a summon:
    /// the person named the app, and the roll stays where it was. The
    /// second ⌘Q, or the line's button, terminates.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = QuitPrompt.terminateReply(flushing: model)
        if reply == .terminateCancel {
            // A cancelled quit goes back to the owner (ADR-0033: the
            // quit anyway line is under the page, and the page is in
            // the window that owns it). Routed through the same table
            // every activation reads, so the "back to owner" rule is
            // written once.
            apply(ActivationRouter.decide(.cancelledQuit, in: activationContext()))
        }
        return reply
    }

    /// AppKit restores focus on activation; only a pending explicit command selects an editor.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard startupComplete else { return }
        // Returning to the app also checks changes made by external file editors.
        pages.checkOpenFilesOnActivate()
        // A companion request supersedes an editor selection waiting for activation.
        let claimed = aboutActivation || settingsActivation || auxiliaryActivation
        aboutActivation = false
        settingsActivation = false
        auxiliaryActivation = false
        let pending = pendingEditorSummon
        pendingEditorSummon = nil
        apply(ActivationRouter.routeForActivation(
            pendingSummon: pending,
            context: activationContext(claimed: claimed)
        ))
    }

    func applicationWillResignActive(_ notification: Notification) {
        // A completed activation consumes the intent above. If the app
        // instead loses activation, no summon should survive that turn
        // away and take precedence over a later return.
        pendingEditorSummon = nil
        aboutActivation = false
        settingsActivation = false
        auxiliaryActivation = false
    }

    /// The Finder's Open and Open With, and files dropped on the Dock icon.
    /// Queued, then opened by the drain once startup is done, no modal is
    /// up and no close decision stands.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: \.isFileURL) { initialOpenHandled = true }
        finderDocuments += urls
        drainFinderDocuments()
    }

    /// Opens what `FinderOpenPlan` allows and keeps the rest; true when a file opened.
    @discardableResult
    private func drainFinderDocuments() -> Bool {
        let plan = FinderOpenPlan.decide(
            queued: finderDocuments,
            startupComplete: startupComplete,
            modalSessionRunning: ModalSession.isRunning,
            modalBracketed: ModalSession.isBracketed,
            closeDecisionPending: pages.openRefusedForCloseDecision)
        finderDocuments = plan.held
        guard openDocuments(plan.open) else { return false }
        return true
    }

    /// Opens each file as a drop would, then selects the editor window without moving the roll.
    private func openDocuments(_ urls: [URL]) -> Bool {
        guard BackdropRootView.forwardDroppedURLs(urls, openFile: { pages.openFile(at: $0) })
        else { return false }
        selectEditor()
        return true
    }

    /// A modal open or save panel has returned, accepted or cancelled.
    /// The surface was raised when it went up, since either panel is
    /// reached from a keyed card or from a menu of an active
    /// app, and it comes forward again now: the panel took the keyboard
    /// on its way in, AppKit promises nothing about where the keyboard
    /// goes on the way out, and a person who has just chosen a file is
    /// owed the pad it opens into.
    ///
    /// Raised as an activation, not a summon: nobody named the surface,
    /// and the roll stays where the person left it (`BackdropRaise`).
    /// Only over a raised surface, because a rest that happened while
    /// the panel was up was somebody's deliberate act and is not ours
    /// to undo. Deferred a turn so the raise runs outside the
    /// caller's own stack, which for the open panel is the model in the
    /// middle of opening the file.
    ///
    /// The deferred half asks `ModalSession.isRunning` again, for the
    /// same reason the outside press rule asks it: the main queue
    /// drains inside a modal's run loop, so a second modal opened on
    /// the first one's return would run this turn under its own
    /// session, and a `makeKeyAndOrderFront` under a live modal is
    /// exactly what the bracket exists to prevent. No chain in the app
    /// runs two modals back to back today; the guard is what keeps
    /// that a fact about the app rather than a requirement on it.
    private func modalSessionEnded() {
        // The gate on stance is kept: a rest that happened while the
        // panel was up was somebody's deliberate act and is not ours
        // to undo. Deferred a turn for the reason
        // `raisesAfterModal` names, and the same fact is asked again
        // there (no modal of ours running now). The route itself is
        // the routing function's, so "back to the owner" is written
        // in one place.
        let raisedWhenItEnded = model.stance == .raised
        Task { @MainActor [weak self] in
            // A Finder open held through the modal selects the editor in place of the return.
            guard let self, !self.drainFinderDocuments(), raisedWhenItEnded,
                Self.raisesAfterModal(
                    stance: self.model.stance, modalSessionRunning: ModalSession.isRunning)
            else { return }
            self.apply(ActivationRouter.decide(.modalReturn, in: self.activationContext()))
        }
    }

    /// Whether the deferred raise after a modal goes ahead: only over
    /// a surface still raised, and only once no modal of ours is up.
    /// The same two facts the outside press rule weighs, read the same
    /// way, so that the two surface actions a modal touches cannot
    /// disagree about what "a modal of ours is up" means.
    nonisolated static func raisesAfterModal(
        stance: BackdropStance, modalSessionRunning: Bool
    ) -> Bool {
        stance == .raised && !modalSessionRunning
    }

    /// Reopen orders existing ordinary windows, or explicitly requests an editor.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        initialOpenHandled = true
        guard startupComplete else {
            pendingApplicationOpen = .reopen(hasVisibleWindows: flag)
            return false
        }
        pages.checkOpenFilesOnActivate()
        if ModalSession.isRunning || ModalSession.isBracketed { return false }
        var frontmost: NSWindow?
        sender.enumerateWindows(options: [.orderedFrontToBack]) { window, stop in
            if let target = Self.reopenWindow(window,
                isAmbientWindow: { self.controller?.owns($0) == true },
                isCompanion: { self.isCompanionWindow($0) }) {
                frontmost = target
                stop.pointee = true
            }
        }
        if let frontmost {
            // AppKit can report no visible windows when only an NSPanel remains.
            if !flag { frontmost.makeKeyAndOrderFront(nil) }
            return flag
        }
        applySummon(.reopen)
        return false
    }

    static func reopenWindow(
        _ window: NSWindow, isAmbientWindow: (NSWindow) -> Bool, isCompanion: (NSWindow) -> Bool
    ) -> NSWindow? {
        let target = window.sheetParent ?? window
        guard !isAmbientWindow(target),
              isVisibleOrdinaryWindow(window, isAmbientWindow: isAmbientWindow(window),
                                      isCompanion: isCompanion(window)) else { return nil }
        return target
    }

    static func isVisibleOrdinaryWindow(
        _ window: NSWindow, isAmbientWindow: Bool, isCompanion: Bool = false
    ) -> Bool {
        !isAmbientWindow && window.isVisible && !window.isMiniaturized
            && (isCompanion || window.canBecomeMain || window.isSheet)
    }

    /// Left click summons (raise, or re-key, or rest — the summon
    /// decision); ⌥-click goes straight to Settings; right click gets
    /// presentation switches alongside About, Settings, and Quit.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.autoenablesItems = false
            // Technical identity is optional here; About always carries it.
            // With menu auto-enabling off, disable the identity line explicitly.
            if pages.showsVersionsInMenu {
                let versionItem = menu.addItem(
                    withTitle: BuildVersion.menuTitle(
                        ffiVersion: CompanionClient.ffiVersion,
                        coreVersion: CompanionClient.coreVersion,
                        bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                        devLane: BuildVersion.isDevLane(
                            bundleIdentifier: Bundle.main.bundleIdentifier)
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                versionItem.isEnabled = false
                menu.addItem(.separator())
            }
            menu.addItem(
                withTitle: "About \(Self.productName)",
                action: #selector(showAbout),
                keyEquivalent: ""
            ).target = self
            addPresentationItems(to: menu)
            menu.addItem(.separator())
            let settingsItem = menu.addItem(
                withTitle: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: settingsKeystroke?.menuKeyEquivalent ?? ""
            )
            settingsItem.keyEquivalentModifierMask = settingsKeystroke?.menuModifierMask ?? []
            settingsItem.target = self
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "Quit \(Self.productName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ).target = NSApp
            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
        } else if NSEvent.modifierFlags.contains(.option) {
            // The live hardware state, not the delivered event's flags:
            // a status-bar event can misreport modifiers, and an
            // accessibility press arrives with a stale currentEvent. ⌥
            // physically held right now is the one honest signal: that
            // opens Settings; anything else summons.
            openSettings()
        } else {
            applySummon(.statusItem)
        }
    }

    var commandPaletteIsShowing: Bool { commandPalette.isShowing(in: NSApp.keyWindow) }

    func dismissCommandPaletteForClose() -> Bool {
        commandPalette.dismissForClose(in: NSApp.keyWindow)
    }

    func dismissCommandPaletteForAction() {
        commandPalette.dismiss(restoringFocus: true)
    }

    func showCommandPalette(reopen: Bool = false) {
        guard let window = NSApp.keyWindow, window.sheetParent == nil,
              window.attachedSheet == nil, !ModalSession.isRunning else { return }
        commandPalette.show(in: window, pageContext: isOwnerWindow(window), reopen: reopen)
    }

    var ambientPanelEnabled: Bool { model.ambientPanelEnabled }

    /// Explicit selection ignores companion activation claims, unlike reopen.
    @objc func openEditorPresentation() {
        applySummon(.openEditorPresentation)
    }

    /// Back to whichever surface owns the pages, the editor window or
    /// the panel, by the route a dismissed sheet takes: a menu command
    /// run from Settings names no surface (ADR-0033, ADR-0036).
    func returnToOwner() {
        // Under one of our own modals or sheets the surface stays put,
        // as the route's other takers do (`raisesAfterModal`).
        guard startupComplete, !ModalSession.isRunning,
              NSApp.keyWindow?.sheetParent == nil
        else { return }
        apply(ActivationRouter.decide(.modalReturn, in: activationContext()))
    }

    /// Switch presentations without toggling rest or anchoring on today. This
    /// preserves the page the person is viewing, unlike a hotkey/status summon.
    @objc func showAmbientPresentation() {
        applySummon(.showAmbientPresentation)
    }

    private func registerSummonShortcut() {
        summonKey = nil
        summonKeyFailure = nil
        summonKey = BackdropHotKey.controlOptionSpace(onFailure: { [weak self] failure in
            self?.summonKeyFailure = failure
            DiagnosticEvents.shared.record(.shortcutFailed, status: Int(failure.status))
            Self.logger.error("summon shortcut registration failed stage=\(failure.stage.rawValue, privacy: .public) status=\(failure.status)")
        }) { [weak self] in
            Task { @MainActor in
                self?.applySummon(.hotkey)
            }
        }
        if summonKey != nil { DiagnosticEvents.shared.record(.shortcutRegistered) }
    }

    @objc private func explainUnavailableShortcut() {
        guard let failure = summonKeyFailure else { return }
        let alert = NSAlert()
        alert.messageText = "The keyboard shortcut is unavailable"
        alert.informativeText = "macOS could not register ⌃⌥Space. Another app, or another copy of \(Self.productName), may use it; with two or more input sources, the Input Sources pane of Keyboard Shortcuts may hold it. The pad still opens from the menu bar. Free the shortcut, then try again.\n\nRegistration: \(failure.stage.rawValue), code \(failure.status)."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        auxiliaryActivation = !applicationIsActive()
        NSApp.activate(ignoringOtherApps: true)
        if ModalSession.run({ alert.runModal() }) == .alertFirstButtonReturn {
            registerSummonShortcut()
        }
    }

    /// Shared context-menu commands with explicit enablement for the ambient feature.
    private func addPresentationItems(to menu: NSMenu) {
        Self.addPresentationItems(to: menu, ambientPanelEnabled: model.ambientPanelEnabled,
                                  target: self)
        if summonKeyFailure != nil {
            menu.addItem(withTitle: "⌃⌥Space Unavailable…",
                         action: #selector(explainUnavailableShortcut), keyEquivalent: "").target = self
        }
    }

    /// AppKit's automatic validation must not overwrite our preference check.
    static func addPresentationItems(to menu: NSMenu, ambientPanelEnabled: Bool,
                                     target: NSObject) {
        menu.autoenablesItems = false
        let open = menu.addItem(withTitle: "Open in Window",
                               action: #selector(openEditorPresentation), keyEquivalent: "")
        open.target = target
        let ambient = menu.addItem(withTitle: "Show Ambient Panel",
                                  action: #selector(showAmbientPresentation), keyEquivalent: "")
        ambient.target = target
        ambient.isEnabled = ambientPanelEnabled
    }

    /// The Dock context menu uses the same explicit switches as the status item.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addPresentationItems(to: menu)
        return menu
    }

    /// The chord Settings advertises, taken from the keymap
    /// (`app::Settings`) rather than spelled here.
    ///
    /// A menu key equivalent is an app-wide claim, live even while a
    /// Settings text field holds the keyboard, so only a keymap section
    /// that opted into `use_key_equivalents` can hand one out; the
    /// bundled default does. Nil means the file took the binding away,
    /// and then the menu shows the item without a chord, which is the
    /// right answer to "unbind Settings" and not a reason to put the
    /// old chord back.
    var settingsKeystroke: Keystroke? {
        model.pages.keymap.menuKeystroke(for: .appSettings)
    }

    /// The model the File menu reads its enablement from.
    var pages: PageModel { model.pages }

    /// What Seal Selected Content greys itself out on: whether the
    /// editor holds an editable page with a selection, published by
    /// the model as the selection moves.
    var sealActions: SealActionAvailability { model.pages.sealActions }

    /// Post an action down the responder chain, which is how a menu
    /// item reaches whoever is first responder. Nothing happens when
    /// nothing answers, which is the fail-closed shape the whole seam
    /// keeps: a menu click with no page holding the keyboard moves no
    /// history at all.
    ///
    /// A `Selector` rather than a string: `undo:` misspelled would send
    /// nothing and look exactly like the honest case of nobody
    /// answering, which is the one failure this route cannot report.
    /// `EditStepResponder` is what lets the compiler check the pairing
    /// from a target that cannot see the page's text view.
    func sendToResponder(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// The same, with a sender the answer reads, as Choose Language's
    /// `CodeLanguageChoice` (Law 0007, keys row).
    func sendToResponder(_ selector: Selector, carrying sender: Any?) {
        NSApp.sendAction(selector, to: nil, from: sender)
    }

    /// The Settings window, from the menu bar's ⌘, or either of the
    /// tray's routes. Its `show()` activates the app so the window can
    /// take the keyboard, and that activation must not read as a summon:
    /// the user asked for Settings, not the surface. Flag it, mirroring
    /// About, and only when the activation will actually happen, since
    /// an already-active app fires no notification to consume the flag.
    @objc func openSettings() {
        openSettingsTab(nil)
    }

    func openSettingsTab(_ tab: SettingsTab?) {
        settingsActivation = !applicationIsActive()
        settings.show(tab: tab)
    }

    private func diagnosticReport() -> DiagnosticsReport {
        let shortcutStatus = summonKeyFailure.map {
            "failed (\($0.stage.rawValue), OSStatus \($0.status))"
        } ?? (summonKey == nil ? "not registered" : "registered")
        return DiagnosticsReport.capture(
            model: model,
            companionKeyed: controller?.companionWindowKeyed ?? false,
            shortcutStatus: shortcutStatus
        )
    }

    @objc func exportDiagnostics() {
        auxiliaryActivation = !applicationIsActive()
        NSApp.activate(ignoringOtherApps: true)
        DiagnosticsActions.export(diagnosticReport())
    }

    @objc func copyDiagnosticSummary() {
        DiagnosticsActions.copySummary(diagnosticReport())
    }

    @objc func sendFeedback() {
        auxiliaryActivation = !applicationIsActive()
        feedback.show()
    }

    /// The standard About panel leads with the app's product version and
    /// stamped build in AppKit's conventional fields. The independently
    /// versioned Rust crates sit below them as explicitly labelled technical
    /// details. `AboutVersion.fields` resolves the bundle-less test run too.
    ///
    /// Every route to the panel goes through here, the tray menu and the
    /// app menu's own item alike, because what happens after the panel
    /// is up is load-bearing and AppKit's synthesized item skips it.
    @objc func showAbout() {
        let versions = AboutVersion.fields(
            ffiVersion: CompanionClient.ffiVersion,
            coreVersion: CompanionClient.coreVersion,
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: Self.productName,
            .applicationVersion: versions.applicationVersion,
        ]
        // The build in parentheses, when there is one to show. Absent
        // rather than empty: an empty string would print bare
        // parentheses, which reads as a build the app failed to name.
        if let build = versions.build {
            aboutOptions[.version] = build
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 3
        let technicalVersions = NSMutableAttributedString(
            string: "Technical Versions\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        technicalVersions.append(NSAttributedString(
            string: versions.technicalVersions,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryInk,
                .paragraphStyle: paragraph,
            ]
        ))
        aboutOptions[.credits] = technicalVersions
        // A bare `swift run` has no bundle icon to fall back on; the
        // bundled app shows its AppIcon.icns without help.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            aboutOptions[.applicationIcon] = Self.maruhiColorImage(side: 256)
        }
        NSApp.orderFrontStandardAboutPanel(options: aboutOptions)
        // AppKit builds one About panel and reuses it for the life of
        // the process, and it is an ordinary window: left open, or
        // merely built, on another desktop, it is something of this app
        // to reveal, so the next activation carries the user's screen
        // there. That is exactly the defect ADR-0019 removed from the
        // surface, and Settings takes the same bit at creation. This
        // panel is not ours to construct, so the bit goes on after
        // AppKit has put it up.
        let panel = standardAboutPanel()
        panel?.collectionBehavior.insert(.moveToActiveSpace)
        // Kept by identity, so the lookup runs here once and not on every key event.
        aboutPanel = panel
        // An active app keyed the panel inside the order front, before it was known,
        // so the key window facts and the altitude keeper (#293) read it now.
        keyWindow.refresh()
        if let panel { controller?.noticeCompanionWindow(panel) }
        // The app is usually inactive when About is chosen from the
        // status item; without activation the panel appears behind
        // whatever is frontmost. This activation is About's, not a
        // summon — flag it so the raise is skipped (only when the
        // activation will actually happen; an already-active app fires
        // no notification to consume the flag).
        aboutActivation = !applicationIsActive()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel `orderFrontStandardAboutPanel` has just put up. AppKit
    /// hands back no reference to it, so it is picked out of the app's
    /// windows by what it is: on screen, titled, and carrying no title
    /// text. Settings has a title, and the surface and its key relay are
    /// borderless, so none of those can be mistaken for it. A sheet can:
    /// a confirmation run on the Settings window is visible, titled and
    /// has no title text, and taking it for the panel would hand
    /// the companion lookup a window that closes with the answer (a
    /// sheet counts through its parent instead). So a sheet is never
    /// the panel, and neither is the Settings window itself,
    /// whatever its title reads at the time, or an open or save panel.
    /// If a future macOS builds the panel differently the lookup finds nothing and the panel
    /// keeps the behavior it had before this existed.
    private func standardAboutPanel() -> NSWindow? {
        NSApp.windows.first { window in
            Self.looksLikeTheAboutPanel(
                visible: window.isVisible,
                titled: window.styleMask.contains(.titled),
                title: window.title,
                isSheet: window.isSheet,
                isSettings: madeSettings?.owns(window) == true,
                isFilePanel: window is NSSavePanel
            )
        }
    }

    /// The lookup's rule, pure so each exclusion is an assertion.
    nonisolated static func looksLikeTheAboutPanel(
        visible: Bool, titled: Bool, title: String, isSheet: Bool, isSettings: Bool,
        isFilePanel: Bool
    ) -> Bool {
        visible && titled && title.isEmpty && !isSheet && !isSettings && !isFilePanel
    }

    /// What this app calls itself to the user, for the places a bundle
    /// cannot answer: a bare `swift run` has no Info.plist, so the
    /// About panel, the tray menu and the status item's accessibility
    /// label would otherwise fall back to the executable name. The
    /// bundled app takes the same name from CFBundleName /
    /// CFBundleDisplayName in shell/OnetimePad-Info.plist, and the two
    /// must agree. Neither is the bundle id, which is infrastructure
    /// rather than paint and does not move with the name.
    ///
    /// Read from the bundle rather than hardcoded, because the dev lane
    /// renames itself: `package-app.sh --debug` writes "OnetimePad Dev"
    /// into both name keys, and everything that says the product's name
    /// out loud has to follow it, or the About panel and the tray claim
    /// to be the installed copy while the ⌘Tab switcher says otherwise.
    static let productName: String = {
        let info = Bundle.main.object(forInfoDictionaryKey:)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info(key) as? String, !name.isEmpty { return name }
        }
        return "OnetimePad"
    }()

    /// Loads the icon named by CFBundleIconFile, which package-app.sh
    /// changes when the rendered artwork changes. Assigning this image to
    /// NSApp at launch keeps the current process's ⌘Tab presentation in
    /// step with Finder's bundle icon.
    private static func bundledIconImage() -> NSImage? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: name, withExtension: "icns")
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Where OnetimePad Help goes until the docs site has a page of its
    /// own (issue #294).
    static let helpURL = URL(string: "https://docs.onetimesecret.dev/macos")!

    /// The Help menu's item, through the model's external link route so
    /// a test records the URL rather than starting a browser.
    @objc func openHelp(_ sender: Any?) {
        model.pages.openExternal(Self.helpURL)
    }

    /// Inserts product help into the supplied menu, below view-backed system items.
    @discardableResult
    static func installHelpItem(in helpMenu: NSMenu?, productName: String,
                                keystroke: Keystroke?,
                                target: BackdropAppDelegate) -> NSMenu? {
        guard let helpMenu else { return nil }
        if helpMenu.items.contains(where: { $0.action == #selector(openHelp(_:)) }) { return helpMenu }
        let help = NSMenuItem(title: CompanionL10n.format("%@ Help", productName),
                              action: #selector(openHelp(_:)),
                              keyEquivalent: keystroke?.menuKeyEquivalent ?? "")
        help.keyEquivalentModifierMask = keystroke?.menuModifierMask ?? []
        help.target = target
        // Below any item drawn by a view of its own, which none of ours is.
        let at = helpMenu.items.firstIndex { $0.view == nil } ?? helpMenu.numberOfItems
        helpMenu.insertItem(help, at: at)
        let next = at + 1
        if next < helpMenu.numberOfItems, !helpMenu.items[next].isSeparatorItem {
            helpMenu.insertItem(.separator(), at: next)
        }
        return helpMenu
    }

    /// What sits in the menu bar: the onetimesecret.com logo mark, the
    /// same art the app icon is built from, so the tray and the Dock
    /// tile read as one app. Template images are tinted by the menu bar
    /// for its appearance and for selection, which is why the mark goes
    /// up as a flat silhouette rather than as brand colour.
    ///
    /// The maruhi stands in if the mark cannot be read, since a menu bar
    /// with nothing in it leaves no way back to the surface.
    private static func trayImage() -> NSImage {
        LogoMark.templateImage(side: 18) ?? maruhiTemplateImage()
    }

    /// The ㊙ glyph rendered monochrome (U+FE0E forces text presentation
    /// over emoji) onto a template image: the menu bar tints template
    /// images to match its appearance, which a colour emoji never gets.
    private static func maruhiTemplateImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let glyph = "㊙\u{FE0E}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The ㊙️ emoji (U+FE0F keeps the colour presentation) rendered at
    /// the given side length — the Dock icon, ⌘Tab card, and About panel.
    private static func maruhiColorImage(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let glyph = "㊙\u{FE0F}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.78)
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
            return true
        }
    }
}
