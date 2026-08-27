//! The sheet body as an operation-logged document (ADR-0013,
//! architecture 3): one Loro text container named "body", with chips
//! standing at sentinel characters and identity carried as a mark.
//!
//! Every Loro API call in the crate lives in this file, so the seam
//! between our offset discipline and the library's stays exactly one
//! module wide. The discipline: every offset that crosses this module's
//! API is a UTF-16 code unit, the unit the shell's text machinery
//! already speaks. Loro's unicode-scalar-indexed methods (`insert`,
//! `delete`, `mark`) must never see wire offsets, because an astral
//! character is one scalar but two code units and the two schemes
//! disagree precisely where the damage would be silent. Only the
//! `_utf16` variants are called here, and no Rust `String` is ever
//! indexed by a wire offset.

use loro::cursor::{Cursor, PosType, Side};
use loro::{
    CommitOptions, ContainerTrait as _, ExpandType, ExportMode, LoroDoc, LoroText, LoroValue,
    StyleConfig, StyleConfigMap, TextDelta, VersionVector,
};
use zeroize::Zeroizing;

use crate::persist::RestoreError;
use crate::sheet::ItemId;

/// The mark key that carries a chip's identity on its sentinel.
const CHIP_MARK: &str = "chip";

/// U+FFFC OBJECT REPLACEMENT CHARACTER, the one character a chip
/// occupies in the body. One code unit in UTF-16, which keeps the
/// sentinel's wire width equal to its width here.
const CHIP_SENTINEL: &str = "\u{FFFC}";

/// One run of the body, in document order: contiguous ink between
/// chips, or a single chip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DocRun {
    /// Visible, editable text.
    Ink(String),
    /// A sealed chip, present in the body as one sentinel character.
    Chip(ItemId),
}

/// The one way an edit fails: the offsets did not describe a position
/// the body recognizes, whether out of bounds or inside a surrogate
/// pair. The edit is refused whole and the body is unchanged, which is
/// the fail-closed answer to a wire offset that stopped being true.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct InvalidRange;

/// Why a remote update was refused. Every arm leaves the document
/// exactly as it was: the update is validated against a fork first
/// ([`SheetDocument::import_update`]), so refusal is whole by
/// construction, the same discipline [`SheetDocument::import_snapshot`]
/// applies to a snapshot that does not read back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UpdateRefusal {
    /// The bytes do not decode as an update batch. Damage, never
    /// partially applied.
    Malformed,
    /// The update depends on operations this document does not hold.
    /// Under the broadcast rules (ADR-0013, ADR-0021 section 1) that
    /// means the sender is across a ceremony boundary from this
    /// document, or this device was away for longer than one GOP;
    /// either way the recovery is to rejoin at the current key frame,
    /// never to ask for history. The pending half is refused rather
    /// than queued, because a queue of undecodable-until-later ops is
    /// a history archive this crate must not keep.
    MissingHistory,
    /// The update would stand a chip sentinel whose identity is not in
    /// the sheet's roster, or stand one identity twice. The chip roster
    /// and the document's marks stay in one-to-one agreement on every
    /// path — restore treats a mismatch as damage
    /// ([`crate::persist`]), and a remote edit does not get a looser
    /// contract than a file. The protocol delivers a chip's sealed
    /// bytes before the delta that references it, or the delta waits.
    ChipRoster,
}

/// What the operation log can still prove about a span: the earliest
/// and latest change stamps, and the persisted message of the earliest
/// (the created-defining) change, which is where a paste's origin
/// rides. Handed to the block index at the compaction boundary so the
/// summary can be frozen before its evidence is destroyed (ADR-0013).
pub(crate) struct SpanProvenance {
    /// Earliest change that touched the span, Unix seconds.
    pub(crate) created_s: i64,
    /// Latest change that touched the span, Unix seconds.
    pub(crate) modified_s: i64,
    /// The created-defining change's persisted message, when it carried
    /// one. This is content (an origin URL can hold a token) and must
    /// never cross a read surface.
    pub(crate) origin: Option<String>,
}

/// A sheet's body as a Loro document. Construction turns on commit
/// timestamps and registers the chip mark with `expand: none`, so that
/// typing against either side of a sentinel stays ink rather than
/// growing the chip.
pub(crate) struct SheetDocument {
    doc: LoroDoc,
    body: LoroText,
}

impl SheetDocument {
    /// A fresh, empty document with a random peer identity.
    pub(crate) fn new() -> Self {
        let doc = LoroDoc::new();
        doc.set_record_timestamp(true);
        // Adjacent commits from one peer would otherwise merge into a
        // single change when their timestamps sit within the library's
        // interval (1000 seconds), and a merged change keeps the
        // earlier stamp: a block's modified time would read up to
        // seventeen minutes stale. Provenance is the point of the
        // timestamps (ADR-0013), so every commit stays its own change.
        // The op log grows faster for it; the compaction ceremony is
        // what bounds that growth. Sync inherits the chattiness and
        // keeps the zero anyway (issue #96's decision): a delta batch
        // that mirrored commit boundaries would publish typing rhythm
        // at keystroke grade, so the protocol batches on a clock
        // instead, and the number belongs to the protocol, not to this
        // interval (ADR-0021 section 4).
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
        Self { doc, body }
    }

    /// Insert ink at a UTF-16 offset. An empty insertion at a valid
    /// offset is a no-op rather than a question for the library.
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

    /// Delete a UTF-16 range. A zero-length range at a valid offset is
    /// a no-op rather than a question for the library.
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

    /// Insert a chip at a UTF-16 offset: one sentinel character, marked
    /// with the chip's identity. If the mark cannot be applied the
    /// sentinel comes back out, because a sentinel without identity is
    /// not a chip and must not linger as one.
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

    /// Close the open transaction as one change, optionally carrying a
    /// persisted message, and immediately open the next.
    pub(crate) fn commit(&self, message: Option<&str>) {
        let mut options = CommitOptions::new().immediate_renew(true);
        if let Some(message) = message {
            options = options.commit_msg(message);
        }
        self.doc.commit_with(options);
    }

    /// The body in document order, split into ink and chips at chip
    /// marks. A sentinel whose mark value fails to parse degrades to
    /// ink: an identity that cannot be read is not a chip, and the bare
    /// replacement character leaks nothing.
    pub(crate) fn runs(&self) -> Vec<DocRun> {
        let mut runs: Vec<DocRun> = Vec::new();
        for piece in self.body.to_delta() {
            // `to_delta` on a text container yields inserts only;
            // retains and deletes belong to diffs, not to state.
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

    /// Every chip still standing in the body, in document order. A chip
    /// whose sentinel was deleted is simply absent, which is how a chip
    /// dies under this model.
    pub(crate) fn live_chips(&self) -> Vec<ItemId> {
        self.runs()
            .into_iter()
            .filter_map(|run| match run {
                DocRun::Chip(id) => Some(id),
                DocRun::Ink(_) => None,
            })
            .collect()
    }

    /// The UTF-16 offset of a chip's sentinel, if it still stands in
    /// the body.
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

    /// The full document, history included, as one plaintext buffer for
    /// the seam above to encrypt. Zeroizing because the buffer holds
    /// every character ever typed, deleted ones included.
    pub(crate) fn export_snapshot(&self) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(
            self.doc
                .export(ExportMode::Snapshot)
                .expect("a full snapshot export has no refusable input"),
        )
    }

    /// Merge a snapshot into this document. Anything the decoder
    /// refuses maps to [`RestoreError::Malformed`]: a buffer that does
    /// not read back is treated as damage, never partially applied.
    pub(crate) fn import_snapshot(&self, bytes: &[u8]) -> Result<(), RestoreError> {
        self.doc
            .import(bytes)
            .map(|_| ())
            .map_err(|_| RestoreError::Malformed)
    }

    /// This document's sync frontier: the version vector of everything
    /// it holds, as opaque bytes. Opaque on purpose (issue #96's
    /// decision, recorded here): the frontier is a cursor a peer hands
    /// back to [`SheetDocument::export_updates_since`], not a value
    /// anything above this module may interpret, exactly as block
    /// anchors are opaque cursor bytes decoded only by
    /// [`SheetDocument::resolve_anchor`]. Structured JSON would invite
    /// the seam above to read peer ids out of it, and a peer id is an
    /// identity this module deliberately never exports.
    pub(crate) fn version(&self) -> Vec<u8> {
        self.doc.oplog_vv().encode()
    }

    /// The operations this document holds beyond `version`: the delta a
    /// peer at that frontier needs to catch up, ADR-0013's P-frames.
    /// `None` when the frontier bytes do not decode; a frontier naming
    /// peers this document has never heard of (a peer across a ceremony
    /// boundary asking with a stale cursor) is well-formed and simply
    /// yields everything this document has, which is the whole current
    /// GOP. Zeroizing because an update batch carries the ops
    /// themselves, deleted text included.
    /// The frontier of a document that has seen nothing: what asks
    /// [`SheetDocument::export_updates_since`] for everything.
    /// `VersionVector::decode` refuses empty bytes, so the empty
    /// cursor has to be spelled in the encoding, and only this module
    /// may spell it.
    pub(crate) fn pristine_version() -> Vec<u8> {
        VersionVector::default().encode()
    }

    pub(crate) fn export_updates_since(&self, version: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let from = VersionVector::decode(version).ok()?;
        Some(Zeroizing::new(
            self.doc
                .export(ExportMode::updates(&from))
                .expect("an updates export since a decoded frontier has no refusable input"),
        ))
    }

    /// Apply a remote update batch, refusing it whole unless every
    /// check passes. The batch is imported into a fork first; only a
    /// fork that comes out clean — decodable, no missing dependencies,
    /// and every chip sentinel resolving one-to-one against `owned` —
    /// admits the same bytes into this document. The fork costs one
    /// page-sized copy and buys the reject-whole discipline
    /// [`SheetDocument::import_snapshot`] already promises: a refused
    /// update leaves no trace, not even a pending op inside the
    /// library.
    pub(crate) fn import_update(
        &self,
        bytes: &[u8],
        owned: &[ItemId],
    ) -> Result<(), UpdateRefusal> {
        let doc = self.doc.fork();
        let body = doc.get_text("body");
        let trial = Self { doc, body };
        let status = trial
            .doc
            .import(bytes)
            .map_err(|_| UpdateRefusal::Malformed)?;
        if status.pending.is_some() {
            return Err(UpdateRefusal::MissingHistory);
        }
        let mut seen: Vec<ItemId> = Vec::new();
        for id in trial.live_chips() {
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

    /// The body's length in UTF-16 code units, the only length the wire
    /// is allowed to reason about.
    pub(crate) fn utf16_len(&self) -> usize {
        self.body.len_utf16()
    }

    /// Whether this document has recorded no operations at all: a page
    /// as [`SheetDocument::new`] minted it, never yet typed in or
    /// imported into. This is the one state that may adopt a key frame,
    /// because a merge over standing ops would duplicate the body
    /// rather than replace it.
    pub(crate) fn is_pristine(&self) -> bool {
        self.doc.oplog_frontiers().is_empty()
    }

    /// A block's stable position as encoded cursor bytes: opaque to
    /// every caller, decoded only by [`SheetDocument::resolve_anchor`].
    /// The first block is anchored at the container itself rather than
    /// at its first character, so it still names the start of the page
    /// after ink lands ahead of it; every other block anchors at its
    /// first character, whose identity the cursor follows through edits
    /// elsewhere. `None` when the offset does not land on a boundary
    /// the body recognizes.
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

    /// Resolve encoded anchor bytes back to a UTF-16 offset, proving an
    /// anchor still points where its block went. The restore path is
    /// the production reader: a persisted materialized record is only
    /// believed when its anchor still lands on a block boundary.
    pub(crate) fn resolve_anchor(&self, anchor: &[u8]) -> Option<usize> {
        let cursor = Cursor::decode(anchor).ok()?;
        let found = self.doc.get_cursor_pos(&cursor).ok()?;
        self.body
            .convert_pos(found.current.pos, PosType::Unicode, PosType::Utf16)
    }

    /// The earliest and latest commit timestamps among the characters
    /// of a UTF-16 span, Unix seconds: created and modified for the
    /// block that owns the span, derived from the ops rather than
    /// stored (ADR-0013). A character whose change has left the history
    /// simply does not vote; after compaction the materialized summary
    /// answers instead. `None` for an empty span, an unrecognizable
    /// offset, or a span with no committed characters.
    pub(crate) fn span_timestamps(&self, start_u16: usize, len_u16: usize) -> Option<(i64, i64)> {
        self.span_provenance(start_u16, len_u16)
            .map(|derived| (derived.created_s, derived.modified_s))
    }

    /// [`SheetDocument::span_timestamps`] with the created-defining
    /// change's persisted message alongside: the last full derivation
    /// the compaction ceremony performs before the ops are destroyed.
    /// Ties on the earliest stamp keep the first character's change,
    /// the one that stands at the span's start.
    ///
    /// A change stamped at the epoch does not vote: the ceremony's
    /// rebuild commit is deliberately stamped zero
    /// ([`SheetDocument::compact`]), so re-typed characters carry no
    /// provenance of their own and the materialized summary is the only
    /// thing that answers for them.
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
                    // A strictly earlier stamp hands the created-defining
                    // role (and its message) to this change; a tie keeps
                    // the change already holding it.
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

    /// The newest committed change's timestamp, Unix seconds: the
    /// page's modified stamp, read off the log's frontier rather than
    /// stored and maintained. `None` for a document with no changes, or
    /// one whose only change is the ceremony's epoch-stamped rebuild;
    /// the materialized summary answers for a compacted page.
    pub(crate) fn latest_timestamp(&self) -> Option<i64> {
        self.doc
            .oplog_frontiers()
            .iter()
            .filter_map(|id| self.doc.get_change(id))
            .map(|change| change.timestamp)
            .filter(|stamp| *stamp > 0)
            .max()
    }

    /// The discard half of the compaction ceremony (ADR-0013): the body
    /// is re-typed, run by run, into a fresh document under a freshly
    /// minted peer identity, and this document becomes that one. The
    /// trail dies with the old document: deleted text, edit history,
    /// commit messages, and the old actor id, which must never be
    /// linkable across the boundary. The stage 1 spike proved a shallow
    /// `StateOnly` export keeps the authoring peer id, so the rebuild
    /// is from runs, never from a blob.
    ///
    /// The rebuild commits with an explicit epoch timestamp so the
    /// re-typed characters cannot pose as fresh edits: derivation skips
    /// epoch-stamped changes, and the graduated summary is what answers
    /// for everything behind the boundary. Should the rebuild somehow
    /// refuse (appends at the running end of an empty document have no
    /// refusable input), the old document stays, because keeping the
    /// trail one more rung is recoverable and losing the page's text
    /// is not.
    pub(crate) fn compact(&mut self) {
        let runs = self.runs();
        let fresh = Self::new();
        // The library mints the fresh document's peer id at random;
        // colliding with the outgoing identity is astronomically
        // unlikely, and ruled out anyway because "differs from the old"
        // is part of the ceremony's claim.
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
    }

    /// Close the open transaction with an injected timestamp, so tests
    /// can assert earliest-and-latest arithmetic against known values
    /// instead of racing the wall clock.
    #[cfg(test)]
    pub(crate) fn commit_at(&self, timestamp: i64) {
        self.doc.commit_with(
            CommitOptions::new()
                .immediate_renew(true)
                .timestamp(timestamp),
        );
    }

    /// This document's own peer identity, exposed so persistence tests
    /// can prove it never reaches the ledger. Test-only: the identity
    /// has no business anywhere else in the crate.
    #[cfg(test)]
    pub(crate) fn peer_id(&self) -> u64 {
        self.doc.peer_id()
    }

    /// The commit timestamp of the change that produced the body's
    /// first character, so persistence tests can prove provenance
    /// survives the round trip. Pinned to offset zero because the
    /// library indexes cursors in unicode scalars, and zero is the one
    /// offset where that scheme and the wire's UTF-16 cannot disagree.
    /// `None` for an empty body. Test-only.
    #[cfg(test)]
    pub(crate) fn first_change_timestamp(&self) -> Option<i64> {
        let cursor = self.body.get_cursor(0, Side::Middle)?;
        let change = self.doc.get_change(cursor.id?)?;
        Some(change.timestamp)
    }

    /// The persisted commit message of the change that produced the
    /// body's first character, pinned to offset zero for the same
    /// reason as [`SheetDocument::first_change_timestamp`]. `None` for
    /// an empty body or a change that carried no message. Test-only:
    /// this is how persistence tests prove an origin message survives
    /// the round trip without any read surface existing for it.
    #[cfg(test)]
    pub(crate) fn first_change_message(&self) -> Option<String> {
        let cursor = self.body.get_cursor(0, Side::Middle)?;
        let change = self.doc.get_change(cursor.id?)?;
        let message = change.message();
        (!message.is_empty()).then(|| message.to_string())
    }
}

/// Read a chip identity back out of its mark value. `None` for any
/// shape other than the lowercase hyphenated rendering [`ItemId`]
/// writes.
fn parse_mark_value(value: &LoroValue) -> Option<ItemId> {
    let LoroValue::String(text) = value else {
        return None;
    };
    parse_item_id(text)
}

/// Parse the 8-4-4-4-12 hyphenated hex form back into raw bytes, the
/// inverse of [`ItemId`]'s `Display`.
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
        // The emoji is one scalar but two code units; deleting it by
        // its UTF-16 width is exactly the operation a wire offset
        // performs.
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
        // Typing hard against both flanks of the sentinel. With expand
        // none the mark must not creep onto either neighbor.
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

    /// Whether `needle` occurs anywhere in `haystack`, the blunt
    /// instrument the spike calls for.
    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    // THE SPIKE (load bearing for stage 6, the compaction ceremony):
    // does a shallow StateOnly export shed deleted text and the
    // authoring peer's identity? Stage 6 wants to birth a fresh
    // document from current state and truthfully claim the history is
    // gone; this test is the acceptance guard on that claim. Measured
    // outcome: deleted text is gone, the old peer id is not.
    #[test]
    fn spike_state_only_export_sheds_deleted_text_but_keeps_the_peer_id() {
        let doc = SheetDocument::new();
        let id = ItemId::random();
        let old_peer = doc.doc.peer_id();

        // Two commits, each containing a deletion, so the history holds
        // tombstones from more than one change.
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

        // Control: live text must be findable in the blob, or a byte
        // scan proves nothing about what is absent.
        assert!(contains(&blob, b"alpha keep"));

        // (a) No deleted fragment survives the shallow export.
        assert!(!contains(&blob, b"DOOMEDONE"));
        assert!(!contains(&blob, b"DOOMEDTWO"));

        // (b) The authoring peer's identity does survive: the shallow
        // frontier and the retained tail of ops still name the peer.
        // Recorded honestly; stage 6 must mint a fresh document rather
        // than treat a StateOnly blob as scrubbed of provenance.
        let le = old_peer.to_le_bytes();
        assert!(contains(&blob, &le));

        // A fresh document under a new peer identity adopts the state.
        let restored = SheetDocument::new();
        restored.doc.set_peer_id(rand_peer(old_peer)).unwrap();
        restored.import_snapshot(&blob).unwrap();
        assert_eq!(restored.runs(), expected);
        assert_eq!(restored.live_chips(), vec![id]);

        // Pre-frontier characters lose their change metadata: the
        // character's op id still comes back from get_cursor, but the
        // change behind it was trimmed with the history, so get_change
        // resolves to nothing. Stage 6 inherits both halves of this:
        // provenance genuinely dies at the frontier, and any metadata
        // worth keeping must be materialized before the export.
        let cursor = restored.body.get_cursor(2, Side::Middle).unwrap();
        let change = restored.doc.get_change(cursor.id.unwrap());
        assert!(change.is_none());
    }

    // The ceremony the spike above was run for: rebuild-from-runs, the
    // branch the spike's measured outcome (deleted text sheds, the peer
    // id does not) forces.
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

        // The body is intact: same runs, same chip, same wire length.
        assert_eq!(doc.runs(), expected);
        assert_eq!(doc.live_chips(), vec![id]);
        assert_eq!(doc.utf16_len(), expected_len);

        // The trail is not: the export carries the live text and none
        // of what the page thought better of. No deleted fragment, no
        // origin message, no old actor id.
        let blob = doc.export_snapshot();
        assert!(contains(&blob, b"alpha  keep"), "the control: live ink");
        assert!(!contains(&blob, b"DOOMEDONE"));
        assert!(!contains(&blob, b"DOOMEDTWO"));
        assert!(!contains(&blob, b"origin.example.test"));
        assert!(!contains(&blob, &old_peer.to_le_bytes()));
        assert_ne!(doc.peer_id(), old_peer);

        // The rebuild does not vote: the page reads as having no newest
        // change until a real edit lands, and the next edit stamps
        // normally on top of the epoch-stamped rebuild.
        assert_eq!(doc.latest_timestamp(), None);
        assert_eq!(doc.span_timestamps(0, doc.utf16_len()), None);
        doc.insert(0, "x").unwrap();
        doc.commit_at(5_000);
        assert_eq!(doc.latest_timestamp(), Some(5_000));
        assert_eq!(doc.span_timestamps(0, 1), Some((5_000, 5_000)));
    }

    // ------------------------------------------------------------------
    // The delta seam (issue #96, ADR-0021 section 1)
    // ------------------------------------------------------------------

    #[test]
    fn deltas_alone_reconstruct_one_document_from_another() {
        let source = SheetDocument::new();
        let mirror = SheetDocument::new();
        let chip = ItemId::random();

        // First delta: everything beyond the mirror's empty frontier.
        source.insert(0, "first words \u{1F600}").unwrap();
        source.commit(Some("seed"));
        let frontier = mirror.version();
        let delta = source.export_updates_since(&frontier).unwrap();
        mirror.import_update(&delta, &[chip]).unwrap();
        assert_eq!(mirror.runs(), source.runs());

        // Second delta: only what the mirror has not seen, edits and a
        // chip alike, applied on top of the first.
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

        // The mirror owns no chip by that identity, so the whole batch
        // refuses: not even the ink lands, and the frontier is
        // untouched.
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

        // The second change alone, offered to a mirror that never saw
        // the first: the dependency is missing, and the refusal is
        // whole rather than a pending queue inside the library.
        let tail = source.export_updates_since(&after_one).unwrap();
        assert_eq!(
            mirror.import_update(&tail, &[]),
            Err(UpdateRefusal::MissingHistory)
        );
        assert_eq!(mirror.runs(), Vec::<DocRun>::new());

        // The same tail lands once the base has: recovery is catching
        // up from a frontier the source recognizes, never a queue.
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

        // Everything the compacted document can ever put on a wire —
        // the full delta from an empty frontier — carries neither the
        // old actor id nor the deleted fragment. The ceremony boundary
        // holds for deltas exactly as the rebuild's own export test
        // proves it for snapshots.
        let empty = SheetDocument::new();
        let full = doc.export_updates_since(&empty.version()).unwrap();
        assert!(contains(&full, b"alpha keep"), "the control: live ink");
        assert!(!contains(&full, b"DOOMED"));
        assert!(!contains(&full, &old_peer.to_le_bytes()));
        assert_ne!(doc.peer_id(), old_peer);
    }

    /// A peer id guaranteed to differ from `not`, minted from the same
    /// CSPRNG as item identities.
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
