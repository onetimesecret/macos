//! Coordinated edits over page documents projected into one writing surface.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Instant;

use crate::document::InvalidRange;
use crate::store::validate_edit_ops;
use crate::{
    Clock, EditIntent, EditOp, EditSelection, ItemId, Sheet, SheetId, SheetStore, TextSelection,
};

/// Changes to one identified page within a surface edit.
#[derive(Debug, Clone)]
pub struct ContinuousPageEdit {
    /// Local page identifier.
    pub page_id: SheetId,
    /// Stable identity expected by the caller's projection.
    pub expected_uuid: ItemId,
    /// Version captured alongside the projected body, when supplied.
    pub expected_version: Option<Vec<u8>>,
    /// Body changes, in sequential UTF-16 coordinates.
    pub ops: Vec<EditOp>,
    /// Omitted leaves the boundary alone; an inner None restores its newline.
    pub join_next: Option<Option<ItemId>>,
}

/// A page body and its document metadata sampled together.
pub struct ContinuousSnapshot<'a> {
    /// Page supplying the visible body and stable identity.
    pub page: &'a Sheet,
    /// Exact version of the document supplying the body.
    pub version: Vec<u8>,
    /// Persisted successor joined to this page.
    pub join_next: Option<ItemId>,
}

/// One editing gesture across any number of pages.
#[derive(Debug, Clone)]
pub struct ContinuousEdit {
    /// Ordered, unique page participants.
    pub pages: Vec<ContinuousPageEdit>,
    /// The originating editing gesture.
    pub intent: EditIntent,
    /// Surface selections before and after the gesture.
    pub selection: EditSelection,
}

/// Result of undoing or redoing a coordinated gesture.
#[derive(Debug, Clone)]
pub struct ContinuousStep {
    /// Surface selection to restore.
    pub selection: TextSelection,
    /// Pages changed by this step.
    pub pages: Vec<SheetId>,
}

#[derive(Clone)]
struct Member {
    page: SheetId,
    uuid: ItemId,
    version: Vec<u8>,
}

#[derive(Clone)]
struct Group {
    token: u64,
    members: Vec<Member>,
    selection: EditSelection,
    intent: EditIntent,
    moves: Vec<(ItemId, SheetId, SheetId)>,
}

#[derive(Default)]
struct ScopeHistory {
    undo: Vec<Group>,
    redo: Vec<Group>,
    last_edit_at: Option<Instant>,
}

#[derive(Default)]
pub(crate) struct ContinuousHistory {
    next_token: u64,
    scopes: BTreeMap<String, ScopeHistory>,
}

impl<C: Clock> SheetStore<C> {
    /// Scope owning the next grouped step of a page's local history.
    pub fn continuous_scope_for_step(&self, page: SheetId, back: bool) -> Option<&str> {
        let token = self.sheet(page)?.document.continuous_token(back)?;
        self.continuous.scopes.iter().find_map(|(scope, history)| {
            let group = if back {
                history.undo.last()
            } else {
                history.redo.last()
            }?;
            (group.token == token && group.members.iter().any(|member| member.page == page))
                .then_some(scope.as_str())
        })
    }

    /// Read a page's body and projection metadata through one deadline gate.
    #[must_use]
    pub fn continuous_snapshot(&self, page: SheetId) -> Option<ContinuousSnapshot<'_>> {
        let page = self.readable_sheet(page)?;
        Some(ContinuousSnapshot {
            version: page.document.version(),
            join_next: page.document.join_next(),
            page,
        })
    }

    /// The persisted successor joined to a page, if the page is still readable.
    #[must_use]
    pub fn continuous_join_next(&self, page: SheetId) -> Option<ItemId> {
        self.readable_sheet(page)?.document.join_next()
    }

    /// Admit all page changes before applying one coordinated gesture.
    pub fn apply_continuous(&mut self, scope: &str, edit: &ContinuousEdit) -> bool {
        self.apply_continuous_resetting(scope, edit, &[])
    }

    pub(crate) fn apply_continuous_resetting(
        &mut self,
        scope: &str,
        edit: &ContinuousEdit,
        reset_pages: &[SheetId],
    ) -> bool {
        let now = self.clock.now();
        if scope.is_empty() || scope.len() > 128 || edit.pages.is_empty() {
            return false;
        }
        let mut seen = BTreeSet::new();
        for part in &edit.pages {
            let Some(sheet) = self.sheet(part.page_id) else {
                return false;
            };
            if !seen.insert(part.page_id)
                || sheet.uuid() != part.expected_uuid
                || part
                    .expected_version
                    .as_ref()
                    .is_some_and(|version| *version != sheet.document.version())
                || sheet.is_due(now)
                || !validate_edit_ops(sheet, &part.ops)
                || part.ops.iter().any(|op| {
                    matches!(op, EditOp::InsertChip { chip, .. }
                    if sheet.owned_chip(*chip).is_none_or(|chip| !chip.stood))
                })
            {
                return false;
            }
            if let Some(Some(next)) = part.join_next
                && (next == part.expected_uuid
                    || !self
                        .sheets()
                        .any(|page| page.uuid() == next && !page.is_due(now)))
            {
                return false;
            }
        }
        if reset_pages
            .iter()
            .any(|id| self.sheet(*id).is_none_or(|sheet| sheet.is_due(now)))
        {
            return false;
        }
        let coalescible = reset_pages.is_empty()
            && edit.pages.len() == 1
            && edit.pages[0].join_next.is_none()
            && edit.selection.before.length_u16 == 0
            && edit.selection.after.length_u16 == 0
            && matches!(edit.intent, EditIntent::Typing | EditIntent::Deletion);
        let previous = self.continuous.scopes.get(scope).and_then(|history| {
            let group = history.undo.last()?;
            let recent = history
                .last_edit_at
                .is_some_and(|at| now.saturating_duration_since(at).as_millis() < 1_000);
            (coalescible
                && recent
                && history.redo.is_empty()
                && group.intent == edit.intent
                && group.members.len() == 1
                && group.members[0].page == edit.pages[0].page_id
                && group.selection.after == edit.selection.before
                && self.continuous_group_valid(group, true, now))
            .then_some(group.token)
        });
        let token = if let Some(token) = previous {
            token
        } else {
            let Some(token) = self.continuous.next_token.checked_add(1) else {
                return false;
            };
            self.continuous.next_token = token;
            token
        };
        for id in reset_pages {
            self.sheet(*id)
                .expect("validated source")
                .document
                .forget_undo();
        }
        let checkpoints: Vec<_> = edit
            .pages
            .iter()
            .map(|part| {
                (
                    part.page_id,
                    self.sheet(part.page_id)
                        .expect("validated page")
                        .document
                        .checkpoint(),
                )
            })
            .collect();
        let mut changed = Vec::new();
        for part in &edit.pages {
            let sheet = self.sheet_mut(part.page_id).expect("validated page");
            let old_version = sheet.document.version();
            let result = (|| {
                for op in &part.ops {
                    match op {
                        EditOp::Insert { pos_u16, text } => {
                            sheet.document.insert(*pos_u16 as usize, text)?;
                        }
                        EditOp::Delete { pos_u16, len_u16 } => sheet
                            .document
                            .delete(*pos_u16 as usize, *len_u16 as usize)?,
                        EditOp::InsertChip { pos_u16, chip } => {
                            let uuid = sheet.owned_chip(*chip).expect("validated chip").uuid();
                            sheet.document.insert_chip(*pos_u16 as usize, uuid)?;
                        }
                    }
                }
                if let Some(next) = part.join_next
                    && sheet.document.join_next() != next
                {
                    sheet.document.set_join_next(next)?;
                }
                Ok::<_, InvalidRange>(())
            })();
            if result.is_err() {
                for (id, checkpoint) in &checkpoints {
                    self.sheet(*id)
                        .expect("validated page")
                        .document
                        .rollback(checkpoint);
                    self.settle_document(*id);
                }
                return false;
            }
            sheet
                .document
                .commit_continuous(token, edit.intent, previous.is_some());
            if sheet.document.version() != old_version {
                for op in &part.ops {
                    match op {
                        EditOp::Insert { pos_u16, text } => {
                            sheet.blocks.note_insert(*pos_u16 as usize, text);
                        }
                        EditOp::Delete { pos_u16, len_u16 } => sheet
                            .blocks
                            .note_delete(*pos_u16 as usize, *len_u16 as usize),
                        EditOp::InsertChip { pos_u16, .. } => {
                            sheet.blocks.note_sentinel(*pos_u16 as usize);
                        }
                    }
                }
                changed.push(part.page_id);
            }
        }
        if changed.is_empty() {
            return true;
        }
        for id in &changed {
            self.settle_document(*id);
        }
        let members = changed
            .iter()
            .map(|id| {
                let sheet = self.sheet(*id).expect("validated page");
                Member {
                    page: *id,
                    uuid: sheet.uuid(),
                    version: sheet.document.version(),
                }
            })
            .collect();
        let history = self.continuous.scopes.entry(scope.into()).or_default();
        history.redo.clear();
        if previous.is_some() {
            let group = history.undo.last_mut().expect("coalescing predecessor");
            group.members = members;
            group.selection.after = edit.selection.after;
        } else {
            history.undo.push(Group {
                token,
                members,
                selection: edit.selection,
                intent: edit.intent,
                moves: Vec::new(),
            });
        }
        history.last_edit_at = coalescible.then_some(now);
        if history.undo.len() > 512 {
            history.undo.remove(0);
        }
        true
    }

    pub(crate) fn record_continuous_moves(
        &mut self,
        scope: &str,
        moves: &[(ItemId, SheetId, SheetId)],
    ) -> bool {
        let Some(group) = self
            .continuous
            .scopes
            .get(scope)
            .and_then(|history| history.undo.last())
        else {
            return false;
        };
        if !group.moves.is_empty() || !self.continuous_group_valid(group, true, self.clock.now()) {
            return false;
        }
        let mut unique = BTreeSet::new();
        for (uuid, from, to) in moves {
            if from == to
                || !unique.insert(*uuid)
                || !group.members.iter().any(|member| member.page == *from)
                || !group.members.iter().any(|member| member.page == *to)
                || !self.continuous_move_owner(*uuid, *to, *from)
            {
                return false;
            }
        }
        let history = self
            .continuous
            .scopes
            .get_mut(scope)
            .expect("validated scope");
        history.undo.last_mut().expect("validated group").moves = moves.to_vec();
        history.last_edit_at = None;
        true
    }

    fn continuous_move_owner(&self, uuid: ItemId, owner: SheetId, other: SheetId) -> bool {
        self.sheet(owner).is_some_and(|sheet| {
            sheet
                .chips
                .iter()
                .chain(&sheet.detached)
                .any(|chip| chip.uuid == uuid)
        }) && self.sheet(other).is_some_and(|sheet| {
            !sheet
                .chips
                .iter()
                .chain(&sheet.detached)
                .any(|chip| chip.uuid == uuid)
        })
    }

    /// Discard surface history after its displayed page roster changes.
    pub fn clear_continuous_history(&mut self, scope: &str) {
        self.continuous.scopes.remove(scope);
    }

    /// End a typing or deletion run after a caret move or focus change.
    pub fn finish_continuous_group(&mut self, scope: &str) {
        if let Some(history) = self.continuous.scopes.get_mut(scope) {
            history.last_edit_at = None;
        }
    }

    fn continuous_group_valid(&self, group: &Group, back: bool, now: Instant) -> bool {
        group.moves.iter().all(|(uuid, from, to)| {
            let (owner, other) = if back { (*to, *from) } else { (*from, *to) };
            self.continuous_move_owner(*uuid, owner, other)
        }) && group.members.iter().all(|member| {
            self.sheet(member.page).is_some_and(|sheet| {
                sheet.uuid() == member.uuid
                    && !sheet.is_due(now)
                    && sheet.document.continuous_token(back) == Some(group.token)
                    && sheet.document.version() == member.version
            })
        })
    }

    /// Whether the complete next group can be stepped without bypassing a page edit.
    #[must_use]
    pub fn can_step_continuous(&self, scope: &str, back: bool) -> bool {
        let Some(history) = self.continuous.scopes.get(scope) else {
            return false;
        };
        let stack = if back { &history.undo } else { &history.redo };
        stack
            .last()
            .is_some_and(|group| self.continuous_group_valid(group, back, self.clock.now()))
    }

    /// The gesture name of the next usable group.
    #[must_use]
    pub fn continuous_action_name(&self, scope: &str, back: bool) -> Option<&'static str> {
        if !self.can_step_continuous(scope, back) {
            return None;
        }
        let history = self.continuous.scopes.get(scope)?;
        (if back { &history.undo } else { &history.redo })
            .last()
            .map(|group| group.intent.action_name())
    }

    /// Step every member of the next group, or refuse before changing a member.
    pub fn step_continuous(&mut self, scope: &str, back: bool) -> Option<ContinuousStep> {
        let history = self.continuous.scopes.get(scope)?;
        let mut group = (if back { &history.undo } else { &history.redo })
            .last()?
            .clone();
        if !self.continuous_group_valid(&group, back, self.clock.now()) {
            return None;
        }
        let checkpoints: Vec<_> = group
            .members
            .iter()
            .map(|member| {
                (
                    member.page,
                    self.sheet(member.page)
                        .expect("validated member")
                        .document
                        .checkpoint(),
                )
            })
            .collect();
        for member in &group.members {
            let doc = &mut self
                .sheet_mut(member.page)
                .expect("validated member")
                .document;
            if !(if back { doc.undo() } else { doc.redo() }) {
                for (id, checkpoint) in &checkpoints {
                    self.sheet(*id)
                        .expect("validated member")
                        .document
                        .rollback(checkpoint);
                    self.settle_document(*id);
                }
                return None;
            }
        }
        for (uuid, from, to) in &group.moves {
            let (source, target) = if back { (*to, *from) } else { (*from, *to) };
            let sheet = self.sheet_mut(source).expect("validated source");
            let record = if let Some(index) = sheet.chips.iter().position(|chip| chip.uuid == *uuid)
            {
                sheet.chips.remove(index)
            } else {
                let index = sheet
                    .detached
                    .iter()
                    .position(|chip| chip.uuid == *uuid)
                    .expect("validated moved object");
                sheet.detached.remove(index)
            };
            self.sheet_mut(target)
                .expect("validated destination")
                .detached
                .push(record);
            self.restated.extend([source, target]);
            self.drain_pending_metadata(target, *uuid);
            self.drain_pending_notes(target, *uuid);
            self.note_metadata(target, *uuid);
        }
        for member in &group.members {
            self.settle_document(member.page);
            self.take_out_standings(member.page);
        }
        for member in &mut group.members {
            member.version = self
                .sheet(member.page)
                .expect("validated member")
                .document
                .version();
        }
        let versions: Vec<_> = group
            .members
            .iter()
            .map(|member| {
                let doc = &self.sheet(member.page).expect("validated member").document;
                (
                    member.page,
                    doc.continuous_token(true),
                    doc.continuous_token(false),
                    member.version.clone(),
                )
            })
            .collect();
        let selection = if back {
            group.selection.before
        } else {
            group.selection.after
        };
        let pages = group.members.iter().map(|member| member.page).collect();
        let history = self
            .continuous
            .scopes
            .get_mut(scope)
            .expect("validated scope");
        history.last_edit_at = None;
        if back {
            history.undo.pop();
            history.redo.push(group);
        } else {
            history.redo.pop();
            history.undo.push(group);
        }
        for (page, undo, redo, version) in versions {
            for (stack, token) in [(&mut history.undo, undo), (&mut history.redo, redo)] {
                for group in stack.iter_mut().rev() {
                    if Some(group.token) == token {
                        if let Some(member) =
                            group.members.iter_mut().find(|member| member.page == page)
                        {
                            member.version = version.clone();
                        }
                        break;
                    }
                }
            }
        }
        Some(ContinuousStep { selection, pages })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ManualClock, Segment};
    use std::time::Duration;

    fn setup() -> (SheetStore<ManualClock>, ManualClock, SheetId, SheetId) {
        let clock = ManualClock::new();
        let mut store = SheetStore::new(clock.clone()).with_grace_snap(false);
        let a = store.new_tab().1;
        let b = store.new_tab().1;
        for (page, text) in [(a, "alpha🙂"), (b, "βeta")] {
            assert!(store.apply_ops(
                page,
                &[EditOp::Insert {
                    pos_u16: 0,
                    text: text.into()
                }]
            ));
        }
        (store, clock, a, b)
    }

    fn text(store: &SheetStore<ManualClock>, page: SheetId) -> String {
        store
            .sheet(page)
            .unwrap()
            .segments
            .iter()
            .map(|segment| match segment {
                Segment::Ink(text) => text.as_str(),
                Segment::Chip(_) => "\u{fffc}",
            })
            .collect()
    }

    fn part(
        store: &SheetStore<ManualClock>,
        page: SheetId,
        ops: Vec<EditOp>,
    ) -> ContinuousPageEdit {
        ContinuousPageEdit {
            page_id: page,
            expected_uuid: store.sheet(page).unwrap().uuid(),
            expected_version: None,
            ops,
            join_next: None,
        }
    }

    fn edit(pages: Vec<ContinuousPageEdit>) -> ContinuousEdit {
        ContinuousEdit {
            pages,
            intent: EditIntent::Replacement,
            selection: EditSelection {
                before: TextSelection {
                    location_u16: 2,
                    length_u16: 8,
                },
                after: TextSelection {
                    location_u16: 3,
                    length_u16: 0,
                },
            },
        }
    }

    fn cross_edit(store: &SheetStore<ManualClock>, a: SheetId, b: SheetId) -> ContinuousEdit {
        let mut first = part(
            store,
            a,
            vec![
                EditOp::Delete {
                    pos_u16: 2,
                    len_u16: 5,
                },
                EditOp::Insert {
                    pos_u16: 2,
                    text: "!".into(),
                },
            ],
        );
        first.join_next = Some(Some(store.sheet(b).unwrap().uuid()));
        edit(vec![
            first,
            part(
                store,
                b,
                vec![EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 2,
                }],
            ),
        ])
    }

    fn typing(
        store: &SheetStore<ManualClock>,
        page: SheetId,
        at: u32,
        content: &str,
    ) -> ContinuousEdit {
        ContinuousEdit {
            pages: vec![part(
                store,
                page,
                vec![EditOp::Insert {
                    pos_u16: at,
                    text: content.into(),
                }],
            )],
            intent: EditIntent::Typing,
            selection: EditSelection {
                before: TextSelection {
                    location_u16: at,
                    length_u16: 0,
                },
                after: TextSelection {
                    location_u16: at + content.encode_utf16().count() as u32,
                    length_u16: 0,
                },
            },
        }
    }

    #[test]
    fn page_undo_and_redo_resolve_the_whole_continuous_group() {
        let (mut store, _, a, b) = setup();
        let original = (text(&store, a), text(&store, b));
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        let edited = (text(&store, a), text(&store, b));
        assert!(store.can_undo(a));
        assert_eq!(store.undo_action_name(a), Some("Replace"));
        assert!(store.undo(a));
        assert_eq!((text(&store, a), text(&store, b)), original);
        assert!(store.can_redo(b));
        assert_eq!(store.redo_action_name(b), Some("Replace"));
        assert!(store.redo(b));
        assert_eq!((text(&store, a), text(&store, b)), edited);
    }

    #[test]
    fn page_history_cannot_split_a_group_after_its_scope_was_cleared() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        let edited = (text(&store, a), text(&store, b));
        store.clear_continuous_history("pad");
        assert!(!store.can_undo(a));
        assert_eq!(store.undo_action_name(a), None);
        assert!(!store.undo(a));
        assert!(!store.undo(b));
        assert_eq!((text(&store, a), text(&store, b)), edited);
    }

    #[test]
    fn page_redo_label_is_absent_after_its_continuous_scope_was_cleared() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        assert!(store.undo(a));
        store.clear_continuous_history("pad");
        assert!(!store.can_redo(a));
        assert_eq!(store.redo_action_name(a), None);
        assert_eq!(store.redo_action_name(b), None);
        assert!(!store.redo(a));
    }

    #[test]
    fn adjacent_typing_coalesces_until_a_caret_move_or_pause() {
        let (mut store, clock, a, _) = setup();
        assert!(store.apply_continuous("pad", &typing(&store, a, 7, "a")));
        assert!(store.apply_continuous("pad", &typing(&store, a, 8, "b")));
        let step = store.step_continuous("pad", true).unwrap();
        assert_eq!(text(&store, a), "alpha🙂");
        assert_eq!(step.selection.location_u16, 7);
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(text(&store, a), "alpha🙂ab");
        store.finish_continuous_group("pad");
        assert!(store.apply_continuous("pad", &typing(&store, a, 9, "c")));
        clock.advance(Duration::from_secs(2));
        assert!(store.apply_continuous("pad", &typing(&store, a, 10, "d")));
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(text(&store, a), "alpha🙂abc");
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(text(&store, a), "alpha🙂ab");
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(text(&store, a), "alpha🙂");
    }

    #[test]
    fn a_remote_change_invalidates_global_selection_history() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        let version = store.document_version(b).unwrap();
        let mut replica = crate::document::SheetDocument::new();
        replica
            .import_snapshot(&store.sheet(b).unwrap().document.export_snapshot())
            .unwrap();
        replica.insert(0, "remote").unwrap();
        replica.commit_edit(EditIntent::Typing, None);
        let update = replica.export_updates_since(&version).unwrap();
        assert!(store.apply_remote_update(b, &update).is_ok());
        assert!(store.step_continuous("pad", true).is_none());
        assert_eq!(text(&store, a), "al!");
    }

    #[test]
    fn replacement_and_join_undo_and_redo_as_one_step() {
        let (mut store, _, a, b) = setup();
        let change = cross_edit(&store, a, b);
        assert!(store.apply_continuous("pad", &change));
        assert_eq!(text(&store, a), "al!");
        assert_eq!(text(&store, b), "ta");
        assert_eq!(
            store.continuous_join_next(a),
            Some(store.sheet(b).unwrap().uuid())
        );
        let step = store.step_continuous("pad", true).unwrap();
        assert_eq!(step.selection, change.selection.before);
        assert_eq!(step.pages, vec![a, b]);
        assert_eq!(text(&store, a), "alpha🙂");
        assert_eq!(text(&store, b), "βeta");
        assert_eq!(store.continuous_join_next(a), None);
        assert_eq!(
            store.step_continuous("pad", false).unwrap().selection,
            change.selection.after
        );
        assert_eq!(text(&store, a), "al!");
        assert_eq!(text(&store, b), "ta");
        assert!(store.continuous_join_next(a).is_some());
    }

    #[test]
    fn snapshot_version_rejects_a_stale_same_length_replacement() {
        let (mut store, _, a, b) = setup();
        let mut change = cross_edit(&store, a, b);
        let snapshot = store.continuous_snapshot(b).unwrap();
        assert_eq!(snapshot.page.uuid(), change.pages[1].expected_uuid);
        assert_eq!(snapshot.version, store.document_version(b).unwrap());
        assert_eq!(snapshot.join_next, None);
        change.pages[1].expected_version = Some(snapshot.version);
        assert!(store.apply_ops(
            b,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 4
                },
                EditOp::Insert {
                    pos_u16: 0,
                    text: "else".into()
                },
            ]
        ));
        assert!(!store.apply_continuous("pad", &change));
        assert_eq!(text(&store, a), "alpha🙂");
        assert_eq!(text(&store, b), "else");
        assert!(store.continuous_join_next(a).is_none());
        change.pages[1].expected_version = store.document_version(b);
        assert!(store.apply_continuous("pad", &change));
        let snapshot = store.continuous_snapshot(a).unwrap();
        assert_eq!(snapshot.join_next, Some(store.sheet(b).unwrap().uuid()));
        assert_eq!(snapshot.version, store.document_version(a).unwrap());
    }

    #[test]
    fn a_later_member_refusal_changes_no_earlier_page() {
        let (mut store, _, a, b) = setup();
        let mut change = cross_edit(&store, a, b);
        change.pages[1].ops.push(EditOp::Delete {
            pos_u16: 100,
            len_u16: 1,
        });
        let versions = [store.document_version(a), store.document_version(b)];
        assert!(!store.apply_continuous("pad", &change));
        assert_eq!(
            [store.document_version(a), store.document_version(b)],
            versions
        );
        assert_eq!(text(&store, a), "alpha🙂");
        assert_eq!(text(&store, b), "βeta");
        assert!(store.continuous_join_next(a).is_none());
    }

    #[test]
    fn a_split_surrogate_and_wrong_identity_refuse_before_writes() {
        let (mut store, _, a, b) = setup();
        let mut change = cross_edit(&store, a, b);
        change.pages[0].ops = vec![EditOp::Delete {
            pos_u16: 6,
            len_u16: 1,
        }];
        assert!(!store.apply_continuous("pad", &change));
        change = cross_edit(&store, a, b);
        change.pages[1].expected_uuid = ItemId::random();
        assert!(!store.apply_continuous("pad", &change));
        assert_eq!(text(&store, a), "alpha🙂");
    }

    #[test]
    fn a_direct_edit_to_one_member_refuses_the_whole_undo() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        assert!(store.apply_ops(
            b,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "later ".into()
            }]
        ));
        assert!(!store.can_step_continuous("pad", true));
        assert!(store.step_continuous("pad", true).is_none());
        assert_eq!(text(&store, a), "al!");
        assert_eq!(text(&store, b), "later ta");
        assert!(store.continuous_join_next(a).is_some());
    }

    #[test]
    fn cleared_member_history_refuses_whole_undo() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        store.sheet(b).unwrap().document.forget_undo();
        assert!(store.step_continuous("pad", true).is_none());
        assert_eq!(text(&store, a), "al!");
    }

    #[test]
    fn expired_participant_refuses_apply_and_undo_without_a_sweep() {
        let (mut store, clock, a, b) = setup();
        let change = cross_edit(&store, a, b);
        assert!(store.apply_continuous("pad", &change));
        clock.advance(Duration::from_secs(31 * 24 * 3600));
        assert!(store.step_continuous("pad", true).is_none());
        assert!(!store.apply_continuous("pad", &change));
        assert_eq!(text(&store, a), "al!");
        assert_eq!(text(&store, b), "ta");
    }

    #[test]
    fn compaction_retains_join_state_and_invalidates_history() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        let successor = store.continuous_join_next(a);
        store.sheet_mut(a).unwrap().document.compact();
        assert_eq!(store.continuous_join_next(a), successor);
        assert!(successor.is_some());
        assert!(!store.can_step_continuous("pad", true));
    }

    #[test]
    fn resetting_a_source_preserves_the_new_composite_step() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous_resetting("pad", &cross_edit(&store, a, b), &[a]));
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(text(&store, a), "alpha🙂");
        assert!(!store.can_undo(a));
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(text(&store, a), "al!");
        store.clear_continuous_history("pad");
        assert!(!store.can_step_continuous("pad", true));
    }

    #[test]
    fn separator_only_edit_persists_and_undoes() {
        let (mut store, clock, a, b) = setup();
        let uuid = store.sheet(b).unwrap().uuid();
        let mut boundary = part(&store, a, vec![]);
        boundary.join_next = Some(Some(uuid));
        assert!(store.apply_continuous("pad", &edit(vec![boundary])));
        let bytes = store.snapshot(clock.wall_ms());
        let mut restored = SheetStore::new(clock.clone());
        assert_eq!(restored.restore(&bytes, clock.wall_ms()), Ok(2));
        let first = restored.sheets().next().unwrap().id;
        assert_eq!(restored.continuous_join_next(first), Some(uuid));
        assert!(!restored.can_step_continuous("pad", true));
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(store.continuous_join_next(a), None);
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(store.continuous_join_next(a), Some(uuid));
    }

    #[test]
    fn consecutive_groups_remain_undoable_in_both_directions() {
        let (mut store, _, a, b) = setup();
        assert!(store.apply_continuous("pad", &cross_edit(&store, a, b)));
        let second = edit(vec![part(
            &store,
            a,
            vec![EditOp::Insert {
                pos_u16: 3,
                text: "two".into(),
            }],
        )]);
        assert!(store.apply_continuous("pad", &second));
        assert!(store.step_continuous("pad", true).is_some());
        assert!(store.step_continuous("pad", true).is_some());
        assert_eq!(text(&store, a), "alpha🙂");
        assert!(store.step_continuous("pad", false).is_some());
        assert!(store.step_continuous("pad", false).is_some());
        assert_eq!(text(&store, a), "al!two");
    }

    #[test]
    fn unexpected_write_failure_rolls_back_all_participants() {
        let (mut store, _, a, b) = setup();
        store.sheet(b).unwrap().document.fail_writes_after(0);
        assert!(!store.apply_continuous("pad", &cross_edit(&store, a, b)));
        assert_eq!(text(&store, a), "alpha🙂");
        assert_eq!(text(&store, b), "βeta");
        assert!(store.continuous_join_next(a).is_none());
    }

    #[test]
    fn joined_boundary_is_in_exported_document_updates() {
        let (mut store, _, a, b) = setup();
        let original = store.sheet(a).unwrap().document.export_snapshot();
        let version = store.document_version(a).unwrap();
        let mut boundary = part(&store, a, vec![]);
        let uuid = store.sheet(b).unwrap().uuid();
        boundary.join_next = Some(Some(uuid));
        assert!(store.apply_continuous("pad", &edit(vec![boundary])));
        let update = store.export_document_updates(a, &version).unwrap();
        let replica = crate::document::SheetDocument::new();
        replica.import_snapshot(&original).unwrap();
        replica.import_update(&update, &[]).unwrap();
        assert_eq!(replica.join_next(), Some(uuid));
    }
}
