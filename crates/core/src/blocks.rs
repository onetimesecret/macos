//! Block identity over the flat body (ADR-0013): a block is one or more
//! paragraphs of the one contiguous stream, and this module is the
//! bookkeeping that lets a block keep a name while it is edited.
//!
//! Identity is policy, not data structure. The document gives every
//! character an intrinsic identity, but which block survives a split or
//! a merge is a convention, adopted here from Notion: a newline typed
//! on its own splits the block it lands in, the fragment holding the
//! pre-split start keeps the original id and the remainder is minted
//! fresh; deleting a separating newline merges, the earlier block
//! absorbs and keeps its id, and the absorbed id dies.
//!
//! Pasted text is the one place a block outgrows a paragraph. Text that
//! arrives with its newlines already inside it was written elsewhere
//! and dropped here in one gesture, so it stays one block: its lines
//! share a name and a stamp, and the page shows one time above the
//! paste rather than the same time repeated down its margin. The shape
//! of the edit is the whole signal (a typed newline arrives alone, a
//! paste arrives whole), so nothing has to be told which gesture it
//! was.
//!
//! Nothing here touches the operation log directly. Offsets are UTF-16
//! code units throughout, the crate's one wire unit; every question
//! that needs the library (anchors, timestamps) is asked of
//! [`SheetDocument`], the module that owns that seam. Created and
//! modified are derived from the ops for as long as the ops exist;
//! `materialized` is the slot the compaction ceremony freezes them
//! into when the evidence is destroyed.

use crate::document::{DocRun, SheetDocument};
use crate::sheet::ItemId;

/// Per-block metadata frozen at a compaction boundary, once the ops
/// that proved it are gone. Written by [`BlockIndex::graduate`] just
/// before the ceremony destroys the evidence, persisted inside the
/// sealed content snapshot, and validated rather than trusted on the
/// way back in ([`BlockIndex::adopt`]).
pub(crate) struct MaterializedMeta {
    /// Earliest change that touched the block, Unix seconds.
    pub(crate) created_s: i64,
    /// Latest change that touched the block, Unix seconds.
    pub(crate) modified_s: i64,
    /// Where the block's content came from, when a paste said so. This
    /// is content (a URL can carry a token) and lives only inside the
    /// sealed snapshot, never on a JSON surface or in the ledger.
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
    /// start instead, so it survives insertions before it). Persisted
    /// beside a materialized summary so restore can prove the record
    /// still names a real block before believing it.
    pub(crate) anchor: Vec<u8>,
    /// The frozen summary, once compaction has destroyed the ops that
    /// derived it. `None` while provenance is still derivable.
    pub(crate) materialized: Option<MaterializedMeta>,
}

/// One materialized record read back from a snapshot: the persisted
/// identity, the anchor that must still resolve, and the summary it
/// claims. Built by the persistence seam, judged by
/// [`BlockIndex::adopt`].
pub(crate) struct PersistedBlock {
    /// The block identity the snapshot stored.
    pub(crate) id: ItemId,
    /// The encoded document cursor stored beside it.
    pub(crate) anchor: Vec<u8>,
    /// The frozen summary, timestamps already clamped by the reader.
    pub(crate) meta: MaterializedMeta,
}

impl MaterializedMeta {
    /// Fold an absorbed block's summary into this one, when a merge
    /// kills the absorbed identity but leaves its text on the page.
    /// Earliest created and latest modified, the same arithmetic
    /// derivation performs over a span's characters, and the origin
    /// follows the created-defining stamp: a strictly earlier birth
    /// hands over the role and the source that came with it, a tie
    /// keeps the summary already holding it.
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
    /// How many paragraphs the block covers: one for a block the reader
    /// typed, more where a paste kept its lines together. Structure, not
    /// content: it says where one block ends and the next begins in a
    /// body the shell already holds, and says nothing about what any of
    /// them contains.
    pub paragraphs: usize,
}

/// One sheet's blocks, in document order. Records and lengths move in
/// lockstep: `lens[i]` is block `i`'s width in UTF-16 code units, its
/// terminating newline included, so the last block (and only the last)
/// may be zero wide. A block covers whole paragraphs, one usually,
/// several when a paste landed, and never stops inside one. There is
/// always at least one block, because an empty page is one empty
/// paragraph.
pub(crate) struct BlockIndex {
    records: Vec<BlockRecord>,
    lens: Vec<usize>,
    /// The operation log's frontier as of the last compaction
    /// ceremony, Unix seconds. The per-block summaries can only speak
    /// for text that is still on the page, and a deletion is precisely
    /// the change that leaves no character behind to speak for it, so
    /// without this the newest thing a reader did to a page could be
    /// destroyed along with the ops that proved it and the page's
    /// modified stamp would walk backwards across the boundary.
    frontier_s: Option<i64>,
}

impl BlockIndex {
    /// The index for a document as it stands: one block per paragraph,
    /// every identity minted fresh. This is the restate path (a new
    /// page, a restore, a recovery resync) where per-block identity
    /// has no history to carry.
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

    /// Whether this index still describes `doc`: the blocks cover the
    /// body exactly, and every block ends where a paragraph ends. Blocks
    /// are no longer paragraphs one for one (a paste keeps its lines
    /// together), so this is containment rather than equality. What it
    /// still catches is a mutation path that failed to narrate its edits
    /// here: an unnarrated edit moves the total width, or strands a
    /// boundary inside a paragraph. The store checks this after every
    /// mutation; a disagreement means the honest answer is a rebuild,
    /// not a stale identity.
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

    /// Narrate an insert of `text` at a UTF-16 offset.
    ///
    /// No newline means an intra-block edit and the block simply widens.
    /// Text ending in a newline closes the block it landed in: what
    /// stood before the insertion point and the inserted text keep the
    /// original id, and the remainder of the block is minted fresh, so
    /// what the reader types next begins a block of its own. That one
    /// rule covers both gestures. A typed Enter *is* a text ending in a
    /// newline, and splits as it always did; a pasted passage arrives
    /// whole, with its newlines inside it, and joins the block it landed
    /// in rather than scattering across one block per line.
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

    /// Narrate a delete of a UTF-16 range. A deletion that swallows a
    /// separating newline merges across it: the block holding the
    /// deletion's start absorbs everything the range reached into,
    /// keeps its id, and the absorbed identities die.
    ///
    /// An identity dies; the evidence does not. Past a compaction
    /// boundary an absorbed block's frozen summary is the only thing
    /// left that can speak for text the survivor now holds, so it is
    /// folded in before the record goes ([`MaterializedMeta::absorb`]).
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

    /// Re-open the trailing empty block when the body ends on a newline
    /// and the index has nothing zero-width standing for the paragraph
    /// after it.
    ///
    /// A delete that reaches the end of the body can leave the last
    /// block terminated by a newline, and that newline opens an empty
    /// paragraph exactly as a typed Enter does, so it wants a block of
    /// its own the way [`BlockIndex::note_insert`] mints one. The
    /// narration cannot see it coming: widths say where blocks end and
    /// never what the characters are, so whether the surviving tail is
    /// a newline is a fact only the document holds. The repair
    /// therefore happens here, where the document is at hand, and it is
    /// deliberately the only shape it mends: any other drift still
    /// moves the total width or strands a boundary inside a paragraph,
    /// so [`BlockIndex::matches`] still catches it and the answer is
    /// still a rebuild.
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

    /// Every block's provenance, in document order: derived from the
    /// ops while they exist, and once compaction has frozen a summary,
    /// the summary merged with whatever newer ops say. Created is
    /// frozen for good, the evidence behind it being gone; modified is
    /// the frozen stamp or the newest post-compaction change, whichever
    /// is later.
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

    /// How many paragraphs each block covers, in document order. One
    /// for a block the reader typed, more where a paste kept its lines
    /// together. Every block covers at least one paragraph, so a stored
    /// span of zero can only be a damaged file and is refused as such
    /// by [`BlockIndex::regroup`].
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

    /// Restore the grouping a snapshot recorded: merge the blocks of a
    /// per-paragraph rebuild back into the spans the file names, the
    /// first block of each group keeping its record. The spans are
    /// believed only when they account for exactly the paragraphs this
    /// document has, each group holding at least one; anything else
    /// leaves the rebuild alone, which is the answer a file written
    /// before grouping existed gives anyway. Identity and stamps are
    /// still [`BlockIndex::adopt`]'s business; this decides only where
    /// the boundaries sit.
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

    /// Graduate every block's provenance into its materialized slot:
    /// the last full derivation before the compaction ceremony destroys
    /// the evidence. A block already carrying a summary keeps its
    /// created stamp and its origin (its created-defining change
    /// predates the previous boundary) and takes the newer modified; a
    /// block with no summary and no evidence, an empty paragraph,
    /// stays unmaterialized, because freezing nothing proves nothing.
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

    /// Adopt materialized records read back from a snapshot. Nothing is
    /// trusted on shape alone: a record is believed only when its
    /// anchor still resolves to the exact start of a block, and each
    /// block accepts at most one record. A believed record restores the
    /// block's persisted identity along with its summary; everything
    /// else is dropped, leaving that block with the fresh identity a
    /// restore mints anyway.
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
        // Anchors are re-taken from the document as it stands, the same
        // discipline as every settle: the persisted bytes proved the
        // match and have no further authority.
        self.retake_anchors(doc);
    }

    /// Remember the log's frontier a ceremony is about to destroy, as
    /// the page-level half of graduation: the blocks freeze what their
    /// surviving characters prove, and this freezes what the log knew
    /// and no character can. Folded rather than assigned, so a
    /// ceremony that finds nothing newer cannot lower the floor, and
    /// so the restore path can hand back a floor a snapshot recorded
    /// without unseating anything the live index already holds.
    pub(crate) fn note_compaction(&mut self, frontier_s: Option<i64>) {
        self.frontier_s = self.frontier_s.max(frontier_s);
    }

    /// The frontier a past ceremony captured, for the persistence seam
    /// to write down. Frozen block summaries travel in the same
    /// section; this is the half of the page's memory that belongs to
    /// no block, and it dies at the next launch if it is not written.
    pub(crate) fn compaction_frontier(&self) -> Option<i64> {
        self.frontier_s
    }

    /// The newest frozen modified stamp across the blocks, if any,
    /// merged with the frontier the last ceremony captured: the
    /// page-level floor a compacted page's modified time rests on once
    /// the ops behind it are gone.
    pub(crate) fn max_materialized_modified(&self) -> Option<i64> {
        self.records
            .iter()
            .filter_map(|record| record.materialized.as_ref().map(|frozen| frozen.modified_s))
            .max()
            .max(self.frontier_s)
    }

    /// The records, in document order, for the persistence seam to
    /// write the materialized summaries out of.
    pub(crate) fn records(&self) -> &[BlockRecord] {
        &self.records
    }

    /// Mutable access to the records, so persistence tests can plant
    /// hostile stamps and dead anchors without binary surgery on the
    /// snapshot. Test-only: production code narrates edits through the
    /// note methods and never reaches into a record.
    #[cfg(test)]
    pub(crate) fn records_mut(&mut self) -> &mut [BlockRecord] {
        &mut self.records
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

    /// A block's frozen summary, for asserting graduation. Test-only:
    /// origin is content, and no production read surface may see it.
    #[cfg(test)]
    pub(crate) fn materialized(&self, block: usize) -> Option<&MaterializedMeta> {
        self.records[block].materialized.as_ref()
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
        // What [`Sheet::settle_blocks`] does after every mutation, so
        // the tests below see the index the store would serve.
        index.reopen_trailing_block(doc);
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

        // A paste carrying two newlines lands as one block, closed by
        // its trailing newline: what it displaced becomes the block
        // after it.
        insert(&doc, &mut index, 0, "x\ny\n");
        let after = index.ids();
        assert_eq!(after.len(), 3);
        assert_eq!(after[0], original, "the pre-split start still leads");
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_pasted_passage_is_one_block() {
        let (doc, mut index) = empty();
        // Three lines arriving in one gesture: one name, one stamp, and
        // no column of identical times down the margin.
        insert(&doc, &mut index, 0, "alpha\nbeta\ngamma");
        assert_eq!(index.ids().len(), 1, "the paste did not scatter");
        assert!(index.matches(&doc), "one block over three paragraphs");
        assert_eq!(index.spans(&doc), vec![3]);

        // Enter inside it splits like anywhere else: the head keeps the
        // name, the remainder is minted fresh.
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

        // What the reader types next belongs to them, not to the paste.
        insert(&doc, &mut index, 11, "mine");
        assert_eq!(index.ids(), ids, "typing extended the open block");
        assert_eq!(index.spans(&doc), vec![2, 1]);
        assert!(index.matches(&doc));
    }

    #[test]
    fn a_merge_kills_the_absorbed_id() {
        let (doc, mut index) = empty();
        // Typed, not pasted: each line arrives with the Enter that ends
        // it, so each is its own block.
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "beta\n");
        insert(&doc, &mut index, 11, "gamma");
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
    fn a_delete_that_ends_the_body_on_a_newline_keeps_every_name() {
        let (doc, mut index) = empty();
        // A paste, so one block spans the three paragraphs: the shape
        // the bug needs, because a typed page already carries the
        // trailing empty block that a delete here must put back.
        insert(&doc, &mut index, 0, "one\ntwo\nthree");
        let pasted = index.ids()[0];

        // Select the last line and delete it. The body now ends on the
        // newline that used to separate it, so the empty paragraph
        // after that newline wants a block of its own; without one the
        // index no longer describes the body and the settle answers a
        // finished sentence by re-minting the whole page.
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

        // And what the reader types next belongs to the new block, not
        // to the paste.
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

        // Past the boundary the summaries are all the evidence there
        // is: nothing else can say when beta appeared or when it last
        // changed.
        index.graduate(&doc);
        doc.compact();
        index.retake_anchors(&doc);
        assert_eq!(index.materialized(1).unwrap().created_s, 36_000);
        assert_eq!(index.materialized(1).unwrap().modified_s, 39_600);

        // Backspace at beta's head: alpha absorbs it and keeps its id,
        // by the merge convention. The absorbed id dies, but the text
        // it named is still on the page, so its summary has to survive
        // in the block that now holds it.
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
    fn graduation_freezes_provenance_and_newer_ops_merge_on_top() {
        let (mut doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\n");
        insert(&doc, &mut index, 6, "\u{1F680}beta");
        doc.commit_at(1_000);
        insert(&doc, &mut index, 12, " grew");
        doc.commit_at(2_000);

        // Graduate, then discard: the summary is frozen from the ops,
        // the ceremony destroys them, and derivation answers from the
        // summary as if nothing happened.
        index.graduate(&doc);
        doc.compact();
        index.retake_anchors(&doc);
        assert!(index.matches(&doc), "the rebuild preserves the shape");

        let metas = index.metas(&doc);
        assert_eq!(metas[0].created_s, Some(1_000));
        assert_eq!(metas[0].modified_s, Some(1_000));
        assert_eq!(metas[1].created_s, Some(1_000));
        assert_eq!(metas[1].modified_s, Some(2_000));

        // A post-compaction edit bumps modified past the frozen stamp;
        // created stays frozen for good, its evidence being gone.
        insert(&doc, &mut index, 12, "\u{1F511}");
        doc.commit_at(5_000);
        let metas = index.metas(&doc);
        assert_eq!(metas[1].created_s, Some(1_000));
        assert_eq!(metas[1].modified_s, Some(5_000));
        assert_eq!(metas[0].modified_s, Some(1_000), "the untouched block");

        // A second boundary re-freezes: created and the first summary's
        // seniority hold, modified graduates to the newest evidence.
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
        // The paste's commit carries the origin message; a later edit
        // commits without one and must not unseat it. The follow-up
        // lands after the paste's characters so a same-second tie still
        // resolves to the paste, the change standing at the span's
        // start.
        insert(&doc, &mut index, 0, "pasted \u{1F600} text\n");
        doc.commit(Some(origin));
        insert(&doc, &mut index, 14, " later");
        doc.commit(None);

        index.graduate(&doc);
        let frozen = index.materialized(0).unwrap();
        assert_eq!(frozen.origin.as_deref(), Some(origin));
        assert!(
            index.materialized(1).is_none(),
            "an empty paragraph has nothing to freeze"
        );

        // The origin outlives the trail that proved it: after the
        // discard the summary still names the source, sealed file only.
        let mut doc = doc;
        doc.compact();
        index.retake_anchors(&doc);
        assert_eq!(
            index.materialized(0).unwrap().origin.as_deref(),
            Some(origin)
        );
    }

    #[test]
    fn regroup_restores_a_paste_and_refuses_a_shape_it_cannot_account_for() {
        let (doc, mut index) = empty();
        insert(&doc, &mut index, 0, "alpha\nbeta\ngamma");
        doc.commit_at(1_000);
        let spans = index.spans(&doc);
        assert_eq!(spans, vec![3]);

        // The restore path: a per-paragraph rebuild, then the grouping
        // the file recorded laid back over it.
        let mut rebuilt = BlockIndex::for_document(&doc);
        assert_eq!(rebuilt.ids().len(), 3, "a rebuild knows only paragraphs");
        let head = rebuilt.ids()[0];
        rebuilt.regroup(&doc, &spans);
        assert_eq!(rebuilt.ids(), vec![head], "the group's first block leads");
        assert_eq!(rebuilt.spans(&doc), spans);
        assert!(rebuilt.matches(&doc));
        assert_eq!(rebuilt.metas(&doc)[0].created_s, Some(1_000));

        // A shape that cannot account for this document's paragraphs is
        // refused whole, leaving the honest per-paragraph rebuild.
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
        insert(&doc, &mut index, 0, "\u{1F600}a\n");
        insert(&doc, &mut index, 4, "\u{1F680}b");
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
