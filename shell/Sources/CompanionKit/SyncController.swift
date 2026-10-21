import AppKit
import Foundation

/// Where sync's endpoints come from: UserDefaults overrides first, then
/// the conceal server's OAuth paths (account-auth.md §1), and no
/// default relay, since an invented hostname would be a claim.
public struct SyncEndpoints: Equatable, Sendable {
    public let relayUrl: String
    public let authorizeUrl: String
    public let tokenUrl: String
    public let clientId: String

    /// Whether enough is known to configure sync at all: the relay is
    /// the one piece with no derivable default.
    public var complete: Bool { !relayUrl.isEmpty }

    public static func resolve(
        serverUrl: String,
        relayOverride: String?,
        authorizeOverride: String?,
        tokenOverride: String?,
        clientOverride: String?
    ) -> SyncEndpoints {
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        return SyncEndpoints(
            relayUrl: relayOverride ?? "",
            authorizeUrl: authorizeOverride ?? "\(base)/oauth/authorize",
            tokenUrl: tokenOverride ?? "\(base)/oauth/token",
            clientId: clientOverride ?? "onetime-companion"
        )
    }

    static func resolve(serverUrl: String, defaults: UserDefaults) -> SyncEndpoints {
        resolve(
            serverUrl: serverUrl,
            relayOverride: defaults.string(forKey: SyncController.relayKey),
            authorizeOverride: defaults.string(forKey: SyncController.authorizeKey),
            tokenOverride: defaults.string(forKey: SyncController.tokenKey),
            clientOverride: defaults.string(forKey: SyncController.clientKey)
        )
    }
}

/// The one word the header says about sync, beside the persistence
/// word and in its pattern (issue #102, surface.md §4). `help` and
/// `spoken` travel with it for the tooltip and VoiceOver.
public struct SyncHeaderWord: Equatable, Sendable {
    /// How loudly the word is drawn: `quiet` settled, `plain` in
    /// motion, `loud` for what a user has to act on.
    public enum Tone: Equatable, Sendable {
        case quiet
        case plain
        case loud
    }

    public let text: String
    public let tone: Tone
    public let help: String
    public let spoken: String
}

/// The shell's sync driver (issues #98 and #102): the off switch, the
/// sign-in ceremony, the engine loop and the pairing flow over the
/// `companion_sync_*` seam. Off is the default and silent: no socket,
/// no sentence. Each engine state becomes a sentence once, in the pure
/// functions at the bottom; retry rules: client protocol §3.
@MainActor
public final class SyncController: ObservableObject {
    /// The off switch, off by default, persisted like every setting.
    /// Turning it on configures and attaches; turning it off detaches
    /// and stops the loop, and the standing sentence goes with it.
    @Published public var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { begin() } else { stop() }
        }
    }

    /// The seam's standing state, refreshed by every action and every
    /// pump.
    @Published public private(set) var status: SyncStatus?
    /// The device list, refreshed with the status.
    @Published public private(set) var devices: [SyncDevice] = []
    /// The pairing ceremony's stage while one is in flight.
    @Published public private(set) var pairingStage: SyncPairingStage?
    /// The last degraded condition the loop met; nil while sync is
    /// quiet and well.
    @Published public private(set) var trouble: Trouble?
    /// A failed sign-in's sentence, standing until the next attempt.
    @Published public private(set) var signinFailure: String?
    /// The pages another device is writing on right now, by PAGE id,
    /// derived from the ops the engine already applies (issue #102).
    @Published public private(set) var editedElsewhere: Set<UInt64> = []
    /// Pages enrolled this session, by PAGE id; nothing persists them
    /// across a relaunch yet.
    @Published public private(set) var enrolledPages: Set<UInt64> = []

    /// What a remote change should do to the surface: the model
    /// rereads the local pages an applied edit moved, refreshes, and
    /// marks the store dirty.
    public var onRemoteChange: ((Set<UInt64>) -> Void)?
    /// What a refused enrolment should do: the model settles as the timer would, since
    /// a page past its deadline refuses (Law 0001, expiry row), and says so.
    public var onEnrolRefused: ((UInt64) -> Void)?
    /// Where the conceal server URL lives, for endpoint derivation.
    public var serverUrlProvider: () -> String = { "" }
    /// How the authorize URL reaches the system browser, never a web
    /// view (account-auth.md §3); a seam so tests open no browser.
    var openAuthorizeUrl: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The degraded conditions issue #102 owes sentences for, each a
    /// different one and none of them silent.
    public enum Trouble: Equatable, Sendable {
        /// No relay URL is configured; nothing can leave.
        case notConfigured
        /// No sign-in rests on this device.
        case signedOut
        /// A sign-in rested here and the account refused it; the token
        /// is gone and signing in again is the way back (account-auth
        /// decision background §5).
        case refused
        /// The relay did not answer; the loop retries.
        case unreachable
        /// The channel rotated past this device's key.
        case behind
    }

    // `nonisolated` so the pure endpoint resolution above can read them.
    nonisolated static let enabledKey = "sync.enabled"
    nonisolated static let relayKey = "sync.relayURL"
    nonisolated static let authorizeKey = "sync.authorizeURL"
    nonisolated static let tokenKey = "sync.tokenURL"
    nonisolated static let clientKey = "sync.clientID"

    private let client: CompanionClient
    private let defaults: UserDefaults
    private var attached = false
    /// Whether the sign-in now settling was one the user ended. Held
    /// only until that settling reads it: nothing durable records a
    /// cancelled ceremony, which never happened.
    private var signinGivenUp = false
    /// The attach response's peer count is the compatibility fallback
    /// until a readable device roster supplies the current count.
    private var lastAttachPeers: Int?
    private var pumping = false
    /// Which run of the engine loop is the live one; a turn that comes
    /// back from an earlier session is dropped, since off and on inside
    /// one long poll leaves `enabled` true for both.
    private(set) var session: UInt64 = 0
    // `nonisolated(unsafe)` for deinit's sake, the model's own timer
    // convention (PageModel.swift).
    private nonisolated(unsafe) var retryTimer: Timer?
    /// Attach refusals in a row that settled to no trouble, for the
    /// backoff in `attachRetryDelay`.
    private var quietRefusals = 0
    private nonisolated(unsafe) var pairingTimer: Timer?
    /// One pairing poll in flight at a time, as `pumping` is for the
    /// pump: a relay slower than the tick would otherwise stack rounds
    /// and post the same queued message twice.
    private var pairingPolling = false
    private nonisolated(unsafe) var elsewhereTimer: Timer?
    /// When a peer's edit last landed on each page; in memory only.
    private var remoteEdits: [UInt64: Date] = [:]
    /// When the armed sweep is due. Held so a pump that changed
    /// nothing about the earliest mark leaves the timer standing.
    private var elsewhereDeadline: Date?

    public init(client: CompanionClient, defaults: UserDefaults = FormFactor.settingsDefaults) {
        self.client = client
        self.defaults = defaults
        // An enabled flag alone starts nothing; `start()` does, after
        // the state restore, so sync never races the pages it publishes.
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    deinit {
        retryTimer?.invalidate()
        pairingTimer?.invalidate()
        elsewhereTimer?.invalidate()
    }

    /// The launch hook, once, after the state restore: a disabled
    /// controller returns without a side effect of any kind.
    public func start() {
        guard enabled else { return }
        begin()
    }

    /// The standing sentence for the surface's status stack; nil when
    /// sync is off (silence is the promise) or quiet and well.
    public var standingSentence: String? {
        Self.sentence(enabled: enabled, status: status, trouble: trouble, peers: displayedPeers)
    }

    /// Whether the standing sentence names something to act on.
    public var standingSentenceIsTrouble: Bool {
        trouble != nil
    }

    /// The header's sync word, or nil when the header should carry
    /// none: sync off, and a switch turned on over no relay at all,
    /// which the gate reads as `off` and the ADR gives nothing to say.
    public var headerWord: SyncHeaderWord? {
        Self.headerWord(
            enabled: enabled, status: status, trouble: trouble, peers: displayedPeers)
    }

    /// The roster's peer count when it carries this device, else the
    /// attach answer's, never a softened zero.
    private var displayedPeers: Int? {
        Self.currentPeers(devices: devices, attachFallback: lastAttachPeers)
    }

    /// The Settings section's own status line: the standing sentence,
    /// or the sign-in failure, or a quiet word.
    public var settingsLine: String? {
        if let signinFailure { return signinFailure }
        if let standingSentence { return standingSentence }
        guard enabled, status?.signedIn == true else { return nil }
        return attached ? "sync is on" : "reaching the relay…"
    }

    /// Whether the settings line names a condition needing action.
    public var settingsLineIsTrouble: Bool {
        signinFailure != nil || trouble != nil
    }

    public func isEnrolled(_ page: UInt64) -> Bool {
        enrolledPages.contains(page)
    }

    // MARK: The sign-in ceremony (issue #98)

    /// Open the system browser on the authorize URL and wait out the
    /// consent screen on a background task (five minutes,
    /// account-auth.md §5); a failure is a sentence, nothing stored.
    public func signIn() {
        let client = self.client
        signinFailure = nil
        signinGivenUp = false
        let begun = client.syncSigninBegin()
        guard begun.ok, let raw = begun.authorizeUrl, let url = URL(string: raw) else {
            signinFailure = Self.signinSentence(reason: begun.reason ?? "no_ceremony")
            return
        }
        openAuthorizeUrl(url)
        let mine = session
        // Through `refreshState`, so the standing `signedOut` is
        // reconciled against the gate's `signing_in`.
        refreshState()
        Task.detached(priority: .userInitiated) {
            let outcome = client.syncSigninFinish(patienceMs: 300_000)
            await MainActor.run { [weak self] in self?.settleSignin(outcome, session: mine) }
        }
    }

    private func settleSignin(_ outcome: SyncOutcome, session mine: UInt64) {
        // A ceremony belongs to the session that opened the browser.
        guard session == mine else { return }
        status = client.syncStatus()
        // Off means silent: no attach and no failure sentence.
        guard enabled else { return }
        // The user's give-up outranks whatever this settling carries.
        guard !signinGivenUp else {
            signinGivenUp = false
            signinFailure = Self.signinSentence(reason: "cancelled")
            refreshState()
            return
        }
        guard outcome.ok else {
            // The core says `abandoned` for both; the guard above tells
            // a give-up from a browser that never returned.
            signinFailure = Self.signinSentence(reason: outcome.reason ?? "refused")
            return
        }
        signinFailure = nil
        signinGivenUp = false
        trouble = nil
        attach()
    }

    /// Give up on a sign-in whose browser trip is still out (account-auth
    /// decision background §5); the core ends the wait and the finish
    /// reports `abandoned`.
    public func giveUpSignin() {
        signinGivenUp = client.syncSigninCancel()
        refreshState()
    }

    /// Whether the surface draws the way out: only while there is a
    /// trip to end.
    public nonisolated static func showsGiveUpSignin(gate: SyncGate?, signinPending: Bool) -> Bool {
        gate == .signingIn || (gate == nil && signinPending)
    }

    /// Sign out: one Keychain account goes, the engine dissolves, the
    /// pad is untouched. Turning sync back on is the ceremony again.
    public func signOut() {
        // A browser trip still out settles as `abandoned`; the new
        // session drops that settle, so a sign-out is never worded as
        // a browser that never returned.
        session &+= 1
        _ = client.syncSignout()
        attached = false
        trouble = enabled ? .signedOut : nil
        refreshState()
    }

    // MARK: The engine loop (issue #102)

    private func begin() {
        session &+= 1
        signinFailure = nil
        // A fresh configuration starts the backoff afresh.
        quietRefusals = 0
        let endpoints = SyncEndpoints.resolve(
            serverUrl: serverUrlProvider(), defaults: defaults)
        guard endpoints.complete,
            client.syncConfigure(
                relayUrl: endpoints.relayUrl,
                authorizeUrl: endpoints.authorizeUrl,
                tokenUrl: endpoints.tokenUrl,
                clientId: endpoints.clientId
            )
        else {
            trouble = .notConfigured
            refreshState()
            return
        }
        trouble = nil
        refreshState()
        if status?.signedIn == true {
            attach()
        } else {
            trouble = .signedOut
        }
    }

    private func stop() {
        session &+= 1
        let wasAttached = attached
        attached = false
        pumping = false
        // The switch ends a browser trip too; the core would persist a
        // late grant before the shell could decline it.
        trouble = nil
        signinFailure = nil
        pairingStage = nil
        pairingTimer?.invalidate()
        retryTimer?.invalidate()
        quietRefusals = 0
        _ = client.syncSigninCancel()
        signinGivenUp = false
        // Nothing is arriving now, so no page says something is.
        elsewhereTimer?.invalidate()
        elsewhereTimer = nil
        elsewhereDeadline = nil
        remoteEdits = [:]
        editedElsewhere = []
        // The enrolment mirror stays, as the core's enrolment does.
        guard wasAttached else {
            refreshState()
            return
        }
        let client = self.client
        Task.detached(priority: .utility) {
            _ = client.syncDetach()
            await MainActor.run { [weak self] in self?.refreshState() }
        }
    }

    private func attach() {
        let client = self.client
        let mine = session
        Task.detached(priority: .userInitiated) {
            let outcome = client.syncAttach()
            await MainActor.run { [weak self] in self?.settleAttach(outcome, session: mine) }
        }
    }

    private func settleAttach(_ outcome: SyncOutcome, session mine: UInt64) {
        guard session == mine else { return }
        // The refresh first, so the settling reads the gate the attach
        // just moved.
        refreshState()
        guard enabled else { return }
        let settled = Self.settledTrouble(
            ok: outcome.ok, reason: outcome.reason, gate: status?.gate)
        trouble = Self.standing(trouble: trouble, after: settled)
        guard outcome.ok else {
            if Self.attachRetries(after: settled) {
                // Only a success or sync off resets the count.
                let quiet = Self.attachBacksOff(afterRefusal: outcome.reason)
                if quiet { quietRefusals += 1 }
                armRetry(
                    after: quiet
                        ? Self.attachRetryDelay(quietRefusals: quietRefusals) : 30)
            } else {
                // A named trouble arms no retry and resets the backoff.
                quietRefusals = 0
            }
            return
        }
        quietRefusals = 0
        attached = true
        lastAttachPeers = outcome.peers
        pump()
    }

    /// One long-poll turn after another on a background task while sync
    /// is on and attached; one turn at a time per session (client
    /// protocol §3).
    private func pump() {
        guard enabled, attached, !pumping else { return }
        pumping = true
        let client = self.client
        let mine = session
        Task.detached(priority: .utility) {
            let outcome = client.syncPump(waitSeconds: 25)
            await MainActor.run { [weak self] in self?.settlePump(outcome, session: mine) }
        }
    }

    func settlePump(_ outcome: SyncPumpOutcome?, session mine: UInt64) {
        // Before the flag: an ended session's turn owns nothing now.
        guard session == mine else { return }
        pumping = false
        guard enabled else { return }
        guard let outcome else {
            trouble = Self.standing(trouble: trouble, after: .unreachable)
            armRetry()
            return
        }
        if let state = outcome.state {
            status = state
            // A pump state is a status refresh; the roster comes with it.
            devices = client.syncDevices()
        }
        var sawUnreachable = false
        var sawUnauthorized = false
        var remoteChanged = false
        var editedPages: Set<UInt64> = []
        for event in outcome.events {
            switch event.kind {
            case "applied", "countdown_moved", "terminal":
                remoteChanged = true
                // Only an applied edit marks a page as written
                // elsewhere (issue #102).
                if event.kind == "applied", let page = event.pageID {
                    remoteEdits[page] = Date()
                    editedPages.insert(page)
                }
            case "rejoin_required", "epoch_conflict":
                trouble = .behind
            case "unreachable":
                sawUnreachable = true
            case "unauthorized":
                sawUnauthorized = true
            case "ceremony_committed", "ceremony_proposed":
                refreshState()
            default:
                break
            }
        }
        sweepElsewhere()
        if remoteChanged { onRemoteChange?(editedPages) }
        switch Self.pumpTurn(
            ok: outcome.ok, reason: outcome.reason, sawUnreachable: sawUnreachable,
            sawUnauthorized: sawUnauthorized)
        {
        case .signedOut:
            attached = false
            trouble = .signedOut
            refreshState()
        case .reattach:
            attached = false
            attach()
        case .unreachable:
            trouble = Self.standing(trouble: trouble, after: .unreachable)
            armRetry()
        case .refused:
            // A 401 returns at once, so re-entering would loop; one turn
            // on the slow clock, and the gate names the state.
            refreshState()
            armRetry()
        case .again:
            if trouble == .unreachable { trouble = nil }
            pump()
        }
    }

    /// What a settled pump owes the next turn; an unnamed outcome would
    /// re-enter at once, a hot loop for an instant refusal.
    public enum PumpTurn: Equatable {
        /// The credential is gone. Stop, and say so.
        case signedOut
        /// The attachment is gone. Attach again.
        case reattach
        /// Nobody answered. The slow retry clock, never a hot loop.
        case unreachable
        /// The relay refused the bearer. Also the slow clock, but the
        /// account gate owns the sentence, not the network.
        case refused
        /// A quiet, well round: straight back into the long poll.
        case again
    }

    /// The pure rule behind the switch above.
    public nonisolated static func pumpTurn(
        ok: Bool, reason: String?, sawUnreachable: Bool, sawUnauthorized: Bool
    ) -> PumpTurn {
        if reason == "signed_out" { return .signedOut }
        if reason == "not_attached" { return .reattach }
        if sawUnreachable || !ok { return .unreachable }
        if sawUnauthorized { return .refused }
        return .again
    }

    /// Recompute which pages are being written elsewhere, and arm one
    /// shot for when the oldest mark lapses.
    private func sweepElsewhere() {
        let now = Date()
        remoteEdits = remoteEdits.filter { now.timeIntervalSince($0.value) < Self.elsewhereWindow }
        let marked = Self.editedElsewhere(marks: remoteEdits, now: now)
        if marked != editedElsewhere { editedElsewhere = marked }
        guard let oldest = remoteEdits.values.min() else {
            elsewhereTimer?.invalidate()
            elsewhereTimer = nil
            elsewhereDeadline = nil
            return
        }
        // A deadline that did not move keeps its timer.
        let deadline = oldest.addingTimeInterval(Self.elsewhereWindow)
        guard deadline != elsewhereDeadline || elsewhereTimer == nil else { return }
        elsewhereTimer?.invalidate()
        let lapses = Self.elsewhereWindow - now.timeIntervalSince(oldest)
        let timer = Timer(timeInterval: max(lapses, 0.5), repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Let go of the fired timer before sweeping, so the
                // sweep it triggers always arms the next one.
                self?.elsewhereTimer = nil
                self?.sweepElsewhere()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elsewhereTimer = timer
        elsewhereDeadline = deadline
    }

    /// A relay that did not answer is retried on a slow clock, never a
    /// hot loop (account-auth.md §4).
    private func armRetry(after delay: TimeInterval = 30) {
        retryTimer?.invalidate()
        let mine = session
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.session == mine else { return }
                if self.attached { self.pump() } else { self.attach() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Enrolment and devices

    /// Enrol a page into the channel or withdraw it — the per-page
    /// opt-in of relay protocol §1.
    public func enrol(page: UInt64, on: Bool) {
        guard client.syncEnrolPage(id: page, enrolled: on) else {
            onEnrolRefused?(page)
            return
        }
        if on {
            enrolledPages.insert(page)
        } else {
            enrolledPages.remove(page)
        }
        refreshState()
    }

    /// Revoke a paired device: its record goes; only a ceremony this
    /// device proposes leaves it out (client protocol §7.9).
    public func revoke(fingerprint: String) {
        _ = client.syncRevokePeer(fingerprint: fingerprint)
        refreshState()
    }

    // MARK: Pairing (issue #97's ceremony on issue #102's surface)

    public func beginInvite() {
        beginPairing { $0.syncInviteBegin() }
    }

    public func beginJoin() {
        beginPairing { $0.syncJoinBegin() }
    }

    private func beginPairing(_ begin: (CompanionClient) -> SyncOutcome) {
        let outcome = begin(client)
        guard outcome.ok else {
            pairingStage = SyncPairingStage(
                stage: "failed", sas: nil, reason: outcome.reason ?? "not_attached")
            return
        }
        pairingStage = SyncPairingStage(stage: "waiting", sas: nil, reason: nil)
        armPairingPoll()
    }

    /// The human's verdict on the six digits; a mismatch aborts whole.
    public func confirmPairing(matched: Bool) {
        pairingStage = client.syncPairingConfirm(matched: matched)
        if matched {
            armPairingPoll()
        } else {
            pairingTimer?.invalidate()
        }
    }

    /// Dismiss the pairing flow at any stage.
    public func cancelPairing() {
        _ = client.syncPairingCancel()
        pairingStage = nil
        pairingTimer?.invalidate()
        refreshState()
    }

    private func armPairingPoll() {
        pairingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPairing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pairingTimer = timer
    }

    private func pollPairing() {
        guard pairingStage != nil else {
            pairingTimer?.invalidate()
            return
        }
        guard !pairingPolling else { return }
        pairingPolling = true
        let client = self.client
        Task.detached(priority: .utility) {
            let stage = client.syncPairingPoll()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pairingPolling = false
                guard self.pairingStage != nil else { return }
                switch stage?.stage {
                case "done":
                    self.pairingStage = stage
                    self.pairingTimer?.invalidate()
                    self.refreshState()
                case "failed":
                    self.pairingStage = stage
                    self.pairingTimer?.invalidate()
                case "idle":
                    // The core holds no ceremony: nothing to render.
                    self.pairingStage = nil
                    self.pairingTimer?.invalidate()
                case .some:
                    self.pairingStage = stage
                case nil:
                    break
                }
            }
        }
    }

    private func refreshState() {
        status = client.syncStatus()
        devices = client.syncDevices()
        // Off is silent whatever the core says.
        guard enabled else { return }
        trouble = Self.reconciled(trouble: trouble, gate: status?.gate)
    }

    // MARK: The sentences, pure and testable

    /// Other devices attached per a readable roster; without this
    /// device's own row, the attach answer stands rather than a zero.
    public nonisolated static func currentPeers(
        devices: [SyncDevice], attachFallback: Int?
    ) -> Int? {
        guard devices.contains(where: { $0.thisDevice }) else { return attachFallback }
        return devices.filter { !$0.thisDevice && $0.attachedMs != nil }.count
    }

    /// The one standing sentence the surface may show: nil when sync is
    /// off or quiet and well; each degraded state its own (issue #102).
    public nonisolated static func sentence(
        enabled: Bool, status: SyncStatus?, trouble: Trouble?, peers: Int?
    ) -> String? {
        guard enabled else { return nil }
        switch trouble {
        case .notConfigured:
            return "sync is on but has no relay configured; nothing leaves this Mac"
        case .signedOut:
            return "sync is signed out; the pad is unaffected"
        case .refused:
            return "the account refused this sign-in; sync is off and the pad is unaffected"
        case .unreachable:
            return "sync could not reach the server; edits stay local and sync retries"
        case .behind:
            return "sync fell behind a key rotation; edits stay local until this pad rejoins"
        case nil:
            break
        }
        // A browser waits on the user, so say so (account-auth decision
        // background §5).
        if status?.gate == .signingIn {
            return "waiting on the browser to finish signing in; Settings can give up on it"
        }
        guard let status, status.attached else { return nil }
        if peers == 0, status.enrolled > 0 {
            // Issue #94's device: enrolled pages with nobody to send
            // them to until a peer wakes.
            return "no other device is awake; pages sync when one wakes"
        }
        return nil
    }

    /// The header's word for where sync stands, driven by the gate the
    /// core reports (account-auth decision background §5) and by nothing
    /// the shell inferred. The words, tones and the `off` rule are
    /// surface.md §4.
    public nonisolated static func headerWord(
        enabled: Bool, status: SyncStatus?, trouble: Trouble?, peers: Int?
    ) -> SyncHeaderWord? {
        guard enabled else { return nil }
        // Falling behind a rotation is not a gate state (account-auth
        // decision background §5), and it outranks the gate's own good
        // news: a device the
        // channel rotated past passed the gate and lacks a key.
        if trouble == .behind {
            return SyncHeaderWord(
                text: "sync behind",
                tone: .loud,
                help:
                    "This Mac is behind the channel's current key. Edits stay local until it rejoins.",
                spoken: "Sync is behind a key rotation"
            )
        }
        switch status?.gate ?? gateStandingIn(for: trouble) {
        case .off, nil:
            return nil
        case .signedOut:
            return SyncHeaderWord(
                text: "sync signed out",
                tone: .plain,
                help: "Sync is on and signed out. Sign in from Settings; the pad is unaffected.",
                spoken: "Sync is signed out"
            )
        case .signingIn:
            return SyncHeaderWord(
                text: "signing in",
                tone: .plain,
                help: "Waiting on your browser to finish signing in. Settings can give up on it.",
                spoken: "Signing in, waiting on the browser"
            )
        case .refused:
            return SyncHeaderWord(
                text: "sync refused",
                tone: .loud,
                help:
                    "The account refused this sign-in and the stored one is gone. Sign in again from Settings; the pad is unaffected.",
                spoken: "The account refused sync"
            )
        case .unreachable:
            return SyncHeaderWord(
                text: "sync offline",
                tone: .loud,
                help: "The relay cannot be reached. Edits stay on this Mac and sync keeps retrying.",
                spoken: "Sync is offline and retrying"
            )
        case .ready:
            return SyncHeaderWord(
                text: "reaching",
                tone: .plain,
                help: "Signed in, reaching the relay to attach.",
                spoken: "Reaching the relay"
            )
        case .attached:
            // Issue #94's device: attached with nobody awake reads
            // waiting, never synced, enrolled pages or not (D-20).
            if peers == 0 {
                return SyncHeaderWord(
                    text: "sync waiting",
                    tone: .plain,
                    help:
                        "No other device is awake. The pages you chose travel as soon as one is.",
                    spoken: "Sync is waiting for another device"
                )
            }
            return SyncHeaderWord(
                text: "synced",
                tone: .quiet,
                help: "Attached to the channel; the pages you chose travel to your paired devices.",
                spoken: "Synced"
            )
        }
    }

    /// The gate a core that named none would have named, read from the
    /// shell's trouble; consulted only where the core said nothing.
    private nonisolated static func gateStandingIn(for trouble: Trouble?) -> SyncGate? {
        switch trouble {
        case .notConfigured: return .off
        case .signedOut: return .signedOut
        case .refused: return .refused
        case .unreachable: return .unreachable
        case .behind, nil: return nil
        }
    }

    /// The account axis of the standing trouble: where the gate names a
    /// condition, it wins (account-auth decision background §5).
    /// `.behind` is not on this axis
    /// and survives a gate with nothing to report or an unreachable one
    /// (surface.md §4). A nil gate is a core that named none and keeps
    /// what the shell believed; `CompanionClient.syncGate()`'s nil, an
    /// unreadable core, never arrives here.
    public nonisolated static func reconciled(trouble: Trouble?, gate: SyncGate?) -> Trouble? {
        guard let gate else { return trouble }
        switch gate {
        case .off: return .notConfigured
        case .signedOut: return .signedOut
        case .refused: return .refused
        case .unreachable: return trouble == .behind ? .behind : .unreachable
        case .signingIn, .ready, .attached:
            return trouble == .behind ? .behind : nil
        }
    }

    /// What a turn's own verdict does to the standing trouble:
    /// `.behind` outlives an unreachable blip and a quiet turn, and
    /// every other verdict is the newer fact and wins (surface.md §4).
    public nonisolated static func standing(trouble: Trouble?, after verdict: Trouble?) -> Trouble?
    {
        if trouble == .behind, verdict == nil || verdict == .unreachable { return .behind }
        return verdict
    }

    /// Whether a refused attach is tried again on the timer, from the
    /// trouble it settled to: no trouble, or `.unreachable`, is
    /// retried with no cap; a named trouble is not (client protocol
    /// §4.3).
    public nonisolated static func attachRetries(after settled: Trouble?) -> Bool {
        settled == nil || settled == .unreachable
    }

    /// How long before a refused attach is tried again: 30 seconds,
    /// doubling per quiet refusal to 300 (client protocol §3, §4.3). A
    /// `keychain` refusal reads the Keychain on every try, and a read
    /// can raise a prompt.
    public nonisolated static func attachRetryDelay(quietRefusals: Int) -> TimeInterval {
        let doublings = min(max(quietRefusals - 1, 0), 4)
        return TimeInterval(min(30 << doublings, 300))
    }

    /// Whether a retried attach refusal counts toward that backoff,
    /// read from the core's reason, since the gate can still show an
    /// earlier turn's `unreachable`: every reason but `unreachable` and
    /// `busy` counts (client protocol §4.3).
    public nonisolated static func attachBacksOff(afterRefusal reason: String?) -> Bool {
        reason != "unreachable" && reason != "busy"
    }

    /// What an attach outcome and the core's gate together mean: the
    /// gate decides where it names a condition, and a reason this shell
    /// does not name reads as no trouble (client protocol §4.3).
    public nonisolated static func settledTrouble(
        ok: Bool, reason: String?, gate: SyncGate?
    ) -> Trouble? {
        var inferred: Trouble?
        if !ok {
            switch reason {
            case "not_configured", "poisoned": inferred = .notConfigured
            case "signed_out": inferred = .signedOut
            case "unreachable": inferred = .unreachable
            default: inferred = nil
            }
        }
        return reconciled(trouble: inferred, gate: gate)
    }

    /// How long a peer's edit keeps a page marked as being written
    /// elsewhere: a pause that still reads as the same session of
    /// writing. A guess, and the only number here that is one.
    public nonisolated static let elsewhereWindow: TimeInterval = 90

    /// Which pages count as being written elsewhere, given when each
    /// last took a peer's edit.
    public nonisolated static func editedElsewhere(
        marks: [UInt64: Date], now: Date, window: TimeInterval = elsewhereWindow
    ) -> Set<UInt64> {
        Set(marks.filter { now.timeIntervalSince($0.value) < window }.keys)
    }

    /// When the channel last saw a device, in the words its row shows:
    /// the attach time the relay reported for that peer, coarse, with a
    /// future stamp read as just now (surface.md §3).
    public nonisolated static func lastSeen(attachedWallMs: UInt64?, nowWallMs: UInt64) -> String {
        guard let attachedWallMs else { return "not seen on this channel" }
        let elapsed = nowWallMs > attachedWallMs ? nowWallMs - attachedWallMs : 0
        let seconds = elapsed / 1000
        if seconds < 90 { return "seen just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "seen \(minutes) \(minutes == 1 ? "minute" : "minutes") ago" }
        let hours = minutes / 60
        if hours < 24 { return "seen \(hours) \(hours == 1 ? "hour" : "hours") ago" }
        let days = hours / 24
        return "seen \(days) \(days == 1 ? "day" : "days") ago"
    }

    /// A failed sign-in, one sentence per §5 failure row.
    public nonisolated static func signinSentence(reason: String) -> String {
        switch reason {
        case "abandoned":
            return "the browser never returned; sync stays signed out"
        case "cancelled":
            return "the sign-in was given up; nothing was stored"
        case "state_mismatch", "no_code":
            return "the sign-in came back wrong and was refused; nothing was stored"
        case "unreachable":
            return "the server could not be reached; try signing in again"
        case "keychain":
            return "the Keychain refused to store the sign-in"
        case "busy":
            return "a sign-in is already waiting on the browser"
        case "no_ceremony":
            // Never a server's word: no server was asked (account-auth
            // decision background §2).
            return "there was no sign-in to finish; nothing was stored"
        case "not_configured":
            return "sync has no server configured to sign in against"
        default:
            return "the server refused the sign-in; nothing was stored"
        }
    }

    /// The pairing flow's sentence for its non-SAS stages.
    public nonisolated static func pairingSentence(stage: String, reason: String?) -> String {
        switch stage {
        case "waiting":
            return "waiting for the other device"
        case "confirmed":
            return "confirmed here; waiting for the other device"
        case "done":
            return "paired"
        case "failed" where reason == "mismatch":
            return "the strings did not match; nothing was stored"
        case "failed":
            return "pairing failed; nothing was stored"
        default:
            return ""
        }
    }
}
