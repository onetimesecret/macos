import Foundation
import os
import CompanionCore

/// The core's own diagnostics, given somewhere to land.
///
/// The core writes a line whenever a persistence step refuses: a key
/// half that would not load, a sealed file that would not authenticate,
/// a snapshot it would not take back, a key rotation the keychain
/// refused. All four produce one visible symptom, an app that has
/// stopped remembering, and telling them apart from the outside means
/// reading ciphertext.
///
/// Those lines went to stderr, and an app launched by double-click or
/// at login has no stderr: `launchd` gives the process `/dev/null`. The
/// only way to read them was to run the binary from a terminal, which
/// is the one launch that reproduces least, since it carries a
/// different keychain posture and a different environment from the
/// launch that actually failed. So the destination moves here, beside
/// the shell's own persistence trail, and `log show` reaches both after
/// the fact:
///
/// ```bash
/// log show --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}' --last 1h --style compact
/// ```
///
/// What crosses is metadata: which step refused and the backend's own
/// error text. Never ink, never a chip, never key material. These
/// records are `public` on purpose (`privacy: .public`): a log line
/// redacted to `<private>` in the field is a log line nobody can act
/// on, and there is nothing here to redact.
public enum CoreDiagnostics {
    /// Where a routed line goes. Written once, before the core is
    /// handed the sink below, and read from whatever thread the core
    /// emits on: the core cannot emit into a sink it has not been given
    /// yet, so the write happens-before every read. `Logger` is itself
    /// thread-safe.
    private nonisolated(unsafe) static var logger = Logger(
        subsystem: FormFactor.backdropBundleIdentifier, category: "core"
    )

    /// Whether the sink is already registered. Main-actor isolated, so
    /// the check and the registration cannot interleave.
    @MainActor private static var routed = false

    /// Send the core's diagnostics to this form factor's subsystem,
    /// under the `core` category.
    ///
    /// Call early, before the first restore: a sink registered after a
    /// refusal misses the refusal. Calling again is a no-op rather than
    /// a second registration, because the destination is process-wide
    /// while the model that asks for it need not be.
    @MainActor
    public static func route(subsystem: String) {
        guard !routed else { return }
        routed = true
        logger = Logger(subsystem: subsystem, category: "core")
        companion_set_diagnostic_sink(sink)
    }

    /// The C function the core calls. Captures nothing, by ABI: it may
    /// arrive on any thread, and the message it borrows is valid only
    /// for the duration of the call.
    private static let sink: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = {
        level, message in
        guard let message else { return }
        let line = String(cString: message)

        // The unified log first, which is the point of the routing, and
        // then stderr when there is a terminal reading it: a developer
        // running the binary directly should not have to open a second
        // window to watch what they just launched. A launched app fails
        // the check and pays nothing.
        if level == COMPANION_DIAG_FAULT {
            logger.error("\(line, privacy: .public)")
        } else {
            logger.notice("\(line, privacy: .public)")
        }
        if isatty(STDERR_FILENO) != 0 {
            fputs(line + "\n", stderr)
        }
    }
}
