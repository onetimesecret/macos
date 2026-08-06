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

    init(model: BackdropModel) {
        self.model = model
        pages = model.pages
    }

    /// Live translation of a header drag, in points. Zero except while
    /// a drag is in flight; the settled position lives in the model.
    @State private var dragTranslation: CGSize = .zero

    /// The edge being pulled and how far, while a resize is in flight.
    @State private var resizingEdge: CardEdge?
    @State private var resizeTranslation: CGSize = .zero

    private var raised: Bool { model.stance == .raised }

    var body: some View {
        let placed = displayedGeometry()
        // While the window hugs the card (a pinned rest), the window's
        // own frame carries the card's place on screen; drawing the
        // card at its pane offset too would push it out of its own
        // window.
        let hugging = !model.stance.spansPane(pinned: model.pinned)
        ZStack(alignment: .topLeading) {
            // The raised window spans the screen, so without this a
            // click beside the card would be swallowed by our own
            // transparent pane. Clicking outside the card rests the
            // surface instead, the click's plain meaning. (While
            // resting the gesture is unreachable: the unpinned rest
            // ignores the mouse entirely, and the pinned rest's window
            // is exactly the card, with no beside-the-card left.)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if raised { model.rest() }
                }
            card
                .frame(width: placed.width, height: placed.height)
                .offset(
                    x: hugging ? 0 : placed.origin.x,
                    y: hugging ? 0 : placed.origin.y
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The drag gestures measure in this space, not their own
        // view's: a grip moves with the card it is resizing, so a
        // translation read in the grip's local space re-subtracts
        // each delta already applied and the edge falls to half the
        // pointer's speed. The pane holds still; measure there.
        .coordinateSpace(name: Self.paneSpace)
        // The keyboard map is mounted only while raised: a resting
        // surface refuses key status outright, so a map it carried
        // could never fire, and not carrying one says so structurally.
        .background(raised ? PageKeyboardMap(model: pages) : nil)
        .onChange(of: model.stance) { _ in
            // A rest mid-drag (Esc works while the mouse is down)
            // cancels the gesture without an `onEnded`; discard the
            // in-flight delta so the card does not stick askew.
            dragTranslation = .zero
            resizingEdge = nil
            resizeTranslation = .zero
        }
    }

    /// The geometry to draw right now: the settled model value with any
    /// in-flight drag or resize applied, run through the same pure
    /// clamp — against the same pane rect — that will judge the
    /// commit. Live feedback and the settled result therefore agree;
    /// the card never previews a place it will not be allowed to keep.
    private func displayedGeometry() -> BackdropGeometry {
        var proposed = model.geometry
        if let resizingEdge {
            proposed = resizingEdge.resized(proposed, by: resizeTranslation)
        }
        proposed.origin.x += dragTranslation.width
        proposed.origin.y += dragTranslation.height
        return proposed.clamped(to: model.pane)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 32)
            Divider()
            PageContentView(model: pages, readOnly: !raised, emptyHint: emptyHint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The glance is the same ink at the same measure,
                // dimmed. Promote and demote must not make the text
                // jump, so only the opacity changes.
                .opacity(raised ? 1 : 0.72)
            PageStatusStack(model: pages)
            Divider()
            TabStripView(model: pages)
                .opacity(raised ? 1 : 0.72)
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
                    .onTapGesture { model.raise() }
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
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text(pages.showingLedger ? "the ledger" : BackdropAppDelegate.productName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            #if DEBUG
            // Standing indicator while the debug capture opt-out is on.
            // Doubly load-bearing here: the backdrop is on screen for
            // every screenshot and screen share, so "the exclusion is
            // off right now" is worth saying out loud.
            if pages.allowCapture {
                Image(systemName: "camera.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.ember)
                    .help("Debug: capture exclusion is OFF — this surface shows up in screenshots and screen sharing")
                    .accessibilityLabel(Text("Screenshots allowed (debug)"))
            }
            #endif
            if let sheet = pages.selectedSheet, !pages.showingLedger {
                CountdownButton(sheet: sheet) { pages.cycleRung(sheet.id) }
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

    /// The header drag: live translation while the mouse is down, one
    /// committed origin when it settles. The model clamps and
    /// persists; the view only proposes. The minimum distance keeps a
    /// plain click on the header from registering as a zero-length
    /// drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.paneSpace))
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { value in
                dragTranslation = .zero
                // A rest mid-drag (Esc) cancels the manipulation, but
                // the window that captured the mouse-down still gets
                // the mouse-up; the abandoned proposal must not land.
                guard raised else { return }
                var proposed = model.geometry
                proposed.origin.x += value.translation.width
                proposed.origin.y += value.translation.height
                model.endZoom()
                model.setGeometry(proposed)
            }
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

    private static let gripThickness: CGFloat = 6
    private static let cornerSide: CGFloat = 12

    /// The stationary space the drag gestures measure in; the pane
    /// covers the screen and does not move with the card.
    private static let paneSpace = "backdrop-pane"

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
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.paneSpace))
            .onChanged { value in
                resizingEdge = edge
                resizeTranslation = value.translation
            }
            .onEnded { value in
                resizingEdge = nil
                resizeTranslation = .zero
                // Same cancellation rule as the header drag: a rest
                // mid-gesture voids the proposal.
                guard raised else { return }
                model.endZoom()
                model.setGeometry(edge.resized(model.geometry, by: value.translation))
            }
    }
}
