//! The sheet: ink and sealed chips (interaction-model rev C, doc 04).
//!
//! A sheet reads like a little text file. **Ink** is anything typed —
//! visible, editable, ordinary text, held authoritatively in the
//! sheet's operation-logged document (ADR-0013) and cached here as a
//! segments projection. A **sealed chip** is an opaque
//! token standing in for content that was deliberately masked; its bytes
//! live only here, in a [`SecretBuffer`], and never render.
//!
//! Masking is decided by **gesture, not by content and not by origin**
//! (doc 04): the core never parses, classifies, or scores what arrives.
//! The excerpt on a chip is mechanical; counts are counts; detection
//! never returns.

use std::time::{Duration, Instant};

use crate::blocks::{BlockIndex, BlockMeta};
use crate::document::{DocRun, SheetDocument};
use crate::secret::SecretBuffer;
use crate::ttl::{self, Ttl};

/// A random 128-bit item identifier (a version 4 UUID), minted at
/// creation. The sequential [`SheetId`] and [`ChipId`] counters stay for
/// internal ordering; this is the only identifier that may appear in the
/// ledger or in any persisted artifact (ADR-0012).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ItemId([u8; 16]);

impl ItemId {
    /// Mint a fresh identity from the operating system CSPRNG.
    ///
    /// Panicking when the CSPRNG is unavailable is deliberate: a fallback
    /// identifier would be predictable, and an unpredictable identity is
    /// the whole point. `getentropy` does not fail on a healthy Darwin or
    /// Linux host, so this panic is a genuine "the machine is broken"
    /// signal rather than a condition worth handling.
    #[must_use]
    pub fn random() -> Self {
        let mut bytes = [0u8; 16];
        getrandom::getrandom(&mut bytes).expect("the OS CSPRNG must be available");
        // Version 4 in the high nibble of byte 6, RFC 4122 variant in the
        // top two bits of byte 8.
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        Self(bytes)
    }

    /// The raw 16 bytes, for writing into a snapshot.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Rebuild an identity from its raw bytes. Used only when reading a
    /// snapshot back, so that a restore preserves identity instead of
    /// minting a new one.
    #[must_use]
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }
}

/// Lowercase hyphenated 8-4-4-4-12 hex. This is the only rendering of an
/// item identity that crosses the FFI seam.
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

    /// Rebuild an id from its raw form (an FFI caller handing one back).
    /// Unknown ids are harmless: lookups simply return `None`.
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

/// One run of the body's cached projection: visible ink, or a sealed
/// chip's position. The sheet's operation-logged document is the source
/// of truth; this shape is rebuilt from its runs for the ledger, for
/// tab titles, and for sheet promotion — ink is not secret (it
/// renders), so holding a copy here breaks no law.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// Visible text, exactly as typed (markup preserved — doc 04).
    Ink(String),
    /// A sealed chip sits here.
    Chip(ChipId),
}

/// What a chip's bytes are, described without reading them — a header
/// peek for the image kind is the entire extent of inspection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChipMeta {
    /// UTF-8 text: character count (after trailing-newline trim) and
    /// line count.
    Text {
        /// Characters, as the size label counts them.
        chars: usize,
        /// Lines, after trimming trailing newlines.
        lines: usize,
    },
    /// An image, held as encoded bytes; only the container format is
    /// sniffed (magic bytes), never the contents.
    Image {
        /// Encoded byte length.
        byte_len: usize,
    },
}

/// Record of a chip's promotion to a one-time link. Only the receipt
/// identifier is retained — no link, no local history of promoted
/// secrets (doc 03 §5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Promotion {
    /// Server receipt identifier, kept solely to offer "burn remote" on
    /// this live chip.
    pub receipt_id: String,
}

/// A sealed chip: the bytes, and the non-secret face it shows.
/// Not `Debug` — it owns a [`SecretBuffer`], and chips are never logged.
pub struct SealedChip {
    pub(crate) id: ChipId,
    /// Minted once, when the chip is sealed, and never re-minted: a
    /// restore carries the stored identity through rather than issuing a
    /// fresh one.
    pub(crate) uuid: ItemId,
    pub(crate) bytes: SecretBuffer,
    pub(crate) meta: ChipMeta,
    pub(crate) excerpt: String,
    pub(crate) size_label: String,
    pub(crate) promotion: Option<Promotion>,
}

impl SealedChip {
    /// Seal UTF-8 text. The excerpt and size label are computed here,
    /// once, mechanically — they are the only rendering this content
    /// will ever get.
    pub(crate) fn text(id: ChipId, text: &str) -> Self {
        Self::text_with_uuid(id, ItemId::random(), text)
    }

    /// Seal UTF-8 text under an identity that already exists. This form
    /// exists solely so a restore preserves the stored identity instead
    /// of re-minting it.
    pub(crate) fn text_with_uuid(id: ChipId, uuid: ItemId, text: &str) -> Self {
        let (excerpt, size_label, meta) = text_face(text);
        Self {
            id,
            uuid,
            bytes: SecretBuffer::from_text(text),
            meta,
            excerpt,
            size_label,
            promotion: None,
        }
    }

    /// Seal image bytes (encoded, as delivered). The face is clipboard
    /// metadata only: sniffed container format and byte size — read
    /// without opening the contents (doc 04). Images are excluded from
    /// `mlock` and documented as such (doc 05): still zeroized on death,
    /// but never pinned against swap.
    pub(crate) fn image(id: ChipId, bytes: Vec<u8>) -> Self {
        Self::image_with_uuid(id, ItemId::random(), bytes)
    }

    /// Seal image bytes under an identity that already exists, for the
    /// restore path.
    pub(crate) fn image_with_uuid(id: ChipId, uuid: ItemId, bytes: Vec<u8>) -> Self {
        let byte_len = bytes.len();
        let excerpt = format!("{} image", sniff_image_kind(&bytes));
        Self {
            id,
            uuid,
            bytes: SecretBuffer::new_unlocked(bytes),
            meta: ChipMeta::Image { byte_len },
            excerpt,
            size_label: human_bytes(byte_len),
            promotion: None,
        }
    }

    /// Identifier.
    #[must_use]
    pub fn id(&self) -> ChipId {
        self.id
    }

    /// The random item identity, minted when this chip was sealed. The
    /// only identifier of this chip that may leave the process.
    #[must_use]
    pub fn uuid(&self) -> ItemId {
        self.uuid
    }

    /// What the bytes are, described without reading them.
    #[must_use]
    pub fn meta(&self) -> ChipMeta {
        self.meta
    }

    /// The mechanical excerpt — recognized by the person who pasted it,
    /// not identified by a stranger. This is the only rendering the
    /// content ever gets; there is no reveal affordance at any privilege.
    #[must_use]
    pub fn excerpt(&self) -> &str {
        &self.excerpt
    }

    /// The count shown beside the excerpt ("40 ch", "5 ln", "212 KB").
    #[must_use]
    pub fn size_label(&self) -> &str {
        &self.size_label
    }

    /// Promotion annotation, if this chip became a one-time link.
    #[must_use]
    pub fn promotion(&self) -> Option<&Promotion> {
        self.promotion.as_ref()
    }
}

/// One sheet's clock. Time belongs to the sheet — no per-chip timers,
/// ever (doc 04).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SheetClock {
    /// Draining toward `deadline`.
    Running {
        /// The instant the sheet expires.
        deadline: Instant,
    },
    /// Held by the pause gesture: the remaining life is frozen and does
    /// not drain until the hold lapses at `until`.
    Held {
        /// When the hold lapses and the page is a regular page again.
        until: Instant,
        /// The remaining life frozen at the moment of the hold.
        frozen_remaining: Duration,
        /// When this hold began — so cumulative held time stays
        /// accountable (a total-held ceiling is open question №8).
        started: Instant,
    },
}

/// A sheet: the operation-logged body, the chips it owns, and one
/// countdown. Not `Debug` — it holds [`SealedChip`]s.
///
/// The `uuid` is minted once, at creation, and never re-minted: a
/// restore carries the stored identity through, so a page keeps the same
/// identity across a relaunch.
pub struct Sheet {
    pub(crate) id: SheetId,
    pub(crate) uuid: ItemId,
    /// The page's name, held as state. Derived at creation and
    /// re-derived on edit, never recomputed at read time and never
    /// derived at ledger time (ADR-0012).
    pub(crate) title: String,
    /// Set once the user names the page by hand. While it is set, no
    /// edit re-derives the title.
    pub(crate) title_is_user_set: bool,
    /// Unix epoch milliseconds at creation, kept solely so the
    /// placeholder title stays the same string for the page's whole
    /// life. Expiry math never reads it.
    pub(crate) created_wall_ms: u64,
    /// The body as an operation-logged document (ADR-0013): the source
    /// of truth for ink and chip positions inside the core.
    pub(crate) document: SheetDocument,
    /// A cached projection of the document, rebuilt from its runs after
    /// every mutation ([`Sheet::rebuild_segments`]). Readers keep this
    /// shape; nothing edits it directly.
    pub(crate) segments: Vec<Segment>,
    /// The page's paragraphs as identities (ADR-0013): maintained op by
    /// op through every mutation path so a paragraph keeps its name
    /// across edits, and settled by [`Sheet::settle_blocks`].
    pub(crate) blocks: BlockIndex,
    pub(crate) chips: Vec<SealedChip>,
    pub(crate) rung: Ttl,
    pub(crate) clock: SheetClock,
    /// Held time from holds that have already lapsed; the live hold's
    /// span is added on normalization (open question №8 accounting).
    pub(crate) total_held: Duration,
}

/// A title is a page property, not a projection: the tab strip and the
/// ledger both read the same stored string.
impl Sheet {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> SheetId {
        self.id
    }

    /// The random item identity, minted when this page was created. The
    /// only identifier of this page that may leave the process.
    #[must_use]
    pub fn uuid(&self) -> ItemId {
        self.uuid
    }

    /// The cached projection of the body, in document order.
    #[must_use]
    pub fn segments(&self) -> &[Segment] {
        &self.segments
    }

    /// Rebuild the cached segments projection from the document's runs.
    /// Every mutation path calls this, so readers never see the
    /// projection drift from the document. A sentinel whose identity
    /// matches no owned chip drops out of the projection: it cannot
    /// arise by construction, and a chip the sheet cannot resolve must
    /// not render.
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

    /// Settle the block index against the document as it now stands:
    /// re-take every anchor, and if the index no longer describes the
    /// body — a wholesale restate, or a mutation path that failed to
    /// narrate itself — rebuild it with fresh identities rather than
    /// serve stale ones. Every mutation path ends here.
    pub(crate) fn settle_blocks(&mut self) {
        if self.blocks.matches(&self.document) {
            self.blocks.retake_anchors(&self.document);
        } else {
            self.blocks = BlockIndex::for_document(&self.document);
        }
    }

    /// The compaction ceremony (ADR-0013): graduate first, then
    /// discard. Every block's derived provenance is frozen into its
    /// materialized slot while the ops still exist to prove it, origin
    /// included; then the document is reborn from its runs under a
    /// fresh peer identity and the trail dies. Chips and their sealed
    /// bytes pass through untouched, since they live beside the
    /// document, not inside its history. The settle at the end keeps
    /// the standing discipline: anchors are re-taken, and an index that
    /// somehow stopped describing the body is rebuilt fresh rather
    /// than trusted.
    pub(crate) fn compact(&mut self) {
        self.blocks.graduate(&self.document);
        self.document.compact();
        self.rebuild_segments();
        self.settle_blocks();
    }

    /// Per-block provenance, in document order: each paragraph's
    /// identity with its created and modified stamps (Unix seconds),
    /// derived from the operation log (ADR-0013). Identities and
    /// timestamps only; block content never crosses here.
    #[must_use]
    pub fn blocks_meta(&self) -> Vec<BlockMeta> {
        self.blocks.metas(&self.document)
    }

    /// The page's modified stamp, Unix seconds: the newest change in
    /// the page's operation log, merged with the newest materialized
    /// stamp once compaction has destroyed the ops behind it. `None`
    /// for a page whose body has never been touched. The created stamp
    /// stays [`Sheet::created_wall_ms`], which predates the document's
    /// first change.
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

    /// Number of chips on the sheet.
    #[must_use]
    pub fn chip_count(&self) -> usize {
        self.chips.len()
    }

    /// The active rung (what the countdown label shows after a reset).
    #[must_use]
    pub fn rung(&self) -> Ttl {
        self.rung
    }

    /// Whether the clock is held by the pause gesture at `now`.
    #[must_use]
    pub fn is_held(&self, now: Instant) -> bool {
        match self.clock {
            SheetClock::Running { .. } => false,
            SheetClock::Held { until, .. } => now < until,
        }
    }

    /// Total time this page's clock has spent held, through `now` —
    /// the accounting a cumulative pause ceiling would need (open
    /// question №8; no ceiling is enforced today).
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

    /// How much longer the hold lasts at `now`; zero when not held.
    #[must_use]
    pub fn hold_remaining(&self, now: Instant) -> Duration {
        match self.clock {
            SheetClock::Running { .. } => Duration::ZERO,
            SheetClock::Held { until, .. } => until.saturating_duration_since(now),
        }
    }

    /// Remaining life at `now`. While held it is the frozen value; after
    /// a hold lapses (lazily, before [`crate::SheetStore::expire_due`]
    /// normalizes) it drains from where it froze.
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

    /// The countdown label text ("3h 40m").
    #[must_use]
    pub fn remaining_label(&self, now: Instant) -> String {
        ttl::human_remaining(self.remaining(now))
    }

    /// Fraction of the gauge still full at `now`, in `0.0..=1.0`.
    #[must_use]
    pub fn fraction_remaining(&self, now: Instant) -> f32 {
        let total = self.rung.duration().as_secs_f32();
        if total <= 0.0 {
            return 0.0;
        }
        (self.remaining(now).as_secs_f32() / total).clamp(0.0, 1.0)
    }

    /// Under an hour left — the gauge turns ember with a hatched
    /// texture; urgency is never colour-only (doc 04).
    #[must_use]
    pub fn last_hour(&self, now: Instant) -> bool {
        let remaining = self.remaining(now);
        !remaining.is_zero() && remaining <= Duration::from_secs(60 * 60)
    }

    /// The tab title: a name the page owns, not a rendering of its
    /// content. It is the first typed line with markdown syntax
    /// stripped, or the creation-stamp placeholder, or whatever the
    /// user named it. Chips never contribute: the author's own typed
    /// line does the naming.
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// Whether the user named this page by hand. While true, an edit
    /// never re-derives the title (ADR-0012).
    #[must_use]
    pub fn title_is_user_set(&self) -> bool {
        self.title_is_user_set
    }

    /// Unix epoch milliseconds at creation, the stamp the placeholder
    /// title is rendered from. Never used for expiry math.
    #[must_use]
    pub fn created_wall_ms(&self) -> u64 {
        self.created_wall_ms
    }
}

/// A title is a name, not a document: 80 characters, counted in `char`s
/// so a multibyte secret can never be split mid-scalar.
pub(crate) const TITLE_CAP: usize = 80;

/// First non-blank ink line across the document, markdown syntax
/// stripped and capped at [`TITLE_CAP`] characters; the creation-stamp
/// placeholder when there is none.
///
/// The word "untitled" no longer exists in the core: an unnamed page
/// reads as `MMDD-HHmm`, which tells the user when they opened it.
pub(crate) fn derive_title(
    segments: &[Segment],
    created_wall_ms: u64,
    utc_offset_seconds: i32,
) -> String {
    segments
        .iter()
        .filter_map(|s| match s {
            Segment::Ink(text) => Some(text),
            Segment::Chip(_) => None,
        })
        .flat_map(|text| text.lines())
        .map(strip_markdown)
        .find(|line| !line.is_empty())
        .map_or_else(
            || placeholder_title(created_wall_ms, utc_offset_seconds),
            |line| line.chars().take(TITLE_CAP).collect(),
        )
}

/// `MMDD-HHmm` in the user's local time, from the page's creation
/// stamp. The common case: a page whose first line is still empty.
pub(crate) fn placeholder_title(wall_ms: u64, utc_offset_seconds: i32) -> String {
    let epoch_seconds = i64::try_from(wall_ms / 1000).unwrap_or(i64::MAX);
    let local_seconds = epoch_seconds.saturating_add(i64::from(utc_offset_seconds));
    let days = local_seconds.div_euclid(86_400);
    let secs_of_day = local_seconds.rem_euclid(86_400);
    let (month, day) = civil_month_day(days);
    let hour = secs_of_day / 3_600;
    let minute = (secs_of_day % 3_600) / 60;
    format!("{month:02}{day:02}-{hour:02}{minute:02}")
}

/// Month and day from days since the Unix epoch: Howard Hinnant's
/// `civil_from_days`, integer arithmetic only, no calendar dependency.
/// The era starts in March, which is why the month wraps by three.
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

/// Reduce one line of markdown to the name inside it. Deliberately not
/// a parser: it handles the syntax a person types on a first line and
/// nothing more, in a fixed order: blockquote markers, one list bullet,
/// heading hashes, inline emphasis and code runs, then link syntax
/// collapsed to its label.
fn strip_markdown(line: &str) -> String {
    let mut rest = line.trim();

    // Blockquote markers, however deeply nested: "> > note" → "note".
    while let Some(after) = rest.strip_prefix('>') {
        rest = after.trim_start();
    }

    rest = strip_list_bullet(rest);
    rest = strip_heading_markup(rest);

    // Emphasis, strikethrough and inline code are decoration; the
    // characters simply drop out.
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

/// `### deploy friday` → `deploy friday`. Headings only (#, ## and
/// deeper, doc 04); a `#hashtag` with no following whitespace is not a
/// heading and stays as typed.
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

/// `[label](https://example.test)` → `label`, in one forward scan. An
/// unterminated link is left exactly as typed.
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

/// The mechanical excerpt rule (doc 04; reference implementation in the
/// rev C prototype's `excerptOf`). Returns (excerpt, size label, meta).
///
/// - Multi-line: first line, at most 17 characters, `…` appended; the
///   count reads in lines ("5 ln").
/// - Single line of n characters: reveal budget `B = min(24, ⌊n/3⌋)`,
///   split 60/40 head–tail (`head = max(1, ⌈0.6·B⌉)`), middle hidden;
///   too short to split (`B < 1`) shows `···`. The count reads in
///   characters ("40 ch").
///
/// Trailing newlines are trimmed before counting: the person who pasted
/// it recognizes "3 ch", not "4 ch with an invisible newline". Counts
/// are `char`s — mechanical, not grapheme-aware; the excerpt only has to
/// be recognized by the person who pasted it.
fn text_face(text: &str) -> (String, String, ChipMeta) {
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
            format!("{lines} ln"),
            ChipMeta::Text { chars, lines },
        );
    }
    let n = trimmed.chars().count();
    let meta = ChipMeta::Text { chars: n, lines };
    let budget = (n / 3).min(24);
    if budget < 1 {
        return ("···".to_string(), format!("{n} ch"), meta);
    }
    // 60/40 head–tail, head rounded up: max(1, ⌈0.6·B⌉) = max(1, ⌈3B/5⌉).
    let head_len = (3 * budget).div_ceil(5).max(1);
    let tail_len = budget - head_len;
    let head: String = trimmed.chars().take(head_len).collect();
    let tail: String = trimmed.chars().skip(n.saturating_sub(tail_len)).collect();
    (format!("{head}…{tail}"), format!("{n} ch"), meta)
}

/// Sniff an image container from magic bytes — a header peek, never a
/// decode. Unknown formats are simply "image".
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

/// "212 KB" — byte sizes the way the chip face reads them.
pub(crate) fn human_bytes(len: usize) -> String {
    if len >= 1024 * 1024 {
        format!("{:.1} MB", len as f64 / (1024.0 * 1024.0))
    } else if len >= 1024 {
        format!("{} KB", len / 1024)
    } else {
        format!("{len} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn face(text: &str) -> (String, String) {
        let (excerpt, label, _) = text_face(text);
        (excerpt, label)
    }

    #[test]
    fn item_ids_are_random_version_four() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..1000 {
            let id = ItemId::random();
            let bytes = *id.as_bytes();
            assert_eq!(bytes[6] >> 4, 0x4, "version nibble");
            assert_eq!(bytes[8] >> 6, 0b10, "variant bits");
            assert!(seen.insert(bytes), "a minted identity repeated");
        }
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
    fn a_sealed_chip_carries_its_own_uuid() {
        // Identity is minted, not derived from content: identical text
        // seals to two chips that are still distinguishable.
        let first = SealedChip::text(ChipId(1), "same text");
        let second = SealedChip::text(ChipId(2), "same text");
        assert_ne!(first.uuid(), second.uuid());
    }

    #[test]
    fn single_line_excerpt_splits_sixty_forty() {
        // 40 chars → budget min(24, 13) = 13; head ⌈7.8⌉ = 8, tail 5.
        // PAT-shaped, assembled at runtime so the raw pattern never
        // sits in the repository text (the secret-scan CI job reads
        // the full history).
        let token = String::from("ghp_") + "4kQ9wXbGpT2mR8vLcY3n" + "Z6qF1sJde0H5jK7a";
        assert_eq!(token.chars().count(), 40);
        let (excerpt, label) = face(&token);
        assert_eq!(label, "40 ch");
        assert_eq!(excerpt, "ghp_4kQ9…5jK7a");
        assert_eq!(excerpt.chars().filter(|c| *c != '…').count(), 13);
    }

    #[test]
    fn long_single_line_caps_the_budget_at_24() {
        let long: String = "x".repeat(200);
        let (excerpt, label) = face(&long);
        assert_eq!(label, "200 ch");
        // budget 24: head ⌈14.4⌉ = 15, tail 9.
        assert_eq!(excerpt.chars().filter(|c| *c != '…').count(), 24);
        assert!(excerpt.starts_with(&"x".repeat(15)));
    }

    #[test]
    fn too_short_to_split_shows_dots() {
        let (excerpt, label) = face("ab");
        assert_eq!(excerpt, "···");
        assert_eq!(label, "2 ch");
    }

    #[test]
    fn three_chars_reveal_exactly_one() {
        // n=3 → budget 1 → head 1, tail 0.
        let (excerpt, label) = face("abc");
        assert_eq!(excerpt, "a…");
        assert_eq!(label, "3 ch");
    }

    #[test]
    fn multi_line_shows_first_line_and_line_count() {
        let (excerpt, label) =
            face("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END-----");
        assert_eq!(excerpt, "-----BEGIN OPENSS…");
        assert_eq!(label, "3 ln");
    }

    #[test]
    fn trailing_newlines_do_not_count() {
        let (excerpt, label) = face("abc\n");
        assert_eq!(label, "3 ch", "a trailing newline is not content");
        assert_eq!(excerpt, "a…");
        let (_, label) = face("one\ntwo\n\n");
        assert_eq!(label, "2 ln");
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
        assert_eq!(chip.size_label(), "212 KB");
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
        assert_eq!(chip.size_label(), "64 B");
    }

    /// The fixed stamp `ManualClock::new()` reports, so every title
    /// test below reads the same placeholder.
    const STAMP: u64 = 1_700_000_000_000;

    fn title_of(line: &str) -> String {
        derive_title(&[Segment::Ink(line.into())], STAMP, 0)
    }

    #[test]
    fn titles_strip_heading_markup_only_when_it_is_markup() {
        let segs = vec![Segment::Ink("### deploy friday\nrest".into())];
        assert_eq!(derive_title(&segs, STAMP, 0), "deploy friday");
        let segs = vec![Segment::Ink("#hashtag stays".into())];
        assert_eq!(derive_title(&segs, STAMP, 0), "#hashtag stays");
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
        // Counted in chars, not bytes: a multibyte line caps at 80
        // scalars and never splits one in half.
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
        assert_eq!(derive_title(&segs, STAMP, 0), "errands");
    }

    #[test]
    fn an_empty_page_takes_the_creation_stamp_placeholder() {
        // 1_700_000_000_000 ms is 2023-11-14 22:13:20 UTC.
        assert_eq!(derive_title(&[], STAMP, 0), "1114-2213");
        let segs = vec![Segment::Ink("   \n".into()), Segment::Chip(ChipId(1))];
        assert_eq!(derive_title(&segs, STAMP, 0), "1114-2213");
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
    fn human_bytes_scales() {
        assert_eq!(human_bytes(212 * 1024), "212 KB");
        assert_eq!(human_bytes(64), "64 B");
        assert_eq!(human_bytes(3 * 1024 * 1024), "3.0 MB");
    }
}
