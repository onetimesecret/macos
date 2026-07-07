//! The working set: a dozen cells, never a thousand rows of history.

use std::time::Instant;

use zeroize::Zeroizing;

use crate::cell::{Cell, CellContent, CellId, Promotion};
use crate::clock::Clock;
use crate::detect::secret_shape;
use crate::ttl::Ttl;

/// Soft cap on the working set (open question №3). At the cap the store
/// refuses gently: silent eviction of deliberately placed content would
/// break trust — eviction here is by the TTL the user chose, never LRU
/// surprise (doc 04).
pub const DEFAULT_CAP: usize = 12;

/// Why staging was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StageError {
    /// The working set is full; let something expire or discard first.
    AtCapacity {
        /// The configured soft cap.
        cap: usize,
    },
    /// Nothing to stage (empty text or zero-byte image).
    EmptyContent,
}

impl std::fmt::Display for StageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StageError::AtCapacity { cap } => write!(
                f,
                "the panel holds {cap} cells — let something expire, or discard"
            ),
            StageError::EmptyContent => write!(f, "nothing to stage"),
        }
    }
}

impl std::error::Error for StageError {}

/// The memory-only cell store. Everything in it dies with the process —
/// exit is total amnesia, and that is the product, not a limitation.
pub struct CellStore<C: Clock> {
    clock: C,
    cells: Vec<Cell>,
    cap: usize,
    default_ttl: Ttl,
    next_id: u64,
}

impl<C: Clock> CellStore<C> {
    /// A store reading time from `clock`, with the default cap and TTL.
    #[must_use]
    pub fn new(clock: C) -> Self {
        Self {
            clock,
            cells: Vec::new(),
            cap: DEFAULT_CAP,
            default_ttl: Ttl::default(),
            next_id: 1,
        }
    }

    /// Override the soft cap (settings surface; still refuse-don't-evict).
    #[must_use]
    pub fn with_cap(mut self, cap: usize) -> Self {
        self.cap = cap;
        self
    }

    /// Override the default TTL for arriving content.
    #[must_use]
    pub fn with_default_ttl(mut self, ttl: Ttl) -> Self {
        self.default_ttl = ttl;
        self
    }

    /// Stage text. `concealed_hint` is `Some(true)` when the source
    /// marked it concealed (e.g. pasteboard `ConcealedType`); otherwise
    /// the secret-shape heuristics decide whether to mask.
    pub fn stage_text(
        &mut self,
        text: &str,
        concealed_hint: Option<bool>,
    ) -> Result<CellId, StageError> {
        if text.is_empty() {
            return Err(StageError::EmptyContent);
        }
        let detected = secret_shape(text);
        let concealed = concealed_hint.unwrap_or(detected.is_some());
        self.stage(CellContent::text(text), concealed, detected)
    }

    /// Stage image bytes (already-encoded PNG/TIFF as delivered).
    pub fn stage_image(
        &mut self,
        bytes: Vec<u8>,
        concealed_hint: Option<bool>,
    ) -> Result<CellId, StageError> {
        if bytes.is_empty() {
            return Err(StageError::EmptyContent);
        }
        let concealed = concealed_hint.unwrap_or(false);
        self.stage(CellContent::image(bytes), concealed, None)
    }

    fn stage(
        &mut self,
        content: CellContent,
        concealed: bool,
        detected_as: Option<&'static str>,
    ) -> Result<CellId, StageError> {
        if self.cells.len() >= self.cap {
            return Err(StageError::AtCapacity { cap: self.cap });
        }
        let now = self.clock.now();
        let id = CellId(self.next_id);
        self.next_id += 1;
        // Newest at top (doc 04).
        self.cells.insert(
            0,
            Cell {
                id,
                content,
                concealed,
                detected_as,
                ttl: self.default_ttl,
                staged_at: now,
                deadline: now + self.default_ttl.duration(),
                promotion: None,
            },
        );
        Ok(id)
    }

    /// The cells, newest first.
    pub fn cells(&self) -> impl Iterator<Item = &Cell> {
        self.cells.iter()
    }

    /// A cell by id.
    #[must_use]
    pub fn get(&self, id: CellId) -> Option<&Cell> {
        self.cells.iter().find(|c| c.id == id)
    }

    fn get_mut(&mut self, id: CellId) -> Option<&mut Cell> {
        self.cells.iter_mut().find(|c| c.id == id)
    }

    /// Number of live cells.
    #[must_use]
    pub fn len(&self) -> usize {
        self.cells.len()
    }

    /// True when the panel is empty — the system working, not failing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    /// The soft cap.
    #[must_use]
    pub fn cap(&self) -> usize {
        self.cap
    }

    /// The store's clock reading, for rendering.
    #[must_use]
    pub fn now(&self) -> Instant {
        self.clock.now()
    }

    /// Copy a cell's content back out. Copy-out does **not** consume the
    /// cell — multi-paste is a core moment (doc 01); the cell keeps
    /// draining. The returned buffer zeroizes on drop; hand it to the
    /// pasteboard and let it fall.
    #[must_use]
    pub fn copy_out(&self, id: CellId) -> Option<Zeroizing<Vec<u8>>> {
        self.get(id).map(|c| c.content().clone_zeroizing())
    }

    /// Cycle the TTL label: next rung on the ladder, clock *reset* to the
    /// full rung value. One affordance for extend, shorten, and reset.
    /// Returns the new rung.
    pub fn cycle_ttl(&mut self, id: CellId) -> Option<Ttl> {
        let now = self.clock.now();
        let cell = self.get_mut(id)?;
        cell.ttl = cell.ttl.next();
        cell.deadline = now + cell.ttl.duration();
        Some(cell.ttl)
    }

    /// Set the TTL to a specific rung, resetting the clock to it.
    pub fn set_ttl(&mut self, id: CellId, ttl: Ttl) -> Option<Ttl> {
        let now = self.clock.now();
        let cell = self.get_mut(id)?;
        cell.ttl = ttl;
        cell.deadline = now + ttl.duration();
        Some(cell.ttl)
    }

    /// Discard a cell now. The content buffer zeroizes as it drops.
    /// Returns true when the cell existed. (Inline undo is a shell
    /// affordance with its own short-lived copy; the core forgets.)
    pub fn discard(&mut self, id: CellId) -> bool {
        let before = self.cells.len();
        self.cells.retain(|c| c.id != id);
        self.cells.len() != before
    }

    /// Record a successful promotion: only the receipt identifier stays
    /// on the live cell (no link, no history — doc 03 §5). The cell
    /// resumes draining; burning the local copy is the user's call.
    pub fn mark_promoted(&mut self, id: CellId, receipt_id: String) -> bool {
        match self.get_mut(id) {
            Some(cell) => {
                cell.promotion = Some(Promotion { receipt_id });
                true
            }
            None => false,
        }
    }

    /// The earliest deadline among live cells — the *only* timer the
    /// shell ever needs to arm. `None` means nothing to schedule: no
    /// timers ticking, no wakeups (doc 05 frugality budget).
    #[must_use]
    pub fn next_deadline(&self) -> Option<Instant> {
        self.cells.iter().map(|c| c.deadline).min()
    }

    /// Remove and zeroize every cell whose deadline has passed. Returns
    /// the expired ids (for the shell to drop from view — silently; the
    /// user set the clock). Call when the armed timer fires, then re-arm
    /// from [`CellStore::next_deadline`].
    pub fn expire_due(&mut self) -> Vec<CellId> {
        let now = self.clock.now();
        let (dead, live): (Vec<Cell>, Vec<Cell>) = std::mem::take(&mut self.cells)
            .into_iter()
            .partition(|c| c.remaining(now).is_zero());
        self.cells = live;
        // `dead` drops here; each buffer zeroizes on the way down.
        dead.into_iter().map(|c| c.id).collect()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::cell::LifecycleState;
    use crate::clock::ManualClock;

    fn store() -> (CellStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        (CellStore::new(clock.clone()), clock)
    }

    const HOUR: Duration = Duration::from_secs(60 * 60);

    #[test]
    fn staging_uses_default_ttl_and_orders_newest_first() {
        let (mut store, _) = store();
        let first = store.stage_text("first", None).unwrap();
        let second = store.stage_text("second", None).unwrap();
        let order: Vec<CellId> = store.cells().map(Cell::id).collect();
        assert_eq!(order, vec![second, first]);
        let cell = store.get(first).unwrap();
        assert_eq!(cell.ttl(), Ttl::default());
        assert_eq!(cell.ttl_label(store.now()), "8h");
    }

    #[test]
    fn refuses_at_capacity_instead_of_evicting() {
        let (mut store, _) = store();
        for i in 0..DEFAULT_CAP {
            store.stage_text(&format!("cell {i}"), None).unwrap();
        }
        let err = store.stage_text("one too many", None).unwrap_err();
        assert_eq!(err, StageError::AtCapacity { cap: DEFAULT_CAP });
        // Nothing was evicted to make room.
        assert_eq!(store.len(), DEFAULT_CAP);
    }

    #[test]
    fn refuses_empty_content() {
        let (mut store, _) = store();
        assert_eq!(store.stage_text("", None), Err(StageError::EmptyContent));
        assert_eq!(
            store.stage_image(Vec::new(), None),
            Err(StageError::EmptyContent)
        );
    }

    #[test]
    fn expiry_is_scheduled_not_polled() {
        let (mut store, clock) = store();
        let id = store.stage_text("draining", None).unwrap();
        store.set_ttl(id, Ttl::MIN).unwrap(); // 1h

        // The shell arms exactly one timer, at the earliest deadline.
        let deadline = store.next_deadline().unwrap();
        assert_eq!(deadline - store.now(), HOUR);

        // Before the deadline nothing expires.
        clock.advance(HOUR - Duration::from_secs(1));
        assert!(store.expire_due().is_empty());

        // At the deadline the cell is removed (and zeroized on drop).
        clock.advance(Duration::from_secs(1));
        assert_eq!(store.expire_due(), vec![id]);
        assert!(store.is_empty());
        assert_eq!(store.next_deadline(), None); // nothing left to arm
    }

    #[test]
    fn copy_out_does_not_consume_the_cell() {
        let (mut store, _) = store();
        let id = store.stage_text("multi-paste me", None).unwrap();
        for _ in 0..3 {
            let bytes = store.copy_out(id).unwrap();
            assert_eq!(&**bytes, b"multi-paste me");
        }
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn cycle_ttl_steps_the_ladder_and_resets_the_clock() {
        let (mut store, clock) = store();
        let id = store.stage_text("cycling", None).unwrap();

        // Burn two hours of the default 8h.
        clock.advance(2 * HOUR);
        assert_eq!(store.get(id).unwrap().remaining(store.now()), 6 * HOUR);

        // Click: 8h → 24h, clock reset to the full rung.
        let rung = store.cycle_ttl(id).unwrap();
        assert_eq!(rung.to_string(), "24h");
        assert_eq!(store.get(id).unwrap().remaining(store.now()), 24 * HOUR);
    }

    #[test]
    fn lifecycle_states_follow_the_clock() {
        let (mut store, clock) = store();
        let id = store.stage_text("stateful", None).unwrap();
        let state_at = |store: &CellStore<ManualClock>| {
            let now = store.now();
            store.get(id).unwrap().state(now)
        };

        assert_eq!(state_at(&store), LifecycleState::Staged);
        clock.advance(2 * HOUR);
        assert_eq!(state_at(&store), LifecycleState::Draining);
        clock.advance(5 * HOUR + Duration::from_secs(30 * 60)); // 7h30m in
        assert_eq!(state_at(&store), LifecycleState::LastHour);
        clock.advance(HOUR);
        assert_eq!(state_at(&store), LifecycleState::Expired);
        assert_eq!(store.expire_due(), vec![id]);
    }

    #[test]
    fn ring_fraction_drains_linearly() {
        let (mut store, clock) = store();
        let id = store.stage_text("ring", None).unwrap();
        clock.advance(4 * HOUR); // half of 8h
        let f = store.get(id).unwrap().fraction_remaining(store.now());
        assert!((f - 0.5).abs() < 0.001);
    }

    #[test]
    fn secret_shaped_text_arrives_masked() {
        let (mut store, _) = store();
        let id = store
            .stage_text("postgres://ops:hunter2@db-3.internal:5432/prod", None)
            .unwrap();
        let cell = store.get(id).unwrap();
        assert!(cell.concealed());
        assert_eq!(cell.detected_as(), Some("URL with password"));
        assert_eq!(cell.recognition_line(), "•".repeat(12));
    }

    #[test]
    fn concealed_hint_overrides_heuristics_both_ways() {
        let (mut store, _) = store();
        // Pasteboard said concealed; heuristics see plain prose.
        let hinted = store.stage_text("meet at noon", Some(true)).unwrap();
        assert!(store.get(hinted).unwrap().concealed());
        // Explicit reveal wins over a heuristic match.
        let revealed = store
            .stage_text("ghp_16C7e42F292c6912E7710c838347Ae178B4a", Some(false))
            .unwrap();
        let cell = store.get(revealed).unwrap();
        assert!(!cell.concealed());
        // …but the detection is still reported for honest labelling.
        assert_eq!(cell.detected_as(), Some("GitHub token"));
    }

    #[test]
    fn discard_and_burn_after_promotion() {
        let (mut store, _) = store();
        let id = store.stage_text("promote me", None).unwrap();
        assert!(store.mark_promoted(id, "9f2abc".into()));
        let cell = store.get(id).unwrap();
        assert_eq!(cell.promotion().unwrap().receipt_id, "9f2abc");
        // Promotion does not consume the cell; burning is explicit.
        assert_eq!(store.len(), 1);
        assert!(store.discard(id));
        assert!(store.is_empty());
        assert!(!store.discard(id));
    }

    #[test]
    fn expire_due_only_removes_the_due() {
        let (mut store, clock) = store();
        let short = store.stage_text("short", None).unwrap();
        store.set_ttl(short, Ttl::MIN).unwrap(); // 1h
        let long = store.stage_text("long", None).unwrap(); // 8h default

        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![short]);
        assert_eq!(store.len(), 1);
        assert!(store.get(long).is_some());

        // Next armed timer is the survivor's deadline.
        assert_eq!(
            store.next_deadline(),
            Some(store.get(long).unwrap().deadline())
        );
    }
}
