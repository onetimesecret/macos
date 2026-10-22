//! Block identity over the flat body (ADR-0013). A typed newline splits
//! the block it lands in, the head keeping the id; deleting a separating
//! newline merges into the earlier block. A paste with newlines inside it
//! stays one block. Offsets are UTF-16 code units throughout.

use zeroize::Zeroizing;

use crate::document::{DocRun, SheetDocument};
use crate::sheet::ItemId;

/// Per-block metadata frozen at a compaction boundary, once the ops that
/// proved it are gone. Validated, not trusted, on restore.
pub(crate) struct MaterializedMeta {
    pub(crate) created_s: i64,
    pub(crate) modified_s: i64,
    /// Paste origin, a wiping owner. Content: sealed snapshot only, never JSON or the
    /// ledger (Law 0004, C17).
    pub(crate) origin: Option<Zeroizing<String>>,
}

pub(crate) struct BlockRecord {
    pub(crate) id: ItemId,
    /// Encoded document cursor at the block's first character (block 0: the
    /// container start). Opaque here; re-taken after every batch.
    pub(crate) anchor: Vec<u8>,
    /// `None` while provenance is still derivable from the ops.
    pub(crate) materialized: Option<MaterializedMeta>,
}

/// A materialized record read back from a snapshot, judged by
/// [`BlockIndex::adopt`].
pub(crate) struct PersistedBlock {
    pub(crate) id: ItemId,
    pub(crate) anchor: Vec<u8>,
    /// Timestamps already clamped by the reader.
    pub(crate) meta: MaterializedMeta,
}

impl MaterializedMeta {
    /// Fold in a merged-away block's summary: earliest created, latest
    /// modified; origin follows a strictly earlier created.
    fn absorb(&mut self, other: MaterializedMeta) {
        if other.created_s < self.created_s {
            self.created_s = other.created_s;
            self.origin = other.origin;
        }
        self.modified_s = self.modified_s.max(other.modified_s);
    }
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

/// A block's provenance as a reader may see it, Unix seconds. No origin:
/// origin URLs are content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockMeta {
    /// The block's random identity.
    pub id: ItemId,
    /// `None` for a block with no committed content yet.
    pub created_s: Option<i64>,
    /// `None` for a block with no committed content yet.
    pub modified_s: Option<i64>,
    /// Paragraphs covered: one when typed, more where a paste kept its lines.
    pub paragraphs: usize,
}

/// One sheet's blocks in document order. `lens[i]` is block `i`'s UTF-16
/// width including its newline; only the last may be zero. A block covers
/// whole paragraphs, and there is always at least one.
pub(crate) struct BlockIndex {
    records: Vec<BlockRecord>,
    lens: Vec<usize>,
    /// The log's frontier at the last ceremony, Unix seconds, so a deletion
    /// compacted away cannot walk the page's modified stamp backwards.
    frontier_s: Option<i64>,
}

impl BlockIndex {
    /// One block per paragraph, every identity fresh: new page, restore, resync.
    pub(crate) fn for_document(doc: &SheetDocument) -> Self {
        let lens = document_lens(doc);
        let records = lens.iter().map(|_| BlockRecord::fresh()).collect();
        let mut index = Self {
            records,
            lens,
            frontier_s: None,
        };
        index.retake_anchors(doc);
        index
    }

    /// Whether the blocks still cover `doc` exactly with every boundary at a
    /// paragraph end. False means an edit went unnarrated: rebuild.
    pub(crate) fn matches(&self, doc: &SheetDocument) -> bool {
        let mut block = 0usize;
        let mut filled = 0usize;
        for paragraph in document_lens(doc) {
            if block >= self.lens.len() {
                return false;
            }
            filled += paragraph;
            if filled > self.lens[block] {
                return false;
            }
            if filled == self.lens[block] {
                block += 1;
                filled = 0;
            }
        }
        block == self.lens.len() && filled == 0
    }

    /// Narrate an insert. Text ending in a newline closes its block: the head
    /// and the text keep the id, the remainder is minted fresh. Otherwise the
    /// block widens.
    pub(crate) fn note_insert(&mut self, pos_u16: usize, text: &str) {
        if text.is_empty() {
            return;
        }
        let (block, start) = self.locate(pos_u16);
        let len = utf16_len(text);
        if !text.ends_with('\n') {
            self.lens[block] += len;
            return;
        }
        let offset = pos_u16 - start;
        let tail = self.lens[block] - offset;
        self.lens[block] = offset + len;
        self.lens.insert(block + 1, tail);
        self.records.insert(block + 1, BlockRecord::fresh());
    }

    /// Narrate a delete. Crossing a newline merges into the block holding the
    /// start; absorbed ids die but their frozen summaries are folded in.
    pub(crate) fn note_delete(&mut self, pos_u16: usize, len_u16: usize) {
        if len_u16 == 0 {
            return;
        }
        let (block, start) = self.locate(pos_u16);
        let end = pos_u16 + len_u16;
        let mut combined = self.lens[block];
        let mut last = block;
        while last + 1 < self.lens.len() && start + combined <= end {
            last += 1;
            combined += self.lens[last];
        }
        self.lens[block] = combined - len_u16;
        self.lens.drain(block + 1..=last);
        let absorbed: Vec<MaterializedMeta> = self
            .records
            .drain(block + 1..=last)
            .filter_map(|record| record.materialized)
            .collect();
        for frozen in absorbed {
            match &mut self.records[block].materialized {
                Some(survivor) => survivor.absorb(frozen),
                slot @ None => *slot = Some(frozen),
            }
        }
    }

    /// Mint the trailing empty block when the body ends on a newline and none
    /// stands for it; only the document can show that tail is a newline.
    pub(crate) fn reopen_trailing_block(&mut self, doc: &SheetDocument) {
        if document_lens(doc).last() != Some(&0) {
            return;
        }
        if self.lens.last() == Some(&0) {
            return;
        }
        self.lens.push(0);
        self.records.push(BlockRecord::fresh());
    }

    /// Narrate a chip sentinel: one unit, never a newline.
    pub(crate) fn note_sentinel(&mut self, pos_u16: usize) {
        let (block, _) = self.locate(pos_u16);
        self.lens[block] += 1;
    }

    /// Re-take every anchor from the document as it now stands.
    pub(crate) fn retake_anchors(&mut self, doc: &SheetDocument) {
        let mut start = 0usize;
        for (record, len) in self.records.iter_mut().zip(&self.lens) {
            record.anchor = doc.block_anchor(start, start == 0).unwrap_or_default();
            start += len;
        }
    }

    /// Every block's provenance: derived from the ops, or the frozen summary
    /// with modified bumped by any newer ops.
    pub(crate) fn metas(&self, doc: &SheetDocument) -> Vec<BlockMeta> {
        let mut start = 0usize;
        let spans = self.spans(doc);
        self.records
            .iter()
            .zip(&self.lens)
            .zip(&spans)
            .map(|((record, len), paragraphs)| {
                let span = doc.span_timestamps(start, *len);
                let meta = match &record.materialized {
                    Some(frozen) => BlockMeta {
                        id: record.id,
                        created_s: Some(frozen.created_s),
                        modified_s: Some(span.map_or(frozen.modified_s, |(_, modified)| {
                            modified.max(frozen.modified_s)
                        })),
                        paragraphs: *paragraphs,
                    },
                    None => BlockMeta {
                        id: record.id,
                        created_s: span.map(|(created, _)| created),
                        modified_s: span.map(|(_, modified)| modified),
                        paragraphs: *paragraphs,
                    },
                };
                start += len;
                meta
            })
            .collect()
    }

    /// Paragraphs per block, in document order; never zero.
    pub(crate) fn spans(&self, doc: &SheetDocument) -> Vec<usize> {
        let mut spans = vec![0usize; self.lens.len()];
        let mut block = 0usize;
        let mut filled = 0usize;
        for paragraph in document_lens(doc) {
            let Some(width) = self.lens.get(block) else {
                break;
            };
            spans[block] += 1;
            filled += paragraph;
            if filled >= *width {
                block += 1;
                filled = 0;
            }
        }
        spans
    }

    /// Lay a snapshot's grouping over a per-paragraph rebuild, each group's
    /// first record leading. Ignored unless the spans are all non-zero and
    /// account for every paragraph.
    pub(crate) fn regroup(&mut self, doc: &SheetDocument, spans: &[usize]) {
        if spans.contains(&0) {
            return;
        }
        if spans.iter().sum::<usize>() != self.lens.len() {
            return;
        }
        let mut lens: Vec<usize> = Vec::with_capacity(spans.len());
        let mut records: Vec<BlockRecord> = Vec::with_capacity(spans.len());
        let mut old_lens = std::mem::take(&mut self.lens).into_iter();
        let mut old_records = std::mem::take(&mut self.records).into_iter();
        for span in spans {
            let mut width = 0usize;
            let mut head = None;
            for _ in 0..*span {
                width += old_lens.next().expect("the spans account for every block");
                let record = old_records
                    .next()
                    .expect("records and lens move in lockstep");
                head.get_or_insert(record);
            }
            lens.push(width);
            records.push(head.expect("a span of zero was refused above"));
        }
        self.lens = lens;
        self.records = records;
        self.retake_anchors(doc);
    }

    /// Freeze every block's provenance before a ceremony destroys the ops. An
    /// existing summary keeps created and origin; an empty block stays unfrozen.
    pub(crate) fn graduate(&mut self, doc: &SheetDocument) {
        let mut start = 0usize;
        for (record, len) in self.records.iter_mut().zip(&self.lens) {
            let derived = doc.span_provenance(start, *len);
            record.materialized = match (record.materialized.take(), derived) {
                (None, None) => None,
                (None, Some(derived)) => Some(MaterializedMeta {
                    created_s: derived.created_s,
                    modified_s: derived.modified_s,
                    origin: derived.origin,
                }),
                (Some(frozen), None) => Some(frozen),
                (Some(frozen), Some(derived)) => Some(MaterializedMeta {
                    created_s: frozen.created_s,
                    modified_s: frozen.modified_s.max(derived.modified_s),
                    origin: frozen.origin,
                }),
            };
            start += len;
        }
    }

    /// Adopt snapshot records. A record is believed only when its anchor
    /// resolves to a block start, at most one per block; the rest are dropped.
    pub(crate) fn adopt(&mut self, doc: &SheetDocument, persisted: Vec<PersistedBlock>) {
        let mut starts = Vec::with_capacity(self.lens.len());
        let mut start = 0usize;
        for len in &self.lens {
            starts.push(start);
            start += len;
        }
        for record in persisted {
            let Some(offset) = doc.resolve_anchor(&record.anchor) else {
                continue;
            };
            let Some(block) = starts.iter().position(|s| *s == offset) else {
                continue;
            };
            if self.records[block].materialized.is_some() {
                continue;
            }
            self.records[block].id = record.id;
            self.records[block].materialized = Some(record.meta);
        }
        self.retake_anchors(doc);
    }

    /// Raise the frontier floor; never lowers it.
    pub(crate) fn note_compaction(&mut self, frontier_s: Option<i64>) {
        self.frontier_s = self.frontier_s.max(frontier_s);
    }

    /// The frontier a past ceremony captured, for persistence to write.
    pub(crate) fn compaction_frontier(&self) -> Option<i64> {
        self.frontier_s
    }

    /// The newest frozen modified stamp, or the frontier if later.
    pub(crate) fn max_materialized_modified(&self) -> Option<i64> {
        self.records
            .iter()
            .filter_map(|record| record.materialized.as_ref().map(|frozen| frozen.modified_s))
            .max()
            .max(self.frontier_s)
    }

    /// The records, for persistence.
    pub(crate) fn records(&self) -> &[BlockRecord] {
        &self.records
    }

    /// For tests that plant hostile stamps and dead anchors.
    #[cfg(test)]
    pub(crate) fn records_mut(&mut self) -> &mut [BlockRecord] {
        &mut self.records
    }

    #[cfg(test)]
    pub(crate) fn ids(&self) -> Vec<ItemId> {
        self.records.iter().map(|record| record.id).collect()
    }

    #[cfg(test)]
    pub(crate) fn anchor(&self, block: usize) -> &[u8] {
        &self.records[block].anchor
    }

    #[cfg(test)]
    pub(crate) fn materialized(&self, block: usize) -> Option<&MaterializedMeta> {
        self.records[block].materialized.as_ref()
    }

    /// The block holding a UTF-16 offset, and its start. An offset just past
    /// a newline belongs to the next block; the end belongs to the last.
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

/// Paragraph widths in UTF-16 units, newline included; a chip counts one.
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
        index.reopen_trailing_block(doc);
    }

    #[test]
    fn a_split_keeps_the_original_id_on_the_first_fragment_and_mints_one() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alphabet");
        let original = index.ids()[0];

        insert(&doc, &mut index, 5, "\n");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0], original, "the first fragment keeps the id");
        assert_ne!(ids[1], original, "the remainder is minted fresh");
        assert!(index.matches(&doc));

        insert(&doc, &mut index, 0, "x\ny\n");
        let after = index.ids();
        assert_eq!(after.len(), 3);
        assert_eq!(after[0], original, "the pre-split start still leads");
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_pasted_passage_is_one_block() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta\ngamma");
        assert_eq!(index.ids().len(), 1, "the paste did not scatter");
        assert!(index.matches(&doc), "one block over three paragraphs");
        assert_eq!(index.spans(&doc), vec![3]);

        let pasted = index.ids()[0];
        insert(&doc, &mut index, 10, "\n");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0], pasted);
        assert_eq!(index.spans(&doc), vec![2, 2]);
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_paste_that_ends_on_a_newline_closes_its_block() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta\n");
        let ids = index.ids();
        assert_eq!(ids.len(), 2, "the trailing newline opened a block");
        assert_eq!(index.spans(&doc), vec![2, 1]);

        insert(&doc, &mut index, 11, "mine");
        assert_eq!(index.ids(), ids, "typing extended the open block");
        assert_eq!(index.spans(&doc), vec![2, 1]);
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_merge_kills_the_absorbed_id() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "beta\n");
        insert(&doc, &mut index, 11, "gamma");
        let ids = index.ids();
        assert_eq!(ids.len(), 3);

        delete(&doc, &mut index, 5, 1);
        let merged = index.ids();
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0], ids[0], "the absorbing block keeps its id");
        assert_eq!(merged[1], ids[2], "the untouched block is untouched");
        assert!(!merged.contains(&ids[1]), "the absorbed id is gone");
        assert!(index.matches(&doc));

        delete(&doc, &mut index, 2, 10);
        let one = index.ids();
        assert_eq!(one, vec![ids[0]]);
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_delete_that_ends_the_body_on_a_newline_keeps_every_name() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "one\ntwo\nthree");
        let pasted = index.ids()[0];

        delete(&doc, &mut index, 8, 5);
        assert!(
            index.matches(&doc),
            "the delete was narrated, so the index must still describe the body"
        );
        assert_eq!(index.spans(&doc), vec![2, 1]);
        assert_eq!(
            index.ids()[0],
            pasted,
            "the paste keeps its name across a delete at its tail"
        );
        assert_eq!(index.ids().len(), 2, "the trailing paragraph is a block");

        insert(&doc, &mut index, 8, "mine");
        assert_eq!(index.ids()[0], pasted);
        assert_eq!(index.ids().len(), 2);
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_merge_keeps_the_absorbed_blocks_frozen_summary() {
        let (mut doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        doc.commit_at(32_400);
        insert(&doc, &mut index, 6, "beta\n");
        doc.commit_at(36_000);
        insert(&doc, &mut index, 10, " more");
        doc.commit_at(39_600);

        index.graduate(&doc);
        doc.compact();
        index.retake_anchors(&doc);
        assert_eq!(index.materialized(1).unwrap().created_s, 36_000);
        assert_eq!(index.materialized(1).unwrap().modified_s, 39_600);

        let ids = index.ids();
        delete(&doc, &mut index, 5, 1);
        assert_eq!(index.ids()[0], ids[0], "the absorbing block keeps its id");
        let merged = index.materialized(0).unwrap();
        assert_eq!(merged.created_s, 32_400, "the earlier birth survives");
        assert_eq!(merged.modified_s, 39_600, "and the later change does");
        assert!(index.matches(&doc));
    }

    #[test]
    fn ids_survive_intra_block_edits() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "first\n");
        insert(&doc, &mut index, 6, "second");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);

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
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "beta");
        doc.commit_at(1_000);
        insert(&doc, &mut index, 10, " grew");
        doc.commit_at(2_000);

        let metas = index.metas(&doc);
        assert_eq!(metas.len(), 2);
        assert!(metas.iter().all(|meta| meta.paragraphs == 1));
        assert_eq!(metas[0].created_s, Some(1_000));
        assert_eq!(metas[0].modified_s, Some(1_000));
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
    fn graduation_freezes_provenance_and_newer_ops_merge_on_top() {
        let (mut doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "\u{1F680}beta");
        doc.commit_at(1_000);
        insert(&doc, &mut index, 12, " grew");
        doc.commit_at(2_000);

        index.graduate(&doc);
        doc.compact();
        index.retake_anchors(&doc);
        assert!(index.matches(&doc), "the rebuild preserves the shape");

        let metas = index.metas(&doc);
        assert_eq!(metas[0].created_s, Some(1_000));
        assert_eq!(metas[0].modified_s, Some(1_000));
        assert_eq!(metas[1].created_s, Some(1_000));
        assert_eq!(metas[1].modified_s, Some(2_000));

        insert(&doc, &mut index, 12, "\u{1F511}");
        doc.commit_at(5_000);
        let metas = index.metas(&doc);
        assert_eq!(metas[1].created_s, Some(1_000));
        assert_eq!(metas[1].modified_s, Some(5_000));
        assert_eq!(metas[0].modified_s, Some(1_000), "the untouched block");

        index.graduate(&doc);
        doc.compact();
        index.retake_anchors(&doc);
        let frozen = index.materialized(1).unwrap();
        assert_eq!(frozen.created_s, 1_000);
        assert_eq!(frozen.modified_s, 5_000);
    }

    #[test]
    fn graduation_carries_the_origin_of_the_created_defining_change() {
        let (doc, mut index) = empty();
        let origin = r#"{"origin":"https://origin.example.test/reset?tk=Vq9Zx"}"#;
        // The later edit lands after the paste so a same-second tie still
        // resolves to the paste.
        insert(&doc, &mut index, 0, "pasted \u{1F600} text\n");
        doc.commit(Some(origin));
        insert(&doc, &mut index, 14, " later");
        doc.commit(None);

        index.graduate(&doc);
        let frozen = index.materialized(0).unwrap();
        assert_eq!(frozen.origin.as_deref().map(String::as_str), Some(origin));
        assert!(
            index.materialized(1).is_none(),
            "an empty paragraph has nothing to freeze"
        );

        let mut doc = doc;
        doc.compact();
        index.retake_anchors(&doc);
        assert_eq!(
            index
                .materialized(0)
                .unwrap()
                .origin
                .as_deref()
                .map(String::as_str),
            Some(origin)
        );
    }

    /// An origin read out of a change is copied once into a wiping owner at its exact size,
    /// and the frozen record keeps that owner (Law 0004, C17).
    #[test]
    fn a_blocks_origin_is_one_exact_wiping_copy_of_its_changes_message() {
        fn wiping_owner<T: zeroize::ZeroizeOnDrop>(_: &T) {}

        let (doc, mut index) = empty();
        let origin = r#"{"origin":"https://origin.example.test/reset?tk=Vq9Zx"}"#;
        insert(&doc, &mut index, 0, "pasted text\n");
        doc.commit(Some(origin));

        let derived = doc.span_provenance(0, 4).unwrap().origin.unwrap();
        wiping_owner(&derived);
        assert_eq!(derived.as_str(), origin);
        assert_eq!(
            derived.capacity(),
            derived.len(),
            "the copy grew past its size"
        );

        index.graduate(&doc);
        let frozen = index.materialized(0).unwrap().origin.as_ref().unwrap();
        wiping_owner(frozen);
        assert_eq!(frozen.as_str(), origin);
        assert_eq!(
            frozen.capacity(),
            frozen.len(),
            "the frozen copy grew past its size"
        );
    }

    #[test]
    fn regroup_restores_a_paste_and_refuses_a_shape_it_cannot_account_for() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta\ngamma");
        doc.commit_at(1_000);
        let spans = index.spans(&doc);
        assert_eq!(spans, vec![3]);

        let mut rebuilt = BlockIndex::for_document(&doc);
        assert_eq!(rebuilt.ids().len(), 3, "a rebuild knows only paragraphs");
        let head = rebuilt.ids()[0];
        rebuilt.regroup(&doc, &spans);
        assert_eq!(rebuilt.ids(), vec![head], "the group's first block leads");
        assert_eq!(rebuilt.spans(&doc), spans);
        assert!(rebuilt.matches(&doc));
        assert_eq!(rebuilt.metas(&doc)[0].created_s, Some(1_000));

        for hostile in [vec![2], vec![4], vec![0, 3], vec![], vec![1, 1, 1, 1]] {
            let mut fresh = BlockIndex::for_document(&doc);
            fresh.regroup(&doc, &hostile);
            assert_eq!(fresh.ids().len(), 3, "refused: {hostile:?}");
        }
    }

    #[test]
    fn anchors_resolve_after_unrelated_edits() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "beta");
        doc.commit(None);
        index.retake_anchors(&doc);

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
        insert(&doc, &mut index, 0, "\u{1F600}a\n");
        insert(&doc, &mut index, 4, "\u{1F680}b");
        let ids = index.ids();
        assert_eq!(ids.len(), 2);
        assert!(index.matches(&doc));
        doc.commit(None);
        index.retake_anchors(&doc);

        assert_eq!(doc.resolve_anchor(index.anchor(1)), Some(4));
        insert(&doc, &mut index, 0, "\u{1F511}");
        doc.commit(None);
        assert_eq!(doc.resolve_anchor(index.anchor(1)), Some(6));
        assert_eq!(index.ids(), ids, "astral ink is an intra-block edit");

        insert(&doc, &mut index, 8, "\n");
        assert_eq!(index.ids().len(), 3);
        assert_eq!(index.ids()[1], ids[1]);
        delete(&doc, &mut index, 8, 1);
        assert_eq!(index.ids(), ids);
        assert!(index.matches(&doc));
    }

    fn frozen(created_s: i64, modified_s: i64, origin: &str) -> MaterializedMeta {
        MaterializedMeta {
            created_s,
            modified_s,
            origin: Some(Zeroizing::new(origin.to_owned())),
        }
    }

    #[test]
    fn absorb_takes_the_earlier_birth_with_its_origin_and_a_tie_keeps_the_survivors() {
        let mut survivor = frozen(200, 300, "survivor");
        survivor.absorb(frozen(100, 250, "earlier"));
        assert_eq!(survivor.created_s, 100);
        assert_eq!(survivor.modified_s, 300);
        assert_eq!(
            survivor.origin.as_deref().map(String::as_str),
            Some("earlier")
        );

        let mut survivor = frozen(100, 100, "survivor");
        survivor.absorb(frozen(100, 400, "tied"));
        assert_eq!(survivor.modified_s, 400);
        assert_eq!(
            survivor.origin.as_deref().map(String::as_str),
            Some("survivor")
        );
    }

    #[test]
    fn adopt_believes_one_record_per_resolving_block_start() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "beta");
        doc.commit(None);
        index.retake_anchors(&doc);
        let anchor = index.anchor(1).to_vec();
        let (first, second, dead) = (ItemId::random(), ItemId::random(), ItemId::random());
        let persisted = |id, anchor: Vec<u8>| PersistedBlock {
            id,
            anchor,
            meta: frozen(1, 2, "o"),
        };

        let mut restored = BlockIndex::for_document(&doc);
        restored.adopt(
            &doc,
            vec![
                persisted(dead, vec![0xff, 0x00, 0x13]),
                persisted(first, anchor.clone()),
                persisted(second, anchor),
            ],
        );
        let ids = restored.ids();
        assert_eq!(ids[1], first);
        assert!(!ids.contains(&second));
        assert!(!ids.contains(&dead));
        assert!(restored.materialized(0).is_none());
    }

    #[test]
    fn the_compaction_frontier_never_lowers() {
        let (_, mut index) = empty();
        index.note_compaction(Some(500));
        index.note_compaction(Some(100));
        index.note_compaction(None);
        assert_eq!(index.compaction_frontier(), Some(500));
        assert_eq!(index.max_materialized_modified(), Some(500));
    }
}
