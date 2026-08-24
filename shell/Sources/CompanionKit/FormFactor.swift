import Foundation

/// What one form factor decides differently from the other, gathered
/// into one value the shared model reads.
///
/// ADR-0010 put the form factors in sibling targets and named the
/// extraction that fires when a sibling graduates. Persistence fired it
/// once, for the seam wrapper. Feature parity fires it again and harder:
/// the tab strip, the ink editor, the ledger, and the promotion flow are
/// the same code, and the same code touching sealed content must not
/// exist twice. What is genuinely per-form-factor is small enough to fit
/// here (where the Keychain items live, where the sealed file rests,
/// which defaults domain holds the settings, which rung a fresh page
/// opens on), so the difference is data the shared model reads rather
/// than a second copy of the model.
public struct FormFactor: Sendable {
    /// Scopes this form factor's Keychain items, always the running
    /// build's own identifier (ADR-0012: services derive from the bundle
    /// id, and the debug lane's `.debug` suffix splits dev from release
    /// structurally). Keychain ACLs are granted to the code identity
    /// that created an item, so two signed binaries sharing one state
    /// key would each meet a confirmation prompt for the other's.
    ///
    /// Never nil now, so `companion_new_scoped` is the only constructor
    /// path: the core's own unscoped default would put a `.debug` build
    /// and an installed release build on one key again.
    public let credentialService: String

    /// The directory under Application Support holding the sealed state
    /// file, named for the running build's bundle id and carrying a
    /// `.noindex` suffix so Spotlight leaves the ciphertext generations
    /// alone. Two form factors, two stores, and two configurations, two
    /// stores: neither reads the other's.
    public let stateDirectory: String

    /// The unified-log subsystem for this form factor's trails.
    public let loggerSubsystem: String

    /// The rung a fresh page opens on, or nil for the core's own
    /// default. The backdrop favours a week, a span you can reason
    /// about by the calendar ("still need this next Friday?"), where
    /// the panel opens shorter.
    public let defaultRung: Rung?

    public init(
        credentialService: String,
        stateDirectory: String,
        loggerSubsystem: String,
        defaultRung: Rung?
    ) {
        self.credentialService = credentialService
        self.stateDirectory = stateDirectory
        self.loggerSubsystem = loggerSubsystem
        self.defaultRung = defaultRung
    }

    /// Where the sealed store rests between runs. Ciphertext only: the
    /// key lives in the Keychain, so the file alone says nothing.
    public var stateFileURL: URL {
        Self.stateFileURL(
            in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(stateDirectory, isDirectory: true))
    }

    /// The sealed store's place inside any state directory. One name,
    /// stated once, whether the directory is the form factor's own or
    /// one a test injected: a test that spelled the name itself could
    /// drift from the name the app writes and pass against a file the
    /// app never reads.
    ///
    /// **The core knows this name too**, as `STATE_FILE_NAME` in
    /// `crates/ffi/src/persist.rs`, where it decides whether dropping a
    /// file should take the content key with it: only the state file
    /// may, and a ledger Clear that did would destroy every staged page.
    /// Renaming this does not break that decision, since the core falls
    /// back to reading the envelope magic, but it does move the
    /// unreadable-file case onto the fallback, so change both together.
    public static func stateFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("state.sealed")
    }

    /// The ledger's place beside it, under the same single-naming rule.
    public static func ledgerFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("ledger.sealed")
    }

    /// Where the ledger rests: its own file under its own long-lived
    /// key (ADR-0012), so discarding staged content at a new boot
    /// session leaves the audit record intact. Metadata plus the
    /// capped, page-owned title; never content.
    ///
    /// Deliberately a sibling of `state.sealed` rather than a second
    /// location, so whatever the state directory grows (bundle-id
    /// naming, `.noindex`, backup exclusion) covers the ledger without
    /// a second directory-preparation path.
    public var ledgerFileURL: URL {
        Self.ledgerFileURL(in: stateFileURL.deletingLastPathComponent())
    }

    /// Makes the state directory ready to be written into, and hands
    /// back the state file URL the caller was after.
    ///
    /// Two properties beyond "the directory exists". The `.noindex`
    /// suffix in the directory's name keeps Spotlight out, and
    /// `isExcludedFromBackup` keeps Time Machine out: every debounced
    /// write renames a fresh sealed file over the old one, and a rename
    /// unlinks rather than erases, so a backup or a local snapshot that
    /// captured the directory would hold ciphertext generations the app
    /// believes it has replaced. Nothing covers those generations on a
    /// schedule any more: ADR-0016 retracted crypto-erasure at the next
    /// boot session, and what replaces it fires when the pad empties,
    /// which may be never. A generation captured before that moment,
    /// together with a captured pair of key halves, stays readable
    /// (ADR-0016 section 8), which is exactly why the copies are worth
    /// keeping out of the backup in the first place.
    ///
    /// The ledger rests in this same directory, so it inherits both
    /// without a second preparation path.
    ///
    /// Static and keyed on the state file rather than on `self`, so a
    /// model writing into an injected directory prepares it through
    /// exactly the code the shipping directories go through.
    @discardableResult
    public static func prepareStateDirectory(holding stateFile: URL) throws -> URL {
        var directory = stateFile.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        return stateFile
    }

    /// This form factor's own directory, through the same preparation.
    @discardableResult
    public func prepareStateDirectory() throws -> URL {
        try Self.prepareStateDirectory(holding: stateFileURL)
    }

    /// The base identifier the panel shipped under before it was
    /// archived (ADR-0014), kept because it is the prefix every
    /// identifier this app answers to must carry, and because retiring
    /// it would strand any panel install's Keychain items and state.
    public static let panelBundleIdentifier = "com.onetimesecret.companion"

    /// The base identifier the app ships under. The product is named
    /// OnetimePad now, but the id keeps the legacy backdrop string:
    /// macOS keys the state directory, Keychain items, the keychain
    /// access group, and TCC grants off the id (ADR-0014).
    public static let backdropBundleIdentifier = "com.onetimesecret.companion.backdrop"

    /// The identifier this build actually runs under, or `fallback` when
    /// the running process is not one of ours.
    ///
    /// The guard is load bearing, not a formality. A bare `swift run`
    /// binary has no bundle identifier at all, and `swift test` runs
    /// under the xctest tool's identifier, so an unguarded
    /// `Bundle.main.bundleIdentifier` would point the panel's state
    /// directory and Keychain items at another process's name.
    ///
    /// Accepted: `fallback` itself, or `fallback` plus one dot-free
    /// configuration suffix, which is exactly what the build lane
    /// produces (`package-app.sh --debug` appends `.debug`). Counting
    /// dots is all the second clause does, so it cannot tell a
    /// configuration suffix from a sibling form factor's own id: asked
    /// with the panel's fallback inside the backdrop process, it
    /// answers with the backdrop's identifier, because `.backdrop` is
    /// one dot-free suffix exactly as `.debug` is. Inert as things
    /// stand, the panel having been archived (ADR-0014) and nothing
    /// shipping asking for `FormFactor.panel`, and pinned as it stands
    /// by `FormFactorTests`, but a second form factor returning would
    /// need a rule that names its siblings rather than one that counts
    /// dots.
    public static func resolvedBundleIdentifier(fallback: String) -> String {
        resolvedBundleIdentifier(running: Bundle.main.bundleIdentifier, fallback: fallback)
    }

    /// The rule itself, over the identifier the process is running
    /// under rather than over `Bundle.main`. Same visibility as the
    /// suite that drives it and no wider: under xctest `Bundle.main` is
    /// the test runner, which takes the early return above, so every
    /// guard that follows it is unreachable through the shipping entry
    /// point. Those guards are what keeps a `.debug` rebuild off the
    /// installed release copy's `state.sealed` and Keychain items, so
    /// they are worth reaching (`FormFactorTests`).
    static func resolvedBundleIdentifier(running: String?, fallback: String) -> String {
        guard let running, running.hasPrefix(panelBundleIdentifier) else { return fallback }

        if running == fallback { return running }

        guard running.hasPrefix(fallback + ".") else { return fallback }
        let suffix = running.dropFirst(fallback.count + 1)
        guard !suffix.isEmpty, !suffix.contains(".") else { return fallback }
        return running
    }

    /// The summoned panel (docs/spec/04): accessory posture, the core's
    /// default opening rung.
    ///
    /// Computed rather than stored, because the identifier it derives
    /// everything from is a property of the running build: a `.debug`
    /// copy and an installed release copy are two apps to LaunchServices
    /// and must be two stores here, or two processes on one debounce
    /// clobber one another's `state.sealed`.
    public static var panel: FormFactor {
        let id = resolvedBundleIdentifier(fallback: panelBundleIdentifier)
        return FormFactor(
            credentialService: id,
            stateDirectory: "\(id).noindex",
            loggerSubsystem: id,
            defaultRung: nil
        )
    }

    /// The background surface (docs/spec/feature/background-surface):
    /// its own Keychain service and its own state file, reached through
    /// `companion_new_scoped`.
    public static var backdrop: FormFactor {
        let id = resolvedBundleIdentifier(fallback: backdropBundleIdentifier)
        return FormFactor(
            credentialService: id,
            stateDirectory: "\(id).noindex",
            loggerSubsystem: id,
            defaultRung: .sevenDays
        )
    }
}

// MARK: - The installed app's data is not a test fixture

extension FormFactor {
    /// The identifier prefix every process running an XCTest bundle
    /// carries, whether `swift test` spawned it or Xcode did.
    static let testRunnerBundlePrefix = "com.apple.dt.xctest"

    /// Whether a construction that would land on a form factor's own
    /// shipping state directory and Keychain service has to be refused
    /// rather than performed.
    ///
    /// The hazard is a consequence of `resolvedBundleIdentifier` doing
    /// its job. Under the runner `Bundle.main` is not ours, so both form
    /// factors take their fallbacks, and the fallbacks are the shipped
    /// identifiers: a test that constructs a model without seams gets
    /// the installed app's `state.sealed`, its `ledger.sealed`, and its
    /// Keychain items, and any route that erases a file by path erases
    /// the user's. That is not hypothetical. A suite added for issue #48
    /// cleared the ledger as one of its steps and took the installed
    /// backdrop's audit record with it.
    ///
    /// Two signals, because neither alone covers both ways a suite
    /// starts. `XCTestConfigurationFilePath` is what Xcode sets and is
    /// the usual published check, but SwiftPM's own runner does not set
    /// it: verified on this machine, where a `swift test` process shows
    /// no such variable and reports `com.apple.dt.xctest.tool` as its
    /// bundle identifier. So the identifier prefix is the signal that
    /// actually fires for `swift test`, and the variable is kept beside
    /// it for the Xcode-hosted case, where the runner may wear a host
    /// app's identity instead.
    ///
    /// Pure, and taking both signals as arguments, because the refusal
    /// itself is a `preconditionFailure`: a test cannot drive the real
    /// thing without ending the process that runs it, so the decision
    /// is what gets pinned (`FormFactorTests`).
    static func refusesProductionStateUnderTests(
        environment: [String: String],
        bundleIdentifier: String?,
        seamsInjected: Bool
    ) -> Bool {
        if seamsInjected { return false }
        if bundleIdentifier?.hasPrefix(testRunnerBundlePrefix) == true { return true }
        return environment["XCTestConfigurationFilePath"] != nil
    }

    /// The same decision about the running process. Short-circuits on
    /// the identifier so a shipping launch, whose identifier is its own
    /// and whose seams are absent by design, never builds the
    /// environment dictionary at all; and it is asked once, at a
    /// model's init, so what it costs there is nothing a shipping build
    /// can feel.
    static func refusesProductionStateUnderTests(seamsInjected: Bool) -> Bool {
        if seamsInjected { return false }
        if Bundle.main.bundleIdentifier?.hasPrefix(testRunnerBundlePrefix) == true { return true }
        return refusesProductionStateUnderTests(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            seamsInjected: false
        )
    }

    /// Whether a runner is what is running, on those same two signals
    /// and with no seam in the question.
    ///
    /// The refusal above asks whether a construction may touch the
    /// shipping state. This asks the plainer thing, for the files a
    /// seam is not required to reach: is any of this machine's owner's
    /// own configuration in reach at all. A suite that reads what they
    /// wrote gives a different answer on their machine than on anyone
    /// else's, which is not a suite.
    static var runningUnderTests: Bool {
        refusesProductionStateUnderTests(seamsInjected: false)
    }
}

// MARK: - Where settings rest

extension FormFactor {
    /// The defaults domain for this form factor's own settings.
    ///
    /// `UserDefaults.standard`, deliberately, and for both form factors:
    /// an app's standard domain *is* its bundle identifier's domain, so
    /// two apps with two bundle ids already have two separate stores;
    /// ADR-0010's separation holds without a named suite doing anything.
    ///
    /// A named suite was the earlier approach here, and it was worse
    /// than a no-op: `UserDefaults(suiteName:)` is documented to refuse
    /// the current application's own bundle identifier, and the name
    /// asked for was exactly the backdrop's bundle id. It returned nil
    /// in the installed copy, so every geometry write went nowhere and
    /// the card reset its place and measure at each launch. A bare
    /// `swift run` binary, having no bundle id to collide with, got a
    /// real suite and persisted fine: a bug that only shows in the
    /// build people actually run.
    public static var settingsDefaults: UserDefaults { .standard }
}

// MARK: - Where the user's own keymap rests

extension FormFactor {
    /// The directory a person may leave configuration in, named for the
    /// running build's bundle id.
    ///
    /// Beside the state directory rather than inside it, and the two
    /// properties that make the state directory right for ciphertext
    /// are exactly what make it wrong for this. That directory carries
    /// a `.noindex` suffix so Spotlight never reads the sealed
    /// generations, and it is excluded from backup so a snapshot cannot
    /// hold a copy the app believes it replaced. A keymap is the
    /// opposite kind of file in both respects: the user wrote it, they
    /// should be able to find it by searching for it, and losing it in
    /// a restore would be a small betrayal for no gain. Nothing here is
    /// sealed and nothing here is secret.
    ///
    /// The app never creates this directory. Configuration is optional,
    /// absence is the ordinary case, and an empty folder appearing in
    /// Application Support for a feature nobody used is noise.
    public var configurationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(credentialService, isDirectory: true)
    }

    /// The user's keymap, laid over the bundled default when it exists
    /// (`Keymap.load(userOverride:)`). Named as Zed names its own, so a
    /// file copied from there arrives under the name it left with.
    public var userKeymapFileURL: URL {
        Self.userKeymapFileURL(in: configurationDirectory)
    }

    /// The keymap's place inside any configuration directory, stated
    /// once so a test's injected directory and the shipping one cannot
    /// spell it differently.
    public static func userKeymapFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("keymap.json")
    }
}

// MARK: - Which build am I on

/// The tray menu's version line, shared by both form factors: "which
/// build am I on" answered at a glance.
public enum BuildVersion {
    /// A bare `swift run` has no bundle version, so the core speaks for
    /// itself; a bundled build shows the stamped version (the build
    /// scripts append the git SHA), and a bundle whose version does not
    /// extend the core's own reveals a stale xcframework instead of
    /// hiding it.
    public static func trayTitle(core: String, bundleVersion: String?) -> String {
        guard let bundleVersion else { return "core \(core)" }
        if bundleVersion.hasPrefix(core) {
            return "build \(bundleVersion)"
        }
        return "build \(bundleVersion), core \(core)"
    }
}
