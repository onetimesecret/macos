//! A sealed object's note (ADR-0043 points 2 and 3): chipless ink
//! beside the chip, with an undo stack of its own and no clock; it goes when
//! its chip goes.

use zeroize::Zeroizing;

use crate::document::{EditIntent, EditSelection, SheetDocument, TextSelection};
use crate::ink::{self, StepOutcome};
use crate::store::EditOp;

/// The note's document, which never holds a chip: sealed objects do not nest.
pub(crate) struct Note {
    document: SheetDocument,
}

impl Note {
    /// A note holding `text` with an empty undo stack: a restore, or a paste.
    pub(crate) fn holding(text: &str) -> Self {
        Self {
            document: ink::document_holding(text),
        }
    }

    /// The note's text at its final size.
    pub(crate) fn text(&self) -> Zeroizing<String> {
        ink::text_of(&self.document)
    }

    /// Whether anything but whitespace is written: the block's doorway.
    pub(crate) fn has_content(&self) -> bool {
        !self.text().trim().is_empty()
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
        ink::apply_batch(&mut self.document, ops, intent, selection)
    }

    pub(crate) fn finish_editing_group(&self, selection: Option<TextSelection>) {
        self.document.finish_editing_group(selection);
    }

    pub(crate) fn can_undo(&self) -> bool {
        self.document.can_undo()
    }

    pub(crate) fn can_redo(&self) -> bool {
        self.document.can_redo()
    }

    pub(crate) fn undo_action_name(&self) -> Option<&'static str> {
        self.document.undo_action_name()
    }

    pub(crate) fn redo_action_name(&self) -> Option<&'static str> {
        self.document.redo_action_name()
    }

    /// Undo (`back`) or redo one of the note's own steps.
    pub(crate) fn step(&mut self, back: bool) -> StepOutcome {
        ink::step(&mut self.document, back)
    }
}
