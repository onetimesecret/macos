import AppKit
import os
import SwiftUI

/// The page: a little text file of **ink** (visible, editable text) and
/// **sealed chips** (opaque tokens whose bytes live core-side and never
/// render). The core owns the document (ADR-0013): every storage edit
/// crosses the seam as a batch of range operations, and the editor's
/// text storage is the projection the user types into.
///
/// The gesture routes (docs/spec/04): ⌘V pastes plain ink like every
/// text editor on the machine; ⇧⌘V seals from the pasteboard; ⌘↩ seals
/// the selection or the current line; a drop from outside seals from
/// the drag pasteboard. Nothing is sealed without a gesture, and
/// nothing sealed ever renders.
public struct InkEditorView: NSViewRepresentable {
    @ObservedObject var model: PageModel
    let sheetID: UInt64

    /// Refuse edits while still showing the page: the backdrop's
    /// resting glance. One editor over one storage in both stances
    /// (ADR-0006's invariant), so raising and resting change what the
    /// editor accepts, never what it renders or where the text sits.
    let readOnly: Bool

    public init(model: PageModel, sheetID: UInt64, readOnly: Bool = false) {
        self.model = model
        self.sheetID = sheetID
        self.readOnly = readOnly
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Before anything is built, because the building writes to the
        // model and every such write says which window it comes from.
        context.coordinator.surface = context.environment.presentationSurface
        return Self.makePage(
            model: model, sheetID: sheetID, readOnly: readOnly,
            coordinator: context.coordinator
        )
    }

    /// The page surface, assembled: the one editor inside its scroller,
    /// opened where the page was last left.
    ///
    /// A static rather than the body of `makeNSView`, for the reason
    /// `DayScrollView.makeRoll` is one: a test cannot make a SwiftUI
    /// `Context`, and what this mount owes the page is worth asserting.
    /// The app and the tests build the same object out of the same call.
    ///
    /// In a window that does not own the page content the scroller
    /// comes back empty (ADR-0033). SwiftUI has to be handed a view
    /// either way, and an empty one is the mount that sheds nothing,
    /// announces nothing and shows no ink.
    @MainActor
    static func makePage(
        model: PageModel, sheetID: UInt64, readOnly: Bool, coordinator: Coordinator
    ) -> NSScrollView {
        let scroll = bareScroller()
        mountPage(
            in: scroll, model: model, sheetID: sheetID, readOnly: readOnly,
            coordinator: coordinator
        )
        return scroll
    }

    /// Build the editor into a scroller that has none, when this window
    /// owns the page content, and say whether it did.
    ///
    /// The question comes before the building and not after it, because
    /// the building sheds every layout manager it finds on the page's
    /// storage, and in a window that does not own the one it would find
    /// is the owner's. Asked quietly here: a root view that mounted a
    /// page in the wrong window is declined without a trap, and the
    /// builder's own guard is the loud one for a caller that never
    /// asked.
    @MainActor
    @discardableResult
    static func mountPage(
        in scroll: NSScrollView,
        model: PageModel, sheetID: UInt64, readOnly: Bool, coordinator: Coordinator
    ) -> Bool {
        guard model.owner == coordinator.surface,
              let textView = makeInkTextView(
                  model: model, sheetID: sheetID, coordinator: coordinator
              )
        else { return false }
        // Whether the page accepts typing is the stance's business and
        // not the editor's, which is why it is set here rather than in
        // the building: `updateNSView` re-gates it on every pass, since
        // resting and raising change what the editor accepts without
        // changing the editor.
        textView.isEditable = !readOnly

        seat(textView, in: scroll)
        coordinator.observeClip(of: scroll)
        coordinator.applyWrap(model.wrapsLines)
        // The scroll half of the place, which is this mount's to put
        // back because the clip is this mount's. The building has
        // already seated the caret. An editor that was torn down, or
        // another window's editor, may have read this page further
        // than the top, and whoever mounts it next opens it there.
        coordinator.restoreScroll(textView: textView, scrollView: scroll, for: sheetID)
        return true
    }

    /// The editor is going away: a ledger round trip, or the empty
    /// state that the selected tab holding no page puts on screen
    /// (ADR-0017 made that a frequent event rather than a rare one).
    ///
    /// Since ADR-0033 the app has two window roles over one document
    /// model, and only the window that owns the page content mounts an
    /// editor. The window that loses ownership unmounts its editor and
    /// is hidden or closed during a presentation switch (ADR-0036). That
    /// unmount arrives here too, but the hand off has already done the work:
    /// `PageModel.transferOwnership(to:)` takes the outgoing editor off
    /// its page and clears `activeEditor` itself
    /// (`relinquishPresentation`) before the owner changes. By the time
    /// SwiftUI dismantles that editor the handle is no longer its own,
    /// so the `retireEditor` call below, which is guarded by identity
    /// and not by ownership, leaves the handle alone, and `leavePage`
    /// finds no page left to leave.
    ///
    /// The model keeps a weak handle on the mounted editor so a summon
    /// or a grant can hand it the keyboard, and weak is not the same as
    /// mounted: a view torn out of the window answers that handle until
    /// ARC lets go, and a hand-off arriving in the meantime would settle
    /// on a view with no window rather than wait for the editor coming
    /// to replace it. `PageModel.mountedEditor` refuses such a view on
    /// the way in; retiring the handle here means it is never offered
    /// one (issue #23).
    ///
    /// Only when the handle is still this view's. SwiftUI may build a
    /// replacement before dismantling what it replaces, and clearing
    /// unconditionally would then drop the live editor a moment after it
    /// arrived.
    ///
    /// The editor comes off its page on the way out, as it does at a
    /// hand off between windows (`Coordinator.leavePage`): the page's
    /// place is left with the model, so the editor that mounts this
    /// page next, here or in another window, opens it where this one
    /// was reading, and the layout manager leaves the storage with it.
    /// The storage outlives every editor and owns whatever is attached
    /// to it, so an editor left on would go on laying the page out,
    /// unseen, until something happened to mount that same page again,
    /// and a page selected in between would never be that something.
    /// An editor already replaced over the same page has had its
    /// layout manager shed, and neither says nor does anything.
    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidateOrdinaryPasteMeasurement()
        guard let textView = scroll.documentView as? InkTextView else { return }
        coordinator.leavePage(textView, scrollView: scroll)
        coordinator.model.retireEditor(textView)
    }

    /// The one editor, built: a TextKit 1 stack over the page's storage,
    /// wired to the coordinator that speaks for it.
    ///
    /// Explicit TextKit 1, because chips render through
    /// `NSTextAttachmentCell` and swapping pages swaps the storage under
    /// one layout manager (`replaceTextStorage`).
    ///
    /// Built apart from `scrollStack(for:)` because a scroller of its own
    /// is only one of the places this editor can stand. A surface that
    /// rolls several days past a single clip needs the same editor,
    /// the same first responder, the same coordinator, the same
    /// `activeEditor` handle, the same `performSealedPaste`, mounted
    /// inside a stack rather than inside a scroll view (ADR-0020), and a
    /// second copy of this wiring is exactly how the two surfaces would
    /// quietly stop agreeing about what the one editor is. Everything a
    /// mount decides for itself stays with the mount: the caller grants
    /// editing, wraps the view in whatever it is going to live in, and
    /// sheds the undo history a teardown left behind.
    ///
    /// Main-actor by hand rather than by inference: everything it wires
    /// belongs to the main thread (the model, the styling, the view), and
    /// a builder called from somewhere other than a representable's
    /// own lifecycle should say so at its declaration.
    ///
    /// Nil in a window that does not own the page content (ADR-0033),
    /// and the refusal is the first thing that happens. A few lines
    /// down the building sheds every layout manager on the page's
    /// storage, and for a window that does not own, the one standing
    /// there is the owner's: an editor built here would take the page
    /// out from under the editor the person is typing into. The mount
    /// sites ask who owns before they call, so a refusal here is a
    /// caller that forgot, and it is as loud as any other declined
    /// write (`PageModel.admits`).
    @MainActor
    static func makeInkTextView(
        model: PageModel, sheetID: UInt64, coordinator: Coordinator
    ) -> InkTextView? {
        guard model.admits(.activeEditor, from: coordinator.surface) else { return nil }
        let storage = model.storage(for: sheetID)
        // The page's storage outlives any one editor instance, the
        // ledger and the empty state unmount the editor, even though
        // page↔page switches no longer do (ADR-0006). A dismantle and
        // a hand off both take their editor off the page
        // (`Coordinator.leavePage`), so this usually finds nothing. It
        // stays for the one order that leaves something: SwiftUI
        // building this editor before it dismantles the one it
        // replaces. Exactly one manager drives this storage.
        Coordinator.shedLayoutManagers(from: storage, keeping: nil)
        let textView = makeSurface(over: storage, coordinator: coordinator)
        textView.textContainerInset = NSSize(
            width: 12, height: Coordinator.topInset
        )
        coordinator.currentSheet = sheetID
        coordinator.appliedTypeface = InkStyle.typeface
        coordinator.appliedSyntaxHighlighting = model.syntaxHighlightingEnabled
        coordinator.appliedPreviewRendering = model.previewRendering(for: sheetID)
        coordinator.appliedLanguageDetection = model.languageDetectionEnabled
        coordinator.appliedFileRenderMode = model.fileRenderMode(for: sheetID)
        coordinator.restyle()
        // The caret is the page's wherever the page is mounted, so the
        // building seats it and every mount gets it: the page in its
        // own scroller and the roll alike. Only when one was kept. A
        // page nobody has left yet keeps the fresh view's caret, and
        // the building stays silent about a selection it did not move.
        if model.viewStates.carets[sheetID] != nil {
            coordinator.restoreCaret(textView: textView, for: sheetID)
        }
        // The editor and the sealed paste route, which the summon-time
        // offer's button takes so the chip lands at the caret and
        // consent stays a gesture aimed at this page.
        coordinator.announce(textView)
        // One line per editor built. Two windows share this model
        // (ADR-0033), and how many editors stand over it is a claim to
        // check in the log stream rather than by eye: a transfer of
        // ownership must produce exactly one of these, from the window
        // that now owns. A later one with no transfer before it is the
        // owner's own rebuild after the ledger or an empty slot.
        // Mechanics only, never the page.
        Logger(subsystem: model.formFactor.loggerSubsystem, category: "editor")
            .info("editor=built")
        coordinator.refreshLanguageActionAvailability()
        return textView
    }

    /// The writing surface over `storage`, wired to `coordinator`; the page's
    /// editor and a sealed object's note are both built here (ADR-0044 point 1).
    @MainActor
    static func makeSurface(over storage: NSTextStorage, coordinator: Coordinator) -> InkTextView {
        let layoutManager = InkLayoutManager()
        let container = InkTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        // Only the mounted page's storage carries the coordinator as
        // its delegate, so ops are emitted for the page on screen and
        // never for a background storage a programmatic write touches.
        storage.delegate = coordinator

        let textView = InkTextView(frame: .zero, textContainer: container)
        // Rich text stays on so chip attachments survive editing; the
        // user-facing surface is still plain, ⌘V pastes plain text and
        // no ruler/font UI exists. Styling is ours alone (restyle()).
        textView.isRichText = true
        // Off, because undo is the core's now (issue #132). A page's
        // history has to live in exactly one place: the core's stack
        // knows which operations this device authored and AppKit's does
        // not, so a second stack could only ever disagree with it, and
        // on a shared page it would happily revert text that arrived
        // from another device. Leaving it on would also mean AppKit
        // quietly retaining every deleted fragment of the page for the
        // life of the process, with nothing left to drain it.
        //
        // There is no non-text undo in this app to lose: nothing but
        // text editing ever registered an operation on that manager.
        // The list automation's grouping calls survive as no-ops and
        // are documented where they stand.
        textView.allowsUndo = false
        // Writing Tools and typing suggestions read past every gate (Law 0001); a file's
        // mount gives them back.
        TextOffers.offerUngatedReaders(false, on: textView)
        Self.enableFinding(on: textView)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Link reading is the restyle pass's alone (ADR-0023): the
        // system detector writes `.link` attributes as the user types,
        // which is a rewrite of the page's styling outside restyle()
        // and a second opinion about what counts as a URL.
        textView.isAutomaticLinkDetectionEnabled = false
        // And the styling is ours too. The default link attributes
        // repaint every `.link` range blue-and-underlined over the
        // restyle pass's work, and carry the pointing-hand cursor that
        // promises open-on-click — the wrong promise on a page where a
        // plain click edits (⌘-click is the opening gesture).
        textView.linkTextAttributes = [:]
        textView.drawsBackground = false
        textView.typingAttributes = [
            .font: InkStyle.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.delegate = coordinator
        textView.coordinator = coordinator
        coordinator.textView = textView
        return textView
    }

    /// The page inside its scroller: a text view free to grow as tall as
    /// its text, clipped by a card-sized window onto it.
    ///
    /// The freedom has to be granted explicitly. `NSScrollView` stamps a
    /// zero-framed document view's `maxSize` with the clip's size the
    /// first time it lays it out, and a vertically resizable text view
    /// refuses to grow past `maxSize.height`. Left at that stamp the
    /// page's frame stops at exactly one cardful: the storage keeps
    /// taking text and the layout manager keeps laying it out, but a
    /// document no taller than its clip has nothing to scroll, so
    /// everything past the first screenful is written and unreachable.
    /// The card is resizable too, and the stamp is not reapplied when it
    /// grows, so the ceiling would be whatever height the card happened
    /// to have the moment the editor mounted.
    static func scrollStack(for textView: InkTextView) -> NSScrollView {
        let scroll = bareScroller()
        seat(textView, in: scroll)
        return scroll
    }

    /// The scroller with nothing in it yet: what a mount starts from,
    /// and all that a window which does not own the page content ever
    /// gets (`makePage`).
    static func bareScroller() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = EditorViewportClipView()
        scroll.hasVerticalScroller = true
        // NSScrollView forwards this to its clip, so apply it after replacing
        // the clip view to keep the page's background transparent.
        scroll.drawsBackground = false
        return scroll
    }

    /// The editor put into its scroller, with the freedom to grow that
    /// `scrollStack(for:)` describes.
    static func seat(_ textView: InkTextView, in scroll: NSScrollView) {
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        // Width is the container's business (`widthTracksTextView`), so
        // the page wraps rather than scrolling sideways.
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.documentView = textView
    }

    /// End an in-progress IME composition on the page that is leaving,
    /// before the page underneath the editor changes.
    ///
    /// Marked text is anchored to offsets in the outgoing page's
    /// storage, and the input method holds a conversion session pointing
    /// at them. The identity change this editor used to take on every
    /// switch discarded both by tearing the view down; the persistent
    /// view has to do it by hand, or the pending composition commits
    /// into the incoming page or leaves the input context aimed at a
    /// range that has since been replaced (ADR-0006's third eject
    /// trigger, issue #23).
    ///
    /// Both halves are needed and in this order: the input context is
    /// told to abandon its session, and the view is then unmarked, which
    /// is what settles the composition through the coordinator's own gate
    /// while `currentSheet` and the storage still name the page it was
    /// typed on. What was provisionally composed stays on that page, in
    /// the storage and in the core alike, and nothing crosses the
    /// boundary. A view with nothing marked is left alone.
    static func discardComposition(in textView: InkTextView) {
        guard textView.hasMarkedText() else { return }
        textView.inputContext?.discardMarkedText()
        textView.unmarkText()
    }

    /// ⌘F and its neighbours, switched on.
    ///
    /// The bar, not the floating panel: it docks under the card's top
    /// edge rather than opening a second window over a surface whose
    /// whole posture is staying out of the way. `usesFindPanel` is the
    /// master switch even so — it is what the Find menu items validate
    /// against — and `usesFindBar` only chooses which face the switch
    /// puts on screen, so both are set and neither is redundant.
    ///
    /// Replacing cannot reach sealed bytes: the finder only ever
    /// replaces ranges it matched, and no search string typed into the
    /// bar can hold the attachment character a chip occupies. ⌘E is the
    /// one route that could, and it refuses
    /// (`InkTextView.refusesFinderAction`).
    static func enableFinding(on textView: NSTextView) {
        textView.usesFindPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
    }

    /// Wrap, or let the lines run (⌥Z, and the setting behind it).
    ///
    /// Wrapped, the container takes its width from the text view and the
    /// text view takes its width from the clip, so the page only ever
    /// scrolls down. Unwrapped, the container is unbounded and the text
    /// view sizes itself to its longest line instead, which is what
    /// gives the scroll view something to scroll sideways — and which is
    /// why `isHorizontallyResizable` has to be granted and the
    /// autoresizing width taken away, or the two would fight over the
    /// frame and the long line would be cut off at the card's edge until
    /// the next keystroke re-fitted it.
    ///
    /// `minSize` is the floor under that self-sizing: without it a page
    /// of short lines shrinks its text view to the width of its longest
    /// one, and every click to the right of the text lands on the scroll
    /// view, where it places no caret. The floor is the clip, so it
    /// moves with the card (`clipFrameChanged`). Its height also stays
    /// at least the viewport height so blank space belongs to the editor.
    ///
    /// Returning to wrapped has one loose end the flags do not tie: a
    /// text view that ran wide keeps that frame, and nothing else takes
    /// it back, so the width is handed to the clip explicitly.
    static func setWrap(_ wraps: Bool, textView: InkTextView, scroll: NSScrollView) {
        guard let container = textView.textContainer else { return }
        let clip = scroll.contentSize
        if wraps {
            container.widthTracksTextView = true
            container.size = NSSize(width: clip.width, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.setFrameSize(NSSize(width: clip.width, height: textView.frame.height))
            scroll.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scroll.hasHorizontalScroller = true
        }
        textView.minSize = NSSize(width: clip.width, height: clip.height)
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.updatePage(
            scroll, model: model, sheetID: sheetID, readOnly: readOnly,
            coordinator: context.coordinator
        )
    }

    /// The pass SwiftUI asks for on every published change. A static
    /// for `makePage`'s reason: what a pass does and declines to do
    /// around a change of owner is worth asserting, and a test cannot
    /// make a `Context`.
    @MainActor
    static func updatePage(
        _ scroll: NSScrollView,
        model: PageModel, sheetID: UInt64, readOnly: Bool, coordinator: Coordinator
    ) {
        // A pass over a mount whose window no longer owns does nothing
        // (ADR-0033). Ownership moves before SwiftUI takes the old
        // mount down, and a pass arriving in between must not announce
        // this editor over the owner's, nor reach the swap below, which
        // sheds the layout managers of whatever page it swaps in.
        guard model.owner == coordinator.surface else { return }
        guard let textView = scroll.documentView as? InkTextView else {
            // The mount was made while the other window owned, and came
            // back empty. This window owns now, so the editor is built
            // on the pass that finds that out.
            mountPage(
                in: scroll, model: model, sheetID: sheetID, readOnly: readOnly,
                coordinator: coordinator
            )
            return
        }
        coordinator.announce(textView)
        // The stance can change without the page changing, so editing
        // is re-gated on every pass rather than at mount alone.
        coordinator.updateEditability(of: textView, to: !readOnly)
        // Same for wrapping, which ⌥Z and Settings can flip while the
        // page stays put. The coordinator skips the pass when the state
        // has not moved, so the common update rebuilds no geometry.
        coordinator.observeClip(of: scroll)
        coordinator.applyWrap(model.wrapsLines)
        // And for the typeface, which Settings can change while the
        // page stays put; the same gate, so the common pass restyles
        // nothing.
        coordinator.applyTypeface(model.typeface)
        coordinator.applySyntaxHighlighting(model.syntaxHighlightingEnabled)
        coordinator.applyPreviewRendering(model.previewRendering(for: sheetID))
        coordinator.applyLanguageDetection(model.languageDetectionEnabled)
        coordinator.applyFileRenderMode(model.fileRenderMode(for: sheetID))
        // The stance may have flipped editing on or off above, so the
        // Edit menu's two items are re-asked on every pass, before the
        // early return that a page which did not change takes.
        model.scheduleEditStepsRefresh()
        guard coordinator.currentSheet != sheetID else { return }
        // The page under the editor changed, so hand the editor over.
        // The scroller goes with it: on this surface the editor is the
        // only page in its clip, so the offset the user left this page
        // at is the offset to put back when they return.
        //
        // An editor that a transfer of ownership took off its page
        // stands on none (`Coordinator.leavePage`), so a mount that
        // outlived one, because ownership came back before SwiftUI had
        // taken it down, arrives here too and is put back on the page
        // at the place the transfer kept.
        coordinator.moveEditor(
            textView, to: sheetID,
            storage: model.storage(for: sheetID), restoringScrollIn: scroll
        )
    }

    // MARK: - Coordinator

    // @preconcurrency: NSTextStorageDelegate is not main-actor
    // annotated in the SDK, but AppKit only ever calls it on the main
    // thread for a storage driven by a main-thread text view; the
    // conformance asserts that at runtime instead of forbidding it at
    // compile time.
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate,
        @preconcurrency NSTextStorageDelegate {
        let model: PageModel
        weak var textView: InkTextView?
        /// The page or file under the editor, or nil on a note's surface,
        /// whose page only paths key on it (ADR-0044).
        var currentSheet: UInt64? {
            didSet {
                if let currentSheet, let textView {
                    TextOffers.offerUngatedReaders(currentSheet.isFileID, on: textView)
                }
                // A teardown parks on no page and keeps the Undo; a mount of another page retires it.
                if let currentSheet, currentSheet != oldValue {
                    model.surfaceMounted(page: currentSheet)
                }
            }
        }
        /// The note this surface writes, by its object's chip, while one is open.
        private(set) var noteChip: UInt64?
        /// The popover that holds this surface when it is a note's, not the page's.
        weak var noteHost: SealedNoteEditor?
        /// A note's display only fence labels, which last as long as it stays open.
        private var noteFenceLanguages: [Int: String] = [:]

        /// What the surface's ink edits: the open note, or the mounted page or file.
        var document: InkDocument? {
            if let noteChip { return .note(chip: noteChip) }
            return currentSheet.map(InkDocument.sheet)
        }

        /// Whether this is a note's surface rather than the page's.
        var writesNote: Bool { noteHost != nil }

        /// Whether the surface writes a file, whose text keeps AppKit's own offers.
        var writesFile: Bool { !writesNote && currentSheet?.isFileID == true }

        /// Which content window this coordinator's mount stands in
        /// (ADR-0033), named on every presentation write it makes so
        /// the model can tell the owner's from the other window's. Read
        /// from the environment as the mount is made. The panel until
        /// then, which is also what a test that builds a page by hand
        /// gets, over a model the panel owns by default.
        var surface: PresentationOwner = .panel

        /// The mount's two handles on the model, announced together:
        /// the editor a summon hands the keyboard to, and the road the
        /// offer's button takes to the same caret as ⇧⌘V (ADR-0007
        /// Amendment 1). Together because a transfer of ownership drops
        /// both, and an editor that outlived one, because ownership
        /// came back before SwiftUI had taken it down, has to put both
        /// back on its next pass.
        func announce(_ textView: InkTextView) {
            model.mountEditor(textView, from: surface)
            model.routeSealedPaste({ [weak self] in self?.sealedPaste() }, from: surface)
        }

        struct OrdinaryPasteMeasurement: Sendable {
            let result: LanguageDetectionResult
            let elapsed: Duration
        }

        #if DEBUG
        private static let defaultOrdinaryPasteShadowEnabled =
            ProcessInfo.processInfo.environment["ONETIMEPAD_MEASURE_PASTE_LANGUAGE"] == "1"
        #else
        private static let defaultOrdinaryPasteShadowEnabled = false
        #endif

        private let ordinaryPasteShadowEnabled: Bool
        private let languageDetectionService: LanguageDetectionService
        private let ordinaryPastePayload: () -> Data?
        private var pendingOrdinaryPasteRequestID: UUID?
        private var pendingAutomaticPaste: AutomaticPaste?
        private var deferredPlainAutomaticPaste: AutomaticPaste?
        private var pendingManualRequestID: UUID?
        private var languageSuggestion: LanguageSuggestion?
        private var structuralStyleNeedsRebuild = false

        private struct AutomaticPaste {
            let requestID: UUID
            let documentID: UInt64
            let revision: UInt64
            let payload: String
            let destination: PasteDestinationContext
        }

        private struct ManualLanguageTarget: Equatable {
            enum Kind: Equatable {
                case selection
                case bareFence(opening: NSRange, body: NSRange, labelInsertionLocation: Int)
            }

            let documentID: UInt64
            let revision: UInt64
            let detectionRange: NSRange
            let selectionSnapshot: NSRange
            let kind: Kind
        }

        private struct LanguageSuggestion {
            let target: ManualLanguageTarget
            let language: String
        }

        public static let manualLanguages = [
            "swift", "rust", "python", "ruby", "javascript", "typescript",
            "go", "shell", "sql", "json", "yaml", "toml",
        ]

        /// In-memory development/test observation only. The source payload is
        /// deliberately absent from the reported value.
        var onOrdinaryPasteMeasurement: ((OrdinaryPasteMeasurement) -> Void)?

        /// A scroll restore that landed before its clip had any size,
        /// waiting for the frame that gives it one. The caret and the
        /// scroll themselves are the model's (`PageModel.viewStates`);
        /// this is only the one restore in flight, with the anchor it
        /// was handed. A nil anchor is a page with no place kept, which
        /// opens at the top.
        private var deferredScrollRestore: (sheet: UInt64, anchor: ScrollAnchor?)?

        init(
            model: PageModel,
            ordinaryPasteShadowEnabled: Bool? = nil,
            languageDetectionService: LanguageDetectionService? = nil,
            ordinaryPastePayload: @escaping () -> Data? = {
                NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
            }
        ) {
            self.model = model
            self.ordinaryPasteShadowEnabled =
                ordinaryPasteShadowEnabled ?? Self.defaultOrdinaryPasteShadowEnabled
            self.languageDetectionService = languageDetectionService ?? LanguageDetectionService()
            self.ordinaryPastePayload = ordinaryPastePayload
            super.init()
            let notifications = NotificationCenter.default
            notifications.addObserver(
                self, selector: #selector(blockMetadataFormatDidChange(_:)),
                name: NSLocale.currentLocaleDidChangeNotification, object: nil
            )
            notifications.addObserver(
                self, selector: #selector(blockMetadataFormatDidChange(_:)),
                name: .NSSystemTimeZoneDidChange, object: nil
            )
            notifications.addObserver(
                self, selector: #selector(windowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: nil
            )
        }

        /// Both notifications mean already-rendered labels could have stale
        /// calendar context or date text. The selector registration is zeroing,
        /// like the clip observer, so it needs no teardown registration.
        @objc private func blockMetadataFormatDidChange(_ notification: Notification) {
            restyle()
        }

        @objc private func windowBecameKey(_ notification: Notification) {
            keysMoved()
        }

        /// The keys moved to or from a surface or a window: the Edit menu's
        /// answers follow them on the next turn, once AppKit has settled.
        func keysMoved() {
            textView?.handlesMayHaveMoved()
            DispatchQueue.main.async { [weak self] in
                self?.refreshLanguageActionAvailability()
            }
        }

        /// Captures the ordinary plain-text payload once, before AppKit performs
        /// its own pasteboard read. Shadow measurements are discarded on later
        /// editor changes; they assume the board itself did not change between
        /// these two synchronous reads. Nil keeps the shipping path untouched
        /// while the shadow gate is off.
        func ordinaryPasteMeasurementPayload() -> Data? {
            guard ordinaryPasteShadowEnabled else { return nil }
            return ordinaryPastePayload()
        }

        var measuresOrdinaryPastes: Bool { ordinaryPasteShadowEnabled }

        func ordinaryPastePayloadIfNeeded(bypassingAutomaticFencing: Bool) -> Data? {
            guard !bypassingAutomaticFencing else { return nil }
            guard ordinaryPasteShadowEnabled
                    || (PageModel.languageDetectionFeaturesAvailable
                        && model.languageDetectionEnabled
                        && model.automaticallyFencePastes)
            else { return nil }
            return ordinaryPastePayload()
        }

        /// Starts non-shipping source-language measurement after the unchanged
        /// plain paste has completed. The request therefore carries the revision
        /// and selection produced by that paste; only later edits invalidate it.
        func observeOrdinaryPaste(payload data: Data) {
            invalidateOrdinaryPasteMeasurement()
            let started = ContinuousClock.now
            guard let documentID = detectionKey, let textView else { return }
            let selection = textView.selectedRange()
            let request = LanguageDetectionRequest(
                documentID: documentID,
                revision: UInt64(generation),
                targetRange: selection,
                trigger: .ordinaryPaste,
                selectionSnapshot: selection,
                data: data
            )
            pendingOrdinaryPasteRequestID = request.requestID
            languageDetectionService.submit(
                request,
                validating: { [weak self] context in
                    guard Thread.isMainThread else { return false }
                    return MainActor.assumeIsolated {
                        self?.isCurrentOrdinaryPaste(context) ?? false
                    }
                },
                completion: { [weak self] result in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        guard let self, self.isCurrentOrdinaryPaste(result.context) else { return }
                        self.pendingOrdinaryPasteRequestID = nil
                        self.onOrdinaryPasteMeasurement?(.init(
                            result: result,
                            elapsed: started.duration(to: .now)
                        ))
                    }
                }
            )
        }

        func invalidateOrdinaryPasteMeasurement() {
            let canceledAutomaticPaste = pendingAutomaticPaste != nil
                || deferredPlainAutomaticPaste != nil
            pendingOrdinaryPasteRequestID = nil
            pendingAutomaticPaste = nil
            deferredPlainAutomaticPaste = nil
            pendingManualRequestID = nil
            languageSuggestion = nil
            languageDetectionService.invalidate()
            if canceledAutomaticPaste {
                model.flash("paste canceled: the editor changed before detection finished")
            }
        }

        /// A text or selection change retires automatic conversion, but does not
        /// discard the captured paste. The storage delegate can call this while
        /// TextKit is processing an edit, so the ordinary replacement waits for
        /// the next main-queue turn and validates the live editor again there.
        private func abandonAutomaticConversionForEditorChange() {
            pendingOrdinaryPasteRequestID = nil
            pendingManualRequestID = nil
            languageSuggestion = nil
            languageDetectionService.invalidate()
            guard let pending = pendingAutomaticPaste else { return }
            pendingAutomaticPaste = nil
            deferredPlainAutomaticPaste = pending
            DispatchQueue.main.async { [weak self] in
                self?.finishDeferredPlainAutomaticPaste(requestID: pending.requestID)
            }
        }

        private func finishDeferredPlainAutomaticPaste(requestID: UUID) {
            guard deferredPlainAutomaticPaste?.requestID == requestID else { return }
            settleAutomaticPasteAsPlainIfPossible()
        }

        /// Settles either an actively classified paste or one already deferred by
        /// an editor change. This also runs before a second automatic paste so the
        /// first captured payload cannot be silently replaced in the detector's
        /// bounded queue.
        private func settleAutomaticPasteAsPlainIfPossible() {
            guard let pending = deferredPlainAutomaticPaste ?? pendingAutomaticPaste else { return }
            pendingAutomaticPaste = nil
            deferredPlainAutomaticPaste = nil
            languageDetectionService.invalidate()
            guard detectionKey == pending.documentID,
                  let textView, isLiveSurface(textView),
                  textView.isEditable, !textView.hasMarkedText(),
                  let storage = textView.textStorage
            else {
                model.flash("paste canceled: the editor changed before detection finished")
                return
            }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, NSMaxRange(selection) <= storage.length else {
                model.flash("paste canceled: the editor changed before detection finished")
                return
            }
            let caret = NSRange(
                location: selection.location + pending.payload.utf16.count,
                length: 0
            )
            applyReplacement(
                pending.payload, range: selection, caret: caret, intent: .paste
            )
        }

        func updateEditability(of textView: InkTextView, to editable: Bool) {
            if textView.isEditable != editable {
                invalidateOrdinaryPasteMeasurement()
            }
            if !editable {
                keepNaming()
                closeNote()
            }
            textView.isEditable = editable
            refreshLanguageActionAvailability()
        }

        func parkEditor() {
            invalidateOrdinaryPasteMeasurement()
            currentSheet = nil
            refreshLanguageActionAvailability()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            abandonAutomaticConversionForEditorChange()
            if !selectionChangeIsIncidental, let document, let textView {
                model.finishEditingGroup(document, selection: textView.selectedRange())
            }
            textView?.handlesMayHaveMoved()
            refreshLanguageActionAvailability()
            if refreshBlockMetadataFocus() {
                updateBlockLabelViews()
            }
        }

        private func isCurrentOrdinaryPaste(_ context: LanguageDetectionContext) -> Bool {
            guard pendingOrdinaryPasteRequestID == context.requestID,
                  detectionKey == context.documentID,
                  UInt64(generation) == context.revision,
                  let textView,
                  textView.isEditable,
                  !textView.hasMarkedText()
            else { return false }
            let selection = textView.selectedRange()
            return selection == context.selectionSnapshot && selection == context.targetRange
        }

        /// Captures and holds one paste while source detection runs. A result is
        /// applied only while the exact document, revision, selection, and editing
        /// state still stand. An editor change instead settles the captured bytes
        /// as one ordinary replacement at the current, revalidated selection.
        func beginAutomaticPaste(payload data: Data) -> Bool {
            guard PageModel.languageDetectionFeaturesAvailable,
                  model.languageDetectionEnabled,
                  model.automaticallyFencePastes,
                  let payload = String(data: data, encoding: .utf8)
            else { return false }

            // The service intentionally has a one-element pending queue. Settle
            // the older captured paste before submitting another so replacement
            // in that queue cannot silently lose the first user gesture.
            settleAutomaticPasteAsPlainIfPossible()
            guard let destination = automaticPasteDestination(payload: payload) else { return false }
            pendingOrdinaryPasteRequestID = nil
            pendingManualRequestID = nil
            languageSuggestion = nil
            languageDetectionService.invalidate()
            guard let documentID = detectionKey else { return false }
            let selection = destination.replacementRange
            let request = LanguageDetectionRequest(
                documentID: documentID,
                revision: UInt64(generation),
                targetRange: selection,
                trigger: .ordinaryPaste,
                selectionSnapshot: selection,
                data: data
            )
            pendingAutomaticPaste = AutomaticPaste(
                requestID: request.requestID,
                documentID: documentID,
                revision: request.revision,
                payload: payload,
                destination: destination
            )
            languageDetectionService.submit(
                request,
                validating: { [weak self] context in
                    guard Thread.isMainThread else { return false }
                    return MainActor.assumeIsolated {
                        self?.isCurrentAutomaticPaste(context) ?? false
                    }
                },
                completion: { [weak self] result in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        self?.finishAutomaticPaste(result)
                    }
                }
            )
            return true
        }

        private func automaticPasteDestination(payload: String) -> PasteDestinationContext? {
            if structuralStyleNeedsRebuild {
                restyle()
            }
            guard !structuralStyleNeedsRebuild,
                  let textView, let storage = textView.textStorage,
                  textView.isEditable, !textView.hasMarkedText(),
                  document != nil
            else { return nil }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  NSMaxRange(selection) <= storage.length
            else { return nil }

            let intersectsFence = rangeIntersectsFence(selection)
            let inContainer = rangeIntersectsContainer(selection, in: storage.string)
            let intersectsAttachment = rangeIntersectsAttachment(selection, in: storage)
            let markdownCapable = isMarkdownCapable
            let destination = PasteDestinationContext(
                documentText: storage.string,
                replacementRange: selection,
                isMarkdownCapable: markdownCapable,
                intersectsCodeFence: intersectsFence,
                isInListOrQuoteContainer: inContainer,
                intersectsAttachment: intersectsAttachment,
                hasMarkedText: textView.hasMarkedText()
            )
            // A harmless label checks all destination and payload-independent
            // planner gates before inference is scheduled.
            guard PasteReplacementPlanner.plan(
                payload: payload, destination: destination, acceptedLanguageLabel: "text"
            ) != nil else { return nil }
            return destination
        }

        private func rangeIntersectsFence(_ range: NSRange) -> Bool {
            fenceRegions.contains { region in
                if range.length == 0 {
                    return range.location >= region.location && range.location < NSMaxRange(region)
                }
                return NSIntersectionRange(region, range).length > 0
            }
        }

        private func rangeIntersectsAttachment(
            _ range: NSRange, in storage: NSTextStorage
        ) -> Bool {
            guard range.length > 0 else { return false }
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        private func rangeIntersectsContainer(_ range: NSRange, in document: String) -> Bool {
            let text = document as NSString
            guard text.length > 0 else { return false }
            let lastCovered = range.length > 0 ? NSMaxRange(range) - 1 : range.location
            var location = text.paragraphRange(
                for: NSRange(location: min(range.location, text.length), length: 0)
            ).location
            while location <= min(lastCovered, text.length - 1) {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                let line = text.substring(with: paragraph)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix(">") { return true }
                if let kind = classifiedKind(ofParagraphAt: paragraph.location), case .list = kind {
                    return true
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            return false
        }

        /// A page and a note read as markdown; a file only in its markdown mode.
        private var isMarkdownCapable: Bool {
            guard case .sheet(let sheet) = document else { return document != nil }
            return !sheet.isFileID || model.fileRenderMode(for: sheet) == .markdown
        }

        /// The id a language detection request carries: the sheet's, or the
        /// note's chip; a surface only ever compares it with its own.
        private var detectionKey: UInt64? { noteChip ?? currentSheet }

        /// The display only fence labels of the document under the surface.
        private func fenceLanguages() -> [Int: String] {
            switch document {
            case .sheet(let sheet): model.fenceRenderingLanguages(for: sheet)
            case .note: noteFenceLanguages
            case nil: [:]
            }
        }

        private func setFenceLanguage(_ language: String, at paragraphLocation: Int) {
            switch document {
            case .sheet(let sheet):
                model.setFenceRenderingLanguage(language, sheet: sheet, at: paragraphLocation)
            case .note: noteFenceLanguages[paragraphLocation] = language
            case nil: break
            }
        }

        private func clearFenceLanguages() {
            switch document {
            case .sheet(let sheet): model.clearFenceRenderingLanguages(for: sheet)
            case .note: noteFenceLanguages = [:]
            case nil: break
            }
        }

        /// Whether `textView` is still the surface a captured paste was for.
        private func isLiveSurface(_ textView: InkTextView) -> Bool {
            writesNote ? noteChip != nil : model.activeEditor === textView
        }

        private func isCurrentAutomaticPaste(_ context: LanguageDetectionContext) -> Bool {
            guard model.languageDetectionEnabled,
                  let pendingAutomaticPaste,
                  pendingAutomaticPaste.requestID == context.requestID,
                  pendingAutomaticPaste.documentID == context.documentID,
                  pendingAutomaticPaste.revision == context.revision,
                  detectionKey == context.documentID,
                  UInt64(generation) == context.revision,
                  let textView, textView.isEditable, !textView.hasMarkedText()
            else { return false }
            return textView.selectedRange() == context.selectionSnapshot
                && context.targetRange == pendingAutomaticPaste.destination.replacementRange
        }

        private func finishAutomaticPaste(_ result: LanguageDetectionResult) {
            guard isCurrentAutomaticPaste(result.context), let pending = pendingAutomaticPaste else {
                return
            }
            pendingAutomaticPaste = nil
            let plan = result.language.flatMap {
                PasteReplacementPlanner.plan(
                    payload: pending.payload,
                    destination: pending.destination,
                    acceptedLanguageLabel: $0
                )
            }
            if let plan {
                applyReplacement(
                    plan.replacementText,
                    range: plan.replacementRange,
                    caret: plan.finalCaretRange,
                    intent: .paste
                )
            } else {
                let caret = NSRange(
                    location: pending.destination.replacementRange.location + pending.payload.utf16.count,
                    length: 0
                )
                applyReplacement(
                    pending.payload,
                    range: pending.destination.replacementRange,
                    caret: caret,
                    intent: .paste
                )
            }
        }

        private func applyReplacement(
            _ replacement: String, range: NSRange, caret: NSRange, intent: EditorEditIntent
        ) {
            guard let textView, let storage = textView.textStorage,
                  textView.isEditable, !textView.hasMarkedText(),
                  NSMaxRange(range) <= storage.length,
                  textView.shouldChangeText(in: range, replacementString: replacement)
            else { return }
            withEditIntent(intent, afterSelection: caret) {
                storage.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(Self.clamped(caret, to: storage.length))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        var manualLanguageTargetAvailable: Bool {
            PageModel.languageDetectionFeaturesAvailable && manualLanguageTarget() != nil
        }

        /// The Edit menu's language and seal items as the key holder can answer
        /// them (Law 0007, keys row); under a field the page offers none.
        func refreshLanguageActionAvailability() {
            if writesNote, textView?.answersChords != true { return }
            if let textView, !textView.answersChords {
                if let holder = textView.window?.firstResponder as? InkTextView,
                   holder !== textView, holder.answersChords { return }
                model.languageActions.stand(
                    canDetect: false, canChoose: false, selectionIsEmpty: nil, canPaste: false)
                model.sealActions.stand(canSeal: false)
                return
            }
            let canChoose = manualLanguageTargetAvailable
            let selectionIsEmpty: Bool?
            if PageModel.languageDetectionFeaturesAvailable,
               let textView, let storage = textView.textStorage,
               document != nil, textView.isEditable, !textView.hasMarkedText()
            {
                let selection = textView.selectedRange()
                selectionIsEmpty = selection.location != NSNotFound
                    && NSMaxRange(selection) <= storage.length
                    ? selection.length == 0
                    : nil
            } else {
                selectionIsEmpty = nil
            }
            model.languageActions.stand(
                canDetect: canChoose && model.languageDetectionEnabled,
                canChoose: canChoose,
                selectionIsEmpty: selectionIsEmpty,
                canPaste: PageModel.languageDetectionFeaturesAvailable
                    && document != nil && textView?.isEditable == true
            )
            model.sealActions.stand(canSeal: sealableSelection() != nil)
        }

        /// Whether a seal gesture landing in this editor has a page to
        /// seal into: the mounted document is a page, not a file, and
        /// the view takes edits. The three seal routes ask this first.
        /// Without it a chord, the offer button or a drop over a file
        /// would route to the page behind the file (the slot the
        /// selection still names) and rewrite the file's storage under
        /// the projection guard with a chip the file's own document
        /// does not hold. It asks the model's own answer
        /// (`PageModel.sealTarget`) as well as the mounted document, so
        /// the two refuse the same cases by construction; this half also
        /// keeps a refused seal from clearing the clipboard or flashing
        /// a line about a seal that did not happen.
        var sealsHere: Bool {
            guard let textView, let sheet = currentSheet, !sheet.isFileID,
                  textView.isEditable, model.sealTarget != nil
            else { return false }
            return true
        }

        /// The selection Edit → Seal Selected Content and the context
        /// menu row would seal: non-empty, on an editable page rather
        /// than a file, where the model has a seal target (no file and
        /// no ledger showing), and not mid-composition. Nil otherwise. The
        /// chord is wider (it takes the current line when nothing is
        /// selected); the menus name a selection and offer only that.
        func sealableSelection() -> NSRange? {
            guard let textView, let storage = textView.textStorage,
                  let sheet = currentSheet, !sheet.isFileID,
                  textView.isEditable, !textView.hasMarkedText(),
                  model.sealTarget != nil
            else { return nil }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.length > 0,
                  NSMaxRange(selection) <= storage.length
            else { return nil }
            return selection
        }

        /// The context menu's Seal Selection row (D-30), offered when
        /// the selection is sealable and holds no chip: over a chip the
        /// row would only ever refuse, and a menu should not offer a
        /// verb it knows it will decline.
        func appendSealItem(to menu: NSMenu) {
            guard let storage = textView?.textStorage, let selection = sealableSelection(),
                  !Self.containsChip(storage, in: selection)
            else { return }
            let seal = NSMenuItem(
                title: SealSelectionMenu.contextMenuTitle,
                action: #selector(sealSelectionFromMenu(_:)),
                keyEquivalent: ""
            )
            seal.target = self
            menu.addItem(seal)
        }

        @objc private func sealSelectionFromMenu(_ sender: NSMenuItem) {
            sealSelectionOrLine()
        }

        var canDetectCodeLanguage: Bool {
            manualLanguageTargetAvailable && model.languageDetectionEnabled
        }

        func detectCodeLanguage() {
            guard PageModel.languageDetectionFeaturesAvailable,
                  model.languageDetectionEnabled
            else { return }
            guard let target = manualLanguageTarget(), let storage = textView?.textStorage else {
                model.flash("select whole lines or place the caret inside a bare code fence")
                return
            }
            invalidateOrdinaryPasteMeasurement()
            let data = Data((storage.string as NSString).substring(with: target.detectionRange).utf8)
            let request = LanguageDetectionRequest(
                documentID: target.documentID,
                revision: target.revision,
                targetRange: target.detectionRange,
                trigger: .manual,
                selectionSnapshot: target.selectionSnapshot,
                data: data
            )
            pendingManualRequestID = request.requestID
            languageDetectionService.submit(
                request,
                validating: { [weak self] context in
                    guard Thread.isMainThread else { return false }
                    return MainActor.assumeIsolated {
                        self?.isCurrentManualRequest(context, target: target) ?? false
                    }
                },
                completion: { [weak self] result in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        guard let self, self.isCurrentManualRequest(result.context, target: target)
                        else { return }
                        self.pendingManualRequestID = nil
                        guard let language = result.language else {
                            self.model.flash("no code language suggestion")
                            return
                        }
                        self.languageSuggestion = LanguageSuggestion(
                            target: target, language: language
                        )
                        self.textView?.showFindIndicator(for: target.detectionRange)
                        self.model.flash("suggested language: \(language) · open the editor menu to apply it")
                    }
                }
            )
        }

        private func isCurrentManualRequest(
            _ context: LanguageDetectionContext, target: ManualLanguageTarget
        ) -> Bool {
            guard model.languageDetectionEnabled,
                  pendingManualRequestID == context.requestID,
                  context.documentID == target.documentID,
                  context.revision == target.revision,
                  context.targetRange == target.detectionRange,
                  detectionKey == target.documentID,
                  UInt64(generation) == target.revision,
                  let textView, textView.isEditable, !textView.hasMarkedText(),
                  textView.selectedRange() == target.selectionSnapshot
            else { return false }
            return manualLanguageTarget() == target
        }

        private func manualLanguageTarget() -> ManualLanguageTarget? {
            guard let textView, let storage = textView.textStorage,
                  let documentID = detectionKey, textView.isEditable,
                  !textView.hasMarkedText()
            else { return nil }
            let selection = textView.selectedRange()
            if selection.length > 0 {
                let destination = PasteDestinationContext(
                    documentText: storage.string,
                    replacementRange: selection,
                    isMarkdownCapable: isMarkdownCapable,
                    intersectsCodeFence: rangeIntersectsFence(selection),
                    isInListOrQuoteContainer: rangeIntersectsContainer(
                        selection, in: storage.string
                    ),
                    intersectsAttachment: rangeIntersectsAttachment(selection, in: storage)
                )
                guard PasteReplacementPlanner.plan(
                    payload: (storage.string as NSString).substring(with: selection),
                    destination: destination,
                    acceptedLanguageLabel: "text"
                ) != nil else { return nil }
                return ManualLanguageTarget(
                    documentID: documentID,
                    revision: UInt64(generation),
                    detectionRange: selection,
                    selectionSnapshot: selection,
                    kind: .selection
                )
            }
            guard let fence = bareFenceTarget(at: selection.location, in: storage.string) else {
                return nil
            }
            return ManualLanguageTarget(
                documentID: documentID,
                revision: UInt64(generation),
                detectionRange: fence.body,
                selectionSnapshot: selection,
                kind: .bareFence(
                    opening: fence.opening,
                    body: fence.body,
                    labelInsertionLocation: fence.labelInsertionLocation
                )
            )
        }

        private func bareFenceTarget(
            at location: Int, in document: String
        ) -> (opening: NSRange, body: NSRange, labelInsertionLocation: Int)? {
            let text = document as NSString
            var scanner = InkStyle.FenceScanner()
            var paragraphStart = 0
            var opening: (range: NSRange, bodyStart: Int, insertion: Int)?
            while paragraphStart < text.length {
                let paragraph = text.paragraphRange(
                    for: NSRange(location: paragraphStart, length: 0)
                )
                let line = text.substring(with: paragraph)
                let wasInside = scanner.insideFence
                let kind = scanner.classify(line)
                if case .fenceRule = kind {
                    if !wasInside {
                        // The same whitespace the scanner trimmed before
                        // it called this line a fence rule. Trimming only
                        // spaces and tabs here let a fence indented with a
                        // no-break space (pasted from a rich source) pass
                        // `classify` and then fail `fenceRun`, which
                        // returned nil for the whole document and took
                        // every bare fence below it out of reach.
                        let trimmedHead = line.prefix { character in
                            character.unicodeScalars.allSatisfy(
                                CharacterSet.whitespacesAndNewlines.contains)
                        }
                        let afterIndent = line.dropFirst(trimmedHead.count)
                        // `classify` already called this line a fence
                        // rule; should the two ever disagree again, the
                        // cost is this fence, not every one below it.
                        if let run = InkStyle.FenceScanner.fenceRun(
                            of: afterIndent.trimmingCharacters(in: .newlines)
                        ) {
                            opening = run.info.isEmpty
                                ? (paragraph, NSMaxRange(paragraph), paragraph.location
                                    + trimmedHead.utf16.count + run.length)
                                : nil
                        } else {
                            opening = nil
                        }
                    } else if let candidate = opening {
                        let body = NSRange(
                            location: candidate.bodyStart,
                            length: paragraph.location - candidate.bodyStart
                        )
                        let region = NSUnionRange(candidate.range, paragraph)
                        if location >= region.location, location < NSMaxRange(region) {
                            return (candidate.range, body, candidate.insertion)
                        }
                        // Closing this fence retires the current candidate.
                        opening = nil
                    }
                }
                paragraphStart = NSMaxRange(paragraph)
            }
            if let opening {
                let body = NSRange(location: opening.bodyStart, length: text.length - opening.bodyStart)
                let region = NSRange(
                    location: opening.range.location,
                    length: text.length - opening.range.location
                )
                if location >= region.location, location <= NSMaxRange(region) {
                    return (opening.range, body, opening.insertion)
                }
            }
            return nil
        }

        func applySuggestedLanguage(displayOnly: Bool) {
            guard let suggestion = languageSuggestion,
                  manualLanguageTarget() == suggestion.target
            else { return }
            switch suggestion.target.kind {
            case .selection:
                let text = textView?.textStorage?.string ?? ""
                let destination = PasteDestinationContext(
                    documentText: text,
                    replacementRange: suggestion.target.detectionRange,
                    isMarkdownCapable: isMarkdownCapable,
                    intersectsCodeFence: rangeIntersectsFence(
                        suggestion.target.detectionRange
                    ),
                    isInListOrQuoteContainer: rangeIntersectsContainer(
                        suggestion.target.detectionRange, in: text
                    ),
                    intersectsAttachment: textView?.textStorage.map {
                        rangeIntersectsAttachment(suggestion.target.detectionRange, in: $0)
                    } ?? true
                )
                let payload = (text as NSString).substring(with: suggestion.target.detectionRange)
                guard let plan = PasteReplacementPlanner.plan(
                    payload: payload,
                    destination: destination,
                    acceptedLanguageLabel: suggestion.language
                ) else { return }
                languageSuggestion = nil
                applyReplacement(
                    plan.replacementText,
                    range: plan.replacementRange,
                    caret: plan.finalCaretRange,
                    intent: .automation
                )
            case .bareFence(let opening, _, let insertion):
                if displayOnly {
                    setFenceLanguage(suggestion.language, at: opening.location)
                    restyle()
                } else {
                    languageSuggestion = nil
                    applyReplacement(
                        suggestion.language,
                        range: NSRange(location: insertion, length: 0),
                        caret: NSRange(location: insertion + suggestion.language.utf16.count, length: 0),
                        intent: .automation
                    )
                }
            }
        }

        func dismissLanguageSuggestion() {
            pendingManualRequestID = nil
            languageSuggestion = nil
            languageDetectionService.invalidate()
        }

        func applyManualLanguage(_ language: String) {
            guard PageModel.languageDetectionFeaturesAvailable,
                  Self.manualLanguages.contains(language),
                  let target = manualLanguageTarget()
            else {
                return
            }
            languageSuggestion = LanguageSuggestion(target: target, language: language)
            applySuggestedLanguage(displayOnly: {
                if case .bareFence = target.kind { return true }
                return false
            }())
        }

        func appendLanguageItems(to menu: NSMenu) {
            guard PageModel.languageDetectionFeaturesAvailable, let textView else { return }
            menu.addItem(.separator())

            let detect = NSMenuItem(
                title: "Detect Code Language…",
                action: #selector(detectCodeLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            detect.target = self
            detect.isEnabled = model.languageDetectionEnabled && manualLanguageTarget() != nil
            menu.addItem(detect)

            if let suggestion = languageSuggestion,
               manualLanguageTarget() == suggestion.target
            {
                let heading = NSMenuItem(
                    title: "Suggested: \(suggestion.language.capitalized)",
                    action: nil,
                    keyEquivalent: ""
                )
                heading.isEnabled = false
                menu.addItem(heading)
                let dismiss = NSMenuItem(
                    title: "Dismiss Suggestion",
                    action: #selector(dismissLanguageSuggestionFromMenu(_:)),
                    keyEquivalent: ""
                )
                dismiss.target = self
                menu.addItem(dismiss)
                switch suggestion.target.kind {
                case .selection:
                    let wrap = NSMenuItem(
                        title: "Wrap as \(suggestion.language.capitalized) Code",
                        action: #selector(applySuggestedWrap(_:)),
                        keyEquivalent: ""
                    )
                    wrap.target = self
                    menu.addItem(wrap)
                case .bareFence:
                    let highlight = NSMenuItem(
                        title: "Use \(suggestion.language.capitalized) for Highlighting",
                        action: #selector(applySuggestedHighlighting(_:)),
                        keyEquivalent: ""
                    )
                    highlight.target = self
                    menu.addItem(highlight)
                    let insert = NSMenuItem(
                        title: "Insert \(suggestion.language) in Fence",
                        action: #selector(insertSuggestedFenceLabel(_:)),
                        keyEquivalent: ""
                    )
                    insert.target = self
                    menu.addItem(insert)
                }
            }

            if manualLanguageTarget() != nil {
                let choose = NSMenuItem(title: "Choose Language", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "Choose Language")
                for language in Self.manualLanguages {
                    let item = NSMenuItem(
                        title: language.capitalized,
                        action: #selector(chooseLanguageFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = language
                    submenu.addItem(item)
                }
                choose.submenu = submenu
                menu.addItem(choose)
            }

            let bypass = NSMenuItem(
                title: "Paste Without Detection",
                action: #selector(LanguageDetectionResponder.pasteWithoutDetection(_:)),
                keyEquivalent: ""
            )
            bypass.target = textView
            bypass.isEnabled = textView.isEditable
            menu.addItem(bypass)
        }

        @objc private func detectCodeLanguageFromMenu(_ sender: Any?) {
            detectCodeLanguage()
        }

        @objc private func dismissLanguageSuggestionFromMenu(_ sender: Any?) {
            dismissLanguageSuggestion()
        }

        @objc private func applySuggestedWrap(_ sender: Any?) {
            applySuggestedLanguage(displayOnly: false)
        }

        @objc private func applySuggestedHighlighting(_ sender: Any?) {
            applySuggestedLanguage(displayOnly: true)
        }

        @objc private func insertSuggestedFenceLabel(_ sender: Any?) {
            applySuggestedLanguage(displayOnly: false)
        }

        @objc private func chooseLanguageFromMenu(_ sender: NSMenuItem) {
            guard let language = sender.representedObject as? String else { return }
            applyManualLanguage(language)
        }

        // MARK: The page swap (ADR-0006)

        /// Move the one editor onto another page.
        ///
        /// A page switch reaches this editor as data, not identity
        /// (ADR-0006): the view (and with it first responder, and the
        /// ember) persists, while the page's storage is swapped in
        /// underneath. Caret and scroll are saved for the page on its
        /// way out and restored for the one coming in; undo history
        /// follows `currentSheet` through the delegate's per-page
        /// manager and needs no hand-off here.
        ///
        /// An in-progress IME composition is anchored to the outgoing
        /// page's offsets. The dropped `.id(selection)` used to discard
        /// it by tearing the view down; the persistent view must do it by
        /// hand, or the pending marked text commits into the incoming
        /// page's storage (the wrong page) or leaves the input context
        /// pointing at a stale range (ADR-0006 eject-trigger #3, issue
        /// #23). Discard before the swap so nothing crosses the boundary.
        ///
        /// The scroller is optional because the editor's own clip is not
        /// the only place it can stand. A surface that rolls several days
        /// past one scroller has a single offset belonging to the roll
        /// rather than to any page in it, and it passes nil: the caret
        /// leg still runs, because a caret belongs to the page wherever
        /// the page is mounted, and the scroll leg is skipped rather than
        /// putting one page's offset back onto everybody's scroller.
        func moveEditor(
            _ textView: InkTextView,
            to sheetID: UInt64,
            storage incoming: NSTextStorage,
            restoringScrollIn scrollView: NSScrollView?
        ) {
            // The swap sheds the incoming page's layout managers, so it
            // is the owner's to make, for the builder's reason
            // (`makeInkTextView`). Both mount sites ask before they get
            // here, and this is the guard for one that did not.
            guard model.admits(.activeEditor, from: surface) else { return }
            invalidateOrdinaryPasteMeasurement()
            keepNaming()
            closeNote()
            InkEditorView.discardComposition(in: textView)
            saveViewState(textView: textView, scrollView: scrollView)
            // The one-layout-manager-per-storage invariant rests on this
            // path now; the mount's detach loop runs only at mount. The
            // incoming storage may still carry a layout manager some
            // torn-down editor (a ledger round trip) left behind, shed
            // those before wiring ours to it. `replaceTextStorage` then
            // moves this editor's layout manager off the outgoing storage,
            // leaving both sides with exactly the managers they should
            // have: one here, none on the page going to the background.
            // The delegate follows the mount: the outgoing storage stops
            // emitting (background writes are projection updates, not
            // edits), the incoming one starts.
            let outgoing = textView.textStorage
            Self.shedLayoutManagers(from: incoming, keeping: textView.layoutManager)
            textView.layoutManager?.replaceTextStorage(incoming)
            outgoing?.delegate = nil
            incoming.delegate = self
            vacantStorage = nil
            currentSheet = sheetID
            restyle()
            restoreViewState(textView: textView, scrollView: scrollView, for: sheetID)
            refreshLanguageActionAvailability()
        }

        /// What the editor stands on between leaving a page at a hand
        /// off and being taken down or put back. Held here because a
        /// TextKit 1 storage that nobody retains is freed under the
        /// view laying it out.
        private var vacantStorage: NSTextStorage?

        /// The unmount half of a hand off (ADR-0033): this editor comes
        /// off its page, now, because the other window is about to own
        /// it. Called by `PageModel.transferOwnership(to:)` before the
        /// owner changes, so the order of a hand off is written down in
        /// one place: the outgoing editor settles its composition,
        /// leaves its place with the model, lets go of the storage, and
        /// only then can the incoming window mount.
        ///
        /// Without this the unmount was the incoming mount's doing, its
        /// shed taking this editor's layout manager off the storage
        /// whenever SwiftUI got round to building it, with the old
        /// editor still the storage's delegate until then. Now a page
        /// changing hands has no layout manager and no delegate in
        /// between, and the incoming shed finds nothing of this
        /// window's to remove.
        ///
        /// The editor itself stays where it is, over an empty storage,
        /// as the roll's parked editor does. SwiftUI takes it down on
        /// its next pass. If ownership comes back first, the pass that
        /// finds this window owning again sees an editor standing on no
        /// page and moves it back (`updatePage`, `DayStackView.update`).
        /// Editing is refused in the meantime, and re-gated by that
        /// same pass.
        func leavePage(_ textView: InkTextView, scrollView: NSScrollView?) {
            guard currentSheet != nil, let outgoing = textView.textStorage else { return }
            keepNaming()
            closeNote()
            InkEditorView.discardComposition(in: textView)
            saveViewState(textView: textView, scrollView: scrollView)
            let vacant = NSTextStorage()
            vacantStorage = vacant
            textView.layoutManager?.replaceTextStorage(vacant)
            outgoing.delegate = nil
            textView.isEditable = false
            parkEditor()
        }

        // MARK: Per-page view state (ADR-0006)

        /// Remember the outgoing page's caret and scroll before the
        /// swap.
        ///
        /// A mount with no scroller of its own saves the caret and stops
        /// there. There is no offset belonging to this page to read, and
        /// whatever a scrolled mount once saved is left standing rather
        /// than overwritten with a guess.
        ///
        /// Nothing settles a typing group on the way out any more:
        /// undo steps are the core's and each page's stack is its own,
        /// so a swap cannot leave half a word open in a page that is
        /// going away (issue #132).
        ///
        /// Both are written to the model's table rather than kept here
        /// (`PageModel.viewStates`), so the place survives this editor
        /// and is there for whichever one mounts the page next. That
        /// next editor may stand in a window of another width, so the
        /// scroll is kept as the line at the top of the clip and never
        /// as the clip's origin in points (`ScrollAnchor`).
        ///
        /// Two editors have nothing true to say and are not asked. One
        /// whose layout manager has been shed from the page, because
        /// another editor mounted over the same storage before this one
        /// was dismantled: its selection and its layout describe
        /// nothing any more, and the place it would write over is the
        /// live editor's. And one whose clip has no size yet, which has
        /// not shown the page at all and keeps the scroll it was handed
        /// rather than replacing it with the top of a view nobody saw.
        func saveViewState(textView: InkTextView, scrollView: NSScrollView?) {
            guard let sheet = currentSheet, textView.textStorage != nil else { return }
            model.viewStates.saveCaret(textView.selectedRange(), for: sheet)
            guard let scrollView, !scrollView.contentView.bounds.isEmpty,
                  let anchor = ScrollAnchor(
                      topOf: textView, clipOrigin: scrollView.contentView.bounds.origin
                  )
            else { return }
            model.viewStates.saveScroll(anchor, for: sheet)
        }

        /// Return the incoming page's caret and scroll after the swap.
        /// The caret is clamped — content can change while a page is
        /// in the background (a burn, a restore) — and lands
        /// synchronously, being character offsets that owe layout
        /// nothing. The scroll cannot: the layout manager re-lays the
        /// new storage out asynchronously, and a synchronous restore
        /// is clobbered by the pass that follows. One main-queue hop
        /// later the geometry can be made real: the restore forces
        /// layout for the text container and measures the used rect,
        /// rather than trusting a `frame` height that a relayout still
        /// in flight may report as zero and so collapse the clamp to the
        /// top of the page. This is ADR-0005's timing discipline applied
        /// to scrolling, with the height forced current rather than
        /// merely hoped current after the hop. The hop carries its sheet
        /// with it: a
        /// switch that lands before the queue drains retires the stale
        /// closure, which checks `currentSheet` and declines to scroll
        /// a page it was never scheduled for. It does not leave empty
        /// handed, though. A switch that fast has already saved the
        /// live origin over this sheet's entry, because the next
        /// `saveViewState` ran before the restore landed; the retired
        /// closure still holds the true anchor, so it writes that back
        /// on its way out. A sheet pruned in the interim stays gone:
        /// the write-back repairs entries, it never resurrects them.
        /// And because content can shrink while a page is in the
        /// background, the offset is clamped against the geometry that
        /// exists on arrival, not the geometry that was saved.
        ///
        /// The hop is also where the anchor becomes an offset. What was
        /// saved is a line, not a distance, and how far down this view
        /// that line sits is a fact about this view's layout, which
        /// the hop has just forced current. The editor that saved it
        /// may have been another one at another width.
        ///
        /// A mount with no scroller of its own takes the caret and stops
        /// there, as `saveViewState` did: there is no clip of this page's
        /// to move, so no hop is scheduled and any offset a scrolled
        /// mount saved stays where it is, waiting for that mount.
        ///
        /// The two legs are separate calls as well, because a mount
        /// takes them at different moments: the building seats the
        /// caret for every surface, and the surface that owns a clip
        /// asks for the scroll once the clip exists.
        func restoreViewState(
            textView: InkTextView, scrollView: NSScrollView?, for sheet: UInt64
        ) {
            restoreCaret(textView: textView, for: sheet)
            guard let scrollView else { return }
            restoreScroll(textView: textView, scrollView: scrollView, for: sheet)
        }

        /// The caret leg: synchronous, clamped, and owing layout nothing.
        func restoreCaret(textView: InkTextView, for sheet: UInt64) {
            let caret = Self.clamped(
                model.viewStates.carets[sheet] ?? NSRange(location: 0, length: 0),
                to: textView.textStorage?.length ?? 0
            )
            textView.setSelectedRange(caret)
        }

        /// The scroll leg, for the surface that owns a clip.
        func restoreScroll(
            textView: InkTextView, scrollView: NSScrollView, for sheet: UInt64
        ) {
            scheduleScrollRestore(
                of: model.viewStates.scrolls[sheet],
                textView: textView, scrollView: scrollView, for: sheet
            )
        }

        /// The hop itself, taking the anchor as a value so a restore
        /// that had to wait can be asked for again with the anchor it
        /// was first given rather than whatever the table holds by then.
        ///
        /// Waiting is for a mount. SwiftUI is free to let the hop run
        /// before it has given a newly made scroller any size, and a
        /// container with no width lays the page out unwrapped, one
        /// line to a paragraph. The anchor's line would go to the top
        /// of that, and when the real width arrived the text view would
        /// hold on to the first character it was showing, which by then
        /// is the start of the paragraph rather than the line inside it
        /// that was being read. Near, and wrong. So a hop that lands on
        /// an empty clip sets the anchor down, and the clip's first
        /// real frame picks it up (`clipFrameChanged`).
        private func scheduleScrollRestore(
            of anchor: ScrollAnchor?,
            textView: InkTextView, scrollView: NSScrollView, for sheet: UInt64
        ) {
            deferredScrollRestore = nil
            DispatchQueue.main.async { [weak self, weak textView, weak scrollView] in
                guard let self else { return }
                guard self.currentSheet == sheet else {
                    self.model.viewStates.repairScroll(anchor, for: sheet)
                    return
                }
                guard let scrollView else { return }
                guard !scrollView.contentView.bounds.isEmpty else {
                    self.deferredScrollRestore = (sheet, anchor)
                    return
                }
                // Measure against layout that has been forced current,
                // not the `frame` height a relayout still in flight can
                // report as zero. The text view is the document view;
                // when its TextKit stack is somehow gone, fall back to
                // the frame the clamp used to trust.
                let documentHeight = textView.flatMap { self.documentHeight(of: $0) }
                    ?? scrollView.documentView?.frame.height ?? 0
                // After the height, so the anchor's line is looked up
                // in the layout that was just made certain. A page with
                // nothing saved opens at the top.
                let offset = textView.flatMap { anchor?.offset(in: $0) } ?? .zero
                let clamped = Self.clampedScrollOffset(
                    offset,
                    documentHeight: documentHeight,
                    clipHeight: scrollView.contentView.bounds.height
                )
                scrollView.contentView.scroll(to: clamped)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// The document's true height, forced current. One main-queue
        /// hop gives the layout manager room to re-lay the swapped
        /// storage, but room is not the same as done, so the height is
        /// made certain rather than assumed: ensure layout for the text
        /// container, then measure its used rect plus the top and bottom
        /// text inset. A height read straight off `frame` can still be
        /// zero here, and a zero height collapses the clamp's ceiling to
        /// the top of the page, discarding a perfectly valid saved
        /// offset. Returns nil only when the TextKit stack is missing,
        /// leaving the caller to fall back to the frame.
        private func documentHeight(of textView: InkTextView) -> CGFloat? {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return nil }
            layoutManager.ensureLayout(for: container)
            return layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
        }

        // MARK: Wrapping (⌥Z, Settings)

        /// The scroll view this editor's page sits in. Weak and held
        /// only so a wrap change, which arrives through the model rather
        /// than through a view, can reach the geometry it has to rebuild.
        private weak var scrollView: NSScrollView?
        /// The exact clip view carrying this coordinator's observers.
        /// A scroll view may replace its clip without changing identity.
        private weak var observedClip: NSClipView?

        /// The wrap state the geometry currently stands in, so a SwiftUI
        /// pass that changed something else does not tear the text
        /// container down and rebuild it for nothing. Nil until the
        /// first apply.
        private var appliedWrap: Bool?

        /// Rebuild the page's geometry for `wraps`, if it has moved.
        func applyWrap(_ wraps: Bool) {
            guard let textView, let scroll = scrollView, appliedWrap != wraps else { return }
            appliedWrap = wraps
            InkEditorView.setWrap(wraps, textView: textView, scroll: scroll)
        }

        /// The typeface the mounted page was last styled in, so the
        /// pass that changed nothing restyles nothing. Set at the
        /// building, where the first styling happens.
        var appliedTypeface: InkStyle.Typeface?
        var appliedSyntaxHighlighting: Bool?
        var appliedPreviewRendering: PreviewRenderingScope?
        var appliedLanguageDetection: Bool?
        var appliedFileRenderMode: FileRenderMode?

        /// Restyle the mounted page in the typeface Settings now names.
        /// The model has already written it to `InkStyle`, so the
        /// restyle pass lays every line back down in the new base font
        /// and the heading ramp derived from it; what that pass does not
        /// touch is what the caret types next, so the typing attributes
        /// are moved here. Pages the editor is not standing on keep
        /// their old fonts until the editor moves to them, and
        /// `moveEditor` restyles on arrival.
        func applyTypeface(_ typeface: InkStyle.Typeface) {
            guard let textView, appliedTypeface != typeface else { return }
            appliedTypeface = typeface
            textView.typingAttributes[.font] = InkStyle.baseFont
            restyle()
        }

        func applySyntaxHighlighting(_ enabled: Bool) {
            guard appliedSyntaxHighlighting != enabled else { return }
            appliedSyntaxHighlighting = enabled
            restyle()
        }

        /// Compare the mounted page's effective scope, including its override.
        func applyPreviewRendering(_ scope: PreviewRenderingScope) {
            let effective = writesNote ? scope : currentSheet.map {
                model.previewRendering(for: $0)
            } ?? scope
            guard appliedPreviewRendering != effective else { return }
            appliedPreviewRendering = effective
            restyle()
        }

        func applyFileRenderMode(_ mode: FileRenderMode) {
            guard appliedFileRenderMode != mode else { return }
            appliedFileRenderMode = mode
            restyle()
        }

        func applyLanguageDetection(_ enabled: Bool) {
            guard appliedLanguageDetection != enabled else { return }
            appliedLanguageDetection = enabled
            refreshLanguageActionAvailability()
            guard !enabled else { return }
            settleAutomaticPasteAsPlainIfPossible()
            pendingOrdinaryPasteRequestID = nil
            pendingManualRequestID = nil
            languageSuggestion = nil
            languageDetectionService.invalidate()
        }

        /// Watch the clip for two jobs: a frame change keeps the unwrapped
        /// page's width floor level with the card, and a bounds change
        /// refreshes hover under a stationary pointer. Registered by
        /// selector rather than by block: that registration is zeroing,
        /// so it retires with this coordinator and needs no `deinit` to
        /// unpick it. Idempotent: every `updateNSView` calls it, and the
        /// same clip re-registers to nothing.
        func observeClip(of scroll: NSScrollView) {
            let clip = scroll.contentView
            guard observedClip !== clip else {
                scrollView = scroll
                return
            }
            if let observedClip {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.frameDidChangeNotification, object: observedClip
                )
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: observedClip
                )
            }
            scrollView = scroll
            observedClip = clip
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: clip
            )
            // Set this explicitly so hover refresh does not depend on
            // NSView's default notification-posting behavior.
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }

        /// The page scrolled. Hover follows the pointer, and the pointer
        /// did not move, so the hit test has to be re-run against the
        /// content that arrived under it. Programmatic scrolls
        /// (`scrollRangeToVisible` while typing, the offset restore at
        /// mount) land here too and re-resolve hover deliberately, the
        /// way tracking-area hover behaves on AppKit controls.
        @objc private func clipBoundsChanged(_ notification: Notification) {
            textView?.refreshHover()
        }

        /// The card resized. The floor under the typing surface is the
        /// clip's to keep (`EditorViewportClipView`), and wrapped, the
        /// autoresizing mask has done everything else. Unwrapped, the
        /// text view sizes itself to its text and nothing else would
        /// ever widen it, so a page narrower than the card is stretched
        /// to meet it here.
        ///
        /// A newly mounted page's first real frame also arrives here,
        /// and with it the scroll restore that could not be resolved
        /// against a clip with no size. It goes back through the hop
        /// rather than landing in this callback, since the text view is
        /// about to be laid out again at the width it was just given.
        @objc private func clipFrameChanged(_ notification: Notification) {
            defer { textView?.refreshHover() }
            if let deferred = deferredScrollRestore, let textView, let scroll = scrollView,
               !scroll.contentView.bounds.isEmpty {
                deferredScrollRestore = nil
                if deferred.sheet == currentSheet {
                    scheduleScrollRestore(
                        of: deferred.anchor,
                        textView: textView, scrollView: scroll, for: deferred.sheet
                    )
                }
            }
            guard appliedWrap == false, let textView, let scroll = scrollView,
                  scroll.documentView === textView else { return }
            let width = scroll.contentSize.width
            guard textView.frame.width < width else { return }
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }

        /// Enforce the one-layout-manager-per-storage invariant
        /// (ADR-0006): detach every layout manager on `storage` except
        /// `keeper`. Pass `nil` to shed them all, as at mount, before
        /// this editor's own manager is attached.
        static func shedLayoutManagers(from storage: NSTextStorage, keeping keeper: NSLayoutManager?) {
            for stale in storage.layoutManagers where stale !== keeper {
                storage.removeLayoutManager(stale)
            }
        }

        /// A caret saved against yesterday's content may overhang
        /// today's. Clamp to what exists, so a shrunken page seats the
        /// caret at its end instead of out of bounds.
        nonisolated static func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(range.location, 0), length)
            let span = min(max(range.length, 0), length - location)
            return NSRange(location: location, length: span)
        }

        /// A scroll offset saved against yesterday's geometry may
        /// overhang today's. `NSClipView.scroll(to:)` does not clamp,
        /// so a page that shrank in the background would come back
        /// showing blank space below its document. Clamp y to what the
        /// document can actually scroll; x stays as saved, since the
        /// page never scrolls horizontally.
        nonisolated static func clampedScrollOffset(
            _ offset: NSPoint, documentHeight: CGFloat, clipHeight: CGFloat
        ) -> NSPoint {
            let maxY = max(0, documentHeight - clipHeight)
            return NSPoint(x: offset.x, y: min(max(offset.y, 0), maxY))
        }

        /// ⌘Z and ⇧⌘Z, taken off AppKit's stack and handed to the
        /// core's (issue #132).
        ///
        /// The core owns the document, so it owns what a step means:
        /// this asks it to take one, and then puts the caret where it
        /// says the writer's hand was. The storage has already been
        /// rewritten from the core's runs by the time this returns, so
        /// the clamp is against the page as it now stands.
        ///
        /// **A step reverts this device's operations and no others.**
        /// Loro's manager is local to the document's own peer, and a
        /// device that joined at a key frame never held the operations
        /// an away-device undo would need (ADR-0021 section 5). ⌘Z is
        /// therefore undo that is safe beside another device's edits,
        /// not undo that reaches across them, and nothing on this route
        /// should be built as though it could.
        func step(back: Bool) {
            invalidateOrdinaryPasteMeasurement()
            guard let document, let textView else { return }
            // The gate lives here rather than only at the callers. Both
            // routes that exist today check it before they arrive, and
            // that is still worth keeping at the chord, which has to
            // fall through rather than be swallowed; but a page shown
            // read-only must not be rewritten by whatever third route
            // is added next, and this is the one place every route
            // passes through.
            guard textView.isEditable else { return }
            // A composition in flight is anchored to offsets this step
            // is about to rewrite, and the emission gate skips its
            // bookkeeping while a projection write is in progress, so a
            // marked span would survive into a storage that no longer
            // holds it. Settle it on the page it was typed on first,
            // exactly as the page swap does. A press that finds nothing
            // on the stack has still ended the composition, which is
            // what every other editor on the machine does with ⌘Z
            // mid-conversion.
            InkEditorView.discardComposition(in: textView)
            let outcome = model.stepEdit(document, back: back)
            guard outcome.applied else { return }
            // The model restates a page's storage; a note's is the surface's own.
            if case .note = document { restateNote() }
            // The model rebuilt the storage from the core's runs, which
            // are plain text carrying the base font and nothing else,
            // so the page arrives here stripped of every attribute the
            // markdown pass puts on it. No other route lays them back
            // down: `textDidChange` is what usually calls the pass and
            // a projection write never fires it, the storage delegate
            // returns early under the emission guard, and
            // `updateNSView` turns back at a page that did not change.
            // A step would otherwise leave headings at body weight and
            // fences uncoloured until the writer typed one more
            // character.
            restyle()
            // A step that carried no selection leaves the current range alone,
            // clamped, rather than guessing at an offset.
            let length = textView.textStorage?.length ?? 0
            let selection = Self.clamped(
                outcome.selection ?? textView.selectedRange(),
                to: length
            )
            textView.setSelectedRange(selection)
            // Rewriting the whole storage resets the scroller, so a
            // step taken over an edit that was off screen would put the
            // caret somewhere the writer cannot see. Follow it.
            textView.scrollRangeToVisible(selection)
            noteHost?.inkDidChange()
        }

        // MARK: Editing (ops across the seam, ADR-0013)

        public func textDidChange(_ notification: Notification) {
            // One action's several edits are one change, taken once its batch has gone.
            guard heldBatch == nil else { return }
            inkChanged()
        }

        private func inkChanged() {
            restyle()
            noteHost?.inkDidChange()
            settleRemovalWatch()
        }

        /// The ops of an action's storage edits, held back to go as one batch (`asOneEdit`).
        private var heldBatch: [DocumentEditOp]?

        /// Runs `body`, whose storage edits reach the core as one batch, so one step.
        func asOneEdit(_ intent: EditorEditIntent, _ body: () -> Void) {
            guard heldBatch == nil, let document, let textView else {
                return withEditIntent(intent, perform: body)
            }
            heldBatch = []
            var sent = false
            withEditIntent(intent) {
                body()
                let ops = heldBatch ?? []
                heldBatch = nil
                sent = !ops.isEmpty
                emit(ops, document: document, selection: EditorEditSelection(
                    before: editSelectionBefore ?? textView.selectedRange(),
                    after: textView.selectedRange()))
            }
            if sent { inkChanged() }
        }

        /// The composition the IME gate is tracking: where it started,
        /// what stood there before it began, and how long the span has
        /// grown to. Nil while no composition is in flight.
        struct CompositionSpan {
            let location: Int
            let baseline: String
            let selectionBefore: NSRange
            var spanLength: Int
        }

        var imeComposition: CompositionSpan?

        /// True while `setMarkedText` is replacing the storage. The
        /// view's own marked-range bookkeeping may update before or
        /// after that edit, so `hasMarkedText()` alone cannot tell a
        /// mid-composition replacement from a resolving one; this flag
        /// can.
        var markedTextInFlight = false

        /// A test hook: every emitted batch, after it was applied.
        /// Nil outside tests.
        var onEmit: (([DocumentEditOp]) -> Void)?

        /// Every character edit, before it is emitted: a U+FFFC no object carries (⌃Y after ⌃K
        /// over one, a board's text, a service) leaves the page or note, never the file (Law 0001).
        public func textStorage(
            _ storage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), document != nil, file == nil,
                  !model.isApplyingProjection, !markedTextInFlight,
                  !(textView?.hasMarkedText() ?? false)
            else { return }
            let stray = Self.strayObjectCharacters(
                in: storage, editedRange, fromBoard: boardReadDepth > 0)
            for range in stray.reversed() {
                storage.replaceCharacters(in: range, with: "")
            }
        }

        /// How deep the view is in reading a board's text, which never carries an object.
        private var boardReadDepth = 0

        /// Runs `read`, a paste, a drop or a service's answer, as a board's text landing.
        func readingBoard<Result>(_ read: () -> Result) -> Result {
            boardReadDepth += 1
            defer { boardReadDepth -= 1 }
            return read()
        }

        /// The emission point: every character edit the storage
        /// processed becomes one replace-shaped batch. Attribute-only
        /// passes (restyle) carry no `.editedCharacters` and emit
        /// nothing; projection writes are suppressed by the model's
        /// guard; marked text is gated below so an abandoned
        /// composition leaves zero ops behind (the ADR forbids phantom
        /// ops).
        public func textStorage(
            _ storage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            // Bumped before every guard below, projection writes and
            // compositions included, because this counter answers one
            // question only: has anything at all changed since the walk
            // that filled the classification cache. An edit this method
            // declines to emit still moves the page under that reading.
            generation &+= 1
            structuralStyleNeedsRebuild = true
            if nameEditor?.isOpen == true || noteEditor?.isOpen == true {
                // On the next turn: the object may have moved or gone, and its field or note follows.
                DispatchQueue.main.async { [weak self] in
                    self?.followNaming()
                    self?.followNote()
                }
            }
            // Display-only inferred labels belong to the old character
            // projection and cannot survive a projection rewrite.
            clearFenceLanguages()
            abandonAutomaticConversionForEditorChange()
            if model.isApplyingProjection {
                let changedGeneration = generation
                let changedDocument = document
                DispatchQueue.main.async { [weak self, weak storage] in
                    guard let self, let storage,
                          self.structuralStyleNeedsRebuild,
                          self.generation == changedGeneration,
                          self.document == changedDocument,
                          self.textView?.textStorage === storage
                    else { return }
                    self.restyle()
                }
                return
            }
            landRemovalWatch()
            guard let document else { return }
            if markedTextInFlight || (textView?.hasMarkedText() ?? false) {
                // Composition in flight: the span grows and shrinks
                // with each marked replacement, and nothing crosses the
                // seam until it resolves.
                imeComposition?.spanLength += delta
                return
            }
            if imeComposition != nil {
                // This edit resolved the composition (a commit's final
                // replacement, or the removal a cancel performs).
                imeComposition?.spanLength += delta
                finishComposition(in: storage, document: document)
                return
            }
            let ops = Self.editOps(
                storage: storage,
                editedRange: editedRange,
                changeInLength: delta
            )
            if heldBatch != nil {
                heldBatch?.append(contentsOf: ops)
                return
            }
            let deletedLength = max(0, editedRange.length - delta)
            let selection = EditorEditSelection(
                before: editSelectionBefore
                    ?? NSRange(location: editedRange.location, length: deletedLength),
                after: editSelectionAfter
                    ?? NSRange(location: NSMaxRange(editedRange), length: 0)
            )
            emit(ops, document: document, selection: selection)
        }

        /// A composition is starting: remember what the span it will
        /// replace held, so its end can be diffed against a truth
        /// rather than replayed edit by edit.
        func beginComposition(over range: NSRange, in storage: NSTextStorage) {
            invalidateOrdinaryPasteMeasurement()
            guard imeComposition == nil else { return }
            let clamped = Self.clamped(range, to: storage.length)
            imeComposition = CompositionSpan(
                location: clamped.location,
                baseline: (storage.string as NSString).substring(with: clamped),
                selectionBefore: clamped,
                spanLength: clamped.length
            )
        }

        /// The composition resolved: diff the accumulated span against
        /// its pre-composition baseline. Equal means an abandoned
        /// composition (Esc), and an abandoned composition must
        /// produce zero ops; different commits the minimal replace.
        func finishComposition(in storage: NSTextStorage, document: InkDocument) {
            guard let ime = imeComposition else { return }
            imeComposition = nil
            // A cancel settles here with no didChangeText to follow it.
            defer { settleRemovalWatch() }
            let text = storage.string as NSString
            let span = NSRange(location: ime.location, length: max(0, ime.spanLength))
            guard NSMaxRange(span) <= text.length else {
                // The span outran the storage, so there is nothing trustworthy to
                // diff, so fall back to the recovery mirror.
                switch document {
                case .sheet(let sheet):
                    model.syncDocument(sheet: sheet, runs: Self.runs(of: storage))
                case .note:
                    restateNoteNextTurn()
                }
                return
            }
            let final = text.substring(with: span)
            guard final != ime.baseline else { return }
            let after = textView?.selectedRange() ?? NSRange(
                location: NSMaxRange(span),
                length: 0
            )
            emit(
                Self.minimalReplace(at: ime.location, old: ime.baseline, new: final),
                document: document,
                selection: EditorEditSelection(before: ime.selectionBefore, after: after)
            )
        }

        /// If a composition is still tracked once the view unmarks
        /// (a cancel that never produced a resolving character edit),
        /// settle it now against the storage as it stands.
        func finishCompositionIfPending() {
            guard imeComposition != nil,
                  let textView, !textView.hasMarkedText(),
                  let storage = textView.textStorage,
                  let document
            else { return }
            finishComposition(in: storage, document: document)
        }

        /// The outermost TextKit action currently producing storage edits.
        /// Nested calls keep the outer action: list continuation calls
        /// `insertText`, for example, but remains automation rather than typing.
        private var editIntentInFlight: EditorEditIntent?
        private var editIntentDepth = 0
        private var editSelectionBefore: NSRange?
        private var editSelectionAfter: NSRange?

        var selectionChangeIsIncidental: Bool {
            editIntentDepth > 0 || model.isApplyingProjection
        }

        @discardableResult
        func withEditIntent<Result>(
            _ intent: EditorEditIntent,
            afterSelection: NSRange? = nil,
            perform body: () -> Result
        ) -> Result {
            let outermost = editIntentDepth == 0
            if outermost {
                editIntentInFlight = intent
                let selected = textView?.selectedRange()
                editSelectionBefore = selected?.location == NSNotFound ? nil : selected
                editSelectionAfter = afterSelection
            } else if editSelectionAfter == nil, let afterSelection {
                editSelectionAfter = afterSelection
            }
            editIntentDepth += 1
            defer {
                editIntentDepth -= 1
                if outermost {
                    editIntentInFlight = nil
                    editSelectionBefore = nil
                    editSelectionAfter = nil
                }
            }
            return body()
        }

        /// Encode and send one batch. Empty batches never cross: a
        /// no-op is not an operation.
        private func emit(
            _ ops: [DocumentEditOp],
            document: InkDocument,
            selection: EditorEditSelection
        ) {
            guard !ops.isEmpty, let json = DocumentEditOp.wireJSON(ops) else { return }
            let intent = editIntentInFlight ?? Self.inferredIntent(for: ops)
            let accepted = model.applyOps(
                to: document, json: json, intent: intent, selection: selection)
            // The model restates a refused page or file; a note is restated here.
            if !accepted, case .note = document { restateNoteNextTurn() }
            onEmit?(ops)
        }

        private static func inferredIntent(for ops: [DocumentEditOp]) -> EditorEditIntent {
            let hasInsert = ops.contains {
                if case .ins = $0 { return true }
                if case .chip = $0 { return true }
                return false
            }
            let hasDelete = ops.contains {
                if case .del = $0 { return true }
                return false
            }
            switch (hasInsert, hasDelete) {
            case (true, false): return .typing
            case (false, true): return .deletion
            default: return .replacement
            }
        }

        /// One storage edit as a replace-shaped batch: the deleted
        /// length is what the edited range grew from
        /// (`range.length - changeInLength`), deleted at the range's
        /// location; the inserted text is read back out of the storage
        /// and split into ink and chip ops by walking its attachments.
        /// All positions are UTF-16 code units, which is what `NSRange`
        /// measures in.
        static func editOps(
            storage: NSTextStorage, editedRange: NSRange, changeInLength delta: Int
        ) -> [DocumentEditOp] {
            var ops: [DocumentEditOp] = []
            let deletedLen = editedRange.length - delta
            if deletedLen > 0 {
                ops.append(.del(at: editedRange.location, len: deletedLen))
            }
            guard editedRange.length > 0 else { return ops }
            let text = storage.string as NSString
            var pos = editedRange.location
            storage.enumerateAttribute(.attachment, in: editedRange) { value, range, _ in
                if let chip = value as? ChipAttachment {
                    // One position per character, so a face standing twice is sent twice.
                    for offset in 0..<range.length {
                        ops.append(.chip(at: pos + offset, id: chip.info.chipId))
                    }
                } else if range.length > 0 {
                    ops.append(.ins(at: pos, text: text.substring(with: range)))
                }
                pos += range.length
            }
            return ops
        }

        /// The smallest single replace that turns `old` into `new` at
        /// `location`: common UTF-16 prefix and suffix trimmed, with
        /// the boundaries nudged off surrogate-pair interiors so the
        /// core is never asked to cut an astral character in half.
        nonisolated static func minimalReplace(
            at location: Int, old: String, new: String
        ) -> [DocumentEditOp] {
            let oldUnits = Array(old.utf16)
            let newUnits = Array(new.utf16)
            var prefix = 0
            while prefix < oldUnits.count, prefix < newUnits.count,
                  oldUnits[prefix] == newUnits[prefix] {
                prefix += 1
            }
            // A prefix ending after a high surrogate would split the
            // pair it opens; step back onto the boundary.
            if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) {
                prefix -= 1
            }
            var suffix = 0
            while suffix < oldUnits.count - prefix, suffix < newUnits.count - prefix,
                  oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
                suffix += 1
            }
            // A suffix beginning on a low surrogate would split the
            // pair it closes; give the unit back.
            if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) {
                suffix -= 1
            }
            var ops: [DocumentEditOp] = []
            let deleted = oldUnits.count - prefix - suffix
            if deleted > 0 {
                ops.append(.del(at: location + prefix, len: deleted))
            }
            let inserted = newUnits[prefix..<(newUnits.count - suffix)]
            if !inserted.isEmpty {
                ops.append(.ins(
                    at: location + prefix,
                    text: String(decoding: inserted, as: UTF16.self)
                ))
            }
            return ops
        }

        /// The document as runs, in order: contiguous ink between chips.
        static func runs(of storage: NSTextStorage) -> [DocumentRun] {
            var runs: [DocumentRun] = []
            let text = storage.string as NSString
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
                if let chip = value as? ChipAttachment {
                    runs.append(contentsOf: repeatElement(.chip(chip.info.chipId), count: range.length))
                } else if range.length > 0 {
                    runs.append(.ink(text.substring(with: range)))
                }
            }
            return runs
        }

        // MARK: The seal gestures

        /// What both seal chords say over a selection that already
        /// holds a chip (D-08). A chip leaves the page only by an act
        /// aimed at the chip; a seal is not one, so the gesture refuses
        /// here, and the core refuses it again on its own.
        static let alreadySealedLine = "already sealed · a chip has no plaintext to seal"

        /// ⇧⌘V: the core reads the pasteboard itself, deletes the
        /// selection captured here, and stands the chip in its place,
        /// one atomic locked call. This process never sees the pasted
        /// bytes.
        func sealedPaste() {
            guard sealsHere, let textView, let storage = textView.textStorage else { return }
            // The offer's button is not a chord, so it asks the holder here (Law 0007, keys row).
            guard textView.answersChords else {
                model.flash(PageModel.sealWaitsLine)
                return
            }
            // Captured at gesture time and passed whole. The seal call
            // is synchronous on the main actor from here through the C
            // seam, so no event can move the caret between this capture
            // and the core's replace: the range is still true when the
            // core deletes it.
            let range = textView.selectedRange()
            guard Self.isValid(range, for: storage.length) else { return }
            // Refused before the board is read: a take that ended in a
            // refusal would have cleared nothing, but it would have
            // read the board for no reason.
            if Self.containsChip(storage, in: range) {
                model.flash(Self.alreadySealedLine)
                return
            }
            guard let chip = model.sealPasteboard(replacing: range) else { return }
            placeChipFace(chip, replacing: range)
        }

        /// A drop from outside: the core reads the drag pasteboard
        /// itself while the session's data is still on it, and replaces
        /// the drop point (a zero-length range) with the sentinel in
        /// the same locked call.
        func sealDrop(at characterIndex: Int) -> Bool {
            guard sealsHere, let textView else { return false }
            textView.setSelectedRange(NSRange(location: characterIndex, length: 0))
            // Same synchronicity as the sealed paste: nothing runs
            // between this capture and the core's replace.
            let range = NSRange(location: characterIndex, length: 0)
            guard let chip = model.sealDrag(replacing: range) else { return false }
            placeChipFace(chip, replacing: range)
            return true
        }

        /// ⌘↩: seal the selection, or the current line if it holds
        /// content. A line already holding a chip refuses with an
        /// explanation; an empty line does nothing (docs/spec/04).
        func sealSelectionOrLine() {
            guard sealsHere, let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            var range = textView.selectedRange()
            guard Self.isValid(range, for: storage.length) else { return }
            if range.length == 0 {
                range = text.lineRange(for: range)
                // Seal the line's content, not its terminator.
                while range.length > 0 {
                    let last = text.character(at: NSMaxRange(range) - 1)
                    guard last == 0x0A || last == 0x0D else { break }
                    range.length -= 1
                }
            }
            guard range.length > 0 else { return }
            if Self.containsChip(storage, in: range) {
                model.flash(Self.alreadySealedLine)
                return
            }
            let ink = text.substring(with: range)
            guard !ink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // The core deletes the range and stands the sentinel in
            // one atomic call; a non-empty selection is deleted
            // core-side, not by a shell edit. Synchronous on the main
            // actor end to end, so the caret cannot move mid-call and
            // the captured range stays true.
            guard let chip = model.sealText(ink, replacing: range) else { return }
            placeChipFace(chip, replacing: range)
        }

        /// Update the projection after a seal: the core already
        /// replaced the range with the sentinel, so the storage
        /// mirrors that under the emission guard; echoing this write
        /// back as ops would stand the chip twice. Undo dies with it:
        /// sealing is not undoable, and undo never un-seals (doc 06
        /// №5).
        ///
        /// The new object is left selected rather than the caret placed
        /// after it (D-30): the seal is the app's one irreversible
        /// gesture, and the selection is what makes the transformation
        /// visible at the moment it happens.
        private func placeChipFace(_ chip: ChipInfo, replacing range: NSRange) {
            guard let textView, let storage = textView.textStorage else { return }
            model.applyingProjection {
                if textView.shouldChangeText(in: range, replacementString: nil) {
                    storage.replaceCharacters(in: range, with: Self.chipString(chip))
                    textView.didChangeText()
                }
            }
            textView.setSelectedRange(NSRange(location: range.location, length: 1))
        }

        static func isValid(_ range: NSRange, for length: Int) -> Bool {
            guard length >= 0,
                  range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location <= length
            else { return false }
            return range.length <= length - range.location
        }

        static func containsChip(_ storage: NSTextStorage, in range: NSRange) -> Bool {
            guard isValid(range, for: storage.length) else { return false }
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value is ChipAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        /// The chip ids of the objects standing in `range`.
        static func chipIDs(_ storage: NSTextStorage, in range: NSRange) -> Set<UInt64> {
            guard isValid(range, for: storage.length) else { return [] }
            var ids = Set<UInt64>()
            storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
                if let chip = value as? ChipAttachment { ids.insert(chip.info.chipId) }
            }
            return ids
        }

        /// The stretches of ink in `range` between its objects, in order, empty ones kept.
        static func inkStretches(_ storage: NSTextStorage, in range: NSRange) -> [NSRange] {
            guard isValid(range, for: storage.length) else { return [] }
            var stretches: [NSRange] = []
            var start = range.location
            storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
                guard value is ChipAttachment else { return }
                for index in run.location..<NSMaxRange(run) {
                    stretches.append(NSRange(location: start, length: index - start))
                    start = index + 1
                }
            }
            stretches.append(NSRange(location: start, length: NSMaxRange(range) - start))
            return stretches
        }

        /// AppKit's rewrite of `range` as `replacement`, stretch by stretch of ink: nil unless
        /// it keeps one U+FFFC for each object and writes no ink where none stood.
        static func inkRewrites(
            _ storage: NSTextStorage, of range: NSRange, as replacement: String
        ) -> [(range: NSRange, text: String)]? {
            let stretches = inkStretches(storage, in: range)
            let texts = replacement.components(separatedBy: objectCharacter)
            guard !stretches.isEmpty, texts.count == stretches.count else { return nil }
            let rewrites = zip(stretches, texts).map { (range: $0, text: $1) }
            if rewrites.contains(where: { $0.range.length == 0 && !$0.text.isEmpty }) { return nil }
            return rewrites
        }

        static func chipString(_ chip: ChipInfo) -> NSAttributedString {
            NSAttributedString(attachment: ChipAttachment(info: chip))
        }

        // MARK: Chip actions: a click selects, a secondary click offers actions, never content

        /// One item of the object's menu.
        enum ChipMenuItem: Equatable {
            case copyName
            case copyDecrypted
            case copyNameValue
            case createLink
            case name
            case rename
            case note
            case editNote
            case remove

            /// Title case; no ellipsis on Name and Rename, which edit in
            /// place, and one noun for the object (ADR-0055).
            var title: String {
                switch self {
                case .copyName: "Copy Name"
                case .copyDecrypted: "Copy Decrypted Contents"
                case .copyNameValue: "Copy Name=Value, Decrypted"
                case .createLink: "Create One-Time Link…"
                case .name: "Name"
                case .rename: "Rename"
                case .note: "Note…"
                case .editNote: "Edit Note…"
                case .remove: "Remove Sealed Content"
                }
            }
        }

        /// The object's menu in D-41's order as Law 0001's presentation invariants extend it, nil
        /// marking a separator: the copies and the link, the object's own
        /// words, then the removal set apart.
        static func chipMenuItems(named: Bool, hasNote: Bool, kind: String) -> [ChipMenuItem?] {
            (named ? [.copyName] : []) + [.copyDecrypted]
                + (named && SealedBlockLayout.copiesNameValue(kind: kind) ? [.copyNameValue] : [])
                + [.createLink, nil, named ? .rename : .name, hasNote ? .editNote : .note, nil, .remove]
        }

        /// The menu's titles, pinned by a test rather than read off a screen.
        static func chipMenuTitles(named: Bool, hasNote: Bool, kind: String) -> [String?] {
            chipMenuItems(named: named, hasNote: hasNote, kind: kind).map { $0?.title }
        }

        /// A plain click on a chip selects the whole object and never
        /// places a caret inside it (D-28). It does not also perform an
        /// action or open a menu: the explicit actions glyph, secondary
        /// click, and Return or Space on the selected object provide the
        /// menu routes. Actions, never content.
        public func textView(
            _ view: NSTextView,
            clickedOn cell: NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            guard cell is SealedBlockCell else { return }
            view.setSelectedRange(NSRange(location: charIndex, length: 1))
        }

        /// The object's menu, opened at `point`: the same items every
        /// explicit route builds, so the glyph, secondary click, and
        /// Return or Space over the selected block cannot drift apart.
        func openChipMenu(at charIndex: Int, from point: NSPoint, in view: NSTextView) {
            guard let menu = chipMenu(at: charIndex) else { return }
            menu.popUp(positioning: nil, at: point, in: view)
        }

        /// Build the sealed object's context menu once for both AppKit's
        /// menu query and the explicit routes that pop it up directly.
        func chipMenu(at charIndex: Int) -> NSMenu? {
            let menu = NSMenu()
            // The object's menu is its own items and nothing the text
            // system would append to a text view's menu (D-41).
            menu.allowsContextMenuPlugIns = false
            appendChipItems(to: menu, at: charIndex)
            return menu.items.isEmpty ? nil : menu
        }

        /// The character index of the chip under `point` (in the text
        /// view's coordinates), or nil when the point is over ink or
        /// past the end of a line. The nearest-glyph answer the layout
        /// manager gives is checked against the glyph's own bounds, so
        /// a click in the margin beside a chip is not a click on it.
        func chipIndex(at point: NSPoint, in view: NSTextView) -> Int? {
            guard let layoutManager = view.layoutManager,
                  let container = view.textContainer,
                  let storage = view.textStorage,
                  storage.length > 0
            else { return nil }
            let origin = view.textContainerOrigin
            let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(
                for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            guard index < storage.length,
                  storage.attribute(.attachment, at: index, effectiveRange: nil) is ChipAttachment
            else { return nil }
            if let inkView = view as? InkTextView {
                guard let frame = inkView.chipFrame(at: index), frame.contains(point) else { return nil }
            } else {
                let bounds = layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                guard bounds.contains(local) else { return nil }
            }
            return index
        }

        /// The chip standing at `charIndex` in the mounted page, if one does.
        func chipAttachment(at charIndex: Int) -> ChipAttachment? {
            guard let storage = textView?.textStorage, charIndex >= 0, charIndex < storage.length
            else { return nil }
            return storage.attribute(.attachment, at: charIndex, effectiveRange: nil)
                as? ChipAttachment
        }

        /// The chip's actions, appended to `menu` for the chip standing
        /// at `charIndex` in `chipMenuItems`' order. The removal deletes the
        /// sentinel whole; the two press removal is the keyboard's.
        func appendChipItems(to menu: NSMenu, at charIndex: Int) {
            guard let attachment = chipAttachment(at: charIndex) else { return }
            for entry in Self.chipMenuItems(
                named: attachment.info.name != nil, hasNote: attachment.info.hasNote,
                kind: attachment.info.kind)
            {
                guard let entry else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.target = self
                // Each item carries the object's place rather than its id,
                // so its action reads the block's own face off the storage.
                item.representedObject = charIndex as NSNumber
                switch entry {
                case .copyName:
                    item.action = #selector(copyChipName(_:))
                case .copyDecrypted:
                    item.action = #selector(copyOutChip(_:))
                    // The chord beside the verb is the keymap's, the way
                    // every tooltip names its chord: a keymap that moved
                    // `chip::CopyDecrypted` moves this, and one that
                    // unbound it leaves the verb alone. Display only; the
                    // page's text view dispatches the chord itself, so the
                    // menu item advertises and never claims.
                    if let chord = model.keymap.hintKeystroke(for: .chipCopyDecrypted) {
                        item.keyEquivalent = chord.menuKeyEquivalent
                        item.keyEquivalentModifierMask = chord.menuModifierMask
                    }
                case .copyNameValue:
                    item.action = #selector(copyChipNameValue(_:))
                case .createLink:
                    item.action = #selector(concealChip(_:))
                    item.representedObject = attachment.info.chipId as NSNumber
                case .name, .rename:
                    item.action = #selector(nameChip(_:))
                case .note, .editNote:
                    item.action = #selector(openChipNote(_:))
                case .remove:
                    // The separator and verb carry the destructive meaning;
                    // leave menu text styling to AppKit.
                    item.action = #selector(removeChip(_:))
                }
                menu.addItem(item)
            }
        }

        /// Copy the page's selected ranges by the core's fragment (ADR-0045 point 2).
        @discardableResult
        func copySelection() -> Bool {
            guard !writesNote, let textView, let sheet = currentSheet, !sheet.isFileID
            else { return false }
            let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            return model.copySelection(ranges, sheet: sheet)
        }

        /// The page's selection as the copy composes it, for a service or another
        /// requester; nil on a note or a file, which AppKit writes.
        func composeSelection() -> PageModel.SelectionComposition? {
            guard !writesNote, let textView, let sheet = currentSheet, !sheet.isFileID
            else { return nil }
            let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            return model.composeSelection(ranges, sheet: sheet)
        }

        /// Whether AppKit may give out the text this surface shows, which no core route
        /// sees (Law 0001, expiry row): the note's page or the page is asked; a file always may.
        func givesOutShownText() -> Bool {
            guard let sheet = writesNote ? noteHost?.sheet : currentSheet else { return !writesNote }
            return model.givesOut(sheet: sheet)
        }

        /// Cut the page's selection through the core (ADR-0046 point 3).
        @discardableResult
        func cutSelection() -> PageModel.CutOutcome {
            guard !writesNote, let textView, textView.isEditable,
                  let sheet = currentSheet, !sheet.isFileID
            else { return .refused }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            let outcome = model.cutSelection(ranges, sheet: sheet)
            if case .cut(let selecting) = outcome { settleRewrite(selecting: selecting) }
            return outcome
        }

        /// Place the clipboard slot's cut at the caret (sealed row spec); stands
        /// aside while a name or note holds the keys (Law 0007, keys row).
        @discardableResult
        func placeActiveCut() -> Bool {
            guard !writesNote, let textView, textView.isEditable,
                  let sheet = currentSheet, !sheet.isFileID
            else { return false }
            guard textView.answersChords else {
                model.flash(PageModel.placeWaitsLine)
                return false
            }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            let ranges = textView.selectedRanges.map(\.rangeValue)
            let replacesObject = rangesHoldObject(ranges)
            guard let placed = model.placeActiveCut(sheet: sheet, ranges: ranges) else { return false }
            settleRewrite(selecting: NSRange(location: NSMaxRange(placed.range), length: 0))
            if replacesObject { noteRemoval() }
            return true
        }

        /// Paste the board's fragment over the selection through the core (ADR-0045);
        /// false where AppKit's paste should run: no fragment, a note or a file.
        func pasteFragment() -> Bool {
            guard !writesNote, let textView, let sheet = currentSheet, !sheet.isFileID,
                  SealedFragment.item(on: model.ambientPasteboard) != nil
            else { return false }
            // Answered here on a read only page, so AppKit's paste is not asked to place its public text.
            guard textView.isEditable else { return true }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            let ranges = textView.selectedRanges.map(\.rangeValue)
            let replacesObject = rangesHoldObject(ranges)
            let outcome = model.pasteFragment(
                from: model.ambientPasteboard, sheet: sheet, ranges: ranges)
            switch outcome {
            case .ordinary:
                return false
            case .refused:
                return true
            case .placed(let placed):
                settleRewrite(selecting: NSRange(location: NSMaxRange(placed.range), length: 0))
                // The removal line, with its Undo, follows any line the paste flashed.
                if replacesObject { noteRemoval() }
                return true
            }
        }

        // MARK: Drags of the page's selection (Law 0001, drag and ⌥ drag rows)

        /// The page's own drag, from its start until its session ends.
        private struct PageDrag {
            let range: NSRange
            let document: InkDocument
            let generation: Int
        }

        private var pageDrag: PageDrag?

        /// Whether a drag of this page's selection is under way.
        var dragsPageSelection: Bool { pageDrag != nil }

        /// What a drag of the page's selection carries.
        enum DragStart {
            /// The core's copy fragment, in the one item the drag writes.
            case fragment(NSPasteboardItem)
            /// Not a page, or several stretches of ink: AppKit drags as it always has.
            case ordinary
            /// Nothing is dragged.
            case refused
        }

        /// Start a drag of the page's selection as the core's copy fragment, so
        /// another app reads only ink and placeholders (ADR-0045 point 2).
        func beginPageDrag() -> DragStart {
            pageDrag = nil
            guard !writesNote, let textView, let storage = textView.textStorage,
                  let sheet = currentSheet, !sheet.isFileID, let document
            else { return .ordinary }
            guard textView.answersChords else { return .refused }
            let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            guard ranges.count == 1 else {
                guard ranges.contains(where: { Self.containsChip(storage, in: $0) }) else {
                    return .ordinary
                }
                model.flash(PageModel.severalStretchesDragLine)
                return .refused
            }
            guard let item = model.dragFragment(sheet: sheet, range: ranges[0])?.pasteboardItem()
            else { return .refused }
            pageDrag = PageDrag(range: ranges[0], document: document, generation: generation)
            return .fragment(item)
        }

        /// A drag that starts on an object drags the selection holding it, or the
        /// object alone, by the page's own drag rather than AppKit's attachment drag.
        public func textView(
            _ view: NSTextView, draggedCell cell: any NSTextAttachmentCellProtocol,
            in rect: NSRect, event: NSEvent, at charIndex: Int
        ) {
            guard let textView = view as? InkTextView, textView === self.textView else { return }
            textView.beginMoveDrag(chipAt: charIndex, event: event)
        }

        /// The page's own drag, while the page still reads as it did when the drag began.
        private var standingPageDrag: PageDrag? {
            guard let drag = pageDrag, drag.document == document, drag.generation == generation
            else { return nil }
            return drag
        }

        /// What the page's own drag would do dropped at `index`: a move inside its own
        /// range is no drop, and a refused page takes none.
        func pageDragOperation(at index: Int, offered mask: NSDragOperation) -> NSDragOperation {
            guard let drag = standingPageDrag, textView?.isEditable == true else { return [] }
            let operation = InkTextView.pageDropOperation(offered: mask)
            let inside = drag.range.location...NSMaxRange(drag.range)
            return operation == .move && inside.contains(index) ? [] : operation
        }

        /// The page's own drag dropped on it at `index`: moved, or cloned for ⌥,
        /// through the core as one step; stands aside while a field holds the keys.
        func dropPageDrag(at index: Int, offered mask: NSDragOperation) -> Bool {
            let operation = pageDragOperation(at: index, offered: mask)
            guard operation != [], let drag = standingPageDrag, let textView,
                  let sheet = currentSheet, admitsDrop(from: textView)
            else { return false }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            guard let placed = model.dropRange(
                drag.range, sheet: sheet, at: index, cloning: operation == .copy)
            else { return false }
            settleRewrite(selecting: placed.range)
            return true
        }

        /// Whether a fragment from another page or app can drop here: an editable page.
        var takesFragmentDrop: Bool {
            guard !writesNote, let textView, textView.isEditable, let sheet = currentSheet
            else { return false }
            return !sheet.isFileID
        }

        /// Whether a drop from `source` may land here: not while a field or note other
        /// than the drag's own source holds the keys (Law 0007, keys row), and the line says why.
        func admitsDrop(from source: NSView?) -> Bool {
            guard let textView else { return false }
            guard textView.yieldsKeys(toAnyBut: source) else { return true }
            model.flash(PageModel.dropWaitsLine)
            return false
        }

        /// A fragment dragged from another page or app, dropped at `index`: pasted
        /// through the core as ⌘V pastes it, never sealed as its public text.
        func dropFragment(from board: NSPasteboard, at index: Int, source: NSView? = nil) -> Bool {
            guard takesFragmentDrop, let textView, let sheet = currentSheet,
                  admitsDrop(from: source)
            else { return false }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            guard case .placed(let placed) = model.pasteFragment(
                from: board, sheet: sheet, ranges: [NSRange(location: index, length: 0)])
            else { return false }
            settleRewrite(selecting: placed.range)
            return true
        }

        /// The page and range of another page's drag that a drop here moves through the
        /// core (Law 0001, drag row): a move, while that drag stands, between two pages.
        func pageDragToMove(
            from source: Coordinator?, offered mask: NSDragOperation
        ) -> (sheet: UInt64, range: NSRange)? {
            guard InkTextView.pageDropOperation(offered: mask) == .move, takesFragmentDrop,
                  let source, source !== self, source.model === model,
                  let drag = source.standingPageDrag, case .sheet(let from) = drag.document,
                  let sheet = currentSheet, from != sheet
            else { return nil }
            return (from, drag.range)
        }

        /// Another page's drag dropped here at `index` as a move: the core takes its range
        /// off that page and stands it here keeping every object, and both pages restate.
        func dropMovedPageDrag(
            from source: Coordinator, at index: Int, offered mask: NSDragOperation
        ) -> Bool {
            guard let drag = pageDragToMove(from: source, offered: mask), let textView,
                  let sheet = currentSheet, admitsDrop(from: source.textView)
            else { return false }
            InkEditorView.discardComposition(in: textView)
            invalidateOrdinaryPasteMeasurement()
            guard let placed = model.dropRange(drag.range, sheet: drag.sheet, onto: sheet, at: index)
            else { return false }
            source.invalidateOrdinaryPasteMeasurement()
            source.settleRewrite(selecting: NSRange(location: drag.range.location, length: 0))
            settleRewrite(selecting: placed.range)
            return true
        }

        /// The page's drag ended. A move between pages went through the core at the drop
        /// (Law 0001, drag row), so the end removes nothing here, whatever the destination answered.
        func endPageDrag() {
            pageDrag = nil
        }

        // MARK: The decrypted drag from a block's handle (ADR-0045 point 5; Law 0001, decrypted drag row)

        /// The decrypted drag under way, held until its session ends.
        private(set) var decryptedDrag: DecryptedDrag?

        /// Start the decrypted drag of the object at `index`: its source and its one item,
        /// whose payload the core writes when a destination asks. Nil while a field holds the keys.
        func beginDecryptedDrag(at index: Int) -> (source: DecryptedDrag, item: NSPasteboardItem)? {
            guard !writesNote, let textView, let attachment = chipAttachment(at: index),
                  let type = DecryptedDrag.pasteboardType(forKind: attachment.info.kind)
            else { return nil }
            guard textView.answersChords else {
                model.flash(PageModel.decryptedDragWaitsLine)
                return nil
            }
            let chip = attachment.info.chipId
            let source = DecryptedDrag(chip: chip, type: type) { [weak model] board, item, type in
                model?.provideDecryptedDrag(chip: chip, pasteboard: board, item: item, type: type)
                    ?? false
            }
            guard let item = source.pasteboardItem() else { return nil }
            source.onEnd = { [weak self, weak source] in
                if let self, self.decryptedDrag === source { self.decryptedDrag = nil }
            }
            decryptedDrag = source
            return (source, item)
        }

        /// After the core rewrote the page under the editor: lay the styles back
        /// down and stand the selection, as a step does.
        func settleRewrite(selecting selection: NSRange) {
            guard let textView else { return }
            restyle()
            let clamped = Self.clamped(selection, to: textView.textStorage?.length ?? 0)
            textView.setSelectedRange(clamped)
            textView.scrollRangeToVisible(clamped)
            noteHost?.inkDidChange()
        }

        /// The chip standing at the selection, when the selection is
        /// exactly one chip and nothing else: the one shape the copy
        /// decrypted chord acts on. Nil over ink, over a caret, or over
        /// a selection that mixes ink and objects, which is what keeps
        /// ⇧⌘C from ever reaching a payload nobody pointed at.
        var selectedChipIndex: Int? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let range = textView.selectedRange()
            guard range.length == 1, range.location < storage.length,
                  storage.attribute(.attachment, at: range.location, effectiveRange: nil)
                    is ChipAttachment
            else { return nil }
            return range.location
        }

        /// Copy the chip at `index` back out through the core, and say
        /// so with the block's own size class in the line.
        @discardableResult
        func copyOutChip(at index: Int) -> Bool {
            guard let attachment = chipAttachment(at: index) else { return false }
            return model.copyOutChip(
                attachment.info.chipId,
                size: SealedBlockCell.displayedSizeClass(attachment.info.sizeLabel)
            )
        }

        /// Copy the name of the chip at `index`, which is ambient ink of this page.
        @discardableResult
        func copyName(at index: Int) -> Bool {
            guard let sheet = currentSheet, let name = chipAttachment(at: index)?.info.name
            else { return false }
            return model.copyChipName(name, onPage: sheet)
        }

        /// Copy `NAME=value` for the chip at `index` by copy decrypted's
        /// route; the core composes and writes it.
        @discardableResult
        func copyNameValue(at index: Int) -> Bool {
            guard let attachment = chipAttachment(at: index), attachment.info.name != nil
            else { return false }
            return model.copyChipNameValue(
                attachment.info.chipId,
                size: SealedBlockCell.displayedSizeClass(attachment.info.sizeLabel)
            )
        }

        /// A named row's zone, clicked: each zone takes its own route.
        @discardableResult
        func copy(_ zone: SealedBlockLayout.Zone, chipAt index: Int) -> Bool {
            switch zone {
            case .name: copyName(at: index)
            case .equals: copyNameValue(at: index)
            case .value: copyOutChip(at: index)
            }
        }

        // MARK: Links — ⌘-click opens, a plain click edits (ADR-0023)

        /// Every click on a `.link` range lands here, and the answer is
        /// always "handled", because the default answer — open on any
        /// click — makes the URL's own text uneditable by mouse. With ⌘
        /// held the click is an aimed gesture and the link opens through
        /// `openLink`, as the text menu's Open Link does; without it the
        /// click is editing, so the caret is placed where the click fell,
        /// exactly as on any other ink.
        public func textView(
            _ view: NSTextView, clickedOnLink link: Any, at charIndex: Int
        ) -> Bool {
            let event = NSApp?.currentEvent
            guard event?.modifierFlags.contains(.command) == true else {
                // The caret goes to the insertion point nearest the
                // click, not merely to the clicked character's start;
                // the char index is the fallback when no event is in
                // flight to measure against.
                if let event {
                    let point = view.convert(event.locationInWindow, from: nil)
                    view.setSelectedRange(
                        NSRange(location: view.characterIndexForInsertion(at: point), length: 0)
                    )
                } else {
                    view.setSelectedRange(NSRange(location: charIndex, length: 0))
                }
                return true
            }
            openLink(link, from: view)
            return true
        }

        /// Opens a link the person aimed at: a file's at once, a page's or a note's only
        /// once its view may read out, so past the deadline the page settles (Law 0001, expiry row).
        @discardableResult
        func openLink(_ link: Any, from view: NSTextView) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
                  writesFile || (view as? AskingTextView)?.mayReadOut == true
            else { return false }
            model.openURL(url)
            return true
        }

        @objc private func copyOutChip(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            copyOutChip(at: index)
        }

        @objc private func copyChipName(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            copyName(at: index)
        }

        @objc private func copyChipNameValue(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            copyNameValue(at: index)
        }

        @objc private func nameChip(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            beginNaming(at: index)
        }

        @objc private func openChipNote(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            beginNote(at: index)
        }

        // MARK: The note, in a popover over the page (Law 0001)

        /// The popover a sealed object's note is written in, made on first use.
        private(set) var noteEditor: SealedNoteEditor?

        /// Opens the note of the block at `index`, on an editable page.
        func beginNote(at index: Int) {
            guard let textView, textView.isEditable, let sheet = currentSheet, !sheet.isFileID
            else { return }
            keepNaming()
            let editor = noteEditor ?? SealedNoteEditor(model: model)
            noteEditor = editor
            editor.pageView = textView
            editor.open(chipAt: index, sheet: sheet)
        }

        /// Closes an open note when its page goes from under it.
        func closeNote() {
            guard let noteEditor else { return }
            noteEditor.close(returningKeys: noteEditor.holdsKeys)
        }

        /// Stands an open note under its object again after the page moved.
        func followNote() {
            guard let noteEditor, noteEditor.isOpen else { return }
            noteEditor.follow()
        }

        // MARK: A note's own surface, over the note's routes (ADR-0044)

        /// Puts the note of `chip` under this surface, its text from the core;
        /// false, with nothing loaded, where the core refuses the note (Law 0001, expiry row).
        @discardableResult
        func loadNote(chip: UInt64) -> Bool {
            unloadNote()
            guard let text = model.noteText(chip: chip) else { return false }
            noteChip = chip
            showNote(text)
            return true
        }

        /// Takes the note away; its edits are already the core's, and the
        /// surface keeps none of its ink.
        func unloadNote() {
            guard let chip = noteChip else { return }
            // A composition settles on the note it was typed in, as a page swap's does.
            if let textView { InkEditorView.discardComposition(in: textView) }
            invalidateOrdinaryPasteMeasurement()
            noteChip = nil
            noteFenceLanguages = [:]
            fenceRegions = []
            (textView?.layoutManager as? InkLayoutManager)?.fenceRegions = []
            if let storage = textView?.textStorage {
                model.applyingProjection {
                    storage.replaceCharacters(
                        in: NSRange(location: 0, length: storage.length), with: "")
                }
            }
            model.finishNoteEditingGroup(chip: chip)
        }

        /// The note's text from the core, with no edit crossing for it. A refusal
        /// closes the note and settles as the timer would (Law 0001, expiry row).
        private func restateNote() {
            guard let noteChip else { return }
            guard let text = model.noteText(chip: noteChip) else {
                let sheet = noteHost?.sheet
                if let host = noteHost { host.close(returningKeys: host.holdsKeys) } else { unloadNote() }
                model.settleRefusal(sheet: sheet, told: true)
                return
            }
            showNote(text)
        }

        /// Lays `text` down as the note's whole storage, styled as the page's ink.
        private func showNote(_ text: String) {
            guard let storage = textView?.textStorage else { return }
            model.applyingProjection {
                storage.setAttributedString(NSAttributedString(
                    string: text,
                    attributes: [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]))
            }
            restyle()
        }

        /// A refused batch: the core's text again, once the storage has
        /// finished processing the edit it refused.
        private func restateNoteNextTurn() {
            guard let chip = noteChip else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.noteChip == chip else { return }
                self.restateNote()
                self.noteHost?.inkDidChange()
            }
        }

        // MARK: The name, in its seat (Law 0007)

        /// The field a sealed object's name is typed into, made on first use.
        private(set) var nameEditor: SealedNameEditor?

        /// Opens the name field over the block at `index`, on an editable page.
        func beginNaming(at index: Int) {
            guard let textView, let sheet = currentSheet, !sheet.isFileID else { return }
            closeNote()
            let editor = nameEditor ?? SealedNameEditor(model: model)
            nameEditor = editor
            editor.textView = textView
            editor.begin(chipAt: index, sheet: sheet)
        }

        /// Keeps the name a field stands over when its page goes from under it.
        func keepNaming() {
            nameEditor?.keep(returningKeys: nameEditor?.holdsKeys ?? false)
        }

        /// Stands an open name field over its object again after the page moved.
        func followNaming() {
            guard let nameEditor, nameEditor.isOpen else { return }
            nameEditor.follow()
        }

        /// The chip's ↗: open the inline confirmation. The bytes stay
        /// core-side; the conceal moves them core → client → network.
        @objc private func concealChip(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.uint64Value else { return }
            model.beginConceal(.chip(id))
        }

        @objc private func removeChip(_ sender: NSMenuItem) {
            guard let textView, let storage = textView.textStorage,
                  let index = (sender.representedObject as? NSNumber)?.intValue,
                  index < storage.length
            else { return }
            let range = NSRange(location: index, length: 1)
            if textView.shouldChangeText(in: range, replacementString: "") {
                storage.replaceCharacters(in: range, with: "")
                textView.didChangeText() // a del op the core detaches by; the removal watch says so
            }
        }

        /// D-30's first press: a caret beside an object selects it whole and removes nothing.
        func selectObjectBeside(forward: Bool) -> Bool {
            guard !writesNote, let textView, textView.isEditable, !textView.hasMarkedText(),
                  textView.selectedRanges.count == 1
            else { return false }
            let caret = textView.selectedRange()
            guard caret.location != NSNotFound, caret.length == 0 else { return false }
            let index = forward ? caret.location : caret.location - 1
            guard chipAttachment(at: index) != nil else { return false }
            textView.setSelectedRange(NSRange(location: index, length: 1))
            return true
        }

        /// Whether a deletion of the page's selection would take an object with it.
        var selectionHoldsObject: Bool {
            rangesHoldObject(textView?.selectedRanges.map(\.rangeValue) ?? [])
        }

        /// Whether any of `ranges` on the page holds an object.
        func rangesHoldObject(_ ranges: [NSRange]) -> Bool {
            guard !writesNote, let storage = textView?.textStorage else { return false }
            return ranges.contains { Self.containsChip(storage, in: $0) }
        }

        /// The objects held by edits AppKit asked to make on one document: `asked` until
        /// that edit reaches the storage, then `landed`, which the settle judges.
        private struct RemovalWatch {
            let document: InkDocument
            var asked: Set<UInt64> = []
            var landed: Set<UInt64> = []
        }

        private var removalWatch: RemovalWatch?

        /// Every edit AppKit makes on the page asks here first; one over an object
        /// ends the coalescing run, so its removal is a step of its own (D-30).
        public func textView(
            _ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard !writesNote, !model.isApplyingProjection, let document,
                  let storage = textView.textStorage
            else { return true }
            // An in place rewrite is made after AppKit asks, stretch by stretch (`rewritingInk`).
            if heldRewrites != nil, let replacementStrings,
               replacementStrings.count == affectedRanges.count
            {
                heldRewrites?.append(contentsOf: zip(affectedRanges, replacementStrings).map {
                    (range: $0.rangeValue, replacement: $1)
                })
                return false
            }
            // A new ask means the last one's edit landed or never comes, so it judges nothing.
            removalWatch?.asked = []
            let chips = affectedRanges.reduce(into: Set<UInt64>()) {
                $0.formUnion(Self.chipIDs(storage, in: $1.rangeValue))
            }
            guard !chips.isEmpty else { return true }
            model.finishEditingGroup(document, selection: textView.selectedRange())
            var watch = removalWatch.flatMap { $0.document == document ? $0 : nil }
                ?? RemovalWatch(document: document)
            watch.asked = chips
            removalWatch = watch
            return true
        }

        /// The edits an AppKit rewrite asked for while `rewritingInk` runs, none yet made.
        private var heldRewrites: [(range: NSRange, replacement: String)]?

        /// Runs `rewrite`, AppKit's rewrite of the page's selection, then makes each edit it
        /// asked for stretch by stretch of ink, so every object stands, as one step (D-30);
        /// one that would not keep its objects is refused with the line.
        func rewritingInk(_ rewrite: () -> Void) {
            guard !writesNote, !writesFile, let textView, let storage = textView.textStorage
            else { return rewrite() }
            asOneEdit(.replacement) {
                heldRewrites = []
                rewrite()
                let asked = (heldRewrites ?? []).sorted { $0.range.location < $1.range.location }
                heldRewrites = nil
                guard !asked.isEmpty else { return }
                let plans = asked.map { Self.inkRewrites(storage, of: $0.range, as: $0.replacement) }
                for stretch in plans.reversed().flatMap({ ($0 ?? []).reversed() })
                where (storage.string as NSString).substring(with: stretch.range) != stretch.text {
                    textView.performValidatedReplacement(
                        in: stretch.range, with: NSAttributedString(string: stretch.text))
                }
                var shift = 0
                textView.selectedRanges = zip(asked, plans).map { ask, plan in
                    let length = plan == nil ? ask.range.length : ask.replacement.utf16.count
                    defer { shift += length - ask.range.length }
                    return NSValue(range: NSRange(location: ask.range.location + shift, length: length))
                }
                if plans.contains(where: { $0 == nil }) { model.flash(PageModel.rewriteRefusedLine) }
            }
        }

        /// The asked edit reached the storage, so its objects are the settle's to judge.
        private func landRemovalWatch() {
            guard var watch = removalWatch, !watch.asked.isEmpty else { return }
            watch.landed.formUnion(watch.asked)
            watch.asked = []
            removalWatch = watch
        }

        /// U+FFFC, which a page or a note holds for its objects alone (Law 0001).
        static let objectCharacter = "\u{FFFC}"

        /// Each U+FFFC in `range` no object stands on (Law 0001): one with no object, a board's,
        /// one whose object's run takes in ink (inherited with it), or an object's second index.
        static func strayObjectCharacters(
            in storage: NSTextStorage, _ range: NSRange, fromBoard: Bool = false
        ) -> [NSRange] {
            let text = storage.string as NSString
            let whole = NSRange(location: 0, length: storage.length)
            var stray: [NSRange] = []
            var objects: [(at: Int, chip: UInt64)] = []
            var rest = range
            while rest.length > 0 {
                let found = text.range(of: objectCharacter, options: .literal, range: rest)
                guard found.location != NSNotFound else { break }
                rest = NSRange(location: NSMaxRange(found), length: NSMaxRange(rest) - NSMaxRange(found))
                var run = NSRange()
                guard !fromBoard,
                      let chip = storage.attribute(.attachment, at: found.location, effectiveRange: nil)
                        as? ChipAttachment,
                      storage.attribute(
                          .attachment, at: found.location, longestEffectiveRange: &run, in: whole)
                        != nil,
                      !(run.location..<NSMaxRange(run)).contains(where: {
                          text.character(at: $0) != 0xFFFC
                      })
                else {
                    stray.append(found)
                    continue
                }
                objects.append((found.location, chip.info.chipId))
            }
            guard !objects.isEmpty else { return stray }
            var standing = chipIDs(storage, in: NSRange(location: 0, length: range.location))
                .union(chipIDs(storage, in: NSRange(
                    location: NSMaxRange(range), length: storage.length - NSMaxRange(range))))
            for object in objects where !standing.insert(object.chip).inserted {
                stray.append(NSRange(location: object.at, length: 1))
            }
            return stray.sorted { $0.location < $1.location }
        }

        /// Once an edit has landed: if an object it held no longer stands, the removal line.
        private func settleRemovalWatch() {
            guard let watch = removalWatch, let storage = textView?.textStorage
            else { return }
            removalWatch = nil
            guard watch.document == document, !watch.landed.isEmpty else { return }
            let standing = Self.chipIDs(storage, in: NSRange(location: 0, length: storage.length))
            if !watch.landed.isSubset(of: standing) { noteRemoval() }
        }

        /// After an edit took an object: end its step, so Undo stands the object alone,
        /// and say so with the model's Undo beside the line (D-30).
        func noteRemoval() {
            guard let document, case .sheet(let sheet) = document, let textView else { return }
            model.finishEditingGroup(document, selection: textView.selectedRange())
            model.noteRemoval(sheet: sheet)
        }

        // MARK: Markdown — styled, never rewritten

        /// Display-only, markup-preserving (docs/spec/04): a heading
        /// line renders at heading weight with its `#`s dimmed in
        /// place. Attributes only; the bytes of the page never change.
        /// Also the ADR-0013 editable-surface rule's display instance:
        /// created/modified are pulled fresh from the core and edited
        /// blocks receive trailing-edge affordances without
        /// touching how it edits.
        func restyle() {
            guard let storage = textView?.textStorage, let document else { return }
            defer { textView?.refreshHover() }
            // Locations are storage offsets. Any structural restyle may
            // move the hovered block underneath a fixed offset, so leave
            // the old row before deriving the new display model.
            hoveredBlockLocation = nil
            // `.never` uses the plain visual profile everywhere. Markdown-capable
            // pages still need the Markdown walk's classifications and fence ranges
            // for editing and paste safety, but neither result is rendered.
            let previewScope = writesNote ? model.previewRendering : currentSheet.map {
                model.previewRendering(for: $0)
            } ?? model.previewRendering
            appliedPreviewRendering = previewScope
            if previewScope == .never {
                restylePlainFile(storage, preservingMarkdownStructure: file == nil)
                return
            }
            if let file {
                switch model.fileRenderMode(for: file) {
                case .plainText:
                    restylePlainFile(storage)
                    return
                case .source(let language):
                    restyleSourceFile(storage, language: language)
                    return
                case .markdown:
                    break
                }
            }
            let (regions, displays, kinds) = Self.applyMarkdownStyling(
                to: storage, blockMetas: blockMetas(),
                syntaxHighlightingEnabled: model.syntaxHighlightingEnabled,
                fenceRenderingLanguages: fenceLanguages(),
                renderBlockLabels: !writesNote
            )
            blockDisplays = displays
            fenceRegions = regions
            lineKinds = kinds
            lineKindsStamp = generation
            lineKindsDocument = document
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                layoutManager.fenceRegions = fenceRegions
                textView?.needsDisplay = true
            }
            keepPageInset()
            _ = refreshBlockMetadataFocus()
            updateBlockLabelViews()
        }

        /// The file under the surface, when the document is one.
        private var file: UInt64? {
            guard case .sheet(let sheet) = document, sheet.isFileID else { return nil }
            return sheet
        }

        /// The page's block stamps; a file and a note show none (Law 0001, object in a note row).
        ///
        /// A file gets no block stamps, and the route is not merely
        /// skipped for dull values: `blocks(sheet:)` is a
        /// companion_sheet_* route, and a tagged id reaching it is
        /// refused core-side. Asking anyway would spend a refused
        /// call on every keystroke. A file's document does carry
        /// change timestamps, because it is a SheetDocument like any
        /// other, but they describe when this process happened to
        /// read the file rather than when a person wrote a
        /// paragraph, so there is nothing true to show
        /// (decisions.md item 15). A note's chip id is not a page id.
        private func blockMetas() -> [BlockInfo] {
            guard case .sheet(let sheet) = document, !sheet.isFileID else { return [] }
            return model.coreClient.blocks(sheet: sheet)
        }

        /// Block metadata rides the first line instead of taking a row
        /// above it, so the page keeps its ordinary top inset regardless
        /// of which blocks have been edited. A note keeps its own.
        private func keepPageInset() {
            guard !writesNote, let textView,
                  textView.textContainerInset.height != Self.topInset
            else { return }
            textView.textContainerInset.height = Self.topInset
        }

        /// The pure part of `restyle()`: walk the storage block by block
        /// under one whole-page fence scanner, style each paragraph, and
        /// return the fence regions, block metadata displays and the
        /// classifications. Shared with `PageModel.quietRendering(for:)`
        /// so a quiet day laid over its own temporary storage reads the
        /// same as the mounted editor would over its live one.
        static func applyMarkdownStyling(
            to storage: NSTextStorage,
            blockMetas: [BlockInfo],
            syntaxHighlightingEnabled: Bool,
            fenceRenderingLanguages: [Int: String],
            renderBlockLabels: Bool = true
        ) -> (
            fenceRegions: [NSRange],
            displays: [BlockDisplay],
            lineKinds: [(range: NSRange, kind: InkStyle.LineKind)]
        ) {
            let text = storage.string as NSString
            // First pass: walk the page block by block and classify
            // every paragraph. One scanner serves the whole page, since
            // a fence opened in one block goes on holding the lines of
            // the blocks after it: what a line means depends on
            // everything above it (issue #75).
            var walks: [BlockWalk] = []
            var location = 0
            var block = 0
            var scanner = InkStyle.FenceScanner()
            // The tokenizer stands beside the scanner because it has
            // the same shape of memory: an open `/*` or an open `"""`
            // means the next line is not what it locally looks like,
            // exactly as an open fence means the next line is not
            // prose. Cross-line state lives where cross-line state
            // already lives, and one linear scan of the page serves
            // both. Nothing is tokenized until a fence names a
            // language, so the tokenizer starts knowing none.
            var tokenizer = CodeInk.Tokenizer(language: nil)
            while location < text.length {
                let meta = block < blockMetas.count ? blockMetas[block] : nil
                // A block is usually one paragraph and sometimes several
                // (a paste keeps its lines together, ADR-0013), so the
                // page is walked block by block, and metadata belongs
                // to the block's first line rather than every line the
                // paste brought with it.
                let extent = Self.blockRange(
                    from: location, paragraphs: meta?.paragraphs ?? 1, of: text
                )
                // A block that begins inside an open fence belongs to
                // the fence region the blocks above it started: the core
                // splits a typed fence into one block per line, but the
                // eye reads the fence as one slab, so those blocks stamp
                // together (and an unterminated fence carries the region
                // to the end of the page, the same reading the styling
                // gives its lines).
                let joinsPrevious = scanner.insideFence
                var head = extent
                var headIsBlank = true
                var paragraphs: [WalkedParagraph] = []
                var paragraphStart = location
                while paragraphStart < NSMaxRange(extent) {
                    let paragraph = text.paragraphRange(
                        for: NSRange(location: paragraphStart, length: 0)
                    )
                    // The affordance rides the first line a reader can
                    // see. A block whose opening paragraph is empty — a
                    // paste that kept its leading blank, a return
                    // pressed before the words arrived — would otherwise
                    // float its pill over whitespace, reading as
                    // belonging to nothing.
                    if headIsBlank {
                        head = paragraph
                        headIsBlank = Self.isBlank(paragraph, of: text)
                    }
                    let line = text.substring(with: paragraph)
                    // Whether the scanner was already holding a fence
                    // open is what tells an opening rule from a closing
                    // one, and only the opening rule declares a
                    // language.
                    let wasInsideFence = scanner.insideFence
                    let kind = scanner.classify(line)
                    var tokens: [CodeInk.Token] = []
                    switch kind {
                    case .fenceRule where !wasInsideFence:
                        // A fresh tokenizer at every opening rule: it
                        // takes the language the rule names and carries
                        // nothing the block above left open, which is
                        // the boundary the spec asks tokenizer state
                        // never to cross.
                        let sessionLanguage = scanner.fenceInfoString?.isEmpty == true
                            ? fenceRenderingLanguages[paragraph.location]
                            : nil
                        tokenizer = CodeInk.Tokenizer(
                            language: scanner.fenceLanguage
                                ?? sessionLanguage.flatMap(CodeInk.renderingLanguage(ofInfoString:))
                        )
                    case .code where syntaxHighlightingEnabled:
                        // The line without its separator, taken off the
                        // tail alone. Trimming both ends would move
                        // every offset the tokenizer returns whenever a
                        // line opens with something Foundation calls a
                        // newline but `paragraphRange` does not break
                        // on: a form feed at the head of a line, which
                        // older sources carry as a page break and a
                        // plain paste lands verbatim, shifted the whole
                        // line's color one unit left. A token's offsets
                        // count from the paragraph's first character,
                        // so the first character must not move.
                        var content = Substring(line)
                        while let last = content.last, last.isNewline {
                            content = content.dropLast()
                        }
                        tokens = tokenizer.tokens(in: String(content))
                    default:
                        break
                    }
                    paragraphs.append(
                        WalkedParagraph(range: paragraph, kind: kind, tokens: tokens)
                    )
                    if paragraph.length == 0 { break }
                    paragraphStart = NSMaxRange(paragraph)
                }
                walks.append(BlockWalk(
                    head: head, extent: extent, meta: meta,
                    // A blank block is spacing, not writing: it carries a
                    // stamp in the core but shows none, so a page of
                    // empty paragraphs no longer stacks a column of
                    // identical times down the margin.
                    blank: Self.isBlank(extent, of: text),
                    paragraphs: paragraphs, joinsPrevious: joinsPrevious
                ))
                block += 1
                if extent.length == 0 { break }
                location = NSMaxRange(extent)
            }
            // Second pass: lay the attributes down group by group,
            // where a group is one ordinary block or the run of blocks
            // a fence region spans. Each edited group gets one compact
            // affordance on its first line, spanning earliest creation
            // to latest touch. No group changes paragraph spacing.
            var displays: [BlockDisplay] = []
            storage.beginEditing()
            var lower = 0
            while lower < walks.count {
                var upper = lower + 1
                while upper < walks.count, walks[upper].joinsPrevious { upper += 1 }
                let group = Array(walks[lower..<upper])
                // Block metadata affordances are editor-only display: a
                // quiet caller (ADR-0030) suppresses them by passing
                // `renderBlockLabels: false`.
                let display = renderBlockLabels ? Self.groupDisplay(for: group) : nil
                for walk in group {
                    for paragraph in walk.paragraphs {
                        Self.styleParagraph(
                            paragraph.range, of: storage, kind: paragraph.kind,
                            tokens: paragraph.tokens
                        )
                    }
                }
                if var display, let head = group.first?.head {
                    display.range = head
                    display.logicalRange = group.reduce(head) { range, walk in
                        NSUnionRange(range, walk.extent)
                    }
                    displays.append(display)
                }
                lower = upper
            }
            storage.endEditing()
            // Third pass, cheap because the classification is already
            // in hand: collect the fence regions as character ranges,
            // opening rule through closing rule, for the layout manager
            // to wash as one slab. The wash used to be a per-paragraph
            // `.backgroundColor`, which rendered as per-line stripes
            // hugging the glyph runs; drawn once per region it is the
            // contiguous rectangle the eye expects. Kept as a return
            // value alongside the classification so the caller can seed
            // its layout manager and its automation cache (ADR-0024:
            // automation decides from the classification, never from a
            // second scan that might disagree with the first).
            let paragraphs = walks.flatMap(\.paragraphs)
                .map { (range: $0.range, kind: $0.kind) }
            return (Self.fenceRegions(of: paragraphs), displays, paragraphs)
        }

        /// File plain text is intentionally not Markdown-capable: it receives
        /// only base attributes and leaves headings, links, lists, and fences
        /// as literal characters. Markdown-capable pages may retain a structural
        /// reading for editor behavior while using this same visual profile.
        private func restylePlainFile(
            _ storage: NSTextStorage, preservingMarkdownStructure: Bool = false
        ) {
            let text = storage.string as NSString
            let full = NSRange(location: 0, length: storage.length)
            let structure = preservingMarkdownStructure
                ? Self.applyMarkdownStyling(
                    to: storage, blockMetas: blockMetas(),
                    syntaxHighlightingEnabled: model.syntaxHighlightingEnabled,
                    fenceRenderingLanguages: fenceLanguages(),
                    renderBlockLabels: false
                )
                : nil
            storage.beginEditing()
            if full.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                storage.addAttributes([
                    .font: InkStyle.baseFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: paragraphStyle,
                ], range: full)
                storage.removeAttribute(.link, range: full)
                storage.removeAttribute(.underlineStyle, range: full)
            }
            storage.endEditing()
            blockDisplays = []
            fenceRegions = structure?.fenceRegions ?? []
            lineKinds = structure?.lineKinds
                ?? (text.length == 0 ? [] : [(range: full, kind: .body)])
            lineKindsStamp = generation
            lineKindsDocument = document
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                // The ranges remain available to the editor's behavior gates, but
                // `.never` must not paint the Markdown fence slab.
                layoutManager.fenceRegions = []
                textView?.needsDisplay = true
            }
            keepPageInset()
            _ = refreshBlockMetadataFocus()
            updateBlockLabelViews()
        }

        /// Source mode tokenizes the complete buffer as code. No Markdown
        /// scanner runs here, so `#`, lists, links, and fence markers retain
        /// their literal source meaning.
        private func restyleSourceFile(_ storage: NSTextStorage, language: String) {
            let text = storage.string as NSString
            var tokenizer = CodeInk.Tokenizer(
                language: CodeInk.renderingLanguage(ofInfoString: language)
            )
            var paragraphs: [NSRange] = []
            var location = 0
            storage.beginEditing()
            while location < text.length {
                let range = text.paragraphRange(for: NSRange(location: location, length: 0))
                let style = NSMutableParagraphStyle()
                storage.addAttributes([
                    .font: InkStyle.codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: style,
                ], range: range)
                storage.removeAttribute(.link, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                if model.syntaxHighlightingEnabled {
                    var line = Substring(text.substring(with: range))
                    while let last = line.last, last.isNewline { line = line.dropLast() }
                    for token in tokenizer.tokens(in: String(line)) {
                        let span = NSRange(location: range.location + token.range.location, length: token.range.length)
                        guard token.range.location >= 0, token.range.length > 0,
                              NSMaxRange(span) <= NSMaxRange(range) else { continue }
                        storage.addAttribute(.foregroundColor, value: InkStyle.tokenColor(token.kind), range: span)
                    }
                }
                paragraphs.append(range)
                let next = NSMaxRange(range)
                if next <= location { break }
                location = next
            }
            storage.endEditing()
            blockDisplays = []
            fenceRegions = []
            lineKinds = paragraphs.map { (range: $0, kind: .code(language: language)) }
            lineKindsStamp = generation
            lineKindsDocument = document
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                layoutManager.fenceRegions = []
                textView?.needsDisplay = true
            }
            keepPageInset()
            _ = refreshBlockMetadataFocus()
            updateBlockLabelViews()
        }

        /// The range a block covers: `paragraphs` paragraphs from
        /// `location`, or as many as the text still holds. One is the
        /// ordinary case (a line the reader typed), and more means a
        /// paste landed here and its lines answer to one name and one
        /// stamp (ADR-0013). A count of zero cannot arise core-side and
        /// is read as one, so a nonsense answer costs a grouping rather
        /// than a walk that never advances.
        static func blockRange(from location: Int, paragraphs: Int, of text: NSString) -> NSRange {
            var end = location
            for _ in 0..<max(1, paragraphs) {
                guard end < text.length else { break }
                end = NSMaxRange(text.paragraphRange(for: NSRange(location: end, length: 0)))
            }
            return NSRange(location: location, length: end - location)
        }

        /// Whitespace only, newline included: nothing a reader would call
        /// content, and so nothing to stamp.
        private static func isBlank(_ range: NSRange, of text: NSString) -> Bool {
            guard range.length > 0 else { return true }
            return text.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        private static func styleParagraph(
            _ range: NSRange, of storage: NSTextStorage,
            kind: InkStyle.LineKind, tokens: [CodeInk.Token]
        ) {
            guard range.length > 0 else { return }
            let paragraphStyle = NSMutableParagraphStyle()
            // Metadata is an overlay at the trailing edge of the first
            // line. It never changes paragraph rhythm.
            paragraphStyle.paragraphSpacingBefore = 0
            // A list item hangs from its content: an item long enough
            // to wrap keeps its second line under the words rather than
            // under the bullet, so the marker column stays a column.
            // This indent belongs to prose; code wrapping and caret
            // geometry come from each range's attributed fixed-pitch font.
            if case .list(let markerLength) = kind {
                paragraphStyle.headIndent = InkStyle.hangingIndent(markerLength: markerLength)
            }
            // Every line is laid back down to plain ink first, because
            // a line that was code a keystroke ago has to be able to
            // stop being code when the fence above it closes or is
            // deleted. (The clear background is belt and braces: the
            // fence wash is no longer an attribute, but nothing stray
            // should linger behind a line either.)
            storage.addAttributes(
                [
                    .font: InkStyle.font(for: kind),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: paragraphStyle,
                ],
                range: range
            )
            // A link is laid back down to plain ink too: the character
            // that breaks a URL has to un-link what it broke, and a
            // line swallowed by a fence stops being clickable at all.
            storage.removeAttribute(.link, range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            switch kind {
            case .body:
                styleLinks(in: range, of: storage)
            case .list:
                // The marker keeps full `labelColor` and its own glyph.
                // A heading's hashes dim because the name beside them
                // gains weight in compensation; a list marker is the
                // thing the eye scans a page for, and dimming it (or
                // swapping `-` for `•`) would bury the structure the
                // writer typed. The hanging indent above is the whole
                // of the styling. An item is otherwise ordinary ink,
                // links and all: "- see https://…" is the commonest
                // line in a working note.
                styleLinks(in: range, of: storage)
            case .heading(_, let markerLength):
                // The `### ` stays on screen, dimmed, exactly where typed.
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: range.location, length: markerLength)
                )
            case .fenceRule:
                // The fence's own line is markup, dimmed the way a
                // heading's hashes are. The wash it shares with the
                // lines it brackets is not an attribute: painting the
                // slab per paragraph left unpainted stripes at every
                // paragraph gap and hugged the glyph runs, so the wash
                // is drawn once per region by the layout manager.
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: range
                )
            case .code:
                // Literally what was typed: the markup a code line
                // carries is part of the code, so nothing here is read
                // as a heading and nothing is dimmed. The wash behind
                // it belongs to the whole fence region and is painted
                // by the layout manager, not laid down per line.
                //
                // Color goes on last, over code ink that is already
                // laid down, and color is all it is: the font, the
                // paragraph style and every byte of the line are the
                // ones a bare fence would have given, so wrapping and
                // the slab's geometry cannot move because a keyword
                // turned purple (ADR-0024, amendment C). A fence with
                // no language, or one the table does not know, hands
                // over no tokens and this loop does nothing.
                for token in tokens {
                    let span = NSRange(
                        location: range.location + token.range.location,
                        length: token.range.length
                    )
                    // A token is read from the line and laid down on
                    // the paragraph, so a span that would run past the
                    // paragraph's end could only come of the two
                    // disagreeing. Nothing is colored on a disagreement
                    // rather than something wrong being colored.
                    guard token.range.location >= 0, token.range.length > 0,
                          NSMaxRange(span) <= NSMaxRange(range)
                    else { continue }
                    storage.addAttribute(
                        .foregroundColor, value: InkStyle.tokenColor(token.kind), range: span
                    )
                }
            }
        }

        /// The hybrid link affordance (ADR-0023), laid down as
        /// attributes on a body line: the construct carries `.link` and
        /// reads as a link, and its markdown syntax — brackets, parens,
        /// the URL between them — stays on screen, dimmed the way a
        /// fence's rules are. What a click does with the `.link` is the
        /// delegate's business (`textView(_:clickedOnLink:at:)`): ⌘
        /// opens, a plain click only moves the caret.
        private static func styleLinks(in range: NSRange, of storage: NSTextStorage) {
            let line = (storage.string as NSString).substring(with: range)
            for link in InkStyle.links(in: line) {
                guard let url = URL(string: link.target) else { continue }
                let place = { (span: NSRange) in
                    NSRange(location: range.location + span.location, length: span.length)
                }
                storage.addAttributes(
                    [
                        .link: url,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: place(link.range)
                )
                for span in link.markup {
                    storage.addAttributes(
                        [
                            .foregroundColor: NSColor.tertiaryLabelColor,
                            .underlineStyle: 0,
                        ],
                        range: place(span)
                    )
                }
            }
        }

        // MARK: Block metadata (ADR-0013: compact edited affordance)

        /// One edited block's compact and expanded readings, anchored to
        /// its first visible paragraph. Untouched blocks deliberately have no
        /// display: the surrounding checkpoint already supplies temporal
        /// context, while an edit is the state worth signaling at rest.
        /// Never holds an origin: the editable-surface rule keeps origin
        /// off every read surface, this one included.
        struct BlockDisplay {
            /// The first visible paragraph, where the pill is drawn.
            var range: NSRange
            /// Every character in the logical block (or coalesced fence
            /// region), which owns caret focus even away from the pill.
            var logicalRange: NSRange
            let compactText: String
            let detailText: String
            let accessibilityText: String
        }

        /// One core block as the first restyle pass read it: where it
        /// starts, what it carries, and whether it began inside a fence
        /// another block opened — the fact the second pass groups by.
        private struct BlockWalk {
            let head: NSRange
            let extent: NSRange
            let meta: BlockInfo?
            let blank: Bool
            let paragraphs: [WalkedParagraph]
            let joinsPrevious: Bool
        }

        /// One paragraph as the first pass read it: where it sits, what
        /// it is, and the spans of it that are keyword, string, comment
        /// or number. The tokens travel with the classification because
        /// neither can be recovered from the paragraph alone: both are
        /// answers the walk could only give having read the page down
        /// to this line. They are consumed by the styling pass and kept
        /// nowhere, the way the classification was before the keystroke
        /// path needed it.
        private struct WalkedParagraph {
            let range: NSRange
            let kind: InkStyle.LineKind
            let tokens: [CodeInk.Token]
        }

        /// The affordance a group renders, or nil when it is blank or has
        /// not changed since creation. A fence region typed line by line
        /// is many core blocks the eye reads as one slab, so its reading
        /// spans earliest creation to latest touch across the region.
        private static func groupDisplay(for group: [BlockWalk]) -> BlockDisplay? {
            guard !(group.count == 1 && group.first?.blank == true) else { return nil }
            let stamps = group.compactMap(\.meta).map { ($0.createdS, $0.modifiedS) }
            guard let span = timestampSpan(for: stamps) else { return nil }
            return blockDisplay(createdS: span.createdS, modifiedS: span.modifiedS)
        }

        /// The earliest creation and latest touch among a display group.
        /// An unmodified block was last touched at creation; a group with
        /// no committed creation has no timestamp span to display.
        static func timestampSpan(
            for stamps: [(createdS: Int64?, modifiedS: Int64?)]
        ) -> (createdS: Int64, modifiedS: Int64)? {
            guard let createdS = stamps.compactMap({ $0.createdS }).min() else { return nil }
            let modifiedS = stamps.compactMap { $0.modifiedS ?? $0.createdS }.max() ?? createdS
            return (createdS, modifiedS)
        }

        /// The fence regions the last restyle read off the page, as
        /// character ranges from opening rule through closing rule (or
        /// through the last classified line, for a fence left open).
        /// Mirrored onto the layout manager, which paints one slab per
        /// entry; kept here as well so the region reading is assertable
        /// without a drawing pass.
        private(set) var fenceRegions: [NSRange] = []

        /// What the last restyle walk decided each paragraph was, keyed
        /// by the paragraph's own range, together with the page and the
        /// storage length that walk read. The keystroke path asks here
        /// instead of scanning the page again, which is the only way
        /// display and automation can be guaranteed to agree about
        /// whether a line is inside a fence (issue #75).
        ///
        /// The stamp is what keeps the cache honest. Restyle runs on
        /// every change, so the reading is normally a keystroke old,
        /// but a keystroke that arrives before the walk has caught up,
        /// or after the editor has moved to another page (ADR-0006),
        /// would be reading a page that no longer exists. Then the
        /// cache answers nothing, and nothing means no automation:
        /// a plain newline is always the safe answer.
        ///
        /// The stamp counts edits rather than measuring the page,
        /// because what a line means depends on every line above it: a
        /// backtick typed over a letter somewhere higher up opens a
        /// fence and turns the caret's bullet into a flag (issue #75)
        /// without moving a single character. A length would call that
        /// page unchanged, and so would a string hash: Foundation's
        /// samples ninety six characters and the length, so on any page
        /// worth the name most of it is never read. A counter bumped on
        /// every character edit is exact at any size, and the guarantee
        /// stops resting on which edits happen to change the
        /// arithmetic.
        private var lineKinds: [(range: NSRange, kind: InkStyle.LineKind)] = []
        /// How many character edits this coordinator has seen, ever.
        /// The classification cache records the value it was built at,
        /// so any edit since retires the reading.
        private var generation = 0
        private var lineKindsStamp = -1
        private var lineKindsDocument: InkDocument?

        /// The classification of the paragraph beginning exactly at
        /// `location`, or nil when the walk has nothing trustworthy to
        /// say about it. Exact, because a paragraph that has moved is a
        /// paragraph the walk has not seen yet.
        func classifiedKind(ofParagraphAt location: Int) -> InkStyle.LineKind? {
            guard textView?.textStorage != nil,
                  generation == lineKindsStamp,
                  let document, document == lineKindsDocument
            else { return nil }
            return lineKinds.first { $0.range.location == location }?.kind
        }

        /// Folds a page's classified paragraphs into fence regions. The
        /// classification already carries the scanner's whole-page
        /// reading, so this is a plain fold: a rule met outside a region
        /// opens one, the rule that answers it closes it, and code lines
        /// extend whatever is open. A fence left open runs to the last
        /// paragraph handed in, the same reading the styling gives its
        /// lines.
        static func fenceRegions(
            of paragraphs: [(range: NSRange, kind: InkStyle.LineKind)]
        ) -> [NSRange] {
            var regions: [NSRange] = []
            var open: NSRange?
            for paragraph in paragraphs {
                switch paragraph.kind {
                case .fenceRule:
                    if let region = open {
                        regions.append(NSUnionRange(region, paragraph.range))
                        open = nil
                    } else {
                        open = paragraph.range
                    }
                case .code:
                    if let region = open { open = NSUnionRange(region, paragraph.range) }
                case .body, .heading, .list:
                    break
                }
            }
            if let region = open { regions.append(region) }
            return regions
        }

        private var blockDisplays: [BlockDisplay] = []
        private var blockLabelViews: [BlockMetadataField] = []
        private var hoveredBlockLocation: Int?
        private var focusedBlockLocation: Int?
        /// First-line rows in text-view coordinates, rebuilt whenever
        /// labels move. Pointer hit testing reads this geometry rather
        /// than asking TextKit to rederive glyph ranges on every move.
        private var blockFirstLineDisplayRects: [Int: NSRect] = [:]
        /// What each live tooltip rect says, keyed by the tag the text
        /// view handed back. Registrations are also keyed by block location
        /// so unchanged rows retain their AppKit registration on layout.
        private var blockToolTips: [NSView.ToolTipTag: String] = [:]
        private var blockToolTipRegistrations: [Int: BlockToolTipRegistration] = [:]

        private struct BlockToolTipRegistration: Equatable {
            let tag: NSView.ToolTipTag
            let rect: NSRect
            let text: String
        }

        #if DEBUG
            /// The tags currently registered, in document order. The tests
            /// read the tooltip table through the same door AppKit does.
            /// A seam, so it is not built into a shipped binary.
            var blockToolTipTags: [NSView.ToolTipTag] { blockToolTips.keys.sorted() }
            private(set) var blockLabelShapeCount = 0

            /// What the last restyle laid out, in document order: one entry
            /// per edited block, the range being the line its affordance
            /// rides. The window tests get onto the block walk; nothing
            /// writes through it.
            var blockLabelLayout: [(range: NSRange, text: String)] {
                blockDisplays.map { ($0.range, $0.compactText) }
            }
        #endif

        private static let blockLabelFont = NSFont.monospacedDigitSystemFont(
            ofSize: 10.5, weight: .medium
        )
        /// Breathing room inside the pill, and the smallest it ever
        /// draws. Both readings share them, so hovering a block expands
        /// the text without the shape appearing to change.
        private static let blockLabelPadding: CGFloat = 10
        private static let blockLabelMinHeight: CGFloat = 19
        /// The gap between the pill and the trailing text edge, so it
        /// reads as sitting in the margin rather than butting against
        /// the column.
        nonisolated static let blockLabelTrailingInset: CGFloat = 6
        /// The clearance a line's last glyph asks of the affordance
        /// beside it, below which the wide reading stands down.
        nonisolated static let blockAffordanceGap: CGFloat = 8
        /// The page's own top margin.
        static let topInset: CGFloat = 12

        private static func localizedBlockDates(
            _ key: String, created: String, edited: String,
            bundle: Bundle, comment: String
        ) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString(key, bundle: bundle, comment: comment), created, edited
            )
        }

        private static func blockDate(
            _ date: Date, template: String, locale: Locale, timeZone: TimeZone
        ) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }

        private static func blockAccessibilityDate(
            _ date: Date, locale: Locale, timeZone: TimeZone
        ) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        private static func blockCalendar(locale: Locale, timeZone: TimeZone) -> Calendar {
            var calendar = Calendar.autoupdatingCurrent
            calendar.locale = locale
            calendar.timeZone = timeZone
            return calendar
        }

        /// The expanded reading uses the checkpoint's day context while
        /// both stamps stay on that day. A cross-day edit restores the
        /// weekday because it has become information again. Formatters are
        /// made at the point of use so the next render observes changes to
        /// the system locale and time zone rather than retaining stale ones.
        static func blockDetails(
            createdS: Int64, modifiedS: Int64,
            locale: Locale = .autoupdatingCurrent,
            timeZone: TimeZone = .autoupdatingCurrent,
            bundle: Bundle = CompanionLocalization.bundle
        ) -> String? {
            guard modifiedS > createdS else { return nil }
            let createdDate = Date(timeIntervalSince1970: TimeInterval(createdS))
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modifiedS))
            let calendar = blockCalendar(locale: locale, timeZone: timeZone)
            // The operation log sees the first and last keystrokes of a
            // newly typed block as different touches. Preserve the old
            // minute-granularity collapse so ordinary typing does not
            // immediately label nearly every block as edited.
            guard !calendar.isDate(
                createdDate, equalTo: modifiedDate, toGranularity: .minute
            ) else { return nil }
            let template = calendar.isDate(createdDate, inSameDayAs: modifiedDate) ? "jm" : "Ejm"
            return localizedBlockDates(
                "created %@ · edited %@",
                created: blockDate(createdDate, template: template, locale: locale, timeZone: timeZone),
                edited: blockDate(modifiedDate, template: template, locale: locale, timeZone: timeZone),
                bundle: bundle,
                comment: "The creation and modification dates in an edited block's metadata."
            )
        }

        static func blockAccessibilityText(
            createdS: Int64, modifiedS: Int64,
            locale: Locale = .autoupdatingCurrent,
            timeZone: TimeZone = .autoupdatingCurrent,
            bundle: Bundle = CompanionLocalization.bundle
        ) -> String {
            let createdDate = Date(timeIntervalSince1970: TimeInterval(createdS))
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modifiedS))
            return localizedBlockDates(
                "Created %@; edited %@",
                created: blockAccessibilityDate(createdDate, locale: locale, timeZone: timeZone),
                edited: blockAccessibilityDate(modifiedDate, locale: locale, timeZone: timeZone),
                bundle: bundle,
                comment: "The creation and modification dates in an edited block's accessibility label."
            )
        }

        private static func blockDisplay(createdS: Int64, modifiedS: Int64) -> BlockDisplay? {
            let locale = Locale.autoupdatingCurrent
            let timeZone = TimeZone.autoupdatingCurrent
            guard let detail = blockDetails(
                createdS: createdS, modifiedS: modifiedS, locale: locale, timeZone: timeZone
            ) else { return nil }
            let accessibility = blockAccessibilityText(
                createdS: createdS, modifiedS: modifiedS, locale: locale, timeZone: timeZone
            )
            return BlockDisplay(
                range: NSRange(location: 0, length: 0),
                logicalRange: NSRange(location: 0, length: 0),
                compactText: NSLocalizedString(
                    "edited", bundle: CompanionLocalization.bundle,
                    comment: "The compact metadata label for an edited block."
                ),
                detailText: detail,
                accessibilityText: accessibility
            )
        }

        /// Resize the label pool to match `blockDisplays` and refresh
        /// their text, then place them. Called after every `restyle`,
        /// content having just changed underneath.
        private func updateBlockLabelViews() {
            guard let textView else { return }
            while blockLabelViews.count < blockDisplays.count {
                let field = Self.makeBlockLabel()
                textView.addSubview(field)
                blockLabelViews.append(field)
            }
            while blockLabelViews.count > blockDisplays.count {
                blockLabelViews.removeLast().removeFromSuperview()
            }
            for (field, display) in zip(blockLabelViews, blockDisplays) {
                let expanded = display.range.location == hoveredBlockLocation
                    || display.range.location == focusedBlockLocation
                // A first line that runs the full measure has no margin
                // left to lend. Decide against an independent measurement
                // before changing the field, so an expanded-but-too-wide
                // row does not size itself long and compact on every pass.
                let requestedText = expanded && expandedLabelFits(display.detailText, for: display)
                    ? display.detailText : display.compactText
                if field.stringValue != requestedText {
                    field.stringValue = requestedText
                    shapeBlockLabel(field)
                }
                // The pill carries only the short reading; the whole
                // created and edited sentence lives in the label a
                // screen reader hears and in the row's tooltip.
                if field.accessibilityLabel() != display.accessibilityText {
                    field.setAccessibilityLabel(display.accessibilityText)
                }
            }
            textView.setBlockAccessibilityChildren(blockLabelViews)
            repositionBlockLabels()
        }

        /// Re-decide each affordance's reading and place it. A resize
        /// rewraps the paragraph under an expanded pill, so the fit test
        /// that stood the wide reading down (or let it through) has to be
        /// taken again; moving the pills alone would leave a wide reading
        /// sitting over the words the rewrap just pushed under it.
        func refitBlockLabels() {
            updateBlockLabelViews()
        }

        /// Lay the affordances out against stamps handed in rather than
        /// read from the core. The mounted editor never takes this door:
        /// it exists because a block cannot be aged inside a test run,
        /// and the pills, the accessibility children and the tooltip
        /// table can only be examined over a page that carries edited
        /// blocks. A seam (ADR-0018), so it is compiled out of a shipped
        /// binary rather than left standing in one.
        #if DEBUG
            func layOutBlockLabels(forMetas metas: [BlockInfo]) {
                guard let storage = textView?.textStorage, let sheet = currentSheet else { return }
                let (_, displays, _) = Self.applyMarkdownStyling(
                    to: storage, blockMetas: metas,
                    syntaxHighlightingEnabled: model.syntaxHighlightingEnabled,
                    fenceRenderingLanguages: model.fenceRenderingLanguages(for: sheet)
                )
                blockDisplays = displays
                updateBlockLabelViews()
            }
        #endif

        /// One padding rule for both readings, so the pill grows and
        /// shrinks without appearing to change shape.
        private func shapeBlockLabel(_ field: BlockMetadataField) {
            #if DEBUG
                blockLabelShapeCount += 1
            #endif
            field.sizeToFit()
            field.frame.size.width = ceil(field.frame.width) + Self.blockLabelPadding * 2
            field.frame.size.height = max(
                Self.blockLabelMinHeight, ceil(field.frame.height) + 6
            )
            field.layer?.cornerRadius = field.frame.height / 2
        }

        private func expandedLabelFits(_ text: String, for display: BlockDisplay) -> Bool {
            guard let line = firstLineUsedRect(for: display) else { return true }
            return Self.blockAffordanceFits(
                lineMaxX: line.maxX, containerWidth: blockAffordanceMeasure,
                affordanceWidth: Self.blockLabelWidth(for: text)
            )
        }

        private static func blockLabelWidth(for text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: blockLabelFont]).width)
                + blockLabelPadding * 2
        }

        /// The trailing container coordinate every affordance is placed
        /// and tested against. In no-wrap mode TextKit hands the container
        /// an unbounded sentinel, so the document view can be much wider
        /// than the clip. `visibleRect` is the actual viewport in the
        /// document view's coordinates; subtracting the container origin
        /// keeps the origin added by `blockAffordanceOrigin` from counting
        /// the leading inset a second time.
        private var blockAffordanceMeasure: CGFloat {
            guard let textView else { return 0 }
            return Self.blockAffordanceMeasure(
                containerWidth: textView.textContainer?.size.width ?? .infinity,
                visibleRect: textView.visibleRect,
                containerOriginX: textView.textContainerOrigin.x
            )
        }

        nonisolated static func blockAffordanceMeasure(
            containerWidth: CGFloat, visibleRect: NSRect, containerOriginX: CGFloat
        ) -> CGFloat {
            guard containerWidth.isFinite,
                  containerWidth < SealedBlockCell.effectivelyUnboundedWidth
            else { return visibleRect.maxX - containerOriginX }
            return min(containerWidth, visibleRect.maxX - containerOriginX)
        }

        /// The used rect of the line a block's affordance rides, in
        /// container coordinates, or nil when the range has no glyphs.
        private func firstLineUsedRect(for display: BlockDisplay) -> NSRect? {
            guard let layoutManager = textView?.layoutManager else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: display.range, actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }
            return layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil
            )
        }

        private static func makeBlockLabel() -> BlockMetadataField {
            let field = BlockMetadataField(labelWithString: "")
            field.font = blockLabelFont
            field.alignment = .center
            field.isSelectable = false
            field.isEditable = false
            field.drawsBackground = true
            field.isBezeled = false
            field.wantsLayer = true
            field.layer?.cornerRadius = blockLabelMinHeight / 2
            field.layer?.masksToBounds = true
            field.layer?.borderWidth = 1
            field.refreshPillColors()
            field.setAccessibilityElement(true)
            field.setAccessibilityRole(.staticText)
            return field
        }

        /// Place every affordance at the trailing edge of its block's
        /// first line. Geometry only, no core round trip. Rows whose text
        /// and geometry did not move retain both their field frame and
        /// tooltip registration, avoiding layout feedback work.
        func repositionBlockLabels() {
            blockFirstLineDisplayRects.removeAll()
            guard let textView else { return }
            let measure = blockAffordanceMeasure
            let origin = textView.textContainerOrigin
            var requestedToolTips: [Int: (rect: NSRect, text: String)] = [:]
            for (field, display) in zip(blockLabelViews, blockDisplays) {
                guard let usedRect = firstLineUsedRect(for: display) else { continue }
                let fieldOrigin = Self.blockAffordanceOrigin(
                    firstLine: usedRect, containerWidth: measure,
                    containerOrigin: origin, affordanceSize: field.frame.size
                )
                if field.frame.origin != fieldOrigin {
                    field.setFrameOrigin(fieldOrigin)
                }
                // AppKit hands a tooltip to whichever view answers the hit
                // test, and the pill answers with nothing so the caret can
                // land behind it. The text view hosts the tooltip instead,
                // over the same row the hover expansion already claims.
                let displayRect = NSRect(
                    x: origin.x, y: origin.y + usedRect.minY,
                    width: measure, height: usedRect.height
                )
                blockFirstLineDisplayRects[display.range.location] = displayRect
                requestedToolTips[display.range.location] = (
                    rect: displayRect, text: display.accessibilityText
                )
            }
            reconcileBlockToolTips(requestedToolTips, in: textView)
        }

        private func reconcileBlockToolTips(
            _ requested: [Int: (rect: NSRect, text: String)], in textView: NSTextView
        ) {
            for (location, registration) in Array(blockToolTipRegistrations) {
                guard let next = requested[location],
                      registration.rect == next.rect, registration.text == next.text
                else {
                    textView.removeToolTip(registration.tag)
                    blockToolTips[registration.tag] = nil
                    blockToolTipRegistrations[location] = nil
                    continue
                }
            }
            for (location, next) in requested where blockToolTipRegistrations[location] == nil {
                let tag = textView.addToolTip(next.rect, owner: self, userData: nil)
                blockToolTips[tag] = next.text
                blockToolTipRegistrations[location] = BlockToolTipRegistration(
                    tag: tag, rect: next.rect, text: next.text
                )
            }
        }


        /// AppKit asking what the row under the pointer says. An unknown
        /// tag is a stale rect the rebuild has already forgotten, and it
        /// answers with nothing rather than with another block's stamps.
        public func view(
            _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
            point: NSPoint, userData: UnsafeMutableRawPointer?
        ) -> String {
            blockToolTips[tag] ?? ""
        }

        /// Whether the wide reading can stand clear of a line's glyphs.
        /// A line that runs to the measure leaves the affordance nowhere
        /// to go, and a pill drawn over words is worse than a short one.
        nonisolated static func blockAffordanceFits(
            lineMaxX: CGFloat, containerWidth: CGFloat, affordanceWidth: CGFloat
        ) -> Bool {
            lineMaxX + blockAffordanceGap + affordanceWidth
                + blockLabelTrailingInset <= containerWidth
        }

        nonisolated static func blockAffordanceOrigin(
            firstLine: NSRect, containerWidth: CGFloat,
            containerOrigin: NSPoint, affordanceSize: NSSize
        ) -> NSPoint {
            NSPoint(
                x: containerOrigin.x + containerWidth
                    - affordanceSize.width - blockLabelTrailingInset,
                y: containerOrigin.y + firstLine.midY - affordanceSize.height / 2
            )
        }

        /// Expand the metadata for the edited block under the pointer.
        /// The whole first-line row is the target rather than the small
        /// pill, so inspecting a block does not demand pixel hunting.
        func updateBlockMetadataHover(at point: NSPoint?) {
            let next = point.flatMap { blockLocation(at: $0) }
            guard next != hoveredBlockLocation else { return }
            hoveredBlockLocation = next
            updateBlockLabelViews()
        }

        private func blockLocation(at point: NSPoint) -> Int? {
            blockDisplays.first { display in
                blockFirstLineDisplayRects[display.range.location]?.contains(point) == true
            }?.range.location
        }

        /// The block owning a selection start. A caret at the document's
        /// final boundary belongs to its final block; boundaries between
        /// blocks remain assigned to the following block.
        static func blockFocusLocation(
            for selection: NSRange, in displays: [BlockDisplay], documentLength: Int
        ) -> Int? {
            guard selection.location != NSNotFound else { return nil }
            return displays.first { display in
                NSLocationInRange(selection.location, display.logicalRange)
                    || (selection.location == documentLength
                        && NSMaxRange(display.logicalRange) == documentLength)
            }?.range.location
        }

        @discardableResult
        private func refreshBlockMetadataFocus() -> Bool {
            guard let textView else { return false }
            let next = Self.blockFocusLocation(
                for: textView.selectedRange(), in: blockDisplays,
                documentLength: textView.textStorage?.length ?? 0
            )
            guard next != focusedBlockLocation else { return false }
            focusedBlockLocation = next
            return true
        }
    }
}

/// Block metadata is informative until the revision read API exists.
/// Let pointer gestures fall through to the editor so the compact pill
/// never steals caret placement or text selection from the line it rides.
/// The tooltip is hosted by the text view rather than here, for the
/// same reason: a view that answers the hit test with nothing is never
/// offered one.
final class BlockMetadataField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override class var cellClass: AnyClass? {
        get { BlockMetadataCell.self }
        set { super.cellClass = newValue }
    }

    /// A dynamic colour asked for its `cgColor` answers with whatever
    /// appearance happened to be current at the time, and then keeps
    /// that answer forever. The pill's washes are resolved again here,
    /// inside this view's own appearance, so a switch between light and
    /// dark carries them along.
    func refreshPillColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            textColor = .secondaryInk
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
            layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.35).cgColor
        }
    }

    /// The one door the washes are resolved through. Resolving them from
    /// a drawing pass instead would assign colours while drawing, which
    /// invalidates display and asks for the next pass, and so on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPillColors()
        needsDisplay = true
    }
}

/// A label's text sits at the top of whatever frame it is given. The
/// pill's frame is taller than its line so it can carry padding, so the
/// text is centered back into it rather than riding the pill's ceiling.
private final class BlockMetadataCell: NSTextFieldCell {
    private func centered(_ frame: NSRect) -> NSRect {
        let height = cellSize(forBounds: frame).height
        guard height < frame.height else { return frame }
        return frame.insetBy(dx: 0, dy: (frame.height - height) / 2)
    }

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        super.drawInterior(withFrame: centered(frame), in: view)
    }

    override func select(
        withFrame frame: NSRect, in view: NSView, editor: NSText,
        delegate: Any?, start: Int, length: Int
    ) {
        super.select(
            withFrame: centered(frame), in: view, editor: editor,
            delegate: delegate, start: start, length: length
        )
    }
}

// MARK: - The layout manager

/// The page's layout manager, which exists to paint the fence wash.
/// Painted as a per-paragraph `.backgroundColor` attribute, the wash
/// rendered as per-line slabs — unpainted stripes at every paragraph
/// gap, edges hugging the glyph runs — instead of the one rectangle a
/// code block reads as. Here it is drawn once per region, under the
/// glyphs, at the full width of the text container, before the
/// superclass lays down whatever backgrounds remain (selection included,
/// which is why the slab goes down first).
final class InkLayoutManager: NSLayoutManager {
    /// The fence regions of the current page, as character ranges, in
    /// document order. `restyle` owns these; drawing only reads them.
    var fenceRegions: [NSRange] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let container = textContainers.first, let storage = textStorage {
            let whole = NSRange(location: 0, length: storage.length)
            for region in fenceRegions {
                // Clamped, because an edit can land between the restyle
                // that computed these ranges and the draw that reads
                // them; a stale region must never index past the text.
                let clamped = NSIntersectionRange(region, whole)
                guard clamped.length > 0 else { continue }
                let glyphs = glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                // TextKit asks for the visible slice, not the whole
                // document; a region that falls entirely outside the
                // requested glyphs needs no paint this pass.
                guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
                // The slab's top comes from the used rect, where the
                // region's glyphs actually begin.
                let top = lineFragmentUsedRect(
                    forGlyphAt: glyphs.location, effectiveRange: nil
                ).minY
                let bottom = boundingRect(forGlyphRange: glyphs, in: container).maxY
                guard let slab = Self.slabRect(
                    firstLineTop: top, regionBottom: bottom,
                    containerWidth: container.size.width, origin: origin
                ) else { continue }
                // TextKit draws on the main thread; the assumption is
                // stated rather than inherited because the SDK does not
                // isolate NSLayoutManager, and the wash's constant
                // lives on the main-actor style enum.
                let wash = MainActor.assumeIsolated { InkStyle.codeBackground }
                wash.setFill()
                NSBezierPath(roundedRect: slab, xRadius: 4, yRadius: 4).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// The rectangle a fence region's wash covers, in the view's
    /// coordinates: from the top of the region's first used line to the
    /// bottom of its last fragment, at the full width of the text
    /// container, offset by the container's origin. Nil when the metrics
    /// describe nothing worth painting. Pure, so the geometry is
    /// testable without a layout pass.
    nonisolated static func slabRect(
        firstLineTop: CGFloat, regionBottom: CGFloat,
        containerWidth: CGFloat, origin: NSPoint
    ) -> NSRect? {
        guard regionBottom > firstLineTop, containerWidth > 0 else { return nil }
        return NSRect(
            x: origin.x,
            y: origin.y + firstLineTop,
            width: containerWidth,
            height: regionBottom - firstLineTop
        )
    }
}

// MARK: - The text view

/// The two actions the Edit menu posts down the responder chain, so
/// that the menu's end of the route and the page's end spell them
/// once. A menu built in the app target cannot name `InkTextView`,
/// which is this package's own; `#selector(EditStepResponder.undo(_:))`
/// resolves to the same `undo:` the page answers, and a rename that
/// broke the pairing would fail to compile rather than becoming a menu
/// item that quietly does nothing.
@MainActor
@objc public protocol EditStepResponder {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

/// Language actions posted by the ordinary Edit menu down the responder chain.
/// The app target can name this protocol without depending on the package-private
/// text-view implementation that owns the selection and paste destination.
@MainActor
@objc public protocol LanguageDetectionResponder {
    var canDetectCodeLanguage: Bool { get }
    var canChooseCodeLanguage: Bool { get }
    func detectCodeLanguage(_ sender: Any?)
    /// `sender` is a `CodeLanguageChoice`, so the language rides the chain.
    func chooseCodeLanguage(_ sender: Any?)
    func pasteWithoutDetection(_ sender: Any?)
}

/// The language Edit → Choose Language sends down the responder chain, to
/// whichever surface holds the keys (Law 0007, keys row).
public final class CodeLanguageChoice: NSObject {
    public let language: String

    public init(language: String) {
        self.language = language
    }
}

/// The seal of a selection, posted by Edit → Seal Selected Content down
/// the responder chain (D-30). Same shape as `EditStepResponder`, for
/// the same reason: the app target cannot name the page's text view,
/// and a selector spelled once here is checked by the compiler at both
/// ends of the route.
@MainActor
@objc public protocol SealResponder {
    func sealSelectedContent(_ sender: Any?)
}

/// The two placements the record gives the seal of a selection (D-30):
/// a row in the editor's context menu and an item in the Edit menu.
/// Both run the same coordinator method the chord runs, so there is
/// one implementation of the verb and the menus cannot drift from the
/// keyboard. The command id is the one the keymap names.
public enum SealSelectionMenu {
    public static let contextMenuTitle = "Seal Selection"
    public static let editMenuTitle = "Seal Selected Content"
    public static let command = CommandID.clipboardSealSelection
}

/// The page's text view: routes the seal gestures, keeps ⌘V plain,
/// hands Esc back, and seals external drops through the core's drag
/// route. Chips are atomic under the caret by construction — an
/// attachment is one character: arrows step over it, one ⌫ removes it
/// whole, selection cannot reach inside it.
/// Carries the mounted editor's finite viewport measure into TextKit's
/// nonisolated attachment-sizing callbacks. One scalar update replaces a
/// whole-document attachment scan on every layout pass.
final class InkTextContainer: NSTextContainer {
    private let editorMeasure = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)

    nonisolated func setEditorMeasure(_ measure: CGFloat) -> Bool {
        editorMeasure.withLock { current in
            guard current != measure else { return false }
            current = measure
            return true
        }
    }

    nonisolated var capturedEditorMeasure: CGFloat? {
        editorMeasure.withLock { $0 }
    }
}

/// Keep an ordinary page's typing surface at least as tall as its viewport.
/// Roll editors get their minimum height from DayStackView instead. This
/// is the one writer of the floor while the page is mounted; `setWrap`
/// seeds the same value when the wrap mode changes.
final class EditorViewportClipView: NSClipView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? InkTextView else { return }
        let previous = editor.minSize
        guard previous != bounds.size else { return }
        editor.minSize = bounds.size
        // Only a surface standing on the old floor, or short of the new
        // one, needs a new frame. A page taller than both already clears
        // the floor, and `sizeToFit` would lay out the whole document
        // for nothing on every frame of a live resize.
        if editor.frame.height <= max(previous.height, bounds.height)
            || editor.frame.width < bounds.width
        {
            #if DEBUG
                editor.floorRefitCount += 1
            #endif
            editor.sizeToFit()
        }
    }
}

final class InkTextView: AskingTextView, EditStepResponder, LanguageDetectionResponder,
    SealResponder
{
    weak var coordinator: InkEditorView.Coordinator?
    private var blockAccessibilityChildren: [BlockMetadataField] = []

    @discardableResult
    private func withEditIntent<Result>(
        _ intent: EditorEditIntent,
        afterSelection: NSRange? = nil,
        perform body: () -> Result
    ) -> Result {
        guard let coordinator else { return body() }
        return coordinator.withEditIntent(
            intent,
            afterSelection: afterSelection,
            perform: body
        )
    }

    /// Which window the editor landed in, by class. The build line
    /// cannot say, since an editor is built before it has a window, and
    /// with two windows over one model "which one mounted" is the
    /// question the log is read for: a hand off (ADR-0033) shows as one
    /// build and one mount in the window that owns now, and a second
    /// mount line with no transfer between is the defect ownership
    /// exists to prevent. The class and nothing else: `BackdropPanel`
    /// is the card, `NSWindow` the editor window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let model = coordinator?.model, coordinator?.writesNote == false
        else { return }
        let surface = String(describing: type(of: window))
        Logger(subsystem: model.formFactor.loggerSubsystem, category: "editor")
            .info("editor=mounted window=\(surface, privacy: .public)")
    }

    #if DEBUG
        /// Deterministic screen-space input for hover-refresh wiring tests.
        /// Production always reads the current window-server state instead.
        var hoverRefreshInput: (screenPoint: NSPoint, holdsKeys: Bool, pointsIntoWindow: Bool)?

        /// Test-only tally of the floor refits `EditorViewportClipView`
        /// asks for, so a test can assert that its gate skips a page
        /// already taller than the viewport. A wrong gate there is extra
        /// layout work on every frame of a live resize, not a wrong frame,
        /// so no geometry assertion would catch it. AppKit's own clip
        /// observer refits the view on every clip frame change regardless,
        /// which is why this counts the gate and not `sizeToFit` itself.
        fileprivate(set) var floorRefitCount = 0
    #endif

    /// Keep the text view's native accessibility hierarchy intact. The
    /// metadata fields supplement it rather than replacing it, preserving
    /// AppKit's text-navigation children.
    func setBlockAccessibilityChildren(_ fields: [BlockMetadataField]) {
        guard blockAccessibilityChildren.map(ObjectIdentifier.init)
            != fields.map(ObjectIdentifier.init)
        else { return }
        blockAccessibilityChildren = fields
    }

    override func accessibilityChildren() -> [Any]? {
        let nativeChildren = super.accessibilityChildren() ?? []
        let metadataChildren = blockAccessibilityChildren.filter { field in
            !nativeChildren.contains { ($0 as AnyObject) === field }
        }
        let children = nativeChildren + metadataChildren + handleAccessibilityElements()
        return children.isEmpty ? nil : children
    }

    var canChooseCodeLanguage: Bool {
        answersChords && coordinator?.manualLanguageTargetAvailable == true
    }

    @objc func chooseCodeLanguage(_ sender: Any?) {
        guard answersChords, let choice = sender as? CodeLanguageChoice else { return }
        coordinator?.applyManualLanguage(choice.language)
    }

    /// The sealed block under the pointer, if any, so the block can
    /// draw its actions glyph while it is hovered (D-10). Kept here
    /// rather than on the cell because the cell is drawn by the layout
    /// manager and holds no state about the pointer; the view watches
    /// the pointer and redraws the block that gained or lost it.
    private(set) var hoveredChipIndex: Int? {
        didSet {
            guard hoveredChipIndex != oldValue else { return }
            for index in [oldValue, hoveredChipIndex].compactMap({ $0 }) {
                redrawChip(at: index)
            }
            handlesMayHaveMoved()
        }
    }

    /// The zone of the hovered block's named row under the pointer, so
    /// its pill and seat words can be drawn (sealed row spec, Hover pill and seat words).
    private(set) var hoveredZone: SealedBlockLayout.Zone?

    /// A zone's copy, worn in ember for `SealedBlockCell.beatDuration`.
    struct CopyBeat: Equatable {
        let index: Int
        let chip: UInt64
        let zone: SealedBlockLayout.Zone
        let started: TimeInterval
    }

    private(set) var copyBeat: CopyBeat?
    private var copyBeatTimer: Timer?

    /// Lights the beat on the zone at `index` and lets it rest after
    /// its second; a second copy restarts it where it fell.
    func beginCopyBeat(_ zone: SealedBlockLayout.Zone, at index: Int) {
        guard let chip = chipCell(at: index)?.info.chipId else { return }
        copyBeatTimer?.invalidate()
        if let previous = copyBeat { redrawChip(at: previous.index) }
        copyBeat = CopyBeat(
            index: index, chip: chip, zone: zone, started: ProcessInfo.processInfo.systemUptime)
        redrawChip(at: index)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let timer = Timer(
            timeInterval: reduceMotion ? SealedBlockCell.beatDuration : 1.0 / 30,
            repeats: !reduceMotion
        ) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.advanceCopyBeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        copyBeatTimer = timer
    }

    private func advanceCopyBeat() {
        guard let beat = copyBeat else {
            copyBeatTimer?.invalidate()
            copyBeatTimer = nil
            return
        }
        if ProcessInfo.processInfo.systemUptime - beat.started >= SealedBlockCell.beatDuration {
            copyBeat = nil
            copyBeatTimer?.invalidate()
            copyBeatTimer = nil
        }
        redrawChip(at: beat.index)
    }

    /// The block whose name seat is a field, and how wide the field is (Law 0007).
    struct Naming: Equatable {
        let index: Int
        let chip: UInt64
        let width: CGFloat
    }

    var naming: Naming?

    /// Where the chip with `chip` as its id stands on this page, if it does.
    func chipIndex(ofChip chip: UInt64) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard (value as? ChipAttachment)?.info.chipId == chip else { return }
            found = range.location
            stop.pointee = true
        }
        return found
    }

    /// Whether another text view or field holds the keys, in this window or
    /// in a key window over it, so the page's chords stand aside (Law 0007, keys row).
    var yieldsKeys: Bool { yieldsKeys(toAnyBut: nil) }

    /// Whether a text view other than this one and `source` holds the keys, in this
    /// window or in a key window over it: a drag's source holds them for its own gesture.
    func yieldsKeys(toAnyBut source: NSView?) -> Bool {
        if keysHeldInAnotherWindow(besides: source) { return true }
        guard let holder = window?.firstResponder as? NSTextView else { return false }
        return holder !== self && holder !== source
    }

    /// Whether this surface answers its chords and Edit menu: a note while it
    /// holds the keys, the page unless another text view does (Law 0007, keys row).
    var answersChords: Bool {
        guard coordinator?.writesNote == true else { return !yieldsKeys }
        return window?.firstResponder === self && !keysHeldInAnotherWindow()
    }

    /// A text field in another key window, such as a pad's in Settings, other than `source`.
    private func keysHeldInAnotherWindow(besides source: NSView? = nil) -> Bool {
        guard let key = NSApp?.keyWindow, key !== window,
              let holder = key.firstResponder as? NSTextView
        else { return false }
        return holder !== source
    }

    /// The sealed block's cell standing at `index`, if one does.
    func chipCell(at index: Int) -> SealedBlockCell? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.attachment, at: index, effectiveRange: nil) as? ChipAttachment)?
            .attachmentCell as? SealedBlockCell
    }

    /// The named row's zone under `point` on the block at `index`; nil
    /// off the row, between runs, and on an unnamed block.
    func chipZone(at point: NSPoint, chipAt index: Int) -> SealedBlockLayout.Zone? {
        guard naming?.index != index,
              let frame = chipFrame(at: index), let cell = chipCell(at: index)
        else { return nil }
        return cell.namedRow(in: frame)?.geometry.zone(at: point)
    }

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        applyHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Re-run the hover hit test against wherever the pointer is now.
    /// Scrolling moves content under a stationary pointer and sends no
    /// mouse event, so without this the block that was hovered before
    /// the scroll stays expanded and the one now under the pointer
    /// stays compact until the mouse moves again.
    func refreshHover() {
        guard let window else {
            applyHover(at: nil)
            return
        }
        #if DEBUG
            let screenPointer = hoverRefreshInput?.screenPoint ?? NSEvent.mouseLocation
            let holdsKeys = hoverRefreshInput?.holdsKeys ?? window.isKeyWindow
            let pointsIntoWindow = hoverRefreshInput?.pointsIntoWindow ?? (
                NSWindow.windowNumber(
                    at: screenPointer, belowWindowWithWindowNumber: 0
                ) == window.windowNumber
            )
        #else
            let screenPointer = NSEvent.mouseLocation
            let holdsKeys = window.isKeyWindow
            let pointsIntoWindow = NSWindow.windowNumber(
                at: screenPointer, belowWindowWithWindowNumber: 0
            ) == window.windowNumber
        #endif
        let pointer = convert(window.convertPoint(fromScreen: screenPointer), from: nil)
        applyHover(at: Self.hoverPoint(
            pointer: pointer, visibleRect: visibleRect,
            holdsKeys: holdsKeys, pointsIntoWindow: pointsIntoWindow
        ))
    }

    /// The point hover should resolve against, or nil to clear it. A
    /// window without keys shows no hover, matching the tracking area's
    /// `.activeInKeyWindow`, and a pointer over another window or outside
    /// the visible rect is over nothing on this page. Containment follows
    /// `NSRect.contains`, so the max edges are outside.
    nonisolated static func hoverPoint(
        pointer: NSPoint, visibleRect: NSRect,
        holdsKeys: Bool, pointsIntoWindow: Bool = true
    ) -> NSPoint? {
        guard holdsKeys, pointsIntoWindow, visibleRect.contains(pointer) else { return nil }
        return pointer
    }

    private func applyHover(at point: NSPoint?) {
        let index = point.flatMap { coordinator?.chipIndex(at: $0, in: self) }
        let zone = index.flatMap { index in point.flatMap { chipZone(at: $0, chipAt: index) } }
        let zoneMoved = zone != hoveredZone
        hoveredZone = zone
        hoveredChipIndex = index
        if zoneMoved, let index { redrawChip(at: index) }
        coordinator?.updateBlockMetadataHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        applyHover(at: nil)
    }

    /// Whether the block at `index` draws its handles: while it is hovered or selected
    /// (sealed row spec, The handles).
    func drawsHandles(at index: Int) -> Bool {
        hoveredChipIndex == index || selectedRange() == NSRange(location: index, length: 1)
    }

    /// The blocks drawing their handles, in page order.
    private var blocksWithHandles: [Int] {
        Set([hoveredChipIndex, selectedRange().location].compactMap { $0 }).sorted()
            .filter(drawsHandles(at:))
    }

    /// Each drawn handle a press would start the decrypted drag from, so none while
    /// another field or the note holds the keys (sealed row spec, Press).
    var decryptedDragCursorRects: [NSRect] { handleCursorRects(.decrypted) }

    /// Each drawn move handle a press would drag the object from (issue 255).
    var moveHandleCursorRects: [NSRect] { handleCursorRects(.move) }

    private func handleCursorRects(_ handle: SealedBlockCell.Handle) -> [NSRect] {
        guard answersChords else { return [] }
        return blocksWithHandles.compactMap { index in
            guard let frame = chipFrame(at: index),
                  let rect = chipCell(at: index)?.handleRect(handle, in: frame)
            else { return nil }
            let shown = rect.intersection(visibleRect)
            return shown.isEmpty ? nil : shown
        }
    }

    /// An open hand over each handle a press would drag from, the drag affordance macOS uses.
    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in decryptedDragCursorRects + moveHandleCursorRects {
            addCursorRect(rect, cursor: .openHand)
        }
    }

    private struct HandleElementKey: Hashable {
        let index: Int
        let handle: SealedBlockCell.Handle
    }

    /// The elements VoiceOver reaches the handles by, kept between asks so a focused one
    /// stays the same object while its block stands.
    private var handleElements: [HandleElementKey: NSAccessibilityElement] = [:]

    /// One labelled element per drawn handle, at the handle's seat (issue 255).
    func handleAccessibilityElements() -> [NSAccessibilityElement] {
        var kept: [HandleElementKey: NSAccessibilityElement] = [:]
        var elements: [NSAccessibilityElement] = []
        for index in blocksWithHandles {
            guard let frame = chipFrame(at: index), let cell = chipCell(at: index) else { continue }
            for handle in SealedBlockCell.Handle.allCases {
                guard let rect = cell.handleRect(handle, in: frame) else { continue }
                let key = HandleElementKey(index: index, handle: handle)
                let element = handleElements[key] ?? makeHandleElement(handle)
                element.setAccessibilityFrameInParentSpace(accessibilityParentSpaceRect(rect))
                kept[key] = element
                elements.append(element)
            }
        }
        handleElements = kept
        return elements
    }

    /// `rect`, drawn in this flipped view, in the space a child element's parent space frame
    /// is read in: the view's bounds with the origin at the lower left.
    func accessibilityParentSpaceRect(_ rect: NSRect) -> NSRect {
        guard isFlipped else { return rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        return NSRect(
            x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY,
            width: rect.width, height: rect.height)
    }

    private func makeHandleElement(_ handle: SealedBlockCell.Handle) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.handle)
        element.setAccessibilityLabel(handle.accessibilityLabel)
        element.setAccessibilityParent(self)
        return element
    }

    /// The hover, the selection or the keys moved, so the handles' cursor rects are stale.
    func handlesMayHaveMoved() {
        window?.invalidateCursorRects(for: self)
    }

    func redrawChip(at index: Int) {
        guard let layoutManager, let textContainer,
              let storage = textStorage, index < storage.length else { return }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
    }

    /// Only the first primary click without a gesture modifier may activate
    /// the actions seat. State flags such as Caps Lock do not change the
    /// gesture; modified gestures and later clicks stay on AppKit's path.
    nonisolated static func shouldOpenChipActions(
        clickCount: Int, modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        clickCount == 1
            && modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
    }

    /// A first Control-primary click is the secondary-click gesture. State
    /// flags do not alter it, while additional gesture modifiers leave it
    /// to AppKit.
    nonisolated static func shouldOpenChipContextMenu(
        clickCount: Int, modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        clickCount == 1
            && modifierFlags.intersection([.command, .shift, .control, .option]) == .control
    }

    /// An editable page takes the click that brings its window forward,
    /// so the first click on blank space focuses rather than merely
    /// activating.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isEditable || super.acceptsFirstMouse(for: event)
    }

    /// How far past the doorway's word a click still opens the note.
    static let doorwaySlop: CGFloat = 3

    /// The zone a click acts on: the one under it, once the seat has named
    /// it under the pointer, and otherwise none (Law 0001, zone gate row).
    nonisolated static func actingZone(
        pointed: SealedBlockLayout.Zone?, index: Int,
        hoveredIndex: Int?, hoveredZone: SealedBlockLayout.Zone?
    ) -> SealedBlockLayout.Zone? {
        guard let pointed, hoveredIndex == index, hoveredZone == pointed else { return nil }
        return pointed
    }

    /// What a primary click on a sealed block does past its actions seat
    /// (Law 0001, unnamed row and zone rows).
    enum ChipClick: Equatable {
        /// AppKit's path, whose delegate selects the whole object (D-40).
        case select
        /// A named row's zone, on its first click.
        case copy(SealedBlockLayout.Zone)
        /// The name field, from a double click (Law 0007).
        case openName
        /// The note, from a click on the seat's `note` (Law 0001).
        case openNote
        /// A later click on a zone that acted on its first.
        case ignore
    }

    /// Pure, so the rule is an assertion. A named row opens the field only
    /// from the name zone; an unnamed one from anywhere on its row.
    nonisolated static func chipClick(
        named: Bool, zone: SealedBlockLayout.Zone?, inRow: Bool, onDoorway: Bool = false,
        clickCount: Int, modifierFlags: NSEvent.ModifierFlags
    ) -> ChipClick {
        guard modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        else { return .select }
        if onDoorway { return clickCount == 1 ? .openNote : .ignore }
        guard named else {
            guard inRow, clickCount >= 2 else { return .select }
            return clickCount == 2 ? .openName : .ignore
        }
        guard let zone else { return .select }
        switch clickCount {
        case 1: return .copy(zone)
        case 2 where zone == .name: return .openName
        default: return .ignore
        }
    }

    /// A click on the explicit actions affordance opens the object's menu.
    /// Control-primary over a chip takes the same direct route as a
    /// secondary click, avoiding text-system additions to the menu. A
    /// named row's zones copy (`chipClick`). Every other primary click
    /// stays on AppKit's attachment path, whose delegate selects the
    /// object without opening anything.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if Self.shouldFocusBlankSpace(
            isEditable: isEditable, clickCount: event.clickCount,
            modifierFlags: event.modifierFlags,
            containsTextLine: containsTextLine(at: point)
        ), consumeBlankFocusClick(event) {
            return
        }
        guard let coordinator, let index = coordinator.chipIndex(at: point, in: self) else {
            super.mouseDown(with: event)
            return
        }
        if Self.shouldOpenChipContextMenu(
            clickCount: event.clickCount, modifierFlags: event.modifierFlags)
            || (Self.shouldOpenChipActions(
                clickCount: event.clickCount, modifierFlags: event.modifierFlags)
                && chipFrame(at: index).map { SealedBlockCell.actionsRect(in: $0).contains(point) }
                    == true)
        {
            setSelectedRange(NSRange(location: index, length: 1))
            coordinator.openChipMenu(at: index, from: point, in: self)
            return
        }
        let frame = chipFrame(at: index)
        let cell = chipCell(at: index)
        let pressed = frame.flatMap { cell?.handle(at: point, in: $0) }
        if Self.startsHandleDrag(
            onHandle: pressed != nil, handleShown: drawsHandles(at: index),
            clickCount: event.clickCount, modifierFlags: event.modifierFlags),
            let handle = pressed, let frame, let rect = cell?.handleRect(handle, in: frame)
        {
            trackHandlePress(from: event, chipAt: index) { moved in
                switch handle {
                case .decrypted: beginDecryptedDrag(chipAt: index, handle: rect, event: moved)
                case .move: beginMoveDrag(chipAt: index, event: moved)
                }
            }
            return
        }
        switch Self.chipClick(
            named: cell?.info.name != nil,
            zone: Self.actingZone(
                pointed: chipZone(at: point, chipAt: index), index: index,
                hoveredIndex: hoveredChipIndex, hoveredZone: hoveredZone),
            inRow: frame.map { SealedBlockCell.contentLayout(in: $0).rowBand.contains(point) }
                ?? false,
            onDoorway: frame.flatMap { cell?.doorwayRect(in: $0) }.map {
                $0.insetBy(dx: -Self.doorwaySlop, dy: -Self.doorwaySlop).contains(point)
            } ?? false,
            clickCount: event.clickCount, modifierFlags: event.modifierFlags)
        {
        case .copy(let zone):
            if coordinator.copy(zone, chipAt: index) { beginCopyBeat(zone, at: index) }
        case .openName:
            coordinator.beginNaming(at: index)
        case .openNote:
            coordinator.beginNote(at: index)
        case .ignore:
            return
        case .select:
            super.mouseDown(with: event)
        }
    }

    /// Only a first plain press on a handle while it is drawn starts its drag.
    nonisolated static func startsHandleDrag(
        onHandle: Bool, handleShown: Bool, clickCount: Int, modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        onHandle && handleShown
            && shouldOpenChipActions(clickCount: clickCount, modifierFlags: modifierFlags)
    }

    /// How far a press on a handle travels before it becomes a drag.
    nonisolated static let decryptedDragSlop: CGFloat = 3

    nonisolated static func pressBecomesDrag(from start: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= decryptedDragSlop
    }

    /// A press on a handle: once it moves, `begin` starts the handle's drag; a press that
    /// lifts first selects the object, as a click elsewhere on the block does.
    private func trackHandlePress(
        from event: NSEvent, chipAt index: Int, begin: (NSEvent) -> Void
    ) {
        guard let window else { return }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true)
            else {
                if NSEvent.pressedMouseButtons & 1 == 0 { return }
                continue
            }
            if next.type == .leftMouseUp {
                setSelectedRange(NSRange(location: index, length: 1))
                return
            }
            if Self.pressBecomesDrag(from: event.locationInWindow, to: next.locationInWindow) {
                begin(next)
                return
            }
        }
    }

    /// The session, its image the handle as drawn rather than the block (sealed row spec, Pointer and image).
    private func beginDecryptedDrag(chipAt index: Int, handle: NSRect, event: NSEvent) {
        guard let (source, item) = coordinator?.beginDecryptedDrag(at: index) else { return }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: handle.size)
        if let snapshot = bitmapImageRepForCachingDisplay(in: handle) {
            cacheDisplay(in: handle, to: snapshot)
            image.addRepresentation(snapshot)
        }
        dragging.setDraggingFrame(handle, contents: image)
        startDraggingSession([dragging], event: event, source: source, slideBack: true)
    }

    /// A drag from an object's face or its move handle is the page's own drag, by the same
    /// session, of the selection the object is in, or of the object alone (Law 0001, move drag row).
    func beginMoveDrag(chipAt index: Int, event: NSEvent) {
        if !NSLocationInRange(index, selectedRange()) {
            setSelectedRange(NSRange(location: index, length: 1))
        }
        _ = dragSelection(with: event, offset: .zero, slideBack: true)
    }

    #if DEBUG
        /// Takes every session this view would start, in place of AppKit, so a test can read
        /// the items and the source without a pointer (ADR-0018 seam).
        var dragSessionWitness: (([NSDraggingItem], NSDraggingSource) -> Void)?
    #endif

    /// Every drag this view starts, the page's or the decrypted one, leaves through here.
    private func startDraggingSession(
        _ items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource, slideBack: Bool
    ) {
        #if DEBUG
            if let dragSessionWitness {
                dragSessionWitness(items, source)
                return
            }
        #endif
        let session = beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = slideBack
        session.draggingFormation = .none
    }

    /// Plain blank-space clicks preserve the existing caret even if the
    /// editor already has focus. This is the requested page-wide focus
    /// gesture; modified and repeated clicks retain native selection.
    nonisolated static func shouldFocusBlankSpace(
        isEditable: Bool, clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags, containsTextLine: Bool
    ) -> Bool {
        isEditable && !containsTextLine && shouldOpenChipActions(
            clickCount: clickCount, modifierFlags: modifierFlags
        )
    }

    /// A mouse-down alone cannot distinguish a focus click from selection
    /// dragged out of blank space. Peek at the next tracking event: leave
    /// a drag queued for NSTextView, or consume the up for a focus click.
    /// Short waits permit a missing mouse-up to end when the button has
    /// been released, rather than keeping the tracking loop alive forever.
    func consumeBlankFocusClick(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        while true {
            if let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking, dequeue: false
            ) {
                guard next.type == .leftMouseUp else { return false }
                _ = window.nextEvent(
                    matching: .leftMouseUp, until: .distantPast,
                    inMode: .eventTracking, dequeue: true
                )
                window.makeFirstResponder(self)
                return true
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                window.makeFirstResponder(self)
                return true
            }
        }
    }

    /// A line's full horizontal band uses native text selection, including
    /// the empty tail of a line and the final empty paragraph. Resolve only
    /// the line nearest the click rather than walking every line in a file.
    func containsTextLine(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer else { return false }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard local.y >= 0 else { return false }
        layoutManager.ensureLayout(forBoundingRect: NSRect(
            x: 0, y: local.y, width: max(1, textContainer.size.width), height: 1
        ), in: textContainer)
        let extra = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer === textContainer,
           local.y >= extra.minY && local.y < extra.maxY {
            return true
        }
        guard layoutManager.numberOfGlyphs > 0 else { return false }
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return false }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return local.y >= line.minY && local.y < line.maxY
    }

    /// The frame the block at `index` is drawn with, in this view's
    /// coordinates, so a click can be tested against the drawn actions
    /// seat. It is derived the way the layout manager derives the frame
    /// it hands the cell: the glyph's location on its line fragment is
    /// where the cell is set down, its bottom left corner with the
    /// cell's baseline offset already folded in, and in this flipped
    /// view the block stands one attachment height above that point.
    /// The glyph's bounding rect is not that frame: it takes the line's
    /// used height at the glyph's column, so whenever ink shares the
    /// line and rises above the block the bounding rect starts above
    /// the block and stands taller than it, and a seat computed off it
    /// misses the drawn glyph.
    func chipFrame(at index: Int) -> NSRect? {
        guard let layoutManager, textContainer != nil,
              let storage = textStorage, index < storage.length,
              storage.attribute(.attachment, at: index, effectiveRange: nil) is ChipAttachment
        else { return nil }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard glyphs.length == 1 else { return nil }
        let glyph = glyphs.location
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let size = layoutManager.attachmentSize(forGlyphAt: glyph)
        return NSRect(
            x: textContainerOrigin.x + line.minX + location.x,
            y: textContainerOrigin.y + line.minY + location.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The secondary click over a chip pops the object's menu up here,
    /// through the same call the glyph and Return take, rather than
    /// handing AppKit a menu to show: the text system's own pop-up
    /// appends AutoFill and Services to whatever `menu(for:)` returns,
    /// and a sealed object offers neither (D-41). Over ink the click is
    /// AppKit's.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinator, let index = coordinator.chipIndex(at: point, in: self) else {
            super.rightMouseDown(with: event)
            return
        }
        setSelectedRange(NSRange(location: index, length: 1))
        coordinator.openChipMenu(at: index, from: point, in: self)
    }

    /// The context menu. Over a chip it is the chip's own: the object
    /// is selected whole first, as a plain click selects it, and the
    /// text menu AppKit would build is not consulted, because Cut and
    /// Copy of a sealed object are not the text menu's to offer. Over
    /// ink it is AppKit's menu with the page's items appended.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let coordinator, let index = coordinator.chipIndex(at: point, in: self) {
            setSelectedRange(NSRange(location: index, length: 1))
            return coordinator.chipMenu(at: index)
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if let coordinator, !coordinator.writesNote, !coordinator.writesFile {
            TextOffers.removeUncarriedTransformations(from: menu)
        }
        aimLinkItems(in: menu, at: point)
        coordinator?.appendSealItem(to: menu)
        coordinator?.appendLanguageItems(to: menu)
        return menu
    }

    // MARK: Links in the text menu (ADR-0023, Law 0001)

    /// The link a text menu item acts on, found under the pointer as the menu was built.
    struct LinkTarget {
        let link: Any
        let index: Int
    }

    /// Sends Open Link to the delegate's `openLink`, and a page's or a note's Copy Link through
    /// the gate any copy asks; there, one with no link found under the pointer leaves.
    private func aimLinkItems(in menu: NSMenu, at point: NSPoint) {
        let target = linkTarget(at: point)
        let asks = coordinator?.writesFile != true
        for item in menu.items {
            let ours: Selector
            switch item.action {
            case TextOffers.openLinkAction: ours = #selector(openLinkFromMenu(_:))
            case TextOffers.copyLinkAction where asks: ours = #selector(copyLinkFromMenu(_:))
            default: continue
            }
            guard let target else {
                if asks { menu.removeItem(item) }
                continue
            }
            item.target = self
            item.action = ours
            item.representedObject = target
        }
    }

    /// The link drawn under `point`, in this view's coordinates.
    func linkTarget(at point: NSPoint) -> LinkTarget? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0
        else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .contains(local)
        else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let link = storage.attribute(.link, at: index, effectiveRange: nil)
        else { return nil }
        return LinkTarget(link: link, index: index)
    }

    /// Open Link, which the delegate opens as it does a ⌘-click (`Coordinator.openLink`).
    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? LinkTarget else { return }
        coordinator?.openLink(target.link, from: self)
    }

    /// Copy Link, which asks first like any copy and writes the URL on the model's ambient board.
    @objc func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? LinkTarget,
              let url = (target.link as? URL) ?? (target.link as? String).flatMap(URL.init(string:)),
              let board = coordinator?.model.ambientPasteboard, mayReadOut
        else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        board.clearContents()
        board.writeObjects([item])
    }

    // MARK: AppKit's readers of the text (Law 0001, expiry row and AppKit's text routes)

    /// Not while another surface holds the keys (Law 0007, keys row); past the page's deadline it settles.
    override var mayReadOut: Bool { answersChords && givesOutShownText }

    /// A file's text menu keeps them all.
    override var keepsSelectionReaders: Bool { coordinator?.writesFile == true }

    /// What a check of a page's or a note's text applies at once, as Substitutions'
    /// replace actions ask, is one step.
    override func checkText(
        in range: NSRange, types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:]
    ) {
        guard let coordinator, !coordinator.writesFile else {
            return super.checkText(in: range, types: checkingTypes, options: options)
        }
        coordinator.asOneEdit(.replacement) {
            super.checkText(in: range, types: checkingTypes, options: options)
        }
    }

    // MARK: AppKit's rewrites of the selection (Law 0001, D-30)

    /// Make Upper Case: the ink changes and every object stands, as one step.
    override func uppercaseWord(_ sender: Any?) {
        rewriting { super.uppercaseWord(sender) }
    }

    /// Make Lower Case, as Make Upper Case.
    override func lowercaseWord(_ sender: Any?) {
        rewriting { super.lowercaseWord(sender) }
    }

    /// Capitalize, as Make Upper Case.
    override func capitalizeWord(_ sender: Any?) {
        rewriting { super.capitalizeWord(sender) }
    }

    /// The spelling panel's Change, refused with the line over a selection holding an object.
    override func changeSpelling(_ sender: Any?) {
        rewriting { super.changeSpelling(sender) }
    }

    /// A page's rewrite stands aside while another surface holds the keys (Law 0007, keys row).
    private func rewriting(_ rewrite: () -> Void) {
        guard let coordinator, !coordinator.writesNote, !coordinator.writesFile else {
            return withEditIntent(.replacement, perform: rewrite)
        }
        guard answersChords else { return }
        coordinator.rewritingInk(rewrite)
    }

    /// A resize rewraps paragraphs without touching their content, so
    /// the block affordances (ADR-0013) are re-decided and moved from
    /// their own displays, never recomputed from the core: no round trip,
    /// cheap enough to run on every layout pass.
    override func layout() {
        updateChipEditorMeasure()
        super.layout()
        coordinator?.refitBlockLabels()
        coordinator?.followNaming()
        coordinator?.followNote()
    }

    /// TextKit's attachment sizing callback is explicitly nonisolated,
    /// while an editor's bounds are main-actor state. Capture the scalar
    /// measure here, before layout, into each cell's lock-protected sizing
    /// state so the callback never reaches across actor isolation.
    private func updateChipEditorMeasure() {
        guard let container = textContainer as? InkTextContainer, let layoutManager else { return }
        // In unwrapped mode the text view can grow to its longest line;
        // the scroll viewport remains the page measure the chip should
        // occupy. A mount without a scroller uses its editor bounds.
        // Either way the container inset comes off both edges, as it
        // does for the ink, so a block is never wider than the page it
        // sits on. A viewport not yet sized measures nothing, and a
        // zero captured as the ceiling would refuse every candidate and
        // drop every block to the floor, so an earlier capture is left
        // in place until a real measure arrives.
        let viewport = enclosingScrollView?.contentSize.width ?? bounds.width
        let measure = viewport - textContainerInset.width * 2
        guard measure > 0 else { return }
        if container.setEditorMeasure(measure) {
            layoutManager.textContainerChangedGeometry(container)
        }
    }

    /// The page's own chords, which the keymap names and this view
    /// answers: the sealed paste and the seal of a selection or a line
    /// (⇧⌘V and ⌘↩ by default, `clipboard::Seal` and
    /// `clipboard::SealSelection` by id).
    ///
    /// A key equivalent reaches the view chain before the surface's
    /// hidden buttons get a look, which is why these two live here and
    /// not in `PageKeyboardMap`: what they act on is the caret and the
    /// selection, and both belong to this text view.
    ///
    /// Only command-bearing chords are taken on this route. A chord
    /// without ⌘ is an ordinary character to every other text field on
    /// screen, and claiming one here would claim it app-wide; those go
    /// through `keyDown` below, which fires only while this page holds
    /// the keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if answersChords, let command = editorCommand(for: event),
           command.modifiers.contains(.command), dispatch(command.id) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The Edit menu's Undo, which sends `undo:` down the responder
    /// chain to whoever is first responder, and while a page is being
    /// typed into that is this view.
    ///
    /// Overridden so the mouse route and the keyboard route reach the
    /// same stack (issue #132). Without this the item would walk past
    /// the page to `NSUndoManager`, which is a different history of the
    /// same document and does not know which operations this device
    /// authored. The chord is intercepted in `performKeyEquivalent`
    /// above; a click on the menu never goes near it, so a second door
    /// had to be closed rather than assumed shut.
    /// Editability gates both routes, for the reason it gates the
    /// chord: a page shown read-only must not be rewritten from a menu
    /// either. The guard itself sits inside `step`, where every route
    /// meets, rather than being spelled once per door.
    @objc func undo(_ sender: Any?) {
        guard answersChords else { return }
        coordinator?.step(back: true)
    }

    @objc func redo(_ sender: Any?) {
        guard answersChords else { return }
        coordinator?.step(back: false)
    }

    /// Edit → Seal Selected Content, arriving nil-targeted. The same
    /// method the chord and the context menu row run; a page shown
    /// read-only refuses it here, as it refuses the chord.
    @objc func sealSelectedContent(_ sender: Any?) {
        guard isEditable, answersChords else { return }
        coordinator?.sealSelectionOrLine()
    }

    /// The answer for any nil-targeted item that asks this view about
    /// the two step actions: the core's, because the core holds the
    /// stack, and `NSTextView`'s own for everything else the menu asks
    /// about.
    ///
    /// The app's Edit menu is nil-targeted, so this is also what greys
    /// its two items while the editor is first responder. A native field
    /// editor answers the same selectors through AppKit's own validation.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let document = coordinator?.document, let model = coordinator?.model else {
            return super.validateMenuItem(item)
        }
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)):
            let back = item.action == #selector(undo(_:))
            let verb = back ? "Undo" : "Redo"
            item.title = model.editStepName(document, back: back).map { "\(verb) \($0)" } ?? verb
            return isEditable && answersChords && model.canStepEdit(document, back: back)
        case #selector(detectCodeLanguage(_:)):
            return canDetectCodeLanguage
        case #selector(chooseCodeLanguage(_:)):
            return canChooseCodeLanguage
        case #selector(pasteWithoutDetection(_:)):
            return PageModel.languageDetectionFeaturesAvailable && isEditable && answersChords
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)),
             #selector(pasteAsPlainText(_:)):
            return answersChords && super.validateMenuItem(item)
        case #selector(selectAll(_:)) where coordinator?.writesNote != true:
            return answersChords && super.validateMenuItem(item)
        default:
            return super.validateMenuItem(item)
        }
    }

    /// The page's chords that carry no ⌘ (⌥Z, the wrap toggle, by
    /// default).
    ///
    /// Handled as a key press on the page rather than as a menu item's
    /// key equivalent, and deliberately: a main-menu equivalent is an
    /// app-wide claim, and ⌥Z is a character (Ω) that the find bar's
    /// search field and every Settings field have as much right to
    /// receive as this view has to steal it. Scoped here, it only fires
    /// while the page itself holds the keyboard.
    override func keyDown(with event: NSEvent) {
        if let command = editorCommand(for: event), !command.modifiers.contains(.command),
           dispatch(command.id) {
            return
        }
        // Return or Space over a selected sealed object opens its menu
        // rather than typing over it (D-40): the object is a block the
        // keyboard has landed on, and the two keys that would replace
        // it with a newline or a space are the two that ask it what may
        // be done instead. The object's own keys, not chords, so they
        // are not the keymap's; anywhere else they type as they always
        // did.
        if Self.opensObjectMenu(characters: event.charactersIgnoringModifiers,
                                modifiers: event.modifierFlags),
           let coordinator, let index = coordinator.selectedChipIndex {
            coordinator.openChipMenu(at: index, from: menuAnchor(forChipAt: index), in: self)
            return
        }
        super.keyDown(with: event)
    }

    /// Whether a key press is Return or Space with no modifier held:
    /// the two keys that open a selected object's menu. Pure, so the
    /// decision is an assertion; the guard on the selection is the
    /// caller's.
    nonisolated static func opensObjectMenu(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              let characters, characters.count == 1, let key = characters.first
        else { return false }
        return key == "\r" || key == "\n" || key == " "
    }

    /// Where a menu opened from the keyboard appears: under the block's
    /// leading edge, where the block's own words begin, so the menu
    /// reads as the block's rather than the caret's.
    private func menuAnchor(forChipAt index: Int) -> NSPoint {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return NSPoint(
            x: rect.minX + textContainerOrigin.x + 12,
            y: rect.maxY + textContainerOrigin.y
        )
    }

    /// What the keymap says this event means on the Editor surface,
    /// with the modifiers it was bound with, so the two routes above
    /// can each take the half that is theirs. Nil when nothing is bound
    /// or when the command belongs to the surface rather than to the
    /// page.
    private func editorCommand(for event: NSEvent) -> (id: CommandID, modifiers: KeyModifiers)? {
        guard let keymap = coordinator?.model.keymap else { return nil }
        guard
            let binding = keymap.bindings(in: .editor, dispatch: .editor)
                .first(where: { $0.keystroke.matches(event: event) })
        else { return nil }
        return (binding.command, binding.keystroke.modifiers)
    }

    /// Runs an editor command, and says whether it ran. The two seal
    /// gestures are this view's; everything else the keymap can put on
    /// the editor route is the model's.
    private func dispatch(_ command: CommandID) -> Bool {
        guard let coordinator else { return false }
        switch command {
        case .clipboardSeal:
            coordinator.sealedPaste()
        case .clipboardSealSelection:
            coordinator.sealSelectionOrLine()
        case .chipCopyDecrypted:
            // Only over exactly one selected object: anywhere else the
            // chord is declined rather than swallowed, so it falls
            // through to whatever else would have had it and never
            // reaches a payload nobody pointed at (D-29).
            guard let index = coordinator.selectedChipIndex else { return false }
            coordinator.copyOutChip(at: index)
        case .editorDetectCodeLanguage:
            guard PageModel.languageDetectionFeaturesAvailable,
                  coordinator.model.languageDetectionEnabled,
                  isEditable
            else { return false }
            coordinator.detectCodeLanguage()
        case .editorUndo, .editorRedo:
            // A resting card and a page shown read-only both arrive
            // here with editing off, and a chord that rewrote the
            // document from either would be an edit made where typing
            // is refused. `step` refuses it too; this guard is about
            // the answer, not the refusal. The press is declined rather
            // than swallowed, so it falls through to whatever else
            // would have had it.
            guard isEditable else { return false }
            coordinator.step(back: command == .editorUndo)
        case .noteToggleExpanded:
            guard let note = coordinator.noteHost else { return false }
            note.toggleExpanded()
        case .editorToggleWrap where coordinator.writesNote:
            // A note always wraps; the page's setting is not the note's to flip.
            return false
        default:
            return coordinator.model.perform(command)
        }
        return true
    }

    /// A fragment pastes through the core; other paste stays plain, with Option bypassing
    /// automatic fencing once. Stands aside while another surface holds the keys (Law 0007, keys row).
    override func paste(_ sender: Any?) {
        guard answersChords else { return }
        if coordinator?.pasteFragment() == true { return }
        let bypass = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        performOrdinaryPaste(sender, bypassingAutomaticFencing: bypass) { [unowned self] sender in
            pasteAsPlainText(sender)
        }
    }

    /// A page copies by the core's fragment and stands aside while another
    /// surface holds the keys (Law 0007, keys row); a note or a file copies as AppKit does.
    override func copy(_ sender: Any?) {
        guard answersChords else { return }
        guard let coordinator, !coordinator.writesNote,
              let sheet = coordinator.currentSheet, !sheet.isFileID
        else {
            guard givesOutShownText else { return }
            return copyAsAppKitDoes(sender)
        }
        coordinator.copySelection()
    }

    /// AppKit's copy of the selection, written on the model's ambient board, which a
    /// test replaces, rather than the general board `super.copy` names.
    private func copyAsAppKitDoes(_ sender: Any?) {
        guard let board = coordinator?.model.ambientPasteboard else { return super.copy(sender) }
        guard selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
        _ = super.writeSelection(to: board, types: writablePasteboardTypes)
    }

    /// Whether AppKit may write out what this view shows (Law 0001, expiry row); a bare view may.
    private var givesOutShownText: Bool {
        coordinator?.givesOutShownText() ?? true
    }

    /// The page's select all stands aside while another surface holds the keys.
    override func selectAll(_ sender: Any?) {
        if coordinator?.writesNote != true, !answersChords { return }
        super.selectAll(sender)
    }

    /// A page cuts through the core, never by `super.cut`, whose `copy:` writes
    /// a copy's fragment; a note, a file and ink stretches cut as AppKit does.
    override func cut(_ sender: Any?) {
        guard answersChords else { return }
        if let coordinator, !coordinator.writesNote,
           let sheet = coordinator.currentSheet, !sheet.isFileID,
           coordinator.cutSelection() != .inkStretches
        { return }
        guard givesOutShownText else { return }
        withEditIntent(.cut) {
            super.cut(sender)
        }
    }

    // MARK: Services and other requesters of the page's selection (Law 0001)

    /// A selection holding an object offers a requester the copy's two types alone.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        guard coordinator?.selectionHoldsObject == true else { return super.writablePasteboardTypes }
        return [SealedFragment.pasteboardType, .string, SealedFragment.legacyStringType]
    }

    /// No service is offered while another surface holds the keys (Law 0007, keys row), nor
    /// one that would write its answer over a selection holding an object.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        guard answersChords else { return nil }
        if returnType != nil, coordinator?.selectionHoldsObject == true { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// A selection holding an object is written as the copy composes it, in whichever
    /// of its two types were asked for; any other selection writes as AppKit does.
    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let composition = requestedComposition() else {
            guard givesOutShownText else { return false }
            return super.writeSelection(to: pboard, types: types)
        }
        guard case .composed(let fragment) = composition,
              let item = fragment.pasteboardItem(offering: types)
        else { return false }
        pboard.clearContents()
        return pboard.writeObjects([item])
    }

    override func writeSelection(
        to pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let composition = requestedComposition() else {
            guard givesOutShownText else { return false }
            return super.writeSelection(to: pboard, type: type)
        }
        guard case .composed(let fragment) = composition else { return false }
        if type == .string || type == SealedFragment.legacyStringType {
            return pboard.setString(fragment.plainText, forType: .string)
        }
        guard type == SealedFragment.pasteboardType, let envelope = fragment.envelope
        else { return false }
        return pboard.setData(envelope, forType: type)
    }

    /// The copy's composition of a page selection holding an object; nil for AppKit
    /// to write any other, and refused whole while another surface holds the keys.
    private func requestedComposition() -> PageModel.SelectionComposition? {
        guard answersChords else { return .refused }
        guard let coordinator, coordinator.selectionHoldsObject else { return nil }
        let composition = coordinator.composeSelection()
        if let composition, let line = PageModel.refusalLine(for: composition, .copy) {
            coordinator.model.flash(line)
        }
        return composition
    }

    override func deleteBackward(_ sender: Any?) {
        deleting(forward: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        deleting(forward: true) { super.deleteForward(sender) }
    }

    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        deleting(forward: false) { super.deleteBackwardByDecomposingPreviousCharacter(sender) }
    }

    override func deleteWordBackward(_ sender: Any?) {
        deleting(forward: false) { super.deleteWordBackward(sender) }
    }

    override func deleteWordForward(_ sender: Any?) {
        deleting(forward: true) { super.deleteWordForward(sender) }
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleting(forward: false) { super.deleteToBeginningOfLine(sender) }
    }

    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleting(forward: false) { super.deleteToBeginningOfParagraph(sender) }
    }

    override func deleteToEndOfLine(_ sender: Any?) {
        deleting(forward: true) { super.deleteToEndOfLine(sender) }
    }

    override func deleteToEndOfParagraph(_ sender: Any?) {
        deleting(forward: true) { super.deleteToEndOfParagraph(sender) }
    }

    /// The mark may stand on either side of the caret, so no first press is taken.
    override func deleteToMark(_ sender: Any?) {
        deleting(forward: nil) { super.deleteToMark(sender) }
    }

    /// Edit > Delete takes the selection alone; a caret deletes nothing.
    override func delete(_ sender: Any?) {
        deleting(forward: nil) { super.delete(sender) }
    }

    /// ⌃Y writes the kill buffer over the selection, which may hold an object.
    override func yank(_ sender: Any?) {
        deleting(forward: nil, intent: .paste) { super.yank(sender) }
    }

    /// Every page deletion: a caret beside an object in `forward`'s direction selects it (D-30),
    /// and nothing goes while another surface holds the keys (Law 0007, keys row).
    private func deleting(
        forward: Bool?, intent: EditorEditIntent = .deletion, _ delete: () -> Void
    ) {
        guard let coordinator, !coordinator.writesNote else {
            return withEditIntent(intent, perform: delete)
        }
        guard answersChords else { return }
        if let forward, coordinator.selectObjectBeside(forward: forward) { return }
        withEditIntent(intent, perform: delete)
    }

    var canDetectCodeLanguage: Bool {
        PageModel.languageDetectionFeaturesAvailable
            && isEditable && answersChords
            && coordinator?.canDetectCodeLanguage == true
    }

    @objc func detectCodeLanguage(_ sender: Any?) {
        guard canDetectCodeLanguage else { return }
        coordinator?.detectCodeLanguage()
    }

    /// Paste and Match Style takes a sealed fragment through the core, as ⌘V does.
    override func pasteAsPlainText(_ sender: Any?) {
        guard answersChords else { return }
        guard let coordinator else { return super.pasteAsPlainText(sender) }
        if coordinator.pasteFragment() { return }
        coordinator.readingBoard { super.pasteAsPlainText(sender) }
    }

    /// A board's text, as a paste, a drop or a service's answer reads it, stands no object.
    override func readSelection(
        from pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let coordinator else { return super.readSelection(from: pboard, type: type) }
        return coordinator.readingBoard { super.readSelection(from: pboard, type: type) }
    }

    @objc func pasteWithoutDetection(_ sender: Any?) {
        guard PageModel.languageDetectionFeaturesAvailable, isEditable, answersChords else { return }
        if coordinator?.pasteFragment() == true { return }
        performOrdinaryPaste(sender, bypassingAutomaticFencing: true) { [unowned self] sender in
            pasteAsPlainText(sender)
        }
    }

    /// Captures the board once when either shipping transformation or DEBUG
    /// measurement needs it. An eligible automatic paste is held until detection
    /// completes; every other path invokes AppKit's plain paste exactly once.
    func performOrdinaryPaste(
        _ sender: Any?,
        bypassingAutomaticFencing: Bool = false,
        pasteAsPlainText: (Any?) -> Void
    ) {
        withEditIntent(.paste) {
            let payload = coordinator?.ordinaryPastePayloadIfNeeded(
                bypassingAutomaticFencing: bypassingAutomaticFencing
            )
            if !bypassingAutomaticFencing, let payload,
               coordinator?.beginAutomaticPaste(payload: payload) == true
            {
                return
            }
            pasteAsPlainText(sender)
            if let payload, coordinator?.measuresOrdinaryPastes == true {
                coordinator?.observeOrdinaryPaste(payload: payload)
            }
        }
    }

    // MARK: Lists (ADR-0024: automation only on the caret's line)

    /// A paragraph's text without the separator at its end, taken off
    /// the tail alone. Every offset a caller compares counts from the
    /// paragraph's first character, so the head must not move.
    ///
    /// Only the characters `paragraphRange` actually breaks on come
    /// off. `Character.isNewline` is a wider set than that: it holds
    /// the form feed and the vertical tab, which the page treats as
    /// ordinary characters sitting inside a line. Trimming one of those
    /// would put the end of the line before the writer's own character,
    /// and a Return there would read as a Return at the end of an item.
    nonisolated static func lineWithoutSeparator(_ paragraph: String) -> String {
        var line = Substring(paragraph)
        while let last = line.last, last == "\n" || last == "\r" || last == "\u{2029}" {
            line = line.dropLast()
        }
        return String(line)
    }

    /// True when everything after a marker is whitespace: an item with
    /// nothing in it, however many spaces the writer left behind.
    nonisolated static func contentIsBlank(of line: String, after markerLength: Int) -> Bool {
        let units = Array(line.utf16)
        guard units.count >= markerLength else { return false }
        return units.dropFirst(markerLength).allSatisfy { $0 == 32 || $0 == 9 }
    }

    /// Return, on a line the page reads as a list item.
    ///
    /// This is the first place the editor writes ink the user did not
    /// type, and the law that keeps it honest is that it may only ever
    /// touch the caret's own line and the line that keystroke creates.
    /// Nothing below is renumbered: an item inserted in the middle of a
    /// numbered list leaves the numbers under it exactly as typed,
    /// because "styled, never rewritten" has to keep its meaning for
    /// every line the caret is not on (docs/spec/04).
    ///
    /// Three gates stand before the automation, and every one of them
    /// falls through to the ordinary newline rather than guessing. The
    /// read-only stance never arrives here at all: `isEditable` is
    /// already false and AppKit does not offer the keystroke.
    override func insertNewline(_ sender: Any?) {
        // An IME is mid-composition: the marked text is not yet the
        // user's word, and writing a marker underneath it would resolve
        // a composition nobody finished (the ADR-0013 gate).
        guard !hasMarkedText() else { return super.insertNewline(sender) }
        // A bare caret only. Return over a selection replaces what is
        // selected, and continuing the marker of a line whose content
        // is going away is not the gesture that was asked for.
        let caret = selectedRange()
        guard caret.length == 0, let storage = textStorage else {
            return super.insertNewline(sender)
        }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: caret)
        // The classification restyle already computed, never a fresh
        // read of the line: inside a fence `- x` is a flag and not a
        // bullet (issue #75), and consulting the one reading is what
        // keeps the styling and the keystroke from ever disagreeing.
        guard let kind = coordinator?.classifiedKind(ofParagraphAt: paragraph.location),
              case .list = kind
        else { return super.insertNewline(sender) }
        // The tail alone, never the head. `CharacterSet.newlines`
        // holds characters `paragraphRange` does not break on, a form
        // feed among them, so a line can carry one before its
        // separator; trimming both ends would put the end of the line
        // one unit short of where it really is, and a Return before
        // that character would read as a Return at the end of an item.
        let line = Self.lineWithoutSeparator(text.substring(with: paragraph))
        guard let item = InkStyle.listMarker(of: line) else {
            return super.insertNewline(sender)
        }

        // Only a Return at the end of a line is about the list at all,
        // and this guard governs both branches below. A Return in the
        // middle of an item would push the text to its right under a
        // marker the writer never typed, and a Return at the head of a
        // bare marker is a writer asking for a line above it, not for
        // the marker to vanish. Both split plainly. Start strict,
        // loosen if dogfooding asks.
        guard caret.location == paragraph.location + line.utf16.count else {
            return super.insertNewline(sender)
        }
        if Self.contentIsBlank(of: line, after: item.length) {
            // An empty item: the marker and nothing after its space
            // that a reader would call content. One stray space is no
            // reason for "one Return ends the list" to stop being true,
            // so the marker and the blank behind it go together and
            // leave a plain empty line.
            // Return takes the marker off and inserts no newline at
            // all, which is the reading every chat client has trained
            // people to expect: one Return ends the list. The removal
            // travels the ordinary edit route, so the core sees an
            // ordinary delete and provenance holds (ADR-0013).
            let prefix = NSRange(location: paragraph.location, length: line.utf16.count)
            // A refused edit is not a keystroke to swallow: the page
            // falls back to the newline it would have given before any
            // of this existed.
            guard shouldChangeText(in: prefix, replacementString: "") else {
                return super.insertNewline(sender)
            }
            // The removal is the page's own doing, so it gets its own
            // undo step for the reason the continuation does.
            withEditIntent(.automation) {
                storage.replaceCharacters(in: prefix, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: paragraph.location, length: 0))
            }
            return
        }
        // One keystroke, one undo step, and since issue #132 that is
        // the core's arrangement rather than AppKit's: the marker is an
        // edit the page made on the writer's behalf, so the batch it
        // emits begins its own step and a single ⌘Z takes it back with
        // none of the words typed before it. The newline and the marker
        // go down as one `insertText`, the ordinary route every other
        // character takes, and the flag rides that one batch across.
        withEditIntent(.automation) {
            insertText("\n" + item.successor, replacementRange: caret)
        }
    }

    /// Tab, on a line the page reads as a list item, with the caret in
    /// the item's marker region: two spaces at the line's start, and
    /// the item hangs one level deeper.
    ///
    /// Two spaces rather than a tab because the hanging indent is measured
    /// from the prose face (`styleParagraph` gives `.list` a head indent
    /// approximating the prefix's own width): a tab's width
    /// would be the layout manager's opinion, and the marker's would be
    /// the parser's. Nothing about the marker itself changes on a depth
    /// change; a nested `-` is still a `-`, because substituting a
    /// glyph is rewriting a line the writer typed (docs/spec/04).
    ///
    /// Anywhere else on the line Tab stays the literal tab it has
    /// always been, which is what makes this safe to add: the gesture
    /// only means depth where a depth reading is unambiguous.
    override func insertTab(_ sender: Any?) {
        guard let target = listDepthTarget() else { return super.insertTab(sender) }
        let start = NSRange(location: target.paragraph.location, length: 0)
        guard nudgeDepth(replacing: start, with: "  ", caret: target.caret) else {
            return super.insertTab(sender)
        }
    }

    /// ⇧Tab, the same gesture read backwards: up to two leading spaces
    /// come off the line's start, or one leading tab if that is what
    /// the depth was spelled in. An item hanging from nothing has
    /// nothing to give back and is left exactly as it stands.
    ///
    /// The spec says only that ⇧Tab removes the indent Tab added, and
    /// leaves open whether it should also fire from the item's content.
    /// The reading taken here is the symmetric one: ⇧Tab is gated to
    /// the marker region exactly as Tab is, which is how doc 04 words
    /// the pair ("Tab and Shift-Tab nudge an item's depth while the
    /// caret sits in the marker"). One region, one rule, and no line
    /// where the two halves of a single gesture disagree about whether
    /// this keystroke is about depth at all.
    ///
    /// An item with no indent swallows the keystroke rather than
    /// deferring. An outdent with nothing to give back has nothing to
    /// say, and the depth gesture is answered on the line it was aimed
    /// at or not at all; handing the keystroke on would make ⇧Tab mean
    /// one thing at depth and another at the margin. (A probe found
    /// that `super.insertBacktab` does not in fact move the first
    /// responder here, so this is a choice about the gesture rather
    /// than a guard against AppKit.)
    override func insertBacktab(_ sender: Any?) {
        guard let target = listDepthTarget() else { return super.insertBacktab(sender) }
        let removable = Self.outdentWidth(of: target.item.indent)
        guard removable > 0 else { return }
        let head = NSRange(location: target.paragraph.location, length: removable)
        guard nudgeDepth(replacing: head, with: "", caret: target.caret) else {
            return super.insertBacktab(sender)
        }
    }

    /// How much of an item's indent one outdent takes back: one tab if
    /// the depth was spelled with a tab, otherwise up to the two spaces
    /// Tab would have put there. Never more than one level per press,
    /// so the gesture is as reversible as it is repeatable.
    nonisolated static func outdentWidth(of indent: String) -> Int {
        guard let first = indent.first else { return 0 }
        if first == "\t" { return 1 }
        return indent.prefix(2).prefix { $0 == " " }.count
    }

    /// The line a depth nudge is allowed to touch, or nil when this
    /// keystroke is an ordinary tab after all.
    ///
    /// Every gate `insertNewline` stands behind stands here too, and
    /// for the same reasons: no automation under a live composition
    /// (ADR-0013), and the classification restyle already computed
    /// rather than a fresh read, so a `- x` inside a fence stays the
    /// flag it is and display and automation can never disagree about
    /// which it is (issue #75).
    ///
    /// The bare caret is the last gate and the one this method has to
    /// argue for itself. A selection spanning lines has no single
    /// caret line, and indenting every line it covers would be writing
    /// where the caret is not, which is the one thing ADR-0024 forbids
    /// outright. Rather than take half the selection's meaning, the
    /// keystroke falls through to the ordinary tab, which replaces the
    /// selection exactly as it does in every other text view on the
    /// machine. Block reindent is a real gesture and it can be argued
    /// for on its own terms later; it is not this keystroke.
    private func listDepthTarget()
        -> (paragraph: NSRange, caret: NSRange, item: InkStyle.ListItem)? {
        guard !hasMarkedText() else { return nil }
        let caret = selectedRange()
        guard caret.length == 0, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: caret)
        guard let kind = coordinator?.classifiedKind(ofParagraphAt: paragraph.location),
              case .list = kind
        else { return nil }
        // The tail alone, and only the separators the page breaks on,
        // for the reason `insertNewline` takes the same care: a form
        // feed sits inside a line, and trimming it would move the
        // marker region's far edge away from where the caret sees it.
        let line = Self.lineWithoutSeparator(text.substring(with: paragraph))
        guard let item = InkStyle.listMarker(of: line) else { return nil }
        // The marker region runs from the line's start through the
        // first character of content, boundary included, because the
        // commonest nesting gesture of all is typing `- ` and reaching
        // straight for Tab: the caret sits exactly at the marker's end
        // there, and an exclusive reading would answer that gesture
        // with a literal tab.
        guard caret.location <= paragraph.location + item.length else { return nil }
        return (paragraph, caret, item)
    }

    /// One depth nudge, and the only place either direction writes.
    ///
    /// The edit travels the ordinary route (`shouldChangeText`, the
    /// edit, `didChangeText`), so the core sees an ordinary op and
    /// ADR-0013's provenance holds with no special case, and the batch
    /// is marked as the page's own doing so it begins its own undo step
    /// and one press takes the depth back and none of the words
    /// (issue #132). False when the delegate refuses, which leaves the
    /// keystroke to the ordinary tab rather than swallowing it.
    private func nudgeDepth(
        replacing range: NSRange, with replacement: String, caret: NSRange
    ) -> Bool {
        guard let storage = textStorage else { return false }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        let width = (replacement as NSString).length
        let landing = caret.location >= NSMaxRange(range)
            ? caret.location - range.length + width
            : range.location + width
        let selection = NSRange(location: landing, length: 0)
        withEditIntent(.automation, afterSelection: selection) {
            storage.replaceCharacters(in: range, with: replacement)
            didChangeText()
            // Where the caret lands is the whole of whether the gesture
            // repeats. It keeps its place relative to the line's content,
            // so after a nudge it is still in the marker region and a
            // second press nudges again; an outdent that eats the ground
            // under it leaves it at the line's start, which is inside the
            // region too.
            setSelectedRange(selection)
        }
        return true
    }

    // MARK: Find (the one route that could reach a chip)

    /// Every other finder action works on ranges the finder matched, and
    /// a match can never contain a chip: the chip is an attachment
    /// character, and no search string typed into the bar can hold one.
    /// ⌘E is the exception — it loads the *selection* into the search
    /// field, so a selection holding a chip would make that chip findable
    /// and, from there, replaceable, which would delete sealed bytes as
    /// a side effect of a text operation. ADR-0009 says a chip leaves
    /// only by a deliberate act aimed at the chip, so this one refuses
    /// and says why.
    ///
    /// Both entry points are covered because both are live: the Find
    /// menu sends `performFindPanelAction:`, and a find bar built by
    /// something else sends `performTextFinderAction:`. The two share
    /// the tag numbering the guard reads.
    ///
    /// Use Selection for Find hands the ink to the finder, whose find
    /// pasteboard every process reads, so it asks first (Law 0001, expiry row).
    override func performFindPanelAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performTextFinderAction(sender)
    }

    /// True for a ⌘E over a selection holding a chip, or over any selection
    /// of a page past its deadline. The action arrives as the sender's tag; a
    /// sender carrying no readable tag is let through, because this is a
    /// refusal to be certain about and not a reason to break find.
    func refusesFinderAction(_ sender: Any?) -> Bool {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSControl)?.tag
        guard tag == NSTextFinder.Action.setSearchString.rawValue else { return false }
        guard givesOutShownText else { return true }
        guard let storage = textStorage,
              InkEditorView.Coordinator.containsChip(storage, in: selectedRange())
        else { return false }
        coordinator?.model.flash("a chip has no text to search for")
        return true
    }

    // MARK: The IME gate (ADR-0013)

    /// The one moment the pre-composition text is still readable: the
    /// first marked replacement has not landed yet, so the span it is
    /// about to replace is captured here as the baseline the
    /// composition's end will be diffed against.
    override func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        if !hasMarkedText() {
            let affected = replacementRange.location == NSNotFound
                ? self.selectedRange()
                : replacementRange
            if let storage = textStorage {
                coordinator?.beginComposition(over: affected, in: storage)
            }
        }
        // The flag brackets the storage edit because the view's own
        // marked-range bookkeeping may land on either side of it;
        // without the bracket, the first marked replacement can read
        // as a resolution and leak a mid-composition op.
        withEditIntent(.composition) {
            coordinator?.markedTextInFlight = true
            super.setMarkedText(
                string, selectedRange: selectedRange, replacementRange: replacementRange)
            coordinator?.markedTextInFlight = false
            // Marking with an empty string IS the cancel: the view is
            // unmarked again, and the composition must settle to zero ops.
            coordinator?.finishCompositionIfPending()
        }
    }

    /// The commit path: the input context replaces the marked text
    /// with the final string. The composition settles after the edit,
    /// as one diffed batch against the pre-composition baseline.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        // Typing over an object removes it, which waits while another surface holds the keys.
        if coordinator?.writesNote == false, !answersChords,
           coordinator?.rangesHoldObject([target]) == true
        { return }
        let intent: EditorEditIntent
        if coordinator?.imeComposition != nil || hasMarkedText() {
            intent = .composition
        } else if target.length > 0 {
            intent = .replacement
        } else {
            intent = .typing
        }
        withEditIntent(intent) {
            super.insertText(string, replacementRange: replacementRange)
            coordinator?.finishCompositionIfPending()
        }
    }

    /// A composition can end without a resolving character edit (a
    /// cancel that removed nothing because nothing was composed); the
    /// unmark is the one signal that always fires, so settle here.
    override func unmarkText() {
        withEditIntent(.composition) {
            super.unmarkText()
            coordinator?.finishCompositionIfPending()
        }
    }

    /// Esc hands the keyboard back (docs/spec/04, the focus law); in a note
    /// it contracts an expanded note and closes one that is not.
    override func cancelOperation(_ sender: Any?) {
        if let note = coordinator?.noteHost { return note.escape() }
        coordinator?.model.escape()
    }

    /// A note given up closes, on the next turn, once the keys have landed;
    /// the Edit menu's answers follow the keys either way (Law 0007, keys row).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.noteHost?.keysMayHaveLeft()
            coordinator?.keysMoved()
        }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.keysMoved() }
        return became
    }

    // MARK: Drop-to-seal

    /// Where a drop on this surface goes, one answer for the cursor and the drop.
    enum DropRoute: Equatable {
        /// Nothing lands: a decrypted drag (Law 0001, decrypted drag row), another surface's
        /// drag on a note (Law 0001, note row), or another app's where no seal can stand.
        case refused
        /// The page's own drag, moved or cloned in place through the core.
        case ownDrag
        /// Another page's standing drag, moved here through the core (Law 0001, drag row).
        case move
        /// A copy fragment, pasted through the core as ⌘V pastes it.
        case fragment
        /// Any other drag from inside this app, or another build's fragment, dropped by AppKit as ink.
        case ink
        /// Another app's drag, sealed where a seal can land.
        case seal
    }

    /// The route a drop from `sender` takes here. Another app's drag seals, and only
    /// where a seal can land: over a file it would write plaintext the next save keeps.
    func dropRoute(for sender: NSDraggingInfo) -> DropRoute {
        if isDecryptedDrag(sender) { return .refused }
        let editor = sender.draggingSource as? InkTextView
        if editor === self { return coordinator?.dragsPageSelection == true ? .ownDrag : .ink }
        guard let coordinator, !coordinator.writesNote else { return .refused }
        let mask = sender.draggingSourceOperationMask
        if coordinator.pageDragToMove(from: editor?.coordinator, offered: mask) != nil {
            return .move
        }
        if carriesFragment(sender) { return coordinator.takesFragmentDrop ? .fragment : .refused }
        // AppKit names a source only inside this app; nothing from here, nor another build's
        // fragment, was meant to be staged.
        if sender.draggingSource != nil || SealedFragment.anyBuildsItem(on: sender.draggingPasteboard) {
            return coordinator.takesFragmentDrop ? .ink : .refused
        }
        return coordinator.sealsHere ? .seal : .refused
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch dropRoute(for: sender) {
        case .refused: []
        case .seal: .copy
        case .ownDrag, .move, .fragment, .ink: super.draggingEntered(sender)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch dropRoute(for: sender) {
        case .refused: []
        case .seal: .copy
        case .ownDrag, .move, .fragment, .ink: super.draggingUpdated(sender)
        }
    }

    /// Dragging content to a secrecy tool is already the "stage this"
    /// gesture: an external drop seals. The core reads the drag
    /// pasteboard itself — the dropped bytes never enter this process.
    /// The page's own drag and a fragment go through the core instead.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Read before drop to seal touches the drag board, which would ask our provider.
        let route = dropRoute(for: sender)
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let mask = sender.draggingSourceOperationMask
        let editor = sender.draggingSource as? InkTextView
        switch route {
        case .refused:
            return false
        case .ownDrag:
            return coordinator?.dropPageDrag(at: index, offered: mask) ?? false
        case .move:
            guard let source = editor?.coordinator else { return false }
            return coordinator?.dropMovedPageDrag(from: source, at: index, offered: mask) ?? false
        case .fragment:
            return coordinator?.dropFragment(
                from: sender.draggingPasteboard, at: index, source: editor) ?? false
        case .ink:
            let source = sender.draggingSource as? NSView
            guard source === self || coordinator?.admitsDrop(from: source) == true else {
                return false
            }
            return super.performDragOperation(sender)
        case .seal:
            return coordinator?.sealDrop(at: index) ?? false
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDecryptedDrag(sender) ? false : super.prepareForDragOperation(sender)
    }

    /// This app's own decrypted drag, which the page and the note refuse (Law 0001, decrypted drag row).
    private func isDecryptedDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource is DecryptedDrag
    }

    // MARK: Drags of the page's selection (Law 0001, drag and ⌥ drag rows)

    /// The page's selection drags as the core's copy fragment, with its own
    /// drawing as the image; several stretches of ink drag as AppKit drags them.
    override func dragSelection(
        with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool
    ) -> Bool {
        guard let coordinator else {
            return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
        }
        switch coordinator.beginPageDrag() {
        case .ordinary:
            guard givesOutShownText else { return false }
            return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
        case .refused:
            return false
        case .fragment(let item):
            var origin = NSPoint.zero
            let image = pageDragImage(with: event, origin: &origin)
                ?? NSImage(size: NSSize(width: 1, height: 1))
            // AppKit gives the image's lower left corner; a flipped frame starts at its top.
            let top = isFlipped ? origin.y - image.size.height : origin.y
            let dragging = NSDraggingItem(pasteboardWriter: item)
            dragging.setDraggingFrame(
                NSRect(origin: NSPoint(x: origin.x, y: top), size: image.size), contents: image)
            startDraggingSession([dragging], event: event, source: self, slideBack: slideBack)
            return true
        }
    }

    /// Whether the page drag's image is being drawn, so each block draws its drag face.
    private(set) var drawsPageDragImage = false

    /// The selection's ink as drawn and each object's face without its excerpt, built as
    /// the decrypted drag's image is (sealed row spec, Pointer and image), since other apps see it pass.
    func pageDragImage(with event: NSEvent, origin: inout NSPoint) -> NSImage? {
        drawsPageDragImage = true
        defer { drawsPageDragImage = false }
        return dragImageForSelection(with: event, origin: &origin)
    }

    override func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        guard coordinator?.dragsPageSelection == true else {
            return super.draggingSession(session, sourceOperationMaskFor: context)
        }
        return Self.pageDragMask(for: context, editable: isEditable)
    }

    override func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        guard let coordinator, coordinator.dragsPageSelection else {
            return super.draggingSession(session, endedAt: screenPoint, operation: operation)
        }
        coordinator.endPageDrag()
    }

    /// The operation AppKit's drop caret follows for the page's own drag, a move or a
    /// fragment, which removes nothing from its source; any other drag keeps AppKit's answer.
    override func dragOperation(
        for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType
    ) -> NSDragOperation {
        let mask = dragInfo.draggingSourceOperationMask
        switch dropRoute(for: dragInfo) {
        case .refused:
            return []
        case .ownDrag:
            let index = characterIndexForInsertion(
                at: convert(dragInfo.draggingLocation, from: nil))
            return coordinator?.pageDragOperation(at: index, offered: mask) ?? []
        case .move:
            return .move
        case .fragment:
            return mask.contains(.copy) ? .copy : []
        case .ink, .seal:
            return super.dragOperation(for: dragInfo, type: type)
        }
    }

    private func carriesFragment(_ sender: NSDraggingInfo) -> Bool {
        SealedFragment.item(on: sender.draggingPasteboard) != nil
    }

    /// What a page's drag offers: a move or a copy inside the app, and only a copy
    /// outside it, so no other app can take the selection off the page.
    nonisolated static func pageDragMask(
        for context: NSDraggingContext, editable: Bool
    ) -> NSDragOperation {
        context == .withinApplication && editable ? [.move, .copy] : .copy
    }

    /// A drop of a page's drag: a move, or a copy when ⌥ leaves only the copy.
    nonisolated static func pageDropOperation(offered mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.move) { return .move }
        return mask.contains(.copy) ? .copy : []
    }
}

// MARK: - The chip, rendered

/// A sealed chip's place in the document: an attachment character
/// carrying only the chip's id and mechanical face. There is no
/// affordance — and no data — to reveal what it stands for.
final class ChipAttachment: NSTextAttachment {
    /// The face the block draws; a name or note changes it in place.
    @MainActor
    var info: ChipInfo {
        didSet { (attachmentCell as? SealedBlockCell)?.info = info }
    }

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = SealedBlockCell(info: info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }

    /// A sealed object occupies the editor's full available measure,
    /// including when long lines are allowed to run horizontally. The
    /// scroll view's viewport is the page measure; the text container
    /// can be effectively infinite in that mode and must not decide the
    /// block's width (D-27).
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let width = SealedBlockCell.blockWidth(
            in: textContainer, proposedLineFragment: lineFrag
        )
        return SealedBlockCell.blockBounds(width: width)
    }
}

/// Draws a sealed object as a full-measure block: classification and
/// size metadata above its mechanical excerpt. It is deliberately a
/// bordered rectangle rather than a pill or button (D-27).
final class SealedBlockCell: NSTextAttachmentCell {
    @MainActor
    var info: ChipInfo

    #if DEBUG
    /// Test-only record of the frame handed to the drawing path.
    @MainActor
    private(set) var lastDrawnFrame: NSRect?
    #endif

    nonisolated static let blockHeight = SealedBlockLayout.height
    /// The width a block takes when nothing has measured the editor:
    /// a context-free `cellSize()` and a layout with no usable measure
    /// both fall back to it, so it is named once.
    nonisolated static let fallbackBlockWidth: CGFloat = 240
    /// Widths at or above this value are TextKit's effectively-unbounded
    /// sentinels, not usable page measurements.
    nonisolated static let effectivelyUnboundedWidth: CGFloat = 1_000_000
    nonisolated static let classification = "SEALED CONTENT"

    nonisolated static func blockBounds(width: CGFloat) -> NSRect {
        let metrics = SealedBlockLayout.metrics(containerWidth: width)
        return NSRect(
            x: 0,
            y: -metrics.height + metrics.baselineOffset,
            width: metrics.width,
            height: metrics.height
        )
    }

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }

    /// Measured and drawn by the layout manager, which is main-thread
    /// work by AppKit's own rule; the font is read live rather than
    /// captured at init so a chip follows the page's typeface without
    /// the storage being rebuilt around it.
    @MainActor
    private var excerpt: NSAttributedString {
        // The excerpt is drawn into a rect that stops short of the size
        // class, and it is the tail that goes when the rect is too
        // narrow: the head is what identifies the object.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: info.excerpt,
            attributes: [
                .font: InkStyle.chipFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
    }

    /// The block's quieter words: the secondary ink at rest, ink on a
    /// selected block, where the selection highlight shows through the
    /// fill and leaves the secondary label near 4:1 (record section 9, row 5).
    nonisolated static func quietInk(selected: Bool) -> NSColor {
        selected ? .labelColor : .secondaryInk
    }

    @MainActor
    private func classificationLabel(selected: Bool = false) -> NSAttributedString {
        NSAttributedString(
            string: Self.classification,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: Self.quietInk(selected: selected),
                .kern: 1.15,
            ]
        )
    }

    @MainActor
    private func metadata(selected: Bool) -> NSAttributedString {
        Self.seatString(
            Self.restingSeat(sizeLabel: info.sizeLabel, hasNote: info.hasNote), selected: selected)
    }

    /// The current core returns this closed vocabulary. Refuse to draw
    /// an older or malformed count-shaped label: D-27 permits a size
    /// class here and explicitly forbids a count.
    nonisolated static func displayedSizeClass(_ label: String) -> String {
        let normalized = label.lowercased()
        guard ["tiny", "small", "medium", "large", "huge"].contains(normalized)
        else { return "size unknown" }
        return normalized
    }

    /// What the size class's seat says a click on `zone` will do,
    /// before the click (Law 0001; sealed row spec, Hover pill and seat words).
    nonisolated static func seatWords(for zone: SealedBlockLayout.Zone) -> String {
        switch zone {
        case .name: "copies the name"
        case .equals: "copies name=value, decrypted"
        case .value: "copies the value, decrypted"
        }
    }

    /// The seat's word for the beat after a zone's copy.
    nonisolated static let copiedWords = "copied"

    /// The word in the seat that opens the note, once one exists (sealed row spec, Doorway).
    nonisolated static let doorwayWord = "note"

    /// The seat at rest: the size class first, then the note's doorway.
    nonisolated static func restingSeat(sizeLabel: String, hasNote: Bool) -> String {
        displayedSizeClass(sizeLabel) + (hasNote ? " · \(doorwayWord)" : "")
    }

    /// What the seat reads: the beat's word, a hovered zone's words, or
    /// the seat at rest.
    nonisolated static func seatText(
        sizeLabel: String, hasNote: Bool = false, hovered: SealedBlockLayout.Zone?, copied: Bool
    ) -> String {
        if copied { return copiedWords }
        if let hovered { return seatWords(for: hovered) }
        return restingSeat(sizeLabel: sizeLabel, hasNote: hasNote)
    }

    /// Where `note` stands in the resting seat of a block drawn at
    /// `cellFrame`; nil without a note.
    @MainActor
    func doorwayRect(in cellFrame: NSRect) -> NSRect? {
        guard info.hasNote else { return nil }
        let seat = Self.seatString(Self.restingSeat(sizeLabel: info.sizeLabel, hasNote: true))
        let word = Self.seatString(Self.doorwayWord).size()
        let origin = Self.contentLayout(in: cellFrame).metadataOrigin(width: seat.size().width)
        return NSRect(
            x: origin.x + seat.size().width - word.width, y: origin.y,
            width: word.width, height: word.height)
    }

    /// The doorway's rule: 0.8 points, 2.5 under the word's baseline.
    @MainActor
    private func drawDoorwayRule(in cellFrame: NSRect) {
        guard let word = doorwayRect(in: cellFrame) else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let y = word.minY + font.ascender + 2.5
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: word.minX, y: y))
        rule.line(to: NSPoint(x: word.maxX, y: y))
        rule.lineWidth = 0.8
        NSColor.tertiaryLabelColor.setStroke()
        rule.stroke()
    }

    /// A long name keeps this many characters and an ellipsis before
    /// the value gives way at all.
    nonisolated static let nameFloorCharacters = 4

    /// A named row as drawn: the three runs, fitted to the row, and
    /// where they stand.
    struct NamedRow {
        let name: NSAttributedString
        let equals: NSAttributedString
        let value: NSAttributedString
        let geometry: SealedBlockLayout.NamedRow
    }

    /// The named row in a block drawn at `cellFrame`, nil when unnamed (Law 0001, unnamed
    /// row row); measured against the seat's widest words, not its current ones.
    /// With `editingWidth` the name's seat is a field that wide (Law 0007),
    /// drawn by the field, and the row follows it whether named or not.
    @MainActor
    func namedRow(
        in cellFrame: NSRect, editingWidth: CGFloat? = nil, selected: Bool = false
    ) -> NamedRow? {
        let name: String
        if editingWidth != nil {
            name = ""
        } else if let typed = info.name, !typed.isEmpty {
            name = typed
        } else {
            return nil
        }
        let layout = Self.contentLayout(in: cellFrame)
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: InkStyle.chipNameFont, .foregroundColor: NSColor.labelColor,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: InkStyle.chipFont, .foregroundColor: NSColor.labelColor,
        ]
        let equals = NSAttributedString(string: "=", attributes: [
            .font: InkStyle.chipFont, .foregroundColor: Self.quietInk(selected: selected),
        ])
        let floor = NSAttributedString(
            string: String(name.prefix(Self.nameFloorCharacters)) + "…",
            attributes: nameAttributes)
        let wholeValue = NSAttributedString(string: info.excerpt, attributes: valueAttributes)
        let available = SealedBlockLayout.excerptWidth(
            containerWidth: cellFrame.width, metadataWidth: Self.widestSeatWidth)
        let allotment = editingWidth.map {
            (name: $0, value: max(0, available - $0 - equals.size().width))
        } ?? SealedBlockLayout.rowAllotment(
            available: available,
            name: NSAttributedString(string: name, attributes: nameAttributes).size().width,
            equals: equals.size().width,
            value: wholeValue.size().width,
            nameFloor: floor.size().width
        )
        let fittedName = Self.fitted(name, attributes: nameAttributes, width: allotment.name)
        let fittedValue = Self.fitted(
            info.excerpt, attributes: valueAttributes, width: allotment.value)
        return NamedRow(
            name: fittedName,
            equals: equals,
            value: fittedValue,
            geometry: layout.namedRow(
                nameWidth: editingWidth ?? fittedName.size().width,
                equalsWidth: equals.size().width,
                valueWidth: fittedValue.size().width,
                height: wholeValue.size().height,
                copiesNameValue: SealedBlockLayout.copiesNameValue(kind: info.kind)
            )
        )
    }

    /// The most the name field may take of a block drawn at `cellFrame`:
    /// the row, less the `=` that follows it.
    @MainActor
    func nameFieldRoom(in cellFrame: NSRect) -> CGFloat {
        let equals = NSAttributedString(string: "=", attributes: [.font: InkStyle.chipFont])
        return SealedBlockLayout.excerptWidth(
            containerWidth: cellFrame.width, metadataWidth: Self.widestSeatWidth
        ) - equals.size().width
    }

    /// The widest thing a named row's seat can say, which its row
    /// leaves room for.
    @MainActor
    static var widestSeatWidth: CGFloat {
        let words = SealedBlockLayout.Zone.allCases.map(seatWords(for:))
            + [copiedWords, restingSeat(sizeLabel: "size unknown", hasNote: true)]
        return words.map { seatString($0).size().width }.max() ?? 0
    }

    @MainActor
    static func seatString(_ text: String, selected: Bool = false) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: quietInk(selected: selected),
            ]
        )
    }

    /// `text` cut at its tail with an ellipsis to fit `width`, or whole
    /// when it fits; the longest prefix that fits is kept.
    @MainActor
    static func fitted(
        _ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat
    ) -> NSAttributedString {
        let whole = NSAttributedString(string: text, attributes: attributes)
        guard whole.size().width > width else { return whole }
        let characters = Array(text)
        func candidate(_ count: Int) -> NSAttributedString {
            NSAttributedString(
                string: String(characters.prefix(count)) + "…", attributes: attributes)
        }
        var kept = 0
        var tooMany = characters.count
        while tooMany - kept > 1 {
            let middle = (kept + tooMany) / 2
            if candidate(middle).size().width <= width { kept = middle } else { tooMany = middle }
        }
        let fitted = candidate(kept)
        return fitted.size().width <= width ? fitted : NSAttributedString(string: "")
    }

    /// The block as VoiceOver names it: what it is, its name, its size.
    override func accessibilityLabel() -> String? {
        [Self.classification.lowercased(), info.name, Self.displayedSizeClass(info.sizeLabel)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    struct ContentLayout {
        let metrics: SealedBlockLayout.Metrics
        /// The content column's leading edge, the one inset every row
        /// starts from.
        let left: CGFloat
        let topRowY: CGFloat
        let bottomRowY: CGFloat
        let lockRect: NSRect
        /// Where the classification starts: a gap past the lock, on the
        /// lock's row.
        let labelOrigin: NSPoint
        /// The metadata column's trailing edge, the inset the actions
        /// seat shares, and the baseline its smaller face sits on.
        let metadataRight: CGFloat
        let metadataY: CGFloat
        /// The bottom row's band, the block's lower half, where a named
        /// row's zones answer the pointer.
        let rowBand: NSRect

        /// The size class is drawn at its own measured width, ending at
        /// the column's trailing edge.
        func metadataOrigin(width: CGFloat) -> NSPoint {
            NSPoint(x: metadataRight - width, y: metadataY)
        }

        /// A named row's three runs end to end from the leading edge, at
        /// the widths they are drawn at.
        func namedRow(
            nameWidth: CGFloat, equalsWidth: CGFloat, valueWidth: CGFloat, height: CGFloat,
            copiesNameValue: Bool
        ) -> SealedBlockLayout.NamedRow {
            let name = NSRect(x: left, y: bottomRowY, width: nameWidth, height: height)
            let equals = NSRect(x: name.maxX, y: bottomRowY, width: equalsWidth, height: height)
            let value = NSRect(x: equals.maxX, y: bottomRowY, width: valueWidth, height: height)
            return SealedBlockLayout.NamedRow(
                name: name, equals: equals, value: value, band: rowBand, metrics: metrics,
                copiesNameValue: copiesNameValue)
        }

        /// Where the excerpt is drawn and where its tail is cut: the
        /// bottom row from the leading edge to a gap short of the size
        /// class. `height` is one line of the excerpt's face, so an
        /// excerpt too long for the rect truncates rather than wrapping
        /// under the block.
        func excerptRect(metadataWidth: CGFloat, height: CGFloat) -> NSRect {
            NSRect(
                x: left,
                y: bottomRowY,
                width: SealedBlockLayout.excerptWidth(
                    containerWidth: metrics.width, metadataWidth: metadataWidth),
                height: height
            )
        }
    }

    /// Row and lock geometry in the flipped text-view coordinate system.
    /// Keeping it pure makes the placement independently testable without
    /// relying on pixels from an AppKit drawing context.
    nonisolated static func contentLayout(in cellFrame: NSRect) -> ContentLayout {
        let metrics = SealedBlockLayout.metrics(containerWidth: cellFrame.width)
        let left = cellFrame.minX + metrics.horizontalPadding
        let topRowY = cellFrame.minY + metrics.verticalPadding
        let bottomRowY = cellFrame.maxY - metrics.bottomRowInset
        let lockRect = NSRect(
            x: left,
            y: topRowY + metrics.lockTopNudge,
            width: metrics.lockSize,
            height: metrics.lockSize
        )
        return ContentLayout(
            metrics: metrics,
            left: left,
            topRowY: topRowY,
            bottomRowY: bottomRowY,
            lockRect: lockRect,
            labelOrigin: NSPoint(x: lockRect.maxX + metrics.lockToLabelGap, y: topRowY),
            metadataRight: cellFrame.maxX - metrics.horizontalPadding,
            metadataY: bottomRowY + metrics.metadataBaselineNudge,
            rowBand: NSRect(
                x: cellFrame.minX, y: cellFrame.midY,
                width: cellFrame.width, height: cellFrame.maxY - cellFrame.midY)
        )
    }

    /// The actions glyph: three dots in the block's top trailing
    /// corner, drawn only while the pointer is over the block or the
    /// block is selected, and clicked to open the object's menu. The
    /// affordance is revealed, the content is not (D-10), and it keeps
    /// its seat whether drawn or not, so revealing it moves nothing.
    nonisolated static let actionsGlyph = "···"

    /// Where the actions glyph sits in a block drawn at `cellFrame`,
    /// and so where a click opens the menu. On the classification's
    /// row, at the trailing edge, wide enough to hit. The text view
    /// the block is drawn in is flipped, so the block's top row is at
    /// `minY` and its bottom row at `maxY`. Pure, so the click test is
    /// an assertion rather than a screen.
    nonisolated static func actionsRect(in cellFrame: NSRect) -> NSRect {
        let metrics = SealedBlockLayout.metrics(containerWidth: cellFrame.width)
        return NSRect(
            x: cellFrame.maxX - metrics.horizontalPadding - metrics.actionsWidth,
            y: cellFrame.minY + metrics.actionsTopInset,
            width: metrics.actionsWidth,
            height: metrics.actionsHeight
        )
    }

    @MainActor
    private func actions(selected: Bool) -> NSAttributedString {
        NSAttributedString(
            string: Self.actionsGlyph,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Self.quietInk(selected: selected),
            ]
        )
    }

    /// The decrypted drag's handle, labelled in the design record's words (D-29).
    nonisolated static let decryptedDragWords = "drag decrypted"

    /// The handle's seat: on the classification's row, a gap before the actions seat and
    /// as wide as its words; nil where it would meet the classification (sealed row spec, Seat and look).
    nonisolated static func decryptedDragRect(
        in cellFrame: NSRect, wordsWidth: CGFloat, labelWidth: CGFloat
    ) -> NSRect? {
        let metrics = SealedBlockLayout.metrics(containerWidth: cellFrame.width)
        let actions = actionsRect(in: cellFrame)
        let width = wordsWidth + metrics.handleInset * 2
        let handle = NSRect(
            x: actions.minX - metrics.handleGap - width, y: actions.minY,
            width: width, height: actions.height)
        let labelEnd = contentLayout(in: cellFrame).labelOrigin.x + labelWidth
        return handle.minX >= labelEnd + metrics.handleGap ? handle : nil
    }

    /// The handle in a block drawn at `cellFrame`, measured in the faces it is drawn in;
    /// nil for a kind with no type to drag as.
    @MainActor
    func decryptedDragRect(in cellFrame: NSRect) -> NSRect? {
        guard DecryptedDrag.pasteboardType(forKind: info.kind) != nil else { return nil }
        return Self.decryptedDragRect(
            in: cellFrame, wordsWidth: Self.decryptedDragString.size().width,
            labelWidth: classificationLabel().size().width)
    }

    @MainActor
    static var decryptedDragString: NSAttributedString {
        NSAttributedString(
            string: decryptedDragWords,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    /// The handle: its words in an ember outline, apart from the block's other ink.
    @MainActor
    static func drawDecryptedDragHandle(in rect: NSRect) {
        let outline = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        outline.lineWidth = 1
        NSColor.ember.setStroke()
        outline.stroke()
        let words = decryptedDragString
        let size = words.size()
        words.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// The two handles on the block's top row, and how VoiceOver names each (issue 255).
    enum Handle: CaseIterable, Hashable, Sendable {
        case move
        case decrypted

        var accessibilityLabel: String {
            switch self {
            case .move: "Move"
            case .decrypted: "Drag decrypted"
            }
        }
    }

    /// Where `handle` sits in a block drawn at `cellFrame`; nil where the block draws none.
    @MainActor
    func handleRect(_ handle: Handle, in cellFrame: NSRect) -> NSRect? {
        switch handle {
        case .move: moveHandleRect(in: cellFrame)
        case .decrypted: decryptedDragRect(in: cellFrame)
        }
    }

    /// The handle whose seat `point` is in, in a block drawn at `cellFrame`; nil off both.
    @MainActor
    func handle(at point: NSPoint, in cellFrame: NSRect) -> Handle? {
        Handle.allCases.first { handleRect($0, in: cellFrame)?.contains(point) == true }
    }

    /// The move handle's glyph, with no words: the decrypted handle is the labelled one,
    /// and D-29 asks that the two read apart (2026-0915 record, block section; issue 255).
    nonisolated static let moveHandleGlyph = "\u{283F}"

    /// The move handle's seat: a gap before `neighbourMinX`, the decrypted handle where the
    /// block has one and the actions seat otherwise; nil where it would meet the classification.
    nonisolated static func moveHandleRect(
        in cellFrame: NSRect, glyphWidth: CGFloat, labelWidth: CGFloat, neighbourMinX: CGFloat
    ) -> NSRect? {
        let metrics = SealedBlockLayout.metrics(containerWidth: cellFrame.width)
        let actions = actionsRect(in: cellFrame)
        let width = glyphWidth + metrics.handleInset * 2
        let handle = NSRect(
            x: neighbourMinX - metrics.handleGap - width, y: actions.minY,
            width: width, height: actions.height)
        let labelEnd = contentLayout(in: cellFrame).labelOrigin.x + labelWidth
        return handle.minX >= labelEnd + metrics.handleGap ? handle : nil
    }

    /// The move handle in a block drawn at `cellFrame`. On a block whose kind has a decrypted
    /// handle it gives way first: once that handle does not fit, neither does this one, rather
    /// than this one taking the vacated seat (Law 0001, move drag row).
    @MainActor
    func moveHandleRect(in cellFrame: NSRect) -> NSRect? {
        let neighbour: NSRect
        if DecryptedDrag.pasteboardType(forKind: info.kind) != nil {
            guard let decrypted = decryptedDragRect(in: cellFrame) else { return nil }
            neighbour = decrypted
        } else {
            neighbour = Self.actionsRect(in: cellFrame)
        }
        return Self.moveHandleRect(
            in: cellFrame, glyphWidth: Self.moveHandleString(selected: false).size().width,
            labelWidth: classificationLabel().size().width, neighbourMinX: neighbour.minX)
    }

    /// The glyph in the block's quiet ink, the actions glyph's, never the decrypted handle's ember.
    @MainActor
    static func moveHandleString(selected: Bool) -> NSAttributedString {
        NSAttributedString(
            string: moveHandleGlyph,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: quietInk(selected: selected),
            ]
        )
    }

    /// The move handle: its glyph alone, centred in its seat, with no outline and no words.
    @MainActor
    static func drawMoveHandle(in rect: NSRect, selected: Bool) {
        let glyph = moveHandleString(selected: selected)
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }


    /// The captured editor measure wins when an unwrapped text container
    /// is effectively infinite; otherwise the finite container or
    /// proposed line fragment supplies the measure.
    nonisolated static func blockWidth(
        in textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect
    ) -> CGFloat {
        // TextKit represents an unbounded container with a very large but
        // finite number. Once the live editor measure is captured, a
        // container may narrow that measure (wrapped mode) but may never
        // widen it (unwrapped mode).
        let capturedMeasure = (textContainer as? InkTextContainer)?.capturedEditorMeasure
        let ceiling = capturedMeasure ?? .infinity
        // Every candidate spans the line fragment padding on both
        // sides. TextKit proposes a fragment as wide as the container
        // and applies the padding to the glyph origin instead, so the
        // fragment is not the rect inside the padding and gives it
        // back like the other two (`SealedBlockTests` pins this
        // against a live layout manager).
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        let candidates = [textContainer?.size.width, lineFrag.width, capturedMeasure]
        for case let width? in candidates {
            guard width.isFinite, width > 0,
                width < effectivelyUnboundedWidth, width <= ceiling
            else { continue }
            return max(0, (width - padding).rounded(.down))
        }
        return max(0, ((capturedMeasure ?? fallbackBlockWidth) - padding).rounded(.down))
    }

    override nonisolated func cellSize() -> NSSize {
        // Context-free callers have no editor measure. Live TextKit
        // layout uses cellFrame(...) below and replaces this fallback.
        let metrics = SealedBlockLayout.metrics(containerWidth: Self.fallbackBlockWidth)
        return NSSize(width: metrics.width, height: metrics.height)
    }

    override nonisolated func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        var frame = super.cellFrame(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        frame.size = Self.blockBounds(width: Self.blockWidth(
            in: textContainer, proposedLineFragment: lineFrag)).size
        return frame
    }

    override nonisolated func cellBaselineOffset() -> NSPoint {
        Self.blockBounds(width: 0).origin
    }

    /// The layout manager's call, which names the character so the
    /// block can ask its text view whether it is the one under the
    /// pointer or the one selected. The plain `draw(withFrame:in:)` is
    /// what it falls through to, with neither fact known.
    override func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        // AppKit draws a drag's image with no control view, so the page is found by its layout.
        if (layoutManager.firstTextView as? InkTextView)?.drawsPageDragImage == true {
            return draw(
                withFrame: cellFrame, in: controlView, face: .dragImage, selected: false,
                hovered: false, editingWidth: nil, zone: nil, beat: nil)
        }
        let view = controlView as? InkTextView
        let selected = view.map { $0.selectedRange() == NSRange(location: charIndex, length: 1) }
            ?? false
        let hovered = view?.hoveredChipIndex == charIndex
        let beat = view?.copyBeat.flatMap {
            $0.index == charIndex && $0.chip == info.chipId ? $0 : nil
        }
        let naming = view?.naming.flatMap {
            $0.index == charIndex && $0.chip == info.chipId ? $0 : nil
        }
        draw(
            withFrame: cellFrame, in: controlView, face: .page, selected: selected,
            hovered: hovered, editingWidth: naming?.width,
            zone: hovered ? view?.hoveredZone : nil,
            beat: beat.flatMap { beat in
                Self.beatStrength(
                    elapsed: ProcessInfo.processInfo.systemUptime - beat.started,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ).map { (beat.zone, $0) }
            }
        )
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(
            withFrame: cellFrame, in: controlView, face: .page, selected: false, hovered: false,
            editingWidth: nil, zone: nil, beat: nil)
    }

    /// Where a block is drawn: on its page, or in the page drag's image, which other
    /// apps see while it passes over them and so shows no excerpt (Law 0001's plain drag row).
    enum Face {
        case page
        case dragImage
    }

    /// How long a zone wears ember after its copy (sealed row spec, Ember beat).
    nonisolated static let beatDuration: TimeInterval = 1
    /// The fade at each end of the beat, which Reduce Motion drops (sealed row spec, Ember beat).
    nonisolated static let beatFade: TimeInterval = 0.15

    /// How strongly the beat is drawn `elapsed` seconds after the copy,
    /// from 0 to 1, or nil once the row rests.
    nonisolated static func beatStrength(elapsed: TimeInterval, reduceMotion: Bool) -> CGFloat? {
        guard elapsed >= 0, elapsed < beatDuration else { return nil }
        guard !reduceMotion else { return 1 }
        let edge = min(elapsed, beatDuration - elapsed)
        return CGFloat(min(1, edge / beatFade))
    }

    /// State first, identity second, actions third: the lock and the
    /// classification on the top row with the actions glyph at its
    /// end, the excerpt and the size class on the row under them. A
    /// selected block wears the ember keyline and its tint, the same
    /// way the card says it holds the keyboard, paired with the
    /// selection itself so the colour is never the only carrier.
    @MainActor
    private func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?, face: Face, selected: Bool,
        hovered: Bool, editingWidth: CGFloat?,
        zone: SealedBlockLayout.Zone?, beat: (zone: SealedBlockLayout.Zone, strength: CGFloat)?
    ) {
        #if DEBUG
        lastDrawnFrame = cellFrame
        #endif
        let metrics = SealedBlockLayout.metrics(containerWidth: cellFrame.width)
        let block = NSBezierPath(
            roundedRect: cellFrame.insetBy(
                dx: metrics.borderWidth / 2,
                dy: metrics.borderWidth / 2
            ),
            xRadius: metrics.cornerRadius,
            yRadius: metrics.cornerRadius
        )
        NSColor.textBackgroundColor.withAlphaComponent(0.34).setFill()
        block.fill()
        if selected {
            let ring = NSBezierPath(
                roundedRect: cellFrame.insetBy(
                    dx: -metrics.selectionRingInset,
                    dy: -metrics.selectionRingInset
                ),
                xRadius: metrics.cornerRadius + metrics.selectionRingInset,
                yRadius: metrics.cornerRadius + metrics.selectionRingInset
            )
            NSColor.ember.withAlphaComponent(0.12).setStroke()
            ring.lineWidth = metrics.selectionRingWidth
            ring.stroke()
            NSColor.ember.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        block.lineWidth = metrics.borderWidth
        block.stroke()
        let layout = Self.contentLayout(in: cellFrame)

        if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
            lock.draw(
                in: layout.lockRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        classificationLabel(selected: selected).draw(at: layout.labelOrigin)
        if hovered || selected {
            let glyph = actions(selected: selected)
            let size = glyph.size()
            let seat = Self.actionsRect(in: cellFrame)
            glyph.draw(at: NSPoint(
                x: seat.maxX - size.width,
                y: seat.midY - size.height / 2
            ))
            if let handle = decryptedDragRect(in: cellFrame) {
                Self.drawDecryptedDragHandle(in: handle)
            }
            if let handle = moveHandleRect(in: cellFrame) {
                Self.drawMoveHandle(in: handle, selected: selected)
            }
        }

        guard let row = namedRow(in: cellFrame, editingWidth: editingWidth, selected: selected)
        else {
            let excerptLine = excerpt
            let metadata = metadata(selected: selected)
            let metadataSize = metadata.size()
            if face == .page {
                excerptLine.draw(in: layout.excerptRect(
                    metadataWidth: metadataSize.width,
                    height: excerptLine.size().height
                ))
            }
            metadata.draw(at: layout.metadataOrigin(width: metadataSize.width))
            drawDoorwayRule(in: cellFrame)
            return
        }
        if editingWidth == nil {
            drawPills(row.geometry, metrics: layout.metrics, zone: zone, beat: beat)
        }
        row.name.draw(at: row.geometry.name.origin)
        if face == .page {
            row.equals.draw(at: row.geometry.equals.origin)
            row.value.draw(at: row.geometry.value.origin)
        }
        let hovered = editingWidth == nil ? zone : nil
        let copied = editingWidth == nil && beat != nil
        let seat = Self.seatString(Self.seatText(
            sizeLabel: info.sizeLabel, hasNote: info.hasNote, hovered: hovered, copied: copied),
            selected: selected)
        seat.draw(at: layout.metadataOrigin(width: seat.size().width))
        if hovered == nil, !copied { drawDoorwayRule(in: cellFrame) }
    }

    /// The hovered zone's pill, and the beat's ember over the zone it
    /// copied from; the beat wins where both would fall.
    @MainActor
    private func drawPills(
        _ row: SealedBlockLayout.NamedRow, metrics: SealedBlockLayout.Metrics,
        zone: SealedBlockLayout.Zone?, beat: (zone: SealedBlockLayout.Zone, strength: CGFloat)?
    ) {
        func pill(_ zone: SealedBlockLayout.Zone, inset: CGFloat = 0) -> NSBezierPath {
            NSBezierPath(
                roundedRect: row.pill(for: zone).insetBy(dx: inset, dy: inset),
                xRadius: metrics.pillRadius, yRadius: metrics.pillRadius)
        }
        if let zone, zone != beat?.zone {
            NSColor.sealedZonePill.setFill()
            pill(zone).fill()
        }
        guard let beat else { return }
        NSColor.sealedZonePill.withAlphaComponent(zone == beat.zone ? 1 : beat.strength).setFill()
        pill(beat.zone).fill()
        NSColor.sealedZoneEmberTint.withAlphaComponent(beat.strength).setFill()
        pill(beat.zone).fill()
        let stroke = pill(beat.zone, inset: 0.5)
        stroke.lineWidth = 1
        NSColor.ember.withAlphaComponent(beat.strength).setStroke()
        stroke.stroke()
    }
}

// MARK: - Type

/// The page's type ramp: monospaced ink; headings by weight and size,
/// their markup dimmed in place (docs/spec/04).
///
/// Prose and code families are the user's (Settings, General and Code),
/// with one shared point size. `Typeface` resolves the prose base and
/// heading ramp separately from fixed-pitch code; list indentation and
/// chip labels continue to follow the prose face.
@MainActor
public enum InkStyle {
    /// A font as the user names it: a family, and a size in points. The
    /// empty family is the system's monospaced font, which is what the
    /// page wore before it could be told otherwise and what it falls
    /// back to when the named family is not installed.
    public struct Typeface: Equatable, Sendable {
        public var family: String
        public var codeFamily: String
        public var size: CGFloat

        public init(family: String, codeFamily: String = "", size: CGFloat) {
            self.family = family.trimmingCharacters(in: .whitespaces)
            self.codeFamily = codeFamily.trimmingCharacters(in: .whitespaces)
            self.size = Self.clamp(size)
        }

        /// What the page wore before it had a setting: System Monospaced
        /// at 13 points for both prose and code.
        public static let standard = Typeface(family: "", codeFamily: "", size: 13)

        /// The sizes a page will take. Below the floor a page is
        /// illegible and above the ceiling a card holds a word; either
        /// end is a typo in the size field rather than a wish.
        public static let sizeRange: ClosedRange<CGFloat> = 8...40

        public static func clamp(_ size: CGFloat) -> CGFloat {
            min(max(size.rounded(), sizeRange.lowerBound), sizeRange.upperBound)
        }

        /// Whether the prose family is the system's monospaced face, named
        /// by leaving the field empty.
        public var usesSystemFamily: Bool { family.isEmpty }
        public var usesSystemCodeFamily: Bool { codeFamily.isEmpty }

        /// Whether the named family is one this Mac can draw. The system
        /// family always is. Compared case-insensitively, since a user
        /// types "menlo" and the system says "Menlo".
        public var isInstalled: Bool {
            usesSystemFamily || Self.installedName(for: family) != nil
        }

        /// Whether the requested code family resolves to a fixed-pitch font.
        /// Empty always means the system fixed-pitch face.
        public var codeFamilyIsUsable: Bool {
            usesSystemCodeFamily || Self.namedFont(
                family: codeFamily, size: size, weight: .regular
            )?.isFixedPitch == true
        }

        /// The family as the system spells it, or nil when it has no
        /// such family.
        static func installedName(for family: String) -> String? {
            NSFontManager.shared.availableFontFamilies.first {
                $0.caseInsensitiveCompare(family) == .orderedSame
            }
        }

        /// The font this typeface resolves to at one weight and one
        /// size. A family that is not installed resolves to the system
        /// monospaced face rather than to nothing, so a page whose font
        /// was uninstalled is still a page.
        func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            Self.namedFont(family: family, size: size, weight: weight)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        func codeFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            guard let font = Self.namedFont(
                family: codeFamily, size: size, weight: weight
            ), font.isFixedPitch else {
                return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            return font
        }

        private static func namedFont(
            family: String, size: CGFloat, weight: NSFont.Weight
        ) -> NSFont? {
            guard !family.isEmpty, let name = installedName(for: family) else { return nil }
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: name,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            return NSFont(descriptor: descriptor, size: size)
        }
    }

    /// The typeface the page is set in. Written by the model, which
    /// owns the setting; read by everything that styles ink. Setting it
    /// re-derives the fonts below, and the coordinator restyles the
    /// mounted page when it notices the change (`applyTypeface`).
    public static var typeface = Typeface.standard {
        didSet {
            guard typeface != oldValue else { return }
            baseFont = typeface.font(size: typeface.size, weight: .regular)
            codeFont = typeface.codeFont(size: typeface.size, weight: .regular)
            cellWidth = Self.measureCell(in: baseFont)
        }
    }

    public private(set) static var baseFont = Typeface.standard.font(
        size: Typeface.standard.size, weight: .regular
    )

    public private(set) static var codeFont = Typeface.standard.codeFont(
        size: Typeface.standard.size, weight: .regular
    )

    public enum TextRole {
        case prose
        case code
    }

    /// Font selection is range-aware: TextKit measures wrapping and insertion
    /// geometry from the attributed font carried by each prose or code range.
    public static func font(for role: TextRole) -> NSFont {
        switch role {
        case .prose: baseFont
        case .code: codeFont
        }
    }

    public static func font(for kind: LineKind) -> NSFont {
        switch kind {
        case .heading(let level, _): headingFont(level: level)
        case .fenceRule, .code: font(for: .code)
        case .body, .list: font(for: .prose)
        }
    }

    /// The heading ramp, as a proportion of the base size so the
    /// steps keep their shape at any size: 17, 15 and 14 over 13 at the
    /// standard size, whole points at every other.
    public static func headingFont(level: Int) -> NSFont {
        let base = typeface.size
        let size: CGFloat = switch level {
        case 1: (base * 17 / 13).rounded()
        case 2: (base * 15 / 13).rounded()
        case 3: (base * 14 / 13).rounded()
        default: base
        }
        return typeface.font(size: size, weight: .semibold)
    }

    /// The chip's label, two points under the ink it sits in so a chip
    /// reads as a token rather than a word, in the page's own face.
    public static var chipFont: NSFont {
        typeface.font(size: max(typeface.size - 2, Typeface.sizeRange.lowerBound), weight: .medium)
    }

    /// A sealed object's name, in the excerpt's face set semibold (sealed row spec, Row).
    public static var chipNameFont: NSFont {
        typeface.font(size: chipFont.pointSize, weight: .semibold)
    }

    /// `### deploy friday` → (level 3, markerLength 4). Scope for rev C
    /// is headings only; inline emphasis is deliberately deferred.
    public nonisolated static func headingMarker(of line: String) -> (level: Int, length: Int)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard level >= 1, index < line.endIndex, line[index] == " " else { return nil }
        return (level, level + 1)
    }

    /// What a list line counts with: the character a bullet repeats,
    /// the number and delimiter an ordered item carries, or the box a
    /// checklist wears. The task box is a variant of the `-` bullet
    /// rather than a kind of its own, which is how markdown spells it
    /// and how it continues (`- [x] done` begets `- [ ] `).
    public enum ListMarker: Equatable {
        case bullet(Character)
        case ordered(number: Int, delimiter: Character)
        case task(checked: Bool)
    }

    /// A list item as the page reads it: the whitespace it hangs from,
    /// the marker it wears, and how many UTF-16 units stand between the
    /// line's start and its content. That last number is the whole of
    /// what display needs; the prose cell measurement turns that count
    /// into the list's hanging indent.
    public struct ListItem: Equatable {
        public let indent: String
        public let marker: ListMarker
        public let length: Int

        public init(indent: String, marker: ListMarker, length: Int) {
            self.indent = indent
            self.marker = marker
            self.length = length
        }

        /// The prefix the item below this one wears, per ADR-0024's
        /// behaviour table: a bullet repeats itself, an ordered item
        /// counts one on and keeps the delimiter it was typed with, and
        /// a task continues unchecked, because the next thing to do has
        /// not been done. The indent is carried over verbatim, tabs and
        /// all, so a nested item stays at the depth its author chose.
        ///
        /// Nothing here renumbers anything: the successor is previous
        /// plus one and the lines below are the user's, exactly as they
        /// stand in a plain text file (the caret-only law).
        public var successor: String {
            switch marker {
            case .bullet(let character):
                indent + String(character) + " "
            case .ordered(let number, let delimiter):
                // Clamped to the ceiling the parser reads, so the
                // marker written here is always one the parser will
                // read back. A tenth digit would classify as body ink:
                // no hanging indent, no continuation, no way to end the
                // list with one Return. The last item repeats its
                // number instead, which is a list the user can fix.
                indent + String(min(number + 1, 999_999_999)) + String(delimiter) + " "
            case .task:
                indent + "- [ ] "
            }
        }
    }

    /// `  1. buy milk` → (indent "  ", ordered 1 with ".", length 5).
    /// Pure and nonisolated, the shape `headingMarker(of:)` set, so the
    /// reading is testable without a text view and the keystroke path
    /// and the styling path can never be looking at different grammars.
    ///
    /// The marker must be followed by exactly one space, which is the
    /// rule that rejects everything a reader would not call a list:
    /// `-x` is a word, `1.5` is a number, `*emphasis*` is prose. An
    /// item with nothing after that space is an empty item, and saying
    /// so is the caller's business (the length is where content would
    /// begin).
    public nonisolated static func listMarker(of line: String) -> ListItem? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        let indent = String(line[line.startIndex..<index])
        let rest = line[index...]
        guard let first = rest.first else { return nil }
        let prefix = { (marker: Int) in indent.utf16.count + marker + 1 }

        // The task box is read before the bullet it is built on: `- [ ]
        // milk` also parses as a `-` bullet whose content happens to
        // start with a bracket, and the checklist is the more specific
        // reading of the two.
        if let checked = taskBox(of: rest) {
            return ListItem(indent: indent, marker: .task(checked: checked), length: prefix(5))
        }
        if first == "-" || first == "*" || first == "+" {
            guard rest.dropFirst().first == " " else { return nil }
            return ListItem(indent: indent, marker: .bullet(first), length: prefix(1))
        }
        // Nine digits is CommonMark's own ceiling for an ordered
        // marker, and keeping it here means the successor's arithmetic
        // can never overflow the number it counts on.
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")",
              after.dropFirst().first == " "
        else { return nil }
        return ListItem(
            indent: indent,
            marker: .ordered(number: number, delimiter: delimiter),
            length: prefix(digits.count + 1)
        )
    }

    /// True for `- [x] `, false for `- [ ] `, nil for anything that is
    /// not a task box. The trailing space is part of the box for the
    /// same reason it is part of every other marker: without it the
    /// line is a bullet whose content begins with a bracket.
    private nonisolated static func taskBox(of rest: Substring) -> Bool? {
        let head = Array(rest.prefix(6))
        guard head.count == 6, head[0] == "-", head[1] == " ", head[2] == "[",
              head[4] == "]", head[5] == " "
        else { return nil }
        switch head[3] {
        case " ": return false
        case "x", "X": return true
        default: return nil
        }
    }

    /// One representative prose cell, measured once per typeface. List
    /// indentation uses this approximation when prose is proportional.
    /// Code wrapping and caret geometry do not use it; TextKit measures
    /// each attributed code range in `codeFont`.
    public private(set) static var cellWidth: CGFloat = measureCell(in: baseFont)

    private static func measureCell(in font: NSFont) -> CGFloat {
        NSAttributedString(string: "0", attributes: [.font: font]).size().width
    }

    /// Where a list item's wrapped lines hang from: under the content,
    /// never under the marker, so a bullet that runs past the edge
    /// still reads as one item.
    public static func hangingIndent(markerLength: Int) -> CGFloat {
        CGFloat(markerLength) * cellWidth
    }

    /// The wash behind a fenced block: a shade off the page, enough
    /// that a slab of code reads as one thing without turning the page
    /// into a document of boxes.
    public static let codeBackground = NSColor.quaternaryLabelColor

    /// What each kind of token wears inside a fence. The four inks are
    /// written down once, in Theme.swift beside ember, as dynamic
    /// colours darkened or lightened from the system hues until each
    /// clears 4.5:1 on the fence wash in its appearance (D-06); a test
    /// measures them rather than naming them. Color is the whole of
    /// token styling. The surrounding code range keeps `codeFont`, so
    /// coloring cannot change metrics, wrapping, caret geometry, or
    /// bytes.
    public nonisolated static func tokenColor(_ kind: CodeInk.TokenKind) -> NSColor {
        switch kind {
        case .keyword: NSColor.inkKeyword
        case .string: NSColor.inkString
        case .comment: NSColor.inkComment
        case .number: NSColor.inkNumber
        }
    }

    /// One link a body line carries: the whole construct's range, the
    /// URL a ⌘-click would open, and whichever spans of the construct
    /// are markdown syntax rather than reading matter — dimmed on
    /// screen the way a fence's rules are, never hidden. Ranges are
    /// UTF-16 offsets into the line the link was read from.
    public struct InkLink: Equatable {
        public let range: NSRange
        public let target: String
        public let markup: [NSRange]

        public init(range: NSRange, target: String, markup: [NSRange] = []) {
            self.range = range
            self.target = target
            self.markup = markup
        }
    }

    /// The links a line of body ink carries, in document order:
    /// markdown `[text](url)` constructs first, then bare http(s) URLs
    /// that fall outside them. Deliberately conservative — only http
    /// and https, nothing with whitespace, and only strings `URL` will
    /// actually parse — because a link is an affordance to open
    /// something, and a guessed-at target is worse than plain ink.
    /// Pure, so the reading is testable without a text view.
    public nonisolated static func links(in line: String) -> [InkLink] {
        let text = line as NSString
        let full = NSRange(location: 0, length: text.length)
        var found: [InkLink] = []
        // `[text](url)`: the label reads as the link; the brackets, the
        // parens and the URL between them are syntax. The URL half
        // refuses parens and whitespace, which keeps the match from
        // swallowing prose after a stray `(`.
        if let markdown = try? NSRegularExpression(
            pattern: #"\[([^\[\]]*)\]\((https?://[^()\s]+)\)"#
        ) {
            markdown.enumerateMatches(in: line, range: full) { match, _, _ in
                guard let match, match.numberOfRanges == 3 else { return }
                let target = text.substring(with: match.range(at: 2))
                guard URL(string: target) != nil else { return }
                let label = match.range(at: 1)
                found.append(InkLink(
                    range: match.range,
                    target: target,
                    markup: [
                        NSRange(location: match.range.location, length: 1),
                        NSRange(
                            location: NSMaxRange(label),
                            length: NSMaxRange(match.range) - NSMaxRange(label)
                        ),
                    ]
                ))
            }
        }
        // Bare URLs, outside any markdown construct already claimed.
        // The match runs to whitespace and is then walked back off
        // trailing punctuation, so `see https://example.com.` links the
        // URL and leaves the sentence its full stop.
        if let bare = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#) {
            bare.enumerateMatches(in: line, range: full) { match, _, _ in
                guard let match,
                      !found.contains(where: {
                          NSIntersectionRange($0.range, match.range).length > 0
                      })
                else { return }
                let target = trimmedBareURL(text.substring(with: match.range))
                // A scheme alone is not a destination; requiring a host
                // rejects `https://` and its trailing-punctuation
                // remnants while keeping short but real targets like
                // `http://a.io` linked.
                guard URL(string: target)?.host?.isEmpty == false else { return }
                found.append(InkLink(
                    range: NSRange(
                        location: match.range.location, length: target.utf16.count
                    ),
                    target: target
                ))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Walks trailing sentence punctuation back off a bare URL: the
    /// full stop after `https://example.com.` belongs to the sentence.
    /// A closing paren comes off only while unbalanced, so the
    /// Wikipedia idiom `…/Rust_(language)` keeps its tail while
    /// `(see https://example.com)` gives the paren back to the prose.
    private nonisolated static func trimmedBareURL(_ candidate: String) -> String {
        var url = Substring(candidate)
        while let last = url.last {
            if ".,;:!?\"'".contains(last) {
                url = url.dropLast()
            } else if last == ")",
                      url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count {
                url = url.dropLast()
            } else {
                break
            }
        }
        return String(url)
    }

    /// What a line is, once the lines above it have been read.
    ///
    /// A heading is local: a line either opens with hashes and a space
    /// or it does not, and nothing above it can change the answer. A
    /// fence is the exception, and the reason this is an enum rather
    /// than a pair of predicates. After a fence opens, the page stops
    /// being prose until the fence closes, and the only way to know
    /// which side of that boundary a line falls on is to have read the
    /// page down to it.
    public enum LineKind: Equatable {
        /// Ordinary ink.
        case body
        /// A heading line: its level, and how many leading characters
        /// are markup rather than name.
        case heading(level: Int, markerLength: Int)
        /// The fence line itself, opening or closing.
        case fenceRule
        /// A line held inside a fence, whatever it happens to look
        /// like. `# comment` here is a comment, not a heading, and `- x`
        /// is a flag, not a bullet (issue #75). The language is the one
        /// the opening rule named, read through CodeInk's alias table,
        /// and nil for a bare fence or for a language the table has
        /// never heard of. It rides on every line of the block because
        /// the rule that declared it may be a long way above: a line of
        /// code can no more be colored alone than classified alone.
        case code(language: String?)
        /// A body line that opens with a list marker: how many leading
        /// units stand before its content, which is both the width its
        /// wrapped lines hang from and the span the empty-item branch
        /// takes off. Nothing inside a fence ever reaches this case,
        /// which is what lets the keystroke path trust the same reading
        /// the styling used.
        case list(markerLength: Int)
    }

    /// Reads a page's lines in document order and says what each one
    /// is. Carried across the whole walk rather than asked line by
    /// line, because a fence is markup whose meaning is not local: the
    /// same `# comment` is a heading above the fence and a comment
    /// below it.
    public struct FenceScanner {
        /// The fence currently open, if one is: its character, how
        /// long its opening run was, since a closing fence has to be at
        /// least as long as the fence it answers, and the language its
        /// info string named. The info string was always parsed; until
        /// highlighting arrived only its emptiness was consulted, and
        /// the language it carried was read and dropped.
        private var open: (
            marker: Character, length: Int, language: String?, info: String
        )?

        public init() {}

        /// True while the lines being handed over fall inside a fence.
        /// This is also what an unterminated fence leaves behind: the
        /// rest of the page is code, and stays code to the last line,
        /// which is the reading a writer mid-paste would expect.
        public var insideFence: Bool { open != nil }

        /// The renderer selected by the fence currently open, if its
        /// label is a supported CodeInk label. The restyle walk reads this
        /// at the opening rule, which is the one place a tokenizer for the
        /// lines below can be made. Labels without a token scanner still
        /// select fixed-width, uncolored code presentation.
        public var fenceLanguage: String? { open?.language }

        /// The exact trimmed info string on the current opening rule.
        /// Empty and unsupported are different states even though neither
        /// resolves to a tokenizer.
        public var fenceInfoString: String? { open?.info }

        public mutating func classify(_ line: String) -> LineKind {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let run = Self.fenceRun(of: trimmed) {
                guard let open else {
                    self.open = (
                        run.marker, run.length,
                        CodeInk.renderingLanguage(ofInfoString: run.info), run.info
                    )
                    return .fenceRule
                }
                // A closing fence answers its opener: the same
                // character, at least as long, and carrying nothing
                // after it. Anything else met inside a fence is content
                // — a ``` line inside a ~~~ block is text about code,
                // not the end of the block.
                guard run.marker == open.marker, run.length >= open.length, run.info.isEmpty else {
                    return .code(language: open.language)
                }
                self.open = nil
                return .fenceRule
            }
            if let open { return .code(language: open.language) }
            if let marker = headingMarker(of: line) {
                return .heading(level: marker.level, markerLength: marker.length)
            }
            // Read after the fence and after the heading, and only ever
            // on a body line: this is the single place that decides a
            // line is a list, so display and automation cannot come to
            // different answers about the `- x` in a shell snippet
            // (issue #75).
            if let item = listMarker(of: line) { return .list(markerLength: item.length) }
            return .body
        }

        /// The delimiter run a line opens with, if it opens with one:
        /// three or more backticks or tildes, plus whatever the rest of
        /// the line says (the info string, `swift` in "```swift").
        nonisolated static func fenceRun(of trimmed: String) -> (marker: Character, length: Int, info: String)? {
            guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
            let run = trimmed.prefix { $0 == marker }
            guard run.count >= 3 else { return nil }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence cannot carry a backtick in its info
            // string, which is the rule that keeps an inline ```span```
            // from opening a block that swallows the rest of the page.
            if marker == "`", info.contains("`") { return nil }
            return (marker, run.count, info)
        }
    }

    /// A whole page's lines, read in order. The scanner is the working
    /// form; this is the one a reader (and a test) can hold in view.
    public nonisolated static func classify(lines: [String]) -> [LineKind] {
        var scanner = FenceScanner()
        return lines.map { scanner.classify($0) }
    }
}
