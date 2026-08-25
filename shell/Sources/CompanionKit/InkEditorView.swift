import AppKit
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
        // A fresh editor mount follows a teardown: a ledger round trip,
        // or the empty state, which since ADR-0017 is reached whenever
        // the selected tab holds no page and not only when the last
        // page died. Every cached undo manager still holds operations
        // bound to the torn-down view; shed them before this view
        // registers its own, so ⌘Z rewrites live text instead of firing
        // at a zombie (issue #23).
        model.discardUndoHistory()
        let textView = Self.makeInkTextView(
            model: model, sheetID: sheetID, coordinator: context.coordinator
        )
        // Whether the page accepts typing is the stance's business and
        // not the editor's, which is why it is set here rather than in
        // the building: `updateNSView` re-gates it on every pass, since
        // resting and raising change what the editor accepts without
        // changing the editor.
        textView.isEditable = !readOnly

        let scroll = Self.scrollStack(for: textView)
        context.coordinator.observeClip(of: scroll)
        context.coordinator.applyWrap(model.wrapsLines)
        return scroll
    }

    /// The editor is going away: a ledger round trip, or the empty
    /// state that the selected tab holding no page puts on screen
    /// (ADR-0017 made that a frequent event rather than a rare one).
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
    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let textView = scroll.documentView as? InkTextView,
              coordinator.model.activeEditor === textView else { return }
        coordinator.model.activeEditor = nil
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
    @MainActor
    static func makeInkTextView(
        model: PageModel, sheetID: UInt64, coordinator: Coordinator
    ) -> InkTextView {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        let storage = model.storage(for: sheetID)
        // The page's storage outlives any one editor instance, the
        // ledger and the empty state unmount the editor, even though
        // page↔page switches no longer do (ADR-0006). Detach layout
        // managers a torn-down editor left behind so exactly one
        // drives this storage.
        Coordinator.shedLayoutManagers(from: storage, keeping: nil)
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
        textView.allowsUndo = true
        Self.enableFinding(on: textView)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: 12, height: Coordinator.topInset
        )
        textView.typingAttributes = [
            .font: InkStyle.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.delegate = coordinator
        textView.coordinator = coordinator
        coordinator.textView = textView
        coordinator.currentSheet = sheetID
        coordinator.restyle()
        model.activeEditor = textView
        // The summon-time offer's button takes the same road as ⇧⌘V,
        // so the chip lands at the caret and consent stays a gesture
        // aimed at this page (ADR-0007 Amendment 1).
        model.performSealedPaste = { [weak coordinator] in
            coordinator?.sealedPaste()
        }
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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
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
    /// moves with the card (`clipFrameChanged`).
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
        textView.minSize = NSSize(width: clip.width, height: 0)
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = scroll.documentView as? InkTextView else { return }
        model.activeEditor = textView
        // The stance can change without the page changing, so editing
        // is re-gated on every pass rather than at mount alone.
        textView.isEditable = !readOnly
        // Same for wrapping, which ⌥Z and Settings can flip while the
        // page stays put. The coordinator skips the pass when the state
        // has not moved, so the common update rebuilds no geometry.
        coordinator.observeClip(of: scroll)
        coordinator.applyWrap(model.wrapsLines)
        // Dead pages take their saved view state with them — the same
        // pruning `refresh()` applies to the storage cache, and keyed
        // the same way, by page identity: a tab outlives its pages
        // (ADR-0017), so a slot's id would keep a dead page's caret and
        // scroll alive for whatever page came next.
        coordinator.pruneViewState(keeping: Set(model.tabs.compactMap(\.pageID)))
        guard coordinator.currentSheet != sheetID else { return }
        // The page under the editor changed, so hand the editor over.
        // The scroller goes with it: on this surface the editor is the
        // only page in its clip, so the offset the user left this page
        // at is the offset to put back when they return.
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
        var currentSheet: UInt64?

        /// Caret and scroll are view state. With one editor serving
        /// every page (ADR-0006) they no longer die with a torn-down
        /// view — they must be carried per page by hand: saved before
        /// the storage swap takes the page away, restored after its
        /// return.
        private var savedCarets: [UInt64: NSRange] = [:]
        private var savedScrolls: [UInt64: NSPoint] = [:]

        /// The live set the last prune saw. `pruneViewState` runs on
        /// every `updateNSView` pass, and the set rarely changes, so
        /// this gate lets the common pass skip the dictionary filters.
        private var lastLiveSheets: Set<UInt64> = []

        init(model: PageModel) {
            self.model = model
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
            currentSheet = sheetID
            restyle()
            restoreViewState(textView: textView, scrollView: scrollView, for: sheetID)
        }

        // MARK: Per-page view state (ADR-0006)

        /// Remember the outgoing page's caret and scroll before the
        /// swap. The pending typing group settles first, so half a
        /// word is not left open in a page that is going away.
        ///
        /// A mount with no scroller of its own saves the caret and stops
        /// there. There is no offset belonging to this page to read, and
        /// whatever a scrolled mount once saved is left standing rather
        /// than overwritten with a guess.
        func saveViewState(textView: InkTextView, scrollView: NSScrollView?) {
            guard let sheet = currentSheet else { return }
            textView.breakUndoCoalescing()
            savedCarets[sheet] = textView.selectedRange()
            guard let scrollView else { return }
            savedScrolls[sheet] = scrollView.contentView.bounds.origin
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
        /// closure still holds the true offset, so it writes that back
        /// on its way out. A sheet pruned in the interim stays gone:
        /// the write-back repairs entries, it never resurrects them.
        /// And because content can shrink while a page is in the
        /// background, the offset is clamped against the geometry that
        /// exists on arrival, not the geometry that was saved.
        ///
        /// A mount with no scroller of its own takes the caret and stops
        /// there, as `saveViewState` did: there is no clip of this page's
        /// to move, so no hop is scheduled and any offset a scrolled
        /// mount saved stays where it is, waiting for that mount.
        func restoreViewState(
            textView: InkTextView, scrollView: NSScrollView?, for sheet: UInt64
        ) {
            let caret = Self.clamped(
                savedCarets[sheet] ?? NSRange(location: 0, length: 0),
                to: textView.textStorage?.length ?? 0
            )
            textView.setSelectedRange(caret)
            guard let scrollView else { return }
            let offset = savedScrolls[sheet] ?? .zero
            DispatchQueue.main.async { [weak self, weak textView, weak scrollView] in
                guard let self else { return }
                guard self.currentSheet == sheet else {
                    if self.savedScrolls[sheet] != nil {
                        self.savedScrolls[sheet] = offset
                    }
                    return
                }
                guard let scrollView else { return }
                // Measure against layout that has been forced current,
                // not the `frame` height a relayout still in flight can
                // report as zero. The text view is the document view;
                // when its TextKit stack is somehow gone, fall back to
                // the frame the clamp used to trust.
                let documentHeight = textView.flatMap { self.documentHeight(of: $0) }
                    ?? scrollView.documentView?.frame.height ?? 0
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

        /// Dead pages take their view state with them — the same
        /// pruning `refresh()` applies to the storage cache.
        func pruneViewState(keeping live: Set<UInt64>) {
            guard live != lastLiveSheets else { return }
            lastLiveSheets = live
            savedCarets = Self.pruned(savedCarets, keeping: live)
            savedScrolls = Self.pruned(savedScrolls, keeping: live)
        }

        /// The pure half of `pruneViewState`: keep only the entries
        /// whose keys are still live.
        nonisolated static func pruned<Value>(
            _ table: [UInt64: Value], keeping live: Set<UInt64>
        ) -> [UInt64: Value] {
            table.filter { live.contains($0.key) }
        }

        // MARK: Wrapping (⌥Z, Settings)

        /// The scroll view this editor's page sits in. Weak and held
        /// only so a wrap change, which arrives through the model rather
        /// than through a view, can reach the geometry it has to rebuild.
        private weak var scrollView: NSScrollView?

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

        /// Watch the clip so the unwrapped page's width floor stays level
        /// with the card. Registered by selector rather than by block:
        /// that registration is zeroing, so it retires with this
        /// coordinator and needs no `deinit` to unpick it. Idempotent —
        /// every `updateNSView` calls it, and the same clip re-registers
        /// to nothing.
        func observeClip(of scroll: NSScrollView) {
            guard scrollView !== scroll else { return }
            scrollView = scroll
            NotificationCenter.default.removeObserver(
                self, name: NSView.frameDidChangeNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: scroll.contentView
            )
        }

        /// The card resized. Wrapped, the autoresizing mask has already
        /// done everything needed. Unwrapped, the text view sizes itself
        /// to its text and nothing else would ever widen it, so the floor
        /// is re-levelled here and a page narrower than the card is
        /// stretched to meet it.
        @objc private func clipFrameChanged(_ notification: Notification) {
            guard appliedWrap == false, let textView, let scroll = scrollView else { return }
            let width = scroll.contentSize.width
            textView.minSize = NSSize(width: width, height: 0)
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

        /// One undo history per page, from the model's cache: the text
        /// view asks its delegate on every undo touch, so history
        /// simply follows `currentSheet` across storage swaps — ⌘Z
        /// after a switch rewrites the page it was typed on, never a
        /// neighbour (ADR-0006).
        public func undoManager(for view: NSTextView) -> UndoManager? {
            guard let sheet = currentSheet else { return nil }
            return model.undoManager(for: sheet)
        }

        // MARK: Editing (ops across the seam, ADR-0013)

        public func textDidChange(_ notification: Notification) {
            restyle()
        }

        /// The composition the IME gate is tracking: where it started,
        /// what stood there before it began, and how long the span has
        /// grown to. Nil while no composition is in flight.
        struct CompositionSpan {
            let location: Int
            let baseline: String
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
            guard !model.isApplyingProjection else { return }
            guard let sheet = currentSheet else { return }
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
                finishComposition(in: storage, sheet: sheet)
                return
            }
            emit(Self.editOps(storage: storage, editedRange: editedRange, changeInLength: delta),
                 sheet: sheet)
        }

        /// A composition is starting: remember what the span it will
        /// replace held, so its end can be diffed against a truth
        /// rather than replayed edit by edit.
        func beginComposition(over range: NSRange, in storage: NSTextStorage) {
            guard imeComposition == nil else { return }
            let clamped = Self.clamped(range, to: storage.length)
            imeComposition = CompositionSpan(
                location: clamped.location,
                baseline: (storage.string as NSString).substring(with: clamped),
                spanLength: clamped.length
            )
        }

        /// The composition resolved: diff the accumulated span against
        /// its pre-composition baseline. Equal means an abandoned
        /// composition (Esc), and an abandoned composition must
        /// produce zero ops; different commits the minimal replace.
        func finishComposition(in storage: NSTextStorage, sheet: UInt64) {
            guard let ime = imeComposition else { return }
            imeComposition = nil
            let text = storage.string as NSString
            let span = NSRange(location: ime.location, length: max(0, ime.spanLength))
            guard NSMaxRange(span) <= text.length else {
                // The span outran the storage, so there is nothing trustworthy to
                // diff, so fall back to the recovery mirror.
                model.syncDocument(sheet: sheet, runs: Self.runs(of: storage))
                return
            }
            let final = text.substring(with: span)
            guard final != ime.baseline else { return }
            emit(Self.minimalReplace(at: ime.location, old: ime.baseline, new: final),
                 sheet: sheet)
        }

        /// If a composition is still tracked once the view unmarks
        /// (a cancel that never produced a resolving character edit),
        /// settle it now against the storage as it stands.
        func finishCompositionIfPending() {
            guard imeComposition != nil,
                  let textView, !textView.hasMarkedText(),
                  let storage = textView.textStorage,
                  let sheet = currentSheet
            else { return }
            finishComposition(in: storage, sheet: sheet)
        }

        /// Encode and send one batch. Empty batches never cross: a
        /// no-op is not an operation.
        private func emit(_ ops: [DocumentEditOp], sheet: UInt64) {
            guard !ops.isEmpty, let json = DocumentEditOp.wireJSON(ops) else { return }
            model.applyOps(sheet: sheet, opsJSON: json)
            onEmit?(ops)
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
                    ops.append(.chip(at: pos, id: chip.info.chipId))
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
                    runs.append(.chip(chip.info.chipId))
                } else if range.length > 0 {
                    runs.append(.ink(text.substring(with: range)))
                }
            }
            return runs
        }

        // MARK: The seal gestures

        /// ⇧⌘V: the core reads the pasteboard itself, deletes the
        /// selection captured here, and stands the chip in its place,
        /// one atomic locked call. This process never sees the pasted
        /// bytes.
        func sealedPaste() {
            guard let textView else { return }
            // Captured at gesture time and passed whole. The seal call
            // is synchronous on the main actor from here through the C
            // seam, so no event can move the caret between this capture
            // and the core's replace: the range is still true when the
            // core deletes it.
            let range = textView.selectedRange()
            guard let chip = model.sealPasteboard(replacing: range) else { return }
            placeChipFace(chip, replacing: range)
        }

        /// A drop from outside: the core reads the drag pasteboard
        /// itself while the session's data is still on it, and replaces
        /// the drop point (a zero-length range) with the sentinel in
        /// the same locked call.
        func sealDrop(at characterIndex: Int) -> Bool {
            guard let textView else { return false }
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
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            var range = textView.selectedRange()
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
                model.flash("already sealed — a chip has no plaintext to seal")
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
        private func placeChipFace(_ chip: ChipInfo, replacing range: NSRange) {
            guard let textView, let storage = textView.textStorage else { return }
            model.applyingProjection {
                if textView.shouldChangeText(in: range, replacementString: nil) {
                    storage.replaceCharacters(in: range, with: Self.chipString(chip))
                    textView.didChangeText()
                }
            }
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            textView.undoManager?.removeAllActions()
        }

        static func containsChip(_ storage: NSTextStorage, in range: NSRange) -> Bool {
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value is ChipAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        static func chipString(_ chip: ChipInfo) -> NSAttributedString {
            NSAttributedString(attachment: ChipAttachment(info: chip))
        }

        // MARK: Chip actions — hover/click reveals actions, never content

        public func textView(
            _ view: NSTextView,
            clickedOn cell: NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            guard let chipCell = cell as? ChipCell else { return }
            let chipID = chipCell.info.chipId
            let menu = NSMenu()
            let copy = NSMenuItem(
                title: "Copy out — stays sealed",
                action: #selector(copyOutChip(_:)),
                keyEquivalent: ""
            )
            copy.target = self
            copy.representedObject = chipID as NSNumber
            menu.addItem(copy)
            let conceal = NSMenuItem(
                title: "Conceal into a one-time link…",
                action: #selector(concealChip(_:)),
                keyEquivalent: ""
            )
            conceal.target = self
            conceal.representedObject = chipID as NSNumber
            menu.addItem(conceal)
            let remove = NSMenuItem(
                title: "Remove chip",
                action: #selector(removeChip(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = charIndex as NSNumber
            menu.addItem(remove)
            menu.popUp(positioning: nil, at: NSPoint(x: cellFrame.minX, y: cellFrame.maxY), in: view)
        }

        @objc private func copyOutChip(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.uint64Value else { return }
            model.copyOutChip(id)
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
                textView.didChangeText() // travels as a del op; the core reaps the chip
            }
        }

        // MARK: Markdown — styled, never rewritten

        /// Display-only, markup-preserving (docs/spec/04): a heading
        /// line renders at heading weight with its `#`s dimmed in
        /// place. Attributes only; the bytes of the page never change.
        /// Also the ADR-0013 editable-surface rule's display instance:
        /// created/modified are pulled fresh from the core and laid out
        /// as labels above each block, styling the text without
        /// touching how it edits.
        func restyle() {
            guard let storage = textView?.textStorage, let sheet = currentSheet else { return }
            let text = storage.string as NSString
            let metas = model.coreClient.blocks(sheet: sheet)
            var displays: [BlockDisplay] = []
            storage.beginEditing()
            var location = 0
            var block = 0
            // One scanner for the whole page, since a fence opened in
            // one block goes on holding the lines of the blocks after
            // it: what a line means depends on everything above it
            // (issue #75).
            var scanner = InkStyle.FenceScanner()
            while location < text.length {
                let meta = block < metas.count ? metas[block] : nil
                // A block is usually one paragraph and sometimes several
                // (a paste keeps its lines together, ADR-0013), so the
                // page is walked block by block, and the stamp stands
                // above the block's first line rather than above every
                // line the paste brought with it.
                let extent = Self.blockRange(
                    from: location, paragraphs: meta?.paragraphs ?? 1, of: text
                )
                // A blank block is spacing, not writing: it carries a
                // stamp in the core but shows none, so a page of empty
                // paragraphs no longer stacks a column of identical
                // times down the margin.
                let blank = Self.isBlank(extent, of: text)
                let createdS = blank ? nil : meta?.createdS
                var head = extent
                var paragraphStart = location
                while paragraphStart < NSMaxRange(extent) {
                    let paragraph = text.paragraphRange(
                        for: NSRange(location: paragraphStart, length: 0)
                    )
                    // Only the block's first line reserves the gap the
                    // label sits in; the rest of a pasted passage runs on
                    // at ordinary spacing.
                    let leads = paragraphStart == location
                    if leads { head = paragraph }
                    styleParagraph(
                        paragraph, of: storage,
                        kind: scanner.classify(text.substring(with: paragraph)),
                        labeled: createdS != nil && leads
                    )
                    if paragraph.length == 0 { break }
                    paragraphStart = NSMaxRange(paragraph)
                }
                if let createdS {
                    displays.append(BlockDisplay(
                        range: head,
                        text: Self.blockLabel(createdS: createdS, modifiedS: meta?.modifiedS)
                    ))
                }
                block += 1
                if extent.length == 0 { break }
                location = NSMaxRange(extent)
            }
            storage.endEditing()
            blockDisplays = displays
            // `paragraphSpacingBefore` is ignored on the first paragraph
            // of the storage, so the top block's gap has to come from the
            // container inset instead — otherwise its label would be laid
            // out above the text view's own top edge and clipped away.
            let leading = displays.first?.range.location == 0
            let inset = Self.topInset + (leading ? Self.blockLabelReserve : 0)
            if let textView, textView.textContainerInset.height != inset {
                textView.textContainerInset.height = inset
            }
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

        private func styleParagraph(
            _ range: NSRange, of storage: NSTextStorage,
            kind: InkStyle.LineKind, labeled: Bool
        ) {
            guard range.length > 0 else { return }
            let paragraphStyle = NSMutableParagraphStyle()
            // Room for the label above the block, reserved only where
            // one will actually render: an untouched block carries no
            // stamp and gets no gap.
            paragraphStyle.paragraphSpacingBefore = labeled ? Self.blockLabelReserve : 0
            // Every line is laid back down to plain ink first, the wash
            // included, because a line that was code a keystroke ago
            // has to be able to stop being code when the fence above it
            // closes or is deleted.
            storage.addAttributes(
                [
                    .font: InkStyle.baseFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: paragraphStyle,
                ],
                range: range
            )
            switch kind {
            case .body:
                break
            case .heading(let level, let markerLength):
                storage.addAttribute(
                    .font,
                    value: InkStyle.headingFont(level: level),
                    range: range
                )
                // The `### ` stays on screen, dimmed, exactly where typed.
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: range.location, length: markerLength)
                )
            case .fenceRule:
                // The fence's own line is markup, dimmed the way a
                // heading's hashes are, and washed like the lines it
                // brackets so the block reads as one slab.
                storage.addAttributes(
                    [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .backgroundColor: InkStyle.codeBackground,
                    ],
                    range: range
                )
            case .code:
                // Literally what was typed: the markup a code line
                // carries is part of the code, so nothing here is read
                // as a heading and nothing is dimmed.
                storage.addAttribute(
                    .backgroundColor,
                    value: InkStyle.codeBackground,
                    range: range
                )
            }
        }

        // MARK: Block labels (ADR-0013: created/modified above each block)

        /// One block's label and the paragraph range it renders above,
        /// recomputed by `restyle` whenever content changes and read by
        /// `repositionBlockLabels` on every layout pass. Never holds an
        /// origin: the editable-surface rule keeps origin off every read
        /// surface, this one included.
        private struct BlockDisplay {
            let range: NSRange
            let text: String
        }

        private var blockDisplays: [BlockDisplay] = []
        private var blockLabelViews: [NSTextField] = []

        /// What the last restyle laid out, in document order: one entry
        /// per labeled block, the range being the line its label sits
        /// above. The window tests get onto the block walk; nothing
        /// writes through it.
        var blockLabelLayout: [(range: NSRange, text: String)] {
            blockDisplays.map { ($0.range, $0.text) }
        }

        private static let blockLabelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        /// Vertical gap a labeled block reserves above its first line:
        /// the label's own height plus a little air on both sides.
        static let blockLabelReserve: CGFloat = 20
        /// The page's own top margin, before any label reserve.
        static let topInset: CGFloat = 12

        private static let blockLabelFormatter: DateFormatter = {
            let formatter = DateFormatter()
            // `DDD HH:mm` (ADR-0013): day name and clock time only,
            // since these are short-lived pages, and a full calendar date
            // would overstate how long anything here is expected to
            // live. The literal `HH` holds the clock at 24-hour
            // regardless of locale; the weekday name still localizes.
            formatter.dateFormat = "EEE HH:mm"
            return formatter
        }()

        /// `Thu 14:32`, or `Thu 14:32 → Thu 14:40` once the block has
        /// been edited past its first commit. The comparison is on the
        /// rendered stamps, not the raw seconds: the format keeps no
        /// seconds, so an edit forty seconds after the first commit
        /// still reads as one stamp rather than the degenerate range
        /// `Thu 14:32 → Thu 14:32`.
        static func blockLabel(createdS: Int64, modifiedS: Int64?) -> String {
            let created = blockLabelFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(createdS))
            )
            guard let modifiedS else { return created }
            let modified = blockLabelFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(modifiedS))
            )
            guard modified != created else { return created }
            return "\(created) → \(modified)"
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
                field.stringValue = display.text
                field.sizeToFit()
            }
            repositionBlockLabels()
        }

        private static func makeBlockLabel() -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.font = blockLabelFont
            field.textColor = .tertiaryLabelColor
            field.isSelectable = false
            field.isEditable = false
            return field
        }

        /// Place every label in the gap above its block's first line.
        /// Geometry only, no core round trip, so this is safe to call on
        /// every layout pass: a resize rewraps paragraphs without
        /// changing what any block says.
        func repositionBlockLabels() {
            guard let textView, let layoutManager = textView.layoutManager,
                  textView.textContainer != nil else { return }
            let origin = textView.textContainerOrigin
            for (field, display) in zip(blockLabelViews, blockDisplays) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: display.range, actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { continue }
                // The line fragment rect swallows `paragraphSpacingBefore`:
                // it starts where the previous paragraph ended, so
                // measuring from its top drops the label onto that
                // paragraph's last line. The used rect is where this
                // block's glyphs actually begin, and the reserved gap is
                // the space immediately above it.
                let usedRect = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                field.frame.origin = NSPoint(
                    x: origin.x + usedRect.minX,
                    y: origin.y + usedRect.minY - field.frame.height - 2
                )
            }
        }
    }
}

// MARK: - The text view

/// The page's text view: routes the seal gestures, keeps ⌘V plain,
/// hands Esc back, and seals external drops through the core's drag
/// route. Chips are atomic under the caret by construction — an
/// attachment is one character: arrows step over it, one ⌫ removes it
/// whole, selection cannot reach inside it.
final class InkTextView: NSTextView {
    weak var coordinator: InkEditorView.Coordinator?

    /// A resize rewraps paragraphs without touching their content, so
    /// the block labels (ADR-0013) need only be moved, not recomputed
    /// from the core, cheap enough to run on every layout pass.
    override func layout() {
        super.layout()
        coordinator?.repositionBlockLabels()
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
        if let command = editorCommand(for: event), command.modifiers.contains(.command),
           dispatch(command.id) {
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        super.keyDown(with: event)
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
        default:
            return coordinator.model.perform(command)
        }
        return true
    }

    /// ⌘V behaves like every text editor on the machine — plain text,
    /// no surprises (docs/spec/04).
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
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
    override func performFindPanelAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !refusesFinderAction(sender) else { return }
        super.performTextFinderAction(sender)
    }

    /// True for a ⌘E over a selection holding a chip. The action arrives
    /// as the sender's tag; a sender carrying no readable tag is let
    /// through, because this is a refusal to be certain about and not a
    /// reason to break find.
    func refusesFinderAction(_ sender: Any?) -> Bool {
        guard (sender as? NSMenuItem)?.tag == NSTextFinder.Action.setSearchString.rawValue,
              let storage = textStorage,
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
        coordinator?.markedTextInFlight = true
        super.setMarkedText(
            string, selectedRange: selectedRange, replacementRange: replacementRange)
        coordinator?.markedTextInFlight = false
        // Marking with an empty string IS the cancel: the view is
        // unmarked again, and the composition must settle to zero ops.
        coordinator?.finishCompositionIfPending()
    }

    /// The commit path: the input context replaces the marked text
    /// with the final string. The composition settles after the edit,
    /// as one diffed batch against the pre-composition baseline.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        coordinator?.finishCompositionIfPending()
    }

    /// A composition can end without a resolving character edit (a
    /// cancel that removed nothing because nothing was composed); the
    /// unmark is the one signal that always fires, so settle here.
    override func unmarkText() {
        super.unmarkText()
        coordinator?.finishCompositionIfPending()
    }

    /// Esc hands the keyboard back (docs/spec/04, the focus law).
    override func cancelOperation(_ sender: Any?) {
        coordinator?.model.escape()
    }

    // MARK: Drop-to-seal

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isExternalDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isExternalDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    /// Dragging content to a secrecy tool is already the "stage this"
    /// gesture: an external drop seals. The core reads the drag
    /// pasteboard itself — the dropped bytes never enter this process.
    /// Internal drags (moving ink within the page) stay ordinary text
    /// editing.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isExternalDrag(sender) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        return coordinator?.sealDrop(at: index) ?? false
    }

    private func isExternalDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView) !== self
    }
}

// MARK: - The chip, rendered

/// A sealed chip's place in the document: an attachment character
/// carrying only the chip's id and mechanical face. There is no
/// affordance — and no data — to reveal what it stands for.
final class ChipAttachment: NSTextAttachment {
    let info: ChipInfo

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = ChipCell(info: info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }
}

/// Draws the chip: `[ excerpt · size ]`, a quiet capsule of exactly the
/// mechanical excerpt the seal route returned — recognizable to the
/// person who pasted it, opaque to a stranger.
final class ChipCell: NSTextAttachmentCell {
    let info: ChipInfo

    private nonisolated static let padding = NSSize(width: 9, height: 3)

    @MainActor
    init(info: ChipInfo) {
        self.info = info
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("chips are never unarchived")
    }

    private nonisolated var label: NSAttributedString {
        NSAttributedString(
            string: "\(info.excerpt) · \(info.sizeLabel)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    override func cellSize() -> NSSize {
        let text = label.size()
        return NSSize(
            width: text.width.rounded(.up) + Self.padding.width * 2,
            height: text.height.rounded(.up) + Self.padding.height * 2
        )
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -(Self.padding.height + 2))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let capsule = NSBezierPath(
            roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5,
            yRadius: 5
        )
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        capsule.fill()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(
            x: cellFrame.minX + Self.padding.width,
            y: cellFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Type

/// The page's type ramp: monospaced ink; headings by weight and size,
/// their markup dimmed in place (docs/spec/04).
@MainActor
public enum InkStyle {
    public static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    public static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        case 2: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        case 3: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        default: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        }
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

    /// The wash behind a fenced block: a shade off the page, enough
    /// that a slab of code reads as one thing without turning the page
    /// into a document of boxes.
    public static let codeBackground = NSColor.quaternaryLabelColor

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
        /// is a flag, not a bullet (issue #75).
        case code
    }

    /// Reads a page's lines in document order and says what each one
    /// is. Carried across the whole walk rather than asked line by
    /// line, because a fence is markup whose meaning is not local: the
    /// same `# comment` is a heading above the fence and a comment
    /// below it.
    public struct FenceScanner {
        /// The fence currently open, if one is: its character and how
        /// long its opening run was, since a closing fence has to be at
        /// least as long as the fence it answers.
        private var open: (marker: Character, length: Int)?

        public init() {}

        /// True while the lines being handed over fall inside a fence.
        /// This is also what an unterminated fence leaves behind: the
        /// rest of the page is code, and stays code to the last line,
        /// which is the reading a writer mid-paste would expect.
        public var insideFence: Bool { open != nil }

        public mutating func classify(_ line: String) -> LineKind {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let run = Self.fenceRun(of: trimmed) {
                guard let open else {
                    self.open = (run.marker, run.length)
                    return .fenceRule
                }
                // A closing fence answers its opener: the same
                // character, at least as long, and carrying nothing
                // after it. Anything else met inside a fence is content
                // — a ``` line inside a ~~~ block is text about code,
                // not the end of the block.
                guard run.marker == open.marker, run.length >= open.length, run.info.isEmpty else {
                    return .code
                }
                self.open = nil
                return .fenceRule
            }
            if open != nil { return .code }
            guard let marker = headingMarker(of: line) else { return .body }
            return .heading(level: marker.level, markerLength: marker.length)
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
