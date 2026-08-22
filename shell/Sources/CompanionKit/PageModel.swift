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

    /// The audit trail, newest first: refreshed on every `refresh()` and
    /// whenever the ledger is shown. Metadata only, never content.
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

    /// Whether a line wider than the card wraps to the next row, or runs
    /// on with the page scrolling sideways to follow it. Persisted, and
    /// there is one wrap state rather than a stored default and a live
    /// override: Settings and ⌥Z set the same value, so the page opens
    /// however it was last left.
    @Published public var wrapsLines: Bool {
        didSet { defaults.set(wrapsLines, forKey: Self.wrapKey) }
    }
    private static let wrapKey = "wrapsLines"

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

    private let client: CompanionClient
    private let defaults: UserDefaults

    /// Test-only visibility onto the seam client, so parity between
    /// the projection and the core's document can be asserted from
    /// outside without a second handle.
    var coreClient: CompanionClient { client }

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

    /// The init's test seams, gathered into one struct so the shipping
    /// signature stays narrow however many seams the tests grow. Each
    /// member is optional and nil means the shipping value: a
    /// `stateDirectory` moves the sealed files out of the form
    /// factor's own locations and into a directory the test owns, a
    /// `client` substitutes a core handle whose credentials never
    /// reach the Keychain (the test target's
    /// `CompanionClient.ephemeral(tag:)` extension, ADR-0018), and a
    /// `saveDebounce` shortens the window so the real timer can fire
    /// inside a test's patience. The default instance leaves all three
    /// alone, which is exactly the construction every shipping call
    /// site performs.
    public struct Seams {
        let stateDirectory: URL?
        let client: CompanionClient?
        let saveDebounce: TimeInterval?

        public init(
            stateDirectory: URL? = nil,
            client: CompanionClient? = nil,
            saveDebounce: TimeInterval? = nil
        ) {
            self.stateDirectory = stateDirectory
            self.client = client
            self.saveDebounce = saveDebounce
        }
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
        logger = Logger(subsystem: formFactor.loggerSubsystem, category: "persistence")
        // Unset → float on top, matching the original behavior.
        floatsOnTop = defaults.object(forKey: Self.floatsKey) as? Bool ?? true
        // Unset → wrap, which is how every plain-text editor opens and
        // the only sane default for a card this narrow.
        wrapsLines = defaults.object(forKey: Self.wrapKey) as? Bool ?? true
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
        if !ledgerLicence {
            // Said plainly, because the consequence is invisible in the
            // interface: the ledger tab still opens, it simply stops
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
    /// empty store over it. Nothing is staged, so the ciphertext on disk
    /// describes nothing, and leaving the generation there for the rest
    /// of the session buys the user nothing (ADR-0012: the last
    /// generation should not outlive what it held).
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
        loaded: Bool, contentLicence: Bool, storeEmpty: Bool
    ) -> Bool {
        loaded && contentLicence && storeEmpty
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
        guard Self.writesEitherFile(
            loaded: stateLoaded, contentLicence: saveLicence, ledgerLicence: ledgerLicence
        ) else { return }
        terminationLatch.acquire()
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
    /// When nothing at all is staged, the content leg drops the file
    /// instead of sealing an empty store over it
    /// (`erasesContentFile`). No write ever drops the ledger's own file:
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
        let saved: Bool
        if !saveLicence {
            // Deliberately left alone, which is settled, not refused:
            // this session could not read the file and so may not write
            // over it. The ledger below is a different file under a
            // different key and is not held back by this.
            saved = true
        } else if Self.erasesContentFile(
            loaded: stateLoaded, contentLicence: saveLicence, storeEmpty: client.sheets().isEmpty
        ) {
            saved = client.persistErase(at: url.path)
            if !saved {
                logger.error("the emptied state file could not be dropped")
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
        if !settled {
            // The buffer is still dirty and nothing else is going to ask
            // for it: the debounce only arms on a mutation, so a session
            // that fails one write and then goes quiet would keep its
            // pages nowhere but in memory. Arm the retry here. The hold
            // stays taken either way: holding is not writing.
            scheduleSave(after: Self.saveRetryDebounce, mode: .default)
        }
        terminationLatch.settle(saved: settled)
        return settled
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
        // A refusal at the cap changed nothing; only a real page is dirt.
        if id != 0 { markDirty() }
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

    /// Drag-to-reorder: move `id` to `index` in visible order; the
    /// ⌘-number map follows.
    public func move(_ id: UInt64, to index: Int) {
        _ = client.moveSheet(id: id, to: UInt64(max(0, index)))
        markDirty()
        refresh()
    }

    /// Click the countdown label: one rung shorter, clock reset
    /// (docs/spec/04).
    public func cycleRung(_ id: UInt64) {
        _ = client.cycleRung(sheet: id)
        markDirty()
        refresh()
    }

    /// Double-click the tab: a three state cycle — hold the clock 1h,
    /// top up to 24h, then release it. The release is what keeps a
    /// stray double-click from ratcheting a page's life up by a day
    /// with no way back (docs/spec/04).
    public func pause(_ id: UInt64) {
        _ = client.pausePress(sheet: id)
        markDirty()
        refresh()
    }

    /// The rename gesture, from the tab context menu (double-click is
    /// already the pause gesture, so the name is set through the menu).
    /// An empty or all-whitespace submission clears the override and
    /// lets the title derive from the page's own content again, which is
    /// the core's contract. The title is persisted state and it is what
    /// every future ledger record freezes, so a rename is a mutation
    /// like any other.
    public func renameSheet(_ id: UInt64, to title: String) {
        guard client.setTitle(sheet: id, title) else { return }
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
        guard let sheet = selection, let (at, length) = Self.wireRange(range) else { return nil }
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
        guard let sheet = selection, let (at, length) = Self.wireRange(range) else { return nil }
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
        guard let sheet = selection, let (at, length) = Self.wireRange(range) else { return nil }
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
            close(id)
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
                guard let self else { return }
                // Expiry is a mutation nobody typed: pages and chips
                // left the store on their own, and the sealed file is
                // stale until this is written. The timer is armed at the
                // core's next event and only fires on one, and both
                // kinds move persisted state: an expiry entombs pages,
                // and a hold lapse rewrites the page's clock and adds to
                // its held total inside `expire_due`'s normalize pass,
                // which reports no expired ids. So mark on the fire, not
                // on the count, because a lapse that returns zero ids has
                // changed the store.
                _ = self.client.expireDue()
                self.markDirty()
                self.refresh() // re-arms for the next event
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }
}
