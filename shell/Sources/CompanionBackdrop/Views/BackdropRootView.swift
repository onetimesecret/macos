import AppKit
import SwiftUI

/// The surface's face: one card of ink at a comfortable reading measure
/// over the desktop, with the page's countdown and draining gauge. The
/// card dims to a glance while resting and becomes a plain editor while
/// raised; the ember border shows exactly while the surface holds the
/// keyboard, the same visual law as the panel. Where the card sits and
/// how wide it reads come from the model's geometry: the view proposes
/// changes through drag and resize gestures, the model clamps and
/// persists, and both stances honor the settled result.
struct BackdropRootView: View {
    @ObservedObject var model: BackdropModel
    @FocusState private var inkFocused: Bool

    /// Live translation of a header drag, in points. Zero except while
    /// a drag is in flight; the settled position lives in the model.
    @State private var dragTranslation: CGSize = .zero

    /// Live delta of a corner resize: width across, editor floor down.
    /// Zero except while the handle is held.
    @State private var resizeDelta: CGSize = .zero

    private var raised: Bool { model.stance == .raised }

    var body: some View {
        GeometryReader { pane in
            let placed = displayedGeometry(in: pane.size)
            ZStack(alignment: .topLeading) {
                // The raised window spans the screen, so without this a
                // click beside the card would be swallowed by our own
                // transparent pane. Clicking outside the card rests the
                // surface instead, the click's plain meaning. (While
                // resting the window ignores the mouse entirely, so the
                // gesture is unreachable there.)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if raised { model.rest() }
                    }
                card(placed)
                    .offset(x: placed.origin.x, y: placed.origin.y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(keyboardMap)
        .onChange(of: model.stance) { _ in
            // A rest mid-drag (Esc works while the mouse is down)
            // cancels the gesture without an `onEnded`; discard the
            // in-flight delta so the card does not stick askew.
            dragTranslation = .zero
            resizeDelta = .zero
        }
    }

    /// The geometry to draw right now: the settled model value with any
    /// in-flight drag or resize applied, run through the same pure
    /// clamp that will judge the commit. Live feedback and the settled
    /// result therefore agree; the card never previews a place it will
    /// not be allowed to keep.
    private func displayedGeometry(in paneSize: CGSize) -> BackdropGeometry {
        var proposed = model.geometry
        proposed.origin.x += dragTranslation.width
        proposed.origin.y += dragTranslation.height
        proposed.width += resizeDelta.width
        proposed.minEditorHeight += resizeDelta.height
        return proposed.clamped(to: paneSize)
    }

    private func card(_ placed: BackdropGeometry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let sheet = model.sheet {
                gauge(sheet)
            }
            content(minEditorHeight: placed.minEditorHeight)
        }
        .padding(20)
        .frame(width: placed.width, alignment: .topLeading)
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
                .strokeBorder(Color.ember.opacity(model.holdsKeys ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottomTrailing) {
            // The resize affordance exists only while raised. The
            // resting glance keeps its chrome-free face, and by the
            // stance invariant it could not take the drag anyway: the
            // resting window ignores the mouse entirely.
            if raised {
                resizeHandle
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text("backdrop")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            if let sheet = model.sheet {
                countdownButton(sheet)
            }
        }
        // The header doubles as the card's handle while raised. The
        // gesture rides the header itself, above the pane's tap
        // catcher, so a drag can never fall through and read as a
        // click-outside rest; the countdown button, being a child,
        // still wins a plain click. While resting the mask yields the
        // gesture to subviews, which leaves the handle inert (and the
        // resting window ignores the mouse regardless).
        .contentShape(Rectangle())
        .gesture(dragGesture, including: raised ? .all : .subviews)
    }

    /// The header drag: live translation while the mouse is down, one
    /// committed origin when it settles. The model clamps and
    /// persists; the view only proposes. The minimum distance keeps a
    /// plain click on the header from registering as a zero-length
    /// drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
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
                model.setGeometry(proposed)
            }
    }

    /// The corner affordance, in the card's own quiet dialect: a small
    /// tertiary glyph that only the raised card shows. Dragging it
    /// widens the column and deepens the editor's floor together.
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(8)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
            .accessibilityHidden(true)
    }

    /// The resize drag, the drag gesture's twin: width follows the
    /// horizontal pull, the editor floor the vertical, and the commit
    /// goes through the model's clamp like every other proposal.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                resizeDelta = value.translation
            }
            .onEnded { value in
                resizeDelta = .zero
                // Same cancellation rule as the header drag: a rest
                // mid-gesture voids the proposal.
                guard raised else { return }
                var proposed = model.geometry
                proposed.width += value.translation.width
                proposed.minEditorHeight += value.translation.height
                model.setGeometry(proposed)
            }
    }

    /// The countdown label: remaining time on the current rung; click
    /// cycles the ladder and resets the clock (docs/spec/04). Only
    /// reachable while raised — the resting window ignores the mouse.
    private func countdownButton(_ sheet: BackdropSheetSummary) -> some View {
        Button {
            model.cycleRung()
        } label: {
            HStack(spacing: 5) {
                if sheet.paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8))
                        .accessibilityHidden(true)
                }
                Text(sheet.remainingLabel)
                    .font(.system(.caption, design: .monospaced))
                Text(sheet.rungLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(sheet.lastHour ? Color.ember : .secondary)
        }
        .buttonStyle(.plain)
        .help("Click to cycle the ladder and reset the clock")
        .accessibilityLabel(Text("Countdown"))
        .accessibilityValue(Text(sheet.spokenRemaining))
        .accessibilityHint(Text("Activate to cycle the ladder and reset the clock"))
    }

    /// The page's draining gauge, the resting surface's one honest
    /// motion (repainted at the stance's cadence, not animated).
    private func gauge(_ sheet: BackdropSheetSummary) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(sheet.lastHour ? Color.ember : Color.secondary)
                    .frame(width: max(0, geometry.size.width * sheet.fractionRemaining))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    /// One editor floor for every branch: the raised editor, the
    /// resting glance, and the empty line all stand on the same
    /// `minEditorHeight`, so promote and demote never make the card
    /// change height underfoot.
    @ViewBuilder
    private func content(minEditorHeight: CGFloat) -> some View {
        if raised {
            TextEditor(text: $model.ink)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($inkFocused)
                .frame(minHeight: minEditorHeight)
                .onChange(of: model.ink) { text in
                    model.inkEdited(text)
                }
                .onAppear {
                    // The keyboard hand-off, from the editor's own side
                    // of the mount. The editor exists only while raised,
                    // so `onAppear` is by definition after the raise made
                    // the window key (controller-side) *and* after the
                    // conditional view is in the hierarchy — a stance
                    // observer could fire before the mount and lose the
                    // request, the same race the panel's
                    // `focusEditorWhenMounted` bounds (issue #19). The
                    // second request one main-actor turn later covers
                    // AppKit wiring the field editor up an instant after
                    // SwiftUI reports the appearance.
                    inkFocused = true
                    Task { @MainActor in inkFocused = true }
                }
                .onChange(of: model.holdsKeys) { holdsKeys in
                    // The keyboard came back to a still-raised surface
                    // (a ⌘Tab return, a re-summon): re-seat the editor,
                    // in case first responder was lost while away.
                    if holdsKeys { inkFocused = true }
                }
        } else if model.ink.isEmpty {
            // The empty state: a single calm line (docs/spec/03, tone).
            Text("empty — ⌃⌥Space raises the surface")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: minEditorHeight, alignment: .topLeading)
        } else {
            // The glance: the same ink at the same measure, dimmed —
            // promote and demote must not make the text jump.
            Text(model.ink)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: minEditorHeight, alignment: .topLeading)
        }
    }

    /// The window-level keyboard map, active exactly while the surface
    /// holds the keys (raised): Esc rests it, handing the keyboard back.
    private var keyboardMap: some View {
        Group {
            Button("") { model.rest() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// The ember accent (#d45a2a) — the same single accent the panel
    /// uses; duplicated here because form factors are separate targets
    /// (ADR-0010).
    static let ember = Color(red: 0.831, green: 0.353, blue: 0.165)
}
