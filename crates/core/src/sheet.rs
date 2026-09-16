//! The tab and the sheet: a durable slot and the perishable page
//! inside it (interaction-model rev C, doc 04; ADR-0017).
//!
//! A [`Tab`] is the thing the user navigates with: an identity, a
//! creation stamp, an optional name they typed, the rung pages born in
//! the slot start at, and at most one page. A [`Sheet`] is everything
//! that expires. Nothing the app derived from content ever reaches the
//! tab, which is why the tab may outlive every page it held.
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
use crate::ledger::SizeClass;
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

/// Opaque, monotonically assigned tab identifier. `0` is never issued.
///
/// A slot's handle, distinct from the [`SheetId`] of whatever page is
/// standing in it: the tab survives the page, so one number cannot do
/// both jobs (ADR-0017).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TabId(pub(crate) u64);

impl TabId {
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
/// tab titles, and for concealing a sheet; ink is not secret (it
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

/// Record of a chip's conceal: the moment it became a one-time link.
/// Only the receipt identifier is retained — no link, no local history
/// of concealed secrets (doc 03 §5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conceal {
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
    pub(crate) conceal: Option<Conceal>,
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
            conceal: None,
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
            size_label: SizeClass::of(byte_len).to_string(),
            conceal: None,
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

    /// The size class shown beside the excerpt ("tiny", "small",
    /// "medium", "large", "huge"): the ledger's own bucket
    /// ([`SizeClass`]), never an exact length (D-29).
    #[must_use]
    pub fn size_label(&self) -> &str {
        &self.size_label
    }

    /// Conceal annotation, if this chip became a one-time link.
    #[must_use]
    pub fn conceal(&self) -> Option<&Conceal> {
        self.conceal.as_ref()
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
        /// Whether the hold has already been topped up to its 24 hour
        /// ceiling. The pause gesture is a three state cycle (doc 04):
        /// hold, top up, release. Without this the third press could
        /// only be inferred from the hold's length, and a restore
        /// (which rebuilds `until` and `started` from time away) would
        /// lose the distinction.
        topped_up: bool,
    },
}

/// How a page's compaction ceremony runs (ADR-0013, issue #101).
/// Solo is the default and the restored state: a rung transition
/// compacts inline, exactly as it always has. A page attached to a
/// sync channel is marked deferred by the session layer, and a
/// transition then leaves the history standing — the ceremony becomes
/// a proposal ([`crate::sync::PageChannel`]), performed only once
/// every attached device confirms
/// ([`SheetStore::perform_ceremony`]). Never persisted: a sync
/// session does not survive a restart, so a restore comes back
/// immediate and the engine re-defers on attach.
///
/// [`SheetStore::perform_ceremony`]: crate::store::SheetStore::perform_ceremony
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CeremonyState {
    /// No peer is attached: compaction runs inline at the transition.
    Immediate,
    /// Peers are attached: transitions mark the ceremony due instead
    /// of compacting, and the history stands until the channel
    /// confirms. Keeping the trail one more rung is recoverable;
    /// splitting devices across a half-run boundary is not.
    Deferred {
        /// Whether a transition has come due since the last ceremony,
        /// which is what tells the session layer this device should
        /// propose.
        due: bool,
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
    /// The first non-blank line of the body, held as state: re-derived
    /// on edit, never recomputed at read time and never derived at
    /// ledger time (ADR-0012). `None` while the body has no line to
    /// take one from. It is content the app derived on its own, so it
    /// dies with the page and is never written down (ADR-0017): the
    /// restore path recomputes it from the restored segments.
    pub(crate) derived_title: Option<String>,
    /// Unix epoch milliseconds at creation, the page's own birth, now
    /// distinct from the tab's. Expiry math never reads it.
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
    pub(crate) clock: SheetClock,
    /// Held time from holds that have already lapsed; the live hold's
    /// span is added on normalization (open question №8 accounting).
    pub(crate) total_held: Duration,
    /// Whether compaction runs inline or waits for the channel
    /// (issue #101). [`CeremonyState::Immediate`] until a sync session
    /// says otherwise, so a page never touched by sync behaves exactly
    /// as it always has.
    pub(crate) ceremony: CeremonyState,
}

/// A derived title is a page property, not a projection: it is
/// computed once per edit and read from state afterwards, so nothing
/// re-derives it at ledger time.
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
    /// body (a wholesale restate, or a mutation path that failed to
    /// narrate itself), rebuild it with fresh identities rather than
    /// serve stale ones. Every mutation path ends here.
    pub(crate) fn settle_blocks(&mut self) {
        // A delete that ended the body on a newline left an empty
        // paragraph with no block standing for it, which the narration
        // could not see because it reads widths and not characters.
        // Mend that here, before the check: judged as it stands the
        // index looks stale, and the page would be handed a whole set
        // of fresh identities for the crime of a finished sentence.
        self.blocks.reopen_trailing_block(&self.document);
        if self.blocks.matches(&self.document) {
            self.blocks.retake_anchors(&self.document);
        } else {
            // The floor is the page's stamp, not any block's, so it must
            // outlive a rebuild of the block identities. A rebuild that
            // dropped it would let the page's modified time step back the
            // moment a wholesale restate (through `sync_document`) tripped
            // the mismatch, and only `compact` happens to re-note it.
            let floor = self.blocks.compaction_frontier();
            self.blocks = BlockIndex::for_document(&self.document);
            self.blocks.note_compaction(floor);
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
        // The log's frontier is read while the log still exists, and
        // kept as the page's floor: a deletion is a change with no
        // surviving character to vote for it, so the per-block
        // summaries below cannot carry it and the page's modified
        // stamp would step back to whenever its oldest surviving text
        // was written.
        let frontier = self.document.latest_timestamp();
        self.blocks.graduate(&self.document);
        self.document.compact();
        self.rebuild_segments();
        self.settle_blocks();
        // After the settle, so a rebuilt index inherits the floor: it
        // is the page's stamp, not any block's, and nothing about a
        // rebuild makes the page younger.
        self.blocks.note_compaction(frontier);
    }

    /// What a rung transition does to the history: compact now when the
    /// page is solo, or mark the ceremony due and leave the trail
    /// standing when peers are attached (issue #101). Every transition
    /// site calls this instead of [`Sheet::compact`] directly, so the
    /// two behaviours cannot drift apart.
    pub(crate) fn compact_or_defer(&mut self) {
        match self.ceremony {
            CeremonyState::Immediate => self.compact(),
            CeremonyState::Deferred { .. } => {
                self.ceremony = CeremonyState::Deferred { due: true };
            }
        }
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

    /// Whether the live hold has already been topped up to 24 hours,
    /// meaning the next pause press releases it rather than extending
    /// it. False when the page is not held at all.
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
    ///
    /// The rung is passed in because it belongs to the tab that owns
    /// this page, not to the page (ADR-0017): the gauge is a reading of
    /// a page's life against the slot it was born into.
    #[must_use]
    pub fn fraction_remaining(&self, rung: Ttl, now: Instant) -> f32 {
        let total = rung.duration().as_secs_f32();
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

    /// The page's own name for itself: its first typed line with
    /// markdown syntax stripped, `None` while nothing has been typed.
    /// Chips never contribute — the author's own typed line does the
    /// naming — and the user never sets this one, which is the tab's
    /// [`name`](Tab::name) instead. It is the middle step of the label
    /// the strip shows, and it dies with the page.
    #[must_use]
    pub fn derived_title(&self) -> Option<&str> {
        self.derived_title.as_deref()
    }

    /// Unix epoch milliseconds at this page's creation. Never used for
    /// expiry math, and no longer the stamp any placeholder renders
    /// from: that is the tab's birthday now (ADR-0017).
    #[must_use]
    pub fn created_wall_ms(&self) -> u64 {
        self.created_wall_ms
    }

    /// Whether this page holds anything at all: one line of ink that is
    /// more than whitespace, or one sealed chip.
    ///
    /// This is the bar the ledger uses. `SheetStore::entomb` asks it
    /// whether a dying page did anything worth recording, so the core
    /// has one definition of holding something rather than two that can
    /// drift apart, and a surface asking the same question of a live
    /// page gets the answer the audit trail would have given at its
    /// death. A page carrying nothing but a stray newline is
    /// deliberately below the bar: whitespace is not a thing a person
    /// did.
    #[must_use]
    pub fn has_content(&self) -> bool {
        !self.chips.is_empty()
            || self.segments.iter().any(|segment| match segment {
                Segment::Ink(text) => !text.trim().is_empty(),
                Segment::Chip(_) => false,
            })
    }

    /// The local day this page was born on, through the offset the
    /// caller's clock reports: [`local_day`] over the page's own stamp.
    ///
    /// The page's stamp and never the slot's, because a slot outlives
    /// every page that stands in it. `SheetStore::open_page` mints
    /// today's page into a tab opened last week, so the tab's birthday
    /// would file a page typed this morning under a day nobody was
    /// here. This one dies with the page, which is exactly the life a
    /// reading of "which day is this page on" should have.
    #[must_use]
    pub fn local_day(&self, utc_offset_seconds: i32) -> i64 {
        local_day(self.created_wall_ms, utc_offset_seconds)
    }
}

/// A tab: the durable slot a page stands in. Not `Debug` — it may hold
/// a [`Sheet`], and a sheet owns [`SealedChip`]s.
///
/// Everything here outlives every page the slot ever held, so nothing
/// here may be derived from what a page contained (ADR-0017). The
/// `name` is the user's own word for the slot or nothing at all; the
/// `rung` is a number with no clock behind it, so a tab schedules
/// nothing and expires never.
pub struct Tab {
    pub(crate) id: TabId,
    /// Minted once, when the slot is opened, and carried through a
    /// restore rather than re-minted. Distinct from the page's identity
    /// and named by no ledger record.
    pub(crate) uuid: ItemId,
    /// Unix epoch milliseconds when the slot was opened: the stamp the
    /// `MMDD-HHmm` placeholder renders from, and the reason an unnamed
    /// tab keeps the same label across every page it holds.
    pub(crate) created_wall_ms: u64,
    /// The name the user typed, capped at [`TITLE_CAP`] characters.
    /// `Some` means they typed it; `None` means the tab has no name.
    /// Never derived from content, at any point, by any path.
    pub(crate) name: Option<String>,
    /// The rung pages born in this slot start at. Not a countdown:
    /// there is no clock, no deadline and nothing remaining, so the
    /// timer path has nothing here to read and nothing to schedule.
    pub(crate) rung: Ttl,
    /// The page standing in the slot, if one is. `None` is a tab whose
    /// page expired, or one that has never held a page.
    pub(crate) page: Option<Sheet>,
}

impl Tab {
    /// Identifier.
    #[must_use]
    pub fn id(&self) -> TabId {
        self.id
    }

    /// The random item identity, minted when this tab was opened.
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

    /// The label the strip and the ledger read, resolved in three
    /// steps: the name the user typed, else the live page's derived
    /// title, else the placeholder from *this tab's* creation stamp.
    ///
    /// The stamp is the tab's rather than the page's on purpose. An
    /// unnamed tab that keeps taking fresh pages would otherwise change
    /// its label every time one was born, and the slot the user
    /// arranged by dragging would stop being recognizable.
    ///
    /// Which branch answered is [`Tab::label_source`]'s business, and
    /// this function reads through it rather than repeating the walk,
    /// so the two cannot disagree about a tab whose name was cleared
    /// or whose page just settled its first line.
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

    /// Which of [`Tab::label`]'s three steps answered. The far side
    /// reads it to decide what the label is worth drawing beside: a
    /// placeholder repeats the stamp the gutter and the rail already
    /// carry, and a derived title repeats the page's own first line.
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

/// A title is a name, not a document: 80 characters, counted in `char`s
/// so a multibyte secret can never be split mid-scalar.
pub(crate) const TITLE_CAP: usize = 80;

/// First non-blank ink line across the document, markdown syntax
/// stripped and capped at [`TITLE_CAP`] characters; `None` when the
/// body offers no such line.
///
/// A fence's rules are markup and never a name (D-12): the walk steps
/// over an opening rule (three backticks or tildes, with or without a
/// language word) and takes the first line inside the fence, as typed,
/// since code carries no markdown to strip. A body that is nothing but
/// rules derives nothing, the same as a body that is nothing but
/// blank lines.
///
/// The walk stops at the walk (ADR-0017): the fallback is
/// [`Tab::label`]'s business, because the placeholder renders from the
/// tab's stamp and not the page's. Answering `None` here is what keeps
/// a label from jumping to a different four-digit stamp the moment a
/// page expires under it.
pub(crate) fn derive_title(segments: &[Segment]) -> Option<String> {
    let mut in_fence = false;
    segments
        .iter()
        .filter_map(|s| match s {
            Segment::Ink(text) => Some(text),
            Segment::Chip(_) => None,
        })
        .flat_map(|text| text.lines())
        .filter_map(|line| {
            if is_fence_rule(line) {
                in_fence = !in_fence;
                return None;
            }
            Some(if in_fence {
                line.trim().to_string()
            } else {
                strip_markdown(line)
            })
        })
        .find(|line| !line.is_empty())
        .map(|line| line.chars().take(TITLE_CAP).collect())
}

/// A fence's opening or closing rule: three backticks or tildes at the
/// start of the line, with or without a language word after them.
fn is_fence_rule(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("```") || trimmed.starts_with("~~~")
}

/// The local day a wall-clock stamp falls on: days since the Unix
/// epoch, counted after the stamp has been folded through the offset
/// the caller's clock reports. The divide is `div_euclid` rather than a
/// truncating one because the local reading can be negative even though
/// the stamp cannot (the first hours of 1970 read from a zone west of
/// UTC), and truncation would round those towards zero and call them
/// the first of January.
///
/// This is the crate's only bucketing arithmetic, and it is
/// [`placeholder_title`]'s: the `MMDD` half of the stamp a tab renders
/// comes from this number, so the four digits on a label and the day
/// anything else files that page under cannot disagree. Anyone
/// grouping by day reads this rather than writing the divide again.
///
/// The offset is read at render time and applied to an old stamp,
/// never stored beside it. A page staged within an hour of local
/// midnight can therefore bucket differently after a daylight-saving
/// change or a flight, the property [`placeholder_title`] already had,
/// and the one its tests already pin. Storing a day index at creation
/// would settle it, at the price of a field in the sealed snapshot and
/// a durable answer to a question that is only ever asked at read time.
#[must_use]
pub fn local_day(wall_ms: u64, utc_offset_seconds: i32) -> i64 {
    local_seconds(wall_ms, utc_offset_seconds).div_euclid(86_400)
}

/// Seconds since the Unix epoch in the caller's local time: the one
/// conversion both the day and the clock face are read out of.
fn local_seconds(wall_ms: u64, utc_offset_seconds: i32) -> i64 {
    let epoch_seconds = i64::try_from(wall_ms / 1000).unwrap_or(i64::MAX);
    epoch_seconds.saturating_add(i64::from(utc_offset_seconds))
}

/// `MMDD-HHmm` in the user's local time, from the tab's creation
/// stamp. The common case: a slot nobody has named holding a page whose
/// first line is still empty.
///
/// The word "untitled" no longer exists in the core: an unnamed tab
/// reads as `MMDD-HHmm`, which tells the user when they opened it.
pub(crate) fn placeholder_title(wall_ms: u64, utc_offset_seconds: i32) -> String {
    let days = local_day(wall_ms, utc_offset_seconds);
    let secs_of_day = local_seconds(wall_ms, utc_offset_seconds).rem_euclid(86_400);
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
/// - Multi-line: first line, at most 17 characters, `…` appended.
/// - Single line of n characters: reveal budget `B = min(24, ⌊n/3⌋)`,
///   split 60/40 head–tail (`head = max(1, ⌈0.6·B⌉)`), middle hidden;
///   too short to split (`B < 1`) shows `···`.
///
/// The size label is a class, never a count: the same bucket the
/// ledger reduces the seal to, read off the sealed bytes whole. An
/// exact length is a weak fingerprint of the content, and the label is
/// what would sit in a clipboard history forever once a placeholder
/// carries it (D-29). Trailing newlines are trimmed before the excerpt
/// is cut, so the person who pasted "abc\n" still recognizes "a…";
/// the character and line counts stay in the meta, which never
/// renders. Counts are `char`s, mechanical and not grapheme-aware; the
/// excerpt only has to be recognized by the person who pasted it.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::{Clock, ManualClock};

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
        // The excerpt is cut from the content, not from its terminator;
        // the label is a class of the whole, so nothing about it can
        // betray the newline either way.
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

    /// The fixed stamp `ManualClock::new()` reports, so every title
    /// test below reads the same placeholder.
    const STAMP: u64 = 1_700_000_000_000;

    fn title_of(line: &str) -> String {
        derive_title(&[Segment::Ink(line.into())]).expect("this line derives a title")
    }

    /// A tab holding `page`, born at [`STAMP`] and never named: the
    /// fixture the label resolution is read through.
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
        assert_eq!(derive_title(&segs).as_deref(), Some("errands"));
    }

    #[test]
    fn a_body_with_no_line_to_take_derives_nothing_at_all() {
        // The walk answers None rather than reaching for a stamp: the
        // fallback belongs to the tab, which is the object that still
        // exists once this page is gone (ADR-0017).
        assert_eq!(derive_title(&[]), None);
        let segs = vec![Segment::Ink("   \n".into()), Segment::Chip(ChipId(1))];
        assert_eq!(derive_title(&segs), None);
    }

    #[test]
    fn a_label_resolves_name_then_derived_title_then_the_tabs_own_stamp() {
        // 1_700_000_000_000 ms is 2023-11-14 22:13:20 UTC.
        let mut tab = unnamed_tab(None);
        assert_eq!(tab.label(0), "1114-2213", "no name, no page");
        assert_eq!(tab.label_source(), LabelSource::Placeholder);

        // A page with a first line supplies the middle step. The page's
        // own birthday sits a day later than the tab's, which is what
        // makes the last step's stamp visibly the tab's.
        let day = 24 * 60 * 60 * 1000;
        let mut page = bare_sheet(STAMP + day);
        page.derived_title = Some("deploy notes".into());
        tab.page = Some(page);
        assert_eq!(tab.label(0), "deploy notes");
        assert_eq!(tab.label_source(), LabelSource::Derived);

        // An untyped page falls straight through to the tab's stamp,
        // never the page's.
        tab.page = Some(bare_sheet(STAMP + day));
        assert_eq!(tab.label(0), "1114-2213");
        assert_eq!(tab.label_source(), LabelSource::Placeholder);

        // And a name the user typed wins over both.
        tab.name = Some("the vault".into());
        assert_eq!(tab.label(0), "the vault");
        assert_eq!(tab.label_source(), LabelSource::Name);
    }

    #[test]
    fn titles_step_over_fence_rules_and_take_the_code_as_typed() {
        // The opening rule names a language and is markup, not a name:
        // the title is the first line inside the fence, and code is
        // taken as typed rather than stripped of emphasis it never had.
        let segs = vec![Segment::Ink(
            "```ruby\n  if Onetime::Utils.yes?(ENV.fetch('STDOUT_SYNC', false))\n```".into(),
        )];
        assert_eq!(
            derive_title(&segs).as_deref(),
            Some("if Onetime::Utils.yes?(ENV.fetch('STDOUT_SYNC', false))")
        );
        // A closing rule is stepped over too, and the line after it is
        // prose again, with its markup stripped.
        let segs = vec![Segment::Ink("```\n```\n## after the fence".into())];
        assert_eq!(derive_title(&segs).as_deref(), Some("after the fence"));
        // Tildes fence too.
        assert_eq!(title_of("~~~sh\nls -la"), "ls -la");
        // A body that is nothing but a rule derives nothing at all.
        assert_eq!(derive_title(&[Segment::Ink("```ruby\n".into())]), None);
    }

    #[test]
    fn compaction_keeps_the_stamp_of_a_deletion_that_left_no_witness() {
        let mut sheet = bare_sheet(STAMP);
        sheet.document.insert(0, "hello\n").unwrap();
        sheet.blocks.note_insert(0, "hello\n");
        sheet.document.insert(6, "world").unwrap();
        sheet.blocks.note_insert(6, "world");
        sheet.document.commit_at(36_000);

        // An hour later the second line goes. A deletion is a change
        // like any other, but it is the one kind that leaves no
        // character behind to vote for it: the page's newest stamp
        // rests on the log alone.
        sheet.document.delete(6, 5).unwrap();
        sheet.blocks.note_delete(6, 5);
        sheet.document.commit_at(39_600);
        sheet.rebuild_segments();
        sheet.settle_blocks();
        assert_eq!(sheet.modified_s(), Some(39_600));

        // The ceremony destroys that log, so the frontier has to be
        // read while it still exists. Modified is a stamp on a page a
        // reader is looking at; it may not walk backwards because the
        // evidence behind it expired on schedule.
        sheet.compact();
        assert_eq!(
            sheet.modified_s(),
            Some(39_600),
            "the deletion's hour survives the boundary"
        );

        // The floor is the page's, not a block's: no paragraph is made
        // to claim a change that did not touch it.
        let metas = sheet.blocks_meta();
        assert_eq!(metas[0].modified_s, Some(36_000));
        assert_eq!(metas[1].modified_s, None);
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
        // Every case pinned above, restated after the day arithmetic
        // came out of `placeholder_title` and into `local_day`. The
        // label is on screen, so the rendering has to be what it was.
        assert_eq!(placeholder_title(STAMP, 0), "1114-2213");
        assert_eq!(placeholder_title(STAMP, -8 * 3600), "1114-1413");
        assert_eq!(placeholder_title(STAMP, 2 * 3600), "1115-0013");
        assert_eq!(placeholder_title(0, 0), "0101-0000");
        assert_eq!(placeholder_title(1_709_210_040_000, 0), "0229-1234");
        assert_eq!(placeholder_title(951_868_800_000, 0), "0301-0000");

        // And the agreement is now structural rather than a
        // coincidence of two spellings: the four digits the label opens
        // with are the calendar reading of the very day `local_day`
        // counts, for every case above.
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
        // [`STAMP`] is 2023-11-14T22:13:20Z, an hour and three quarters
        // short of midnight.
        let hour = 60 * 60 * 1000;
        let eve = local_day(STAMP, 0);
        assert_eq!(local_day(STAMP + hour, 0), eve, "23:13 is still the 14th");
        assert_eq!(
            local_day(STAMP + 2 * hour, 0),
            eve + 1,
            "00:13 is the 15th, and one day is one day"
        );
        // Which is the boundary the label crosses too.
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
        // And a stamp just past midnight UTC is still yesterday there:
        // the negative offset is the case a truncating divide would get
        // wrong for any stamp before the epoch, and the case a shell
        // asking a system time zone would get wrong at the edges.
        let after_midnight = STAMP + 4 * 60 * 60 * 1000; // 2023-11-15T02:13:20Z
        assert_eq!(local_day(after_midnight, 0), utc + 1);
        assert_eq!(local_day(after_midnight, -8 * 3600), utc);

        // The offset a store hands out is a clock's answer, not a
        // constant, and this is the pair a caller reads it as.
        let clock = ManualClock::new().with_local_offset_seconds(2 * 3600);
        assert_eq!(
            local_day(clock.wall_ms(), clock.local_offset_seconds()),
            utc + 1
        );
    }

    #[test]
    fn a_local_reading_before_the_epoch_rounds_the_way_the_calendar_does() {
        // The stamp cannot be negative, but the local reading can: the
        // first hours of 1970 seen from eight hours west of UTC are the
        // last day of 1969. A truncating divide would round that
        // towards zero and call it the first of January, and the label
        // beside it already says otherwise.
        assert_eq!(local_day(0, -8 * 3600), -1);
        assert_eq!(placeholder_title(0, -8 * 3600), "1231-1600");
        assert_eq!(local_day(0, 0), 0);
    }

    #[test]
    fn a_stamp_near_midnight_buckets_by_the_offset_it_is_read_with() {
        // 2023-11-14T23:30:00Z. Nothing about the page changes here;
        // the offset does, which is what a daylight-saving change does
        // to a page already staged. The bucket moves with it, and so
        // does the label, the property the placeholder always had.
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
        // The slot was opened three days before the page standing in
        // it, which is every reused tab: `open_page` mints today's page
        // into a slot that is as old as it is.
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
        // One typed character is, wherever the blank lines fall.
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
        // The label and the ledger read the same bytes through the
        // same buckets, so the face can never say more than the record.
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
