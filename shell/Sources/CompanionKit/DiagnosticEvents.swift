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
    public let startedAt = Date()
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 100) { self.capacity = max(1, min(capacity, 100)) }

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

    public func recordCoreDiagnostic(_ line: String, isFault: Bool) {
        let kind: Kind?
        if line.hasPrefix("companion-credentials: the data protection keychain refused service ") {
            kind = .keychainLoginFallback
        } else if line.hasPrefix("companion-ffi: the state-key item ") {
            kind = .stateKeyRefused
        } else if line.hasPrefix("companion-ffi: the ledger-key item ") {
            kind = .ledgerKeyRefused
        } else if line.hasPrefix("companion-ffi: the state file ") {
            kind = .stateRestoreRefused
        } else {
            kind = isFault ? .coreFault : nil
        }
        if let kind { record(kind) }
    }
}
