import AppKit
import CompanionKit
import SwiftUI

/// The surface's face: a card of pages over the desktop, dimmed to a
/// glance while resting and a plain editor while raised. The ember
/// border shows exactly while the surface holds the keyboard, the same
/// visual law as the panel.
///
/// What the card *contains* is the shared surface (`PageSurface.swift`
/// in CompanionKit): the same content area, status lines, countdown and
/// tab strip the panel window shows. What is here is the card itself:
/// where it sits, how it is sized, and how the two stances look.
struct BackdropRootView: View {
    @ObservedObject var model: BackdropModel

    /// The shared model, observed directly: the card's own chrome reads
    /// the selected page and its clock, so this view must redraw when
    /// they change and not only when the stance does.
    @ObservedObject var pages: PageModel

    /// The sync controller, observed on its own account: it is a
    /// nested `ObservableObject`, and a nested object's changes do not
    /// republish through the model that holds it, so the header's sync
    /// word would otherwise stand at whatever it read first.
    @ObservedObject var sync: SyncController

    init(model: BackdropModel) {
        self.model = model
        pages = model.pages
        sync = model.pages.sync
    }

    /// Where the pointer was when the manipulation in flight began, in
    /// AppKit's screen coordinates. Nil except while the mouse is down;
    /// its presence is what tells `onEnded` there is a real gesture to
    /// commit rather than one a mid-drag rest already voided.
    @State private var gestureAnchor: CGPoint?

    private var raised: Bool { model.stance == .raised }

    var body: some View {
        let placed = model.displayedGeometry
        // While the window hugs the card (a pinned rest, and every
        // raise), the window's own frame carries the card's place on
        // screen; drawing the card at its pane offset too would push it
        // out of its own window.
        let hugging = !model.stance.spansPane(pinned: model.pinned)
        ZStack(alignment: .topLeading) {
            card
                .frame(width: placed.width, height: placed.height)
                .offset(
                    x: hugging ? 0 : placed.origin.x,
                    y: hugging ? 0 : placed.origin.y
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The keyboard map is mounted only while raised: a resting
        // surface refuses key status outright, so a map it carried
        // could never fire, and not carrying one says so structurally.
        .background(raised ? PageKeyboardMap(model: pages) : nil)
        .onChange(of: model.stance) { _ in
            // A rest mid-drag (Esc works while the mouse is down)
            // cancels the gesture without an `onEnded`; discard the
            // in-flight proposal so the card does not stick askew.
            gestureAnchor = nil
            model.discardProposal()
        }
    }

    /// How far the pointer has travelled since the manipulation began,
    /// in the pane's own top-leading coordinates.
    ///
    /// Measured against the screen, not against a SwiftUI coordinate
    /// space. Every space available here (the view's own, the
    /// window's, `.global`) now travels with the card, because the
    /// raised window *is* the card: a translation read in a moving
    /// space re-subtracts each delta already applied, and the card
    /// falls to half the pointer's speed or stalls outright. The
    /// screen is the one frame of reference that holds still. AppKit's
    /// y grows upward and the pane's grows downward, hence the flip.
    private func paneTranslation(from anchor: CGPoint) -> CGSize {
        let mouse = NSEvent.mouseLocation
        return CGSize(width: mouse.x - anchor.x, height: anchor.y - mouse.y)
    }

    /// The manipulation's anchor in screen coordinates, seeded on the
    /// first change of a gesture and held for the rest of it.
    ///
    /// The seed backs the gesture's own translation out of the current
    /// pointer position, recovering the exact point the mouse went
    /// down: on the first change the card has not moved yet, so
    /// SwiftUI's local measure is still trustworthy, and using it
    /// keeps the card from lagging the pointer by the two points the
    /// gesture spent activating. Every change after that is measured
    /// from the screen, because by then the window is travelling with
    /// the pointer. SwiftUI's y grows downward, AppKit's upward.
    private func anchor(seededBy translation: CGSize) -> CGPoint {
        if let gestureAnchor { return gestureAnchor }
        let mouse = NSEvent.mouseLocation
        let seed = CGPoint(x: mouse.x - translation.width, y: mouse.y + translation.height)
        gestureAnchor = seed
        return seed
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 32)
            Divider()
            // Two content rows, written out rather than one row with a
            // rail wrapped around it (issue #79). The mode's branch is
            // the whole expression, so the off-path tree below is the
            // tree the card has always built, character for character:
            // "pixel-identical while the toggle is off" is then a fact
            // about the source rather than a hope about layout. The
            // cost is that flipping the mode is an identity change and
            // remounts the editor, which is what a deliberate flip
            // should cost and what a keystroke must never.
            if pages.showsTimeUnits {
                HStack(spacing: 0) {
                    // The rail eats into the page's column, not into
                    // the header, so `BackdropGeometry.minWidth` and
                    // its clamp are untouched by the mode.
                    TimeRailView(model: pages)
                        .opacity(raised ? 1 : 0.72)
                    Divider()
                    PageContentView(model: pages, readOnly: !raised, emptyHint: emptyHint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(raised ? 1 : 0.72)
                }
            } else {
                PageContentView(model: pages, readOnly: !raised, emptyHint: emptyHint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The glance is the same ink at the same measure,
                    // dimmed. Raising and lowering must not make the
                    // text jump, so only the opacity changes.
                    .opacity(raised ? 1 : 0.72)
            }
            PageStatusStack(model: pages)
            // The two are exclusive: the days are the tabs while the
            // mode is on, and a strip underneath them would be the same
            // slots counted a second way. The strip's own verbs go with
            // it for now, and Settings is how they come back.
            if !pages.showsTimeUnits {
                Divider()
                TabStripView(model: pages)
                    .opacity(raised ? 1 : 0.72)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            // The ember border shows exactly while the surface holds
            // the keyboard — raised and keyed are distinct facts (a
            // card the user ⌘Tabbed away from is raised, unkeyed, and
            // unlit). Visible state, never colour alone; the caret and
            // focus ring agree.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.ember.opacity(pages.holdsKeys ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // A file dropped on the card opens as a file, and anything else
        // is refused in words (ADR-0028). It rides the whole card
        // rather than the editor, so the gesture works over the tabs
        // and the header too, and it is mounted whatever the stance:
        // dropping a file onto a resting card is a deliberate act like
        // any other summon.
        //
        // `dropDestination` rather than `onDrop`: it hands back URLs,
        // which are values that cross an actor boundary safely, where
        // the older call hands back item providers, which are not.
        .dropDestination(for: URL.self) { urls, _ in openDropped(urls) }
        .overlay {
            // The resize affordances exist only while raised. The
            // resting glance keeps its chrome-free face, and by the
            // stance invariant it could not take the drag anyway: the
            // resting window either ignores the mouse (unpinned) or
            // gives every click one meaning (pinned, below).
            if raised {
                resizeFrame
            }
        }
        .overlay {
            // A pinned rest takes the mouse (its window would otherwise
            // let clicks fall into whatever it covers), and this shield
            // gives the whole card a single meaning for them: a click
            // raises, the same deliberate act as any other summon. It
            // sits above every control, so a resting countdown button
            // or pin cannot be worked without raising first. On the
            // unpinned rest it is mounted but unreachable; the window
            // itself ignores the mouse.
            if !raised {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.raise(.summon) }
                    .help("Click to raise the card")
            }
        }
    }

    /// The empty state names the gesture that actually conjures a page
    /// on this surface. A resting card cannot be typed into, so it
    /// points at the summon that would change that; the pinned rest is
    /// clickable, so its hint says so.
    private var emptyHint: String {
        if raised { return "click, ⌃⌥Space, or ↩ for a page" }
        return model.pinned
            ? "click or ⌃⌥Space raises the surface"
            : "⌃⌥Space raises the surface"
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The ember dot is hidden (issue #78): the name alone says
            // whose card this is, and the dot spent its colour on
            // nothing in particular. The header's drag and its
            // double-click zoom are untouched, since both ride the
            // HStack rather than the dot.
            if HiddenUI.showsHeaderDot {
                Circle().fill(Color.ember).frame(width: 6, height: 6)
            }
            if let file = pages.activeFile, !pages.showingLedger {
                // A file showing puts its own identity where the
                // product name stands, because on a file surface the
                // question the header answers is which file this is and
                // whether it is on disk (ADR-0028).
                fileIdentity(FileHeaderState.derive(from: file))
            } else {
                Text(pages.showingLedger ? "the ledger" : BackdropAppDelegate.productName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            // Standing indicator while the capture opt-out is on.
            // Doubly load-bearing here: the backdrop is on screen for
            // every screenshot and screen share, so "the exclusion is
            // off right now" is worth saying out loud. It matters more
            // in a release build launched with the variable than in a
            // debug one, so it is not compiled out.
            if pages.allowCapture {
                Image(systemName: "camera.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.ember)
                    .help("Capture exclusion is OFF: this surface shows up in screenshots and screen sharing")
                    .accessibilityLabel(Text("Screenshots allowed"))
            }
            // Whether the session's edits are on disk (issue #49):
            // quiet words in the header rather than a symbol, since the
            // difference between saving, saved and failed is exactly
            // what a glyph would blur. Nothing shows before the first
            // owed write; a withheld licence shows its own standing
            // state instead, because "saved" would then describe the
            // ledger leg while the pages go nowhere.
            saveIndicator
            // And whether the session's edits are reaching the user's
            // other devices (issue #102), in the same shape and beside
            // the same word: one lower-case word, absent while sync is
            // off, quiet when the channel is well, ember when it needs
            // acting on. The gate the core reports chooses it; nothing
            // here infers a state of its own.
            syncIndicator
            // A countdown belongs to a page, so a slot holding none
            // shows no label: there is nothing counting down, and the
            // rung it keeps for its next page is not a deadline
            // (ADR-0017).
            // A file has no countdown to show and no rung to cycle, so
            // the control goes away with the page rather than standing
            // there inert (ADR-0028).
            if let tab = pages.selectedTab, tab.hasPage, !pages.showingLedger,
                pages.selectedFile == nil
            {
                CountdownButton(sheet: tab) { pages.cycleRung(tab.id) }
            }
            pinToggle
        }
        // The header doubles as the card's handle while raised. The
        // gesture rides the header itself, above the pane's tap
        // catcher, so a drag can never fall through and read as a
        // click-outside rest; the countdown button, being a child,
        // still wins a plain click. While resting the mask yields the
        // gesture to subviews, which leaves the handle inert (and any
        // resting click stops at the raise shield anyway).
        .contentShape(Rectangle())
        .gesture(dragGesture, including: raised ? .all : .subviews)
        // A window zooms on a title-bar double-click; the header is
        // where this card's title bar would be.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { if raised { model.toggleZoom() } }
        )
    }

    /// Open every dropped file the pad opens, and say so about each one
    /// it does not.
    ///
    /// Each item is answered on its own, so a drop of a README beside
    /// a screenshot opens the README and refuses the screenshot rather
    /// than refusing both. The refusal names the item, because a person
    /// who dropped several needs to know which one was not taken.
    ///
    /// It answers true whenever anything was dropped, refusals
    /// included: a refusal the pad said out loud is a drop it handled,
    /// and answering false would give the item back to whatever is
    /// underneath the card.
    private func openDropped(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        for url in urls {
            if FileDropDecision.opens(url) {
                pages.openFile(at: url)
            } else {
                pages.refuseUnsupportedDrop(name: url.lastPathComponent)
            }
        }
        return true
    }

    /// The header while a file is showing: its name, then whether it is
    /// on disk, then the two quiet facts beside them (ADR-0028).
    ///
    /// The words come from `FileHeaderState`, which decides them as a
    /// pure function of the file, so what the header says is testable
    /// without a card. What is here is only the drawing.
    ///
    /// The dot is drawn beside the word and never instead of it. A
    /// person who cannot tell ember from grey reads "unsaved" either
    /// way, which is the commitment in doc 05 held at the one place a
    /// colour was tempting.
    @ViewBuilder
    private func fileIdentity(_ state: FileHeaderState) -> some View {
        HStack(spacing: 6) {
            Text(state.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 3) {
                if state.showsUnsavedDot {
                    Circle().fill(Color.ember).frame(width: 5, height: 5)
                }
                Text(state.saveWord)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(state.showsUnsavedDot ? Color.ember : Color.secondary)
            }
            if let stamp = state.lastEditStamp {
                // The draft's age, on a file whose buffer came back
                // from the drafts file rather than from disk. It is the
                // whole of what the app owes for quitting without a
                // save sheet: a person can see how old the typing is
                // before pressing the save chord.
                Text(stamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(state.encodingAndFormat)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.spoken))
    }

    /// The header's persistence word. Ember for the two states that
    /// need acting on, quiet secondary text for the two that do not,
    /// and absent entirely until a write is owed, matching the
    /// surface's rule that a line appears only when it has something
    /// to say.
    @ViewBuilder
    private var saveIndicator: some View {
        if pages.activeFile != nil, !pages.showingLedger {
            // The file surface has its own saved word, about the file
            // on disk. The sealed state's word is about the pages
            // behind, and two words reading "saved" a few points apart
            // would be one word too many for a person to tell apart.
            EmptyView()
        } else if pages.contentRestoreRefused {
            Text("not saving")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.ember)
                .help("The existing state file would not open, so this session is not being saved. The page shows the recovery.")
                .accessibilityLabel(Text("This session is not being saved"))
        } else {
            switch pages.saveStatus {
            case .idle:
                EmptyView()
            case .saving:
                Text("saving")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Edits are waiting on the deferred write")
                    .accessibilityLabel(Text("Saving"))
            case .saved:
                Text("saved")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("The sealed state file matches this session")
                    .accessibilityLabel(Text("Saved"))
            case .failed:
                Text("save failed")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.ember)
                    .help("The last write was refused; the app keeps retrying. Quitting now will warn before any loss.")
                    .accessibilityLabel(Text("Save failed, retrying"))
            }
        }
    }

    /// The header's sync word. Nothing at all while sync is off, which
    /// is the first acceptance criterion of issue #102 held in the one
    /// place a user would notice it missing.
    @ViewBuilder
    private var syncIndicator: some View {
        if let word = sync.headerWord {
            Text(word.text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(tone(word.tone))
                .help(word.help)
                .accessibilityLabel(Text(word.spoken))
        }
    }

    private func tone(_ tone: SyncHeaderWord.Tone) -> AnyShapeStyle {
        switch tone {
        case .quiet: return AnyShapeStyle(.tertiary)
        case .plain: return AnyShapeStyle(.secondary)
        case .loud: return AnyShapeStyle(Color.ember)
        }
    }

    /// The resting altitude, as a real `Toggle` so VoiceOver announces
    /// a switch with on and off state (the panel's pin, ported).
    /// Pinned, the card rests floating above other windows, readable
    /// beside whatever the user is writing; a click on that resting
    /// card raises it (the shield overlay above every control), so the
    /// toggle itself is workable only while raised. The glyph shows in
    /// both stances: a floating rest should say why it floats.
    private var pinToggle: some View {
        Toggle(isOn: $model.pinned) {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(model.pinned
            ? "Rests above other windows; click to send the card back to the desktop"
            : "Rests at the desktop; click to keep the card above other windows")
        .accessibilityLabel(Text("Keep resting card above other windows"))
    }

    /// The header drag: live proposals while the mouse is down, one
    /// committed origin when it settles. The model clamps and
    /// persists; the view only proposes. The minimum distance keeps a
    /// plain click on the header from registering as a zero-length
    /// drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard raised else { return }
                let anchor = anchor(seededBy: value.translation)
                model.proposeGeometry(dragged(by: paneTranslation(from: anchor)))
            }
            .onEnded { _ in
                let started = gestureAnchor
                gestureAnchor = nil
                // A rest mid-drag (Esc) cancels the manipulation, but
                // the window that captured the mouse-down still gets
                // the mouse-up; the abandoned proposal must not land.
                guard raised, let started else {
                    model.discardProposal()
                    return
                }
                model.endZoom()
                model.setGeometry(dragged(by: paneTranslation(from: started)))
            }
    }

    /// The settled geometry moved by a pane translation.
    private func dragged(by translation: CGSize) -> BackdropGeometry {
        var proposed = model.geometry
        proposed.origin.x += translation.width
        proposed.origin.y += translation.height
        return proposed
    }

    // MARK: Resizing

    /// The card's eight grips, laid over its own edges and corners the
    /// way a window's resize margins lie over its frame. A window can
    /// be pulled from any side; a card being sized like a window should
    /// answer the same reach, rather than hiding the whole verb behind
    /// one corner glyph.
    private var resizeFrame: some View {
        ZStack {
            VStack(spacing: 0) {
                grip(.top).frame(maxWidth: .infinity, maxHeight: Self.gripThickness)
                Spacer(minLength: 0)
                grip(.bottom).frame(maxWidth: .infinity, maxHeight: Self.gripThickness)
            }
            HStack(spacing: 0) {
                grip(.leading).frame(maxWidth: Self.gripThickness, maxHeight: .infinity)
                Spacer(minLength: 0)
                grip(.trailing).frame(maxWidth: Self.gripThickness, maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    corner(.topLeading)
                    Spacer(minLength: 0)
                    corner(.topTrailing)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    corner(.bottomLeading)
                    Spacer(minLength: 0)
                    corner(.bottomTrailing)
                }
            }
            // The bottom-trailing corner keeps a visible glyph: the
            // other seven grips are invisible margins, as a window's
            // are, and one drawn affordance is what tells a first-time
            // user the card is resizable at all.
            //
            // Hidden for now (issue #78). Only the drawing goes: the
            // glyph never took a click (`allowsHitTesting(false)`), so
            // all eight grips and the corner under this one still
            // resize the card exactly as before.
            if HiddenUI.showsResizeGlyph {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private static let gripThickness: CGFloat = 6
    private static let cornerSide: CGFloat = 12

    private func grip(_ edge: CardEdge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(resizeGesture(edge))
    }

    private func corner(_ edge: CardEdge) -> some View {
        Color.clear
            .frame(width: Self.cornerSide, height: Self.cornerSide)
            .contentShape(Rectangle())
            .gesture(resizeGesture(edge))
    }

    /// One resize drag, per edge: the pure `CardEdge` decision turns the
    /// pull into a proposal, and the commit goes through the model's
    /// clamp like every other proposal.
    private func resizeGesture(_ edge: CardEdge) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard raised else { return }
                let anchor = anchor(seededBy: value.translation)
                model.proposeGeometry(
                    edge.resized(model.geometry, by: paneTranslation(from: anchor))
                )
            }
            .onEnded { _ in
                let started = gestureAnchor
                gestureAnchor = nil
                // Same cancellation rule as the header drag: a rest
                // mid-gesture voids the proposal.
                guard raised, let started else {
                    model.discardProposal()
                    return
                }
                model.endZoom()
                model.setGeometry(
                    edge.resized(model.geometry, by: paneTranslation(from: started))
                )
            }
    }
}
