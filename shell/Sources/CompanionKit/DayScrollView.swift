import AppKit
import SwiftUI

/// The roll: every live day on one surface, today at the top and the
/// days before it below, behind labelled perforations (issue #79,
/// ADR-0020).
///
/// One `NSScrollView` over one flipped stack laid out top-down by frame.
/// Per day the stack holds a header (the tear, the relative label, and
/// that page's own gutter with its title, its countdown and its verbs)
/// and under it the page itself. Exactly one of those pages is the app's
/// single editor (ADR-0006): the same `InkTextView`, built by the same
/// factory, driven by the same coordinator, so op emission, restyling,
/// chip rendering, the seal gestures and per-page undo are the shipped
/// paths rather than a second copy of them that could quietly stop
/// agreeing with the first.
///
/// The editor is a **permanent child** of the stack. A day switch moves
/// its frame origin and swaps the storage underneath it, and
/// `removeFromSuperview` is never called on it, so nothing resigns first
/// responder and no composition or caret is lost crossing a
/// perforation, the exact class of bug issues #19, #22 and #23 closed.
///
/// Every other visible page is a `QuietPageView`: a rendering over its
/// **own** private storage, not editable, not selectable, and unable to
/// take first responder. Private storages are what keep the roll out of
/// `PageModel.storages`, `shedLayoutManagers` and the
/// projection-parity assertion entirely, every storage in the app still
/// carries exactly one layout manager, because each still has exactly
/// one view. There is still one editor, one `activeEditor`, one
/// `performSealedPaste` and one first-responder candidate in the app,
/// which is the whole of the claim that ADR-0006's second eject trigger
/// ("a future feature needs per-sheet view instances") has not fired.
///
/// Since ADR-0033 there are two windows, and the roll mounts only in
/// the one that owns the page content: the panel, resting or raised,
/// while it owns, and the editor window while that owns. The window
/// that does not own mounts no editor on any live storage; it draws a
/// glance built from private storages (`GlanceView`), or nothing. So
/// the counts above hold for the whole app and not only for one
/// window, which is what ADR-0033's one owner per page rule keeps.
///
/// Perforations are chrome, and that is a security property rather than
/// a drawing preference: anything inserted into a text storage to
/// separate two days would travel across the seam as an insert op and
/// land in somebody's document.
///
/// Nothing here animates. The anchors are instant clip moves, so there
/// is no `prefers-reduced-motion` branch to maintain and nothing that
/// could scroll itself against doc 05's motion and frugality
/// commitments.
public struct DayScrollView: NSViewRepresentable {
    @ObservedObject var model: PageModel

    /// Refuse edits while still showing the pages, the backdrop's
    /// resting glance, on the same terms `InkEditorView` takes it. The
    /// stance can change without the days changing, so it is re-gated on
    /// every pass rather than at mount alone.
    let readOnly: Bool

    /// The second line of the empty state's copy, named as the gesture
    /// that actually conjures a page on this surface. Carried in rather
    /// than invented here so that an empty Today inside the roll reads
    /// word for word like the empty state the strip's surface shows.
    let emptyHint: String

    public init(model: PageModel, readOnly: Bool = false, emptyHint: String) {
        self.model = model
        self.readOnly = readOnly
        self.emptyHint = emptyHint
    }

    /// The editor's own coordinator, and deliberately not a new type.
    /// Everything the page does (emit ops, restyle, render chips, seal
    /// a selection, answer for undo) is this object's, and a roll with
    /// a coordinator of its own would be a second implementation of the
    /// page for the mode to drift away from.
    public func makeCoordinator() -> InkEditorView.Coordinator {
        InkEditorView.Coordinator(model: model)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Before the roll is built, because the building writes to the
        // model and every such write says which window it comes from
        // (ADR-0033).
        context.coordinator.surface = context.environment.presentationSurface
        let scroll = Self.makeRoll(
            model: model, coordinator: context.coordinator, emptyHint: emptyHint
        )
        // The summon half of the anchor rule. Held weakly, so a surface
        // that has gone away cannot be scrolled and cannot be kept
        // alive by the model holding a way to reach it. The owner's
        // roll only: one made in the other window installs nothing,
        // and the pass that finds its window owning puts the anchor in
        // (`updateRoll`).
        let surface = context.coordinator.surface
        if model.owner == surface {
            Self.installTodayAnchor(on: scroll, model: model, from: surface)
        }
        return scroll
    }

    private static func installTodayAnchor(
        on scroll: NSScrollView, model: PageModel, from surface: PresentationOwner
    ) {
        model.installTodayAnchor(
            { [weak scroll] in
                (scroll?.documentView as? DayStackView)?.scrollToDayZero()
            },
            from: surface
        )
    }

    /// The roll's claim on the rail's navigator: this stack is the one
    /// the rail listens to, and these are its answers to the two things
    /// the rail may ask of a roll, a jump to an offset and a wheel that
    /// turned over the rail, and to the one thing the model asks at a
    /// hand off, where the roll stands. All weak, so a torn-down roll
    /// answers with nothing.
    private static func claimRollGeometry(
        for stack: DayStackView, in scroll: NSScrollView,
        model: PageModel, from surface: PresentationOwner
    ) {
        model.claimRollGeometry(
            by: stack,
            scroller: { [weak stack] offset in stack?.scroll(toDocumentOffset: offset) },
            wheel: { [weak scroll] event in scroll?.scrollWheel(with: event) },
            place: { [weak stack] in stack?.currentPlace },
            from: surface
        )
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.updateRoll(
            scroll, model: model, readOnly: readOnly, coordinator: context.coordinator
        )
    }

    /// The pass SwiftUI asks for on every published change. A static
    /// for `makeRoll`'s reason: what a pass puts back when ownership
    /// returns is worth asserting, and a test cannot make a `Context`.
    static func updateRoll(
        _ scroll: NSScrollView,
        model: PageModel, readOnly: Bool, coordinator: InkEditorView.Coordinator
    ) {
        guard let stack = scroll.documentView as? DayStackView else { return }
        // A pass over a roll whose window does not own does nothing,
        // for `InkEditorView.updatePage`'s reason: the pass settles
        // the editor on a page, and settling sheds that page's layout
        // managers.
        let surface = coordinator.surface
        guard model.owner == surface else { return }
        // Ownership can leave and come back before SwiftUI has taken
        // this roll down, and the transfer dropped what the mount
        // installed. A roll still standing when its window owns again
        // puts both back, and so does a roll that was made while the
        // other window owned and so installed neither. The ordinary
        // pass finds them in place and writes nothing: a fresh claim
        // blanks the navigator until the next measurement, which is
        // not something to do every second.
        if model.onAnchorToday == nil {
            Self.installTodayAnchor(on: scroll, model: model, from: surface)
        }
        if !model.rollGeometry.holdsClaim(stack) {
            Self.claimRollGeometry(for: stack, in: scroll, model: model, from: surface)
        }
        // The place the other window's roll left at the hand off, for
        // the first owned pass of this one. Set down in the stack and
        // not applied here: the rows it names are assembled by the pass
        // below, and SwiftUI may not have sized the clip yet.
        if let place = model.viewStates.takeRollPlace() {
            stack.open(at: place)
        }
        stack.update(
            projection: model.timeUnits,
            selectedPage: model.selectedPageID,
            readOnly: readOnly
        )
    }

    /// The roll is going away: the ledger, or the toggle going off. The
    /// model's handle on the editor is retired here for
    /// `InkEditorView.dismantleNSView`'s reason, a weak handle answers
    /// for a view torn out of its window until ARC lets go, and a
    /// hand-off arriving in the meantime would settle on a view with no
    /// window rather than wait for the surface coming to replace it
    /// (issue #23). Only when the handle is still this mount's: SwiftUI
    /// may build a replacement before dismantling what it replaces, and
    /// clearing unconditionally would drop the live editor a moment
    /// after it arrived.
    ///
    /// The anchor closure is deliberately left alone for the same
    /// reason, without the identity check being available to it: a
    /// replacement roll has already installed its own by now, and the
    /// closure this mount installed holds its scroller weakly, so an
    /// anchor that outlives its surface is a no-op rather than a
    /// misfire.
    public static func dismantleNSView(
        _ scroll: NSScrollView, coordinator: InkEditorView.Coordinator
    ) {
        coordinator.invalidateOrdinaryPasteMeasurement()
        guard let stack = scroll.documentView as? DayStackView else { return }
        // Whatever became of the editor, this roll's measurement
        // describes a surface that is going away, and the rail must not
        // keep drawing the shape of it behind a ledger (issue #131).
        // Under the same rule as the handle below, and for the same
        // interleaving: a replacement roll that has already claimed the
        // measurement has also already published one, and this parting
        // word would blank it until the next pass happened to re-measure.
        coordinator.model.rollGeometry.reset(from: stack)
        guard let editor = stack.editor else { return }
        // The editor comes off its page on the way out, as the page's
        // own dismantle takes it off: the caret is left with the model,
        // so the surface that mounts this page next finds it, and the
        // layout manager leaves the storage. The caret only: the roll's
        // offset belongs to the roll's one clip and to no page in it,
        // and it is the hand off that carries it to the other window
        // (`PageModel.transferOwnership`), never a dismantle, since a
        // roll rebuilt in its own window opens at Day 0. A parked
        // editor stands on no page and an editor already replaced has
        // no storage, and `leavePage` declines both.
        coordinator.leavePage(editor, scrollView: nil)
        coordinator.model.retireEditor(editor)
    }

    /// The roll, assembled: one scroller over one flipped stack.
    ///
    /// A static rather than a body of `makeNSView`, because a test
    /// cannot make a SwiftUI `Context` and everything worth asserting
    /// about this surface is geometry, where the regions sit, which
    /// view is where, what the clip can reach. The app and the tests
    /// therefore build the same object out of the same call.
    static func makeRoll(
        model: PageModel, coordinator: InkEditorView.Coordinator, emptyHint: String
    ) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // The card's own material shows through the roll, as it does
        // through the page.
        scroll.drawsBackground = false
        let stack = DayStackView(
            model: model, coordinator: coordinator, emptyHint: emptyHint
        )
        // A roll with nothing laid out in it has no proportions to
        // report, and the rail's navigator must not spend this pass
        // drawing the shape of the roll it is replacing (issue #131).
        // The claim also names this stack as the one the rail listens
        // to, so the roll it replaces cannot answer for it on the way
        // out. The first `relayout` publishes the real measurement a
        // moment later. The claim is the owner's (ADR-0033): a roll
        // made in the window that does not own leaves the navigator
        // with the roll that has it, and claims on the pass that finds
        // its own window owning (`updateRoll`).
        if model.owner == coordinator.surface {
            claimRollGeometry(for: stack, in: scroll, model: model, from: coordinator.surface)
        }
        scroll.documentView = stack
        stack.observeRoll()
        // The clip the wrap geometry is levelled against is the roll's,
        // there being exactly one for every day in it.
        coordinator.observeClip(of: scroll)
        // The mount half of the anchor rule. A fresh clip is at its
        // origin already, so this says the rule rather than enforcing
        // it, which is the point: there is no anchoring state that can
        // be wrong, only a place the roll opens at. The one roll that
        // opens elsewhere is the one a hand off left a place for, and
        // it is moved there by its first owned pass (`updateRoll`).
        stack.scrollToDayZero()
        return scroll
    }
}

// MARK: - The stack

/// The days, stacked. Flipped, so a child's frame origin is measured
/// down from the top of the document and time runs the way the reader
/// reads: today at zero, yesterday under it, the day before that under
/// that.
///
/// Auto Layout is not in play anywhere here. Every child is placed by
/// frame, out of one `relayout()` that measures each region against the
/// layout it was actually given, `ensureLayout(for:)` and then
/// `usedRect`, the one measurement the page's scroll restore already
/// trusts, rather than against a `frame` height a relayout still in
/// flight may report as zero.
final class DayStackView: NSView {
    /// One row of the roll: a header, and what stands under it.
    private struct Row {
        let header: DayHeaderView
        /// The editor, a quiet region, or the place today's page would
        /// go.
        let body: NSView
        /// The day this row was laid out for, as the projection counts
        /// them. Carried so the rail's navigator can be told which day
        /// each stretch of the roll belongs to (issue #131); a day
        /// holding two pages has two rows and one bucket, and the
        /// navigator draws two nodes under one day's words.
        let bucket: Int
        /// The page under this header, or nil for the empty Today
        /// place, which is a place and not a page (ADR-0017).
        let page: UInt64?
        /// This row is an empty Today with no history below it, so it
        /// takes the rest of the viewport rather than a line's worth of
        /// it: the empty state is the surface at that moment, not a
        /// caption at the top of a blank card.
        let fillsViewport: Bool
    }

    /// What the roll was last built for. Two passes that agree on all of
    /// it rebuild nothing: `refresh()` runs on every accepted edit
    /// batch, so the common pass has to be a measure and not an
    /// assembly.
    ///
    /// The clip's width is in it because a region's height is a fact
    /// about the width it was wrapped at, and the card is resizable.
    private struct Signature: Equatable {
        let buckets: [Int]
        let pages: [[UInt64]]
        let selected: UInt64?
        let clipWidth: CGFloat
    }

    let model: PageModel
    let coordinator: InkEditorView.Coordinator
    private let emptyHint: String

    /// The one editor, once a page has existed for it to stand on. Nil
    /// only before the roll has ever had a page to show; from the first
    /// mount onward this view is a permanent child of the stack.
    private(set) var editor: InkTextView?

    /// The quiet regions by page, kept across passes so that a day the
    /// projection still holds keeps the same view, the same storage and
    /// the same laid-out glyphs.
    private(set) var quietRegions: [UInt64: QuietPageView] = [:]

    /// The headers, pooled and re-used rather than re-made, the way the
    /// page's own block labels are: a header is a frame and three
    /// strings, and an assembly that discarded them all would churn a
    /// dozen views every time the card was resized.
    private var headers: [DayHeaderView] = []

    /// The empty storage a parked editor is left showing. Held here
    /// because a layout manager does not own its text storage, the
    /// ownership runs the other way, so an unheld one would be freed
    /// out from under the view still pointing at it.
    private var parkedStorage: NSTextStorage?

    private var rows: [Row] = []
    private var rendered: Signature?

    /// Extents and line marks change only during layout. Scroll
    /// notifications reuse this captured document half and publish a new
    /// viewport over it, avoiding a second layout-fragment enumeration for
    /// every clip movement.
    private let documentIdentity = UUID()
    private var measuredDocument = RollGeometry.Document.unmeasured
    private var nextDocumentRevision: UInt64 = 0

    /// How many times the rows have been assembled, for the test that
    /// asserts a second identical pass assembles nothing.
    private(set) var rebuilds = 0

    /// True while `relayout` is setting frames. Setting a frame posts a
    /// frame-change notification, and the notifications are what call
    /// `relayout`; without the gate the first region placed would start
    /// the whole pass again.
    private var isLayingOut = false

    /// Where the caret goes once the editor lands on the page a click
    /// into a quiet region promoted. The click knows the character it
    /// landed on; the swap that makes that page editable happens a
    /// SwiftUI pass later, so the answer waits here for it.
    private var pendingCaret: (page: UInt64, index: Int)?

    init(model: PageModel, coordinator: InkEditorView.Coordinator, emptyHint: String) {
        self.model = model
        self.coordinator = coordinator
        self.emptyHint = emptyHint
        super.init(frame: .zero)
        // Every child's frame is this view's to decide. Autoresizing
        // would otherwise re-widen each region by the same delta the
        // stack just grew by, on top of the width `relayout` had already
        // given it, and the roll would double its own measure the first
        // time it was put in a window.
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the roll is built in code and never unarchived")
    }

    override var isFlipped: Bool { true }

    override var needsPanelToBecomeKey: Bool { editor?.isEditable == true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The unused viewport below the pages is part of the editing area.
    /// Focusing it preserves the selected page and its insertion point.
    override func mouseDown(with event: NSEvent) {
        guard let editor = focusableEditor else {
            super.mouseDown(with: event)
            return
        }
        // Use the editor's click-versus-drag decision for the entire blank
        // viewport, including the stretch outside the text view's frame.
        editor.mouseDown(with: event)
    }

    private var focusableEditor: InkTextView? {
        guard model.owner == coordinator.surface,
              let window, let editor, editor.isEditable,
              editor.window === window else { return nil }
        return editor
    }

    @discardableResult
    func focusEditor() -> Bool {
        guard let editor = focusableEditor, let window else { return false }
        return window.makeFirstResponder(editor) && window.firstResponder === editor
    }

    // MARK: What the roll is watching

    /// The two things that change a region's height without anybody
    /// asking SwiftUI for a pass: the card resizing under the roll, and
    /// the editor growing as it is typed into.
    ///
    /// Registered by selector rather than by block, for the reason the
    /// coordinator's own clip observation gives: that registration is
    /// zeroing, so it retires with this view and needs no `deinit` to
    /// unpick it.
    func observeRoll() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surroundingsChanged),
            name: NSView.frameDidChangeNotification,
            object: clip
        )
        // And the third thing, which changes nothing about the layout
        // and everything about what the reader can see: the clip moving
        // over a document that stayed still. Nothing was watching it
        // until the rail gained a minimap with a viewport band to keep
        // honest (issue #131).
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rollScrolled),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        // A rendering dependency moved under a page whose contents did
        // not change (preview scope, syntax highlighting, typeface); the
        // model has already dropped its quiet cache, and the roll picks
        // up the change by reseeding every visible region. The mounted
        // page is restyled by the coordinator on its own published side.
        // Registered by selector so it retires with the view.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quietRenderingsInvalidated),
            name: PageModel.quietRenderingsDidInvalidateNotification,
            object: model
        )
    }

    private func observeEditor(_ editor: InkTextView) {
        editor.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surroundingsChanged),
            name: NSView.frameDidChangeNotification,
            object: editor
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surroundingsChanged),
            name: NSText.didChangeNotification,
            object: editor
        )
    }

    /// A measurement changed. Only frames move from here, nothing
    /// touches the model, because a layout pass is the one place a
    /// synchronous change to observed state would re-enter SwiftUI
    /// mid-render.
    @objc private func surroundingsChanged(_ notification: Notification) {
        relayout()
        // A roll mounted before SwiftUI sized its clip finds the place
        // a hand off left for it here, on the clip's first real frame.
        settlePendingPlace()
    }

    /// The reader moved over the roll. No frame changed, so nothing is
    /// re-measured and nothing is placed; all that moved is which part
    /// of the document the clip has open, which is half of what the
    /// minimap says.
    @objc private func rollScrolled(_ notification: Notification) {
        publishGeometry()
    }

    /// A rendering dependency moved (preview scope, syntax highlighting,
    /// typeface). Every quiet region still on screen belongs to a page
    /// whose cached rendering the model has already dropped, so a fresh
    /// call to `quietRendering(for:)` builds under the new preference
    /// and is handed back through `reseed`.
    @objc private func quietRenderingsInvalidated(_ notification: Notification) {
        refreshQuietRegions()
    }

    // MARK: The pass

    /// What SwiftUI asks for on every published change, and what the
    /// tests drive directly: here are the days, here is the one the
    /// editor belongs on, and here is whether the card will accept
    /// typing.
    func update(projection: TimeUnitProjection, selectedPage: UInt64?, readOnly: Bool) {
        // The pass builds the editor and moves it between pages, and
        // both shed the layout managers of the page they arrive on, so
        // the pass is the owner's (ADR-0033). `updateRoll` has already
        // asked. It is asked again here because this is the mount site
        // and the tests drive it directly.
        guard model.owner == coordinator.surface else { return }
        let signature = Signature(
            buckets: projection.units.map(\.bucket),
            pages: projection.units.map(\.pageIDs),
            selected: selectedPage,
            clipWidth: clipWidth
        )
        // The typeface can change under a roll that is otherwise still:
        // the editor's page is restyled here, and the quiet days follow
        // through `refreshQuietRegions`, since the model dropped their
        // renderings when the setting moved.
        coordinator.applyTypeface(model.typeface)
        coordinator.applySyntaxHighlighting(model.syntaxHighlightingEnabled)
        coordinator.applyLanguageDetection(model.languageDetectionEnabled)
        coordinator.applyPreviewRendering(model.previewRendering)
        guard signature != rendered else {
            // The ordinary pass: a keystroke, or the cosmetic redraw.
            // The countdowns in the gutters move every second and the
            // regions have to be re-measured against text that just
            // changed, but nothing is assembled.
            if let selectedPage, editor != nil, coordinator.currentSheet == nil {
                // An editor standing on no page while the roll has one
                // selected was taken off it by a transfer of ownership
                // (`Coordinator.leavePage`), and this roll outlived the
                // transfer because ownership came back before SwiftUI
                // had taken it down. Nothing about the rows moved, so
                // the editor goes back on the page it left, shut away
                // from `relayout` as the assembling pass shuts it.
                isLayingOut = true
                settleEditor(on: selectedPage)
                isLayingOut = false
            } else if let editor, coordinator.currentSheet != nil {
                coordinator.announce(editor)
            }
            refreshGutters()
            refreshQuietRegions()
            relayout()
            settlePendingPlace()
            if let editor {
                coordinator.updateEditability(of: editor, to: !readOnly)
            }
            model.scheduleEditStepsRefresh()
            return
        }
        // Building the editor gives it a frame, and a frame change is
        // one of the two things that call `relayout`. Hold the pass shut
        // until the rows it would be laying out are the new ones, and
        // shut it before the composition settles below, because settling
        // one puts characters in the editor and a text view that grows
        // posts a frame change like any other.
        isLayingOut = true
        // The page the editor is leaving has to be finished with before
        // it is drawn. A composition in flight is provisional text the
        // emission gate deliberately keeps out of the core, so a
        // rendering built for the outgoing day while it is still marked
        // would show that day without the sentence just typed into it,
        // and the swap below, which is what settles the composition,
        // happens after the rows are assembled. So settle first: the
        // assembly reads the core, and the core has to be told before it
        // is read.
        settleComposition(before: selectedPage)
        // A row appearing above the viewport must not move what the
        // reader is looking at, so where the topmost page stands is
        // remembered across the assembly and answered for afterwards.
        let anchor = topmostPageAnchor()
        rendered = signature
        assembleRows(projection: projection, selectedPage: selectedPage)
        settleEditor(on: selectedPage)
        isLayingOut = false
        if let editor {
            coordinator.updateEditability(of: editor, to: !readOnly)
        }
        model.scheduleEditStepsRefresh()
        relayout()
        keepStill(anchoredOn: anchor)
        settlePendingPlace()
    }

    /// The clip's width, which is the width every region wraps at. Zero
    /// until the roll is in a window, which is harmless: the first real
    /// width arrives as a frame change and re-measures everything.
    private var clipWidth: CGFloat {
        enclosingScrollView?.contentView.bounds.width ?? bounds.width
    }

    /// Build the rows the projection asks for, reusing every view that
    /// is still wanted and taking out only the ones that are not.
    ///
    /// The editor is never taken out. The quiet region for the page the
    /// editor is moving onto is, and it goes **before** the swap: the
    /// two of them must never be over the same page at once, even for
    /// the length of one call.
    private func assembleRows(projection: TimeUnitProjection, selectedPage: UInt64?) {
        rebuilds += 1
        var built: [Row] = []
        var wantedPages: Set<UInt64> = []
        var isFirstOnRoll = true
        var emptyToday: EmptyTodayView?
        for unit in projection.units {
            if unit.pageIDs.isEmpty {
                // Only today can be a day with no page on it: every
                // other day exists because a live page is keyed to it.
                let header = pooledHeader(at: built.count)
                header.show(
                    dayText: DayHeaderView.dayText(spokenLabel: unit.spokenLabel, stamp: nil),
                    spokenLabel: unit.spokenLabel,
                    mark: DayHeaderView.mark(isFirstOnRoll: isFirstOnRoll, isFirstOfDay: true),
                    summary: nil
                )
                // The empty place is where the surface stands only by
                // elimination: nothing else on the roll holds the
                // selection.
                header.isActive = selectedPage == nil
                let place = todayPlace ?? EmptyTodayView(model: model, hint: emptyHint)
                emptyToday = place
                built.append(Row(
                    header: header,
                    body: place,
                    bucket: unit.bucket,
                    page: nil,
                    fillsViewport: unit.bucket == projection.units.last?.bucket
                ))
                isFirstOnRoll = false
                continue
            }
            // One day's stamps are decided together, so two pages born
            // the same minute read to the second and the rail's nodes
            // say the same (`StreamNavigator.stamps`).
            let summaries = unit.tabIDs.map { summary(ofTab: $0) }
            let stamps = StreamNavigator.stamps(
                createdMs: summaries.map { $0?.pageCreatedMs }, format: model.stampFormat)
            for (index, page) in unit.pageIDs.enumerated() {
                let firstOfDay = index == 0
                let header = pooledHeader(at: built.count)
                let summary = summaries[index]
                header.show(
                    dayText: DayHeaderView.dayText(
                        spokenLabel: unit.spokenLabel, stamp: stamps[index], firstOfDay: firstOfDay
                    ),
                    spokenLabel: unit.spokenLabel,
                    mark: DayHeaderView.mark(
                        isFirstOnRoll: isFirstOnRoll && firstOfDay, isFirstOfDay: firstOfDay
                    ),
                    summary: summary
                )
                header.isActive = page == selectedPage
                wantedPages.insert(page)
                // The rendering also stands in where the builder
                // declined an editor, which `update`'s own guard keeps
                // from happening: a day with no editor on it is a quiet
                // day.
                let body: NSView = (page == selectedPage ? editorView(for: page) : nil)
                    ?? quietRegion(for: page)
                built.append(Row(
                    header: header, body: body, bucket: unit.bucket, page: page,
                    fillsViewport: false
                ))
                isFirstOnRoll = false
            }
        }

        // Out with what is no longer wanted. The quiet region for the
        // page the editor is moving onto goes with them, and it goes
        // **before** the swap: the editor and a rendering must never be
        // over one page at once, not even for the length of a call.
        for page in Array(quietRegions.keys)
        where !wantedPages.contains(page) || page == selectedPage {
            quietRegions.removeValue(forKey: page)?.removeFromSuperview()
        }
        if todayPlace !== emptyToday {
            todayPlace?.removeFromSuperview()
            todayPlace = emptyToday
        }
        // The editor is never in this loop: it is a permanent child, and
        // a day switch moves its frame rather than its parent.
        trimHeaders(to: built.count)
        for row in built {
            if row.body.superview !== self { addSubview(row.body) }
        }
        rows = built
    }

    /// Today's empty place, kept across passes for the reason the quiet
    /// regions are: it holds the focus law's catcher, and a catcher
    /// re-made under a keyed window would resign first responder every
    /// time the countdown redrew.
    private var todayPlace: EmptyTodayView?

    /// The header at this place on the roll, made once and thereafter
    /// re-used.
    private func pooledHeader(at index: Int) -> DayHeaderView {
        if index < headers.count { return headers[index] }
        let made = DayHeaderView(model: model)
        headers.append(made)
        addSubview(made)
        return made
    }

    private func trimHeaders(to count: Int) {
        while headers.count > count {
            headers.removeLast().removeFromSuperview()
        }
    }

    /// The tab summary a gutter draws from, or nil for a slot the strip
    /// no longer holds. The projection carries ids; the words belong to
    /// the summary the model already decoded.
    private func summary(ofTab id: UInt64) -> TabSummary? {
        model.tabs.first { $0.id == id }
    }

    /// The one editor, built over this page the first time the roll has
    /// a page to build it over and simply handed back every time after.
    /// Which page it is *showing* is settled by `settleEditor(on:)`
    /// after the rows are assembled, so that the region it is leaving is
    /// out of the stack before the swap happens.
    ///
    /// Nil only when the builder declined, which it does for a window
    /// that does not own the page content. `update` asks before it gets
    /// this far, so the nil is the builder's guard being honoured and
    /// never an ordinary outcome.
    private func editorView(for page: UInt64) -> InkTextView? {
        editor ?? buildEditor(on: page)
    }

    /// The rendering of a day the editor is not standing on, built once
    /// per page and kept for as long as the projection holds it, and
    /// re-read whenever the model has rebuilt it underneath.
    private func quietRegion(for page: UInt64) -> QuietPageView {
        let rendering = model.quietRendering(for: page)
        if let existing = quietRegions[page] {
            existing.reseed(with: rendering)
            return existing
        }
        let region = QuietPageView(
            page: page, rendering: rendering
        ) { [weak self] clicked, index in
            self?.promote(page: clicked, caretAt: index)
        }
        quietRegions[page] = region
        return region
    }

    /// Take every quiet day's ink again wherever the model has rebuilt
    /// it since the region was seeded.
    ///
    /// An assembly is not the only moment a day the roll is drawing can
    /// change. A chip burned out of an older page, an edit that landed
    /// through the strip while this roll was unmounted, a composition
    /// settling as the editor leaves, none of those moves a bucket, a
    /// page id or the selection, so none of them changes the signature
    /// and none of them assembles anything. This is how the roll notices
    /// them, and it is why a region's contents can be trusted without
    /// the view having to know which of those happened.
    ///
    /// It costs one dictionary lookup per visible day on a pass that is
    /// already re-reading every gutter, and it copies nothing while
    /// nothing has changed: the model hands back the very object each
    /// region was seeded from, and identity is the whole test.
    ///
    /// Every key here belongs to the projection the roll last assembled,
    /// and this runs only on a pass whose signature matched that one, so
    /// no page named here has left the projection since.
    private func refreshQuietRegions() {
        for (page, region) in quietRegions {
            region.reseed(with: model.quietRendering(for: page))
        }
    }

    /// Settle whatever the input method has provisionally placed, when
    /// the editor is about to move off the page it was placed on.
    ///
    /// `moveEditor` does this too, as its first statement, and that is
    /// the one that matters for the storage swap. This one is about the
    /// *reading*: the composition has to be in the core before the
    /// outgoing day's rendering is built out of it. A view with nothing
    /// marked is left alone, so the common pass pays a `hasMarkedText`
    /// and no more.
    private func settleComposition(before page: UInt64?) {
        guard let editor, coordinator.currentSheet != nil, coordinator.currentSheet != page
        else { return }
        InkEditorView.discardComposition(in: editor)
    }

    // MARK: The one editor

    /// Put the editor on the selected page, building it the first time
    /// and moving it every time after.
    ///
    /// Moving is `moveEditor` with no scroller: the caret belongs to the
    /// page wherever the page is mounted, and the offset belongs to the
    /// roll's one clip rather than to any page in it, so the caret leg
    /// runs and the scroll leg is skipped (ADR-0020, branch 4). What is
    /// left over is the focus law's: nothing resigned first responder,
    /// because nothing was re-parented, but the mounted editor moved and
    /// every path that moves it asks for the keys back (ADR-0005).
    private func settleEditor(on page: UInt64?) {
        guard let page else {
            parkEditor()
            return
        }
        guard let mounted = editorView(for: page) else { return }
        coordinator.announce(mounted)
        // Above the guard, because the guard is taken on the pass that
        // *builds* the editor: `makeInkTextView` sets `currentSheet`
        // itself, so a fresh mount looks to the line below like a page
        // the editor was already standing on. From here on this page can
        // change, and what it says when it goes quiet again must be read
        // after those changes rather than before them, the model drops
        // the reading at every mutation now, and this covers the moment
        // before there has been one.
        model.invalidateQuietRendering(for: page)
        guard coordinator.currentSheet != page else {
            placeCaretIfPending(on: page, in: mounted)
            return
        }
        coordinator.moveEditor(
            mounted, to: page,
            storage: model.storage(for: page), restoringScrollIn: nil
        )
        placeCaretIfPending(on: page, in: mounted)
        model.refocusEditorIfKeyed()
    }

    private func buildEditor(on page: UInt64) -> InkTextView? {
        if let editor { return editor }
        guard let built = InkEditorView.makeInkTextView(
            model: model, sheetID: page, coordinator: coordinator
        ) else { return nil }
        editor = built
        addSubview(built)
        observeEditor(built)
        // A mount with no scroller of its own has to grant what
        // `scrollStack(for:)` grants the editor's own clip. `NSTextView`
        // starts with `maxSize` at its frame (zero, for a view built
        // into nothing) and a vertically resizable view will not grow
        // past `maxSize.height`, so today's page would stop at no height
        // at all: the storage would keep taking text, the layout manager
        // would keep laying it out, and none of it past the first line
        // would be on screen. Unbounded on both axes, resizable down the
        // page and not across it, which is the same grant the page's own
        // scroller makes and the one whose absence is silent.
        built.isVerticallyResizable = true
        built.isHorizontallyResizable = false
        built.minSize = .zero
        built.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        // Wrap is forced on while the days are showing, and the stored
        // `wrapsLines` preference is left exactly where the user left
        // it: a line that ran off the side of one day would run off the
        // side of the roll, and a roll that scrolled in two directions
        // would have no honest anchor. This passes `true` rather than
        // the preference, so the setting takes effect again the moment
        // the mode goes off, and ⌥Z changes nothing here, because the
        // dispatch refuses it in this mode and says so rather than
        // writing a value this surface would not honour
        // (`PageModel.wrapIsFixedNotice`).
        coordinator.applyWrap(true)
        return built
    }

    /// No page anywhere on the roll: the last one expired, or the pad
    /// has nothing on it at all. The editor stays a child of the stack,
    /// it is never re-parented, but it stops showing anything, because
    /// a page that has expired must not still be legible in a view
    /// nobody can see the frame of.
    ///
    /// The storage it is handed is a fresh empty one rather than the
    /// dead page's, and the model's handle is dropped the way a
    /// dismantle drops it, so a hand-off arriving before the next page
    /// exists waits for that page instead of settling on a view with
    /// nothing in it.
    private func parkEditor() {
        guard let editor, coordinator.currentSheet != nil else { return }
        InkEditorView.discardComposition(in: editor)
        let outgoing = editor.textStorage
        let empty = NSTextStorage()
        parkedStorage = empty
        editor.layoutManager?.replaceTextStorage(empty)
        outgoing?.delegate = nil
        coordinator.parkEditor()
        editor.frame = .zero
        model.retireEditor(editor)
    }

    /// A click landed in a day the editor was not standing on: make that
    /// page the selected one, and remember which character was under the
    /// pointer so the caret can land there once the swap has happened.
    ///
    /// Selecting is the shipped gesture, `select(_:)` through the tab
    /// the page is standing in, so a click into history mints nothing
    /// and reaches the ledger, the focus law and the mode's own
    /// reconciliation by the roads they already run on.
    private func promote(page: UInt64, caretAt index: Int) {
        guard let tab = model.tabs.first(where: { $0.pageID == page })?.id else { return }
        pendingCaret = (page: page, index: index)
        model.select(tab)
    }

    private func placeCaretIfPending(on page: UInt64, in editor: InkTextView) {
        guard let pending = pendingCaret, pending.page == page else { return }
        pendingCaret = nil
        editor.setSelectedRange(InkEditorView.Coordinator.clamped(
            NSRange(location: pending.index, length: 0),
            to: editor.textStorage?.length ?? 0
        ))
    }

    // MARK: Measuring and placing

    /// Re-measure every region and place it. Frames only, with one
    /// deliberate exception at the end: the measurement handed to the
    /// rail's minimap, which is published on a hop rather than written
    /// here (issue #131). Nothing observable moves synchronously from
    /// this pass, which is what lets the AppKit notifications call it
    /// without re-entering a SwiftUI render.
    func relayout() {
        guard !isLayingOut, let scroll = enclosingScrollView else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let width = max(scroll.contentView.bounds.width, 0)
        let clipHeight = scroll.contentView.bounds.height
        var y: CGFloat = 0
        for row in rows {
            let headerHeight = row.header.preferredHeight
            row.header.frame = NSRect(x: 0, y: y, width: width, height: headerHeight)
            row.header.place()
            y += headerHeight
            let height: CGFloat
            if let text = row.body as? NSTextView {
                height = Self.measuredHeight(of: text, width: width)
            } else if row.fillsViewport {
                height = max(clipHeight - y, Self.minimumRegionHeight)
            } else {
                height = Self.minimumRegionHeight
            }
            row.body.frame = NSRect(x: 0, y: y, width: width, height: height)
            (row.body as? EmptyTodayView)?.place()
            y += height
        }
        // A parked editor is a child of the stack with no row of its
        // own, and a child with no row occupies nothing.
        if let editor, !rows.contains(where: { $0.body === editor }) {
            editor.frame = .zero
        }
        setFrameSize(NSSize(width: width, height: max(y, clipHeight)))
        scroll.reflectScrolledClipView(scroll.contentView)
        captureDocumentGeometry()
        publishGeometry()
    }

    // MARK: What the rail draws behind the days

    /// Where each page now stands, how its lines fall, and how much of
    /// the roll is on screen (issue #131).
    ///
    /// Read off the frames this pass just set rather than computed a
    /// second way, so the nodes on the rail and the regions under the
    /// reader's eye cannot disagree about where a page is. A row's span
    /// runs from the top of its header to the bottom of its body, the
    /// perforation included, because the tear is part of what a reader
    /// scrolls past. One extent per row, a day holding two pages
    /// measuring as two, because the navigator draws a node per page.
    ///
    /// The lines are the layout manager's own fragments, as rectangles:
    /// where each begins down the roll and what share of the wrap width
    /// it used. Geometry only. No glyph, run or string is read here,
    /// so the slivers the rail draws from them can say a page has a
    /// long line and never what the line says.
    ///
    /// Internal and readable so a test can mount the roll and ask it
    /// what it measured, without waiting on the publication's hop
    /// through the main queue.
    var measuredGeometry: RollGeometry {
        guard let scroll = enclosingScrollView else { return .unmeasured }
        let clip = scroll.contentView
        return RollGeometry(
            document: measuredDocument,
            viewportTop: clip.bounds.origin.y,
            viewportHeight: clip.bounds.height
        )
    }

    /// Capture the document half after frames and text layout have settled.
    /// Equal captures retain the revision so consumers can cache by a
    /// scalar identity rather than comparing every line mark.
    private func captureDocumentGeometry() {
        let extents = rows.map { row in
            RollGeometry.Extent(
                bucket: row.bucket,
                page: row.page,
                top: row.header.frame.minY,
                height: max(row.body.frame.maxY - row.header.frame.minY, 0),
                lines: Self.lineMarks(of: row.body as? NSTextView)
            )
        }
        guard extents != measuredDocument.extents || frame.height != measuredDocument.height else {
            return
        }
        nextDocumentRevision &+= 1
        measuredDocument = RollGeometry.Document(
            extents: extents,
            height: frame.height,
            identity: documentIdentity,
            revision: nextDocumentRevision)
    }

    /// A page's laid-out lines as rectangles in document coordinates.
    /// Empty for a row with no text view under it, and for a view whose
    /// layout has nothing in it yet.
    static func lineMarks(of text: NSTextView?) -> [RollGeometry.LineMark] {
        guard let text, let layoutManager = text.layoutManager,
              let container = text.textContainer else { return [] }
        let wrap = max(container.size.width - container.lineFragmentPadding * 2, 1)
        let origin = text.frame.minY + text.textContainerInset.height
        var marks: [RollGeometry.LineMark] = []
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            marks.append(RollGeometry.LineMark(
                y: origin + used.minY, width: min(1, max(0, used.width / wrap))
            ))
        }
        return marks
    }

    // MARK: What the rail asks of the roll

    /// Move the clip to a document offset: a node or the bare track was
    /// clicked on the rail. Clamped to the document, so a click past
    /// the last page lands on the last page rather than in the elastic.
    /// Over the stance's own 160 ms, and instantly for a reader who
    /// asked for less motion, which is the surface's one motion rule
    /// (D-02). The bounds change notifications the roll already listens
    /// to fire along the way, so the band on the rail travels with the
    /// clip rather than jumping after it. Instant as well in a window
    /// nobody can see, which is a test's, where an animation would be
    /// a frame nobody draws and a clip that has not moved yet.
    func scroll(toDocumentOffset offset: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let floor = max(frame.height - clip.bounds.height, 0)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(offset, 0), floor))
        let duration = StreamNavigator.jumpDuration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard duration > 0, window?.isVisible == true else {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak scroll] in
            MainActor.assumeIsolated {
                guard let scroll else { return }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    /// Hand the measurement to the rail. The model's own observable
    /// takes it, coalesces it and publishes it after this pass, so a
    /// layout that runs inside a SwiftUI render does not write observed
    /// state in the middle of one.
    private func publishGeometry() {
        model.rollGeometry.publish(measuredGeometry, from: self)
    }

    /// A region no shorter than one line of ink, so an empty day is
    /// still somewhere a click can land.
    static let minimumRegionHeight: CGFloat = 32

    /// How tall a region has to be to show all of its text at this
    /// width: the used rect of laid-out glyphs plus the inset above and
    /// below, which is the one measurement the page's own scroll restore
    /// already trusts. The width is handed over first, because what a
    /// paragraph is worth in height is a fact about what it wrapped at.
    static func measuredHeight(of text: NSTextView, width: CGFloat) -> CGFloat {
        guard let layoutManager = text.layoutManager,
              let container = text.textContainer else { return text.frame.height }
        if text.frame.width != width {
            text.setFrameSize(NSSize(width: width, height: max(text.frame.height, 1)))
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
            + text.textContainerInset.height * 2
        return max(used, minimumRegionHeight)
    }

    // MARK: Anchoring

    /// Day 0 is the top of the document, and a summon puts the clip back
    /// on it. Instant and unanimated: there is no anchoring state that
    /// can be wrong, and nothing to reduce for a reader who asked for
    /// less motion.
    func scrollToDayZero() {
        // A summon outranks a place still waiting to be opened on.
        pendingPlace = nil
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: The roll's place across a hand off (ADR-0033)

    /// Where the roll stands: the first page with anything below the
    /// top edge of the clip, and the line of it at that edge. Nil at
    /// Day 0, which is no place at all (`RollPlace`), and nil from a
    /// roll that is in no window, which nobody is reading.
    ///
    /// A top edge in a header, or in the empty Today above the first
    /// page, is a place above that page's first line, and the anchor
    /// says so with a negative fraction, as it does for a top inset.
    var currentPlace: RollPlace? {
        guard window != nil, let scroll = enclosingScrollView else { return nil }
        let origin = scroll.contentView.bounds.origin
        guard origin.y > 0,
              let row = rows.first(where: { $0.page != nil && $0.body.frame.maxY > origin.y }),
              let page = row.page, let text = row.body as? NSTextView,
              let anchor = ScrollAnchor(
                  topOf: text,
                  clipOrigin: NSPoint(x: origin.x, y: origin.y - text.frame.minY)
              )
        else { return nil }
        return RollPlace(page: page, anchor: anchor)
    }

    /// The place the other window's roll left, waiting for rows to find
    /// it in and a clip with a size. SwiftUI sizes a new scroller when
    /// it pleases, so the place is set down here and picked up by the
    /// first pass that can honour it, which is the page surface's rule
    /// for its own restore (`Coordinator.deferredScrollRestore`).
    private var pendingPlace: RollPlace?

    /// Open the roll on `place` once it can be found.
    func open(at place: RollPlace) {
        pendingPlace = place
    }

    /// Move the clip to the waiting place, against this roll's own
    /// layout: the other window wrapped every page above it
    /// differently, so the distance is worked out here and was never
    /// carried. Called after `relayout`, which has just forced every
    /// region's layout current. A page that died in between leaves the
    /// roll at Day 0, and so does one that is no longer a text region.
    /// Never from inside a pass, where the rows are half assembled and
    /// a frame change arrives for every region being built.
    private func settlePendingPlace() {
        guard !isLayingOut, let place = pendingPlace, !rows.isEmpty,
              let scroll = enclosingScrollView, !scroll.contentView.bounds.isEmpty
        else { return }
        pendingPlace = nil
        guard let row = rows.first(where: { $0.page == place.page }),
              let text = row.body as? NSTextView,
              let within = place.anchor.offset(in: text) else { return }
        let clip = scroll.contentView
        let floor = max(frame.height - clip.bounds.height, 0)
        let target = NSPoint(
            x: within.x, y: min(max(text.frame.minY + within.y, 0), floor)
        )
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }

    /// The topmost page on the roll and where its ink stands, taken
    /// before an assembly so the same page can be found again
    /// afterwards.
    ///
    /// The ink rather than the header above it, because a header is not
    /// a fixed height: the page that was first on the roll gains a
    /// perforation the moment a day arrives over it, and its header
    /// grows by `tearReserve` to draw one. Measured at the header's top
    /// that growth is invisible (the header moved by exactly what was
    /// inserted) and everything below it, the reader included, slides
    /// down by the twelve points nothing answered for. Measured at the
    /// ink's top the chrome that appeared counts as part of what
    /// arrived, which is what a reader experiences it as.
    private func topmostPageAnchor() -> (page: UInt64, top: CGFloat)? {
        guard let row = rows.first(where: { $0.page != nil }), let page = row.page else {
            return nil
        }
        return (page: page, top: row.body.frame.minY)
    }

    /// Local midnight, or a page minted into a day above the one being
    /// read: rows arrived over the top of the roll. Move the clip down
    /// by exactly as far as the roll's first page moved, so what the
    /// reader was looking at stays where it was.
    private func keepStill(anchoredOn anchor: (page: UInt64, top: CGFloat)?) {
        guard let anchor, let scroll = enclosingScrollView,
              let row = rows.first(where: { $0.page == anchor.page }) else { return }
        let origin = Self.offsetAfterPrepending(
            insertedHeight: row.body.frame.minY - anchor.top,
            current: scroll.contentView.bounds.origin
        )
        guard origin != scroll.contentView.bounds.origin else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Where the clip goes after rows were inserted above it.
    ///
    /// A reader scrolled into history keeps what they were reading: the
    /// offset grows by exactly the height that arrived above them, so
    /// the calendar cannot yank content out from under a sentence being
    /// read. A reader at the origin is not scrolled at all: they are
    /// looking at the top of the roll, and the top of the roll is where
    /// the new day now is, which is the whole of "Day 0 is always
    /// displayed" and the only place this rule would fight it. Pure, so
    /// both readings are testable without a window.
    nonisolated static func offsetAfterPrepending(
        insertedHeight: CGFloat, current: NSPoint
    ) -> NSPoint {
        guard insertedHeight > 0, current.y > 0 else { return current }
        return NSPoint(x: current.x, y: current.y + insertedHeight)
    }

    /// What the roll is made of, in document order: each header and the
    /// region under it. A reading seam for the tests, in the idiom
    /// `Coordinator.blockLabelLayout` set, the geometry is the claim
    /// worth asserting, and it is better asserted against the parts than
    /// against a number somebody wrote down. Nothing writes through it.
    var laidOut: [(header: DayHeaderView, body: NSView)] {
        rows.map { (header: $0.header, body: $0.body) }
    }

    // MARK: The gutters

    /// The spoken countdowns tick and the titles follow the page's
    /// first line, so every pass refreshes what the gutters say without
    /// touching what the roll is made of. `stampFormat` is one such
    /// change: a pattern edited in Settings publishes back into an
    /// unchanged projection, so the `dayText` the header prints must be
    /// re-derived here rather than only in the assembly pass, or the
    /// mounted headers keep their old stamps until the roll rebuilds
    /// for another reason (Greptile P1 #1).
    private func refreshGutters() {
        let units = model.timeUnits.units
        let unitByBucket = Dictionary(uniqueKeysWithValues: units.map { ($0.bucket, $0) })
        var stampsByBucket: [Int: [String]] = [:]
        for unit in units where !unit.pageIDs.isEmpty {
            let summaries = unit.tabIDs.map { summary(ofTab: $0) }
            stampsByBucket[unit.bucket] = StreamNavigator.stamps(
                createdMs: summaries.map { $0?.pageCreatedMs }, format: model.stampFormat
            )
        }
        for row in rows {
            let unit = unitByBucket[row.bucket]
            let spokenLabel = unit?.spokenLabel ?? ""
            let dayText: String
            let rowSummary: TabSummary?
            if let page = row.page, let unit,
               let index = unit.pageIDs.firstIndex(of: page)
            {
                let stamp = stampsByBucket[unit.bucket]?[index] ?? ""
                dayText = DayHeaderView.dayText(
                    spokenLabel: spokenLabel, stamp: stamp, firstOfDay: index == 0
                )
                rowSummary = summary(ofTab: unit.tabIDs[index])
            } else {
                dayText = DayHeaderView.dayText(spokenLabel: spokenLabel, stamp: nil)
                rowSummary = row.header.tab.flatMap { summary(ofTab: $0) }
            }
            row.header.refresh(dayText: dayText, summary: rowSummary)
        }
    }
}

// MARK: - The perforation and the page's gutter

/// The tear between two days, and the gutter of the page under it.
///
/// Chrome, entirely. The perforation is an `NSBezierPath` hairline in
/// `EmptyRule`'s dash vocabulary and the labels are plain text fields:
/// nothing here is ever inserted into a text storage, because a
/// character inserted to separate two days would cross the seam as an
/// insert op and land in a document.
///
/// It carries the four verbs the strip used to be the only route to.
/// They live on the page rather than on the rail because a day can hold
/// more than one page, and a menu that renamed "yesterday" would have to
/// pick one of them; addressed to a page's own slot they are
/// unambiguous, and the rail stays honest about being a projection you
/// cannot rename or reorder.
final class DayHeaderView: NSView {
    /// What is drawn across the top of the header.
    enum Mark: Equatable {
        /// The first header on the roll. Today is where the roll starts,
        /// so there is nothing above it to tear away from.
        case none
        /// A new day begins here: the perforation, dashed.
        case tear
        /// Another page born on the same day: a hairline, because these
        /// two are one day's worth of writing and not a jump in time.
        case hairline
    }

    private let model: PageModel
    private let dayField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    /// The retained words for a page past the window, and otherwise
    /// empty. The countdown that used to stand here became a gauge,
    /// and the gauge went too: a page's remaining life is drawn once,
    /// under the active node on the rail, since a gauge on every
    /// gutter was the same shape twenty times over and read as a
    /// texture rather than a fact. VoiceOver still hears the countdown
    /// here (`spokenHeader`).
    private let remainingField = NSTextField(labelWithString: "")
    /// Which step of the core's label resolution the title came from,
    /// as of the last refresh, which is what decides whether the title
    /// is drawn once a rename ends (`drawsTitle`).
    private var titleSource: TitleSource?

    /// What this header draws across its top. Readable so a test can
    /// ask the mounted roll where its perforations are rather than
    /// inferring them from a height.
    private(set) var mark: Mark = .none

    /// The page under this gutter is the one the surface is showing:
    /// the rule under the checkpoint's words draws in ember, and the
    /// words in ink rather than the faint label. Set by the stack on
    /// every assembly, the selection being part of what an assembly is
    /// keyed on.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            dayField.textColor = isActive ? .labelColor : .tertiaryLabelColor
            needsDisplay = true
        }
    }

    /// The slot the verbs are addressed to, or nil for the empty Today
    /// place, which has no page and therefore nothing to rename, hold,
    /// shorten or close.
    private(set) var tab: UInt64?
    private var hasPage = false
    private var paused = false
    private var toppedUp = false
    /// The page under the slot, which the sync item is addressed to:
    /// enrolment is per page (relay protocol §1), not per slot.
    private var pageID: UInt64?

    /// The title the gutter showed when a rename began, or nil while
    /// the title is a label (D-14, issue #172). Its presence is the
    /// fact of a rename in progress, which the per second pass reads
    /// so it does not write the page's first line over the draft, and
    /// its value is what a cancel puts back.
    private var titleBeforeRename: String?
    /// The slot captured when editing began. A pooled header can be
    /// reassigned while its field is active, so submission must never
    /// infer its target from the header's current `tab`.
    private var tabBeingRenamed: UInt64?
    /// Who held the keyboard when the rename began, given it back on
    /// return and on escape. On a focus loss the keyboard has already
    /// gone where the user sent it and is left there.
    private weak var responderBeforeRename: NSResponder?

    init(model: PageModel) {
        self.model = model
        super.init(frame: .zero)
        dayField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        dayField.textColor = .tertiaryLabelColor
        titleField.font = NSFont.systemFont(ofSize: 11)
        titleField.textColor = .secondaryLabelColor
        titleField.usesSingleLineMode = true
        titleField.cell?.lineBreakMode = .byTruncatingTail
        remainingField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        remainingField.textColor = .tertiaryLabelColor
        remainingField.alignment = .right
        titleField.isHidden = true
        addSubview(dayField)
        addSubview(titleField)
        addSubview(remainingField)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the roll is built in code and never unarchived")
    }

    override var isFlipped: Bool { true }

    // MARK: What a header says

    /// The checkpoint belongs to the content area. Its passive labels
    /// share the focus click; an inline rename keeps its own text input.
    override var needsPanelToBecomeKey: Bool {
        dayStack?.needsPanelToBecomeKey ?? false
    }

    private var dayStack: DayStackView? {
        var ancestor = superview
        while let view = ancestor {
            if let stack = view as? DayStackView { return stack }
            ancestor = view.superview
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === dayField || hit === remainingField
            || (hit === titleField && !titleField.isEditable) {
            return self
        }
        return hit
    }

    // Mouse hit redirection must not replace the composed spoken header
    // with an individual passive label. The editable rename field keeps
    // its own accessibility target.
    private enum AccessibilityHit: Sendable { case outside, header, rename }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let target: AccessibilityHit = MainActor.assumeIsolated {
            guard let window else { return .outside }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            guard bounds.contains(local) else { return .outside }
            if titleField.isEditable && !titleField.isHidden && titleField.frame.contains(local) {
                return .rename
            }
            return .header
        }
        switch target {
        case .header: return self
        case .rename: return titleField
        case .outside: return super.accessibilityHitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        if dayStack?.focusEditor() != true { super.mouseDown(with: event) }
    }

    /// Which mark a header draws, as a decision rather than as a
    /// drawing: the roll's first header tears from nothing, a day's
    /// first header is the perforation, and a page continuing a day is a
    /// hairline. Pure, so "a perforation sits between two days and none
    /// above the first" is an assertion.
    nonisolated static func mark(isFirstOnRoll: Bool, isFirstOfDay: Bool) -> Mark {
        if isFirstOnRoll { return .none }
        return isFirstOfDay ? .tear : .hairline
    }

    /// The checkpoint's words. A day's first gutter reads the day and
    /// the page's birth time, "2 days ago · 13:00"; the gutters under
    /// it on the same day read the time alone, "13:17", because the
    /// day was said once above them and the hairline says these are
    /// one day's pages. Saying the day on every gutter, and a date in
    /// every time, was the same fact three times over. Two pages born
    /// the same minute read to the second (`StreamNavigator.stamps`).
    /// The empty place has no time, so it says the day alone. Pure, so
    /// the shape is an assertion.
    nonisolated static func dayText(
        spokenLabel: String, stamp: String?, firstOfDay: Bool = true
    ) -> String {
        guard let stamp, !stamp.isEmpty else { return spokenLabel }
        return firstOfDay ? "\(spokenLabel) · \(stamp)" : stamp
    }

    /// Whether the gutter draws its title: only a name the user typed.
    /// A placeholder repeats the stamp beside it in the core's own
    /// shape, and a derived title repeats the page's first line, which
    /// stands directly under the gutter. Both are still spoken
    /// (`spokenHeader`), since VoiceOver reads the gutter on its own.
    /// A rename in progress shows the field whatever it holds: the
    /// draft is the thing being edited.
    nonisolated static func drawsTitle(source: TitleSource?, renaming: Bool) -> Bool {
        renaming || source == .name
    }

    /// Past the seven day window, a gutter says the page is retained
    /// where it would draw the gauge (`StreamNavigator.retainedLabel`).
    /// Pure, on the day the summary reports.
    nonisolated static func retainedText(pageDayOffset: Int?) -> String {
        guard let pageDayOffset, StreamNavigator.isTrailing(bucket: pageDayOffset) else {
            return ""
        }
        return StreamNavigator.retainedLabel
    }

    /// What VoiceOver hears at a perforation: which day it is, what the
    /// page under it is called, and how long that page has left. The
    /// rail already speaks the day; this speaks the page, which is what
    /// the rail deliberately does not carry. Pure.
    nonisolated static func spokenHeader(
        spokenLabel: String, title: String, remainingLabel: String
    ) -> String {
        guard !title.isEmpty else { return spokenLabel }
        guard !remainingLabel.isEmpty else { return "\(spokenLabel), \(title)" }
        return "\(spokenLabel), \(title), \(remainingLabel) left"
    }

    /// The height a header takes: a gutter's worth, plus room for the
    /// tear above it where one is drawn.
    static let gutterHeight: CGFloat = 20
    static let tearReserve: CGFloat = 12

    var preferredHeight: CGFloat {
        mark == .none ? Self.gutterHeight : Self.gutterHeight + Self.tearReserve
    }

    func show(dayText: String, spokenLabel: String, mark: Mark, summary: TabSummary?) {
        self.mark = mark
        self.spokenLabel = spokenLabel
        refresh(dayText: dayText, summary: summary)
    }

    private var spokenLabel = ""

    /// The words, re-read from the current summary. The countdown moves
    /// every second, the title follows the page's own first line, and
    /// the stamp beside the day follows `PageModel.stampFormat`; this
    /// runs on every pass while `show` runs only on an assembly, so a
    /// pattern edit that leaves the roll's structure alone still moves
    /// the stamp on every gutter.
    func refresh(dayText: String, summary: TabSummary?) {
        dayField.stringValue = dayText
        refresh(summary: summary)
    }

    func refresh(summary: TabSummary?) {
        if let tabBeingRenamed, tabBeingRenamed != summary?.id {
            returnKeyboard()
            endRename(committed: false)
        }
        tab = summary?.id
        hasPage = summary?.hasPage ?? false
        paused = summary?.paused ?? false
        toppedUp = summary?.holdToppedUp ?? false
        pageID = summary?.pageID
        spokenRemainingLabel = summary.map { $0.hasPage ? $0.remainingLabel : "" } ?? ""
        // Not while a draft is in the field: this pass runs every
        // second, and the title it would write is the one the rename
        // is there to replace.
        if titleBeforeRename == nil {
            titleField.stringValue = summary?.title ?? ""
        }
        titleSource = summary?.titleSource
        titleField.isHidden = !Self.drawsTitle(
            source: titleSource, renaming: titleBeforeRename != nil)
        remainingField.stringValue = Self.retainedText(pageDayOffset: summary?.pageDayOffset)
        updateAccessibilityLabel()
        needsDisplay = true
    }

    /// The countdown VoiceOver hears, kept beside the gauge that
    /// replaced it on screen: the words are what a gauge owes (D-11).
    private var spokenRemainingLabel = ""

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(Self.spokenHeader(
            spokenLabel: spokenLabel,
            title: titleField.stringValue,
            remainingLabel: remainingField.stringValue.isEmpty
                ? spokenRemainingLabel : remainingField.stringValue
        ))
    }

    /// Frame layout, called by the stack after the header's own frame is
    /// set. Auto Layout is not in play on the roll, and `layout()` alone
    /// would leave a test that never spins a run loop measuring an
    /// unplaced header.
    func place() {
        let top: CGFloat = mark == .none ? 0 : Self.tearReserve
        dayField.sizeToFit()
        remainingField.sizeToFit()
        let dayWidth = dayField.frame.width
        let remainingWidth = remainingField.frame.width
        dayField.frame = NSRect(
            x: Self.margin, y: top + 3, width: dayWidth, height: Self.gutterHeight - 6
        )
        remainingField.frame = NSRect(
            x: max(bounds.width - Self.margin - remainingWidth, 0), y: top + 3,
            width: remainingWidth, height: Self.gutterHeight - 6
        )
        let titleX = Self.margin + (dayWidth > 0 ? dayWidth + 8 : 0)
        titleField.frame = NSRect(
            x: titleX,
            y: top + 2,
            width: max(bounds.width - titleX - remainingWidth - Self.margin * 2, 0),
            height: Self.gutterHeight - 4
        )
    }

    override func layout() {
        super.layout()
        place()
    }

    private static let margin: CGFloat = 12

    // MARK: The tear

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isActive {
            // The rule under the page the surface is showing: ember,
            // 1.5 points, one of the three things the rail spends ember
            // on (with the active node and the band's bar), and paired
            // with the words above it drawn in ink rather than faint,
            // so the colour is never the only carrier (D-03).
            let rule = NSBezierPath()
            let y = bounds.height - 0.75
            rule.move(to: NSPoint(x: Self.margin, y: y))
            rule.line(to: NSPoint(x: max(bounds.width - Self.margin, Self.margin), y: y))
            rule.lineWidth = 1.5
            NSColor.ember.setStroke()
            rule.stroke()
        }
        guard mark != .none else { return }
        let y = (Self.tearReserve / 2).rounded() + 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: Self.margin, y: y))
        path.line(to: NSPoint(x: max(bounds.width - Self.margin, Self.margin), y: y))
        path.lineWidth = 1
        switch mark {
        case .tear:
            // The dashed language `EmptyRule` speaks on the strip, which
            // is what a reader of this app already reads as "a place
            // where something is not".
            var pattern: [CGFloat] = [2, 3]
            path.setLineDash(&pattern, count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        case .hairline:
            // One day's second page: a join, not a jump.
            NSColor.quaternaryLabelColor.setStroke()
        case .none:
            return
        }
        path.stroke()
    }

    // MARK: The page's verbs

    /// Rename, hold, rung, sync and close, addressed to this page's own
    /// slot: the strip's context menu, verb for verb (D-13), on the page
    /// rather than on the rail. The words differ where the object does:
    /// on the strip a slot is a tab, on the roll it is a page under a
    /// day, so the two items that name the object say "page" here.
    /// Built per click so each item says what the next press of it will
    /// actually do.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard tab != nil else { return nil }
        let menu = NSMenu()
        // The items say for themselves what they will do; letting AppKit
        // decide would send it looking for a validator this view does
        // not have, and the hold item's own refusal would go with it.
        menu.autoenablesItems = false
        menu.addItem(item(title: "Rename page…", action: #selector(renameTab)))
        let hold = item(
            title: SheetTab.holdMenuTitle(paused: paused, toppedUp: toppedUp),
            action: #selector(holdClock)
        )
        // Disabled rather than hidden on a slot with no page, exactly as
        // the strip's menu does it: the item keeps its place in a shape
        // the user knows, and it would otherwise offer a gesture the
        // core refuses, there being no clock.
        hold.isEnabled = hasPage
        menu.addItem(hold)
        menu.addItem(item(
            title: SheetTab.rungMenuTitle(hasPage: hasPage), action: #selector(shortenRung)
        ))
        // Present only while the sync switch is on, exactly as on the
        // strip: with it off the menu is yesterday's menu, which is the
        // indistinguishability issue #102 promises. Per page, because
        // enrolment is (relay protocol §1), so an empty slot offers it
        // no more than the strip does.
        if model.sync.enabled, let pageID {
            menu.addItem(item(
                title: SheetTab.syncMenuTitle(enrolled: model.sync.isEnrolled(pageID)),
                action: #selector(toggleSync)
            ))
        }
        menu.addItem(item(title: "Close page", action: #selector(closeTab)))
        return menu
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func renameTab() {
        beginRename()
    }

    // MARK: The rename, in place

    /// The title becomes a field where it stands (D-14, issue #172): a
    /// rename is not destructive and has no claim on an interrupting
    /// question, so the gutter's own label takes the keyboard, with
    /// the whole title selected, and gives it back when the draft is
    /// committed or let go of. The label is a text field already; what
    /// changes is that it may be edited, and who holds the keyboard.
    ///
    /// Internal, with `endRename` and `renameDraft`, so the roll's
    /// tests can drive a rename without a window's field editor and
    /// pin that no modal session is entered on the way.
    func beginRename() {
        guard let tab, titleBeforeRename == nil else { return }
        titleBeforeRename = titleField.stringValue
        tabBeingRenamed = tab
        responderBeforeRename = window?.firstResponder
        // A placeholder or a first line is not drawn as a label, but
        // it is the draft a rename starts from, so the field shows for
        // the rename's length.
        titleField.isHidden = false
        titleField.delegate = self
        titleField.isSelectable = true
        titleField.isEditable = true
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Whether the title field is drawn, readable so the roll's tests
    /// can pin what a gutter shows without a window.
    var titleIsDrawn: Bool { !titleField.isHidden }

    /// The day text as the gutter is drawing it, readable so a test
    /// can pin what the header shows across a stamp-format edit.
    var dayText: String { dayField.stringValue }

    /// The draft as the field holds it, readable and settable so a test
    /// can stand in for the keyboard.
    var renameDraft: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            updateAccessibilityLabel()
        }
    }

    /// Ends the rename one way or the other, deciding through
    /// `TabRename` what the ending means. The label goes back to being
    /// a label; on a keep the title it showed is restored, and on a
    /// rename the model's next pass writes the name it settled on. The
    /// keyboard is not moved here: the endings that give it back do so
    /// themselves, and a focus loss has already moved it.
    func endRename(committed: Bool) {
        guard let current = titleBeforeRename else { return }
        let targetTab = tabBeingRenamed
        titleBeforeRename = nil
        tabBeingRenamed = nil
        titleField.delegate = nil
        titleField.isEditable = false
        titleField.isSelectable = false
        switch TabRename.outcome(draft: titleField.stringValue, current: current, committed: committed) {
        case .rename(let name):
            guard let targetTab else { return }
            // The field stays up: the name it now holds is a typed
            // one, and the model's next pass confirms it as such.
            model.renameTab(targetTab, to: name)
        case .keep:
            titleField.stringValue = current
            titleField.isHidden = !Self.drawsTitle(source: titleSource, renaming: false)
        }
        updateAccessibilityLabel()
        needsDisplay = true
    }

    /// The keyboard back to whoever held it before the rename, or to
    /// nobody when that responder is gone or refuses. Moving it ends
    /// the field's editing, which is how escape reaches `endRename`.
    private func returnKeyboard() {
        guard let window else { return }
        let previous = responderBeforeRename
        responderBeforeRename = nil
        if !window.makeFirstResponder(previous) {
            window.makeFirstResponder(nil)
        }
    }

    @objc private func holdClock() {
        guard let tab else { return }
        model.pause(tab)
    }

    @objc private func shortenRung() {
        guard let tab else { return }
        model.cycleRung(tab)
    }

    @objc private func toggleSync() {
        guard let pageID else { return }
        model.sync.enrol(page: pageID, on: !model.sync.isEnrolled(pageID))
    }

    @objc private func closeTab() {
        guard let tab else { return }
        model.close(tab)
    }
}

/// How the field's endings reach the header. Return ends editing with
/// its movement named, and so does a click elsewhere, which is the
/// focus loss; escape never ends editing by itself in a field editor,
/// so it is caught as the command it is and the keyboard is moved,
/// which ends the editing the ordinary way.
extension DayHeaderView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateAccessibilityLabel()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        returnKeyboard()
        // Without a window nothing ended the editing, so end it here.
        endRename(committed: false)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?["NSTextMovement"] as? Int)
            .flatMap(NSTextMovement.init(rawValue:))
        let committed = movement == .return
        endRename(committed: committed)
        if committed { returnKeyboard() }
    }
}

// MARK: - A day the editor is not standing on

/// One older day, rendered and inert.
///
/// Its own layout manager over its **own** `NSTextStorage`, seeded from
/// the model's rendering of that page and watched by no delegate, so
/// nothing it holds can emit an op and nothing about it enters
/// `PageModel.storages` or `shedLayoutManagers`. It is
/// not editable, not selectable, and it refuses to become first
/// responder: there is one focusable text view in the card and it is the
/// editor.
///
/// A click here is the whole of its interaction, and it does what
/// clicking into history should do: promotes this page to the selected
/// one and puts the caret where the pointer was. Everything else a
/// reader might want of a quiet day (select, copy out, work a chip,
/// conceal) arrives with the editor, one click later.
final class QuietPageView: NSTextView {
    let page: UInt64
    private let onClick: (UInt64, Int) -> Void

    /// This region's own storage, held because nothing else would.
    /// Ownership in a TextKit 1 network runs storage → layout manager →
    /// container → view, and the back references are unowned, so a
    /// storage nobody keeps is freed out from under the view still
    /// laying it out. The editor's own storages are kept by the model;
    /// a quiet day's is kept here, which is the same fact from the other
    /// end: it is this view's and the model never learns of it.
    private let storage: NSTextStorage

    /// The model's rendering this region was last seeded from, kept so
    /// that "has this day changed since?" is an identity comparison
    /// rather than a walk over two attributed strings.
    ///
    /// A second hold on the payload, and deliberately not a widening
    /// of it: the storage below already carries the same ink for exactly
    /// as long as this view lives, so what this keeps alive is the wrapper
    /// whose identity is the cache-hit signal. It is dropped the moment
    /// the day is re-read.
    private var seeded: PageModel.QuietRendering

    init(
        page: UInt64,
        rendering: PageModel.QuietRendering,
        onClick: @escaping (UInt64, Int) -> Void
    ) {
        self.page = page
        self.onClick = onClick
        self.seeded = rendering
        let storage = NSTextStorage()
        storage.setAttributedString(rendering.text)
        self.storage = storage
        // The same layout manager the editor uses, seeded with the
        // payload's fence regions (ADR-0030): fence wash is part of the
        // preview contract, and painting it here rather than in the
        // storage means quiet regions render the slab as one rectangle,
        // exactly as the mounted page does.
        let layoutManager = InkLayoutManager()
        layoutManager.fenceRegions = rendering.fenceRegions
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        // The editor's own inset and base font, so a day does not shift
        // sideways or change size the moment it becomes the page being
        // written on. The inset is the ordinary top inset alone: quiet
        // pages carry no block labels (ADR-0030), so the label-reserve
        // gap the editor adds above its first line is deliberately absent
        // here.
        textContainerInset = NSSize(width: 12, height: InkEditorView.Coordinator.topInset)
        font = InkStyle.baseFont
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the roll's quiet days are never unarchived")
    }

    /// Take the day's ink again, because the model has rebuilt it.
    ///
    /// A quiet day can change without the editor ever standing on it: a
    /// chip burned out of it, an edit that reached it through the strip,
    /// a composition settling as the editor left. The model drops its
    /// reading at each of those, so the object it hands back afterwards
    /// is a different one, and that, rather than a comparison of the
    /// text, is the signal. An unchanged day hands back the very string
    /// this was seeded from and nothing is copied at all.
    ///
    /// The storage is re-filled rather than the view re-made: a region
    /// rebuilt under the roll would take its layout, its measured height
    /// and its place in the stack down with it, for a day whose only
    /// news is a word.
    func reseed(with rendering: PageModel.QuietRendering) {
        guard rendering !== seeded else { return }
        seeded = rendering
        storage.setAttributedString(rendering.text)
        if let manager = layoutManager as? InkLayoutManager {
            manager.fenceRegions = rendering.fenceRegions
            needsDisplay = true
        }
    }

    /// One focusable text view in the card, always. The editor is it.
    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool { false }

    /// A click here means "take me to this day", which is a deliberate
    /// act on a surface that may not hold the keyboard yet, so it must
    /// not be spent keying the window (the empty state's catcher answers
    /// the same way for the same reason).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        clicked(at: convert(event.locationInWindow, from: nil))
    }

    /// The click itself, in this region's own coordinates, apart from
    /// the event that carried it, so what a click on a day does can be
    /// asserted without a synthesized `NSEvent`, which is a fact about
    /// AppKit rather than about this surface.
    func clicked(at point: NSPoint) {
        onClick(page, characterIndexForInsertion(at: point))
    }
}

// MARK: - Today, with nothing on it yet

/// Day 0 as a place rather than as a page (ADR-0017): the shipped empty
/// state, mounted inside the roll.
///
/// The same two lines of copy the strip's surface shows, over the same
/// `KeyGrantingClickView`, the focus law's third and fourth grants
/// (ADR-0005), so a click into the emptiness conjures today's page and
/// hands its editor the keyboard, and Return does the same while the
/// card already holds the keys. Displayed is not minted: drawing this
/// costs nothing, where minting it would start a countdown nobody asked
/// for.
final class EmptyTodayView: NSView {
    /// The focus law's catcher, kept reachable so a test can take the
    /// grant a click would take without synthesizing the click.
    let grant = KeyGrantingClickView(frame: .zero)
    let lead = NSTextField(labelWithString: "No page here yet.")
    let hint: NSTextField

    init(model: PageModel, hint: String) {
        self.hint = NSTextField(labelWithString: hint)
        super.init(frame: .zero)
        lead.font = NSFont.preferredFont(forTextStyle: .callout)
        lead.textColor = .secondaryLabelColor
        lead.alignment = .center
        self.hint.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        self.hint.textColor = .tertiaryLabelColor
        self.hint.alignment = .center
        addSubview(lead)
        addSubview(self.hint)
        // The grant goes on last so the clicks are its, and it draws
        // nothing, so the copy underneath it still reads. The model's
        // fact is read live rather than cached, for the reason
        // `KeyGrantingClickView` gives: a page opened this instant fills
        // the selected slot before any pass could push a fresh snapshot.
        grant.selectedTabHoldsNoPage = { [weak model] in
            model?.selectedTabHoldsNoPage ?? true
        }
        // `startToday()` rather than `createPageAndFocus(in:)`, which is
        // what the strip's own empty state calls. The two agree on the
        // cases the strip can be in (no tabs at all, or a selected slot
        // holding nothing) and disagree on the one only the roll has:
        // this region can be on screen while the editor is standing on
        // an older day, and there `createPageAndFocus` would find the
        // selected slot peopled and quietly do nothing at all. Today's
        // place has to make today's page. It is still the shipped
        // gesture and it still cannot mint twice: a second click finds
        // today holding a page and selects it (ADR-0017). Not
        // `openToday()`, which is ⌘N's and mints another page on
        // today's when asked again (issue #158): a place is not an ask.
        grant.onCreate = { [weak model] window in
            model?.startToday()
            model?.focusEditorWhenMounted(in: window)
        }
        grant.onEscape = { [weak model] in model?.escape() }
        addSubview(grant)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the roll is built in code and never unarchived")
    }

    override var isFlipped: Bool { true }

    /// Frame layout, called by the stack once this region's own frame is
    /// known, for `DayHeaderView.place`'s reason.
    func place() {
        grant.frame = bounds
        lead.sizeToFit()
        hint.sizeToFit()
        let block = lead.frame.height + 6 + hint.frame.height
        let top = max((bounds.height - block) / 2, 8)
        lead.frame = NSRect(
            x: 0, y: top, width: bounds.width, height: lead.frame.height
        )
        hint.frame = NSRect(
            x: 0, y: top + lead.frame.height + 6, width: bounds.width, height: hint.frame.height
        )
    }

    override func layout() {
        super.layout()
        place()
    }
}
