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

/// The editing gesture represented by one operation batch. The raw values are
/// the C ABI contract in `companion_ffi.h`.
public enum EditorEditIntent: UInt32, Sendable {
    case typing = 0
    case deletion = 1
    case paste = 2
    case cut = 3
    case replacement = 4
    case automation = 5
    case composition = 6
}

/// The TextKit selection on both sides of one editor action.
public struct EditorEditSelection: Equatable, Sendable {
    public let before: NSRange
    public let after: NSRange

    public init(before: NSRange, after: NSRange) {
        self.before = before
        self.after = after
    }
}

/// One edit against a page's body, as the shell sends it to the core
/// (`companion_sheet_apply_ops`, ADR-0013). Every position and length
/// is a UTF-16 code unit, which is what `NSRange` already speaks, so
/// nothing is ever re-measured on the way to the wire.
public enum DocumentEditOp: Equatable, Sendable {
    case ins(at: Int, text: String)
    case del(at: Int, len: Int)
    case chip(at: Int, id: UInt64)

    /// The batch as the seam's wire JSON: an ordered array of
    /// single-key objects. Nil only when serialization itself refuses,
    /// which no op built from an `NSTextStorage` edit can trigger.
    public static func wireJSON(_ ops: [DocumentEditOp]) -> String? {
        let objects: [[String: Any]] = ops.map {
            switch $0 {
            case .ins(let at, let text): ["ins": ["at": at, "text": text]]
            case .del(let at, let len): ["del": ["at": at, "len": len]]
            case .chip(let at, let id): ["chip": ["at": at, "id": id]]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// An in-flight conceal: the inline, in-place confirmation's state
/// (docs/spec/04 — not a modal). Holds options and outcome, never
/// content: the payload stays core-side throughout.
public struct ConcealDraft {
    /// Sendable explicitly, not by inference: a public enum gets no
    /// implicit conformance, and this value is captured by the
    /// detached task that carries the conceal to the network.
    public enum Target: Equatable, Sendable {
        case chip(UInt64)
        case page(UInt64)
    }

    public let target: Target
    /// Requested TTL. It starts at the link's own default, seven days,
    /// which the core applies too when the shell sends nil (ADR-0011
    /// section 5). The page's remaining time is not an input: a link's
    /// lifetime is chosen as a link's lifetime (ADR-0026).
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

    /// The link's default TTL when the person chooses none: exactly
    /// seven days (ADR-0011 section 5). Not a rung of the page ladder,
    /// even though the picker happens to offer the same value.
    public static let defaultTtlSecs: UInt64 = 7 * 24 * 60 * 60
}

/// The hold ADR-0012 requires while the in-memory store differs from
/// the sealed file. macOS may kill a cooperating process outright at
/// logout or shutdown (no quit, no delegate, no flush), which is
/// exactly the window a debounced write leaves open, so a dirty buffer
/// takes the hold and only a write that settled gives it back.
///
/// Counted, because mutations arrive far faster than writes: a burst of
/// marks stacks into one hold, and the single write that follows
/// discharges all of them at once. Only the 0 → 1 and the n → 0
/// transitions reach `ProcessInfo`, and the depth floors at zero, so
/// the disable/enable pair can never go unbalanced. The two effects are
/// injectable so the balance is testable without AppKit and without
/// moving the test runner's own termination policy.
///
/// Load-bearing, not decorative: both bundles declare
/// `NSSupportsSuddenTermination`, which lowers the per-process counter
/// macOS starts at 1 down to 0 and makes each app a genuine
/// sudden-termination candidate. `disableSuddenTermination` then takes
/// the counter 0 → 1 and the matching enable returns it 1 → 0, so this
/// latch is what actually stands between a pending write and a logout
/// that kills the process where it sits. An unbalanced enable here
/// hands away a hold the model still needs; an unbalanced disable leaves
/// the machine waiting on a process with nothing left to write.
public struct SuddenTerminationLatch {
    /// Outstanding holds. Never negative.
    public private(set) var depth = 0

    private let disable: () -> Void
    private let enable: () -> Void

    public init(
        disable: @escaping () -> Void = { ProcessInfo.processInfo.disableSuddenTermination() },
        enable: @escaping () -> Void = { ProcessInfo.processInfo.enableSuddenTermination() }
    ) {
        self.disable = disable
        self.enable = enable
    }

    /// Take a hold. Only the first one reaches `ProcessInfo`.
    public mutating func acquire() {
        depth += 1
        if depth == 1 { disable() }
    }

    /// Give back every outstanding hold. One write flushes the whole
    /// buffer, so it answers every mark that asked for the hold;
    /// releasing one at a time would leave the process unkillable with
    /// nothing left to write. Releasing an empty latch is a no-op
    /// rather than an unbalanced enable.
    public mutating func release() {
        guard depth > 0 else { return }
        depth = 0
        enable()
    }

    /// Discharge on a save's outcome. A refused write leaves the buffer
    /// dirty with nowhere to go, and dropping the hold there would let
    /// logout kill the process over exactly the pages the hold exists
    /// to protect, so a failure keeps it.
    public mutating func settle(saved: Bool) {
        guard saved else { return }
        release()
    }
}

/// The debounce's bookkeeping, kept apart from the timer that runs it so
/// the two rules the ADR's loss window actually rests on are testable
/// without a run loop.
///
/// First rule, anchoring: the window belongs to the first mark of a
/// burst, not the last. A trailing debounce restarted on every mark
/// defers the write for as long as the marks keep coming, and marks come
/// one per typed character, so someone entering a long credential at any
/// pace faster than the interval would get no write at all until they
/// stopped. That is unbounded, and it is unbounded in exactly the case
/// the persistence exists for. Anchored, a burst costs one write no
/// later than `interval` after it began.
///
/// Second rule, generations: `Timer.invalidate` cannot recall a body
/// that has already fired, and the body hops to the main actor before it
/// writes, so between the fire and the hop a quit-time write can slip in
/// underneath it. Every deferred body carries the generation it was
/// armed with and stands down when a write has since moved it on, which
/// is what keeps quit a flush rather than a duplicate write.
public struct SaveSchedule {
    /// Bumped by every arm and every write; a deferred body holding an
    /// older value has been overtaken.
    public private(set) var generation = 0

    /// A write is armed and has not started yet.
    public private(set) var pending = false

    /// A mutation landed. Returns the generation the deferred write must
    /// carry when this call is the one that arms the timer, or nil when a
    /// write is already pending and the burst keeps the window its first
    /// mark opened.
    public mutating func arm() -> Int? {
        guard !pending else { return nil }
        pending = true
        generation += 1
        return generation
    }

    /// Whether a deferred body armed at `generation` may still run.
    public func isCurrent(_ generation: Int) -> Bool {
        pending && generation == self.generation
    }

    /// A write is starting. The window closes, and anything still queued
    /// behind an already-fired timer is stale from here.
    public mutating func begin() {
        pending = false
        generation += 1
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
/// What the surface says about the sealed files' currency: nothing at
/// all until the first mutation owes a write, then the write's own
/// lifecycle. `saved` is quiet and `failed` is loud, and a session whose
/// content licence is withheld shows the withholding instead of any of
/// these, because "saved" there would describe the ledger leg while the
/// pages go nowhere (issue #49).
public enum SaveStatus: Equatable, Sendable {
    /// No write owed yet this session.
    case idle
    /// A write is armed or in flight; the buffer differs from the file.
    case saving
    /// The last write settled; the files match the session.
    case saved
    /// The last write was refused and the retry is armed. Sticky: a
    /// fresh mutation does not talk over it, only a settle clears it.
    case failed
}

/// What the quit path learned from its flush. Settled state may terminate;
/// a refused write or an unsavable session holding new content keeps the app
/// running with its existing inline state visible.
public enum QuitSaveOutcome: Equatable, Sendable {
    /// Every owed write landed, or nothing was owed. Quit proceeds.
    case settled
    /// A write was attempted and refused; the pages are not on disk.
    case refused
    /// The content licence is withheld and the session accumulated
    /// work after the load, none of which was ever written. The writes
    /// that were owed, if any, settled.
    case unsavableWithContent
}

/// What a navigation gesture can land on (issue #79).
///
/// The strip has always offered exactly one kind of target, a durable
/// slot, and ⌘1 to ⌘9 and ⌥⌘←/→ indexed the strip directly. With the days
/// grouped by day they index days instead, and one of those days,
/// today, which is a place whether or not a page is standing in it,
/// answers to no slot at all. So the gestures route through this rather
/// than forking: one path, two readings, and no new command id.
///
/// No new id is not a convenience. `CommandID`'s raw values are
/// published contract, named in whatever `keymap.json` a user has
/// written, and a binding parked in `.tabStrip` would validate, log
/// `contextNotConsulted` and do nothing, because only `.editor` is
/// consulted. Reinterpreting the verbs the app already has under an
/// exclusive, default-off mode keeps the keyboard complete with no new
/// surface at all.
public enum SurfaceTarget: Equatable, Sendable {
    /// A slot, by its tab id: every target the strip has ever had.
    case tab(UInt64)
    /// Today, holding no page yet. Selecting it takes the shipped
    /// create path; nothing here is minted by being drawn (ADR-0017).
    case today
    /// An open file, by its tagged file id. A file is the second
    /// content class and not a Tab: it has no rung, no countdown and no
    /// day, so it addresses nothing on the strip's page side and
    /// carries its own id instead.
    case file(UInt64)
}

/// What a person chose to do about a file that changed on disk while
/// their own copy held unsaved edits.
/// A nonmodal offer to change an open file's presentation. The proposed mode
/// is not applied until a person chooses it.
public struct FileRenderSuggestion: Equatable, Sendable {
    public let fileID: UInt64
    public let mode: FileRenderMode

    public init(fileID: UInt64, mode: FileRenderMode) {
        self.fileID = fileID
        self.mode = mode
    }

    public var language: String {
        if case .source(let language) = mode { return language.capitalized }
        return mode.formatLabel
    }
}

public enum FileConflictResolution: Equatable, Sendable {
    /// Keep the buffer and overwrite the file on the next save.
    case keepMine
    /// Replace the buffer with the copy on disk.
    case takeTheirs
    /// Write the buffer somewhere else and leave the file alone.
    case saveAs
    /// Say where the file is now. Offered beside the three when the
    /// file is no longer at its path or cannot be read there. It is
    /// not a choice between the two copies: it finds the other copy,
    /// and the three are what choose afterwards if they still differ.
    case locate
}

/// The outcomes offered by the inline dirty-close banner, in visual order.
public enum FileCloseAction: CaseIterable, Equatable, Sendable {
    case save
    case discard
    case keepEditing

    public var label: String {
        switch self {
        case .save: return "Save file"
        case .discard: return "Discard changes"
        case .keepEditing: return "Keep editing"
        }
    }
}

/// A dirty file waiting for an inline close decision.
public struct PendingFileClose: Equatable, Sendable {
    public let fileID: UInt64
    public let name: String

    public init(fileID: UInt64, name: String) {
        self.fileID = fileID
        self.name = name
    }
}

/// Which pages the hybrid markdown preview and syntax highlighting reach.
/// `focusedOnly` preserves the older behavior where only the active editor
/// carried block labels, fence washes and token colors; `allPages` extends
/// the same styling to every visible day; `never` collapses the roll to
/// plain ink even where a file mode would ordinarily read as source.
public enum PreviewRenderingScope: String, CaseIterable, Codable, Sendable {
    case focusedOnly
    case allPages
    case never
}

/// Whether the page holding the keyboard has a step waiting in each
/// direction. Native Edit menu items ask the focused responder directly;
/// these published values serve any other undo affordance (issue #132).
///
/// An observable of its own rather than a published pair on the model,
/// for the reason `rollGeometry` is one: an answer that moves on every
/// keystroke should not redraw the page, the header and the status stack
/// behind it.
///
/// Nothing here is a cache of what a step would do. Both booleans are
/// the core's own answers, re-asked whenever the page under the editor,
/// its editability, or its history can have moved.
@MainActor
public final class LanguageActionAvailability: ObservableObject {
    @Published public private(set) var canDetect = false
    @Published public private(set) var canChoose = false
    @Published public private(set) var selectionIsEmpty: Bool?

    func stand(canDetect: Bool, canChoose: Bool, selectionIsEmpty: Bool?) {
        if self.canDetect != canDetect { self.canDetect = canDetect }
        if self.canChoose != canChoose { self.canChoose = canChoose }
        if self.selectionIsEmpty != selectionIsEmpty {
            self.selectionIsEmpty = selectionIsEmpty
        }
    }
}

@MainActor
public final class EditStepAvailability: ObservableObject {
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    /// Published only on a change, because the model re-asks on every
    /// refresh and the usual answer is the one already standing.
    func stand(canUndo: Bool, canRedo: Bool) {
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
    }
}

/// What Edit → Seal Selected Content greys itself out on: whether the
/// editor holds an editable page with a non-empty selection. Published
/// for the same reason as the two above, a SwiftUI menu item carries
/// its own target and is never validated down the responder chain.
///
/// Enablement is display, never a gate. A selection that holds a chip
/// leaves the item enabled and the click refuses out loud (D-08); a
/// disabled item would hide the refusal rather than say it.
@MainActor
public final class SealActionAvailability: ObservableObject {
    @Published public private(set) var canSeal = false

    func stand(canSeal: Bool) {
        if self.canSeal != canSeal { self.canSeal = canSeal }
    }
}

@MainActor
public final class PageModel: ObservableObject {
    /// What this form factor decides differently — where its Keychain
    /// items and sealed file live.
    public let formFactor: FormFactor

    public let pads: PadCatalog
    private var lastPadID = PadCatalog.scratchID
    private var lastPadsEnabled = false
    private var applicationContext: PadApplicationContext?

    /// The strip: one entry per durable tab, in visible order, whether
    /// or not the tab holds a page (ADR-0017). A tab whose page expired
    /// keeps its place here, named and empty.
    @Published public private(set) var tabs: [TabSummary] = []

    /// Every open file, in open order. A parallel array beside `tabs`
    /// rather than entries within it: files are never on the strip,
    /// never in the day roll and never synced, and
    /// keeping them out of `tabs` is what makes those facts structural
    /// rather than rules a reader has to remember.
    @Published public private(set) var openFiles: [FileSummary] = []

    /// The dirty file whose close request is awaiting an inline outcome.
    @Published public private(set) var pendingFileClose: PendingFileClose?
    private var selectionBeforePendingFileClose: UInt64?
    private var ledgerBeforePendingFileClose = false

    /// Presentation state is deliberately separate from `FileSummary`: the
    /// core owns file content and persistence, while these choices last only
    /// until this open file is closed or the app relaunches.
    @Published public private(set) var fileRenderModes: [UInt64: FileRenderMode] = [:]
    @Published public private(set) var fileRenderSuggestions: [UInt64: FileRenderSuggestion] = [:]
    private var explicitFileRenderModes: Set<UInt64> = []
    private var dismissedFileRenderSuggestions: Set<UInt64> = []
    private var fileContentRenderHints: [UInt64: FileRenderMode] = [:]
    private let fileLanguageDetection: LanguageDetectionService
    private var fileLanguageRequestIDs: [UInt64: UUID] = [:]

    /// The open file the surface is showing, by its tagged id, or nil
    /// while the surface is showing a page.
    ///
    /// A second selection rather than a value folded into `selection`,
    /// because the two answer different questions and both have to
    /// survive the other being moved: a person who reads a file and
    /// goes back to the roll expects the slot they left to still be the
    /// selected slot. Selecting any tab clears this, so the two are
    /// never both live.
    @Published public private(set) var selectedFile: UInt64? {
        didSet { if selectedFile != nil { expandedPageID = nil } }
    }

    /// What the surface is showing, as one value: the open file when
    /// one is selected, otherwise the selected slot, otherwise today.
    ///
    /// The header, the menu enablement and the two second readings of
    /// the save and close chords all ask this one question, so there is
    /// one answer for them to disagree about rather than four.
    public var activeTarget: SurfaceTarget {
        if let selectedFile { return .file(selectedFile) }
        if let selection { return .tab(selection) }
        return .today
    }

    /// The selected file's own summary, or nil when a page is showing.
    /// Nil also when the selection names a file the roster no longer
    /// holds, which is what a close leaves behind for the instant
    /// before the refresh lands.
    public var activeFile: FileSummary? {
        guard let selectedFile else { return nil }
        return openFiles.first { $0.id == selectedFile }
    }

    /// The active file's actual presentation. A file with no selection yet is
    /// plain text; filename hints are proposals, not a substitute for a mode.
    public var activeFileRenderMode: FileRenderMode {
        guard let selectedFile else { return .plainText }
        return fileRenderMode(for: selectedFile)
    }

    public func fileRenderMode(for id: UInt64) -> FileRenderMode {
        fileRenderModes[id] ?? .plainText
    }

    public var fileRenderSuggestion: FileRenderSuggestion? {
        guard let selectedFile else { return nil }
        return fileRenderSuggestions[selectedFile]
    }

    public func renderSuggestion(for id: UInt64) -> FileRenderSuggestion? {
        fileRenderSuggestions[id]
    }

    public func fileContentRenderHint(for id: UInt64) -> FileRenderMode? {
        fileContentRenderHints[id]
    }

    public func selectFileRenderMode(_ mode: FileRenderMode, for id: UInt64? = nil) {
        guard let id = id ?? selectedFile, openFiles.contains(where: { $0.id == id }) else { return }
        fileRenderModes[id] = mode
        explicitFileRenderModes.insert(id)
        dismissedFileRenderSuggestions.insert(id)
        cancelFileLanguageDetection(for: id)
        fileRenderSuggestions[id] = nil
    }

    public func keepFilePlainText(_ id: UInt64? = nil) {
        selectFileRenderMode(.plainText, for: id)
    }

    public func dismissFileRenderSuggestion(_ id: UInt64? = nil) {
        guard let id = id ?? selectedFile else { return }
        dismissedFileRenderSuggestions.insert(id)
        cancelFileLanguageDetection(for: id)
        fileRenderSuggestions[id] = nil
    }

    /// The visibly selected **tab**, the slot the editor shows a page
    /// from and the gestures act on. It is the tab's id and never the
    /// page's, because a slot the user is looking at may hold nothing.
    /// Nil only when no tabs exist.
    @Published public var selection: UInt64? {
        didSet { if selection != oldValue { expandedPageID = nil } }
    }

    /// The ledger tab is showing instead of a page.
    @Published public var showingLedger = false {
        didSet { if showingLedger { expandedPageID = nil } }
    }

    /// Temporary presentation state, scoped to the page being expanded.
    @Published private var expandedPageID: UInt64?

    struct PageExpansionReturn {
        let place: RollPlace?
    }
    // Shared with the mounted roll so a window handoff retains the return place.
    var pageExpansionReturn: PageExpansionReturn?

    public var canExpandPage: Bool {
        selectedPageID != nil && selectedFile == nil && !showingLedger
    }

    public var isPageExpanded: Bool {
        canExpandPage && expandedPageID != nil && expandedPageID == selectedPageID
    }

    public func togglePageExpansion() {
        guard canExpandPage else { return }
        if !isPageExpanded { pageExpansionReturn = nil }
        expandedPageID = isPageExpanded ? nil : selectedPageID
        refocusEditorIfKeyed()
    }

    /// The audit trail, newest first: refreshed on every `refresh()` and
    /// whenever the ledger is shown. Metadata only, never content.
    @Published public private(set) var ledgerEntries: [LedgerEntry] = []

    /// A refusal or status line the surface shows briefly ("nothing to
    /// seal"). When the app declines something it says so.
    @Published public var notice: String?

    /// How the current notice is drawn. Ember is for what needs acting
    /// on (design record, section 5); a notice that only reports what
    /// just happened, "the link is on the clipboard" or "long lines
    /// wrap", is a quiet line like any other. Set by `flash` alongside
    /// the words, so the two never disagree.
    @Published public private(set) var noticeTone: NoticeTone = .plain

    /// The two ways a notice can read: as information, or as something
    /// the person has to do something about.
    public enum NoticeTone: Equatable, Sendable {
        /// A fact about what just happened. Secondary ink.
        case plain
        /// A refusal that leaves work undone until the person acts,
        /// such as a save that did not reach disk. Ember ink.
        case actionable
    }

    /// The one thing a notice may offer to do about itself, drawn as a
    /// button beside the words: "Undo" after a removal. Set by `flash`
    /// with the words, cleared with them, so an action never outlives
    /// the line it belongs to.
    public struct NoticeAction {
        public let label: String
        public let perform: @MainActor () -> Void

        public init(label: String, perform: @escaping @MainActor () -> Void) {
            self.label = label
            self.perform = perform
        }
    }

    @Published public private(set) var noticeAction: NoticeAction?

    /// Notices are transient by contract: each `flash` restarts the
    /// clock, and the line clears itself unless a newer notice has
    /// taken its place. A line with an action stays longer, because a
    /// person has to find the button; a line that only reports stays
    /// long enough to be read.
    private var noticeGeneration = 0
    static let noticeDwell: TimeInterval = 4
    static let noticeDwellWithAction: TimeInterval = 12

    /// The state file existed and would not open, so the content
    /// licence is withheld and nothing typed this session reaches disk.
    /// Persistent for the whole run, unlike a notice: it ends only
    /// through `clearUnreadableStateFile`, the user's own discard
    /// (ADR-0016 section 7, issue #49).
    @Published public private(set) var contentRestoreRefused = false

    /// The ledger file existed and would not open, so the trail is not
    /// recording and will not on any later launch either, until the
    /// user clears the ledger in Settings (`clearLedger`). Persistent
    /// for the same reason as the content flag; quieter in the surface
    /// because no page is at stake.
    @Published public private(set) var ledgerRestoreRefused = false

    /// The write lifecycle the surface shows (issue #49). Moves in
    /// `markDirty` and `saveState` only, and deliberately not on the
    /// withheld-licence leg, where the two flags above own the story.
    @Published public private(set) var saveStatus: SaveStatus = .idle

    /// The quit the terminate path cancelled, if one stands: a refused
    /// write or an unsavable session, recorded so the surface can say
    /// what the quit would lose and offer to quit anyway. Set only by
    /// `offerQuitAnyway`; cleared when the reason goes away, a settled
    /// write for a refusal and the user's discard for an unsavable
    /// session. Never cleared by time: the line is a standing state,
    /// not a notice, because the condition is.
    @Published public private(set) var quitRefusal: QuitSaveOutcome?

    /// Which of the two content windows owns the live page content
    /// right now (ADR-0033). Published, so a surface's root view can ask
    /// whether it is the one and mount the page only when it is. The
    /// form factor resolves it (`PresentationOwner.resolve`) and moves
    /// it through `transferOwnership(to:)`, which is its only writer.
    /// The panel until somebody says otherwise, which is every launch:
    /// the editor window starts closed, and the closed rows of the
    /// shipped rule both answer the panel.
    @Published public private(set) var owner: PresentationOwner = .panel

    /// True while the owner's window holds the keyboard, which drives
    /// the editor's focus rules and, through `holdsKeys(on:)`, the
    /// ember border. A plain fact and not a claim on anything: the
    /// keyboard passing to Settings, About or a modal panel makes it
    /// false and moves neither `owner` nor `activeEditor`. Written
    /// through `reportKeys(_:from:)` by the owner's window controller
    /// from its key status.
    ///
    /// It is the owner's fact and says nothing of the other window. The
    /// focus rules may read it bare, because the editor they focus is
    /// the owner's. A surface that shows it must ask `holdsKeys(on:)`.
    @Published public private(set) var holdsKeys = false

    /// Whether this surface's own window holds the keyboard: it owns,
    /// and the owner's window is key. Both inputs are published, so a
    /// view that reads this redraws when either moves.
    public func holdsKeys(on surface: PresentationOwner) -> Bool {
        PresentationOwner.holdsKeyboard(surface, owner: owner, ownerHoldsKeys: holdsKeys)
    }

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
    /// and this model never places document content itself. The owner's
    /// editor installs it (`routeSealedPaste(_:from:)`).
    public private(set) var performSealedPaste: (() -> Void)?

    /// The inline conceal confirmation, when one is open.
    @Published public var concealDraft: ConcealDraft?

    /// Connection state for Settings and the conceal header (never
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

    /// Whether a line wider than the card wraps to the next row, or runs
    /// on with the page scrolling sideways to follow it. Persisted, and
    /// there is one wrap state rather than a stored default and a live
    /// override: Settings and ⌥Z set the same value, so the page opens
    /// however it was last left.
    @Published public var wrapsLines: Bool {
        didSet { defaults.set(wrapsLines, forKey: Self.wrapKey) }
    }
    private static let wrapKey = "wrapsLines"

    /// Whether the menu-bar menu includes the app build and linked Rust
    /// component versions. Persisted presentation preference; off by default.
    @Published public var showsVersionsInMenu: Bool {
        didSet { defaults.set(showsVersionsInMenu, forKey: Self.showsVersionsInMenuKey) }
    }
    private static let showsVersionsInMenuKey = "showsVersionsInMenu"

    /// Whether future eligible pastes are wrapped in Markdown fences when
    /// source detection returns a language. The accepted release gates in
    /// ADR-0029 are not complete, so visible detection remains development-only.
    public static var languageDetectionFeaturesAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether explicit fence labels color recognized source tokens. This is
    /// presentation only; fixed-width code typography remains when it is off.
    @Published public var syntaxHighlightingEnabled: Bool {
        didSet {
            guard syntaxHighlightingEnabled != oldValue else { return }
            defaults.set(syntaxHighlightingEnabled, forKey: Self.syntaxHighlightingKey)
            // Quiet renderings baked the old token colors into their
            // attributes; a live-mounted page is restyled by the coordinator
            // on its own published side.
            invalidateQuietRenderings()
        }
    }
    private static let syntaxHighlightingKey = "syntaxHighlightingEnabled"

    /// Which pages receive hybrid markdown preview and syntax highlighting.
    /// The default styles every visible day: the roll used to render quiet
    /// pages as plain text carrying only the base font, so a code fence
    /// walked out of the editor lost its wash and its keyword colors as
    /// soon as the caret left. Reserved is the option to hold that older
    /// behavior for a reader who prefers a quieter roll, and an option to
    /// turn markdown styling off outright.
    @Published public var previewRendering: PreviewRenderingScope {
        didSet {
            guard previewRendering != oldValue else { return }
            defaults.set(previewRendering.rawValue, forKey: Self.previewRenderingKey)
            // Any cached quiet ink was built to the old scope, so drop the
            // lot: the next reader rebuilds them under the new preference.
            invalidateQuietRenderings()
        }
    }
    private static let previewRenderingKey = "previewRendering"

    /// Posted when a rendering dependency (preview scope, syntax highlighting,
    /// typeface) moves and the quiet cache has been dropped. The roll listens
    /// so every visible quiet region is reseeded from the model at once, and
    /// the coordinator restyles the mounted page on its own published side.
    public static let quietRenderingsDidInvalidateNotification =
        Notification.Name("PageModel.quietRenderingsDidInvalidate")

    /// Whether detector-backed suggestions and automatic paste recognition may
    /// run. Off by default while detection remains an explicit opt-in.
    @Published public var languageDetectionEnabled: Bool {
        didSet { defaults.set(languageDetectionEnabled, forKey: Self.languageDetectionKey) }
    }
    private static let languageDetectionKey = "languageDetectionEnabled"

    /// This is a default-off editing preference in this form factor's defaults.
    /// Changing it does not inspect or rewrite existing text. Detection must also
    /// be enabled before this preference can affect a paste.
    @Published public var automaticallyFencePastes: Bool {
        didSet { defaults.set(automaticallyFencePastes, forKey: Self.automaticPasteFencingKey) }
    }
    private static let automaticPasteFencingKey = "automaticallyFencePastes"

    /// The family the page is set in, named the way the system names
    /// it ("Menlo", "JetBrains Mono"), the way an editor's buffer font
    /// is named. Empty means the system's monospaced face. Persisted;
    /// a family that is not installed is kept as typed and the page
    /// falls back to the system face until it is, so a font that
    /// arrives later is honoured without the setting being retyped.
    @Published public var fontFamily: String {
        didSet {
            let trimmed = fontFamily.trimmingCharacters(in: .whitespaces)
            if trimmed != fontFamily {
                fontFamily = trimmed
                return
            }
            defaults.set(fontFamily, forKey: Self.fontFamilyKey)
            applyTypeface()
        }
    }
    private static let fontFamilyKey = "fontFamily"

    /// The fixed-pitch family used for fenced code and, later, whole-file Source
    /// mode. Empty means System Monospaced. An unavailable or proportional
    /// family is retained as the preference but rendered with that fallback.
    @Published public var codeFontFamily: String {
        didSet {
            let trimmed = codeFontFamily.trimmingCharacters(in: .whitespaces)
            if trimmed != codeFontFamily {
                codeFontFamily = trimmed
                return
            }
            defaults.set(codeFontFamily, forKey: Self.codeFontFamilyKey)
            applyTypeface()
        }
    }
    private static let codeFontFamilyKey = "codeFontFamily"

    /// The page's base size in points. Persisted, and clamped to
    /// `InkStyle.Typeface.sizeRange` on the way in, so a slip in the
    /// field cannot leave a page nobody can read.
    @Published public var fontSize: Double {
        didSet {
            let clamped = Double(InkStyle.Typeface.clamp(CGFloat(fontSize)))
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Self.fontSizeKey)
            applyTypeface()
        }
    }
    private static let fontSizeKey = "fontSize"

    /// The two settings as the one value the styling reads.
    public var typeface: InkStyle.Typeface {
        InkStyle.Typeface(
            family: fontFamily,
            codeFamily: codeFontFamily,
            size: CGFloat(fontSize)
        )
    }

    /// Hand the typeface to the styling and forget every quiet day's
    /// rendering, which carried the old font in its attributes. The
    /// mounted page is restyled by the coordinator on the next pass
    /// (`applyTypeface`), which the published change provokes. Nothing
    /// is marked dirty: a font is how the page looks, not what it says,
    /// and a sealed generation for a size change would be the same
    /// mistake `showsTimeUnits` refuses.
    private func applyTypeface() {
        InkStyle.typeface = typeface
        invalidateQuietRenderings()
    }

    /// Drop every cached quiet rendering and tell the roll so it reseeds
    /// its visible regions from the model at once. Called whenever a
    /// rendering dependency moves under a page whose contents have not
    /// changed: preview scope, syntax-highlighting, typeface. Per-page
    /// content edits go through `invalidateQuietRendering(for:)` instead.
    private func invalidateQuietRenderings() {
        quietRenderings.removeAll()
        NotificationCenter.default.post(
            name: Self.quietRenderingsDidInvalidateNotification, object: self
        )
    }

    /// Whether a rung, when applied, rounds its deadline up to the next
    /// whole clock hour (rungs under a day) or local midnight (a day and
    /// up), by at most a day (ADR-0011 section 4). On unless turned
    /// off. The value is the shell's, in this form factor's defaults,
    /// and the core is told at launch and on every flip; the core
    /// consults it only when a rung is applied, so flipping it moves no
    /// deadline already set.
    @Published public var snapsToBoundaries: Bool {
        didSet {
            defaults.set(snapsToBoundaries, forKey: Self.graceSnapKey)
            client.setGraceSnap(snapsToBoundaries)
        }
    }
    private static let graceSnapKey = "snapsToBoundaries"

    /// Whether navigation represents the day each live page was born
    /// on, rather than the durable slot containing it (issue #79). A
    /// prototype, off until the user asks for it. Timeline navigation
    /// always appears vertically; Tabs navigation appears at the bottom.
    ///
    /// Persisted the way every other preference here is, and persisted
    /// nowhere else: this writes one boolean to `defaults` and never
    /// calls `markDirty()`. A mark would take the sudden-termination
    /// hold and arm a debounced ciphertext write, so looking at the same
    /// pages a second way would buy a fresh sealed generation every time
    /// the user changed their mind. Nothing else moves either, the
    /// projection reads `tabs` and calls no core mutator, which is what
    /// makes the toggle safe in both directions by construction rather
    /// than by care.
    ///
    /// The one thing that does move is where the selection is standing,
    /// and only on the way in. See `reconciledTimeSelection`: the mode
    /// draws no row for a slot holding no page, and the strip
    /// deliberately leaves a selection on one when the page expires
    /// under it. That is the state a user is most likely to flip this
    /// from (the selected page died overnight) and entering the mode
    /// with it would show a surface with nothing selected, no editor
    /// mounted and no row lit until something else happened to call
    /// `refresh()`. So the mode's own reconciliation runs at its own
    /// entrance, where the rule was always meant to apply.
    @Published public var showsTimeUnits: Bool {
        didSet {
            defaults.set(showsTimeUnits, forKey: Self.timeUnitsKey)
            // One direction, and one state. Leaving the mode gives the
            // strip back, and the strip draws every slot, so there is
            // nothing to fall off; and a selection this mode does draw
            // is returned unchanged, so the toggle cannot move a
            // selection the user can see either before or after it. It
            // mints nothing (`reconciledTimeSelection` never does) and
            // it marks nothing dirty, which is the whole of what
            // ADR-0020 asks a presentation preference to leave alone.
            if showsTimeUnits, !oldValue {
                selection = Self.reconciledTimeSelection(current: selection, projection: timeUnits)
            }
        }
    }
    private static let timeUnitsKey = "showsTimeUnits"

    /// Timeline uses the leading column; Tabs uses the bottom navigation.
    /// Older placement preferences are ignored in favor of these two layouts.
    public var showsPagesDownSide: Bool { showsTimeUnits }
    private static let retiredPagesDownSideKey = "showsPagesDownSide"

    /// How a page's birth time reads on the rail and in the gutters
    /// while pages are organized by day (`StreamNavigator.StampFormat`):
    /// the pattern every page reads in, and the finer one two pages
    /// born the same minute fall back to. A presentation preference
    /// like the layout preference above: it lives in UserDefaults and marks nothing
    /// dirty.
    @Published public var stampFormat: StreamNavigator.StampFormat {
        didSet {
            defaults.set(stampFormat.short, forKey: Self.stampShortKey)
            defaults.set(stampFormat.fine, forKey: Self.stampFineKey)
        }
    }
    private static let stampShortKey = "stampFormatShort"
    private static let stampFineKey = "stampFormatFine"

    /// ⌥Z. A page whose lines all fit shows no difference, so the toggle
    /// says what it did rather than leaving the keystroke looking dead.
    ///
    /// Not reachable while pages are organized by day; see
    /// `wrapIsFixedNotice` and the `.editorToggleWrap` arm of `perform`.
    public func toggleWrap() {
        wrapsLines.toggle()
        flash(wrapsLines ? "long lines wrap" : "long lines run on")
    }

    /// What ⌥Z says instead, while pages are organized by day (issue
    /// #79).
    ///
    /// The roll wraps every day whatever the preference says: a line
    /// that ran off the side of one day would run off the side of the
    /// roll, and a roll scrolling in two directions would have no honest
    /// anchor. So the chord cannot do the one thing it is for, and both
    /// of the alternatives to saying so are worse than a sentence, a
    /// dead key, or the stored preference rewritten under a surface that
    /// will not honour it, which hands horizontal mode back unwrapped
    /// for a keystroke whose effect the user was never shown.
    public static let wrapIsFixedNotice =
        "long lines always wrap while the days are showing"

    /// The rule, as a pure decision on the two facts a launch knows, so
    /// the release branch is testable from a debug test binary: a debug
    /// build always offers the capture opt-out, and a release build
    /// offers it only when the launch variable is set.
    public nonisolated static func offersCaptureOptOut(
        isDebugBuild: Bool,
        launchVariableSet: Bool
    ) -> Bool {
        isDebugBuild || launchVariableSet
    }

    /// Whether the running app was compiled with assertions, i.e. is a
    /// debug build. The one place the configuration is read.
    public nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var captureVariableSet: Bool {
        ProcessInfo.processInfo.environment["COMPANION_ALLOW_CAPTURE"] != nil
    }

    /// Whether the capture opt-out is reachable at all in this process:
    /// the switch is available for diagnosing the installed app and is
    /// absent from Settings for anyone who did not deliberately ask for
    /// it. Decided once at launch, so nothing in the running app can
    /// turn the offer on.
    public static let captureOptOutOffered = offersCaptureOptOut(
        isDebugBuild: isDebugBuild,
        launchVariableSet: captureVariableSet
    )

    /// Lifts the capture exclusion so the surface can be screenshotted
    /// while diagnosing the UI. Deliberately NOT persisted: a security
    /// opt-out fails closed at every launch. The launch variable both
    /// reveals the switch and seeds it on, so a scripted run needs no
    /// click; without the variable a release build leaves this false
    /// and offers no way to change it.
    @Published public var allowCapture =
        PageModel.captureOptOutOffered && PageModel.captureVariableSet

    /// The live editor view, so a summon can hand it the keyboard.
    /// Weak and non-published: view plumbing, not state.
    ///
    /// The Edit menu's enablement is a function of it, so a mount or an
    /// unmount re-asks. On the next turn of the loop rather than now:
    /// every assignment happens inside a SwiftUI update pass, and
    /// publishing from inside one is what the runtime warns about.
    ///
    /// Always the owner's editor or nothing. A mount announces itself
    /// through `mountEditor(_:from:)` and lets go through
    /// `retireEditor(_:)`.
    public private(set) weak var activeEditor: NSTextView? {
        didSet { scheduleEditStepsRefresh() }
    }

    /// What the Edit menu's language actions read as the selection moves.
    public let languageActions = LanguageActionAvailability()

    /// What the Edit menu's Undo and Redo read as right now.
    public let editSteps = EditStepAvailability()

    /// What Edit → Seal Selected Content reads as the selection moves.
    public let sealActions = SealActionAvailability()

    /// Set by the app delegate; Esc routes here when no editor holds
    /// the keys (the controller re-keys the frontmost app's window).
    public var onHandBackKeys: (() -> Void)?

    /// Set by the app delegate; ⌘, routes here (the delegate owns the
    /// Settings window, the surface merely asks for it).
    public var onOpenSettings: (() -> Void)?

    /// Set by the roll while it is mounted: put the clip back on Day 0
    /// (issue #79). Nil in horizontal mode, where there is one page in
    /// the clip and no roll to anchor.
    ///
    /// A closure rather than a Combine sink, for what the surface has to
    /// do with it. Re-anchoring is one instant clip move at one moment (a
    /// summon), and a publisher would mean a subscription to keep
    /// alive, a value to invent for it, and an anchor that could fire on
    /// a pass nobody asked for. The mounted surface hands the model a
    /// way to reach it (`installTodayAnchor(_:from:)`), and the model
    /// drops it when ownership moves.
    public private(set) var onAnchorToday: (() -> Void)?

    /// What the keyboard does, resolved once at launch from the bundled
    /// default keymap and whatever override the user wrote
    /// (`Keymap.load(userOverride:)`). Read by the surface, which
    /// installs the chords it carries, and by the page's own text view,
    /// which answers the rest. Held here because both of them already
    /// hold the model, and because one resolution shared is the only
    /// way the two routes can be guaranteed to agree.
    public private(set) var keymap: ResolvedKeymap

    private let client: CompanionClient
    private let defaults: UserDefaults

    /// The sync driver (issues #98 and #102): the off switch, the
    /// sign-in ceremony, the engine loop and the pairing flow, over
    /// the same seam client. Off by default, and started only after
    /// the restore (`loadStateIfNeeded`), so sync never races the
    /// pages it would publish. Its own `ObservableObject`, observed
    /// directly by the views that render it.
    public let sync: SyncController

    /// Where the days stand in the roll and what part of it is on
    /// screen, published by the roll for the rail's minimap alone
    /// (issue #131).
    ///
    /// An observable of its own rather than a `@Published` field here,
    /// because the viewport moves on every scroll event and a change
    /// published on the model would redraw the header, the status stack
    /// and the page along with the minimap. It carries rectangles and
    /// never ink: nothing about a page's content can reach the rail
    /// through it.
    public let rollGeometry = RollGeometryModel()

    /// Test-only visibility onto the seam client, so parity between
    /// the projection and the core's document can be asserted from
    /// outside without a second handle.
    var coreClient: CompanionClient { client }

    /// Each live page's document, shell-side, **keyed by page identity
    /// and never by tab** (ADR-0017): the ink is ordinary text in an
    /// `NSTextStorage`; chips appear as attachment characters carrying
    /// only ids and excerpts. Pruned when pages die.
    ///
    /// The key is the whole mitigation for the split's one real
    /// correctness trap. A tab outlives every page it holds, so a map
    /// keyed by the slot would hand a replacement page the dead one's
    /// storage, and an attachment character for a zeroized chip would
    /// sit there within reach of ⌘Z, the exact resurrection ADR-0009
    /// closed.
    private var storages: [UInt64: NSTextStorage] = [:]

    /// Each page's caret and scroll, keyed and pruned with `storages`.
    ///
    /// Here rather than in the editor's coordinator because a page can
    /// be mounted by more than one editor over its life, and across two
    /// windows (ADR-0033): whichever mounts it next has to find the
    /// place the last one left. Written by the editor on the way off a
    /// page and read on the way onto one; nothing draws from it, so it
    /// is deliberately not published.
    var viewStates = PageViewStates()

    /// Each visible day's page as the roll renders it while the editor
    /// is standing somewhere else (issue #79): the same ink and the same
    /// chip faces, in an attributed string the quiet regions copy into
    /// their own private storages.
    ///
    /// Keyed by page identity and pruned with `storages`, for the same
    /// reason. Held here rather than in the view because the roll
    /// rebuilds its regions whenever the day model moves and a rendering
    /// rebuilt per pass would ask the core for every visible day's
    /// document on every keystroke.
    ///
    /// Sound to cache because every path that changes a page's document
    /// drops that page's entry on its way through
    /// (`invalidateQuietRendering(for:)`), so the rendering a page comes
    /// back with is built after the last edit it took rather than before
    /// the first. The invalidation is at the mutation (an accepted op
    /// batch, a wholesale mirror, a chip burned out of a document), and
    /// deliberately not at the roll's swap, because a page can change
    /// while the roll is not the surface on screen at all, or while it
    /// is and the editor is standing on another day. A cache invalidated
    /// by a view's choreography is a cache that is correct only on the
    /// paths somebody thought of.
    private var quietRenderings: [UInt64: QuietRendering] = [:]

    /// Manual or inferred fence-language labels a page carries in its
    /// presentation state, per bare-fence opening paragraph. Keyed by
    /// page identity, then by the paragraph location of the opening
    /// rule; the value is the language name a user picked or the
    /// detector inferred. Presentation only: the fence characters and
    /// the block above the language name are unchanged, and nothing in
    /// the core moves. Pruned alongside `quietRenderings` when a page
    /// dies, and dropped for a page on any structural rewrite.
    private var fenceRenderingLanguages: [UInt64: [Int: String]] = [:]

    /// The slot a selection gesture last minted a page into, and the
    /// monotonic reading at which it did. Read by `pause` alone, so a
    /// double-click on an empty slot cannot mint a page with its first
    /// tap and freeze that page's countdown with its second
    /// (ADR-0017). Nil the rest of the time, which is every gesture
    /// that landed on a slot already holding a page.
    private var mintedBySelection: (tab: UInt64, at: TimeInterval)?

    // nonisolated(unsafe): deinit is always nonisolated, even on a
    // @MainActor class (Swift 6), and Timer isn't Sendable. Safe here —
    // Timer.invalidate() is documented thread-safe, and every other
    // touch of these properties already runs on the main actor.
    private nonisolated(unsafe) var eventTimer: Timer?
    private nonisolated(unsafe) var redrawTimer: Timer?
    private nonisolated(unsafe) var saveTimer: Timer?
    /// The clear-after-copy: one shot, armed on every pasteboard
    /// egress, re-armed rather than doubled when a second egress lands
    /// inside the window. Its firing is the guarded clear, which takes
    /// nothing the user copied since.
    private nonisolated(unsafe) var clipboardClearTimer: Timer?

    // nonisolated(unsafe) for the same reason as the timers: deinit is
    // nonisolated even on a @MainActor class, and deinit is where a
    // model that dies dirty gives its hold back. Every other touch is on
    // the main actor, and the two effects it calls (`ProcessInfo`) are
    // themselves thread-safe.
    //
    /// Held from the first mutation after a write until the next write
    /// settles the file (ADR-0012).
    private nonisolated(unsafe) var terminationLatch = SuddenTerminationLatch()

    /// The debounce's state, separate from the timer running it: which
    /// deferred write is current, and whether one is already armed. See
    /// `SaveSchedule` for why both matter.
    private var saveSchedule = SaveSchedule()

    /// The debounce ADR-0012 states as a tradeoff rather than a free
    /// win: shorter shrinks the crash-loss window, longer leaves fewer
    /// ciphertext generations behind on disk (each atomic replace
    /// unlinks the prior one, it does not erase it). Measured from the
    /// first mutation of a burst, so it is the whole loss window and not
    /// a per-keystroke restart. Private once more: a seam left nil
    /// resolves to this inside the init body, the one place the
    /// visibility rule on a public init's default arguments cannot
    /// reach.
    private static let saveDebounce: TimeInterval = 2.0

    /// The window this instance actually runs: the shipping value above
    /// unless the caller injected a shorter one at init, which only a
    /// test does. The round-trip suite lets the real timer fire rather
    /// than calling the write by hand, and it should not spend two
    /// seconds per test doing it.
    private let saveDebounce: TimeInterval

    /// Where this model's two sealed files rest: the form factor's own
    /// locations unless the caller pointed the model elsewhere at init,
    /// which again only a test does. The whole persistence cycle has
    /// to be drivable inside a temporary directory the test owns.
    private let stateFileURL: URL
    private let ledgerFileURL: URL

    /// The third sealed file, resolved from the same seam so a test
    /// derives it from the directory it owns rather than spelling the
    /// name. The core finds it by that name beside the state file, so
    /// a test that spelled its own would be testing a path the app
    /// never writes.
    private let draftsFileURL: URL

    /// The user's keymap file, resolved once from the same seam the
    /// launch-time load consulted. Nil under the test runner unless a
    /// seam named one, matching `userKeymapURL`'s rule.
    private let userKeymapFileURL: URL?

    /// The interval after a refused write. Longer than the debounce: a
    /// full volume or a denied Keychain prompt does not clear in two
    /// seconds, and retrying at the debounce cadence would spend the
    /// session hammering a path that keeps saying no.
    private static let saveRetryDebounce: TimeInterval = 10.0

    /// The retry window this instance actually runs, on the same terms
    /// as `saveDebounce`: the shipping value unless a test injected a
    /// shorter one. A test that waits out the real one spends ten
    /// seconds of wall clock proving something about a window whose
    /// length is not the claim; what is the claim is that the window
    /// exists, that it absorbs what is typed inside it, and that the
    /// retry at its far end needs no further gesture.
    private let saveRetryDebounce: TimeInterval

    /// The clear-after-copy window a test shortened, or nil for the
    /// core's own interval (`CompanionClient.clipboardClearSeconds`).
    private let clipboardClearDebounce: TimeInterval?

    /// The receipt-guarded clear itself. Shipping construction always
    /// delegates to the core; the seam lets timer and teardown behavior
    /// be asserted without touching the developer's clipboard.
    private let clearClipboardIfOurs: @Sendable () -> Bool

    /// The init's test seams, gathered into one struct so the shipping
    /// signature stays narrow however many seams the tests grow. Each
    /// member is optional and nil means the shipping value: a
    /// `stateDirectory` moves the sealed files out of the form
    /// factor's own locations and into a directory the test owns, a
    /// `client` substitutes a core handle whose credentials never
    /// reach the Keychain (the test target's
    /// `CompanionClient.ephemeral(tag:)` extension, ADR-0018), and a
    /// `saveDebounce` shortens the window so the real timer can fire
    /// inside a test's patience, and a `saveRetryDebounce` does the
    /// same for the longer window a refused write opens. The default
    /// instance leaves all four alone, which is exactly the
    /// construction every shipping call site performs.
    public struct Seams {
        let stateDirectory: URL?
        let client: CompanionClient?
        let saveDebounce: TimeInterval?
        let saveRetryDebounce: TimeInterval?
        let fileLanguageDetection: LanguageDetectionService?
        /// The user keymap a test wants read, if any. This one reads
        /// differently from its neighbours: nil under the runner means
        /// *no override at all*, rather than the shipping path, and it
        /// says so on its own rather than by watching a neighbour
        /// (`PageModel.userKeymapURL(formFactor:seam:underTests:)`).
        /// A suite that fell back to the shipping path would resolve
        /// the installed app's own configuration directory and start
        /// passing or failing on whatever the person running the tests
        /// happens to have bound, which is not a test.
        let keymapOverride: URL?
        /// A shorter window for the clear-after-copy timer, so a test
        /// can watch it fire. The number the confirmation line names
        /// is never this one: that is always the core's constant, and
        /// only the timer's wait is shortened.
        let clipboardClearDebounce: TimeInterval?
        let clearClipboardIfOurs: (@Sendable () -> Bool)?
        /// What a declined presentation write does besides being
        /// declined and logged. Nil is the shipping answer, a debug
        /// assertion, which a test process cannot walk into; a suite
        /// that wants to watch the refusal hands in a recorder. The
        /// write is declined either way: the seam replaces the trap and
        /// never the verdict.
        let declinedPresentationWrite: (@MainActor (PresentationField, PresentationOwner) -> Void)?

        public init(
            stateDirectory: URL? = nil,
            client: CompanionClient? = nil,
            saveDebounce: TimeInterval? = nil,
            saveRetryDebounce: TimeInterval? = nil,
            keymapOverride: URL? = nil,
            fileLanguageDetection: LanguageDetectionService? = nil,
            clipboardClearDebounce: TimeInterval? = nil,
            clearClipboardIfOurs: (@Sendable () -> Bool)? = nil,
            declinedPresentationWrite: (
                @MainActor (PresentationField, PresentationOwner) -> Void
            )? = nil
        ) {
            self.stateDirectory = stateDirectory
            self.client = client
            self.saveDebounce = saveDebounce
            self.saveRetryDebounce = saveRetryDebounce
            self.keymapOverride = keymapOverride
            self.fileLanguageDetection = fileLanguageDetection
            self.clipboardClearDebounce = clipboardClearDebounce
            self.clearClipboardIfOurs = clearClipboardIfOurs
            self.declinedPresentationWrite = declinedPresentationWrite
        }
    }

    /// Which user keymap a launch reads: the file a test named, and
    /// the form factor's own otherwise.
    ///
    /// The keymap seam is the only thing that decides it. The state
    /// directory's seam used to, which made a model seamed for its
    /// files but not for its keymap read the installed user's file, and
    /// a suite that passes or fails on whatever the person running it
    /// happens to have bound is not a suite. Under the runner the
    /// shipping path is refused outright rather than merely unused, so
    /// no future seam can put that coupling back by accident.
    static func userKeymapURL(
        formFactor: FormFactor,
        seam: URL?,
        underTests: Bool = FormFactor.runningUnderTests
    ) -> URL? {
        if let seam { return seam }
        return underTests ? nil : formFactor.userKeymapFileURL
    }

    /// `defaults` is injectable so tests can point at a throwaway
    /// domain; both shipping form factors take their own standard one
    /// (`FormFactor.settingsDefaults`). Everything else a test would
    /// reach for lives in `Seams`, whose default instance resolves to
    /// exactly the values the shipping construction always had.
    public init(
        formFactor: FormFactor,
        defaults: UserDefaults = FormFactor.settingsDefaults,
        seams: Seams = Seams()
    ) {
        // Ahead of everything, including the diagnostics route, because
        // this is the one narrow place where a test run can be pointed
        // at the installed app's own data. The four lines below resolve
        // the sealed files and the Keychain service, and with no seams
        // they resolve to the shipped ones, which under the runner is
        // never what the author meant: a model built that way reads the
        // user's pages, writes over their sealed file on the debounce,
        // and can erase their ledger outright. Under a shipping bundle
        // the answer is a bundle-identifier prefix test that says no, so
        // the launch path is exactly what it was.
        if FormFactor.refusesProductionStateUnderTests(
            seamsInjected: seams.stateDirectory != nil && seams.client != nil
        ) {
            preconditionFailure(
                """
                a test built a PageModel on the shipping state directory and Keychain \
                service, which belong to the installed app and to the person running it. \
                Pass PageModel.Seams(stateDirectory:client:) with a directory the test \
                owns and CompanionClient.ephemeral(tag:), whose credentials stay in \
                process memory. Both seams are required: a directory alone still mints \
                keys in the login Keychain, and a client alone still writes the \
                installed app's files.
                """
            )
        }
        // Before the first call into the core, so nothing it refuses on
        // the way up is written to a stderr this process may not have.
        CoreDiagnostics.route(subsystem: formFactor.loggerSubsystem)
        self.formFactor = formFactor
        self.defaults = defaults
        pads = PadCatalog(defaults: defaults)
        let resolvedClient =
            seams.client ?? CompanionClient(credentialService: formFactor.credentialService)
        client = resolvedClient
        clearClipboardIfOurs = seams.clearClipboardIfOurs ?? {
            resolvedClient.clearClipboardIfOurs()
        }
        fileLanguageDetection = seams.fileLanguageDetection ?? LanguageDetectionService()
        stateFileURL = seams.stateDirectory.map(FormFactor.stateFileURL(in:))
            ?? formFactor.stateFileURL
        ledgerFileURL = seams.stateDirectory.map(FormFactor.ledgerFileURL(in:))
            ?? formFactor.ledgerFileURL
        draftsFileURL = seams.stateDirectory.map(FormFactor.draftsFileURL(in:))
            ?? formFactor.draftsFileURL
        saveDebounce = seams.saveDebounce ?? Self.saveDebounce
        saveRetryDebounce = seams.saveRetryDebounce ?? Self.saveRetryDebounce
        clipboardClearDebounce = seams.clipboardClearDebounce
        declinedPresentationWrite = seams.declinedPresentationWrite
        logger = Logger(subsystem: formFactor.loggerSubsystem, category: "persistence")
        ownershipLogger = Logger(subsystem: formFactor.loggerSubsystem, category: "ownership")
        // Resolved once, here, so the surface and the page's text view
        // are answering out of one map. A test reads only the override
        // it named, which for most of them is none.
        let resolvedKeymapURL = Self.userKeymapURL(
            formFactor: formFactor, seam: seams.keymapOverride)
        userKeymapFileURL = resolvedKeymapURL
        keymap = Keymap.load(userOverride: resolvedKeymapURL)
        keymap.report(subsystem: formFactor.loggerSubsystem)
        // Unset → float on top, matching the original behavior.
        floatsOnTop = defaults.object(forKey: Self.floatsKey) as? Bool ?? true
        // Unset → wrap, which is how every plain-text editor opens and
        // the only sane default for a card this narrow.
        wrapsLines = defaults.object(forKey: Self.wrapKey) as? Bool ?? true
        // Unset → off. Technical build details stay in About until explicitly
        // requested in the menu-bar menu.
        showsVersionsInMenu =
            defaults.object(forKey: Self.showsVersionsInMenuKey) as? Bool ?? false
        // Unset → current highlighting behavior, while detector-backed actions
        // and automatic edits remain explicit opt-ins.
        syntaxHighlightingEnabled =
            defaults.object(forKey: Self.syntaxHighlightingKey) as? Bool ?? true
        // Unset → all pages styled. The older reading (focused page only,
        // quiet days rendered as plain ink) is kept as a scope, not the
        // default: a fence that stays a fence off the caret is what the
        // eye expects of a page it can already read.
        previewRendering = (defaults.string(forKey: Self.previewRenderingKey)
            .flatMap(PreviewRenderingScope.init(rawValue:))) ?? .allPages
        languageDetectionEnabled =
            defaults.object(forKey: Self.languageDetectionKey) as? Bool ?? false
        automaticallyFencePastes =
            defaults.object(forKey: Self.automaticPasteFencingKey) as? Bool ?? false
        // Unset → System Monospaced for both roles at 13 points. Handed to
        // styling here because property observers do not run during init.
        let typeface = InkStyle.Typeface(
            family: defaults.string(forKey: Self.fontFamilyKey) ?? InkStyle.Typeface.standard.family,
            codeFamily: defaults.string(forKey: Self.codeFontFamilyKey)
                ?? InkStyle.Typeface.standard.codeFamily,
            size: CGFloat(
                defaults.object(forKey: Self.fontSizeKey) as? Double ?? Double(InkStyle.Typeface.standard.size)
            )
        )
        fontFamily = typeface.family
        codeFontFamily = typeface.codeFamily
        fontSize = Double(typeface.size)
        // Unset → off. A prototype is something a user turns on, and an
        // upgrade must not rearrange the pad of somebody who never
        // asked for a second way of looking at it (issue #79).
        let showsTimeUnits = defaults.object(forKey: Self.timeUnitsKey) as? Bool ?? false
        self.showsTimeUnits = showsTimeUnits
        // Placement follows the layout now, so the retired independent
        // placement key is dropped rather than left for a later read
        // to resurrect.
        defaults.removeObject(forKey: Self.retiredPagesDownSideKey)
        // Unset → the standard patterns, "HH:mm" and "HH:mm:ss".
        stampFormat = StreamNavigator.StampFormat(
            short: defaults.string(forKey: Self.stampShortKey)
                ?? StreamNavigator.StampFormat.standard.short,
            fine: defaults.string(forKey: Self.stampFineKey)
                ?? StreamNavigator.StampFormat.standard.fine
        )
        // Unset → on (ADR-0011 section 4). Told to the core here because
        // a property observer does not run during init.
        let snapsToBoundaries = defaults.object(forKey: Self.graceSnapKey) as? Bool ?? true
        self.snapsToBoundaries = snapsToBoundaries
        self.client.setGraceSnap(snapsToBoundaries)
        InkStyle.typeface = typeface
        // No pages yet: the restore is the caller's to time
        // (`loadStateIfNeeded`). The panel defers it to the first
        // reveal, so launching at login never raises a Keychain prompt
        // for a window nobody asked to see (ADR-0004); the backdrop,
        // which is on screen from launch, spends it there instead.
        // The connection outlives the process in two non-secret halves:
        // config in UserDefaults, the token in the Keychain (core-side).
        // Configuring with a nil token keeps whatever the Keychain
        // holds, so a guest conceal works with zero setup and a saved
        // token survives relaunch.
        _ = self.client.configureConnection(
            serverUrl: defaults.string(forKey: Self.serverKey) ?? Self.defaultServer,
            shareDomain: defaults.string(forKey: Self.shareDomainKey) ?? "",
            extid: defaults.string(forKey: Self.extidKey) ?? "",
            token: nil
        )
        connection = self.client.connectionInfo()
        sync = SyncController(client: client, defaults: defaults)
        sync.serverUrlProvider = { [weak self] in self?.connection?.serverUrl ?? "" }
        // A peer's edit both shows and persists: the refresh redraws
        // what the core now holds, and the dirty mark schedules the
        // sealed write exactly as a local keystroke would.
        sync.onRemoteChange = { [weak self] in
            self?.markDirty()
            self?.refresh()
        }
        lastPadID = pads.activeID
        lastPadsEnabled = pads.isEnabled
        pads.onChange = { [weak self] in self?.padCatalogChanged() }
        updateApplicationContextObservation()
        modalEndObserver = NotificationCenter.default.addObserver(
            forName: ModalSession.didEndNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // ModalSession posts synchronously on the main actor. A file
            // panel's answer is not processed yet; its gesture drains the
            // owed check instead, after it has finished with that answer.
            MainActor.assumeIsolated { self?.consumeOwedActivationCheck() }
        }
    }

    /// The one route to a system file panel, a bookmark, a security
    /// scope or a save's staging directory.
    ///
    /// `lazy` so no panel object is built at init, and `var` so a test
    /// can put scripted panels in its place. It is not in `Seams`
    /// because nothing here is resolved during the init that `Seams`
    /// exists to steer: a panel is raised by a gesture, long after the
    /// model is standing, so a plain settable property is the whole of
    /// what the injection needs.
    public lazy var fileCoordinator = FileCoordinator()

    /// How many gestures that raise a file panel are under way: an
    /// open, a Save As or a locate, from the panel going up until the
    /// gesture has finished with its answer. A count and not a flag
    /// because a locate can be reached from inside another gesture.
    private var filePanelGestures = 0

    /// Whether an activation asked for the file check during a modal
    /// bracket or file-panel gesture. Consumed when both are over.
    private var activationCheckOwed = false

    // removeObserver is thread-safe; every other access is main-actor
    // isolated, but Swift 6 deinit is nonisolated.
    private nonisolated(unsafe) var modalEndObserver: NSObjectProtocol?

    /// Whether the drafts file owes a write.
    ///
    /// Separate from the sealed store's dirtiness because the two are
    /// licensed separately. A session whose state restore was refused
    /// may not write over yesterday's pages, and that refusal says
    /// nothing about a file the person opened by hand in this session:
    /// their unsaved typing still deserves to survive a crash.
    ///
    /// Readable so the cancelled quit's line can tell a drafts leg
    /// that failed from one that landed before another leg refused.
    private(set) var draftsDirty = false

    /// Whether the first reveal has run — restore is attempted once.
    private var stateLoaded = false

    /// Whether anything changed after the load settled: typed ink, a
    /// new or closed tab, a rename, a rung. Set at every `markDirty`
    /// and reset once at the end of `loadStateIfNeeded`, so the mint
    /// that launch itself performs does not count as the user's work.
    /// Quit cancellation under a withheld licence hangs off this: in a
    /// session that cannot write, everything it records is exactly
    /// what termination would lose.
    private var mutatedSinceLoad = false

    /// The licence `saveState` requires, granted separately from
    /// `stateLoaded`: a restore that failed over an *existing* file —
    /// Keychain key denied or missing, damaged snapshot — leaves the
    /// session usable but unlicensed, so no write in it can overwrite
    /// yesterday's sealed file with this session's consolation page.
    private var saveLicence = false

    /// The same licence, asked separately for the ledger file. The two
    /// files are sealed under two different keys and fail for different
    /// reasons, so one refusing to open says nothing about the other: a
    /// damaged ledger must not cost the session its pages, and a ledger
    /// that would not open must not be overwritten by an empty one. The
    /// rule is identical at launch, hence the same truth table.
    ///
    /// It parts company with the content licence afterwards, because the
    /// two refusals cost different things. Withholding the content
    /// licence protects yesterday's pages, and there is nothing better to
    /// do than keep protecting them. Withholding this one protects a file
    /// of metadata at the price of recording nothing further, and since
    /// nothing removes the file, one transient refusal (a keychain that
    /// said no while the machine was locked) would end the audit trail
    /// for every future launch as well. So this licence has one deliberate
    /// way back: the user clearing the ledger in Settings, which discards
    /// the file they were told could not be read and re-grants the licence
    /// (`licencesAfterLedgerClear`). Nothing auto-clears a refused ledger;
    /// the recovery is always the user's instruction. The one exception
    /// is not a refusal at all: a ledger payload from a version this app
    /// itself once wrote and has replaced is disposed of by the seam
    /// during the restore, before the probe below runs, so the file is
    /// gone and the licence is granted fresh (ADR-0016 section 9).
    private var ledgerLicence = false

    /// The persistence trail in the unified log: restore refusals and
    /// save failures, never content — the file is ciphertext and
    /// these lines carry only what happened to it.
    private let logger: Logger

    /// Who owns the live page content, and every write a surface that
    /// does not own was refused. Surfaces and field names only, never a
    /// page.
    private let ownershipLogger: Logger

    /// The test seam for a declined presentation write, or nil for the
    /// shipping assertion (`Seams.declinedPresentationWrite`).
    private let declinedPresentationWrite:
        (@MainActor (PresentationField, PresentationOwner) -> Void)?

    /// The first reveal loads yesterday's pages: the core decrypts the
    /// state file (the key comes from the Keychain — a prompt, if the
    /// ACL raises one, answers the user's own summon, per ADR-0004's
    /// spirit of prompting only on use) and drains the time the app was
    /// closed, expiring what didn't survive it. A missing file is a
    /// fresh start; an existing file that refuses to open still gets a
    /// working page but forfeits the save licence, keeping the refusal
    /// recoverable. Either way a page awaits, and the surface never opens
    /// onto nothing.
    ///
    /// The probe runs **after** the restore, and that ordering is
    /// load-bearing: see `grantsSaveLicence`.
    public func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        let path = stateFileURL.path
        let restored = client.persistRestore(from: path)
        saveLicence = Self.grantsSaveLicence(
            fileExists: FileManager.default.fileExists(atPath: path), restored: restored
        )
        contentRestoreRefused = !saveLicence
        if !saveLicence {
            logger.error(
                "restore failed over an existing state file; withholding the save licence"
            )
        }
        // The ledger is a second sealed file under a second key, so it
        // is restored separately and licensed separately. It carries no
        // page the surface needs, so a refusal here is quieter than a
        // content refusal: the session runs, the trail simply does not
        // go back any further, and this session may not overwrite the
        // file it could not read.
        let ledgerPath = ledgerFileURL.path
        let ledgerRestored = client.ledgerRestore(from: ledgerPath)
        // Probed after the restore for the same reason as above: the
        // restore has one cause to discard this file, a payload version
        // this app once wrote and has replaced, and that arm must have
        // fired before the probe asks whether the file exists. Beyond
        // that, the one thing that unlinks it is the user's own Clear
        // (`clearLedger`), which cannot race a probe that already ran.
        ledgerLicence = Self.grantsSaveLicence(
            fileExists: FileManager.default.fileExists(atPath: ledgerPath),
            restored: ledgerRestored
        )
        ledgerRestoreRefused = !ledgerLicence
        if !ledgerLicence {
            // Said plainly here as well as in the surface's standing
            // line: the ledger tab still opens, it simply stops
            // gaining records, and it will keep stopping on every future
            // launch until someone acts. Metadata only, as everywhere on
            // this trail: a path, never a title and never a byte of the
            // file.
            logger.error(
                """
                the ledger file exists but would not open, so this session is \
                NOT recording to the audit trail and will not overwrite that \
                file. Every later launch does the same until the ledger is \
                cleared from Settings, which discards the unreadable file and \
                starts a new trail. Pages are unaffected.
                """
            )
        }
        // The restore path is the one that would make relaunch mint,
        // and it takes the second predicate only (ADR-0017): a tab
        // remains, so nothing is conjured, even when every tab came
        // back empty after an overnight expiry. Minting on the first
        // predicate would start a fresh countdown on nothing in a slot
        // the user never selected. A seam that will not answer mints
        // nothing either: Return still conjures a page, and that is a
        // gesture rather than a guess.
        if client.emptiness()?.hasNoTabs == true {
            newTab()
        }
        refresh()
        selection = navigationTabs.first?.id
        if pads.isEnabled { restorePadSelection() }
        // The third sealed file, after the pages and after the
        // selection settles. It is licensed by nothing: a state file
        // that would not open says nothing about the drafts, which are
        // a different file that either opens or does not, and refusing
        // to read them because of the other one would lose a person's
        // unsaved typing to an unrelated failure.
        restoreDrafts()
        // The load is settled, mint included: what happens from here is
        // the user's work, and only that can block a later quit.
        mutatedSinceLoad = false
        // Sync starts only now, after the restore, so the engine never
        // sweeps a store the load is still filling. Off — the default —
        // this is a no-op with no side effect of any kind.
        sync.start()
    }

    /// The licence's truth table. The core folds "no file yet" and
    /// "refused" into one false; the file's presence on disk is what
    /// tells them apart. A restore that succeeded keeps the licence, a
    /// missing file grants it fresh (nothing exists to protect), and
    /// only an existing file that would not open withholds it.
    ///
    /// **`fileExists` is the probe taken after the restore, never
    /// before, and the order is part of the rule.** A state file sealed
    /// under an envelope the core has since replaced is dropped from
    /// disk *by the restore itself*, which then answers false. Nothing
    /// in such a file can ever be decrypted again, so there is nothing
    /// to preserve by keeping it. Probed beforehand, it reads as "a file
    /// was there and would not open", which is the one combination that
    /// withholds the licence: the install would then refuse to write for
    /// every session after the update, which is exactly the permanently
    /// unwritable install ADR-0016 section 9 exists to prevent. Probed
    /// afterwards, the dropped file reads as "no file", which is what it
    /// now is, and the session starts clean with its licence.
    ///
    /// Every other failure leaves the file exactly where it is, and each
    /// one still withholds: a missing key, a failed authentication, a
    /// snapshot the core rejects, an envelope from no version this app
    /// ever shipped. That is the outcome to want, because a session that
    /// could not read the file must not write over it. The table below
    /// did not change; only what feeds it.
    public nonisolated static func grantsSaveLicence(fileExists: Bool, restored: Bool) -> Bool {
        restored || !fileExists
    }

    /// Whether a mutation in this session has any file it could reach,
    /// which is what decides both the sudden-termination hold and the
    /// debounce. Either licence is enough: the state file and the
    /// ledger are sealed under different keys, fail for different
    /// reasons and are written by different calls, so a session that may
    /// not touch one of them still owes the other its write. Asking for
    /// both, as this once did through `saveLicence` alone, meant a
    /// session whose content restore was refused wrote no ledger at all,
    /// and a Clear the ledger in such a session never reached disk.
    public nonisolated static func writesEitherFile(
        loaded: Bool, contentLicence: Bool, ledgerLicence: Bool
    ) -> Bool {
        loaded && (contentLicence || ledgerLicence)
    }

    /// Whether this write should drop the state file rather than seal an
    /// empty store over it. Nothing is left at all, so the ciphertext on
    /// disk describes nothing, and leaving the generation there for the
    /// rest of the session buys the user nothing (ADR-0012: the last
    /// generation should not outlive what it held).
    ///
    /// **`storeEmpty` is "no tabs remain" and never "no tab holds a
    /// page"** (ADR-0017). The two are different questions since the
    /// sealed file started carrying tab names, rungs and strip order: a
    /// pad whose pages have all expired still has a strip to reseal,
    /// and dropping the file there would destroy exactly what the
    /// expiry was supposed to leave standing. The other predicate has
    /// its own job, ADR-0016 section 6's key rotation, and the core
    /// answers both in one call so neither can be recomputed into
    /// disagreement.
    ///
    /// All three conditions are the write's own preconditions, restated
    /// because deleting a file is the one thing that cannot be taken
    /// back: a session that never loaded knows nothing about what is on
    /// disk, and a session without the content licence could not read
    /// the file it would be deleting.
    ///
    /// The ledger deliberately has no say here. It is a second file
    /// under a second key with a lifetime that outlives the pages it
    /// describes, and an expiry that empties the store is precisely the
    /// moment the ledger gains records, so letting a non-empty ledger
    /// veto this would leave the erase permanently unreachable in the
    /// case it was written for.
    public nonisolated static func erasesContentFile(
        loaded: Bool, contentLicence: Bool, noTabsRemain: Bool
    ) -> Bool {
        loaded && contentLicence && noTabsRemain
    }

    /// Whether this write should rotate both content key halves and
    /// reseal the strip under the new ones rather than seal over the old
    /// ones: the other predicate's job, and the one that makes an
    /// emptied pad a forgetting (ADR-0016 section 6's first rotation
    /// trigger, ADR-0017).
    ///
    /// **`holdsNoPage` is "no tab holds a page" and never "no tabs
    /// remain".** Taking the second here would leave the install on one
    /// content key for as long as any tab exists, which is the whole
    /// failure the split names: a user who keeps a slot around would
    /// keep every ciphertext generation their pages ever lived in
    /// decryptable, including the ones an atomic rename unlinked and
    /// nothing sweeps.
    ///
    /// The drop takes precedence, which is why it is excluded here
    /// rather than merely ordered after: a pad with no tabs also holds
    /// no page, and there is nothing left to reseal, so the file goes
    /// instead. The two are one decision with three outcomes, not two
    /// independent tests.
    ///
    /// Rotating on the state rather than on the transition into it is
    /// deliberate, and its price is per write, not per emptying: every
    /// save that runs while the pad stays empty rotates again, so a
    /// persistently failing ledger write that rearms the retry every
    /// ten seconds spends a keychain write and a generation of tab
    /// names on each attempt. Each of those is another forgetting
    /// rather than a leak, which is why the price is paid; a latch
    /// that remembered whether the last write had already rotated
    /// would be a second source of truth about what is on disk, and it
    /// would be wrong in exactly the case that matters, a write that
    /// failed after the rotation landed. ADR-0016 section 6 records
    /// the choice.
    public nonisolated static func rotatesContentKey(
        loaded: Bool, contentLicence: Bool, holdsNoPage: Bool, noTabsRemain: Bool
    ) -> Bool {
        loaded && contentLicence && holdsNoPage && !noTabsRemain
    }

    /// The pair of licences after the user clears the ledger, which is
    /// the only thing in the app that moves a licence after launch.
    ///
    /// The ledger licence comes back unconditionally. A clear is an
    /// explicit instruction to discard the trail, so the file this
    /// session refused to overwrite is exactly the file the user just
    /// asked to be rid of, and the reason for withholding goes with it.
    /// Without this the withholding is permanent by construction: nothing
    /// else removes the file, so a single transient refusal (a keychain
    /// that said no while the machine was locked) would silently end the
    /// audit trail on this launch and on every launch after it. The
    /// re-grant is what makes that recoverable, and it is deliberately
    /// reachable only through the user's own gesture, never automatic.
    ///
    /// The content licence is passed through untouched, including when it
    /// is false. Clearing the ledger says nothing about the state file:
    /// it is a different file under a different key that the user did not
    /// ask about, and there is no such auto-heal on that side, because
    /// withholding there protects real pages rather than costing a
    /// metadata record.
    ///
    /// `ledger` is the licence as it stood and is deliberately not read:
    /// the whole point is that the outcome does not depend on it. It
    /// stays in the signature so the rule takes the pair in and hands the
    /// pair back, which is what lets a caller and a test say "withheld,
    /// then cleared" in one call.
    public nonisolated static func licencesAfterLedgerClear(
        content: Bool, ledger: Bool
    ) -> (content: Bool, ledger: Bool) {
        (content: content, ledger: true)
    }

    /// The mirror rule for the content side (ADR-0016 section 7's
    /// required work): the pair of licences after the user discards the
    /// unreadable state file. The content licence comes back
    /// unconditionally, on the same reasoning as the ledger's re-grant:
    /// the discard is the user saying the file may go, which is a
    /// stronger instruction than the licence's caution about
    /// overwriting it, and without a way back the withholding is
    /// permanent by construction. The ledger licence passes through
    /// untouched: a different file under a different key that the
    /// gesture did not ask about.
    public nonisolated static func licencesAfterContentClear(
        content: Bool, ledger: Bool
    ) -> (content: Bool, ledger: Bool) {
        (content: true, ledger: ledger)
    }

    private static let defaultServer = "https://eu.onetimesecret.com"
    private static let serverKey = "connection.serverURL"
    private static let extidKey = "connection.extid"
    private static let shareDomainKey = "connection.shareDomain"

    #if DEBUG
    /// How many times a mutation has asked for a write, counted before
    /// the licence guard. The invariant test for issue #52 reads this,
    /// because a test session never loads a state file and the guard
    /// in `markDirty` rightly stands down there; the call itself is the
    /// fact the invariant is about.
    private(set) var dirtyMarks = 0

    /// How many times a path asked the editor to take the keyboard,
    /// counted where the asking happens rather than where it lands. The
    /// landing needs a key window with a mounted editor in it, and the
    /// runner has neither, so the ask is the part of the hand-off a
    /// test can see: every path that rebuilds the mount must make it,
    /// and an unkeyed window must make none of them, because the law
    /// accepts keys and never takes them (issue #22).
    private(set) var keyboardHandoffs = 0
    #endif

    /// A mutation landed: the store now differs from the sealed file.
    /// Take the sudden-termination hold and make sure a write is armed.
    /// This, not the quit-time flush, is the mechanism (ADR-0012): a
    /// crash, a force quit or a logout loses at most one debounce
    /// window's worth of edits, because the window is measured from the
    /// first mark of a burst (see `SaveSchedule`). Quit flushing what is
    /// still pending is an optimization on top.
    ///
    /// A session that may write neither file takes no hold: there is no
    /// write it could be waiting for, and blocking shutdown over a
    /// buffer that may never reach disk buys nothing. One licence is
    /// enough, though: the ledger's write is not the content file's.
    private func markDirty() {
        #if DEBUG
        dirtyMarks += 1
        #endif
        // Before the licence guard, deliberately: a session that may
        // write nothing still accumulates work, and that work is what
        // makes the quit outcome unsavable.
        mutatedSinceLoad = true
        guard Self.writesEitherFile(
            loaded: stateLoaded, contentLicence: saveLicence, ledgerLicence: ledgerLicence
        ) else { return }
        terminationLatch.acquire()
        // The surface's "saving" begins at the mark, not at the timer's
        // far end, because the buffer differs from the file from this
        // moment on. A failed status stays put: the retry is already
        // armed, and a keystroke on top of a refusal does not make the
        // refusal old news. Only a settle in `saveState` clears it.
        if saveStatus != .failed { saveStatus = .saving }
        scheduleSave(after: saveDebounce)
    }

    /// A file moved: the drafts file now differs from what is open.
    ///
    /// It rides the same debounce and the same force-save path as the
    /// sealed state, which is the whole of decisions.md item 3's crash
    /// safety: a dirty file's unsaved typing is nowhere but in memory
    /// until this window closes, exactly as a page's is, and no
    /// longer.
    ///
    /// It does not go through `markDirty`, and the difference is the
    /// licence. `markDirty` stands down when this session may write
    /// neither of the two sealed files, which is the right answer for
    /// yesterday's pages and the wrong one for a file the person
    /// opened by hand ten seconds ago: that file's draft is sealed
    /// under the content key but is not the state file, and refusing
    /// to write it would lose work this session created and can
    /// perfectly well store.
    private func markFilesDirty() {
        draftsDirty = true
        mutatedSinceLoad = true
        terminationLatch.acquire()
        if saveStatus != .failed { saveStatus = .saving }
        scheduleSave(after: saveDebounce)
    }

    /// Arm the deferred write, unless one is already armed. The timer
    /// runs in `.common` so a tracked menu cannot stall the write past
    /// its window; the failure retry runs in `.default` instead, outside
    /// the system file panels' modal run-loop mode.
    private func scheduleSave(after interval: TimeInterval, mode: RunLoop.Mode = .common) {
        guard let generation = saveSchedule.arm() else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // The hop is why this check exists: the timer has fired
                // and can no longer be invalidated, so a write that ran
                // in the meantime (quit, most likely) is what stands
                // this one down.
                guard let self, self.saveSchedule.isCurrent(generation) else { return }
                self.saveState()
            }
        }
        RunLoop.main.add(timer, forMode: mode)
        saveTimer = timer
    }

    /// Arm the clear-after-copy (D-29, D-32; ADR-0012): one shot, the
    /// core's interval unless a test shortened it, firing the guarded
    /// clear that takes the board back only while it still holds what
    /// the core wrote. Re-armed on every egress: a second copy inside
    /// the window gets its own full window, and the first timer is
    /// stood down rather than left to fire early against the newer
    /// write. In `.common` so a tracked menu cannot hold the clear
    /// past its window.
    private func armClipboardClear() {
        clipboardClearTimer?.invalidate()
        let interval =
            clipboardClearDebounce ?? TimeInterval(CompanionClient.clipboardClearSeconds())
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clipboardClearTimer = nil
                _ = self.clearClipboardIfOurs()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardClearTimer = timer
    }

    /// Seal the store into its two files: live pages and their chips
    /// into the state file, the audit trail into the ledger file. Two
    /// files because they are sealed under two different keys with two
    /// different lifetimes, so each carries its own licence, each can
    /// refuse on its own, and neither one's licence gates the other's
    /// write. The debounce's far end, and the same call the terminate
    /// path makes: quit stands down whatever the debounce still holds
    /// and writes once, so it flushes rather than duplicating a write. A
    /// session that never loaded must not overwrite yesterday's files
    /// with its empty store; nor may one whose restore of that
    /// particular file was refused.
    ///
    /// The content leg has three outcomes rather than two. When no tabs
    /// remain it drops the file instead of sealing an empty store over
    /// it (`erasesContentFile`); when tabs remain but none of them holds
    /// a page it rotates both key halves and reseals the strip under the
    /// new ones (`rotatesContentKey`), which is what makes an emptied
    /// pad a forgetting rather than a fresh generation beside the old
    /// readable ones; otherwise it seals as usual.
    /// No write ever drops the ledger's own file:
    /// it is long-lived by design, and an emptied ledger is written as an
    /// empty ledger. The single thing that unlinks it is the user's own
    /// Clear, which does it from `clearLedger` rather than from here,
    /// because it is that gesture and not a write that decides the trail
    /// may end.
    ///
    /// Main-actor and synchronous by design. The terminate path answers
    /// `applicationShouldTerminate` with this result, so the write must
    /// have happened by the time it returns, and running it here is
    /// also what makes two overlapping writes to the same path
    /// impossible.
    ///
    /// Returns true when the file is settled — written, or deliberately
    /// left alone. False means the save was attempted and refused: this
    /// session's pages are not on disk, the sudden-termination hold
    /// stays taken, and the caller should say so before the process
    /// goes.
    @discardableResult
    public func saveState() -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        saveSchedule.begin()
        let licensed = Self.writesEitherFile(
            loaded: stateLoaded, contentLicence: saveLicence, ledgerLicence: ledgerLicence
        )
        // Drafts owe a write on their own terms, so this stands down
        // only when neither of the two has anything to do.
        guard licensed || draftsDirty else { return true }
        // Both files rest in this directory, so one preparation covers
        // them: it is created if missing, and marked so Time Machine
        // leaves the ciphertext generations alone (`.noindex` in the
        // name keeps Spotlight out the same way). A refusal here is not
        // fatal on its own: the write below reports what actually
        // happened, and the retry it arms comes back to try again.
        let url = (try? FormFactor.prepareStateDirectory(holding: stateFileURL)) ?? stateFileURL
        // The content leg, under its own licence. Emptiness is asked of
        // the core rather than of the published summaries, which a write
        // can reach before the refresh does, and a store with no pages
        // has no chips either: chips ride on pages.
        // Both predicates, in one answer, from the core (ADR-0017). The
        // shell derives neither: one of them decides a key rotation and
        // a predicate recomputed from the summaries can drift from the
        // one the rotation uses. A seam that will not answer reads as
        // neither, which drops nothing and rotates nothing, and is the
        // reading that loses nothing.
        let emptiness = client.emptiness()
        // The drafts leg goes first, and the order is the decision.
        // The content leg below can rotate the key halves, which
        // reseals the drafts file in the same core operation, or drop
        // the content file, which takes the drafts with it
        // (decisions.md item 14). Writing the drafts afterwards would
        // put them back the moment an emptied pad was supposed to have
        // discarded them, so they are written first and whatever the
        // content leg decides about them stands.
        let draftsSaved = saveDrafts(in: url.deletingLastPathComponent())
        let saved: Bool
        if !licensed || !saveLicence {
            // Deliberately left alone, which is settled, not refused:
            // this session could not read the file and so may not write
            // over it. The ledger below is a different file under a
            // different key and is not held back by this.
            saved = true
        } else if Self.erasesContentFile(
            loaded: stateLoaded,
            contentLicence: saveLicence,
            // The second predicate and only the second: the file is
            // dropped when no tabs remain, never when the tabs merely
            // hold no page. A strip of empty slots still carries names,
            // rungs and an order, so it is resealed rather than
            // unlinked, and feeding the other predicate here would
            // destroy the tabs an expiry was supposed to leave standing.
            noTabsRemain: emptiness?.hasNoTabs ?? false
        ) {
            saved = client.persistErase(at: url.path)
            if !saved {
                logger.error("the emptied state file could not be dropped")
            }
        } else if Self.rotatesContentKey(
            loaded: stateLoaded,
            contentLicence: saveLicence,
            // And the first predicate here, where it belongs: the pad
            // holds no content while the strip stands, so both halves
            // go and the names, rungs and order are resealed under new
            // ones. This is the write that makes an overnight expiry a
            // forgetting rather than a rename of the ciphertext on
            // disk.
            holdsNoPage: emptiness?.holdsNoPage ?? false,
            noTabsRemain: emptiness?.hasNoTabs ?? false
        ) {
            saved = client.persistRotateAndSave(to: url.path)
            if !saved {
                logger.error(
                    "the emptied pad's rotation or reseal did not land; the retry returns to it")
            }
        } else {
            saved = client.persistSave(to: url.path)
            if !saved {
                logger.error("save refused; the sealed state file was not rewritten")
            }
        }
        // The ledger's own write, under its own licence and its own key.
        // One debounce covers both files: the ledger only ever changes
        // on a mutation that already marked the store dirty.
        let ledgerSaved = licensed && ledgerLicence
            ? client.ledgerSave(to: ledgerFileURL.path)
            : true
        if !ledgerSaved {
            logger.error("save refused; the sealed ledger file was not rewritten")
        }
        // A refused ledger write is a refused write. The audit trail is
        // the record of what this app did with the user's secrets, so
        // losing it to a logout is not a lesser failure than losing a
        // page: it keeps the hold and it arms the same retry. The hold
        // therefore stays taken while EITHER file still owes a write,
        // which is what the conjunction says. A leg with no licence
        // reports true because it owes nothing, not because it wrote.
        let settled = saved && ledgerSaved && draftsSaved
        // The surface's answer, from the write's own outcome and
        // nowhere else. On the withheld-content leg this can read
        // "saved" while the pages went nowhere; the surface shows the
        // standing `contentRestoreRefused` state ahead of this one, so
        // that reading is never displayed (issue #49).
        saveStatus = settled ? .saved : .failed
        quitRefusal = Self.quitOfferAfterWrite(offer: quitRefusal, settled: settled)
        if !settled {
            // The buffer is still dirty and nothing else is going to ask
            // for it: the debounce only arms on a mutation, so a session
            // that fails one write and then goes quiet would keep its
            // pages nowhere but in memory. Arm the retry here. The hold
            // stays taken either way: holding is not writing.
            scheduleSave(after: saveRetryDebounce, mode: .default)
        }
        terminationLatch.settle(saved: settled)
        return settled
    }

    // MARK: Files: the third sealed file

    /// The drafts leg of a write: the roster of open files and, for
    /// each dirty one, the edits nobody has saved yet.
    ///
    /// It writes only when something moved, and with nothing open it
    /// drops the file rather than sealing an empty roster over it: an
    /// empty roster on disk is what the next launch would read as "no
    /// files", which is also what no file at all says, and of the two
    /// the absent file is the one that leaves nothing behind.
    ///
    /// The directory is passed in rather than read from the stored URL
    /// so that this and the state file cannot be resolved from two
    /// different places. The core finds the drafts beside the state
    /// path it is handed, so the two names must sit in one directory
    /// or a rotation will not find them.
    private func saveDrafts(in directory: URL) -> Bool {
        guard draftsDirty else { return true }
        let path = FormFactor.draftsFileURL(in: directory).path
        let wrote = openFiles.isEmpty
            ? client.draftsErase(at: path)
            : client.draftsSave(to: path)
        if wrote {
            draftsDirty = false
        } else {
            logger.error("the drafts file was not written; unsaved file edits are in memory only")
        }
        return wrote
    }

    /// Bring back the files that were open when the app last went
    /// away, and the unsaved edits any of them held.
    ///
    /// Run right after the page state restore and after the selection
    /// settles on a tab, so a relaunch opens where the person left the
    /// pad rather than on whichever file happens to be first. The
    /// files come back as tabs; which surface is showing is a separate
    /// question and this does not answer it.
    ///
    /// Two steps. The restore itself reads the drafts file and nothing
    /// else, and every row it brings back is pending. Each row is then
    /// hydrated on its own, which is the step that reads the file: a
    /// clean file is filled from disk, a dirty one keeps its draft and
    /// is measured against the disk, and a clean file that is gone or
    /// will not be read leaves the roster. The steps are separate
    /// because under the sandbox a file can be read only while its own
    /// security scope is open, and the scope comes from the file's
    /// bookmark, which only the shell can resolve.
    ///
    /// Every pending row is asked here, before the roster is published
    /// and before anything else can run. One kind of row is still
    /// pending afterwards: a clean file the system would not let the
    /// core read, which the core holds rather than drops
    /// (`FileSummary.isHeld`). It is published with the rest, with no
    /// text shown as the file's and a banner offering to locate it,
    /// and the core refuses every edit and save on it until it is
    /// settled. An open that would land on such a row hydrates it
    /// first (`openFile(at:)`).
    ///
    /// What is owed afterwards is the talking: the files that were
    /// dropped, the drafts that were too large to seal, and each clean
    /// file that came back from a disk copy that had changed while the
    /// app was away.
    private func restoreDrafts() {
        guard client.draftsRestore(from: draftsFileURL.path) else { return }
        // Whether the roster in memory came to differ from the one the
        // drafts file holds, which decides at the end whether a write
        // is owed.
        var recordMoved = false
        // Asked of the core directly, not through `refreshOpenFiles`:
        // that would publish rows that are not fit to draw yet.
        let restoredFiles = client.fileRoster()
        var waiting = restoredFiles.filter(\.pendingHydration)
        // In passes, because a hydration can wait. A file whose
        // bookmark resolves to the recorded path of a file not yet
        // hydrated is put off by the core until that one has settled,
        // since it may be about to move off the path. Each pass asks
        // the files still waiting, and a pass that settles none of
        // them, which is files that traded places, is ended by
        // hydrating every one of them at the path on record
        // (`settleCrossedFiles`).
        while !waiting.isEmpty {
            var deferred: [FileSummary] = []
            for file in waiting {
                switch hydrateRestoredFile(file) {
                case .deferred: deferred.append(file)
                case .settled(let moved): recordMoved = recordMoved || moved
                }
            }
            if deferred.count == waiting.count {
                if settleCrossedFiles(deferred) { recordMoved = true }
                deferred = []
            }
            waiting = deferred
        }
        if pads.isEnabled {
            pads.transferFiles(client.fileRoster().compactMap { new in
                guard let old = restoredFiles.first(where: { $0.id == new.id }), old.path != new.path else { return nil }
                return (old.path, new.path)
            })
        }
        refreshOpenFiles()
        for file in openFiles {
            // The core restored either the draft or the current disk copy;
            // classify that buffer directly, without creating editor storage.
            reconsiderFileRenderMode(for: file.id, resetDismissal: true)
        }
        // The reload flag is sticky, so it is answered as it is
        // posted. Reading the roster does not drain it, deliberately:
        // the strip redraws more than once and a flag that vanished on
        // the first read would be a notice nobody ever saw.
        let reloaded = openFiles.filter(\.externallyReloaded)
        for file in reloaded { client.clearFileReloadNotice(file.id) }
        // Drained rather than polled, once, here.
        let notices = client.draftNotices()
        if let sentence = Self.launchNotice(reloaded: reloaded, notices: notices) {
            flash(sentence)
        }
        // The roster on disk and the roster in memory agree only when
        // the hydration changed nothing. A file that was dropped, found
        // at a new path, given a fresh bookmark, read again from a
        // changed disk copy or told its draft was too large now differs
        // from its record, and a record left as it was would make the
        // next launch do all of it again and say all of it again. It
        // would also keep a bookmark that is known to be going bad, and
        // the one launch that held a good one would have thrown it
        // away. So the write is owed now, without waiting for the
        // person to touch a file.
        if recordMoved || !reloaded.isEmpty || !notices.isEmpty {
            markDraftsRecordMoved()
        } else {
            draftsDirty = false
        }
    }

    /// The one line a launch says about the files it brought back.
    ///
    /// One line and not four, because they arrive together and a
    /// person reading four in a row reads none of them. Files are
    /// named, because a general warning about unsaved work is exactly
    /// the warning nobody can act on.
    public nonisolated static func launchNotice(
        reloaded: [FileSummary], notices: [DraftNotice]
    ) -> String? {
        var clauses: [String] = []
        if !reloaded.isEmpty {
            clauses.append(
                "\(englishList(reloaded.map(\.name))) changed on disk and was read again")
        }
        for reason in [DraftNoticeReason.missing, .unreadable, .draftTooLarge] {
            let names = notices.filter { $0.reason == reason }.map(\.name)
            guard !names.isEmpty else { continue }
            switch reason {
            case .missing:
                clauses.append("\(englishList(names)) is no longer at its path")
            case .unreadable:
                clauses.append("\(englishList(names)) could not be read")
            case .draftTooLarge:
                clauses.append("unsaved changes to \(englishList(names)) were too large to keep")
            }
        }
        guard !clauses.isEmpty else { return nil }
        return englishList(clauses) + "."
    }

    /// Hydrate one restored file inside its own access bracket.
    ///
    /// The bookmark is resolved first, and where it resolves is handed
    /// to the core, which is how a file moved while the app was away
    /// is found where it is now rather than missed where it was. A
    /// file with no bookmark, or one that resolves to nothing, is
    /// hydrated at the path on record with no scope open: outside a
    /// sandbox that reads it, and inside one the read is refused and
    /// the core says so for that file alone.
    ///
    /// Nothing here can fail for more than the one file. Each has its
    /// own bracket and its own call, and the core's hydration touches
    /// no file but the one named.
    ///
    /// The bookmark is made again, inside the scope, when the old one
    /// is no longer the right one to keep: it came back stale, or it
    /// is a plain one from before the scoped bookmarks, or the file
    /// moved. Only for a file that still stands, and only when the
    /// core is now bound to the path the bookmark resolved to. A
    /// rebind the core refused leaves the file at its recorded path,
    /// and a bookmark for some other file's path is not one to keep.
    /// A refresh that fails keeps the old bookmark and says nothing:
    /// the file is open and the launch has its own line to say.
    ///
    /// A bookmark that resolves into a Trash is treated as one that
    /// resolves to nothing, and the file is hydrated at the path on
    /// record. A thrown away file keeps its identity, so following it
    /// would bring it back as an ordinary tab, and a draft over it
    /// would be saved into the Trash. Read at the recorded path it is
    /// simply gone, which is what the person made it.
    ///
    /// The answer says whether the core put the question off, and if
    /// it settled, whether the file now differs from its record in the
    /// drafts file: dropped, bound to a new path, or carrying a new
    /// bookmark. A file the core holds counts as settled here. It was
    /// asked and nothing about it is waiting on another file, and it
    /// is asked again on each activation (`retryHeldFile`).
    private func hydrateRestoredFile(_ file: FileSummary) -> RestoredHydration {
        // Nil from the bracket means the bookmark resolved to nothing
        // and the body never ran, which is a different thing from a
        // hydration that ran and dropped the file.
        let bracketed: RestoredHydration? = fileBookmark(file.id).flatMap { data in
            fileCoordinator.withAccess(toBookmark: data) { access in
                if fileCoordinator.isInTrash(access.url) {
                    // Inside the bracket all the same: a file that was
                    // opened from the Trash on purpose has that path
                    // on record, and the scope is what reads it.
                    let kept = client.hydrateFile(file.id, resolvedPath: nil)
                    return .settled(recordMoved: !kept)
                }
                let resolved = access.url.path
                guard client.hydrateFile(file.id, resolvedPath: resolved) else {
                    return .settled(recordMoved: true)
                }
                guard let row = client.fileRoster().first(where: { $0.id == file.id }) else {
                    return .settled(recordMoved: true)
                }
                let rebound = row.path != file.path
                // Held: asked and answered, with nothing read. There
                // is no bookmark worth making for a file the scope
                // could not read.
                if row.isHeld { return .settled(recordMoved: rebound) }
                if row.pendingHydration { return .deferred }
                guard Self.samePath(row.path, resolved) else {
                    return .settled(recordMoved: rebound)
                }
                guard access.isStale || !access.isScoped || rebound else {
                    return .settled(recordMoved: false)
                }
                let renewed = renewBookmark(for: file.id, from: access.url)
                return .settled(recordMoved: rebound || renewed)
            }
        }
        if let bracketed { return bracketed }
        let kept = client.hydrateFile(file.id, resolvedPath: nil)
        return .settled(recordMoved: !kept)
    }

    /// End a wait that cannot end on its own: every file in `files`
    /// was put off, each because its bookmark leads to the recorded
    /// path of another that is also waiting. That is files that traded
    /// names while the app was away. Each is hydrated at the path its
    /// record carries, which never waits, and that is where all of
    /// them would come to rest if only one were forced: once one stays
    /// put, the file waiting for its path is refused it and stays put
    /// as well, and so on round the ring.
    ///
    /// The reads happen with every one of their bookmarks' scopes
    /// open at once. A file here is read at its recorded path, and
    /// the grant on that path is not its own bookmark's, which leads
    /// to where the file went: it is the bookmark of the file that
    /// now sits there. Read with no scope, or each inside its own,
    /// every one of them would be refused under the sandbox and left
    /// held, with Locate the only way back.
    ///
    /// Each file that settles is then given a bookmark for the path
    /// it came to rest at, made from the URL whose scope is on that
    /// path. The one it carried names another tab's file, and every
    /// later bracket for this file would open its scope on that one.
    /// A bookmark that cannot be made leaves the old one in place, so
    /// the next launch meets the same crossing and ends it the same
    /// way rather than finding no bookmark at all.
    ///
    /// Answers whether any file now differs from its record.
    private func settleCrossedFiles(_ files: [FileSummary]) -> Bool {
        var recordMoved = false
        withAccessToBookmarks(of: files[...], opened: []) { opened in
            for file in files {
                guard client.hydrateFile(file.id, resolvedPath: nil),
                      let row = client.fileRoster().first(where: { $0.id == file.id })
                else {
                    recordMoved = true
                    continue
                }
                guard !row.pendingHydration else { continue }
                let source = opened.first(where: { Self.samePath($0.path, row.path) })
                    ?? URL(fileURLWithPath: row.path)
                if renewBookmark(for: file.id, from: source) { recordMoved = true }
            }
        }
        return recordMoved
    }

    /// Run `body` inside the access bracket of every file's bookmark
    /// at once, nested, and hand it the URLs those brackets are open
    /// on. A file with no bookmark, or one that resolves to nothing,
    /// contributes no bracket, and the body runs all the same. Each
    /// bracket closes what it opened, innermost first. For N roster rows,
    /// this can hold N concurrent security scopes and uses O(N) stack
    /// depth; both are bounded by the restored roster size.
    private func withAccessToBookmarks(
        of files: ArraySlice<FileSummary>, opened: [URL], _ body: ([URL]) -> Void
    ) {
        guard let first = files.first else {
            body(opened)
            return
        }
        let rest = files.dropFirst()
        let ran: Void? = fileBookmark(first.id).flatMap { data in
            fileCoordinator.withAccess(toBookmark: data) { access in
                withAccessToBookmarks(of: rest, opened: opened + [access.url], body)
            }
        }
        if ran == nil { withAccessToBookmarks(of: rest, opened: opened, body) }
    }

    /// What one attempt to hydrate a restored file came to.
    private enum RestoredHydration {
        /// The core put the question off: the file is still pending
        /// and is asked again after the others.
        case deferred
        /// The file is settled, kept or dropped. `recordMoved` says
        /// whether it now differs from its record in the drafts file.
        case settled(recordMoved: Bool)
    }

    // MARK: Files: access

    /// The bookmark the core carries for a file, or nil when it holds
    /// none.
    private func fileBookmark(_ id: UInt64) -> Data? {
        guard let base64 = client.fileBookmarkBase64(id), !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    /// Whether two paths name one place once symlinks are resolved.
    /// The core's paths are resolved at open and a bookmark or a panel
    /// hands back whatever it likes, so a plain string comparison
    /// would call /tmp and /private/tmp two directories.
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// Run `body` with access open on an open file, and hand back what
    /// it returned.
    ///
    /// Every call that makes the core read, stat or write a file the
    /// person chose goes through here or through the coordinator's
    /// panel bracket: the check, the reload, the save, keep mine and
    /// take theirs. Under the sandbox the core's call is refused
    /// outside a bracket, and the bracket is the file's own bookmark,
    /// resolved and scoped for exactly as long as the body runs.
    ///
    /// The body is handed the URL the bookmark resolved to, or nil
    /// when it runs with none. It runs unbracketed for a file with no
    /// bookmark, or one whose bookmark resolves to nothing: a file
    /// inside the app's own container, such as the keymap, needs no
    /// grant, and any other file then hears the refusal from the core
    /// in the ordinary way. The body always runs exactly once.
    ///
    /// A bookmark that resolved stale is made again here, before the
    /// body, so every bracket mends it rather than only the launch.
    /// The mended one is owed to the drafts file as well: a stale
    /// bookmark is one the system says may stop resolving, and a fresh
    /// one that lived only in memory would be gone at the next quit.
    ///
    /// Brackets nest. A save reached from the save panel runs inside
    /// the panel's bracket and opens this one within it, and each
    /// closes what it opened.
    private func withFileAccess<T>(_ id: UInt64, _ body: (URL?) -> T) -> T {
        guard let data = fileBookmark(id) else { return body(nil) }
        // Nil from the bracket means the bookmark resolved to nothing
        // and the body has not run yet, so it runs below instead.
        let bracketed: T? = fileCoordinator.withAccess(toBookmark: data) { access in
            if access.isStale, renewBookmark(for: id, from: access.url) {
                markDraftsRecordMoved()
            }
            return body(access.url)
        }
        if let bracketed { return bracketed }
        return body(nil)
    }

    /// Make a fresh bookmark from `url` and hand it to the core.
    /// Called inside an open bracket. False when none could be made.
    ///
    /// What the file is left holding after a failure is the caller's
    /// to say, because it turns on what the old bookmark names. When
    /// it names the file at the core's path, it is kept: an older
    /// bookmark for the right file is better than none. When the
    /// core's path has moved on, as it has after a Save As, the old
    /// bookmark names a file the person left, and the next launch
    /// would follow it and bind the tab back to that file. A draft
    /// made since would then be one save away from overwriting the
    /// very file Save As was used to spare. So `orphansHeld` drops the
    /// old bookmark when the new one cannot be made, and the next
    /// launch reads the recorded path with nothing to mislead it.
    @discardableResult
    private func renewBookmark(for id: UInt64, from url: URL, orphansHeld: Bool = false) -> Bool {
        do {
            let data = try fileCoordinator.bookmark(for: url)
            client.setFileBookmark(id, base64: data.base64EncodedString())
            return true
        } catch {
            // The error names no path and no content: a Cocoa domain
            // and a code, which is what a sandbox refusal looks like.
            let reason = error as NSError
            logger.error(
                "a file bookmark could not be made: \(reason.domain, privacy: .public) \(reason.code, privacy: .public)")
            if orphansHeld { client.setFileBookmark(id, base64: "") }
            return false
        }
    }

    /// The drafts file now differs from the roster in memory, through
    /// no act of the person's: a restore found a file somewhere new or
    /// dropped one, or a bookmark was made again.
    ///
    /// The write is armed as `markFilesDirty` arms it. What is left
    /// out is everything that treats the change as work. It is not
    /// counted as a mutation since the load, so it cannot hold up a
    /// quit, and it does not take the sudden termination hold or show
    /// as saving: a record that misses this write is mended again at
    /// the next launch, and nothing a person typed rides on it.
    private func markDraftsRecordMoved() {
        draftsDirty = true
        scheduleSave(after: saveDebounce)
    }

    /// Whether a missing bookmark for the file at `path` is worth a
    /// sentence. The keymap file lives in the app's own configuration
    /// directory, which it may read with no grant at all, so a
    /// bookmark that could not be made for it costs nothing and a
    /// warning about it would be a false one.
    private func owesBookmark(path: String) -> Bool {
        guard let keymap = userKeymapFileURL else { return true }
        return !Self.samePath(keymap.path, path)
    }

    /// What a person is told when a file's bookmark could not be made.
    ///
    /// The file is open and the save landed, so this is about later:
    /// without a bookmark the next launch has only the recorded path
    /// to go on, which a sandboxed build may not read.
    public nonisolated static func bookmarkFailureNotice(name: String) -> String {
        "\(name) may not reopen after a relaunch, because access to it could not be kept."
    }

    /// The quit policy's outcome table. A refused write cancels the first
    /// quit regardless of the licence. A settled flush over a withheld
    /// content licence also cancels it when the session accumulated work
    /// after load; an untouched session under a withheld licence may
    /// terminate. What a cancelled quit does next is `QuitPrompt`'s.
    public nonisolated static func quitOutcome(
        settled: Bool, contentLicence: Bool, loaded: Bool, mutatedSinceLoad: Bool
    ) -> QuitSaveOutcome {
        if !settled { return .refused }
        if loaded && !contentLicence && mutatedSinceLoad { return .unsavableWithContent }
        return .settled
    }

    /// The terminate path's flush: `saveState` plus the one question it
    /// cannot answer alone, whether a settled flush still left this
    /// session's work nowhere but in memory. Work is `mutatedSinceLoad`
    /// rather than a content probe, because in a session that cannot
    /// write, everything recorded since the load is exactly what the
    /// quit loses, and the empty page launch itself mints is not.
    public func saveStateForQuit() -> QuitSaveOutcome {
        let settled = saveState()
        return Self.quitOutcome(
            settled: settled,
            contentLicence: saveLicence,
            loaded: stateLoaded,
            mutatedSinceLoad: mutatedSinceLoad
        )
    }

    public var quitAnywayOffered: Bool { quitRefusal != nil }

    /// The standing line's button, answered.
    ///
    /// It asks for a termination rather than performing one: the request
    /// goes back through `applicationShouldTerminate`, which is where
    /// `QuitPrompt.terminateReply` reads the offer this line represents
    /// and lets the second ask through. That is why the button and a
    /// second ⌘Q are the same answer, and it is the reason this is a
    /// model call and not `NSApp.terminate` from inside a view: every
    /// other action on the status stack goes through the model, and the
    /// quit path is the one that can least afford a second route.
    ///
    /// `NSApp` is read optionally because a filtered test run has no
    /// application object, and a status action that traps the runner is
    /// worse than one that does nothing there.
    public func requestQuitAnyway() {
        NSApp?.terminate(nil)
    }

    /// The cancelled quit's standing line goes up. A settled outcome is
    /// never recorded: there is nothing to quit anyway from.
    public func offerQuitAnyway(after outcome: QuitSaveOutcome) {
        guard outcome != .settled else { return }
        quitRefusal = outcome
    }

    /// Whether the offer survives a write. A refusal's offer stands
    /// until a write settles, because a settled write is exactly the
    /// thing the refusal said had not happened. An unsavable session's
    /// offer is untouched by writes: on that leg the flush settles
    /// while the pages go nowhere, so a settle says nothing about it.
    public nonisolated static func quitOfferAfterWrite(
        offer: QuitSaveOutcome?, settled: Bool
    ) -> QuitSaveOutcome? {
        offer == .refused && settled ? nil : offer
    }

    /// Whether the offer survives the user's discard of the unreadable
    /// file. The discard grants the licence, so an unsavable session's
    /// offer comes down; a refusal's stands until its own write lands.
    public nonisolated static func quitOfferAfterContentClear(
        offer: QuitSaveOutcome?
    ) -> QuitSaveOutcome? {
        offer == .unsavableWithContent ? nil : offer
    }

    /// The standing line's sentence, a pure function of the outcome so
    /// the two cases are testable as words. Lower case, third person,
    /// and it names the loss rather than warning in general (D-15).
    ///
    /// The drafts are a third file with a write of their own, and a
    /// refusal says only that one of the three legs failed. The drafts
    /// leg runs under a withheld content licence too, so an unsavable
    /// session's drafts are on disk. The line therefore names dirty
    /// files only when that leg itself still owes its write
    /// (`draftsUnwritten`), and names the pages alone otherwise.
    public nonisolated static func quitRefusalSentence(
        _ outcome: QuitSaveOutcome, files: [FileSummary] = [], draftsUnwritten: Bool = false
    ) -> String? {
        let loss = lostAtQuit(files: files, draftsUnwritten: draftsUnwritten)
        switch outcome {
        case .settled:
            return nil
        case .refused:
            return "the sealed state file was not written, so this session's \(loss) will not survive the quit"
        case .unsavableWithContent:
            return "nothing typed this session is on disk, so its \(loss) will not survive the quit"
        }
    }

    /// What a cancelled quit takes, as the object of the standing line.
    private nonisolated static func lostAtQuit(
        files: [FileSummary], draftsUnwritten: Bool
    ) -> String {
        let dirty = draftsUnwritten ? files.filter(\.holdsUnsavedEdits).map(\.name) : []
        guard !dirty.isEmpty else { return "pages" }
        return "pages and the unsaved changes to \(englishList(dirty))"
    }

    deinit {
        if let modalEndObserver { NotificationCenter.default.removeObserver(modalEndObserver) }
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
        if clipboardClearTimer != nil {
            _ = clearClipboardIfOurs()
            clipboardClearTimer?.invalidate()
        }
        // A pending write dies with the model. In practice the model
        // outlives everything but the process, and the process's own
        // exit routes through `saveState` first.
        saveTimer?.invalidate()
        // A model that dies dirty still owes the hold back. Nothing else
        // can return it once the object is gone, and a stranded disable
        // is process-wide: in a test that builds a model against a
        // throwaway domain it would be the runner that stopped being
        // killable.
        terminationLatch.release()
    }

    // MARK: State

    /// The selected slot's summary, page or no page.
    public var selectedTab: TabSummary? {
        tabs.first { $0.id == selection }
    }

    /// The page the selected slot holds, or nil when it holds none.
    /// Every page-addressed call goes through this rather than through
    /// `selection`, which names a slot and may name an empty one.
    public var selectedPageID: UInt64? {
        selectedTab?.pageID
    }

    /// The pages the strip is holding right now, by identity. The
    /// pruning set for the document maps, and the liveness set the
    /// conceal drafts are checked against.
    private var livePageIDs: Set<UInt64> {
        Set(tabs.compactMap(\.pageID))
    }

    /// The live pages grouped by the day they were born on, newest day
    /// first: the whole of what the time-unit mode draws (issue #79).
    ///
    /// Computed, and cached nowhere on purpose. Every fact it rests on
    /// is already in `tabs`, which `refresh()` re-reads on every
    /// accepted edit, every expiry and every cosmetic redraw. A stored
    /// copy would go stale the moment a page expired and (worse) it
    /// would freeze the day reading the core recomputes on each read,
    /// so the labels would stop rolling over at local midnight and the
    /// mode would need the timer this whole design exists to avoid.
    /// What it costs instead is a walk over the summaries the model has
    /// already decoded, with no call into the core at all.

    // MARK: Experimental pads (local navigation ownership)

    public var navigationTabs: [TabSummary] {
        guard pads.isEnabled else { return tabs }
        return tabs.filter { pads.owner(ofTabUUID: $0.uuid) == pads.activeID }
    }
    public var navigationFiles: [FileSummary] {
        guard pads.isEnabled else { return openFiles }
        return openFiles.filter { pads.owner(ofFile: $0.path) == pads.activeID }
    }
    /// Soft application context yields to any explicit file context or an
    /// unfinished confirmation. Called by the transient workspace observer.
    func routeFromApplication(_ bundleID: String) {
        guard !ModalSession.isRunning, !ModalSession.isBracketed,
            pendingFileClose == nil, concealDraft == nil, selectedFile == nil,
            let target = pads.pad(forApplication: bundleID) else { return }
        pads.activate(target, recordRecency: false)
    }
    public func activatePad(_ id: UUID) {
        guard pads.isEnabled else { return }
        guard pendingFileClose == nil else {
            flash("Finish the file close decision before switching pads.")
            return
        }
        pads.activate(id)
    }
    @discardableResult
    public func createPad(named name: String) -> UUID? {
        guard pads.isEnabled, pendingFileClose == nil else { return nil }
        return pads.create(named: name)
    }
    private func updateApplicationContextObservation() {
        guard !FormFactor.runningUnderTests else { return }
        if pads.isEnabled && pads.appAssociationsEnabled {
            if applicationContext == nil {
                applicationContext = PadApplicationContext { [weak self] bundleID in
                    self?.routeFromApplication(bundleID)
                }
            }
        } else {
            applicationContext = nil
        }
    }
    private func padCatalogChanged() {
        updateApplicationContextObservation()
        if pads.isEnabled != lastPadsEnabled || (pads.isEnabled && pads.activeID != lastPadID) {
            if lastPadsEnabled { pads.onChange = nil
                pads.remember(tabUUID: selectedTab?.uuid, for: lastPadID)
                pads.onChange = { [weak self] in self?.padCatalogChanged() }
            }
            lastPadID = pads.activeID
            lastPadsEnabled = pads.isEnabled
            showingLedger = false
            selectedFile = nil
            expandedPageID = nil
            if pads.isEnabled { restorePadSelection() }
            else { selection = Self.reconciledSelection(current: selection, live: tabs.map(\.id)) }
        }
        objectWillChange.send()
    }
    private func restorePadSelection() {
        let remembered = pads.rememberedTab(for: pads.activeID)
        selection = navigationTabs.first { $0.uuid == remembered }?.id ?? navigationTabs.first?.id
        if showsTimeUnits {
            selection = Self.reconciledTimeSelection(current: selection, projection: timeUnits)
        }
    }
    public func toggleDaySort() { pads.toggleDaySort(for: pads.activeID) }
    public func toggleCheckpointSort(dayBucket: Int) {
        pads.toggleCheckpointSort(for: pads.activeID, onDate: dateKey(forDayBucket: dayBucket))
    }
    public func dateKey(forDayBucket bucket: Int) -> String {
        let calendar = Calendar.current
        let date: Date
        if let stamp = navigationTabs.first(where: { min($0.pageDayOffset ?? 1, 0) == bucket && $0.pageCreatedMs != nil })?.pageCreatedMs {
            date = Date(timeIntervalSince1970: Double(stamp) / 1000)
        } else {
            date = calendar.date(byAdding: .day, value: bucket, to: Date()) ?? Date()
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    private func sortedPadProjection(_ projection: TimeUnitProjection) -> TimeUnitProjection {
        guard pads.isEnabled else { return projection }
        let summaries = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var units = projection.units.map { unit in
            let direction = pads.checkpointSortDirection(for: pads.activeID, onDate: dateKey(forDayBucket: unit.bucket))
            let ordered = zip(unit.tabIDs, unit.pageIDs).sorted { a, b in
                let lhs = summaries[a.0]?.pageCreatedMs ?? 0, rhs = summaries[b.0]?.pageCreatedMs ?? 0
                if lhs == rhs {
                    let left = summaries[a.0]?.uuid ?? String(a.0)
                    let right = summaries[b.0]?.uuid ?? String(b.0)
                    return direction == .chronological ? left < right : left > right
                }
                return direction == .chronological ? lhs < rhs : lhs > rhs
            }
            return TimeUnitProjection.Unit(bucket: unit.bucket, label: unit.label, spokenLabel: unit.spokenLabel,
                railLabel: unit.railLabel, pageIDs: ordered.map { $0.1 }, tabIDs: ordered.map { $0.0 },
                fractionRemaining: unit.fractionRemaining, paused: unit.paused, toppedUp: unit.toppedUp,
                lastHour: unit.lastHour, remainingLabel: unit.remainingLabel, spokenRemaining: unit.spokenRemaining)
        }
        if pads.daySortDirection(for: pads.activeID) == .chronological { units.reverse() }
        return TimeUnitProjection(units: units, hiddenBlankPages: projection.hiddenBlankPages)
    }

    public var timeUnits: TimeUnitProjection {
        sortedPadProjection(TimeUnitProjection.project(tabs: navigationTabs, selectedPageID: selectedPageID, unit: .day))
    }

    public func refresh() {
        // Whatever moved the page may have moved its history: an edit,
        // a step, a seal, a settle that reaped a chip, a page that
        // died. The menu's two items are asked again on every one of
        // them rather than at a list of paths someone has to keep.
        refreshEditSteps()
        tabs = client.tabs()
        let livePages = livePageIDs
        // A dead page's ink lives on only in the ledger; drop the
        // editor-side document. The filter is on the live PAGE
        // identities and never on the tabs, because a tab outlives its
        // page: keyed by the slot, a reused tab would inherit the dead
        // page's storage, and its attachment character for a zeroized
        // chip with it (ADR-0009, ADR-0017 item 9).
        //
        // A file id is exempt, and the exemption is not a courtesy: a
        // file is never in `tabs`, so it is never in `livePages`, and
        // without this line the first refresh after a file is opened
        // drops the storage the one persistent text view is still
        // laying out. Every restate path then guards on a map entry
        // that is gone and silently does nothing, which is how a Take
        // theirs can report the file was read again while the editor
        // still shows the discarded draft. A file's storage is dropped
        // by exactly one place, the close, which does it by name.
        storages = storages.filter { $0.key.isFileID || livePages.contains($0.key) }
        // The caret and the scroll go with the page they were kept for,
        // under the same exemption: a file's place is dropped by the
        // roster, never by a set it was never in.
        viewStates.prune(keeping: livePages)
        // The roll's renderings of the days the editor is not standing
        // on go the same way and on the same set. They are plaintext of
        // a page, so an entry outliving its page would be exactly the
        // ink an expiry is supposed to take away.
        quietRenderings = quietRenderings.filter { livePages.contains($0.key) }
        fenceRenderingLanguages = fenceRenderingLanguages.filter { livePages.contains($0.key) }
        selection = Self.reconciledSelection(current: selection, live: navigationTabs.map(\.id))
        // When pages are organized by day, a slot holding no page is not on
        // the rail at all, so a selection left on one would be pointing
        // at something the surface is not drawing. One boolean ahead of
        // the fall leaves the strip's own reconciliation exactly as it
        // was, and this arm mints no more than that one does.
        if showsTimeUnits {
            selection = Self.reconciledTimeSelection(current: selection, projection: timeUnits)
        }
        // A conceal whose subject died — expiry, mostly; `close`
        // clears its own — must not keep the confirmation standing:
        // ↩ lands on "Create link", and a stale draft would answer a
        // stray keystroke with a network call over a page (or a chip's
        // page) that no longer exists (issue #19). A chip is orphaned
        // when it survives on no live page: its host page has gone,
        // even if others remain. The core is authoritative here, even
        // for a page whose editor never mounted.
        if let draft = concealDraft {
            var liveChips: Set<UInt64> = []
            if case .chip = draft.target {
                liveChips = Set(livePages.flatMap { chipIds(onSheet: $0) })
            }
            if Self.isRefreshOrphan(
                target: draft.target, liveSheets: livePages, liveChips: liveChips
            ) {
                concealDraft = nil
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

    /// Which **tab** holds the selection after the model reloads. A
    /// selection that still names a tab on the strip keeps it, and an
    /// expiry therefore changes nothing about the selection: the slot
    /// is still there, holding nothing, and the surface renders its
    /// empty state rather than jumping the user to another page. A
    /// selection whose tab is gone (a close, a reorder that dropped it)
    /// falls to the first tab in strip order, the same tab a nil
    /// selection seats, so the "it went" path and the "nothing was
    /// selected" path land together. A model with no tabs selects
    /// nothing: the keyed-empty state ADR-0005's grants are built to
    /// hold. Pure, so the decision is testable without a window; `live`
    /// is ordered, so "first" is the first visible tab.
    ///
    /// This never mints. Minting on a reconciled selection would mint
    /// whenever the selected tab's page expired under the user's
    /// cursor, which is the silent countdown on nothing ADR-0017
    /// refuses; only the three deliberate gestures and Return open a
    /// page into a slot.
    public nonisolated static func reconciledSelection(current: UInt64?, live: [UInt64]) -> UInt64? {
        if let current, live.contains(current) { return current }
        return live.first
    }

    /// Which tab the selection falls to while the days are down the
    /// side and the slot it names is not one the rail is drawing
    /// (issue #79).
    ///
    /// The strip's rule above keeps a selection on a tab whose page
    /// expired, deliberately: the slot is still there, and the surface
    /// shows its empty state rather than moving the user somewhere they
    /// did not ask to go. In this mode that slot is not on screen at
    /// all, the rail draws days, and a day exists because a live page
    /// is keyed to it, so a selection left there would name something
    /// nobody can see. It falls to the newest visible page instead. When
    /// no page is visible anywhere it stays exactly where it is, which
    /// is the empty Today the create grant is already waiting on.
    ///
    /// It never mints, for `reconciledSelection`'s reason: `refresh()`
    /// runs on every accepted edit and every expiry, and a page expiring
    /// under the cursor must not start a fresh countdown on nothing
    /// (ADR-0017). Pure, so the fall is testable without a window.
    ///
    /// Two callers, and the second is the reason this is stated as a
    /// rule rather than as a line inside `refresh()`: the mode's
    /// entrance (`showsTimeUnits`) applies it too, because a selection
    /// standing on a slot the mode draws no row for is exactly the state
    /// somebody turns the mode on from, and the rule that answers it
    /// must not wait for the next refresh to happen along.
    public nonisolated static func reconciledTimeSelection(
        current: UInt64?, projection: TimeUnitProjection
    ) -> UInt64? {
        let visible = projection.units.flatMap(\.tabIDs)
        if let current, visible.contains(current) { return current }
        return visible.first ?? current
    }

    /// The page's document, created on first use. A page restored from
    /// the state file already has a document core-side; replay it into
    /// the fresh storage with the editor's own attributes, so restored
    /// ink and chips are indistinguishable from typed ones. A page born
    /// in this process replays as empty.
    /// The runs behind an id, from whichever of the two stores holds
    /// it.
    ///
    /// One function rather than a branch at each of the four call
    /// sites, because the four have to agree: a storage built from one
    /// store and restated from the other would silently replace a
    /// file's text with a page's. The tag is the whole of the
    /// decision, and the core refuses the wrong store on its own side
    /// too, so a mistake here fails loudly rather than reading page
    /// zero.
    private func runs(of id: UInt64) -> [RestoredRun] {
        id.isFileID ? client.fileRuns(id) : client.documentRuns(sheet: id)
    }

    public func storage(for id: UInt64) -> NSTextStorage {
        if let existing = storages[id] { return existing }
        let created = NSTextStorage()
        for run in runs(of: id) {
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

    /// How a page reads on the roll while the editor is somewhere else
    /// (issue #79), built on first use from the core's own document.
    /// Under ADR-0033 the editor can also be in the other window: the
    /// glance the window that does not own draws over its own private
    /// storage is a `QuietRendering` of the same page.
    ///
    /// Deliberately **not** `storage(for:)`. The map above is the
    /// editor's, and a quiet region borrowing an entry from it would put
    /// two layout managers on one storage, hand `shedLayoutManagers` a
    /// manager to rip out from under a region that is still on screen,
    /// and enter the roll into the parity assertion that compares one
    /// storage to one core document. A rendering of its own keeps every
    /// storage in the app at exactly one view and exactly one manager,
    /// which is the invariant ADR-0006 rests on stated as a property of
    /// the object graph rather than as a rule to remember. ADR-0033
    /// depends on this same object graph: two windows over one model
    /// remain one editor per page because the non owning window mounts
    /// the glance, never a second live editor.
    ///
    /// It is a rendering and not an editor: the roll copies it into a
    /// storage no delegate is watching, so nothing it holds can emit an
    /// op, and the chips in it carry the same non-secret face they
    /// carry on the live page and no bytes at all.
    /// A quiet page's rendering contract (ADR-0030). Under `.allPages` a
    /// quiet region reads the same as the mounted editor for Markdown
    /// structure, code typography, links, lists, fence wash and syntax
    /// tokens — but never for block created/modified labels, which are
    /// editor-only. The attributed text carries the styled ink; the
    /// fence regions are the character ranges an `InkLayoutManager` paints
    /// as one slab per region. `.focusedOnly` and `.never` hand back
    /// plain ink and an empty region list.
    ///
    /// A class rather than a struct so the roll's cache-hit comparison
    /// (`!==`) stays an identity check.
    public final class QuietRendering {
        public let text: NSAttributedString
        public let fenceRegions: [NSRange]
        public init(text: NSAttributedString, fenceRegions: [NSRange]) {
            self.text = text
            self.fenceRegions = fenceRegions
        }
    }

    public func quietRendering(for id: UInt64) -> QuietRendering {
        if let existing = quietRenderings[id] { return existing }
        let rendered = NSMutableAttributedString()
        for run in client.documentRuns(sheet: id) {
            switch run {
            case .ink(let text):
                rendered.append(NSAttributedString(
                    string: text,
                    attributes: [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]
                ))
            case .chip(let info):
                rendered.append(NSAttributedString(attachment: ChipAttachment(info: info)))
            }
        }
        // `.allPages` runs the same block walk over a temporary storage
        // that the mounted editor runs over its live one, so a quiet day
        // reads as a fence, a heading or a list wherever the focused page
        // would. Block created/modified labels are editor-only per
        // ADR-0030, so quiet passes `renderBlockLabels: false`: the label
        // stamps and their reserved paragraph spacing are both suppressed.
        // The payload carries the fence regions the styling walk returned
        // so a quiet region's `InkLayoutManager` can paint the same slab
        // the editor would. `.focusedOnly` and `.never` return plain ink.
        if previewRendering == .allPages, !id.isFileID {
            // A throwaway storage keeps the styling pass off any layout
            // manager: the roll copies the result into its own storage,
            // and the copy is what the region draws (ADR-0006).
            let scratch = NSTextStorage(attributedString: rendered)
            let (regions, _, _) = InkEditorView.Coordinator.applyMarkdownStyling(
                to: scratch,
                sheet: id,
                blockMetas: [],
                syntaxHighlightingEnabled: syntaxHighlightingEnabled,
                fenceRenderingLanguages: fenceRenderingLanguages(for: id),
                renderBlockLabels: false
            )
            let styled = NSAttributedString(attributedString: scratch)
            let payload = QuietRendering(text: styled, fenceRegions: regions)
            quietRenderings[id] = payload
            return payload
        }
        let payload = QuietRendering(
            text: NSAttributedString(attributedString: rendered),
            fenceRegions: []
        )
        quietRenderings[id] = payload
        return payload
    }

    /// Forget how a page reads quietly, because the page has changed.
    ///
    /// Called from every path in this file that moves a page's document
    /// (an accepted op batch, a wholesale mirror, a chip burned out of
    /// one), and by the roll as the editor lands on a page, which is the
    /// moment a page starts being able to change. Without it this cache
    /// would go on holding the page as it stood before, so the day the
    /// user just wrote on would come back, when they moved to another
    /// one, showing what it said before they arrived.
    ///
    /// Dropping the entry is the whole of it: the next reader rebuilds
    /// from the core, and the roll notices because the object it gets
    /// back is not the one its region was seeded from.
    public func invalidateQuietRendering(for id: UInt64) {
        quietRenderings[id] = nil
    }

    /// Snapshot of the fence-language labels a page carries in its
    /// presentation state, keyed by the paragraph location of each
    /// bare fence's opening rule. Read by both the mounted editor's
    /// styling walk and `quietRendering(for:)`, so a fence a reader
    /// coloured on one page looks the same when the editor is standing
    /// on another day.
    public func fenceRenderingLanguages(for id: UInt64) -> [Int: String] {
        fenceRenderingLanguages[id] ?? [:]
    }

    /// Attach a language name to a bare fence's opening paragraph on
    /// the given page. Presentation only: no text is rewritten and
    /// nothing in the core moves. The page's quiet cache is dropped so
    /// the roll rebuilds it under the new label.
    public func setFenceRenderingLanguage(
        _ language: String, sheet: UInt64, at paragraphLocation: Int
    ) {
        fenceRenderingLanguages[sheet, default: [:]][paragraphLocation] = language
        invalidateQuietRendering(for: sheet)
    }

    /// Drop every fence-language label a page was carrying. Called on
    /// a structural rewrite of the page's projection, since the
    /// paragraph locations the labels were keyed against no longer
    /// name the fences they were placed above.
    public func clearFenceRenderingLanguages(for sheet: UInt64) {
        guard fenceRenderingLanguages.removeValue(forKey: sheet) != nil else { return }
        invalidateQuietRendering(for: sheet)
    }

    /// Which pages the editor has a storage for.
    ///
    /// A reading seam for the tests that assert the roll never borrows
    /// one (issue #79): every quiet day renders over a storage of its
    /// own, and asking `storage(for:)` whether a page has one would make
    /// one, which is the very thing under test.
    var pagesWithStorage: Set<UInt64> { Set(storages.keys) }

    // MARK: Navigation — the keyboard map

    /// What ⌘1 to ⌘9 count through and ⌥⌘←/→ walk, in the order the
    /// surface draws them (issue #79).
    ///
    /// With the mode off this is the strip, element for element, and a
    /// test says exactly that
    /// (`visibleTargetsWithTheModeOffEqualTheStripElementForElement`).
    /// That identity is the whole evidence for "horizontal mode is
    /// unchanged": the two modes share one routing path instead of two
    /// that would have to be kept in step by hand, and the shared
    /// path's value with the mode off is the array these gestures have
    /// always indexed.
    ///
    /// With the mode on it is one entry per visible day, newest first,
    /// so ⌘2 means the second day rather than the second slot. A day
    /// holding more than one page answers with the first of them in
    /// strip order, and only today can be a day with no page at all,
    /// which is the single `.today` entry.
    ///
    /// Open files come first, in open order, in both modes, which is
    /// the order both layouts draw: the FILES group sits before the PAD
    /// group on the strip and the Files shelf sits above the days on
    /// the rail. With no file open the array is exactly what it has
    /// always been, element for element, in both modes.
    public var visibleTargets: [SurfaceTarget] {
        let files = navigationFiles.map { SurfaceTarget.file($0.id) }
        guard showsTimeUnits else { return files + navigationTabs.map { .tab($0.id) } }
        return files + timeUnits.units.map { unit -> SurfaceTarget in
            guard let tab = unit.tabIDs.first else { return .today }
            return .tab(tab)
        }
    }

    /// Select whatever the surface is drawing at that entry.
    ///
    /// Both arms are gestures the app already ships: a slot goes
    /// through `select(_:)`, which mints into it when it holds nothing,
    /// and today goes through `startToday()`, which selects today's page
    /// when there is one and otherwise takes the shipped create path.
    /// Nothing new mints here, and nothing mints at all without a
    /// gesture asking for it (ADR-0017).
    public func select(target: SurfaceTarget) {
        switch target {
        case .tab(let id):
            select(id)
        case .today:
            // A place, not an ask for another page: `.today` exists
            // only while today holds no page, so this can only mint the
            // first one (issue #158).
            startToday()
        case .file(let id):
            selectFile(id)
        }
    }

    /// Show an open file. The roll gives way to that file alone, and
    /// the slot the person left keeps its place, so selecting a day
    /// afterwards puts them back where they were.
    ///
    /// It mints nothing and starts no clock, which is the whole of what
    /// separates this from `select(_:)`: a file is not a slot, and
    /// there is no empty file to conjure.
    public func selectFile(_ id: UInt64) {
        if pads.isEnabled, let file = openFiles.first(where: { $0.id == id }) {
            let target = pads.owner(ofFile: file.path)
            if target != pads.activeID {
                activatePad(target)
                guard pads.activeID == target else { return }
            }
        }
        showingLedger = false
        if pendingFileClose?.fileID != id {
            clearPendingFileClose()
        }
        guard selectedFile != id else { return }
        selectedFile = id
        refocusEditorIfKeyed()
    }

    /// The roster the surface draws, restated.
    ///
    /// Internal because populating it is the model lane's work, not the
    /// view's: the file store is what will call this, and the tests
    /// call it to stand a roster up without a file on disk. It drops a
    /// selection naming a file the roster no longer holds, so a closed
    /// file cannot leave the surface pointing at nothing.
    func standOpenFiles(_ files: [FileSummary]) {
        if pads.isEnabled {
            pads.transferFiles(files.compactMap { new in
                guard let old = openFiles.first(where: { $0.id == new.id }), old.path != new.path else { return nil }
                return (old.path, new.path)
            })
        }
        openFiles = files
        if let pending = pendingFileClose {
            if let file = files.first(where: { $0.id == pending.fileID }) {
                // A pending close is answered only by its own three
                // actions; nothing here closes a tab, and a second
                // close gesture on the same tab is a no-op while the
                // decision stands. A file that came clean by any other
                // route (⌘S, an Undo back to the saved text, Take
                // theirs) has had its question overtaken, so
                // the decision is withdrawn and the tab stays, undo
                // and redo history intact. Closing is the one step on
                // this surface that cannot be undone, which is why only
                // an explicit answer may take it.
                if !file.holdsUnsavedEdits {
                    clearPendingFileClose()
                }
            } else {
                clearPendingFileClose()
            }
        }
        if let selectedFile, !files.contains(where: { $0.id == selectedFile }) {
            self.selectedFile = nil
        }
        forgetFilesOffTheRoster(files)
        let live = Set(files.map(\.id))
        fileRenderModes = fileRenderModes.filter { live.contains($0.key) }
        explicitFileRenderModes.formIntersection(live)
        dismissedFileRenderSuggestions.formIntersection(live)
        for (id, requestID) in fileLanguageRequestIDs where !live.contains(id) {
            fileLanguageDetection.cancel(requestID: requestID)
        }
        fileLanguageRequestIDs = fileLanguageRequestIDs.filter { live.contains($0.key) }
        fileContentRenderHints = fileContentRenderHints.filter { live.contains($0.key) }
        fileRenderSuggestions = fileRenderSuggestions.filter { live.contains($0.key) }
    }

    /// The counterpart to the tag exemption in the two prunes.
    ///
    /// A file's storage, caret and scroll are exempt from the page
    /// prunes because a file is never in `tabs`, so nothing there can
    /// ever drop them. This is what does, and it hangs off the roster
    /// rather than off any one gesture: every way a file leaves,
    /// whether a close after Save or Discard or the automatic drop of
    /// a clean file that was gone at restore, ends in a roster that no
    /// longer names it, and this runs on all of them. Keyed on the tag
    /// so a page id can never be swept by it.
    private func forgetFilesOffTheRoster(_ files: [FileSummary]) {
        let live = Set(files.map(\.id))
        let gone = storages.keys.filter { $0.isFileID && !live.contains($0) }
        for id in gone {
            storages[id] = nil
            viewStates.forget(id)
        }
        // A file can leave with no storage ever built, if it was never
        // drawn, and a caret may still be held for it from a mount that
        // came and went. So the view state is swept on its own terms
        // too rather than only alongside a storage. It is the model's
        // own table now, so the sweep reaches it whether or not an
        // editor happens to be mounted when the file goes.
        for id in viewStates.keys where id.isFileID && !live.contains(id) {
            viewStates.forget(id)
        }
    }

    // MARK: Files: the peer content class to pages

    /// Restate the roster from the core, which is the authority for
    /// every file's name, path, dirtiness and conflict.
    ///
    /// Called after everything that could have moved any of those: an
    /// open, an edit, a save, a reload, a close, a conflict
    /// resolution, a restore. The roster is asked for whole rather
    /// than patched, so no field the shell forgot to update can drift
    /// away from what the core holds.
    public func refreshOpenFiles() {
        standOpenFiles(client.fileRoster())
    }

    private func cancelFileLanguageDetection(for id: UInt64) {
        guard let requestID = fileLanguageRequestIDs.removeValue(forKey: id) else { return }
        fileLanguageDetection.cancel(requestID: requestID)
    }

    private func fileTextSnapshot(for id: UInt64) -> String {
        client.fileRuns(id).reduce(into: "") { text, run in
            if case .ink(let ink) = run { text += ink }
        }
    }

    /// Seed Markdown's stable filename default and offer source-language hints.
    /// Content inference is asynchronous and only contributes when there is no
    /// explicit choice and no stronger filename hint.
    private func reconsiderFileRenderMode(for id: UInt64, resetDismissal: Bool = false) {
        guard let file = openFiles.first(where: { $0.id == id }) else { return }
        cancelFileLanguageDetection(for: id)
        fileRenderSuggestions[id] = nil
        // A replacement buffer is a new revision. A previous dismissal must
        // not suppress a new proposal, while an explicit mode remains the
        // strongest session choice.
        if resetDismissal {
            dismissedFileRenderSuggestions.remove(id)
            fileContentRenderHints[id] = nil
        }
        if !explicitFileRenderModes.contains(id) {
            if FileFormatHints.markdownExtensions.contains((file.name as NSString).pathExtension.lowercased()) {
                fileRenderModes[id] = .markdown
                return
            }
            fileRenderModes[id] = .plainText
        }
        guard !explicitFileRenderModes.contains(id), !dismissedFileRenderSuggestions.contains(id) else { return }
        let filenameHint = Self.filenameRenderHint(for: file.name)
        if let filenameHint {
            fileRenderSuggestions[id] = FileRenderSuggestion(fileID: id, mode: filenameHint)
        }
        guard PageModel.languageDetectionFeaturesAvailable, modelLanguageDetectionEnabledForFileHints else { return }
        let snapshot = fileTextSnapshot(for: id)
        let request = LanguageDetectionRequest(
            documentID: id, revision: 0, targetRange: NSRange(location: 0, length: snapshot.utf16.count),
            trigger: .manual, selectionSnapshot: NSRange(location: 0, length: 0), data: Data(snapshot.utf8)
        )
        fileLanguageRequestIDs[id] = request.requestID
        fileLanguageDetection.submit(request, validating: { [weak self] context in
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                guard let self, self.fileLanguageRequestIDs[context.documentID] == context.requestID,
                      !self.explicitFileRenderModes.contains(context.documentID),
                      !self.dismissedFileRenderSuggestions.contains(context.documentID),
                      self.fileTextSnapshot(for: context.documentID) == snapshot
                else { return false }
                return true
            }
        }, completion: { [weak self] result in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self, self.fileLanguageRequestIDs[result.context.documentID] == result.context.requestID else { return }
                self.fileLanguageRequestIDs[result.context.documentID] = nil
                guard let language = result.language, language.lowercased() != "markdown" else { return }
                let contentHint = FileRenderMode.source(language)
                self.fileContentRenderHints[result.context.documentID] = contentHint
                // A recognized filename wins the initial offer. The picker
                // still exposes this content result when the two disagree.
                guard let file = self.openFiles.first(where: { $0.id == result.context.documentID }),
                      Self.filenameRenderHint(for: file.name) == nil
                else { return }
                self.fileRenderSuggestions[result.context.documentID] = FileRenderSuggestion(
                    fileID: result.context.documentID, mode: contentHint
                )
            }
        })
    }

    private var modelLanguageDetectionEnabledForFileHints: Bool { languageDetectionEnabled }

    public nonisolated static func filenameRenderHint(for name: String) -> FileRenderMode? {
        let ext = (name as NSString).pathExtension.lowercased()
        let languages = [
            "swift": "swift", "rs": "rust", "py": "python", "rb": "ruby",
            "js": "javascript", "mjs": "javascript", "ts": "typescript", "tsx": "typescript",
            "go": "go", "sh": "shell", "bash": "shell", "zsh": "shell",
            "sql": "sql", "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        ]
        return languages[ext].map(FileRenderMode.source)
    }

    /// Ask for a file and open it. The panel lives in the file
    /// coordinator, never here.
    public func openFile() {
        duringFilePanel {
            guard let url = fileCoordinator.chooseFileToOpen() else { return }
            openFile(at: url)
        }
    }

    /// Run a gesture that raises a file panel, from the panel going up
    /// to the last thing done with its answer, and then make the
    /// activation check that was put off while it ran, if one was.
    ///
    /// A panel is modal and the main queue drains while it is up, so
    /// the app can be activated underneath it: a person who goes to
    /// the Finder to look for the file they are about to choose, and
    /// comes back, has done exactly that. The check that activation
    /// asks for can drop a held row, follow a moved file to a new
    /// path or reload a buffer, and the gesture in progress is about
    /// one of those rows and is holding what it read of it before the
    /// panel went up. So the check waits (`checkOpenFilesOnActivate`)
    /// and is made here, once, when the gesture is over and the
    /// roster is whatever the gesture left.
    private func duringFilePanel(_ gesture: () -> Void) {
        filePanelGestures += 1
        defer {
            filePanelGestures -= 1
            consumeOwedActivationCheck()
        }
        gesture()
    }

    private func consumeOwedActivationCheck() {
        guard activationCheckOwed, filePanelGestures == 0, !ModalSession.isBracketed else { return }
        // Clear before checking so synchronous observers cannot consume it twice.
        activationCheckOwed = false
        checkOpenFilesOnActivate()
    }

    /// Open the file at `url`, the path a panel or a drop produced.
    ///
    /// The core does the reading, so this refuses nothing itself: a
    /// file that is not UTF-8, or is past the size limit, or will not
    /// be read at all comes back as a refusal naming itself, and the
    /// panel's own type filter is a convenience rather than the rule.
    ///
    /// The read and the bookmark both happen inside the access bracket
    /// on that URL. A panel's URL usually arrives with its grant
    /// already open; a URL from elsewhere may not, and the bracket
    /// covers both.
    ///
    /// An open never lands on a pending row. The core hands back the
    /// id a path is already open under, and a row still waiting on its
    /// hydration has a buffer that is not the file's text, so raising
    /// it as the answer to an open would draw an empty file under the
    /// person's filename. The rule is to hydrate first: a pending row
    /// at this path is asked inside this bracket, where the panel's
    /// grant is what lets the read through, and the open is made
    /// afterwards. A row that settles is the file the open then hands
    /// back. One that was dropped leaves the path free and the open
    /// reads the file afresh. One that is still held is refused by the
    /// core, and the refusal is said like any other.
    public func openFile(at url: URL) {
        if pads.isEnabled, pendingFileClose != nil {
            flash("Finish the file close decision before opening another file.")
            return
        }
        // The bracket closes before anything is said or drawn: what it
        // guards is the core's read and the bookmark, and nothing
        // after them touches the file.
        var owed: [DraftNotice] = []
        var droppedPendingRow = false
        let opened: (id: UInt64, bookmarked: Bool)? = fileCoordinator.withAccess(to: url) {
            // Asked of the core rather than of the published roster,
            // so the rule holds for any pending row and not only for
            // the ones the surface happens to be showing.
            for row in client.fileRoster()
            where row.pendingHydration && Self.samePath(row.path, url.path) {
                discardStaleDraftNotices()
                _ = client.hydrateFile(row.id, resolvedPath: nil)
                if !client.fileRoster().contains(where: { $0.id == row.id }) {
                    droppedPendingRow = true
                }
                // A dropped row's notice is moot, since the open below
                // reads the file on its own account. A draft that was
                // too large to keep is still owed its sentence.
                owed += client.draftNotices().filter { $0.reason == .draftTooLarge }
            }
            guard let id = client.openFile(path: url.path) else { return nil }
            // The bookmark is taken here, while access is open, and
            // again after every save. It is handed straight to the
            // core, which carries it into the drafts file and gives it
            // back at the next launch.
            return (id, renewBookmark(for: id, from: url))
        }
        guard let opened else {
            flash(Self.openRefusalNotice(
                name: url.lastPathComponent, json: client.openFileErrorJSON()
            ))
            // A pending row at the path may have been dropped on the
            // way to this refusal, and the surface must not go on
            // showing it.
            refreshOpenFiles()
            if droppedPendingRow { markFilesDirty() }
            return
        }
        let id = opened.id
        // A held row this open settled was filled from a copy nobody
        // had read, and the person has just asked for exactly that, so
        // the reload flag it may carry is answered without a sentence.
        client.clearFileReloadNotice(id)
        if !opened.bookmarked, owesBookmark(path: url.path) {
            flash(Self.bookmarkFailureNotice(name: url.lastPathComponent))
        } else if let sentence = Self.launchNotice(reloaded: [], notices: owed) {
            flash(sentence)
        }
        // A reopen of a file that is already open hands back the same
        // id core-side, so the editor may be mounted over this exact
        // storage right now. Restate it in place rather than dropping
        // the entry: dropping it would leave the text view laying out
        // an object the model no longer knows about, and nothing would
        // rebuild it, because `selectFile` returns early on a
        // selection that did not change and `updateNSView` returns
        // early on a sheet that did not change.
        if storages[id] != nil {
            restateStorage(sheet: id)
        }
        refreshOpenFiles()
        reconsiderFileRenderMode(for: id)
        if pads.isEnabled {
            let target = pads.pad(forPath: url.path) ?? pads.activeID
            pads.assign(filePath: openFiles.first(where: { $0.id == id })?.path ?? url.path, to: target)
            activatePad(target)
        }
        selectFile(id)
        markFilesDirty()
    }

    /// Open the user's keymap file (`keymap.json` under the form
    /// factor's configuration directory) as an ordinary document.
    ///
    /// The configuration directory is created on demand and the file
    /// is seeded with the bundled default when it does not yet exist,
    /// so the item the person is opening is the file the app already
    /// reads. This is the one place that creates the directory: the
    /// launch path leaves it alone on purpose (`configurationDirectory`
    /// on FormFactor), because absence is the ordinary case; a click
    /// on this menu item is the moment the user chose otherwise.
    ///
    /// A test suite that did not name a keymap seam has no file to
    /// open at all (`userKeymapURL` refuses the installed path under
    /// the runner), and the call flashes an actionable notice rather
    /// than doing nothing.
    public func openUserKeymapFile() {
        guard let url = userKeymapFileURL else {
            flash(Self.keymapUnavailableNotice, tone: .actionable)
            return
        }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            let directory = url.deletingLastPathComponent()
            do {
                try manager.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                flash(Self.keymapSeedFailureNotice, tone: .actionable)
                return
            }
            let seed = Keymap.bundledDefaultText() ?? "[]\n"
            do {
                try seed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                flash(Self.keymapSeedFailureNotice, tone: .actionable)
                return
            }
        }
        openFile(at: url)
    }

    /// Write the selected file back to its own path. The second reading
    /// of the save chord: on a page it flushes sealed state as it
    /// always has.
    public func saveActiveFile() {
        guard let file = activeFile else { return }
        saveFile(file.id)
    }

    /// Write one file, with the before-save check decisions.md item 5
    /// asks for.
    ///
    /// The check runs first and can itself put the file into a
    /// conflict, which is the point: a save that discovered the change
    /// only by overwriting it would be the one outcome nobody wants.
    /// A file already standing in an unresolved conflict is refused
    /// out loud, since the banner's actions are the way out and
    /// silently writing would make the banner a lie. A conflict the
    /// save's own check raises is refused out loud the same way, and a
    /// standing missing conflict is checked again first, so a file
    /// that has come back is judged as the file it now is.
    ///
    /// The check, the write and the fresh bookmark are one access
    /// bracket, opened once. They are one act as far as the person is
    /// concerned, and a scope closed between the check and the write
    /// would leave a moment in which the file the check approved is
    /// not the file the write can reach.
    ///
    /// A save never makes a file where there is none. The core refuses
    /// a save whose path holds nothing, and the sentence then names
    /// Locate and Save As, which are the two ways to say where the text
    /// should go. The exception is a draft the person has chosen keep
    /// mine for, which is written, as it was before.
    @discardableResult
    public func saveFile(_ id: UInt64) -> Bool {
        guard let before = openFiles.first(where: { $0.id == id }) else { return false }
        // A held file's buffer is empty because nothing was read, not
        // because the file is. The core refuses the write whatever is
        // asked here; this is the sentence that says why.
        guard !before.pendingHydration else {
            flash(Self.heldFileNotice(name: before.name), tone: .actionable)
            return false
        }
        // A conflict over a copy that is there is refused from the row
        // as it stands: the banner's answers are the way out and
        // nothing the disk does takes the question back. A missing
        // conflict is different. It says nothing is at the path, which
        // stops being true the moment another tool puts the file back,
        // and a refusal read off a stale row would then be a sentence
        // about a file that is there. So that one is looked at again
        // below before anything is refused.
        guard before.conflict == .none || before.conflict == .missing else {
            flash(Self.unresolvedConflictNotice(for: before), tone: .actionable)
            return false
        }
        return withFileAccess(id) { resolved in
            // The check can reload a clean file out from under the save,
            // which the person is owed a word about, and it can put a
            // dirty one into a conflict.
            if let outcome = applyCheck(for: id, resolved: resolved),
               let sentence = Self.activationNotice([outcome]) {
                flash(sentence)
            }
            guard let file = openFiles.first(where: { $0.id == id }) else { return false }
            guard file.conflict == .none else {
                // A save was asked for and is not happening, so it is
                // said, in the sentence for the conflict the check has
                // just found or confirmed. It takes the place of
                // whatever the check had to say, because a person who
                // pressed save is owed the ways out and not only the
                // news. Without it a draft typed over a file already
                // marked gone would be refused with no word at all.
                flash(Self.unresolvedConflictNotice(for: file), tone: .actionable)
                return false
            }
            let target = URL(fileURLWithPath: file.path)
            let result = fileCoordinator.withStagingDirectory(for: target) { staging -> Bool? in
                guard let staging else { return nil }
                return client.saveFile(id, stagingDirectory: staging.path)
            }
            guard let wrote = result else {
                flash(Self.writeRefusalNotice(name: file.name), tone: .actionable)
                return false
            }
            guard wrote else {
                // The core answers false for every refusal and keeps
                // the reason, which is asked for before anything else
                // is asked of it. The sentence is chosen from that
                // reason. The row is read again only because a refusal
                // can move it, into the missing conflict or out of a
                // consent, and the sentence for a conflict names the
                // ways out of the one the row is now in.
                let refusal = client.saveFileRefusal()
                refreshOpenFiles()
                let after = openFiles.first(where: { $0.id == id }) ?? file
                flash(Self.saveRefusalNotice(refusal, for: after), tone: .actionable)
                return false
            }
            // The write put a new file at the path, and the old
            // bookmark followed the old one. Made again while the
            // scope is still open, from the URL the scope is on when
            // that is where the core wrote, since that is the URL the
            // grant belongs to.
            //
            // When the scope's URL is not where the core wrote, the
            // file was moved while it was open and the write has made a
            // new one at the path the core holds. The old bookmark
            // names the moved file, so if no new one can be made it is
            // dropped rather than left to lead the next launch there.
            let inScope = resolved.flatMap { Self.samePath($0.path, file.path) ? $0 : nil }
            let strayed = resolved != nil && inScope == nil
            let source = inScope ?? target
            if !renewBookmark(for: id, from: source, orphansHeld: strayed),
               owesBookmark(path: file.path) {
                flash(Self.bookmarkFailureNotice(name: file.name))
            }
            // The roster is what the header and the dots read, and a save
            // moved the dirty flag and the conflict, so the surface is
            // restated before anything else looks at it. The drafts owe a
            // write too: this file no longer carries a snapshot.
            refreshOpenFiles()
            markFilesDirty()
            return true
        }
    }

    /// Write the selected file somewhere else and adopt that path.
    public func saveActiveFileAs() {
        duringFilePanel { saveActiveFileAsThroughPanel() }
    }

    private func saveActiveFileAsThroughPanel() {
        guard let asked = activeFile else { return }
        // Said before the panel rather than after it: a held file has
        // nothing to write, and asking for a destination first would
        // be asking for an answer that cannot be used.
        guard !asked.pendingHydration else {
            flash(Self.heldFileNotice(name: asked.name), tone: .actionable)
            return
        }
        guard let url = fileCoordinator.chooseDestination(suggestedName: asked.name) else { return }
        // Read again now the panel is down, for the reason the locate
        // reads its row again: the path compared below has to be the
        // one the core holds now.
        guard let file = openFiles.first(where: { $0.id == asked.id }) else { return }
        // Compared on the resolved path, because the roster's path is
        // the one the core resolved through symlinks at open and the
        // panel hands back whatever the person navigated to. On this
        // system /tmp and /private/tmp are the same directory.
        let target = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
        // Everything from here to the bookmark runs inside the access
        // bracket on the URL the panel handed over. The write is the
        // core's and the panel's grant is what lets it land.
        fileCoordinator.withAccess(to: url) {
            // Picking the file's own name in the save panel is a save, not
            // a save as, and every save is checked immediately before it
            // writes (decisions.md item 5). Without this the one path that
            // can overwrite a changed disk copy with no conflict raised is
            // the panel, which is the last place a person would expect it.
            // The save opens the file's own bracket inside this one,
            // and each closes what it opened.
            //
            // Only while something is at that path. A save refuses to
            // make a file where there is none, and here the person has
            // just chosen this destination in a panel, which is the
            // consent a bare save lacks. With nothing there, there is
            // also no disk copy a check could protect, so the choice
            // goes on as the save as it is and writes the file.
            if URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path == target,
               FileManager.default.fileExists(atPath: target) {
                saveFile(file.id)
                return
            }
            let result = fileCoordinator.withStagingDirectory(for: url) { staging -> Bool? in
                guard let staging else { return nil }
                return client.saveFile(file.id, as: url.path, stagingDirectory: staging.path)
            }
            guard let wrote = result else {
                flash(Self.writeRefusalNotice(name: url.lastPathComponent), tone: .actionable)
                return
            }
            guard wrote else {
                // The core refuses a target another open file already
                // holds, before anything is written, and says that this
                // was the reason. The roster is read only for the name
                // of the tab that holds it, which the sentence owes the
                // person and the reason does not carry.
                let refusal = client.saveFileRefusal()
                let holder = openFiles.first(where: {
                    $0.id != file.id
                        && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target
                })?.name
                let sentence = Self.saveAsRefusalNotice(
                    refusal, file: file.name, target: url.lastPathComponent, holder: holder
                )
                flash(sentence.text, tone: sentence.tone)
                return
            }
            // The identity moved, so the bookmark has to move with it, or
            // the next launch would reopen the file the person saved away
            // from. Made after the write, because the write is what put
            // the file there, and before the bracket closes. When it
            // cannot be made the old one is dropped, not kept: it is a
            // bookmark for the file that was saved away from.
            if !renewBookmark(for: file.id, from: url, orphansHeld: true),
               owesBookmark(path: url.path) {
                flash(Self.bookmarkFailureNotice(name: url.lastPathComponent))
            }
            refreshOpenFiles()
            reconsiderFileRenderMode(for: file.id, resetDismissal: true)
            markFilesDirty()
        }
    }

    /// Close the selected file. A clean file closes immediately. A dirty
    /// file publishes an inline decision and remains editable.
    ///
    /// A held file closes immediately whatever its record says. The
    /// decision offers to save, discard or keep editing a draft, and a
    /// held file has none: its buffer is empty because nothing was
    /// read, and a record that came back dirty after its draft was too
    /// large to keep is dirty in name only. Asking would be asking
    /// about nothing, and its Save could only be refused.
    @discardableResult
    public func closeActiveFile() -> Bool {
        guard let file = activeFile else { return false }
        guard !file.holdsUnsavedEdits else {
            beginPendingFileClose(
                file, returningTo: selectedFile, returningToLedger: showingLedger
            )
            return false
        }
        return closeFileNow(file.id)
    }

    /// Close a named file, which is what the ✕ on a row asks for. A dirty
    /// non-active file is selected so its inline decision appears above its
    /// editor; Keep editing returns to the surface that was showing.
    /// A held file closes at once, for the reason `closeActiveFile`
    /// gives.
    public func closeFile(_ id: UInt64) {
        guard let file = openFiles.first(where: { $0.id == id }) else {
            clearPendingFileClose()
            return
        }
        let wasShowing = selectedFile
        if pendingFileClose?.fileID != id { clearPendingFileClose() }
        if file.holdsUnsavedEdits {
            let wasShowingLedger = showingLedger
            selectedFile = id
            showingLedger = false
            beginPendingFileClose(
                file, returningTo: wasShowing, returningToLedger: wasShowingLedger
            )
            refocusEditorIfKeyed()
        } else {
            _ = closeFileNow(id)
        }
    }

    /// Resolve the inline dirty-close decision. Save closes only after a
    /// successful write; Discard closes without writing; Keep editing closes
    /// nothing and restores the prior surface when the request came from
    /// another file's row.
    public func resolvePendingFileClose(_ action: FileCloseAction) {
        guard let pending = pendingFileClose,
              openFiles.contains(where: { $0.id == pending.fileID })
        else {
            clearPendingFileClose()
            return
        }
        switch action {
        case .save:
            guard saveFile(pending.fileID) else { return }
            // The save's own roster refresh withdrew the decision (the
            // file is clean now) but closed nothing: this is the answer
            // that closes, and it closes only after the write landed.
            // The check writes down that the only id this closes is one
            // the core still holds, rather than leaning on file ids
            // never being reused.
            guard openFiles.contains(where: { $0.id == pending.fileID }) else { return }
            clearPendingFileClose()
            _ = closeFileNow(pending.fileID)
        case .discard:
            clearPendingFileClose()
            _ = closeFileNow(pending.fileID)
        case .keepEditing:
            let previous = selectionBeforePendingFileClose
            let previousLedger = ledgerBeforePendingFileClose
            clearPendingFileClose()
            if selectedFile == pending.fileID, previous != pending.fileID {
                selectedFile = previous.flatMap { previousID in
                    openFiles.contains(where: { $0.id == previousID }) ? previousID : nil
                }
                showingLedger = previousLedger
                refocusEditorIfKeyed()
            }
        }
    }

    private func beginPendingFileClose(
        _ file: FileSummary, returningTo selection: UInt64?, returningToLedger: Bool
    ) {
        guard pendingFileClose?.fileID != file.id else { return }
        pendingFileClose = PendingFileClose(fileID: file.id, name: file.name)
        selectionBeforePendingFileClose = selection
        ledgerBeforePendingFileClose = returningToLedger
    }

    private func clearPendingFileClose() {
        pendingFileClose = nil
        selectionBeforePendingFileClose = nil
        ledgerBeforePendingFileClose = false
    }

    @discardableResult
    private func closeFileNow(_ id: UInt64) -> Bool {
        guard client.closeFile(id) else { return false }
        storages[id] = nil
        refreshOpenFiles()
        markFilesDirty()
        return true
    }


    /// Settle a file that changed on disk under unsaved edits. Save
    /// stays refused until one of the three is chosen.
    public func resolveConflict(_ resolution: FileConflictResolution) {
        guard let file = activeFile else { return }
        // A held row has no copy to choose. Only locating it is meaningful.
        guard !file.isHeld || resolution == .locate else { return }
        switch resolution {
        case .keepMine:
            // No confirmation. Nothing is lost at this moment: the
            // copy on disk is overwritten by the next save, which is
            // its own deliberate gesture and has its own chord.
            // Bracketed because the core looks at the file on disk to
            // record what the consent was given against.
            if !withFileAccess(file.id, { _ in client.resolveFileKeepMine(file.id) }) {
                refreshOpenFiles()
                let current = openFiles.first(where: { $0.id == file.id }) ?? file
                flash("Keep mine could not be applied. " + Self.unresolvedConflictNotice(for: current),
                      tone: .actionable)
            }
        case .takeTheirs:
            // The core's read is what needs the bracket; the restating
            // below reads only what the core already holds.
            guard withFileAccess(file.id, { _ in client.resolveFileTakeTheirs(file.id) }) else {
                flash(Self.readRefusalNotice(name: file.name), tone: .actionable)
                // The refused read is itself news about the file: the
                // core now knows the copy on disk cannot be read, or
                // is gone. Restated so the banner stops offering the
                // action that has just failed and offers Locate.
                refreshOpenFiles()
                return
            }
            restateStorage(sheet: file.id)
            refreshOpenFiles()
            reconsiderFileRenderMode(for: file.id, resetDismissal: true)
        case .saveAs:
            // Save As settles the conflict by moving the identity
            // somewhere nothing else has written, so it is the same
            // path the chord takes and not a variant of it.
            saveActiveFileAs()
            return
        case .locate:
            locateFile(file.id)
            return
        }
        if resolution != .takeTheirs { refreshOpenFiles() }
        markFilesDirty()
    }

    // MARK: Files: locating one that cannot be reached

    /// Ask the person where a file is now, and bind the open file to
    /// their answer.
    ///
    /// This is the way back for a file that is no longer at its path,
    /// or is there and cannot be read: the bookmark could not be made
    /// or no longer resolves, or the scope will not start. The person
    /// knows where the file is, and the panel they answer in is also
    /// what grants the access that was missing, so one gesture mends
    /// both.
    ///
    /// Everything after the panel runs inside the access bracket on
    /// the URL it handed over: the core's read, and the fresh bookmark
    /// that replaces the one that failed.
    ///
    /// The core settles the file as a launch would. A file with no
    /// draft takes the text of the file chosen. A draft stands, with no
    /// conflict when the file chosen is the one the draft was measured
    /// against, and in a conflict otherwise, where the three actions
    /// choose between the copies and Take theirs now has a copy to
    /// take.
    ///
    /// A cancel changes nothing. A file that is already open in
    /// another tab is refused with its own sentence, and one that is
    /// not UTF-8 text or is past the size limit is refused with the
    /// sentence an open gives. After either the file is exactly as it
    /// was.
    ///
    /// It asks for no confirmation and has no chord, like the three
    /// actions it stands beside.
    public func locateFile(_ id: UInt64) {
        duringFilePanel { locateFileThroughPanel(id) }
    }

    private func locateFileThroughPanel(_ id: UInt64) {
        guard let asked = openFiles.first(where: { $0.id == id }) else { return }
        guard let url = fileCoordinator.chooseFileToLocate(recordedPath: asked.path) else { return }
        // Read again now the panel is down. The main queue drains
        // while a panel is up, and the row the panel was raised about
        // is only worth acting on if it is still here.
        guard let file = openFiles.first(where: { $0.id == id }) else { return }
        discardStaleDraftNotices()
        fileCoordinator.withAccess(to: url) {
            // The core refuses a path another open file holds, and all
            // it can answer is false. The roster is the same answer
            // and it is here, so the refusal gets its own sentence, as
            // Save As does it and for the same reason.
            var holderNews: String?
            if let held = openFiles.first(where: {
                $0.id != id && Self.samePath($0.path, url.path)
            }) {
                // A holder the launch is itself still holding has just
                // been granted: the person chose its path in a panel.
                // It is asked again here, inside that grant, so one
                // gesture at least mends the tab the file belongs to.
                if held.isHeld {
                    holderNews = Self.activationNotice(settleHeldHolder(held, at: url))
                }
            }
            if let held = openFiles.first(where: {
                $0.id != id && Self.samePath($0.path, url.path)
            }) {
                let refusal = Self.locateHeldNotice(name: file.name, holder: held.name)
                flash([refusal, holderNews].compactMap { $0 }.joined(separator: " "), tone: .actionable)
                return
            }
            // The old bookmark is dropped if no new one can be made. It
            // either failed or names a file the person has just said
            // is not this one, and the next launch must not follow it.
            guard let bookmarked = settleRelocation(of: id, at: url, orphansHeld: true) else {
                let refusal = Self.openRefusalNotice(
                    name: url.lastPathComponent, json: client.openFileErrorJSON())
                flash([holderNews, refusal].compactMap { $0 }.joined(separator: " "))
                return
            }
            if !bookmarked, owesBookmark(path: url.path) {
                flash(Self.bookmarkFailureNotice(name: url.lastPathComponent))
            } else if let sentence = Self.launchNotice(
                reloaded: [],
                notices: client.draftNotices().filter { $0.reason == .draftTooLarge }
            ) {
                flash(sentence)
            }
            // The person asked for this file's text, so a reload flag
            // the settlement raised is answered without a sentence.
            client.clearFileReloadNotice(id)
            refreshOpenFiles()
            markFilesDirty()
        }
    }

    /// Hydrate a held file whose path a locate panel has just been
    /// pointed at on another file's behalf.
    ///
    /// The panel's grant is on this path and is open, which is the one
    /// thing the held file was missing, so the launch's question is
    /// put to it again here. If it settles it is given a bookmark from
    /// the panel's URL, replacing one that failed to let it be read,
    /// and the surface and the drafts file are restated as an
    /// activation's retry restates them. What it has to say about
    /// itself is handed back for the locate to say beside its own
    /// sentence. One that is dropped instead, because what is there
    /// will not open as text, leaves the path free, and the locate
    /// goes on to hear that same refusal from the core about the file
    /// it was asked for.
    ///
    /// The caller has emptied the core's notice list already.
    private func settleHeldHolder(_ holder: FileSummary, at url: URL) -> [CheckOutcome] {
        _ = client.hydrateFile(holder.id, resolvedPath: nil)
        var bookmarkFailure: String?
        if let row = client.fileRoster().first(where: { $0.id == holder.id }),
           !row.pendingHydration {
            if !renewBookmark(for: holder.id, from: url, orphansHeld: true),
               owesBookmark(path: url.path) {
                bookmarkFailure = row.name
            }
        }
        var outcomes = concludeHeldRetry(of: holder, recordMoved: false)
        if let bookmarkFailure { outcomes.append(.bookmarkFailed(bookmarkFailure)) }
        return outcomes
    }

    /// Bind an open file to `url` through the core and restate the
    /// surface around what that settled. Nil when the core refused,
    /// which leaves the file exactly as it was. Otherwise the answer
    /// is whether a fresh bookmark could be made.
    ///
    /// Called inside an open access bracket on `url`, by the locate
    /// panel and by the check that follows a moved file. The bookmark
    /// is made again here, before that bracket closes, because the one
    /// the file held either failed or named the place the file left.
    /// `orphansHeld` is as `renewBookmark` has it: whether the old
    /// bookmark is dropped when a new one cannot be made.
    private func settleRelocation(of id: UInt64, at url: URL, orphansHeld: Bool) -> Bool? {
        let before = fileTextSnapshot(for: id)
        guard client.relocateFile(id, to: url.path) else { return nil }
        let bookmarked = renewBookmark(for: id, from: url, orphansHeld: orphansHeld)
        // Restated only when the text moved. A draft that stands is
        // the text already on screen, and restating it would cost the
        // caret and the scroll position for nothing.
        if fileTextSnapshot(for: id) != before, storages[id] != nil {
            restateStorage(sheet: id)
        }
        refreshOpenFiles()
        reconsiderFileRenderMode(for: id, resetDismissal: true)
        return bookmarked
    }

    // MARK: Files: what else wrote them

    /// Ask of every open file whether anything else has written it.
    ///
    /// Decisions.md item 5's first half: on activate. The second half,
    /// before a save, is inside `saveFile(_:)`, and both go through
    /// `applyCheck(for:)` so the two moments cannot come to different
    /// conclusions about the same file.
    /// One notice, not one per file. A checkout that rewrote three
    /// open files posts three flashes in the same turn of the run
    /// loop, and `flash` overwrites, so the person would see only the
    /// last of them and would be owed the other two. The outcomes are
    /// collected and said together, the way the launch says its own.
    ///
    /// Not while a file panel is up, or while the gesture that raised
    /// one is still using its answer. The check is owed instead and is
    /// made when that gesture ends (`duringFilePanel`). A modal of any
    /// other origin puts it off the same way, and the next activation
    /// or file panel gesture makes it.
    public func checkOpenFilesOnActivate() {
        guard filePanelGestures == 0, !ModalSession.isBracketed else {
            activationCheckOwed = true
            return
        }
        activationCheckOwed = false
        var outcomes: [CheckOutcome] = []
        for file in openFiles {
            // A held file has nothing to check: nothing of it was ever
            // read. The activation asks the launch's question again
            // instead, which is how a file whose volume came back or
            // whose permissions were mended is noticed without the
            // person having to locate it.
            if file.pendingHydration {
                outcomes += retryHeldFile(file)
                continue
            }
            // One bracket per file, around the check and the reload it
            // may lead to. A save makes the same call inside the
            // bracket it already holds.
            let outcome = withFileAccess(file.id) { applyCheck(for: file.id, resolved: $0) }
            if let outcome { outcomes.append(outcome) }
        }
        if let sentence = Self.activationNotice(outcomes) { flash(sentence) }
    }

    /// Hydrate a held file again, and say what came of it.
    ///
    /// The same bracket and the same call the launch made. A file that
    /// still cannot be read stays held and nothing is said, since its
    /// banner is already saying it. One that settles is drawn from the
    /// text it was filled with. One that has since gone from its path
    /// leaves the roster, as a clean file that is gone does at launch,
    /// and is named.
    private func retryHeldFile(_ file: FileSummary) -> [CheckOutcome] {
        discardStaleDraftNotices()
        let moved: Bool
        switch hydrateRestoredFile(file) {
        case .deferred: moved = false
        case .settled(let recordMoved): moved = recordMoved
        }
        return concludeHeldRetry(of: file, recordMoved: moved)
    }

    /// What follows a second hydration of a held file, whoever asked
    /// for it: the core's notices are read, a file that settled is
    /// drawn from the text it was filled with, and the roster and the
    /// drafts file are brought up to date. The caller emptied the
    /// notice list before the hydration, so what is read here is the
    /// hydration's own.
    private func concludeHeldRetry(of file: FileSummary, recordMoved moved: Bool) -> [CheckOutcome] {
        var outcomes: [CheckOutcome] = client.draftNotices().map { notice in
            switch notice.reason {
            case .missing: return .missing(notice.name)
            case .unreadable: return .couldNotBeRead(notice.name)
            case .draftTooLarge: return .draftTooLarge(notice.name)
            }
        }
        let row = client.fileRoster().first(where: { $0.id == file.id })
        if let row, !row.pendingHydration {
            if storages[file.id] != nil { restateStorage(sheet: file.id) }
            if row.externallyReloaded {
                client.clearFileReloadNotice(file.id)
                outcomes.append(.reloaded(row.name))
            }
        }
        refreshOpenFiles()
        if let row, !row.pendingHydration {
            reconsiderFileRenderMode(for: file.id, resetDismissal: true)
        }
        if moved || row == nil || row?.pendingHydration == false { markDraftsRecordMoved() }
        return outcomes
    }

    /// Empty the core's notice list before a call whose own notices
    /// are about to be read from it.
    ///
    /// The list is drained by reading it, and outside a launch nothing
    /// reads it, so it can be holding entries from drafts saves made
    /// since: one for every save that left an oversized draft out.
    /// Read after a hydration or a relocation, those would be said as
    /// if that call had caused them. What is left after this is what
    /// the call itself put there.
    private func discardStaleDraftNotices() {
        _ = client.draftNotices()
    }

    /// What one file's check had to say, gathered rather than posted.
    enum CheckOutcome: Equatable {
        case reloaded(String)
        case bookmarkFailed(String)
        /// A read that was tried and did not give the file's text,
        /// whatever the reason. It is the sentence "could not be
        /// read", and is named apart from both the roster's
        /// `accessRefused` mark and the notice reason `unreadable`,
        /// either of which can lead here.
        case couldNotBeRead(String)
        case missing(String)
        /// A held file settled, and the draft its record once carried
        /// had been too large to keep.
        case draftTooLarge(String)
    }

    /// The activation's single sentence, on the same shape as the
    /// launch's.
    static func activationNotice(_ outcomes: [CheckOutcome]) -> String? {
        var reloaded: [String] = []
        var notRead: [String] = []
        var missing: [String] = []
        var tooLarge: [String] = []
        var bookmarkFailures: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .reloaded(let name): reloaded.append(name)
            case .bookmarkFailed(let name): bookmarkFailures.append(name)
            case .couldNotBeRead(let name): notRead.append(name)
            case .missing(let name): missing.append(name)
            case .draftTooLarge(let name): tooLarge.append(name)
            }
        }
        // One file keeps the wording it had, so the single file case,
        // which is nearly every case, reads exactly as before.
        if tooLarge.isEmpty, bookmarkFailures.isEmpty {
            if reloaded.count == 1, notRead.isEmpty, missing.isEmpty {
                return reloadedNotice(name: reloaded[0])
            }
            if missing.count == 1, notRead.isEmpty, reloaded.isEmpty {
                return missingNotice(name: missing[0])
            }
            if notRead.count == 1, reloaded.isEmpty, missing.isEmpty {
                return readRefusalNotice(name: notRead[0])
            }
        }
        var clauses: [String] = []
        if !reloaded.isEmpty {
            clauses.append("\(englishList(reloaded)) changed on disk and was read again")
        }
        if !notRead.isEmpty {
            clauses.append("\(englishList(notRead)) could not be read")
        }
        if !missing.isEmpty {
            clauses.append("\(englishList(missing)) is no longer at its path")
        }
        if !tooLarge.isEmpty {
            clauses.append("unsaved changes to \(englishList(tooLarge)) were too large to keep")
        }
        var sentences = clauses.isEmpty ? [] : [englishList(clauses) + "."]
        sentences += bookmarkFailures.map { bookmarkFailureNotice(name: $0) }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// One file's check, and what follows from the answer.
    ///
    /// A clean file that changed is read again without asking and the
    /// notice is posted afterwards, always: a person whose scroll
    /// position moved because a checkout ran under them deserves to
    /// know why. A dirty file that changed enters a conflict, which
    /// the core sets from the same call, and the banner takes it from
    /// there. A file that is no longer at its path says so.
    /// Returns what the caller owes the person, or nil when the file
    /// is where it was. It says nothing itself, so a caller checking
    /// several files can say one thing about all of them.
    ///
    /// It opens no access bracket of its own. Both callers hold one
    /// when they call, the activation one per file and the save one
    /// around the check and the write together, and both hand over
    /// the URL that bracket's bookmark resolved to, or nil when it
    /// resolved to nothing.
    ///
    /// That URL is how a file moved while the app is running is
    /// followed. A bookmark follows its file, so when the check finds
    /// nothing at the recorded path and the bookmark has resolved
    /// somewhere else, the file is there. The open file is bound to
    /// that path and settled as a located one is, inside the scope
    /// the caller already holds, and nothing is reported missing. A
    /// bookmark that leads into a Trash is not followed, for the
    /// reason the launch does not follow one: a person who threw a
    /// file away did not move it. When the core refuses the new path,
    /// because another tab holds it or the file there will not open,
    /// the file is reported missing as before.
    @discardableResult
    private func applyCheck(for id: UInt64, resolved: URL?) -> CheckOutcome? {
        guard let file = openFiles.first(where: { $0.id == id }),
              let check = client.checkFile(id)
        else { return nil }
        switch check.state {
        case .unchanged:
            // The witness matches, but the read can newly refuse access
            // (and put a dirty file in conflict), or clear a previous
            // refusal or missing mark. Publish the post-check roster;
            // the pre-check row cannot tell us whether those flags moved.
            refreshOpenFiles()
            return nil
        case .changed:
            if file.isDirty {
                // The conflict is already set core-side by the check
                // itself. Restating the roster is what puts the banner
                // on screen, and the banner is the notice: a person
                // looking at three buttons does not also need a line.
                refreshOpenFiles()
                return nil
            }
            if client.reloadFile(id) {
                // reload clears externallyReloaded; its successful answer,
                // not that sticky notice flag, identifies the new disk copy.
                let source = resolved.flatMap {
                    Self.samePath($0.path, file.path) ? $0 : nil
                } ?? URL(fileURLWithPath: file.path)
                if renewBookmark(for: id, from: source) { markDraftsRecordMoved() }
                restateStorage(sheet: id)
                refreshOpenFiles()
                reconsiderFileRenderMode(for: id, resetDismissal: true)
                return .reloaded(file.name)
            }
            refreshOpenFiles()
            return .couldNotBeRead(file.name)
        case .missing:
            if let resolved,
               !Self.samePath(resolved.path, check.path),
               !fileCoordinator.isInTrash(resolved),
               settleRelocation(of: id, at: resolved, orphansHeld: false) != nil {
                // Owed to the drafts file through no act of the
                // person's, the way a path a launch found is.
                markDraftsRecordMoved()
                guard let row = openFiles.first(where: { $0.id == id }),
                      row.externallyReloaded
                else { return nil }
                client.clearFileReloadNotice(id)
                refreshOpenFiles()
                return .reloaded(row.name)
            }
            // Restated because the core has marked the row: a draft is
            // in the missing conflict and a clean file is not found,
            // and either way a banner offering Locate now stands. The
            // sentence is said once, when the file is first found
            // gone. After that the banner is saying it, and an
            // activation that repeated it would only be talking over
            // the banner.
            refreshOpenFiles()
            return file.notFound ? nil : .missing(file.name)
        }
    }

    // MARK: Files: the sentences

    /// The core's open refusal, decoded and said in one sentence
    /// naming the file, and the limit when there is one.
    ///
    /// Static and pure so the wording is testable without a file on
    /// disk that is genuinely 4 MiB or genuinely not UTF-8.
    public nonisolated static func openRefusalNotice(name: String, json: String?) -> String {
        struct Refusal: Decodable {
            let error: String
            let limit: UInt64?
            let detail: String?
        }
        guard let json,
              let data = json.data(using: .utf8),
              let refusal = try? JSONDecoder().decode(Refusal.self, from: data)
        else {
            return "\(name) could not be opened."
        }
        switch refusal.error {
        case "binary":
            return "\(name) contains binary data and cannot be opened as text. Choose a UTF-8 text file instead."
        case "notUtf8":
            return "\(name) uses an unsupported text encoding. Convert it to UTF-8, then try again."
        case "tooLarge":
            let limit = refusal.limit.map(Self.sizePhrase(bytes:)) ?? "the size limit"
            return "\(name) is larger than \(limit), so it was not opened."
        case "io" where refusal.detail?.localizedCaseInsensitiveContains("directory") == true:
            return "\(name) is a directory, so it was not opened."
        default:
            return "\(name) could not be read, so it was not opened."
        }
    }

    /// A byte count as a phrase a person reads rather than counts.
    /// Whole binary megabytes get their own name; anything else stays
    /// in bytes rather than being rounded into a number that is not
    /// the limit.
    nonisolated static func sizePhrase(bytes: UInt64) -> String {
        let mib: UInt64 = 1024 * 1024
        if bytes >= mib, bytes % mib == 0 { return "\(bytes / mib) MiB" }
        return "\(bytes) bytes"
    }

    public nonisolated static func unresolvedConflictNotice(name: String) -> String {
        "\(name) changed on disk. Choose keep mine, take theirs, or Save As before saving."
    }

    /// The refused save's sentence for the conflict the file is
    /// actually in. A file that changed keeps the wording above. One
    /// that is gone or cannot be read names Locate first, since
    /// finding the file is the way out that loses nothing, and neither
    /// names take theirs, since there is no copy on disk that could be
    /// taken.
    public nonisolated static func unresolvedConflictNotice(for file: FileSummary) -> String {
        if file.accessRefused {
            return "\(file.name) cannot be read at its path. "
                + "Choose Locate, keep mine, or Save As before saving."
        }
        if file.conflict == .missing {
            return "\(file.name) is no longer at its path. "
                + "Choose Locate, keep mine, or Save As before saving."
        }
        return unresolvedConflictNotice(name: file.name)
    }

    /// A save asked of a file with no unsaved edits and nothing at its
    /// path. The save is refused: it writes a file back and does not
    /// make one where a person deleted or moved theirs. The wording
    /// this follows is in docs/spec/feature/file-editing/README.md,
    /// External changes: "The pad does not recreate a file at a path a
    /// person deleted." The sentence names the two ways out.
    /// Keep mine is not among them, because a file with no unsaved
    /// edits is in no conflict for it to answer. A file that does hold
    /// edits is in the missing conflict instead, and
    /// `unresolvedConflictNotice(for:)` is its sentence.
    public nonisolated static func saveNotFoundNotice(name: String) -> String {
        "\(name) is no longer at its path, so it was not saved. "
            + "Choose Locate to find it, or Save As to write it somewhere."
    }

    /// A save asked of a held file: one that came back from the last
    /// session and could not be read, so that nothing of it is in the
    /// buffer to write.
    public nonisolated static func heldFileNotice(name: String) -> String {
        "\(name) has not been read, so there is nothing to save. Locate the file or close the tab."
    }

    /// Locate onto a file that is already open in another tab. Two
    /// buffers over one file would each believe they were the file, so
    /// the core refuses and the file being located stays as it was.
    public nonisolated static func locateHeldNotice(name: String, holder: String) -> String {
        "\(holder) is already open, so \(name) was not pointed at it. "
            + "Close it first, or choose another file."
    }

    public nonisolated static func writeRefusalNotice(name: String) -> String {
        "\(name) could not be written."
    }

    /// The sentence for a save the core refused, chosen from the reason
    /// the core gave and not from what the row looks like afterwards.
    ///
    /// The row cannot stand in for the reason. A file that is not found
    /// and whose save a keep mine licensed looks, after a write the
    /// platform refused, exactly like a file refused for being not
    /// found, and the two owe different sentences: one names Locate and
    /// Save As, the other says the write did not land.
    ///
    /// `file` is the row as it stands after the refusal. It supplies
    /// the name, and for a conflict it says which one, since each has
    /// its own ways out. A save refused as not found leaves a file
    /// holding edits in the missing conflict, and that file is owed the
    /// conflict's sentence, which offers keep mine; one with no edits
    /// has no conflict for keep mine to answer. No reason at all is a
    /// refusal that never reached the core's file, and is worded as the
    /// write that did not land, which is true of every refused save.
    public nonisolated static func saveRefusalNotice(
        _ refusal: FileSaveRefusal?, for file: FileSummary
    ) -> String {
        switch refusal {
        case .conflict:
            return unresolvedConflictNotice(for: file)
        case .notFound:
            return file.conflict == .none
                ? saveNotFoundNotice(name: file.name)
                : unresolvedConflictNotice(for: file)
        case .pendingHydration:
            return heldFileNotice(name: file.name)
        case .write, .pathInUse, .unknownFile, nil:
            return writeRefusalNotice(name: file.name)
        }
    }

    /// The sentence and its tone for a save as the core refused, chosen
    /// from the reason as `saveRefusalNotice(_:for:)` chooses.
    ///
    /// `file` is the name of the file being saved, `target` the name
    /// the person chose for it, and `holder` the tab already open on
    /// that path when the roster shows one. A save as writes to a path
    /// the person has just chosen, so it is never refused as not found
    /// or as a conflict, and those read as the write that did not land.
    public nonisolated static func saveAsRefusalNotice(
        _ refusal: FileSaveRefusal?, file: String, target: String, holder: String?
    ) -> (text: String, tone: NoticeTone) {
        switch refusal {
        case .pathInUse:
            return (pathInUseNotice(name: holder ?? target), .plain)
        case .pendingHydration:
            return (heldFileNotice(name: file), .actionable)
        case .write, .conflict, .notFound, .unknownFile, nil:
            return (writeRefusalNotice(name: target), .actionable)
        }
    }

    /// Save As onto a path another open file already holds. Two
    /// buffers over one file would each believe they were the file, so
    /// the core refuses before anything is written.
    public nonisolated static func pathInUseNotice(name: String) -> String {
        "\(name) is already open, so nothing was written to it. Close it first, or choose another name."
    }

    public nonisolated static func readRefusalNotice(name: String) -> String {
        "\(name) could not be read."
    }

    public nonisolated static func reloadedNotice(name: String) -> String {
        "\(name) changed on disk and was read again."
    }

    public nonisolated static func missingNotice(name: String) -> String {
        "\(name) is no longer at its path."
    }

    /// The keymap file cannot be resolved at all, which only happens
    /// under the test runner without a seam. Named so a suite that
    /// exercises the menu route can assert against it.
    public nonisolated static var keymapUnavailableNotice: String {
        "The keymap file is unavailable in this build."
    }

    /// The seed write itself failed: the configuration directory or
    /// the file underneath it could not be created, which is a disk
    /// or permission problem the app cannot recover from silently.
    public nonisolated static var keymapSeedFailureNotice: String {
        "The keymap file could not be created."
    }

    /// What a discard of the sealed content file also takes with it.
    ///
    /// Decisions.md item 14. The drafts are sealed under the content
    /// key, so anything that drops or rotates that key drops them too,
    /// and a person is owed the filenames rather than a general
    /// warning about unsaved work. Nil when nothing is at risk, so a
    /// caller can append it or not.
    public nonisolated static func draftsAtRiskSentence(files: [FileSummary]) -> String? {
        let dirty = files.filter(\.holdsUnsavedEdits).map(\.name)
        guard !dirty.isEmpty else { return nil }
        return "Unsaved changes to \(englishList(dirty)) go with it."
    }

    /// A list a person reads out loud, which is the only reason this
    /// is not `joined(separator:)`.
    nonisolated static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    /// Where a ⌥⌘←/→ walk starts from.
    ///
    /// With the strip that is the selected slot's own entry, which is
    /// the index the walk has always begun at. With the days down the
    /// side it is the day the selected page was born on, which is not
    /// always that day's first entry, because a day can hold more than
    /// one page. A selection the surface is not drawing (a slot whose
    /// page expired, in a mode that draws no such slot) starts the
    /// walk at the top, where today is.
    private func indexOfSelection(within targets: [SurfaceTarget]) -> Int {
        if let selectedFile, let at = targets.firstIndex(of: .file(selectedFile)) { return at }
        guard let selection else { return 0 }
        if showsTimeUnits, let day = timeUnits.units.firstIndex(
            where: { $0.tabIDs.contains(selection) }
        ) {
            // The days start after the Files shelf, so the day's own
            // place is its index past the files the rail drew above it.
            return navigationFiles.count + day
        }
        return targets.firstIndex(of: .tab(selection)) ?? 0
    }

    /// Select a tab, and open a page into it if it holds none.
    ///
    /// This is one of the three gestures that mint, and the mint is
    /// deliberate on both counts (ADR-0017). It happens on selection
    /// rather than lazily on the first keystroke, because the empty
    /// branch renders no editor at all: a selected empty tab would
    /// unmount the editor and re-mount it on the first character,
    /// turning every expiry into an editor teardown and putting
    /// ADR-0005's Return grant in competition with this path. And it
    /// happens only here, on a user's gesture, never on the selection
    /// `refresh()` reconciles, so a page that expires under the cursor
    /// leaves an empty tab rather than a fresh countdown on nothing.
    public func select(_ id: UInt64) {
        if pads.isEnabled, let tab = tabs.first(where: { $0.id == id }) {
            let target = pads.owner(ofTabUUID: tab.uuid)
            if target != pads.activeID {
                activatePad(target)
                guard pads.activeID == target else { return }
            }
        }
        let leavingLedger = showingLedger
        clearPendingFileClose()
        // A slot and a file are never both showing, so choosing a slot
        // puts the file away. The file itself stays open and keeps its
        // place in the FILES group; only the surface moved.
        let leavingFile = selectedFile != nil
        selectedFile = nil
        showingLedger = false
        selection = id
        let minted = openPageIfSlotIsEmpty(id)
        // Both arms change what is *mounted*, rather than what the one
        // persistent editor is showing, and a mount nobody focuses is
        // the lit ember over a keystroke that beeps (issue #22).
        // Leaving the ledger rebuilds the editor the ledger stood in
        // for; minting rebuilds the editor the empty state's catcher
        // stood in for, and the catcher takes first responder with it
        // when it unmounts. A plain switch between two pages takes
        // neither arm: it keeps its editor, keeps its focus, and asks
        // for nothing.
        if leavingLedger || leavingFile || minted { refocusEditorIfKeyed() }
        if pads.isEnabled { pads.remember(tabUUID: selectedTab?.uuid, for: pads.activeID) }
    }

    /// ⌘1 to ⌘9: jump by visible order. With the strip that is the
    /// slot, so ⌘3 means the third slot whether or not it holds a page,
    /// and it means the same slot next week. With the days down the
    /// side it is the third day (issue #79).
    public func select(index: Int) {
        let targets = visibleTargets
        guard targets.indices.contains(index) else { return }
        select(target: targets[index])
    }

    /// ⌥⌘← / ⌥⌘→. Steps slots, not pages, and mints into the slot it
    /// lands on when that slot is empty, or steps days, when the days
    /// are the thing on screen.
    ///
    /// The landing is `select`'s, and always was: the walk lands on
    /// slots, the slot it lands on may be empty, and it carries
    /// `select`'s hand-off for `select`'s reasons. It used to carry a
    /// copy of that ceremony and now calls it, so a walk that both
    /// leaves the ledger and mints still asks for the keys once, after
    /// the mint rather than before it, and there is one place for the
    /// rule to live rather than two that can drift.
    public func step(_ delta: Int) {
        let targets = visibleTargets
        guard !targets.isEmpty else { return }
        let current = indexOfSelection(within: targets)
        let next = Self.steppedIndex(from: current, by: delta, within: targets.count)
        select(target: targets[next])
    }

    /// The mint the three selection gestures share: a page into the
    /// named slot at that slot's own rung, and nothing at all when the
    /// slot already holds one or the tab is unknown. Refuses at the
    /// seam rather than here, so the "one page to a slot" rule has a
    /// single home.
    ///
    /// Answers whether it minted, which is what tells the gesture
    /// above it that the surface it was looking at has been rebuilt:
    /// the empty state gives way to a freshly built editor, and the
    /// keys have to be handed on to it (issue #22). A slot that
    /// already held a page answers false, and the gesture stays the
    /// quiet switch it always was.
    @discardableResult
    private func openPageIfSlotIsEmpty(_ tab: UInt64) -> Bool {
        // Selecting some other slot retires the record of the last
        // mint, so what stands is always the mint of a tap on this
        // slot and never one from a gesture ago. Reaching the same
        // slot again keeps it: with a simultaneous gesture the double
        // click's second single tap re-enters here before the hold
        // resolves, and clearing on that re-entry is what let the hold
        // strike the page the first tap had just minted.
        if mintedBySelection?.tab != tab { mintedBySelection = nil }
        guard tabs.first(where: { $0.id == tab })?.hasPage == false else { return false }
        guard client.openPage(tab: tab) != 0 else { return false }
        mintedBySelection = (tab: tab, at: ProcessInfo.processInfo.systemUptime)
        markDirty()
        refresh()
        return true
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

    /// `ledger::Show`: open the ledger. Which chord reaches it, if
    /// any, is the keymap's business; the bundled default names none
    /// while the ledger's entry points are hidden (issue #78).
    public func showLedger() {
        clearPendingFileClose()
        ledgerEntries = client.ledger()
        showingLedger = true
    }

    /// Drop the whole audit trail (Settings, behind a confirmation).
    /// The ledger now survives reboots under a long-lived key and its
    /// titles are often the secret's own label, so the user must be able
    /// to end that record on demand.
    ///
    /// Three things, in this order, and it runs the same way whether or
    /// not this session holds the ledger licence. Clearing is the user
    /// saying the file may go, which is a stronger instruction than the
    /// licence's caution about overwriting it.
    ///
    /// 1. The in-memory ledger goes, core-side.
    /// 2. The file goes, by path. This is the half that works when the
    ///    licence is withheld: an unreadable ledger cannot be replaced by
    ///    a write, so without the unlink the user's Clear would leave the
    ///    old ciphertext sitting there, and the licence would have nothing
    ///    to come back for. A refusal here is not fatal; the write below
    ///    still tries to put an empty ledger over it.
    /// 3. The ledger licence comes back
    ///    (`licencesAfterLedgerClear`), so a session that was recording
    ///    nothing starts recording again from here. Before `markDirty`,
    ///    which consults it.
    ///
    /// The content file and its licence are not in this path at all: a
    /// different file, a different key, and a gesture that did not ask
    /// about pages.
    public func clearLedger() {
        client.clearLedger()
        // Path-scoped: overwrite, truncate, sync, unlink, and it refuses
        // symlinks and anything that is not a regular file, so this
        // reaches the ledger file and nothing else. No key is touched and
        // no page is touched.
        let ledgerPath = ledgerFileURL.path
        if !client.persistErase(at: ledgerPath) {
            logger.error(
                "the ledger file could not be dropped on a user clear; an empty ledger follows"
            )
        }
        let licences = Self.licencesAfterLedgerClear(
            content: saveLicence, ledger: ledgerLicence
        )
        saveLicence = licences.content
        ledgerLicence = licences.ledger
        // The standing not-recording line comes down with the refusal
        // it described: the licence is back, so the trail records again
        // from here.
        ledgerRestoreRefused = false
        markDirty()
        refresh()
    }

    /// Discard the state file this session could not read and start
    /// saving (the banner's one action; ADR-0016 section 7, issue #49).
    /// The ledger clear's shape, ported to the content side, and like
    /// it this is the user's gesture only: nothing auto-clears a
    /// refused restore.
    ///
    /// 1. The file goes, by path, key halves rotated on the way out.
    ///    This is the half a write cannot do while the licence is
    ///    withheld, and without the unlink the licence would have
    ///    nothing to come back for. A refusal here is not fatal: the
    ///    reseal armed below still puts this session's store over it,
    ///    which is now what the user asked for.
    /// 2. The content licence comes back (`licencesAfterContentClear`),
    ///    before `markDirty`, which consults it.
    /// 3. The banner comes down, and the session's current store is
    ///    marked dirty so the first sealed generation lands within one
    ///    debounce rather than waiting on the next keystroke.
    ///
    /// Guarded to the one condition it exists for: a session that holds
    /// its licence has no unreadable file to discard, and running the
    /// erase there would drop a file this session can and does write.
    public func clearUnreadableStateFile() {
        guard stateLoaded, !saveLicence else { return }
        if !client.persistErase(at: stateFileURL.path) {
            logger.error(
                "the unreadable state file could not be dropped on a user discard; the reseal will try to replace it instead"
            )
        }
        let licences = Self.licencesAfterContentClear(
            content: saveLicence, ledger: ledgerLicence
        )
        saveLicence = licences.content
        ledgerLicence = licences.ledger
        contentRestoreRefused = false
        quitRefusal = Self.quitOfferAfterContentClear(offer: quitRefusal)
        markDirty()
        refresh()
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
    ///
    /// Internal rather than private since the roll (issue #79) moves the
    /// one editor between days without a SwiftUI mount changing, so the
    /// surface has to ask for this itself where `select` would otherwise
    /// have asked on its behalf. Focus is law (ADR-0005): every path
    /// that changes what is mounted, or where the mounted thing stands,
    /// comes through here.
    func refocusEditorIfKeyed() {
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
        #if DEBUG
        keyboardHandoffs += 1
        #endif
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self else { return }
                if requireKeys, !self.holdsKeys { return }
                if requireKeys, let window, !window.isKeyWindow { return }
                if let editor = Self.mountedEditor(self.activeEditor, in: window) {
                    (window ?? editor.window)?.makeFirstResponder(editor)
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// The editor to hand the keys to, or nil when the one the model is
    /// holding has already left the window.
    ///
    /// `activeEditor` is weak, which answers the question of whether the
    /// view still exists and not the question the hand-off is actually
    /// asking, which is whether it is still mounted. A ledger round trip
    /// or a visit to an empty slot tears the editor out of the window,
    /// and the torn-out view answers the weak handle for as long as it
    /// takes ARC and the autorelease pool to let go of it, which is at
    /// least the rest of the turn. Accepting it there ends the wait
    /// twice over: there is no window to make it first responder in, so
    /// nothing is focused, and the poll returns rather than waiting for
    /// the editor that is genuinely on its way. The window is key, the
    /// ember is lit, and the keystroke beeps, which is the fault the
    /// poll exists to prevent, on the ledger's own return path (issue
    /// #23). A view inside a window is mounted; that is the whole test.
    static func mountedEditor(_ editor: NSTextView?, in targetWindow: NSWindow? = nil) -> NSTextView? {
        guard let editor, editor.window != nil else { return nil }
        // Ownership can transfer before SwiftUI replaces the old mount.
        // A focus request for one window must wait for its own editor.
        if let targetWindow, editor.window !== targetWindow { return nil }
        return editor
    }

    /// Show `message` for a few seconds, then clear it — unless a newer
    /// notice replaced it in the meantime. Plain unless the caller says
    /// otherwise: most notices report, and the few that ask for a hand
    /// name themselves as `.actionable` where they are raised.
    public func flash(_ message: String, tone: NoticeTone = .plain, action: NoticeAction? = nil) {
        notice = message
        noticeTone = tone
        noticeAction = action
        noticeGeneration += 1
        let generation = noticeGeneration
        let dwell = action == nil ? Self.noticeDwell : Self.noticeDwellWithAction
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
            self.noticeAction = nil
        }
    }

    /// The notice's button was pressed: run it, and take the line down
    /// with it, since what it offered has been done.
    public func performNoticeAction() {
        guard let action = noticeAction else { return }
        noticeGeneration += 1
        notice = nil
        noticeAction = nil
        action.perform()
    }

    /// Esc first leaves page expansion, then the ledger, then hands back keys.
    public func escape() {
        if isPageExpanded {
            expandedPageID = nil
            refocusEditorIfKeyed()
        } else if showingLedger {
            showingLedger = false
            refocusEditorIfKeyed()
        } else {
            onHandBackKeys?()
        }
    }

    // MARK: Pages

    /// What the pad says on the one failure a new page has left: the
    /// core answered with no slot at all, which is a broken handle and
    /// not a full strip. There is no cap to hit (issue #158); ⌘1 to ⌘9
    /// reach the first nine tabs and the rest simply have no chord.
    static let newPageFailed = "the pad could not open a page"

    /// A new tab at the ladder's top rung (ADR-0011 section 3, the
    /// core's own default), holding a new page. 0 only when the core
    /// could not answer, never for want of room. Returns the TAB's id,
    /// which is what the selection keeps.
    @discardableResult
    private func newTab() -> UInt64 {
        let id = client.newTab()
        // A failed ask changed nothing; only a real tab is dirt.
        if id != 0 {
            if pads.isEnabled, let tab = client.tabs().first(where: { $0.id == id }), let uuid = tab.uuid {
                pads.assign(tabUUID: uuid, to: pads.activeID)
            }
            markDirty()
        }
        return id
    }

    /// A new page (⌘N or the + tab). It cannot be refused for room:
    /// the strip has no cap, and a tenth tab opens like the ninth
    /// (issue #158).
    public func newPage() {
        notice = nil
        clearPendingFileClose()
        // A page asked for now is a page to look at now, so the file
        // that was showing gives way to it.
        selectedFile = nil
        let created = newTab()
        if created == 0 {
            logger.error("the core answered a new page with no tab")
            flash(Self.newPageFailed)
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
            if pads.isEnabled { pads.remember(tabUUID: selectedTab?.uuid, for: pads.activeID) }
            refocusEditorIfKeyed()
        }
    }

    /// ⌘N while pages are organized by day: go to today's page, make
    /// one when today has none, and make another when the person is
    /// already on today's page (issues #79, #158).
    ///
    /// Three arms, none of them a new mint policy. When today holds a
    /// live page and the selection is elsewhere this is a plain
    /// `select(_:)`, the jump, which cannot mint into an occupied slot.
    /// When today holds none it is `newPage()`, the same path ⌘N takes
    /// with the strip showing, which opens a fresh slot at this form
    /// factor's rung and hands its editor the keys. And when the
    /// selection already stands on one of today's pages it is
    /// `newPage()` again: first press jumps, second press creates, and
    /// the projection files the new page under today beside the first,
    /// in strip order. Every mint stamps the clock's own reading of
    /// now, so the page it makes lands on today by construction rather
    /// than by being filed there.
    ///
    /// Blank or not makes no difference, exactly as on the strip: ⌘N
    /// there opens a slot whether or not the last one was written on,
    /// and a person on today's page who asks for another gets another.
    /// A bar on content would be a second mint policy dressed as a
    /// courtesy, and it was tried and taken out (issue #158).
    ///
    /// What it will not do is reach for some arbitrary empty tab to put
    /// today's page in. That would be opinionated in exactly the place
    /// the issue asked for unopinionated, and it has a real cost:
    /// flipping back to the strip would show a tab the user named
    /// holding today's typing. Nothing here can be refused for room:
    /// the strip has no cap (issue #158).
    ///
    /// Reached from ⌘N and ⌘T only. The gestures that name today as a
    /// place, the roll's empty region and the rail's Today row, take
    /// `startToday()`, which never mints a second page. Nothing calls
    /// either from `refresh()`, from a mount or from the toggle: what is
    /// displayed is not thereby minted (ADR-0017).
    public func openToday() {
        // Bucket 0 is today and there is exactly one of it: the
        // projection folds a page stamped ahead of now into today rather
        // than giving it a bucket of its own, so this cannot find an
        // empty Today standing above a peopled one and mint beside a
        // page already on screen (`TimeUnit.bucket(dayOffset:)`).
        guard let today = timeUnits.units.first(where: { $0.bucket == 0 }),
            let first = today.tabIDs.first
        else {
            newPage()
            return
        }
        if let selection, today.tabIDs.contains(selection) {
            // Already on today, and today's page is what is on screen:
            // a file or the ledger standing in front of it makes this a
            // jump back, not a second page.
            let onScreen = selectedFile == nil && !showingLedger
            if onScreen {
                newPage()
            } else {
                select(selection)
            }
            return
        }
        select(first)
    }

    /// Today's place, clicked or chosen: go to today's page, and make
    /// one only when today has none (issues #79, #158).
    ///
    /// The two arms `openToday()` had before it learned to mint a
    /// second page, kept for the gestures that name today as a place
    /// rather than ask for a page: the roll's empty Today region and a
    /// `.today` target, which exists only while today holds no page.
    /// Those grants can fire again after the page they made has
    /// appeared, a double click on the region, a chord landing during
    /// the relayout, and a place that made a page a moment ago must
    /// find that page and select it rather than stack a blank one
    /// beside it. ⌘N is the gesture that asks for another; this is not.
    public func startToday() {
        if let tab = timeUnits.units.first(where: { $0.bucket == 0 })?.tabIDs.first {
            select(tab)
            return
        }
        newPage()
    }

    /// A summon: put the surface back on today (issue #79).
    ///
    /// Day 0 is the top of the roll, and between summons the scroll is
    /// free, a reader can sit in Day -3 as long as they like. Coming
    /// forward is the moment that changes: the pad is furniture (doc 03
    /// section 2), and a pad untouched since yesterday should present
    /// today rather than wherever it was last left. So the clip goes
    /// back to the origin, instantly and unanimated, and when today
    /// already holds a page the selection goes with it.
    ///
    /// It cannot mint. The selection arm runs only when today's day
    /// already holds a live page, and `select(_:)` cannot open a page
    /// into a slot that holds one; a summon onto an empty Day 0 lands on
    /// the empty state with its Return grant intact, which is exactly
    /// the state ADR-0017 describes for a selected tab whose page
    /// expired. Nothing happens at all in horizontal mode, which has one
    /// page in its clip and no roll to anchor.
    ///
    /// A summon beside the open editor window is also a hand off
    /// (ADR-0033), and the panel's roll is then not built yet, so there
    /// is no clip to move. What is waiting for that roll instead is the
    /// place the editor window's roll left, and the summon's answer to
    /// it is the same: the place is dropped, and a roll handed no place
    /// opens at Day 0.
    public func anchorOnToday() {
        guard showsTimeUnits else { return }
        if let tab = timeUnits.units.first(where: { $0.bucket == 0 })?.tabIDs.first,
           tab != selection {
            select(tab)
        }
        viewStates.leaveRollPlace(nil)
        onAnchorToday?()
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
        // Three cases, in the order the strip can be in. No tabs at
        // all: conjure one, which is the launch-into-emptiness case.
        // A selected slot holding nothing: open a page into it, so
        // Return lands on the slot the user was looking at rather than
        // widening the strip (ADR-0017 item 11). A selected slot that
        // already holds a page: the grant promises one page and not one
        // per keystroke, so focus what exists.
        if navigationTabs.isEmpty {
            newPage()
        } else if let tab = selection, selectedTab?.hasPage == false {
            openPageIfSlotIsEmpty(tab)
        }
        focusEditorWhenMounted(in: window)
    }

    /// Whether the empty state's catcher should hold first responder,
    /// which is the whole of the fourth grant's availability: yes
    /// exactly when the selected tab holds no page while the window
    /// holds the keys. The grant spends key status an earlier grant
    /// conferred, never takes it; an unkeyed window still receives no
    /// keystrokes at all, so it has nothing to offer Return. Pure, so
    /// the decision is testable without a window.
    ///
    /// It follows the selection and not the strip (ADR-0017 item 11): a
    /// selected empty tab offers the create surface while another tab
    /// holds a page, because that is the surface the user is actually
    /// looking at. Neither store-wide predicate belongs here, both are
    /// about the whole pad, and feeding either one in would hide the
    /// create surface at exactly the moment a user is looking at an
    /// empty tab. A strip with no tabs at all also holds no page in the
    /// selected one, so the launch-into-emptiness case falls out of the
    /// same sentence.
    public nonisolated static func shouldOfferEnterCreate(
        selectedTabHoldsNoPage: Bool, holdsKeys: Bool
    ) -> Bool {
        selectedTabHoldsNoPage && holdsKeys
    }

    /// The fact the create grant reads, taken from the model: the
    /// selected slot holds no page, which a strip with nothing selected
    /// satisfies too.
    public var selectedTabHoldsNoPage: Bool {
        selectedPageID == nil
    }

    /// Close the tab; whatever page it held rests in the ledger.
    /// Closing also clears any standing refusal, since what it named
    /// may no longer hold. Explicit close is the one thing that ends a
    /// tab (ADR-0017), and it takes the slot with the page.
    public func close(_ id: UInt64) {
        notice = nil
        // A draft aimed at this page — or at a chip riding on it —
        // dies with it. Left standing, the confirmation would still
        // answer ↩ ("Create link" carries the default action) with a
        // network call over a page that no longer exists (issue #19).
        // The chips must be asked for *before* the close; a dead page
        // replays no runs.
        let closingPage = tabs.first { $0.id == id }?.pageID
        if let draft = concealDraft, let closingPage,
           Self.shouldClearConcealDraft(
               target: draft.target,
               closingSheet: closingPage,
               chipsOnSheet: chipIds(onSheet: closingPage)
           ) {
            concealDraft = nil
        }
        _ = client.closeTab(id: id)
        markDirty()
        refresh()
    }

    /// Whether closing `closingSheet` orphans the open conceal
    /// draft: a draft for the page itself, or for a chip the page
    /// carries. A draft aimed elsewhere survives — its subject is
    /// still alive. Pure, so the decision is testable without a core.
    public nonisolated static func shouldClearConcealDraft(
        target: ConcealDraft.Target,
        closingSheet: UInt64,
        chipsOnSheet: Set<UInt64>
    ) -> Bool {
        switch target {
        case .page(let id): id == closingSheet
        case .chip(let id): chipsOnSheet.contains(id)
        }
    }

    /// Whether a refresh orphans the open conceal draft: its subject
    /// is no longer among the live pages. A page draft dies when its id
    /// drops from the live set; a chip draft dies when the chip rides
    /// on no live page — which is exactly when its host page has gone,
    /// whether it was the last page or one of several. Pure, so the
    /// decision is testable without a core.
    public nonisolated static func isRefreshOrphan(
        target: ConcealDraft.Target,
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

    /// Drag-to-reorder: move the tab `id` to `index` in visible order;
    /// the ⌘-number map follows. The arrangement is the slot's, so it
    /// survives every page the slot holds.
    public func move(_ id: UInt64, to index: Int) {
        var destination = max(0, index)
        if pads.isEnabled {
            let remaining = tabs.filter { $0.id != id }
            let active = remaining.indices.filter { pads.owner(ofTabUUID: remaining[$0].uuid) == pads.activeID }
            destination = destination < active.count ? active[destination] : active.last.map { $0 + 1 } ?? remaining.count
        }
        _ = client.moveTab(id: id, to: UInt64(destination))
        markDirty()
        refresh()
    }

    /// Click the countdown label: one rung shorter, clock reset
    /// (docs/spec/04).
    public func cycleRung(_ id: UInt64) {
        _ = client.cycleRung(tab: id)
        markDirty()
        refresh()
    }

    /// Double-click the tab: a three state cycle — hold the clock 1h,
    /// top up to 24h, then release it. The release is what keeps a
    /// stray double-click from ratcheting a page's life up by a day
    /// with no way back (docs/spec/04).
    ///
    /// A hold that would land on the page the tap before it minted is
    /// refused (ADR-0017). Selecting an empty slot opens a page into it,
    /// so on a slot whose page expired overnight the first tap of a
    /// double-click makes a page and the second one would freeze its
    /// countdown for an hour: the user double-clicked an empty slot and
    /// got a held page they never asked to hold. The refusal is here
    /// rather than in the strip because the gesture recognizers are
    /// re-made as the view re-renders and the mint is what makes them
    /// disagree; the model knows what it just minted.
    ///
    /// A press the core refuses changed nothing, so it marks nothing
    /// dirty: a slot holding no page has no clock to hold, and arming a
    /// write for a store that did not move is a ciphertext generation
    /// bought with a gesture that did nothing.
    public func pause(_ id: UInt64) {
        guard !Self.holdWouldStrikeItsOwnMint(
            tab: id,
            mintedTab: mintedBySelection?.tab,
            elapsed: ProcessInfo.processInfo.systemUptime - (mintedBySelection?.at ?? 0),
            within: NSEvent.doubleClickInterval
        ) else { return }
        guard client.pausePress(tab: id) else { return }
        markDirty()
        refresh()
    }

    /// Whether this hold is the second half of the double-click whose
    /// first half minted the page it would land on: the same slot, and
    /// inside the interval the system calls a double-click. Pure, so
    /// the window is testable without a gesture recognizer.
    ///
    /// The elapsed time comes from `systemUptime`, which stops while
    /// the machine sleeps, so a sleep inside the window can only make
    /// the reading shorter. Shorter errs toward ignoring a hold, but
    /// the window is the double-click interval: a hold that follows a
    /// sleep taken inside a double-click is not a gesture anyone
    /// performs. A wall clock step never moves the reading at all.
    public nonisolated static func holdWouldStrikeItsOwnMint(
        tab: UInt64, mintedTab: UInt64?, elapsed: TimeInterval, within window: TimeInterval
    ) -> Bool {
        mintedTab == tab && elapsed >= 0 && elapsed <= window
    }

    /// The rename gesture, from the tab context menu (double-click is
    /// already the pause gesture, so the name is set through the menu).
    /// An empty or all-whitespace submission clears the name and lets
    /// the label fall back to the live page's derived title, which is
    /// the core's contract. The name is durable state on the tab and it
    /// is what every future ledger record freezes, for this page and
    /// for every page the slot goes on to hold, so a rename is a
    /// mutation like any other.
    public func renameTab(_ id: UInt64, to title: String) {
        guard client.setTitle(tab: id, title) else { return }
        markDirty()
        refresh()
    }

    // MARK: Sealing — called by the editor, which places the chip

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself,
    /// the content lands as an opaque chip, and the board is cleared
    /// in the same operation (ADR-0007 Amendment 1) — the app drains
    /// the pasteboard rather than avoiding it. Consent is the gesture.
    /// `range` is the selection captured at gesture time, in UTF-16
    /// code units: the core deletes it and stands the sentinel in its
    /// place inside the same locked call (ADR-0013). A take that could
    /// not clear is said out loud: a paste that leaves the secret on
    /// the board is the failure this route exists to prevent.
    public func sealPasteboard(replacing range: NSRange) -> ChipInfo? {
        notice = nil
        guard let sheet = selectedPageID, let (at, length) = Self.wireRange(range) else { return nil }
        let (chip, cleared) = client.sealFromPasteboard(sheet: sheet, at: at, length: length)
        guard let chip else {
            flash("nothing to seal")
            return nil
        }
        pasteboardOffer = false
        markDirty()
        flash(
            cleared
                ? "sealed; the clipboard is clear"
                : "sealed, but the clipboard changed mid-take and was left untouched")
        return chip
    }

    /// An `NSRange` as the seam's `u32` pair, refused rather than
    /// truncated when it does not fit: `NSNotFound` must never travel
    /// as a position.
    nonisolated static func wireRange(_ range: NSRange) -> (at: UInt32, length: UInt32)? {
        guard let at = UInt32(exactly: range.location),
              let length = UInt32(exactly: range.length)
        else { return nil }
        return (at, length)
    }

    /// Reveal-time check for the offer: consult the core's probe once
    /// per reveal. Never a poll — the board is looked at exactly when
    /// the surface comes forward. The offer is made under the owner's
    /// page, so only the owner makes one.
    public func refreshPasteboardOffer(from surface: PresentationOwner) {
        guard admits(.pasteboardOffer, from: surface) else { return }
        pasteboardOffer = client.pasteboardHasContent()
    }

    /// Withdrawing is a release and asks nobody: an offer nobody is
    /// making is the safe state, and the surface that made this one may
    /// already have handed ownership on.
    public func withdrawPasteboardOffer() {
        guard pasteboardOffer else { return }
        pasteboardOffer = false
    }

    /// Whether the offer row should show: the board must hold content
    /// and a page must be there to take it; the ledger is a reading
    /// surface, not an ingest one. And only in the window that owns
    /// the page content (ADR-0033): the offer stands under the owner's
    /// page and its button takes the owner's road to the owner's
    /// caret, so the same row in the other window would seal into a
    /// page the person pressing it cannot see.
    public nonisolated static func shouldShowPasteboardOffer(
        boardHolds: Bool, hasPage: Bool, ledgerShowing: Bool, ownsPresentation: Bool
    ) -> Bool {
        ownsPresentation && boardHolds && hasPage && !ledgerShowing
    }

    /// Drop-to-seal: the core reads the drag pasteboard itself; the
    /// dropped bytes never transit this process. `range` is the drop
    /// point (zero length) or the selection the drop replaces.
    public func sealDrag(replacing range: NSRange) -> ChipInfo? {
        notice = nil
        guard let sheet = selectedPageID, let (at, length) = Self.wireRange(range) else { return nil }
        let chip = client.sealFromDrag(sheet: sheet, at: at, length: length)
        if chip == nil { flash("nothing to seal") } else { markDirty() }
        return chip
    }

    /// ⌘↩: seal visible ink the editor already holds. The core deletes
    /// `range` from its body and stands the sentinel there in the same
    /// locked call (ADR-0013); the editor then updates its projection
    /// to match rather than performing an edit of its own.
    public func sealText(_ text: String, replacing range: NSRange) -> ChipInfo? {
        notice = nil
        guard let sheet = selectedPageID, let (at, length) = Self.wireRange(range) else { return nil }
        let chip = client.sealText(sheet: sheet, text, at: at, length: length)
        if chip != nil { markDirty() }
        return chip
    }

    /// Copy a chip back out — the core writes the pasteboard itself,
    /// marked transient + concealed; non-consuming. Non-consuming is
    /// not read-only: a successful copy appends a sent record to the
    /// ledger, and that record is lost unless a write is armed for it
    /// (issue #52).
    public func copyOutChip(_ id: UInt64, size: String? = nil) {
        guard client.copyOutChip(id: id) else { return }
        markDirty()
        armClipboardClear()
        flash(Self.copiedLine(clearsIn: CompanionClient.clipboardClearSeconds(), size: size))
    }

    /// The confirmation after a copy-out (D-29): what happened, how
    /// much of it, and when the board gives it back, in the words the
    /// stream navigator design gave it. The size is the object's own
    /// size class, the one its block already shows, never a count; the
    /// number is the core's, read through the seam, never a promise the
    /// shell makes on its own.
    public nonisolated static func copiedLine(clearsIn seconds: UInt32, size: String? = nil)
        -> String
    {
        let what = size.map { "copied decrypted contents — \($0)." }
            ?? "copied decrypted contents."
        return "\(what) the clipboard clears in \(seconds) seconds."
    }

    /// The line after a sealed object is removed from the page, in the
    /// design's words. Its Undo is owed to issue 170: today the core
    /// zeroizes an object the moment the document stops referencing it,
    /// so an Undo would put back a reference to nothing, and the
    /// button is not offered until the detached state exists to
    /// reattach from (D-30, D-33).
    public static let removedLine = "protected content removed."

    /// Whether a removal's Undo is offered beside `removedLine`. False
    /// until issue 170 lands the detached state; the button and the
    /// plumbing are ready for it.
    public static let offersRemovalUndo = false

    /// After a removal: the line, with Undo beside it once the core can
    /// honour one.
    public func noteRemoval(undo: @escaping @MainActor () -> Void) {
        flash(
            Self.removedLine,
            action: Self.offersRemovalUndo ? NoticeAction(label: "Undo", perform: undo) : nil
        )
    }

    /// The line after a one-time link is made, in the design's words:
    /// the link is on the board, and what to do with it.
    public static let linkCopiedLine =
        "the link is on the clipboard — paste it where it needs to go."

    /// True while the shell is writing the projection itself: a
    /// page-switch rebuild, a seal's chip-face insertion, a recovery
    /// resync. The editor's storage delegate consults this and emits
    /// no operations for those writes: they describe state the core
    /// already holds, and echoing them back would apply every change
    /// twice.
    public private(set) var isApplyingProjection = false

    /// Run `body` with emission suppressed. Re-entrant: an inner write
    /// restores whatever the outer one saw.
    public func applyingProjection(_ body: () -> Void) {
        let previous = isApplyingProjection
        isApplyingProjection = true
        defer { isApplyingProjection = previous }
        body()
    }

    /// Apply an edit batch to the core's document (ADR-0013): the
    /// per-edit path that replaced the per-keystroke mirror. On
    /// acceptance this marks and refreshes exactly as the snapshot
    /// mirror did. On rejection it does not assert-crash: the batch
    /// mutated nothing core-side, so the shell logs and re-converges by
    /// one legacy `syncDocument` mirror. The page's steps go with that
    /// mirror, in the core and by the core's own rule: after a
    /// wholesale rewrite every offset a step holds describes nothing.
    ///
    /// `intent` tells the core which editing gesture produced the batch. The
    /// core owns the grouping rules and both undo stacks.
    public func applyOps(
        sheet: UInt64,
        opsJSON: String,
        intent: EditorEditIntent = .typing,
        selection: EditorEditSelection? = nil
    ) {
        // Files route first, on the tag and nothing else. A file has no
        // quiet rendering on the roll, no chips to reap, and its
        // dirtiness is the file's own rather than the sealed store's,
        // so it takes none of the page bookkeeping below.
        if sheet.isFileID {
            let accepted = client.applyFileOps(
                sheet, json: opsJSON, intent: intent, selection: selection)
            if accepted {
                markFilesDirty()
                refreshOpenFiles()
            } else {
                logger.error("the core rejected a file edit batch; restating the file whole")
                restateStorage(sheet: sheet)
            }
            return
        }
        let accepted = client.applyOps(
            sheet: sheet, json: opsJSON, intent: intent, selection: selection)
        if accepted {
            // The page just changed, so how it reads when it is quiet
            // changed with it (issue #79). Here rather than at the
            // roll's swap: this is the path a keystroke takes in either
            // mode, and the page it names is not always a page the roll
            // is on, or a page any roll is mounted over.
            invalidateQuietRendering(for: sheet)
            markDirty()
            refresh()
        } else {
            logger.error("the core rejected an edit batch; restating the page whole")
            recoverProjection(sheet: sheet)
        }
        #if DEBUG
        assertProjectionParity(sheet: sheet)
        #endif
    }

    /// End the current coalescing run without creating an undo item.
    public func finishEditingGroup(sheet: UInt64, selection: NSRange? = nil) {
        if sheet.isFileID {
            _ = client.finishFileEditingGroup(sheet, selection: selection)
        } else {
            _ = client.finishEditingGroup(sheet: sheet, selection: selection)
        }
    }

    // MARK: Undo, which is the core's stack now (issue #132)

    /// What one ⌘Z or ⇧⌘Z did: whether the core moved the page, and
    /// where it says the caret belongs afterwards.
    public struct StepOutcome: Equatable, Sendable {
        /// False means nothing moved and the caller changes nothing.
        public let applied: Bool
        /// The selection restored by the step, or nil when the step carried
        /// no selection and the editor should leave its range alone.
        public let selection: NSRange?

        public var caret: Int? { selection?.location }

        public static let nothing = StepOutcome(applied: false, selection: nil)
    }

    /// Take back the page's last local edit through the core's stack,
    /// and bring the editor's storage back into line with the document
    /// that has just moved underneath it.
    ///
    /// **A step reverts only what this device typed.** Loro's manager
    /// is bound to the document's own peer and refuses another peer's
    /// operations by design; and a device that joined a page at a key
    /// frame never received the operations an away-device undo would
    /// have to invert (ADR-0021 section 5). So ⌘Z here is undo that is
    /// safe beside another device's edits, never undo that reaches
    /// across them, and it should not grow into the latter without the
    /// key-frame law being reopened first.
    @discardableResult
    public func undoEdit(sheet: UInt64) -> StepOutcome {
        if sheet.isFileID { return fileStep(sheet) { self.client.undoFile(sheet) } }
        return step(sheet: sheet) { self.client.undo(sheet: sheet) }
    }

    /// Put the step back, on the same terms.
    @discardableResult
    public func redoEdit(sheet: UInt64) -> StepOutcome {
        if sheet.isFileID { return fileStep(sheet) { self.client.redoFile(sheet) } }
        return step(sheet: sheet) { self.client.redo(sheet: sheet) }
    }

    /// The file half of `step`, routed here rather than at the editor
    /// so that one id decides one store in one place.
    ///
    /// The editor asks the model for a step by the id it is mounted
    /// over, and that id is already the tagged one for a file, so the
    /// switch belongs where the id first reaches a store. A second
    /// switch in the view would be a second thing to keep in step, and
    /// ADR-0006's single persistent text view is precisely the
    /// arrangement where a mis-switch reverts the wrong document.
    ///
    /// The core answers both halves at once for a file, which is why
    /// there is no second call for the caret: the outcome carries it.
    private func fileStep(_ file: UInt64, _ take: () -> CompanionKit.StepOutcome?) -> StepOutcome {
        guard let outcome = take(), outcome.applied else { return .nothing }
        restateStorage(sheet: file)
        markFilesDirty()
        refreshOpenFiles()
        return StepOutcome(applied: true, selection: outcome.selection)
    }

    /// Whether the page has a step waiting in either direction: what a
    /// menu item or an affordance would grey out on.
    ///
    /// Routed on the tag like every other document question. The
    /// page's route refuses a tagged id and answers false, so without
    /// the branch the menu would grey both items over a file whose
    /// undo stack is full, and the menu would be saying something
    /// untrue about a chord that works.
    public func canUndoEdit(sheet: UInt64) -> Bool {
        sheet.isFileID ? client.canUndoFile(sheet) : client.canUndo(sheet: sheet)
    }

    public func canRedoEdit(sheet: UInt64) -> Bool {
        sheet.isFileID ? client.canRedoFile(sheet) : client.canRedo(sheet: sheet)
    }

    /// Content-free label for the next step, routed to the page or file
    /// store by the same tagged id that routes the action itself.
    public func undoActionName(sheet: UInt64) -> String? {
        sheet.isFileID
            ? client.undoFileActionName(sheet)
            : client.undoActionName(sheet: sheet)
    }

    public func redoActionName(sheet: UInt64) -> String? {
        sheet.isFileID
            ? client.redoFileActionName(sheet)
            : client.redoActionName(sheet: sheet)
    }

    /// Re-ask the core what the Edit menu should read as, and publish
    /// the answer for the two items to grey themselves out on.
    ///
    /// The page it asks about is the one under the editor, not
    /// `selection`: on the roll those can differ, and the menu speaks
    /// for the page the keyboard is in. Everything else fails closed
    /// and says no step is available: no editor mounted, a page shown
    /// read-only, an editor between pages. An unknown page fails closed
    /// in the core itself, which is why no liveness check is spelled
    /// here.
    public func refreshEditSteps() {
        guard let editor = activeEditor as? InkTextView,
              editor.isEditable,
              let sheet = editor.coordinator?.currentSheet
        else {
            editSteps.stand(canUndo: false, canRedo: false)
            return
        }
        // Through the routed pair, not the client's page route: the id
        // under the editor is a file's whenever a file is showing.
        editSteps.stand(
            canUndo: canUndoEdit(sheet: sheet),
            canRedo: canRedoEdit(sheet: sheet)
        )
    }

    /// The same question, asked on the next turn of the loop.
    ///
    /// For the callers that sit inside a SwiftUI update pass: the
    /// editor's `updateNSView`, which is where a resting card's
    /// read-only stance and a page swap both arrive. Publishing while
    /// SwiftUI is updating its own graph is what the runtime warns
    /// about, and one turn of the loop is a long way ahead of a hand
    /// reaching the menu bar.
    public func scheduleEditStepsRefresh() {
        Task { @MainActor [weak self] in self?.refreshEditSteps() }
    }

    /// The shared half of both directions: ask the core, and on a step
    /// that happened, restate the page from the document the core now
    /// holds. The core is the authority for what a step means, so the
    /// storage is rewritten from its runs rather than reverse-engineered
    /// here; the write goes in under the emission guard, because it
    /// describes a document that has already moved and echoing it back
    /// as operations would apply the step twice.
    private func step(sheet: UInt64, _ take: () -> Bool) -> StepOutcome {
        guard take() else { return .nothing }
        restateStorage(sheet: sheet)
        invalidateQuietRendering(for: sheet)
        markDirty()
        refresh()
        #if DEBUG
        assertProjectionParity(sheet: sheet)
        #endif
        return StepOutcome(applied: true, selection: client.undoSelection(sheet: sheet))
    }

    /// Rewrite a page's storage in place from the core's document.
    ///
    /// In place, and deliberately: the text view holds this exact
    /// object, so replacing the entry in the map would leave the editor
    /// laying out a storage nobody else can see. There is no second
    /// history to drop alongside it: the stack is the core's, and the
    /// core cleared or moved it before this was called.
    private func restateStorage(sheet: UInt64) {
        guard let storage = storages[sheet] else { return }
        let rebuilt = NSMutableAttributedString()
        for run in runs(of: sheet) {
            switch run {
            case .ink(let text):
                rebuilt.append(NSAttributedString(
                    string: text,
                    attributes: [.font: InkStyle.baseFont, .foregroundColor: NSColor.labelColor]
                ))
            case .chip(let info):
                rebuilt.append(NSAttributedString(attachment: ChipAttachment(info: info)))
            }
        }
        applyingProjection {
            storage.setAttributedString(rebuilt)
        }
    }

    /// Mirror the page's document to the core wholesale: the recovery
    /// path (still authoritative for chip liveness: a chip the
    /// snapshot omits was deleted in the editor and is zeroized
    /// there). The rejected-batch route arrives via
    /// `recoverProjection`; programmatic rewrites (a burn) come here
    /// directly.
    public func syncDocument(sheet: UInt64, runs: [DocumentRun]) {
        // A file has no wholesale mirror. The core has no
        // companion_file_sync_document, deliberately: the mirror exists
        // for chip liveness after a refused batch, and a file holds no
        // chips. The file recovery is a restate from the core's own
        // runs, which `applyOps` above already takes.
        if sheet.isFileID {
            restateStorage(sheet: sheet)
            return
        }
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
        if !accepted {
            logger.error("the recovery mirror itself was refused; core and editor disagree")
        }
        if accepted {
            // A wholesale rewrite is the largest change a page can take,
            // so the roll's reading of it is the most wrong (issue #79).
            invalidateQuietRendering(for: sheet)
            markDirty()
        }
        refresh()
    }

    /// Re-converge a page after the core refused an edit batch. The
    /// storage is the truth for ink; the core is the truth for chip
    /// liveness. So first strip any chip glyph the core no longer
    /// owns; the one way a well-formed batch is refused is an undo
    /// re-inserting a dead chip's attachment, and undo never un-seals
    /// (ADR-0009), so the glyph goes silently, no notice. Then mirror
    /// the storage whole and drop the page's undo history, which after
    /// a rewrite holds ranges that describe nothing.
    private func recoverProjection(sheet: UInt64) {
        guard let storage = storages[sheet] else {
            refresh()
            return
        }
        let live = chipIds(onSheet: sheet)
        applyingProjection {
            var dead: [NSRange] = []
            storage.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                if let chip = value as? ChipAttachment, !live.contains(chip.info.chipId) {
                    dead.append(range)
                }
            }
            for range in dead.reversed() {
                storage.replaceCharacters(in: range, with: "")
            }
        }
        syncDocument(sheet: sheet, runs: InkEditorView.Coordinator.runs(of: storage))
    }

    #if DEBUG
    /// The projection invariant, checked after every batch in debug
    /// builds: the editor's storage and the core's document must spell
    /// the same page. A divergence here is a bug in the emitter or the
    /// guard, and it should fail loudly where tests can see it.
    private func assertProjectionParity(sheet: UInt64) {
        guard let storage = storages[sheet] else { return }
        let shell = InkEditorView.Coordinator.runs(of: storage)
        let core = client.documentRuns(sheet: sheet)
        var matches = shell.count == core.count
        if matches {
            for (ours, theirs) in zip(shell, core) {
                switch (ours, theirs) {
                case (.ink(let a), .ink(let b)) where a == b: continue
                case (.chip(let a), .chip(let b)) where a == b.chipId: continue
                default:
                    matches = false
                }
            }
        }
        assert(matches, "the editor and the core disagree about the page")
    }
    #endif

    // MARK: Conceal — the exit ramp

    /// Open the inline confirmation for a chip's ↗ or the footer's
    /// ↗ page. Everything after this is in-place: no modal, and the
    /// network boundary is the one confirming click.
    public func beginConceal(_ target: ConcealDraft.Target) {
        notice = nil
        // The draft opens on the link's own default. Which page the
        // target sits on, and how long that page has left, is not
        // consulted (ADR-0026).
        concealDraft = ConcealDraft(target: target, ttlSecs: ConcealDraft.defaultTtlSecs)
    }

    /// The confirming click: one POST, off the main actor — the core
    /// releases its lock during the round-trip, so the surface stays
    /// live. On success the link is on the clipboard (written
    /// core-side) and the confirmation offers Burn local copy.
    public func confirmConceal() {
        guard var draft = concealDraft, !draft.inFlight else { return }
        draft.inFlight = true
        draft.error = nil
        concealDraft = draft
        let client = self.client
        let target = draft.target
        let ttl = draft.ttlSecs
        let passphrase = draft.passphrase
        let recipient = draft.recipient
        Task.detached(priority: .userInitiated) {
            let outcome: ConcealOutcome = switch target {
            case .chip(let id):
                client.concealChip(id: id, ttlSecs: ttl, passphrase: passphrase, recipient: recipient)
            case .page(let id):
                client.concealSheet(id: id, ttlSecs: ttl, passphrase: passphrase, recipient: recipient)
            }
            await MainActor.run { [weak self] in
                self?.finishConceal(outcome, for: target)
            }
        }
    }

    func finishConceal(_ outcome: ConcealOutcome, for target: ConcealDraft.Target) {
        // Before the staleness guard: the round trip moved core-side
        // state (a receipt in the ledger either way), whether or not
        // the draft that started it is still standing.
        markDirty()
        // Success has already put a link on the clipboard core-side. Its
        // clear belongs to that egress, not to whichever draft the UI is
        // showing when the response returns.
        if outcome.ok { armClipboardClear() }
        // The confirmation may have been dismissed — or reopened on a
        // different target — while the call was out; a stale outcome
        // must not land on someone else's draft. (On success the link
        // is on the clipboard and the receipt marked either way.)
        guard var draft = concealDraft, draft.target == target else { return }
        draft.inFlight = false
        if outcome.ok {
            draft.error = nil
            draft.receiptId = outcome.receiptId
            flash(Self.linkCopiedLine)
        } else {
            // Inline, with retry; content never left the sheet.
            draft.error = outcome.error ?? "the conceal failed"
        }
        concealDraft = draft
        refresh()
    }

    /// Success's one offer: the content travelled, so the local copy
    /// may go. A chip burns by a core delete that zeroizes its bytes
    /// and drops its sentinel, its glyph stripped from the projection;
    /// a page burns by closing (it rests in the ledger).
    public func burnConcealedCopy() {
        guard let draft = concealDraft, draft.receiptId != nil else { return }
        switch draft.target {
        case .chip(let id):
            removeChipFromDocument(id)
        case .page(let id):
            // The draft names a page, so the burn does too. It leaves
            // the slot standing, empty and named, the way an expiry
            // leaves one: what the user asked to be rid of is the copy
            // that travelled, and the name, the rung, the position and
            // the number key are the arrangement they built, which only
            // a close may end (ADR-0017).
            _ = client.discardPage(id: id)
            markDirty()
            refresh()
        }
        concealDraft = nil
    }

    public func dismissConceal() {
        concealDraft = nil
    }

    /// Remove a chip from the core (its bytes die there, and its
    /// sentinel leaves the document) and strip its attachment glyph
    /// from whichever page's storage still shows it. The storage edit
    /// is a projection write (the core already forgot the position),
    /// so it runs under the emission guard rather than travelling back
    /// as an op.
    private func removeChipFromDocument(_ chipId: UInt64) {
        // Which page owns the chip has to be asked before the delete
        // takes the answer away, and asked of the core rather than of
        // the storages below (issue #79). A chip can be standing on a
        // day the editor has never visited: that page has a rendering on
        // the roll and no storage at all, so the loop would find nothing
        // and the burned chip would go on being drawn there.
        let host = livePageIDs.first { chipIds(onSheet: $0).contains(chipId) }
        _ = client.deleteChip(id: chipId)
        if let host { invalidateQuietRendering(for: host) }
        for storage in storages.values {
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
            applyingProjection {
                storage.replaceCharacters(in: range, with: "")
            }
            break
        }
        markDirty()
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
    public func testConnection(completion: @escaping @MainActor (ConcealOutcome) -> Void) {
        let client = self.client
        Task.detached(priority: .userInitiated) {
            let outcome = client.testConnection()
            await MainActor.run { completion(outcome) }
        }
    }

    // MARK: Presentation ownership (ADR-0033)

    /// Move ownership of the live page content to the other window.
    /// A transfer to the window that already owns is nothing at all,
    /// which is what lets the form factor resolve and call this at
    /// every event without asking first whether anything moved.
    ///
    /// The order is the hand off, stated once: the window that is
    /// leaving unmounts, and only then does the owner change, and only
    /// an owner mounts. Unmounting is the outgoing editor leaving its
    /// place here and coming off the page's storage
    /// (`InkEditorView.Coordinator.leavePage`), so the storage changes
    /// hands with no layout manager on it and the mount that follows
    /// has nothing of the other window's to shed. SwiftUI takes the
    /// old mount's views down in its own time, before or after the new
    /// one is built, and by then there is nothing left for the order
    /// of those two callbacks to decide.
    public func transferOwnership(to newOwner: PresentationOwner) {
        guard newOwner != owner else { return }
        relinquishPresentation()
        ownershipLogger.info(
            "owner=\(newOwner.logName, privacy: .public) was=\(self.owner.logName, privacy: .public)"
        )
        owner = newOwner
        owesIncomingEditorTheKeys = true
    }

    /// A hand off has happened and the incoming owner's editor has not
    /// been handed the keyboard yet.
    ///
    /// The window that receives the page content shows a placeholder
    /// until SwiftUI's next pass builds its editor, and it is often key
    /// before that pass: a summon keys the panel from inside the raise,
    /// and a click on the editor window keys it before the page has
    /// even moved. A key window whose editor arrives later has the
    /// window itself as first responder, which is the ember lit over
    /// typing that beeps (issue #19), on a route that did not exist
    /// while each window kept its editor mounted.
    ///
    /// So the debt is recorded at the transfer and settled when the
    /// owner's window reports the keys (`reportKeys(_:from:)`), in
    /// whichever order the window's controller got there, reordering or
    /// not. Settled once: a later key gain, the keyboard coming back
    /// from Settings, follows no hand off, and the window's first
    /// responder is AppKit's to restore. A window that never takes the
    /// keys is never focused, since focus only ever accepts (ADR-0005).
    private var owesIncomingEditorTheKeys = false

    /// The outgoing owner lets go of everything it held, so that no
    /// field describes a window that no longer owns. The incoming owner
    /// writes its own as it mounts and as its window reports.
    ///
    /// The editor comes off the page first, leaving the page's place
    /// on its way while its layout manager is still its own. The
    /// scroll half goes with it only when the editor stands in a
    /// scroller of its own: the roll's clip belongs to the roll and to
    /// no page in it, which is the rule the roll's dismantle follows
    /// too.
    ///
    /// The roll's own place is asked of the roll, and before anything
    /// else, because the editor leaving its page empties a row and
    /// every row below it moves. It is kept for the roll that mounts in
    /// the other window (`PageViewStates.rollPlace`), so a hand off in
    /// the days mode keeps the scroll as one between two page surfaces
    /// does. Only a hand off writes it, and what a summon then does to
    /// it is the summon's business (`anchorOnToday`).
    ///
    /// Key status is forgotten and not carried, because it described
    /// the other window. The window that owns now reports its own, and
    /// until it does the honest reading is that nobody holds the keys.
    private func relinquishPresentation() {
        viewStates.leaveRollPlace(rollGeometry.relinquish())
        if let editor = activeEditor as? InkTextView, let coordinator = editor.coordinator {
            let scroll = editor.enclosingScrollView
            coordinator.leavePage(
                editor,
                scrollView: scroll?.documentView === editor ? scroll : nil
            )
        }
        activeEditor = nil
        performSealedPaste = nil
        onAnchorToday = nil
        withdrawPasteboardOffer()
        if holdsKeys { holdsKeys = false }
    }

    /// The guard every claim on a presentation field passes through:
    /// true when `surface` owns and the write may go ahead.
    ///
    /// A refusal is a defect in the caller, never an event. The mount
    /// sites ask `owner` before they write, so nothing reaches here
    /// from a window that does not own unless somebody forgot to ask.
    /// A debug build says so at once. A release build declines the
    /// write and leaves a line, because the alternative is the last
    /// writer winning, which is two windows each believing the editor,
    /// the paste route and the keyboard are theirs.
    func admits(_ field: PresentationField, from surface: PresentationOwner) -> Bool {
        if PresentationOwner.mayWrite(surface, owner: owner) { return true }
        ownershipLogger.error(
            "declined write field=\(field.rawValue, privacy: .public) from=\(surface.logName, privacy: .public) owner=\(self.owner.logName, privacy: .public)"
        )
        if let declinedPresentationWrite {
            declinedPresentationWrite(field, surface)
        } else {
            assertionFailure(
                "\(surface.logName) wrote \(field.rawValue) while \(owner.logName) owns (ADR-0033)"
            )
        }
        return false
    }

    /// A mount, or an update pass over one, announcing its editor.
    public func mountEditor(_ editor: NSTextView, from surface: PresentationOwner) {
        guard admits(.activeEditor, from: surface) else { return }
        activeEditor = editor
    }

    /// An editor leaving: parked, dismantled, or replaced. A release,
    /// guarded by identity and not by ownership. A teardown usually
    /// runs after ownership has moved, and the handle is cleared only
    /// when it is still this editor's, so a surface can never retire
    /// the other window's editor or a replacement that SwiftUI built
    /// before dismantling what it replaces.
    public func retireEditor(_ editor: NSTextView) {
        guard activeEditor === editor else { return }
        activeEditor = nil
    }

    /// The owner's editor naming the road the offer's button takes.
    public func routeSealedPaste(
        _ route: @escaping () -> Void, from surface: PresentationOwner
    ) {
        guard admits(.sealedPasteRoute, from: surface) else { return }
        performSealedPaste = route
    }

    /// The owner's roll handing over the way to reach Day 0.
    public func installTodayAnchor(
        _ anchor: @escaping () -> Void, from surface: PresentationOwner
    ) {
        guard admits(.todayAnchor, from: surface) else { return }
        onAnchorToday = anchor
    }

    /// The owner's roll claiming the rail's navigator. Publishing and
    /// resetting stay with `RollGeometryModel`, which answers only the
    /// roll that holds the claim, so the claim is the one write that
    /// needs the owner's word.
    func claimRollGeometry(
        by roll: AnyObject,
        scroller: ((CGFloat) -> Void)? = nil,
        scrubber: ((CGFloat) -> Void)? = nil,
        wheel: ((NSEvent) -> Void)? = nil,
        place: (() -> RollPlace?)? = nil,
        from surface: PresentationOwner
    ) {
        guard admits(.rollGeometry, from: surface) else { return }
        rollGeometry.claim(by: roll, scroller: scroller, scrubber: scrubber, wheel: wheel, place: place)
    }

    /// A window reporting its key status. Only the owner's counts: the
    /// other window gaining or losing the keyboard says nothing about
    /// whether the page holds it. The form factor decides which reports
    /// to pass on before it calls (`BackdropModel`), and this declines
    /// the ones it should not have.
    ///
    /// The first keys to arrive after a hand off are passed on to the
    /// incoming editor (`owesIncomingEditorTheKeys`).
    public func reportKeys(_ keyed: Bool, from surface: PresentationOwner) {
        guard admits(.holdsKeys, from: surface) else { return }
        guard holdsKeys != keyed else { return }
        holdsKeys = keyed
        // The keys have reached the window a hand off gave the page to:
        // pass them on to its editor, waiting for the mount if SwiftUI
        // has not built it yet.
        if keyed, owesIncomingEditorTheKeys {
            owesIncomingEditorTheKeys = false
            refocusEditorIfKeyed()
        }
    }

    // MARK: Timers

    /// The surface became visible: start the countdown redraw at
    /// `interval`. The panel shows at 1 Hz while revealed; the backdrop
    /// is always on screen and coarsens the cadence at rest instead.
    /// Restarting with a different interval is meaningful — it is how
    /// the backdrop's stance change retimes the clock — so a live timer
    /// at the wrong cadence is replaced rather than kept.
    ///
    /// There is one timer, so the cadence is the owner's to set: the
    /// countdowns that are on screen are the ones in its window.
    public func startRedraw(interval: TimeInterval = 1.0, from surface: PresentationOwner) {
        guard admits(.redrawCadence, from: surface) else { return }
        if let redrawTimer, redrawTimer.timeInterval == interval { return }
        redrawTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSummaries() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// The surface is hidden: stop redrawing. The armed event timer is
    /// the only remaining wakeup. The owner's call, as starting is: a
    /// window that does not own has no say over a clock the other one
    /// is showing.
    public func stopRedraw(from surface: PresentationOwner) {
        guard admits(.redrawCadence, from: surface) else { return }
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    /// The countdown's repaint: summaries only. Never `refresh()` —
    /// that re-arms timers and reconciles selection, work the clock
    /// tick has no business doing.
    private func refreshSummaries() {
        tabs = client.tabs()
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
                self?.settleCoreEvent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }

    /// What the fired timer does, which is the whole of what an event
    /// means to this model: settle the clock, arm a write, re-arm.
    ///
    /// Expiry is a mutation nobody typed: pages and chips left the
    /// store on their own, and the sealed file is stale until this is
    /// written. The timer is armed at the core's next event and only
    /// fires on one, and both kinds move persisted state: an expiry
    /// entombs pages, and a hold lapse rewrites the page's clock and
    /// adds to its held total inside `expire_due`'s normalize pass,
    /// which reports no expired ids. So mark on the fire, not on the
    /// count, because a lapse that returns zero ids has changed the
    /// store.
    ///
    /// A named method rather than the closure it used to be, so the
    /// arming invariant can be asserted on it (`MutationArmingTests`).
    /// The shortest rung is an hour, so no test can wait for this timer
    /// to fire on its own, and this is the one mutation site whose mark
    /// nothing else in the app would ever make good: a lapse the user
    /// never saw, over a file that would stay stale until they typed.
    func settleCoreEvent() {
        _ = client.expireDue()
        markDirty()
        refresh() // re-arms for the next event
    }
}
