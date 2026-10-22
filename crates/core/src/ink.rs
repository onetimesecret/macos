//! Ink with no chips in it, the document an open file's body (ADR-0028) and a
//! sealed object's note (ADR-0043 point 2) each are: one batch rule,
//! one step rule.

use zeroize::Zeroizing;

use crate::document::{DocRun, EditIntent, EditSelection, SheetDocument, TextSelection};
use crate::store::EditOp;

/// What one undo or redo did, and where the caret belongs (UTF-16).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StepOutcome {
    /// Whether the step moved anything.
    pub applied: bool,
    /// Where the caret belongs; `None` when the step carried no position.
    pub caret_u16: Option<u32>,
    /// The complete selection restored by the step.
    pub selection_u16: Option<TextSelection>,
}

impl StepOutcome {
    /// A step that moved nothing.
    pub(crate) const NONE: Self = Self {
        applied: false,
        caret_u16: None,
        selection_u16: None,
    };
}

/// A document holding `text`, with an empty undo stack.
pub(crate) fn document_holding(text: &str) -> SheetDocument {
    let document = SheetDocument::new();
    if !text.is_empty() {
        document
            .insert(0, text)
            .expect("an insert at zero into an empty body");
    }
    document.commit(None);
    document.forget_undo();
    document
}

/// The document's text at its final size, each run wiped once copied; a
/// chip sentinel, unreachable here, is written as U+FFFC.
pub(crate) fn text_of(document: &SheetDocument) -> Zeroizing<String> {
    let runs = document.runs();
    let len = runs
        .iter()
        .map(|run| match run {
            DocRun::Ink(ink) => ink.len(),
            DocRun::Chip(_) => '\u{FFFC}'.len_utf8(),
        })
        .sum();
    let mut text = Zeroizing::new(String::with_capacity(len));
    for run in runs {
        match run {
            DocRun::Ink(ink) => text.push_str(&ink),
            DocRun::Chip(_) => text.push('\u{FFFC}'),
        }
    }
    text
}

/// Apply a batch whole or not at all. `None`: refused before anything moved.
/// `Some(false)`: a validated op failed anyway, and the caller restates.
pub(crate) fn apply_batch(
    document: &mut SheetDocument,
    ops: &[EditOp],
    intent: EditIntent,
    selection: Option<EditSelection>,
) -> Option<bool> {
    if ops.is_empty() {
        return Some(true);
    }
    if !admits(&text_of(document), ops) {
        return None;
    }
    let before_selection =
        selection.and_then(|selection| document.snapshot_selection(selection.before));
    // Phase two: validated, so these cannot refuse; if one does, false tells
    // the caller to restate.
    let mut clean = true;
    for op in ops {
        let outcome = match op {
            EditOp::Insert { pos_u16, text } => document.insert(*pos_u16 as usize, text),
            EditOp::Delete { pos_u16, len_u16 } => {
                document.delete(*pos_u16 as usize, *len_u16 as usize)
            }
            // Unreachable: phase one refuses chip ops.
            EditOp::InsertChip { .. } => Err(crate::document::InvalidRange),
        };
        if outcome.is_err() {
            clean = false;
            break;
        }
    }
    // Close the transaction regardless, or what landed folds into the next.
    if let (Some(before), Some(selection)) = (before_selection, selection) {
        document.commit_edit_with_selection(intent, None, before, selection.after);
    } else {
        document.commit_edit(intent, None);
    }
    Some(clean)
}

/// Phase one of a batch against `text`: whether every op applies, simulated in UTF-16 so
/// a refusal moves nothing. Sized once and zeroized, so no reallocation leaves plaintext.
pub(crate) fn admits(text: &str, ops: &[EditOp]) -> bool {
    // Every variant named, so a new inserting op fails to compile here.
    let room = ops
        .iter()
        .fold(text.encode_utf16().count(), |room, op| match op {
            EditOp::Insert { text: inserted, .. } => {
                room.saturating_add(inserted.encode_utf16().count())
            }
            EditOp::Delete { .. } | EditOp::InsertChip { .. } => room,
        });
    let mut sim: Zeroizing<Vec<u16>> = Zeroizing::new(Vec::new());
    if sim.try_reserve_exact(room).is_err() {
        return false;
    }
    sim.extend(text.encode_utf16());
    ops.iter().all(|op| sim_admit(&mut sim, op))
}

/// Undo (`back`) or redo one step, and say where the caret belongs.
pub(crate) fn step(document: &mut SheetDocument, back: bool) -> StepOutcome {
    let applied = if back {
        document.undo()
    } else {
        document.redo()
    };
    if !applied {
        return StepOutcome::NONE;
    }
    StepOutcome {
        applied,
        caret_u16: document
            .restored_caret()
            .and_then(|caret| u32::try_from(caret).ok()),
        selection_u16: document.restored_selection(),
    }
}

/// One op against the simulated UTF-16 body; false refuses the batch.
fn sim_admit(sim: &mut Vec<u16>, op: &EditOp) -> bool {
    match op {
        EditOp::Insert { pos_u16, text } => {
            let at = *pos_u16 as usize;
            if !boundary(sim, at) {
                return false;
            }
            // Wiped on drop.
            let mut units = Zeroizing::new(Vec::with_capacity(text.encode_utf16().count()));
            units.extend(text.encode_utf16());
            sim.splice(at..at, units.iter().copied());
            true
        }
        EditOp::Delete { pos_u16, len_u16 } => {
            let at = *pos_u16 as usize;
            let Some(end) = at.checked_add(*len_u16 as usize) else {
                return false;
            };
            if end > sim.len() || !boundary(sim, at) || !boundary(sim, end) {
                return false;
            }
            sim.drain(at..end);
            true
        }
        // Chipless by definition.
        EditOp::InsertChip { .. } => false,
    }
}

/// In bounds and not inside a surrogate pair.
fn boundary(sim: &[u16], at: usize) -> bool {
    if at > sim.len() {
        return false;
    }
    if at == 0 || at == sim.len() {
        return true;
    }
    let before = sim[at - 1];
    let after = sim[at];
    !((0xD800..=0xDBFF).contains(&before) && (0xDC00..=0xDFFF).contains(&after))
}

#[cfg(test)]
mod tests {
    use zeroize::{Zeroize, ZeroizeOnDrop};

    use super::*;
    use crate::sheet::ItemId;

    #[test]
    fn text_projection_is_exact_and_zeroizing_including_sentinels() {
        fn wiping_owner<T: ZeroizeOnDrop>(_: &T) {}

        let large = "λ".repeat(8192);
        for body in ["", "🙂\r\n尾", "x", large.as_str()] {
            let document = document_holding(body);
            let mut text: Zeroizing<String> = text_of(&document);
            wiping_owner(&text);
            assert_eq!(text.as_str(), body);
            assert_eq!(text.capacity(), text.len());
            let pointer = text.as_ptr();
            text.as_mut_str().zeroize();
            assert!(text.as_bytes().iter().all(|byte| *byte == 0));
            assert_eq!(text.as_ptr(), pointer);
        }
        let document = document_holding("a🙂");
        document.insert_chip(1, ItemId::random()).unwrap();
        let text = text_of(&document);
        assert_eq!(text.as_str(), "a\u{FFFC}🙂");
        assert_eq!(text.capacity(), text.len());
    }
}
