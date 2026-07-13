import Foundation
import CompanionCore

/// A non-secret snapshot of a cell, decoded from the core's JSON (see
/// crates/ffi/include/companion_ffi.h for the field contract). There is
/// deliberately no secret field — the UI is never handed plaintext; the
/// recognition line arrives masked exactly as the core renders it.
struct CellSummary: Identifiable, Codable, Hashable {
    let id: UInt64
    let kind: String
    let state: String
    let concealed: Bool
    let detectedAs: String?
    let ttlCode: Int32
    let ttlLabel: String
    let remainingMs: UInt64
    let remainingLabel: String
    let spokenRemaining: String
    let recognition: String
    let displaySize: UInt64
    let promoted: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, state, concealed, recognition, promoted
        case detectedAs = "detected_as"
        case ttlCode = "ttl_code"
        case ttlLabel = "ttl_label"
        case remainingMs = "remaining_ms"
        case remainingLabel = "remaining_label"
        case spokenRemaining = "spoken_remaining"
        case displaySize = "display_size"
    }
}

/// The TTL ladder (docs/spec/04). Raw values are the C ABI rung codes.
enum Rung: Int32, CaseIterable {
    case oneHour = 0, threeHours, eightHours, twentyFourHours, threeDays, sevenDays

    /// Total lifetime of this rung, for drawing the draining ring.
    var seconds: Double {
        switch self {
        case .oneHour: return 3600
        case .threeHours: return 3 * 3600
        case .eightHours: return 8 * 3600
        case .twentyFourHours: return 24 * 3600
        case .threeDays: return 3 * 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        }
    }
}

/// A thin, memory-safe Swift wrapper over the C ABI. Owns the opaque
/// handle for its lifetime and only ever sees ids, non-secret summaries,
/// and booleans. Both pasteboard directions run inside the core.
final class CompanionClient {
    private let handle: OpaquePointer

    init() {
        companion_init()
        guard let created = companion_new() else {
            fatalError("companion_new returned null")
        }
        handle = created
    }

    deinit {
        companion_free(handle)
    }

    /// Stage the pasteboard's content; returns the new cell id, or 0 when
    /// there was nothing to stage or the store refused at capacity.
    @discardableResult
    func ingestPasteboard() -> UInt64 {
        companion_ingest_pasteboard(handle)
    }

    /// Copy a cell back out. The core writes the pasteboard itself; this
    /// process never holds the bytes.
    @discardableResult
    func copyOut(id: UInt64) -> Bool {
        companion_cell_copy_out(handle, id)
    }

    /// Change-count-guarded clear of our own last copy-out.
    @discardableResult
    func clearClipboardIfOurs() -> Bool {
        companion_clear_clipboard_if_ours(handle)
    }

    /// Current cells, newest first.
    func list() -> [CellSummary] {
        guard let ptr = companion_list_json(handle) else { return [] }
        defer { companion_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CellSummary].self, from: data)) ?? []
    }

    /// Milliseconds until the earliest deadline — the ONE timer to arm.
    /// -1 means nothing to schedule.
    func nextDeadlineMs() -> Int64 {
        companion_next_deadline_ms(handle)
    }

    /// Expire overdue cells; returns how many were wiped.
    @discardableResult
    func expireDue() -> UInt64 {
        companion_expire_due(handle)
    }

    /// Step a cell up the ladder (clock reset); returns the new rung.
    @discardableResult
    func cycleTTL(id: UInt64) -> Rung? {
        Rung(rawValue: companion_cell_cycle_ttl(handle, id))
    }

    @discardableResult
    func setTTL(id: UInt64, rung: Rung) -> Bool {
        companion_cell_set_ttl(handle, id, rung.rawValue)
    }

    @discardableResult
    func discard(id: UInt64) -> Bool {
        companion_cell_discard(handle, id)
    }

    /// DEV SCAFFOLDING (deleted with the NSPasteboard adapter): seed the
    /// in-process pasteboard stand-in so the spike can stage a live cell.
    @discardableResult
    func devSeedPasteboard(_ text: String) -> Bool {
        text.withCString { companion_dev_seed_pasteboard(handle, $0) }
    }

    /// The core's version string.
    static var version: String {
        String(cString: companion_version())
    }
}
