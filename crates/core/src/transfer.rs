//! Copy, cut, paste and the drags inside a page (Law 0001, ADR-0047): the
//! fragment's routes, the one active cut, and how a reference resolves.

use zeroize::Zeroizing;

use crate::clock::Clock;
use crate::document::{EditIntent, EditSelection, InvalidRange, TextSelection};
use crate::fragment::{Copied, Fragment, Node, placeholder};
use crate::ledger::{DestinationClass, LedgerEvent, SizeClass};
use crate::sheet::{ChipId, ItemId, SealedChip, Sheet, SheetId};
use crate::store::{SheetStore, range_in_body};

/// The store's one active cut (ADR-0047 point 5).
pub(crate) struct ActiveCut {
    /// The page the cut came from, whose detached store holds its objects.
    pub(crate) page: SheetId,
    /// The identity the cut's envelope names.
    pub(crate) token: ItemId,
    /// The objects the cut detached, in selection order.
    pub(crate) members: Vec<ItemId>,
    /// The envelope the cut wrote, which the slot places.
    pub(crate) envelope: Zeroizing<Vec<u8>>,
}

impl ActiveCut {
    /// The cut a page record carries, when its envelope names a cut whose
    /// every object is detached on that page (ADR-0047 point 9).
    pub(crate) fn restored(sheet: &Sheet, envelope: &[u8]) -> Option<Self> {
        let fragment = Fragment::parse(envelope)?;
        let token = fragment.cut?;
        let members: Vec<ItemId> = fragment.references().map(|r| r.uuid).collect();
        let detached = |uuid: &ItemId| sheet.detached.iter().any(|chip| chip.uuid == *uuid);
        (!members.is_empty() && members.iter().all(detached)).then(|| Self {
            page: sheet.id,
            token,
            members,
            envelope: Zeroizing::new(envelope.to_vec()),
        })
    }
}

/// What a paste, a move or a clone placed (ADR-0047 point 6).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Placed {
    /// Where the placed run starts, in UTF-16 code units.
    pub location_u16: u32,
    /// Its length in UTF-16 code units.
    pub length_u16: u32,
    /// Objects that kept their identity: the active cut's, or a move's.
    pub reattached: u32,
    /// Objects cloned from a live one.
    pub cloned: u32,
    /// References placed as `[sealed content · expired]`.
    pub expired: u32,
    /// References placed as `[sealed content · burned]`.
    pub burned: u32,
    /// References placed as `[sealed content · unavailable]`.
    pub unavailable: u32,
    /// The envelope could not be read, so its public text was placed.
    pub unreadable: bool,
}

/// One resolved node, ready to stand in a body.
enum Planned<'a> {
    Ink(&'a str),
    Placeholder(String),
    /// An object keeping its identity; `from` is the page holding it now.
    Reattach {
        uuid: ItemId,
        from: SheetId,
    },
    Clone(Box<SealedChip>),
}

impl Planned<'_> {
    /// Its width in the body, in UTF-16 code units.
    fn width(&self) -> usize {
        match self {
            Planned::Ink(text) => text.encode_utf16().count(),
            Planned::Placeholder(text) => text.encode_utf16().count(),
            Planned::Reattach { .. } | Planned::Clone(_) => 1,
        }
    }
}

impl<C: Clock> SheetStore<C> {
    /// Copy a selection (Law 0001, ADR-0047): its envelope when it holds an
    /// object, and its public text. `None` for an unknown page or a range
    /// [`Sheet::select`] refuses. The page is not touched.
    #[must_use]
    pub fn copy_fragment(&self, id: SheetId, at_u16: u32, len_u16: u32) -> Option<Copied> {
        let (fragment, plain) = self.sheet(id)?.select(at_u16, len_u16)?;
        let envelope = fragment.has_reference().then(|| fragment.envelope());
        Some(Copied { envelope, plain })
    }

    /// Cut a selection: copy it, then delete it as one undo step. The objects
    /// it held detach as the store's one active cut, replacing any before it.
    /// `None`, changing nothing, where the copy or the body refuses.
    pub fn cut_fragment(&mut self, id: SheetId, at_u16: u32, len_u16: u32) -> Option<Copied> {
        let (mut fragment, plain) = self.sheet(id)?.select(at_u16, len_u16)?;
        let members: Vec<ItemId> = fragment.references().map(|r| r.uuid).collect();
        let token = (!members.is_empty()).then(ItemId::random);
        fragment.cut = token;
        let envelope = token.map(|_| fragment.envelope());
        let selection = selection(at_u16, len_u16, at_u16, 0);
        let sheet = self.sheet_mut(id)?;
        let stood = edit_body(sheet, EditIntent::Cut, selection, |sheet| {
            sheet.document.delete(at_u16 as usize, len_u16 as usize)?;
            sheet.blocks.note_delete(at_u16 as usize, len_u16 as usize);
            Ok(())
        });
        self.settle_document(id);
        if !stood {
            return None;
        }
        if let (Some(token), Some(envelope)) = (token, &envelope) {
            self.active_cut = Some(ActiveCut {
                page: id,
                token,
                members,
                envelope: envelope.clone(),
            });
        }
        Some(Copied { envelope, plain })
    }

    /// Paste an envelope over a UTF-16 range as one undo step, resolving each
    /// reference (ADR-0047 point 6). An unreadable envelope places `plain`
    /// instead. `None`, changing nothing, for an unknown page, a bad range,
    /// nothing to place, or a body that refuses the edit.
    pub fn paste_fragment(
        &mut self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
        envelope: &[u8],
        plain: Option<&str>,
    ) -> Option<Placed> {
        if let Some(fragment) = Fragment::parse(envelope) {
            return self.place(id, at_u16, len_u16, &fragment, false);
        }
        let plain = plain.filter(|text| !text.is_empty())?;
        let fallback = Fragment {
            cut: None,
            nodes: vec![Node::Ink(Zeroizing::new(plain.to_owned()))],
        };
        self.place(id, at_u16, len_u16, &fallback, true)
    }

    /// Place the active cut's own envelope, the slot's route (ADR-0047 point
    /// 12). `None` when no cut stands, or as [`SheetStore::paste_fragment`].
    pub fn paste_active_cut(&mut self, id: SheetId, at_u16: u32, len_u16: u32) -> Option<Placed> {
        let envelope = self.active_cut.as_ref()?.envelope.clone();
        self.paste_fragment(id, at_u16, len_u16, &envelope, None)
    }

    /// A drag inside a page: move a range to `to`, measured before the move,
    /// as one step that keeps every object's identity. `None`, changing
    /// nothing, for a `to` inside or at the edge of the range, or a bad range.
    pub fn move_range(
        &mut self,
        id: SheetId,
        from_u16: u32,
        len_u16: u32,
        to_u16: u32,
    ) -> Option<Placed> {
        let sheet = self.sheet(id)?;
        let end = from_u16.checked_add(len_u16)?;
        if (from_u16..=end).contains(&to_u16) || !range_in_body(&sheet.segments, to_u16, 0) {
            return None;
        }
        let (fragment, _) = sheet.select(from_u16, len_u16)?;
        let dest = if to_u16 > from_u16 {
            to_u16 - len_u16
        } else {
            to_u16
        };
        let plan: Vec<Planned<'_>> = fragment
            .nodes
            .iter()
            .map(|node| match node {
                Node::Ink(text) => Planned::Ink(text),
                Node::Ref(reference) => Planned::Reattach {
                    uuid: reference.uuid,
                    from: id,
                },
            })
            .collect();
        let placed = Placed {
            location_u16: dest,
            length_u16: len_u16,
            reattached: count(
                plan.iter()
                    .filter(|p| matches!(p, Planned::Reattach { .. })),
            ),
            ..Placed::default()
        };
        let selection = selection(from_u16, len_u16, dest, len_u16);
        let sheet = self.sheet_mut(id)?;
        let stood = edit_body(sheet, EditIntent::Replacement, selection, |sheet| {
            sheet.document.delete(from_u16 as usize, len_u16 as usize)?;
            sheet
                .blocks
                .note_delete(from_u16 as usize, len_u16 as usize);
            stand(sheet, dest as usize, &plan)
        });
        self.settle_document(id);
        stood.then_some(placed)
    }

    /// The ⌥ drag inside a page: insert a copy of a range at `to` as one
    /// step, every object in it cloned. `None`, changing nothing, for a bad
    /// range.
    pub fn clone_range(
        &mut self,
        id: SheetId,
        from_u16: u32,
        len_u16: u32,
        to_u16: u32,
    ) -> Option<Placed> {
        let (fragment, _) = self.sheet(id)?.select(from_u16, len_u16)?;
        self.place(id, to_u16, 0, &fragment, false)
    }

    /// The active cut's page and objects, for the app's clipboard slot
    /// (ADR-0047 point 12). Faces only; nothing here reads a payload.
    #[must_use]
    pub fn active_cut(&self) -> Option<(SheetId, Vec<&SealedChip>)> {
        let cut = self.active_cut.as_ref()?;
        let sheet = self.sheet(cut.page)?;
        let objects = cut
            .members
            .iter()
            .filter_map(|uuid| sheet.detached.iter().find(|chip| chip.uuid == *uuid))
            .collect();
        Some((cut.page, objects))
    }

    /// End the active cut once any of its objects is not detached on its page.
    pub(crate) fn end_a_broken_cut(&mut self) {
        let broken = self.active_cut.as_ref().is_some_and(|cut| {
            self.sheet(cut.page).is_none_or(|sheet| {
                cut.members
                    .iter()
                    .any(|uuid| sheet.detached.iter().all(|chip| chip.uuid != *uuid))
            })
        });
        if broken {
            self.active_cut = None;
        }
    }

    /// Stand a fragment over a range in one step, then move the chips it
    /// names: the transaction of ADR-0047 point 8.
    fn place(
        &mut self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
        fragment: &Fragment,
        unreadable: bool,
    ) -> Option<Placed> {
        if !range_in_body(&self.sheet(id)?.segments, at_u16, len_u16) {
            return None;
        }
        let mut placed = Placed {
            location_u16: at_u16,
            unreadable,
            ..Placed::default()
        };
        let plan = self.resolve(fragment, &mut placed);
        let width: usize = plan.iter().map(Planned::width).sum();
        if width == 0 {
            return None;
        }
        placed.length_u16 = u32::try_from(width).ok()?;
        let end = at_u16.checked_add(placed.length_u16)?;
        let selection = selection(at_u16, len_u16, end, 0);
        let sheet = self.sheet_mut(id)?;
        let stood = edit_body(sheet, EditIntent::Paste, selection, |sheet| {
            sheet.document.delete(at_u16 as usize, len_u16 as usize)?;
            sheet.blocks.note_delete(at_u16 as usize, len_u16 as usize);
            stand(sheet, at_u16 as usize, &plan)
        });
        if !stood {
            // The prepared clones drop here, zeroized; nothing else moved.
            self.settle_document(id);
            return None;
        }
        let mut sources: Vec<SheetId> = Vec::new();
        let mut clones: Vec<(ItemId, usize)> = Vec::new();
        for item in plan {
            match item {
                Planned::Reattach { uuid, from } if from != id => {
                    let moved = self.sheet_mut(from).and_then(|source| {
                        let index = source.detached.iter().position(|c| c.uuid == uuid)?;
                        Some(source.detached.remove(index))
                    });
                    if let (Some(chip), Some(sheet)) = (moved, self.sheet_mut(id)) {
                        sheet.detached.push(chip);
                    }
                    if !sources.contains(&from) {
                        sources.push(from);
                    }
                }
                Planned::Clone(chip) => {
                    clones.push((chip.uuid, chip.bytes.len()));
                    if let Some(sheet) = self.sheet_mut(id) {
                        sheet.detached.push(*chip);
                    }
                }
                Planned::Ink(_) | Planned::Placeholder(_) | Planned::Reattach { .. } => {}
            }
        }
        // A step there could stand a moved sentinel a second time.
        for source in sources {
            if let Some(sheet) = self.sheet_mut(source) {
                sheet.document.forget_undo();
            }
        }
        // The settle stands every chip the edit placed, which ends a reattached cut.
        self.settle_document(id);
        self.record_clones(id, &clones);
        Some(placed)
    }

    /// Resolve each node in order (ADR-0047 point 6), preparing clones.
    fn resolve<'a>(&mut self, fragment: &'a Fragment, placed: &mut Placed) -> Vec<Planned<'a>> {
        let cut = self
            .active_cut
            .as_ref()
            .filter(|cut| fragment.cut == Some(cut.token))
            .map(|cut| (cut.page, cut.members.clone()));
        let mut reattaching: Vec<ItemId> = Vec::new();
        let mut plan = Vec::with_capacity(fragment.nodes.len());
        for node in &fragment.nodes {
            let uuid = match node {
                Node::Ink(text) => {
                    plan.push(Planned::Ink(text));
                    continue;
                }
                Node::Ref(reference) => reference.uuid,
            };
            if let Some((page, members)) = &cut
                && members.contains(&uuid)
                && !reattaching.contains(&uuid)
            {
                reattaching.push(uuid);
                placed.reattached += 1;
                plan.push(Planned::Reattach { uuid, from: *page });
                continue;
            }
            let id = ChipId(self.next_chip_id);
            if let Some(clone) = self.live_object(uuid).map(|source| source.duplicate(id)) {
                self.next_chip_id += 1;
                placed.cloned += 1;
                plan.push(Planned::Clone(Box::new(clone)));
                continue;
            }
            let word = match self.terminal_cause(uuid) {
                Some(LedgerEvent::Expired) => {
                    placed.expired += 1;
                    "expired"
                }
                Some(_) => {
                    placed.burned += 1;
                    "burned"
                }
                None => {
                    placed.unavailable += 1;
                    "unavailable"
                }
            };
            plan.push(Planned::Placeholder(placeholder(word)));
        }
        plan
    }

    /// A live object by identity, attached or detached, on any page.
    fn live_object(&self, uuid: ItemId) -> Option<&SealedChip> {
        self.sheets()
            .flat_map(|sheet| sheet.chips.iter().chain(&sheet.detached))
            .find(|chip| chip.uuid == uuid)
    }

    /// The newest `expired` or `discarded` record for an identity, the only
    /// evidence of how an object ended (ADR-0047 point 7).
    fn terminal_cause(&self, uuid: ItemId) -> Option<LedgerEvent> {
        self.ledger
            .iter()
            .find(|record| {
                record.item == uuid
                    && matches!(record.event, LedgerEvent::Expired | LedgerEvent::Discarded)
            })
            .map(|record| record.event)
    }

    /// One `sealed` per clone, under the page it landed on.
    fn record_clones(&mut self, id: SheetId, clones: &[(ItemId, usize)]) {
        let offset = self.clock.local_offset_seconds();
        let Some(tab) = self.tab_of(id) else {
            return;
        };
        let label = tab.label(offset);
        let created = tab.page().map_or(0, Sheet::created_wall_ms);
        for (uuid, len) in clones {
            self.record(
                LedgerEvent::Sealed,
                *uuid,
                label.clone(),
                created,
                SizeClass::of(*len),
                DestinationClass::None,
            );
        }
    }
}

/// Stand a plan in a body from `at`, narrating each write (ADR-0013).
fn stand(sheet: &mut Sheet, at: usize, plan: &[Planned<'_>]) -> Result<(), InvalidRange> {
    let mut pos = at;
    for item in plan {
        match item {
            Planned::Ink(text) => {
                sheet.document.insert(pos, text)?;
                sheet.blocks.note_insert(pos, text);
            }
            Planned::Placeholder(text) => {
                sheet.document.insert(pos, text)?;
                sheet.blocks.note_insert(pos, text);
            }
            Planned::Reattach { uuid, .. } => {
                sheet.document.insert_chip(pos, *uuid)?;
                sheet.blocks.note_sentinel(pos);
            }
            Planned::Clone(chip) => {
                sheet.document.insert_chip(pos, chip.uuid)?;
                sheet.blocks.note_sentinel(pos);
            }
        }
        pos += item.width();
    }
    Ok(())
}

/// One structural edit of a body as one undo step (ADR-0047 point 8). A
/// refusal partway reverts the body, clears its undo and returns false.
fn edit_body(
    sheet: &mut Sheet,
    intent: EditIntent,
    selection: EditSelection,
    edit: impl FnOnce(&mut Sheet) -> Result<(), InvalidRange>,
) -> bool {
    let before = sheet.document.snapshot_selection(selection.before);
    let checkpoint = sheet.document.checkpoint();
    if edit(sheet).is_err() {
        sheet.document.rollback(&checkpoint);
        return false;
    }
    match before {
        Some(before) => {
            sheet
                .document
                .commit_edit_with_selection(intent, None, before, selection.after);
        }
        None => sheet.document.commit_edit(intent, None),
    }
    true
}

/// The selections on both sides of one edit.
fn selection(at: u32, len: u32, after_at: u32, after_len: u32) -> EditSelection {
    EditSelection {
        before: TextSelection {
            location_u16: at,
            length_u16: len,
        },
        after: TextSelection {
            location_u16: after_at,
            length_u16: after_len,
        },
    }
}

/// A count as the outcome's width.
fn count<T>(items: impl Iterator<Item = T>) -> u32 {
    u32::try_from(items.count()).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::clock::ManualClock;
    use crate::ledger::LEDGER_RETENTION_MS;
    use crate::sheet::Segment;
    use crate::store::EditOp;
    use crate::ttl::Ttl;

    const HOUR: Duration = Duration::from_secs(60 * 60);
    const A: &str = "ghp_first_n0ts3cr3t";
    const B: &str = "ghp_second_n0ts3cr3t";

    fn store() -> (SheetStore<ManualClock>, ManualClock) {
        let clock = ManualClock::new();
        let store = SheetStore::new(clock.clone())
            .with_grace_snap(false)
            .with_default_rung(Ttl::MIN);
        (store, clock)
    }

    /// `ab` then object A then `cd` then object B then `ef`: eight units.
    fn mixed(store: &mut SheetStore<ManualClock>) -> (SheetId, ChipId, ChipId) {
        let id = store.new_tab().1;
        let a = store.seal_text(id, A).unwrap();
        let b = store.seal_text(id, B).unwrap();
        assert!(store.sync_document(
            id,
            vec![
                Segment::Ink("ab".into()),
                Segment::Chip(a),
                Segment::Ink("cd".into()),
                Segment::Chip(b),
                Segment::Ink("ef".into()),
            ],
        ));
        (id, a, b)
    }

    fn body(store: &SheetStore<ManualClock>, id: SheetId) -> String {
        store
            .sheet(id)
            .unwrap()
            .segments()
            .iter()
            .map(|segment| match segment {
                Segment::Ink(text) => text.clone(),
                Segment::Chip(_) => "\u{FFFC}".to_string(),
            })
            .collect()
    }

    fn uuid_of(store: &SheetStore<ManualClock>, chip: ChipId) -> ItemId {
        store.live_object_by_id(chip).unwrap().uuid
    }

    /// The identities standing on a page, in order.
    fn standing(store: &SheetStore<ManualClock>, id: SheetId) -> Vec<ItemId> {
        let sheet = store.sheet(id).unwrap();
        sheet
            .segments()
            .iter()
            .filter_map(|segment| match segment {
                Segment::Chip(chip) => sheet.chip(*chip).map(SealedChip::uuid),
                Segment::Ink(_) => None,
            })
            .collect()
    }

    fn detached(store: &SheetStore<ManualClock>, id: SheetId) -> Vec<ItemId> {
        store
            .sheet(id)
            .unwrap()
            .detached()
            .map(SealedChip::uuid)
            .collect()
    }

    fn payload_at(store: &SheetStore<ManualClock>, id: SheetId, index: usize) -> Vec<u8> {
        let sheet = store.sheet(id).unwrap();
        let chips: Vec<ChipId> = sheet
            .segments()
            .iter()
            .filter_map(|segment| match segment {
                Segment::Chip(chip) => Some(*chip),
                Segment::Ink(_) => None,
            })
            .collect();
        store.copy_out_chip(chips[index]).unwrap().0.to_vec()
    }

    impl<C: Clock> SheetStore<C> {
        fn live_object_by_id(&self, chip: ChipId) -> Option<&SealedChip> {
            self.sheets()
                .flat_map(|sheet| sheet.chips.iter().chain(&sheet.detached))
                .find(|owned| owned.id == chip)
        }
    }

    #[test]
    fn a_cut_chip_is_detached_not_reaped() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let records = store.ledger().count();

        let cut = store.cut_fragment(id, 2, 1).unwrap();
        assert!(cut.envelope.is_some());
        assert_eq!(body(&store, id), "abcd\u{FFFC}ef");
        assert_eq!(detached(&store, id), vec![uuid]);
        assert!(store.copy_out_chip(a).is_none(), "off the page");
        assert_eq!(store.ledger().count(), records, "a cut records nothing");
        let (page, objects) = store.active_cut().unwrap();
        assert_eq!(page, id);
        assert_eq!(
            objects.iter().map(|chip| chip.uuid).collect::<Vec<_>>(),
            vec![uuid]
        );
    }

    #[test]
    fn a_cut_detaches_every_object_in_one_step_and_undo_stands_them_all() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = vec![uuid_of(&store, a), uuid_of(&store, b)];
        let cut = store.cut_fragment(id, 0, 8).unwrap();
        assert_eq!(
            cut.plain.as_str(),
            "ab[sealed content \u{b7} tiny]cd[sealed content \u{b7} tiny]ef"
        );
        assert_eq!(body(&store, id), "");
        assert_eq!(detached(&store, id), uuids);
        let objects: Vec<ItemId> = store
            .active_cut()
            .unwrap()
            .1
            .iter()
            .map(|c| c.uuid)
            .collect();
        assert_eq!(objects, uuids, "together in the slot, in order");

        assert!(store.undo(id), "one step");
        assert_eq!(body(&store, id), "ab\u{FFFC}cd\u{FFFC}ef");
        assert_eq!(standing(&store, id), uuids);
        assert!(store.active_cut().is_none(), "undo ended the cut");
    }

    #[test]
    fn a_cut_of_ink_alone_names_no_cut_and_leaves_the_one_standing() {
        let (mut store, _) = store();
        let (id, ..) = mixed(&mut store);
        store.cut_fragment(id, 2, 1).unwrap();
        let ink = store.cut_fragment(id, 0, 2).unwrap();
        assert!(ink.envelope.is_none());
        assert_eq!(ink.plain.as_str(), "ab");
        assert_eq!(
            store.active_cut().unwrap().1.len(),
            1,
            "the earlier cut stands"
        );
    }

    #[test]
    fn a_later_cut_replaces_the_active_one_and_leaves_its_objects_detached() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let first = store.cut_fragment(id, 2, 1).unwrap().envelope.unwrap();
        store.cut_fragment(id, 4, 1).unwrap();
        let objects: Vec<ItemId> = store
            .active_cut()
            .unwrap()
            .1
            .iter()
            .map(|c| c.uuid)
            .collect();
        assert_eq!(objects, vec![uuid_of(&store, b)]);
        assert_eq!(
            detached(&store, id).len(),
            2,
            "the first cut's object stays"
        );

        // The first fragment no longer names the active cut, so it clones.
        let placed = store.paste_fragment(id, 0, 0, &first, None).unwrap();
        assert_eq!((placed.reattached, placed.cloned), (0, 1));
        assert!(detached(&store, id).contains(&uuid_of(&store, a)));
    }

    #[test]
    fn a_cut_the_body_refuses_changes_nothing() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let records = store.ledger().count();
        store.sheet_mut(id).unwrap().document.fail_writes_after(0);
        assert!(store.cut_fragment(id, 0, 8).is_none());
        assert_eq!(body(&store, id), "ab\u{FFFC}cd\u{FFFC}ef");
        assert!(detached(&store, id).is_empty());
        assert!(store.active_cut().is_none());
        assert_eq!(store.ledger().count(), records);
        assert!(store.copy_out_chip(a).is_some());
    }

    #[test]
    fn a_pasted_reference_reattaches_by_id() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let envelope = store.cut_fragment(id, 2, 1).unwrap().envelope.unwrap();
        let placed = store.paste_fragment(id, 7, 0, &envelope, None).unwrap();
        assert_eq!(placed.reattached, 1);
        assert_eq!(placed.cloned, 0);
        assert_eq!(body(&store, id), "abcd\u{FFFC}ef\u{FFFC}");
        assert_eq!(
            standing(&store, id)[1],
            uuid,
            "the same object, by identity"
        );
        assert!(store.copy_out_chip(a).is_some(), "the same chip id");
        assert!(
            store.active_cut().is_none(),
            "its first paste ended the cut"
        );
    }

    #[test]
    fn the_first_paste_of_a_cut_reattaches_all_and_a_later_one_clones() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = vec![uuid_of(&store, a), uuid_of(&store, b)];
        let envelope = store.cut_fragment(id, 0, 8).unwrap().envelope.unwrap();

        let first = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!((first.reattached, first.cloned), (2, 0));
        assert_eq!(standing(&store, id), uuids);

        let sealed_before = store
            .ledger()
            .filter(|record| record.event() == LedgerEvent::Sealed)
            .count();
        let second = store.paste_fragment(id, 8, 0, &envelope, None).unwrap();
        assert_eq!((second.reattached, second.cloned), (0, 2));
        let all = standing(&store, id);
        assert_eq!(all.len(), 4);
        assert!(
            !uuids.contains(&all[2]) && !uuids.contains(&all[3]),
            "new identities"
        );
        assert_eq!(
            payload_at(&store, id, 2),
            A.as_bytes(),
            "the payload, cloned core-side"
        );
        assert_eq!(payload_at(&store, id, 3), B.as_bytes());
        let sealed_after = store
            .ledger()
            .filter(|record| record.event() == LedgerEvent::Sealed)
            .count();
        assert_eq!(sealed_after, sealed_before + 2, "one sealed per clone");
    }

    #[test]
    fn a_fragment_not_naming_the_cut_clones_its_objects_and_the_cut_stands() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let copied = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        let cut = store.cut_fragment(id, 2, 1).unwrap().envelope.unwrap();

        let placed = store.paste_fragment(id, 0, 0, &copied, None).unwrap();
        assert_eq!((placed.reattached, placed.cloned), (0, 1));
        assert_eq!(detached(&store, id), vec![uuid], "still in the slot");
        assert!(store.active_cut().is_some());

        let placed = store.paste_fragment(id, 0, 0, &cut, None).unwrap();
        assert_eq!(placed.reattached, 1, "the cut's own fragment reattaches");
        assert_eq!(standing(&store, id)[0], uuid);
    }

    #[test]
    fn a_cut_pasted_on_another_page_moves_there_and_clears_the_source_undo() {
        let (mut store, _) = store();
        let (home, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let away = store.new_tab().1;
        let envelope = store.cut_fragment(home, 2, 1).unwrap().envelope.unwrap();
        assert!(store.can_undo(home));

        let placed = store.paste_fragment(away, 0, 0, &envelope, None).unwrap();
        assert_eq!(placed.reattached, 1);
        assert_eq!(standing(&store, away), vec![uuid]);
        assert!(detached(&store, home).is_empty(), "it left its page");
        assert!(
            !store.can_undo(home),
            "an undo there would stand the moved sentinel twice"
        );
        assert!(store.undo(away));
        assert_eq!(detached(&store, away), vec![uuid], "undone where it landed");
    }

    #[test]
    fn a_paste_after_copy_clones_every_live_reference_without_its_receipt() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        assert!(store.mark_chip_concealed(a, "receipt-42".into()));
        let envelope = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        let placed = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!((placed.reattached, placed.cloned), (0, 1));
        let sheet = store.sheet(id).unwrap();
        let Segment::Chip(clone) = sheet.segments()[0] else {
            panic!("the clone stands first");
        };
        let clone = sheet.chip(clone).unwrap();
        assert_ne!(clone.uuid, uuid_of(&store, a));
        assert!(clone.conceal().is_none(), "the receipt was the original's");
        assert_eq!(sheet.chip_count(), 3);
    }

    #[test]
    fn a_reference_to_a_removed_object_clones_the_retained_one_and_undo_reattaches_it() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let envelope = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        assert!(store.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 2,
                len_u16: 1
            }]
        ));
        assert_eq!(detached(&store, id), vec![uuid]);

        let placed = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!(
            (placed.reattached, placed.cloned),
            (0, 1),
            "paste clones it"
        );
        assert_eq!(
            detached(&store, id),
            vec![uuid],
            "the removed one waits for undo"
        );
        assert_eq!(
            placed.expired + placed.burned + placed.unavailable,
            0,
            "no removed placeholder"
        );

        assert!(store.undo(id), "the paste");
        assert!(store.undo(id), "the removal");
        assert!(
            standing(&store, id).contains(&uuid),
            "undo, not paste, reattaches it"
        );
    }

    #[test]
    fn an_expired_reference_says_so_while_evidence_remains_then_is_unavailable() {
        let (mut store, clock) = store();
        let (id, ..) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 0, 8).unwrap().envelope.unwrap();
        clock.advance(HOUR);
        assert_eq!(store.expire_due(), vec![id]);

        let page = store.new_tab().1;
        let placed = store.paste_fragment(page, 0, 0, &envelope, None).unwrap();
        assert_eq!(placed.expired, 2);
        assert_eq!(
            body(&store, page),
            "ab[sealed content \u{b7} expired]cd[sealed content \u{b7} expired]ef"
        );
        assert!(
            store.sheet(page).unwrap().chips().next().is_none(),
            "nothing came back"
        );

        clock.advance(Duration::from_millis(LEDGER_RETENTION_MS + 1));
        let later = store.new_tab().1;
        let placed = store.paste_fragment(later, 0, 0, &envelope, None).unwrap();
        assert_eq!(
            (placed.expired, placed.unavailable),
            (0, 2),
            "never guessed expired"
        );
    }

    #[test]
    fn a_burned_reference_says_so() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 0, 8).unwrap().envelope.unwrap();
        assert!(store.delete_chip(a));
        let placed = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!((placed.burned, placed.cloned), (1, 1));
        assert!(body(&store, id).starts_with("ab[sealed content \u{b7} burned]cd\u{FFFC}ef"));

        // Closing a page burns what it held.
        let other = store.new_tab().1;
        let tab = store
            .tabs()
            .find(|tab| tab.page().is_some_and(|p| p.id() == id))
            .unwrap()
            .id();
        assert!(store.live_object_by_id(b).is_some());
        assert!(store.close_tab(tab));
        let placed = store.paste_fragment(other, 0, 0, &envelope, None).unwrap();
        assert_eq!(placed.burned, 2);
    }

    #[test]
    fn an_unknown_reference_is_unavailable_and_never_called_expired() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let foreign = format!(
            r#"{{"version":1,"nodes":[{{"ink":"from elsewhere "}},{{"ref":{{"uuid":"{}"}}}}]}}"#,
            ItemId::random()
        );
        let placed = store
            .paste_fragment(id, 0, 0, foreign.as_bytes(), None)
            .unwrap();
        assert_eq!((placed.unavailable, placed.expired), (1, 0));
        assert_eq!(
            body(&store, id),
            "from elsewhere [sealed content \u{b7} unavailable]"
        );
    }

    #[test]
    fn an_unreadable_envelope_pastes_its_public_text_and_says_so() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let placed = store
            .paste_fragment(
                id,
                0,
                0,
                br#"{"version":9}"#,
                Some("ink [sealed content · small]"),
            )
            .unwrap();
        assert!(placed.unreadable);
        assert_eq!(body(&store, id), "ink [sealed content · small]");
        assert_eq!(placed.length_u16, 28);

        let before = body(&store, id);
        assert!(store.paste_fragment(id, 0, 0, b"garbage", None).is_none());
        assert!(
            store
                .paste_fragment(id, 0, 0, b"garbage", Some(""))
                .is_none()
        );
        assert_eq!(
            body(&store, id),
            before,
            "nothing to place, nothing changed"
        );
    }

    #[test]
    fn a_paste_is_one_step_and_replaces_the_selection_it_covers() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 5, 1).unwrap().envelope.unwrap();
        // A clone of B over object A and `c`, which the paste covers.
        let placed = store.paste_fragment(id, 2, 2, &envelope, None).unwrap();
        assert_eq!(placed.location_u16, 2);
        assert_eq!(placed.length_u16, 1);
        assert_eq!(body(&store, id), "ab\u{FFFC}d\u{FFFC}ef");
        assert_eq!(
            detached(&store, id),
            vec![uuid_of(&store, a)],
            "covered, so removed"
        );

        assert!(store.undo(id), "the whole paste is one step");
        assert_eq!(body(&store, id), "ab\u{FFFC}cd\u{FFFC}ef");
        assert_eq!(
            standing(&store, id),
            vec![uuid_of(&store, a), uuid_of(&store, b)]
        );
    }

    #[test]
    fn a_paste_the_body_refuses_partway_changes_nothing_on_any_page() {
        let (mut store, _) = store();
        let (home, a, b) = mixed(&mut store);
        let away = store.new_tab().1;
        assert!(store.apply_ops(
            away,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "x".into()
            }]
        ));
        let envelope = store.cut_fragment(home, 0, 8).unwrap().envelope.unwrap();
        let records = store.ledger().count();

        // Ink and object A's sentinel stand; the third write is refused.
        store.sheet_mut(away).unwrap().document.fail_writes_after(2);
        assert!(store.paste_fragment(away, 1, 0, &envelope, None).is_none());
        assert_eq!(body(&store, away), "x", "the body reverted");
        assert_eq!(
            detached(&store, home),
            vec![uuid_of(&store, a), uuid_of(&store, b)]
        );
        assert!(store.active_cut().is_some(), "the cut still stands");
        assert!(store.can_undo(home), "the source page kept its undo");
        assert_eq!(store.ledger().count(), records);

        // A copy's paste refused the same way puts no clone in any roster.
        assert!(store.undo(home));
        let envelope = store.copy_fragment(home, 0, 8).unwrap().envelope.unwrap();
        store.sheet_mut(away).unwrap().document.fail_writes_after(3);
        assert!(store.paste_fragment(away, 1, 0, &envelope, None).is_none());
        assert_eq!(body(&store, away), "x");
        assert!(store.sheet(away).unwrap().detached().next().is_none());
        assert_eq!(store.sheet(home).unwrap().chip_count(), 2);
        assert_eq!(store.ledger().count(), records, "no clone was recorded");

        // And the transaction runs whole once nothing refuses.
        let placed = store.paste_fragment(away, 1, 0, &envelope, None).unwrap();
        assert_eq!(placed.cloned, 2);
    }

    #[test]
    fn a_mixed_paste_keeps_its_order_with_each_cause_in_position() {
        let (mut store, clock) = store();
        let (doomed, ..) = mixed(&mut store);
        let doomed_envelope = store.copy_fragment(doomed, 2, 1).unwrap().envelope.unwrap();
        clock.advance(HOUR);
        store.expire_due();
        let (id, a, _) = mixed(&mut store);
        let live = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        let expired = Fragment::parse(&doomed_envelope).unwrap();
        let alive = Fragment::parse(&live).unwrap();
        let mut nodes = vec![Node::Ink(Zeroizing::new("1 ".into()))];
        nodes.extend(alive.nodes);
        nodes.push(Node::Ink(Zeroizing::new(" 2 ".into())));
        nodes.extend(expired.nodes);
        nodes.push(Node::Ink(Zeroizing::new(" 3 ".into())));
        nodes.push(Node::Ref(crate::fragment::Reference {
            uuid: ItemId::random(),
        }));
        let mixed = Fragment { cut: None, nodes }.envelope();

        let page = store.new_tab().1;
        let placed = store.paste_fragment(page, 0, 0, &mixed, None).unwrap();
        assert_eq!(
            (placed.cloned, placed.expired, placed.unavailable),
            (1, 1, 1)
        );
        assert_eq!(
            body(&store, page),
            "1 \u{FFFC} 2 [sealed content \u{b7} expired] 3 [sealed content \u{b7} unavailable]"
        );
        assert_eq!(payload_at(&store, page, 0), A.as_bytes());
        assert_ne!(standing(&store, page)[0], uuid_of(&store, a));
    }

    #[test]
    fn the_slot_places_the_active_cut_without_the_pasteboard() {
        let (mut store, _) = store();
        assert!(
            store.paste_active_cut(SheetId::from_raw(1), 0, 0).is_none(),
            "no cut"
        );
        let (id, a, _) = mixed(&mut store);
        store.cut_fragment(id, 0, 3).unwrap();
        let placed = store.paste_active_cut(id, 5, 0).unwrap();
        assert_eq!(placed.reattached, 1);
        assert_eq!(body(&store, id), "cd\u{FFFC}efab\u{FFFC}");
        assert_eq!(standing(&store, id)[1], uuid_of(&store, a));
        assert!(
            store.paste_active_cut(id, 0, 0).is_none(),
            "placed once, the cut ended"
        );
    }

    #[test]
    fn the_active_cut_ends_with_its_page() {
        let (mut store, _) = store();
        let (id, ..) = mixed(&mut store);
        let envelope = store.cut_fragment(id, 0, 8).unwrap().envelope.unwrap();
        let tab = store.tabs().next().unwrap().id();
        assert!(store.close_tab(tab));
        assert!(store.active_cut().is_none());
        let page = store.new_tab().1;
        let placed = store.paste_fragment(page, 0, 0, &envelope, None).unwrap();
        assert_eq!(placed.burned, 2, "a closed page burns its cut objects");
    }

    #[test]
    fn a_drag_inside_a_page_moves_ink_and_objects_in_one_step_keeping_identity() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = vec![uuid_of(&store, a), uuid_of(&store, b)];
        let placed = store.move_range(id, 1, 3, 7).unwrap();
        assert_eq!(
            (placed.location_u16, placed.length_u16, placed.reattached),
            (4, 3, 1)
        );
        assert_eq!(body(&store, id), "ad\u{FFFC}eb\u{FFFC}cf");
        assert_eq!(standing(&store, id), vec![uuids[1], uuids[0]]);
        assert!(store.copy_out_chip(a).is_some(), "the same chip");
        assert!(detached(&store, id).is_empty());

        assert!(store.move_range(id, 1, 3, 2).is_none(), "inside the range");
        assert!(store.move_range(id, 1, 3, 4).is_none(), "at its edge");
        assert!(store.move_range(id, 1, 3, 99).is_none(), "past the body");

        assert!(store.undo(id), "one step");
        assert_eq!(body(&store, id), "ab\u{FFFC}cd\u{FFFC}ef");
        assert_eq!(standing(&store, id), uuids);
    }

    #[test]
    fn an_option_drag_clones_every_object_in_one_step() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let originals = vec![uuid_of(&store, a), uuid_of(&store, b)];
        let placed = store.clone_range(id, 0, 8, 8).unwrap();
        assert_eq!((placed.cloned, placed.reattached), (2, 0));
        let all = standing(&store, id);
        assert_eq!(&all[..2], &originals[..]);
        assert!(!originals.contains(&all[2]) && !originals.contains(&all[3]));
        assert!(store.undo(id));
        assert_eq!(standing(&store, id), originals);
    }

    #[test]
    fn the_active_cut_survives_a_relaunch_and_its_first_paste_reattaches() {
        let (mut store, clock) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let envelope = store.cut_fragment(id, 2, 1).unwrap().envelope.unwrap();
        let snapshot = store.snapshot(1_000_000);
        assert_eq!(
            snapshot.capacity(),
            snapshot.len(),
            "Law 0004, with a cut in it"
        );

        let mut revived = SheetStore::new(clock).with_grace_snap(false);
        revived.restore(&snapshot, 1_000_000).unwrap();
        let page = revived.sheets().next().unwrap().id();
        let objects: Vec<ItemId> = revived
            .active_cut()
            .unwrap()
            .1
            .iter()
            .map(|c| c.uuid)
            .collect();
        assert_eq!(objects, vec![uuid]);
        let placed = revived.paste_fragment(page, 0, 0, &envelope, None).unwrap();
        assert_eq!(placed.reattached, 1);
        assert_eq!(standing(&revived, page)[0], uuid);
    }

    #[test]
    fn a_cut_whose_objects_are_not_all_detached_restores_as_no_cut() {
        let (mut store, clock) = store();
        let (id, ..) = mixed(&mut store);
        store.cut_fragment(id, 0, 8).unwrap();
        // One object stands again under the cut's nose, as damage would leave it.
        let sheet = store.sheet_mut(id).unwrap();
        let back = sheet.detached.remove(0);
        sheet.chips.push(back);
        let uuid = sheet.chips[0].uuid;
        assert!(sheet.document.insert_chip(0, uuid).is_ok());
        sheet.document.commit(None);
        let snapshot = store.snapshot(0);

        let mut revived = SheetStore::new(clock).with_grace_snap(false);
        revived.restore(&snapshot, 0).unwrap();
        assert!(revived.active_cut().is_none());
        assert_eq!(revived.sheets().next().unwrap().detached().count(), 1);
    }
}
