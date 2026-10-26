//! What a peer learns of a sealed object beside the page's ops: its kind,
//! size class and versioned name, and never its value (ADR-0058 point 5).

use std::collections::VecDeque;
use std::fmt;

use zeroize::Zeroizing;

use crate::clock::Clock;
use crate::ledger::SizeClass;
use crate::sheet::{
    Availability, ChipMeta, ItemId, NameRefusal, PeerKind, SealedChip, Sheet, SheetId, judge_name,
};
use crate::store::SheetStore;

/// The most entries kept for objects no page here has a record for yet
/// (ADR-0058 point 5).
pub(crate) const PENDING_CAP: usize = 256;

/// A name's version: a counter, then the writing device's fingerprint,
/// compared in that order; the greater wins (ADR-0058 point 5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NameVersion {
    /// One more than the highest counter the writer knew for the name.
    pub counter: u64,
    /// The SHA-256 of the writing device's identity public key.
    pub writer: [u8; 32],
}

impl NameVersion {
    /// The first version of a name, as a new identity's.
    pub(crate) const fn first(writer: [u8; 32]) -> Self {
        Self { counter: 1, writer }
    }

    /// The version a local write after `current` takes.
    pub(crate) fn after(current: Option<Self>, writer: [u8; 32]) -> Result<Self, NameRefusal> {
        let Some(current) = current else {
            return Ok(Self::first(writer));
        };
        let counter = current
            .counter
            .checked_add(1)
            .ok_or(NameRefusal::VersionsSpent)?;
        Ok(Self { counter, writer })
    }
}

/// One object's metadata as it travels between devices: no bytes, excerpt,
/// exact count, receipt or note (ADR-0058 point 5).
#[derive(Clone, PartialEq, Eq)]
pub struct ObjectMetadata {
    /// The object's identity.
    pub object: ItemId,
    /// Its kind, when known.
    pub kind: Option<PeerKind>,
    /// Its size class, when known.
    pub size: Option<SizeClass>,
    /// The name's version and the name, `None` inside for a clear; `None`
    /// for a name never set. A wiping owner, since a name is content (Law 0004).
    pub name: Option<(NameVersion, Option<Zeroizing<String>>)>,
}

impl fmt::Debug for ObjectMetadata {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ObjectMetadata")
            .field("object", &self.object)
            .field("kind", &self.kind)
            .field("size", &self.size)
            .field(
                "name_version",
                &self.name.as_ref().map(|(version, _)| version),
            )
            .field("named", &self.name.as_ref().map(|(_, name)| name.is_some()))
            .finish()
    }
}

impl ObjectMetadata {
    /// What `record` tells a peer. A name set before versions existed goes
    /// as counter 0, which every versioned write passes.
    fn of(record: &SealedChip, writer: [u8; 32]) -> Self {
        let (kind, size) = face_of(record);
        Self {
            object: record.uuid,
            kind,
            size,
            name: version_of(record, writer).map(|version| (version, record.name.clone())),
        }
    }

    /// This entry with a name the rule refuses taken out, so it is skipped.
    fn judged(mut self) -> Self {
        let refused = matches!(
            &self.name,
            Some((_, Some(name))) if judge_name(name).ok().flatten() != Some(name.as_str())
        );
        if refused {
            self.name = None;
        }
        self
    }

    /// Fold a later entry for the same object into this held one: the first
    /// kind and size class known, and the greater name version.
    fn absorb(&mut self, later: Self) {
        self.kind = self.kind.or(later.kind);
        self.size = self.size.or(later.size);
        if let Some((version, _)) = &later.name
            && self.name.as_ref().is_none_or(|(held, _)| version > held)
        {
            self.name = later.name;
        }
    }
}

/// A record's kind and size class: its value's own when here, else what it was told.
fn face_of(record: &SealedChip) -> (Option<PeerKind>, Option<SizeClass>) {
    match &record.availability {
        Availability::Local(local) => {
            let kind = match local.meta {
                ChipMeta::Text { .. } => PeerKind::Text,
                ChipMeta::Image { .. } => PeerKind::Image,
            };
            (Some(kind), Some(SizeClass::of(local.bytes.len())))
        }
        Availability::Peer { kind, size } => (*kind, *size),
    }
}

/// The version `record`'s name compares at, sent or received: a name from
/// before versions at counter 0 under `writer`, no name and no version none.
fn version_of(record: &SealedChip, writer: [u8; 32]) -> Option<NameVersion> {
    match (record.name_version, &record.name) {
        (Some(version), _) => Some(version),
        (None, Some(_)) => Some(NameVersion { counter: 0, writer }),
        (None, None) => None,
    }
}

/// Adopt from `entry` a kind or size class a record with no value lacks, and
/// a name of a greater version than [`version_of`] gives it under `writer`.
/// Returns whether the record changed.
fn adopt(record: &mut SealedChip, entry: ObjectMetadata, writer: [u8; 32]) -> bool {
    let mut changed = false;
    if let Availability::Peer { kind, size } = &mut record.availability {
        if kind.is_none() && entry.kind.is_some() {
            *kind = entry.kind;
            changed = true;
        }
        if size.is_none() && entry.size.is_some() {
            *size = entry.size;
            changed = true;
        }
    }
    if let Some((version, name)) = entry.name
        && version_of(record, writer).is_none_or(|current| version > current)
    {
        record.name_version = Some(version);
        record.name = name;
        changed = true;
    }
    changed
}

/// Fold into `into` what `from`, a record for the same object about to drop,
/// knows and it lacks, both read under `writer`. Returns whether `into` changed.
pub(crate) fn absorb(into: &mut SealedChip, from: &SealedChip, writer: [u8; 32]) -> bool {
    adopt(into, ObjectMetadata::of(from, writer), writer)
}

/// The record for `object` on `sheet`, attached or detached.
pub(crate) fn record_on(sheet: &Sheet, object: ItemId) -> Option<&SealedChip> {
    sheet
        .chips
        .iter()
        .chain(&sheet.detached)
        .find(|chip| chip.uuid == object)
}

/// The same, mutably.
pub(crate) fn record_on_mut(sheet: &mut Sheet, object: ItemId) -> Option<&mut SealedChip> {
    sheet
        .chips
        .iter_mut()
        .chain(&mut sheet.detached)
        .find(|chip| chip.uuid == object)
}

impl<C: Clock> SheetStore<C> {
    /// Name this device's fingerprint as the writer of its name versions
    /// (ADR-0058 point 5). A name version written here before a writer was set
    /// takes this one, and its object is marked changed on its page.
    pub fn set_writer(&mut self, writer: [u8; 32]) {
        self.writer = writer;
        if writer == [0; 32] {
            return;
        }
        let mut stamped = Vec::new();
        for sheet in self.tabs.iter_mut().filter_map(|tab| tab.page.as_mut()) {
            for record in sheet.chips.iter_mut().chain(&mut sheet.detached) {
                if let Some(version) = &mut record.name_version
                    && version.writer == [0; 32]
                {
                    version.writer = writer;
                    stamped.push((sheet.id, record.uuid));
                }
            }
        }
        for (page, object) in stamped {
            self.note_metadata(page, object);
        }
    }

    /// The writer local name versions take; zero until set.
    #[must_use]
    pub fn writer(&self) -> [u8; 32] {
        self.writer
    }

    /// Drain the objects whose metadata changed on `page`, as they stand now.
    /// A page past its deadline drains and gives nothing (Law 0001, expiry row).
    pub fn take_metadata_changes(&mut self, page: SheetId) -> Vec<ObjectMetadata> {
        let changed = self.metadata_dirty.remove(&page).unwrap_or_default();
        let Some(sheet) = self.readable_sheet(page) else {
            return Vec::new();
        };
        changed
            .into_iter()
            .filter_map(|object| record_on(sheet, object))
            .map(|record| ObjectMetadata::of(record, self.writer))
            .collect()
    }

    /// Every record on `page`, attached and detached, for a restate; nothing
    /// for a page past its deadline (Law 0001, expiry row).
    #[must_use]
    pub fn all_metadata(&self, page: SheetId) -> Vec<ObjectMetadata> {
        self.readable_sheet(page).map_or_else(Vec::new, |sheet| {
            sheet
                .chips
                .iter()
                .chain(&sheet.detached)
                .map(|record| ObjectMetadata::of(record, self.writer))
                .collect()
        })
    }

    /// Mark `objects` changed on `page` again, as a failed send leaves them.
    pub fn mark_metadata_dirty(&mut self, page: SheetId, objects: &[ItemId]) {
        if self.sheet(page).is_some() {
            self.metadata_dirty
                .entry(page)
                .or_default()
                .extend(objects.iter().copied());
        }
    }

    /// Apply a peer's entries to their objects' records on every readable page
    /// here, sent for the page whose cross-device identity is `page`. An entry
    /// for an object with no record here waits until one arrives; a page past
    /// its deadline, ended or unknown here takes none. A record it changes on
    /// another page is marked changed there, and one on `page` is not. Returns
    /// how many entries changed a record.
    pub fn apply_object_metadata(&mut self, page: ItemId, entries: Vec<ObjectMetadata>) -> usize {
        let now = self.clock.now();
        // A name is content, so none waits on a page that ended or never stood here.
        let Some(named) = self
            .sheets()
            .find(|sheet| sheet.uuid == page && !sheet.is_due(now))
            .map(Sheet::id)
        else {
            return 0;
        };
        let mut changed = 0;
        for entry in entries {
            if self.terminal_cause(entry.object).is_some() {
                continue;
            }
            match self.apply_entry(named, entry.judged()) {
                Ok(applied) => changed += usize::from(applied),
                Err(entry) => self.hold_metadata(page, entry),
            }
        }
        changed
    }

    /// Adopt `entry` into each record of its object on the readable pages,
    /// marking those it changed on pages other than `named`, the one it was
    /// sent for. Returns whether a record changed, or the entry back when no
    /// record of its object is here.
    fn apply_entry(
        &mut self,
        named: SheetId,
        entry: ObjectMetadata,
    ) -> Result<bool, ObjectMetadata> {
        let writer = self.writer;
        let mut found = false;
        let mut changed = false;
        let mut elsewhere = Vec::new();
        for sheet in self.readable_sheets_mut() {
            if let Some(record) = record_on_mut(sheet, entry.object) {
                found = true;
                if adopt(record, entry.clone(), writer) {
                    changed = true;
                    if sheet.id != named {
                        elsewhere.push(sheet.id);
                    }
                }
            }
        }
        if !found {
            return Err(entry);
        }
        // The sender's channel has it; another page's channel owes it to its peers.
        for page in elsewhere {
            self.note_metadata(page, entry.object);
            self.restated.insert(page);
        }
        Ok(changed)
    }

    /// Keep `entry` until its record arrives, folded into any entry already
    /// held for its object; the oldest goes past [`PENDING_CAP`].
    fn hold_metadata(&mut self, page: ItemId, entry: ObjectMetadata) {
        let held = self
            .metadata_pending
            .iter()
            .position(|(at, held)| *at == page && held.object == entry.object)
            .and_then(|index| self.metadata_pending.remove(index));
        let entry = match held {
            Some((_, mut earlier)) => {
                earlier.absorb(entry);
                earlier
            }
            None => entry,
        };
        if self.metadata_pending.len() >= PENDING_CAP {
            self.metadata_pending.pop_front();
        }
        self.metadata_pending.push_back((page, entry));
    }

    /// Apply waiting entries to every readable record once `id` has the object.
    /// Each entry uses its original page when marking other pages changed.
    pub(crate) fn drain_pending_metadata(&mut self, id: SheetId, object: ItemId) {
        if self
            .readable_sheet(id)
            .is_none_or(|sheet| record_on(sheet, object).is_none())
        {
            return;
        }
        let (waiting, kept): (VecDeque<_>, VecDeque<_>) =
            std::mem::take(&mut self.metadata_pending)
                .into_iter()
                .partition(|(_, held)| held.object == object);
        self.metadata_pending = kept;
        for (sent_for, entry) in waiting {
            let named = self
                .sheets()
                .find(|sheet| sheet.uuid == sent_for)
                .map(Sheet::id);
            if let Some(named) = named {
                let _ = self.apply_entry(named, entry);
            }
        }
    }

    /// Drop pending entries and unsent changes for an object that ended here.
    pub(crate) fn forget_object_metadata(&mut self, object: ItemId) {
        self.metadata_pending
            .retain(|(_, entry)| entry.object != object);
        for changed in self.metadata_dirty.values_mut() {
            changed.remove(&object);
        }
    }

    /// Drop what is held and what changed for page `id`, whose identity is
    /// `page`, as it ends; each name wipes with its owner.
    pub(crate) fn forget_page_metadata(&mut self, id: SheetId, page: ItemId) {
        self.metadata_pending.retain(|(at, _)| *at != page);
        self.metadata_dirty.remove(&id);
    }

    /// Mark `object` changed on `page`, if the page stands.
    pub(crate) fn note_metadata(&mut self, page: SheetId, object: ItemId) {
        if self.sheet(page).is_some() {
            self.metadata_dirty.entry(page).or_default().insert(object);
        }
    }

    /// Fold `from`, a record about to drop, into the record standing its
    /// identity on `there`, marking that page when it learned something.
    /// Returns whether it did.
    pub(crate) fn keep_newer_metadata(&mut self, there: SheetId, from: &SealedChip) -> bool {
        let writer = self.writer;
        let learned = self
            .sheet_mut(there)
            .and_then(|sheet| sheet.chips.iter_mut().find(|chip| chip.uuid == from.uuid))
            .is_some_and(|standing| absorb(standing, from, writer));
        if learned {
            self.note_metadata(there, from.uuid);
        }
        learned
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::clock::ManualClock;
    use crate::store::EditOp;
    use crate::ttl::Ttl;

    type Store = SheetStore<ManualClock>;

    const ALPHA: [u8; 32] = [1; 32];
    const BETA: [u8; 32] = [2; 32];
    const SECRET: &str = "ghp_payload_marker_9f3c";
    const RUNG: Duration = Duration::from_secs(8 * 60 * 60);

    fn store(writer: [u8; 32]) -> (Store, ManualClock) {
        let clock = ManualClock::new();
        let mut store = SheetStore::new(clock.clone())
            .with_grace_snap(false)
            .with_default_rung(Ttl::from_secs(RUNG.as_secs()).unwrap());
        store.set_writer(writer);
        (store, clock)
    }

    fn type_on(store: &mut Store, id: SheetId, text: &str) {
        let end = u32::try_from(store.sheet(id).unwrap().document.utf16_len()).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: end,
                text: text.into(),
            }],
        ));
    }

    fn ship(from: &Store, from_page: SheetId, to: &mut Store, to_page: SheetId) {
        let frontier = to.document_version(to_page).unwrap();
        let batch = from.export_document_updates(from_page, &frontier).unwrap();
        assert_eq!(to.apply_remote_update(to_page, &batch), Ok(()));
    }

    fn page_of(store: &Store, id: SheetId) -> ItemId {
        store.sheet(id).unwrap().uuid()
    }

    /// Hand `from`'s changed entries for a page to its mirror; how many changed a record.
    fn send(from: &mut Store, from_page: SheetId, to: &mut Store, to_page: SheetId) -> usize {
        let entries = from.take_metadata_changes(from_page);
        let page = page_of(to, to_page);
        to.apply_object_metadata(page, entries)
    }

    fn record(store: &Store, id: SheetId, object: ItemId) -> &SealedChip {
        record_on(store.sheet(id).unwrap(), object).expect("a record for the object")
    }

    fn version(counter: u64, writer: [u8; 32]) -> NameVersion {
        NameVersion { counter, writer }
    }

    fn named(object: ItemId, at: NameVersion, name: Option<&str>) -> ObjectMetadata {
        ObjectMetadata {
            object,
            kind: None,
            size: None,
            name: Some((at, name.map(|name| Zeroizing::new(name.to_owned())))),
        }
    }

    fn told(object: ItemId, kind: PeerKind, size: SizeClass) -> ObjectMetadata {
        ObjectMetadata {
            object,
            kind: Some(kind),
            size: Some(size),
            name: None,
        }
    }

    /// One page on each device, its object sealed on alpha and standing on
    /// beta as a record with no value; nothing is left to send.
    struct Shared {
        alpha: Store,
        beta: Store,
        a: SheetId,
        b: SheetId,
        /// Alpha's record, with the value.
        chip: crate::sheet::ChipId,
        /// Beta's record, with none.
        peer: crate::sheet::ChipId,
        object: ItemId,
    }

    impl Shared {
        fn new() -> Self {
            let (mut alpha, _) = store(ALPHA);
            let (mut beta, _) = store(BETA);
            let a = alpha.new_tab().1;
            let b = beta.new_tab().1;
            type_on(&mut alpha, a, "one two");
            let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
            ship(&alpha, a, &mut beta, b);
            alpha.take_metadata_changes(a);
            let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
            let peer = record(&beta, b, object).id();
            Self {
                alpha,
                beta,
                a,
                b,
                chip,
                peer,
                object,
            }
        }

        /// Apply entries to beta's page; how many changed its record.
        fn tell_beta(&mut self, entries: Vec<ObjectMetadata>) -> usize {
            let page = page_of(&self.beta, self.b);
            self.beta.apply_object_metadata(page, entries)
        }

        fn on_alpha(&self) -> &SealedChip {
            record(&self.alpha, self.a, self.object)
        }

        fn on_beta(&self) -> &SealedChip {
            record(&self.beta, self.b, self.object)
        }
    }

    #[test]
    fn name_versions_order_by_counter_then_writer_bytes() {
        let mut early = [0; 32];
        early[31] = 9;
        let mut late = [0; 32];
        late[0] = 1;
        assert!(
            version(2, [0; 32]) > version(1, [u8::MAX; 32]),
            "the counter first"
        );
        assert!(
            version(1, late) > version(1, early),
            "then the writer, first byte first"
        );
        let mut sorted = vec![version(2, early), version(1, late), version(1, early)];
        sorted.sort();
        assert_eq!(
            sorted,
            [version(1, early), version(1, late), version(2, early)]
        );
    }

    #[test]
    fn a_local_rename_after_a_received_higher_counter_takes_one_more() {
        let mut shared = Shared::new();
        let object = shared.object;
        let sent = named(object, version(5, ALPHA), Some("FROM_ALPHA"));
        assert_eq!(shared.tell_beta(vec![sent]), 1);
        assert_eq!(shared.on_beta().name(), Some("FROM_ALPHA"));

        shared.beta.set_chip_name(shared.peer, "FROM_BETA").unwrap();
        assert_eq!(shared.on_beta().name_version(), Some(version(6, BETA)));
    }

    #[test]
    fn concurrent_renames_converge_in_both_delivery_orders() {
        for alpha_first in [true, false] {
            for alpha_twice in [false, true] {
                let mut shared = Shared::new();
                if alpha_twice {
                    shared
                        .alpha
                        .set_chip_name(shared.chip, "ALPHA_DRAFT")
                        .unwrap();
                }
                shared
                    .alpha
                    .set_chip_name(shared.chip, "ALPHA_NAME")
                    .unwrap();
                shared.beta.set_chip_name(shared.peer, "BETA_NAME").unwrap();
                let to_beta = shared.alpha.take_metadata_changes(shared.a);
                let to_alpha = shared.beta.take_metadata_changes(shared.b);
                let at_alpha = page_of(&shared.alpha, shared.a);
                if alpha_first {
                    shared.alpha.apply_object_metadata(at_alpha, to_alpha);
                    shared.tell_beta(to_beta);
                } else {
                    shared.tell_beta(to_beta);
                    shared.alpha.apply_object_metadata(at_alpha, to_alpha);
                }
                // Equal counters fall to the greater writer, beta's.
                let winner = if alpha_twice {
                    "ALPHA_NAME"
                } else {
                    "BETA_NAME"
                };
                assert_eq!(shared.on_alpha().name(), Some(winner));
                assert_eq!(shared.on_beta().name(), Some(winner));
                assert_eq!(
                    shared.on_alpha().name_version(),
                    shared.on_beta().name_version()
                );
            }
        }
    }

    #[test]
    fn a_clear_beats_an_older_name_and_loses_to_a_newer_one() {
        let mut shared = Shared::new();
        let object = shared.object;
        assert_eq!(
            shared.tell_beta(vec![named(object, version(2, ALPHA), Some("OLD"))]),
            1
        );
        assert_eq!(
            shared.tell_beta(vec![named(object, version(1, BETA), None)]),
            0
        );
        assert_eq!(shared.on_beta().name(), Some("OLD"), "an older clear");

        assert_eq!(
            shared.tell_beta(vec![named(object, version(3, ALPHA), None)]),
            1
        );
        assert_eq!(shared.on_beta().name(), None);
        assert_eq!(shared.on_beta().name_version(), Some(version(3, ALPHA)));
        let stale = named(object, version(2, BETA), Some("STALE"));
        assert_eq!(shared.tell_beta(vec![stale]), 0);
        assert_eq!(shared.on_beta().name(), None);

        let newer = named(object, version(4, BETA), Some("NEWER"));
        assert_eq!(shared.tell_beta(vec![newer]), 1);
        assert_eq!(shared.on_beta().name(), Some("NEWER"));
    }

    #[test]
    fn equal_versions_with_different_names_keep_the_local_one() {
        let mut shared = Shared::new();
        shared.beta.set_chip_name(shared.peer, "LOCAL").unwrap();
        let rival = named(shared.object, version(1, BETA), Some("OTHER"));
        assert_eq!(shared.tell_beta(vec![rival]), 0);
        assert_eq!(shared.on_beta().name(), Some("LOCAL"));
    }

    #[test]
    fn an_invalid_received_name_is_skipped_and_the_rest_of_its_entry_applies() {
        let long = "A".repeat(crate::sheet::NAME_CAP + 1);
        for refused in ["not a name", " PADDED ", "9lives", "", long.as_str()] {
            let mut shared = Shared::new();
            shared.beta.set_chip_name(shared.peer, "KEPT").unwrap();
            let mut sent = named(shared.object, version(9, ALPHA), Some(refused));
            sent.kind = Some(PeerKind::Text);
            assert_eq!(shared.tell_beta(vec![sent]), 1, "the kind still applies");
            let face = shared.on_beta();
            assert_eq!(face.name(), Some("KEPT"), "{refused:?}");
            assert_eq!(face.name_version(), Some(version(1, BETA)), "{refused:?}");
            assert!(matches!(
                face.availability(),
                Availability::Peer {
                    kind: Some(PeerKind::Text),
                    size: None
                }
            ));
        }
    }

    #[test]
    fn an_entry_before_its_sentinel_waits_and_applies_when_the_record_arrives() {
        let (mut alpha, _) = store(ALPHA);
        let (mut beta, _) = store(BETA);
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;
        type_on(&mut alpha, a, "one two");
        let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        alpha.set_chip_name(chip, "API_KEY").unwrap();
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();

        assert_eq!(
            send(&mut alpha, a, &mut beta, b),
            0,
            "nothing to apply it to yet"
        );
        assert_eq!(beta.metadata_pending.len(), 1);
        ship(&alpha, a, &mut beta, b);

        let arrived = record(&beta, b, object);
        assert_eq!(arrived.name(), Some("API_KEY"));
        assert_eq!(arrived.name_version(), Some(version(1, ALPHA)));
        assert!(matches!(
            arrived.availability(),
            Availability::Peer {
                kind: Some(PeerKind::Text),
                size: Some(SizeClass::Tiny)
            }
        ));
        assert!(beta.metadata_pending.is_empty());
        assert!(
            beta.take_metadata_changes(b).is_empty(),
            "an applied entry is no change here"
        );
    }

    #[test]
    fn a_rename_sent_for_the_page_an_object_left_reaches_it_where_it_moved() {
        let (mut alpha, _) = store(ALPHA);
        let (mut beta, _) = store(BETA);
        let a = alpha.new_tab().1;
        let (moved_to, sent_for) = (beta.new_tab().1, beta.new_tab().1);
        type_on(&mut alpha, a, "one two");
        let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        ship(&alpha, a, &mut beta, sent_for);
        alpha.take_metadata_changes(a);
        assert!(beta.move_range_to(sent_for, 4, 1, moved_to, 0).is_some());
        assert!(record_on(beta.sheet(sent_for).unwrap(), object).is_none());
        beta.take_restated_pages();
        beta.take_metadata_changes(moved_to);

        alpha.set_chip_name(chip, "MOVED_KEY").unwrap();
        assert_eq!(send(&mut alpha, a, &mut beta, sent_for), 1);
        assert_eq!(record(&beta, moved_to, object).name(), Some("MOVED_KEY"));
        assert!(beta.metadata_pending.is_empty());
        assert_eq!(beta.take_restated_pages(), [moved_to]);
        let owed = beta.take_metadata_changes(moved_to);
        assert_eq!(
            owed.iter().map(|entry| entry.object).collect::<Vec<_>>(),
            [object],
            "owed to the peers of the page it moved to"
        );
    }

    #[test]
    fn an_entry_held_for_one_page_drains_when_its_object_arrives_on_another() {
        let (mut alpha, _) = store(ALPHA);
        let (mut beta, _) = store(BETA);
        let a = alpha.new_tab().1;
        let (sent_for, arrived_on) = (beta.new_tab().1, beta.new_tab().1);
        type_on(&mut alpha, a, "one two");
        let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        alpha.set_chip_name(chip, "API_KEY").unwrap();
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        assert_eq!(send(&mut alpha, a, &mut beta, sent_for), 0);
        assert_eq!(beta.metadata_pending.len(), 1);

        ship(&alpha, a, &mut beta, arrived_on);
        assert_eq!(record(&beta, arrived_on, object).name(), Some("API_KEY"));
        assert!(beta.metadata_pending.is_empty());
        let owed = beta.take_metadata_changes(arrived_on);
        assert_eq!(owed.len(), 1, "owed to the peers of the page it arrived on");
        assert_eq!(
            owed[0].name,
            Some((
                version(1, ALPHA),
                Some(Zeroizing::new("API_KEY".to_owned()))
            ))
        );
    }

    #[test]
    fn a_held_entry_sent_for_the_page_it_drains_onto_marks_nothing() {
        let (mut alpha, _) = store(ALPHA);
        let (mut beta, _) = store(BETA);
        let a = alpha.new_tab().1;
        let b = beta.new_tab().1;
        type_on(&mut alpha, a, "one two");
        let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        alpha.set_chip_name(chip, "API_KEY").unwrap();
        assert_eq!(send(&mut alpha, a, &mut beta, b), 0);

        ship(&alpha, a, &mut beta, b);
        assert!(beta.metadata_pending.is_empty());
        assert!(beta.take_metadata_changes(b).is_empty());
    }

    /// Alpha's object standing on beta's first page, from alpha, and on beta's
    /// second, whose peer is gamma's page; nothing is left to send.
    struct TwoChannels {
        shared: Shared,
        gamma: Store,
        other: SheetId,
        g: SheetId,
    }

    impl TwoChannels {
        fn new() -> Self {
            let mut shared = Shared::new();
            let (mut gamma, _) = store([3; 32]);
            let other = shared.beta.new_tab().1;
            let g = gamma.new_tab().1;
            shared
                .beta
                .stand_peer_record_as(other, 0, shared.object, None, None)
                .unwrap();
            ship(&shared.beta, other, &mut gamma, g);
            for page in [shared.b, other] {
                shared.beta.take_metadata_changes(page);
            }
            shared.beta.take_restated_pages();
            gamma.take_metadata_changes(g);
            Self {
                shared,
                gamma,
                other,
                g,
            }
        }
    }

    #[test]
    fn an_entry_for_one_page_is_owed_to_the_other_pages_its_object_stands_on() {
        let TwoChannels {
            shared:
                Shared {
                    mut alpha,
                    mut beta,
                    a,
                    b,
                    chip,
                    object,
                    ..
                },
            mut gamma,
            other,
            g,
        } = TwoChannels::new();
        alpha.set_chip_name(chip, "SHARED_KEY").unwrap();
        let sent = alpha.take_metadata_changes(a);
        assert_eq!(
            beta.apply_object_metadata(page_of(&beta, b), sent.clone()),
            1
        );
        for page in [b, other] {
            let here = record(&beta, page, object);
            assert_eq!(
                (here.name(), here.name_version()),
                (Some("SHARED_KEY"), Some(version(1, ALPHA)))
            );
        }
        assert_eq!(beta.take_restated_pages(), [other]);
        assert!(
            beta.take_metadata_changes(b).is_empty(),
            "its sender's channel has it"
        );
        let owed = beta.take_metadata_changes(other);
        assert_eq!(
            owed.iter().map(|entry| entry.object).collect::<Vec<_>>(),
            [object]
        );

        assert_eq!(
            gamma.apply_object_metadata(page_of(&gamma, g), owed.clone()),
            1
        );
        assert_eq!(record(&gamma, g, object).name(), Some("SHARED_KEY"));
        assert!(gamma.take_metadata_changes(g).is_empty());

        // Each echo meets an equal version, so it adopts nothing and marks nothing.
        assert_eq!(beta.apply_object_metadata(page_of(&beta, other), owed), 0);
        assert_eq!(beta.apply_object_metadata(page_of(&beta, b), sent), 0);
        for page in [b, other] {
            assert!(beta.take_metadata_changes(page).is_empty());
        }
        assert!(beta.take_restated_pages().is_empty());
    }

    #[test]
    fn a_rename_names_every_record_of_its_object_here() {
        let (mut alpha, _) = store(ALPHA);
        let (here, there) = (alpha.new_tab().1, alpha.new_tab().1);
        let chip = alpha.seal_text_at(here, SECRET, 0, 0).unwrap();
        let object = alpha.sheet(here).unwrap().chip(chip).unwrap().uuid();
        let standing = alpha
            .stand_peer_record_as(there, 0, object, None, None)
            .unwrap();
        for page in [here, there] {
            alpha.take_metadata_changes(page);
        }
        alpha.take_restated_pages();

        alpha.set_chip_name(chip, "BOTH").unwrap();
        for page in [here, there] {
            let named = record(&alpha, page, object);
            assert_eq!(
                (named.name(), named.name_version()),
                (Some("BOTH"), Some(version(1, ALPHA)))
            );
            let owed = alpha.take_metadata_changes(page);
            assert_eq!(
                owed.iter().map(|entry| entry.object).collect::<Vec<_>>(),
                [object]
            );
        }
        assert_eq!(alpha.take_restated_pages(), [there]);

        // A record that kept a higher version sets the next one for both.
        record_on_mut(alpha.sheet_mut(there).unwrap(), object)
            .unwrap()
            .name_version = Some(version(5, BETA));
        alpha.set_chip_name(standing, "FROM_THERE").unwrap();
        for page in [here, there] {
            let named = record(&alpha, page, object);
            assert_eq!(
                (named.name(), named.name_version()),
                (Some("FROM_THERE"), Some(version(6, ALPHA)))
            );
        }
        assert_eq!(alpha.take_restated_pages(), [here]);
    }

    #[test]
    fn a_rename_reaches_a_record_kept_detached_on_another_page() {
        let (mut alpha, _) = store(ALPHA);
        let (kept, there) = (alpha.new_tab().1, alpha.new_tab().1);
        let chip = alpha.seal_text_at(kept, SECRET, 0, 0).unwrap();
        let object = alpha.sheet(kept).unwrap().chip(chip).unwrap().uuid();
        assert!(alpha.apply_ops(
            kept,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 1
            }]
        ));
        let standing = alpha
            .stand_peer_record_as(there, 0, object, None, None)
            .unwrap();
        assert_eq!(alpha.sheet(kept).unwrap().detached().count(), 1);
        alpha.take_metadata_changes(kept);

        alpha.set_chip_name(standing, "KEPT").unwrap();
        let detached = record(&alpha, kept, object);
        assert!(detached.is_local());
        assert_eq!(
            (detached.name(), detached.name_version()),
            (Some("KEPT"), Some(version(1, ALPHA)))
        );
        assert_eq!(alpha.take_metadata_changes(kept).len(), 1);
    }

    #[test]
    fn a_refused_rename_changes_no_record_of_its_object() {
        let (mut alpha, _) = store(ALPHA);
        let (here, there) = (alpha.new_tab().1, alpha.new_tab().1);
        let chip = alpha.seal_text_at(here, SECRET, 0, 0).unwrap();
        let object = alpha.sheet(here).unwrap().chip(chip).unwrap().uuid();
        alpha
            .stand_peer_record_as(there, 0, object, None, None)
            .unwrap();
        alpha.set_chip_name(chip, "FULL").unwrap();
        let spent = version(u64::MAX, BETA);
        record_on_mut(alpha.sheet_mut(there).unwrap(), object)
            .unwrap()
            .name_version = Some(spent);
        for page in [here, there] {
            alpha.take_metadata_changes(page);
        }
        alpha.take_restated_pages();

        assert_eq!(
            alpha.set_chip_name(chip, "NEXT"),
            Err(NameRefusal::VersionsSpent),
            "the highest version here is spent"
        );
        assert_eq!(
            alpha.set_chip_name(chip, "9_LEADS_WITH_A_DIGIT"),
            Err(NameRefusal::OutsideCharset)
        );
        let faces = [here, there].map(|page| {
            let face = record(&alpha, page, object);
            (face.name(), face.name_version())
        });
        assert_eq!(
            faces,
            [
                (Some("FULL"), Some(version(1, ALPHA))),
                (Some("FULL"), Some(spent))
            ]
        );
        for page in [here, there] {
            assert!(alpha.take_metadata_changes(page).is_empty());
        }
        assert!(alpha.take_restated_pages().is_empty());
    }

    #[test]
    fn names_written_before_a_writer_was_set_converge_once_each_device_sets_one() {
        for alpha_first in [true, false] {
            let (mut alpha, _) = store([0; 32]);
            let (mut beta, _) = store([0; 32]);
            let a = alpha.new_tab().1;
            let b = beta.new_tab().1;
            type_on(&mut alpha, a, "one two");
            let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
            ship(&alpha, a, &mut beta, b);
            let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
            let peer = record(&beta, b, object).id();
            alpha.set_chip_name(chip, "ALPHA_NAME").unwrap();
            beta.set_chip_name(peer, "BETA_NAME").unwrap();
            // A relaunch keeps the versions and loses what was marked changed.
            alpha.take_metadata_changes(a);
            beta.take_metadata_changes(b);
            assert_eq!(
                record(&beta, b, object).name_version(),
                Some(version(1, [0; 32]))
            );

            alpha.set_writer(ALPHA);
            beta.set_writer(BETA);
            assert_eq!(
                record(&alpha, a, object).name_version(),
                Some(version(1, ALPHA))
            );
            let to_beta = alpha.take_metadata_changes(a);
            let to_alpha = beta.take_metadata_changes(b);
            assert_eq!((to_beta.len(), to_alpha.len()), (1, 1));
            let (at_alpha, at_beta) = (page_of(&alpha, a), page_of(&beta, b));
            if alpha_first {
                alpha.apply_object_metadata(at_alpha, to_alpha);
                beta.apply_object_metadata(at_beta, to_beta);
            } else {
                beta.apply_object_metadata(at_beta, to_beta);
                alpha.apply_object_metadata(at_alpha, to_alpha);
            }
            // Equal counters fall to the greater writer, beta's.
            assert_eq!(record(&alpha, a, object).name(), Some("BETA_NAME"));
            assert_eq!(record(&beta, b, object).name(), Some("BETA_NAME"));
        }
    }

    #[test]
    fn an_entry_for_a_page_with_no_sheet_here_is_not_held() {
        let (mut beta, _) = store(BETA);
        let b = beta.new_tab().1;
        let ended = page_of(&beta, b);
        assert!(beta.discard_page(b));
        for page in [ItemId::random(), ended] {
            let entry = named(ItemId::random(), version(1, ALPHA), Some("ORPHAN"));
            assert_eq!(beta.apply_object_metadata(page, vec![entry]), 0);
            assert!(beta.metadata_pending.is_empty());
        }
    }

    #[test]
    fn a_held_entry_goes_when_its_page_ends() {
        let (mut beta, _) = store(BETA);
        let [kept, ended] = [beta.new_tab().1, beta.new_tab().1];
        for id in [kept, ended] {
            let entry = named(ItemId::random(), version(1, ALPHA), Some("WAITING"));
            assert_eq!(
                beta.apply_object_metadata(page_of(&beta, id), vec![entry]),
                0
            );
        }
        assert_eq!(beta.metadata_pending.len(), 2);

        assert!(beta.discard_page(ended));
        let held: Vec<ItemId> = beta.metadata_pending.iter().map(|(at, _)| *at).collect();
        assert_eq!(held, [page_of(&beta, kept)]);
    }

    #[test]
    fn a_waiting_metadata_entry_reaches_all_records_and_restates_other_pages() {
        let (mut store, _) = store(BETA);
        let named_page = store.new_tab().1;
        let other_page = store.new_tab().1;
        let chip = store.seal_text_at(named_page, SECRET, 0, 0).unwrap();
        let object = store.sheet(named_page).unwrap().chip(chip).unwrap().uuid();
        store
            .stand_peer_record_as(other_page, 0, object, None, None)
            .unwrap();
        for page in [named_page, other_page] {
            store.take_metadata_changes(page);
        }
        store.take_restated_pages();
        let page = page_of(&store, named_page);
        store.hold_metadata(page, named(object, version(1, ALPHA), Some("WAITING")));

        store.drain_pending_metadata(named_page, object);
        assert!(store.metadata_pending.is_empty());
        for page in [named_page, other_page] {
            assert_eq!(record(&store, page, object).name(), Some("WAITING"));
        }
        assert!(store.take_metadata_changes(named_page).is_empty());
        assert_eq!(store.take_metadata_changes(other_page).len(), 1);
        assert_eq!(store.take_restated_pages(), [other_page]);
    }

    #[test]
    fn the_waiting_cache_evicts_its_oldest_past_256() {
        for (others, kept) in [(PENDING_CAP - 1, true), (PENDING_CAP, false)] {
            let (mut alpha, _) = store(ALPHA);
            let (mut beta, _) = store(BETA);
            let a = alpha.new_tab().1;
            let b = beta.new_tab().1;
            let chip = alpha.seal_text_at(a, SECRET, 0, 0).unwrap();
            alpha.set_chip_name(chip, "OLDEST").unwrap();
            assert_eq!(send(&mut alpha, a, &mut beta, b), 0);
            let strangers = (0..others)
                .map(|_| named(ItemId::random(), version(1, ALPHA), Some("STRANGER")))
                .collect();
            assert_eq!(beta.apply_object_metadata(page_of(&beta, b), strangers), 0);
            assert_eq!(beta.metadata_pending.len(), PENDING_CAP.min(others + 1));

            ship(&alpha, a, &mut beta, b);
            let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
            let name = record(&beta, b, object).name();
            assert_eq!(name.is_some(), kept, "{others} entries after it");
        }
    }

    #[test]
    fn kind_and_size_fill_a_record_with_no_value_once_and_never_flip() {
        let mut shared = Shared::new();
        let object = shared.object;
        let first = told(object, PeerKind::Text, SizeClass::Small);
        assert_eq!(shared.tell_beta(vec![first.clone(), first]), 1);
        let flip = told(object, PeerKind::Image, SizeClass::Huge);
        assert_eq!(shared.tell_beta(vec![flip]), 0);
        assert!(matches!(
            shared.on_beta().availability(),
            Availability::Peer {
                kind: Some(PeerKind::Text),
                size: Some(SizeClass::Small)
            }
        ));
    }

    #[test]
    fn a_record_with_its_value_ignores_a_received_kind_and_size() {
        let mut shared = Shared::new();
        let at_alpha = page_of(&shared.alpha, shared.a);
        let wrong = told(shared.object, PeerKind::Image, SizeClass::Huge);
        assert_eq!(shared.alpha.apply_object_metadata(at_alpha, vec![wrong]), 0);
        assert!(matches!(
            shared.on_alpha().meta(),
            Some(ChipMeta::Text { .. })
        ));
        let restated = shared.alpha.all_metadata(shared.a);
        assert_eq!(restated[0].kind, Some(PeerKind::Text));
        assert_eq!(restated[0].size, Some(SizeClass::Tiny));
    }

    #[test]
    fn a_name_from_before_versions_restates_at_counter_zero_and_any_rename_passes_it() {
        let mut shared = Shared::new();
        let sheet = shared.alpha.sheet_mut(shared.a).unwrap();
        let chip = sheet
            .chips
            .iter_mut()
            .find(|c| c.id == shared.chip)
            .unwrap();
        chip.name = Some(Zeroizing::new("FROM_V4".to_owned()));
        let restated = shared.alpha.all_metadata(shared.a);
        let sent = restated[0].name.clone();
        assert_eq!(
            sent,
            Some((
                version(0, ALPHA),
                Some(Zeroizing::new("FROM_V4".to_owned()))
            ))
        );
        assert_eq!(shared.tell_beta(restated), 1);
        assert_eq!(shared.on_beta().name(), Some("FROM_V4"));

        shared.beta.set_chip_name(shared.peer, "RENAMED").unwrap();
        let back = shared.beta.take_metadata_changes(shared.b);
        let at_alpha = page_of(&shared.alpha, shared.a);
        assert_eq!(shared.alpha.apply_object_metadata(at_alpha, back), 1);
        assert_eq!(shared.on_alpha().name(), Some("RENAMED"));
        assert_eq!(shared.on_alpha().name_version(), Some(version(1, BETA)));
    }

    /// Give `object`'s record on `id` a name with no version, as an `OTSSNAP4` restore does.
    fn name_unversioned(store: &mut Store, id: SheetId, object: ItemId, name: &str) {
        let record = record_on_mut(store.sheet_mut(id).unwrap(), object).unwrap();
        record.name = Some(Zeroizing::new(name.to_owned()));
        record.name_version = None;
    }

    #[test]
    fn two_names_from_before_versions_exchanged_at_once_converge_on_one() {
        for alpha_first in [true, false] {
            let mut shared = Shared::new();
            let object = shared.object;
            name_unversioned(&mut shared.alpha, shared.a, object, "ALPHA_NAME");
            name_unversioned(&mut shared.beta, shared.b, object, "BETA_NAME");
            // Both restates leave before either arrives.
            let to_beta = shared.alpha.all_metadata(shared.a);
            let to_alpha = shared.beta.all_metadata(shared.b);
            let at_alpha = page_of(&shared.alpha, shared.a);
            if alpha_first {
                shared.alpha.apply_object_metadata(at_alpha, to_alpha);
                shared.tell_beta(to_beta);
            } else {
                shared.tell_beta(to_beta);
                shared.alpha.apply_object_metadata(at_alpha, to_alpha);
            }
            let names = (shared.on_alpha().name(), shared.on_beta().name());
            assert_eq!(
                names,
                (Some("BETA_NAME"), Some("BETA_NAME")),
                "{alpha_first}"
            );

            let to_beta = shared.alpha.all_metadata(shared.a);
            let to_alpha = shared.beta.all_metadata(shared.b);
            assert_eq!(shared.tell_beta(to_beta), 0, "settled");
            assert_eq!(shared.alpha.apply_object_metadata(at_alpha, to_alpha), 0);
        }
    }

    #[test]
    fn a_folded_record_keeps_its_name_from_before_versions() {
        // Away's record with no value folds into the value as the value arrives, or drops beside it.
        for value_moves in [true, false] {
            let (mut store, _) = store(ALPHA);
            let [home, away] = [store.new_tab().1, store.new_tab().1];
            type_on(&mut store, home, "ink ");
            let chip = store.seal_text_at(home, SECRET, 4, 0).unwrap();
            let object = store.sheet(home).unwrap().chip(chip).unwrap().uuid();
            store
                .stand_peer_record_as(away, 0, object, None, None)
                .unwrap();
            name_unversioned(&mut store, away, object, "FROM_V4");

            let (edited, at, kept) = if value_moves {
                (home, 4, away)
            } else {
                (away, 0, home)
            };
            assert!(store.apply_ops(
                edited,
                &[EditOp::Delete {
                    pos_u16: at,
                    len_u16: 1
                }]
            ));
            let folded = record(&store, kept, object);
            assert!(folded.is_local(), "{value_moves}");
            assert_eq!(folded.name(), Some("FROM_V4"), "{value_moves}");
            assert_eq!(folded.name_version(), Some(version(0, ALPHA)));
        }
    }

    #[test]
    fn a_changed_entry_goes_when_its_page_ends() {
        let (mut store, _) = store(ALPHA);
        let [kept, discarded] = [store.new_tab().1, store.new_tab().1];
        let (tab, closed) = store.new_tab();
        for id in [kept, discarded, closed] {
            store.seal_text_at(id, SECRET, 0, 0).unwrap();
        }
        assert_eq!(store.metadata_dirty.len(), 3);

        assert!(store.discard_page(discarded));
        assert!(store.close_tab(tab));
        let changed: Vec<SheetId> = store.metadata_dirty.keys().copied().collect();
        assert_eq!(changed, [kept]);

        store.note_metadata(discarded, ItemId::random());
        store.mark_metadata_dirty(closed, &[ItemId::random()]);
        assert_eq!(
            store.metadata_dirty.len(),
            1,
            "an ended page takes no change"
        );
    }

    #[test]
    fn an_applied_entry_marks_nothing_changed() {
        let mut shared = Shared::new();
        let object = shared.object;
        let mut sent = named(object, version(3, ALPHA), Some("ECHOED"));
        sent.kind = Some(PeerKind::Text);
        sent.size = Some(SizeClass::Tiny);
        assert_eq!(shared.tell_beta(vec![sent]), 1);
        assert!(shared.beta.take_metadata_changes(shared.b).is_empty());
        assert_eq!(shared.on_beta().name(), Some("ECHOED"));
    }

    #[test]
    fn taking_changes_drains_them_and_a_second_take_is_empty() {
        let (mut store, _) = store(ALPHA);
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, SECRET, 0, 0).unwrap();
        let object = store.sheet(id).unwrap().chip(chip).unwrap().uuid();
        let sealed = store.take_metadata_changes(id);
        assert_eq!(
            sealed,
            [ObjectMetadata {
                object,
                kind: Some(PeerKind::Text),
                size: Some(SizeClass::Tiny),
                name: None,
            }]
        );
        assert!(store.take_metadata_changes(id).is_empty());

        store.set_chip_name(chip, "NAMED").unwrap();
        let renamed = store.take_metadata_changes(id);
        assert_eq!(
            renamed[0].name,
            Some((version(1, ALPHA), Some(Zeroizing::new("NAMED".to_owned()))))
        );
        store.set_chip_name(chip, " NAMED ").unwrap();
        assert!(
            store.take_metadata_changes(id).is_empty(),
            "the name it has"
        );
        store.set_chip_name(chip, "").unwrap();
        assert_eq!(
            store.take_metadata_changes(id)[0].name,
            Some((version(2, ALPHA), None))
        );

        // A failed send puts its entries back.
        store.mark_metadata_dirty(id, &[object]);
        assert_eq!(store.take_metadata_changes(id).len(), 1);
        assert!(store.take_metadata_changes(id).is_empty());
    }

    #[test]
    fn a_restate_lists_detached_records_too() {
        let (mut store, _) = store(ALPHA);
        let id = store.new_tab().1;
        let kept = store.seal_text_at(id, SECRET, 0, 0).unwrap();
        let gone = store.seal_text_at(id, "ghp_detached", 1, 0).unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 1,
                len_u16: 1,
            }],
        ));
        let sheet = store.sheet(id).unwrap();
        assert_eq!(sheet.detached().count(), 1);
        let uuids = [kept, gone].map(|chip| sheet.owned_chip(chip).unwrap().uuid());
        let listed: Vec<ItemId> = store
            .all_metadata(id)
            .iter()
            .map(|entry| entry.object)
            .collect();
        assert_eq!(listed, uuids);
        assert_eq!(
            store.take_metadata_changes(id).len(),
            2,
            "a restate drains nothing"
        );
    }

    #[test]
    fn a_page_past_its_deadline_gives_and_takes_no_metadata() {
        let (mut store, clock) = store(ALPHA);
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, SECRET, 0, 0).unwrap();
        let object = store.sheet(id).unwrap().chip(chip).unwrap().uuid();
        clock.advance(RUNG + Duration::from_secs(1));
        assert!(store.is_due(id));

        let tab = store
            .tabs()
            .find(|tab| tab.page().map(Sheet::id) == Some(id))
            .unwrap()
            .id();
        assert!(!store.pause_press(tab));
        assert_eq!(
            store.set_rung(tab, Ttl::from_secs(RUNG.as_secs()).unwrap()),
            None
        );
        assert!(!store.observe_peer_hold(
            page_of(&store, id),
            crate::sync::HoldRegister::Held {
                until_wall_ms: clock.wall_ms() + 24 * 60 * 60 * 1_000,
                frozen_ms: RUNG.as_millis() as u64,
                topped_up: true,
            },
        ));
        assert!(store.is_due(id));

        assert!(store.take_metadata_changes(id).is_empty());
        assert!(store.all_metadata(id).is_empty());
        let late = named(object, version(1, BETA), Some("LATE"));
        assert_eq!(
            store.apply_object_metadata(page_of(&store, id), vec![late]),
            0
        );
        assert_eq!(record(&store, id, object).name(), None);
        assert!(
            store.metadata_pending.is_empty(),
            "nor does it wait for one"
        );
    }

    #[test]
    fn a_spent_version_refuses_the_rename_and_nothing_else() {
        let (mut store, _) = store(ALPHA);
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, SECRET, 0, 0).unwrap();
        let other = store.seal_text_at(id, "ghp_other", 1, 0).unwrap();
        store.set_chip_name(chip, "FULL").unwrap();
        let spent = version(u64::MAX, BETA);
        let sheet = store.sheet_mut(id).unwrap();
        sheet
            .chips
            .iter_mut()
            .find(|c| c.id == chip)
            .unwrap()
            .name_version = Some(spent);
        store.take_metadata_changes(id);

        for draft in ["NEXT", ""] {
            assert_eq!(
                store.set_chip_name(chip, draft),
                Err(NameRefusal::VersionsSpent)
            );
        }
        let face = store.sheet(id).unwrap().chip(chip).unwrap();
        assert_eq!(
            (face.name(), face.name_version()),
            (Some("FULL"), Some(spent))
        );
        assert!(store.take_metadata_changes(id).is_empty());
        assert_eq!(store.set_chip_name(other, "OTHER"), Ok(()));
        assert_eq!(&*store.copy_out_chip(chip).unwrap().0, SECRET.as_bytes());
    }

    #[test]
    fn no_payload_marker_reaches_a_metadata_debug() {
        let mut shared = Shared::new();
        shared
            .alpha
            .set_chip_name(shared.chip, "NAME_MARKER_7d1e")
            .unwrap();
        let entries: Vec<ObjectMetadata> = shared
            .alpha
            .take_metadata_changes(shared.a)
            .into_iter()
            .chain(shared.alpha.all_metadata(shared.a))
            .collect();
        let stranger = named(
            ItemId::random(),
            version(1, ALPHA),
            Some("NAME_MARKER_7d1e"),
        );
        shared.tell_beta(entries.iter().cloned().chain([stranger]).collect());
        assert_eq!(shared.beta.metadata_pending.len(), 1);
        let printed = format!(
            "{entries:?} {:?} {:?}",
            shared.beta.all_metadata(shared.b),
            shared.beta.metadata_pending
        );
        let excerpt = shared.on_alpha().excerpt().to_owned();
        assert!(!excerpt.is_empty());
        for marker in [SECRET, "payload_marker", "NAME_MARKER", excerpt.as_str()] {
            assert!(!printed.contains(marker), "{marker} in {printed}");
        }
        assert!(
            printed.contains("named: Some(true)"),
            "the debug says a name stands"
        );
    }

    #[test]
    fn a_seal_a_rename_and_a_clone_mark_their_page_and_a_restore_marks_nothing() {
        let (mut original, clock) = store(ALPHA);
        let id = original.new_tab().1;
        let chip = original.seal_text_at(id, SECRET, 0, 0).unwrap();
        original.set_chip_name(chip, "DRAFT").unwrap();
        original.set_chip_name(chip, "API_KEY").unwrap();
        assert_eq!(original.take_metadata_changes(id).len(), 1);

        let copied = original.copy_fragment(id, 0, 1).unwrap();
        let envelope = copied.envelope.expect("an object was copied");
        let placed = original.paste_fragment(id, 1, 0, &envelope, None).unwrap();
        assert_eq!(placed.cloned, 1);
        let clone = original
            .sheet(id)
            .unwrap()
            .chips()
            .find(|c| c.id() != chip)
            .unwrap();
        assert_eq!(clone.name(), Some("API_KEY"));
        assert_eq!(
            clone.name_version(),
            Some(version(1, ALPHA)),
            "a fresh version"
        );
        let clone = clone.uuid();
        let marked: Vec<ItemId> = original
            .take_metadata_changes(id)
            .iter()
            .map(|entry| entry.object)
            .collect();
        assert_eq!(marked, [clone]);

        let snapshot = original.snapshot(1_000);
        let mut revived = SheetStore::new(clock.clone()).with_grace_snap(false);
        assert_eq!(revived.restore(&snapshot, 1_000), Ok(1));
        let page = revived.sheets().next().unwrap().id();
        assert!(revived.take_metadata_changes(page).is_empty());
        assert_eq!(revived.all_metadata(page).len(), 2);
    }

    /// Alpha and beta each with two inked pages, an object sealed on alpha's
    /// first, which beta moves to its second; neither batch has reached alpha.
    fn moved_by_beta() -> (Store, Store, [SheetId; 2], [SheetId; 2], ItemId) {
        let (mut alpha, _) = store(ALPHA);
        let (mut beta, _) = store(BETA);
        let home = [alpha.new_tab().1, alpha.new_tab().1];
        let mirror = [beta.new_tab().1, beta.new_tab().1];
        for (page, text) in [(0, "ink "), (1, "dest ")] {
            type_on(&mut alpha, home[page], text);
            ship(&alpha, home[page], &mut beta, mirror[page]);
        }
        let chip = alpha.seal_text_at(home[0], SECRET, 4, 0).unwrap();
        ship(&alpha, home[0], &mut beta, mirror[0]);
        alpha.take_metadata_changes(home[0]);
        let moved = beta.move_range_to(mirror[0], 4, 1, mirror[1], 0).unwrap();
        assert_eq!(moved.reattached, 1);
        let object = alpha.sheet(home[0]).unwrap().chip(chip).unwrap().uuid();
        (alpha, beta, home, mirror, object)
    }

    #[test]
    fn a_value_that_follows_its_sentinel_marks_the_page_it_arrives_on() {
        for order in [[1, 0], [0, 1]] {
            let (mut alpha, beta, home, mirror, object) = moved_by_beta();
            for page in order {
                ship(&beta, mirror[page], &mut alpha, home[page]);
            }
            let told = alpha.take_metadata_changes(home[1]);
            assert_eq!(told.len(), 1, "{order:?}");
            assert_eq!(told[0].object, object);
            assert_eq!(told[0].kind, Some(PeerKind::Text));
            assert_eq!(told[0].size, Some(SizeClass::Tiny));
            assert!(alpha.take_metadata_changes(home[0]).is_empty());
        }
    }

    #[test]
    fn a_value_that_follows_keeps_the_newer_name_its_stand_in_learned() {
        let (mut alpha, mut beta, home, mirror, object) = moved_by_beta();
        ship(&beta, mirror[1], &mut alpha, home[1]);
        let renamed = record(&beta, mirror[1], object).id();
        beta.set_chip_name(renamed, "RENAMED_THERE").unwrap();
        assert_eq!(send(&mut beta, mirror[1], &mut alpha, home[1]), 1);

        ship(&beta, mirror[0], &mut alpha, home[0]);
        let arrived = record(&alpha, home[1], object);
        assert!(arrived.is_local(), "the value followed its sentinel");
        assert_eq!(arrived.name(), Some("RENAMED_THERE"));
        assert_eq!(arrived.name_version(), Some(version(1, BETA)));
    }
}
