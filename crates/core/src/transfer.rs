//! Copy, cut, paste and the drags inside a page and between pages (Law 0001;
//! ADR-0045 and ADR-0046): the fragment's routes, the one active
//! cut, and how a reference resolves.

use std::borrow::Cow;
use std::collections::HashSet;

use zeroize::Zeroizing;

use crate::clock::Clock;
use crate::continuous::ContinuousEdit;
use crate::document::{EditIntent, EditSelection, InvalidRange, TextSelection};
use crate::fragment::{Copied, CopyRefusal, Fragment, Node, ink_of, placeholder};
use crate::ledger::{DestinationClass, LedgerEvent, SizeClass};
use crate::metadata::NameVersion;
use crate::note::Note;
use crate::sheet::{ChipId, ItemId, SealedChip, Segment, Sheet, SheetId, judge_name};
use crate::store::{EditOp, SheetStore, range_in_body};

/// The store's one active cut (ADR-0046 point 3).
#[derive(Clone)]
pub(crate) struct ActiveCut {
    /// The anchor page whose persisted record contains the cut envelope.
    pub(crate) page: SheetId,
    /// The identity the cut's envelope names.
    pub(crate) token: ItemId,
    /// The objects the cut detached, in selection order.
    pub(crate) members: Vec<ItemId>,
    /// The envelope the cut wrote, which the slot places.
    pub(crate) envelope: Zeroizing<Vec<u8>>,
}

impl ActiveCut {
    /// Read the anchor page's cut; store restore then validates all member sources.
    pub(crate) fn restored(sheet: &Sheet, envelope: &[u8]) -> Option<Self> {
        let fragment = Fragment::parse(envelope)?;
        let token = fragment.cut?;
        let members: Vec<ItemId> = fragment.references().map(|r| r.uuid).collect();
        let detached = |uuid: &ItemId| sheet.detached.iter().any(|chip| chip.uuid == *uuid);
        members.first().is_some_and(detached).then(|| Self {
            page: sheet.id,
            token,
            members,
            envelope: Zeroizing::new(envelope.to_vec()),
        })
    }
}

/// What a paste, a move or a clone placed (Law 0001, sealed fragment representation).
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
    /// References placed as `[sealed content · unavailable]` with no record
    /// and no terminal record here; never one counted in `elsewhere`.
    pub unavailable: u32,
    /// References placed as `[sealed content · unavailable]` because the
    /// value is on another device (ADR-0058 point 4), beside `unavailable`.
    pub elsewhere: u32,
    /// The envelope could not be read, so its public text was placed.
    pub unreadable: bool,
    /// Pages past their deadline the route swept before resolving
    /// (Law 0001, expiry row).
    pub pages_expired: u32,
}

/// One page range in a continuous selection; separators are projection newlines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FragmentSelection {
    /// Runtime identifier of the selected page.
    pub page: SheetId,
    /// Stable identity observed when the selection was projected.
    pub expected_uuid: ItemId,
    /// Document version observed when the selection was projected.
    pub expected_version: Option<Vec<u8>>,
    /// Start offset in the page's UTF-16 text.
    pub at_u16: u32,
    /// Selected length in UTF-16 code units.
    pub len_u16: u32,
    /// Whether the selection includes the following projection newline.
    pub separator_after: bool,
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
    /// Copy a selection: its envelope when it holds an object, and its public
    /// text. Refused for an unknown page, a page past its deadline
    /// (Law 0001, expiry row), a range [`Sheet::select`] refuses or an
    /// envelope past a cap (Law 0001, copy row).
    pub fn copy_fragment(
        &self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<Copied, CopyRefusal> {
        let (fragment, plain) = self.selected(id, at_u16, len_u16)?;
        let envelope = composed(&fragment)?;
        Ok(Copied { envelope, plain })
    }

    /// Compose an ordered selection across pages through the core (ADR-0045 point 1).
    pub fn copy_fragments(&self, ranges: &[FragmentSelection]) -> Result<Copied, CopyRefusal> {
        let (fragment, plain) = self.selected_fragments(ranges)?;
        let envelope = composed(&fragment)?;
        Ok(Copied { envelope, plain })
    }

    fn selected_fragments(
        &self,
        ranges: &[FragmentSelection],
    ) -> Result<(Fragment, Zeroizing<String>), CopyRefusal> {
        if ranges.is_empty() {
            return Err(CopyRefusal::Refused);
        }
        let now = self.clock.now();
        let mut seen = HashSet::new();
        let selected = ranges
            .iter()
            .map(|range| {
                let sheet = self.sheet(range.page).ok_or(CopyRefusal::Refused)?;
                if !seen.insert(range.page)
                    || sheet.uuid() != range.expected_uuid
                    || sheet.is_due(now)
                    || range
                        .expected_version
                        .as_ref()
                        .is_some_and(|version| *version != sheet.document.version())
                {
                    return Err(CopyRefusal::Refused);
                }
                if range.len_u16 == 0 {
                    return range_in_body(sheet.segments(), range.at_u16, 0)
                        .then(|| {
                            (
                                Fragment {
                                    cut: None,
                                    nodes: Vec::new(),
                                },
                                Zeroizing::new(String::new()),
                            )
                        })
                        .ok_or(CopyRefusal::Refused);
                }
                sheet
                    .select(range.at_u16, range.len_u16)
                    .ok_or(CopyRefusal::Refused)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut fragment = Fragment {
            cut: None,
            nodes: Vec::new(),
        };
        let mut plain = Zeroizing::new(String::new());
        for (range, (part, text)) in ranges.iter().zip(selected) {
            fragment.nodes.extend(part.nodes);
            plain.push_str(&text);
            if range.separator_after {
                fragment.nodes.push(Node::Ink(Zeroizing::new("\n".into())));
                plain.push('\n');
            }
        }
        Ok((fragment, plain))
    }

    /// Compose the selected ranges, then delete them as one surface gesture.
    pub fn cut_continuous(
        &mut self,
        scope: &str,
        ranges: &[FragmentSelection],
        edit: &ContinuousEdit,
    ) -> Result<Copied, CopyRefusal> {
        let (mut fragment, plain) = self.selected_fragments(ranges)?;
        if !deletes_selection(edit, ranges) {
            return Err(CopyRefusal::Refused);
        }
        let members: Vec<_> = fragment
            .references()
            .map(|reference| reference.uuid)
            .collect();
        let anchor = members.first().and_then(|uuid| {
            self.sheets()
                .find(|sheet| sheet.chips().any(|chip| chip.uuid == *uuid))
                .map(Sheet::id)
        });
        fragment.cut = anchor.map(|_| ItemId::random());
        let envelope = composed(&fragment)?;
        let mut edit = edit.clone();
        edit.intent = EditIntent::Cut;
        if !self.apply_continuous(scope, &edit) {
            return Err(CopyRefusal::Refused);
        }
        if let (Some(page), Some(token), Some(envelope)) = (anchor, fragment.cut, envelope.as_ref())
        {
            self.active_cut = Some(ActiveCut {
                page,
                token,
                members,
                envelope: envelope.clone(),
            });
            self.end_a_broken_cut();
        }
        Ok(Copied { envelope, plain })
    }

    /// Resolve and insert a fragment after the surface's deletion and join operations.
    pub fn paste_continuous(
        &mut self,
        scope: &str,
        edit: &ContinuousEdit,
        target: SheetId,
        at_u16: u32,
        envelope: &[u8],
        plain: Option<&str>,
    ) -> Option<Placed> {
        let (fragment, unreadable) = match Fragment::parse(envelope) {
            Some(fragment) => (fragment, false),
            None => (
                Fragment {
                    cut: None,
                    nodes: vec![Node::Ink(ink_of(Cow::Borrowed(plain?))?)],
                },
                true,
            ),
        };
        let mut placed = Placed {
            location_u16: at_u16,
            unreadable,
            ..Placed::default()
        };
        let plan = self.resolve(&fragment, &mut placed);
        self.place_continuous_plan(scope, edit, target, plan, placed, false)
    }

    /// Move or clone selected source ranges through one coordinated surface edit.
    pub fn move_continuous(
        &mut self,
        scope: &str,
        ranges: &[FragmentSelection],
        edit: &ContinuousEdit,
        target: SheetId,
        at_u16: u32,
        cloning: bool,
    ) -> Option<Placed> {
        let (fragment, _) = self.selected_fragments(ranges).ok()?;
        if cloning {
            if edit.pages.iter().any(|part| !part.ops.is_empty()) {
                return None;
            }
        } else if !deletes_selection(edit, ranges) {
            return None;
        }
        let mut placed = Placed {
            location_u16: at_u16,
            ..Placed::default()
        };
        let plan = if cloning {
            self.resolve(&fragment, &mut placed)
        } else {
            let mut plan = Vec::new();
            let mut seen = HashSet::new();
            for node in &fragment.nodes {
                match node {
                    Node::Ink(text) => plan.push(Planned::Ink(text)),
                    Node::Ref(reference) => {
                        if !seen.insert(reference.uuid) {
                            return None;
                        }
                        let source = ranges.iter().find_map(|range| {
                            self.readable_sheet(range.page)?
                                .chips
                                .iter()
                                .any(|chip| chip.uuid == reference.uuid)
                                .then_some(range.page)
                        })?;
                        placed.reattached += 1;
                        plan.push(Planned::Reattach {
                            uuid: reference.uuid,
                            from: source,
                        });
                    }
                }
            }
            plan
        };
        self.place_continuous_plan(scope, edit, target, plan, placed, !cloning)
    }

    fn place_continuous_plan(
        &mut self,
        scope: &str,
        edit: &ContinuousEdit,
        target: SheetId,
        plan: Vec<Planned<'_>>,
        mut placed: Placed,
        moving: bool,
    ) -> Option<Placed> {
        let at_u16 = placed.location_u16;
        let mut edit = edit.clone();
        if edit.pages.iter().any(|part| {
            part.ops
                .iter()
                .any(|op| !matches!(op, EditOp::Delete { .. }))
        }) {
            return None;
        }
        let target_index = edit.pages.iter().position(|part| part.page_id == target)?;
        let now = self.clock.now();
        if edit.pages.iter().any(|part| {
            self.sheet(part.page_id).is_none_or(|sheet| {
                sheet.uuid() != part.expected_uuid
                    || part
                        .expected_version
                        .as_ref()
                        .is_some_and(|version| *version != sheet.document.version())
                    || sheet.is_due(now)
                    || !crate::store::validate_edit_ops(sheet, &part.ops)
            })
        }) {
            return None;
        }
        let width: usize = plan.iter().map(Planned::width).sum();
        placed.length_u16 = u32::try_from(width).ok()?;
        if width == 0 {
            return None;
        }
        at_u16.checked_add(placed.length_u16)?;
        edit.selection.after.location_u16 = edit
            .selection
            .after
            .location_u16
            .checked_add(placed.length_u16)?;
        edit.selection.after.length_u16 = 0;
        edit.intent = if moving {
            EditIntent::Replacement
        } else {
            EditIntent::Paste
        };
        let prior_cut = self.active_cut.clone();
        let mut moved = Vec::new();
        let mut clones = Vec::new();
        let mut inserted = Vec::new();
        let mut at = at_u16;
        for item in plan {
            let width = u32::try_from(item.width()).ok()?;
            let op = match item {
                Planned::Ink(text) => EditOp::Insert {
                    pos_u16: at,
                    text: text.into(),
                },
                Planned::Placeholder(text) => EditOp::Insert { pos_u16: at, text },
                Planned::Clone(mut chip) => {
                    let id = chip.id();
                    chip.stood = true;
                    inserted.push(chip.uuid);
                    clones.extend(chip.local_len().map(|len| (chip.uuid, len)));
                    self.sheet_mut(target)?.detached.push(*chip);
                    EditOp::InsertChip {
                        pos_u16: at,
                        chip: id,
                    }
                }
                Planned::Reattach { uuid, from } => {
                    if from != target {
                        let source = self.sheet_mut(from)?;
                        let (chip, standing) = if let Some(index) =
                            source.detached.iter().position(|chip| chip.uuid == uuid)
                        {
                            (source.detached.remove(index), false)
                        } else if moving {
                            let index = source.chips.iter().position(|chip| chip.uuid == uuid)?;
                            (source.chips.remove(index), true)
                        } else {
                            return None;
                        };
                        self.sheet_mut(target)?.detached.push(chip);
                        moved.push((uuid, from, standing));
                    }
                    let chip = self
                        .sheet(target)?
                        .detached
                        .iter()
                        .chain(&self.sheet(target)?.chips)
                        .find(|chip| chip.uuid == uuid)?
                        .id();
                    EditOp::InsertChip { pos_u16: at, chip }
                }
            };
            edit.pages[target_index].ops.push(op);
            at += width;
        }
        let reset_pages: Vec<_> = moved
            .iter()
            .map(|(_, from, _)| *from)
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        if !self.apply_continuous_resetting(scope, &edit, &reset_pages) {
            self.sheet_mut(target)?
                .detached
                .retain(|chip| !inserted.contains(&chip.uuid));
            let mut restored = Vec::new();
            for (uuid, from, standing) in moved {
                let destination = self.sheet_mut(target)?;
                let index = destination
                    .detached
                    .iter()
                    .position(|chip| chip.uuid == uuid)?;
                let chip = destination.detached.remove(index);
                if standing {
                    self.sheet_mut(from)?.chips.push(chip);
                } else {
                    self.sheet_mut(from)?.detached.push(chip);
                }
                restored.push(from);
            }
            for from in restored {
                self.settle_document(from);
            }
            self.active_cut = prior_cut;
            return None;
        }
        if moving && !moved.is_empty() {
            let transitions: Vec<_> = moved
                .iter()
                .map(|(uuid, from, _)| (*uuid, *from, target))
                .collect();
            if !self.record_continuous_moves(scope, &transitions) {
                self.clear_continuous_history(scope);
            }
        }
        for (uuid, from, _) in moved {
            self.restated.insert(from);
            self.drain_pending_metadata(target, uuid);
            self.drain_pending_notes(target, uuid);
            self.note_metadata(target, uuid);
        }
        for (uuid, _) in &clones {
            self.note_metadata(target, *uuid);
        }
        self.record_clones(target, &clones);
        if moving {
            self.active_cut = prior_cut;
        }
        self.end_a_broken_cut();
        Some(placed)
    }

    /// Place the current cut through the surface's coordinated edit path.
    pub fn paste_active_cut_continuous(
        &mut self,
        scope: &str,
        edit: &ContinuousEdit,
        target: SheetId,
        at_u16: u32,
    ) -> Option<Placed> {
        let envelope = self.active_cut.as_ref()?.envelope.clone();
        self.paste_continuous(scope, edit, target, at_u16, &envelope, None)
    }

    /// Compose runs the shell shows of a page, a preview's rendered text and
    /// its objects by chip id, as [`SheetStore::copy_fragment`] composes a
    /// range: its envelope when an object is among them, and its public text.
    /// Refused for an unknown page, a page past its deadline (Law 0001,
    /// expiry row), an object off the page or an envelope past a cap (Law
    /// 0001, copy row).
    pub fn compose_fragment(&self, id: SheetId, shown: &[Segment]) -> Result<Copied, CopyRefusal> {
        let (fragment, plain) = self
            .readable_sheet(id)
            .and_then(|sheet| sheet.compose(shown))
            .ok_or(CopyRefusal::Refused)?;
        let envelope = composed(&fragment)?;
        Ok(Copied { envelope, plain })
    }

    /// Copy a selection, then delete it as one step, its objects detaching as
    /// the one active cut. Refused, changing nothing, where either refuses.
    pub fn cut_fragment(
        &mut self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<Copied, CopyRefusal> {
        let (mut fragment, plain) = self.selected(id, at_u16, len_u16)?;
        let members: Vec<ItemId> = fragment.references().map(|r| r.uuid).collect();
        let token = (!members.is_empty()).then(ItemId::random);
        fragment.cut = token;
        let envelope = composed(&fragment)?;
        let selection = selection(at_u16, len_u16, at_u16, 0);
        let sheet = self.sheet_mut(id).ok_or(CopyRefusal::Refused)?;
        let stood = edit_body(sheet, EditIntent::Cut, selection, |sheet| {
            sheet.document.delete(at_u16 as usize, len_u16 as usize)?;
            sheet.blocks.note_delete(at_u16 as usize, len_u16 as usize);
            Ok(())
        });
        self.settle_document(id);
        if !stood {
            return Err(CopyRefusal::Refused);
        }
        if let (Some(token), Some(envelope)) = (token, &envelope) {
            self.active_cut = Some(ActiveCut {
                page: id,
                token,
                members,
                envelope: envelope.clone(),
            });
            // The settle may have moved a value to a page standing its sentinel.
            self.end_a_broken_cut();
        }
        Ok(Copied { envelope, plain })
    }

    /// Paste an envelope over a range as one step, resolving each reference;
    /// an unreadable one places `plain`. `None` on refusal, keeping only its sweep.
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
        let plain = plain.and_then(|text| ink_of(Cow::Borrowed(text)))?;
        let fallback = Fragment {
            cut: None,
            nodes: vec![Node::Ink(plain)],
        };
        self.place(id, at_u16, len_u16, &fallback, true)
    }

    /// Place the active cut's own envelope, the slot's route
    /// (sealed row spec, The clipboard slot). `None` when no cut stands, or
    /// as [`SheetStore::paste_fragment`].
    pub fn paste_active_cut(&mut self, id: SheetId, at_u16: u32, len_u16: u32) -> Option<Placed> {
        let envelope = self.active_cut.as_ref()?.envelope.clone();
        self.paste_fragment(id, at_u16, len_u16, &envelope, None)
    }

    /// A drag inside a page: move a range to `to`, measured before the move, as
    /// one step keeping every object. `None` for a `to` in the range, a bad one
    /// or a page past its deadline.
    pub fn move_range(
        &mut self,
        id: SheetId,
        from_u16: u32,
        len_u16: u32,
        to_u16: u32,
    ) -> Option<Placed> {
        if self.is_due(id) {
            return None;
        }
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
        let plan = reattaching(&fragment, id);
        let placed = Placed {
            location_u16: dest,
            length_u16: len_u16,
            reattached: reattached(&plan),
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

    /// A drag between pages (Law 0001, drag row): move a range from `source`
    /// to `at` on `dest` as one transaction keeping every object. `None`,
    /// changing neither page, for one page, a bad range or point, or a due page.
    pub fn move_range_to(
        &mut self,
        source: SheetId,
        from_u16: u32,
        len_u16: u32,
        dest: SheetId,
        at_u16: u32,
    ) -> Option<Placed> {
        if source == dest
            || len_u16 == 0
            || self.is_due(dest)
            || !range_in_body(&self.sheet(dest)?.segments, at_u16, 0)
        {
            return None;
        }
        let (fragment, _) = self.selected(source, from_u16, len_u16).ok()?;
        let mut plan = reattaching(&fragment, source);
        let placed = Placed {
            location_u16: at_u16,
            reattached: reattached(&plan),
            ..Placed::default()
        };
        let sheet = self.sheet_mut(source)?;
        let checkpoint = sheet.document.checkpoint();
        let selection = selection(from_u16, len_u16, from_u16, 0);
        let stood = edit_body(sheet, EditIntent::Replacement, selection, |sheet| {
            sheet.document.delete(from_u16 as usize, len_u16 as usize)?;
            sheet
                .blocks
                .note_delete(from_u16 as usize, len_u16 as usize);
            Ok(())
        });
        if !stood {
            self.settle_document(source);
            return None;
        }
        // Defer following other pages' sentinels until both edits succeed.
        self.sheet_mut(source)?.settle_roster();
        plan.retain(|item| match item {
            Planned::Reattach { uuid, .. } => self
                .sheet(dest)
                .is_none_or(|sheet| sheet.document.chip_position(*uuid).is_none()),
            _ => true,
        });
        if plan.iter().all(|item| item.width() == 0) {
            self.settle_document(source);
            return Some(placed);
        }
        let moved = self.stand_plan(dest, at_u16, 0, EditIntent::Replacement, plan, placed);
        if moved.is_none() {
            // The destination refused, so the source takes its range back.
            if let Some(sheet) = self.sheet_mut(source) {
                sheet.document.rollback(&checkpoint);
            }
        }
        self.settle_document(source);
        moved
    }

    /// The ⌥ drag inside a page: a copy of a range at `to`, every object
    /// cloned, as one step. `None` for a bad range.
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
    /// (sealed row spec, The clipboard slot). Faces only; nothing here reads a
    /// payload.
    #[must_use]
    pub fn active_cut(&self) -> Option<(SheetId, Vec<&SealedChip>)> {
        let cut = self.active_cut.as_ref()?;
        let objects: Vec<_> = cut
            .members
            .iter()
            .filter_map(|uuid| {
                self.sheets()
                    .flat_map(|sheet| sheet.detached.iter())
                    .find(|chip| chip.uuid == *uuid)
            })
            .collect();
        (objects.len() == cut.members.len()).then_some((cut.page, objects))
    }

    /// End the active cut when any member lacks a readable detached source.
    pub(crate) fn end_a_broken_cut(&mut self) {
        let broken = self.active_cut.as_ref().is_some_and(|cut| {
            self.sheet(cut.page).is_none()
                || cut.members.iter().any(|uuid| {
                    self.readable_sheets()
                        .all(|sheet| sheet.detached.iter().all(|chip| chip.uuid != *uuid))
                })
        });
        if broken {
            self.active_cut = None;
        }
    }

    /// Resolve a fragment, then stand it over a range: a paste.
    fn place(
        &mut self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
        fragment: &Fragment,
        unreadable: bool,
    ) -> Option<Placed> {
        if !range_in_body(&self.sheet(id)?.segments, at_u16, len_u16) || self.is_due(id) {
            return None;
        }
        // Sweep first, as a load does, so a due page's objects resolve expired.
        let pages_expired = if fragment.has_reference() {
            count(self.expire_due().into_iter())
        } else {
            0
        };
        let mut placed = Placed {
            location_u16: at_u16,
            unreadable,
            pages_expired,
            ..Placed::default()
        };
        let plan = self.resolve(fragment, &mut placed);
        self.stand_plan(id, at_u16, len_u16, EditIntent::Paste, plan, placed)
    }

    /// Stand a plan over a range in one step, then move the chips it names:
    /// the transaction of Law 0001's sealed fragment representation. `None`
    /// once the body reverts.
    fn stand_plan(
        &mut self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
        intent: EditIntent,
        plan: Vec<Planned<'_>>,
        mut placed: Placed,
    ) -> Option<Placed> {
        let width: usize = plan.iter().map(Planned::width).sum();
        if width == 0 {
            return None;
        }
        placed.length_u16 = u32::try_from(width).ok()?;
        let end = at_u16.checked_add(placed.length_u16)?;
        let selection = selection(at_u16, len_u16, end, 0);
        let sheet = self.sheet_mut(id)?;
        let stood = edit_body(sheet, intent, selection, |sheet| {
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
                    self.drain_pending_metadata(id, uuid);
                    self.drain_pending_notes(id, uuid);
                    self.note_metadata(id, uuid);
                    if !sources.contains(&from) {
                        sources.push(from);
                    }
                }
                Planned::Clone(chip) => {
                    clones.extend(chip.local_len().map(|len| (chip.uuid, len)));
                    let uuid = chip.uuid;
                    if let Some(sheet) = self.sheet_mut(id) {
                        sheet.detached.push(*chip);
                    }
                    self.note_metadata(id, uuid);
                }
                Planned::Ink(_) | Planned::Placeholder(_) | Planned::Reattach { .. } => {}
            }
        }
        // A step there could stand a moved sentinel a second time.
        for source in sources {
            if let Some(sheet) = self.sheet_mut(source) {
                sheet.document.forget_undo();
                self.restated.insert(source);
            }
        }
        // The settle stands every chip the edit placed, which ends a reattached cut.
        self.settle_document(id);
        self.record_clones(id, &clones);
        Some(placed)
    }

    /// Resolve each node in order (Law 0001, sealed fragment representation),
    /// preparing clones.
    fn resolve<'a>(&mut self, fragment: &'a Fragment, placed: &mut Placed) -> Vec<Planned<'a>> {
        let cut = self
            .active_cut
            .as_ref()
            .filter(|cut| fragment.cut == Some(cut.token))
            .map(|cut| cut.members.clone());
        let mut reattaching: Vec<ItemId> = Vec::new();
        let mut plan = Vec::with_capacity(fragment.nodes.len());
        for node in &fragment.nodes {
            let reference = match node {
                Node::Ink(text) => {
                    plan.push(Planned::Ink(text));
                    continue;
                }
                Node::Ref(reference) => reference,
            };
            let uuid = reference.uuid;
            if let Some(members) = &cut
                && members.contains(&uuid)
                && !reattaching.contains(&uuid)
                && let Some(page) = self
                    .readable_sheets()
                    .find(|sheet| sheet.detached.iter().any(|chip| chip.uuid == uuid))
                    .map(Sheet::id)
            {
                reattaching.push(uuid);
                placed.reattached += 1;
                plan.push(Planned::Reattach { uuid, from: page });
                continue;
            }
            let id = ChipId(self.next_chip_id);
            match self.live_object(uuid).map(|source| source.duplicate(id)) {
                Some(Some(mut clone)) => {
                    self.next_chip_id += 1;
                    // The envelope's name and note, the name judged as a typed one is.
                    clone.name = reference
                        .name
                        .as_ref()
                        .and_then(|name| judge_name(name.as_str()).ok().flatten())
                        .map(|name| Zeroizing::new(name.to_owned()));
                    // A new identity, so its name starts a version of its own.
                    let writer = self.writer;
                    clone.name_version = clone.name.as_ref().map(|_| NameVersion::first(writer));
                    clone.note = reference.note.as_deref().map(|text| Note::holding(text));
                    placed.cloned += 1;
                    plan.push(Planned::Clone(Box::new(clone)));
                    continue;
                }
                // Live here with its value elsewhere, so there is nothing to clone.
                Some(None) => {
                    placed.elsewhere += 1;
                    plan.push(Planned::Placeholder(placeholder("unavailable")));
                    continue;
                }
                None => {
                    if self.sheets().any(|sheet| {
                        sheet.is_due(self.clock.now())
                            && sheet
                                .chips
                                .iter()
                                .chain(&sheet.detached)
                                .any(|chip| chip.uuid == uuid)
                    }) {
                        placed.expired += 1;
                        plan.push(Planned::Placeholder(placeholder("expired")));
                        continue;
                    }
                }
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

    /// A readable page's range as a fragment and its public text
    /// (Law 0001, expiry row).
    fn selected(
        &self,
        id: SheetId,
        at_u16: u32,
        len_u16: u32,
    ) -> Result<(Fragment, Zeroizing<String>), CopyRefusal> {
        self.readable_sheet(id)
            .and_then(|sheet| sheet.select(at_u16, len_u16))
            .ok_or(CopyRefusal::Refused)
    }

    /// A live object by identity, attached or detached, on any page.
    fn live_object(&self, uuid: ItemId) -> Option<&SealedChip> {
        self.readable_sheets()
            .flat_map(|sheet| sheet.chips.iter().chain(&sheet.detached))
            .filter(|chip| chip.uuid == uuid)
            .max_by_key(|chip| chip.is_local())
    }

    /// The newest `expired` or `discarded` record for an identity, the only
    /// evidence of how an object ended (Law 0001, lifecycle states).
    pub(crate) fn terminal_cause(&self, uuid: ItemId) -> Option<LedgerEvent> {
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

fn deletes_selection(edit: &ContinuousEdit, ranges: &[FragmentSelection]) -> bool {
    let mut remaining: Vec<_> = ranges.iter().filter(|range| range.len_u16 > 0).collect();
    for part in &edit.pages {
        for op in &part.ops {
            let EditOp::Delete { pos_u16, len_u16 } = op else {
                return false;
            };
            if *len_u16 == 0 {
                continue;
            }
            let Some(index) = remaining.iter().position(|range| {
                range.page == part.page_id
                    && range.expected_uuid == part.expected_uuid
                    && range.at_u16 == *pos_u16
                    && range.len_u16 == *len_u16
            }) else {
                return false;
            };
            remaining.remove(index);
        }
    }
    remaining.is_empty()
}

/// One structural edit of a body as one undo step
/// (Law 0001, sealed fragment representation). A refusal partway reverts the
/// body, clears its undo and returns false.
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

/// A copy's or a cut's envelope, `None` for ink alone; refused past a cap.
fn composed(fragment: &Fragment) -> Result<Option<Zeroizing<Vec<u8>>>, CopyRefusal> {
    fragment
        .has_reference()
        .then(|| fragment.envelope())
        .transpose()
        .map_err(CopyRefusal::PastCap)
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

/// A selection's nodes as a plan that stands each object again by identity,
/// taken from `from`: a move's plan.
fn reattaching(fragment: &Fragment, from: SheetId) -> Vec<Planned<'_>> {
    fragment
        .nodes
        .iter()
        .map(|node| match node {
            Node::Ink(text) => Planned::Ink(text),
            Node::Ref(reference) => Planned::Reattach {
                uuid: reference.uuid,
                from,
            },
        })
        .collect()
}

/// How many objects a plan stands again by identity.
fn reattached(plan: &[Planned<'_>]) -> u32 {
    count(
        plan.iter()
            .filter(|item| matches!(item, Planned::Reattach { .. })),
    )
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
    use crate::fragment::{EnvelopeCap, REFERENCE_CAP};
    use crate::ledger::LEDGER_RETENTION_MS;
    use crate::sheet::{NameRefusal, PeerKind, Segment};
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

    fn fragment_range(
        store: &SheetStore<ManualClock>,
        page: SheetId,
        at_u16: u32,
        len_u16: u32,
        separator_after: bool,
    ) -> FragmentSelection {
        FragmentSelection {
            page,
            expected_uuid: store.sheet(page).unwrap().uuid(),
            expected_version: Some(store.sheet(page).unwrap().document.version()),
            at_u16,
            len_u16,
            separator_after,
        }
    }

    fn surface_deletion(
        store: &SheetStore<ManualClock>,
        ranges: &[FragmentSelection],
    ) -> ContinuousEdit {
        ContinuousEdit {
            pages: ranges
                .iter()
                .enumerate()
                .map(|(index, range)| crate::continuous::ContinuousPageEdit {
                    page_id: range.page,
                    expected_uuid: store.sheet(range.page).unwrap().uuid(),
                    expected_version: Some(store.sheet(range.page).unwrap().document.version()),
                    ops: (range.len_u16 > 0)
                        .then_some(EditOp::Delete {
                            pos_u16: range.at_u16,
                            len_u16: range.len_u16,
                        })
                        .into_iter()
                        .collect(),
                    join_next: range
                        .separator_after
                        .then(|| ranges.get(index + 1).map(|next| next.expected_uuid)),
                })
                .collect(),
            intent: EditIntent::Cut,
            selection: selection(
                0,
                ranges
                    .iter()
                    .map(|range| range.len_u16 + u32::from(range.separator_after))
                    .sum(),
                0,
                0,
            ),
        }
    }

    #[test]
    fn continuous_native_move_restores_ownership_on_undo_without_replacing_active_cut() {
        let (mut store, _) = store();
        let (clipboard_page, ..) = mixed(&mut store);
        let original_cut = store
            .cut_fragment(clipboard_page, 2, 1)
            .unwrap()
            .envelope
            .unwrap();
        let (first, first_chip, _) = mixed(&mut store);
        name_and_note(&mut store, first_chip, "API_KEY", "rotate monthly");
        let (second, ..) = mixed(&mut store);
        let target = store.new_tab().1;
        let originals: Vec<_> = standing(&store, first)
            .into_iter()
            .chain(standing(&store, second))
            .collect();
        let ranges = [
            fragment_range(&store, first, 0, 8, true),
            fragment_range(&store, second, 0, 8, false),
        ];
        let mut edit = surface_deletion(&store, &ranges);
        edit.pages
            .extend(surface_deletion(&store, &[fragment_range(&store, target, 0, 0, false)]).pages);
        let placed = store
            .move_continuous("pad", &ranges, &edit, target, 0, false)
            .unwrap();
        assert_eq!((placed.reattached, placed.cloned), (4, 0));
        assert_eq!(standing(&store, target), originals);
        assert_eq!(
            store.copy_out_chip(first_chip).unwrap().0.as_slice(),
            A.as_bytes()
        );
        assert_eq!(&**store.note_text(first_chip).unwrap(), "rotate monthly");
        assert_eq!(body(&store, first), "");
        assert_eq!(body(&store, second), "");
        assert_eq!(
            body(&store, target),
            "ab\u{fffc}cd\u{fffc}ef\nab\u{fffc}cd\u{fffc}ef"
        );
        assert_eq!(
            store.active_cut.as_ref().unwrap().envelope.as_slice(),
            original_cut.as_slice()
        );
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
        assert!(body(&store, target).is_empty());
        assert_eq!(standing(&store, first), originals[..2]);
        assert_eq!(standing(&store, second), originals[2..]);
        assert_eq!(
            store.copy_out_chip(first_chip).unwrap().0.as_slice(),
            A.as_bytes()
        );
        assert_eq!(&**store.note_text(first_chip).unwrap(), "rotate monthly");
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(standing(&store, target), originals);
        assert_eq!(
            store.copy_out_chip(first_chip).unwrap().0.as_slice(),
            A.as_bytes()
        );
        assert_eq!(&**store.note_text(first_chip).unwrap(), "rotate monthly");
        assert!(body(&store, first).is_empty());
        assert!(body(&store, second).is_empty());
        assert_eq!(
            store.active_cut.as_ref().unwrap().envelope.as_slice(),
            original_cut.as_slice()
        );
    }

    #[test]
    fn continuous_move_finishes_when_deadline_passes_before_history_registration() {
        use std::cell::Cell;
        use std::rc::Rc;
        use std::time::Instant;

        #[derive(Clone)]
        struct DeadlineOnRead {
            inner: ManualClock,
            remaining_reads: Rc<Cell<u8>>,
        }
        impl Clock for DeadlineOnRead {
            fn now(&self) -> Instant {
                let remaining = self.remaining_reads.get();
                if remaining > 0 {
                    self.remaining_reads.set(remaining - 1);
                    if remaining == 1 {
                        self.inner.advance(Duration::from_secs(31 * 24 * 3600));
                    }
                }
                self.inner.now()
            }
            fn wall_ms(&self) -> u64 {
                self.inner.wall_ms()
            }
            fn local_offset_seconds(&self) -> i32 {
                self.inner.local_offset_seconds()
            }
        }

        let clock = DeadlineOnRead {
            inner: ManualClock::new(),
            remaining_reads: Rc::new(Cell::new(0)),
        };
        let mut store = SheetStore::new(clock.clone()).with_grace_snap(false);
        let source = store.new_tab().1;
        let target = store.new_tab().1;
        let chip = store.seal_text(source, A).unwrap();
        assert!(store.sync_document(source, vec![Segment::Chip(chip)]));
        let uuid = store.sheet(source).unwrap().chips[0].uuid;
        let edit = ContinuousEdit {
            pages: [source, target]
                .into_iter()
                .map(|page| crate::continuous::ContinuousPageEdit {
                    page_id: page,
                    expected_uuid: store.sheet(page).unwrap().uuid(),
                    expected_version: Some(store.sheet(page).unwrap().document.version()),
                    ops: if page == source {
                        vec![EditOp::Delete {
                            pos_u16: 0,
                            len_u16: 1,
                        }]
                    } else {
                        vec![]
                    },
                    join_next: None,
                })
                .collect(),
            intent: EditIntent::Replacement,
            selection: selection(0, 1, 0, 0),
        };
        // Two admission reads and two settle reads precede move-history registration.
        clock.remaining_reads.set(5);
        let result = store.place_continuous_plan(
            "pad",
            &edit,
            target,
            vec![Planned::Reattach { uuid, from: source }],
            Placed::default(),
            true,
        );
        assert!(result.is_some());
        assert_eq!(clock.remaining_reads.get(), 0);
        assert!(store.sheet(source).unwrap().segments().is_empty());
        assert_eq!(store.sheet(target).unwrap().chips[0].uuid, uuid);
        assert!(store.continuous_scope_for_step(target, true).is_none());
        assert!(!store.can_step_continuous("pad", true));
    }

    #[test]
    fn continuous_native_move_within_one_page_and_clone_leave_source_identity_consistent() {
        let (mut store, _) = store();
        let (source, chip, _) = mixed(&mut store);
        let uuid = uuid_of(&store, chip);
        let ranges = [fragment_range(&store, source, 1, 3, false)];
        let edit = surface_deletion(&store, &ranges);
        let moved = store
            .move_continuous("pad", &ranges, &edit, source, 5, false)
            .unwrap();
        assert_eq!(moved.reattached, 1);
        assert_eq!(body(&store, source), "ad\u{fffc}efb\u{fffc}c");
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(body(&store, source), "ab\u{fffc}cd\u{fffc}ef");
        let ranges = [fragment_range(&store, source, 1, 3, false)];
        let target = store.new_tab().1;
        let edit = surface_deletion(&store, &[fragment_range(&store, target, 0, 0, false)]);
        let copied = store
            .move_continuous("pad", &ranges, &edit, target, 0, true)
            .unwrap();
        assert_eq!((copied.reattached, copied.cloned), (0, 1));
        assert_eq!(body(&store, target), "b\u{fffc}c");
        assert_ne!(standing(&store, target)[0], uuid);
        assert_eq!(standing(&store, source)[0], uuid);
        assert!(store.step_continuous("pad", true).is_some());
        assert!(body(&store, target).is_empty());
        assert_eq!(body(&store, source), "ab\u{fffc}cd\u{fffc}ef");
    }

    #[test]
    fn continuous_native_move_history_refuses_a_missing_or_deleted_object() {
        for burn in [false, true] {
            let (mut store, _) = store();
            let (source, chip, _) = mixed(&mut store);
            let target = store.new_tab().1;
            let ranges = [fragment_range(&store, source, 2, 1, false)];
            let mut edit = surface_deletion(&store, &ranges);
            edit.pages.extend(
                surface_deletion(&store, &[fragment_range(&store, target, 0, 0, false)]).pages,
            );
            assert!(
                store
                    .move_continuous("pad", &ranges, &edit, target, 0, false)
                    .is_some()
            );
            if burn {
                assert!(store.delete_chip(chip));
            } else {
                store
                    .sheet_mut(target)
                    .unwrap()
                    .chips
                    .retain(|object| object.id() != chip);
            }
            let before = (body(&store, source), body(&store, target));
            assert!(!store.can_step_continuous("pad", true));
            assert!(store.step_continuous("pad", true).is_none());
            assert_eq!((body(&store, source), body(&store, target)), before);
        }
    }

    #[test]
    fn continuous_native_move_refusal_and_write_failure_restore_standing_sources() {
        let (mut store, _) = store();
        let (first, ..) = mixed(&mut store);
        let (second, ..) = mixed(&mut store);
        let target = store.new_tab().1;
        let ranges = [
            fragment_range(&store, first, 0, 8, true),
            fragment_range(&store, second, 0, 8, false),
        ];
        let mut edit = surface_deletion(&store, &ranges);
        edit.pages
            .extend(surface_deletion(&store, &[fragment_range(&store, target, 0, 0, false)]).pages);
        let before = (standing(&store, first), standing(&store, second));
        let mut invalid = edit.clone();
        invalid.pages[1].ops.clear();
        assert!(
            store
                .move_continuous("pad", &ranges, &invalid, target, 0, false)
                .is_none()
        );
        assert!(
            store
                .move_continuous("pad", &ranges, &edit, target, 99, false)
                .is_none()
        );
        store
            .sheet_mut(second)
            .unwrap()
            .document
            .fail_writes_after(0);
        assert!(
            store
                .move_continuous("pad", &ranges, &edit, target, 0, false)
                .is_none()
        );
        assert_eq!((standing(&store, first), standing(&store, second)), before);
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
        assert!(body(&store, target).is_empty());
        assert!(detached(&store, target).is_empty());
        assert!(store.active_cut().is_none());
    }

    #[test]
    fn continuous_cut_groups_sources_and_restores_the_active_cut_after_restart() {
        let (mut store, clock) = store();
        let (first, a, _) = mixed(&mut store);
        let (second, b, _) = mixed(&mut store);
        let uuids = [uuid_of(&store, a), uuid_of(&store, b)];
        let ranges = [
            fragment_range(&store, first, 2, 1, true),
            fragment_range(&store, second, 2, 1, false),
        ];
        let edit = surface_deletion(&store, &ranges);
        store.cut_continuous("pad", &ranges, &edit).unwrap();
        assert_eq!(
            store
                .active_cut()
                .unwrap()
                .1
                .iter()
                .map(|chip| chip.uuid)
                .collect::<Vec<_>>(),
            uuids
        );
        assert!(store.step_continuous("pad", true).is_some());
        assert!(store.active_cut().is_none());
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(detached(&store, first), vec![uuids[0]]);
        assert_eq!(detached(&store, second), vec![uuids[1]]);

        assert!(store.step_continuous("pad", true).is_some());
        let ranges = [
            fragment_range(&store, first, 2, 1, true),
            fragment_range(&store, second, 2, 1, false),
        ];
        let edit = surface_deletion(&store, &ranges);
        store.cut_continuous("pad", &ranges, &edit).unwrap();
        let snapshot = store.snapshot(1_000_000);
        let mut revived = SheetStore::new(clock).with_grace_snap(false);
        revived.restore(&snapshot, 1_000_000).unwrap();
        assert_eq!(
            revived
                .active_cut()
                .unwrap()
                .1
                .iter()
                .map(|chip| chip.uuid)
                .collect::<Vec<_>>(),
            uuids
        );
        let destination = revived.new_tab().1;
        let edits = surface_deletion(
            &revived,
            &[fragment_range(&revived, destination, 0, 0, false)],
        );
        let pasted = revived
            .paste_active_cut_continuous("pad", &edits, destination, 0)
            .unwrap();
        assert_eq!(pasted.reattached, 2);
        assert_eq!(standing(&revived, destination), uuids);
        assert!(revived.step_continuous("pad", true).is_some());
        assert!(standing(&revived, destination).is_empty());
        assert!(revived.step_continuous("pad", false).is_some());
        assert_eq!(standing(&revived, destination), uuids);
    }

    #[test]
    fn continuous_paste_replaces_multiple_pages_and_undoes_clones_as_one_gesture() {
        let (mut store, _) = store();
        let (source, ..) = mixed(&mut store);
        let copied = store.copy_fragment(source, 0, 8).unwrap();
        let (first, ..) = mixed(&mut store);
        let (second, ..) = mixed(&mut store);
        let ranges = [
            fragment_range(&store, first, 1, 7, true),
            fragment_range(&store, second, 0, 3, false),
        ];
        let edit = surface_deletion(&store, &ranges);
        let pasted = store
            .paste_continuous("pad", &edit, first, 1, &copied.envelope.unwrap(), None)
            .unwrap();
        assert_eq!(pasted.cloned, 2);
        assert_eq!(body(&store, first), "aab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "cd\u{fffc}ef");
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(body(&store, first), "aab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "cd\u{fffc}ef");
    }

    #[test]
    fn continuous_clipboard_refuses_invalid_edits_and_rolls_back_prepared_objects() {
        let (mut store, _) = store();
        let (first, ..) = mixed(&mut store);
        let (second, ..) = mixed(&mut store);
        let ranges = [
            fragment_range(&store, first, 2, 1, true),
            fragment_range(&store, second, 2, 1, false),
        ];
        let edit = surface_deletion(&store, &ranges);
        let mut invalid = edit.clone();
        invalid.pages[1].ops.clear();
        assert_eq!(
            store.cut_continuous("pad", &ranges, &invalid).err(),
            Some(CopyRefusal::Refused)
        );
        let copied = store.copy_fragments(&ranges).unwrap();
        let ledger_before = store.ledger().count();
        let standing_before = (standing(&store, first), standing(&store, second));
        store
            .sheet_mut(second)
            .unwrap()
            .document
            .fail_writes_after(0);
        assert!(
            store
                .paste_continuous(
                    "pad",
                    &edit,
                    first,
                    2,
                    copied.envelope.as_ref().unwrap(),
                    None
                )
                .is_none()
        );
        assert_eq!(
            (standing(&store, first), standing(&store, second)),
            standing_before
        );
        assert!(detached(&store, first).is_empty());
        assert!(detached(&store, second).is_empty());
        assert_eq!(store.ledger().count(), ledger_before);
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
        assert!(!store.can_step_continuous("pad", true));
    }

    #[test]
    fn continuous_paste_keeps_new_history_when_a_moved_source_is_a_participant() {
        let (mut store, _) = store();
        let (source, chip, _) = mixed(&mut store);
        let (target, ..) = mixed(&mut store);
        let uuid = uuid_of(&store, chip);
        store.cut_fragment(source, 2, 1).unwrap();
        let ranges = [
            fragment_range(&store, source, 1, 2, true),
            fragment_range(&store, target, 0, 1, false),
        ];
        let edit = surface_deletion(&store, &ranges);
        let pasted = store
            .paste_active_cut_continuous("pad", &edit, target, 0)
            .unwrap();
        assert_eq!(pasted.reattached, 1);
        assert_eq!(standing(&store, target)[0], uuid);
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(body(&store, source), "abcd\u{fffc}ef");
        assert_eq!(body(&store, target), "ab\u{fffc}cd\u{fffc}ef");
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(standing(&store, target)[0], uuid);
    }

    #[test]
    fn continuous_paste_invalid_offset_restores_staged_cut_objects_and_active_cut() {
        let (mut store, _) = store();
        let (source, chip, _) = mixed(&mut store);
        let (target, ..) = mixed(&mut store);
        let uuid = uuid_of(&store, chip);
        store.cut_fragment(source, 2, 1).unwrap();
        let ranges = [fragment_range(&store, target, 0, 2, false)];
        let edit = surface_deletion(&store, &ranges);
        assert!(
            store
                .paste_active_cut_continuous("pad", &edit, target, 99)
                .is_none()
        );
        assert_eq!(store.active_cut().unwrap().1[0].uuid, uuid);
        assert_eq!(detached(&store, source), vec![uuid]);
        assert!(detached(&store, target).is_empty());
        assert_eq!(body(&store, target), "ab\u{fffc}cd\u{fffc}ef");
    }

    #[test]
    fn continuous_active_cut_paste_classifies_an_unswept_expired_source() {
        let (mut store, clock) = store();
        let (source, ..) = mixed(&mut store);
        store.cut_fragment(source, 2, 1).unwrap();
        clock.advance(HOUR);
        let target = store.new_tab().1;
        let edit = surface_deletion(&store, &[fragment_range(&store, target, 0, 0, false)]);
        let pasted = store
            .paste_active_cut_continuous("pad", &edit, target, 0)
            .unwrap();
        assert_eq!(
            (pasted.expired, pasted.reattached, pasted.cloned),
            (1, 0, 0)
        );
        assert_eq!(body(&store, target), "[sealed content · expired]");
        assert!(store.active_cut().is_none());
    }

    #[test]
    fn continuous_copy_composes_ink_and_objects_from_each_source_in_order() {
        let (mut store, _) = store();
        let (first, first_chip, _) = mixed(&mut store);
        let (second, second_chip, _) = mixed(&mut store);
        let ranges = [
            fragment_range(&store, first, 1, 3, true),
            fragment_range(&store, second, 0, 3, false),
        ];
        let copied = store.copy_fragments(&ranges).unwrap();
        assert_eq!(
            copied.plain.as_str(),
            "b[sealed content · tiny]c\nab[sealed content · tiny]"
        );
        let envelope = copied.envelope.unwrap();
        let parsed = Fragment::parse(&envelope).unwrap();
        assert!(parsed.cut.is_none());
        assert_eq!(
            parsed
                .references()
                .map(|reference| reference.uuid)
                .collect::<Vec<_>>(),
            vec![uuid_of(&store, first_chip), uuid_of(&store, second_chip)]
        );
        assert!(!String::from_utf8_lossy(&envelope).contains(A));
        let destination = store.new_tab().1;
        let pasted = store
            .paste_fragment(destination, 0, 0, &envelope, None)
            .unwrap();
        assert_eq!(pasted.cloned, 2);
        assert_eq!(body(&store, destination), "b\u{fffc}c\nab\u{fffc}");
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
    }

    #[test]
    fn continuous_copy_uses_utf16_ranges_and_explicit_separator_selection() {
        let (mut store, _) = store();
        let first = store.new_tab().1;
        let second = store.new_tab().1;
        assert!(store.sync_document(first, vec![Segment::Ink("a😀b".into())]));
        assert!(store.sync_document(second, vec![Segment::Ink("tail".into())]));
        let mut ranges = [
            fragment_range(&store, first, 1, 2, false),
            fragment_range(&store, second, 0, 4, false),
        ];
        let copied = store.copy_fragments(&ranges).unwrap();
        assert_eq!(copied.plain.as_str(), "😀tail");
        assert!(copied.envelope.is_none());
        ranges[0].separator_after = true;
        assert_eq!(
            store.copy_fragments(&ranges).unwrap().plain.as_str(),
            "😀\ntail"
        );
        ranges[0].len_u16 = 1;
        assert_eq!(
            store.copy_fragments(&ranges).err(),
            Some(CopyRefusal::Refused)
        );
        let separator = fragment_range(&store, first, 4, 0, true);
        assert_eq!(
            store.copy_fragments(&[separator]).unwrap().plain.as_str(),
            "\n"
        );
    }

    #[test]
    fn continuous_copy_refuses_the_whole_selection_for_an_invalid_final_member() {
        let (mut store, _) = store();
        let (first, ..) = mixed(&mut store);
        let (second, ..) = mixed(&mut store);
        let first_range = fragment_range(&store, first, 0, 8, true);
        let second_range = fragment_range(&store, second, 0, 8, false);
        for invalid in [
            FragmentSelection {
                page: SheetId::from_raw(u64::MAX),
                ..second_range.clone()
            },
            FragmentSelection {
                expected_uuid: ItemId::random(),
                ..second_range.clone()
            },
            FragmentSelection {
                len_u16: 9,
                ..second_range
            },
            first_range.clone(),
        ] {
            assert_eq!(
                store.copy_fragments(&[first_range.clone(), invalid]).err(),
                Some(CopyRefusal::Refused)
            );
        }
        assert_eq!(store.copy_fragments(&[]).err(), Some(CopyRefusal::Refused));
        assert_eq!(body(&store, first), "ab\u{fffc}cd\u{fffc}ef");
        assert_eq!(body(&store, second), "ab\u{fffc}cd\u{fffc}ef");
    }

    #[test]
    fn continuous_copy_and_cut_refuse_same_length_replacement_after_projection() {
        let (mut store, _) = store();
        let (page, a, b) = mixed(&mut store);
        let ranges = [fragment_range(&store, page, 0, 2, false)];
        let edit = surface_deletion(&store, &ranges);
        assert!(store.sync_document(
            page,
            vec![
                Segment::Ink("xy".into()),
                Segment::Chip(a),
                Segment::Ink("cd".into()),
                Segment::Chip(b),
                Segment::Ink("ef".into()),
            ]
        ));
        assert_eq!(
            store.copy_fragments(&ranges).err(),
            Some(CopyRefusal::Refused)
        );
        assert_eq!(
            store.cut_continuous("pad", &ranges, &edit).err(),
            Some(CopyRefusal::Refused)
        );
        assert_eq!(body(&store, page), "xy\u{fffc}cd\u{fffc}ef");
        assert!(!store.can_step_continuous("pad", true));
    }

    #[test]
    fn continuous_copy_refuses_a_due_source_before_sweep() {
        let (mut store, clock) = store();
        let (old, ..) = mixed(&mut store);
        clock.advance(HOUR / 2);
        let (recent, ..) = mixed(&mut store);
        let ranges = [
            fragment_range(&store, recent, 0, 2, true),
            fragment_range(&store, old, 0, 2, false),
        ];
        clock.advance(HOUR / 2);
        assert_eq!(
            store.copy_fragments(&ranges).err(),
            Some(CopyRefusal::Refused)
        );
        assert!(store.sheet(old).is_some());
        assert!(store.copy_fragment(recent, 0, 2).is_ok());
    }

    #[test]
    fn continuous_copy_applies_reference_cap_to_the_combined_envelope() {
        let (mut store, _) = store();
        let first_count = REFERENCE_CAP / 2;
        let second_count = REFERENCE_CAP - first_count + 1;
        let first = objects(&mut store, first_count);
        let second = objects(&mut store, second_count);
        let ranges = [
            fragment_range(&store, first, 0, first_count as u32, true),
            fragment_range(&store, second, 0, second_count as u32, false),
        ];
        assert!(store.copy_fragment(first, 0, first_count as u32).is_ok());
        assert!(store.copy_fragment(second, 0, second_count as u32).is_ok());
        assert_eq!(
            store.copy_fragments(&ranges).err(),
            Some(CopyRefusal::PastCap(EnvelopeCap::References))
        );
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
        assert_eq!(
            store.cut_fragment(id, 0, 8).err(),
            Some(CopyRefusal::Refused)
        );
        assert_eq!(body(&store, id), "ab\u{FFFC}cd\u{FFFC}ef");
        assert!(detached(&store, id).is_empty());
        assert!(store.active_cut().is_none());
        assert_eq!(store.ledger().count(), records);
        assert!(store.copy_out_chip(a).is_some());
    }

    /// A page of `count` objects and nothing else, one unit each.
    fn objects(store: &mut SheetStore<ManualClock>, count: usize) -> SheetId {
        let id = store.new_tab().1;
        let segments = (0..count)
            .map(|_| Segment::Chip(store.seal_text(id, A).unwrap()))
            .collect();
        assert!(store.sync_document(id, segments));
        id
    }

    #[test]
    fn a_copy_or_cut_naming_past_the_reference_cap_composes_nothing_and_changes_nothing() {
        let (mut store, _) = store();
        let id = objects(&mut store, REFERENCE_CAP + 2);
        store.cut_fragment(id, 0, 1).unwrap();
        let earlier: Vec<ItemId> = store
            .active_cut()
            .unwrap()
            .1
            .iter()
            .map(|c| c.uuid)
            .collect();
        let before = (standing(&store, id), detached(&store, id));
        let records = store.ledger().count();

        let past = u32::try_from(REFERENCE_CAP + 1).unwrap();
        let refused = Some(CopyRefusal::PastCap(EnvelopeCap::References));
        assert_eq!(store.copy_fragment(id, 0, past).err(), refused);
        assert_eq!(store.cut_fragment(id, 0, past).err(), refused);
        assert_eq!((standing(&store, id), detached(&store, id)), before);
        let active: Vec<ItemId> = store
            .active_cut()
            .unwrap()
            .1
            .iter()
            .map(|c| c.uuid)
            .collect();
        assert_eq!(active, earlier, "the earlier cut stands");
        assert_eq!(store.ledger().count(), records, "nothing recorded");

        assert!(store.undo(id), "the earlier cut is the newest step");
        assert_eq!(standing(&store, id).len(), REFERENCE_CAP + 2);
        let at_cap = u32::try_from(REFERENCE_CAP).unwrap();
        let cut = store.cut_fragment(id, 0, at_cap).unwrap();
        assert!(
            Fragment::parse(&cut.envelope.unwrap()).is_some(),
            "at the cap"
        );
    }

    #[test]
    fn a_copy_or_cut_longer_than_the_length_cap_composes_nothing_and_changes_nothing() {
        let (mut store, _) = store();
        let id = store.new_tab().1;
        let a = store.seal_text(id, A).unwrap();
        let ink = "x".repeat(EnvelopeCap::Length.limit());
        assert!(store.sync_document(id, vec![Segment::Ink(ink.clone()), Segment::Chip(a)]));
        let uuid = uuid_of(&store, a);
        let records = store.ledger().count();

        let whole = u32::try_from(ink.len() + 1).unwrap();
        let refused = Some(CopyRefusal::PastCap(EnvelopeCap::Length));
        assert_eq!(store.copy_fragment(id, 0, whole).err(), refused);
        assert_eq!(store.cut_fragment(id, 0, whole).err(), refused);
        assert_eq!(standing(&store, id), vec![uuid]);
        assert!(detached(&store, id).is_empty());
        assert!(store.active_cut().is_none());
        assert_eq!(store.ledger().count(), records, "nothing recorded");

        let ink_alone = store.copy_fragment(id, 0, whole - 1).unwrap();
        assert!(ink_alone.envelope.is_none(), "ink alone meets no cap");
    }

    #[test]
    fn a_paste_places_its_ink_without_the_chip_sentinel() {
        let (mut store, _) = store();
        let (id, _, _) = mixed(&mut store);
        let envelope = format!(r#"{{"version":1,"nodes":[{{"ink":"x{}y"}}]}}"#, '\u{FFFC}');
        let placed = store
            .paste_fragment(id, 0, 0, envelope.as_bytes(), None)
            .unwrap();
        assert_eq!(placed.length_u16, 2);
        assert_eq!(body(&store, id), "xyab\u{FFFC}cd\u{FFFC}ef");

        let unreadable = br#"{"version":99,"nodes":[]}"#;
        let placed = store
            .paste_fragment(id, 0, 0, unreadable, Some("p\u{FFFC}q"))
            .unwrap();
        assert_eq!(placed.length_u16, 2, "the public text kept the sentinel");
        assert_eq!(body(&store, id), "pqxyab\u{FFFC}cd\u{FFFC}ef");
        assert!(
            store
                .paste_fragment(id, 0, 0, unreadable, Some("\u{FFFC}"))
                .is_none(),
            "a public text of the sentinel alone placed something"
        );
        assert_eq!(
            standing(&store, id).len(),
            2,
            "a sentinel stood as an object"
        );
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
    fn undo_ends_a_cut_and_redo_detaches_as_a_removal_whose_objects_a_later_paste_clones() {
        let (mut store, _) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = vec![uuid_of(&store, a), uuid_of(&store, b)];
        let envelope = store.cut_fragment(id, 0, 8).unwrap().envelope.unwrap();
        assert!(store.undo(id));
        assert!(store.active_cut().is_none(), "undo ended the cut");
        assert_eq!(standing(&store, id), uuids);

        let records = store.ledger().count();
        assert!(store.redo(id));
        assert_eq!(body(&store, id), "");
        assert_eq!(detached(&store, id), uuids, "retained, not reaped");
        assert!(store.active_cut().is_none(), "redo stands no cut again");
        assert_eq!(store.ledger().count(), records, "a removal records nothing");

        let placed = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!((placed.reattached, placed.cloned), (0, 2));
        let clones = standing(&store, id);
        assert_eq!(clones.len(), 2);
        assert!(
            clones.iter().all(|uuid| !uuids.contains(uuid)),
            "new identities"
        );
        assert_eq!(payload_at(&store, id, 0), A.as_bytes());
        assert_eq!(payload_at(&store, id, 1), B.as_bytes());
        assert_eq!(detached(&store, id), uuids, "the retained objects stay");
        assert_eq!(store.ledger().count(), records + 2, "one sealed per clone");
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

    fn name_and_note(store: &mut SheetStore<ManualClock>, chip: ChipId, name: &str, note: &str) {
        store.set_chip_name(chip, name).unwrap();
        let len = u32::try_from(store.note_text(chip).unwrap().encode_utf16().count()).unwrap();
        let mut ops = vec![EditOp::Delete {
            pos_u16: 0,
            len_u16: len,
        }];
        ops.push(EditOp::Insert {
            pos_u16: 0,
            text: note.into(),
        });
        assert!(store.apply_note_ops(chip, &ops, EditIntent::Replacement, None));
    }

    /// The chip standing at `index` on a page.
    fn standing_chip(store: &SheetStore<ManualClock>, id: SheetId, index: usize) -> ChipId {
        let chips: Vec<ChipId> = store
            .sheet(id)
            .unwrap()
            .segments()
            .iter()
            .filter_map(|segment| match segment {
                Segment::Chip(chip) => Some(*chip),
                Segment::Ink(_) => None,
            })
            .collect();
        chips[index]
    }

    #[test]
    fn a_clone_carries_the_name_and_note_its_fragment_holds() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        let envelope = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        // The original moves on; the copy holds what was copied.
        name_and_note(&mut store, a, "OLD_KEY", "retired");

        store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        let clone = standing_chip(&store, id, 0);
        let face = store.sheet(id).unwrap().chip(clone).unwrap();
        assert_eq!(face.name(), Some("API_KEY"));
        assert!(face.has_note());
        assert!(
            face.note.as_ref().and_then(Note::resting).is_some(),
            "the pasted note was made a document"
        );
        assert_eq!(&**store.note_text(clone).unwrap(), "rotate monthly");
        assert!(
            !store.note_can_undo(clone),
            "the note's text, not its history"
        );
        assert_eq!(
            store.sheet(id).unwrap().chip(a).unwrap().name(),
            Some("OLD_KEY")
        );
        let ledger = store.ledger_snapshot();
        for word in ["API_KEY", "rotate monthly"] {
            assert!(
                !ledger.windows(word.len()).any(|w| w == word.as_bytes()),
                "{word} reached the ledger"
            );
        }
    }

    #[test]
    fn a_pasted_name_the_rule_refuses_is_dropped_and_the_object_kept() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let envelope = format!(
            r#"{{"version":1,"nodes":[{{"ref":{{"uuid":"{}","name":"not a name","note":"kept"}}}}]}}"#,
            uuid_of(&store, a)
        );
        let placed = store
            .paste_fragment(id, 0, 0, envelope.as_bytes(), None)
            .unwrap();
        assert_eq!(placed.cloned, 1);
        let clone = standing_chip(&store, id, 0);
        assert_eq!(store.sheet(id).unwrap().chip(clone).unwrap().name(), None);
        assert_eq!(&**store.note_text(clone).unwrap(), "kept");
    }

    #[test]
    fn a_reattached_object_keeps_its_own_name_and_note() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        let envelope = store.cut_fragment(id, 2, 1).unwrap().envelope.unwrap();
        store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        let face = store.sheet(id).unwrap().chip(a).unwrap();
        assert_eq!(face.name(), Some("API_KEY"));
        assert_eq!(&**store.note_text(a).unwrap(), "rotate monthly");
    }

    #[test]
    fn a_placeholder_carries_neither_name_nor_note() {
        let (mut store, clock) = store();
        let (id, a, _) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        let envelope = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        clock.advance(HOUR);
        store.expire_due();
        let page = store.new_tab().1;
        store.paste_fragment(page, 0, 0, &envelope, None).unwrap();
        assert_eq!(body(&store, page), "[sealed content \u{b7} expired]");
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
    fn burning_a_clones_source_leaves_the_clone() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 2, 1).unwrap().envelope.unwrap();
        store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        let clone = standing_chip(&store, id, 0);
        assert!(store.delete_chip(a));
        assert_eq!(&**store.copy_out_chip(clone).unwrap().0, A.as_bytes());
        assert!(store.delete_chip(clone));
        assert!(store.live_object_by_id(clone).is_none());
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
    fn a_crafted_envelope_naming_a_live_object_twice_clones_nothing() {
        let (mut store, _) = store();
        let (id, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        let crafted = format!(
            r#"{{"version":1,"nodes":[{{"ref":{{"uuid":"{uuid}"}}}},{{"ref":{{"uuid":"{uuid}"}}}}]}}"#
        );
        let page = store.new_tab().1;
        let records = store.ledger().count();

        let placed = store
            .paste_fragment(page, 0, 0, crafted.as_bytes(), Some("[x][y]"))
            .unwrap();
        assert!(placed.unreadable);
        assert_eq!(placed.cloned, 0);
        assert_eq!(body(&store, page), "[x][y]");
        assert!(store.sheet(page).unwrap().chips().next().is_none());
        assert_eq!(store.ledger().count(), records, "no clone was recorded");
        assert_eq!(store.sheet(id).unwrap().chip_count(), 2);
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
            name: Some(Zeroizing::new("FOREIGN".into())),
            note: None,
        }));
        let mixed = Fragment { cut: None, nodes }.envelope().unwrap();

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

    fn expired_on_record(store: &SheetStore<ManualClock>, uuid: ItemId) -> bool {
        store
            .ledger()
            .any(|record| record.item == uuid && matches!(record.event, LedgerEvent::Expired))
    }

    #[test]
    fn a_cut_from_a_page_past_its_deadline_reattaches_nothing_and_places_expired() {
        let (mut store, clock) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = [uuid_of(&store, a), uuid_of(&store, b)];
        store.cut_fragment(id, 0, 8).unwrap();
        clock.advance(HOUR);
        let fresh = store.new_tab().1;

        let placed = store.paste_active_cut(fresh, 0, 0).unwrap();
        assert_eq!(
            (placed.reattached, placed.cloned, placed.expired),
            (0, 0, 2)
        );
        assert_eq!(placed.pages_expired, 1, "the paste swept the due page");
        assert_eq!(
            body(&store, fresh),
            "ab[sealed content \u{b7} expired]cd[sealed content \u{b7} expired]ef"
        );
        assert!(store.sheet(fresh).unwrap().chips().next().is_none());
        assert!(detached(&store, fresh).is_empty());
        assert!(store.sheet(id).is_none(), "the due page is gone");
        assert!(store.active_cut().is_none());
        assert!(uuids.iter().all(|uuid| expired_on_record(&store, *uuid)));
    }

    #[test]
    fn a_copy_from_a_page_past_its_deadline_clones_nothing_and_places_expired() {
        let (mut store, clock) = store();
        let (id, a, b) = mixed(&mut store);
        let uuids = [uuid_of(&store, a), uuid_of(&store, b)];
        let envelope = store.copy_fragment(id, 0, 8).unwrap().envelope.unwrap();
        clock.advance(HOUR);
        let fresh = store.new_tab().1;
        let sealed = |store: &SheetStore<ManualClock>| {
            store
                .ledger()
                .filter(|record| matches!(record.event, LedgerEvent::Sealed))
                .count()
        };
        let before = sealed(&store);

        let placed = store.paste_fragment(fresh, 0, 0, &envelope, None).unwrap();
        assert_eq!(
            (placed.cloned, placed.expired, placed.pages_expired),
            (0, 2, 1)
        );
        assert!(store.sheet(fresh).unwrap().chips().next().is_none());
        assert!(detached(&store, fresh).is_empty());
        assert!(store.sheet(id).is_none());
        assert_eq!(sealed(&store), before, "no clone was recorded");
        assert!(uuids.iter().all(|uuid| expired_on_record(&store, *uuid)));
    }

    #[test]
    fn a_page_past_its_deadline_gives_no_copy_before_its_sweep() {
        let (mut store, clock) = store();
        let (id, ..) = mixed(&mut store);
        assert!(store.copy_fragment(id, 0, 8).is_ok(), "readable before");
        clock.advance(HOUR);
        let records = store.ledger().count();

        assert_eq!(
            store.copy_fragment(id, 0, 8).err(),
            Some(CopyRefusal::Refused)
        );
        assert!(store.copy_fragment(id, 0, 2).is_err(), "ink alone too");
        assert_eq!(store.ledger().count(), records, "nothing recorded");
        assert_eq!(store.expire_due(), vec![id], "the timer still reaps it");
    }

    #[test]
    fn a_shown_selection_past_its_pages_deadline_composes_nothing_before_its_sweep() {
        let (mut store, clock) = store();
        let (id, a, _) = mixed(&mut store);
        let shown = [Segment::Ink("Heading\n".into()), Segment::Chip(a)];
        let copied = store.compose_fragment(id, &shown).unwrap();
        assert!(copied.envelope.is_some(), "readable before");
        assert_eq!(
            copied.plain.as_str(),
            "Heading\n[sealed content \u{b7} tiny]"
        );
        clock.advance(HOUR);
        let records = store.ledger().count();

        assert_eq!(
            store.compose_fragment(id, &shown).err(),
            Some(CopyRefusal::Refused)
        );
        assert!(
            store
                .compose_fragment(id, &[Segment::Ink("ab".into())])
                .is_err(),
            "ink alone too"
        );
        assert_eq!(store.ledger().count(), records, "nothing recorded");
        assert_eq!(store.expire_due(), vec![id], "the timer still reaps it");
    }

    #[test]
    fn a_page_past_its_deadline_gives_no_cut_before_its_sweep() {
        let (mut store, clock) = store();
        let (id, ..) = mixed(&mut store);
        clock.advance(HOUR);
        let before = body(&store, id);
        let records = store.ledger().count();

        assert_eq!(
            store.cut_fragment(id, 0, 8).err(),
            Some(CopyRefusal::Refused)
        );
        assert!(store.cut_fragment(id, 0, 2).is_err(), "ink alone too");
        assert_eq!(body(&store, id), before, "nothing changed");
        assert!(store.active_cut().is_none(), "no cut stands");
        assert_eq!(store.ledger().count(), records, "nothing recorded");
        assert_eq!(store.expire_due(), vec![id], "the timer still reaps it");
    }

    #[test]
    fn a_page_past_its_deadline_takes_no_paste_move_or_clone_and_waits_for_its_sweep() {
        let (mut store, clock) = store();
        let (id, ..) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 0, 8).unwrap().envelope.unwrap();
        store.cut_fragment(id, 0, 3).unwrap();
        clock.advance(HOUR);
        let before = body(&store, id);
        let records = store.ledger().count();

        assert!(store.paste_fragment(id, 0, 0, &envelope, None).is_none());
        assert!(store.paste_active_cut(id, 0, 0).is_none());
        assert!(store.clone_range(id, 0, 5, 5).is_none());
        assert!(store.move_range(id, 0, 1, 5).is_none());
        assert_eq!(body(&store, id), before, "nothing changed");
        assert_eq!(store.ledger().count(), records);
        assert!(store.active_cut().is_some());
        assert_eq!(store.expire_due(), vec![id], "the timer still reaps it");
    }

    /// An object's note and name as they stand.
    #[derive(Debug, PartialEq)]
    struct NoteAndName {
        text: String,
        can_undo: bool,
        can_redo: bool,
        name: Option<String>,
    }

    /// The note and name of the object at `chip`, read past the deadline gate.
    fn note_and_name(store: &SheetStore<ManualClock>, chip: ChipId) -> NoteAndName {
        let face = store.sheets().find_map(|s| s.chip(chip)).unwrap();
        let note = face.note.as_ref().unwrap();
        NoteAndName {
            text: note.text().to_string(),
            can_undo: note.can_undo(),
            can_redo: note.can_redo(),
            name: face.name().map(str::to_owned),
        }
    }

    #[test]
    fn a_page_past_its_deadline_takes_no_note_edit_step_or_rename_and_waits_for_its_sweep() {
        let (mut store, clock) = store();
        let (id, a, b) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        name_and_note(&mut store, b, "OLD_KEY", "retired");
        assert!(
            store.undo_note(b).unwrap().applied,
            "the control: a step to put back"
        );
        let caret = TextSelection {
            location_u16: 2,
            length_u16: 0,
        };
        clock.advance(HOUR);
        let notes = (note_and_name(&store, a), note_and_name(&store, b));
        let before = body(&store, id);
        let records = store.ledger().count();

        let typed = [EditOp::Insert {
            pos_u16: 0,
            text: "x".into(),
        }];
        assert!(!store.apply_note_ops(a, &typed, EditIntent::Typing, None));
        assert!(!store.apply_note_ops(a, &[], EditIntent::Typing, None));
        assert!(store.undo_note(a).is_none());
        assert!(store.redo_note(b).is_none());
        assert!(!store.finish_note_editing_group(a, Some(caret)));
        for draft in ["NEW_KEY", ""] {
            assert_eq!(
                store.set_chip_name(a, draft),
                Err(NameRefusal::UnknownChip),
                "{draft:?}"
            );
        }
        assert_eq!(
            (note_and_name(&store, a), note_and_name(&store, b)),
            notes,
            "nothing changed"
        );
        assert_eq!(body(&store, id), before);
        assert_eq!(store.ledger().count(), records);
        assert_eq!(store.expire_due(), vec![id], "the timer still reaps it");
    }

    #[test]
    fn a_restored_note_on_a_page_past_its_deadline_rests_after_a_refused_batch() {
        let (mut store, clock) = store();
        let (_, a, _) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        let uuid = uuid_of(&store, a);
        let mut revived = SheetStore::new(clock.clone())
            .with_grace_snap(false)
            .with_default_rung(Ttl::MIN);
        let snapshot = store.snapshot(1_000_000);
        assert_eq!(revived.restore(&snapshot, 1_000_000).unwrap(), 1);
        let chip = revived
            .sheets()
            .flat_map(Sheet::chips)
            .find(|face| face.uuid == uuid)
            .unwrap()
            .id;
        let resting = |store: &SheetStore<ManualClock>| {
            let face = store.sheets().find_map(|s| s.chip(chip)).unwrap();
            face.note
                .as_ref()
                .and_then(Note::resting)
                .map(|text| text.to_string())
        };
        assert_eq!(
            resting(&revived).as_deref(),
            Some("rotate monthly"),
            "the control: a restored note rests"
        );
        clock.advance(HOUR);
        assert!(revived.chip_stands(chip), "the object is due, not gone");

        let typed = [EditOp::Insert {
            pos_u16: 0,
            text: "x".into(),
        }];
        assert!(!revived.apply_note_ops(chip, &typed, EditIntent::Typing, None));
        assert!(revived.undo_note(chip).is_none());
        assert!(!revived.finish_note_editing_group(chip, None));
        assert_eq!(
            resting(&revived).as_deref(),
            Some("rotate monthly"),
            "a refused batch made the note's document"
        );
        assert_eq!(revived.expire_due().len(), 1, "the timer still reaps it");
    }

    #[test]
    fn a_paste_the_body_refuses_after_its_sweep_reverts_the_paste_and_not_the_sweep() {
        let (mut store, clock) = store();
        let (doomed, a, _) = mixed(&mut store);
        let doomed_uuid = uuid_of(&store, a);
        clock.advance(HOUR / 2);
        let (id, ..) = mixed(&mut store);
        let envelope = store.copy_fragment(id, 0, 8).unwrap().envelope.unwrap();
        clock.advance(HOUR / 2);
        let before = body(&store, id);

        store.sheet_mut(id).unwrap().document.fail_writes_after(2);
        assert!(store.paste_fragment(id, 8, 0, &envelope, None).is_none());
        assert_eq!(body(&store, id), before, "the paste reverted");
        assert!(store.sheet(doomed).is_none(), "the sweep stands");
        assert!(expired_on_record(&store, doomed_uuid));
    }

    #[test]
    fn a_paste_of_ink_alone_sweeps_nothing() {
        let (mut store, clock) = store();
        let (doomed, ..) = mixed(&mut store);
        clock.advance(HOUR);
        let fresh = store.new_tab().1;
        let placed = store
            .paste_fragment(fresh, 0, 0, b"not an envelope", Some("ink"))
            .unwrap();
        assert_eq!(placed.pages_expired, 0);
        assert!(store.sheet(doomed).is_some(), "left for the timer");
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

    /// How many live objects carry an identity, attached or detached, on any page.
    fn copies(store: &SheetStore<ManualClock>, uuid: ItemId) -> usize {
        store
            .sheets()
            .flat_map(|sheet| sheet.chips.iter().chain(&sheet.detached))
            .filter(|chip| chip.uuid == uuid)
            .count()
    }

    fn type_at(store: &mut SheetStore<ManualClock>, id: SheetId, pos_u16: u32, text: &str) {
        let ops = [EditOp::Insert {
            pos_u16,
            text: text.into(),
        }];
        assert!(store.apply_ops(id, &ops));
    }

    #[test]
    fn a_drag_between_pages_moves_ink_and_objects_keeping_identity_name_and_note() {
        let (mut store, _) = store();
        let (home, a, b) = mixed(&mut store);
        name_and_note(&mut store, a, "API_KEY", "rotate monthly");
        let (uuid_a, uuid_b) = (uuid_of(&store, a), uuid_of(&store, b));
        let away = store.new_tab().1;
        type_at(&mut store, away, 0, "xy");
        let records = store.ledger().count();

        let placed = store.move_range_to(home, 1, 3, away, 1).unwrap();
        assert_eq!(
            (placed.location_u16, placed.length_u16),
            (1, 3),
            "where it landed"
        );
        assert_eq!((placed.reattached, placed.cloned), (1, 0));
        assert_eq!(body(&store, home), "ad\u{FFFC}ef");
        assert_eq!(body(&store, away), "xb\u{FFFC}cy");
        assert_eq!(standing(&store, home), vec![uuid_b]);
        assert_eq!(standing(&store, away), vec![uuid_a]);
        assert!(detached(&store, home).is_empty() && detached(&store, away).is_empty());
        assert_eq!(store.ledger().count(), records, "a move records nothing");

        let face = store.sheet(away).unwrap().chip(a).expect("the same chip");
        assert_eq!(face.name(), Some("API_KEY"));
        assert_eq!(&**store.note_text(a).unwrap(), "rotate monthly");
        assert!(store.note_can_undo(a), "its own note, history and all");
        assert_eq!(store.copy_out_chip(a).unwrap().0.as_slice(), A.as_bytes());
    }

    #[test]
    fn a_drag_between_pages_clears_the_source_undo_so_nothing_stands_a_second_copy() {
        let (mut store, _) = store();
        let (home, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        type_at(&mut store, home, 0, "typed");
        assert!(store.can_undo(home));
        let away = store.new_tab().1;

        store.move_range_to(home, 6, 3, away, 0).unwrap();
        assert!(!store.can_undo(home) && !store.can_redo(home));
        assert!(!store.undo(home), "no step there stands it again");
        let stand = [EditOp::InsertChip {
            pos_u16: 0,
            chip: a,
        }];
        assert!(
            !store.apply_ops(home, &stand),
            "nor can the source's editor"
        );
        assert_eq!(copies(&store, uuid), 1);

        assert!(store.undo(away), "the move is one step where it landed");
        assert_eq!(body(&store, away), "");
        assert!(!store.can_undo(away));
        assert_eq!(detached(&store, away), vec![uuid]);
        assert_eq!(copies(&store, uuid), 1);
        assert!(store.redo(away));
        assert_eq!(body(&store, away), "b\u{FFFC}c");
        assert_eq!(standing(&store, away), vec![uuid]);
        assert_eq!(copies(&store, uuid), 1);
    }

    #[test]
    fn a_moved_object_ends_with_the_page_it_landed_on() {
        let (mut store, clock) = store();
        let (home, a, _) = mixed(&mut store);
        let uuid = uuid_of(&store, a);
        clock.advance(HOUR / 2);
        let away = store.new_tab().1;
        store.move_range_to(home, 2, 1, away, 0).unwrap();

        clock.advance(HOUR / 2);
        assert_eq!(store.expire_due(), vec![home]);
        assert_eq!(copies(&store, uuid), 1, "its old page's death leaves it");
        assert!(!expired_on_record(&store, uuid));

        clock.advance(HOUR / 2);
        assert_eq!(store.expire_due(), vec![away]);
        assert_eq!(copies(&store, uuid), 0);
        assert!(expired_on_record(&store, uuid), "its death is on record");
    }

    #[test]
    fn a_drag_of_ink_alone_between_pages_keeps_the_source_undo() {
        let (mut store, _) = store();
        let (home, ..) = mixed(&mut store);
        let away = store.new_tab().1;
        let placed = store.move_range_to(home, 0, 2, away, 0).unwrap();
        assert_eq!(placed.reattached, 0);
        assert_eq!(body(&store, away), "ab");
        assert_eq!(body(&store, home), "\u{FFFC}cd\u{FFFC}ef");
        assert!(store.undo(home), "no object left, so its step stands");
        assert_eq!(body(&store, home), "ab\u{FFFC}cd\u{FFFC}ef");
    }

    #[test]
    fn a_drag_between_pages_refuses_one_page_a_bad_range_or_a_bad_point() {
        let (mut store, _) = store();
        let (home, ..) = mixed(&mut store);
        let away = store.new_tab().1;
        let unknown = SheetId::from_raw(4_242);
        assert!(
            store.move_range_to(home, 1, 3, home, 7).is_none(),
            "one page"
        );
        assert!(
            store.move_range_to(home, 6, 5, away, 0).is_none(),
            "past the body"
        );
        assert!(
            store.move_range_to(home, 1, 0, away, 0).is_none(),
            "nothing"
        );
        assert!(
            store.move_range_to(home, 1, 3, away, 1).is_none(),
            "past its body"
        );
        assert!(store.move_range_to(home, 1, 3, unknown, 0).is_none());
        assert!(store.move_range_to(unknown, 0, 1, away, 0).is_none());
        assert_eq!(body(&store, home), "ab\u{FFFC}cd\u{FFFC}ef");
        assert_eq!(body(&store, away), "");
        assert!(detached(&store, home).is_empty() && detached(&store, away).is_empty());
    }

    #[test]
    fn a_drag_between_pages_refuses_a_page_past_its_deadline_and_changes_neither() {
        let (mut store, clock) = store();
        let (doomed, ..) = mixed(&mut store);
        clock.advance(HOUR / 2);
        let (live, ..) = mixed(&mut store);
        type_at(&mut store, live, 0, "x");
        clock.advance(HOUR / 2);
        let before = (body(&store, doomed), body(&store, live));
        let records = store.ledger().count();

        assert!(
            store.move_range_to(doomed, 2, 1, live, 0).is_none(),
            "from it"
        );
        assert!(
            store.move_range_to(live, 3, 1, doomed, 0).is_none(),
            "onto it"
        );
        assert_eq!((body(&store, doomed), body(&store, live)), before);
        assert!(store.can_undo(live), "the live page keeps its step");
        assert_eq!(store.ledger().count(), records);
        assert_eq!(store.expire_due(), vec![doomed], "the timer still reaps it");
    }

    #[test]
    fn a_drag_between_pages_either_body_refuses_changes_neither_page() {
        let (mut store, _) = store();
        let (home, a, b) = mixed(&mut store);
        let (uuid_a, uuid_b) = (uuid_of(&store, a), uuid_of(&store, b));
        let away = store.new_tab().1;
        type_at(&mut store, away, 0, "x");
        store.cut_fragment(home, 5, 1).unwrap();
        let home_body = body(&store, home);
        let records = store.ledger().count();
        let unchanged = |store: &SheetStore<ManualClock>| {
            assert_eq!(body(store, home), home_body);
            assert_eq!(body(store, away), "x");
            assert_eq!(standing(store, home), vec![uuid_a]);
            assert_eq!(detached(store, home), vec![uuid_b]);
            assert!(detached(store, away).is_empty());
            let (page, objects) = store.active_cut().expect("the cut still stands");
            assert_eq!(page, home);
            assert_eq!(objects.iter().map(|c| c.uuid).collect::<Vec<_>>(), [uuid_b]);
            assert_eq!(store.ledger().count(), records);
            assert_eq!(copies(store, uuid_a), 1);
        };

        // The ink stands on the destination; the object's sentinel is refused.
        store.sheet_mut(away).unwrap().document.fail_writes_after(1);
        assert!(store.move_range_to(home, 1, 3, away, 1).is_none());
        unchanged(&store);

        // The source refuses its own deletion.
        store.sheet_mut(home).unwrap().document.fail_writes_after(0);
        assert!(store.move_range_to(home, 1, 3, away, 1).is_none());
        unchanged(&store);

        // And the move runs whole once nothing refuses.
        let placed = store.move_range_to(home, 1, 3, away, 1).unwrap();
        assert_eq!(placed.reattached, 1);
        assert_eq!(standing(&store, away), vec![uuid_a]);
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

    /// `ab`, a record whose value is on another device, then `cd`: five units.
    fn with_a_peer_record(store: &mut SheetStore<ManualClock>) -> (SheetId, ChipId) {
        let id = store.new_tab().1;
        type_at(store, id, 0, "abcd");
        let peer = store
            .stand_peer_record(id, 2, Some(PeerKind::Text), Some(SizeClass::Tiny))
            .unwrap();
        (id, peer)
    }

    const UNAVAILABLE: &str = "[sealed content \u{b7} unavailable]";

    #[test]
    fn a_cut_and_its_first_paste_keep_a_record_with_no_value_by_identity() {
        let (mut store, _) = store();
        let (id, peer) = with_a_peer_record(&mut store);
        let uuid = uuid_of(&store, peer);
        let envelope = store.cut_fragment(id, 1, 3).unwrap().envelope.unwrap();
        assert_eq!(detached(&store, id), vec![uuid]);

        let placed = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!(
            (placed.reattached, placed.cloned, placed.elsewhere),
            (1, 0, 0)
        );
        assert_eq!(standing(&store, id), vec![uuid]);
        let record = store.sheet(id).unwrap().chip(peer).expect("the same chip");
        assert!(!record.is_local());
    }

    #[test]
    fn a_drag_moves_a_record_with_no_value_keeping_its_identity_inside_a_page_and_between_pages() {
        let (mut store, _) = store();
        let (home, peer) = with_a_peer_record(&mut store);
        let uuid = uuid_of(&store, peer);
        let away = store.new_tab().1;
        type_at(&mut store, away, 0, "xy");
        let records = store.ledger().count();

        let inside = store.move_range(home, 1, 3, 5).unwrap();
        assert_eq!((inside.reattached, inside.elsewhere), (1, 0));
        assert_eq!(body(&store, home), "adb\u{FFFC}c");
        assert_eq!(standing(&store, home), vec![uuid]);

        let between = store.move_range_to(home, 2, 3, away, 1).unwrap();
        assert_eq!((between.reattached, between.elsewhere), (1, 0));
        assert_eq!(body(&store, away), "xb\u{FFFC}cy");
        assert_eq!(standing(&store, away), vec![uuid]);
        assert!(standing(&store, home).is_empty() && detached(&store, home).is_empty());
        assert!(!store.sheet(away).unwrap().chip(peer).unwrap().is_local());
        assert_eq!(copies(&store, uuid), 1);
        assert_eq!(store.ledger().count(), records, "a move records nothing");
    }

    #[test]
    fn a_live_reference_ignores_a_value_on_a_page_past_its_deadline() {
        let (mut store, clock) = store();
        let value_page = store.new_tab().1;
        let chip = store.seal_text_at(value_page, A, 0, 0).unwrap();
        let uuid = uuid_of(&store, chip);
        clock.advance(HOUR / 2);
        let peer_page = store.new_tab().1;
        store
            .stand_peer_record_as(peer_page, 0, uuid, None, None)
            .unwrap();
        clock.advance(HOUR / 2);
        assert!(!store.live_object(uuid).unwrap().is_local());
        assert!(store.sheet(value_page).is_some());
    }

    #[test]
    fn a_paste_prefers_the_value_over_an_earlier_peer_record() {
        let (mut store, _) = store();
        let peer_page = store.new_tab().1;
        let value_page = store.new_tab().1;
        let chip = store.seal_text_at(value_page, A, 0, 0).unwrap();
        let uuid = uuid_of(&store, chip);
        store
            .stand_peer_record_as(peer_page, 0, uuid, None, None)
            .unwrap();
        let copied = store.copy_fragment(peer_page, 0, 1).unwrap();
        let dest = store.new_tab().1;
        let placed = store
            .paste_fragment(dest, 0, 0, &copied.envelope.unwrap(), None)
            .unwrap();
        assert_eq!((placed.cloned, placed.elsewhere), (1, 0));
        assert_eq!(payload_at(&store, dest, 0), A.as_bytes());
    }

    #[test]
    fn a_paste_after_copy_places_unavailable_for_a_record_with_no_value_and_counts_elsewhere() {
        let (mut store, _) = store();
        let (id, peer) = with_a_peer_record(&mut store);
        let unknown = store.stand_peer_record(id, 5, None, None).unwrap();
        let uuids = vec![uuid_of(&store, peer), uuid_of(&store, unknown)];
        let copied = store.copy_fragment(id, 1, 5).unwrap();
        assert_eq!(
            copied.plain.as_str(),
            format!("b[sealed content \u{b7} tiny]cd{UNAVAILABLE}")
        );
        let records = store.ledger().count();

        let envelope = copied.envelope.unwrap();
        let placed = store.paste_fragment(id, 6, 0, &envelope, None).unwrap();
        assert_eq!(
            (placed.cloned, placed.elsewhere, placed.unavailable),
            (0, 2, 0)
        );
        assert_eq!(
            body(&store, id),
            format!("ab\u{FFFC}cd\u{FFFC}b{UNAVAILABLE}cd{UNAVAILABLE}")
        );
        assert_eq!(standing(&store, id), uuids, "nothing cloned");
        assert_eq!(store.ledger().count(), records, "no clone was sealed");
    }

    #[test]
    fn a_later_paste_of_a_cut_places_unavailable_for_a_record_with_no_value() {
        let (mut store, _) = store();
        let (id, peer) = with_a_peer_record(&mut store);
        let uuid = uuid_of(&store, peer);
        let envelope = store.cut_fragment(id, 1, 3).unwrap().envelope.unwrap();
        let first = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!(first.reattached, 1);

        let later = store.paste_fragment(id, 0, 0, &envelope, None).unwrap();
        assert_eq!((later.reattached, later.cloned, later.elsewhere), (0, 0, 1));
        assert_eq!(body(&store, id), format!("b{UNAVAILABLE}cb\u{FFFC}cad"));
        assert_eq!(copies(&store, uuid), 1);
    }

    #[test]
    fn an_option_drag_places_unavailable_for_a_record_with_no_value() {
        let (mut store, _) = store();
        let (id, peer) = with_a_peer_record(&mut store);
        let uuid = uuid_of(&store, peer);
        let records = store.ledger().count();
        let placed = store.clone_range(id, 1, 3, 5).unwrap();
        assert_eq!((placed.cloned, placed.elsewhere), (0, 1));
        assert_eq!(body(&store, id), format!("ab\u{FFFC}cdb{UNAVAILABLE}c"));
        assert_eq!(copies(&store, uuid), 1);
        assert_eq!(store.ledger().count(), records);
    }
}
