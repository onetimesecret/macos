import Foundation
import OtsCore

/// A non-secret snapshot of a cell, decoded from the core's JSON. Mirrors
/// `ots_core::cell::CellSummary`. There is deliberately no secret field — the
/// UI is never handed plaintext (docs/01 §3).
struct CellSummary: Identifiable, Codable, Hashable {
    let id: UInt64
    let kind: String
    let rung: String
    let rungLabel: String
    let remainingMs: UInt64
    let remainingLabel: String
    let byteLen: UInt64
    let preview: String

    enum CodingKeys: String, CodingKey {
        case id, kind, rung, preview
        case rungLabel = "rung_label"
        case remainingMs = "remaining_ms"
        case remainingLabel = "remaining_label"
        case byteLen = "byte_len"
    }
}

/// The TTL ladder, mirroring `ots_core::cell::TtlRung`. Raw values are the C ABI
/// rung codes.
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

    /// Decode from the summary's snake_case rung string.
    init?(apiString: String) {
        switch apiString {
        case "one_hour": self = .oneHour
        case "three_hours": self = .threeHours
        case "eight_hours": self = .eightHours
        case "twenty_four_hours": self = .twentyFourHours
        case "three_days": self = .threeDays
        case "seven_days": self = .sevenDays
        default: return nil
        }
    }
}

/// The outputs of a successful conceal — never the secret itself.
struct ShareLink: Codable {
    let shareURL: String
    let metadataURL: String
    let secretKey: String
    let metadataKey: String
    let ttlSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case shareURL = "share_url"
        case metadataURL = "metadata_url"
        case secretKey = "secret_key"
        case metadataKey = "metadata_key"
        case ttlSecs = "ttl_secs"
    }
}

struct ConcealFailure: Error {
    let code: Int
    let message: String
}

/// A thin, memory-safe Swift wrapper over the C ABI. Owns the opaque cache
/// handle for its lifetime and only ever sees ids, non-secret summaries, and
/// action outputs.
final class OtsCoreClient {
    private let handle: OpaquePointer

    init() {
        otsc_init()
        guard let created = otsc_cache_new() else {
            fatalError("otsc_cache_new returned null")
        }
        handle = created
    }

    deinit {
        otsc_cache_free(handle)
    }

    /// Configure the optional share bridge. Both values are non-secret; the API
    /// token lives in the Keychain, keyed by `extid`.
    func configureAPI(baseURL: String, extid: String) {
        _ = otsc_cache_set_api(handle, baseURL, extid)
    }

    /// Take whatever is on the pasteboard into a new cell; returns its id, or 0
    /// if there was nothing to ingest.
    @discardableResult
    func ingestPasteboard() -> UInt64 {
        otsc_ingest_pasteboard(handle)
    }

    /// Current cells, newest first.
    func list() -> [CellSummary] {
        guard let ptr = otsc_list_json(handle) else { return [] }
        defer { otsc_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CellSummary].self, from: data)) ?? []
    }

    @discardableResult
    func resetTTL(id: UInt64, rung: Rung) -> Bool {
        otsc_cell_reset_ttl(handle, id, rung.rawValue)
    }

    /// Step a cell up the ladder; returns the new rung.
    @discardableResult
    func cycleTTL(id: UInt64) -> Rung? {
        Rung(rawValue: otsc_cell_cycle_ttl(handle, id))
    }

    @discardableResult
    func evict(id: UInt64) -> Bool {
        otsc_cell_evict(handle, id)
    }

    /// Promote a text cell to a one-time link. Blocks on network I/O — call off
    /// the main thread.
    func conceal(id: UInt64, ttlSecs: UInt64) -> Result<ShareLink, ConcealFailure> {
        guard let ptr = otsc_cell_conceal_json(handle, id, ttlSecs) else {
            return .failure(ConcealFailure(code: -99, message: "null response"))
        }
        defer { otsc_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = obj["ok"] as? Bool
        else {
            return .failure(ConcealFailure(code: -98, message: "unparseable response"))
        }
        if ok, let link = try? JSONDecoder().decode(ShareLink.self, from: data) {
            return .success(link)
        }
        let code = (obj["code"] as? Int) ?? -1
        let message = (obj["message"] as? String) ?? "conceal failed"
        return .failure(ConcealFailure(code: code, message: message))
    }

    /// The core's version string.
    static var version: String {
        String(cString: otsc_version())
    }
}
