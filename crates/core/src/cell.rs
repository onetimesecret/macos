//! The `SleeperCell`: a handle for content in motion, not a display of it.

use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::secret::SecretBuffer;
use crate::ttl::{self, Ttl};

/// Opaque, monotonically assigned cell identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CellId(pub(crate) u64);

impl CellId {
    /// The raw id, for carrying across an FFI seam. `0` is never issued.
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

/// What kind of content a cell holds — the "kind glyph".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellKind {
    /// UTF-8 text.
    Text,
    /// An image, held as encoded bytes (PNG/TIFF as delivered).
    Image,
}

/// Where a cell is in its life. Promotion is a parallel annotation, not a
/// lifecycle stage: a promoted cell resumes draining if kept (doc 04).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleState {
    /// Just arrived; ring effectively full.
    Staged,
    /// Ambient and honest: the ring drains in real time.
    Draining,
    /// Under an hour left; urgency shifts geometry, not colour alone.
    LastHour,
    /// The deadline has passed; the store will remove and zeroize it.
    Expired,
}

/// Record of a cell's promotion to a one-time link. Only the receipt
/// identifier is retained — no link, no local history of promoted
/// secrets (doc 03 §5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Promotion {
    /// Server receipt identifier, kept solely to offer "burn remote" on
    /// this live cell.
    pub receipt_id: String,
}

/// The content buffer: a [`SecretBuffer`] — page-locked while alive,
/// zeroized on drop — so expiry and discard are the same wipe.
/// Deliberately not `Debug`: cell contents cannot be logged.
pub struct CellContent {
    bytes: SecretBuffer,
    kind: CellKind,
}

impl CellContent {
    /// Text content.
    #[must_use]
    pub fn text(s: &str) -> Self {
        Self {
            bytes: SecretBuffer::from_text(s),
            kind: CellKind::Text,
        }
    }

    /// Image content (encoded bytes).
    #[must_use]
    pub fn image(bytes: Vec<u8>) -> Self {
        Self {
            bytes: SecretBuffer::new(bytes),
            kind: CellKind::Image,
        }
    }

    /// Content kind.
    #[must_use]
    pub fn kind(&self) -> CellKind {
        self.kind
    }

    /// Size in bytes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    /// True when the buffer is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    /// Borrow the raw bytes. Callers copying these out own the hygiene of
    /// their copy; [`CellContent::clone_zeroizing`] is the preferred exit.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        self.bytes.expose()
    }

    /// Text view of the content, when it is text.
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self.kind {
            CellKind::Text => std::str::from_utf8(self.bytes.expose()).ok(),
            CellKind::Image => None,
        }
    }

    /// A zeroizing copy of the bytes, for handing to the pasteboard.
    /// The copy leaves the page-locked region — that is inherent to
    /// copy-out; it exists to be written somewhere else and dropped.
    #[must_use]
    pub fn clone_zeroizing(&self) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(self.bytes.expose().to_vec())
    }

    /// Character count for text, byte count for images — the metadata
    /// whisper.
    #[must_use]
    pub fn display_size(&self) -> usize {
        self.as_text()
            .map_or_else(|| self.bytes.len(), |t| t.chars().count())
    }
}

/// A `SleeperCell`. Anatomy per doc 04: time-remaining cue, kind glyph,
/// recognition line, interactive TTL label, promote CTA.
/// Not `Debug` — it holds a [`CellContent`], and cells are never logged.
pub struct Cell {
    pub(crate) id: CellId,
    pub(crate) content: CellContent,
    pub(crate) concealed: bool,
    pub(crate) detected_as: Option<&'static str>,
    pub(crate) ttl: Ttl,
    pub(crate) staged_at: Instant,
    pub(crate) deadline: Instant,
    pub(crate) promotion: Option<Promotion>,
}

/// How many characters of text the recognition line shows before
/// middle-ellipsizing.
const RECOGNITION_CHARS: usize = 60;

impl Cell {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> CellId {
        self.id
    }

    /// The content handle.
    #[must_use]
    pub fn content(&self) -> &CellContent {
        &self.content
    }

    /// Content kind (the glyph).
    #[must_use]
    pub fn kind(&self) -> CellKind {
        self.content.kind()
    }

    /// True when the cell renders masked by default: it arrived marked
    /// `ConcealedType`, or matched a secret-shape heuristic.
    #[must_use]
    pub fn concealed(&self) -> bool {
        self.concealed
    }

    /// Which heuristic flagged the content, if any — honest labelling for
    /// the UI ("looks like a GitHub token"), never a certainty claim.
    #[must_use]
    pub fn detected_as(&self) -> Option<&'static str> {
        self.detected_as
    }

    /// The active TTL rung (what the label shows after a reset).
    #[must_use]
    pub fn ttl(&self) -> Ttl {
        self.ttl
    }

    /// The instant this cell expires.
    #[must_use]
    pub fn deadline(&self) -> Instant {
        self.deadline
    }

    /// Promotion annotation, if this cell became a one-time link.
    #[must_use]
    pub fn promotion(&self) -> Option<&Promotion> {
        self.promotion.as_ref()
    }

    /// Time remaining at `now`; zero once expired.
    #[must_use]
    pub fn remaining(&self, now: Instant) -> Duration {
        self.deadline.saturating_duration_since(now)
    }

    /// The TTL label text ("3h 40m").
    #[must_use]
    pub fn ttl_label(&self, now: Instant) -> String {
        ttl::human_remaining(self.remaining(now))
    }

    /// Fraction of the ring still full at `now`, in `0.0..=1.0`.
    #[must_use]
    pub fn fraction_remaining(&self, now: Instant) -> f32 {
        let total = self.ttl.duration().as_secs_f32();
        if total <= 0.0 {
            return 0.0;
        }
        (self.remaining(now).as_secs_f32() / total).clamp(0.0, 1.0)
    }

    /// Lifecycle state at `now`.
    #[must_use]
    pub fn state(&self, now: Instant) -> LifecycleState {
        let remaining = self.remaining(now);
        if remaining.is_zero() {
            LifecycleState::Expired
        } else if remaining <= Duration::from_secs(60 * 60) {
            LifecycleState::LastHour
        } else if now.saturating_duration_since(self.staged_at) <= Duration::from_secs(60) {
            LifecycleState::Staged
        } else {
            LifecycleState::Draining
        }
    }

    /// The recognition line: a trimmed snippet for text (middle-ellipsized
    /// past ~60 chars), a size summary for images — masked when concealed.
    /// Recognition, not consumption (doc 03 §3).
    #[must_use]
    pub fn recognition_line(&self) -> String {
        if self.concealed {
            return mask_line(&self.content);
        }
        match self.content.as_text() {
            Some(text) => middle_ellipsize(text.trim(), RECOGNITION_CHARS),
            None => format!("image · {}", human_bytes(self.content.len())),
        }
    }
}

fn mask_line(content: &CellContent) -> String {
    match content.as_text() {
        // Enough dots to say "something is here", never enough to
        // leak length precisely.
        Some(_) => "•".repeat(12),
        None => format!("image · {} · concealed", human_bytes(content.len())),
    }
}

/// Trim `text` to at most `max` characters, ellipsizing in the middle so
/// both the start and the end stay recognizable.
fn middle_ellipsize(text: &str, max: usize) -> String {
    let flattened: String = text
        .chars()
        .map(|c| {
            if c == '\n' || c == '\r' || c == '\t' {
                ' '
            } else {
                c
            }
        })
        .collect();
    let count = flattened.chars().count();
    if count <= max {
        return flattened;
    }
    let head = max * 2 / 3;
    let tail = max - head - 1;
    let start: String = flattened.chars().take(head).collect();
    let end: String = flattened.chars().skip(count - tail).collect();
    format!("{start}…{end}")
}

fn human_bytes(len: usize) -> String {
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

    #[test]
    fn middle_ellipsize_keeps_head_and_tail() {
        let url = "postgres://ops:hunter2@db-3.internal:5432/prod_replica_eu_west_1";
        let out = middle_ellipsize(url, 30);
        assert_eq!(out.chars().count(), 30);
        assert!(out.starts_with("postgres://ops:hunte"));
        assert!(out.ends_with("west_1"));
        assert!(out.contains('…'));
    }

    #[test]
    fn middle_ellipsize_leaves_short_text_alone() {
        assert_eq!(middle_ellipsize("hello", 60), "hello");
    }

    #[test]
    fn middle_ellipsize_flattens_newlines() {
        assert_eq!(middle_ellipsize("a\nb\tc", 60), "a b c");
    }

    #[test]
    fn human_bytes_scales() {
        assert_eq!(human_bytes(212 * 1024), "212 KB");
        assert_eq!(human_bytes(64), "64 B");
        assert_eq!(human_bytes(3 * 1024 * 1024), "3.0 MB");
    }

    #[test]
    fn display_size_counts_chars_for_text_bytes_for_images() {
        assert_eq!(CellContent::text("héllo").display_size(), 5);
        assert_eq!(CellContent::image(vec![0u8; 42]).display_size(), 42);
    }
}
