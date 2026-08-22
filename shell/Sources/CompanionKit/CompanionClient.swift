import Foundation
import CompanionCore

// The shared seam wrapper, one copy for every form factor. ADR-0010
// carried two copies deliberately while the backdrop was an
// exploration, and named the extraction as the trigger that fires when
// a sibling graduates: the backdrop gaining persistence is that
// graduation. Everything here is a window onto the core, never logic.
// Logic that would need adding twice belongs in the core once.

/// A non-secret snapshot of one tab — a durable slot on the strip,
/// holding at most one perishable page of ink and sealed chips —
/// decoded from the core's JSON (see crates/ffi/include/companion_ffi.h
/// for the field contract). There is deliberately no content field of
/// any kind: sealed bytes have no display form at all (the boundary
/// law, hard form), and the live ink belongs to the shell's editor, not
/// the summary.
///
/// **Two ids, and neither can do the other's job** (ADR-0017). `id` is
/// the tab's: it is what the selection holds, what the keyboard lands
/// on, and what survives every page the slot ever held. `pageID` is the
/// page's: it addresses the content, it is what the storage and undo
/// maps are keyed by, and it is nil the moment the page expires. A slot
/// whose page expired keeps its place on the strip with `hasPage`
/// false, and every clock field below then describes nothing.
public struct TabSummary: Identifiable, Codable, Hashable, Sendable {
    /// The tab's id: the slot, not the page.
    public let id: UInt64
    /// Whether the slot holds a page at all. False after an expiry and
    /// before the next deliberate gesture opens one; the tab draws the
    /// dashed empty treatment rather than a gauge, and every clock
    /// field on this summary is meaningless.
    public let hasPage: Bool
    /// The page's id, or nil when the slot holds none. The only id the
    /// page-addressed routes accept, and the only key a shell-side
    /// document map may use: a map keyed by the slot would hand a new
    /// page the dead one's text storage and undo stack, which is the
    /// resurrection ADR-0009 closed.
    public let pageID: UInt64?
    /// The tab's label, resolved three ways core-side: the name the
    /// user typed; else the live page's derived title, its first
    /// non-empty ink line with markdown markup stripped, capped at 80
    /// characters; else "MMDD-HHmm" from the TAB's creation stamp in
    /// LOCAL time. The middle term is the only derived one and it dies
    /// with the page, so an expiry falls the label back one step rather
    /// than leaving a string the app invented on a durable object.
    public let title: String
    public let rungCode: Int32
    public let rungLabel: String
    public let remainingMs: UInt64
    public let remainingLabel: String
    public let spokenRemaining: String
    public let fractionRemaining: Double
    public let paused: Bool
    /// The hold is already at its 24 hour ceiling, so the next pause
    /// press releases it rather than topping it up. False whenever the
    /// page is not held.
    public let holdToppedUp: Bool
    public let holdRemainingMs: UInt64
    public let chipCount: UInt64
    public let lastHour: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, paused
        case hasPage = "has_page"
        case pageID = "page_id"
        case rungCode = "rung_code"
        case rungLabel = "rung_label"
        case remainingMs = "remaining_ms"
        case remainingLabel = "remaining_label"
        case spokenRemaining = "spoken_remaining"
        case fractionRemaining = "fraction_remaining"
        case holdToppedUp = "hold_topped_up"
        case holdRemainingMs = "hold_remaining_ms"
        case chipCount = "chip_count"
        case lastHour = "last_hour"
    }
}

/// The two emptiness answers, taken together in one call because they
/// are one question asked twice (ADR-0017) and the shell derives
/// neither.
///
/// `holdsNoPage` is ADR-0016 section 6's key rotation trigger: the pad
/// holds no content while the strip stands, which is a security
/// decision and not a rendering convenience. `hasNoTabs` is the one
/// condition under which the sealed file is dropped rather than
/// resealed, because a strip of empty slots still has names, rungs and
/// an order worth keeping. Wiring them backwards destroys the tabs an
/// expiry was supposed to leave standing, or leaves the install on one
/// content key for as long as any tab exists.
public struct StoreEmptiness: Hashable, Sendable {
    public let holdsNoPage: Bool
    public let hasNoTabs: Bool
}

/// A freshly sealed chip's non-secret face, returned by the seal
/// routes: the mechanical excerpt and counts are the only rendering the
/// content ever gets — never revealable, at any privilege.
public struct ChipInfo: Codable, Hashable, Sendable {
    public let chipId: UInt64
    public let kind: String
    public let excerpt: String
    public let sizeLabel: String
    public let promoted: Bool

    enum CodingKeys: String, CodingKey {
        case kind, excerpt, promoted
        case chipId = "chip_id"
        case sizeLabel = "size_label"
    }
}

/// One line of the audit trail (⌘0): what the app did with one item,
/// and when. The ledger outlives the pages it describes, so this type
/// carries a guarantee, not a convention: **no field on it can hold
/// content**.
/// `event`, `size` and `destination` are closed vocabularies, `item` is
/// a random UUID, the two stamps are numbers, and `title` is the one
/// piece of page-owned text on the record, already capped at 80
/// characters core-side. There is no ink field, no excerpt field and no
/// tombstone field, so there is nothing here a renderer could
/// accidentally reveal.
public struct LedgerEntry: Codable, Hashable, Sendable, Identifiable {
    /// created | sealed | sent | expired | discarded
    public let event: String
    /// The item's random UUID, lowercase hyphenated 8-4-4-4-12, 36
    /// characters. Plain, with no digest and no salt: an identifier an
    /// auditor cannot line up across records is not an audit trail.
    public let item: String
    /// The host page's title at the moment of the event, capped at 80
    /// characters core-side. A secret typed into the rename field does
    /// land here; that is a documented exception, and the cap bounds it.
    public let title: String
    /// When it happened, Unix epoch milliseconds.
    public let atMs: UInt64
    /// When the item's page was created, Unix epoch milliseconds.
    public let createdAtMs: UInt64
    /// tiny | small | medium | large | huge: a coarse bucket, never a
    /// byte count.
    public let size: String
    /// none | clipboard | link
    public let destination: String

    /// One item can produce several records, so identity is the item,
    /// the event, and the instant together.
    public var id: String { "\(item)-\(event)-\(atMs)" }

    enum CodingKeys: String, CodingKey {
        case event, item, title, size, destination
        case atMs = "at_ms"
        case createdAtMs = "created_at_ms"
    }
}

/// One run of a live page's document, as the core replays it for an
/// editor rebuilding after a restore: visible ink, or a chip's
/// non-secret face (never its bytes).
public enum RestoredRun: Decodable, Sendable {
    case ink(String)
    case chip(ChipInfo)

    private enum CodingKeys: String, CodingKey {
        case ink, chip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .ink) {
            self = .ink(text)
        } else {
            self = .chip(try container.decode(ChipInfo.self, forKey: .chip))
        }
    }
}

/// A page's provenance, derived core-side from its operation log
/// (ADR-0013). Deliberately nothing beyond the two stamps: origin URLs
/// are content and never cross this seam.
public struct SheetMeta: Codable, Hashable, Sendable {
    /// The page's creation stamp, Unix epoch milliseconds.
    public let createdMs: UInt64
    /// The newest change's commit timestamp, Unix SECONDS; nil for a
    /// page whose body was never touched.
    public let modifiedS: Int64?

    enum CodingKeys: String, CodingKey {
        case createdMs = "created_ms"
        case modifiedS = "modified_s"
    }
}

/// One block of a page, as identity, stamps, and reach (ADR-0013): a
/// random UUID that survives every edit inside the block,
/// created/modified in Unix seconds derived from the operation log, and
/// how many paragraphs the block covers. No text, no sizes, no origin.
public struct BlockInfo: Codable, Hashable, Sendable, Identifiable {
    /// The block's random identity, lowercase hyphenated UUID.
    public let id: String
    /// Earliest change that touched the block, Unix seconds; nil for a
    /// block with no committed content.
    public let createdS: Int64?
    /// Latest change that touched the block, Unix seconds; nil for a
    /// block with no committed content.
    public let modifiedS: Int64?
    /// How many paragraphs this block covers: one for a line the reader
    /// typed, more where a paste kept its lines together. The editor
    /// walks the page by this, so a pasted passage carries one stamp
    /// above its first line rather than one above every line in it.
    public let paragraphs: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdS = "created_s"
        case modifiedS = "modified_s"
        case paragraphs
    }
}

/// The TTL ladder (docs/spec/04). Raw values are the C ABI rung codes.
public enum Rung: Int32, CaseIterable, Sendable {
    case oneHour = 0, threeHours, eightHours, twentyFourHours, threeDays, sevenDays
}

/// Connection state as Settings may render it (companion_ffi.h):
/// configuration only, never the token — that rests in the Keychain,
/// core-side.
public struct ConnectionInfo: Codable, Hashable, Sendable {
    public let configured: Bool
    public let serverUrl: String
    public let shareDomain: String
    public let extid: String
    public let hasToken: Bool

    enum CodingKeys: String, CodingKey {
        case configured, extid
        case serverUrl = "server_url"
        case shareDomain = "share_domain"
        case hasToken = "has_token"
    }
}

/// A promotion (or connection-test) result off the seam: success, or an
/// inline-able error message. Never a link — on success the link is
/// already on the clipboard, written core-side.
public struct PromotionOutcome: Codable, Hashable, Sendable {
    public let ok: Bool
    public let receiptId: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case receiptId = "receipt_id"
    }
}

/// A thin, memory-safe Swift wrapper over the C ABI. Owns the opaque
/// handle for its lifetime and only ever sees ids, non-secret summaries,
/// excerpts, and booleans. Sealed-byte movement runs inside the core.
///
/// `@unchecked Sendable`: the handle is immutable after init and every
/// call is serialized by the core's own mutex (companion_ffi.h) — the
/// promotion routes are *meant* to be called off the main actor, since
/// they block for a network round-trip.
public final class CompanionClient: @unchecked Sendable {
    private let handle: OpaquePointer

    /// `credentialService` scopes this client's Keychain items. Nil
    /// takes the core's default, `com.onetimesecret.companion`, which
    /// is the panel's. A second form factor passes its own bundle id:
    /// Keychain ACLs are granted to the code identity that created an
    /// item, so two signed binaries sharing one state key would each
    /// meet a confirmation prompt for the other's, and a state file
    /// either could open is a state file neither one owns.
    public init(credentialService: String? = nil) {
        companion_init()
        let created =
            if let credentialService {
                credentialService.withCString { companion_new_scoped($0) }
            } else {
                companion_new()
            }
        guard let created else {
            fatalError("the core refused to create a handle")
        }
        handle = created
    }

    /// Adopt a handle another constructor already created. Internal
    /// rather than private for one client: the test target's
    /// `ephemeral(tag:)` extension wraps the core's gated
    /// `companion_new_ephemeral` seam, which lives outside this target
    /// because the symbol exists only in test-util builds of the core
    /// (ADR-0018) and a shipping target must never need it to link.
    init(adopting handle: OpaquePointer) {
        self.handle = handle
    }

    /// The raw handle, for the test target's gated seams alone
    /// (ADR-0018), on the same terms as `init(adopting:)`: internal, so
    /// only a `@testable` import reaches it, and used only where a seam
    /// that exists in no release build has to be called. Nothing in
    /// this module or above it may take a second reference to the
    /// handle: its lifetime is this object's.
    var rawHandleForTests: OpaquePointer { handle }

    deinit {
        companion_free(handle)
    }

    // MARK: Tabs — the durable slots

    /// A new tab at the end of the strip, holding a new page; 0 means
    /// the store refused at the cap of 9 (refuse-don't-evict — say so).
    /// The id is the TAB's: it is what the selection keeps afterwards.
    @discardableResult
    public func newTab() -> UInt64 {
        companion_tab_new(handle)
    }

    /// Mint a page into a tab that holds none, at that tab's rung. 0
    /// means an unknown tab or one that already holds a page. This is
    /// the route every deliberate mint into an existing slot takes: a
    /// click on the tab, ⌘1–⌘9, ⌥⌘←/→, and the Return grant. Nothing
    /// else may call it, and expiry above all: a countdown that ran out
    /// overnight must leave an empty tab rather than start a fresh one
    /// on nothing.
    @discardableResult
    public func openPage(tab: UInt64) -> UInt64 {
        companion_tab_open_page(handle, tab)
    }

    /// Close a tab; whatever page it held rests in the ledger, sealed
    /// bytes zeroized. An empty slot closes as readily as a full one.
    @discardableResult
    public func closeTab(id: UInt64) -> Bool {
        companion_tab_close(handle, id)
    }

    /// Name a tab explicitly (the rename gesture in the tab context
    /// menu). Empty or all-whitespace clears the name and lets the
    /// label fall back to the live page's derived title and then to the
    /// tab's own creation stamp; anything else is trimmed, capped at 80
    /// characters, and sticks from then on — through every edit, and
    /// through the death of the page it was typed over. Returns whether
    /// the tab existed.
    @discardableResult
    public func setTitle(tab: UInt64, _ title: String) -> Bool {
        title.withCString { companion_tab_set_title(handle, tab, $0) }
    }

    /// Move a tab in the visible order (drag-to-reorder).
    @discardableResult
    public func moveTab(id: UInt64, to index: UInt64) -> Bool {
        companion_tab_move(handle, id, index)
    }

    /// The strip, in visible order: one entry per slot, page or no page.
    public func tabs() -> [TabSummary] {
        decodeJSON([TabSummary].self, from: companion_tabs_json(handle)) ?? []
    }

    /// Both emptiness predicates, asked of the core rather than derived
    /// from `tabs()`. Nil when the seam refused to answer, which the
    /// caller reads as neither: no rotation and no drop is the reading
    /// that changes nothing.
    public func emptiness() -> StoreEmptiness? {
        var holdsNoPage = false
        var hasNoTabs = false
        guard companion_store_emptiness(handle, &holdsNoPage, &hasNoTabs) else { return nil }
        return StoreEmptiness(holdsNoPage: holdsNoPage, hasNoTabs: hasNoTabs)
    }

    /// A page's provenance (ADR-0013): creation stamp and derived
    /// modified stamp. Nil for an unknown page.
    public func sheetMeta(sheet: UInt64) -> SheetMeta? {
        decodeJSON(SheetMeta.self, from: companion_sheet_meta_json(handle, sheet))
    }

    /// A page's blocks in document order: block identities with their
    /// derived created/modified stamps and how far each reaches, and
    /// nothing else.
    public func blocks(sheet: UInt64) -> [BlockInfo] {
        decodeJSON([BlockInfo].self, from: companion_sheet_blocks_json(handle, sheet)) ?? []
    }

    // MARK: Sealing — the gesture routes

    /// The sealed paste (⇧⌘V): the core reads the pasteboard itself
    /// and clears it in the same locked operation (ADR-0007 Amendment
    /// 1). `at`/`length` name the selection the gesture replaces, in
    /// UTF-16 code units against the page's body (ADR-0013): the core
    /// deletes that range and stands the chip's sentinel in its place
    /// inside the same locked call. Returns the new chip's face (or
    /// nil), plus whether the board was actually cleared: false
    /// alongside a chip means another writer moved the change count
    /// mid-take, the guarded clear stood down, and the caller must say
    /// so.
    @discardableResult
    public func sealFromPasteboard(
        sheet: UInt64, at: UInt32, length: UInt32
    ) -> (chip: ChipInfo?, cleared: Bool) {
        var cleared = false
        let chip = decodeJSON(
            ChipInfo.self,
            from: companion_sheet_seal_from_pasteboard(handle, sheet, at, length, &cleared))
        return (chip, cleared)
    }

    /// Whether the board holds content a sealed paste could take —
    /// external, representable, not our own transient copy-out. Type
    /// metadata only; no content bytes cross for the answer.
    public func pasteboardHasContent() -> Bool {
        companion_pasteboard_has_content(handle)
    }

    /// Drop-to-seal: the core reads the drag pasteboard itself while
    /// the drag session's data is still on it — dropped bytes never
    /// transit this process (the drag boundary decision,
    /// docs/hardware-verification.md). `at`/`length` name the drop
    /// point as a UTF-16 range the sentinel replaces, core-side; a
    /// plain drop is a zero-length range at the insertion index.
    /// Returns the new chip's face, or nil when nothing readable was
    /// dragged.
    @discardableResult
    public func sealFromDrag(sheet: UInt64, at: UInt32, length: UInt32) -> ChipInfo? {
        decodeJSON(
            ChipInfo.self, from: companion_sheet_seal_from_drag(handle, sheet, at, length))
    }

    /// The ⌘↩ retrofit: seal editor text the user selected. The one
    /// deliberate plaintext-in call: the text was visible ink already.
    /// `at`/`length` name the sealed span in UTF-16 code units: the
    /// core deletes it from the body and stands the sentinel in its
    /// place in the same locked call (ADR-0013), so the caller updates
    /// its projection rather than performing an edit of its own.
    @discardableResult
    public func sealText(sheet: UInt64, _ text: String, at: UInt32, length: UInt32) -> ChipInfo? {
        // A C string truncates at an interior NUL; sealing a silently
        // truncated secret while the core deletes the whole range
        // would lose the remainder. Refuse instead; the editor keeps
        // its copy and nothing was sealed.
        guard !text.contains("\0") else { return nil }
        return text.withCString { cText in
            decodeJSON(
                ChipInfo.self,
                from: companion_sheet_seal_text(handle, sheet, cText, at, length))
        }
    }

    /// Apply an ordered edit batch (JSON operations, UTF-16 offsets)
    /// to the page's body core-side, the ADR-0013 operation path.
    /// False means the batch was rejected whole and nothing moved;
    /// the caller re-converges through `syncDocument`.
    @discardableResult
    public func applyOps(sheet: UInt64, json: String) -> Bool {
        json.withCString { companion_sheet_apply_ops(handle, sheet, $0) }
    }

    /// Push a whole document snapshot (JSON runs) to the core. The
    /// recovery path now that edits travel as operations: it restates
    /// the page wholesale, at the price of that page's provenance.
    /// Still authoritative for chip liveness.
    @discardableResult
    public func syncDocument(sheet: UInt64, json: String) -> Bool {
        json.withCString { companion_sheet_sync_document(handle, sheet, $0) }
    }

    // MARK: Chips

    /// Copy a chip back out. The core writes the pasteboard itself,
    /// marked transient + concealed; this process never holds the bytes.
    @discardableResult
    public func copyOutChip(id: UInt64) -> Bool {
        companion_chip_copy_out(handle, id)
    }

    /// ⌫ on a chip: removes it whole, bytes zeroized, no resurrection.
    @discardableResult
    public func deleteChip(id: UInt64) -> Bool {
        companion_chip_delete(handle, id)
    }

    /// Change-count-guarded clear of our own last copy-out.
    @discardableResult
    public func clearClipboardIfOurs() -> Bool {
        companion_clear_clipboard_if_ours(handle)
    }

    // MARK: Time

    /// Milliseconds until the next scheduled instant — page expiry or
    /// hold lapse — the ONE timer to arm. -1 means nothing to schedule.
    public func nextEventMs() -> Int64 {
        companion_next_event_ms(handle)
    }

    /// Settle the clock: normalize lapsed holds, expire due pages;
    /// returns how many pages expired.
    @discardableResult
    public func expireDue() -> UInt64 {
        companion_expire_due(handle)
    }

    /// Click the countdown label: one rung shorter, clock reset. Tab
    /// addressed, and a slot holding no page keeps the shorter rung for
    /// the page it is opened with next.
    @discardableResult
    public func cycleRung(tab: UInt64) -> Rung? {
        Rung(rawValue: companion_tab_cycle_rung(handle, tab))
    }

    @discardableResult
    public func setRung(tab: UInt64, rung: Rung) -> Bool {
        companion_tab_set_rung(handle, tab, rung.rawValue)
    }

    /// Double-click the tab: hold 1h, top up to 24h from now, then
    /// release — the countdown resumes where it froze. False for a slot
    /// with no page in it, which has no clock to hold.
    @discardableResult
    public func pausePress(tab: UInt64) -> Bool {
        companion_tab_pause_press(handle, tab)
    }

    // MARK: Promotion — the exit ramp, the app's only network action

    /// Configure where promotion goes. The token, when passed, goes
    /// straight to the OS credential store core-side and is never
    /// retained here or in config; nil keeps the stored one, "" deletes
    /// it. Returns false on a non-https URL or malformed input.
    @discardableResult
    public func configureConnection(
        serverUrl: String, shareDomain: String, extid: String, token: String?
    ) -> Bool {
        var object: [String: String] = [
            "server_url": serverUrl,
            "share_domain": shareDomain,
            "extid": extid,
        ]
        if let token { object["token"] = token }
        guard let json = Self.encodeJSON(object) else { return false }
        return json.withCString { companion_connection_configure(handle, $0) }
    }

    /// Connection state for Settings — never the token itself.
    public func connectionInfo() -> ConnectionInfo? {
        decodeJSON(ConnectionInfo.self, from: companion_connection_json(handle))
    }

    /// The Settings "test" button: one status round-trip. **Blocks** —
    /// call off the main actor.
    public func testConnection() -> PromotionOutcome {
        decodeJSON(PromotionOutcome.self, from: companion_connection_test(handle))
            ?? PromotionOutcome(ok: false, receiptId: nil, error: "no connection configured")
    }

    /// Promote one sealed chip into a one-time link. The sealed bytes
    /// travel core → client → transport and never enter this process;
    /// on success the link is on the clipboard and only the receipt id
    /// stays on the chip. **Blocks** for the round-trip — call off the
    /// main actor.
    public func promoteChip(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String
    ) -> PromotionOutcome {
        promote(id: id, ttlSecs: ttlSecs, passphrase: passphrase, recipient: recipient) {
            companion_chip_promote($0, $1, $2)
        }
    }

    /// Promote the whole page (ink verbatim, sealed bytes inlined,
    /// core-side). Refused when the page holds an image chip. **Blocks**
    /// — call off the main actor.
    public func promoteSheet(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String
    ) -> PromotionOutcome {
        promote(id: id, ttlSecs: ttlSecs, passphrase: passphrase, recipient: recipient) {
            companion_sheet_promote($0, $1, $2)
        }
    }

    private func promote(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String,
        via route: (OpaquePointer, UInt64, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) -> PromotionOutcome {
        var object: [String: Any] = [:]
        if let ttlSecs { object["ttl_secs"] = ttlSecs }
        if !passphrase.isEmpty { object["passphrase"] = passphrase }
        if !recipient.isEmpty { object["recipient"] = recipient }
        guard let json = Self.encodeJSON(object) else {
            return PromotionOutcome(ok: false, receiptId: nil, error: "malformed promotion options")
        }
        let outcome = json.withCString { opts in
            decodeJSON(PromotionOutcome.self, from: route(handle, id, opts))
        }
        return outcome
            ?? PromotionOutcome(ok: false, receiptId: nil, error: "the core refused the request")
    }

    private static func encodeJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: The ledger

    /// The audit trail, newest first (⌘0): metadata only, held to a
    /// rolling 90-day window on the records' own wall-clock stamps.
    /// Records accumulate on ordinary use, not only on death, so a
    /// session in which pages were merely opened still has records.
    public func ledger() -> [LedgerEntry] {
        decodeJSON([LedgerEntry].self, from: companion_ledger_json(handle)) ?? []
    }

    /// Throw the whole ledger away: the user-facing "clear the ledger"
    /// affordance. In memory only, so call `ledgerSave(to:)` afterwards
    /// for the empty ledger to reach the file.
    public func clearLedger() {
        companion_ledger_clear(handle)
    }

    /// Save the ledger to `path`. It rests under its OWN long-lived
    /// key, minted on first save and never rotated with the content
    /// halves, which is why the audit record survives the emptying that
    /// forgets the content it describes. Its envelope magic is its own AEAD
    /// associated data, so this file and the state file are not
    /// interchangeable in either direction. Call it beside
    /// `persistSave(to:)`, behind the same debounce.
    ///
    /// The save sweeps the rolling 90-day window off the live records
    /// before it writes, so this mutates the in-memory ledger too: a
    /// record that aged out is gone from `ledger()` after a save, not
    /// only after the next restore. False now also covers an unreadable
    /// wall clock, which leaves the sweep no window to measure.
    @discardableResult
    public func ledgerSave(to path: String) -> Bool {
        path.withCString { companion_ledger_save(handle, $0) }
    }

    /// Restore the ledger at startup, beside and independent of
    /// `persistRestore(from:)`: either may succeed while the other
    /// fails, so licence each save on its own restore. Records outside
    /// the rolling 90-day window are dropped as the file loads. Nothing
    /// here ages a countdown or expires a page. False covers a fresh
    /// start with no file as much as a missing key, failed
    /// authentication, or a damaged snapshot.
    @discardableResult
    public func ledgerRestore(from path: String) -> Bool {
        path.withCString { companion_ledger_restore(handle, $0) }
    }

    // MARK: Persistence — the sealed state file

    /// A live page's document runs, for rebuilding the editor after a
    /// restore: ink verbatim, chips as their non-secret faces.
    public func documentRuns(sheet: UInt64) -> [RestoredRun] {
        decodeJSON([RestoredRun].self, from: companion_sheet_document_json(handle, sheet)) ?? []
    }

    /// Save the staged content (pages, sealed chips, clocks) to `path`,
    /// encrypted core-side (the key rests in the Keychain; only
    /// ciphertext touches disk). The ledger is not in this file: it has
    /// its own file under its own key, see `ledgerSave(to:)`. Call at
    /// quit; nothing saves on its own.
    @discardableResult
    public func persistSave(to path: String) -> Bool {
        path.withCString { companion_persist_save(handle, $0) }
    }

    /// Restore the store from `path` at startup, before the first page
    /// is created. False means a fresh start (no file) as much as a
    /// refused one (missing key, failed authentication, a damaged
    /// snapshot). A refusal leaves the file exactly where it is, which
    /// is what withholds this session's save licence rather than writing
    /// over content it could not read.
    ///
    /// One case answers false and leaves nothing behind: a file sealed
    /// under an envelope the core has since replaced is dropped on the
    /// spot, because nothing in it can ever be decrypted and an install
    /// that refused it forever would simply stop saving (ADR-0016
    /// section 9). The caller tells the cases apart by probing the path
    /// *after* this returns, never before (see
    /// `PageModel.loadStateIfNeeded`), so that disposal reads as "no
    /// file", which is what it now is.
    @discardableResult
    public func persistRestore(from path: String) -> Bool {
        path.withCString { companion_persist_restore(handle, $0) }
    }

    /// Drop the file at `path`: rotate the content key halves if a
    /// content envelope is what sits there, then overwrite, truncate,
    /// sync, unlink. The call stays path-scoped and touches no store, so
    /// it serves the state file and equally the ledger file on a user
    /// clear; what it no longer does is leave the content key alive
    /// behind a dropped content file. The rotation is decided by the
    /// magic at the path, never by which caller made the call, so
    /// clearing the ledger cannot take the staged pages with it.
    /// The open refuses a final symlink and refuses to block, and the
    /// writes refuse anything that is not a regular file. Those checks
    /// are narrower than they sound: a hard link at the path is a
    /// regular file and IS zeroed and truncated, and a symlinked parent
    /// directory is never examined. What contains this is that the path
    /// lives in an owner-only, app-owned directory. The canonical
    /// statement of the contract lives on `erase_state` in the core's
    /// persist module; this comment deliberately does not restate it.
    ///
    /// True when the path is confirmed empty, answered without following
    /// a link, including when there was nothing to begin with. A dangling
    /// symlink is still something, and a stat that will not answer counts
    /// as not empty, so both report false.
    ///
    /// Not erasure, and not to be described as erasure: the filesystem is
    /// copy on write and every generation an atomic rename already
    /// unlinked is out of reach. What forgets staged content is
    /// crypto-erasure, which is the rotation above: those unlinked
    /// generations stop being decryptable at the moment the keychain half
    /// goes. This is for the moment the store empties, so the last
    /// ciphertext generation does not sit there for the rest of the
    /// session describing nothing.
    ///
    /// The in-memory store is untouched: this deletes a file, not a page.
    @discardableResult
    public func persistErase(at path: String) -> Bool {
        path.withCString { companion_persist_erase(handle, $0) }
    }

    /// The core's version string.
    public static var version: String {
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
