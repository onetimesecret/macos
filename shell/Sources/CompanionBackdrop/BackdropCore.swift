import CompanionKit
import Foundation

/// The backdrop's policy over the shared seam. The wrapper itself now
/// lives in CompanionKit, one copy for both form factors (ADR-0010's
/// extraction, triggered by this target graduating out of exploration);
/// what stays here is only what the backdrop decides differently from
/// the panel, which is the opening rung and the shape of its document.
///
/// The boundary law holds as it always did: the only content in Swift
/// is visible ink the user typed into this surface. The kit carries no
/// sealed byte across the seam either.
final class BackdropCore {
    /// The backdrop's own Keychain scope, never the panel's (ADR-0010
    /// keeps the form factors out of each other's storage). The state
    /// key this names is created by, and granted to, this app alone.
    static let credentialService = "com.onetimesecret.companion.backdrop"

    private let client = CompanionClient(credentialService: BackdropCore.credentialService)

    /// The rung a fresh backdrop page opens on. The backdrop favours a
    /// week, a span you can reason about by the calendar ("still need
    /// this next Friday?") rather than by counting work hours, where the
    /// panel opens shorter.
    private static let defaultRung: Rung = .sevenDays

    /// A new page, opened on the backdrop's default rung; 0 means the
    /// store refused at the cap (the backdrop only ever holds one page,
    /// so this is unreachable in practice).
    @discardableResult
    func newSheet() -> UInt64 {
        let id = client.newSheet()
        if id != 0 {
            _ = client.setRung(sheet: id, rung: Self.defaultRung)
        }
        return id
    }

    /// Current pages, of which the backdrop uses only the first. The
    /// summary carries more fields than this surface renders (chips, the
    /// hold clock); asking for the shared type and ignoring the rest
    /// costs a decode, where a second narrower type would cost a second
    /// copy of the wire contract to keep in step.
    func sheets() -> [SheetSummary] {
        client.sheets()
    }

    /// Mirror the surface's ink to the core, which is authoritative for
    /// the page's title and lifecycle. `json` comes from `inkRunsJSON`.
    @discardableResult
    func syncDocument(sheet: UInt64, json: String) -> Bool {
        client.syncDocument(sheet: sheet, json: json)
    }

    /// Click the countdown label: next rung, clock reset.
    @discardableResult
    func cycleRung(sheet: UInt64) -> Rung? {
        client.cycleRung(sheet: sheet)
    }

    /// Milliseconds until the next scheduled instant; -1 means nothing
    /// to schedule. Expiry is scheduled, never polled (docs/spec/03 §4).
    func nextEventMs() -> Int64 {
        client.nextEventMs()
    }

    /// Settle the clock: expire what is due. Returns how many pages died.
    @discardableResult
    func expireDue() -> UInt64 {
        client.expireDue()
    }

    /// Seal the store into `path`. Ciphertext only; the key rests in
    /// the Keychain under this app's own service.
    @discardableResult
    func persistSave(to path: String) -> Bool {
        client.persistSave(to: path)
    }

    /// Open a sealed file back into the store. False covers both a
    /// fresh start (no file) and a refusal (missing key, failed
    /// authentication); the caller tells them apart by whether the file
    /// was there.
    @discardableResult
    func persistRestore(from path: String) -> Bool {
        client.persistRestore(from: path)
    }

    /// The restored page's ink, for the editor to open onto. The
    /// backdrop's document is ink and nothing else, so the runs join
    /// back into the one string the surface edits; a chip run cannot
    /// occur here, and is dropped rather than rendered, because this
    /// surface has no way to show one.
    func documentInk(sheet: UInt64) -> String {
        client.documentRuns(sheet: sheet)
            .compactMap { if case .ink(let text) = $0 { text } else { nil } }
            .joined()
    }

    /// The core's version string.
    static var version: String {
        CompanionClient.version
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
}
