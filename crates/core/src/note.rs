//! A sealed object's note (ADR-0043 points 2 and 3): chipless ink
//! beside the chip, with an undo stack of its own and no clock; it goes when
//! its chip goes. Its history is a Loro text of its own, which peers merge
//! and the key frame rebuilds (ADR-0058 point 6).

use std::collections::VecDeque;

use zeroize::Zeroizing;

use crate::clock::Clock;
use crate::document::{
    EditIntent, EditSelection, Lineage, SheetDocument, TextSelection, UpdateRefusal,
};
use crate::ink::{self, StepOutcome};
use crate::metadata::{record_on, record_on_mut};
use crate::sheet::{ItemId, SealedChip, Sheet, SheetId};
use crate::store::{EditOp, RemoteRefusal, SheetStore, refusal_from};

/// The most bytes of note batches kept for objects no page here has a record
/// for yet (ADR-0058 point 6).
pub(crate) const PENDING_NOTE_BYTES: usize = 256 * 1024;

/// The most note batches kept for those objects, however small each is.
pub(crate) const PENDING_NOTE_BATCHES: usize = 256;

/// Note batches for objects with no record here yet, by the identity of the page
/// they were sent for and the object, oldest first, with their byte total.
#[derive(Default)]
pub(crate) struct PendingNotes {
    batches: VecDeque<(ItemId, ItemId, Zeroizing<Vec<u8>>)>,
    bytes: usize,
}

impl PendingNotes {
    /// How many batches wait (test-only).
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.batches.len()
    }

    /// Whether none waits (test-only).
    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.batches.is_empty()
    }

    /// The waiting batches, oldest first (test-only).
    #[cfg(test)]
    pub(crate) fn iter(&self) -> impl Iterator<Item = &(ItemId, ItemId, Zeroizing<Vec<u8>>)> {
        self.batches.iter()
    }

    /// Keep only the batches `keep` answers true for.
    pub(crate) fn retain(
        &mut self,
        mut keep: impl FnMut(&(ItemId, ItemId, Zeroizing<Vec<u8>>)) -> bool,
    ) {
        let bytes = &mut self.bytes;
        self.batches.retain(|batch| {
            let kept = keep(batch);
            if !kept {
                *bytes = bytes.saturating_sub(batch.2.len());
            }
            kept
        });
    }

    /// Keep a batch, the oldest going while either bound would pass; one past the
    /// byte bound alone is not kept.
    fn hold(&mut self, page: ItemId, object: ItemId, bytes: &[u8]) {
        if bytes.len() > PENDING_NOTE_BYTES {
            return;
        }
        while self.batches.len() >= PENDING_NOTE_BATCHES
            || self.bytes + bytes.len() > PENDING_NOTE_BYTES
        {
            let Some((_, _, gone)) = self.batches.pop_front() else {
                break;
            };
            self.bytes = self.bytes.saturating_sub(gone.len());
        }
        self.bytes += bytes.len();
        self.batches
            .push_back((page, object, Zeroizing::new(bytes.to_vec())));
    }

    /// Take every batch held for `object`, whichever page it was sent for, oldest first.
    fn take(&mut self, object: ItemId) -> Vec<(ItemId, Zeroizing<Vec<u8>>)> {
        let (taken, kept): (VecDeque<_>, VecDeque<_>) = std::mem::take(&mut self.batches)
            .into_iter()
            .partition(|(_, held, _)| *held == object);
        self.batches = kept;
        taken
            .into_iter()
            .map(|(page, _, batch)| {
                self.bytes = self.bytes.saturating_sub(batch.len());
                (page, batch)
            })
            .collect()
    }
}

/// The note's text, and once edited its document, in which no chip ever stands: sealed
/// objects do not nest.
pub(crate) struct Note {
    body: Body,
}

/// A restored or pasted note rests in a wiping owner until an edit applies, since the
/// document's Loro arena does not wipe (Law 0004, C01, C31). Its history is shared once
/// any of it has left this device or come from another.
enum Body {
    /// The text, the selection the last run's end kept, and the operation log a restore
    /// or a key frame left, each given to the document later. A note resting with a log
    /// has a shared history.
    Resting {
        text: Zeroizing<String>,
        kept: Option<TextSelection>,
        history: Option<Zeroizing<Vec<u8>>>,
    },
    Document {
        document: SheetDocument,
        shared: bool,
    },
}

impl Note {
    /// A note of `text` with no history and an empty undo stack: a paste's, whose new
    /// identity starts its own (ADR-0043 point 1). It rests at its exact size until edited.
    pub(crate) fn holding(text: &str) -> Self {
        Self::restored(text, &[])
    }

    /// A note of `text` and the operation log written beside it, empty for none
    /// (ADR-0058 point 9). It rests until its first edit, with an empty undo stack.
    pub(crate) fn restored(text: &str, history: &[u8]) -> Self {
        Self {
            body: Body::Resting {
                text: Zeroizing::new(text.to_owned()),
                kept: None,
                history: (!history.is_empty()).then(|| Zeroizing::new(history.to_vec())),
            },
        }
    }

    /// A note replaying a key frame's rebuild, judged as a peer's batch is.
    pub(crate) fn rebuilt(rebuild: &[u8]) -> Result<Self, UpdateRefusal> {
        let mut note = Self::holding("");
        note.import(rebuild)?;
        Ok(note)
    }

    /// The note's text at its final size.
    pub(crate) fn text(&self) -> Zeroizing<String> {
        match &self.body {
            Body::Resting { text, .. } => Zeroizing::new(text.as_str().to_owned()),
            Body::Document { document, .. } => ink::text_of(document),
        }
    }

    /// Whether anything but whitespace is written: the block's doorway.
    pub(crate) fn has_content(&self) -> bool {
        match &self.body {
            Body::Resting { text, .. } => !text.trim().is_empty(),
            Body::Document { document, .. } => !ink::text_of(document).trim().is_empty(),
        }
    }

    /// The operation log to write beside the text, at its exact size: the one the note
    /// rests with, or its document's; `None` when it has no operation or its history
    /// is not shared, so the text alone restores it.
    pub(crate) fn history(&self) -> Option<Zeroizing<Vec<u8>>> {
        match &self.body {
            Body::Resting { history, .. } => {
                history.as_ref().map(|log| Zeroizing::new(log.to_vec()))
            }
            Body::Document { document, shared } => {
                (*shared && !document.is_pristine()).then(|| document.export_snapshot())
            }
        }
    }

    /// The resting text; `None` once an edit has made the document.
    #[cfg(test)]
    pub(crate) fn resting(&self) -> Option<&Zeroizing<String>> {
        match &self.body {
            Body::Resting { text, .. } => Some(text),
            Body::Document { .. } => None,
        }
    }

    /// Whether any of the note's history has left this device or come from another.
    fn is_shared(&self) -> bool {
        match &self.body {
            Body::Resting { history, .. } => history.is_some(),
            Body::Document { shared, .. } => *shared,
        }
    }

    /// The document a resting note becomes, given the selection a run's end kept: replayed
    /// from its log, or typed from its text when it has none or the log disagrees.
    fn woken(&self) -> Option<SheetDocument> {
        let Body::Resting {
            text,
            kept,
            history,
        } = &self.body
        else {
            return None;
        };
        let document = history
            .as_deref()
            .and_then(|log| replayed(text, log))
            .unwrap_or_else(|| ink::document_holding(text));
        if kept.is_some() {
            document.finish_editing_group(*kept);
        }
        Some(document)
    }

    /// The document an edit, an export or a merge needs, made the first time.
    fn document(&mut self) -> &mut SheetDocument {
        if let Some(document) = self.woken() {
            let shared = self.is_shared();
            self.body = Body::Document { document, shared };
        }
        match &mut self.body {
            Body::Document { document, .. } => document,
            Body::Resting { .. } => unreachable!("the resting text was made a document above"),
        }
    }

    /// Mark a document's history shared; a resting note is shared by its log alone.
    fn mark_shared(&mut self) {
        if let Body::Document { shared, .. } = &mut self.body {
            *shared = true;
        }
    }

    /// [`ink::apply_batch`]; `None` refused the batch whole, as is one that
    /// would write the chip sentinel as ink. A resting note is judged on its text first.
    pub(crate) fn apply(
        &mut self,
        ops: &[EditOp],
        intent: EditIntent,
        selection: Option<EditSelection>,
    ) -> Option<bool> {
        if ops.is_empty() {
            return Some(true);
        }
        if ops.iter().any(EditOp::inks_sentinel) {
            return None;
        }
        if let Body::Resting { text, kept, .. } = &mut self.body {
            if !ink::admits(text, ops) {
                return None;
            }
            // Nothing moves, so the note rests on, keeping the selection the document would.
            if ops.iter().all(moves_nothing) {
                let ends = selection.filter(|ends| within(text, ends.before));
                if let Some(after) = ends.map(|ends| ends.after).filter(|at| within(text, *at)) {
                    *kept = Some(after);
                }
                return Some(true);
            }
        }
        ink::apply_batch(self.document(), ops, intent, selection)
    }

    /// End the typing run. A resting note has none, and keeps a selection only where the
    /// document would.
    pub(crate) fn finish_editing_group(&mut self, selection: Option<TextSelection>) {
        match &mut self.body {
            Body::Resting { text, kept, .. } => {
                if let Some(selection) = selection.filter(|value| within(text, *value)) {
                    *kept = Some(selection);
                }
            }
            Body::Document { document, .. } => document.finish_editing_group(selection),
        }
    }

    /// The document, once an edit has made it; a resting note has no step to take.
    fn edited(&self) -> Option<&SheetDocument> {
        match &self.body {
            Body::Resting { .. } => None,
            Body::Document { document, .. } => Some(document),
        }
    }

    pub(crate) fn can_undo(&self) -> bool {
        self.edited().is_some_and(SheetDocument::can_undo)
    }

    pub(crate) fn can_redo(&self) -> bool {
        self.edited().is_some_and(SheetDocument::can_redo)
    }

    pub(crate) fn undo_action_name(&self) -> Option<&'static str> {
        self.edited()?.undo_action_name()
    }

    pub(crate) fn redo_action_name(&self) -> Option<&'static str> {
        self.edited()?.redo_action_name()
    }

    /// Undo (`back`) or redo one of the note's own steps.
    pub(crate) fn step(&mut self, back: bool) -> StepOutcome {
        match &mut self.body {
            Body::Resting { .. } => StepOutcome::NONE,
            Body::Document { document, .. } => ink::step(document, back),
        }
    }

    /// The version of the note's history, as opaque bytes; reading it makes the document.
    pub(crate) fn version(&mut self) -> Vec<u8> {
        self.document().version()
    }

    /// The note's operations beyond `since`, which leave the device, so its history is
    /// shared from here on; `None` if `since` does not decode.
    pub(crate) fn export_since(&mut self, since: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let exported = self.document().export_updates_since(since)?;
        self.mark_shared();
        Some(exported)
    }

    /// Merge a peer's batch outside the undo stack (ADR-0058 point 6), only over the note's
    /// own history once it has one; a refusal leaves the note as it was, resting included.
    /// Returns whether the note's history changed.
    pub(crate) fn import(&mut self, bytes: &[u8]) -> Result<bool, UpdateRefusal> {
        if let Body::Document { document, shared } = &mut self.body {
            let changed = document.import_ink_update(bytes, Lineage::Own)?;
            *shared = true;
            return Ok(changed);
        }
        let Body::Resting {
            text,
            kept,
            history,
        } = &self.body
        else {
            unreachable!("a note that is not a document rests");
        };
        let (document, changed) = if history.is_some() {
            let document = self.woken().expect("a resting note wakes");
            let changed = document.import_ink_update(bytes, Lineage::Own)?;
            (document, changed)
        } else {
            // With no history of its own, a blank note takes any batch's history, and
            // another only one that spells its text.
            let document = SheetDocument::new();
            let changed = document.import_ink_update(bytes, Lineage::Own)?;
            if !text.is_empty() && ink::text_of(&document).as_str() != text.as_str() {
                return Err(UpdateRefusal::UnrelatedHistory);
            }
            if kept.is_some() {
                document.finish_editing_group(*kept);
            }
            (document, changed)
        };
        self.body = Body::Document {
            document,
            shared: true,
        };
        Ok(changed)
    }

    /// Shed a history no other device has seen with the page's (ADR-0058 point 6): the
    /// note rests as its text alone, with no step to take back. A shared history stays
    /// whole, since a copy of it elsewhere may still meet it.
    pub(crate) fn compact(&mut self) {
        let Body::Document {
            document,
            shared: false,
        } = &self.body
        else {
            return;
        };
        let text = ink::text_of(document);
        self.body = Body::Resting {
            text,
            kept: None,
            history: None,
        };
    }

    /// Re-type the text under a fresh peer for a key frame (ADR-0058 point 6): the note
    /// rests with the rebuild's log, shared by the frame, and no step to take back.
    /// Returns that log; `None` for a note with no text, whose rebuild has no operation.
    pub(crate) fn rebuild(&mut self) -> Option<Zeroizing<Vec<u8>>> {
        let text = self.text();
        let rebuild = ink::document_holding(&text);
        let history = (!rebuild.is_pristine()).then(|| rebuild.export_snapshot());
        self.body = Body::Resting {
            text,
            kept: None,
            history,
        };
        self.history()
    }

    /// Fold `arriving`, the note of a value moving into a standing record's place, into
    /// `standing`'s (ADR-0058 point 6). A blank standing note gives way to it.
    pub(crate) fn fold(standing: &mut Option<Self>, mut arriving: Self) {
        match standing {
            Some(note) if !note.is_blank() => {
                if !arriving.is_blank() {
                    note.merge_shared(&mut arriving);
                }
            }
            _ => *standing = Some(arriving),
        }
    }

    /// Put a key frame's rebuild in `standing`'s place, or merge it in over a shared
    /// base: the channel's note ops build on the frame from here on.
    pub(crate) fn adopt(standing: &mut Option<Self>, mut rebuilt: Self) {
        let merged = standing
            .as_mut()
            .is_some_and(|note| note.merge_shared(&mut rebuilt));
        if !merged {
            *standing = Some(rebuilt);
        }
    }

    /// Merge `other`'s history into this note's over a base the two share; false, the
    /// text as it was, when they share none.
    fn merge_shared(&mut self, other: &mut Self) -> bool {
        // Typed from text alone, a note mints a base no other note has.
        if !self.has_history() || !other.has_history() {
            return false;
        }
        let theirs = other.document();
        let ours = self.document();
        let merged = ours.shares_base(theirs)
            && ours
                .import_ink_update(&theirs.export_snapshot(), Lineage::Any)
                .is_ok();
        if merged {
            self.mark_shared();
        }
        merged
    }

    /// Whether the note has no operation at all.
    fn is_blank(&self) -> bool {
        match &self.body {
            Body::Resting { text, history, .. } => text.is_empty() && history.is_none(),
            Body::Document { document, .. } => document.is_pristine(),
        }
    }

    /// Whether the note has a log another note may share.
    fn has_history(&self) -> bool {
        match &self.body {
            Body::Resting { history, .. } => history.is_some(),
            Body::Document { .. } => true,
        }
    }

    /// Every peer the note's history has operations from (test-only).
    #[cfg(test)]
    pub(crate) fn peers(&mut self) -> Vec<u64> {
        self.document().history_peers()
    }
}

/// A document replaying `log`, with an empty undo stack, if its text is `text`.
fn replayed(text: &str, log: &[u8]) -> Option<SheetDocument> {
    let document = SheetDocument::new();
    document.import_snapshot(log).ok()?;
    document.forget_undo();
    (ink::text_of(&document).as_str() == text).then_some(document)
}

/// Merge `bytes` into `record`'s note, made empty first if it has none; a refusal
/// leaves no note the record did not have.
fn merge_into(record: &mut SealedChip, bytes: &[u8]) -> Result<bool, RemoteRefusal> {
    let made = record.note.is_none();
    let note = record.note.get_or_insert_with(|| Note::holding(""));
    match note.import(bytes) {
        Ok(changed) => Ok(changed),
        Err(refusal) => {
            if made {
                record.note = None;
            }
            Err(refusal_from(refusal))
        }
    }
}

impl<C: Clock> SheetStore<C> {
    /// Each record on `page`, attached and detached, that has a note; none for a page
    /// past its deadline (Law 0001, expiry row).
    #[must_use]
    pub fn notes_on(&self, page: SheetId) -> Vec<ItemId> {
        self.readable_sheet(page).map_or_else(Vec::new, |sheet| {
            sheet
                .chips
                .iter()
                .chain(&sheet.detached)
                .filter(|record| record.note.is_some())
                .map(|record| record.uuid)
                .collect()
        })
    }

    /// The version of `object`'s note on `page`, opaque bytes for
    /// [`SheetStore::export_note_updates`]; reading it makes a resting note its document.
    /// `None` for an unknown page or object, a record with no note or a page past its
    /// deadline (Law 0001, expiry row).
    pub fn note_version(&mut self, page: SheetId, object: ItemId) -> Option<Vec<u8>> {
        Some(self.readable_note(page, object)?.version())
    }

    /// The operations `object`'s note on `page` has beyond `since`, plaintext for the
    /// seam to seal (ADR-0058 point 6). `None` as [`SheetStore::note_version`] says, or
    /// for an undecodable frontier.
    pub fn export_note_updates(
        &mut self,
        page: SheetId,
        object: ItemId,
        since: &[u8],
    ) -> Option<Zeroizing<Vec<u8>>> {
        self.readable_note(page, object)?.export_since(since)
    }

    /// Merge a peer's batch into every readable record of `object`.
    /// The named page must be readable; batches without a record wait for one.
    ///
    /// # Errors
    /// Refuses empty bytes, unknown pages, or a batch every record rejects.
    pub fn apply_remote_note_update(
        &mut self,
        page: ItemId,
        object: ItemId,
        bytes: &[u8],
    ) -> Result<bool, RemoteRefusal> {
        // Loro refuses empty bytes too; held, they would cost the bound nothing.
        if bytes.is_empty() {
            return Err(RemoteRefusal::Malformed);
        }
        let now = self.clock.now();
        let sheet = self
            .sheet_mut_by_uuid(page)
            .ok_or(RemoteRefusal::UnknownSheet)?;
        if sheet.is_due(now) {
            return Ok(false);
        }
        let named = sheet.id;
        if self.terminal_cause(object).is_some() {
            return Ok(false);
        }
        let mut merged = Vec::new();
        for sheet in self.readable_sheets_mut() {
            let id = sheet.id;
            if let Some(record) = record_on_mut(sheet, object) {
                merged.push((id, merge_into(record, bytes)));
            }
        }
        let Some(&(_, first)) = merged.first() else {
            self.note_pending.hold(page, object, bytes);
            return Ok(false);
        };
        let changed: Vec<SheetId> = merged
            .iter()
            .filter(|(id, outcome)| *id != named && *outcome == Ok(true))
            .map(|(id, _)| *id)
            .collect();
        let outcome = if merged.iter().any(|(_, outcome)| outcome.is_ok()) {
            Ok(merged.iter().any(|(_, outcome)| *outcome == Ok(true)))
        } else {
            first
        };
        // Another page's note changed, so the shell reads that page again.
        self.restated.extend(changed);
        outcome
    }

    /// Give each record on page `id` the note a key frame rebuilt for it; a rebuild for
    /// an object with no record there waits as a peer's batch would.
    pub(crate) fn adopt_frame_notes(&mut self, id: SheetId, notes: Vec<(ItemId, &[u8], Note)>) {
        let Some(page) = self.sheet(id).map(Sheet::uuid) else {
            return;
        };
        for (object, rebuild, note) in notes {
            match self
                .sheet_mut(id)
                .and_then(|sheet| record_on_mut(sheet, object))
            {
                Some(record) => Note::adopt(&mut record.note, note),
                None => self.note_pending.hold(page, object, rebuild),
            }
        }
    }

    /// Apply waiting batches to every readable record once `id` has the object.
    /// Changed pages other than each batch's sender page are restated.
    pub(crate) fn drain_pending_notes(&mut self, id: SheetId, object: ItemId) {
        if self
            .readable_sheet(id)
            .is_none_or(|sheet| record_on(sheet, object).is_none())
        {
            return;
        }
        let waiting = self.note_pending.take(object);
        let mut restated = Vec::new();
        for (sent_for, batch) in waiting {
            for sheet in self.readable_sheets_mut() {
                if let Some(record) = record_on_mut(sheet, object)
                    && merge_into(record, &batch) == Ok(true)
                    && sheet.uuid != sent_for
                {
                    restated.push(sheet.id);
                }
            }
        }
        self.restated.extend(restated);
    }

    /// Drop batches waiting for an object that ended here.
    pub(crate) fn forget_object_notes(&mut self, object: ItemId) {
        self.note_pending.retain(|(_, at, _)| *at != object);
    }

    /// Drop every batch held for the page whose identity is `page`, as it ends.
    pub(crate) fn forget_page_notes(&mut self, page: ItemId) {
        self.note_pending.retain(|(at, _, _)| *at != page);
    }

    /// The note of `object`'s record on `page`, refused past the page's deadline.
    fn readable_note(&mut self, page: SheetId, object: ItemId) -> Option<&mut Note> {
        if self.is_due(page) {
            return None;
        }
        record_on_mut(self.sheet_mut(page)?, object)?.note.as_mut()
    }
}

/// Whether `op` changes no text: an empty insert, or a deletion of nothing.
fn moves_nothing(op: &EditOp) -> bool {
    match op {
        EditOp::Insert { text, .. } => text.is_empty(),
        EditOp::Delete { len_u16, .. } => *len_u16 == 0,
        EditOp::InsertChip { .. } => false,
    }
}

/// Whether `selection` ends within `text` in UTF-16, all
/// [`SheetDocument::snapshot_selection`] asks of it.
fn within(text: &str, selection: TextSelection) -> bool {
    let end = u64::from(selection.location_u16) + u64::from(selection.length_u16);
    end <= text.encode_utf16().count() as u64
}

#[cfg(test)]
mod tests {
    use zeroize::ZeroizeOnDrop;

    use super::*;

    const RESTED: &str = "kept \u{1F600} beside it";

    fn wiping_owner<T: ZeroizeOnDrop>(_: &T) {}

    fn typed(pos_u16: u32, text: &str) -> Vec<EditOp> {
        vec![EditOp::Insert {
            pos_u16,
            text: text.into(),
        }]
    }

    /// A restored note is one wiping copy at its exact size (Law 0004, C31): a plain `String`
    /// would not compile here, and a read, a step, a run's end, an empty batch, one that
    /// moves nothing or a refused one makes no document.
    #[test]
    fn a_restored_note_rests_as_one_wiping_copy_until_its_first_edit() {
        let mut note = Note::holding(RESTED);
        let text = note.resting().expect("a restored note rests");
        wiping_owner(text);
        assert_eq!(text.capacity(), text.len(), "the copy grew past its size");
        assert_eq!(note.text().as_str(), RESTED);
        assert!(note.has_content());
        assert!(!note.can_undo() && !note.can_redo());
        assert_eq!(note.undo_action_name(), None);
        assert_eq!(note.redo_action_name(), None);
        assert_eq!(note.step(true), StepOutcome::NONE);
        assert_eq!(note.step(false), StepOutcome::NONE);
        note.finish_editing_group(None);
        note.finish_editing_group(Some(TextSelection {
            location_u16: 4,
            length_u16: 0,
        }));
        assert_eq!(note.apply(&[], EditIntent::Typing, None), Some(true));
        let nothing = [
            EditOp::Delete {
                pos_u16: 0,
                len_u16: 0,
            },
            EditOp::Insert {
                pos_u16: 0,
                text: String::new(),
            },
        ];
        for batch in [&nothing[..1], &nothing[1..], &nothing[..]] {
            assert_eq!(note.apply(batch, EditIntent::Typing, None), Some(true));
        }
        let nothing_past_the_end = [EditOp::Delete {
            pos_u16: 99,
            len_u16: 0,
        }];
        assert_eq!(
            note.apply(&nothing_past_the_end, EditIntent::Deletion, None),
            None
        );
        let sentinel = typed(0, "\u{FFFC}");
        assert_eq!(note.apply(&sentinel, EditIntent::Typing, None), None);
        let past_the_end = typed(99, "x");
        assert_eq!(note.apply(&past_the_end, EditIntent::Typing, None), None);
        let inside_the_pair = typed(6, "x");
        assert_eq!(note.apply(&inside_the_pair, EditIntent::Typing, None), None);
        assert!(note.resting().is_some(), "the note was made a document");

        let quoted = typed(0, "> ");
        assert_eq!(note.apply(&quoted, EditIntent::Typing, None), Some(true));
        assert!(
            note.resting().is_none(),
            "the edit never reached a document"
        );
        assert_eq!(note.text().as_str(), "> kept \u{1F600} beside it");
        assert!(note.step(true).applied);
        assert_eq!(
            note.text().as_str(),
            RESTED,
            "the undo went past the restored text"
        );
        assert!(!note.can_undo());
    }

    /// The note's every answer beside the document's.
    fn same_answers(note: &Note, document: &SheetDocument, context: &str) {
        let text = ink::text_of(document);
        assert_eq!(note.text().as_str(), text.as_str(), "{context}");
        assert_eq!(note.can_undo(), document.can_undo(), "{context}");
        assert_eq!(note.can_redo(), document.can_redo(), "{context}");
        let undo = document.undo_action_name();
        assert_eq!(note.undo_action_name(), undo, "{context}");
        let redo = document.redo_action_name();
        assert_eq!(note.redo_action_name(), redo, "{context}");
    }

    /// The document a note becomes answers as one made at once would, the selections given
    /// at runs' ends included, so resting changes no step (ADR-0043 point 4).
    #[test]
    fn a_resting_note_edits_and_steps_as_the_document_it_becomes() {
        let at = |location_u16| TextSelection {
            location_u16,
            length_u16: 0,
        };
        let moved = |before, after| {
            Some(EditSelection {
                before: at(before),
                after: at(after),
            })
        };
        let delete = |pos_u16, len_u16| vec![EditOp::Delete { pos_u16, len_u16 }];
        let runs: [&[Option<TextSelection>]; 6] = [
            &[],
            &[None],
            &[Some(at(99))],
            &[Some(at(4))],
            &[Some(at(2)), Some(at(4)), None],
            &[Some(at(4)), Some(at(6)), Some(at(99))],
        ];
        let typing = EditIntent::Typing;
        let deletion = EditIntent::Deletion;
        // Each text, then the batches one group sends it, with their intents and selections.
        let edits = [
            (RESTED, vec![(typed(4, "!!"), typing, None)]),
            (RESTED, vec![(typed(4, "!!"), typing, moved(4, 6))]),
            ("", vec![(typed(0, "first"), typing, moved(0, 5))]),
            (RESTED, vec![(delete(4, 3), deletion, moved(7, 4))]),
            (
                RESTED,
                vec![
                    (delete(6, 2), deletion, None),
                    (delete(4, 3), deletion, None),
                ],
            ),
            (
                RESTED,
                vec![
                    (typed(4, "a"), typing, moved(4, 5)),
                    (typed(5, "b"), typing, moved(5, 6)),
                ],
            ),
            (
                RESTED,
                vec![
                    (delete(2, 0), typing, moved(2, 2)),
                    (typed(4, "!!"), typing, None),
                ],
            ),
            (
                RESTED,
                vec![
                    (delete(2, 0), typing, moved(99, 2)),
                    (typed(4, "!!"), typing, None),
                ],
            ),
            (
                RESTED,
                vec![
                    (delete(2, 0), deletion, moved(2, 2)),
                    (typed(4, "!!"), typing, None),
                ],
            ),
        ];
        for ends in runs {
            for (text, batches) in &edits {
                let mut note = Note::holding(text);
                let mut document = ink::document_holding(text);
                for end in ends {
                    note.finish_editing_group(*end);
                    document.finish_editing_group(*end);
                }
                assert!(note.resting().is_some(), "a run's end made a document");
                for (ops, intent, selection) in batches {
                    let context = format!("{text:?}, ends {ends:?}, batch {ops:?}");
                    let answer = ink::apply_batch(&mut document, ops, *intent, *selection);
                    assert_eq!(note.apply(ops, *intent, *selection), answer, "{context}");
                    same_answers(&note, &document, &context);
                }
                for back in [true, false, true, true, false, false] {
                    let context = format!("{text:?}, ends {ends:?}, back {back}");
                    let step = ink::step(&mut document, back);
                    assert_eq!(note.step(back), step, "{context}");
                    same_answers(&note, &document, &context);
                }
            }
        }
    }

    /// A resting note keeps a run's selection exactly where its document would take one.
    #[test]
    fn a_resting_note_keeps_the_selections_its_document_would() {
        for text in ["", RESTED, "\u{1F600}\u{1F600}"] {
            let document = ink::document_holding(text);
            let units = u32::try_from(text.encode_utf16().count()).unwrap();
            let mut selections = vec![TextSelection {
                location_u16: u32::MAX,
                length_u16: u32::MAX,
            }];
            for location_u16 in 0..=units + 1 {
                for length_u16 in 0..=units + 1 - location_u16 {
                    selections.push(TextSelection {
                        location_u16,
                        length_u16,
                    });
                }
            }
            for selection in selections {
                assert_eq!(
                    within(text, selection),
                    document.snapshot_selection(selection).is_some(),
                    "{text:?} {selection:?}"
                );
            }
        }
    }

    // The store's note routes between devices (ADR-0058 point 6).

    type Store = SheetStore<crate::clock::ManualClock>;

    const SECRET: &str = "ghp_note_payload_marker_4b2a";
    const DOOMED: &str = "DOOMED_NOTE_MARKER_51c9";

    fn device() -> Store {
        device_on(crate::clock::ManualClock::new())
    }

    fn device_on(clock: crate::clock::ManualClock) -> Store {
        SheetStore::new(clock)
            .with_grace_snap(false)
            .with_default_rung(crate::ttl::Ttl::from_secs(8 * 60 * 60).unwrap())
    }

    fn type_on(store: &mut Store, id: SheetId, text: &str) {
        let end = u32::try_from(store.sheet(id).unwrap().document.utf16_len()).unwrap();
        assert!(store.apply_ops(id, &typed(end, text)));
    }

    /// One discrete step in a note.
    fn write(store: &mut Store, chip: crate::sheet::ChipId, at: u32, text: &str) {
        let ops = typed(at, text);
        assert!(store.apply_note_ops(chip, &ops, EditIntent::Paste, None));
    }

    fn ship(from: &Store, from_page: SheetId, to: &mut Store, to_page: SheetId) {
        let frontier = to.document_version(to_page).unwrap();
        let batch = from.export_document_updates(from_page, &frontier).unwrap();
        assert_eq!(to.apply_remote_update(to_page, &batch), Ok(()));
    }

    fn page_of(store: &Store, id: SheetId) -> ItemId {
        store.sheet(id).unwrap().uuid()
    }

    fn record(store: &Store, id: SheetId, object: ItemId) -> &SealedChip {
        let sheet = store.sheet(id).unwrap();
        sheet
            .chips
            .iter()
            .chain(&sheet.detached)
            .find(|chip| chip.uuid == object)
            .expect("the page keeps a record for it")
    }

    fn note_mut(store: &mut Store, id: SheetId, object: ItemId) -> &mut Note {
        record_on_mut(store.sheet_mut(id).unwrap(), object)
            .and_then(|chip| chip.note.as_mut())
            .expect("the record has a note")
    }

    fn text_of(store: &Store, id: SheetId, object: ItemId) -> String {
        record(store, id, object)
            .note
            .as_ref()
            .map_or_else(String::new, |note| note.text().to_string())
    }

    /// The batch of what `from` has beyond what `to` has, applied there.
    fn send(
        from: &mut Store,
        from_page: SheetId,
        to: &mut Store,
        to_page: SheetId,
        object: ItemId,
    ) -> Result<bool, RemoteRefusal> {
        let since = to
            .note_version(to_page, object)
            .unwrap_or_else(SheetDocument::pristine_version);
        let batch = from.export_note_updates(from_page, object, &since).unwrap();
        to.apply_remote_note_update(page_of(to, to_page), object, &batch)
    }

    fn contains(haystack: &[u8], needle: &str) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle.as_bytes())
    }

    /// One page on each device, its object sealed on alpha with a note that beta
    /// has too, on its record with no value.
    struct Pair {
        alpha: Store,
        beta: Store,
        a: SheetId,
        b: SheetId,
        chip: crate::sheet::ChipId,
        peer: crate::sheet::ChipId,
        object: ItemId,
    }

    impl Pair {
        fn new(note: &str) -> Self {
            let (mut alpha, mut beta) = (device(), device());
            let (a, b) = (alpha.new_tab().1, beta.new_tab().1);
            type_on(&mut alpha, a, "one two");
            let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
            write(&mut alpha, chip, 0, note);
            ship(&alpha, a, &mut beta, b);
            let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
            let peer = record(&beta, b, object).id;
            assert_eq!(send(&mut alpha, a, &mut beta, b, object), Ok(true));
            assert_eq!(text_of(&beta, b, object), note);
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

        fn texts(&self) -> [String; 2] {
            [
                text_of(&self.alpha, self.a, self.object),
                text_of(&self.beta, self.b, self.object),
            ]
        }
    }

    #[test]
    fn two_devices_editing_one_note_converge_in_either_delivery_order() {
        for alpha_first in [true, false] {
            let mut pair = Pair::new("base");
            let (a, b, object) = (pair.a, pair.b, pair.object);
            write(&mut pair.alpha, pair.chip, 4, " alpha");
            write(&mut pair.beta, pair.peer, 0, "beta ");
            let alpha_at = pair.alpha.note_version(a, object).unwrap();
            let beta_at = pair.beta.note_version(b, object).unwrap();
            let to_beta = pair.alpha.export_note_updates(a, object, &beta_at).unwrap();
            let to_alpha = pair.beta.export_note_updates(b, object, &alpha_at).unwrap();
            let (alpha_page, beta_page) = (page_of(&pair.alpha, a), page_of(&pair.beta, b));
            for to_alpha_now in [alpha_first, !alpha_first] {
                let applied = if to_alpha_now {
                    pair.alpha
                        .apply_remote_note_update(alpha_page, object, &to_alpha)
                } else {
                    pair.beta
                        .apply_remote_note_update(beta_page, object, &to_beta)
                };
                assert_eq!(applied, Ok(true), "alpha first {alpha_first}");
            }
            let [on_alpha, on_beta] = pair.texts();
            assert_eq!(on_alpha, on_beta, "alpha first {alpha_first}");
            assert_eq!(on_alpha, "beta base alpha", "alpha first {alpha_first}");
        }
    }

    #[test]
    fn a_relaunch_keeps_the_shared_history_and_a_later_edit_merges_once() {
        let mut pair = Pair::new("base");
        let object = pair.object;
        let mut beta = device();
        assert_eq!(beta.restore(&pair.beta.snapshot(1_000), 1_000), Ok(1));
        let b = beta.sheets().next().unwrap().id();
        let peer = record(&beta, b, object).id;
        assert!(!beta.note_can_undo(peer), "the undo stack starts empty");

        write(&mut beta, peer, 0, "beta ");
        assert_eq!(
            send(&mut beta, b, &mut pair.alpha, pair.a, object),
            Ok(true)
        );
        write(&mut pair.alpha, pair.chip, 9, " alpha");
        assert_eq!(
            send(&mut pair.alpha, pair.a, &mut beta, b, object),
            Ok(true)
        );
        assert_eq!(text_of(&beta, b, object), "beta base alpha");
        assert_eq!(text_of(&pair.alpha, pair.a, object), "beta base alpha");
    }

    #[test]
    fn an_unedited_restored_note_rests_with_its_log_when_only_shown() {
        let pair = Pair::new(RESTED);
        let mut beta = device();
        assert_eq!(beta.restore(&pair.beta.snapshot(1_000), 1_000), Ok(1));
        let b = beta.sheets().next().unwrap().id();
        let peer = record(&beta, b, pair.object).id;
        assert_eq!(beta.note_text(peer).unwrap().as_str(), RESTED);
        assert_eq!(beta.notes_on(b), vec![pair.object]);
        let note = record(&beta, b, pair.object).note.as_ref().unwrap();
        let Body::Resting {
            history: Some(history),
            ..
        } = &note.body
        else {
            panic!("the shown note left its rest, or came back with no log");
        };
        wiping_owner(history);
        assert_eq!(
            history.capacity(),
            history.len(),
            "the log grew past its size"
        );
    }

    #[test]
    fn a_note_batch_standing_an_object_is_refused_and_moves_nothing() {
        let rogue = |marked: bool| {
            let document = SheetDocument::new();
            if marked {
                document.insert_chip(0, ItemId::random()).unwrap();
            } else {
                document.insert(0, "\u{FFFC}").unwrap();
            }
            document.commit(None);
            document
                .export_updates_since(&SheetDocument::pristine_version())
                .unwrap()
        };
        for marked in [true, false] {
            let mut pair = Pair::new("base");
            let page = page_of(&pair.beta, pair.b);
            assert_eq!(
                pair.beta
                    .apply_remote_note_update(page, pair.object, &rogue(marked)),
                Err(RemoteRefusal::NestedObject),
                "marked {marked}"
            );
            assert_eq!(text_of(&pair.beta, pair.b, pair.object), "base");

            // A record with no note is left with none.
            let mut alpha = device();
            let id = alpha.new_tab().1;
            let chip = alpha.seal_text_at(id, SECRET, 0, 0).unwrap();
            let object = alpha.sheet(id).unwrap().chip(chip).unwrap().uuid();
            let page = page_of(&alpha, id);
            assert_eq!(
                alpha.apply_remote_note_update(page, object, &rogue(marked)),
                Err(RemoteRefusal::NestedObject)
            );
            assert!(record(&alpha, id, object).note.is_none());
            assert!(alpha.notes_on(id).is_empty());
        }
    }

    #[test]
    fn missing_history_and_bad_bytes_are_refused_and_leave_the_note_as_it_was() {
        let mut pair = Pair::new("base");
        let object = pair.object;
        write(&mut pair.alpha, pair.chip, 4, " one");
        let between = pair.alpha.note_version(pair.a, object).unwrap();
        write(&mut pair.alpha, pair.chip, 8, " two");
        let gap = pair
            .alpha
            .export_note_updates(pair.a, object, &between)
            .unwrap();
        let page = page_of(&pair.beta, pair.b);
        assert_eq!(
            pair.beta.apply_remote_note_update(page, object, &gap),
            Err(RemoteRefusal::MissingHistory)
        );
        assert_eq!(text_of(&pair.beta, pair.b, object), "base");

        // A restored note refusing a batch still rests.
        let mut beta = device();
        assert_eq!(beta.restore(&pair.beta.snapshot(1_000), 1_000), Ok(1));
        let b = beta.sheets().next().unwrap().id();
        for bytes in [&gap[..], b"not a loro batch"] {
            assert!(beta.apply_remote_note_update(page, object, bytes).is_err());
            let note = record(&beta, b, object).note.as_ref().unwrap();
            assert!(note.resting().is_some(), "a refusal woke the note");
            assert_eq!(note.text().as_str(), "base");
        }
    }

    #[test]
    fn a_peers_note_edit_leaves_the_local_steps_as_they_were() {
        let mut pair = Pair::new("base");
        write(&mut pair.beta, pair.peer, 0, "mine ");
        let undo = pair.beta.note_undo_action_name(pair.peer);
        assert!(pair.beta.note_can_undo(pair.peer));
        write(&mut pair.alpha, pair.chip, 4, " theirs");
        assert_eq!(
            send(&mut pair.alpha, pair.a, &mut pair.beta, pair.b, pair.object),
            Ok(true)
        );
        assert_eq!(text_of(&pair.beta, pair.b, pair.object), "mine base theirs");
        assert_eq!(pair.beta.note_undo_action_name(pair.peer), undo);
        assert!(!pair.beta.note_can_redo(pair.peer));

        assert!(pair.beta.undo_note(pair.peer).unwrap().applied);
        assert_eq!(text_of(&pair.beta, pair.b, pair.object), "base theirs");
        assert!(
            !pair.beta.note_can_undo(pair.peer),
            "the peer's edit became a step"
        );
    }

    #[test]
    fn a_note_batch_before_its_record_waits_and_applies_when_it_arrives() {
        let (mut alpha, mut beta) = (device(), device());
        let (a, b) = (alpha.new_tab().1, beta.new_tab().1);
        let chip = alpha.seal_text_at(a, SECRET, 0, 0).unwrap();
        write(&mut alpha, chip, 0, "early");
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        assert_eq!(send(&mut alpha, a, &mut beta, b, object), Ok(false));
        assert_eq!(beta.note_pending.len(), 1);

        ship(&alpha, a, &mut beta, b);
        assert!(beta.note_pending.is_empty());
        assert_eq!(text_of(&beta, b, object), "early");
        assert_eq!(beta.notes_on(b), vec![object]);

        // A page that is not here keeps nothing; a page that ends drops what it kept.
        let batch = alpha
            .export_note_updates(a, object, &SheetDocument::pristine_version())
            .unwrap();
        assert_eq!(
            beta.apply_remote_note_update(ItemId::random(), object, &batch),
            Err(RemoteRefusal::UnknownSheet)
        );
        let page = page_of(&beta, b);
        assert_eq!(
            beta.apply_remote_note_update(page, ItemId::random(), &batch),
            Ok(false)
        );
        assert_eq!(beta.note_pending.len(), 1);
        assert!(beta.discard_page(b));
        assert!(beta.note_pending.is_empty());
    }

    #[test]
    fn a_note_edit_sent_for_the_page_an_object_left_reaches_it_where_it_moved() {
        let mut pair = Pair::new("base");
        let (sent_for, object) = (pair.b, pair.object);
        let moved_to = pair.beta.new_tab().1;
        assert!(
            pair.beta
                .move_range_to(sent_for, 4, 1, moved_to, 0)
                .is_some()
        );
        assert!(record_on_mut(pair.beta.sheet_mut(sent_for).unwrap(), object).is_none());
        pair.beta.take_restated_pages();

        write(&mut pair.alpha, pair.chip, 4, " moved");
        let since = pair.beta.note_version(moved_to, object).unwrap();
        let batch = pair
            .alpha
            .export_note_updates(pair.a, object, &since)
            .unwrap();
        let page = page_of(&pair.beta, sent_for);
        assert_eq!(
            pair.beta.apply_remote_note_update(page, object, &batch),
            Ok(true)
        );
        assert_eq!(text_of(&pair.beta, moved_to, object), "base moved");
        assert!(pair.beta.note_pending.is_empty());
        assert_eq!(pair.beta.take_restated_pages(), [moved_to]);
    }

    #[test]
    fn a_note_update_reaches_named_and_other_records_even_if_one_refuses() {
        for unrelated in [false, true] {
            let mut pair = Pair::new("base");
            let other = pair.beta.new_tab().1;
            pair.beta
                .stand_peer_record_as(other, 0, pair.object, None, None)
                .unwrap();
            if unrelated {
                let record =
                    record_on_mut(pair.beta.sheet_mut(pair.b).unwrap(), pair.object).unwrap();
                record.note = Some(Note::holding("unrelated"));
                write(&mut pair.beta, pair.peer, 9, " history");
            }
            pair.beta.take_restated_pages();
            write(&mut pair.alpha, pair.chip, 4, " update");
            let batch = pair
                .alpha
                .export_note_updates(pair.a, pair.object, &SheetDocument::pristine_version())
                .unwrap();
            let page = page_of(&pair.beta, pair.b);
            assert_eq!(
                pair.beta
                    .apply_remote_note_update(page, pair.object, &batch),
                Ok(true)
            );
            assert_eq!(text_of(&pair.beta, other, pair.object), "base update");
            assert_eq!(
                text_of(&pair.beta, pair.b, pair.object),
                if unrelated {
                    "unrelated history"
                } else {
                    "base update"
                }
            );
            assert_eq!(pair.beta.take_restated_pages(), [other]);
            assert_eq!(
                pair.beta
                    .apply_remote_note_update(page, pair.object, &batch),
                Ok(false)
            );
            assert!(pair.beta.take_restated_pages().is_empty());
        }
    }

    #[test]
    fn draining_a_waiting_note_updates_every_readable_record_and_restates_other_pages() {
        let mut pair = Pair::new("base");
        let other = pair.beta.new_tab().1;
        pair.beta
            .stand_peer_record_as(other, 0, pair.object, None, None)
            .unwrap();
        write(&mut pair.alpha, pair.chip, 4, " waiting");
        let batch = pair
            .alpha
            .export_note_updates(pair.a, pair.object, &SheetDocument::pristine_version())
            .unwrap();
        let page = page_of(&pair.beta, pair.b);
        pair.beta.note_pending.hold(page, pair.object, &batch);
        pair.beta.take_restated_pages();

        pair.beta.drain_pending_notes(pair.b, pair.object);
        assert!(pair.beta.note_pending.is_empty());
        assert_eq!(pair.beta.note_pending.bytes, 0);
        for id in [pair.b, other] {
            assert_eq!(text_of(&pair.beta, id, pair.object), "base waiting");
        }
        assert_eq!(pair.beta.take_restated_pages(), [other]);
    }

    #[test]
    fn a_note_batch_held_for_one_page_drains_when_its_object_arrives_on_another() {
        let (mut alpha, mut beta) = (device(), device());
        let a = alpha.new_tab().1;
        let (sent_for, arrived_on) = (beta.new_tab().1, beta.new_tab().1);
        let chip = alpha.seal_text_at(a, SECRET, 0, 0).unwrap();
        write(&mut alpha, chip, 0, "early");
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        assert_eq!(send(&mut alpha, a, &mut beta, sent_for, object), Ok(false));
        assert_eq!(beta.note_pending.len(), 1);

        ship(&alpha, a, &mut beta, arrived_on);
        assert!(beta.note_pending.is_empty());
        assert_eq!(beta.note_pending.bytes, 0);
        assert_eq!(text_of(&beta, arrived_on, object), "early");
    }

    #[test]
    fn a_burn_purges_pending_content_and_late_batches_do_not_refill_it() {
        let mut store = device();
        let page = store.new_tab().1;
        let chip = store.seal_text_at(page, SECRET, 0, 0).unwrap();
        write(&mut store, chip, 0, "waiting");
        let object = store.sheet(page).unwrap().chip(chip).unwrap().uuid();
        let identity = page_of(&store, page);
        let batch = store
            .export_note_updates(page, object, &SheetDocument::pristine_version())
            .unwrap();
        let entry = crate::metadata::ObjectMetadata {
            object,
            kind: None,
            size: None,
            name: Some((
                crate::metadata::NameVersion::first([1; 32]),
                Some(Zeroizing::new("WAITING".to_owned())),
            )),
        };
        store.note_pending.hold(identity, object, &batch);
        store.metadata_pending.push_back((identity, entry.clone()));
        assert!(!store.note_pending.is_empty());
        assert!(store.delete_chip(chip));
        assert!(store.note_pending.is_empty());
        assert_eq!(store.note_pending.bytes, 0);
        assert!(store.metadata_pending.is_empty());
        assert!(
            store
                .metadata_dirty
                .values()
                .all(|dirty| !dirty.contains(&object))
        );

        assert_eq!(
            store.apply_remote_note_update(identity, object, &batch),
            Ok(false)
        );
        assert_eq!(store.apply_object_metadata(identity, vec![entry]), 0);
        assert!(store.note_pending.is_empty());
        assert!(store.metadata_pending.is_empty());
    }

    #[test]
    fn an_empty_note_batch_is_refused_and_nothing_waits() {
        // Loro refuses one too, so the early refusal names what the import would.
        assert_eq!(
            SheetDocument::new().import_ink_update(&[], Lineage::Own),
            Err(UpdateRefusal::Malformed)
        );
        let mut pair = Pair::new("base");
        let page = page_of(&pair.beta, pair.b);
        for (page, object) in [
            (page, pair.object),
            (page, ItemId::random()),
            (ItemId::random(), ItemId::random()),
        ] {
            assert_eq!(
                pair.beta.apply_remote_note_update(page, object, &[]),
                Err(RemoteRefusal::Malformed)
            );
        }
        assert!(pair.beta.note_pending.is_empty());
        assert_eq!(text_of(&pair.beta, pair.b, pair.object), "base");
    }

    #[test]
    fn the_waiting_cache_keeps_at_most_256_batches_however_small() {
        let mut beta = device();
        let b = beta.new_tab().1;
        let page = page_of(&beta, b);
        let objects: Vec<ItemId> = (0..300).map(|_| ItemId::random()).collect();
        for object in &objects {
            assert_eq!(
                beta.apply_remote_note_update(page, *object, &[7]),
                Ok(false)
            );
        }
        let held: Vec<ItemId> = beta.note_pending.iter().map(|(_, at, _)| *at).collect();
        assert_eq!(
            held,
            objects[300 - PENDING_NOTE_BATCHES..],
            "the oldest went"
        );
        assert_eq!(beta.note_pending.bytes, PENDING_NOTE_BATCHES);

        assert!(beta.discard_page(b));
        assert_eq!(beta.note_pending.bytes, 0, "the total follows a purge");
    }

    #[test]
    fn the_waiting_cache_evicts_its_oldest_past_256_kib() {
        let mut beta = device();
        let b = beta.new_tab().1;
        let page = page_of(&beta, b);
        let objects: Vec<ItemId> = (0..3).map(|_| ItemId::random()).collect();
        for object in &objects {
            let batch = vec![7u8; 100 * 1024];
            assert_eq!(
                beta.apply_remote_note_update(page, *object, &batch),
                Ok(false)
            );
        }
        let held: Vec<ItemId> = beta.note_pending.iter().map(|(_, at, _)| *at).collect();
        assert_eq!(held, objects[1..], "the oldest stayed");

        let whole = vec![7u8; PENDING_NOTE_BYTES];
        let last = ItemId::random();
        assert_eq!(beta.apply_remote_note_update(page, last, &whole), Ok(false));
        let held: Vec<ItemId> = beta.note_pending.iter().map(|(_, at, _)| *at).collect();
        assert_eq!(held, [last], "the bound itself fits alone");

        let past = vec![7u8; PENDING_NOTE_BYTES + 1];
        assert_eq!(
            beta.apply_remote_note_update(page, ItemId::random(), &past),
            Ok(false)
        );
        let held: Vec<ItemId> = beta.note_pending.iter().map(|(_, at, _)| *at).collect();
        assert_eq!(held, [last], "a batch past the bound alone was kept");
    }

    #[test]
    fn a_page_past_its_deadline_gives_no_note_and_takes_none() {
        let clock = crate::clock::ManualClock::new();
        let mut store = device_on(clock.clone());
        let id = store.new_tab().1;
        let chip = store.seal_text_at(id, SECRET, 0, 0).unwrap();
        write(&mut store, chip, 0, "base");
        let object = store.sheet(id).unwrap().chip(chip).unwrap().uuid();
        let page = page_of(&store, id);
        let concurrent = ink::document_holding("peer text")
            .export_updates_since(&SheetDocument::pristine_version())
            .unwrap();
        clock.advance(std::time::Duration::from_secs(8 * 60 * 60));
        assert!(store.is_due(id), "the control: the page is due");

        assert!(store.notes_on(id).is_empty());
        assert_eq!(store.note_version(id, object), None);
        let pristine = SheetDocument::pristine_version();
        assert!(store.export_note_updates(id, object, &pristine).is_none());
        for target in [object, ItemId::random()] {
            assert_eq!(
                store.apply_remote_note_update(page, target, &concurrent),
                Ok(false)
            );
        }
        assert!(store.note_pending.is_empty(), "a due page held a batch");
        assert_eq!(text_of(&store, id, object), "base");
    }

    /// A note's whole history, as a peer meeting it for the first time is sent it.
    fn export_whole(store: &mut Store, id: SheetId, object: ItemId) -> Zeroizing<Vec<u8>> {
        let pristine = SheetDocument::pristine_version();
        store.export_note_updates(id, object, &pristine).unwrap()
    }

    /// Seal `value` at `at` on page `id`, its note `keep ` after `doomed` is typed and deleted.
    fn sealed_with_a_deletion(
        store: &mut Store,
        id: SheetId,
        value: &str,
        at: u32,
        doomed: &str,
    ) -> ItemId {
        let chip = store.seal_text_at(id, value, at, 0).unwrap();
        write(store, chip, 0, "keep ");
        write(store, chip, 5, doomed);
        let len_u16 = u32::try_from(doomed.len()).unwrap();
        let gone = [EditOp::Delete {
            pos_u16: 5,
            len_u16,
        }];
        assert!(store.apply_note_ops(chip, &gone, EditIntent::Deletion, None));
        store.sheet(id).unwrap().chip(chip).unwrap().uuid()
    }

    fn note_on(store: &Store, id: SheetId, object: ItemId) -> &Note {
        record(store, id, object)
            .note
            .as_ref()
            .expect("the record has a note")
    }

    /// A deferred page whose object's note once held [`DOOMED`], sent whole to a peer
    /// when `shared`, and the note's peers then.
    fn noted_with_a_deletion(shared: bool) -> (Store, SheetId, ItemId, Vec<u64>) {
        let mut alpha = device();
        let a = alpha.new_tab().1;
        assert!(alpha.set_compaction_deferred(a, true));
        type_on(&mut alpha, a, "one two");
        let object = sealed_with_a_deletion(&mut alpha, a, SECRET, 4, DOOMED);
        if shared {
            export_whole(&mut alpha, a, object);
            assert!(contains(&alpha.snapshot(1_000), DOOMED), "the control");
        }
        let peers = note_mut(&mut alpha, a, object).peers();
        (alpha, a, object, peers)
    }

    #[test]
    fn compaction_sheds_deleted_note_text_under_a_fresh_peer() {
        for shared in [false, true] {
            let (mut alpha, a, object, before) = noted_with_a_deletion(shared);
            let tab = alpha.tabs().next().unwrap().id();
            alpha.cycle_rung(tab).unwrap();
            let frame = alpha.perform_ceremony(a).unwrap();
            let parts = crate::frame::decode(&frame).unwrap();
            let objects: Vec<ItemId> = parts.notes.iter().map(|(object, _)| *object).collect();
            assert_eq!(
                objects,
                [object],
                "shared {shared}: the frame has no rebuild"
            );
            assert!(!contains(&frame, DOOMED), "the frame kept the deleted text");
            assert!(
                !contains(&alpha.snapshot(1_000), DOOMED),
                "shared {shared}: the file kept it"
            );
            assert_eq!(text_of(&alpha, a, object), "keep ");
            let after = note_mut(&mut alpha, a, object).peers();
            assert!(
                after.iter().all(|peer| !before.contains(peer)),
                "shared {shared}: an old peer survived the rebuild"
            );
            assert!(!contains(&frame, SECRET), "a value reached the frame");
        }
    }

    #[test]
    fn a_detached_records_note_keeps_its_history_through_its_pages_compaction() {
        let (mut alpha, a, object, before) = noted_with_a_deletion(true);
        assert!(alpha.apply_ops(
            a,
            &[EditOp::Delete {
                pos_u16: 4,
                len_u16: 1,
            }],
        ));
        assert!(
            alpha.sheet(a).unwrap().chips.is_empty(),
            "the object detached"
        );
        let tab = alpha.tabs().next().unwrap().id();
        alpha.cycle_rung(tab).unwrap();
        assert!(alpha.perform_ceremony(a).is_some());
        assert_eq!(note_mut(&mut alpha, a, object).peers(), before);
        let history = record(&alpha, a, object)
            .note
            .as_ref()
            .and_then(Note::history)
            .unwrap();
        assert!(
            contains(&history, DOOMED),
            "the detached note was compacted"
        );
    }

    #[test]
    fn a_pages_compaction_sheds_only_a_history_no_other_device_has_seen() {
        const KEPT: &str = "SHARED_DELETION_MARKER_77ab";
        // Two notes that restore resting: a shared one with its log, one with its text alone.
        let mut first = device();
        let id = first.new_tab().1;
        let chips = [
            first.seal_text_at(id, SECRET, 0, 0).unwrap(),
            first.seal_text_at(id, "ghp_bare_value", 0, 0).unwrap(),
        ];
        write(&mut first, chips[0], 0, "logged");
        write(&mut first, chips[1], 0, "bare");
        let [logged, bare] = chips.map(|chip| first.sheet(id).unwrap().chip(chip).unwrap().uuid());
        export_whole(&mut first, id, logged);
        let mut alpha = device();
        assert_eq!(alpha.restore(&first.snapshot(1_000), 1_000), Ok(1));
        let a = alpha.sheets().next().unwrap().id();
        let tab = alpha.tabs().next().unwrap().id();

        let local = sealed_with_a_deletion(&mut alpha, a, "ghp_local_value", 0, DOOMED);
        let shared = sealed_with_a_deletion(&mut alpha, a, "ghp_shared_value", 0, KEPT);
        export_whole(&mut alpha, a, shared);
        let detached = sealed_with_a_deletion(&mut alpha, a, "ghp_detached_value", 0, DOOMED);
        let gone = [EditOp::Delete {
            pos_u16: 0,
            len_u16: 1,
        }];
        assert!(alpha.apply_ops(a, &gone));
        let sheet = alpha.sheet(a).unwrap();
        assert!(
            sheet.detached.iter().any(|chip| chip.uuid == detached),
            "the control"
        );
        let before = note_mut(&mut alpha, a, shared).peers();
        for object in [local, detached] {
            assert!(
                note_on(&alpha, a, object).resting().is_none(),
                "the control"
            );
        }

        alpha.cycle_rung(tab).unwrap();
        for object in [logged, bare] {
            assert!(
                note_on(&alpha, a, object).resting().is_some(),
                "a resting note woke"
            );
        }
        assert!(note_on(&alpha, a, logged).history().is_some());
        for object in [bare, local, detached] {
            let note = note_on(&alpha, a, object);
            assert!(
                note.resting().is_some(),
                "a never shared note kept its document"
            );
            assert!(note.history().is_none(), "a never shared note kept its log");
        }
        assert_eq!(note_on(&alpha, a, local).text().as_str(), "keep ");
        let note = note_on(&alpha, a, shared);
        assert!(note.resting().is_none(), "the shared note was typed again");
        assert!(note.history().is_some_and(|log| contains(&log, KEPT)));
        assert_eq!(note_mut(&mut alpha, a, shared).peers(), before);
        let snapshot = alpha.snapshot(1_000);
        assert!(
            !contains(&snapshot, DOOMED),
            "the file kept a deletion no peer has"
        );
        assert!(
            contains(&snapshot, KEPT),
            "the control: the shared log is written"
        );
    }

    #[test]
    fn a_note_no_other_device_has_seen_persists_no_log_and_a_shared_one_persists_its_own() {
        for shared in [false, true] {
            let (alpha, _, object, before) = noted_with_a_deletion(shared);
            let snapshot = alpha.snapshot(1_000);
            assert_eq!(contains(&snapshot, DOOMED), shared, "shared {shared}");
            let mut revived = device();
            assert_eq!(revived.restore(&snapshot, 1_000), Ok(1));
            let r = revived.sheets().next().unwrap().id();
            let note = note_on(&revived, r, object);
            assert!(note.resting().is_some(), "shared {shared}: the note woke");
            assert_eq!(note.text().as_str(), "keep ");
            assert_eq!(note.history().is_some(), shared, "shared {shared}");
            if shared {
                assert_eq!(note_mut(&mut revived, r, object).peers(), before);
            }
        }
    }

    /// The traced defect: an object leaves an enrolled page for one that compacts and
    /// comes back, and the cursor met again exports its note from the pristine version.
    #[test]
    fn a_note_back_from_a_page_that_compacted_never_shows_its_text_twice() {
        for rebuilt in [false, true] {
            let mut pair = Pair::new("abc");
            let (a1, b1, object) = (pair.a, pair.b, pair.object);
            let (tab, a0) = pair.alpha.new_tab();
            if rebuilt {
                assert!(pair.alpha.set_compaction_deferred(a0, true));
            }
            assert!(pair.alpha.move_range_to(a1, 4, 1, a0, 0).is_some());
            ship(&pair.alpha, a1, &mut pair.beta, b1);
            let detached = &pair.beta.sheet(b1).unwrap().detached;
            assert!(
                detached.iter().any(|chip| chip.uuid == object),
                "the control"
            );
            pair.alpha.cycle_rung(tab).unwrap();
            if rebuilt {
                assert!(pair.alpha.perform_ceremony(a0).is_some());
            }
            assert!(pair.alpha.move_range_to(a0, 0, 1, a1, 4).is_some());
            ship(&pair.alpha, a1, &mut pair.beta, b1);
            let standing = &pair.beta.sheet(b1).unwrap().chips;
            assert!(
                standing.iter().any(|chip| chip.uuid == object),
                "the control"
            );

            let whole = export_whole(&mut pair.alpha, a1, object);
            let page = page_of(&pair.beta, b1);
            let outcome = pair.beta.apply_remote_note_update(page, object, &whole);
            let expected = if rebuilt {
                Err(RemoteRefusal::UnrelatedHistory)
            } else {
                Ok(false)
            };
            assert_eq!(outcome, expected, "rebuilt {rebuilt}");
            assert_eq!(pair.texts(), ["abc", "abc"], "rebuilt {rebuilt}");

            // A later edit on either side reaches the other, or is refused changing neither.
            let chip = record(&pair.alpha, a1, object).id;
            write(&mut pair.alpha, chip, 3, " alpha");
            let to_beta = send(&mut pair.alpha, a1, &mut pair.beta, b1, object);
            let peer = record(&pair.beta, b1, object).id;
            write(&mut pair.beta, peer, 0, "beta ");
            let to_alpha = send(&mut pair.beta, b1, &mut pair.alpha, a1, object);
            if rebuilt {
                let refused = Err(RemoteRefusal::UnrelatedHistory);
                assert_eq!((to_beta, to_alpha), (refused, refused));
                assert_eq!(pair.texts(), ["abc alpha", "beta abc"]);
            } else {
                assert_eq!((to_beta, to_alpha), (Ok(true), Ok(true)));
                assert_eq!(pair.texts(), ["beta abc alpha", "beta abc alpha"]);
            }
        }
    }

    #[test]
    fn a_batch_building_on_none_of_a_notes_history_is_refused_and_leaves_the_note() {
        // Two devices write one record's first note apart, so neither builds on the other.
        let (mut alpha, mut beta) = (device(), device());
        let (a, b) = (alpha.new_tab().1, beta.new_tab().1);
        let chip = alpha.seal_text_at(a, SECRET, 0, 0).unwrap();
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        ship(&alpha, a, &mut beta, b);
        let peer = record(&beta, b, object).id;
        write(&mut alpha, chip, 0, "alpha's");
        write(&mut beta, peer, 0, "beta's");
        let before = note_mut(&mut beta, b, object).peers();
        assert_eq!(
            send(&mut alpha, a, &mut beta, b, object),
            Err(RemoteRefusal::UnrelatedHistory)
        );
        assert_eq!(text_of(&beta, b, object), "beta's");
        assert_eq!(note_mut(&mut beta, b, object).peers(), before);

        // A note resting with a log of its own refuses one too, and rests on.
        let theirs = ink::document_holding("theirs");
        let batch = theirs
            .export_updates_since(&SheetDocument::pristine_version())
            .unwrap();
        let mut logged = Note::restored("mine", &ink::document_holding("mine").export_snapshot());
        assert_eq!(logged.import(&batch), Err(UpdateRefusal::UnrelatedHistory));
        assert!(logged.resting().is_some(), "a refusal woke the note");
        assert_eq!(logged.text().as_str(), "mine");

        // A blank note takes any batch, and one extending the history it took merges.
        let mut blank = Note::holding("");
        assert_eq!(blank.import(&batch), Ok(true));
        theirs.insert(6, " more").unwrap();
        theirs.commit(None);
        let more = theirs.export_updates_since(&blank.version()).unwrap();
        assert_eq!(blank.import(&more), Ok(true));
        assert_eq!(blank.text().as_str(), "theirs more");
    }

    #[test]
    fn a_note_restored_from_its_text_alone_takes_a_batch_spelling_it_and_refuses_another() {
        let theirs = ink::document_holding(RESTED);
        let batch = theirs
            .export_updates_since(&SheetDocument::pristine_version())
            .unwrap();
        let mut differs = Note::restored("another text", &[]);
        assert_eq!(differs.import(&batch), Err(UpdateRefusal::UnrelatedHistory));
        assert!(differs.resting().is_some(), "a refusal woke the note");
        assert_eq!(differs.text().as_str(), "another text");

        let mut same = Note::restored(RESTED, &[]);
        assert_eq!(same.import(&batch), Ok(true));
        assert_eq!(same.text().as_str(), RESTED, "the text showed twice");
        assert_eq!(
            same.peers(),
            theirs.history_peers(),
            "it kept a history of its own"
        );
        assert!(!same.can_undo(), "the batch became a step");
        assert!(
            same.history().is_some(),
            "the history it took is not shared"
        );
        theirs.insert(0, "> ").unwrap();
        theirs.commit(None);
        let more = theirs.export_updates_since(&same.version()).unwrap();
        assert_eq!(same.import(&more), Ok(true));
        assert_eq!(same.text().as_str(), format!("> {RESTED}"));
    }

    #[test]
    fn a_peer_adopting_the_frame_gets_each_note_and_a_later_edit_merges_once() {
        let mut alpha = device();
        let a = alpha.new_tab().1;
        assert!(alpha.set_compaction_deferred(a, true));
        type_on(&mut alpha, a, "one two");
        let first = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        let second = alpha.seal_text_at(a, "ghp_second_value", 0, 0).unwrap();
        write(&mut alpha, first, 0, "base");
        write(&mut alpha, second, 0, "second");
        let objects =
            [first, second].map(|chip| alpha.sheet(a).unwrap().chip(chip).unwrap().uuid());
        let tab = alpha.tabs().next().unwrap().id();
        alpha.cycle_rung(tab).unwrap();
        let frame = alpha.perform_ceremony(a).unwrap();

        let mut beta = device();
        let b = beta.new_tab().1;
        let page = page_of(&alpha, a);
        assert_eq!(beta.adopt_key_frame(b, page, &frame), Ok(()));
        assert_eq!(text_of(&beta, b, objects[0]), "base");
        assert_eq!(text_of(&beta, b, objects[1]), "second");
        let peer = record(&beta, b, objects[0]).id;
        assert!(!beta.note_can_undo(peer), "a rebuild became a step");

        write(&mut alpha, first, 4, " more");
        assert_eq!(send(&mut alpha, a, &mut beta, b, objects[0]), Ok(true));
        assert_eq!(text_of(&beta, b, objects[0]), "base more");
        write(&mut beta, peer, 0, "> ");
        assert_eq!(send(&mut beta, b, &mut alpha, a, objects[0]), Ok(true));
        assert_eq!(text_of(&alpha, a, objects[0]), "> base more");
    }

    #[test]
    fn a_malformed_frame_is_refused_whole_and_a_bare_page_rebuild_still_adopts() {
        let mut alpha = device();
        let a = alpha.new_tab().1;
        type_on(&mut alpha, a, "one two");
        let chip = alpha.seal_text_at(a, SECRET, 4, 0).unwrap();
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        let page = page_of(&alpha, a);
        let rebuild = alpha.sheet(a).unwrap().document.export_snapshot();
        let nested = {
            let document = SheetDocument::new();
            document.insert_chip(0, ItemId::random()).unwrap();
            document.commit(None);
            document.export_snapshot()
        };
        let framed = |note: &[u8]| {
            crate::frame::encode(&rebuild, &[(object, Zeroizing::new(note.to_vec()))])
        };
        let mut short = framed(b"").to_vec();
        short.pop();
        for (frame, refusal) in [
            (
                framed(b"not a loro rebuild").to_vec(),
                RemoteRefusal::Malformed,
            ),
            (framed(&nested).to_vec(), RemoteRefusal::NestedObject),
            (short, RemoteRefusal::Malformed),
            (
                crate::frame::encode(b"not a page", &[]).to_vec(),
                RemoteRefusal::Malformed,
            ),
        ] {
            let mut beta = device();
            let b = beta.new_tab().1;
            let before = page_of(&beta, b);
            assert_eq!(beta.adopt_key_frame(b, page, &frame), Err(refusal));
            let sheet = beta.sheet(b).unwrap();
            assert!(
                sheet.document.is_pristine(),
                "the refused frame moved the page"
            );
            assert!(sheet.chips.is_empty() && sheet.detached.is_empty());
            assert_eq!(sheet.uuid(), before);
            assert!(beta.note_pending.is_empty());
        }

        let mut beta = device();
        let b = beta.new_tab().1;
        assert_eq!(beta.adopt_key_frame(b, page, &rebuild), Ok(()));
        assert_eq!(
            beta.sheet(b).unwrap().segments().len(),
            alpha.sheet(a).unwrap().segments().len()
        );
        assert!(record(&beta, b, object).note.is_none());
    }

    #[test]
    fn a_clones_note_starts_a_history_of_its_own() {
        let mut alpha = device();
        let a = alpha.new_tab().1;
        let chip = alpha.seal_text_at(a, SECRET, 0, 0).unwrap();
        write(&mut alpha, chip, 0, "copied text");
        let object = alpha.sheet(a).unwrap().chip(chip).unwrap().uuid();
        let envelope = alpha.copy_fragment(a, 0, 1).unwrap().envelope.unwrap();
        alpha.paste_fragment(a, 1, 0, &envelope, None).unwrap();
        let clone = alpha
            .sheet(a)
            .unwrap()
            .chips
            .iter()
            .map(|chip| chip.uuid)
            .find(|uuid| *uuid != object)
            .expect("the paste cloned the object");
        assert_eq!(text_of(&alpha, a, clone), "copied text");
        let source = note_mut(&mut alpha, a, object).peers();
        let cloned = note_mut(&mut alpha, a, clone).peers();
        assert!(!cloned.is_empty());
        assert!(
            cloned.iter().all(|peer| !source.contains(peer)),
            "the clone took the source's history"
        );
    }

    /// Two pages on one device: the value on `home` with a note, and a record with no
    /// value standing it on `away`.
    fn standing_elsewhere() -> (Store, SheetId, SheetId, crate::sheet::ChipId, ItemId) {
        let mut store = device();
        let (home, away) = (store.new_tab().1, store.new_tab().1);
        type_on(&mut store, home, "ink ");
        let chip = store.seal_text_at(home, SECRET, 4, 0).unwrap();
        write(&mut store, chip, 0, "base");
        let object = store.sheet(home).unwrap().chip(chip).unwrap().uuid();
        store
            .stand_peer_record_as(away, 0, object, None, None)
            .unwrap();
        (store, home, away, chip, object)
    }

    /// Delete the value's sentinel on `home`, so the value moves to `away`.
    fn move_away(store: &mut Store, home: SheetId, away: SheetId, object: ItemId) {
        let gone = [EditOp::Delete {
            pos_u16: 4,
            len_u16: 1,
        }];
        assert!(store.apply_ops(home, &gone));
        assert!(record(store, away, object).is_local(), "the value followed");
    }

    #[test]
    fn a_value_moving_onto_a_record_whose_note_shares_its_base_merges_both_sides() {
        let (mut store, home, away, chip, object) = standing_elsewhere();
        let batch = store
            .export_note_updates(home, object, &SheetDocument::pristine_version())
            .unwrap();
        let away_page = page_of(&store, away);
        assert_eq!(
            store.apply_remote_note_update(away_page, object, &batch),
            Ok(true)
        );
        let peer = record(&store, away, object).id;
        write(&mut store, chip, 4, " home");
        write(&mut store, peer, 0, "away ");

        move_away(&mut store, home, away, object);
        assert_eq!(text_of(&store, away, object), "away base home");
    }

    #[test]
    fn a_value_moving_onto_a_record_with_no_shared_base_keeps_the_standing_note_once() {
        for standing in [Some("standing"), None] {
            let (mut store, home, away, _, object) = standing_elsewhere();
            if let Some(text) = standing {
                let peer = record(&store, away, object).id;
                write(&mut store, peer, 0, text);
            }
            move_away(&mut store, home, away, object);
            assert_eq!(
                text_of(&store, away, object),
                standing.unwrap_or("base"),
                "a blank standing note gives way"
            );
        }
    }
}
