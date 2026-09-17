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
        coordinator.invalidateOrdinaryPasteMeasurement()
        guard let textView = scroll.documentView as? InkTextView,
              coordinator.model.activeEditor === textView else { return }
        coordinator.parkEditor()
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
        let layoutManager = InkLayoutManager()
        let container = InkTextContainer(size: NSSize(
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
        coordinator.appliedTypeface = InkStyle.typeface
        coordinator.appliedSyntaxHighlighting = model.syntaxHighlightingEnabled
        coordinator.appliedPreviewRendering = model.previewRendering
        coordinator.appliedLanguageDetection = model.languageDetectionEnabled
        coordinator.appliedFileRenderMode = model.fileRenderMode(for: sheetID)
        coordinator.restyle()
        model.activeEditor = textView
        coordinator.refreshLanguageActionAvailability()
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
        coordinator.applyPreviewRendering(model.previewRendering)
        coordinator.applyLanguageDetection(model.languageDetectionEnabled)
        coordinator.applyFileRenderMode(model.fileRenderMode(for: sheetID))
        // Dead pages take their saved view state with them — the same
        // pruning `refresh()` applies to the storage cache, and keyed
        // the same way, by page identity: a tab outlives its pages
        // (ADR-0017), so a slot's id would keep a dead page's caret and
        // scroll alive for whatever page came next.
        coordinator.pruneViewState(keeping: Set(model.tabs.compactMap(\.pageID)))
        // The stance may have flipped editing on or off above, so the
        // Edit menu's two items are re-asked on every pass, before the
        // early return that a page which did not change takes.
        model.scheduleEditStepsRefresh()
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
        /// The last set `pruneViewState` was handed, so a pass that
        /// changed nothing costs nothing. Nil means "ask again",
        /// which is what a file leaving the roster sets it to.
        private var lastLiveSheets: Set<UInt64>?

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
            guard let documentID = currentSheet, let textView else { return }
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
            guard currentSheet == pending.documentID,
                  let textView, model.activeEditor === textView,
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
                pending.payload, range: selection, caret: caret, startsNewUndoStep: true
            )
        }

        func updateEditability(of textView: InkTextView, to editable: Bool) {
            if textView.isEditable != editable {
                invalidateOrdinaryPasteMeasurement()
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
            refreshLanguageActionAvailability()
            refreshBlockMetadataFocus()
        }

        private func isCurrentOrdinaryPaste(_ context: LanguageDetectionContext) -> Bool {
            guard pendingOrdinaryPasteRequestID == context.requestID,
                  currentSheet == context.documentID,
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
            guard let documentID = currentSheet else { return false }
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
                  let sheet = currentSheet
            else { return nil }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  NSMaxRange(selection) <= storage.length
            else { return nil }

            let intersectsFence = rangeIntersectsFence(selection)
            let inContainer = rangeIntersectsContainer(selection, in: storage.string)
            let intersectsAttachment = rangeIntersectsAttachment(selection, in: storage)
            let markdownCapable = isMarkdownCapable(sheet: sheet)
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

        private func isMarkdownCapable(sheet: UInt64) -> Bool {
            !sheet.isFileID || model.fileRenderMode(for: sheet) == .markdown
        }

        private func isCurrentAutomaticPaste(_ context: LanguageDetectionContext) -> Bool {
            guard model.languageDetectionEnabled,
                  let pendingAutomaticPaste,
                  pendingAutomaticPaste.requestID == context.requestID,
                  pendingAutomaticPaste.documentID == context.documentID,
                  pendingAutomaticPaste.revision == context.revision,
                  currentSheet == context.documentID,
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
                    startsNewUndoStep: true
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
                    startsNewUndoStep: true
                )
            }
        }

        private func applyReplacement(
            _ replacement: String, range: NSRange, caret: NSRange, startsNewUndoStep: Bool
        ) {
            guard let textView, let storage = textView.textStorage,
                  textView.isEditable, !textView.hasMarkedText(),
                  NSMaxRange(range) <= storage.length,
                  textView.shouldChangeText(in: range, replacementString: replacement)
            else { return }
            nextEditIsAutomation = startsNewUndoStep
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            // The core's explicit boundary is in front of one commit. Leave
            // another boundary armed so subsequent typing cannot merge into this
            // complete paste/wrap action and come off in the same undo.
            if startsNewUndoStep {
                nextEditIsAutomation = true
            }
            textView.setSelectedRange(Self.clamped(caret, to: storage.length))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        var manualLanguageTargetAvailable: Bool {
            PageModel.languageDetectionFeaturesAvailable && manualLanguageTarget() != nil
        }

        func refreshLanguageActionAvailability() {
            let canChoose = manualLanguageTargetAvailable
            let selectionIsEmpty: Bool?
            if PageModel.languageDetectionFeaturesAvailable,
               let textView, let storage = textView.textStorage,
               currentSheet != nil, textView.isEditable, !textView.hasMarkedText()
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
                selectionIsEmpty: selectionIsEmpty
            )
            model.sealActions.stand(canSeal: sealableSelection() != nil)
        }

        /// The selection Edit → Seal Selected Content and the context
        /// menu row would seal: non-empty, on an editable page rather
        /// than a file, and not mid-composition. Nil otherwise. The
        /// chord is wider (it takes the current line when nothing is
        /// selected); the menus name a selection and offer only that.
        func sealableSelection() -> NSRange? {
            guard let textView, let storage = textView.textStorage,
                  let sheet = currentSheet, !sheet.isFileID,
                  textView.isEditable, !textView.hasMarkedText()
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
                  currentSheet == target.documentID,
                  UInt64(generation) == target.revision,
                  let textView, textView.isEditable, !textView.hasMarkedText(),
                  textView.selectedRange() == target.selectionSnapshot
            else { return false }
            return manualLanguageTarget() == target
        }

        private func manualLanguageTarget() -> ManualLanguageTarget? {
            guard let textView, let storage = textView.textStorage,
                  let documentID = currentSheet, textView.isEditable,
                  !textView.hasMarkedText()
            else { return nil }
            let selection = textView.selectedRange()
            if selection.length > 0 {
                let destination = PasteDestinationContext(
                    documentText: storage.string,
                    replacementRange: selection,
                    isMarkdownCapable: isMarkdownCapable(sheet: documentID),
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
                        let trimmedHead = line.prefix { $0 == " " || $0 == "\t" }
                        let afterIndent = line.dropFirst(trimmedHead.utf16.count)
                        guard let run = InkStyle.FenceScanner.fenceRun(
                            of: afterIndent.trimmingCharacters(in: .newlines)
                        ) else { return nil }
                        opening = run.info.isEmpty
                            ? (paragraph, NSMaxRange(paragraph), paragraph.location
                                + trimmedHead.utf16.count + run.length)
                            : nil
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
                    isMarkdownCapable: isMarkdownCapable(sheet: suggestion.target.documentID),
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
                    startsNewUndoStep: true
                )
            case .bareFence(let opening, _, let insertion):
                if displayOnly {
                    model.setFenceRenderingLanguage(
                        suggestion.language,
                        sheet: suggestion.target.documentID,
                        at: opening.location
                    )
                    restyle()
                } else {
                    languageSuggestion = nil
                    applyReplacement(
                        suggestion.language,
                        range: NSRange(location: insertion, length: 0),
                        caret: NSRange(location: insertion + suggestion.language.utf16.count, length: 0),
                        startsNewUndoStep: true
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
            invalidateOrdinaryPasteMeasurement()
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
            refreshLanguageActionAvailability()
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
        func saveViewState(textView: InkTextView, scrollView: NSScrollView?) {
            guard let sheet = currentSheet else { return }
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

        /// Forget one id's caret and scroll outright.
        ///
        /// The counterpart to the tag exemption in `pruned`. A file is
        /// exempt from the page prune because it is never in the live
        /// page set, so something has to drop its entries when it
        /// actually goes, and this is that something. Called when a
        /// file leaves the roster, never on a page: a page's entries
        /// are the prune's business.
        func forgetViewState(for sheet: UInt64) {
            savedCarets[sheet] = nil
            savedScrolls[sheet] = nil
            // The prune's guard compares against the last live set and
            // returns early when it has not changed. Clearing it means
            // the next prune actually runs rather than skipping over a
            // set that looks familiar.
            lastLiveSheets = nil
        }

        /// Which ids hold a caret and which hold a scroll offset.
        ///
        /// A reading seam for the test that a closed file leaves
        /// nothing behind in either map. Both are private, and asking
        /// through the save or restore paths would write an entry
        /// rather than read one.
        var viewStateKeys: (carets: Set<UInt64>, scrolls: Set<UInt64>) {
            (Set(savedCarets.keys), Set(savedScrolls.keys))
        }

        /// The pure half of `pruneViewState`: keep only the entries
        /// whose keys are still live.
        ///
        /// A file id is always live here. The set is built from page
        /// identities and a file is never among them, so without the
        /// exemption a file's caret and scroll are thrown away on every
        /// pass of `updateNSView`, and page to file to page returns the
        /// file to the top with the caret at zero. A file's entries go
        /// when the file closes, which drops the whole id.
        nonisolated static func pruned<Value>(
            _ table: [UInt64: Value], keeping live: Set<UInt64>
        ) -> [UInt64: Value] {
            table.filter { $0.key.isFileID || live.contains($0.key) }
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

        /// Restyle the mounted page when the preview-rendering scope
        /// changes. `.never` short-circuits to the plain-file path, and
        /// the other two return to the block walk; the roll picks up its
        /// own reseed through the notification the model posts.
        func applyPreviewRendering(_ scope: PreviewRenderingScope) {
            guard appliedPreviewRendering != scope else { return }
            appliedPreviewRendering = scope
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
            guard let sheet = currentSheet, let textView else { return }
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
            let outcome = back ? model.undoEdit(sheet: sheet) : model.redoEdit(sheet: sheet)
            guard outcome.applied else { return }
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
            // A step that carried no position leaves the caret alone,
            // clamped, rather than guessing at an offset.
            let length = textView.textStorage?.length ?? 0
            let landing = outcome.caret ?? textView.selectedRange().location
            let caret = Self.clamped(NSRange(location: landing, length: 0), to: length)
            textView.setSelectedRange(caret)
            // Rewriting the whole storage resets the scroller, so a
            // step taken over an edit that was off screen would put the
            // caret somewhere the writer cannot see. Follow it.
            textView.scrollRangeToVisible(caret)
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
            // Bumped before every guard below, projection writes and
            // compositions included, because this counter answers one
            // question only: has anything at all changed since the walk
            // that filled the classification cache. An edit this method
            // declines to emit still moves the page under that reading.
            generation &+= 1
            structuralStyleNeedsRebuild = true
            if let sheet = currentSheet {
                // Display-only inferred labels belong to the old character
                // projection and cannot survive a projection rewrite.
                model.clearFenceRenderingLanguages(for: sheet)
            }
            abandonAutomaticConversionForEditorChange()
            if model.isApplyingProjection {
                let changedGeneration = generation
                let changedSheet = currentSheet
                DispatchQueue.main.async { [weak self, weak storage] in
                    guard let self, let storage,
                          self.structuralStyleNeedsRebuild,
                          self.generation == changedGeneration,
                          self.currentSheet == changedSheet,
                          self.textView?.textStorage === storage
                    else { return }
                    self.restyle()
                }
                return
            }
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
            invalidateOrdinaryPasteMeasurement()
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

        /// Set for the one edit that follows, by the keystroke handlers
        /// that write on the writer's behalf: a continued list marker,
        /// a nudged indent. The core gives such a batch its own undo
        /// step, so one press takes the automation back and leaves the
        /// words typed before it standing (issue #132).
        ///
        /// A one-shot rather than a mode, and consumed in `emit` rather
        /// than cleared by the caller, because an automation edit that
        /// somehow produced no batch must not hand its boundary to
        /// whatever the writer types next.
        var nextEditIsAutomation = false

        /// Encode and send one batch. Empty batches never cross: a
        /// no-op is not an operation.
        private func emit(_ ops: [DocumentEditOp], sheet: UInt64) {
            let automation = nextEditIsAutomation
            nextEditIsAutomation = false
            guard !ops.isEmpty, let json = DocumentEditOp.wireJSON(ops) else { return }
            model.applyOps(sheet: sheet, opsJSON: json, startingNewStep: automation)
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
            guard let textView, let storage = textView.textStorage else { return }
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

        static func chipString(_ chip: ChipInfo) -> NSAttributedString {
            NSAttributedString(attachment: ChipAttachment(info: chip))
        }

        // MARK: Chip actions: a click selects, a secondary click offers actions, never content

        /// The chip's menu, in order (D-29): the two egresses, then the
        /// removal set apart. Lifted so the titles are pinned by a test
        /// rather than read off a screen.
        static let chipMenuTitles = [
            "Copy decrypted contents",
            "Create one-time link…",
            "Remove protected content",
        ]

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
            // The object's menu is the three items and nothing the text
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

        /// The chip's three actions, appended to `menu` for the chip
        /// standing at `charIndex`: the egresses first, a separator,
        /// then the removal, which keeps today's behaviour of deleting
        /// the sentinel whole (the two stage removal is a separate
        /// call).
        func appendChipItems(to menu: NSMenu, at charIndex: Int) {
            guard let storage = textView?.textStorage, charIndex < storage.length,
                  let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil)
                    as? ChipAttachment
            else { return }
            let chipID = attachment.info.chipId
            let copy = NSMenuItem(
                title: Self.chipMenuTitles[0],
                action: #selector(copyOutChip(_:)),
                keyEquivalent: ""
            )
            copy.target = self
            // The item carries the object's place rather than its id,
            // so the action can read the block's own size class off
            // the storage for the confirmation line.
            copy.representedObject = charIndex as NSNumber
            // The chord beside the verb is the keymap's, the way every
            // tooltip names its chord: a keymap that moved
            // `chip::CopyDecrypted` moves this, and one that unbound it
            // leaves the verb alone. Display only; the page's text view
            // dispatches the chord itself, so the menu item advertises
            // and never claims.
            if let chord = model.keymap.hintKeystroke(for: .chipCopyDecrypted) {
                copy.keyEquivalent = chord.menuKeyEquivalent
                copy.keyEquivalentModifierMask = chord.menuModifierMask
            }
            menu.addItem(copy)
            let conceal = NSMenuItem(
                title: Self.chipMenuTitles[1],
                action: #selector(concealChip(_:)),
                keyEquivalent: ""
            )
            conceal.target = self
            conceal.representedObject = chipID as NSNumber
            menu.addItem(conceal)
            menu.addItem(.separator())
            let remove = NSMenuItem(
                title: Self.chipMenuTitles[2],
                action: #selector(removeChip(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = charIndex as NSNumber
            // The separator and verb carry the destructive meaning;
            // leave menu text styling to AppKit.
            menu.addItem(remove)
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
        func copyOutChip(at index: Int) {
            guard let storage = textView?.textStorage, index < storage.length,
                  let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
                    as? ChipAttachment
            else { return }
            model.copyOutChip(
                attachment.info.chipId,
                size: SealedBlockCell.displayedSizeClass(attachment.info.sizeLabel)
            )
        }

        // MARK: Links — ⌘-click opens, a plain click edits (ADR-0023)

        /// Every click on a `.link` range lands here, and the answer is
        /// always "handled", because the default answer — open on any
        /// click — makes the URL's own text uneditable by mouse. With ⌘
        /// held the click is an aimed gesture and the link opens;
        /// without it the click is editing, so the caret is placed
        /// where the click fell, exactly as on any other ink.
        public func textView(
            _ view: NSTextView, clickedOnLink link: Any, at charIndex: Int
        ) -> Bool {
            let event = NSApp.currentEvent
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
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url { NSWorkspace.shared.open(url) }
            return true
        }

        @objc private func copyOutChip(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
            copyOutChip(at: index)
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
                // The line says what happened. Its Undo steps the
                // core's stack back once the core keeps a removed
                // object to step back to (issue 170); until then the
                // model offers the line without the button.
                model.noteRemoval { [weak self] in self?.step(back: true) }
            }
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
            guard let storage = textView?.textStorage, let sheet = currentSheet else { return }
            // `.never` uses the plain visual profile everywhere. Markdown-capable
            // pages still need the Markdown walk's classifications and fence ranges
            // for editing and paste safety, but neither result is rendered.
            if model.previewRendering == .never {
                restylePlainFile(
                    storage, sheet: sheet,
                    preservingMarkdownStructure: !sheet.isFileID
                )
                return
            }
            if sheet.isFileID {
                switch model.fileRenderMode(for: sheet) {
                case .plainText:
                    restylePlainFile(storage, sheet: sheet)
                    return
                case .source(let language):
                    restyleSourceFile(storage, sheet: sheet, language: language)
                    return
                case .markdown:
                    break
                }
            }
            // A file gets no block stamps, and the route is not merely
            // skipped for dull values: `blocks(sheet:)` is a
            // companion_sheet_* route, and a tagged id reaching it is
            // refused core-side. Asking anyway would spend a refused
            // call on every keystroke. A file's document does carry
            // change timestamps, because it is a SheetDocument like any
            // other, but they describe when this process happened to
            // read the file rather than when a person wrote a
            // paragraph, so there is nothing true to show
            // (decisions.md item 15).
            let metas = sheet.isFileID ? [] : model.coreClient.blocks(sheet: sheet)
            let (regions, displays, kinds) = Self.applyMarkdownStyling(
                to: storage, sheet: sheet, blockMetas: metas,
                syntaxHighlightingEnabled: model.syntaxHighlightingEnabled,
                fenceRenderingLanguages: model.fenceRenderingLanguages(for: sheet)
            )
            blockDisplays = displays
            fenceRegions = regions
            lineKinds = kinds
            lineKindsStamp = generation
            lineKindsSheet = sheet
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                layoutManager.fenceRegions = fenceRegions
                textView?.needsDisplay = true
            }
            // Block metadata rides the first line instead of taking a row
            // above it, so the page keeps its ordinary top inset regardless
            // of which blocks have been edited.
            if let textView, textView.textContainerInset.height != Self.topInset {
                textView.textContainerInset.height = Self.topInset
            }
            refreshBlockMetadataFocus()
            updateBlockLabelViews()
        }

        /// The pure part of `restyle()`: walk the storage block by block
        /// under one whole-page fence scanner, style each paragraph, and
        /// return the fence regions, block metadata displays and the
        /// classifications. Shared with `PageModel.quietRendering(for:)`
        /// so a quiet day laid over its own temporary storage reads the
        /// same as the mounted editor would over its live one.
        static func applyMarkdownStyling(
            to storage: NSTextStorage,
            sheet: UInt64,
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
                    head: head, meta: meta,
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
            _ storage: NSTextStorage, sheet: UInt64,
            preservingMarkdownStructure: Bool = false
        ) {
            let text = storage.string as NSString
            let full = NSRange(location: 0, length: storage.length)
            let structure = preservingMarkdownStructure
                ? Self.applyMarkdownStyling(
                    to: storage, sheet: sheet,
                    blockMetas: model.coreClient.blocks(sheet: sheet),
                    syntaxHighlightingEnabled: model.syntaxHighlightingEnabled,
                    fenceRenderingLanguages: model.fenceRenderingLanguages(for: sheet),
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
            lineKindsSheet = sheet
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                // The ranges remain available to the editor's behavior gates, but
                // `.never` must not paint the Markdown fence slab.
                layoutManager.fenceRegions = []
                textView?.needsDisplay = true
            }
            if textView?.textContainerInset.height != Self.topInset {
                textView?.textContainerInset.height = Self.topInset
            }
            updateBlockLabelViews()
        }

        /// Source mode tokenizes the complete buffer as code. No Markdown
        /// scanner runs here, so `#`, lists, links, and fence markers retain
        /// their literal source meaning.
        private func restyleSourceFile(_ storage: NSTextStorage, sheet: UInt64, language: String) {
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
            lineKindsSheet = sheet
            structuralStyleNeedsRebuild = false
            if let layoutManager = textView?.layoutManager as? InkLayoutManager {
                layoutManager.fenceRegions = []
                textView?.needsDisplay = true
            }
            if textView?.textContainerInset.height != Self.topInset {
                textView?.textContainerInset.height = Self.topInset
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
        /// its first paragraph. Untouched blocks deliberately have no
        /// display: the surrounding checkpoint already supplies temporal
        /// context, while an edit is the state worth signaling at rest.
        /// Never holds an origin: the editable-surface rule keeps origin
        /// off every read surface, this one included.
        struct BlockDisplay {
            var range: NSRange
            let compactText: String
            let detailText: String
            let accessibilityText: String
        }

        /// One core block as the first restyle pass read it: where it
        /// starts, what it carries, and whether it began inside a fence
        /// another block opened — the fact the second pass groups by.
        private struct BlockWalk {
            let head: NSRange
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
            if group.count == 1, let walk = group.first {
                guard !walk.blank, let createdS = walk.meta?.createdS,
                      let modifiedS = walk.meta?.modifiedS
                else { return nil }
                return blockDisplay(createdS: createdS, modifiedS: modifiedS)
            }
            let stamps = group.compactMap(\.meta).map { ($0.createdS, $0.modifiedS) }
            guard let created = stamps.compactMap({ $0.0 }).min() else { return nil }
            let modified = stamps.compactMap { $0.1 ?? $0.0 }.max() ?? created
            return blockDisplay(createdS: created, modifiedS: modified)
        }

        /// The stamp a fence region wears: earliest created to latest
        /// touch across every block the region spans, since the lines
        /// were typed over a stretch of time but read as one slab. A
        /// block that was touched but never modified counts its created
        /// stamp as its latest, and a region with no committed content
        /// at all wears nothing.
        static func fenceRegionDetails(
            stamps: [(createdS: Int64?, modifiedS: Int64?)]
        ) -> String? {
            guard let created = stamps.compactMap({ $0.createdS }).min() else { return nil }
            let modified = stamps.compactMap { $0.modifiedS ?? $0.createdS }.max()
            guard let modified else { return nil }
            return blockDetails(createdS: created, modifiedS: modified)
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
        private var lineKindsSheet: UInt64?

        /// The classification of the paragraph beginning exactly at
        /// `location`, or nil when the walk has nothing trustworthy to
        /// say about it. Exact, because a paragraph that has moved is a
        /// paragraph the walk has not seen yet.
        func classifiedKind(ofParagraphAt location: Int) -> InkStyle.LineKind? {
            guard textView?.textStorage != nil,
                  generation == lineKindsStamp,
                  let sheet = currentSheet, sheet == lineKindsSheet
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

        /// What the last restyle laid out, in document order: one entry
        /// per edited block, the range being the line its affordance
        /// rides. The window tests get onto the block walk; nothing
        /// writes through it.
        var blockLabelLayout: [(range: NSRange, text: String)] {
            blockDisplays.map { ($0.range, $0.compactText) }
        }

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
        /// The page's own top margin.
        static let topInset: CGFloat = 12

        private static let blockTimeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()

        private static let blockDayTimeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE HH:mm"
            return formatter
        }()

        private static let blockAccessibilityFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        /// The expanded reading uses the checkpoint's day context while
        /// both stamps stay on that day. A cross-day edit restores the
        /// weekday because it has become information again.
        static func blockDetails(createdS: Int64, modifiedS: Int64) -> String? {
            guard modifiedS > createdS else { return nil }
            let createdDate = Date(timeIntervalSince1970: TimeInterval(createdS))
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modifiedS))
            // The operation log sees the first and last keystrokes of a
            // newly typed block as different touches. Preserve the old
            // minute-granularity collapse so ordinary typing does not
            // immediately label nearly every block as edited.
            guard !Calendar.current.isDate(
                createdDate, equalTo: modifiedDate, toGranularity: .minute
            ) else { return nil }
            let formatter = Calendar.current.isDate(createdDate, inSameDayAs: modifiedDate)
                ? blockTimeFormatter : blockDayTimeFormatter
            return "created \(formatter.string(from: createdDate)) · edited \(formatter.string(from: modifiedDate))"
        }

        private static func blockDisplay(createdS: Int64, modifiedS: Int64) -> BlockDisplay? {
            guard let detail = blockDetails(createdS: createdS, modifiedS: modifiedS) else {
                return nil
            }
            let createdDate = Date(timeIntervalSince1970: TimeInterval(createdS))
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modifiedS))
            let accessibility = "Created \(blockAccessibilityFormatter.string(from: createdDate)); edited \(blockAccessibilityFormatter.string(from: modifiedDate))"
            return BlockDisplay(
                range: NSRange(location: 0, length: 0),
                compactText: "edited", detailText: detail,
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
                field.stringValue = expanded ? display.detailText : display.compactText
                field.toolTip = display.accessibilityText
                field.setAccessibilityLabel(display.accessibilityText)
                field.sizeToFit()
                // One padding rule for both readings, so the pill grows
                // and shrinks without appearing to change shape.
                field.frame.size.width = ceil(field.frame.width) + Self.blockLabelPadding * 2
                field.frame.size.height = max(
                    Self.blockLabelMinHeight, ceil(field.frame.height) + 6
                )
                field.layer?.cornerRadius = field.frame.height / 2
            }
            repositionBlockLabels()
        }

        private static func makeBlockLabel() -> BlockMetadataField {
            let field = BlockMetadataField(labelWithString: "")
            field.font = blockLabelFont
            field.textColor = .secondaryLabelColor
            field.alignment = .center
            field.isSelectable = false
            field.isEditable = false
            field.drawsBackground = true
            field.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
            field.isBezeled = false
            field.wantsLayer = true
            field.layer?.cornerRadius = blockLabelMinHeight / 2
            field.layer?.masksToBounds = true
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.35).cgColor
            field.setAccessibilityElement(true)
            field.setAccessibilityRole(.staticText)
            return field
        }

        /// Place every affordance at the trailing edge of its block's
        /// first line. Geometry only, no core round trip, so this is safe
        /// to call on every layout pass: a resize rewraps paragraphs
        /// without changing what any block says.
        func repositionBlockLabels() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let origin = textView.textContainerOrigin
            for (field, display) in zip(blockLabelViews, blockDisplays) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: display.range, actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { continue }
                let usedRect = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                field.frame.origin = Self.blockAffordanceOrigin(
                    firstLine: usedRect, containerWidth: container.size.width,
                    containerOrigin: origin, affordanceSize: field.frame.size
                )
            }
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
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let horizontal = origin.x...(origin.x + container.size.width)
            guard horizontal.contains(point.x) else { return nil }
            return blockDisplays.first { display in
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: display.range, actualCharacterRange: nil
                )
                guard glyphs.length > 0 else { return false }
                let line = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphs.location, effectiveRange: nil
                )
                return (origin.y + line.minY...origin.y + line.maxY).contains(point.y)
            }?.range.location
        }

        private func refreshBlockMetadataFocus() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            let next = blockDisplays.first { display in
                selection.location != NSNotFound
                    && NSLocationInRange(selection.location, display.range)
            }?.range.location
            guard next != focusedBlockLocation else { return }
            focusedBlockLocation = next
            updateBlockLabelViews()
        }
    }
}

/// Block metadata is informative until the revision read API exists.
/// Let pointer gestures fall through to the editor so the compact pill
/// never steals caret placement or text selection from the line it rides.
private final class BlockMetadataField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override class var cellClass: AnyClass? {
        get { BlockMetadataCell.self }
        set { super.cellClass = newValue }
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
    func chooseCodeLanguage(_ language: String)
    func pasteWithoutDetection(_ sender: Any?)
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

final class InkTextView: NSTextView, EditStepResponder, LanguageDetectionResponder,
    SealResponder
{
    weak var coordinator: InkEditorView.Coordinator?

    var canChooseCodeLanguage: Bool {
        coordinator?.manualLanguageTargetAvailable == true
    }

    func chooseCodeLanguage(_ language: String) {
        coordinator?.applyManualLanguage(language)
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
        }
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
        let point = convert(event.locationInWindow, from: nil)
        hoveredChipIndex = coordinator?.chipIndex(at: point, in: self)
        coordinator?.updateBlockMetadataHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredChipIndex = nil
        coordinator?.updateBlockMetadataHover(at: nil)
    }

    private func redrawChip(at index: Int) {
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

    /// A click on the explicit actions affordance opens the object's menu.
    /// Control-primary over a chip takes the same direct route as a
    /// secondary click, avoiding text-system additions to the menu. Every
    /// other primary click stays on AppKit's attachment path, whose
    /// delegate selects the object without opening anything.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if Self.shouldOpenChipContextMenu(
            clickCount: event.clickCount, modifierFlags: event.modifierFlags),
           let coordinator,
           let index = coordinator.chipIndex(at: point, in: self)
        {
            setSelectedRange(NSRange(location: index, length: 1))
            coordinator.openChipMenu(at: index, from: point, in: self)
            return
        }
        guard Self.shouldOpenChipActions(
            clickCount: event.clickCount, modifierFlags: event.modifierFlags)
        else {
            super.mouseDown(with: event)
            return
        }
        if let coordinator,
           let index = coordinator.chipIndex(at: point, in: self),
           let frame = chipFrame(at: index),
           SealedBlockCell.actionsRect(in: frame).contains(point)
        {
            setSelectedRange(NSRange(location: index, length: 1))
            coordinator.openChipMenu(at: index, from: point, in: self)
            return
        }
        super.mouseDown(with: event)
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
        coordinator?.appendSealItem(to: menu)
        coordinator?.appendLanguageItems(to: menu)
        return menu
    }

    /// A resize rewraps paragraphs without touching their content, so
    /// the block affordances (ADR-0013) need only be moved, not recomputed
    /// from the core, cheap enough to run on every layout pass.
    override func layout() {
        updateChipEditorMeasure()
        super.layout()
        coordinator?.repositionBlockLabels()
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
        if let command = editorCommand(for: event), command.modifiers.contains(.command),
           dispatch(command.id) {
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
        coordinator?.step(back: true)
    }

    @objc func redo(_ sender: Any?) {
        coordinator?.step(back: false)
    }

    /// Edit → Seal Selected Content, arriving nil-targeted. The same
    /// method the chord and the context menu row run; a page shown
    /// read-only refuses it here, as it refuses the chord.
    @objc func sealSelectedContent(_ sender: Any?) {
        guard isEditable else { return }
        coordinator?.sealSelectionOrLine()
    }

    /// The answer for any nil-targeted item that asks this view about
    /// the two step actions: the core's, because the core holds the
    /// stack, and `NSTextView`'s own for everything else the menu asks
    /// about.
    ///
    /// It is not what greys out the app's own Edit menu. Those two
    /// items are built in SwiftUI and carry SwiftUI's target rather
    /// than walking the responder chain to be validated, so they are
    /// dimmed from `PageModel.editSteps` instead, which asks the core
    /// the same question this method does.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let sheet = coordinator?.currentSheet, let model = coordinator?.model else {
            return super.validateMenuItem(item)
        }
        switch item.action {
        case #selector(undo(_:)):
            return isEditable && model.canUndoEdit(sheet: sheet)
        case #selector(redo(_:)):
            return isEditable && model.canRedoEdit(sheet: sheet)
        case #selector(detectCodeLanguage(_:)):
            return canDetectCodeLanguage
        case #selector(pasteWithoutDetection(_:)):
            return PageModel.languageDetectionFeaturesAvailable && isEditable
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
        default:
            return coordinator.model.perform(command)
        }
        return true
    }

    /// Ordinary paste remains plain when the preference is off. When it is on,
    /// Option bypasses automatic fencing for this paste only.
    override func paste(_ sender: Any?) {
        let bypass = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        performOrdinaryPaste(sender, bypassingAutomaticFencing: bypass) { [unowned self] sender in
            pasteAsPlainText(sender)
        }
    }

    var canDetectCodeLanguage: Bool {
        PageModel.languageDetectionFeaturesAvailable
            && isEditable
            && coordinator?.canDetectCodeLanguage == true
    }

    @objc func detectCodeLanguage(_ sender: Any?) {
        guard canDetectCodeLanguage else { return }
        coordinator?.detectCodeLanguage()
    }

    @objc func pasteWithoutDetection(_ sender: Any?) {
        guard PageModel.languageDetectionFeaturesAvailable, isEditable else { return }
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
            coordinator?.nextEditIsAutomation = true
            storage.replaceCharacters(in: prefix, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: paragraph.location, length: 0))
            return
        }
        // One keystroke, one undo step, and since issue #132 that is
        // the core's arrangement rather than AppKit's: the marker is an
        // edit the page made on the writer's behalf, so the batch it
        // emits begins its own step and a single ⌘Z takes it back with
        // none of the words typed before it. The newline and the marker
        // go down as one `insertText`, the ordinary route every other
        // character takes, and the flag rides that one batch across.
        coordinator?.nextEditIsAutomation = true
        insertText("\n" + item.successor, replacementRange: caret)
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
        coordinator?.nextEditIsAutomation = true
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        // Where the caret lands is the whole of whether the gesture
        // repeats. It keeps its place relative to the line's content,
        // so after a nudge it is still in the marker region and a
        // second press nudges again; an outdent that eats the ground
        // under it leaves it at the line's start, which is inside the
        // region too.
        let width = (replacement as NSString).length
        let landing = caret.location >= NSMaxRange(range)
            ? caret.location - range.length + width
            : range.location + width
        setSelectedRange(NSRange(location: landing, length: 0))
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
    let info: ChipInfo

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

    @MainActor
    private var classificationLabel: NSAttributedString {
        NSAttributedString(
            string: Self.classification,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 1.15,
            ]
        )
    }

    @MainActor
    private var metadata: NSAttributedString {
        NSAttributedString(
            string: Self.displayedSizeClass(info.sizeLabel),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
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

        /// The size class is drawn at its own measured width, ending at
        /// the column's trailing edge.
        func metadataOrigin(width: CGFloat) -> NSPoint {
            NSPoint(x: metadataRight - width, y: metadataY)
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
            metadataY: bottomRowY + metrics.metadataBaselineNudge
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
    private var actions: NSAttributedString {
        NSAttributedString(
            string: Self.actionsGlyph,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
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
        let view = controlView as? InkTextView
        let selected = view.map { $0.selectedRange() == NSRange(location: charIndex, length: 1) }
            ?? false
        let hovered = view?.hoveredChipIndex == charIndex
        draw(withFrame: cellFrame, in: controlView, selected: selected, hovered: hovered)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, selected: false, hovered: false)
    }

    /// State first, identity second, actions third: the lock and the
    /// classification on the top row with the actions glyph at its
    /// end, the excerpt and the size class on the row under them. A
    /// selected block wears the ember keyline and its tint, the same
    /// way the card says it holds the keyboard, paired with the
    /// selection itself so the colour is never the only carrier.
    @MainActor
    private func draw(withFrame cellFrame: NSRect, in controlView: NSView?, selected: Bool, hovered: Bool) {
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

        classificationLabel.draw(at: layout.labelOrigin)
        if hovered || selected {
            let glyph = actions
            let size = glyph.size()
            let seat = Self.actionsRect(in: cellFrame)
            glyph.draw(at: NSPoint(
                x: seat.maxX - size.width,
                y: seat.midY - size.height / 2
            ))
        }

        let excerptLine = excerpt
        let metadataSize = metadata.size()
        excerptLine.draw(in: layout.excerptRect(
            metadataWidth: metadataSize.width,
            height: excerptLine.size().height
        ))
        metadata.draw(at: layout.metadataOrigin(width: metadataSize.width))
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
