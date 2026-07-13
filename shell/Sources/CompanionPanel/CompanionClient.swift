import Foundation
import CompanionCore

/// A non-secret snapshot of a sheet — a page of ink and sealed chips —
/// decoded from the core's JSON (see crates/ffi/include/companion_ffi.h
/// for the field contract). There is deliberately no content field of
/// any kind: sealed bytes have no display form at all (the boundary
/// law, hard form), and the live ink belongs to the shell's editor, not
/// the summary.
struct SheetSummary: Identifiable, Codable, Hashable {
    let id: UInt64
    let title: String
    let rungCode: Int32
    let rungLabel: String
    let remainingMs: UInt64
    let remainingLabel: String
    let spokenRemaining: String
    let fractionRemaining: Double
    let paused: Bool
    let holdRemainingMs: UInt64
    let chipCount: UInt64
    let lastHour: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, paused
        case rungCode = "rung_code"
        case rungLabel = "rung_label"
        case remainingMs = "remaining_ms"
        case remainingLabel = "remaining_label"
        case spokenRemaining = "spoken_remaining"
        case fractionRemaining = "fraction_remaining"
        case holdRemainingMs = "hold_remaining_ms"
        case chipCount = "chip_count"
        case lastHour = "last_hour"
    }
}

/// A freshly sealed chip's non-secret face, returned by the seal
/// routes: the mechanical excerpt and counts are the only rendering the
/// content ever gets — never revealable, at any privilege.
struct ChipInfo: Codable, Hashable {
    let chipId: UInt64
    let kind: String
    let excerpt: String
    let sizeLabel: String
    let promoted: Bool

    enum CodingKeys: String, CodingKey {
        case kind, excerpt, promoted
        case chipId = "chip_id"
        case sizeLabel = "size_label"
    }
}

/// One run of a dead page in the ledger: dimmed ink, or the tombstone
/// of a chip (its excerpt; the bytes were zeroized at death).
enum LedgerRun: Hashable {
    case ink(String)
    case tombstone(String)
}

/// A dead page, resting in the ledger (⌘0): session-bound, read-only.
struct LedgerEntry: Codable, Hashable {
    let cause: String
    let title: String
    let ageMs: UInt64
    private let segments: [[String: SegmentValue]]

    enum CodingKeys: String, CodingKey {
        case cause, title, segments
        case ageMs = "age_ms"
    }

    /// The wire carries `{"ink": "…"}` or `{"tombstone": "…"}` objects
    /// — one key, string value either way (companion_ffi.h).
    enum SegmentValue: Codable, Hashable {
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = .string(try container.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if case .string(let value) = self { try container.encode(value) }
        }
    }

    /// The page's runs, in document order.
    var runs: [LedgerRun] {
        segments.compactMap { object in
            if case .string(let text)? = object["ink"] { return .ink(text) }
            if case .string(let excerpt)? = object["tombstone"] { return .tombstone(excerpt) }
            return nil
        }
    }
}

/// The TTL ladder (docs/spec/04). Raw values are the C ABI rung codes.
enum Rung: Int32, CaseIterable {
    case oneHour = 0, threeHours, eightHours, twentyFourHours, threeDays, sevenDays
}

/// A thin, memory-safe Swift wrapper over the C ABI. Owns the opaque
/// handle for its lifetime and only ever sees ids, non-secret summaries,
/// excerpts, and booleans. Sealed-byte movement runs inside the core.
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

    // MARK: Sheets

    /// A new page at the end of the tab strip; 0 means the store
    /// refused at the cap of 9 (refuse-don't-evict — say so).
    @discardableResult
    func newSheet() -> UInt64 {
        companion_sheet_new(handle)
    }

    /// Close a page; it rests in the ledger, sealed bytes zeroized.
    @discardableResult
    func closeSheet(id: UInt64) -> Bool {
        companion_sheet_close(handle, id)
    }

    /// Move a page in the visible order (drag-to-reorder).
    @discardableResult
    func moveSheet(id: UInt64, to index: UInt64) -> Bool {
        companion_sheet_move(handle, id, index)
    }

    /// Current pages, in visible (tab) order.
    func sheets() -> [SheetSummary] {
        decodeJSON([SheetSummary].self, from: companion_sheets_json(handle)) ?? []
    }

    // MARK: Sealing — the gesture routes

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself.
    /// Returns the new chip's face, or nil.
    @discardableResult
    func sealFromPasteboard(sheet: UInt64) -> ChipInfo? {
        decodeJSON(ChipInfo.self, from: companion_sheet_seal_from_pasteboard(handle, sheet))
    }

    /// The ⌘↩ retrofit: seal editor text the user selected. The one
    /// deliberate plaintext-in call — the text was visible ink already;
    /// after this returns, the caller deletes its copy from the view.
    @discardableResult
    func sealText(sheet: UInt64, _ text: String) -> ChipInfo? {
        // A C string truncates at an interior NUL; sealing a silently
        // truncated secret and telling the editor to delete the whole
        // thing would lose the remainder. Refuse instead — the editor
        // keeps its copy and nothing was sealed.
        guard !text.contains("\0") else { return nil }
        return text.withCString { cText in
            decodeJSON(ChipInfo.self, from: companion_sheet_seal_text(handle, sheet, cText))
        }
    }

    /// Push the page's document snapshot (JSON runs) to the core —
    /// authoritative for chip liveness.
    @discardableResult
    func syncDocument(sheet: UInt64, json: String) -> Bool {
        json.withCString { companion_sheet_sync_document(handle, sheet, $0) }
    }

    // MARK: Chips

    /// Copy a chip back out. The core writes the pasteboard itself,
    /// marked transient + concealed; this process never holds the bytes.
    @discardableResult
    func copyOutChip(id: UInt64) -> Bool {
        companion_chip_copy_out(handle, id)
    }

    /// ⌫ on a chip: removes it whole, bytes zeroized, no resurrection.
    @discardableResult
    func deleteChip(id: UInt64) -> Bool {
        companion_chip_delete(handle, id)
    }

    /// Change-count-guarded clear of our own last copy-out.
    @discardableResult
    func clearClipboardIfOurs() -> Bool {
        companion_clear_clipboard_if_ours(handle)
    }

    // MARK: Time

    /// Milliseconds until the next scheduled instant — page expiry or
    /// hold lapse — the ONE timer to arm. -1 means nothing to schedule.
    func nextEventMs() -> Int64 {
        companion_next_event_ms(handle)
    }

    /// Settle the clock: normalize lapsed holds, expire due pages;
    /// returns how many pages expired.
    @discardableResult
    func expireDue() -> UInt64 {
        companion_expire_due(handle)
    }

    /// Click the countdown label: next rung, clock reset.
    @discardableResult
    func cycleRung(sheet: UInt64) -> Rung? {
        Rung(rawValue: companion_sheet_cycle_rung(handle, sheet))
    }

    @discardableResult
    func setRung(sheet: UInt64, rung: Rung) -> Bool {
        companion_sheet_set_rung(handle, sheet, rung.rawValue)
    }

    /// Double-click the tab: hold 1h, then top-up to 24h from now.
    @discardableResult
    func pausePress(sheet: UInt64) -> Bool {
        companion_sheet_pause_press(handle, sheet)
    }

    // MARK: The ledger

    /// Dead pages, newest first (⌘0) — dimmed ink and tombstones.
    func ledger() -> [LedgerEntry] {
        decodeJSON([LedgerEntry].self, from: companion_ledger_json(handle)) ?? []
    }

    // MARK: Dev scaffolding

    /// DEV SCAFFOLDING: seed the pasteboard as an external app would,
    /// so demo affordances have something to seal. Only present in
    /// `--dev-scaffolding` builds of the core.
    @discardableResult
    func devSeedPasteboard(_ text: String) -> Bool {
        text.withCString { companion_dev_seed_pasteboard(handle, $0) }
    }

    /// The core's version string.
    static var version: String {
        String(cString: companion_version())
    }

    // MARK: Plumbing

    /// Decode an owned JSON C string from the seam, freeing it either way.
    private func decodeJSON<T: Decodable>(_ type: T.Type, from ptr: UnsafeMutablePointer<CChar>?) -> T? {
        guard let ptr else { return nil }
        defer { companion_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
