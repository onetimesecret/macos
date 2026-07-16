import CompanionCore
import Foundation

/// The one sheet's non-secret face, decoded from the core's JSON (see
/// crates/ffi/include/companion_ffi.h). A deliberate subset of the
/// panel's `SheetSummary` — the backdrop shows one page and no chips,
/// so it asks for no more than it renders.
struct BackdropSheetSummary: Decodable, Equatable {
    let id: UInt64
    let title: String
    let rungLabel: String
    let remainingLabel: String
    let spokenRemaining: String
    let fractionRemaining: Double
    let paused: Bool
    let lastHour: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, paused
        case rungLabel = "rung_label"
        case remainingLabel = "remaining_label"
        case spokenRemaining = "spoken_remaining"
        case fractionRemaining = "fraction_remaining"
        case lastHour = "last_hour"
    }
}

/// A thin wrapper over the C-ABI seam, scoped to what the backdrop
/// exploration needs: one ink-only sheet, its clock, and nothing else.
///
/// This deliberately duplicates a sliver of the panel's
/// `CompanionClient` rather than extracting a shared library while the
/// panel is alpha (ADR-0010): the exploration must not restructure the
/// code it exists to leave undisturbed. The boundary law holds
/// trivially here — the backdrop never seals, so no sealed byte exists
/// on either side of the seam; the only content in Swift is visible
/// ink the user typed into this surface.
final class BackdropCore {
    private let handle: OpaquePointer

    init() {
        companion_init()
        guard let created = companion_new() else {
            fatalError("companion_new returned null")
        }
        handle = created
    }

    deinit {
        // Dropping the store zeroizes core-side. The backdrop keeps no
        // state file and touches no Keychain: quit is total amnesia.
        companion_free(handle)
    }

    /// A new page; 0 means the store refused at the cap (the backdrop
    /// only ever holds one page, so this is unreachable in practice).
    @discardableResult
    func newSheet() -> UInt64 {
        companion_sheet_new(handle)
    }

    /// Current pages — the backdrop uses only the first.
    func sheets() -> [BackdropSheetSummary] {
        decodeJSON([BackdropSheetSummary].self, from: companion_sheets_json(handle)) ?? []
    }

    /// Mirror the surface's ink to the core, which is authoritative for
    /// the page's title and lifecycle. `json` comes from `inkRunsJSON`.
    @discardableResult
    func syncDocument(sheet: UInt64, json: String) -> Bool {
        json.withCString { companion_sheet_sync_document(handle, sheet, $0) }
    }

    /// Click the countdown label: next rung, clock reset.
    @discardableResult
    func cycleRung(sheet: UInt64) -> Int32 {
        companion_sheet_cycle_rung(handle, sheet)
    }

    /// Milliseconds until the next scheduled instant; -1 means nothing
    /// to schedule. Expiry is scheduled, never polled (docs/spec/03 §4).
    func nextEventMs() -> Int64 {
        companion_next_event_ms(handle)
    }

    /// Settle the clock: expire what is due. Returns how many pages died.
    @discardableResult
    func expireDue() -> UInt64 {
        companion_expire_due(handle)
    }

    /// The core's version string.
    static var version: String {
        String(cString: companion_version())
    }

    /// The document-snapshot JSON for a page holding nothing but `text`
    /// as visible ink — the backdrop's whole document model. Empty text
    /// is an empty document; nil means the encoder refused (it will
    /// not, for a string) and the caller must skip the sync rather than
    /// mirror a wrongly emptied page.
    static func inkRunsJSON(_ text: String) -> String? {
        guard !text.isEmpty else { return "[]" }
        guard let data = try? JSONSerialization.data(withJSONObject: [["ink": text]]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Decode an owned JSON C string from the seam, freeing it either way.
    private func decodeJSON<T: Decodable>(
        _ type: T.Type, from ptr: UnsafeMutablePointer<CChar>?
    ) -> T? {
        guard let ptr else { return nil }
        defer { companion_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
