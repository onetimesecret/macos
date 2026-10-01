import AppKit
import CompanionKit
import SwiftUI

/// Dim one piece of the card as the stance crosses. Kept as a modifier
/// so the opacity rule has one implementation for the rail, page and
/// strip, and so the transaction it hands to embedded AppKit content is
/// directly testable.
struct StanceFadeModifier: ViewModifier {
    let raised: Bool
    let animation: Animation?

    #if DEBUG
    /// Sees the transaction the fade itself runs under, above the
    /// boundary that clears it. Nothing below the boundary can observe
    /// that the fade is animated, so debug tests use this seam to pin
    /// the positive half of the rule. It is not compiled into releases.
    var fadeProbe: (@MainActor (Transaction) -> Void)? = nil
    #endif

    func body(content: Content) -> some View {
        content
            // The fade belongs to this compositing boundary and to
            // nothing under it. A transaction covers the whole subtree,
            // so this clears the animation for everything the modifier
            // wraps, the banners and status lines included, and not
            // only for the embedded editor that made it necessary:
            // letting the transaction reach the NSTextView/NSScrollView
            // update animates its viewport while editability changes,
            // which makes the page dip and return on every raise and
            // rest. The breadth is accepted rather than incidental.
            // Stance is a whole-card change, so a piece of the card
            // animating on its own timing across it would read as a
            // glitch, and any animation a child truly needs can carry
            // its own transaction below this one.
            .transaction { transaction in
                transaction.animation = nil
            }
            .opacity(raised ? 1 : 0.72)
            #if DEBUG
            .transaction { transaction in
                fadeProbe?(transaction)
            }
            #endif
            .animation(animation, value: raised)
    }
}

extension View {
    func stanceFaded(raised: Bool, animation: Animation?) -> some View {
        modifier(StanceFadeModifier(raised: raised, animation: animation))
    }
}

/// The surface's face: a card of pages over the desktop, dimmed to a
/// glance while resting and a plain editor while raised. The ember
/// border shows exactly while the surface holds the keyboard, the same
/// visual law as the panel.
///
/// What the card *contains* is the shared surface (`PageSurface.swift`
/// in CompanionKit): the same content area, status lines and tab strip
/// the panel window shows. What is here is the card itself:
/// where it sits, how it is sized, and how the two stances look.
struct BackdropRootView: View {
    @ObservedObject var model: BackdropModel
    let onCardClick: () -> Void

    /// The shared model, observed directly: the card's own chrome reads
    /// the selected page and its clock, so this view must redraw when
    /// they change and not only when the stance does.
    @ObservedObject var pages: PageModel

    /// The sync controller, observed on its own account: it is a
    /// nested `ObservableObject`, and a nested object's changes do not
    /// republish through the model that holds it, so the header's sync
    /// word would otherwise stand at whatever it read first.
    @ObservedObject var sync: SyncController

    init(model: BackdropModel, onCardClick: @escaping () -> Void) {
        self.model = model
        self.onCardClick = onCardClick
        pages = model.pages
        sync = model.pages.sync
    }

    /// Where the pointer was when the manipulation in flight began, in
    /// AppKit's screen coordinates. Nil except while the mouse is down;
    /// its presence is what tells `onEnded` there is a real gesture to
    /// commit rather than one a mid-drag rest already voided.
    @State private var gestureAnchor: CGPoint?

    /// How wide the trailing indicator cluster is drawing right now.
    /// The header mirrors it as an empty leading column so the identity
    /// can stay centred on the card without the two ever sharing a
    /// point of the header.
    @State private var indicatorWidth: CGFloat = 0
    @State private var headerWidth: CGFloat = 0

    private var raised: Bool { model.stance == .raised }

    /// The crossing between the two stances (D-02): a short fade of
    /// the dimmed content, or no animation at all under Reduce Motion,
    /// where SwiftUI takes nil as "arrive at once". Read on each body
    /// evaluation rather than captured, so a stance change sees the
    /// setting as it stands. Nothing else on the card animates: the
    /// keyline, the header words and the geometry all snap.
    private var stanceFade: Animation? {
        let duration = BackdropStance.currentStanceFadeDuration()
        return duration > 0 ? .easeInOut(duration: duration) : nil
    }

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
            // Organization (slots or days) and placement (bottom or
            // side) are independent. The content view answers the
            // former; this branch answers only the latter (D-26).
            HStack(spacing: 0) {
                if pages.showsPagesDownSide && !pages.isPageExpanded {
                    Group {
                        if pages.showsTimeUnits {
                            TimeRailView(model: pages)
                        } else {
                            SlotRailView(model: pages)
                        }
                    }
                    .stanceFaded(raised: raised, animation: stanceFade)
                    Divider()
                }
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .stanceFaded(raised: raised, animation: stanceFade)
            }
            PageStatusStack(model: pages)
            if !pages.showsPagesDownSide && !pages.isPageExpanded {
                Divider()
                Group {
                    if pages.showsTimeUnits {
                        TimeStripView(model: pages)
                    } else {
                        TabStripView(model: pages)
                    }
                }
                .stanceFaded(raised: raised, animation: stanceFade)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            // The ember border shows exactly while this surface holds
            // the keyboard. Raised and keyed are distinct facts: a card
            // the user ⌘Tabbed away from is raised, unkeyed, and unlit.
            // The model's key fact is the owner's, so the card asks for
            // its own: a resting card beside a keyed editor window is
            // unlit too. Visible state, never colour alone; the caret
            // and focus ring agree.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    pages.holdsKeys(on: .panel) ? Color.ember : Color.clear, lineWidth: 1.5
                )
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Every URL dropped on the card goes through the shared file-open
        // path, where the core decides whether it can be opened (ADR-0028).
        // It rides the whole card
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
            // sits above every control, so a resting card's pin cannot
            // be worked without raising first. On the
            // unpinned rest it is mounted but unreachable; the window
            // itself ignores the mouse.
            if !raised {
                Color.clear
                    .contentShape(Rectangle())
                    // The app delegate sends this gesture through the
                    // same routing table as the other summons.
                    .onTapGesture(perform: onCardClick)
                    .help("Click to raise the card")
            }
        }
    }

    /// The panel mounts content only while it owns. The whole panel is
    /// hidden while the regular window is selected, including its resting form.
    @ViewBuilder
    private var pageContent: some View {
        if pages.owner == .panel {
            PageContentView(model: pages, readOnly: !raised, emptyHint: emptyHint)
        } else if !model.editorWindowOpen {
            // Reserved never-grant policy: a visible read-only panel still
            // renders its page. Ordinary switches hide the entire non-owner.
            GlanceView(model: pages)
        } else {
            Color.clear
        }
    }

    /// The empty state names the gesture that actually conjures a page
    /// on this surface. A resting card cannot be typed into, so it
    /// points at the summon that would change that; the pinned rest is
    /// clickable, so its hint says so.
    private var emptyHint: String {
        if raised { return "click, ⌃⌥Space, or ↩ to start one" }
        return model.pinned
            ? "click or ⌃⌥Space raises the surface"
            : "⌃⌥Space raises the surface"
    }

    /// What the middle column may take, or nil for the single pass
    /// before the card has been measured, where an unconstrained
    /// identity reads better than one starved to nothing.
    private var identityColumnWidth: CGFloat? {
        guard headerWidth > 0 else { return nil }
        return HeaderLayout.identityWidth(
            cardWidth: headerWidth, indicatorWidth: indicatorWidth
        )
    }

    private var header: some View {
        // Three columns rather than a stack. The identity used to be
        // centred in a ZStack with the indicators laid over it, which
        // held only while the identity stayed inside its 260 point
        // cap; a file identity, whose words are the file's and not
        // ours, routinely asked for more and slid under the cluster
        // drawn after it. Given a column of its own the identity can
        // no longer reach the cluster's ground, whatever it has to
        // say, and the empty leading column, kept the same width as
        // the cluster, keeps the middle centred on the card rather
        // than on what is left of it.
        HStack(spacing: HeaderLayout.gutter) {
            Color.clear
                .frame(width: indicatorWidth, height: 0)

            // This is a borderless surface, so the header has to supply
            // the quiet orientation cue a title bar normally would. A
            // centered identity belongs to the card rather than to the
            // navigation column below it: the rail is one mode of the
            // page picker, not the owner of the window.
            headerIdentity
                .frame(width: identityColumnWidth)
                .frame(maxWidth: .infinity)

            headerIndicators
                .fixedSize()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HeaderIndicatorWidthKey.self, value: proxy.size.width
                        )
                    }
                )
        }
        // The card's width, read from the header's own ground. Nothing
        // downstream of it changes that ground: the cluster is sized to
        // fit and the identity only ever takes what this arithmetic
        // hands it, so measuring here cannot start a loop.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeaderWidthKey.self, value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(HeaderIndicatorWidthKey.self) { width in
            indicatorWidth = width
        }
        .onPreferenceChange(HeaderWidthKey.self) { width in
            headerWidth = width
        }
        // The header doubles as the card's handle while raised. The
        // gesture rides the header itself, above the pane's tap
        // catcher, so a drag can never fall through and read as a
        // click-outside rest; the pin toggle, being a child, still
        // wins a plain click. While resting the mask yields the
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

    /// The name of what is on screen, held at the optical centre of the
    /// card. A file replaces the product name at this same seat, so the
    /// header still answers the file surface's primary question without
    /// pulling the controls out of their stable trailing cluster.
    @ViewBuilder
    private var headerIdentity: some View {
        // The ember dot is hidden (issue #78): the name alone says
        // whose card this is, and the dot spent its colour on nothing
        // in particular.
        if HiddenUI.showsHeaderDot {
            HStack(spacing: 8) {
                Circle().fill(Color.ember).frame(width: 6, height: 6)
                headerIdentityText
            }
        } else {
            headerIdentityText
        }
    }

    @ViewBuilder
    private var headerIdentityText: some View {
        if let file = pages.activeFile, !pages.showingLedger {
            // A file showing puts its own identity where the product
            // name stands, because on a file surface the question the
            // header answers is which file this is and whether it is on
            // disk (ADR-0028).
            fileIdentity(FileHeaderState.derive(
                from: file, renderMode: pages.activeFileRenderMode
            ))
        } else {
            Text(pages.showingLedger ? "the ledger" : BackdropAppDelegate.productName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The card-wide state controls. Kept as one trailing cluster so
    /// their changing words do not move the surface identity or compete
    /// with the navigation rail's headings.
    private var headerIndicators: some View {
        HStack(spacing: 8) {
            if raised {
                Button {
                    model.onOpenEditorWindow?()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Open in Window")
                .accessibilityLabel("Open in Window")
            }

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
            // No countdown here. The header used to print the selected
            // page's remaining time as a clickable label, and dogfooding
            // found it was a second clock for a page that already has
            // one: the gauge under its tab while the strip is the
            // navigation, the label in its own day gutter while the
            // days are (docs/dogfood/ABERRATIONS.md, 2026-09-05). The
            // rung still steps from the tab's context menu and from the
            // gutter's, which is where the page is, rather than up
            // here beside the product name.
            pinToggle
        }
    }

    /// Forward every dropped URL to the shared file-open path. The core
    /// evaluates each item by its contents, not its suffix or declared type.
    ///
    /// It answers true whenever anything was dropped, including files the
    /// core refuses with a notice. Answering false would give the item back
    /// to whatever is underneath the card.
    private func openDropped(_ urls: [URL]) -> Bool {
        Self.forwardDroppedURLs(urls) { pages.openFile(at: $0) }
    }

    /// The testable part of drop handling: no suffix or type classification,
    /// only forwarding every URL in order to the caller's file-open path.
    static func forwardDroppedURLs(_ urls: [URL], openFile: (URL) -> Void) -> Bool {
        guard !urls.isEmpty else { return false }
        for url in urls {
            openFile(url)
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
                    .foregroundStyle(state.showsUnsavedDot ? Color.emberText : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            if let stamp = state.lastEditStamp {
                // The draft's age, on a file whose buffer came back
                // from the drafts file rather than from disk. It is the
                // whole of what the app owes for quitting without a
                // save sheet: a person can see how old the typing is
                // before pressing the save chord. Secondary rather than
                // tertiary ink, since a fact the app owes is text that
                // carries meaning and must be readable as such.
                Text(stamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !state.encodingAndFormat.isEmpty {
                Text(state.encodingAndFormat)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // The name yields its width before the facts beside it do: a
        // middle-truncated file name still says which file this is,
        // where a clipped "unsaved" says nothing at all.
        .lineLimit(1)
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
                .foregroundStyle(Color.emberText)
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
                    .foregroundStyle(Color.emberText)
                    .help("The last write was refused; the app keeps retrying. Quit is cancelled while the flush remains refused.")
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
        case .loud: return AnyShapeStyle(Color.emberText)
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

/// How wide the header's ground came out, which is the card's width
/// less its own padding. The identity's column is cut from it by
/// `HeaderLayout.identityWidth`, so the drawing and the arithmetic the
/// tests assert are one thing rather than two.
private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// How wide the trailing indicator cluster came out. Read from the
/// cluster itself rather than guessed, because its words come and go
/// with the session's state and a guessed width would be wrong in
/// exactly the cases the reserve exists for.
private struct HeaderIndicatorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The header's width arithmetic, written apart from the drawing but
/// consulted by it: the header measures its own ground and asks here
/// how much of it the identity may take. Keeping the rule in one
/// function means the invariant that matters can be asserted without a
/// card — the identity's column and the indicator cluster's never share
/// a point, however narrow the card gets — and that what is asserted is
/// what the view does.
enum HeaderLayout {
    /// The space between the header's three columns.
    static let gutter: CGFloat = 8

    /// As wide as the identity is ever allowed to be. A centred name
    /// that runs on becomes a line of text rather than a title, so it
    /// stops here and truncates instead.
    static let identityCap: CGFloat = 260

    /// The width the middle column may take on a card this wide, given
    /// an indicator cluster of `indicatorWidth` and its mirror on the
    /// leading side.
    ///
    /// Answers zero rather than a negative measure when the cluster and
    /// its mirror have eaten the header whole: the identity then shows
    /// nothing, which is the right failure, since the cluster's states
    /// are the ones that need acting on.
    static func identityWidth(cardWidth: CGFloat, indicatorWidth: CGFloat) -> CGFloat {
        let reserved = 2 * (indicatorWidth + gutter)
        return max(0, min(identityCap, cardWidth - reserved))
    }
}
