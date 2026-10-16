//! The tab, a durable slot, and the sheet, the page that expires in it
//! (doc 04, ADR-0017). Masking is by gesture, never by content (doc 04).

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::blocks::{BlockIndex, BlockMeta};
use crate::document::{DocRun, SheetDocument};
use crate::ledger::SizeClass;
use crate::note::Note;
use crate::secret::SecretBuffer;
use crate::ttl::{self, Ttl};

/// A 128-bit item identity: `UUIDv7` when minted, legacy bytes kept on
/// restore. The only identifier allowed in the ledger or on disk (ADR-0012).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ItemId([u8; 16]);

impl ItemId {
    /// Mint a `UUIDv7` from Unix milliseconds and the OS CSPRNG; out-of-range
    /// clocks clamp rather than fail.
    ///
    /// # Panics
    /// If the OS CSPRNG is unavailable; a fallback would be predictable.
    #[must_use]
    pub fn random() -> Self {
        let mut bytes = [0u8; 16];
        getrandom::getrandom(&mut bytes).expect("the OS CSPRNG must be available");
        Self::version_seven_at(SystemTime::now(), bytes)
    }

    fn version_seven_at(time: SystemTime, bytes: [u8; 16]) -> Self {
        let millis = time
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        Self::version_seven(millis, bytes)
    }

    fn version_seven(millis: u128, mut bytes: [u8; 16]) -> Self {
        let millis = millis.min((1_u128 << 48) - 1);
        // RFC 9562 §5.7 layout.
        bytes[..6].copy_from_slice(&millis.to_be_bytes()[10..]);
        bytes[6] = (bytes[6] & 0x0F) | 0x70;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        Self(bytes)
    }

    /// The raw 16 bytes, for writing into a snapshot.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Rebuild an identity from its raw bytes (restore path).
    #[must_use]
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    /// Parse the 8-4-4-4-12 hex form, the inverse of `Display`.
    pub(crate) fn parse(text: &str) -> Option<Self> {
        if text.len() != 36 {
            return None;
        }
        let hex: Vec<u32> = text
            .bytes()
            .filter(|byte| *byte != b'-')
            .map(|byte| (byte as char).to_digit(16))
            .collect::<Option<_>>()?;
        if hex.len() != 32 {
            return None;
        }
        let mut bytes = [0u8; 16];
        for (index, pair) in hex.chunks(2).enumerate() {
            bytes[index] = ((pair[0] << 4) | pair[1]) as u8;
        }
        Some(Self(bytes))
    }
}

/// Lowercase hyphenated 8-4-4-4-12 hex, the form that crosses the FFI seam.
impl std::fmt::Display for ItemId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                f.write_str("-")?;
            }
            write!(f, "{byte:02x}")?;
        }
        Ok(())
    }
}

/// Opaque, monotonically assigned sheet identifier. `0` is never issued.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SheetId(pub(crate) u64);

impl SheetId {
    /// The raw id, for carrying across an FFI seam.
    #[must_use]
    pub fn raw(self) -> u64 {
        self.0
    }

    /// Rebuild an id from its raw form; an unknown id just misses on lookup.
    #[must_use]
    pub fn from_raw(raw: u64) -> Self {
        Self(raw)
    }
}

/// Opaque, monotonically assigned tab identifier, distinct from the
/// page's [`SheetId`] (ADR-0017). `0` is never issued.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TabId(pub(crate) u64);

impl TabId {
    /// The raw id, for carrying across an FFI seam.
    #[must_use]
    pub fn raw(self) -> u64 {
        self.0
    }

    /// Rebuild an id from its raw form; an unknown id just misses on lookup.
    #[must_use]
    pub fn from_raw(raw: u64) -> Self {
        Self(raw)
    }
}

/// Opaque, monotonically assigned chip identifier, unique across all
/// sheets. `0` is never issued.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChipId(pub(crate) u64);

impl ChipId {
    /// The raw id, for carrying across an FFI seam.
    #[must_use]
    pub fn raw(self) -> u64 {
        self.0
    }

    /// Rebuild an id from its raw form.
    #[must_use]
    pub fn from_raw(raw: u64) -> Self {
        Self(raw)
    }
}

/// One run of the body's projection, cached from the sheet's document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// Visible text, exactly as typed.
    Ink(String),
    /// A sealed chip sits here.
    Chip(ChipId),
}

/// What a chip's bytes are, described without reading them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChipMeta {
    /// UTF-8 text.
    Text {
        /// Characters, as the size label counts them.
        chars: usize,
        /// Lines, after trimming trailing newlines.
        lines: usize,
    },
    /// An image; only the container format is sniffed.
    Image {
        /// Encoded byte length.
        byte_len: usize,
    },
}

/// A chip's conceal: only the receipt id is kept (doc 03 §5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conceal {
    /// Server receipt id, kept to offer burn-remote on this chip.
    pub receipt_id: String,
}

/// The longest sealed name, in characters (ADR-0042 point 1).
pub const NAME_CAP: usize = 64;

/// Why a sealed name was refused. A refusal leaves the name as it was.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameRefusal {
    /// No such chip.
    UnknownChip,
    /// Longer than [`NAME_CAP`] once trimmed.
    TooLong,
    /// Outside `[A-Za-z_][A-Za-z0-9_]*`.
    OutsideCharset,
}

impl std::fmt::Display for NameRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NameRefusal::UnknownChip => write!(f, "no such sealed object"),
            NameRefusal::TooLong => write!(f, "a name is at most {NAME_CAP} characters"),
            NameRefusal::OutsideCharset => write!(
                f,
                "a name is letters, digits and underscores, and does not start with a digit"
            ),
        }
    }
}

impl std::error::Error for NameRefusal {}

/// Judge a draft name: trimmed, empty clears (`None`), anything else must
/// be [`NAME_CAP`] characters of `[A-Za-z_][A-Za-z0-9_]*`
/// (ADR-0042 point 1).
///
/// # Errors
/// [`NameRefusal::OutsideCharset`], judged first, or [`NameRefusal::TooLong`].
pub fn judge_name(draft: &str) -> Result<Option<&str>, NameRefusal> {
    let name = draft.trim();
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return Ok(None);
    };
    let leads = first.is_ascii_alphabetic() || first == '_';
    if !leads || !chars.all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(NameRefusal::OutsideCharset);
    }
    // ASCII by now, so bytes count characters.
    if name.len() > NAME_CAP {
        return Err(NameRefusal::TooLong);
    }
    Ok(Some(name))
}

/// A sealed chip: secret bytes, the non-secret face it shows, and the
/// typed name and note beside it (ADR-0043 point 1).
pub struct SealedChip {
    pub(crate) id: ChipId,
    pub(crate) uuid: ItemId,
    pub(crate) bytes: SecretBuffer,
    pub(crate) meta: ChipMeta,
    pub(crate) excerpt: String,
    pub(crate) size_label: String,
    pub(crate) conceal: Option<Conceal>,
    pub(crate) name: Option<String>,
    /// Made by its first accepted edit.
    pub(crate) note: Option<Note>,
    /// Whether its sentinel has stood in a body; the first standing is the
    /// seal's, which no step may take back (D-30).
    pub(crate) stood: bool,
}

impl SealedChip {
    /// Seal UTF-8 text; the face is computed once, here.
    pub(crate) fn text(id: ChipId, text: &str) -> Self {
        Self::text_with_uuid(id, ItemId::random(), text)
    }

    /// Seal text under an existing identity (restore path).
    pub(crate) fn text_with_uuid(id: ChipId, uuid: ItemId, text: &str) -> Self {
        let (excerpt, size_label, meta) = text_face(text);
        Self {
            id,
            uuid,
            bytes: SecretBuffer::from_text(text),
            meta,
            excerpt,
            size_label,
            conceal: None,
            name: None,
            note: None,
            stood: false,
        }
    }

    /// Seal encoded image bytes. Not `mlock`ed (doc 05), but still zeroized.
    pub(crate) fn image(id: ChipId, bytes: Vec<u8>) -> Self {
        Self::image_with_uuid(id, ItemId::random(), bytes)
    }

    /// Seal image bytes under an existing identity (restore path).
    pub(crate) fn image_with_uuid(id: ChipId, uuid: ItemId, bytes: Vec<u8>) -> Self {
        let byte_len = bytes.len();
        let excerpt = format!("{} image", sniff_image_kind(&bytes));
        Self {
            id,
            uuid,
            bytes: SecretBuffer::new_unlocked(bytes),
            meta: ChipMeta::Image { byte_len },
            excerpt,
            size_label: SizeClass::of(byte_len).to_string(),
            conceal: None,
            name: None,
            note: None,
            stood: false,
        }
    }

    /// A clone under a new identity: the payload copied core-side at its exact size, with
    /// no receipt, name or note; resolution then sets the envelope's (Law 0001, sealed fragment).
    pub(crate) fn duplicate(&self, id: ChipId) -> Self {
        let mut clone = match self.meta {
            ChipMeta::Text { .. } => Self::text(
                id,
                std::str::from_utf8(self.bytes.expose()).expect("a text chip is sealed from UTF-8"),
            ),
            ChipMeta::Image { .. } => Self::image(id, self.bytes.expose().to_vec()),
        };
        // Its first standing is a paste, which a step may take back.
        clone.stood = true;
        clone
    }

    /// Identifier.
    #[must_use]
    pub fn id(&self) -> ChipId {
        self.id
    }

    /// The item identity, the only chip identifier that leaves the process.
    #[must_use]
    pub fn uuid(&self) -> ItemId {
        self.uuid
    }

    /// What the bytes are, described without reading them.
    #[must_use]
    pub fn meta(&self) -> ChipMeta {
        self.meta
    }

    /// The mechanical excerpt, the only rendering the content ever gets.
    #[must_use]
    pub fn excerpt(&self) -> &str {
        &self.excerpt
    }

    /// The ledger's size class, never an exact length (D-29).
    #[must_use]
    pub fn size_label(&self) -> &str {
        &self.size_label
    }

    /// Conceal annotation, if this chip became a one-time link.
    #[must_use]
    pub fn conceal(&self) -> Option<&Conceal> {
        self.conceal.as_ref()
    }

    /// The typed name, if one was given.
    #[must_use]
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    /// Whether a note holds anything but whitespace: the block's doorway.
    #[must_use]
    pub fn has_note(&self) -> bool {
        self.note.as_ref().is_some_and(Note::has_content)
    }
}

/// One sheet's clock; there are no per-chip timers (doc 04).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SheetClock {
    /// Draining toward `deadline`.
    Running {
        /// The instant the sheet expires.
        deadline: Instant,
    },
    /// Frozen by the pause gesture until `until`.
    Held {
        /// When the hold lapses and the page is a regular page again.
        until: Instant,
        /// The remaining life frozen at the moment of the hold.
        frozen_remaining: Duration,
        /// When the hold began (total-held accounting, open question №8).
        started: Instant,
        /// Topped up to 24 hours, so the next press releases (doc 04). Stored
        /// because a restore cannot infer it from the hold's length.
        topped_up: bool,
    },
}

/// Whether rung-transition compaction runs inline or waits for every
/// attached device to confirm (issue #101). Never persisted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CeremonyState {
    /// No peer is attached: compaction runs inline at the transition.
    Immediate,
    /// Peers attached: a transition marks the ceremony due instead.
    Deferred {
        /// A transition came due since the last ceremony; this device proposes.
        due: bool,
    },
}

/// A sheet: the operation-logged body, its chips, and one countdown.
pub struct Sheet {
    pub(crate) id: SheetId,
    pub(crate) uuid: ItemId,
    /// First non-blank line, re-derived on edit; never persisted (ADR-0017).
    pub(crate) derived_title: Option<String>,
    /// Unix ms at the page's creation, not the tab's.
    pub(crate) created_wall_ms: u64,
    /// The body (ADR-0013): source of truth for ink and chip positions.
    pub(crate) document: SheetDocument,
    /// Projection of `document`, rebuilt by [`Sheet::rebuild_segments`].
    pub(crate) segments: Vec<Segment>,
    /// Paragraph identities, kept across edits (ADR-0013).
    pub(crate) blocks: BlockIndex,
    /// Chips whose sentinels stand in the body.
    pub(crate) chips: Vec<SealedChip>,
    /// Chips the body no longer shows, kept on the page's clock
    /// (ADR-0046 point 1).
    pub(crate) detached: Vec<SealedChip>,
    pub(crate) clock: SheetClock,
    /// Held time from lapsed holds (open question №8).
    pub(crate) total_held: Duration,
    /// Inline or deferred compaction (issue #101); `Immediate` until sync.
    pub(crate) ceremony: CeremonyState,
}

impl Sheet {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> SheetId {
        self.id
    }

    /// The item identity, the only page identifier that leaves the process.
    #[must_use]
    pub fn uuid(&self) -> ItemId {
        self.uuid
    }

    /// The cached projection of the body, in document order.
    #[must_use]
    pub fn segments(&self) -> &[Segment] {
        &self.segments
    }

    /// Detach each chip whose sentinel left the body and reattach each
    /// detached chip whose sentinel stands again (ADR-0046 point 1).
    pub(crate) fn settle_roster(&mut self) {
        let live = self.document.live_chips();
        let (standing, gone): (Vec<_>, Vec<_>) = std::mem::take(&mut self.chips)
            .into_iter()
            .partition(|chip| live.contains(&chip.uuid));
        let (back, away): (Vec<_>, Vec<_>) = std::mem::take(&mut self.detached)
            .into_iter()
            .partition(|chip| live.contains(&chip.uuid));
        self.chips = standing;
        self.chips.extend(back);
        for chip in &mut self.chips {
            chip.stood = true;
        }
        self.detached = away;
        self.detached.extend(gone);
    }

    /// Rebuild `segments` from the document. A sentinel matching no owned
    /// chip is dropped rather than rendered.
    pub(crate) fn rebuild_segments(&mut self) {
        self.segments = self
            .document
            .runs()
            .into_iter()
            .filter_map(|run| match run {
                DocRun::Ink(text) => Some(Segment::Ink(text)),
                DocRun::Chip(uuid) => self
                    .chips
                    .iter()
                    .find(|chip| chip.uuid == uuid)
                    .map(|chip| Segment::Chip(chip.id)),
            })
            .collect();
    }

    /// Re-take anchors, or rebuild the index with fresh identities when it no
    /// longer describes the body. Every mutation path ends here.
    pub(crate) fn settle_blocks(&mut self) {
        // Before the check: narration reads widths, so it cannot open the trailing block.
        self.blocks.reopen_trailing_block(&self.document);
        if self.blocks.matches(&self.document) {
            self.blocks.retake_anchors(&self.document);
        } else {
            let floor = self.blocks.compaction_frontier();
            self.blocks = BlockIndex::for_document(&self.document);
            self.blocks.note_compaction(floor);
        }
    }

    /// The compaction ceremony (ADR-0013): freeze provenance into the blocks,
    /// then rebirth the document without its history. Chips pass through.
    pub(crate) fn compact(&mut self) {
        // Read while the log exists: a deletion leaves no character to carry it.
        let frontier = self.document.latest_timestamp();
        self.blocks.graduate(&self.document);
        self.document.compact();
        self.rebuild_segments();
        self.settle_blocks();
        // After the settle, so a rebuilt index inherits the floor.
        self.blocks.note_compaction(frontier);
    }

    /// Compact now when solo, or mark the ceremony due when peers are
    /// attached (issue #101). Every transition calls this, not `compact`.
    pub(crate) fn compact_or_defer(&mut self) {
        match self.ceremony {
            CeremonyState::Immediate => self.compact(),
            CeremonyState::Deferred { .. } => {
                self.ceremony = CeremonyState::Deferred { due: true };
            }
        }
    }

    /// Per-block identity and stamps (Unix seconds), in document order; no
    /// content (ADR-0013).
    #[must_use]
    pub fn blocks_meta(&self) -> Vec<BlockMeta> {
        self.blocks.metas(&self.document)
    }

    /// Newest change in the log or in compacted stamps, Unix seconds; `None`
    /// for an untouched body.
    #[must_use]
    pub fn modified_s(&self) -> Option<i64> {
        self.document
            .latest_timestamp()
            .max(self.blocks.max_materialized_modified())
    }

    /// The chips this sheet owns, in seal order.
    pub fn chips(&self) -> impl Iterator<Item = &SealedChip> {
        self.chips.iter()
    }

    /// A chip by id.
    #[must_use]
    pub fn chip(&self, id: ChipId) -> Option<&SealedChip> {
        self.chips.iter().find(|c| c.id == id)
    }

    /// The chips the body no longer shows, kept for undo and for a paste
    /// that names them (ADR-0046 point 1).
    pub fn detached(&self) -> impl Iterator<Item = &SealedChip> {
        self.detached.iter()
    }

    /// A chip by id, attached or detached.
    pub(crate) fn owned_chip(&self, id: ChipId) -> Option<&SealedChip> {
        self.chips.iter().chain(&self.detached).find(|c| c.id == id)
    }

    /// Every identity the page owns, attached or detached.
    pub(crate) fn owned_uuids(&self) -> Vec<ItemId> {
        self.chips
            .iter()
            .chain(&self.detached)
            .map(|chip| chip.uuid)
            .collect()
    }

    /// Number of chips on the sheet.
    #[must_use]
    pub fn chip_count(&self) -> usize {
        self.chips.len()
    }

    /// Whether the clock is held by the pause gesture at `now`.
    #[must_use]
    pub fn is_held(&self, now: Instant) -> bool {
        match self.clock {
            SheetClock::Running { .. } => false,
            SheetClock::Held { until, .. } => now < until,
        }
    }

    /// Total held time through `now` (open question №8; no ceiling enforced).
    #[must_use]
    pub fn total_held(&self, now: Instant) -> Duration {
        let live = match self.clock {
            SheetClock::Running { .. } => Duration::ZERO,
            SheetClock::Held { until, started, .. } => {
                now.min(until).saturating_duration_since(started)
            }
        };
        self.total_held + live
    }

    /// Whether the live hold is topped up, so the next press releases it.
    #[must_use]
    pub fn hold_topped_up(&self, now: Instant) -> bool {
        match self.clock {
            SheetClock::Running { .. } => false,
            SheetClock::Held {
                until, topped_up, ..
            } => now < until && topped_up,
        }
    }

    /// How much longer the hold lasts at `now`; zero when not held.
    #[must_use]
    pub fn hold_remaining(&self, now: Instant) -> Duration {
        match self.clock {
            SheetClock::Running { .. } => Duration::ZERO,
            SheetClock::Held { until, .. } => until.saturating_duration_since(now),
        }
    }

    /// Remaining life: frozen while held, draining after the hold lapses.
    #[must_use]
    pub fn remaining(&self, now: Instant) -> Duration {
        match self.clock {
            SheetClock::Running { deadline } => deadline.saturating_duration_since(now),
            SheetClock::Held {
                until,
                frozen_remaining,
                ..
            } => {
                if now < until {
                    frozen_remaining
                } else {
                    (until + frozen_remaining).saturating_duration_since(now)
                }
            }
        }
    }

    /// Whether the countdown has run out at `now`, whether or not a sweep
    /// has taken the page yet (Law 0001, expiry row).
    #[must_use]
    pub fn is_due(&self, now: Instant) -> bool {
        self.remaining(now).is_zero()
    }

    /// When this page's clock next changes: `now` once [`Sheet::is_due`]
    /// holds, else its hold's lapse or its deadline (Law 0001, expiry row).
    #[must_use]
    pub(crate) fn next_event(&self, now: Instant) -> Instant {
        if self.is_due(now) {
            return now;
        }
        match self.clock {
            SheetClock::Running { deadline } => deadline,
            SheetClock::Held {
                until,
                frozen_remaining,
                ..
            } => {
                if now < until {
                    until
                } else {
                    until + frozen_remaining
                }
            }
        }
    }

    /// The countdown label text ("3h 40m").
    #[must_use]
    pub fn remaining_label(&self, now: Instant) -> String {
        ttl::human_remaining(self.remaining(now))
    }

    /// Fraction of the gauge still full, in `0.0..=1.0`, against the tab's
    /// rung (ADR-0017).
    #[must_use]
    pub fn fraction_remaining(&self, rung: Ttl, now: Instant) -> f32 {
        let total = rung.duration().as_secs_f32();
        if total <= 0.0 {
            return 0.0;
        }
        (self.remaining(now).as_secs_f32() / total).clamp(0.0, 1.0)
    }

    /// Under an hour left (the ember gauge, doc 04).
    #[must_use]
    pub fn last_hour(&self, now: Instant) -> bool {
        let remaining = self.remaining(now);
        !remaining.is_zero() && remaining <= Duration::from_secs(60 * 60)
    }

    /// The first typed line, markdown stripped; `None` until one is typed.
    #[must_use]
    pub fn derived_title(&self) -> Option<&str> {
        self.derived_title.as_deref()
    }

    /// Unix ms at this page's creation; neither expiry nor the placeholder reads it.
    #[must_use]
    pub fn created_wall_ms(&self) -> u64 {
        self.created_wall_ms
    }

    /// A non-whitespace line or a standing chip: what the page shows. The
    /// ledger also records a page holding only detached chips.
    #[must_use]
    pub fn has_content(&self) -> bool {
        !self.chips.is_empty()
            || self.segments.iter().any(|segment| match segment {
                Segment::Ink(text) => !text.trim().is_empty(),
                Segment::Chip(_) => false,
            })
    }

    /// The local day this page was born on, by its own stamp, not the tab's.
    #[must_use]
    pub fn local_day(&self, utc_offset_seconds: i32) -> i64 {
        local_day(self.created_wall_ms, utc_offset_seconds)
    }
}

/// A tab: the durable slot a page stands in. Nothing here may derive from
/// page content (ADR-0017).
pub struct Tab {
    pub(crate) id: TabId,
    pub(crate) uuid: ItemId,
    /// Unix ms the slot opened; the placeholder renders from it.
    pub(crate) created_wall_ms: u64,
    /// The name the user typed, at most [`TITLE_CAP`] chars; never derived.
    pub(crate) name: Option<String>,
    /// The rung new pages start at. No clock: a tab never expires.
    pub(crate) rung: Ttl,
    /// The page in the slot; `None` once it expires or before the first.
    pub(crate) page: Option<Sheet>,
}

impl Tab {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> TabId {
        self.id
    }

    /// The item identity, minted when this tab was opened.
    #[must_use]
    pub fn uuid(&self) -> ItemId {
        self.uuid
    }

    /// Unix epoch milliseconds when this tab was opened.
    #[must_use]
    pub fn created_wall_ms(&self) -> u64 {
        self.created_wall_ms
    }

    /// The name the user typed, if they typed one.
    #[must_use]
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    /// The rung pages born in this slot start at.
    #[must_use]
    pub fn rung(&self) -> Ttl {
        self.rung
    }

    /// The page standing in this slot, if one is.
    #[must_use]
    pub fn page(&self) -> Option<&Sheet> {
        self.page.as_ref()
    }

    /// Whether this slot holds the page with that id.
    pub(crate) fn holds(&self, page: SheetId) -> bool {
        self.page.as_ref().is_some_and(|held| held.id == page)
    }

    /// The user's name, else the page's derived title, else the placeholder
    /// from the tab's own stamp, so an unnamed slot keeps its label.
    #[must_use]
    pub fn label(&self, utc_offset_seconds: i32) -> String {
        match self.label_source() {
            LabelSource::Name => self
                .name
                .clone()
                .expect("label_source promised Name has a name"),
            LabelSource::Derived => self
                .page
                .as_ref()
                .and_then(|page| page.derived_title.clone())
                .expect("label_source promised Derived has a derived title"),
            LabelSource::Placeholder => placeholder_title(self.created_wall_ms, utc_offset_seconds),
        }
    }

    /// Which of [`Tab::label`]'s steps answered.
    #[must_use]
    pub fn label_source(&self) -> LabelSource {
        if self.name.is_some() {
            LabelSource::Name
        } else if self
            .page
            .as_ref()
            .is_some_and(|page| page.derived_title.is_some())
        {
            LabelSource::Derived
        } else {
            LabelSource::Placeholder
        }
    }
}

/// Which step of [`Tab::label`] a label came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LabelSource {
    /// The name the user typed.
    Name,
    /// The live page's first typed line.
    Derived,
    /// The tab's own `MMDD-HHmm` stamp, because nothing was typed.
    Placeholder,
}

impl LabelSource {
    /// The word the seam carries.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Derived => "derived",
            Self::Placeholder => "placeholder",
        }
    }
}

/// Counted in `char`s so a multibyte scalar is never split.
pub(crate) const TITLE_CAP: usize = 80;

/// First non-blank ink line, markdown stripped, capped at [`TITLE_CAP`].
/// Fence rules are skipped and fenced code is taken as typed (D-12).
/// No fallback here; that is the tab's (ADR-0017).
pub(crate) fn derive_title(segments: &[Segment]) -> Option<String> {
    let mut fence: Option<Fence> = None;
    let mut result: Option<String> = None;
    'outer: for text in segments.iter().filter_map(|s| match s {
        Segment::Ink(text) => Some(text),
        Segment::Chip(_) => None,
    }) {
        for line in text.lines() {
            match fence {
                Some(open) if closes_fence(line, open) => fence = None,
                Some(_) => {
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        result = Some(trimmed.to_string());
                        break 'outer;
                    }
                }
                None => {
                    if let Some(open) = opens_fence(line) {
                        fence = Some(open);
                        continue;
                    }
                    let stripped = strip_markdown(line);
                    if !stripped.is_empty() {
                        result = Some(stripped);
                        break 'outer;
                    }
                }
            }
        }
    }
    result.map(|line| line.chars().take(TITLE_CAP).collect())
}

/// An open fence. A closer must match its marker and be at least as long
/// (`CommonMark` §4.5).
#[derive(Clone, Copy)]
struct Fence {
    marker: char,
    length: usize,
}

/// Up to three spaces of indent, then three or more backticks or tildes.
fn opens_fence(line: &str) -> Option<Fence> {
    let indent = line.chars().take_while(|c| *c == ' ').count();
    if indent >= 4 {
        return None;
    }
    let rest = &line[indent..];
    let marker = rest.chars().next()?;
    if marker != '`' && marker != '~' {
        return None;
    }
    let length = rest.chars().take_while(|c| *c == marker).count();
    if length < 3 {
        return None;
    }
    Some(Fence { marker, length })
}

/// A long-enough run of the opener's marker, then only whitespace.
fn closes_fence(line: &str, opener: Fence) -> bool {
    let indent = line.chars().take_while(|c| *c == ' ').count();
    if indent >= 4 {
        return false;
    }
    let rest = &line[indent..];
    let marker_count = rest.chars().take_while(|c| *c == opener.marker).count();
    if marker_count < opener.length {
        return false;
    }
    rest[marker_count..].chars().all(char::is_whitespace)
}

/// Days since the Unix epoch in local time, via the caller's UTC offset.
/// The crate's one day-bucketing function; the placeholder's `MMDD` uses it.
#[must_use]
pub fn local_day(wall_ms: u64, utc_offset_seconds: i32) -> i64 {
    local_seconds(wall_ms, utc_offset_seconds).div_euclid(86_400)
}

fn local_seconds(wall_ms: u64, utc_offset_seconds: i32) -> i64 {
    let epoch_seconds = i64::try_from(wall_ms / 1000).unwrap_or(i64::MAX);
    epoch_seconds.saturating_add(i64::from(utc_offset_seconds))
}

/// `MMDD-HHmm` in local time, from the tab's creation stamp.
pub(crate) fn placeholder_title(wall_ms: u64, utc_offset_seconds: i32) -> String {
    let days = local_day(wall_ms, utc_offset_seconds);
    let secs_of_day = local_seconds(wall_ms, utc_offset_seconds).rem_euclid(86_400);
    let (month, day) = civil_month_day(days);
    let hour = secs_of_day / 3_600;
    let minute = (secs_of_day % 3_600) / 60;
    format!("{month:02}{day:02}-{hour:02}{minute:02}")
}

/// Month and day from days since the epoch (Hinnant's `civil_from_days`).
fn civil_month_day(days_since_epoch: i64) -> (i64, i64) {
    // Shift the epoch to 0000-03-01, the start of a 400-year era.
    let z = days_since_epoch + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z - era * 146_097; // [0, 146096]
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let march_month = (5 * day_of_year + 2) / 153; // [0, 11], 0 is March
    let day = day_of_year - (153 * march_month + 2) / 5 + 1; // [1, 31]
    let month = if march_month < 10 {
        march_month + 3
    } else {
        march_month - 9
    };
    (month, day)
}

/// Reduce a first line of markdown to its name. Not a parser.
fn strip_markdown(line: &str) -> String {
    let mut rest = line.trim();

    // Blockquote markers, however deeply nested: "> > note" → "note".
    while let Some(after) = rest.strip_prefix('>') {
        rest = after.trim_start();
    }

    rest = strip_list_bullet(rest);
    rest = strip_heading_markup(rest);

    let bare: String = rest
        .chars()
        .filter(|c| !matches!(c, '`' | '*' | '_' | '~'))
        .collect();

    flatten_links(&bare).trim().to_string()
}

/// One leading list bullet: `- item`, `* item`, `+ item`, `3. item`.
/// The marker must be followed by whitespace, so `-30C` is content.
fn strip_list_bullet(line: &str) -> &str {
    if let Some(rest) = line.strip_prefix(['-', '*', '+'])
        && rest.starts_with(char::is_whitespace)
    {
        return rest.trim_start();
    }
    let digits = line.len() - line.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits > 0
        && let Some(rest) = line[digits..].strip_prefix('.')
        && rest.starts_with(char::is_whitespace)
    {
        return rest.trim_start();
    }
    line
}

/// Strip heading hashes; a `#hashtag` with no space after stays.
fn strip_heading_markup(line: &str) -> &str {
    let trimmed = line.trim();
    let hashes = trimmed.len() - trimmed.trim_start_matches('#').len();
    if hashes > 0 {
        let rest = &trimmed[hashes..];
        if rest.starts_with(char::is_whitespace) {
            return rest.trim();
        }
        if rest.is_empty() {
            return "";
        }
    }
    trimmed
}

/// `[label](url)` becomes `label`; an unterminated link stays as typed.
fn flatten_links(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        let after_open = &rest[open + 1..];
        let Some(label_end) = after_open.find("](") else {
            break;
        };
        let target = &after_open[label_end + 2..];
        let Some(target_end) = target.find(')') else {
            break;
        };
        out.push_str(&rest[..open]);
        out.push_str(&after_open[..label_end]);
        rest = &target[target_end + 1..];
    }
    out.push_str(rest);
    out
}

/// The mechanical excerpt rule (doc 04), returning (excerpt, size label,
/// meta). The label is a size class, never a count (D-29).
fn text_face(text: &str) -> (String, String, ChipMeta) {
    let size_label = SizeClass::of(text.len()).to_string();
    let trimmed = text.trim_end_matches('\n');
    let lines = trimmed.split('\n').count().max(1);
    if lines > 1 {
        let head: String = trimmed
            .split('\n')
            .next()
            .unwrap_or_default()
            .chars()
            .take(17)
            .collect();
        let chars = trimmed.chars().count();
        return (
            format!("{head}…"),
            size_label,
            ChipMeta::Text { chars, lines },
        );
    }
    let n = trimmed.chars().count();
    let meta = ChipMeta::Text { chars: n, lines };
    let budget = (n / 3).min(24);
    if budget < 1 {
        return ("···".to_string(), size_label, meta);
    }
    // 60/40 head–tail, head rounded up: max(1, ⌈0.6·B⌉) = max(1, ⌈3B/5⌉).
    let head_len = (3 * budget).div_ceil(5).max(1);
    let tail_len = budget - head_len;
    let head: String = trimmed.chars().take(head_len).collect();
    let tail: String = trimmed.chars().skip(n.saturating_sub(tail_len)).collect();
    (format!("{head}…{tail}"), size_label, meta)
}

/// Image container from magic bytes; never a decode.
fn sniff_image_kind(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "PNG"
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "JPEG"
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        "TIFF"
    } else if bytes.starts_with(b"GIF8") {
        "GIF"
    } else {
        "an"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::{Clock, ManualClock};

    fn face(text: &str) -> (String, String) {
        let (excerpt, label, _) = text_face(text);
        (excerpt, label)
    }

    #[test]
    fn item_ids_are_version_seven_with_current_unix_milliseconds() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..1000 {
            let before = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();
            let id = ItemId::random();
            let after = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();
            let bytes = *id.as_bytes();
            let mut timestamp = [0u8; 8];
            timestamp[2..].copy_from_slice(&bytes[..6]);
            let millis = u128::from(u64::from_be_bytes(timestamp));
            assert!((before..=after).contains(&millis), "Unix milliseconds");
            assert_eq!(bytes[6] >> 4, 0x7, "version nibble");
            assert_eq!(bytes[8] >> 6, 0b10, "variant bits");
            assert!(seen.insert(bytes), "a minted identity repeated");
        }
    }

    #[test]
    fn item_id_v7_matches_rfc_9562_vector_and_orders_distinct_milliseconds() {
        let random = [
            0, 0, 0, 0, 0, 0, 0xcc, 0xc3, 0x18, 0xc4, 0xdc, 0x0c, 0x0c, 0x07, 0x39, 0x8f,
        ];
        let id = ItemId::version_seven(0x017f_22e2_79b0, random);
        assert_eq!(id.to_string(), "017f22e2-79b0-7cc3-98c4-dc0c0c07398f");
        let later = ItemId::version_seven(0x017f_22e2_79b1, [0; 16]);
        assert!(id < later);
        // Restoring an older UUIDv4 retains every original bit.
        let mut legacy = [0x44; 16];
        legacy[8] = 0x84;
        assert_eq!(ItemId::from_bytes(legacy).as_bytes(), &legacy);
    }

    #[test]
    fn item_id_renders_as_hyphenated_lowercase_hex() {
        let id = ItemId::random();
        let text = id.to_string();
        assert_eq!(text.len(), 36);
        let hyphens: Vec<usize> = text
            .char_indices()
            .filter_map(|(i, c)| (c == '-').then_some(i))
            .collect();
        assert_eq!(hyphens, vec![8, 13, 18, 23]);
        assert!(
            text.chars()
                .all(|c| c == '-' || c.is_ascii_digit() || ('a'..='f').contains(&c))
        );
        assert_eq!(ItemId::from_bytes(*id.as_bytes()), id);
    }

    #[test]
    fn an_item_id_parses_back_from_the_form_it_displays() {
        let id = ItemId::random();
        assert_eq!(ItemId::parse(&id.to_string()), Some(id));
        assert_eq!(ItemId::parse(&id.to_string().to_uppercase()), Some(id));
        assert_eq!(ItemId::parse(""), None);
        assert_eq!(ItemId::parse("017f22e2-79b0-7cc3-98c4-dc0c0c07398"), None);
        assert_eq!(ItemId::parse("017f22e2-79b0-7cc3-98c4-dc0c0c07398g"), None);
    }

    #[test]
    fn item_id_clock_boundaries_clamp_without_changing_random_bits() {
        let random = [0xAB; 16];
        let earliest = ItemId::version_seven_at(UNIX_EPOCH - Duration::from_millis(1), random);
        let epoch = ItemId::version_seven_at(UNIX_EPOCH, random);
        assert_eq!(earliest, epoch);
        assert_eq!(&earliest.as_bytes()[..6], &[0; 6]);
        let submillisecond =
            ItemId::version_seven_at(UNIX_EPOCH + Duration::from_nanos(999_999), random);
        assert_eq!(submillisecond, epoch);
        let one_millisecond =
            ItemId::version_seven_at(UNIX_EPOCH + Duration::from_millis(1), random);
        assert_eq!(&one_millisecond.as_bytes()[..6], &[0, 0, 0, 0, 0, 1]);

        let maximum_millis = (1_u64 << 48) - 1;
        let maximum =
            ItemId::version_seven_at(UNIX_EPOCH + Duration::from_millis(maximum_millis), random);
        let beyond = ItemId::version_seven_at(
            UNIX_EPOCH + Duration::from_millis(maximum_millis + 1),
            random,
        );
        assert_eq!(beyond, maximum);
        assert_eq!(ItemId::version_seven(u128::MAX, random), maximum);
        assert_eq!(&maximum.as_bytes()[..6], &[0xFF; 6]);
        assert_eq!(&earliest.as_bytes()[6..], &maximum.as_bytes()[6..]);
        assert_eq!(earliest.as_bytes()[6] >> 4, 7);
        assert_eq!(earliest.as_bytes()[8] >> 6, 2);
    }

    #[test]
    fn a_sealed_chip_carries_its_own_uuid() {
        let first = SealedChip::text(ChipId(1), "same text");
        let second = SealedChip::text(ChipId(2), "same text");
        assert_ne!(first.uuid(), second.uuid());
    }

    #[test]
    fn single_line_excerpt_splits_sixty_forty() {
        // 40 chars: budget 13, head 8, tail 5. Assembled at runtime so the
        // secret scan never sees a PAT.
        let token = String::from("ghp_") + "4kQ9wXbGpT2mR8vLcY3n" + "Z6qF1sJde0H5jK7a";
        assert_eq!(token.chars().count(), 40);
        let (excerpt, label) = face(&token);
        assert_eq!(label, "tiny");
        assert_eq!(excerpt, "ghp_4kQ9…5jK7a");
        assert_eq!(excerpt.chars().filter(|c| *c != '…').count(), 13);
    }

    #[test]
    fn long_single_line_caps_the_budget_at_24() {
        let long: String = "x".repeat(200);
        let (excerpt, label) = face(&long);
        assert_eq!(label, "small");
        // budget 24: head ⌈14.4⌉ = 15, tail 9.
        assert_eq!(excerpt.chars().filter(|c| *c != '…').count(), 24);
        assert!(excerpt.starts_with(&"x".repeat(15)));
    }

    #[test]
    fn too_short_to_split_shows_dots() {
        let (excerpt, label) = face("ab");
        assert_eq!(excerpt, "···");
        assert_eq!(label, "tiny");
    }

    #[test]
    fn three_chars_reveal_exactly_one() {
        // n=3 → budget 1 → head 1, tail 0.
        let (excerpt, label) = face("abc");
        assert_eq!(excerpt, "a…");
        assert_eq!(label, "tiny");
    }

    #[test]
    fn multi_line_shows_first_line_and_a_size_class() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END-----";
        let (excerpt, label) = face(key);
        assert_eq!(excerpt, "-----BEGIN OPENSS…");
        assert_eq!(label, SizeClass::of(key.len()).to_string());
        assert!(!label.contains("ln"), "a line count is a count: {label}");
    }

    #[test]
    fn trailing_newlines_do_not_shape_the_excerpt() {
        let (excerpt, label) = face("abc\n");
        assert_eq!(excerpt, "a…");
        assert_eq!(label, "tiny");
        let (excerpt, _) = face("one\ntwo\n\n");
        assert_eq!(excerpt, "one…");
    }

    #[test]
    fn excerpt_reveals_no_middle() {
        let secret = "AAAA-the-middle-is-hidden-ZZZZ";
        let (excerpt, _) = face(secret);
        assert!(
            !excerpt.contains("middle"),
            "middle must stay hidden: {excerpt}"
        );
    }

    #[test]
    fn image_face_is_metadata_only() {
        let png = {
            let mut b = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
            b.resize(212 * 1024, 0);
            b
        };
        let chip = SealedChip::image(ChipId(1), png);
        assert_eq!(chip.excerpt(), "PNG image");
        assert_eq!(chip.size_label(), "large");
        assert_eq!(
            chip.meta(),
            ChipMeta::Image {
                byte_len: 212 * 1024
            }
        );
    }

    #[test]
    fn unknown_image_kind_stays_generic() {
        let chip = SealedChip::image(ChipId(1), vec![0u8; 64]);
        assert_eq!(chip.excerpt(), "an image");
        assert_eq!(chip.size_label(), "small");
    }

    /// `ManualClock::new()`'s stamp, 2023-11-14 22:13:20 UTC.
    const STAMP: u64 = 1_700_000_000_000;

    fn title_of(line: &str) -> String {
        derive_title(&[Segment::Ink(line.into())]).expect("this line derives a title")
    }

    /// An unnamed tab born at [`STAMP`].
    fn unnamed_tab(page: Option<Sheet>) -> Tab {
        Tab {
            id: TabId(1),
            uuid: ItemId::random(),
            created_wall_ms: STAMP,
            name: None,
            rung: Ttl::default(),
            page,
        }
    }

    #[test]
    fn titles_strip_heading_markup_only_when_it_is_markup() {
        let segs = vec![Segment::Ink("### deploy friday\nrest".into())];
        assert_eq!(derive_title(&segs).as_deref(), Some("deploy friday"));
        let segs = vec![Segment::Ink("#hashtag stays".into())];
        assert_eq!(derive_title(&segs).as_deref(), Some("#hashtag stays"));
    }

    #[test]
    fn titles_strip_the_markdown_a_first_line_carries() {
        assert_eq!(title_of("- shopping list"), "shopping list");
        assert_eq!(title_of("* shopping list"), "shopping list");
        assert_eq!(title_of("3. third thing"), "third thing");
        assert_eq!(title_of("> quoted note"), "quoted note");
        assert_eq!(title_of("> > deeply quoted"), "deeply quoted");
        assert_eq!(title_of("**bold plan**"), "bold plan");
        assert_eq!(title_of("_italic plan_"), "italic plan");
        assert_eq!(title_of("~~struck plan~~"), "struck plan");
        assert_eq!(title_of("`rotate the key`"), "rotate the key");
        assert_eq!(
            title_of("[runbook](https://example.test/runbook)"),
            "runbook"
        );
        assert_eq!(
            title_of("> - ## **[the works](https://example.test)**"),
            "the works"
        );
        // Not markup: a marker needs whitespace after it.
        assert_eq!(title_of("-30C in the freezer"), "-30C in the freezer");
        assert_eq!(title_of("2.5x the budget"), "2.5x the budget");
        // An unterminated link is left exactly as typed.
        assert_eq!(title_of("[unclosed label"), "[unclosed label");
    }

    #[test]
    fn titles_cap_at_eighty_characters() {
        let long = "x".repeat(200);
        assert_eq!(title_of(&long).chars().count(), TITLE_CAP);
        // Chars, not bytes.
        let multibyte = "é".repeat(200);
        let capped = title_of(&multibyte);
        assert_eq!(capped.chars().count(), TITLE_CAP);
        assert_eq!(capped.len(), TITLE_CAP * 2);
    }

    #[test]
    fn title_skips_blank_lines_and_chips() {
        let segs = vec![
            Segment::Chip(ChipId(9)),
            Segment::Ink("\n\n  \nerrands".into()),
        ];
        assert_eq!(derive_title(&segs).as_deref(), Some("errands"));
    }

    #[test]
    fn a_body_with_no_line_to_take_derives_nothing_at_all() {
        assert_eq!(derive_title(&[]), None);
        let segs = vec![Segment::Ink("   \n".into()), Segment::Chip(ChipId(1))];
        assert_eq!(derive_title(&segs), None);
    }

    #[test]
    fn a_label_resolves_name_then_derived_title_then_the_tabs_own_stamp() {
        let mut tab = unnamed_tab(None);
        assert_eq!(tab.label(0), "1114-2213", "no name, no page");
        assert_eq!(tab.label_source(), LabelSource::Placeholder);

        // The page is born a day after the tab.
        let day = 24 * 60 * 60 * 1000;
        let mut page = bare_sheet(STAMP + day);
        page.derived_title = Some("deploy notes".into());
        tab.page = Some(page);
        assert_eq!(tab.label(0), "deploy notes");
        assert_eq!(tab.label_source(), LabelSource::Derived);

        tab.page = Some(bare_sheet(STAMP + day));
        assert_eq!(tab.label(0), "1114-2213");
        assert_eq!(tab.label_source(), LabelSource::Placeholder);

        tab.name = Some("the vault".into());
        assert_eq!(tab.label(0), "the vault");
        assert_eq!(tab.label_source(), LabelSource::Name);
    }

    #[test]
    fn titles_step_over_fence_rules_and_take_the_code_as_typed() {
        let segs = vec![Segment::Ink(
            "```ruby\n  if Onetime::Utils.yes?(ENV.fetch('STDOUT_SYNC', false))\n```".into(),
        )];
        assert_eq!(
            derive_title(&segs).as_deref(),
            Some("if Onetime::Utils.yes?(ENV.fetch('STDOUT_SYNC', false))")
        );
        let segs = vec![Segment::Ink("```\n```\n## after the fence".into())];
        assert_eq!(derive_title(&segs).as_deref(), Some("after the fence"));
        assert_eq!(title_of("~~~sh\nls -la"), "ls -la");
        assert_eq!(derive_title(&[Segment::Ink("```ruby\n".into())]), None);
    }

    #[test]
    fn a_mismatched_inner_marker_does_not_close_the_outer_fence() {
        let segs = vec![Segment::Ink(
            "```\ninner code\n~~~\nmore code\n```\n## after".into(),
        )];
        assert_eq!(derive_title(&segs).as_deref(), Some("inner code"));
    }

    #[test]
    fn a_fence_indented_four_spaces_is_prose_not_a_fence() {
        let segs = vec![Segment::Ink("    ```\n**bold**".into())];
        assert_eq!(derive_title(&segs).as_deref(), Some("bold"));
    }

    #[test]
    fn a_fence_closer_with_an_info_string_is_not_a_closer() {
        let segs = vec![Segment::Ink(
            "```\nfirst line of code\n``` js\nstill code\n```".into(),
        )];
        assert_eq!(derive_title(&segs).as_deref(), Some("first line of code"));
    }

    #[test]
    fn compaction_keeps_the_stamp_of_a_deletion_that_left_no_witness() {
        let mut sheet = bare_sheet(STAMP);
        sheet.document.insert(0, "hello\n").unwrap();
        sheet.blocks.note_insert(0, "hello\n");
        sheet.document.insert(6, "world").unwrap();
        sheet.blocks.note_insert(6, "world");
        sheet.document.commit_at(36_000);

        sheet.document.delete(6, 5).unwrap();
        sheet.blocks.note_delete(6, 5);
        sheet.document.commit_at(39_600);
        sheet.rebuild_segments();
        sheet.settle_blocks();
        assert_eq!(sheet.modified_s(), Some(39_600));

        sheet.compact();
        assert_eq!(
            sheet.modified_s(),
            Some(39_600),
            "the deletion's hour survives the boundary"
        );

        // No block claims the deletion.
        let metas = sheet.blocks_meta();
        assert_eq!(metas[0].modified_s, Some(36_000));
        assert_eq!(metas[1].modified_s, None);
    }

    #[test]
    fn settling_a_delete_that_ends_on_a_newline_keeps_every_block_name() {
        let mut sheet = bare_sheet(STAMP);
        sheet.document.insert(0, "one\ntwo\nthree").unwrap();
        sheet.blocks.note_insert(0, "one\ntwo\nthree");
        sheet.document.commit(None);
        sheet.rebuild_segments();
        sheet.settle_blocks();
        let pasted = sheet.blocks.ids();
        assert_eq!(pasted.len(), 1);

        sheet.document.delete(8, 5).unwrap();
        sheet.blocks.note_delete(8, 5);
        sheet.document.commit(None);
        sheet.rebuild_segments();
        sheet.settle_blocks();

        let settled = sheet.blocks.ids();
        assert_eq!(settled.len(), 2, "the trailing paragraph is a block");
        assert_eq!(settled[0], pasted[0], "no fresh identities for a newline");
    }

    #[test]
    fn the_compaction_floor_survives_a_block_index_rebuild() {
        let mut sheet = bare_sheet(STAMP);
        sheet.blocks.note_compaction(Some(39_600));
        let before = sheet.blocks.ids();

        // Unnarrated, so the settle has to rebuild the index.
        sheet.document.insert(0, "one\ntwo").unwrap();
        sheet.document.commit(None);
        sheet.rebuild_segments();
        sheet.settle_blocks();

        assert_ne!(sheet.blocks.ids()[0], before[0], "the index was rebuilt");
        assert_eq!(sheet.blocks.compaction_frontier(), Some(39_600));
    }

    /// A page with nothing in it, born at `created_wall_ms`.
    fn bare_sheet(created_wall_ms: u64) -> Sheet {
        let document = SheetDocument::new();
        let blocks = BlockIndex::for_document(&document);
        Sheet {
            id: SheetId(1),
            uuid: ItemId::random(),
            derived_title: None,
            created_wall_ms,
            document,
            segments: Vec::new(),
            blocks,
            chips: Vec::new(),
            detached: Vec::new(),
            clock: SheetClock::Running {
                deadline: Instant::now(),
            },
            total_held: Duration::ZERO,
            ceremony: CeremonyState::Immediate,
        }
    }

    #[test]
    fn placeholder_respects_the_local_offset() {
        assert_eq!(placeholder_title(STAMP, 0), "1114-2213");
        assert_eq!(placeholder_title(STAMP, -8 * 3600), "1114-1413");
        // A day boundary crossed by the offset moves MMDD too.
        assert_eq!(placeholder_title(STAMP, 2 * 3600), "1115-0013");
    }

    #[test]
    fn the_placeholder_calendar_holds_across_leap_years_and_epochs() {
        assert_eq!(placeholder_title(0, 0), "0101-0000");
        // 2024-02-29T12:34:00Z, the leap day the naive math gets wrong.
        assert_eq!(placeholder_title(1_709_210_040_000, 0), "0229-1234");
        // 2000-03-01T00:00:00Z, just past a century leap year.
        assert_eq!(placeholder_title(951_868_800_000, 0), "0301-0000");
    }

    #[test]
    fn the_placeholder_stamp_did_not_move() {
        assert_eq!(placeholder_title(STAMP, 0), "1114-2213");
        assert_eq!(placeholder_title(STAMP, -8 * 3600), "1114-1413");
        assert_eq!(placeholder_title(STAMP, 2 * 3600), "1115-0013");
        assert_eq!(placeholder_title(0, 0), "0101-0000");
        assert_eq!(placeholder_title(1_709_210_040_000, 0), "0229-1234");
        assert_eq!(placeholder_title(951_868_800_000, 0), "0301-0000");

        // The label's MMDD is the calendar reading of `local_day`.
        for (wall, offset) in [
            (STAMP, 0),
            (STAMP, -8 * 3600),
            (STAMP, 2 * 3600),
            (0, 0),
            (1_709_210_040_000, 0),
            (951_868_800_000, -8 * 3600),
        ] {
            let (month, day) = civil_month_day(local_day(wall, offset));
            assert!(
                placeholder_title(wall, offset).starts_with(&format!("{month:02}{day:02}")),
                "the label and the bucket disagree at {wall} offset {offset}"
            );
        }
    }

    #[test]
    fn a_page_born_before_local_midnight_is_a_different_day_from_one_after() {
        // STAMP is 22:13:20Z.
        let hour = 60 * 60 * 1000;
        let eve = local_day(STAMP, 0);
        assert_eq!(local_day(STAMP + hour, 0), eve, "23:13 is still the 14th");
        assert_eq!(
            local_day(STAMP + 2 * hour, 0),
            eve + 1,
            "00:13 is the 15th, and one day is one day"
        );
        assert_eq!(placeholder_title(STAMP + hour, 0), "1114-2313");
        assert_eq!(placeholder_title(STAMP + 2 * hour, 0), "1115-0013");
    }

    #[test]
    fn the_day_index_follows_the_offset_the_clock_reports() {
        let utc = local_day(STAMP, 0);
        // Two hours east of UTC, 22:13 has already crossed midnight.
        assert_eq!(local_day(STAMP, 2 * 3600), utc + 1);
        // Eight hours west it is the middle of the afternoon.
        assert_eq!(local_day(STAMP, -8 * 3600), utc);
        let after_midnight = STAMP + 4 * 60 * 60 * 1000; // 2023-11-15T02:13:20Z
        assert_eq!(local_day(after_midnight, 0), utc + 1);
        assert_eq!(local_day(after_midnight, -8 * 3600), utc);

        let clock = ManualClock::new().with_local_offset_seconds(2 * 3600);
        assert_eq!(
            local_day(clock.wall_ms(), clock.local_offset_seconds()),
            utc + 1
        );
    }

    #[test]
    fn a_local_reading_before_the_epoch_rounds_the_way_the_calendar_does() {
        assert_eq!(local_day(0, -8 * 3600), -1);
        assert_eq!(placeholder_title(0, -8 * 3600), "1231-1600");
        assert_eq!(local_day(0, 0), 0);
    }

    #[test]
    fn a_stamp_near_midnight_buckets_by_the_offset_it_is_read_with() {
        // 2023-11-14T23:30:00Z; only the offset moves, as with a DST change.
        let near_midnight = 1_700_004_600_000;
        assert_eq!(
            local_day(near_midnight, 3600),
            local_day(near_midnight, 0) + 1
        );
        assert_eq!(placeholder_title(near_midnight, 0), "1114-2330");
        assert_eq!(placeholder_title(near_midnight, 3600), "1115-0030");
    }

    #[test]
    fn a_pages_day_is_its_own_and_not_the_slots() {
        // The slot is three days older than its page.
        let day = 24 * 60 * 60 * 1000;
        let mut tab = unnamed_tab(None);
        tab.page = Some(bare_sheet(STAMP + 3 * day));
        let page = tab.page().expect("the slot holds one");
        assert_eq!(tab.created_wall_ms(), STAMP);
        assert_eq!(page.local_day(0), local_day(STAMP, 0) + 3);
        assert_eq!(
            tab.label(0),
            "1114-2213",
            "and the label still reads the slot's stamp, which is the point of the split"
        );
    }

    #[test]
    fn whitespace_alone_is_not_content() {
        assert!(!bare_sheet(STAMP).has_content(), "an untouched page");
        for blank in ["", "\n", "   ", " \t\n \r\n"] {
            let mut sheet = bare_sheet(STAMP);
            sheet.segments = vec![Segment::Ink(blank.into())];
            assert!(
                !sheet.has_content(),
                "{blank:?} is not something a person did"
            );
        }
        let mut sheet = bare_sheet(STAMP);
        sheet.segments = vec![Segment::Ink("\n\n  rotate the key  \n".into())];
        assert!(sheet.has_content());
    }

    #[test]
    fn a_chip_with_no_ink_is_content() {
        let mut sheet = bare_sheet(STAMP);
        sheet.chips = vec![SealedChip::text(ChipId(1), "one secret")];
        sheet.segments = vec![Segment::Ink("   ".into()), Segment::Chip(ChipId(1))];
        assert!(
            sheet.has_content(),
            "a page holding a sealed chip did something, whatever was typed around it"
        );
    }

    #[test]
    fn the_size_label_is_the_ledgers_bucket_never_a_count() {
        for (text, class) in [
            ("ab".to_string(), "tiny"),
            ("x".repeat(64), "small"),
            ("x".repeat(1024), "medium"),
            ("x".repeat(65_536), "large"),
        ] {
            let (_, label) = face(&text);
            assert_eq!(label, class, "{} bytes", text.len());
            assert_eq!(label, SizeClass::of(text.len()).to_string());
        }
        assert!(
            !face(&"x".repeat(200)).1.contains("200"),
            "an exact length must never reach the face"
        );
    }
}
