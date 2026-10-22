//! A sealed object's note (ADR-0043 points 2 and 3): chipless ink
//! beside the chip, with an undo stack of its own and no clock; it goes when
//! its chip goes.

use zeroize::Zeroizing;

use crate::document::{EditIntent, EditSelection, SheetDocument, TextSelection};
use crate::ink::{self, StepOutcome};
use crate::store::EditOp;

/// The note's text, and once edited its document, in which no chip ever stands: sealed
/// objects do not nest.
pub(crate) struct Note {
    body: Body,
}

/// A restored or pasted note rests in a wiping owner until an edit applies, since the
/// document's Loro arena does not wipe (Law 0004, C01, C31).
enum Body {
    /// The text, and the selection the last run's end kept, given to the document later.
    Resting(Zeroizing<String>, Option<TextSelection>),
    Document(SheetDocument),
}

impl Note {
    /// A note of `text` with an empty undo stack: a restore, or a paste. It rests as one
    /// copy at its exact size until its first edit.
    pub(crate) fn holding(text: &str) -> Self {
        Self {
            body: Body::Resting(Zeroizing::new(text.to_owned()), None),
        }
    }

    /// The note's text at its final size.
    pub(crate) fn text(&self) -> Zeroizing<String> {
        match &self.body {
            Body::Resting(text, _) => Zeroizing::new(text.as_str().to_owned()),
            Body::Document(document) => ink::text_of(document),
        }
    }

    /// Whether anything but whitespace is written: the block's doorway.
    pub(crate) fn has_content(&self) -> bool {
        match &self.body {
            Body::Resting(text, _) => !text.trim().is_empty(),
            Body::Document(document) => !ink::text_of(document).trim().is_empty(),
        }
    }

    /// The resting text; `None` once an edit has made the document.
    #[cfg(test)]
    pub(crate) fn resting(&self) -> Option<&Zeroizing<String>> {
        match &self.body {
            Body::Resting(text, _) => Some(text),
            Body::Document(_) => None,
        }
    }

    /// The document an edit needs, made from the resting text the first time, with the
    /// selection a run's end kept given to it as the run's end would have.
    fn document(&mut self) -> &mut SheetDocument {
        if let Body::Resting(text, kept) = &self.body {
            let document = ink::document_holding(text);
            if kept.is_some() {
                document.finish_editing_group(*kept);
            }
            self.body = Body::Document(document);
        }
        match &mut self.body {
            Body::Document(document) => document,
            Body::Resting(..) => unreachable!("the resting text was made a document above"),
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
        if let Body::Resting(text, kept) = &mut self.body {
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
            Body::Resting(text, kept) => {
                if let Some(selection) = selection.filter(|value| within(text, *value)) {
                    *kept = Some(selection);
                }
            }
            Body::Document(document) => document.finish_editing_group(selection),
        }
    }

    /// The document, once an edit has made it; a resting note has no step to take.
    fn edited(&self) -> Option<&SheetDocument> {
        match &self.body {
            Body::Resting(..) => None,
            Body::Document(document) => Some(document),
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
            Body::Resting(..) => StepOutcome::NONE,
            Body::Document(document) => ink::step(document, back),
        }
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
}
