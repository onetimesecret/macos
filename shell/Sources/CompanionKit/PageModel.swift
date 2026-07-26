import AppKit
import Foundation
import SwiftUI
import os

/// One run of a page's document, as the shell mirrors it to the core
/// (`companion_sheet_sync_document`): visible ink, or a sealed chip's id.
public enum DocumentRun {
    case ink(String)
    case chip(UInt64)
}

/// An in-flight promotion: the inline, in-place confirmation's state
/// (docs/spec/04 — not a modal). Holds options and outcome, never
/// content: the payload stays core-side throughout.
public struct PromotionDraft {
    /// Sendable explicitly, not by inference: a public enum gets no
    /// implicit conformance, and this value is captured by the
    /// detached task that carries the promotion to the network.
    public enum Target: Equatable, Sendable {
        case chip(UInt64)
        case page(UInt64)
    }

    public let target: Target
    /// Requested TTL, seeded from the page's remaining time snapped
    /// down the ladder (the core applies the same default when nil).
    public var ttlSecs: UInt64
    public var passphrase = ""
    public var recipient = ""
    /// The network call is out; the confirm button waits.
    public var inFlight = false
    /// Inline failure — offline, auth, refusal — with retry. Content
    /// never left the sheet.
    public var error: String?
    /// Success: the link is on the clipboard; this is all we keep.
    public var receiptId: String?

    public init(target: Target, ttlSecs: UInt64) {
        self.target = target
        self.ttlSecs = ttlSecs
    }

    /// The ladder rungs at or under the page's remaining time — the
    /// promoted secret never outlives the local intent (doc 06 №13).
    public static func snappedTtl(remainingMs: UInt64) -> UInt64 {
        let ladder: [UInt64] = [3600, 10800, 28800, 86400, 259_200, 604_800]
        let remaining = remainingMs / 1000
        return ladder.last { $0 <= remaining } ?? ladder[0]
    }
}

/// The view model both form factors share: it wraps the core client and
/// publishes non-secret summaries. It never holds a sealed byte — the
/// page's live ink belongs to the editor's text storage; chips are ids
/// and excerpts. What differs between a summoned panel and an ambient
/// surface is the window around it, not this: the pages, their clocks,
/// the ledger, and the exit ramp are one behaviour, described once.
///
/// Frugality contract (docs/spec/05): expiry is *scheduled*, not polled —
/// one timer armed at the core's next event (page expiry or hold lapse),
/// re-armed after it fires. The only periodic work is a countdown
/// redraw, and its cadence is the surrounding form factor's business.
@MainActor
public final class PageModel: ObservableObject {
    /// What this form factor decides differently — where its Keychain
    /// items and sealed file live, which rung a fresh page opens on.
    public let formFactor: FormFactor

    @Published public private(set) var sheets: [SheetSummary] = []

    /// The visibly selected page — the one the editor shows and the
    /// gestures act on. Nil only when no pages exist.
    @Published public var selection: UInt64?

    /// The ledger tab (⌘0) is showing instead of a page.
    @Published public var showingLedger = false

    /// Dead pages, refreshed when the ledger is shown or pages die.
    @Published public private(set) var ledgerEntries: [LedgerEntry] = []

    /// A refusal or status line the surface shows briefly ("the window
    /// holds 9 pages…"). Refuse-don't-evict means the app says so.
    @Published public var notice: String?

    /// Notices are transient by contract: each `flash` restarts the
    /// clock, and the line clears itself unless a newer notice has
    /// taken its place.
    private var noticeGeneration = 0

    /// True while the page holds the keyboard — drives the ember
    /// border. Set by the controller from window key status.
    @Published public var holdsKeys = false

    /// The tab currently being drag-reordered, if any.
    @Published public var draggingTab: UInt64?

    /// The summon-time offer (ADR-0007 Amendment 1): the board holds
    /// external content and the surface offers to take it. Set at each
    /// reveal, withdrawn on hide and the moment a seal takes the
    /// content — a snapshot of the board at summon, not a live watch
    /// (the app never polls the pasteboard).
    @Published public private(set) var pasteboardOffer = false

    /// Set by the editor's coordinator: the offer's button routes
    /// through the same path as ⇧⌘V, so the chip lands at the caret
    /// and this model never places document content itself.
    public var performSealedPaste: (() -> Void)?

    /// The inline promotion confirmation, when one is open.
    @Published public var promotion: PromotionDraft?

    /// Connection state for Settings and the promotion header (never
    /// the token itself).
    @Published public private(set) var connection: ConnectionInfo?

    /// Whether the window floats above other apps' windows
    /// (`.statusBar` level) or behaves like a normal window others can
    /// cover (`.normal`). Persisted; the panel's controller follows it.
    /// The backdrop's altitude is its stance's business instead, and it
    /// leaves this alone.
    @Published public var floatsOnTop: Bool {
        didSet { defaults.set(floatsOnTop, forKey: Self.floatsKey) }
    }
    private static let floatsKey = "floatsOnTop"

    #if DEBUG
    /// Debug builds only: lift the capture exclusion so the surface can
    /// be screenshotted while diagnosing the UI. Deliberately NOT
    /// persisted — a security opt-out fails closed at every launch.
    /// COMPANION_ALLOW_CAPTURE=1 seeds it for scripted runs; a release
    /// build compiles the property out entirely.
    @Published public var allowCapture =
        ProcessInfo.processInfo.environment["COMPANION_ALLOW_CAPTURE"] != nil
    #endif

    /// The live editor view, so a summon can hand it the keyboard.
    /// Weak and non-published: view plumbing, not state.
    public weak var activeEditor: NSTextView?

    /// Set by the app delegate; Esc routes here when no editor holds
    /// the keys (the controller re-keys the frontmost app's window).
    public var onHandBackKeys: (() -> Void)?

    /// Set by the app delegate; ⌘, routes here (the delegate owns the
    /// Settings window, the surface merely asks for it).
    public var onOpenSettings: (() -> Void)?

    private let client: CompanionClient
    private let defaults: UserDefaults

    /// Each live page's document, shell-side: the ink is ordinary text
    /// in an `NSTextStorage`; chips appear as attachment characters
    /// carrying only ids and excerpts. Pruned when pages die.
    private var storages: [UInt64: NSTextStorage] = [:]

    /// Each live page's undo history. Undo is as document-scoped as
    /// the storage it rewrites (ADR-0006): one editor serves every
    /// page, so letting the window's single manager span pages would
    /// let ⌘Z on one page replay edits against another. Pruned with
    /// the storages; cleared for a page whose storage is changed
    /// behind the editor's back.
    private var undoManagers: [UInt64: UndoManager] = [:]

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var eventTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?

    /// `defaults` is injectable so tests can point at a throwaway
    /// domain; both shipping form factors take their own standard one
    /// (`FormFactor.settingsDefaults`).
    public init(formFactor: FormFactor, defaults: UserDefaults = FormFactor.settingsDefaults) {
        self.formFactor = formFactor
        self.defaults = defaults
        client = CompanionClient(credentialService: formFactor.credentialService)
        logger = Logger(subsystem: formFactor.loggerSubsystem, category: "persistence")
        // Unset → float on top, matching the original behavior.
        floatsOnTop = defaults.object(forKey: Self.floatsKey) as? Bool ?? true
        // No pages yet: the restore is the caller's to time
        // (`loadStateIfNeeded`). The panel defers it to the first
        // reveal, so launching at login never raises a Keychain prompt
        // for a window nobody asked to see (ADR-0004); the backdrop,
        // which is on screen from launch, spends it there instead.
        // The connection outlives the process in two non-secret halves:
        // config in UserDefaults, the token in the Keychain (core-side).
        // Configuring with a nil token keeps whatever the Keychain
        // holds, so guest promotion works with zero setup and a saved
        // token survives relaunch.
        _ = client.configureConnection(
            serverUrl: defaults.string(forKey: Self.serverKey) ?? Self.defaultServer,
            shareDomain: defaults.string(forKey: Self.shareDomainKey) ?? "",
            extid: defaults.string(forKey: Self.extidKey) ?? "",
            token: nil
        )
        connection = client.connectionInfo()
    }

    /// Whether the first reveal has run — restore is attempted once.
    private var stateLoaded = false

    /// The licence `saveState` requires, granted separately from
    /// `stateLoaded`: a restore that failed over an *existing* file —
    /// Keychain key denied or missing, damaged snapshot — leaves the
    /// session usable but unlicensed, so quitting cannot overwrite
    /// yesterday's sealed file with this session's consolation page.
    private var saveLicence = false

    /// The persistence trail in the unified log: restore refusals and
    /// quit-save failures, never content — the file is ciphertext and
    /// these lines carry only what happened to it.
    private let logger: Logger

    /// The first reveal loads yesterday's pages: the core decrypts the
    /// state file (the key comes from the Keychain — a prompt, if the
    /// ACL raises one, answers the user's own summon, per ADR-0004's
    /// spirit of prompting only on use) and drains the wall-clock time
    /// the app was closed, expiring what didn't survive it. A missing
    /// file is a fresh start; an existing file that refuses to open
    /// still gets a working page but forfeits the quit-save licence,
    /// keeping the refusal recoverable. Either way a page awaits — the
    /// surface never opens onto nothing.
    public func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        let path = formFactor.stateFileURL.path
        let fileExists = FileManager.default.fileExists(atPath: path)
        let restored = client.persistRestore(from: path)
        saveLicence = Self.grantsSaveLicence(fileExists: fileExists, restored: restored)
        if !saveLicence {
            logger.error(
                "restore failed over an existing state file; withholding the quit-save licence"
            )
        }
        if client.sheets().isEmpty {
            newSheet()
        }
        refresh()
        selection = sheets.first?.id
    }

    /// The licence's truth table. The core folds "no file yet" and
    /// "refused" into one false; the file's presence on disk is what
    /// tells them apart. A restore that succeeded keeps the licence, a
    /// missing file grants it fresh (nothing exists to protect), and
    /// only an existing file that would not open withholds it.
    public nonisolated static func grantsSaveLicence(fileExists: Bool, restored: Bool) -> Bool {
        restored || !fileExists
    }

    private static let defaultServer = "https://eu.onetimesecret.com"
    private static let serverKey = "connection.serverURL"
    private static let extidKey = "connection.extid"
    private static let shareDomainKey = "connection.shareDomain"

    /// JIT encryption at quit: seal the whole store — live pages,
    /// chips, the ledger — into the state file in one core call.
    /// Nothing touches disk while the app runs. A session that never
    /// loaded must not overwrite yesterday's file with its empty store;
    /// nor may one whose restore was refused (`saveLicence`).
    ///
    /// Returns true when the file is settled — written, or deliberately
    /// left alone. False means the save was attempted and refused: this
    /// session's pages will not survive the quit, and the caller should
    /// say so before the process goes.
    @discardableResult
    public func saveState() -> Bool {
        guard stateLoaded, saveLicence else { return true }
        let url = formFactor.stateFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let saved = client.persistSave(to: url.path)
        if !saved {
            logger.error("quit-save refused; the sealed state file was not rewritten")
        }
        return saved
    }

    deinit {
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
    }

    // MARK: State

    public var selectedSheet: SheetSummary? {
        sheets.first { $0.id == selection }
    }

    public func refresh() {
        sheets = client.sheets()
        let live = Set(sheets.map(\.id))
        // A dead page's ink lives on only in the ledger; drop the
        // editor-side document, and its undo history with it.
        storages = storages.filter { live.contains($0.key) }
        undoManagers = undoManagers.filter { live.contains($0.key) }
        selection = Self.reconciledSelection(current: selection, live: sheets.map(\.id))
        // A promotion whose subject died — expiry, mostly; `close`
        // clears its own — must not keep the confirmation standing:
        // ↩ lands on "Create link", and a stale draft would answer a
        // stray keystroke with a network call over a page (or a chip's
        // page) that no longer exists (issue #19). A chip is orphaned
        // when it survives on no live page: its host page has gone,
        // even if others remain. The core is authoritative here, even
        // for a page whose editor never mounted.
        if let draft = promotion {
            var liveChips: Set<UInt64> = []
            if case .chip = draft.target {
                liveChips = Set(sheets.flatMap { chipIds(onSheet: $0.id) })
            }
            if Self.isRefreshOrphan(
                target: draft.target, liveSheets: live, liveChips: liveChips
            ) {
                promotion = nil
            }
        }
        ledgerEntries = client.ledger()
        armEventTimer()
        // No hand-back when the last page dies while the surface is
        // key: keyed emptiness is a legal state (ADR-0005). The window
        // keeps the keyboard it was granted, the empty state's catcher
        // takes first responder, and Return conjures the next page.
        // Esc remains the way to give the keyboard back.
    }

    /// Which page holds the selection after the model reloads. A
    /// selection that still names a live page keeps it: the reload
    /// changed the world around the page, not the page itself. A
    /// selection whose page is gone (expiry, a close, a reorder that
    /// dropped it) falls to the first live page in tab order, the same
    /// page a nil selection seats, so the "it died" path and the
    /// "nothing was selected" path land together. An empty model
    /// selects nothing: the keyed-empty state ADR-0005's grants are
    /// built to hold. Pure, so the decision is testable without a
    /// window; `live` is ordered, so "first" is the first visible tab.
    public nonisolated static func reconciledSelection(current: UInt64?, live: [UInt64]) -> UInt64? {
        if let current, live.contains(current) { return current }
        return live.first
    }

    /// The page's document, created on first use. A page restored from
    /// the state file already has a document core-side; replay it into
    /// the fresh storage with the editor's own attributes, so restored
    /// ink and chips are indistinguishable from typed ones. A page born
    /// in this process replays as empty.
    public func storage(for id: UInt64) -> NSTextStorage {
        if let existing = storages[id] { return existing }
        let created = NSTextStorage()
        for run in client.documentRuns(sheet: id) {
            switch run {
            case .ink(let text):
                created.append(NSAttributedString(
                    string: text,
                    attributes: [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]
                ))
            case .chip(let info):
                created.append(NSAttributedString(attachment: ChipAttachment(info: info)))
            }
        }
        storages[id] = created
        return created
    }

    /// The page's undo history, created on first use. The editor asks
    /// its delegate for a manager on every undo touch, so history
    /// simply follows the current page — no hand-off at the swap
    /// (ADR-0006).
    public func undoManager(for id: UInt64) -> UndoManager {
        if let existing = undoManagers[id] { return existing }
        let created = UndoManager()
        undoManagers[id] = created
        return created
    }

    /// Discard every page's undo history. One editor serves all pages
    /// (ADR-0006), so every registered undo operation is bound to that
    /// single NSTextView. When the view is torn down — a ledger round
    /// trip, or the empty state after the last page dies — and a fresh
    /// editor later mounts, those cached managers still hold operations
    /// targeting the dead view: replaying one drives a zombie reference,
    /// not the live editor (issue #23). A mount clears them so ⌘Z after
    /// a remount is a clean no-op rather than a misfire. Page↔page
    /// swaps keep the same view and are untouched.
    public func discardUndoHistory() {
        undoManagers.values.forEach { $0.removeAllActions() }
    }

    // MARK: Navigation — the keyboard map

    public func select(_ id: UInt64) {
        let leavingLedger = showingLedger
        showingLedger = false
        selection = id
        if leavingLedger { refocusEditorIfKeyed() }
    }

    /// ⌘1–⌘9: jump by visible tab order.
    public func select(index: Int) {
        guard sheets.indices.contains(index) else { return }
        select(sheets[index].id)
    }

    /// ⌥⌘← / ⌥⌘→.
    public func step(_ delta: Int) {
        guard !sheets.isEmpty else { return }
        if showingLedger {
            showingLedger = false
            refocusEditorIfKeyed()
        }
        let current = sheets.firstIndex { $0.id == selection } ?? 0
        let next = Self.steppedIndex(from: current, by: delta, within: sheets.count)
        selection = sheets[next].id
    }

    /// The next tab index after a ⌥⌘←/→ step, clamped to the ends. A
    /// step off the last page holds on the last; a step off the first
    /// holds on the first, so the walk never wraps. `step` guards a
    /// non-empty list, so `count` is at least one and `count - 1` is a
    /// real index. Pure, so the clamp is testable without a window.
    public nonisolated static func steppedIndex(
        from current: Int, by delta: Int, within count: Int
    ) -> Int {
        precondition(count > 0, "steppedIndex needs a non-empty list; count - 1 is the last index")
        return min(max(current + delta, 0), count - 1)
    }

    /// ⌘0: the ledger.
    public func showLedger() {
        ledgerEntries = client.ledger()
        showingLedger = true
    }

    /// The ◌ tab is a toggle: click to visit the ledger, click again
    /// to return to the page.
    public func toggleLedger() {
        if showingLedger {
            showingLedger = false
            refocusEditorIfKeyed()
        } else {
            showLedger()
        }
    }

    /// The ledger's exit. Visiting the ledger unmounted the editor, so
    /// the page returns with the window key and nothing focused — the
    /// ember lit over typing that beeps (issue #19). When the window
    /// already holds the keys, pass them to the editor once it has
    /// remounted: that is a render pass after `showingLedger` flips,
    /// hence the turn's delay (ADR-0005's timing discipline). An
    /// unkeyed window is left alone — focusing would be *taking*, and
    /// the law only ever accepts.
    private func refocusEditorIfKeyed() {
        guard holdsKeys else { return }
        focusEditorWhenMounted(in: nil, requireKeys: true)
    }

    /// Hand the editor the keys once SwiftUI has mounted it. A page born
    /// this instant reaches `activeEditor` only a render pass after
    /// `selection` changes, and a single main-actor hop can land before
    /// that pass — finding `activeEditor` still nil, skipping the
    /// hand-off, and leaving the key window with no first responder so
    /// every keystroke beeps (the issue #19 symptom the grants exist to
    /// cure). Poll a bounded span of runloop turns instead: focus the
    /// moment the editor appears, give up quietly if it never does.
    /// `requireKeys` bails the instant the window stops holding the
    /// keys, so a focus meant for a keyed window never fires against one
    /// that handed the keyboard back mid-wait. `window` nil defers to
    /// the editor's own window. The first turn checks before waiting, so
    /// an already-mounted editor is focused with no delay.
    public func focusEditorWhenMounted(in window: NSWindow?, requireKeys: Bool = false) {
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self else { return }
                if requireKeys, !self.holdsKeys { return }
                if let editor = self.activeEditor {
                    (window ?? editor.window)?.makeFirstResponder(editor)
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Show `message` for a few seconds, then clear it — unless a newer
    /// notice replaced it in the meantime.
    public func flash(_ message: String) {
        notice = message
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
        }
    }

    /// Esc: leave the ledger if it is showing; otherwise hand the
    /// keyboard back.
    public func escape() {
        if showingLedger {
            showingLedger = false
            refocusEditorIfKeyed()
        } else {
            onHandBackKeys?()
        }
    }

    // MARK: Pages

    /// A new page at this form factor's opening rung. 0 means the store
    /// refused at the cap of 9.
    @discardableResult
    private func newSheet() -> UInt64 {
        let id = client.newSheet()
        if id != 0, let rung = formFactor.defaultRung {
            _ = client.setRung(sheet: id, rung: rung)
        }
        return id
    }

    /// A new page (⌥⌘N or the + tab). At the cap the app declines and
    /// says so.
    public func newPage() {
        notice = nil
        let created = newSheet()
        if created == 0 {
            flash("the window holds 9 pages — let one expire, or close one")
        }
        refresh()
        if created != 0 {
            // A new page cannot borrow a plain tab switch's assumption
            // that the editor still holds the keys (issue #22). A switch
            // keeps one persistent editor focused and swaps its content
            // beneath it, so `select` refocuses only when it leaves the
            // ledger. Conjuring a page can instead tear the mount whole:
            // an empty window's catcher gives way to a freshly built
            // editor, and the + tab is chrome whose click resigns first
            // responder before we arrive. Left to `select`'s conditional
            // refocus alone the page mounts with nothing focused and every
            // keystroke beeps, so this path always hands the editor the
            // keys once it appears. Set selection inline rather than
            // through `select`, whose own leaving-ledger refocus would
            // otherwise schedule a second, redundant focus poll here.
            // `refocusEditorIfKeyed` only ever accepts, staying a quiet
            // no-op on the switch paths where focus never left.
            showingLedger = false
            selection = created
            refocusEditorIfKeyed()
        }
    }

    /// The empty state's create-and-focus, shared by the third and
    /// fourth grants (ADR-0005): a click into the pageless surface's
    /// empty content area, or Return while it already holds the keys,
    /// creates the page and hands its editor the keyboard.
    /// The window is key by the time this runs (the click keyed it
    /// through `needsPanelToBecomeKey`; Return required it already),
    /// but the editor mounts a render pass after `selection` changes,
    /// so the focus call waits for the mount (`focusEditorWhenMounted`).
    /// Inlining a bare focus here would find `activeEditor` still nil
    /// and reintroduce the beep this grant exists to cure.
    public func createPageAndFocus(in window: NSWindow?) {
        // The grant promises one page, not one per keystroke: a rapid
        // second Return (or another create path that won the race before
        // SwiftUI unmounted the catcher) finds the model already peopled,
        // so focus the page that exists rather than stack a blank one.
        if sheets.isEmpty { newPage() }
        focusEditorWhenMounted(in: window)
    }

    /// Whether the empty state's catcher should hold first responder,
    /// which is the whole of the fourth grant's availability: yes
    /// exactly when the sheet list is empty while the window holds the
    /// keys. The grant spends key status an earlier grant conferred,
    /// never takes it; an unkeyed window still receives no keystrokes
    /// at all, so it has nothing to offer Return. Pure, so the
    /// decision is testable without a window.
    public nonisolated static func shouldOfferEnterCreate(
        sheetsEmpty: Bool, holdsKeys: Bool
    ) -> Bool {
        sheetsEmpty && holdsKeys
    }

    /// Close the page; it rests in the ledger. Closing also clears any
    /// standing refusal — the cap condition it named may be resolved.
    public func close(_ id: UInt64) {
        notice = nil
        // A draft aimed at this page — or at a chip riding on it —
        // dies with it. Left standing, the confirmation would still
        // answer ↩ ("Create link" carries the default action) with a
        // network call over a page that no longer exists (issue #19).
        // The chips must be asked for *before* the close; a dead page
        // replays no runs.
        if let draft = promotion,
           Self.shouldClearPromotion(
               target: draft.target,
               closingSheet: id,
               chipsOnSheet: chipIds(onSheet: id)
           ) {
            promotion = nil
        }
        _ = client.closeSheet(id: id)
        refresh()
    }

    /// Whether closing `closingSheet` orphans the open promotion
    /// draft: a draft for the page itself, or for a chip the page
    /// carries. A draft aimed elsewhere survives — its subject is
    /// still alive. Pure, so the decision is testable without a core.
    public nonisolated static func shouldClearPromotion(
        target: PromotionDraft.Target,
        closingSheet: UInt64,
        chipsOnSheet: Set<UInt64>
    ) -> Bool {
        switch target {
        case .page(let id): id == closingSheet
        case .chip(let id): chipsOnSheet.contains(id)
        }
    }

    /// Whether a refresh orphans the open promotion draft: its subject
    /// is no longer among the live pages. A page draft dies when its id
    /// drops from the live set; a chip draft dies when the chip rides
    /// on no live page — which is exactly when its host page has gone,
    /// whether it was the last page or one of several. Pure, so the
    /// decision is testable without a core.
    public nonisolated static func isRefreshOrphan(
        target: PromotionDraft.Target,
        liveSheets: Set<UInt64>,
        liveChips: Set<UInt64>
    ) -> Bool {
        switch target {
        case .page(let id): !liveSheets.contains(id)
        case .chip(let id): !liveChips.contains(id)
        }
    }

    /// The chips riding on a page, by id — asked of the core, which
    /// is authoritative even for a page whose editor never mounted.
    private func chipIds(onSheet id: UInt64) -> Set<UInt64> {
        Set(client.documentRuns(sheet: id).compactMap {
            if case .chip(let info) = $0 { info.chipId } else { nil }
        })
    }

    /// ⌘W closes what's showing, the macOS convention: the ledger view
    /// steps aside; a page goes to rest in the ledger.
    public func closeCurrent() {
        if showingLedger {
            showingLedger = false
            refocusEditorIfKeyed()
        } else if let id = selection {
            close(id)
        }
    }

    /// Drag-to-reorder: move `id` to `index` in visible order; the
    /// ⌘-number map follows.
    public func move(_ id: UInt64, to index: Int) {
        _ = client.moveSheet(id: id, to: UInt64(max(0, index)))
        refresh()
    }

    /// Click the countdown label: next rung, clock reset (docs/spec/04).
    public func cycleRung(_ id: UInt64) {
        _ = client.cycleRung(sheet: id)
        refresh()
    }

    /// Double-click the tab: hold the clock 1h, then top-up to 24h.
    public func pause(_ id: UInt64) {
        _ = client.pausePress(sheet: id)
        refresh()
    }

    // MARK: Sealing — called by the editor, which places the chip

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself,
    /// the content lands as an opaque chip, and the board is cleared
    /// in the same operation (ADR-0007 Amendment 1) — the app drains
    /// the pasteboard rather than avoiding it. Consent is the gesture.
    /// A take that could not clear is said out loud: a paste that
    /// leaves the secret on the board is the failure this route
    /// exists to prevent.
    public func sealPasteboard() -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        let (chip, cleared) = client.sealFromPasteboard(sheet: sheet)
        guard let chip else {
            flash("nothing to seal")
            return nil
        }
        pasteboardOffer = false
        flash(
            cleared
                ? "sealed; the clipboard is clear"
                : "sealed, but the clipboard changed mid-take and was left untouched")
        return chip
    }

    /// Reveal-time check for the offer: consult the core's probe once
    /// per reveal. Never a poll — the board is looked at exactly when
    /// the surface comes forward.
    public func refreshPasteboardOffer() {
        pasteboardOffer = client.pasteboardHasContent()
    }

    public func withdrawPasteboardOffer() {
        pasteboardOffer = false
    }

    /// Whether the offer row should show: the board must hold content
    /// and a page must be there to take it; the ledger is a reading
    /// surface, not an ingest one.
    public nonisolated static func shouldShowPasteboardOffer(
        boardHolds: Bool, hasPage: Bool, ledgerShowing: Bool
    ) -> Bool {
        boardHolds && hasPage && !ledgerShowing
    }

    /// Drop-to-seal: the core reads the drag pasteboard itself; the
    /// dropped bytes never transit this process.
    public func sealDrag() -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        let chip = client.sealFromDrag(sheet: sheet)
        if chip == nil { flash("nothing to seal") }
        return chip
    }

    /// ⌘↩: seal visible ink the editor already holds. The editor
    /// deletes its copy the moment this returns.
    public func sealText(_ text: String) -> ChipInfo? {
        notice = nil
        guard let sheet = selection else { return nil }
        return client.sealText(sheet: sheet, text)
    }

    /// Copy a chip back out — the core writes the pasteboard itself,
    /// marked transient + concealed; non-consuming.
    public func copyOutChip(_ id: UInt64) {
        _ = client.copyOutChip(id: id)
    }

    /// Mirror the page's document to the core (tab titles, the ledger,
    /// promotion) — and authoritative for chip liveness: a chip the
    /// snapshot omits was deleted in the editor and is zeroized there.
    public func syncDocument(sheet: UInt64, runs: [DocumentRun]) {
        let objects: [[String: Any]] = runs.map {
            switch $0 {
            case .ink(let text): ["ink": text]
            case .chip(let id): ["chip": id]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let accepted = client.syncDocument(sheet: sheet, json: json)
        assert(accepted, "core rejected a document snapshot")
        refresh()
    }

    // MARK: Promotion — the exit ramp

    /// Open the inline confirmation for a chip's ↗ or the footer's
    /// ↗ page. Everything after this is in-place: no modal, and the
    /// network boundary is the one confirming click.
    public func beginPromotion(_ target: PromotionDraft.Target) {
        notice = nil
        let sheetId: UInt64? = switch target {
        case .page(let id): id
        case .chip: selection
        }
        let remaining = sheets.first { $0.id == sheetId }?.remainingMs ?? 0
        promotion = PromotionDraft(
            target: target,
            ttlSecs: PromotionDraft.snappedTtl(remainingMs: remaining)
        )
    }

    /// The confirming click: one POST, off the main actor — the core
    /// releases its lock during the round-trip, so the surface stays
    /// live. On success the link is on the clipboard (written
    /// core-side) and the confirmation offers Burn local copy.
    public func confirmPromotion() {
        guard var draft = promotion, !draft.inFlight else { return }
        draft.inFlight = true
        draft.error = nil
        promotion = draft
        let client = self.client
        let target = draft.target
        let ttl = draft.ttlSecs
        let passphrase = draft.passphrase
        let recipient = draft.recipient
        Task.detached(priority: .userInitiated) {
            let outcome: PromotionOutcome = switch target {
            case .chip(let id):
                client.promoteChip(id: id, ttlSecs: ttl, passphrase: passphrase, recipient: recipient)
            case .page(let id):
                client.promoteSheet(id: id, ttlSecs: ttl, passphrase: passphrase, recipient: recipient)
            }
            await MainActor.run { [weak self] in
                self?.finishPromotion(outcome, for: target)
            }
        }
    }

    private func finishPromotion(_ outcome: PromotionOutcome, for target: PromotionDraft.Target) {
        // The confirmation may have been dismissed — or reopened on a
        // different target — while the call was out; a stale outcome
        // must not land on someone else's draft. (On success the link
        // is on the clipboard and the receipt marked either way.)
        guard var draft = promotion, draft.target == target else { return }
        draft.inFlight = false
        if outcome.ok {
            draft.error = nil
            draft.receiptId = outcome.receiptId
            flash("the link is on the clipboard")
        } else {
            // Inline, with retry; content never left the sheet.
            draft.error = outcome.error ?? "promotion failed"
        }
        promotion = draft
        refresh()
    }

    /// Success's one offer: the content travelled, so the local copy
    /// may go. A chip burns by leaving the document (the sync zeroizes
    /// it core-side); a page burns by closing (it rests in the ledger).
    public func burnPromotedCopy() {
        guard let draft = promotion, draft.receiptId != nil else { return }
        switch draft.target {
        case .chip(let id):
            removeChipFromDocument(id)
        case .page(let id):
            close(id)
        }
        promotion = nil
    }

    public func dismissPromotion() {
        promotion = nil
    }

    /// Remove a chip's attachment character from whichever page's
    /// document holds it, then mirror — the snapshot that omits the
    /// chip is what zeroizes it core-side.
    private func removeChipFromDocument(_ chipId: UInt64) {
        for (sheet, storage) in storages {
            var found: NSRange?
            storage.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if let chip = value as? ChipAttachment, chip.info.chipId == chipId {
                    found = range
                    stop.pointee = true
                }
            }
            guard let range = found else { continue }
            storage.replaceCharacters(in: range, with: "")
            // The storage changed behind the editor's back: the page's
            // undo history now points at offsets that may no longer
            // exist, and — as everywhere — undo must never resurrect
            // what was sealed and has now travelled. History dies.
            undoManagers[sheet]?.removeAllActions()
            syncDocument(sheet: sheet, runs: InkEditorView.Coordinator.runs(of: storage))
            return
        }
        // No storage holds it (already deleted editor-side): delete
        // directly so the bytes still die.
        _ = client.deleteChip(id: chipId)
        refresh()
    }

    // MARK: Connection (Settings)

    /// Save the connection. The token goes straight through the seam to
    /// the Keychain — nil keeps the stored one, "" deletes it; the rest
    /// persists as ordinary defaults. Returns false on a refused config
    /// (non-https URL).
    @discardableResult
    public func saveConnection(
        serverUrl: String, shareDomain: String, extid: String, token: String?
    ) -> Bool {
        let accepted = client.configureConnection(
            serverUrl: serverUrl, shareDomain: shareDomain, extid: extid, token: token
        )
        guard accepted else { return false }
        defaults.set(serverUrl, forKey: Self.serverKey)
        defaults.set(shareDomain, forKey: Self.shareDomainKey)
        defaults.set(extid, forKey: Self.extidKey)
        connection = client.connectionInfo()
        return true
    }

    /// Clear the stored API token: an empty string through the seam
    /// deletes it from the Keychain. The rest of the connection config is
    /// resent from the saved state (not the form's unsaved edits), so
    /// nothing else moves. Returns false only if the core refuses — it
    /// won't, since a valid https server is always configured.
    @discardableResult
    public func clearToken() -> Bool {
        guard let connection else { return false }
        let accepted = client.configureConnection(
            serverUrl: connection.serverUrl,
            shareDomain: connection.shareDomain,
            extid: connection.extid,
            token: ""
        )
        guard accepted else { return false }
        self.connection = client.connectionInfo()
        return true
    }

    /// The Settings test button: one status round-trip, off the main
    /// actor, result to `completion` on the main actor.
    public func testConnection(completion: @escaping @MainActor (PromotionOutcome) -> Void) {
        let client = self.client
        Task.detached(priority: .userInitiated) {
            let outcome = client.testConnection()
            await MainActor.run { completion(outcome) }
        }
    }

    // MARK: Timers

    /// The surface became visible: start the countdown redraw at
    /// `interval`. The panel shows at 1 Hz while revealed; the backdrop
    /// is always on screen and coarsens the cadence at rest instead.
    /// Restarting with a different interval is meaningful — it is how
    /// the backdrop's stance change retimes the clock — so a live timer
    /// at the wrong cadence is replaced rather than kept.
    public func startRedraw(interval: TimeInterval = 1.0) {
        if let redrawTimer, redrawTimer.timeInterval == interval { return }
        redrawTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSummaries() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// The surface is hidden: stop redrawing. The armed event timer is
    /// the only remaining wakeup.
    public func stopRedraw() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    /// The countdown's repaint: summaries only. Never `refresh()` —
    /// that re-arms timers and reconciles selection, work the clock
    /// tick has no business doing.
    private func refreshSummaries() {
        sheets = client.sheets()
    }

    /// Arm exactly one timer, at the core's next event — a page expiry
    /// or a hold lapse, whichever is first. When it fires, settle the
    /// clock and re-arm. No event → no timer.
    private func armEventTimer() {
        eventTimer?.invalidate()
        eventTimer = nil
        let ms = client.nextEventMs()
        guard ms >= 0 else { return }
        let timer = Timer(
            timeInterval: max(0.05, Double(ms) / 1000.0),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.client.expireDue()
                self?.refresh() // re-arms for the next event
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }
}
