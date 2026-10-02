import Foundation

/// A bounded, process-local trail. Only typed labels and numeric status codes
/// are retained; backend diagnostic strings are classified and discarded.
public final class DiagnosticEvents: @unchecked Sendable {
    public enum Kind: String, Sendable {
        case keychainLoginFallback = "Keychain: login fallback announced"
        case stateKeyRefused = "Keychain: saved-pages key refused"
        case ledgerKeyRefused = "Keychain: history key refused"
        case stateRestoreRefused = "Saved pages: restore diagnostic"
        case coreFault = "Core: operation refused (details omitted)"
        case shortcutRegistered = "Shortcut: registered"
        case shortcutFailed = "Shortcut: registration failed"
        case panelRaised = "Ambient panel: raised"
        case panelRested = "Ambient panel: resting"
        case panelEnabled = "Ambient panel: enabled"
        case panelDisabled = "Ambient panel: disabled"
    }

    public struct Entry: Sendable {
        public let date: Date
        public let kind: Kind
        public let status: Int?
    }

    public static let shared = DiagnosticEvents()
    /// When this process began, as the kernel recorded it, so the
    /// report's uptime counts from launch and not from whichever moment
    /// first happened to touch `shared`.
    public let startedAt = DiagnosticEvents.processStartDate()
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    /// A trail of at most `capacity` entries, oldest dropped first. The
    /// capacity is clamped to 1...100 whatever is asked for, because the
    /// report introduces the trail as "up to 100" events and a larger
    /// trail would make that sentence false.
    public init(capacity: Int = 100) { self.capacity = max(1, min(capacity, 100)) }

    /// The process start time from `kinfo_proc`, or the present moment
    /// when the kernel will not answer: a shorter uptime is the honest
    /// failure, a guessed one is not.
    private static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride else { return Date() }
        // `p_starttime` is a C macro over this union member, and Swift
        // imports the member but not the macro.
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    public func record(_ kind: Kind, status: Int? = nil, date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(date: date, kind: kind, status: status))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// The core lines that earn a label of their own, matched by prefix
    /// and tried in order. The wording belongs to the Rust crates, so
    /// `CoreDiagnosticPrefixTests` reads each prefix back out of their
    /// sources: a reworded message fails that test rather than falling
    /// quietly into `.coreFault`, or out of the trail altogether.
    static let corePrefixes: [(prefix: String, kind: Kind)] = [
        ("companion-credentials: the data protection keychain refused service ", .keychainLoginFallback),
        ("companion-ffi: the state-key item ", .stateKeyRefused),
        ("companion-ffi: the ledger-key item ", .ledgerKeyRefused),
        ("companion-ffi: the state file ", .stateRestoreRefused),
    ]

    public func recordCoreDiagnostic(_ line: String, isFault: Bool) {
        let kind: Kind? = Self.corePrefixes.first { line.hasPrefix($0.prefix) }?.kind
            ?? (isFault ? .coreFault : nil)
        if let kind { record(kind) }
    }
}
