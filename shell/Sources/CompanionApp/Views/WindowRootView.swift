import AppKit
import Carbon.HIToolbox
import CompanionKit
import SwiftUI

/// The window's face (docs/spec/04): a quiet header where the title bar
/// is, one page of ink and chips (or the ledger), the page's draining
/// gauge, and the bottom-edge tab strip. An ember border shows exactly
/// while the page holds the keyboard.
struct WindowRootView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 34)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if WindowModel.shouldShowPasteboardOffer(
                boardHolds: model.pasteboardOffer,
                hasPage: model.selection != nil,
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
                Text(notice)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ember)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let draft = model.promotion, !model.showingLedger {
                // The inline, in-place confirmation (never a modal):
                // the network boundary is the one confirming click.
                PromotionView(model: model, draft: draft)
            }
            if let sheet = model.selectedSheet, !model.showingLedger {
                // The page's bottom edge drains continuously.
                GaugeBar(
                    fraction: sheet.fractionRemaining,
                    paused: sheet.paused,
                    lastHour: sheet.lastHour
                )
                .frame(height: 4)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            }
            Divider()
            TabStripView(model: model)
        }
        .background(Color.panelBackground)
        .overlay(
            // The ember border: the window holds the keyboard, and a
            // keystroke lands somewhere (the editor when a page shows,
            // the Return grant when none does). Visible state, never
            // colour alone; the caret and focus ring agree.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.ember.opacity(model.holdsKeys ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .background(keyboardMap)
        // The 1 Hz countdown redraw runs only while the window is on
        // screen (docs/spec/05 frugality budget).
        .onAppear { model.startRedraw() }
        .onDisappear { model.stopRedraw() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text(model.showingLedger ? "the ledger" : "CompanionApp")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            #if DEBUG
            // Standing indicator while the debug capture opt-out is on:
            // the window is screenshot-able and screen-share-visible,
            // and stderr alone is invisible outside a terminal.
            if model.allowCapture {
                Image(systemName: "camera.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.ember)
                    .help("Debug: capture exclusion is OFF — this window shows up in screenshots and screen sharing")
                    .accessibilityLabel(Text("Screenshots allowed (debug)"))
            }
            #endif
            if let sheet = model.selectedSheet, !model.showingLedger {
                countdownButton(sheet)
            }
            pinToggle
        }
    }

    /// The countdown label: remaining time on the current rung; click
    /// cycles the ladder and resets the clock (docs/spec/04).
    private func countdownButton(_ sheet: SheetSummary) -> some View {
        Button {
            model.cycleRung(sheet.id)
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

    /// Float-on-top setting. A real `Toggle` so VoiceOver announces a
    /// switch with on/off state; the window level follows it.
    private var pinToggle: some View {
        Toggle(isOn: $model.floatsOnTop) {
            Image(systemName: model.floatsOnTop ? "pin.fill" : "pin")
                .font(.system(size: 9))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(model.floatsOnTop
            ? "Floating above other windows — click to let them cover it"
            : "Behaves like a normal window — click to keep it on top")
        .accessibilityLabel(Text("Keep window above other windows"))
    }

    @ViewBuilder
    private var content: some View {
        if model.showingLedger {
            LedgerView(entries: model.ledgerEntries)
        } else if let selection = model.selection {
            // No `.id(selection)` on the editor, and the omission is
            // contract, not oversight (ADR-0006): one editor persists
            // across page switches, and `updateNSView` swaps the
            // page's storage underneath it. Re-adding an id would make
            // every switch an identity change again — the swap path
            // goes dead, and caret, scroll, and undo are quietly
            // discarded on every tab change.
            InkEditorView(model: model, sheetID: selection)
        } else {
            // The empty state: static text over a catcher that serves
            // two grants (ADR-0005). A click into the emptiness, the
            // third grant, creates a page and hands its editor the
            // keyboard. While the window already holds the keys, the
            // catcher holds first responder so Return, the fourth
            // grant, creates a page too, and Esc still hands the
            // keyboard back.
            ZStack {
                EmptyStateKeyGrant(
                    sheetsEmpty: { [model] in model.sheets.isEmpty },
                    onCreate: { window in model.createPageAndFocus(in: window) },
                    onEscape: { model.escape() }
                )
                VStack(spacing: 6) {
                    Text("Empty is the resting state.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("click, ⌥Space, or ↩ for a page")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The window-level keyboard map (docs/spec/04), carried by
    /// zero-size hidden buttons: active exactly while the window holds
    /// the keys — never a global claim (⌥Space, the one exception,
    /// lives in `GlobalHotKey`). ⇧⌘V and ⌘↩ belong to the editor.
    private var keyboardMap: some View {
        Group {
            // ⌘1–⌘9: jump by visible tab order.
            ForEach(1...9, id: \.self) { number in
                Button("") { model.select(index: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            // ⌘0: the ledger.
            Button("") { model.showLedger() }
                .keyboardShortcut("0", modifiers: .command)
            // ⌥⌘N: new page, default rung.
            Button("") { model.newPage() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            // ⌥⌘← / ⌥⌘→: previous / next page.
            Button("") { model.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("") { model.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            // ⌘W: close the page — every macOS app's close verb. The
            // ledger view, when showing, closes back to the page.
            Button("") { model.closeCurrent() }
                .keyboardShortcut("w", modifiers: .command)
            // ⌘,: Settings — the macOS convention, honoured while the
            // window holds the keys (an accessory app has no app menu
            // to carry it globally).
            Button("") { model.onOpenSettings?() }
                .keyboardShortcut(",", modifiers: .command)
            // Esc outside the editor (the ledger, chrome): hand back.
            Button("") { model.escape() }
                .keyboardShortcut(.cancelAction)
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
/// so a pageless window could never accept the keyboard at all, and
/// keystrokes fell through to the app underneath. This view answers
/// yes, because a click into the emptiness is itself the deliberate
/// act the law requires, and it reports the click so the model can
/// conjure the page the grant promises. While the window already
/// holds the keys it also holds first responder, so Return conjures
/// the page as well (the muscle memory of starting a new thought) and
/// Esc hands the keyboard back. Chrome (tabs, header, pin) carries no
/// such view and stays mute.
private struct EmptyStateKeyGrant: NSViewRepresentable {
    let sheetsEmpty: () -> Bool
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
        view.sheetsEmpty = sheetsEmpty
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
private final class KeyGrantingClickView: NSView {
    var onCreate: ((NSWindow?) -> Void)?
    var onEscape: (() -> Void)?

    /// The model's live fact, read through a closure rather than cached
    /// as a bool: a page created this instant flips `model.sheets` at
    /// once, but the representable only pushes a cached snapshot on the
    /// next render pass. The `didBecomeKey` observer can fire inside
    /// that gap — after the editor already took focus — and a stale
    /// `true` would let the catcher seize first responder back from the
    /// editor, then unmount and strand it (issue #23). Reading live
    /// closes the gap.
    var sheetsEmpty: () -> Bool = { true }

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
    /// fourth grant is on offer; the window's key status and the
    /// model's sheet count are both consulted live.
    private func claimFirstResponderIfEntitled() {
        guard let window else { return }
        guard WindowModel.shouldOfferEnterCreate(
            sheetsEmpty: sheetsEmpty(), holdsKeys: window.isKeyWindow
        ) else { return }
        window.makeFirstResponder(self)
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }
}
