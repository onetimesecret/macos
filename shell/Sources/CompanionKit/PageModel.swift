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

/// What the quit path learned from its flush, in the order the alert
/// cares about: a refused write is the loudest, a session that was
/// never allowed to write but holds real content repeats the warning
/// the banner has been showing, and everything else quits silently
/// (issue #49: the quit-time behavior repeats the warning if unsaved
/// work remains).
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

@MainActor
public final class PageModel: ObservableObject {
    /// What this form factor decides differently — where its Keychain
    /// items and sealed file live, which rung a fresh page opens on.
    public let formFactor: FormFactor

    /// The strip: one entry per durable tab, in visible order, whether
    /// or not the tab holds a page (ADR-0017). A tab whose page expired
    /// keeps its place here, named and empty.
    @Published public private(set) var tabs: [TabSummary] = []

    /// The visibly selected **tab**, the slot the editor shows a page
    /// from and the gestures act on. It is the tab's id and never the
    /// page's, because a slot the user is looking at may hold nothing.
    /// Nil only when no tabs exist.
    @Published public var selection: UInt64?

    /// The ledger tab is showing instead of a page.
    @Published public var showingLedger = false

    /// The audit trail, newest first: refreshed on every `refresh()` and
    /// whenever the ledger is shown. Metadata only, never content.
    @Published public private(set) var ledgerEntries: [LedgerEntry] = []

    /// A refusal or status line the surface shows briefly ("the window
    /// holds 9 tabs…"). Refuse-don't-evict means the app says so.
    @Published public var notice: String?

    /// Notices are transient by contract: each `flash` restarts the
    /// clock, and the line clears itself unless a newer notice has
    /// taken its place.
    private var noticeGeneration = 0

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

    /// Whether a line wider than the card wraps to the next row, or runs
    /// on with the page scrolling sideways to follow it. Persisted, and
    /// there is one wrap state rather than a stored default and a live
    /// override: Settings and ⌥Z set the same value, so the page opens
    /// however it was last left.
    @Published public var wrapsLines: Bool {
        didSet { defaults.set(wrapsLines, forKey: Self.wrapKey) }
    }
    private static let wrapKey = "wrapsLines"

    /// Whether the surface groups the live pages by the day they were
    /// born on and stands the tabs down the side, instead of showing
    /// the durable slots along the bottom (issue #79). A prototype, off
    /// until the user asks for it.
    ///
    /// Persisted the way every other preference here is, and persisted
    /// nowhere else: this writes one boolean to `defaults` and never
    /// calls `markDirty()`. A mark would take the sudden-termination
    /// hold and arm a debounced ciphertext write, so looking at the same
    /// pages a second way would buy a fresh sealed generation every time
    /// the user changed their mind. Nothing else moves either — the
    /// projection reads `tabs` and calls no core mutator — which is what
    /// makes the toggle safe in both directions by construction rather
    /// than by care.
    @Published public var showsTimeUnits: Bool {
        didSet { defaults.set(showsTimeUnits, forKey: Self.timeUnitsKey) }
    }
    private static let timeUnitsKey = "showsTimeUnits"

    /// ⌥Z. A page whose lines all fit shows no difference, so the toggle
    /// says what it did rather than leaving the keystroke looking dead.
    public func toggleWrap() {
        wrapsLines.toggle()
        flash(wrapsLines ? "long lines wrap" : "long lines run on")
    }

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
    public weak var activeEditor: NSTextView?

    /// Set by the app delegate; Esc routes here when no editor holds
    /// the keys (the controller re-keys the frontmost app's window).
    public var onHandBackKeys: (() -> Void)?

    /// Set by the app delegate; ⌘, routes here (the delegate owns the
    /// Settings window, the surface merely asks for it).
    public var onOpenSettings: (() -> Void)?

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

    /// Each live page's undo history. Undo is as document-scoped as
    /// the storage it rewrites (ADR-0006): one editor serves every
    /// page, so letting the window's single manager span pages would
    /// let ⌘Z on one page replay edits against another. Keyed by page
    /// identity for the reason `storages` is: undo carried across a
    /// page replacement in a reused tab is how a dead chip's glyph
    /// comes back. Pruned with the storages; cleared for a page whose
    /// storage is changed behind the editor's back.
    private var undoManagers: [UInt64: UndoManager] = [:]

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

        public init(
            stateDirectory: URL? = nil,
            client: CompanionClient? = nil,
            saveDebounce: TimeInterval? = nil,
            saveRetryDebounce: TimeInterval? = nil,
            keymapOverride: URL? = nil
        ) {
            self.stateDirectory = stateDirectory
            self.client = client
            self.saveDebounce = saveDebounce
            self.saveRetryDebounce = saveRetryDebounce
            self.keymapOverride = keymapOverride
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
        client = seams.client ?? CompanionClient(credentialService: formFactor.credentialService)
        stateFileURL = seams.stateDirectory.map(FormFactor.stateFileURL(in:))
            ?? formFactor.stateFileURL
        ledgerFileURL = seams.stateDirectory.map(FormFactor.ledgerFileURL(in:))
            ?? formFactor.ledgerFileURL
        saveDebounce = seams.saveDebounce ?? Self.saveDebounce
        saveRetryDebounce = seams.saveRetryDebounce ?? Self.saveRetryDebounce
        logger = Logger(subsystem: formFactor.loggerSubsystem, category: "persistence")
        // Resolved once, here, so the surface and the page's text view
        // are answering out of one map. A test reads only the override
        // it named, which for most of them is none.
        keymap = Keymap.load(
            userOverride: Self.userKeymapURL(formFactor: formFactor, seam: seams.keymapOverride)
        )
        keymap.report(subsystem: formFactor.loggerSubsystem)
        // Unset → float on top, matching the original behavior.
        floatsOnTop = defaults.object(forKey: Self.floatsKey) as? Bool ?? true
        // Unset → wrap, which is how every plain-text editor opens and
        // the only sane default for a card this narrow.
        wrapsLines = defaults.object(forKey: Self.wrapKey) as? Bool ?? true
        // Unset → off. A prototype is something a user turns on, and an
        // upgrade must not rearrange the pad of somebody who never
        // asked for a second way of looking at it (issue #79).
        showsTimeUnits = defaults.object(forKey: Self.timeUnitsKey) as? Bool ?? false
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
        _ = self.client.configureConnection(
            serverUrl: defaults.string(forKey: Self.serverKey) ?? Self.defaultServer,
            shareDomain: defaults.string(forKey: Self.shareDomainKey) ?? "",
            extid: defaults.string(forKey: Self.extidKey) ?? "",
            token: nil
        )
        connection = self.client.connectionInfo()
    }

    /// Whether the first reveal has run — restore is attempted once.
    private var stateLoaded = false

    /// Whether anything changed after the load settled: typed ink, a
    /// new or closed tab, a rename, a rung. Set at every `markDirty`
    /// and reset once at the end of `loadStateIfNeeded`, so the mint
    /// that launch itself performs does not count as the user's work.
    /// The quit warning under a withheld licence hangs off this: in a
    /// session that cannot write, everything it records is exactly
    /// what a quit would lose (issue #49).
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
        selection = tabs.first?.id
        // The load is settled, mint included: what happens from here is
        // the user's work, and only that arms the quit warning.
        mutatedSinceLoad = false
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
        // the quit warning is about.
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

    /// Arm the deferred write, unless one is already armed. The timer
    /// runs in `.common` so a tracked menu cannot stall the write past
    /// its window; the failure retry runs in `.default` instead, so it
    /// cannot fire underneath the terminate path's modal alert and make
    /// that alert's text false while the user reads it.
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
        guard Self.writesEitherFile(
            loaded: stateLoaded, contentLicence: saveLicence, ledgerLicence: ledgerLicence
        ) else { return true }
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
        let saved: Bool
        if !saveLicence {
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
        let ledgerSaved = ledgerLicence
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
        let settled = saved && ledgerSaved
        // The surface's answer, from the write's own outcome and
        // nowhere else. On the withheld-content leg this can read
        // "saved" while the pages went nowhere; the surface shows the
        // standing `contentRestoreRefused` state ahead of this one, so
        // that reading is never displayed (issue #49).
        saveStatus = settled ? .saved : .failed
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

    /// The quit alert's truth table (issue #49). A refused write is the
    /// loudest outcome regardless of the licence, because pages that
    /// were supposed to land did not. A settled flush over a withheld
    /// content licence warns only when the session accumulated work
    /// after the load: an untouched session under a withheld licence
    /// loses nothing by quitting, and warning there would teach the
    /// user to click through the one alert that matters.
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

    deinit {
        eventTimer?.invalidate()
        redrawTimer?.invalidate()
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
    /// promotion drafts are checked against.
    private var livePageIDs: Set<UInt64> {
        Set(tabs.compactMap(\.pageID))
    }

    public func refresh() {
        tabs = client.tabs()
        let livePages = livePageIDs
        // A dead page's ink lives on only in the ledger; drop the
        // editor-side document, and its undo history with it. The
        // filter is on the live PAGE identities and never on the tabs,
        // because a tab outlives its page: keyed by the slot, a reused
        // tab would inherit the dead page's storage and undo stack, and
        // a ⌘Z past the page boundary would re-insert a zeroized chip's
        // attachment character (ADR-0009, ADR-0017 item 9).
        storages = storages.filter { livePages.contains($0.key) }
        undoManagers = undoManagers.filter { livePages.contains($0.key) }
        selection = Self.reconciledSelection(current: selection, live: tabs.map(\.id))
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
                liveChips = Set(livePages.flatMap { chipIds(onSheet: $0) })
            }
            if Self.isRefreshOrphan(
                target: draft.target, liveSheets: livePages, liveChips: liveChips
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
    /// single NSTextView. When the view is torn down and a fresh editor
    /// later mounts, those cached managers still hold operations
    /// targeting the dead view: replaying one drives a zombie
    /// reference, not the live editor (issue #23). A mount clears them
    /// so ⌘Z after a remount is a clean no-op rather than a misfire.
    /// Page↔page swaps keep the same view and are untouched.
    ///
    /// **Every page's, and not the mounted one's, because every one of
    /// them points at the same dead view.** There is no narrower
    /// discard to make: an operation registered against the torn-down
    /// editor is dead whether or not its page is still alive, so
    /// keeping one would be keeping the zombie rather than keeping the
    /// history.
    ///
    /// The teardown is more frequent since the split (ADR-0017), and
    /// that cost is stated rather than hidden. The empty state used to
    /// be reached only when the last page in the store died; now the
    /// selected tab holding no page is enough, so a visit to a slot
    /// whose page expired overnight unmounts the editor and the next
    /// mount spends the undo history of every other live page with it.
    /// Nothing on screen or on disk changes: what the user loses is
    /// ⌘Z reaching back past that visit.
    public func discardUndoHistory() {
        undoManagers.values.forEach { $0.removeAllActions() }
    }

    // MARK: Navigation — the keyboard map

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
        let leavingLedger = showingLedger
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
        if leavingLedger || minted { refocusEditorIfKeyed() }
    }

    /// ⌘1 to ⌘9: jump by visible tab order. The index is into the strip,
    /// so ⌘3 means the third slot whether or not it holds a page, and
    /// it means the same slot next week.
    public func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// ⌥⌘← / ⌥⌘→. Steps slots, not pages, and mints into the slot it
    /// lands on when that slot is empty.
    public func step(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let leavingLedger = showingLedger
        if leavingLedger { showingLedger = false }
        let current = tabs.firstIndex { $0.id == selection } ?? 0
        let next = Self.steppedIndex(from: current, by: delta, within: tabs.count)
        let landed = tabs[next].id
        selection = landed
        let minted = openPageIfSlotIsEmpty(landed)
        // The walk lands on slots, and the slot it lands on may be
        // empty, so it carries `select`'s hand-off for `select`'s
        // reasons. One call rather than two: a walk that both leaves
        // the ledger and mints has one editor to focus, and the focus
        // is asked for after the mint rather than before it, so the
        // wait is for the editor that is actually coming.
        if leavingLedger || minted { refocusEditorIfKeyed() }
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
        #if DEBUG
        keyboardHandoffs += 1
        #endif
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self else { return }
                if requireKeys, !self.holdsKeys { return }
                if let editor = Self.mountedEditor(self.activeEditor) {
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
    static func mountedEditor(_ editor: NSTextView?) -> NSTextView? {
        guard let editor, editor.window != nil else { return nil }
        return editor
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

    /// A new tab at this form factor's opening rung, holding a new
    /// page. 0 means the store refused at the cap of 9. Returns the
    /// TAB's id, which is what the selection keeps.
    @discardableResult
    private func newTab() -> UInt64 {
        let id = client.newTab()
        if id != 0, let rung = formFactor.defaultRung {
            _ = client.setRung(tab: id, rung: rung)
        }
        // A refusal at the cap changed nothing; only a real tab is dirt.
        if id != 0 { markDirty() }
        return id
    }

    /// A new page (⌘N or the + tab). At the cap the app declines and
    /// says so.
    public func newPage() {
        notice = nil
        let created = newTab()
        if created == 0 {
            // Not "let one expire" any more: an expiry empties a slot
            // and never frees it, so closing is the only thing that
            // moves the wall (ADR-0017). Saying otherwise would send
            // the user off to wait for something that cannot happen.
            flash("the window holds 9 tabs, close one to make room")
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
        // Three cases, in the order the strip can be in. No tabs at
        // all: conjure one, which is the launch-into-emptiness case.
        // A selected slot holding nothing: open a page into it, so
        // Return lands on the slot the user was looking at rather than
        // widening the strip (ADR-0017 item 11). A selected slot that
        // already holds a page: the grant promises one page and not one
        // per keystroke, so focus what exists.
        if tabs.isEmpty {
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
    /// Closing also clears any standing refusal, the cap condition it
    /// named may be resolved. Explicit close is one of the two things
    /// that end a tab (ADR-0017), and it takes the slot with the page.
    public func close(_ id: UInt64) {
        notice = nil
        // A draft aimed at this page — or at a chip riding on it —
        // dies with it. Left standing, the confirmation would still
        // answer ↩ ("Create link" carries the default action) with a
        // network call over a page that no longer exists (issue #19).
        // The chips must be asked for *before* the close; a dead page
        // replays no runs.
        let closingPage = tabs.first { $0.id == id }?.pageID
        if let draft = promotion, let closingPage,
           Self.shouldClearPromotion(
               target: draft.target,
               closingSheet: closingPage,
               chipsOnSheet: chipIds(onSheet: closingPage)
           ) {
            promotion = nil
        }
        _ = client.closeTab(id: id)
        markDirty()
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

    /// Drag-to-reorder: move the tab `id` to `index` in visible order;
    /// the ⌘-number map follows. The arrangement is the slot's, so it
    /// survives every page the slot holds.
    public func move(_ id: UInt64, to index: Int) {
        _ = client.moveTab(id: id, to: UInt64(max(0, index)))
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
    public func copyOutChip(_ id: UInt64) {
        if client.copyOutChip(id: id) { markDirty() }
    }

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
    /// mutated nothing core-side, so the shell logs, re-converges by
    /// one legacy `syncDocument` mirror, and clears that page's undo
    /// history, because stale-range undo replays after a wholesale rewrite
    /// would corrupt the document they no longer describe.
    public func applyOps(sheet: UInt64, opsJSON: String) {
        let accepted = client.applyOps(sheet: sheet, json: opsJSON)
        if accepted {
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

    /// Mirror the page's document to the core wholesale: the recovery
    /// path (still authoritative for chip liveness: a chip the
    /// snapshot omits was deleted in the editor and is zeroized
    /// there). The rejected-batch route arrives via
    /// `recoverProjection`; programmatic rewrites (a burn) come here
    /// directly.
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
        if !accepted {
            logger.error("the recovery mirror itself was refused; core and editor disagree")
        }
        if accepted { markDirty() }
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
        undoManagers[sheet]?.removeAllActions()
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

    // MARK: Promotion — the exit ramp

    /// Open the inline confirmation for a chip's ↗ or the footer's
    /// ↗ page. Everything after this is in-place: no modal, and the
    /// network boundary is the one confirming click.
    public func beginPromotion(_ target: PromotionDraft.Target) {
        notice = nil
        // A page draft names a page; a chip draft borrows the selected
        // slot's page, which is the page the chip is showing on.
        let pageId: UInt64? = switch target {
        case .page(let id): id
        case .chip: selectedPageID
        }
        let remaining = tabs.first { $0.pageID == pageId }?.remainingMs ?? 0
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
        // Before the staleness guard: the round trip moved core-side
        // state (a receipt in the ledger either way), whether or not
        // the draft that started it is still standing.
        markDirty()
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
    /// may go. A chip burns by a core delete that zeroizes its bytes
    /// and drops its sentinel, its glyph stripped from the projection;
    /// a page burns by closing (it rests in the ledger).
    public func burnPromotedCopy() {
        guard let draft = promotion, draft.receiptId != nil else { return }
        switch draft.target {
        case .chip(let id):
            removeChipFromDocument(id)
        case .page(let id):
            // The draft names a page, so the burn does too. It leaves
            // the slot standing, empty and named, the way an expiry
            // leaves one: what the user asked to be rid of is the copy
            // that travelled, and the name, the rung, the position and
            // the number key are the arrangement they built, which only
            // a close and the cap may end (ADR-0017).
            _ = client.discardPage(id: id)
            markDirty()
            refresh()
        }
        promotion = nil
    }

    public func dismissPromotion() {
        promotion = nil
    }

    /// Remove a chip from the core (its bytes die there, and its
    /// sentinel leaves the document) and strip its attachment glyph
    /// from whichever page's storage still shows it. The storage edit
    /// is a projection write (the core already forgot the position),
    /// so it runs under the emission guard rather than travelling back
    /// as an op.
    private func removeChipFromDocument(_ chipId: UInt64) {
        _ = client.deleteChip(id: chipId)
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
            applyingProjection {
                storage.replaceCharacters(in: range, with: "")
            }
            // The storage changed behind the editor's back: the page's
            // undo history now points at offsets that may no longer
            // exist, and — as everywhere — undo must never resurrect
            // what was sealed and has now travelled. History dies.
            undoManagers[sheet]?.removeAllActions()
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
