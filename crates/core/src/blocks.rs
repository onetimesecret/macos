//! Block identity over the flat body (ADR-0013): a block is a
//! paragraph, the text between newlines in the one contiguous stream,
//! and this module is the bookkeeping that lets a paragraph keep a name
//! while it is edited.
//!
//! Identity is policy, not data structure. The document gives every
//! character an intrinsic identity, but which paragraph survives a
//! split or a merge is a convention, adopted here from Notion: an
//! insert that carries a newline splits its block, the fragment holding
//! the pre-split start keeps the original id and the remainder is
//! minted fresh; deleting a separating newline merges, the earlier
//! block absorbs and keeps its id, and the absorbed id dies.
//!
//! Nothing here touches the operation log directly. Offsets are UTF-16
//! code units throughout, the crate's one wire unit; every question
//! that needs the library — anchors, timestamps — is asked of
//! [`SheetDocument`], the module that owns that seam. Created and
//! modified are derived from the ops for as long as the ops exist;
//! `materialized` is the slot the compaction ceremony (stage 6) will
//! freeze them into when the evidence is destroyed.

use crate::document::{DocRun, SheetDocument};
use crate::sheet::ItemId;

/// Per-block metadata frozen at a compaction boundary, once the ops
/// that proved it are gone. Nothing writes this yet: the compaction
/// ceremony (ADR-0013 stage 6) is what graduates derived values into
/// this slot.
pub(crate) struct MaterializedMeta {
    /// Earliest change that touched the block, Unix seconds.
    pub(crate) created_s: i64,
    /// Latest change that touched the block, Unix seconds.
    pub(crate) modified_s: i64,
    /// Where the block's content came from, when a paste said so. This
    /// is content — a URL can carry a token — and lives only inside the
    /// sealed snapshot, never on a JSON surface or in the ledger.
    #[allow(
        dead_code,
        reason = "the compaction ceremony (stage 6) writes and reads it"
    )]
    pub(crate) origin: Option<String>,
}

/// One block: an identity, a stable position, and (after compaction)
/// a frozen summary.
pub(crate) struct BlockRecord {
    /// The block's identity, minted when the block appears and carried
    /// through every intra-block edit.
    pub(crate) id: ItemId,
    /// The block's position as an encoded document cursor: opaque
    /// bytes, taken from [`SheetDocument`] and handed back to it, never
    /// parsed here. Re-taken after every batch so it always names the
    /// block's first character (block 0 is anchored at the container
    /// start instead, so it survives insertions before it).
    #[allow(
        dead_code,
        reason = "re-taken every settle and proven to resolve by tests; the first production reader is the stage 6 ceremony"
    )]
    pub(crate) anchor: Vec<u8>,
    /// The frozen summary, once compaction has destroyed the ops that
    /// derived it. `None` while provenance is still derivable.
    pub(crate) materialized: Option<MaterializedMeta>,
}

impl BlockRecord {
    fn fresh() -> Self {
        Self {
            id: ItemId::random(),
            anchor: Vec::new(),
            materialized: None,
        }
    }
}

/// A block's provenance as a reader may see it: the identity and the
/// derived (or materialized) timestamps, Unix seconds. Deliberately no
/// origin field: origin URLs are content and cross no read surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockMeta {
    /// The block's random identity.
    pub id: ItemId,
    /// Earliest change that touched the block, Unix seconds; `None`
    /// for a block with no committed content yet.
    pub created_s: Option<i64>,
    /// Latest change that touched the block, Unix seconds; `None` for
    /// a block with no committed content yet.
    pub modified_s: Option<i64>,
}

/// One sheet's blocks, in document order. Records and lengths move in
/// lockstep: `lens[i]` is block `i`'s width in UTF-16 code units, its
/// terminating newline included, so the last block (and only the last)
/// may be zero wide. There is always at least one block, because an
/// empty page is one empty paragraph.
pub(crate) struct BlockIndex {
    records: Vec<BlockRecord>,
    lens: Vec<usize>,
}

impl BlockIndex {
    /// The index for a document as it stands: one block per paragraph,
    /// every identity minted fresh. This is the restate path — a new
    /// page, a restore, a recovery resync — where per-block identity
    /// has no history to carry.
    pub(crate) fn for_document(doc: &SheetDocument) -> Self {
        let lens = document_lens(doc);
        let records = lens.iter().map(|_| BlockRecord::fresh()).collect();
        let mut index = Self { records, lens };
        index.retake_anchors(doc);
        index
    }

    /// Whether this index still describes `doc`: same paragraph
    /// widths, block for block. The store checks this after every
    /// mutation; a disagreement means the mutation path did not narrate
    /// its edits here, and the honest answer is a rebuild, not a stale
    /// identity.
    pub(crate) fn matches(&self, doc: &SheetDocument) -> bool {
        self.lens == document_lens(doc)
    }

    /// Narrate an insert of `text` at a UTF-16 offset. No newline means
    /// an intra-block edit and the block simply widens; each newline
    /// splits, the fragment holding the pre-split start keeping the
    /// original id and everything after it minting fresh.
    pub(crate) fn note_insert(&mut self, pos_u16: usize, text: &str) {
        let (block, start) = self.locate(pos_u16);
        let pieces: Vec<usize> = text.split('\n').map(utf16_len).collect();
        if pieces.len() == 1 {
            self.lens[block] += pieces[0];
            return;
        }
        let offset = pos_u16 - start;
        let tail = self.lens[block] - offset;
        // The original block becomes the first fragment: what stood
        // before the insertion point, the first piece, and the newline
        // that now ends it.
        self.lens[block] = offset + pieces[0] + 1;
        for (index, piece) in pieces.iter().enumerate().skip(1) {
            let last = index + 1 == pieces.len();
            let len = piece + if last { tail } else { 1 };
            self.lens.insert(block + index, len);
            self.records.insert(block + index, BlockRecord::fresh());
        }
    }

    /// Narrate a delete of a UTF-16 range. A deletion that swallows a
    /// separating newline merges across it: the block holding the
    /// deletion's start absorbs everything the range reached into,
    /// keeps its id, and the absorbed identities die.
    pub(crate) fn note_delete(&mut self, pos_u16: usize, len_u16: usize) {
        if len_u16 == 0 {
            return;
        }
        let (block, start) = self.locate(pos_u16);
        let end = pos_u16 + len_u16;
        let mut combined = self.lens[block];
        let mut last = block;
        // Absorb forward while the range still covers the current run's
        // terminating newline (which sits one unit before its end).
        while last + 1 < self.lens.len() && start + combined <= end {
            last += 1;
            combined += self.lens[last];
        }
        self.lens[block] = combined - len_u16;
        self.lens.drain(block + 1..=last);
        self.records.drain(block + 1..=last);
    }

    /// Narrate a chip sentinel standing at a UTF-16 offset: one unit of
    /// width, never a newline, so an intra-block edit by construction.
    pub(crate) fn note_sentinel(&mut self, pos_u16: usize) {
        let (block, _) = self.locate(pos_u16);
        self.lens[block] += 1;
    }

    /// Re-take every block's anchor from the document as it now
    /// stands. Anchors go stale the moment text moves under them, so
    /// the store calls this once per settled mutation rather than
    /// trusting cursor arithmetic.
    pub(crate) fn retake_anchors(&mut self, doc: &SheetDocument) {
        let mut start = 0usize;
        for (record, len) in self.records.iter_mut().zip(&self.lens) {
            record.anchor = doc.block_anchor(start, start == 0).unwrap_or_default();
            start += len;
        }
    }

    /// Every block's provenance, in document order: materialized where
    /// compaction froze it, derived from the ops everywhere else.
    pub(crate) fn metas(&self, doc: &SheetDocument) -> Vec<BlockMeta> {
        let mut start = 0usize;
        self.records
            .iter()
            .zip(&self.lens)
            .map(|(record, len)| {
                let meta = match &record.materialized {
                    Some(frozen) => BlockMeta {
                        id: record.id,
                        created_s: Some(frozen.created_s),
                        modified_s: Some(frozen.modified_s),
                    },
                    None => {
                        let span = doc.span_timestamps(start, *len);
                        BlockMeta {
                            id: record.id,
                            created_s: span.map(|(created, _)| created),
                            modified_s: span.map(|(_, modified)| modified),
                        }
                    }
                };
                start += len;
                meta
            })
            .collect()
    }

    /// The block ids in document order, for asserting identity across
    /// edits.
    #[cfg(test)]
    pub(crate) fn ids(&self) -> Vec<ItemId> {
        self.records.iter().map(|record| record.id).collect()
    }

    /// A block's anchor bytes, for asserting resolution.
    #[cfg(test)]
    pub(crate) fn anchor(&self, block: usize) -> &[u8] {
        &self.records[block].anchor
    }

    /// The block that holds a UTF-16 offset, with its start offset. A
    /// block spans up to and including its terminating newline, so an
    /// offset just past a newline belongs to the next block; the very
    /// end of the body belongs to the last.
    fn locate(&self, pos_u16: usize) -> (usize, usize) {
        let mut start = 0usize;
        for (index, len) in self.lens.iter().enumerate() {
            if pos_u16 < start + len {
                return (index, start);
            }
            start += len;
        }
        let last = self.lens.len() - 1;
        (last, start - self.lens[last])
    }
}

/// The paragraph widths a document's body implies, in UTF-16 code
/// units, each terminating newline counted with its paragraph. A chip
/// sentinel is one unit and never a newline.
fn document_lens(doc: &SheetDocument) -> Vec<usize> {
    let mut lens = vec![0usize];
    for run in doc.runs() {
        match run {
            DocRun::Ink(text) => {
                for ch in text.chars() {
                    *lens.last_mut().expect("lens is never empty") += ch.len_utf16();
                    if ch == '\n' {
                        lens.push(0);
                    }
                }
            }
            DocRun::Chip(_) => *lens.last_mut().expect("lens is never empty") += 1,
        }
    }
    lens
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A document and its index, kept in lockstep by the helpers below
    /// the way the store keeps them.
    fn empty() -> (SheetDocument, BlockIndex) {
        let doc = SheetDocument::new();
        let index = BlockIndex::for_document(&doc);
        (doc, index)
    }

    fn insert(doc: &SheetDocument, index: &mut BlockIndex, pos: usize, text: &str) {
        doc.insert(pos, text).unwrap();
        index.note_insert(pos, text);
    }

    fn delete(doc: &SheetDocument, index: &mut BlockIndex, pos: usize, len: usize) {
        doc.delete(pos, len).unwrap();
        index.note_delete(pos, len);
    }

    #[test]
    fn a_split_keeps_the_original_id_on_the_first_fragment_and_mints_one() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alphabet");
        let original = index.ids()[0];

        // Enter in the middle: "alpha\nbet".
        insert(&doc, &mut index, 5, "\n");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0], original, "the first fragment keeps the id");
        assert_ne!(ids[1], original, "the remainder is minted fresh");
        assert!(index.matches(&doc));

        // A paste carrying two newlines splits twice in one op.
        insert(&doc, &mut index, 0, "x\ny\n");
        let after = index.ids();
        assert_eq!(after.len(), 4);
        assert_eq!(after[0], original, "the pre-split start still leads");
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_merge_kills_the_absorbed_id() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta\ngamma");
        let ids = index.ids();
        assert_eq!(ids.len(), 3);

        // Backspace at the head of "beta" deletes the separating
        // newline: alpha absorbs, beta's identity dies.
        delete(&doc, &mut index, 5, 1);
        let merged = index.ids();
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0], ids[0], "the absorbing block keeps its id");
        assert_eq!(merged[1], ids[2], "the untouched block is untouched");
        assert!(!merged.contains(&ids[1]), "the absorbed id is gone");
        assert!(index.matches(&doc));

        // A selection spanning both remaining paragraphs merges the
        // same way: the block holding the start survives.
        delete(&doc, &mut index, 2, 10);
        let one = index.ids();
        assert_eq!(one, vec![ids[0]]);
        assert!(index.matches(&doc));
    }

    #[test]
    fn ids_survive_intra_block_edits() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "first\nsecond");
        let ids = index.ids();

        insert(&doc, &mut index, 5, " draft");
        delete(&doc, &mut index, 0, 2);
        insert(&doc, &mut index, 14, " thoughts");
        doc.insert_chip(4, ItemId::random()).unwrap();
        index.note_sentinel(4);

        assert_eq!(index.ids(), ids, "no split, no merge, no new names");
        assert!(index.matches(&doc));
    }

    #[test]
    fn created_is_the_earliest_and_modified_the_latest_change() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta");
        doc.commit_at(1_000);
        insert(&doc, &mut index, 10, " grew");
        doc.commit_at(2_000);

        let metas = index.metas(&doc);
        assert_eq!(metas.len(), 2);
        // Block 0 was written once and never touched again.
        assert_eq!(metas[0].created_s, Some(1_000));
        assert_eq!(metas[0].modified_s, Some(1_000));
        // Block 1 holds characters from both commits: earliest for
        // created, latest for modified.
        assert_eq!(metas[1].created_s, Some(1_000));
        assert_eq!(metas[1].modified_s, Some(2_000));
    }

    #[test]
    fn an_empty_block_has_no_derived_provenance() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        doc.commit_at(1_000);
        let metas = index.metas(&doc);
        assert_eq!(metas.len(), 2, "a trailing newline opens an empty block");
        assert_eq!(metas[0].created_s, Some(1_000));
        assert_eq!(metas[1].created_s, None, "no ops, no provenance");
        assert_eq!(metas[1].modified_s, None);
    }

    #[test]
    fn anchors_resolve_after_unrelated_edits() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta");
        doc.commit(None);
        index.retake_anchors(&doc);

        // An edit in the first paragraph moves the second without the
        // anchors being re-taken: the stored positions must follow.
        doc.insert(0, "xx").unwrap();
        doc.commit(None);
        assert_eq!(
            doc.resolve_anchor(index.anchor(1)),
            Some(8),
            "the anchor follows beta's first character"
        );
        assert_eq!(
            doc.resolve_anchor(index.anchor(0)),
            Some(0),
            "block 0 is anchored at the container start, not at its first character"
        );
    }

    #[test]
    fn astral_paragraphs_split_merge_and_anchor_in_utf16() {
        let (doc, mut index) = empty();
        // Two units per emoji: the offsets below are UTF-16 throughout.
        insert(&doc, &mut index, 0, "\u{1F600}a\n\u{1F680}b");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);
        assert!(index.matches(&doc));
        doc.commit(None);
        index.retake_anchors(&doc);

        // The second paragraph starts at unit 4; its anchor resolves
        // there, and follows when astral ink lands ahead of it.
        assert_eq!(doc.resolve_anchor(index.anchor(1)), Some(4));
        insert(&doc, &mut index, 0, "\u{1F511}");
        doc.commit(None);
        assert_eq!(doc.resolve_anchor(index.anchor(1)), Some(6));
        assert_eq!(index.ids(), ids, "astral ink is an intra-block edit");

        // Split inside the astral paragraph, then merge back: the
        // convention holds at two-unit offsets as at one.
        insert(&doc, &mut index, 8, "\n");
        assert_eq!(index.ids().len(), 3);
        assert_eq!(index.ids()[1], ids[1]);
        delete(&doc, &mut index, 8, 1);
        assert_eq!(index.ids(), ids);
        assert!(index.matches(&doc));
    }
}
