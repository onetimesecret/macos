//! The sheet: ink and sealed chips (interaction-model rev C, doc 04).
//!
//! A sheet reads like a little text file. **Ink** is anything typed —
//! visible, editable, ordinary text, owned by the shell's text view and
//! mirrored here as a synced snapshot. A **sealed chip** is an opaque
//! token standing in for content that was deliberately masked; its bytes
//! live only here, in a [`SecretBuffer`], and never render.
//!
//! Masking is decided by **gesture, not by content and not by origin**
//! (doc 04): the core never parses, classifies, or scores what arrives.
//! The excerpt on a chip is mechanical; counts are counts; detection
//! never returns.

use std::time::{Duration, Instant};

use crate::secret::SecretBuffer;
use crate::ttl::{self, Ttl};

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

/// One run of the synced document: visible ink, or a sealed chip's
/// position. The shell owns the live document; this is the core's
/// snapshot of its structure, kept for the ledger, for tab titles, and
/// for sheet promotion — ink is not secret (it renders), so holding a
/// copy here breaks no law.
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
        let (excerpt, size_label, meta) = text_face(text);
        Self {
            id,
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
        let byte_len = bytes.len();
        let excerpt = format!("{} image", sniff_image_kind(&bytes));
        Self {
            id,
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

/// A sheet: the synced document snapshot, the chips it owns, and one
/// countdown. Not `Debug` — it holds [`SealedChip`]s.
pub struct Sheet {
    pub(crate) id: SheetId,
    pub(crate) segments: Vec<Segment>,
    pub(crate) chips: Vec<SealedChip>,
    pub(crate) rung: Ttl,
    pub(crate) clock: SheetClock,
    /// Held time from holds that have already lapsed; the live hold's
    /// span is added on normalization (open question №8 accounting).
    pub(crate) total_held: Duration,
}

/// Tab titles show at most the first typed line; the ledger keeps the
/// same derivation.
impl Sheet {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> SheetId {
        self.id
    }

    /// The synced document snapshot, in document order.
    #[must_use]
    pub fn segments(&self) -> &[Segment] {
        &self.segments
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

    /// The tab title: the sheet's first typed line, markdown heading
    /// markup stripped — a title is a name, not a document (doc 04). A
    /// page with no typed line is "untitled". Chips never contribute:
    /// the author's own typed line does the naming.
    #[must_use]
    pub fn title(&self) -> String {
        derive_title(&self.segments)
    }
}

/// First non-blank ink line across the document, heading markup
/// stripped; "untitled" when there is none.
pub(crate) fn derive_title(segments: &[Segment]) -> String {
    segments
        .iter()
        .filter_map(|s| match s {
            Segment::Ink(text) => Some(text),
            Segment::Chip(_) => None,
        })
        .flat_map(|text| text.lines())
        .map(strip_heading_markup)
        .find(|line| !line.is_empty())
        .map_or_else(|| "untitled".to_string(), str::to_string)
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

    #[test]
    fn titles_strip_heading_markup_only_when_it_is_markup() {
        let segs = vec![Segment::Ink("### deploy friday\nrest".into())];
        assert_eq!(derive_title(&segs), "deploy friday");
        let segs = vec![Segment::Ink("#hashtag stays".into())];
        assert_eq!(derive_title(&segs), "#hashtag stays");
    }

    #[test]
    fn title_skips_blank_lines_and_chips() {
        let segs = vec![
            Segment::Chip(ChipId(9)),
            Segment::Ink("\n\n  \nerrands".into()),
        ];
        assert_eq!(derive_title(&segs), "errands");
    }

    #[test]
    fn empty_page_is_untitled() {
        assert_eq!(derive_title(&[]), "untitled");
        let segs = vec![Segment::Ink("   \n".into()), Segment::Chip(ChipId(1))];
        assert_eq!(derive_title(&segs), "untitled");
    }

    #[test]
    fn human_bytes_scales() {
        assert_eq!(human_bytes(212 * 1024), "212 KB");
        assert_eq!(human_bytes(64), "64 B");
        assert_eq!(human_bytes(3 * 1024 * 1024), "3.0 MB");
    }
}
