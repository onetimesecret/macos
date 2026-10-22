//! A sealed object's note (ADR-0043 points 2 and 3): chipless ink
//! beside the chip, with an undo stack of its own and no clock; it goes when
//! its chip goes.

use zeroize::Zeroizing;

use crate::document::{EditIntent, EditSelection, SheetDocument, TextSelection};
use crate::ink::{self, StepOutcome};
use crate::store::EditOp;

/// The note's text, and once edited its document, which never holds a chip: sealed objects
/// do not nest.
pub(crate) struct Note {
    body: Body,
}

/// A restored or pasted note rests in a wiping owner until an edit needs the document,
/// whose Loro arena does not wipe (Law 0004, C01, C31).
enum Body {
    Resting(Zeroizing<String>),
    Document(SheetDocument),
}

impl Note {
    /// A note holding `text` with an empty undo stack: a restore, or a paste. It rests as
    /// one copy at its exact size until its first edit.
    pub(crate) fn holding(text: &str) -> Self {
        Self {
            body: Body::Resting(Zeroizing::new(text.to_owned())),
        }
    }

    /// The note's text at its final size.
    pub(crate) fn text(&self) -> Zeroizing<String> {
        match &self.body {
            Body::Resting(text) => Zeroizing::new(text.as_str().to_owned()),
            Body::Document(document) => ink::text_of(document),
        }
    }

    /// Whether anything but whitespace is written: the block's doorway.
    pub(crate) fn has_content(&self) -> bool {
        match &self.body {
            Body::Resting(text) => !text.trim().is_empty(),
            Body::Document(document) => !ink::text_of(document).trim().is_empty(),
        }
    }

    /// The resting text; `None` once an edit has made the document.
    #[cfg(test)]
    pub(crate) fn resting(&self) -> Option<&Zeroizing<String>> {
        match &self.body {
            Body::Resting(text) => Some(text),
            Body::Document(_) => None,
        }
    }

    /// The document an edit needs, made from the resting text the first time.
    fn document(&mut self) -> &mut SheetDocument {
        if let Body::Resting(text) = &self.body {
            self.body = Body::Document(ink::document_holding(text));
        }
        match &mut self.body {
            Body::Document(document) => document,
            Body::Resting(_) => unreachable!("the resting text was made a document above"),
        }
    }

    /// [`ink::apply_batch`]; `None` refused the batch whole, as is one that
    /// would write the chip sentinel as ink.
    pub(crate) fn apply(
        &mut self,
        ops: &[EditOp],
        intent: EditIntent,
        selection: Option<EditSelection>,
    ) -> Option<bool> {
        if ops.iter().any(EditOp::inks_sentinel) {
            return None;
        }
        ink::apply_batch(self.document(), ops, intent, selection)
    }

    /// End the typing run. A resting note has none, so only a selection to keep makes its
    /// document.
    pub(crate) fn finish_editing_group(&mut self, selection: Option<TextSelection>) {
        if selection.is_some() || self.edited().is_some() {
            self.document().finish_editing_group(selection);
        }
    }

    /// The document, once an edit has made it; a resting note has no step to take.
    fn edited(&self) -> Option<&SheetDocument> {
        match &self.body {
            Body::Resting(_) => None,
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
            Body::Resting(_) => StepOutcome::NONE,
            Body::Document(document) => ink::step(document, back),
        }
    }
}

#[cfg(test)]
mod tests {
    use zeroize::ZeroizeOnDrop;

    use super::*;

    const HELD: &str = "kept \u{1F600} beside it";

    fn wiping_owner<T: ZeroizeOnDrop>(_: &T) {}

    fn typed(pos_u16: u32, text: &str) -> Vec<EditOp> {
        vec![EditOp::Insert {
            pos_u16,
            text: text.into(),
        }]
    }

    /// A held note is one wiping copy at its exact size (Law 0004, C31): a plain `String`
    /// would not compile here, and a read, a step, a run's end or a sentinel's refusal makes
    /// no document.
    #[test]
    fn a_held_note_rests_as_one_wiping_copy_until_its_first_edit() {
        let mut note = Note::holding(HELD);
        let text = note.resting().expect("a held note rests");
        wiping_owner(text);
        assert_eq!(text.capacity(), text.len(), "the copy grew past its size");
        assert_eq!(note.text().as_str(), HELD);
        assert!(note.has_content());
        assert!(!note.can_undo() && !note.can_redo());
        assert_eq!(note.undo_action_name(), None);
        assert_eq!(note.redo_action_name(), None);
        assert_eq!(note.step(true), StepOutcome::NONE);
        assert_eq!(note.step(false), StepOutcome::NONE);
        note.finish_editing_group(None);
        let sentinel = typed(0, "\u{FFFC}");
        assert_eq!(note.apply(&sentinel, EditIntent::Typing, None), None);
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
            HELD,
            "the undo went past the held text"
        );
        assert!(!note.can_undo());
    }

    /// The document a note becomes answers as one made at once would, a selection kept at a
    /// run's end included, so resting changes no step (ADR-0043 point 4).
    #[test]
    fn a_resting_note_edits_and_steps_as_the_document_it_becomes() {
        let caret = TextSelection {
            location_u16: 4,
            length_u16: 0,
        };
        let edit = EditSelection {
            before: caret,
            after: TextSelection {
                location_u16: 6,
                length_u16: 0,
            },
        };
        for (kept, selection) in [(None, Some(edit)), (Some(caret), None)] {
            let mut note = Note::holding(HELD);
            let mut document = ink::document_holding(HELD);
            note.finish_editing_group(kept);
            document.finish_editing_group(kept);
            assert_eq!(note.resting().is_some(), kept.is_none(), "kept {kept:?}");
            let ops = typed(4, "!!");
            assert_eq!(
                note.apply(&ops, EditIntent::Typing, selection),
                ink::apply_batch(&mut document, &ops, EditIntent::Typing, selection),
            );
            for back in [true, false, true] {
                assert_eq!(
                    note.step(back),
                    ink::step(&mut document, back),
                    "kept {kept:?}, back {back}"
                );
                assert_eq!(note.text().as_str(), ink::text_of(&document).as_str());
            }
        }
    }
}
