import AppKit
import Foundation

/// Where sync's endpoints come from: UserDefaults overrides first,
/// then the conceal server's conventional OAuth paths — the account
/// server owns sign-in (account-auth.md §1) — and no default at all
/// for the relay, because inventing a hostname for a service that has
/// not shipped would be a claim, not a default. A pure resolution so
/// the rule is testable without defaults.
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

/// The shell's sync driver (issues #98 and #102): owns the off
/// switch, the sign-in ceremony, the engine loop, and the pairing
/// flow, all over the `companion_sync_*` seam. Off is the default and
/// off is silent — a controller that is never enabled configures
/// nothing, opens no socket, and publishes no sentence, so the app
/// with sync off is indistinguishable from the app before sync
/// existed.
///
/// Every state the engine hands up becomes a sentence exactly once,
/// in the pure functions at the bottom, which is where the tests
/// hold them.
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
    /// Pages enrolled this session, by PAGE id. Per session on
    /// purpose for now: page ids do not survive a relaunch, and the
    /// durable enrolment record arrives with the cross-relaunch
    /// wiring, not before it.
    @Published public private(set) var enrolledPages: Set<UInt64> = []

    /// What a remote change should do to the surface: the model
    /// refreshes and marks the store dirty, so a peer's edit both
    /// shows and persists.
    public var onRemoteChange: (() -> Void)?
    /// Where the conceal server URL lives, for endpoint derivation.
    public var serverUrlProvider: () -> String = { "" }

    /// The degraded conditions issue #102 owes sentences for, each a
    /// different one and none of them silent.
    public enum Trouble: Equatable, Sendable {
        /// No relay URL is configured; nothing can leave.
        case notConfigured
        /// No sign-in rests on this device.
        case signedOut
        /// A sign-in rested here and the account refused it; the token
        /// is gone and signing in again is the way back (ADR-0027 §5).
        case refused
        /// The relay did not answer; the loop retries.
        case unreachable
        /// The channel rotated past this device's key.
        case behind
    }

    // `nonisolated` so the pure endpoint resolution above can read
    // them without hopping to the main actor; they are immutable
    // strings, so isolation buys nothing.
    nonisolated static let enabledKey = "sync.enabled"
    nonisolated static let relayKey = "sync.relayURL"
    nonisolated static let authorizeKey = "sync.authorizeURL"
    nonisolated static let tokenKey = "sync.tokenURL"
    nonisolated static let clientKey = "sync.clientID"

    private let client: CompanionClient
    private let defaults: UserDefaults
    private var attached = false
    private var lastAttachPeers: Int?
    private var pumping = false
    // `nonisolated(unsafe)` for deinit's sake, the model's own timer
    // convention (PageModel.swift).
    private nonisolated(unsafe) var retryTimer: Timer?
    private nonisolated(unsafe) var pairingTimer: Timer?

    public init(client: CompanionClient, defaults: UserDefaults = FormFactor.settingsDefaults) {
        self.client = client
        self.defaults = defaults
        // Read without side effects: an enabled flag alone starts
        // nothing — `start()` does, after the state restore, so sync
        // never races the pages it would publish.
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    deinit {
        retryTimer?.invalidate()
        pairingTimer?.invalidate()
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
        Self.sentence(enabled: enabled, status: status, trouble: trouble, peers: lastAttachPeers)
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
    /// consent screen on a background task. Account-auth.md §5 budgets
    /// five minutes; every failure comes back as a sentence and
    /// nothing stored, with retry being this same button.
    public func signIn() {
        let client = self.client
        signinFailure = nil
        let begun = client.syncSigninBegin()
        guard begun.ok, let raw = begun.authorizeUrl, let url = URL(string: raw) else {
            signinFailure = Self.signinSentence(reason: begun.reason ?? "no_ceremony")
            return
        }
        NSWorkspace.shared.open(url)
        status = client.syncStatus()
        Task.detached(priority: .userInitiated) {
            let outcome = client.syncSigninFinish(patienceMs: 300_000)
            await MainActor.run { [weak self] in self?.settleSignin(outcome) }
        }
    }

    private func settleSignin(_ outcome: SyncOutcome) {
        status = client.syncStatus()
        // The switch may have gone off while the browser consent was
        // open; off means silent and detached — no attach, and no
        // failure sentence either.
        guard enabled else { return }
        guard outcome.ok else {
            signinFailure = Self.signinSentence(reason: outcome.reason ?? "refused")
            return
        }
        signinFailure = nil
        trouble = nil
        attach()
    }

    /// Sign out: one Keychain account goes, the engine dissolves, the
    /// pad is untouched. Turning sync back on is the ceremony again.
    public func signOut() {
        _ = client.syncSignout()
        attached = false
        trouble = enabled ? .signedOut : nil
        refreshState()
    }

    // MARK: The engine loop (issue #102)

    private func begin() {
        signinFailure = nil
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
        let wasAttached = attached
        attached = false
        trouble = nil
        signinFailure = nil
        pairingStage = nil
        pairingTimer?.invalidate()
        retryTimer?.invalidate()
        // The enrolment mirror stays: the core keeps its enrolment
        // across detach and re-configure, so clearing only the mirror
        // would leave pages syncing while the menu says they don't.
        // The menu is hidden while the switch is off either way.
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
        Task.detached(priority: .userInitiated) {
            let outcome = client.syncAttach()
            await MainActor.run { [weak self] in self?.settleAttach(outcome) }
        }
    }

    private func settleAttach(_ outcome: SyncOutcome) {
        // The refresh first, so the gate the settling reads is the one
        // the attach just moved rather than the one before it.
        refreshState()
        guard enabled else { return }
        let settled = Self.settledTrouble(
            ok: outcome.ok, reason: outcome.reason, gate: status?.gate)
        guard outcome.ok else {
            trouble = settled
            if settled == .unreachable { armRetry() }
            return
        }
        attached = true
        lastAttachPeers = outcome.peers
        trouble = settled
        pump()
    }

    /// One long-poll turn after another, each on a background task,
    /// for as long as sync is on and attached. The pump itself blocks
    /// for the §8 long-poll, so back-to-back turns are the intended
    /// cadence — an empty poll re-enters immediately, and delivery
    /// latency is bounded by the peers' publish clocks.
    private func pump() {
        guard enabled, attached, !pumping else { return }
        pumping = true
        let client = self.client
        Task.detached(priority: .utility) {
            let outcome = client.syncPump(waitSeconds: 25)
            await MainActor.run { [weak self] in self?.settlePump(outcome) }
        }
    }

    private func settlePump(_ outcome: SyncPumpOutcome?) {
        pumping = false
        guard enabled else { return }
        guard let outcome else {
            trouble = .unreachable
            armRetry()
            return
        }
        if let state = outcome.state { status = state }
        var sawUnreachable = false
        var sawUnauthorized = false
        var remoteChanged = false
        for event in outcome.events {
            switch event.kind {
            case "applied", "countdown_moved", "terminal":
                remoteChanged = true
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
        if remoteChanged { onRemoteChange?() }
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
            trouble = .unreachable
            armRetry()
        case .refused:
            // The relay refused the bearer under the long poll. The
            // core dropped the access token as it refused, so the next
            // turn refreshes before it polls; but a 401 comes back at
            // once rather than holding the poll open, so re-entering
            // now would be a refresh, poll, refuse loop at the speed of
            // the network. One turn on the slow clock instead, and the
            // gate says what it means rather than the shell guessing.
            refreshState()
            armRetry()
        case .again:
            if trouble == .unreachable { trouble = nil }
            pump()
        }
    }

    /// What a settled pump owes the next turn. Every outcome the core
    /// can report has to be named here: one that nothing reads falls
    /// through to re-entering the long poll at once, which for a
    /// refusal that returns instantly is a hot loop against the relay
    /// rather than a wait.
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

    /// A relay that did not answer is retried on a slow clock, never a
    /// hot loop (account-auth.md §4).
    private func armRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
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
        guard client.syncEnrolPage(id: page, enrolled: on) else { return }
        if on {
            enrolledPages.insert(page)
        } else {
            enrolledPages.remove(page)
        }
        refreshState()
    }

    /// Revoke a paired device: its record goes, and the next key
    /// rotation leaves it behind.
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
        let client = self.client
        Task.detached(priority: .utility) {
            let stage = client.syncPairingPoll()
            await MainActor.run { [weak self] in
                guard let self, self.pairingStage != nil else { return }
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
        // Off is silent whatever the core says, so a controller nobody
        // switched on publishes nothing at all.
        guard enabled else { return }
        trouble = Self.reconciled(trouble: trouble, gate: status?.gate)
    }

    // MARK: The sentences, pure and testable

    /// The one standing sentence the surface may show — nil when sync
    /// is off (off must be indistinguishable) and nil when it is quiet
    /// and well. Every degraded state gets its own, and none of them
    /// is silent (issue #102).
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
        guard let status, status.attached else { return nil }
        if peers == 0, status.enrolled > 0 {
            // Issue #94's device: enrolled pages with nobody to send
            // them to until a peer wakes.
            return "no other device is awake; pages sync when one wakes"
        }
        return nil
    }

    /// The account axis of the standing trouble, as the core reports
    /// it. The gate is the authority on whether this client may attach
    /// (ADR-0027 §5), so where it names a condition, that condition
    /// wins over whatever the shell had inferred from a refusal
    /// string. Falling behind a key rotation is not on this axis: the
    /// gate admitted that device and it is short a key, so `.behind`
    /// survives a gate with nothing to report.
    ///
    /// A nil gate here is a core that named none: one older or newer
    /// than this shell, which the seam's optional decoding is built
    /// for. That is no opinion, and the shell keeps whatever it
    /// already believed. It is not the same nil as
    /// `CompanionClient.syncGate()`'s, which is a core that could not
    /// be read at all and means "has not been passed"; that one never
    /// arrives here, because a core that cannot answer the gate cannot
    /// answer the status either.
    public nonisolated static func reconciled(trouble: Trouble?, gate: SyncGate?) -> Trouble? {
        guard let gate else { return trouble }
        switch gate {
        case .off: return .notConfigured
        case .signedOut: return .signedOut
        case .refused: return .refused
        case .unreachable: return .unreachable
        case .signingIn, .ready, .attached:
            return trouble == .behind ? .behind : nil
        }
    }

    /// What an attach outcome and the core's gate together mean. The
    /// outcome's reason is the coarser of the two: the core answers the
    /// second 401 on one attach with `signed_out`, which is exactly the
    /// case `.refused` exists to tell apart, so the gate decides and
    /// the reason only fills in what the gate does not name.
    public nonisolated static func settledTrouble(
        ok: Bool, reason: String?, gate: SyncGate?
    ) -> Trouble? {
        var inferred: Trouble?
        if !ok {
            switch reason {
            case "signed_out": inferred = .signedOut
            case "unreachable": inferred = .unreachable
            default: inferred = .notConfigured
            }
        }
        return reconciled(trouble: inferred, gate: gate)
    }

    /// A failed sign-in, one sentence per §5 failure row.
    public nonisolated static func signinSentence(reason: String) -> String {
        switch reason {
        case "abandoned":
            return "the browser never returned; sync stays signed out"
        case "state_mismatch", "no_code":
            return "the sign-in came back wrong and was refused; nothing was stored"
        case "unreachable":
            return "the server could not be reached; try signing in again"
        case "keychain":
            return "the Keychain refused to store the sign-in"
        case "busy":
            return "a sign-in is already waiting on the browser"
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
