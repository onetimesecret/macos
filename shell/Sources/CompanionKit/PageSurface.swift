import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The parts of a surface that are the same wherever pages are shown:
/// what fills the content area, the status lines under it, and the
/// keyboard map. A form factor supplies its own chrome
/// around these (the panel a window with a title bar, the backdrop a
/// card on the desktop), and neither one re-describes what a page is.

// MARK: - The content area

/// What the surface shows: the ledger, the selected page, or the empty
/// state. The three cases and their focus consequences are one
/// behaviour (ADR-0005, ADR-0006), so they live here rather than in
/// each form factor's root view.
public struct PageContentView: View {
    @ObservedObject var model: PageModel

    /// A surface showing a page it will not let you edit — the
    /// backdrop's resting glance. The same editor, the same storage,
    /// the same measure, with editing refused: raising and lowering the
    /// card must not make the text jump, and a second read-only view
    /// over the page's storage would break the one-layout-manager
    /// invariant ADR-0006 rests on.
    let readOnly: Bool

    /// What the empty state offers, named as the gesture that actually
    /// works on this surface: the panel names its summon, and a resting
    /// backdrop names the one that would make it typeable at all.
    let emptyHint: String

    public init(model: PageModel, readOnly: Bool = false, emptyHint: String) {
        self.model = model
        self.readOnly = readOnly
        self.emptyHint = emptyHint
    }

    public var body: some View {
        if model.showingLedger {
            LedgerView(entries: model.ledgerEntries)
        } else if let file = model.activeFile {
            let bannerDefault = FileBannerDefaultAction.derive(
                hasPendingClose: model.pendingFileClose?.fileID == file.id,
                hasConflict: file.conflict != .none
            )
            // A file replaces whatever the surface was showing, in
            // either layout: the roll is a projection of pages and a
            // file is not one, so there is nothing for a file to be a
            // region inside of (ADR-0028).
            //
            // The same editor over the same kind of storage, addressed
            // by the file's own tagged id. No `.id(file.id)` for
            // ADR-0006's reason: one editor persists and its storage is
            // swapped underneath it, and files join that rotation
            // rather than standing up an editor of their own.
            VStack(spacing: 0) {
                if let pending = model.pendingFileClose, pending.fileID == file.id {
                    FileCloseBanner(pending: pending) { model.resolvePendingFileClose($0) }
                    Divider()
                }
                if file.conflict != .none {
                    FileConflictBanner(
                        file: file,
                        saveAsIsDefault: bannerDefault == .saveAs
                    ) { model.resolveConflict($0) }
                    Divider()
                }
                if let suggestion = model.fileRenderSuggestion, suggestion.fileID == file.id {
                    FileRenderSuggestionBanner(model: model, suggestion: suggestion)
                    Divider()
                }
                InkEditorView(model: model, sheetID: file.id, readOnly: readOnly)
            }
        } else if model.showsTimeUnits {
            // The days, as one roll (issue #79). It answers for all
            // three of the cases below at once, the selected page is
            // the region the one editor is standing in, the older days
            // are renderings around it, and an empty Day 0 carries the
            // same empty state with the same two grants, so it takes
            // the whole branch rather than sitting inside one of them.
            // The mode is off by default and exclusive with the strip,
            // so with it off nothing here is reached and the three
            // branches below are the surface, unchanged.
            DayScrollView(model: model, readOnly: readOnly, emptyHint: emptyHint)
        } else if let page = model.selectedPageID {
            // No `.id(page)` on the editor, and the omission is
            // contract, not oversight (ADR-0006): one editor persists
            // across page switches, and `updateNSView` swaps the
            // page's storage underneath it. Re-adding an id would make
            // every switch an identity change again — the swap path
            // goes dead, and caret, scroll, and undo are quietly
            // discarded on every tab change.
            InkEditorView(model: model, sheetID: page, readOnly: readOnly)
        } else {
            // The empty state: static text over a catcher that serves
            // two grants (ADR-0005). A click into the emptiness, the
            // third grant, creates a page and hands its editor the
            // keyboard. While the surface already holds the keys, the
            // catcher holds first responder so Return, the fourth
            // grant, creates a page too, and Esc still hands the
            // keyboard back.
            ZStack {
                EmptyStateKeyGrant(
                    selectedTabHoldsNoPage: { [model] in model.selectedTabHoldsNoPage },
                    onCreate: { window in model.createPageAndFocus(in: window) },
                    onEscape: { model.escape() }
                )
                VStack(spacing: 6) {
                    Text("No page here yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(emptyHint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - The status lines

/// Everything between the page and the tabs: the pasteboard offer, the
/// notice line and the open conceal. Each appears only when it has
/// something to say, so a quiet surface shows none of them and the
/// layout does not reserve their room.
public struct PageStatusStack: View {
    @ObservedObject var model: PageModel
    /// Observed directly: the controller is its own `ObservableObject`,
    /// and a nested object's changes do not republish through the
    /// model.
    @ObservedObject var sync: SyncController

    public init(model: PageModel) {
        self.model = model
        _sync = ObservedObject(wrappedValue: model.sync)
    }

    /// What the discard button says it will do.
    ///
    /// Out of the body because it is a sentence rather than a view,
    /// and because the drafts clause makes it long enough that the
    /// type checker stops enjoying it inline. The discard drops the
    /// sealed content file, and the drafts are sealed under the same
    /// key, so it takes any unsaved file edits with it. Named by
    /// filename rather than warned about in general (decisions.md
    /// item 14).
    private var discardHelp: String {
        let base = "Deletes the sealed file this session could not read and starts "
            + "saving this session's pages in its place. The unreadable file "
            + "cannot be recovered afterwards."
        guard let atRisk = PageModel.draftsAtRiskSentence(files: model.openFiles) else {
            return base
        }
        return base + " " + atRisk
    }

    public var body: some View {
        if model.contentRestoreRefused {
            // The standing restore-failure state (issue #49): persistent
            // for the whole session, unlike a notice, because the
            // condition is. One action, the content-side discard that
            // ADR-0016 section 7 requires; until it is taken, nothing
            // typed here reaches disk and the unreadable file is left
            // untouched.
            HStack(spacing: 8) {
                Text("the existing state file would not open, so nothing in this session is being saved")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.emberText)
                Button("discard it and start saving") { model.clearUnreadableStateFile() }
                    .font(.system(.caption, design: .monospaced))
                    .controlSize(.small)
                    .help(discardHelp)
                    .accessibilityLabel(
                        Text("Discard the unreadable state file and start saving this session"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        if model.ledgerRestoreRefused {
            // Quieter than the content banner because no page is at
            // stake, but standing for the same reason: the trail stops
            // recording on this and every later launch until the user
            // clears the ledger in Settings.
            Text("the audit trail would not open and is not recording; clear the ledger in Settings to start a new trail")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.emberText)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let sentence = sync.standingSentence {
            // Sync's one standing line (issue #102): present only while
            // sync is on AND has something to report. Off is silence,
            // and quiet-and-well is too. Each condition is its own
            // sentence; ember for the ones that name something to act
            // on, and secondary for a browser trip that is simply out,
            // which is a fact rather than a fault.
            Text(sentence)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(sync.standingSentenceIsTrouble ? Color.emberText : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let page = model.selectedPageID, sync.editedElsewhere.contains(page),
            !model.showingLedger
        {
            // Someone else is writing on this page (issue #102). A word
            // and never a dialog: the edits are already merging, so
            // there is nothing to decide and nothing to interrupt for.
            // It sits with the page's own status lines because it is a
            // fact about this page and not about the channel, which is
            // what the header's word is for.
            Text("another device is editing this page")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Another device is editing this page"))
        }
        if PageModel.shouldShowPasteboardOffer(
            boardHolds: model.pasteboardOffer,
            hasPage: model.selectedPageID != nil,
            ledgerShowing: model.showingLedger
        ) {
            // The summon-time offer (ADR-0007 Amendment 1): one
            // gesture from "secret in hand" to "chip with a TTL,
            // off the clipboard". Routed through the editor's own
            // sealed-paste path so the chip lands at the caret.
            HStack(spacing: 8) {
                Text("the clipboard holds content")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("seal it (⇧⌘V)") { model.performSealedPaste?() }
                    .font(.system(.caption, design: .monospaced))
                    .controlSize(.small)
                    .accessibilityLabel(Text("Seal the clipboard's content onto this page"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        if let notice = model.notice {
            // Ember only for what needs acting on (design record,
            // section 5): a refusal that leaves a save undone. A
            // notice that reports what just happened is a quiet line
            // like the ones above it. The one thing a line may offer
            // to do about itself (Undo, after a removal) is a button
            // beside the words, in the pasteboard offer's shape.
            HStack(spacing: 8) {
                Text(notice)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(
                        model.noticeTone == .actionable ? Color.emberText : Color.secondary)
                if let action = model.noticeAction {
                    Button(action.label) { model.performNoticeAction() }
                        .font(.system(.caption, design: .monospaced))
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        if let draft = model.concealDraft, !model.showingLedger {
            // The inline, in-place confirmation (never a modal):
            // the network boundary is the one confirming click.
            ConcealView(model: model, draft: draft)
        }
        // The stack used to end in a four point `GaugeBar` spanning the
        // page's bottom edge, the page draining continuously as the
        // design spec asked. It came out in dogfood phase 4 because a
        // thin horizontal bar along the bottom edge of a text surface
        // is where a horizontal scroll bar lives, and a full width one
        // is a convincing impostor (docs/dogfood/ABERRATIONS.md,
        // 2026-09-05). The per tab gauge on the strip stays: a short
        // bar framed by its tab is not mistaken for one. The page's
        // remaining time is otherwise written in words, in its own day
        // gutter while the days are the navigation.
    }
}

// MARK: - The keyboard map

/// The surface-level keyboard map (docs/spec/04), carried by zero-size
/// hidden buttons: active exactly while the surface holds the keys —
/// never a global claim (the summon hotkeys are the one exception, and
/// they live in the form factors' hotkey types).
///
/// Which chord runs which command is no longer written here. It is
/// read out of the keymap (issue #76,
/// `docs/development/about-the-keymap.md`): the bundled default file
/// says ⌘1 through ⌘9 jump by visible tab order, ⌘W closes, ⌘S forces
/// the debounced write to happen now, ⌘, opens Settings and Esc hands
/// the keyboard back, and a user's own keymap may say otherwise. What
/// is left here is the installation: one hidden button per chord the
/// surface carries, mounted only while the surface is raised.
///
/// ⌘0 used to sit at the end of that run and open the ledger. It is
/// withdrawn from the default file while the ledger's entry points are
/// hidden (issue #78); the command still dispatches, so an override
/// keymap can name it.
///
/// The seal gestures (⇧⌘V, ⌘↩) and the wrap toggle are in the same
/// file and are not installed here. They are dispatched by the page's
/// own text view, which sees a keystroke before any of these buttons
/// do and which owns the caret they act on.
public struct PageKeyboardMap: View {
    @ObservedObject var model: PageModel

    public init(model: PageModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            ForEach(model.keymap.surfaceShortcuts()) { installed in
                Button("") { model.perform(installed.command) }
                    .keyboardShortcut(installed.shortcut)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - The empty state's catcher

/// The focus law's third and fourth grants (ADR-0005). The window
/// honours the law through `becomesKeyOnlyIfNeeded`: a click grants
/// key status only when the clicked view answers
/// `needsPanelToBecomeKey`. The empty state's static text answers no,
/// so a pageless surface could never accept the keyboard at all, and
/// keystrokes fell through to the app underneath. This view answers
/// yes, because a click into the emptiness is itself the deliberate
/// act the law requires, and it reports the click so the model can
/// conjure the page the grant promises. While the surface already
/// holds the keys it also holds first responder, so Return conjures
/// the page as well (the muscle memory of starting a new thought) and
/// Esc hands the keyboard back. Chrome (tabs, header, pin) carries no
/// such view and stays mute.
struct EmptyStateKeyGrant: NSViewRepresentable {
    let selectedTabHoldsNoPage: () -> Bool
    let onCreate: (NSWindow?) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyGrantingClickView {
        let view = KeyGrantingClickView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: KeyGrantingClickView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: KeyGrantingClickView) {
        view.selectedTabHoldsNoPage = selectedTabHoldsNoPage
        view.onCreate = onCreate
        view.onEscape = onEscape
    }
}

/// The minimal view that satisfies the panel's question: it needs the
/// panel to become key (that is its entire purpose) and it takes the
/// very first click even from an unkeyed window, so granting and
/// creating are one gesture, not two. In a window that is already key
/// it claims first responder, on mount and again whenever the window
/// becomes key, so Return has somewhere to land; the window would
/// otherwise answer every keystroke itself, with a beep.
final class KeyGrantingClickView: NSView {
    var onCreate: ((NSWindow?) -> Void)?
    var onEscape: (() -> Void)?

    /// The model's live fact, read through a closure rather than cached
    /// as a bool: a page opened this instant fills the selected slot at
    /// once, but the representable only pushes a cached snapshot on the
    /// next render pass. The `didBecomeKey` observer can fire inside
    /// that gap — after the editor already took focus — and a stale
    /// `true` would let the catcher seize first responder back from the
    /// editor, then unmount and strand it (issue #23). Reading live
    /// closes the gap.
    var selectedTabHoldsNoPage: () -> Bool = { true }

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // main-actor class (Swift 6), and the observation token isn't
    // Sendable. Safe here: removeObserver is documented thread-safe,
    // and every other touch runs on the main actor.
    private nonisolated(unsafe) var keyObserver: NSObjectProtocol?

    override var needsPanelToBecomeKey: Bool { true }

    /// Return needs a responder to land on; the window's own fallback
    /// answer to a keystroke is the beep this view exists to replace.
    override var acceptsFirstResponder: Bool { true }

    /// The granting click must not be swallowed as "just focusing":
    /// the same click that keys the window creates the page.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The window is captured here, before the click's consequences
    /// unmount this view and sever it from the hierarchy.
    override func mouseDown(with event: NSEvent) {
        onCreate?(window)
    }

    /// Return creates the page (the fourth grant) and Esc routes to
    /// the model's escape, the same path the keyboard map serves.
    /// Everything else takes NSView's default road, the beep, so an
    /// unhandled keystroke is audible rather than silently eaten.
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onCreate?(window)
        case kVK_Escape:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Rehome the key observation whenever the view lands in (or
    /// leaves) a window, then claim first responder if the window is
    /// key right now: the empty state can appear inside an already
    /// keyed window, as when the last page dies, and no notification
    /// replays for a state that predates the observer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.claimFirstResponderIfEntitled() }
        }
        claimFirstResponderIfEntitled()
    }

    /// The seat is taken exactly when the pure decision says the
    /// fourth grant is on offer; the window's key status and whether
    /// the selected slot holds a page are both consulted live.
    private func claimFirstResponderIfEntitled() {
        guard let window else { return }
        guard PageModel.shouldOfferEnterCreate(
            selectedTabHoldsNoPage: selectedTabHoldsNoPage(), holdsKeys: window.isKeyWindow
        ) else { return }
        window.makeFirstResponder(self)
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }
}
