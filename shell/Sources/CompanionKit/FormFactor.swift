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
/// here — where the Keychain items live, where the sealed file rests,
/// which defaults domain holds the settings, which rung a fresh page
/// opens on — so the difference is data the shared model reads rather
/// than a second copy of the model.
public struct FormFactor: Sendable {
    /// The name in the About panel, the alerts, and the tray item.
    public let displayName: String

    /// Scopes this form factor's Keychain items. Nil takes the core's
    /// default (`com.onetimesecret.companion`, the panel's). Keychain
    /// ACLs are granted to the code identity that created an item, so
    /// two signed binaries sharing one state key would each meet a
    /// confirmation prompt for the other's.
    public let credentialService: String?

    /// The directory under Application Support holding the sealed state
    /// file. Two form factors, two stores — neither reads the other's.
    public let stateDirectory: String

    /// The unified-log subsystem for this form factor's trails.
    public let loggerSubsystem: String

    /// The rung a fresh page opens on, or nil for the core's own
    /// default. The backdrop favours a week, a span you can reason
    /// about by the calendar ("still need this next Friday?"), where
    /// the panel opens shorter.
    public let defaultRung: Rung?

    public init(
        displayName: String,
        credentialService: String?,
        stateDirectory: String,
        loggerSubsystem: String,
        defaultRung: Rung?
    ) {
        self.displayName = displayName
        self.credentialService = credentialService
        self.stateDirectory = stateDirectory
        self.loggerSubsystem = loggerSubsystem
        self.defaultRung = defaultRung
    }

    /// Where the sealed store rests between runs. Ciphertext only — the
    /// key lives in the Keychain, so the file alone says nothing.
    public var stateFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(stateDirectory, isDirectory: true)
            .appendingPathComponent("state.sealed")
    }

    /// The summoned panel (docs/spec/04): accessory posture, the core's
    /// default Keychain service, the core's default opening rung.
    public static let panel = FormFactor(
        displayName: "CompanionApp",
        credentialService: nil,
        stateDirectory: "CompanionApp",
        loggerSubsystem: "com.onetimesecret.companion",
        defaultRung: nil
    )

    /// The background surface (docs/spec/feature/background-surface):
    /// its own Keychain service and its own state file, reached through
    /// `companion_new_scoped`.
    public static let backdrop = FormFactor(
        displayName: "CompanionBackdrop",
        credentialService: "com.onetimesecret.companion.backdrop",
        stateDirectory: "CompanionBackdrop",
        loggerSubsystem: "com.onetimesecret.companion.backdrop",
        defaultRung: .sevenDays
    )
}

// MARK: - Where settings rest

extension FormFactor {
    /// The defaults domain for this form factor's own settings.
    ///
    /// `UserDefaults.standard`, deliberately, and for both form factors:
    /// an app's standard domain *is* its bundle identifier's domain, so
    /// two apps with two bundle ids already have two separate stores —
    /// ADR-0010's separation holds without a named suite doing anything.
    ///
    /// A named suite was the earlier approach here, and it was worse
    /// than a no-op: `UserDefaults(suiteName:)` is documented to refuse
    /// the current application's own bundle identifier, and the name
    /// asked for was exactly the backdrop's bundle id. It returned nil
    /// in the installed copy — every geometry write went nowhere and
    /// the card reset its place and measure at each launch — while a
    /// bare `swift run` binary, having no bundle id to collide with,
    /// got a real suite and persisted fine. A bug that only shows in
    /// the build people actually run.
    public static var settingsDefaults: UserDefaults { .standard }
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
