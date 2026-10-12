//! The sheet body as a Loro document (ADR-0013): one text container,
//! chips as marked sentinel characters. Every Loro call lives here, and
//! every offset in this API is UTF-16: only Loro's `_utf16` methods are used.

use std::cell::Cell;
use std::sync::{Arc, Mutex};

use loro::cursor::{Cursor, PosType, Side};
use loro::event::{Diff, DiffEvent};
use loro::{
    CommitOptions, ContainerTrait as _, ExpandType, ExportMode, LoroDoc, LoroText, LoroValue,
    StyleConfig, StyleConfigMap, TextDelta, UndoItemMeta, UndoManager, VersionVector,
};
use zeroize::Zeroizing;

use crate::persist::RestoreError;
use crate::sheet::ItemId;

/// The mark key that carries a chip's identity on its sentinel.
const CHIP_MARK: &str = "chip";

/// U+FFFC: one UTF-16 code unit, so a chip's wire width is one.
const CHIP_SENTINEL: &str = "\u{FFFC}";

/// Undo grouping window; a ceiling on a step's growth, not an idle-gap
/// detector (block-revisions/2026-0901-pause-boundaries.md). Local only.
const UNDO_MERGE_INTERVAL_MS: i64 = 2_000;

/// The user-visible action one editor commit represents, which Loro
/// cannot infer: part of a typing run, or a discrete undo step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditIntent {
    /// Keyboard input that may join adjacent keyboard input.
    Typing,
    /// Repeated backward or forward deletion.
    Deletion,
    /// One paste gesture.
    Paste,
    /// One cut gesture.
    Cut,
    /// One replacement of a selected or matched range.
    Replacement,
    /// Text the editor inserted or removed on the writer's behalf.
    Automation,
    /// One completed input-method composition.
    Composition,
}

/// A text selection in UTF-16 code units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextSelection {
    /// The selection's lower boundary.
    pub location_u16: u32,
    /// The selected length; zero represents a caret.
    pub length_u16: u32,
}

/// The selection on both sides of one editor action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditSelection {
    /// The selection before the operation batch was applied.
    pub before: TextSelection,
    /// The selection after the operation batch was applied.
    pub after: TextSelection,
}

#[derive(Clone)]
pub(crate) struct StableSelection {
    start: Cursor,
    end: Cursor,
}

impl EditIntent {
    fn is_discrete(self) -> bool {
        matches!(
            self,
            Self::Paste | Self::Cut | Self::Replacement | Self::Automation | Self::Composition
        )
    }

    /// Content-free label used by native Undo and Redo menu titles.
    pub fn action_name(self) -> &'static str {
        match self {
            Self::Typing => "Typing",
            Self::Deletion => "Delete",
            Self::Paste => "Paste",
            Self::Cut => "Cut",
            Self::Replacement => "Replace",
            Self::Automation => "Automatic Change",
            Self::Composition => "Composition",
        }
    }

    fn from_action_name(value: &str) -> Option<Self> {
        match value {
            "Typing" => Some(Self::Typing),
            "Delete" => Some(Self::Deletion),
            "Paste" => Some(Self::Paste),
            "Cut" => Some(Self::Cut),
            "Replace" => Some(Self::Replacement),
            "Automatic Change" => Some(Self::Automation),
            "Composition" => Some(Self::Composition),
            _ => None,
        }
    }
}

/// One run of the body: contiguous ink between chips, or one chip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DocRun {
    /// Visible, editable text.
    Ink(String),
    /// A sealed chip, present in the body as one sentinel character.
    Chip(ItemId),
}

/// An edit whose offsets name no position in the body; the body is unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct InvalidRange;

/// Why a remote update was refused. Every arm leaves the document unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UpdateRefusal {
    /// The bytes do not decode as an update batch.
    Malformed,
    /// The update depends on operations this document lacks. Refused, never
    /// queued: recovery is rejoining at the key frame (ADR-0021).
    MissingHistory,
    /// A chip sentinel names an identity not in the roster, or one twice;
    /// roster and marks stay one-to-one, as on restore.
    ChipRoster,
}

/// What the op log can still prove about a span, frozen into the block
/// index before compaction destroys it (ADR-0013).
pub(crate) struct SpanProvenance {
    /// Earliest change that touched the span, Unix seconds.
    pub(crate) created_s: i64,
    /// Latest change that touched the span, Unix seconds.
    pub(crate) modified_s: i64,
    /// The created-defining change's message. Content: never a read surface.
    pub(crate) origin: Option<String>,
}

/// A sheet's body as a Loro document. The chip mark is `expand: none`, so
/// typing beside a sentinel stays ink.
pub(crate) struct SheetDocument {
    doc: LoroDoc,
    body: LoroText,
    /// Reverts only this peer's operations, which is why undo lives here and
    /// not in `AppKit` (issue #132).
    undo: UndoManager,
    /// Caret after the last popped step, in scalars; converted to UTF-16
    /// once the document is quiet.
    caret: Arc<Mutex<Option<usize>>>,
    /// Cursor pair from the last popped step, resolved once the document is quiet.
    popped_selection: Arc<Mutex<Option<StableSelection>>>,
    /// Selection before an admitted batch; the push hook consumes it.
    pending_edit_selection: Arc<Mutex<Option<StableSelection>>>,
    /// Selection currently shown; copied into the inverse item by undo/redo.
    current_selection: Arc<Mutex<Option<StableSelection>>>,
    /// The selection the next inverse item should restore.
    inverse_selection: Arc<Mutex<Option<StableSelection>>>,
    /// The merge interval currently set; Loro cannot report it. Helpers
    /// restore this, not the constant.
    merge_interval: i64,
    /// The next ordinary commit starts a new step.
    separate_next_commit: Cell<bool>,
    /// Coalescing intent at the top of the stack; typing and deletion each
    /// merge only with their own kind.
    coalescing_intent: Cell<Option<EditIntent>>,
    /// Intent stamped onto the undo item created by the next editor commit.
    pending_edit_intent: Arc<Mutex<Option<EditIntent>>>,
    /// Intent carried by the item most recently popped from either stack.
    popped_edit_intent: Arc<Mutex<Option<EditIntent>>>,
    /// Set only across the Take theirs commit; the push hook stamps it.
    take_theirs_commit: Arc<Mutex<Option<i64>>>,
    /// Take theirs generation of the last popped item.
    popped_take_theirs: Arc<Mutex<Option<i64>>>,
}

impl SheetDocument {
    /// A fresh, empty document with a random peer identity.
    pub(crate) fn new() -> Self {
        let doc = LoroDoc::new();
        doc.set_record_timestamp(true);
        // Every commit its own change, so a block's modified stamp is never up to
        // 1000 s stale (block-revisions/2026-0901-pause-boundaries.md).
        doc.set_change_merge_interval(0);
        let mut styles = StyleConfigMap::new();
        styles.insert(
            CHIP_MARK.into(),
            StyleConfig {
                expand: ExpandType::None,
            },
        );
        doc.config_text_style(styles);
        let body = doc.get_text("body");
        // Bound here only, so restore and compaction (both re-mint the peer)
        // start with an empty stack (block-revisions/2026-0829-loro-reconciliation.md).
        let binding = bind_undo(&doc, &body);
        Self {
            doc,
            body,
            undo: binding.undo,
            caret: binding.caret,
            popped_selection: binding.popped_selection,
            pending_edit_selection: binding.pending_edit_selection,
            current_selection: binding.current_selection,
            inverse_selection: binding.inverse_selection,
            merge_interval: UNDO_MERGE_INTERVAL_MS,
            separate_next_commit: Cell::new(false),
            coalescing_intent: Cell::new(None),
            pending_edit_intent: binding.pending_edit_intent,
            popped_edit_intent: binding.popped_edit_intent,
            take_theirs_commit: binding.take_theirs_commit,
            popped_take_theirs: binding.popped_take_theirs,
        }
    }

    /// Undo one step of this peer's own edits; returns whether anything moved.
    pub(crate) fn undo(&mut self) -> bool {
        self.set_caret(None);
        self.clear_popped_selection();
        self.set_popped_take_theirs(None);
        self.seed_inverse_selection();
        // A library refusal reads as no step taken.
        let applied = self.undo.undo().unwrap_or(false);
        self.clear_inverse_selection();
        applied
    }

    /// Redo one step; returns whether anything moved.
    pub(crate) fn redo(&mut self) -> bool {
        self.set_caret(None);
        self.clear_popped_selection();
        self.set_popped_take_theirs(None);
        self.seed_inverse_selection();
        let applied = self.undo.redo().unwrap_or(false);
        self.clear_inverse_selection();
        applied
    }

    /// Generation of the last popped Take theirs action, kept across undo/redo.
    pub(crate) fn popped_take_theirs(&self) -> Option<i64> {
        *self.popped_take_theirs.lock().ok()?
    }

    /// Whether a step is waiting to be taken back.
    pub(crate) fn can_undo(&self) -> bool {
        self.undo.can_undo()
    }

    /// Whether a step that was taken back is waiting to be restored.
    pub(crate) fn can_redo(&self) -> bool {
        self.undo.can_redo()
    }

    pub(crate) fn undo_action_name(&self) -> Option<&'static str> {
        self.undo
            .top_undo_value()
            .as_ref()
            .and_then(edit_intent_from_value)
            .map(EditIntent::action_name)
    }

    pub(crate) fn redo_action_name(&self) -> Option<&'static str> {
        self.undo
            .top_redo_value()
            .as_ref()
            .and_then(edit_intent_from_value)
            .map(EditIntent::action_name)
    }

    /// Commit an editor action: discrete intents stand alone, typing and
    /// deletion coalesce only with their own kind.
    pub(crate) fn commit_edit(&mut self, intent: EditIntent, message: Option<&str>) {
        self.commit_edit_inner(intent, message);
    }

    /// Capture a selection as cursors that follow later edits.
    pub(crate) fn snapshot_selection(&self, selection: TextSelection) -> Option<StableSelection> {
        let start_u16 = selection.location_u16 as usize;
        let end_u16 = start_u16.checked_add(selection.length_u16 as usize)?;
        let start = self
            .body
            .convert_pos(start_u16, PosType::Utf16, PosType::Unicode)?;
        let end = self
            .body
            .convert_pos(end_u16, PosType::Utf16, PosType::Unicode)?;
        Some(StableSelection {
            start: self.body.get_cursor(start, Side::Left)?,
            end: self.body.get_cursor(end, Side::Right)?,
        })
    }

    /// Commit an editor action with its before and after selections. A merged
    /// run keeps its first `before` and its last `after`.
    pub(crate) fn commit_edit_with_selection(
        &mut self,
        intent: EditIntent,
        message: Option<&str>,
        before: StableSelection,
        after: TextSelection,
    ) {
        let Some(after) = self.snapshot_selection(after) else {
            self.commit_edit_inner(intent, message);
            return;
        };
        if let Ok(mut slot) = self.pending_edit_selection.lock() {
            *slot = Some(before);
        }
        self.commit_edit_inner(intent, message);
        if let Ok(mut slot) = self.pending_edit_selection.lock() {
            *slot = None;
        }
        if let Ok(mut slot) = self.current_selection.lock() {
            *slot = Some(after);
        }
    }

    fn commit_edit_inner(&mut self, intent: EditIntent, message: Option<&str>) {
        let follows_boundary = self.separate_next_commit.replace(false);
        let changes_coalescing_kind = !intent.is_discrete()
            && self
                .coalescing_intent
                .get()
                .is_some_and(|previous| previous != intent);
        let separate = follows_boundary || intent.is_discrete() || changes_coalescing_kind;
        if separate {
            self.undo.set_merge_interval(0);
        }
        if let Ok(mut slot) = self.pending_edit_intent.lock() {
            *slot = Some(intent);
        }
        self.commit_now(message);
        if let Ok(mut slot) = self.pending_edit_intent.lock() {
            *slot = None;
        }
        if separate {
            self.undo.set_merge_interval(self.merge_interval);
        }

        if intent.is_discrete() {
            self.separate_next_commit.set(true);
            self.coalescing_intent.set(None);
        } else {
            self.coalescing_intent.set(Some(intent));
        }
    }

    /// End the coalescing run, so typing after a caret move starts a new step.
    pub(crate) fn finish_editing_group(&self, selection: Option<TextSelection>) {
        self.separate_next_commit.set(true);
        self.coalescing_intent.set(None);
        if let Ok(mut slot) = self.pending_edit_intent.lock() {
            *slot = None;
        }
        if let Ok(mut slot) = self.popped_edit_intent.lock() {
            *slot = None;
        }
        if let Some(selection) = selection.and_then(|value| self.snapshot_selection(value))
            && let Ok(mut slot) = self.current_selection.lock()
        {
            *slot = Some(selection);
        }
    }

    /// Commit Take theirs as an isolated undo item. Returns whether the top
    /// undo item now carries `generation`; an empty commit pushes none.
    pub(crate) fn commit_take_theirs_step(&mut self, generation: i64) -> bool {
        self.set_take_theirs_commit(Some(generation));
        self.undo.set_merge_interval(0);
        self.commit_now(None);
        self.undo.set_merge_interval(self.merge_interval);
        // A slot still holding the generation means nothing was pushed; the top
        // check rules out another push having consumed it.
        let consumed = self
            .take_theirs_commit
            .lock()
            .is_ok_and(|slot| slot.is_none());
        let expected_top = matches!(
            self.undo.top_undo_value(),
            Some(LoroValue::I64(top_generation)) if top_generation == generation
        );
        debug_assert!(
            !consumed || expected_top,
            "Take theirs marker was consumed by a non-top undo item"
        );
        self.set_take_theirs_commit(None);
        self.separate_next_commit.set(true);
        self.coalescing_intent.set(None);
        consumed && expected_top
    }

    /// Caret after the last undo or redo, in UTF-16; `None` when there is no
    /// recorded position or it no longer lands on a boundary.
    pub(crate) fn restored_caret(&self) -> Option<usize> {
        if let Some(selection) = self.restored_selection() {
            return Some(selection.location_u16 as usize);
        }
        let scalar = (*self.caret.lock().ok()?)?;
        self.body
            .convert_pos(scalar, PosType::Unicode, PosType::Utf16)
    }

    /// The selection restored by the last undo or redo, moved through remote edits.
    pub(crate) fn restored_selection(&self) -> Option<TextSelection> {
        let stable = self.popped_selection.lock().ok()?.clone()?;
        let start = self.doc.get_cursor_pos(&stable.start).ok()?.current.pos;
        let end = self.doc.get_cursor_pos(&stable.end).ok()?.current.pos;
        let start = self
            .body
            .convert_pos(start, PosType::Unicode, PosType::Utf16)?;
        let end = self
            .body
            .convert_pos(end, PosType::Unicode, PosType::Utf16)?;
        let (location, far_edge) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        Some(TextSelection {
            location_u16: u32::try_from(location).ok()?,
            length_u16: u32::try_from(far_edge - location).ok()?,
        })
    }

    /// Clear both stacks: after compaction, a wholesale restate, or any chip
    /// roster change, since sealing is one-way (D-30).
    pub(crate) fn forget_undo(&self) {
        self.undo.clear();
        self.set_caret(None);
        self.clear_popped_selection();
        self.separate_next_commit.set(false);
        self.coalescing_intent.set(None);
        self.set_take_theirs_commit(None);
        self.set_popped_take_theirs(None);
        if let Ok(mut slot) = self.pending_edit_selection.lock() {
            *slot = None;
        }
        if let Ok(mut slot) = self.current_selection.lock() {
            *slot = None;
        }
        self.clear_inverse_selection();
    }

    /// Tolerates a poisoned lock; the caret then simply does not move.
    fn set_caret(&self, scalar: Option<usize>) {
        if let Ok(mut slot) = self.caret.lock() {
            *slot = scalar;
        }
    }

    fn clear_popped_selection(&self) {
        if let Ok(mut slot) = self.popped_selection.lock() {
            *slot = None;
        }
    }

    fn seed_inverse_selection(&self) {
        let current = self
            .current_selection
            .lock()
            .ok()
            .and_then(|slot| slot.clone());
        let refreshed = current.and_then(|selection| self.refresh_selection(&selection));
        if let Ok(mut slot) = self.inverse_selection.lock() {
            *slot = refreshed;
        }
    }

    fn clear_inverse_selection(&self) {
        if let Ok(mut slot) = self.inverse_selection.lock() {
            *slot = None;
        }
    }

    fn refresh_selection(&self, selection: &StableSelection) -> Option<StableSelection> {
        let start = self.doc.get_cursor_pos(&selection.start).ok()?.current.pos;
        let end = self.doc.get_cursor_pos(&selection.end).ok()?.current.pos;
        Some(StableSelection {
            start: self.body.get_cursor(start, Side::Left)?,
            end: self.body.get_cursor(end, Side::Right)?,
        })
    }

    fn set_take_theirs_commit(&self, value: Option<i64>) {
        if let Ok(mut slot) = self.take_theirs_commit.lock() {
            *slot = value;
        }
    }

    fn set_popped_take_theirs(&self, value: Option<i64>) {
        if let Ok(mut slot) = self.popped_take_theirs.lock() {
            *slot = value;
        }
    }

    /// Insert ink at a UTF-16 offset.
    pub(crate) fn insert(&self, pos: usize, text: &str) -> Result<(), InvalidRange> {
        if text.is_empty() {
            return if pos <= self.utf16_len() {
                Ok(())
            } else {
                Err(InvalidRange)
            };
        }
        self.body.insert_utf16(pos, text).map_err(|_| InvalidRange)
    }

    /// Delete a UTF-16 range.
    pub(crate) fn delete(&self, pos: usize, len: usize) -> Result<(), InvalidRange> {
        if len == 0 {
            return if pos <= self.utf16_len() {
                Ok(())
            } else {
                Err(InvalidRange)
            };
        }
        self.body.delete_utf16(pos, len).map_err(|_| InvalidRange)
    }

    /// Insert a chip sentinel marked with its identity; if marking fails the
    /// sentinel is removed again.
    pub(crate) fn insert_chip(&self, pos: usize, id: ItemId) -> Result<(), InvalidRange> {
        self.body
            .insert_utf16(pos, CHIP_SENTINEL)
            .map_err(|_| InvalidRange)?;
        if self
            .body
            .mark_utf16(pos..pos + 1, CHIP_MARK, id.to_string())
            .is_err()
        {
            let _ = self.body.delete_utf16(pos, 1);
            return Err(InvalidRange);
        }
        Ok(())
    }

    /// Commit the open transaction, optionally with a persisted message.
    pub(crate) fn commit(&self, message: Option<&str>) {
        self.commit_now(message);
    }

    fn commit_now(&self, message: Option<&str>) {
        let mut options = CommitOptions::new().immediate_renew(true);
        if let Some(message) = message {
            options = options.commit_msg(message);
        }
        self.doc.commit_with(options);
    }

    /// The body split into ink and chips. A sentinel with an unreadable mark is ink.
    pub(crate) fn runs(&self) -> Vec<DocRun> {
        runs_of(&self.body)
    }

    /// Chips still standing, in document order; deleting a sentinel kills its chip.
    pub(crate) fn live_chips(&self) -> Vec<ItemId> {
        chips_of(&self.body)
    }

    /// UTF-16 offset of a chip's sentinel, if it still stands.
    pub(crate) fn chip_position(&self, id: ItemId) -> Option<usize> {
        let mut pos = 0usize;
        for run in self.runs() {
            match run {
                DocRun::Chip(found) if found == id => return Some(pos),
                DocRun::Chip(_) => pos += 1,
                DocRun::Ink(text) => pos += text.encode_utf16().count(),
            }
        }
        None
    }

    /// The whole document, history and deleted text included, for encryption.
    pub(crate) fn export_snapshot(&self) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(
            self.doc
                .export(ExportMode::Snapshot)
                .expect("a full snapshot export has no refusable input"),
        )
    }

    /// Merge a snapshot; anything undecodable is [`RestoreError::Malformed`].
    pub(crate) fn import_snapshot(&self, bytes: &[u8]) -> Result<(), RestoreError> {
        self.doc
            .import(bytes)
            .map(|_| ())
            .map_err(|_| RestoreError::Malformed)
    }

    /// The sync frontier as opaque bytes, decoded only by
    /// [`SheetDocument::export_updates_since`]; peer ids stay inside (issue #96).
    pub(crate) fn version(&self) -> Vec<u8> {
        self.doc.oplog_vv().encode()
    }

    /// The frontier of an empty document. `VersionVector::decode` refuses
    /// empty bytes, so the empty cursor is spelled here.
    pub(crate) fn pristine_version() -> Vec<u8> {
        VersionVector::default().encode()
    }

    /// The ops beyond `version`, history included; `None` if `version` does
    /// not decode. An unknown frontier yields everything.
    pub(crate) fn export_updates_since(&self, version: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let from = VersionVector::decode(version).ok()?;
        Some(Zeroizing::new(
            self.doc
                .export(ExportMode::updates(&from))
                .expect("an updates export since a decoded frontier has no refusable input"),
        ))
    }

    /// Apply a remote update batch only if a trial on a fork is clean:
    /// decodable, no missing history, chips one-to-one with `owned`.
    pub(crate) fn import_update(
        &self,
        bytes: &[u8],
        owned: &[ItemId],
    ) -> Result<(), UpdateRefusal> {
        // A bare fork, not a `SheetDocument`: no undo stack to bind.
        let trial = self.doc.fork();
        let body = trial.get_text("body");
        let status = trial.import(bytes).map_err(|_| UpdateRefusal::Malformed)?;
        if status.pending.is_some() {
            return Err(UpdateRefusal::MissingHistory);
        }
        let mut seen: Vec<ItemId> = Vec::new();
        for id in chips_of(&body) {
            if !owned.contains(&id) || seen.contains(&id) {
                return Err(UpdateRefusal::ChipRoster);
            }
            seen.push(id);
        }
        let status = self
            .doc
            .import(bytes)
            .expect("the same bytes imported cleanly into a fork a moment ago");
        debug_assert!(
            status.pending.is_none(),
            "a batch the fork applied whole cannot leave pending ops here"
        );
        Ok(())
    }

    /// The body's length in UTF-16 code units.
    pub(crate) fn utf16_len(&self) -> usize {
        self.body.len_utf16()
    }

    /// No operations recorded yet: the only state that may adopt a key frame,
    /// since merging over standing ops would duplicate the body.
    pub(crate) fn is_pristine(&self) -> bool {
        self.doc.oplog_frontiers().is_empty()
    }

    /// A block's position as opaque cursor bytes. The first block anchors at
    /// the container so it survives ink typed ahead of it.
    pub(crate) fn block_anchor(&self, start_u16: usize, container_start: bool) -> Option<Vec<u8>> {
        if container_start {
            return Some(Cursor::new(None, self.body.id(), Side::Left, 0).encode());
        }
        let scalar = self
            .body
            .convert_pos(start_u16, PosType::Utf16, PosType::Unicode)?;
        self.body
            .get_cursor(scalar, Side::Left)
            .map(|cursor| cursor.encode())
    }

    /// Resolve anchor bytes to a UTF-16 offset, if the anchor still lands.
    pub(crate) fn resolve_anchor(&self, anchor: &[u8]) -> Option<usize> {
        let cursor = Cursor::decode(anchor).ok()?;
        let found = self.doc.get_cursor_pos(&cursor).ok()?;
        self.body
            .convert_pos(found.current.pos, PosType::Unicode, PosType::Utf16)
    }

    /// Earliest and latest commit stamps of a span, Unix seconds (ADR-0013).
    /// `None` for an empty span, a bad offset, or no committed characters.
    pub(crate) fn span_timestamps(&self, start_u16: usize, len_u16: usize) -> Option<(i64, i64)> {
        self.span_provenance(start_u16, len_u16)
            .map(|derived| (derived.created_s, derived.modified_s))
    }

    /// [`SheetDocument::span_timestamps`] plus the created-defining change's
    /// message. Epoch-stamped changes (the compaction rebuild) do not vote.
    pub(crate) fn span_provenance(
        &self,
        start_u16: usize,
        len_u16: usize,
    ) -> Option<SpanProvenance> {
        if len_u16 == 0 {
            return None;
        }
        let start = self
            .body
            .convert_pos(start_u16, PosType::Utf16, PosType::Unicode)?;
        let end = self
            .body
            .convert_pos(start_u16 + len_u16, PosType::Utf16, PosType::Unicode)?;
        let mut derived: Option<SpanProvenance> = None;
        for pos in start..end {
            let Some(id) = self.body.get_cursor(pos, Side::Middle).and_then(|c| c.id) else {
                continue;
            };
            let Some(change) = self.doc.get_change(id) else {
                continue;
            };
            let stamp = change.timestamp;
            if stamp <= 0 {
                continue;
            }
            let message = || {
                let message = change.message();
                (!message.is_empty()).then(|| message.to_string())
            };
            derived = Some(match derived {
                None => SpanProvenance {
                    created_s: stamp,
                    modified_s: stamp,
                    origin: message(),
                },
                Some(so_far) => {
                    // A strictly earlier stamp takes the created role; a tie keeps the first.
                    let origin = if stamp < so_far.created_s {
                        message()
                    } else {
                        so_far.origin
                    };
                    SpanProvenance {
                        created_s: so_far.created_s.min(stamp),
                        modified_s: so_far.modified_s.max(stamp),
                        origin,
                    }
                }
            });
        }
        derived
    }

    /// The newest change's timestamp, Unix seconds; the epoch-stamped
    /// compaction rebuild does not count.
    pub(crate) fn latest_timestamp(&self) -> Option<i64> {
        self.doc
            .oplog_frontiers()
            .iter()
            .filter_map(|id| self.doc.get_change(id))
            .map(|change| change.timestamp)
            .filter(|stamp| *stamp > 0)
            .max()
    }

    /// Compaction's discard half (ADR-0013): re-type the runs into a fresh
    /// document under a new peer id. A `StateOnly` export would keep the old
    /// peer id (see the spike test). If the rebuild fails, the old document stays.
    pub(crate) fn compact(&mut self) {
        let runs = self.runs();
        let fresh = Self::new();
        while fresh.doc.peer_id() == self.doc.peer_id() {
            let mut bytes = [0u8; 8];
            getrandom::getrandom(&mut bytes).expect("the OS CSPRNG must be available");
            fresh
                .doc
                .set_peer_id(u64::from_le_bytes(bytes))
                .expect("a document with no ops accepts a peer id");
        }
        let mut pos = 0usize;
        for run in &runs {
            let landed = match run {
                DocRun::Ink(text) => {
                    let landed = fresh.body.insert_utf16(pos, text).is_ok();
                    pos += text.encode_utf16().count();
                    landed
                }
                DocRun::Chip(id) => {
                    let landed = fresh.insert_chip(pos, *id).is_ok();
                    pos += 1;
                    landed
                }
            };
            if !landed {
                return;
            }
        }
        fresh
            .doc
            .commit_with(CommitOptions::new().immediate_renew(true).timestamp(0));
        *self = fresh;
        // The re-typing pushed an undo step that would empty the page.
        self.forget_undo();
    }

    /// Commit with an injected timestamp.
    #[cfg(test)]
    pub(crate) fn commit_at(&self, timestamp: i64) {
        self.doc.commit_with(
            CommitOptions::new()
                .immediate_renew(true)
                .timestamp(timestamp),
        );
    }

    /// Retune the undo merge interval (test-only).
    #[cfg(test)]
    pub(crate) fn set_merge_interval(&mut self, ms: i64) {
        self.merge_interval = ms;
        self.undo.set_merge_interval(ms);
    }

    /// This document's peer id (test-only).
    #[cfg(test)]
    pub(crate) fn peer_id(&self) -> u64 {
        self.doc.peer_id()
    }

    /// Commit timestamp of the body's first character (test-only).
    #[cfg(test)]
    pub(crate) fn first_change_timestamp(&self) -> Option<i64> {
        let cursor = self.body.get_cursor(0, Side::Middle)?;
        let change = self.doc.get_change(cursor.id?)?;
        Some(change.timestamp)
    }

    /// Counts local commits from now on whose diff carries a chip mark on a retain (test-only).
    #[cfg(test)]
    pub(crate) fn count_mark_only_chip_writes(&self) -> Arc<std::sync::atomic::AtomicUsize> {
        let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let sink = Arc::clone(&count);
        self.doc
            .subscribe_root(Arc::new(move |event| {
                if event.triggered_by != loro::EventTriggerKind::Local {
                    return;
                }
                let marked_retain = event.events.iter().any(|container| {
                    matches!(&container.diff, Diff::Text(deltas) if deltas.iter().any(|delta| {
                        matches!(delta, TextDelta::Retain { attributes: Some(attributes), .. }
                            if attributes.contains_key(CHIP_MARK))
                    }))
                });
                if marked_retain {
                    sink.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
            }))
            .detach();
        count
    }

    /// Commit message of the body's first character (test-only).
    #[cfg(test)]
    pub(crate) fn first_change_message(&self) -> Option<String> {
        let cursor = self.body.get_cursor(0, Side::Middle)?;
        let change = self.doc.get_change(cursor.id?)?;
        let message = change.message();
        (!message.is_empty()).then(|| message.to_string())
    }
}

/// A body split into ink and chips; free-standing so a fork can be read.
fn runs_of(body: &LoroText) -> Vec<DocRun> {
    let mut runs: Vec<DocRun> = Vec::new();
    for piece in body.to_delta() {
        let TextDelta::Insert { insert, attributes } = piece else {
            continue;
        };
        let chip = attributes
            .as_ref()
            .and_then(|attrs| attrs.get(CHIP_MARK))
            .and_then(parse_mark_value);
        match chip {
            Some(id) => runs.push(DocRun::Chip(id)),
            None => match runs.last_mut() {
                Some(DocRun::Ink(text)) => text.push_str(&insert),
                _ => runs.push(DocRun::Ink(insert)),
            },
        }
    }
    runs
}

/// Every chip standing in a body, in document order.
fn chips_of(body: &LoroText) -> Vec<ItemId> {
    runs_of(body)
        .into_iter()
        .filter_map(|run| match run {
            DocRun::Chip(id) => Some(id),
            DocRun::Ink(_) => None,
        })
        .collect()
}

/// The push hook reads the body in Loro's callback; relies on loro 1.13.9 `emit_events` unlocking first.
struct UndoBinding {
    undo: UndoManager,
    caret: Arc<Mutex<Option<usize>>>,
    popped_selection: Arc<Mutex<Option<StableSelection>>>,
    pending_edit_intent: Arc<Mutex<Option<EditIntent>>>,
    popped_edit_intent: Arc<Mutex<Option<EditIntent>>>,
    pending_edit_selection: Arc<Mutex<Option<StableSelection>>>,
    current_selection: Arc<Mutex<Option<StableSelection>>>,
    inverse_selection: Arc<Mutex<Option<StableSelection>>>,
    take_theirs_commit: Arc<Mutex<Option<i64>>>,
    popped_take_theirs: Arc<Mutex<Option<i64>>>,
}

fn bind_undo(doc: &LoroDoc, body: &LoroText) -> UndoBinding {
    let mut undo = UndoManager::new(doc);
    undo.set_merge_interval(UNDO_MERGE_INTERVAL_MS);

    let take_theirs_commit = Arc::new(Mutex::new(None));
    let take_theirs_source = Arc::clone(&take_theirs_commit);
    let popped_take_theirs = Arc::new(Mutex::new(None));
    let inverse_take_theirs_source = Arc::clone(&popped_take_theirs);
    let pending_edit_selection = Arc::new(Mutex::new(None::<StableSelection>));
    let pending_edit_source = Arc::clone(&pending_edit_selection);
    let current_selection = Arc::new(Mutex::new(None::<StableSelection>));
    let inverse_selection = Arc::new(Mutex::new(None::<StableSelection>));
    let inverse_selection_source = Arc::clone(&inverse_selection);
    let anchor = body.clone();
    let pending_edit_intent = Arc::new(Mutex::new(None::<EditIntent>));
    let pending_edit_intent_source = Arc::clone(&pending_edit_intent);
    let popped_edit_intent = Arc::new(Mutex::new(None::<EditIntent>));
    let inverse_edit_intent_source = Arc::clone(&popped_edit_intent);
    undo.set_on_push(Some(Box::new(move |_kind, _span, event| {
        let mut meta = UndoItemMeta::new();
        // Taken, so the committer can tell whether an item carried it.
        let explicit_commit = take_theirs_source
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        let inverse_step = event
            .is_none()
            .then(|| {
                inverse_take_theirs_source
                    .lock()
                    .ok()
                    .and_then(|slot| *slot)
            })
            .flatten();
        if let Some(generation) = explicit_commit.or(inverse_step) {
            meta.set_value(LoroValue::I64(generation));
        } else {
            let intent = if event.is_some() {
                pending_edit_intent_source
                    .lock()
                    .ok()
                    .and_then(|mut slot| slot.take())
            } else {
                inverse_edit_intent_source
                    .lock()
                    .ok()
                    .and_then(|slot| *slot)
            };
            if let Some(intent) = intent {
                meta.set_value(LoroValue::String(intent.action_name().to_string().into()));
            }
        }
        let edit_selection = if event.is_some() {
            pending_edit_source
                .lock()
                .ok()
                .and_then(|mut slot| slot.take())
        } else {
            inverse_selection_source
                .lock()
                .ok()
                .and_then(|mut slot| slot.take())
        };
        if let Some(selection) = edit_selection {
            meta.add_cursor(&selection.start);
            meta.add_cursor(&selection.end);
        }
        // A cursor, so the position follows remote ops while the step waits.
        if meta.cursors.is_empty()
            && let Some(pos) = event.as_ref().and_then(change_start)
            && let Some(cursor) = anchor.get_cursor(pos, Side::Left)
        {
            meta.add_cursor(&cursor);
        }
        meta
    })));

    let caret = Arc::new(Mutex::new(None));
    let sink = Arc::clone(&caret);
    let popped_selection = Arc::new(Mutex::new(None::<StableSelection>));
    let popped_selection_sink = Arc::clone(&popped_selection);
    let current_selection_sink = Arc::clone(&current_selection);
    let popped_edit_intent_sink = Arc::clone(&popped_edit_intent);
    let take_theirs_sink = Arc::clone(&popped_take_theirs);
    undo.set_on_pop(Some(Box::new(move |_kind, _span, meta| {
        if let Ok(mut slot) = sink.lock() {
            *slot = meta.cursors.first().map(|cursor| cursor.pos.pos);
        }
        if let Ok(mut slot) = popped_selection_sink.lock() {
            *slot = (meta.cursors.len() >= 2).then(|| StableSelection {
                start: meta.cursors[0].cursor.clone(),
                end: meta.cursors[1].cursor.clone(),
            });
        }
        if let Ok(mut slot) = current_selection_sink.lock() {
            *slot = if meta.cursors.len() >= 2 {
                Some(StableSelection {
                    start: meta.cursors[0].cursor.clone(),
                    end: meta.cursors[1].cursor.clone(),
                })
            } else {
                None
            };
        }
        if let Ok(mut slot) = popped_edit_intent_sink.lock() {
            *slot = edit_intent_from_value(&meta.value);
        }
        if let Ok(mut slot) = take_theirs_sink.lock() {
            *slot = match meta.value {
                LoroValue::I64(generation) => Some(generation),
                _ => None,
            };
        }
    })));

    UndoBinding {
        undo,
        caret,
        popped_selection,
        pending_edit_intent,
        popped_edit_intent,
        pending_edit_selection,
        current_selection,
        inverse_selection,
        take_theirs_commit,
        popped_take_theirs,
    }
}

/// Where a local change began, in scalars: the retain before the first insert or delete.
fn change_start(event: &DiffEvent) -> Option<usize> {
    for container in &event.events {
        let Diff::Text(deltas) = &container.diff else {
            continue;
        };
        let mut pos = 0usize;
        for delta in deltas {
            match delta {
                TextDelta::Retain { retain, .. } => pos += retain,
                TextDelta::Insert { .. } | TextDelta::Delete { .. } => return Some(pos),
            }
        }
    }
    None
}

fn edit_intent_from_value(value: &LoroValue) -> Option<EditIntent> {
    let LoroValue::String(value) = value else {
        return None;
    };
    EditIntent::from_action_name(value)
}

/// A chip identity from its mark value; `None` for any other shape.
fn parse_mark_value(value: &LoroValue) -> Option<ItemId> {
    let LoroValue::String(text) = value else {
        return None;
    };
    parse_item_id(text)
}

/// Parse the 8-4-4-4-12 hex form, the inverse of [`ItemId`]'s `Display`.
fn parse_item_id(text: &str) -> Option<ItemId> {
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
    Some(ItemId::from_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use loro::cursor::Side;

    use super::*;

    #[test]
    fn utf16_offsets_round_trip_through_astral_characters() {
        let doc = SheetDocument::new();
        doc.insert(0, "a\u{1F600}b").unwrap();
        assert_eq!(doc.utf16_len(), 4);
        doc.delete(1, 2).unwrap();
        assert_eq!(doc.runs(), vec![DocRun::Ink("ab".to_string())]);
        assert_eq!(doc.utf16_len(), 2);
    }

    #[test]
    fn a_chip_survives_edits_on_either_side() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        doc.insert(0, "before").unwrap();
        doc.insert_chip(6, id).unwrap();
        doc.insert(7, "after").unwrap();
        doc.insert(0, "\u{1F980} ").unwrap();
        doc.delete(0, 3).unwrap();
        assert_eq!(
            doc.runs(),
            vec![
                DocRun::Ink("before".to_string()),
                DocRun::Chip(id),
                DocRun::Ink("after".to_string()),
            ]
        );
    }

    #[test]
    fn deleting_the_sentinel_removes_the_chip() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        doc.insert(0, "ab").unwrap();
        doc.insert_chip(1, id).unwrap();
        assert_eq!(doc.live_chips(), vec![id]);
        doc.delete(1, 1).unwrap();
        assert!(doc.live_chips().is_empty());
        assert_eq!(doc.runs(), vec![DocRun::Ink("ab".to_string())]);
    }

    #[test]
    fn typing_against_a_chip_does_not_extend_the_mark() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        doc.insert_chip(0, id).unwrap();
        doc.insert(0, "x\u{1F600}").unwrap();
        doc.insert(4, "y").unwrap();
        assert_eq!(
            doc.runs(),
            vec![
                DocRun::Ink("x\u{1F600}".to_string()),
                DocRun::Chip(id),
                DocRun::Ink("y".to_string()),
            ]
        );
    }

    #[test]
    fn commits_carry_timestamps_and_persisted_messages() {
        let doc = SheetDocument::new();
        doc.insert(0, "hello").unwrap();
        doc.commit(Some("first words"));
        let cursor = doc.body.get_cursor(0, Side::Middle).unwrap();
        let change = doc.doc.get_change(cursor.id.unwrap()).unwrap();
        assert!(change.timestamp > 0);
        assert_eq!(change.message(), "first words");
    }

    #[test]
    fn a_snapshot_round_trips_runs_marks_and_timestamps() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        doc.insert(0, "ink \u{1F600} more").unwrap();
        doc.insert_chip(4, id).unwrap();
        doc.commit(Some("seed"));
        let expected = doc.runs();
        let cursor = doc.body.get_cursor(0, Side::Middle).unwrap();
        let stamped = doc.doc.get_change(cursor.id.unwrap()).unwrap();

        let restored = SheetDocument::new();
        restored.import_snapshot(&doc.export_snapshot()).unwrap();
        assert_eq!(restored.runs(), expected);
        assert_eq!(restored.live_chips(), vec![id]);
        let cursor = restored.body.get_cursor(0, Side::Middle).unwrap();
        let change = restored.doc.get_change(cursor.id.unwrap()).unwrap();
        assert!(change.timestamp > 0);
        assert_eq!(change.timestamp, stamped.timestamp);
        assert_eq!(change.message(), "seed");
    }

    #[test]
    fn garbage_refuses_to_import() {
        let doc = SheetDocument::new();
        assert_eq!(
            doc.import_snapshot(b"not a loro blob"),
            Err(RestoreError::Malformed)
        );
        assert_eq!(doc.utf16_len(), 0);
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    // Spike: a shallow `StateOnly` export sheds deleted text but keeps the
    // authoring peer id, so compaction rebuilds from runs instead.
    #[test]
    fn spike_state_only_export_sheds_deleted_text_but_keeps_the_peer_id() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        let old_peer = doc.doc.peer_id();

        doc.insert(0, "alpha DOOMEDONE keep").unwrap();
        doc.delete(6, 10).unwrap();
        doc.commit(Some("first"));
        doc.insert(10, " DOOMEDTWO tail").unwrap();
        doc.insert_chip(0, id).unwrap();
        doc.delete(11, 11).unwrap();
        doc.commit(Some("second"));
        let expected = doc.runs();

        let blob = doc
            .doc
            .export(ExportMode::StateOnly(None))
            .expect("a state-only export has no refusable input");

        // Control: live text is findable, or the absence checks prove nothing.
        assert!(contains(&blob, b"alpha keep"));

        assert!(!contains(&blob, b"DOOMEDONE"));
        assert!(!contains(&blob, b"DOOMEDTWO"));

        let le = old_peer.to_le_bytes();
        assert!(contains(&blob, &le));

        let restored = SheetDocument::new();
        restored.doc.set_peer_id(rand_peer(old_peer)).unwrap();
        restored.import_snapshot(&blob).unwrap();
        assert_eq!(restored.runs(), expected);
        assert_eq!(restored.live_chips(), vec![id]);

        // Pre-frontier characters lose their change metadata.
        let cursor = restored.body.get_cursor(2, Side::Middle).unwrap();
        let change = restored.doc.get_change(cursor.id.unwrap());
        assert!(change.is_none());
    }

    #[test]
    fn compaction_rebuilds_under_a_fresh_peer_and_sheds_the_trail() {
        let mut doc = SheetDocument::new();
        let id = ItemId::random();
        let old_peer = doc.peer_id();

        doc.insert(0, "alpha DOOMEDONE\u{1F680} keep\nsecond")
            .unwrap();
        doc.delete(6, 11).unwrap();
        doc.commit(Some("https://origin.example.test/reset?tk=Vq9Zx"));
        doc.insert_chip(0, id).unwrap();
        doc.insert(11, " DOOMEDTWO\u{1F511}").unwrap();
        doc.delete(11, 12).unwrap();
        doc.commit(None);
        let expected = doc.runs();
        let expected_len = doc.utf16_len();

        doc.compact();

        assert_eq!(doc.runs(), expected);
        assert_eq!(doc.live_chips(), vec![id]);
        assert_eq!(doc.utf16_len(), expected_len);

        let blob = doc.export_snapshot();
        assert!(contains(&blob, b"alpha  keep"), "the control: live ink");
        assert!(!contains(&blob, b"DOOMEDONE"));
        assert!(!contains(&blob, b"DOOMEDTWO"));
        assert!(!contains(&blob, b"origin.example.test"));
        assert!(!contains(&blob, &old_peer.to_le_bytes()));
        assert_ne!(doc.peer_id(), old_peer);

        assert_eq!(doc.latest_timestamp(), None);
        assert_eq!(doc.span_timestamps(0, doc.utf16_len()), None);
        doc.insert(0, "x").unwrap();
        doc.commit_at(5_000);
        assert_eq!(doc.latest_timestamp(), Some(5_000));
        assert_eq!(doc.span_timestamps(0, 1), Some((5_000, 5_000)));
    }

    #[test]
    fn deltas_alone_reconstruct_one_document_from_another() {
        let source = SheetDocument::new();
        let mirror = SheetDocument::new();
        let chip = ItemId::random();

        source.insert(0, "first words \u{1F600}").unwrap();
        source.commit(Some("seed"));
        let frontier = mirror.version();
        let delta = source.export_updates_since(&frontier).unwrap();
        mirror.import_update(&delta, &[chip]).unwrap();
        assert_eq!(mirror.runs(), source.runs());

        source.insert_chip(5, chip).unwrap();
        source.delete(0, 5).unwrap();
        source.commit(None);
        let frontier = mirror.version();
        let delta = source.export_updates_since(&frontier).unwrap();
        mirror.import_update(&delta, &[chip]).unwrap();
        assert_eq!(mirror.runs(), source.runs());
        assert_eq!(mirror.live_chips(), vec![chip]);
        assert_eq!(mirror.utf16_len(), source.utf16_len());
    }

    #[test]
    fn an_undecodable_frontier_and_a_garbage_delta_both_refuse() {
        let doc = SheetDocument::new();
        doc.insert(0, "standing").unwrap();
        doc.commit(None);
        assert!(doc.export_updates_since(b"not a frontier").is_none());
        assert_eq!(
            doc.import_update(b"not an update batch", &[]),
            Err(UpdateRefusal::Malformed)
        );
        assert_eq!(doc.runs(), vec![DocRun::Ink("standing".to_string())]);
    }

    #[test]
    fn a_delta_breaking_the_chip_roster_is_refused_whole() {
        let source = SheetDocument::new();
        let mirror = SheetDocument::new();
        let foreign = ItemId::random();

        mirror.insert(0, "local").unwrap();
        mirror.commit(None);
        let before_runs = mirror.runs();
        let before_version = mirror.version();

        source.insert(0, "ink").unwrap();
        source.insert_chip(0, foreign).unwrap();
        source.commit(None);
        let delta = source.export_updates_since(&mirror.version()).unwrap();

        assert_eq!(
            mirror.import_update(&delta, &[]),
            Err(UpdateRefusal::ChipRoster)
        );
        assert_eq!(mirror.runs(), before_runs);
        assert_eq!(mirror.version(), before_version);
    }

    #[test]
    fn a_delta_missing_its_dependencies_is_refused_not_queued() {
        let source = SheetDocument::new();
        let mirror = SheetDocument::new();

        source.insert(0, "one").unwrap();
        source.commit(None);
        let after_one = source.version();
        source.insert(3, " two").unwrap();
        source.commit(None);

        let tail = source.export_updates_since(&after_one).unwrap();
        assert_eq!(
            mirror.import_update(&tail, &[]),
            Err(UpdateRefusal::MissingHistory)
        );
        assert_eq!(mirror.runs(), Vec::<DocRun>::new());

        let base = source.export_updates_since(&mirror.version()).unwrap();
        mirror.import_update(&base, &[]).unwrap();
        assert_eq!(mirror.runs(), source.runs());
    }

    #[test]
    fn no_peer_id_crosses_a_ceremony_boundary_in_a_delta() {
        let mut doc = SheetDocument::new();
        let old_peer = doc.peer_id();
        doc.insert(0, "alpha DOOMED keep").unwrap();
        doc.delete(6, 7).unwrap();
        doc.commit(Some("first"));

        doc.compact();

        let empty = SheetDocument::new();
        let full = doc.export_updates_since(&empty.version()).unwrap();
        assert!(contains(&full, b"alpha keep"), "the control: live ink");
        assert!(!contains(&full, b"DOOMED"));
        assert!(!contains(&full, &old_peer.to_le_bytes()));
        assert_ne!(doc.peer_id(), old_peer);
    }

    #[test]
    fn a_step_back_and_a_step_forward_return_the_body_to_where_it_was() {
        let mut doc = SheetDocument::new();
        doc.insert(0, "first").unwrap();
        doc.commit(None);
        // Apart, so the interval cannot fold them into one step.
        doc.set_merge_interval(0);
        doc.insert(5, " second").unwrap();
        doc.commit(None);

        assert!(doc.can_undo());
        assert!(!doc.can_redo());
        assert!(doc.undo());
        assert_eq!(doc.runs(), vec![DocRun::Ink("first".to_string())]);
        assert!(doc.can_redo());
        assert!(doc.redo());
        assert_eq!(doc.runs(), vec![DocRun::Ink("first second".to_string())]);
    }

    #[test]
    fn an_empty_stack_refuses_to_step_in_either_direction() {
        let mut doc = SheetDocument::new();
        assert!(!doc.can_undo());
        assert!(!doc.can_redo());
        assert!(!doc.undo());
        assert!(!doc.redo());
        assert_eq!(doc.restored_caret(), None);
    }

    #[test]
    fn a_step_puts_the_caret_where_the_edit_was_authored() {
        let mut doc = SheetDocument::new();
        doc.insert(0, "alpha").unwrap();
        doc.commit(None);
        doc.set_merge_interval(0);
        doc.insert(5, "\u{1F600}beta").unwrap();
        doc.commit(None);

        assert!(doc.undo());
        assert_eq!(doc.restored_caret(), Some(5));
        assert_eq!(doc.utf16_len(), 5);
    }

    #[test]
    fn undo_and_redo_selections_follow_a_remote_insert() {
        let mut local = SheetDocument::new();
        local.insert(0, "base.").unwrap();
        local.commit(None);
        let snapshot = local.export_snapshot();
        let base_version = local.version();
        local.forget_undo();

        let remote = SheetDocument::new();
        remote.import_snapshot(&snapshot).unwrap();

        let before = local
            .snapshot_selection(TextSelection {
                location_u16: 5,
                length_u16: 0,
            })
            .unwrap();
        local.insert(5, " mine").unwrap();
        local.commit_edit_with_selection(
            EditIntent::Typing,
            None,
            before,
            TextSelection {
                location_u16: 10,
                length_u16: 0,
            },
        );

        remote.insert(0, "remote ").unwrap();
        remote.commit(None);
        let update = remote.export_updates_since(&base_version).unwrap();
        local.import_update(&update, &[]).unwrap();
        assert!(local.undo());
        assert_eq!(
            local.restored_selection(),
            Some(TextSelection {
                location_u16: 12,
                length_u16: 0,
            })
        );
        assert!(local.redo());
        assert_eq!(
            local.restored_selection(),
            Some(TextSelection {
                location_u16: 17,
                length_u16: 0,
            })
        );
    }

    #[test]
    fn commits_inside_the_merge_interval_come_back_as_one_step() {
        let mut doc = SheetDocument::new();
        doc.insert(0, "one").unwrap();
        doc.commit(None);
        doc.insert(3, " two").unwrap();
        doc.commit(None);
        assert!(doc.undo());
        assert_eq!(doc.runs(), Vec::<DocRun>::new());
        assert!(!doc.can_undo());

        let mut ungrouped = SheetDocument::new();
        ungrouped.set_merge_interval(0);
        ungrouped.insert(0, "one").unwrap();
        ungrouped.commit(None);
        ungrouped.insert(3, " two").unwrap();
        ungrouped.commit(None);
        assert!(ungrouped.undo());
        assert_eq!(ungrouped.runs(), vec![DocRun::Ink("one".to_string())]);
        assert!(ungrouped.can_undo());
    }

    #[test]
    fn a_new_step_commit_leaves_a_retuned_interval_where_it_found_it() {
        let mut doc = SheetDocument::new();
        doc.set_merge_interval(0);
        doc.insert(0, "- milk").unwrap();
        doc.commit_edit(EditIntent::Automation, None);
        doc.insert(6, "\n- eggs").unwrap();
        doc.commit(None);

        assert!(doc.undo());
        assert_eq!(doc.runs(), vec![DocRun::Ink("- milk".to_string())]);
        assert!(doc.can_undo());
    }

    #[test]
    fn take_theirs_step_pins_its_generation_to_the_top_undo_item() {
        let mut doc = SheetDocument::new();
        doc.insert(0, "mine").unwrap();
        doc.commit(None);
        doc.insert(0, "theirs").unwrap();

        assert!(doc.commit_take_theirs_step(41));
        assert!(matches!(
            doc.undo.top_undo_value(),
            Some(LoroValue::I64(41))
        ));
        assert!(doc.undo());
        assert_eq!(doc.popped_take_theirs(), Some(41));

        let mut no_op = SheetDocument::new();
        no_op.insert(0, "standing").unwrap();
        no_op.commit(None);
        assert!(!no_op.commit_take_theirs_step(42));
        assert!(!matches!(
            no_op.undo.top_undo_value(),
            Some(LoroValue::I64(42))
        ));
    }

    #[test]
    fn a_restored_document_has_nothing_to_step_back_through() {
        let source = SheetDocument::new();
        source.insert(0, "written before the quit").unwrap();
        source.commit(None);

        let restored = SheetDocument::new();
        restored.import_snapshot(&source.export_snapshot()).unwrap();

        assert_eq!(
            restored.runs(),
            vec![DocRun::Ink("written before the quit".to_string())]
        );
        assert!(!restored.can_undo());
        assert!(!restored.can_redo());
    }

    #[test]
    fn the_ceremony_leaves_nothing_to_step_back_through() {
        let mut doc = SheetDocument::new();
        doc.insert(0, "kept").unwrap();
        doc.commit(None);
        assert!(doc.can_undo());

        doc.compact();

        assert!(!doc.can_undo());
        assert!(!doc.can_redo());
        assert!(!doc.undo());
        assert_eq!(doc.runs(), vec![DocRun::Ink("kept".to_string())]);
    }

    #[test]
    fn a_local_step_back_leaves_a_peers_operations_standing() {
        let source = SheetDocument::new();
        let mut mirror = SheetDocument::new();

        mirror.insert(0, "mine.").unwrap();
        mirror.commit(None);
        source.insert(0, "theirs.").unwrap();
        source.commit(None);
        let delta = source.export_updates_since(&mirror.version()).unwrap();
        mirror.import_update(&delta, &[]).unwrap();
        let merged = mirror.utf16_len();
        assert_eq!(merged, 12);

        assert!(mirror.undo());
        let left: String = mirror
            .runs()
            .into_iter()
            .map(|run| match run {
                DocRun::Ink(text) => text,
                DocRun::Chip(_) => String::new(),
            })
            .collect();
        assert_eq!(left, "theirs.");
        assert!(!mirror.can_undo(), "the peer's ops were never candidates");
    }

    #[test]
    fn empty_edits_are_no_ops_only_at_valid_offsets() {
        let doc = SheetDocument::new();
        doc.insert(0, "ab").unwrap();
        assert_eq!(doc.insert(2, ""), Ok(()));
        assert_eq!(doc.delete(2, 0), Ok(()));
        assert_eq!(doc.insert(3, ""), Err(InvalidRange));
        assert_eq!(doc.delete(3, 0), Err(InvalidRange));
        assert_eq!(doc.insert(3, "x"), Err(InvalidRange));
        assert_eq!(doc.runs(), vec![DocRun::Ink("ab".to_string())]);
    }

    #[test]
    fn a_sentinel_with_an_unreadable_mark_reads_as_ink() {
        let doc = SheetDocument::new();
        doc.body.insert_utf16(0, CHIP_SENTINEL).unwrap();
        doc.body.mark_utf16(0..1, CHIP_MARK, "not-an-id").unwrap();
        assert_eq!(doc.runs(), vec![DocRun::Ink(CHIP_SENTINEL.to_string())]);
        assert!(doc.live_chips().is_empty());
    }

    #[test]
    fn a_delta_standing_one_chip_twice_is_refused_whole() {
        let source = SheetDocument::new();
        let mirror = SheetDocument::new();
        let id = ItemId::random();
        source.insert_chip(0, id).unwrap();
        source.insert(1, "x").unwrap();
        source.insert_chip(2, id).unwrap();
        source.commit(None);
        let delta = source.export_updates_since(&mirror.version()).unwrap();
        assert_eq!(
            mirror.import_update(&delta, &[id]),
            Err(UpdateRefusal::ChipRoster)
        );
        assert_eq!(mirror.runs(), Vec::<DocRun>::new());
    }

    #[test]
    fn a_frontier_naming_unknown_peers_yields_everything() {
        let source = SheetDocument::new();
        source.insert(0, "whole page").unwrap();
        source.commit(None);
        let stranger = SheetDocument::new();
        stranger.insert(0, "elsewhere").unwrap();
        stranger.commit(None);
        let delta = source.export_updates_since(&stranger.version()).unwrap();
        let mirror = SheetDocument::new();
        mirror.import_update(&delta, &[]).unwrap();
        assert_eq!(mirror.runs(), source.runs());
    }

    #[test]
    fn a_mark_only_retain_does_not_move_the_change_start() {
        let doc = SheetDocument::new();
        doc.insert(0, "hello world").unwrap();
        doc.commit(None);
        let mark_only = doc.count_mark_only_chip_writes();
        let starts = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&starts);
        let _subscription = doc.doc.subscribe_root(Arc::new(move |event| {
            sink.lock().unwrap().push(change_start(&event));
        }));

        doc.body.mark_utf16(1..3, CHIP_MARK, "mark only").unwrap();
        doc.commit(None);
        doc.body.mark_utf16(6..8, CHIP_MARK, "mark beside").unwrap();
        doc.insert(9, "!").unwrap();
        doc.commit(None);

        assert_eq!(*starts.lock().unwrap(), vec![None, Some(9)]);
        assert_eq!(mark_only.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[test]
    fn the_undo_push_hook_reads_the_body_without_deadlocking() {
        let (done, finished) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut doc = SheetDocument::new();
            doc.insert(0, "base").unwrap();
            doc.commit(None);
            doc.forget_undo();
            doc.insert(4, " more").unwrap();
            // The push hook takes a cursor from inside Loro's event callback.
            doc.commit_edit(EditIntent::Typing, None);
            let undone = doc.undo();
            let _ = done.send((undone, doc.restored_caret()));
        });
        match finished.recv_timeout(std::time::Duration::from_secs(10)) {
            Ok(outcome) => assert_eq!(outcome, (true, Some(4))),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                panic!("the undo push hook deadlocked inside Loro's event callback")
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                panic!("the undo push thread panicked")
            }
        }
    }

    fn rand_peer(not: u64) -> u64 {
        loop {
            let mut bytes = [0u8; 8];
            getrandom::getrandom(&mut bytes).expect("the OS CSPRNG must be available");
            let peer = u64::from_le_bytes(bytes);
            if peer != not {
                return peer;
            }
        }
    }
}
