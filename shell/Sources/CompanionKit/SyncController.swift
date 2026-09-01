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

/// The one word the header says about sync, beside the one it already
/// says about the write (issue #102). The persistence word is the
/// pattern being followed rather than a second vocabulary invented:
/// short, lower case, absent while there is nothing to report, quiet
/// for the states that need nothing and loud for the ones that need
/// acting on. `help` and `spoken` travel with the word so a tooltip
/// and VoiceOver never have to reconstruct what it meant.
public struct SyncHeaderWord: Equatable, Sendable {
    /// How loudly the word is drawn. `quiet` is the settled state, the
    /// way `saved` is quiet; `plain` is a state in motion; `loud` is
    /// the ember reserved for what a user has to do something about.
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
    /// The pages another device is writing on right now, by PAGE id:
    /// a page is in this set while a peer's edit has landed on it
    /// recently enough to still be happening (issue #102). Derived
    /// from the ops the engine already applies, so it costs no
    /// presence protocol and claims nothing the relay was not already
    /// told.
    @Published public private(set) var editedElsewhere: Set<UInt64> = []
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
    /// Whether the sign-in now settling was one the user ended. Held
    /// only until that settling reads it: nothing durable records a
    /// cancelled ceremony, which never happened.
    private var signinGivenUp = false
    private var lastAttachPeers: Int?
    private var pumping = false
    // `nonisolated(unsafe)` for deinit's sake, the model's own timer
    // convention (PageModel.swift).
    private nonisolated(unsafe) var retryTimer: Timer?
    private nonisolated(unsafe) var pairingTimer: Timer?
    private nonisolated(unsafe) var elsewhereTimer: Timer?
    /// When a peer's edit last landed on each page. The mark's whole
    /// life is this session and this window: nothing about who is
    /// writing elsewhere is worth keeping, and nothing about it is
    /// written down.
    private var remoteEdits: [UInt64: Date] = [:]

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
        Self.sentence(enabled: enabled, status: status, trouble: trouble, peers: lastAttachPeers)
    }

    /// Whether the standing sentence names something to act on. The
    /// waiting states say themselves quietly; only a condition a user
    /// has to answer earns the ember the surface reserves for those.
    public var standingSentenceIsTrouble: Bool {
        trouble != nil
    }

    /// The header's sync word, or nil when the header should carry
    /// none: sync off, and a switch turned on over no relay at all,
    /// which the gate reads as `off` and the ADR gives nothing to say.
    public var headerWord: SyncHeaderWord? {
        Self.headerWord(
            enabled: enabled, status: status, trouble: trouble, peers: lastAttachPeers)
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
        signinGivenUp = false
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
        // The user's own decision outranks whatever this settling
        // carries. The core drops a grant that arrives for a ceremony
        // somebody gave up on, so a successful outcome here could only
        // come from a core that predates that rule, and attaching on
        // one would be signing a user in behind their own cancel.
        guard !signinGivenUp else {
            signinGivenUp = false
            signinFailure = Self.signinSentence(reason: "cancelled")
            refreshState()
            return
        }
        guard outcome.ok else {
            // A trip that never returned and a trip somebody ended come
            // back through the same door, `abandoned`, because to the
            // core they are one fact: no redirect arrived. The guard
            // above is what tells them apart, and telling someone their
            // browser never returned when they gave up on purpose would
            // be describing them to themselves wrongly.
            signinFailure = Self.signinSentence(reason: outcome.reason ?? "refused")
            return
        }
        signinFailure = nil
        signinGivenUp = false
        trouble = nil
        attach()
    }

    /// Give up on a sign-in whose browser trip is still out (ADR-0027
    /// §5: `signing_in` owes the surface a way to give up). The core
    /// ends the wait rather than recording a wish, so the gate leaves
    /// `signing_in` within a poll and the blocked finish reports the
    /// abandonment through the ordinary path.
    public func giveUpSignin() {
        signinGivenUp = client.syncSigninCancel()
        refreshState()
    }

    /// Whether the surface draws the way out. It exists only while
    /// there is a trip to end, which is the ledger clear button's
    /// shape: a control that appears with the condition it answers and
    /// leaves with it, rather than standing there disabled.
    public nonisolated static func showsGiveUpSignin(gate: SyncGate?, signinPending: Bool) -> Bool {
        gate == .signingIn || (gate == nil && signinPending)
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
        // Nothing is arriving from anywhere now, so no page may go on
        // saying that something is.
        elsewhereTimer?.invalidate()
        remoteEdits = [:]
        editedElsewhere = []
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
        var remoteChanged = false
        for event in outcome.events {
            switch event.kind {
            case "applied", "countdown_moved", "terminal":
                remoteChanged = true
                // Someone else's writing, on a page this device can
                // name: the mark that page carries for the next while
                // (issue #102). Only an applied edit counts — a
                // countdown moving or a page dying elsewhere is not
                // someone typing.
                if event.kind == "applied", let page = event.pageID {
                    remoteEdits[page] = Date()
                }
            case "rejoin_required", "epoch_conflict":
                trouble = .behind
            case "unreachable":
                sawUnreachable = true
            case "ceremony_committed", "ceremony_proposed":
                refreshState()
            default:
                break
            }
        }
        sweepElsewhere()
        if remoteChanged { onRemoteChange?() }
        if outcome.reason == "signed_out" {
            attached = false
            trouble = .signedOut
            refreshState()
            return
        }
        if outcome.reason == "not_attached" {
            attached = false
            attach()
            return
        }
        if sawUnreachable || !outcome.ok {
            trouble = .unreachable
            armRetry()
            return
        }
        if trouble == .unreachable { trouble = nil }
        pump()
    }

    /// Recompute which pages are being written elsewhere, and arm one
    /// shot to recompute again when the oldest mark lapses.
    ///
    /// One timer, at the one moment the answer can change on its own,
    /// rather than a clock ticking over a set that is empty nearly
    /// always: the same frugality the countdown follows.
    private func sweepElsewhere() {
        let now = Date()
        remoteEdits = remoteEdits.filter { now.timeIntervalSince($0.value) < Self.elsewhereWindow }
        let marked = Self.editedElsewhere(marks: remoteEdits, now: now)
        if marked != editedElsewhere { editedElsewhere = marked }
        elsewhereTimer?.invalidate()
        guard let oldest = remoteEdits.values.min() else { return }
        let lapses = Self.elsewhereWindow - now.timeIntervalSince(oldest)
        let timer = Timer(timeInterval: max(lapses, 0.5), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sweepElsewhere() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elsewhereTimer = timer
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
            return "the relay cannot be reached; edits stay local and sync retries"
        case .behind:
            return "sync fell behind a key rotation; edits stay local until this pad rejoins"
        case nil:
            break
        }
        // Not a degraded state, and not a silent one either: a browser
        // is open on the user's screen waiting for them, and the app
        // that opened it should say so rather than look idle (ADR-0027
        // §5, `signing_in`).
        if status?.gate == .signingIn {
            return "waiting on your browser to finish signing in; Settings can give up on it"
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
    /// core reports (ADR-0027 §5) and by nothing the shell inferred.
    ///
    /// Three rules, all inherited from the persistence word rather than
    /// invented here. Nothing shows while there is nothing to report,
    /// so a user who never turned sync on sees a header identical to
    /// the one before sync existed. The settled state is quiet, the way
    /// `saved` is quiet, because a working channel is not news. And the
    /// two states a user has to act on are loud, the way `save failed`
    /// is loud.
    ///
    /// `off` earns no word even with the switch on, which happens when
    /// no relay is configured: the ADR gives that state nothing to say
    /// here, and the page's standing sentence says the whole of it in a
    /// place with room for the reason.
    public nonisolated static func headerWord(
        enabled: Bool, status: SyncStatus?, trouble: Trouble?, peers: Int?
    ) -> SyncHeaderWord? {
        guard enabled else { return nil }
        // Falling behind a rotation is not a gate state (ADR-0027 §5),
        // and it outranks the gate's own good news: a device the
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
            // Issue #94's device: enrolled pages and nobody awake to
            // receive them. Saying "synced" there would be the one
            // cheerful lie this word could tell.
            if peers == 0, let status, status.enrolled > 0 {
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

    /// What gate a core too old or too new to name one would have
    /// named, read back from the shell's own trouble. A fallback and
    /// never an override: `headerWord` consults it only where the core
    /// said nothing, so the gate stays the authority wherever there is
    /// one (ADR-0027 §5).
    private nonisolated static func gateStandingIn(for trouble: Trouble?) -> SyncGate? {
        switch trouble {
        case .notConfigured: return .off
        case .signedOut: return .signedOut
        case .refused: return .refused
        case .unreachable: return .unreachable
        case .behind, nil: return nil
        }
    }

    /// The account axis of the standing trouble, as the core reports
    /// it. The gate is the authority on whether this client may attach
    /// (ADR-0027 §5), so where it names a condition, that condition
    /// wins over whatever the shell had inferred from a refusal
    /// string. Falling behind a key rotation is not on this axis: the
    /// gate admitted that device and it is short a key, so `.behind`
    /// survives a gate with nothing to report.
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

    /// How long a peer's edit keeps a page marked as being written
    /// elsewhere. Long enough to cover the pauses in someone's typing
    /// and the publish clock's own two seconds, short enough that the
    /// mark means "now" rather than "today". A guess, and the only
    /// number here that is one: it is the length of a pause that still
    /// reads as the same session of writing.
    public nonisolated static let elsewhereWindow: TimeInterval = 90

    /// Which pages count as being written elsewhere, given when each
    /// last took a peer's edit. Pure, so the rule is testable without
    /// a relay or a clock that has to be waited out.
    public nonisolated static func editedElsewhere(
        marks: [UInt64: Date], now: Date, window: TimeInterval = elsewhereWindow
    ) -> Set<UInt64> {
        Set(marks.filter { now.timeIntervalSince($0.value) < window }.keys)
    }

    /// When the channel last saw a device, in the words its row shows
    /// (issue #102's device list). The stamp is the attach time the
    /// relay reported for that peer, which is the one piece of
    /// metadata ADR-0021 §4 admits the relay may hold, so this says
    /// "seen" rather than "active": it is when the device joined the
    /// channel, not when it last typed anything.
    ///
    /// Coarse on purpose. A device list is read to answer "is my
    /// laptop on this channel, and roughly since when", and a stamp to
    /// the second would be a precision the number does not have — the
    /// roster is refreshed when this Mac attaches, so it ages between
    /// attaches. A future stamp is a clock disagreeing across two
    /// machines, not a device seen tomorrow, so it reads as just now.
    public nonisolated static func lastSeen(attachedWallMs: UInt64?, nowWallMs: UInt64) -> String {
        guard let attachedWallMs else { return "not seen on this channel" }
        let elapsed = nowWallMs > attachedWallMs ? nowWallMs - attachedWallMs : 0
        let seconds = elapsed / 1000
        if seconds < 90 { return "seen just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "seen \(minutes) minutes ago" }
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
            // Never a server's word. The core answers this only when
            // there was nothing to finish, so falling through to the
            // refusal below would put a "no" in the mouth of a server
            // that was never asked (ADR-0027 §2).
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
