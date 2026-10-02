import Foundation
import CompanionCore


// The shared seam wrapper, one copy for every form factor. ADR-0010
// carried two copies deliberately while the backdrop was an
// exploration, and named the extraction as the trigger that fires when
// a sibling graduates: the backdrop gaining persistence is that
// graduation. Everything here is a window onto the core, never logic.
// Logic that would need adding twice belongs in the core once.

/// A non-secret snapshot of one tab, a durable slot on the strip,
/// holding at most one perishable page of ink and sealed chips,
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
    /// Stable identity across relaunch; numeric ids are re-minted by restore.
    public var uuid: String? = nil
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
    /// Which of the three steps answered. The gutter draws a title
    /// only when it is a name the user typed: a placeholder repeats
    /// the stamp the gutter already carries, and a derived title
    /// repeats the page's own first line, which stands directly under
    /// the gutter (2026-0916 rail redundancy record).
    public let titleSource: TitleSource
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
    /// Whether the page holds anything at all: ink that is more than
    /// whitespace, or at least one sealed chip. False whenever
    /// `hasPage` is false.
    ///
    /// Answered core-side because it is the same bar the ledger applies
    /// when it decides whether a dying page did anything worth
    /// recording, and a second spelling of "empty" up here would
    /// eventually disagree with the audit trail. It arrives as a
    /// boolean and never as text: nothing needs a document read out to
    /// know whether a page has something on it.
    public let pageHasContent: Bool
    /// Which local day the PAGE was born on, counted relative to today:
    /// 0 for a page made today, -1 for one made yesterday, and nil when
    /// the slot holds no page: a slot with nothing in it is on no day,
    /// so it follows `pageID`'s null rather than the clock fields' zero.
    ///
    /// The stamp behind it is the page's own and not the tab's. A slot
    /// outlives every page that stands in it, so opening a page in a
    /// tab from last week would file this morning's typing under a day
    /// nobody was here; this one dies with the page it describes. The
    /// core buckets it with the same UTC offset the "MMDD-HHmm"
    /// placeholder is rendered from, so a tab's stamp and the day it
    /// sorts into cannot disagree at a daylight-saving change.
    ///
    /// It arrives already relative, which is why nothing up here has to
    /// know what today is or be woken when it changes: the core
    /// recomputes it on every read, so the ordinary cosmetic redraw
    /// rolls the reading over at local midnight on its own.
    public let pageDayOffset: Int?
    /// The page's own creation stamp, Unix epoch milliseconds, and nil
    /// on the same terms as `pageDayOffset`: a slot holding no page was
    /// born on no minute. The absolute stamp the offset was counted
    /// from, carried so the stream navigator and the gutters can print
    /// the time a checkpoint was made ("11:39", `StreamNavigator.stamps`)
    /// without a second reading of the clock.
    public let pageCreatedMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, paused
        case hasPage = "has_page"
        case pageID = "page_id"
        case titleSource = "title_source"
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
        case pageHasContent = "page_has_content"
        case pageDayOffset = "page_day_offset"
        case pageCreatedMs = "page_created_ms"
    }
}

/// Which step of the core's three-step label resolution answered
/// (`Tab::label` in `crates/core/src/sheet.rs`).
public enum TitleSource: String, Codable, Hashable, Sendable {
    /// The name the user typed.
    case name
    /// The live page's first typed line, markup stripped.
    case derived
    /// The tab's own "MMDD-HHmm" stamp, because nothing was typed.
    case placeholder
}

/// A non-secret snapshot of one open file, decoded from the core's
/// JSON (see crates/ffi/include/companion_ffi.h for the field
/// contract). A file is a peer content class to a page: the file on disk is
/// the artifact, saving is explicit, and none of a page's clock fields
/// have a meaning here, which is why this is its own type beside
/// `TabSummary` rather than more optionals on that one.
public struct FileSummary: Identifiable, Codable, Hashable, Sendable {
    /// The file's id, tagged with `CompanionClient.fileIDTag`.
    public let id: UInt64
    /// The display name, which is the last path component.
    public let name: String
    /// The last known path.
    public let path: String
    /// The buffer holds edits the file on disk does not.
    public let isDirty: Bool
    /// Whether something else wrote the file, and what.
    public let conflict: FileConflict
    /// The line ending style the file arrived with, preserved on save.
    public let lineEnding: FileLineEnding
    /// The file arrived with a UTF-8 BOM, preserved on save.
    public let hasBOM: Bool
    /// When the buffer was last edited, Unix seconds, or 0 when it has
    /// not been. The header states this beside the unsaved marker on a
    /// file restored from a draft, so a person can see the draft's age
    /// before pressing the save chord.
    public let lastEditedAt: UInt64
    /// The buffer came back from the drafts file at launch rather than
    /// from the file on disk.
    public let restoredFromDraft: Bool
    /// The buffer was filled from a disk copy that had changed while
    /// the app was away, so one notice is owed.
    ///
    /// Sticky, unlike the drafts notices, and cleared only by
    /// `clearFileReloadNotice(_:)`. The roster is read every time the
    /// strip redraws, so a flag that vanished on the first read would
    /// be a notice nobody ever saw.
    ///
    /// Defaulted so a roster row built by hand need not name it, and
    /// read as false when the key is absent (see `init(from:)`): the
    /// file was not reloaded behind anyone's back, which is what false
    /// says.
    public var externallyReloaded: Bool = false
    /// The row came out of the drafts file and has not been reconciled
    /// against the disk yet, so it is not fit to edit or save.
    ///
    /// True for every row between `draftsRestore(from:)` and the
    /// `hydrateFile(_:resolvedPath:)` that settles it. The model asks
    /// every row before it publishes a roster, and the one kind of row
    /// that reaches the surface still pending is a held one, which is
    /// also `accessRefused`: see `isHeld`. The core refuses an edit or a
    /// save on a pending file regardless, which is the rule that holds
    /// if the shell ever gets that wrong.
    ///
    /// Defaulted and tolerant of an absent key, as above.
    public var pendingHydration: Bool = false
    /// The system refused the core's last attempt to reach the file on
    /// disk, for a reason other than the file being gone: a read or a
    /// stat that was denied, which is what the sandbox answers for a
    /// file whose access was not kept. Cleared by the next read that
    /// succeeds and by a save.
    ///
    /// While it stands the surface offers to locate the file and does
    /// not offer to take the copy on disk, which nothing can read.
    ///
    /// While it stands over unsaved edits the file also stays in the
    /// changed conflict, whatever a later check's stat says, until a
    /// read succeeds or the person answers it with keep mine, Save As
    /// or Locate.
    ///
    /// Not `DraftNoticeReason.unreadable`, and the two words never
    /// stand for each other. This is a standing mark on an open file
    /// the system would not let the core reach. That is the reason on
    /// a notice for a file that was dropped at launch because its
    /// bytes were read and will not open as text.
    ///
    /// Defaulted and tolerant of an absent key, as above.
    public var accessRefused: Bool = false
    /// The core's last look at the path found nothing there. Cleared
    /// by the next look that finds something and by a save.
    ///
    /// A file with unsaved edits in this state is also in the missing
    /// conflict, unless keep mine has answered it. A clean file never
    /// enters a conflict, so for a clean file this is all that says
    /// its file is gone, and it is what puts Locate in front of the
    /// person rather than only a passing sentence.
    ///
    /// Defaulted and tolerant of an absent key, as above.
    public var notFound: Bool = false
}

extension FileSummary {
    /// Decoding, written out so the four flags above really are
    /// optional on the wire.
    ///
    /// A default value on a stored property does not do that on its
    /// own. The synthesized decoder asks for every key and throws on a
    /// missing one whatever the property's default is, and the roster
    /// is decoded as one array, so a single absent key would cost the
    /// whole roster rather than one field. The flags were each added
    /// after the first roster shape, and a test fixture or an older
    /// core that leaves one out must still decode.
    ///
    /// In an extension so the memberwise initializer survives for the
    /// rows a test builds by hand.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UInt64.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            path: try values.decode(String.self, forKey: .path),
            isDirty: try values.decode(Bool.self, forKey: .isDirty),
            conflict: try values.decode(FileConflict.self, forKey: .conflict),
            lineEnding: try values.decode(FileLineEnding.self, forKey: .lineEnding),
            hasBOM: try values.decode(Bool.self, forKey: .hasBOM),
            lastEditedAt: try values.decode(UInt64.self, forKey: .lastEditedAt),
            restoredFromDraft: try values.decode(Bool.self, forKey: .restoredFromDraft),
            externallyReloaded:
                try values.decodeIfPresent(Bool.self, forKey: .externallyReloaded) ?? false,
            pendingHydration:
                try values.decodeIfPresent(Bool.self, forKey: .pendingHydration) ?? false,
            accessRefused:
                try values.decodeIfPresent(Bool.self, forKey: .accessRefused) ?? false,
            notFound: try values.decodeIfPresent(Bool.self, forKey: .notFound) ?? false
        )
    }

    /// The row is a restored record the core could not read and did
    /// not drop: still pending, with an empty buffer that is not the
    /// file's text. It stays on the surface so a person who knows
    /// where the file is can say so, and until they do it can be
    /// located or closed and nothing else.
    /// Core `FileStore::hydrate_one` (`crates/core/src/files.rs`) leaves
    /// held records pending with `conflict == .none`; a staged draft's
    /// refused read settles into a conflict instead and is not held.
    public var isHeld: Bool { pendingHydration && accessRefused }

    /// Whether the row holds edits of the person's that the file on
    /// disk does not, which is what the header's save word, the
    /// unsaved dot and the dirty close decision all ask.
    ///
    /// A held row never does, whatever `isDirty` says. Its record can
    /// come back marked dirty with no draft behind it, when the draft
    /// was too large to seal, and the buffer of a held row is empty
    /// either way because nothing was read. There is nothing in it to
    /// save, nothing to discard and nothing to keep editing.
    public var holdsUnsavedEdits: Bool { isDirty && !isHeld }

    /// Whether the surface offers to locate the file: it is no longer
    /// at its path, with or without unsaved edits over it, or it is
    /// there and cannot be read.
    public var offersLocate: Bool { conflict == .missing || notFound || accessRefused }

    /// Whether the conflict banner offers the copy on disk. Not while
    /// that copy cannot be read, and not while it is gone: either way
    /// there is nothing to take, and the button could only fail.
    public var offersTakeTheirs: Bool { !accessRefused && conflict != .missing }

    /// Whether the file's copy on disk cannot be reached while no
    /// conflict stands: it cannot be read, or nothing is at its path.
    /// The state the unavailable banner is drawn for.
    public var isUnavailable: Bool { conflict == .none && (accessRefused || notFound) }
}

/// Something a drafts save or restore has to tell the person about,
/// after the fact.
public struct DraftNotice: Codable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let reason: DraftNoticeReason
}

/// Why a file the drafts file named is not on the surface, or why its
/// unsaved edits are not.
public enum DraftNoticeReason: String, Codable, Hashable, Sendable {
    /// The file is no longer at its path.
    case missing
    /// The file is there and will not open as text: it is not UTF-8,
    /// looks binary or is past the size limit. Never
    /// `FileSummary.accessRefused`, which is a file the system would
    /// not let the core read, and which is held rather than dropped.
    case unreadable
    /// The unsaved edits were too large to seal, so the file came back
    /// as itself and the edits did not.
    case draftTooLarge
}

/// Whether something else wrote the file since the core last read or
/// wrote it, and what.
public enum FileConflict: String, Codable, Hashable, Sendable {
    case none
    case changed
    case missing
}

/// The line ending style a file arrived with. Decided at open,
/// preserved on save, never changed after.
public enum FileLineEnding: String, Codable, Hashable, Sendable {
    case lf
    case crlf
}

/// What a fresh look at the filesystem says about an open file.
///
/// The three readings are the check's own and not `FileConflict`'s: a
/// clean file that changed on disk is reloaded without asking and never
/// enters a conflict at all, so "unchanged" and "none" are answers to
/// two different questions and are spelled differently on the wire.
public enum FileCheckState: String, Codable, Hashable, Sendable {
    case unchanged
    case changed
    case missing
}

/// The result of `CompanionClient.checkFile(_:)`.
public struct FileCheck: Codable, Hashable, Sendable {
    public let state: FileCheckState
    public let path: String
}

/// Why a save was refused, as `companion_file_save_error_json` states
/// it. The bool a save answers cannot say, and the roster row
/// afterwards does not say either: a row marked not found whose write
/// the platform then refused looks exactly like one refused for being
/// not found. The shell chooses its sentence from this.
public enum FileSaveRefusal: Equatable, Sendable {
    /// The file came back from the last session and nothing has
    /// reconciled it against the disk yet.
    case pendingHydration
    /// The file stands in a conflict nobody has answered, which the
    /// save itself may have been the one to find.
    case conflict
    /// Nothing is at the file's path and no keep mine stands, so
    /// nothing was written.
    case notFound
    /// A save as onto a path another open file already holds.
    case pathInUse
    /// No file is open under that id.
    case unknownFile
    /// The save was allowed and the write itself failed. `detail` is
    /// the kind of failure, a fixed English label that carries no part
    /// of the path.
    case write(detail: String)

    private struct Wire: Decodable {
        let error: String
        let detail: String?
    }

    /// Read the core's answer. Nil for no answer, for JSON that will
    /// not parse and for a reason this build does not know, all of
    /// which the caller words as a write that did not land: the one
    /// sentence that is true of every refused save.
    public init?(json: String?) {
        guard let json,
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        else { return nil }
        switch wire.error {
        case "pendingHydration": self = .pendingHydration
        case "conflict": self = .conflict
        case "notFound": self = .notFound
        case "pathInUse": self = .pathInUse
        case "unknownFile": self = .unknownFile
        case "write": self = .write(detail: wire.detail ?? "")
        default: return nil
        }
    }
}

extension UInt64 {
    /// Whether this id addresses an open file rather than a page. The
    /// one question every routing branch in the shell asks; the tag it
    /// reads is `CompanionClient.fileIDTag`, mirrored from
    /// crates/core/src/files.rs.
    public var isFileID: Bool { self & CompanionClient.fileIDTag != 0 }
}

/// What one undo or redo step did: whether anything moved, and where
/// the caret belongs afterwards.
public struct StepOutcome: Codable, Hashable, Sendable {
    public let applied: Bool
    /// Caret position in UTF-16 code units, or nil when the step
    /// carried no position and the caret stays where the writer had it.
    public var selection: NSRange? {
        guard selectionLocationUTF16 >= 0, selectionLengthUTF16 >= 0 else { return nil }
        return NSRange(
            location: Int(selectionLocationUTF16),
            length: Int(selectionLengthUTF16)
        )
    }
    public var caret: Int? { selection?.location ?? (caretUTF16 < 0 ? nil : Int(caretUTF16)) }

    let caretUTF16: Int64
    let selectionLocationUTF16: Int64
    let selectionLengthUTF16: Int64
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
    public let concealed: Bool

    enum CodingKeys: String, CodingKey {
        case kind, excerpt, concealed
        case chipId = "chip_id"
        case sizeLabel = "size_label"
    }
}

/// One line of the audit trail: what the app did with one item,
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

/// A conceal (or connection-test) result off the seam: success, or an
/// inline-able error message. Never a link — on success the link is
/// already on the clipboard, written core-side.
public struct ConcealOutcome: Codable, Hashable, Sendable {
    public let ok: Bool
    public let receiptId: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case receiptId = "receipt_id"
    }
}

/// Sync's standing state as Settings may render it (companion_ffi.h):
/// existence checks and in-memory reads core-side — never a token, and
/// never a network wait.
public struct SyncStatus: Codable, Hashable, Sendable {
    public let configured: Bool
    public let signedIn: Bool
    /// Where the account gate stands, as the core spells it. Kept as
    /// the raw token and read through `gate` below, so neither a core
    /// built before the gate existed nor one a version ahead can make
    /// the whole status fail to decode.
    public let gateToken: String?
    public let signinPending: Bool
    public let attached: Bool
    public let epoch: UInt64?
    public let framePresent: Bool?
    public let enrolled: Int
    public let pairing: String?

    /// The gate as a state the surface can switch on, or nil when the
    /// core named something this build has never heard of.
    public var gate: SyncGate? { gateToken.flatMap(SyncGate.init(rawValue:)) }

    enum CodingKeys: String, CodingKey {
        case configured, attached, epoch, enrolled, pairing
        case gateToken = "gate"
        case signedIn = "signed_in"
        case signinPending = "signin_pending"
        case framePresent = "frame_present"
    }
}

/// The account gate's seven states (ADR-0027 §5), as the core names
/// them. Each earns its own sentence and none of them is silent; none
/// of them touches the pad, which keeps working with no account and no
/// network whatever this says.
///
public enum SyncGate: String, Codable, Hashable, Sendable {
    case off
    case signedOut = "signed_out"
    case signingIn = "signing_in"
    case refused
    case unreachable
    case ready
    case attached
}

/// One row of the device list: a peer a human verified here, this
/// device itself, or an attached stranger no pairing vouches for —
/// each labelled as what it is.
public struct SyncDevice: Codable, Hashable, Sendable, Identifiable {
    public let fingerprint: String
    public let label: String
    public let thisDevice: Bool
    public let verified: Bool
    public let pairedWallMs: UInt64?
    public let attachedMs: UInt64?

    public var id: String { fingerprint }

    enum CodingKeys: String, CodingKey {
        case fingerprint, label, verified
        case thisDevice = "this_device"
        case pairedWallMs = "paired_wall_ms"
        case attachedMs = "attached_ms"
    }
}

/// The envelope the device list arrives in.
struct SyncDeviceList: Codable {
    let devices: [SyncDevice]
}

/// A sync action's result off the seam: ok, or a machine reason the
/// surface owns a sentence for. Begin carries the authorize URL;
/// attach carries where the channel stands.
public struct SyncOutcome: Codable, Hashable, Sendable {
    public let ok: Bool
    public let reason: String?
    public let authorizeUrl: String?
    public let epoch: UInt64?
    public let framePresent: Bool?
    public let peers: Int?

    enum CodingKeys: String, CodingKey {
        case ok, reason, epoch, peers
        case authorizeUrl = "authorize_url"
        case framePresent = "frame_present"
    }

    static func refused(_ reason: String) -> SyncOutcome {
        SyncOutcome(
            ok: false, reason: reason, authorizeUrl: nil, epoch: nil, framePresent: nil,
            peers: nil)
    }
}

/// One engine-loop turn's outcome: what happened (machine kinds, the
/// surface owns the sentences) and where sync now stands.
public struct SyncPumpOutcome: Codable, Hashable, Sendable {
    public let ok: Bool
    public let reason: String?
    public let events: [SyncPumpEvent]
    public let state: SyncStatus?
}

/// One pump event: a machine kind and, where one is concerned, the
/// page, twice over. `page` is the cross-device identity, the only
/// name a peer can use; `pageID` is the local id the same page answers
/// to here, and it is nil for an event about no page and for a page
/// this device no longer keeps. The surface uses the second: a mark
/// saying "another device is editing this page" has to land on a page
/// the user is looking at, and the identity alone would not say which
/// one that is.
public struct SyncPumpEvent: Codable, Hashable, Sendable {
    public let kind: String
    public let page: String?
    public let pageID: UInt64?

    enum CodingKeys: String, CodingKey {
        case kind, page
        case pageID = "page_id"
    }
}

/// The pairing ceremony's stage, polled while the enrolment sheet is
/// open: `waiting`, `sas` (show the digits), `confirmed`, `done`,
/// `failed`, `idle`.
public struct SyncPairingStage: Codable, Hashable, Sendable {
    public let stage: String
    public let sas: String?
    public let reason: String?
}

/// A thin, memory-safe Swift wrapper over the C ABI. Owns the opaque
/// handle for its lifetime and only ever sees ids, non-secret summaries,
/// excerpts, and booleans. Sealed-byte movement runs inside the core.
///
/// `@unchecked Sendable`: the handle is immutable after init and every
/// call is serialized by the core's own mutex (companion_ffi.h) — the
/// conceal routes are *meant* to be called off the main actor, since
/// they block for a network round-trip.
///
/// Not final, for one reason: the test target subclasses it to answer a
/// call the way the core never would on demand. A close is the case
/// that forced it, since the core refuses one only for an id it has
/// never heard of, and the shell's behaviour when a close is refused
/// under a standing decision is exactly what wants covering. Nothing in
/// the app subclasses it, and no method here is written to be extended.
public class CompanionClient: @unchecked Sendable {
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

    private func selectionWire(_ selection: NSRange?) -> (UInt32, UInt32)? {
        guard let selection else { return (UInt32.max, UInt32.max) }
        guard selection.location != NSNotFound,
              let location = UInt32(exactly: selection.location),
              let length = UInt32(exactly: selection.length)
        else { return nil }
        return (location, length)
    }

    private func editSelectionWire(
        _ selection: EditorEditSelection?
    ) -> (UInt32, UInt32, UInt32, UInt32)? {
        guard let selection else {
            return (UInt32.max, UInt32.max, UInt32.max, UInt32.max)
        }
        guard let before = selectionWire(selection.before),
              let after = selectionWire(selection.after),
              before.0 != UInt32.max,
              after.0 != UInt32.max
        else { return nil }
        return (before.0, before.1, after.0, after.1)
    }

    deinit {
        companion_free(handle)
    }

    // MARK: Tabs, the durable slots

    /// A new tab at the end of the strip, holding a new page; 0 only
    /// when the core could not answer, since the strip has no cap
    /// (issue #158). The id is the TAB's: it is what the selection
    /// keeps afterwards.
    @discardableResult
    public func newTab() -> UInt64 {
        companion_tab_new(handle)
    }

    /// Mint a page into a tab that holds none, at that tab's rung. 0
    /// means an unknown tab or one that already holds a page. This is
    /// the route every deliberate mint into an existing slot takes: a
    /// click on the tab, ⌘1 to ⌘9, ⌥⌘←/→, and the Return grant. Nothing
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

    /// Discard the page a slot holds and leave the slot standing: its
    /// sealed bytes are zeroized, the ledger keeps one discarded
    /// record, and the tab keeps its name, its rung, its position and
    /// its number key, the way an expiry leaves it. Returns whether a
    /// page by that id was standing.
    ///
    /// Page addressed rather than tab addressed, which is the whole
    /// difference from `closeTab`: the burn offered after a conceal
    /// names the content that travelled, and spending the user's
    /// arrangement on it would end a tab that only a close may end
    /// (ADR-0017).
    @discardableResult
    public func discardPage(id: UInt64) -> Bool {
        companion_page_discard(handle, id)
    }

    /// Name a tab explicitly (the rename gesture in the tab context
    /// menu). Empty or all-whitespace clears the name and lets the
    /// label fall back to the live page's derived title and then to the
    /// tab's own creation stamp; anything else is trimmed, capped at 80
    /// characters, and sticks from then on, through every edit, and
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
    /// docs/qa/hardware-verification.md). `at`/`length` name the drop
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
    ///
    /// `intent` supplies the editing gesture; the core owns grouping.
    @discardableResult
    public func applyOps(
        sheet: UInt64,
        json: String,
        intent: EditorEditIntent = .typing,
        selection: EditorEditSelection? = nil
    ) -> Bool {
        guard let wire = editSelectionWire(selection) else { return false }
        return json.withCString {
            companion_sheet_apply_ops_with_intent(
                handle,
                sheet,
                $0,
                intent.rawValue,
                wire.0,
                wire.1,
                wire.2,
                wire.3
            )
        }
    }

    /// End the current coalescing run without creating an undo item.
    @discardableResult
    public func finishEditingGroup(sheet: UInt64, selection: NSRange? = nil) -> Bool {
        guard let wire = selectionWire(selection) else { return false }
        return companion_sheet_finish_editing_group(handle, sheet, wire.0, wire.1)
    }

    /// Push a whole document snapshot (JSON runs) to the core. The
    /// recovery path now that edits travel as operations: it restates
    /// the page wholesale, at the price of that page's provenance.
    /// Still authoritative for chip liveness.
    @discardableResult
    public func syncDocument(sheet: UInt64, json: String) -> Bool {
        json.withCString { companion_sheet_sync_document(handle, sheet, $0) }
    }

    // MARK: Undo (issue #132)

    /// Take back the page's last local edit, or the couple of seconds
    /// of them the core groups into one step. False means nothing
    /// moved, and the caller leaves the page alone.
    ///
    /// The stack is the core's and it is bound to that document's own
    /// peer, so a step reverts only what this device authored. Undo
    /// does not reach another device's text and is not meant to: the
    /// library refuses a peer's operations by design, and a device that
    /// joined at a key frame never held the operations an away-device
    /// undo would have to invert (ADR-0021 section 5).
    @discardableResult
    public func undo(sheet: UInt64) -> Bool {
        companion_sheet_undo(handle, sheet)
    }

    /// Put back the step `undo(sheet:)` took, on the same terms.
    @discardableResult
    public func redo(sheet: UInt64) -> Bool {
        companion_sheet_redo(handle, sheet)
    }

    /// Whether the page has a step waiting in either direction.
    public func canUndo(sheet: UInt64) -> Bool {
        companion_sheet_can_undo(handle, sheet)
    }

    public func canRedo(sheet: UInt64) -> Bool {
        companion_sheet_can_redo(handle, sheet)
    }

    /// Content-free label for the next page step in either direction.
    public func undoActionName(sheet: UInt64) -> String? {
        ownedString(from: companion_sheet_undo_action_name(handle, sheet))
    }

    public func redoActionName(sheet: UInt64) -> String? {
        ownedString(from: companion_sheet_redo_action_name(handle, sheet))
    }

    /// Where the caret belongs after the last accepted step, in UTF-16
    /// code units. Nil when the step carried no position, which is the
    /// signal to leave the caret where the writer had it.
    public func undoCaret(sheet: UInt64) -> Int? {
        let caret = companion_sheet_undo_caret_u16(handle, sheet)
        return caret < 0 ? nil : Int(caret)
    }

    /// The complete selection restored by the last accepted step.
    public func undoSelection(sheet: UInt64) -> NSRange? {
        let location = companion_sheet_undo_selection_location_u16(handle, sheet)
        let length = companion_sheet_undo_selection_length_u16(handle, sheet)
        guard location >= 0, length >= 0 else { return nil }
        return NSRange(location: Int(location), length: Int(length))
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

    /// How long a copy-out may dwell on the general pasteboard before
    /// the armed clear takes it back, in seconds. The core's one
    /// constant, so the confirmation line and the timer name the same
    /// number (D-29, D-32).
    public static func clipboardClearSeconds() -> UInt32 {
        companion_clipboard_clear_seconds()
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

    /// The boundary snap (ADR-0011 section 4): on, a rung applied from
    /// now on rounds its deadline up to the next whole clock hour or
    /// local midnight, by at most a day; off, a rung is exactly its
    /// nominal duration. Deadlines already set never move.
    @discardableResult
    public func setGraceSnap(_ on: Bool) -> Bool {
        companion_set_grace_snap(handle, on)
    }

    /// Double-click the tab: hold 1h, top up to 24h from now, then
    /// release, the countdown resumes where it froze. False for a slot
    /// with no page in it, which has no clock to hold.
    @discardableResult
    public func pausePress(tab: UInt64) -> Bool {
        companion_tab_pause_press(handle, tab)
    }

    // MARK: Conceal — the exit ramp, an explicit user action

    /// Configure where a conceal goes. The token, when passed, goes
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
    public func testConnection() -> ConcealOutcome {
        decodeJSON(ConcealOutcome.self, from: companion_connection_test(handle))
            ?? ConcealOutcome(ok: false, receiptId: nil, error: "no connection configured")
    }

    /// Conceal one sealed chip into a one-time link. The sealed bytes
    /// travel core → client → transport and never enter this process;
    /// on success the link is on the clipboard and only the receipt id
    /// stays on the chip. **Blocks** for the round-trip — call off the
    /// main actor.
    public func concealChip(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String
    ) -> ConcealOutcome {
        conceal(id: id, ttlSecs: ttlSecs, passphrase: passphrase, recipient: recipient) {
            companion_chip_conceal($0, $1, $2)
        }
    }

    /// Conceal the whole page (ink verbatim, sealed bytes inlined,
    /// core-side). Refused when the page holds an image chip. **Blocks**
    /// — call off the main actor.
    public func concealSheet(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String
    ) -> ConcealOutcome {
        conceal(id: id, ttlSecs: ttlSecs, passphrase: passphrase, recipient: recipient) {
            companion_sheet_conceal($0, $1, $2)
        }
    }

    private func conceal(
        id: UInt64, ttlSecs: UInt64?, passphrase: String, recipient: String,
        via route: (OpaquePointer, UInt64, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) -> ConcealOutcome {
        var object: [String: Any] = [:]
        if let ttlSecs { object["ttl_secs"] = ttlSecs }
        if !passphrase.isEmpty { object["passphrase"] = passphrase }
        if !recipient.isEmpty { object["recipient"] = recipient }
        guard let json = Self.encodeJSON(object) else {
            return ConcealOutcome(ok: false, receiptId: nil, error: "malformed conceal options")
        }
        let outcome = json.withCString { opts in
            decodeJSON(ConcealOutcome.self, from: route(handle, id, opts))
        }
        return outcome
            ?? ConcealOutcome(ok: false, receiptId: nil, error: "the core refused the request")
    }

    private static func encodeJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Sync — the relay channel (issues #98 and #102)

    /// Configure sync's endpoints and client identity. Not persisted
    /// core-side — re-sent at launch like the conceal connection — but
    /// configuring resumes the persisted sign-in from the Keychain.
    /// False on a missing field or a non-https URL.
    @discardableResult
    public func syncConfigure(
        relayUrl: String, authorizeUrl: String, tokenUrl: String, clientId: String
    ) -> Bool {
        let object: [String: String] = [
            "relay_url": relayUrl,
            "authorize_url": authorizeUrl,
            "token_url": tokenUrl,
            "client_id": clientId,
        ]
        guard let json = Self.encodeJSON(object) else { return false }
        return json.withCString { companion_sync_configure(handle, $0) }
    }

    /// Sync's standing state for Settings — existence checks only,
    /// never a decrypt and never a network wait.
    public func syncStatus() -> SyncStatus? {
        decodeJSON(SyncStatus.self, from: companion_sync_status_json(handle))
    }

    /// Where the account gate stands, without the rest of the status:
    /// the one word the surface needs to know whether sync may attach.
    /// Nil when the core could not be read, which is not a state the
    /// gate has and is therefore never mistaken for one: a gate that
    /// could not be read has not been passed, so a caller treats nil
    /// as "may not attach" rather than as no opinion.
    /// `SyncStatus.gate`'s nil is the other fact, a core that named no
    /// gate at all, and that one does mean no opinion.
    public func syncGate() -> SyncGate? {
        guard let ptr = companion_sync_gate(handle) else { return nil }
        defer { companion_string_free(ptr) }
        return SyncGate(rawValue: String(cString: ptr))
    }

    /// Begin the sign-in ceremony: the result's `authorizeUrl` opens in
    /// the system browser — never a web view — and the finish call
    /// waits out the consent screen.
    public func syncSigninBegin() -> SyncOutcome {
        decodeJSON(SyncOutcome.self, from: companion_sync_signin_begin(handle))
            ?? .refused("no_ceremony")
    }

    /// Finish the sign-in ceremony: wait for the browser's one
    /// redirect and persist the rotated refresh token. **Blocks** for
    /// up to the whole patience — call off the main actor.
    public func syncSigninFinish(patienceMs: UInt64) -> SyncOutcome {
        decodeJSON(SyncOutcome.self, from: companion_sync_signin_finish(handle, patienceMs))
            ?? .refused("no_ceremony")
    }

    /// Forget a begun, unfinished sign-in ceremony.
    @discardableResult
    public func syncSigninCancel() -> Bool {
        companion_sync_signin_cancel(handle)
    }

    /// Sign sync out: exactly one Keychain account goes; the pad is
    /// unaffected.
    @discardableResult
    public func syncSignout() -> Bool {
        companion_sync_signout(handle)
    }

    /// Enrol a page into the channel or withdraw it — per page, off by
    /// default. `id` is the PAGE id.
    @discardableResult
    public func syncEnrolPage(id: UInt64, enrolled: Bool) -> Bool {
        companion_sync_enrol_page(handle, id, enrolled)
    }

    /// Attach to the account's channel. **Blocks** for the round-trips
    /// — call off the main actor.
    public func syncAttach() -> SyncOutcome {
        decodeJSON(SyncOutcome.self, from: companion_sync_attach(handle))
            ?? .refused("not_configured")
    }

    /// Detach and dissolve the engine, keeping the sign-in. **Blocks**
    /// briefly — call off the main actor.
    @discardableResult
    public func syncDetach() -> Bool {
        companion_sync_detach(handle)
    }

    /// One turn of the engine loop: sweep, publish, long-poll, walk
    /// the ballot patience, publish a committed frame. **Blocks** for
    /// up to the whole long-poll — call off the main actor, in the
    /// loop that runs while sync is on.
    public func syncPump(waitSeconds: UInt32) -> SyncPumpOutcome? {
        decodeJSON(SyncPumpOutcome.self, from: companion_sync_pump(handle, waitSeconds))
    }

    /// The device list for Settings.
    public func syncDevices() -> [SyncDevice] {
        decodeJSON(SyncDeviceList.self, from: companion_sync_devices_json(handle))?.devices ?? []
    }

    /// Revoke a paired peer: nothing is ever sealed to it again, and
    /// the chain leaves it behind at the next ceremony at the latest.
    @discardableResult
    public func syncRevokePeer(fingerprint: String) -> Bool {
        fingerprint.withCString { companion_sync_revoke_peer(handle, $0) }
    }

    /// Begin inviting a new device into the channel; then poll.
    public func syncInviteBegin() -> SyncOutcome {
        decodeJSON(SyncOutcome.self, from: companion_sync_invite_begin(handle))
            ?? .refused("not_attached")
    }

    /// Begin joining a channel from this new device; then poll.
    public func syncJoinBegin() -> SyncOutcome {
        decodeJSON(SyncOutcome.self, from: companion_sync_join_begin(handle))
            ?? .refused("not_attached")
    }

    /// One mailbox round of the pairing ceremony. **Blocks** for the
    /// round-trips — call off the main actor, on a timer while the
    /// enrolment sheet is open.
    public func syncPairingPoll() -> SyncPairingStage? {
        decodeJSON(SyncPairingStage.self, from: companion_sync_pairing_poll(handle))
    }

    /// The human's verdict on the six digits: a match moves the
    /// ceremony forward, a mismatch aborts it whole with nothing
    /// stored.
    public func syncPairingConfirm(matched: Bool) -> SyncPairingStage? {
        decodeJSON(SyncPairingStage.self, from: companion_sync_pairing_confirm(handle, matched))
    }

    /// Forget the pairing ceremony in flight, at any stage.
    @discardableResult
    public func syncPairingCancel() -> Bool {
        companion_sync_pairing_cancel(handle)
    }

    // MARK: The ledger

    /// The audit trail, newest first: metadata only, held to a
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

    /// Rotate both content key halves and reseal the store under the
    /// new ones: the write for the moment no tab holds a page, which is
    /// ADR-0016 section 6's first rotation trigger and the reason
    /// `StoreEmptiness.holdsNoPage` is asked of the core rather than
    /// derived here.
    ///
    /// The rotation is the forgetting: every ciphertext generation the
    /// old halves ever sealed, including the ones an atomic rename
    /// unlinked and nothing sweeps, stops being decryptable at once.
    /// The reseal is what keeps the strip, since an empty pad still has
    /// tab names, rungs and an order the user arranged, and there is no
    /// page content left in the file to lose.
    ///
    /// False means the rotation refused and nothing was written, which
    /// leaves the old generation where it was and arms the caller's
    /// retry. Sealing a fresh generation under halves the rotation could
    /// not replace would report a forgetting that did not happen.
    @discardableResult
    public func persistRotateAndSave(to path: String) -> Bool {
        path.withCString { companion_persist_rotate_and_save(handle, $0) }
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

    // MARK: Files: the peer content class to pages

    /// The high bit, set on every file id and on no page id.
    ///
    /// The mirror of `FILE_ID_TAG` in crates/core/src/files.rs, which
    /// is where it is defined. Two stores share one `UInt64` across the
    /// seam, so this is not a convention: every `companion_sheet_*`
    /// entry point refuses a tagged id core-side, and the shell routes
    /// on the same bit rather than on a parallel bookkeeping set that
    /// could drift.
    public static let fileIDTag: UInt64 = 1 << 63

    /// Open the file at `path`, returning its tagged id, or nil when
    /// the open refused. Ask `openFileErrorJSON()` why.
    ///
    /// A path that is already open hands back the id it is open under,
    /// except when that row is still `pendingHydration`: the core
    /// refuses then, because the row's buffer is not the file's text
    /// yet. The caller hydrates the row first and asks again.
    public func openFile(path: String) -> UInt64? {
        let id = path.withCString { companion_file_open(handle, $0) }
        return id == 0 ? nil : id
    }

    /// Why the last `openFile(path:)` refused, as the raw JSON the
    /// header describes. Nil when nothing has refused.
    public func openFileErrorJSON() -> String? {
        guard let ptr = companion_file_open_error_json(handle) else { return nil }
        defer { companion_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Close the file and drop its buffer. The draft goes with it: a
    /// draft never outlives its tab. Any dirty-close decision is settled
    /// in the shell before this call.
    @discardableResult
    public func closeFile(_ file: UInt64) -> Bool {
        companion_file_close(handle, file)
    }

    /// The file's document runs, the same shape a page's arrive in.
    public func fileRuns(_ file: UInt64) -> [RestoredRun] {
        decodeJSON([RestoredRun].self, from: companion_file_runs_json(handle, file)) ?? []
    }

    /// Apply an ordered edit batch to the file's body. False means the
    /// batch was rejected whole and nothing moved.
    @discardableResult
    public func applyFileOps(
        _ file: UInt64,
        json: String,
        intent: EditorEditIntent = .typing,
        selection: EditorEditSelection? = nil
    ) -> Bool {
        guard let wire = editSelectionWire(selection) else { return false }
        return json.withCString {
            companion_file_apply_ops_with_intent(
                handle,
                file,
                $0,
                intent.rawValue,
                wire.0,
                wire.1,
                wire.2,
                wire.3
            )
        }
    }

    /// End the current coalescing run without creating an undo item.
    @discardableResult
    public func finishFileEditingGroup(_ file: UInt64, selection: NSRange? = nil) -> Bool {
        guard let wire = selectionWire(selection) else { return false }
        return companion_file_finish_editing_group(handle, file, wire.0, wire.1)
    }

    /// Take back the file's last local edit step.
    public func undoFile(_ file: UInt64) -> StepOutcome? {
        decodeJSON(StepOutcome.self, from: companion_file_undo(handle, file))
    }

    /// Put back the step `undoFile(_:)` took, on the same terms.
    public func redoFile(_ file: UInt64) -> StepOutcome? {
        decodeJSON(StepOutcome.self, from: companion_file_redo(handle, file))
    }

    /// Whether the file has a step waiting in either direction: what
    /// the Edit menu's two items grey themselves out on.
    ///
    /// Its own pair rather than the page's, because the page's route
    /// refuses a tagged id and answers false, which would tell the
    /// menu that a file with a full undo stack had nothing to take
    /// back.
    public func canUndoFile(_ file: UInt64) -> Bool {
        companion_file_can_undo(handle, file)
    }

    public func canRedoFile(_ file: UInt64) -> Bool {
        companion_file_can_redo(handle, file)
    }

    /// Content-free label for the next file step in either direction.
    public func undoFileActionName(_ file: UInt64) -> String? {
        ownedString(from: companion_file_undo_action_name(handle, file))
    }

    public func redoFileActionName(_ file: UInt64) -> String? {
        ownedString(from: companion_file_redo_action_name(handle, file))
    }

    /// Write the buffer back to the file's own path. False when the
    /// write refused, which includes a file standing in a conflict
    /// nobody has resolved yet and a restored file that has not been
    /// hydrated.
    ///
    /// A save never makes a file where there is none. When nothing is
    /// at the file's path the core refuses, whether or not it was
    /// asked to check first, and leaves the row `notFound`, and in the
    /// `missing` conflict when it holds unsaved edits. The one save
    /// that writes to an empty path is the one a keep mine licensed.
    /// `saveFile(_:as:stagingDirectory:)` is not refused this way: a
    /// destination a person chose is theirs to make a file at.
    ///
    /// `stagingDirectory` is where the core makes its temp file before
    /// renaming it onto the target. Nil makes it beside the target,
    /// which a sandboxed process may not do. Otherwise it is a
    /// directory on the target's volume that the caller made and will
    /// remove. The core never falls back from one to the other: a
    /// staging directory it cannot use fails the save with nothing
    /// written.
    ///
    /// No default, deliberately. Every caller has to say where the
    /// temp file goes, because the answer that is easiest to leave out
    /// is the one that cannot save under the sandbox.
    @discardableResult
    public func saveFile(_ file: UInt64, stagingDirectory: String?) -> Bool {
        guard let stagingDirectory else { return companion_file_save(handle, file, nil) }
        return stagingDirectory.withCString { companion_file_save(handle, file, $0) }
    }

    /// Write the buffer to `path` and adopt it as the file's path.
    /// `stagingDirectory` is as `saveFile(_:stagingDirectory:)` has
    /// it, for the new target's volume.
    @discardableResult
    public func saveFile(_ file: UInt64, as path: String, stagingDirectory: String?) -> Bool {
        path.withCString { target in
            guard let stagingDirectory else {
                return companion_file_save_as(handle, file, target, nil)
            }
            return stagingDirectory.withCString {
                companion_file_save_as(handle, file, target, $0)
            }
        }
    }

    /// Why the last `saveFile(_:stagingDirectory:)` or
    /// `saveFile(_:as:stagingDirectory:)` refused, as the raw JSON the
    /// header describes. Nil when that save wrote, when none has been
    /// asked for, and when it was refused for an argument the core
    /// could not read. A plain read: the next save replaces the answer.
    public func saveFileErrorJSON() -> String? {
        guard let ptr = companion_file_save_error_json(handle) else { return nil }
        defer { companion_string_free(ptr) }
        return String(cString: ptr)
    }

    /// `saveFileErrorJSON()`, read. Asked straight after a save that
    /// answered false, before anything else is asked of the core.
    public func saveFileRefusal() -> FileSaveRefusal? {
        FileSaveRefusal(json: saveFileErrorJSON())
    }

    /// Whether anything else wrote the file since the core last read or
    /// wrote it. Asked on activate and before every save.
    public func checkFile(_ file: UInt64) -> FileCheck? {
        decodeJSON(FileCheck.self, from: companion_file_check(handle, file))
    }

    /// Re-read a clean file, replacing its buffer.
    @discardableResult
    public func reloadFile(_ file: UInt64) -> Bool {
        companion_file_reload(handle, file)
    }

    /// Resolve a conflict in favor of the copy on disk. Unlike an ordinary
    /// reload, this explicit resolution records the replacement in the
    /// file's core-owned edit history.
    @discardableResult
    public func resolveFileTakeTheirs(_ file: UInt64) -> Bool {
        companion_file_resolve_take_theirs(handle, file)
    }

    /// Every open file, in open order.
    public func fileRoster() -> [FileSummary] {
        decodeJSON([FileSummary].self, from: companion_file_roster_json(handle)) ?? []
    }

    /// Keep mine: the first of the three conflict resolutions. Take theirs
    /// has its own explicit resolution above, and the third is
    /// `saveFile(_:as:)`. It clears
    /// the conflict and lets the next save write over whatever is on
    /// disk, so it is called only after the person has chosen.
    ///
    /// The core binds the consent to what the path held when it was
    /// given, a copy or nothing, and withdraws it when the path is
    /// later found the other way or the buffer settles clean. False
    /// also means the choice was made on a missing conflict whose file
    /// is back and changed: the row is then in the changed conflict,
    /// and restating the roster shows it.
    @discardableResult
    public func resolveFileKeepMine(_ file: UInt64) -> Bool {
        companion_file_resolve_keep_mine(handle, file)
    }

    /// Attach the shell's bookmark for a file, as standard base64. The
    /// blob is opaque to the core: it is carried into the drafts file
    /// and handed back at the next launch. An empty string clears it.
    ///
    /// Base64 rather than raw bytes because no byte buffer has ever
    /// crossed this ABI, and a plain text file is not the place to
    /// invent the first one.
    @discardableResult
    public func setFileBookmark(_ file: UInt64, base64: String) -> Bool {
        base64.withCString { companion_file_set_bookmark(handle, file, $0) }
    }

    /// The bookmark last attached to a file, or an empty string when
    /// none was. Nil for a file the core does not hold.
    public func fileBookmarkBase64(_ file: UInt64) -> String? {
        guard let ptr = companion_file_bookmark_b64(handle, file) else { return nil }
        defer { companion_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Say that the reload notice for a file has been posted, so its
    /// roster row stops carrying `externallyReloaded`.
    @discardableResult
    public func clearFileReloadNotice(_ file: UInt64) -> Bool {
        companion_file_clear_reload_notice(handle, file)
    }

    /// Everything the last drafts save, and the hydrations after the
    /// last restore, have to tell the person about. Reading drains the
    /// list, so this is asked once, after every restored file has been
    /// hydrated, rather than polled.
    public func draftNotices() -> [DraftNotice] {
        decodeJSON([DraftNotice].self, from: companion_drafts_notices_json(handle)) ?? []
    }

    /// Seal the open file roster and every dirty file's draft to
    /// `path`, under the same content key as the state file.
    @discardableResult
    public func draftsSave(to path: String) -> Bool {
        path.withCString { companion_drafts_save(handle, $0) }
    }

    /// Restore the roster and the drafts at launch. False covers a
    /// fresh start with no file as much as a refused one.
    ///
    /// The first of two steps. It reads the drafts file and no other:
    /// every row it brings back is `pendingHydration` until
    /// `hydrateFile(_:resolvedPath:)` has settled it.
    @discardableResult
    public func draftsRestore(from path: String) -> Bool {
        path.withCString { companion_drafts_restore(handle, $0) }
    }

    /// Reconcile one restored file against the disk: the second step
    /// of a restore, made once per pending row, inside that file's own
    /// access bracket.
    ///
    /// The two steps are separate because under the sandbox a file can
    /// be read only while its own scope is open, and only the shell
    /// can open one.
    ///
    /// `resolvedPath` is where the file's bookmark resolved to, or nil
    /// when it has none or it would not resolve, in which case the
    /// path on record is read. A path that differs from the record
    /// rebinds the file to it first, unless another open file already
    /// holds that path; the roster row's path says which happened.
    ///
    /// The core puts the question off when the resolved path is the
    /// recorded path of another file that is still pending, since that
    /// file may have moved off it. The answer is then true and the row
    /// is still `pendingHydration`: the caller hydrates the others and
    /// asks again, and ends a wait that will not end by passing nil,
    /// which never waits.
    ///
    /// The core holds a clean file whose read the system refused: it
    /// is neither filled nor dropped, the answer is true, and the row
    /// is still `pendingHydration` and now `accessRefused` as well, which
    /// is `FileSummary.isHeld` and is how a hold is told from a wait.
    /// A held file may be asked again, and settles once it can be
    /// read.
    ///
    /// True when the file stands in the roster afterwards. False when
    /// it was dropped, with a notice queued for `draftNotices()`, and
    /// when nothing is open under the id.
    @discardableResult
    public func hydrateFile(_ file: UInt64, resolvedPath: String?) -> Bool {
        guard let resolvedPath else { return companion_file_hydrate(handle, file, nil) }
        return resolvedPath.withCString { companion_file_hydrate(handle, file, $0) }
    }

    /// Bind an open file to `path`, which is where a person has said
    /// the file is now, read the copy there and settle the file around
    /// it. Called inside the access that choice granted.
    ///
    /// The read settles the way a hydration's does. A file with no
    /// draft adopts the copy on disk. A draft stands: with no conflict
    /// when the copy is the one the draft was measured against, by the
    /// file's identity or by its text, and in a `changed` conflict
    /// otherwise, in which the copy on disk can now be taken. A held
    /// row is settled and is pending no longer.
    ///
    /// False leaves the file exactly as it was. It is false for a file
    /// the core does not hold, for a path another open file already
    /// holds, and for a file that will not open, which
    /// `openFileErrorJSON()` then explains in an open's own words. The
    /// middle one cannot be told from the others afterwards, so a
    /// caller that wants to name it asks the roster first.
    @discardableResult
    public func relocateFile(_ file: UInt64, to path: String) -> Bool {
        path.withCString { companion_file_relocate(handle, file, $0) }
    }

    /// Drop the drafts file at `path`. True when the path is confirmed
    /// empty, including when there was nothing there to begin with.
    @discardableResult
    public func draftsErase(at path: String) -> Bool {
        path.withCString { companion_drafts_erase(handle, $0) }
    }

    /// Detect a source-language slug without consulting or mutating a client
    /// handle. The input storage is borrowed only for the synchronous C call;
    /// the returned owned C string is copied before it is freed.
    public static func detectSourceLanguage(in data: Data) -> String? {
        let detected: UnsafeMutablePointer<CChar>? =
            if data.isEmpty {
                companion_detect_source_language(nil, 0)
            } else {
                data.withUnsafeBytes { bytes in
                    companion_detect_source_language(
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count
                    )
                }
            }

        guard let detected else { return nil }
        defer { companion_string_free(detected) }
        return String(cString: detected)
    }

    /// The C-ABI seam crate linked into this process.
    public static var ffiVersion: String {
        String(cString: companion_ffi_version())
    }

    /// The Rust domain crate linked behind the FFI seam.
    public static var coreVersion: String {
        String(cString: companion_core_version())
    }

    /// Compatibility spelling retained for clients of CompanionKit.
    @available(*, deprecated, renamed: "ffiVersion")
    public static var version: String { ffiVersion }

    // MARK: Plumbing

    /// Read and release a string allocated by the C ABI.
    private func ownedString(from ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { companion_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Decode an owned JSON C string from the seam, freeing it either way.
    private func decodeJSON<T: Decodable>(_ type: T.Type, from ptr: UnsafeMutablePointer<CChar>?) -> T? {
        guard let ptr else { return nil }
        defer { companion_string_free(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
