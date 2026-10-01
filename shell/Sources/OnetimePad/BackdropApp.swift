import AppKit
import CompanionKit
import SwiftUI

/// OnetimePad, the background-surface form factor
/// (docs/spec/feature/background-surface): an ambient pane resting at
/// desktop level, raised to a floating editor by ⌃⌥Space or the
/// menu-bar item, beside the primary editor window that ⌘Tab, the
/// Dock icon and a person's launch select (ADR-0033). It began as a
/// sibling of the panel app (ADR-0010), same Rust core through the
/// same seam, different posture; the panel was archived once this form
/// factor reached parity (ADR-0014), and its state file and Keychain
/// items remain untouched by this target.
@main
struct BackdropApp: App {
    @NSApplicationDelegateAdaptor(BackdropAppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppKit owns the windows. Native Settings scene requests still
        // need a destination, even with the menu command replaced below.
        Settings {
            SettingsSceneRedirect(openSettings: appDelegate.openSettings)
        }
            .commands {
                // ⌘F and its neighbours. The editor answers
                // `performTextFinderAction:` (its find bar is on), but
                // nothing sends it without menu items to send it: the
                // card is borderless and this app's only declared scene
                // is the Settings placeholder, so the standard Edit menu
                // is asked for by name rather than assumed.
                TextEditingCommands()
                // Edit → Seal Selected Content (D-30): the menu bar's
                // placement of the seal, beside the pasteboard verbs
                // it is a cousin of. It posts the same action down
                // the responder chain that Undo does, and the page's
                // text view answers with the method the chord runs.
                CommandGroup(after: .pasteboard) {
                    SealSelectionMenuItem(
                        availability: appDelegate.sealActions,
                        shortcut: appDelegate.shortcut(for: SealSelectionMenu.command),
                        send: appDelegate.sendToResponder
                    )
                }
                if PageModel.languageDetectionFeaturesAvailable {
                    CommandGroup(after: .pasteboard) {
                        LanguageDetectionMenuItems(
                            pages: appDelegate.pages,
                            send: appDelegate.sendToResponder
                        )
                    }
                }
                // The app's first File menu (ADR-0028). Every item
                // dispatches the same command id the chord does, so
                // there is one implementation of each verb and the menu
                // cannot drift from the keyboard; the chords are read
                // out of the keymap for the reason ⌘, is, so a person
                // who rebound one sees their own chord here.
                CommandMenu("File") {
                    FileMenuItems(
                        pages: appDelegate.pages,
                        openShortcut: appDelegate.shortcut(for: .fileOpen),
                        saveShortcut: appDelegate.shortcut(for: .stateSaveNow),
                        saveAsShortcut: appDelegate.shortcut(for: .fileSaveAs),
                        closeShortcut: appDelegate.shortcut(for: .pageClose)
                    )
                }
                // These buttons establish the menu placement, labels and
                // configured shortcuts. Once AppKit has built the menu,
                // `routeUndoRedoThroughResponder` turns the items into
                // ordinary nil-targeted `undo:`/`redo:` commands. The
                // focused editor then answers from Loro, while a native
                // field editor in Settings keeps AppKit's own undo stack.
                //
                // The chords come from the keymap, like every other
                // chord this app advertises: nil means the file unbound
                // them, and then the items stay and lose the shortcut.
                CommandGroup(replacing: .undoRedo) {
                    UndoRedoItems(
                        undoShortcut: appDelegate.undoShortcut,
                        redoShortcut: appDelegate.redoShortcut,
                        send: appDelegate.sendToResponder
                    )
                }
                // The scene's automatic "Settings…" (⌘,) item would open
                // the empty placeholder as a blank window. Repoint it so
                // every ⌘, in the app lands on the one real Settings
                // window the delegate owns.
                //
                // "Customize Keyboard Shortcuts…" sits below Settings…
                // because it is a preference too, one that carries no
                // chord of its own on purpose: users rebind it rarely,
                // and offering a shortcut here would spend the chord
                // budget on the door to the file rather than on a page
                // verb. It opens keymap.json as an ordinary document
                // (creating the configuration directory and seeding the
                // bundled default the first time), so the file the app
                // reads is the file the person is editing.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(appDelegate.settingsShortcut)
                    Button("Customize Keyboard Shortcuts…") {
                        appDelegate.pages.openUserKeymapFile()
                    }
                }
                // Repointed for the same reason and with more at stake.
                // The synthesized item calls AppKit's own
                // `orderFrontStandardAboutPanel:`, which builds the
                // panel with default collection behavior; the delegate's
                // route is what puts `.moveToActiveSpace` on it
                // (ADR-0019), and a panel left open on the desktop it
                // was first shown on carries the user back there on the
                // next ⌘Tab. The app is `.regular`, so this menu is on
                // screen whenever the app is active and the route is not
                // hypothetical. It also adds the linked Rust component
                // versions, which the standard item cannot know.
                CommandGroup(replacing: .appInfo) {
                    Button("About \(BackdropAppDelegate.productName)") {
                        appDelegate.showAbout()
                    }
                }
                // The Window menu's Close Window (issue #201, ADR-0033).
                // ⌘W stays `page::Close` on the strip; ⇧⌘W closes the
                // window the keyboard is in and reaches Settings too.
                // The item is placed before AppKit's Minimize/Zoom group
                // so it heads the menu the way Close does in every other
                // macOS app. The chord comes from the keymap, so an
                // override that takes it away leaves the item without a
                // shortcut rather than lying (see docs/development/keymap-format-and-dispatch.md).
                //
                // `performClose:` down the responder chain: the key
                // window answers, so Settings closes on Settings, the
                // editor closes on itself, and the borderless panel
                // (`.panel` and its key relay) answers with nothing to
                // do because it carries no close box. Panel and relay
                // are also `isExcludedFromWindowsMenu = true`, so the
                // menu itself lists the editor window and Settings only.
                CommandGroup(before: .windowArrangement) {
                    appDelegate.presentationCommands
                    Divider()
                    WindowCloseMenuItem(shortcut: appDelegate.shortcut(for: .windowClose)) {
                        appDelegate.sendToResponder(#selector(NSWindow.performClose(_:)))
                    }
                    Divider()
                }
            }
    }
}

/// The File menu: Open, Save, Save As and Close File (ADR-0028).
///
/// A view of its own because a `CommandMenu`'s content is a view, and a
/// view is what can observe the model whose state greys three of these
/// four out.
///
/// Every item goes through `perform`, the same route the chord takes,
/// so each verb has one implementation. Save, Save As and Close File
/// are dimmed while a page rather than a file is showing, because on a
/// page those chords mean something else entirely and a menu that
/// offered them under a file's names would be lying about what the
/// click does.
///
/// Enablement is display and never a gate: the model's own arms decide
/// what happens, and a click that arrives anyway lands on the page
/// reading of the chord rather than on nothing.
@MainActor
private struct FileMenuItems: View {
    @ObservedObject var pages: PageModel
    let openShortcut: KeyboardShortcut?
    let saveShortcut: KeyboardShortcut?
    let saveAsShortcut: KeyboardShortcut?
    let closeShortcut: KeyboardShortcut?

    /// Whether the surface is showing a file, which is what the three
    /// file verbs need to be true.
    private var onAFile: Bool {
        if case .file = pages.activeTarget { return true }
        return false
    }

    var body: some View {
        Button("Open…") { pages.perform(.fileOpen) }
            .keyboardShortcut(openShortcut)
        Divider()
        Button("Save") { pages.perform(.stateSaveNow) }
            .keyboardShortcut(saveShortcut)
            .disabled(!onAFile)
        Button("Save As…") { pages.perform(.fileSaveAs) }
            .keyboardShortcut(saveAsShortcut)
            .disabled(!onAFile)
        Divider()
        Button("Close File") { pages.perform(.pageClose) }
            .keyboardShortcut(closeShortcut)
            .disabled(!onAFile)
    }
}

/// The Edit menu's Undo and Redo.
///
/// SwiftUI supplies their placement and shortcuts. At launch the delegate
/// replaces their targets with the nil-targeted AppKit selectors so menu
/// validation follows the focused responder.
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
}

@MainActor
private struct LanguageDetectionMenuItems: View {
    @ObservedObject var pages: PageModel
    @ObservedObject private var languageActions: LanguageActionAvailability
    let send: (Selector) -> Void

    init(pages: PageModel, send: @escaping (Selector) -> Void) {
        self.pages = pages
        _languageActions = ObservedObject(wrappedValue: pages.languageActions)
        self.send = send
    }

    private var responder: LanguageDetectionResponder? {
        pages.activeEditor as? LanguageDetectionResponder
    }

    private var manualChoiceTarget: ManualLanguageChoiceTarget? {
        ManualLanguageChoiceTarget.resolve(
            editorCanChoose: languageActions.canChoose,
            editorSelectionIsEmpty: languageActions.selectionIsEmpty,
            selectedFile: pages.showingLedger ? nil : pages.selectedFile
        )
    }

    private func chooseSourceLanguage(_ language: String) {
        switch manualChoiceTarget {
        case .editor:
            responder?.chooseCodeLanguage(language)
        case .file(let id):
            pages.selectFileRenderMode(.source(language), for: id)
        case nil:
            break
        }
    }

    var body: some View {
        Button("Detect Code Language…") {
            send(#selector(LanguageDetectionResponder.detectCodeLanguage(_:)))
        }
        .disabled(!languageActions.canDetect)

        Menu("Choose Language") {
            if case .file(let id) = manualChoiceTarget {
                Button("Plain Text") { pages.selectFileRenderMode(.plainText, for: id) }
                Button("Markdown") { pages.selectFileRenderMode(.markdown, for: id) }
                Divider()
            }
            ForEach(InkEditorView.Coordinator.manualLanguages, id: \.self) { language in
                Button(language.capitalized) { chooseSourceLanguage(language) }
            }
        }
        .disabled(manualChoiceTarget == nil)

        Button("Paste Without Detection") {
            send(#selector(LanguageDetectionResponder.pasteWithoutDetection(_:)))
        }
        .disabled(pages.activeEditor?.isEditable != true)
    }
}

@MainActor
private struct UndoRedoItems: View {
    let undoShortcut: KeyboardShortcut?
    let redoShortcut: KeyboardShortcut?
    let send: (Selector) -> Void

    var body: some View {
        Button("Undo") { send(#selector(EditStepResponder.undo(_:))) }
            .keyboardShortcut(undoShortcut)
        Button("Redo") { send(#selector(EditStepResponder.redo(_:))) }
            .keyboardShortcut(redoShortcut)
    }
}

/// The Edit menu's Seal Selected Content (D-30). It greys itself out on
/// the model's answer, which is whether the editor holds an editable page
/// with a selection. The chord comes from the keymap like every other chord
/// the menus advertise, and the page's text view claims it first; the menu
/// carries it to show what the item costs, not to be the thing that fires.
private struct SealSelectionMenuItem: View {
    @ObservedObject var availability: SealActionAvailability
    let shortcut: KeyboardShortcut?
    let send: (Selector) -> Void

    var body: some View {
        Button(SealSelectionMenu.editMenuTitle) {
            send(#selector(SealResponder.sealSelectedContent(_:)))
        }
        .keyboardShortcut(shortcut)
        .disabled(!availability.canSeal)
    }
}

/// The Window menu's Close Window (issue #201). A view of its own
/// because `.keyboardShortcut(nil)` on a `Button` inside a Window-menu
/// `CommandGroup` empties the group in place, item and neighbouring
/// divider both; the surrounding menu closes over the gap and the
/// item disappears rather than losing only its chord. Splitting the
/// two arms into distinct expressions keeps the button live when the
/// keymap has nothing to say, which is the fail-open shape the doc
/// comment on the group promises.
private struct WindowCloseMenuItem: View {
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    var body: some View {
        if let shortcut {
            Button("Close Window", action: action)
                .keyboardShortcut(shortcut)
        } else {
            Button("Close Window", action: action)
        }
    }
}

@MainActor
final class BackdropAppDelegate: NSObject, NSApplicationDelegate {
    private let model = BackdropModel()
    private var controller: BackdropWindowController?
    private var statusItem: NSStatusItem?
    private var summonKey: BackdropHotKey?
    private lazy var settings = BackdropSettingsWindowController(model: model)

    /// The primary editor window (ADR-0033), the second of the two
    /// content windows over the one model.
    private lazy var editorWindow = PrimaryEditorWindowController(model: model)

    /// Holds the About panel at the surface's keyless altitude while
    /// it is open. Settings owns a follower of its own; this one is
    /// the delegate's because the About panel is AppKit's and has no
    /// controller of ours to live in.
    private lazy var aboutLevelFollower = CompanionLevelFollower(model: model)

    /// Not every activation is the same raise, and one kind of launch
    /// brings no activation at all. A launch the person performs, from
    /// the Finder, the Dock, Spotlight or `open`, activates the app
    /// within moments of `applicationDidFinishLaunching`, and that
    /// activation is read as the launch itself and routed to the editor
    /// as a summon. A login item, or any other launch the system performs
    /// in the background, never activates, so nothing arrives inside the
    /// launch window.
    /// About's activation is flagged by `showAbout`, and Settings' by
    /// `openSettings`, because those windows need the activation for
    /// themselves without dragging the surface up with them. A
    /// panel-off editor summon waits for its own activation before
    /// showing the window. Every other activation, whether by ⌘Tab or
    /// the Dock icon, is the user choosing this app and answers with a
    /// raise.
    ///
    /// The launch time is taken in `applicationWillFinishLaunching`,
    /// the first thing AppKit tells the delegate, rather than in
    /// `applicationDidFinishLaunching`, so that the recency rule does
    /// not rest on which of the two launch notifications and the
    /// activation is delivered first. Were the activation ever to
    /// arrive between the two, a launch time taken in the later one
    /// would still be `distantPast`, and the person's launch would be
    /// read as a ⌘Tab hours later.
    private var launchedAt = Date.distantPast
    private var aboutActivation = false
    private var settingsActivation = false

    /// An inactive app must finish activating before its editor can be key.
    private var pendingEditorSummon: ActivationRoute?

    /// The observation of `ModalSession.didEndNotification`, held for
    /// the life of the delegate, which is the life of the process.
    private var modalEndObserver: NSObjectProtocol?

    /// The observation of every window's close, held as long, which is
    /// how the model learns that the keyboard is coming back from a
    /// window that is neither content window
    /// (`BackdropModel.auxiliaryWindowReleasedKeys`).
    private var windowCloseObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAt = Date()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app, deliberately — the panel's accessory posture
        // (menu bar only, docs/spec/03 §2) is amended for this form
        // factor: living in ⌘Tab is what makes flipping between the
        // work window and the surface (copy from one, paste into the
        // other) a reflex instead of a remembered chord. The Dock icon
        // is the fee; whether it makes the surface too central is the
        // feature spec's open question №7.
        NSApp.setActivationPolicy(.regular)

        // File belongs after the app menu, the way every macOS app
        // orders its own. SwiftUI's `CommandMenu("File")` appends
        // instead, because the app has no document scene for the
        // synthesised File menu to attach to (Settings is the only
        // scene, and it is the placeholder). Move it into place, so
        // the menu bar reads: App | File | Edit | View | Window | Help.
        Self.moveFileMenuAfterAppMenu()
        Self.routeUndoRedoThroughResponder(in: NSApp.mainMenu)

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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.trayImage()
        item.button?.setAccessibilityLabel(Self.productName)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // ⌃⌥Space, system-wide. Registration can fail (another app
        // holds the combination); the menu-bar item still summons.
        summonKey = BackdropHotKey.controlOptionSpace { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applySummon(.hotkey)
            }
        }

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
                guard let self, let closing else { return }
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

        // The backdrop exists by being there: it takes its place on
        // screen at launch, resting, opened onto whatever page the last
        // quit sealed (`BackdropModel.start`). Whether anything then
        // comes forward is not decided here, because the launch cannot
        // tell who asked for it. A person who opens the app is owed a
        // window in front, since an app that parks itself behind every
        // other window on first open reads as broken (dogfood phase 4),
        // and under ADR-0033 that window is the editor window, opened
        // as a summon; a login item, or any other launch the system
        // performs, is owed the resting card, behind everything, and
        // no editor window. AppKit already tells the two apart: a
        // person's launch activates the app moments after this returns,
        // and a background launch never does. So the opening waits for
        // that activation (`applicationDidBecomeActive`), and a launch
        // nobody activates stays resting.
        controller.show()
    }


    /// How long after launch an activation is read as the launch's own.
    /// Recency rather than a skip-one counter, since a login item or a
    /// background launch never activates and a counter would read the
    /// first real ⌘Tab hours later as the launch, anchoring the roll on
    /// today under a sentence someone was coming back to.
    nonisolated static let launchWindow: TimeInterval = 2


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
            closeEditorForPanel: { [self] in editorWindow.closeForAmbientPanel() }
        )
    }

    /// Accepted ADR-0033 says: "With the panel off, the hotkey and the
    /// status item select the editor window." Activating the app for
    /// this case is an implementation interpretation of that selection,
    /// so the ordinary editor window can take keyboard focus. Show it from
    /// that activation callback, which must not route this same gesture
    /// a second time as a launch or ⌘Tab (and possibly anchor on today).
    private func applySummon(_ reason: ActivationReason) {
        // A deliberate selection supersedes an outstanding companion request;
        // only automatic activation callbacks defer to that earlier claim.
        if reason == .openEditorPresentation {
            aboutActivation = false
            settingsActivation = false
        }
        let route = ActivationRouter.decide(reason, in: activationContext())
        if ActivationRouter.defersForActivation(route: route, appActive: NSApp.isActive) {
            // Activation is a request and may never deliver its callback.
            // Panel-off summons and explicit Open in Window all select
            // .openEditorWindow(.activation), matching late activation, so a
            // stranded route cannot change the next activation's meaning.
            // This relies on their raise staying .activation;
            // changing it to .summon would require expiring pending intent.
            assert(route == .openEditorWindow(.activation),
                   "Deferred editor selections must match the late activation route")
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

    /// ⌘Tab (or the Dock icon) landing on this app selects the editor
    /// window (ADR-0033): the user came here, so bring it, opening it
    /// when it is closed, unconditionally, never a rest, because
    /// activation only ever means "bring it to me". The activation a
    /// person's launch sends moments after
    /// `applicationDidFinishLaunching` is the opening the launch itself
    /// withheld, and takes the launch route; About's and Settings' are
    /// exempt because those windows asked for the activation for
    /// themselves.
    ///
    /// Otherwise an **activation** and not a summon: the user named the
    /// app, not a surface, and someone who ⌘Tabbed away from a sentence
    /// in an older day is coming back to that sentence. What hangs off
    /// the distinction is the roll's anchor, see `BackdropRaise`.
    func applicationDidBecomeActive(_ notification: Notification) {
        // Ahead of the routing table's answer, and ahead of the launch
        // window: coming back to the app is exactly when a checkout, a
        // formatter or another editor has had its turn at a file, and
        // that is true whether or not this particular activation moves
        // any window (decisions.md item 5).
        pages.checkOpenFilesOnActivate()
        // Both flags are consumed by whichever activation arrives next,
        // launch window or not: each was set only when an activation
        // was certain to follow, so this is that activation, and a flag
        // left standing here would swallow the next real ⌘Tab instead.
        //
        // Under ADR-0033 an editor window on screen is not a claim: it
        // is exactly the surface the activation is routed to. Only
        // About and Settings hold their own claim, and the routing
        // function sees them through `claimedByAnotherWindow`.
        let claimed = aboutActivation || settingsActivation
        aboutActivation = false
        settingsActivation = false
        // Consume pending intent even when About/Settings claim this
        // activation, so it cannot leak into the next real ⌘Tab. Otherwise
        // it takes precedence over recency and keeps the gesture's raise.
        let pending = pendingEditorSummon
        pendingEditorSummon = nil
        apply(ActivationRouter.routeForActivation(
            pendingSummon: pending,
            sinceLaunch: Date().timeIntervalSince(launchedAt),
            launchWindow: Self.launchWindow,
            context: activationContext(claimed: claimed)
        ))
    }

    func applicationWillResignActive(_ notification: Notification) {
        // A completed activation consumes the intent above. If the app
        // instead loses activation, no summon should survive that turn
        // away and take precedence over a later return.
        pendingEditorSummon = nil
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
        guard model.stance == .raised else { return }
        Task { @MainActor [weak self] in
            guard let self,
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

    /// The Dock icon's click, and any other reopen (`open -a` on a
    /// running app). It selects the editor window, opening it when it
    /// is closed and bringing the open one forward, the same
    /// destination `applicationDidBecomeActive` gives a later
    /// activation (ADR-0033), so one gesture cannot mean two things
    /// depending on which of the two callbacks it arrived at.
    ///
    /// A Dock click on an inactive app sends an activation as well as
    /// this, in no promised order. Either order ends in the same place:
    /// whichever arrives first opens the window and rests a raised
    /// panel, and the second finds the window open and brings it
    /// forward (`PrimaryEditorWindowController.show()`).
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        // The same activation, so the same file check. This is the
        // route a Dock click takes while the app is already frontmost,
        // which `applicationDidBecomeActive` never sees, and a person
        // coming back through it is owed the same answer about what
        // else wrote their files.
        pages.checkOpenFilesOnActivate()
        // Through the routing table like every other activation: the
        // reopen row selects the editor window whatever the ambient
        // panel preference says, and opens it when it is closed. Only
        // a claim by About or Settings turns it into a no-op, and this
        // callback passes none.
        apply(ActivationRouter.decide(.reopen, in: activationContext()))
        return false
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
                withTitle: "Quit",
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

    /// Observed Window-menu switches, updated when the ambient preference changes.
    var presentationCommands: some View {
        PresentationSwitchMenuItems(model: model,
                                    openWindow: openEditorPresentation,
                                    showPanel: showAmbientPresentation)
    }

    /// Explicit selection ignores companion activation claims, unlike reopen.
    @objc func openEditorPresentation() {
        applySummon(.openEditorPresentation)
    }

    /// Switch presentations without toggling rest or anchoring on today. This
    /// preserves the page the person is viewing, unlike a hotkey/status summon.
    @objc func showAmbientPresentation() {
        applySummon(.showAmbientPresentation)
    }

    /// Shared context-menu commands with explicit enablement for the ambient feature.
    private func addPresentationItems(to menu: NSMenu) {
        let open = menu.addItem(withTitle: "Open in Window",
                               action: #selector(openEditorPresentation), keyEquivalent: "")
        open.target = self
        let ambient = menu.addItem(withTitle: "Show Ambient Panel",
                                  action: #selector(showAmbientPresentation), keyEquivalent: "")
        ambient.target = self
        ambient.isEnabled = model.ambientPanelEnabled
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

    /// The same chord for the SwiftUI command group, and nil for the
    /// same reason: a main-menu shortcut is the app-wide half of the
    /// claim, so restoring ⌘, here would hand back most of what the
    /// unbinding took away. Both menu items stay, and stay clickable;
    /// what a nil costs is the chord, which is what was asked for.
    ///
    /// The keymap has nothing to say only when the file took the
    /// binding away or moved it into a section that does not advertise
    /// chords. An override that cannot be read leaves the bundled
    /// default standing, and the bundled default binds ⌘, in a section
    /// that does; a bundled default this build lost binds nothing at
    /// all, and quietly keeping one chord out of the twenty would be
    /// the surprise, not the honesty.
    var settingsShortcut: KeyboardShortcut? {
        settingsKeystroke?.keyboardShortcut
    }

    /// The Edit menu's two undo chords, read from the keymap for the
    /// same reason ⌘, is: the file is the authoritative list of what
    /// the keyboard does, and a chord spelled in Swift here would
    /// survive a user unbinding it in their own keymap.
    ///
    /// The page's text view claims the same chord first, because a key
    /// equivalent reaches the key window's view chain before the main
    /// menu. The menu carries it to show what the item costs, not to be
    /// the thing that fires.
    var undoShortcut: KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: .editorUndo)?.keyboardShortcut
    }

    var redoShortcut: KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: .editorRedo)?.keyboardShortcut
    }

    /// Any command's advertised chord, on the same terms as the three
    /// above: the keymap decides, and nil means the file took the
    /// binding away and the item keeps its place without a chord.
    ///
    /// General rather than one property per command because the File
    /// menu needs four of them and four near-identical properties would
    /// be four places for the same rule to be written differently.
    func shortcut(for command: CommandID) -> KeyboardShortcut? {
        model.pages.keymap.menuKeystroke(for: command)?.keyboardShortcut
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

    /// The Settings window, from the menu bar's ⌘, or either of the
    /// tray's routes. Its `show()` activates the app so the window can
    /// take the keyboard, and that activation must not read as a summon:
    /// the user asked for Settings, not the surface. Flag it, mirroring
    /// About, and only when the activation will actually happen, since
    /// an already-active app fires no notification to consume the flag.
    @objc func openSettings() {
        settingsActivation = !NSApp.isActive
        settings.show()
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
                .foregroundColor: NSColor.secondaryLabelColor,
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
        // About sits at the surface's keyless altitude for as long as
        // it is open, as Settings does and through the same follower
        // (ADR-0032, #188). Otherwise About opens at .normal beneath a
        // raised, pinned or keep above card, and a level read only at
        // open strands it there the moment the pin is toggled on the
        // card while About is up. The follower lets go when the panel
        // closes and picks it up again on the next open.
        if let panel {
            aboutLevelFollower.follow(panel)
        }
        // The app is usually inactive when About is chosen from the
        // status item; without activation the panel appears behind
        // whatever is frontmost. This activation is About's, not a
        // summon — flag it so the raise is skipped (only when the
        // activation will actually happen; an already-active app fires
        // no notification to consume the flag).
        aboutActivation = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel `orderFrontStandardAboutPanel` has just put up. AppKit
    /// hands back no reference to it, so it is picked out of the app's
    /// windows by what it is: on screen, titled, and carrying no title
    /// text. Settings has a title, and the surface and its key relay are
    /// borderless, so none of those can be mistaken for it. A sheet can:
    /// a confirmation run on the Settings window is visible, titled and
    /// carries no title text, and following it would hand the About
    /// follower a window that closes with the answer. So a sheet is
    /// never the panel, and neither is the Settings window itself,
    /// whatever its title reads at the time. If a future macOS builds
    /// the panel differently the lookup finds nothing and the panel
    /// keeps the behavior it had before this existed.
    private func standardAboutPanel() -> NSWindow? {
        NSApp.windows.first { window in
            Self.looksLikeTheAboutPanel(
                visible: window.isVisible,
                titled: window.styleMask.contains(.titled),
                title: window.title,
                isSheet: window.isSheet,
                isSettings: settings.owns(window)
            )
        }
    }

    /// The lookup's rule, pure so each exclusion is an assertion.
    nonisolated static func looksLikeTheAboutPanel(
        visible: Bool, titled: Bool, title: String, isSheet: Bool, isSettings: Bool
    ) -> Bool {
        visible && titled && title.isEmpty && !isSheet && !isSettings
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

    /// Move the File menu item into standard macOS position: right
    /// after the app menu, ahead of Edit and View.
    ///
    /// SwiftUI has no direct positioning knob for `CommandMenu`, and
    /// this app has no document scene for the framework to synthesise
    /// a File menu around, so the runtime order comes out as App | Edit
    /// | View | File | Window | Help. AppKit's main menu is an ordinary
    /// `NSMenu` by the time the delegate is called, so a reorder here
    /// is safe and idempotent. Absence of the File item (a future
    /// build that dropped the menu) is silent on purpose.
    private static func moveFileMenuAfterAppMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let index = mainMenu.items.firstIndex(where: { $0.title == "File" }),
              index > 1
        else { return }
        let item = mainMenu.items[index]
        mainMenu.removeItem(at: index)
        mainMenu.insertItem(item, at: 1)
    }

    /// Turn SwiftUI's two placeholder buttons into ordinary nil-targeted
    /// AppKit commands. The responder chain then chooses the undo owner: an
    /// `InkTextView` validates against Loro, while a field editor in Settings
    /// keeps its native `UndoManager` behavior.
    static func routeUndoRedoThroughResponder(in mainMenu: NSMenu?) {
        guard let editMenu = mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu
        else { return }
        editMenu.autoenablesItems = true
        for (title, action) in [
            ("Undo", #selector(EditStepResponder.undo(_:))),
            ("Redo", #selector(EditStepResponder.redo(_:))),
        ] {
            guard let item = editMenu.items.first(where: { $0.title == title }) else { continue }
            item.target = nil
            item.action = action
            item.isEnabled = true
        }
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

/// Keep SwiftUI menu enablement current without rebuilding the app delegate.
private struct PresentationSwitchMenuItems: View {
    @ObservedObject var model: BackdropModel
    let openWindow: () -> Void
    let showPanel: () -> Void

    var body: some View {
        Button("Open in Window", action: openWindow)
        Button("Show Ambient Panel", action: showPanel)
            .disabled(!model.ambientPanelEnabled)
    }
}
