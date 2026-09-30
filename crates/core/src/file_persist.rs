//! The drafts snapshot: `OTSDRFT1`.
//!
//! A dirty file's unsaved edits and the roster of open files go in a
//! third plaintext buffer, sealed in `crates/ffi` under the same content
//! key as the state file and under an envelope magic of its own. Not a
//! new section inside `OTSSNAP4`: that is a format break, and it would
//! take every user's pages once. Not a trailing field on the tab record
//! either, cheap as that is: it would make a file's draft a property of
//! a Tab, and a Tab is the strip's own object with the strip's own
//! lifetime. One file keeps the two content classes structurally apart.
//!
//! Layout follows the content snapshot exactly: magic, wall stamp,
//! count, then one framed record per open file. Records are positional
//! and carry no kind tag, so a trailing field inside a record is
//! tolerated and anything past the record list is not. Same framed
//! helper, same strict envelope rule. `OTSSNAP4` is not touched.
//!
//! One record per open file: the bookmark blob, the last known path,
//! the witness, the line ending and BOM, the dirty flag, the last edit
//! stamp, and for a dirty file the Loro snapshot. A clean file records
//! only its identity, so its tab comes back with nothing staged behind
//! it and the shell fills it from disk with a reload. A record that
//! carries the trailing generation-dirty flag one earlier build wrote
//! is tolerated on read and the flag is never acted on.
//!
//! [`restore`] is only half of a restore: it decodes, and touches no
//! filesystem. Every file it puts back is pending until
//! [`crate::files::FileStore::hydrate_one`] has looked at the disk for
//! it, and every caller owes each file that call. Splitting them keeps
//! the decoder pure, so damage is refused before anything is opened, it
//! keeps the one place that reads a person's files out of the one place
//! that parses bytes off disk, and it lets a shell open each file's own
//! access grant around the read of that file and no other.
//!
//! Drafts die on save, on discard, on `companion_persist_erase`, and
//! whenever the content key halves rotate without this file being
//! rewritten in the same operation. Rotation rewrites it.

use zeroize::Zeroizing;

use crate::files::{DraftBody, FileNotice, FileStore, line_ending_from_code};
use crate::persist::{Reader, RestoreError, Sink, Writer, count, framed};

/// Magic and version prefix of a plaintext drafts snapshot. Separate
/// from the content and ledger magics so no two of the three files can
/// ever be mistaken for each other.
pub const MAGIC: &[u8; 8] = b"OTSDRFT1";

/// What one emit produced: the buffer, and every draft it would not
/// carry because the buffer was over
/// [`crate::files::DRAFT_SNAPSHOT_LIMIT`].
pub struct Emitted {
    /// The plaintext drafts snapshot, for the seam above to seal.
    pub bytes: Vec<u8>,
    /// The files whose drafts were left out, so the shell can say so
    /// rather than let a person find out at the next launch.
    pub oversized: Vec<FileNotice>,
}

/// Serialize the open file roster and every dirty file's draft.
#[must_use]
pub fn emit(store: &FileStore, wall_ms: u64) -> Emitted {
    let mut buf = Vec::new();
    let mut oversized = Vec::new();
    let mut out = Writer(&mut buf);
    out.raw(MAGIC);
    out.u64(wall_ms);
    out.u64(store.files().len() as u64);
    for file in store.files() {
        // Exported once out here rather than inside the framed body,
        // which is called twice and must stay a pure function of what
        // it captures.
        let body = store.draft_body(file.id());
        if matches!(body, DraftBody::Oversized)
            && let Some(notice) = store.oversize_notice(file.id())
        {
            oversized.push(notice);
        }
        let snapshot = match &body {
            DraftBody::Snapshot(bytes) => Some(bytes),
            DraftBody::None | DraftBody::Oversized | DraftBody::AlreadyDropped => None,
        };
        let witness = file.witness_or_zero();
        framed(&mut out, |out| {
            out.bytes(file.bookmark());
            out.bytes(file.path().to_string_lossy().as_bytes());
            out.u8(u8::from(file.has_witness()));
            out.u64(witness.dev);
            out.u64(witness.ino);
            out.u64(witness.size);
            out.bytes(&witness.mtime_ns.to_le_bytes());
            out.u8(file.line_ending_code());
            out.u8(u8::from(file.has_bom()));
            out.u8(u8::from(file.is_dirty()));
            out.u64(file.last_edited_ms());
            match snapshot {
                None => out.u8(0),
                Some(bytes) => {
                    out.u8(1);
                    out.bytes(bytes);
                }
            }
        });
    }
    Emitted {
        bytes: buf,
        oversized,
    }
}

/// Read a drafts snapshot back into the store, replacing whatever it
/// held, and return how many files were restored.
///
/// `wall_ms` is the reading of the clock at the restore. It is accepted
/// and deliberately unused: a file has no countdown to drain and no
/// deadline to move, which is the whole difference between this file
/// and the content snapshot. The parameter stays so that the two
/// restore paths read alike and so a future field that does age has
/// somewhere to get the time from.
///
/// # Errors
///
/// [`RestoreError::UnknownFormat`] for a buffer that is not a drafts
/// snapshot this build reads; [`RestoreError::Malformed`] for one that
/// is damaged.
pub fn restore(store: &mut FileStore, bytes: &[u8], wall_ms: u64) -> Result<usize, RestoreError> {
    use RestoreError::Malformed;
    let _ = wall_ms;
    let mut reader = Reader { buf: bytes, pos: 0 };
    if reader.raw(MAGIC.len()) != Some(MAGIC.as_slice()) {
        return Err(RestoreError::UnknownFormat);
    }
    let _saved_wall = reader.u64().ok_or(Malformed)?;
    let file_count = count(&mut reader)?;

    // Everything is decoded before the store is touched, so a damaged
    // buffer leaves whatever was open exactly as it was.
    let mut records = Vec::with_capacity(file_count);
    for _ in 0..file_count {
        let mut record = reader.framed().ok_or(Malformed)?;
        let bookmark = record.bytes().ok_or(Malformed)?.to_vec();
        let path = record.str().ok_or(Malformed)?.to_string();
        let has_witness = match record.u8().ok_or(Malformed)? {
            0 => false,
            1 => true,
            _ => return Err(Malformed),
        };
        let dev = record.u64().ok_or(Malformed)?;
        let ino = record.u64().ok_or(Malformed)?;
        let size = record.u64().ok_or(Malformed)?;
        let mtime: [u8; 16] = record
            .bytes()
            .ok_or(Malformed)?
            .try_into()
            .map_err(|_| Malformed)?;
        let line_ending = line_ending_from_code(record.u8().ok_or(Malformed)?).ok_or(Malformed)?;
        let has_bom = match record.u8().ok_or(Malformed)? {
            0 => false,
            1 => true,
            _ => return Err(Malformed),
        };
        let dirty = match record.u8().ok_or(Malformed)? {
            0 => false,
            1 => true,
            _ => return Err(Malformed),
        };
        let last_edited_ms = record.u64().ok_or(Malformed)?;
        let snapshot = match record.u8().ok_or(Malformed)? {
            0 => None,
            1 => Some(Zeroizing::new(record.bytes().ok_or(Malformed)?.to_vec())),
            _ => return Err(Malformed),
        };
        // A build in between wrote a generation-dirty flag here. It is
        // read by nobody now and stepped over by the frame's own length,
        // which is what ADR-0031 asks for: the field may survive in old
        // records, and it carries no authority over dirty state, because
        // file undo history does not cross launch and a marker without
        // its history explains nothing to the person looking at the tab.
        //
        // Fields this build has never heard of are left behind inside
        // the frame. The record's own length is what finds the next
        // one, so the walk above stopping early is the rule working.
        records.push(Record {
            bookmark,
            path,
            witness: has_witness.then_some(crate::files::FileWitness {
                dev,
                ino,
                size,
                mtime_ns: i128::from_le_bytes(mtime),
            }),
            line_ending,
            has_bom,
            dirty,
            last_edited_ms,
            snapshot,
        });
    }
    // The envelope stays strict even though the records do not: a tail
    // after the last record is outside every frame, so nothing states
    // how long it is or promises it was ever meant to be here.
    if !reader.done() {
        return Err(Malformed);
    }

    store.clear();
    let mut restored = 0;
    for record in records {
        store.adopt_restored(
            record.path.into(),
            record.bookmark,
            record.witness,
            record.line_ending,
            record.has_bom,
            record.dirty,
            record.last_edited_ms,
            record.snapshot.as_deref().map(Vec::as_slice),
        )?;
        restored += 1;
    }
    Ok(restored)
}

/// One decoded record, held until the whole buffer has read back.
struct Record {
    bookmark: Vec<u8>,
    path: String,
    witness: Option<crate::files::FileWitness>,
    line_ending: crate::files::LineEnding,
    has_bom: bool,
    dirty: bool,
    last_edited_ms: u64,
    /// Plaintext Loro bytes retained only while the complete snapshot is
    /// validated and adopted into the document.
    snapshot: Option<Zeroizing<Vec<u8>>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::{
        DroppedReason, FileConflict, FileId, FileIo, FileStore, FileWitness, HydrationFate,
        LineEnding, OpenFile, OpenRefusal, PathRebind, RelocateRefusal, SaveError,
    };
    use crate::store::EditOp;
    use std::collections::{HashMap, HashSet};
    use std::io;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemoryIo {
        files: Mutex<HashMap<PathBuf, Vec<u8>>>,
        /// Bumped on every write, so a file rewritten with the same
        /// bytes still reads as changed the way a real mtime would.
        tick: Mutex<i128>,
        stamps: Mutex<HashMap<PathBuf, i128>>,
        /// Paths that stat and will not read, which is what a sandbox
        /// answers for a file nobody has granted.
        denied: Mutex<HashSet<PathBuf>>,
        /// Paths that will not stat either, which is a directory the
        /// process may not search.
        walled: Mutex<HashSet<PathBuf>>,
    }

    impl MemoryIo {
        fn with(path: &str, bytes: &[u8]) -> Self {
            let io = Self::default();
            io.put(path, bytes);
            io
        }

        /// Move a file the way a person moves one in the Finder: the
        /// bytes and the stamp go with it, so its witness is unchanged.
        fn rename(&self, from: &str, to: &str) {
            let bytes = self.files.lock().unwrap().remove(Path::new(from)).unwrap();
            let stamp = self.stamps.lock().unwrap().remove(Path::new(from)).unwrap();
            self.files.lock().unwrap().insert(PathBuf::from(to), bytes);
            self.stamps.lock().unwrap().insert(PathBuf::from(to), stamp);
        }

        fn deny(&self, path: &str) {
            self.denied.lock().unwrap().insert(PathBuf::from(path));
        }

        /// Give the grant back, which is what a bookmark that resolves
        /// again does for a sandboxed read.
        fn allow(&self, path: &str) {
            self.denied.lock().unwrap().remove(Path::new(path));
        }

        /// Make the path one the platform will not even stat.
        fn wall_off(&self, path: &str) {
            self.walled.lock().unwrap().insert(PathBuf::from(path));
        }

        fn put(&self, path: &str, bytes: &[u8]) {
            let path = PathBuf::from(path);
            let mut tick = self.tick.lock().unwrap();
            *tick += 1;
            self.stamps.lock().unwrap().insert(path.clone(), *tick);
            self.files.lock().unwrap().insert(path, bytes.to_vec());
        }

        fn remove(&self, path: &str) {
            self.files.lock().unwrap().remove(Path::new(path));
        }
    }

    impl FileIo for MemoryIo {
        fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
            if self.denied.lock().unwrap().contains(path) {
                return Err(io::Error::from(io::ErrorKind::PermissionDenied));
            }
            self.files
                .lock()
                .unwrap()
                .get(path)
                .cloned()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }
        fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
            self.put(&path.to_string_lossy(), bytes);
            Ok(())
        }
        fn stat(&self, path: &Path) -> io::Result<FileWitness> {
            if self.walled.lock().unwrap().contains(path) {
                return Err(io::Error::from(io::ErrorKind::PermissionDenied));
            }
            let files = self.files.lock().unwrap();
            let bytes = files
                .get(path)
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
            Ok(FileWitness {
                dev: 7,
                ino: 11,
                size: bytes.len() as u64,
                mtime_ns: *self.stamps.lock().unwrap().get(path).unwrap_or(&0),
            })
        }
    }

    /// One clean file and one dirty one, which is the pair every
    /// property below needs.
    fn seeded() -> (MemoryIo, FileStore, FileId, FileId) {
        let io = MemoryIo::with("/clean.txt", b"clean body\n");
        io.put("/dirty.txt", b"dirty body\r\n");
        let mut store = FileStore::new();
        let clean = store.open(&io, Path::new("/clean.txt")).unwrap();
        let dirty = store.open(&io, Path::new("/dirty.txt")).unwrap();
        store.set_bookmark(dirty, vec![9, 8, 7, 0, 255]);
        assert!(store.apply_ops(
            dirty,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "typed ".into(),
            }],
            42_000,
        ));
        (io, store, clean, dirty)
    }

    #[test]
    fn magic_is_its_own() {
        assert_eq!(MAGIC, b"OTSDRFT1");
        assert_ne!(MAGIC.as_slice(), b"OTSSNAP4".as_slice());
        assert_ne!(MAGIC.as_slice(), b"OTSLEDR2".as_slice());
    }

    #[test]
    fn a_roster_round_trips_with_its_drafts() {
        let (_io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;

        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &bytes, 2_000).unwrap(), 2);

        let files = back.files();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path(), Path::new("/clean.txt"));
        assert!(!files[0].is_dirty());
        assert_eq!(
            files[0].text(),
            "",
            "a clean file records identity only, so its buffer comes back empty"
        );
        assert_eq!(files[1].path(), Path::new("/dirty.txt"));
        assert!(files[1].is_dirty());
        assert_eq!(files[1].text(), "typed dirty body\n");
        assert_eq!(files[1].bookmark(), &[9, 8, 7, 0, 255]);
        assert_eq!(files[1].line_ending(), LineEnding::Crlf);
        assert_eq!(files[1].last_edited_at(), 42);
        assert!(files[1].restored_from_draft());
        assert!(files.iter().all(|f| FileId::is_tagged(f.id().raw())));
    }

    #[test]
    fn an_undone_equal_text_take_theirs_settles_clean_after_relaunch() {
        let io = MemoryIo::with("/generation.txt", b"old\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/generation.txt")).unwrap();
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 3,
                },
                EditOp::Insert {
                    pos_u16: 0,
                    text: "same".into(),
                },
            ],
            4_000,
        ));
        io.put(
            "/generation.txt",
            &[&[0xEF, 0xBB, 0xBF][..], b"same\r\n"].concat(),
        );
        store.refresh_conflict(&io, id);
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\n");
        assert!(store.is_dirty(id));

        let bytes = emit(&store, 5_000).bytes;
        let (mut back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let file = &back.files()[0];
        let restored = file.id();
        assert_eq!(file.text(), "same\n");
        assert!(
            !file.is_dirty(),
            "a generation marker without its undo history cannot keep equal output dirty"
        );
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert!(file.has_bom());
        assert_eq!(
            file.bytes_to_write(),
            [&[0xEF, 0xBB, 0xBF][..], b"same\r\n"].concat(),
            "the restored save output is already byte-identical to disk"
        );
        assert_eq!(
            back.check(&io, restored),
            crate::files::ExternalState::Unchanged
        );
        assert!(
            !back.can_undo(restored),
            "undo history does not cross launch"
        );
        assert!(
            !back.can_redo(restored),
            "redo history does not cross launch"
        );
        back.save(&io, restored).unwrap();
        assert!(!back.is_dirty(restored), "Save remains available and clean");
    }

    #[test]
    fn an_undone_equal_text_take_theirs_settles_clean_after_mixed_endings_normalize() {
        let io = MemoryIo::with("/mixed.txt", b"old\nline\n");
        let mut store = FileStore::new();
        let id = store.open(&io, Path::new("/mixed.txt")).unwrap();
        assert!(store.apply_ops(
            id,
            &[
                EditOp::Delete {
                    pos_u16: 0,
                    len_u16: 3,
                },
                EditOp::Insert {
                    pos_u16: 0,
                    text: "same".into(),
                },
            ],
            4_000,
        ));
        io.put("/mixed.txt", b"same\nline\r\n");
        store.refresh_conflict(&io, id);
        store.take_theirs(&io, id).unwrap();
        assert!(store.undo(id).unwrap().applied);
        assert_eq!(store.text(id).unwrap(), "same\nline\n");

        let bytes = emit(&store, 5_000).bytes;
        let (mut back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let restored = back.files()[0].id();
        let file = back.file(restored).unwrap();
        assert!(
            !file.is_dirty(),
            "restored drafts compare the same normalized text baseline as Take theirs"
        );
        assert_eq!(file.bytes_to_write(), b"same\nline\n");
        assert_ne!(
            file.bytes_to_write(),
            io.files.lock().unwrap()[file.path()],
            "mixed endings still become uniform when a later save is requested"
        );
        assert!(!back.can_undo(restored));
        assert!(!back.can_redo(restored));

        // Accepted batches compare runs to the normalized baseline rather
        // than materializing save bytes, so returning to the draft text is
        // clean even though a later save will make the disk endings uniform.
        assert!(back.apply_ops(
            restored,
            &[EditOp::Insert {
                pos_u16: 9,
                text: "!".into(),
            }],
            6_000,
        ));
        assert!(back.is_dirty(restored));
        assert!(back.apply_ops(
            restored,
            &[EditOp::Delete {
                pos_u16: 9,
                len_u16: 1,
            }],
            7_000,
        ));
        assert!(!back.is_dirty(restored));
    }

    #[test]
    fn a_restored_draft_saves_the_text_it_came_back_with() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let mut back = FileStore::new();
        restore(&mut back, &bytes, 2_000).unwrap();
        let id = back.files()[1].id();
        assert_eq!(back.hydrate_one(&io, id, None).fate, HydrationFate::Kept);
        back.save(&io, id).unwrap();
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/dirty.txt")],
            b"typed dirty body\r\n".to_vec(),
            "the CRLF style and the draft both survived the relaunch"
        );
        assert!(!back.is_dirty(id));
    }

    #[test]
    fn an_empty_roster_round_trips() {
        let store = FileStore::new();
        let bytes = emit(&store, 5).bytes;
        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &bytes, 5).unwrap(), 0);
        assert!(back.files().is_empty());
    }

    #[test]
    fn a_restore_replaces_rather_than_appends() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1).bytes;
        let mut back = FileStore::new();
        back.open(&io, Path::new("/clean.txt")).unwrap();
        assert_eq!(restore(&mut back, &bytes, 1).unwrap(), 2);
        assert_eq!(back.files().len(), 2);
    }

    #[test]
    fn records_carrying_the_old_generation_field_still_restore() {
        // The shape a build in between wrote: one trailing boolean this
        // build neither reads nor grants any say over dirty state.
        let (io, store, _clean, _dirty) = seeded();
        let current = emit(&store, 1_000).bytes;
        let old = widen_first_record(&current, &[1]);
        let (back, notices) = relaunch(&io, &old);
        assert!(notices.is_empty());
        assert_eq!(back.files().len(), 2);
        assert!(!back.files()[0].is_dirty());
        assert!(back.files()[1].is_dirty());
        assert_eq!(back.files()[1].text(), "typed dirty body\n");
    }

    #[test]
    fn a_wrong_magic_is_refused_as_unknown() {
        let (_io, store, _clean, _dirty) = seeded();
        let mut bytes = emit(&store, 1).bytes;
        bytes[..8].copy_from_slice(b"OTSSNAP4");
        let mut back = FileStore::new();
        assert_eq!(
            restore(&mut back, &bytes, 1),
            Err(RestoreError::UnknownFormat)
        );
        assert!(back.files().is_empty());
    }

    #[test]
    fn a_short_buffer_is_refused_as_unknown() {
        let mut back = FileStore::new();
        assert_eq!(
            restore(&mut back, b"OTS", 1),
            Err(RestoreError::UnknownFormat)
        );
    }

    #[test]
    fn every_truncation_is_refused_and_leaves_the_store_alone() {
        let (_io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1).bytes;
        for cut in MAGIC.len()..bytes.len() {
            let mut back = FileStore::new();
            assert!(
                restore(&mut back, &bytes[..cut], 1).is_err(),
                "a buffer cut at {cut} must not read back"
            );
            assert!(back.files().is_empty(), "a refusal restores nothing");
        }
    }

    #[test]
    fn a_corrupt_count_is_refused() {
        let (_io, store, _clean, _dirty) = seeded();
        let mut bytes = emit(&store, 1).bytes;
        // The count sits after the magic and the wall stamp.
        bytes[16..24].copy_from_slice(&u64::MAX.to_le_bytes());
        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &bytes, 1), Err(RestoreError::Malformed));

        let mut bytes = emit(&store, 1).bytes;
        bytes[16..24].copy_from_slice(&3u64.to_le_bytes());
        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &bytes, 1), Err(RestoreError::Malformed));
    }

    #[test]
    fn a_tail_past_the_record_list_is_refused() {
        let (_io, store, _clean, _dirty) = seeded();
        let mut bytes = emit(&store, 1).bytes;
        bytes.push(0);
        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &bytes, 1), Err(RestoreError::Malformed));
    }

    #[test]
    fn a_trailing_field_inside_a_record_is_tolerated() {
        // A record written by a build that appended one field: the
        // frame states its own length, so this build reads the fields
        // it knows and steps over the rest.
        let (_io, store, _clean, _dirty) = seeded();
        let original = emit(&store, 1).bytes;
        let widened = widen_first_record(&original, &[0xAB, 0xCD]);
        let mut back = FileStore::new();
        assert_eq!(restore(&mut back, &widened, 1).unwrap(), 2);
        assert_eq!(back.files()[0].path(), Path::new("/clean.txt"));
        assert_eq!(back.files()[1].text(), "typed dirty body\n");
    }

    /// Append `extra` inside the first record's frame and restate the
    /// frame's length, which is exactly what a later build writing one
    /// more field would produce.
    fn widen_first_record(bytes: &[u8], extra: &[u8]) -> Vec<u8> {
        let head = MAGIC.len() + 8 + 8;
        let len = u64::from_le_bytes(bytes[head..head + 8].try_into().unwrap()) as usize;
        let body_at = head + 8;
        let mut out = Vec::new();
        out.extend_from_slice(&bytes[..head]);
        out.extend_from_slice(&((len + extra.len()) as u64).to_le_bytes());
        out.extend_from_slice(&bytes[body_at..body_at + len]);
        out.extend_from_slice(extra);
        out.extend_from_slice(&bytes[body_at + len..]);
        out
    }

    #[test]
    fn a_snapshot_the_decoder_refuses_is_refused_whole() {
        // The dirty file's frame ends with its snapshot, so restating
        // the frame's own length one byte shorter hands the decoder a
        // truncated blob. The whole restore fails and nothing lands.
        let (_io, store, _clean, dirty) = seeded();
        assert!(matches!(
            store.draft_body(dirty),
            crate::files::DraftBody::Snapshot(_)
        ));
        let bytes = emit(&store, 1).bytes;
        let mut back = FileStore::new();
        assert_eq!(
            restore(&mut back, &bytes[..bytes.len() - 1], 1),
            Err(RestoreError::Malformed)
        );
        assert!(back.files().is_empty());
    }

    // -----------------------------------------------------------------
    // The hydration: the second half of a restore, one case per branch
    // -----------------------------------------------------------------

    /// Restore the seeded roster into a fresh store and hydrate it
    /// against `io`, which the caller may have changed underneath.
    ///
    /// One file at a time through `hydrate_one`, at the recorded path,
    /// which is the route a shell with no bookmark to resolve takes. So
    /// every case in the table below is exercised through the per file
    /// entry point rather than through the loop over it.
    fn relaunch(io: &MemoryIo, bytes: &[u8]) -> (FileStore, Vec<FileNotice>) {
        let mut back = FileStore::new();
        restore(&mut back, bytes, 2_000).unwrap();
        let ids: Vec<FileId> = back.files().iter().map(OpenFile::id).collect();
        let mut notices = Vec::new();
        for id in ids {
            assert!(back.file(id).unwrap().pending_hydration());
            let outcome = back.hydrate_one(io, id, None);
            assert_eq!(outcome.rebind, PathRebind::Unmoved);
            match outcome.fate {
                HydrationFate::Kept => {
                    assert!(!back.file(id).unwrap().pending_hydration());
                }
                HydrationFate::Dropped => {
                    assert!(back.file(id).is_none());
                    assert!(outcome.notice.is_some(), "a dropped file is always named");
                }
                HydrationFate::Held => {
                    let file = back.file(id).unwrap();
                    assert!(file.pending_hydration(), "a held file is not settled");
                    assert!(file.access_refused());
                    assert!(outcome.notice.is_none(), "it is still in the roster");
                }
                other => panic!("a pending file was answered {other:?}"),
            }
            notices.extend(outcome.notice);
        }
        (back, notices)
    }

    /// Restore the seeded roster and stop there, with both files still
    /// pending: the clean one first and the dirty one second.
    fn restored_only(bytes: &[u8]) -> (FileStore, FileId, FileId) {
        let mut back = FileStore::new();
        restore(&mut back, bytes, 2_000).unwrap();
        let clean = back.files()[0].id();
        let dirty = back.files()[1].id();
        (back, clean, dirty)
    }

    #[test]
    fn a_restore_leaves_every_file_pending_and_reads_nothing() {
        let (_io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (back, clean, dirty) = restored_only(&bytes);
        assert!(back.file(clean).unwrap().pending_hydration());
        assert!(back.file(dirty).unwrap().pending_hydration());
        assert_eq!(back.text(clean).unwrap(), "", "nothing was read");
    }

    #[test]
    fn a_pending_file_refuses_every_route_that_would_move_it() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, dirty) = restored_only(&bytes);
        let typed = [EditOp::Insert {
            pos_u16: 0,
            text: "x".into(),
        }];
        for id in [clean, dirty] {
            assert_eq!(back.save(&io, id), Err(SaveError::PendingHydration));
            assert_eq!(
                back.save_as(&io, id, Path::new("/elsewhere.txt")),
                Err(SaveError::PendingHydration)
            );
            assert!(!back.apply_ops(id, &typed, 9_000));
            assert!(!back.apply_ops_as_new_step(id, &typed, 9_000));
            assert!(!back.undo(id).unwrap().applied);
            assert_eq!(
                back.reload(&io, id),
                Err(OpenRefusal::Io(io::ErrorKind::ResourceBusy))
            );
            assert_eq!(
                back.take_theirs(&io, id),
                Err(OpenRefusal::Io(io::ErrorKind::ResourceBusy))
            );
            assert!(!back.resolve_keep_mine(&io, id));
        }
        // Nothing was written anywhere and neither buffer moved. The
        // clean record's empty buffer is the one that matters: a save
        // that got through would have emptied the person's file.
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/clean.txt")],
            b"clean body\n".to_vec()
        );
        assert!(
            !io.files
                .lock()
                .unwrap()
                .contains_key(Path::new("/elsewhere.txt"))
        );
        assert_eq!(back.text(clean).unwrap(), "");
        assert_eq!(back.text(dirty).unwrap(), "typed dirty body\n");

        // A check while pending answers and decides nothing.
        io.put("/dirty.txt", b"somebody else wrote this\r\n");
        let _ = back.refresh_conflict(&io, dirty);
        assert_eq!(back.file(dirty).unwrap().conflict(), FileConflict::None);

        // And the hydration is what lifts the refusal.
        assert_eq!(back.hydrate_one(&io, clean, None).fate, HydrationFate::Kept);
        assert!(back.apply_ops(clean, &typed, 9_000));
        back.save(&io, clean).unwrap();
    }

    #[test]
    fn a_pending_file_still_takes_a_bookmark_and_a_close() {
        let (_io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, dirty) = restored_only(&bytes);
        assert!(back.set_bookmark(clean, vec![1, 2, 3]));
        assert_eq!(back.file(clean).unwrap().bookmark(), &[1, 2, 3]);
        assert!(back.close(dirty));
        assert_eq!(back.files().len(), 1);
    }

    #[test]
    fn hydrating_an_unknown_or_a_settled_file_changes_nothing() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, _dirty) = restored_only(&bytes);
        assert_eq!(
            back.hydrate_one(&io, FileId(crate::files::FILE_ID_TAG | 999), None)
                .fate,
            HydrationFate::UnknownFile
        );
        assert_eq!(back.hydrate_one(&io, clean, None).fate, HydrationFate::Kept);
        // Asked again, with a path that would otherwise rebind it: the
        // file is settled, so nothing is read and nothing moves.
        io.put("/other.txt", b"other\n");
        let again = back.hydrate_one(&io, clean, Some(Path::new("/other.txt")));
        assert_eq!(again.fate, HydrationFate::NotPending);
        assert_eq!(again.rebind, PathRebind::Unmoved);
        assert_eq!(back.file(clean).unwrap().path(), Path::new("/clean.txt"));
        assert_eq!(back.text(clean).unwrap(), "clean body\n");
    }

    #[test]
    fn a_file_moved_while_closed_is_rebound_to_where_it_is_now() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.rename("/clean.txt", "/moved/clean.txt");
        io.rename("/dirty.txt", "/moved/dirty.txt");
        let (mut back, clean, dirty) = restored_only(&bytes);

        let outcome = back.hydrate_one(&io, clean, Some(Path::new("/moved/clean.txt")));
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.rebind, PathRebind::Rebound);
        assert!(outcome.notice.is_none());
        let file = back.file(clean).unwrap();
        assert_eq!(file.path(), Path::new("/moved/clean.txt"));
        assert_eq!(file.text(), "clean body\n");
        assert!(
            !file.externally_reloaded(),
            "a move is not a change to the file"
        );

        // The dirty one keeps its draft and measures it against the
        // file where it now is, and its save lands there.
        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/moved/dirty.txt")));
        assert_eq!(outcome.rebind, PathRebind::Rebound);
        assert_eq!(back.file(dirty).unwrap().conflict(), FileConflict::None);
        back.save(&io, dirty).unwrap();
        let files = io.files.lock().unwrap();
        assert_eq!(
            files[Path::new("/moved/dirty.txt")],
            b"typed dirty body\r\n".to_vec()
        );
        assert!(!files.contains_key(Path::new("/dirty.txt")));
    }

    #[test]
    fn a_rebind_onto_a_path_another_open_file_holds_is_refused() {
        // The clean file was deleted and the dirty one moved into its
        // place while the app was closed, so the dirty record's
        // bookmark resolves to a path the clean record still holds.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, dirty) = restored_only(&bytes);
        // The holder is settled first, so its claim on the path is one
        // the disk has confirmed.
        assert_eq!(back.hydrate_one(&io, clean, None).fate, HydrationFate::Kept);

        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/clean.txt")));
        assert_eq!(outcome.rebind, PathRebind::Refused);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(
            back.file(dirty).unwrap().path(),
            Path::new("/dirty.txt"),
            "the recorded path stands"
        );
        assert_eq!(back.text(dirty).unwrap(), "typed dirty body\n");
        // The file that holds the path was not read again or moved by
        // somebody else's hydration.
        let other = back.file(clean).unwrap();
        assert_eq!(other.path(), Path::new("/clean.txt"));
        assert_eq!(other.text(), "clean body\n");
        let paths: HashSet<&Path> = back.files().iter().map(OpenFile::path).collect();
        assert_eq!(paths.len(), 2, "no two buffers share one path");
    }

    #[test]
    fn a_rebind_onto_a_pending_files_recorded_path_waits_and_decides_nothing() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, dirty) = restored_only(&bytes);

        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/clean.txt")));
        assert_eq!(outcome.fate, HydrationFate::Deferred);
        assert_eq!(outcome.rebind, PathRebind::Unmoved);
        assert!(outcome.notice.is_none());
        // Nothing was read and nothing moved, on either side.
        let waiting = back.file(dirty).unwrap();
        assert!(waiting.pending_hydration());
        assert_eq!(waiting.path(), Path::new("/dirty.txt"));
        assert_eq!(waiting.text(), "typed dirty body\n");
        let holder = back.file(clean).unwrap();
        assert!(holder.pending_hydration());
        assert_eq!(holder.path(), Path::new("/clean.txt"));
        // A file still waiting refuses everything a pending file does.
        assert_eq!(back.save(&io, dirty), Err(SaveError::PendingHydration));
        // The recorded path never defers, which is how a caller ends a
        // wait that would otherwise not end.
        assert_eq!(back.hydrate_one(&io, dirty, None).fate, HydrationFate::Kept);
    }

    /// The seeded pair after a chain of renames made while the app was
    /// closed: the dirty file stepped aside and the clean one took its
    /// name. Both bookmarks still resolve, each to where its file is.
    fn chained_renames() -> (MemoryIo, Vec<u8>) {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.rename("/dirty.txt", "/old.txt");
        io.rename("/clean.txt", "/dirty.txt");
        (io, bytes)
    }

    fn assert_both_found_after_the_chain(io: &MemoryIo, back: &mut FileStore, ids: [FileId; 2]) {
        let [clean, dirty] = ids;
        let file = back
            .file(clean)
            .expect("the clean file's bookmark found it");
        assert_eq!(file.path(), Path::new("/dirty.txt"));
        assert_eq!(file.text(), "clean body\n");
        assert!(!file.externally_reloaded());
        let file = back.file(dirty).unwrap();
        assert_eq!(file.path(), Path::new("/old.txt"));
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(file.text(), "typed dirty body\n");
        let paths: HashSet<&Path> = back.files().iter().map(OpenFile::path).collect();
        assert_eq!(paths.len(), 2, "no two buffers share one path");
        // Each save lands on the file its own buffer followed.
        back.save(io, dirty).unwrap();
        let files = io.files.lock().unwrap();
        assert_eq!(
            files[Path::new("/old.txt")],
            b"typed dirty body\r\n".to_vec()
        );
        assert_eq!(files[Path::new("/dirty.txt")], b"clean body\n".to_vec());
    }

    #[test]
    fn a_file_renamed_onto_a_name_another_moved_off_is_found_in_roster_order() {
        let (io, bytes) = chained_renames();
        let (mut back, clean, dirty) = restored_only(&bytes);

        // The clean file is asked first, while the dirty one still
        // carries the name it moved off. Refusing here is what used to
        // drop the clean file as missing.
        let first = back.hydrate_one(&io, clean, Some(Path::new("/dirty.txt")));
        assert_eq!(first.fate, HydrationFate::Deferred);
        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/old.txt")));
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.rebind, PathRebind::Rebound);
        // Asked again, the name is free.
        let again = back.hydrate_one(&io, clean, Some(Path::new("/dirty.txt")));
        assert_eq!(again.fate, HydrationFate::Kept);
        assert_eq!(again.rebind, PathRebind::Rebound);
        assert!(again.notice.is_none());

        assert_both_found_after_the_chain(&io, &mut back, [clean, dirty]);
    }

    #[test]
    fn a_file_renamed_onto_a_name_another_moved_off_is_found_in_the_other_order() {
        let (io, bytes) = chained_renames();
        let (mut back, clean, dirty) = restored_only(&bytes);

        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/old.txt")));
        assert_eq!(outcome.rebind, PathRebind::Rebound);
        let outcome = back.hydrate_one(&io, clean, Some(Path::new("/dirty.txt")));
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.rebind, PathRebind::Rebound);

        assert_both_found_after_the_chain(&io, &mut back, [clean, dirty]);
    }

    #[test]
    fn two_files_swapped_while_closed_each_wait_and_the_recorded_path_ends_it() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.rename("/dirty.txt", "/aside.txt");
        io.rename("/clean.txt", "/dirty.txt");
        io.rename("/aside.txt", "/clean.txt");
        let (mut back, clean, dirty) = restored_only(&bytes);

        // Each resolves to the other's recorded path, in either order.
        let at_dirty = Some(Path::new("/dirty.txt"));
        let at_clean = Some(Path::new("/clean.txt"));
        assert_eq!(
            back.hydrate_one(&io, clean, at_dirty).fate,
            HydrationFate::Deferred
        );
        assert_eq!(
            back.hydrate_one(&io, dirty, at_clean).fate,
            HydrationFate::Deferred
        );

        // The caller ends the wait by settling one at its recorded
        // path. The other's resolved path is then held by a settled
        // file and is refused in the ordinary way. Both stand, neither
        // shares a path, and no draft was lost: what each name holds
        // now is reported as a change to that name.
        let outcome = back.hydrate_one(&io, clean, None);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        let outcome = back.hydrate_one(&io, dirty, at_clean);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.rebind, PathRebind::Refused);

        let file = back.file(clean).unwrap();
        assert_eq!(file.path(), Path::new("/clean.txt"));
        assert!(file.externally_reloaded());
        let file = back.file(dirty).unwrap();
        assert_eq!(file.path(), Path::new("/dirty.txt"));
        assert_eq!(file.text(), "typed dirty body\n");
        assert_eq!(file.conflict(), FileConflict::Changed);
    }

    #[test]
    fn one_file_failing_to_hydrate_leaves_the_others_exactly_as_they_were() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/clean.txt");
        let (mut back, clean, dirty) = restored_only(&bytes);

        let outcome = back.hydrate_one(&io, clean, None);
        assert_eq!(outcome.fate, HydrationFate::Dropped);
        assert_eq!(outcome.notice.unwrap().reason, DroppedReason::Missing);
        assert!(back.file(clean).is_none());

        // The dirty file is still there, still pending, still holding
        // its draft, and hydrates as if nothing beside it had failed.
        let file = back.file(dirty).unwrap();
        assert!(file.pending_hydration());
        assert_eq!(file.text(), "typed dirty body\n");
        let outcome = back.hydrate_one(&io, dirty, None);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert!(outcome.notice.is_none());
        assert!(back.is_dirty(dirty));
        assert_eq!(back.file(dirty).unwrap().conflict(), FileConflict::None);
    }

    #[test]
    fn a_read_refused_for_want_of_a_grant_holds_a_clean_record_and_keeps_a_draft() {
        // What a sandbox answers for a file nobody granted: the stat
        // works and the read does not.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        io.deny("/dirty.txt");
        let (back, notices) = relaunch(&io, &bytes);
        assert!(
            notices.is_empty(),
            "nothing was dropped, so nothing is named"
        );
        assert_eq!(back.files().len(), 2);

        // The clean record is held: in the roster, marked access
        // refused, and with nothing in its buffer passed off as the
        // file's text.
        let held = &back.files()[0];
        assert_eq!(held.path(), Path::new("/clean.txt"));
        assert!(held.pending_hydration());
        assert!(held.access_refused());
        assert_eq!(held.text(), "");
        assert!(!held.is_dirty());

        let file = &back.files()[1];
        assert!(!file.pending_hydration());
        assert_eq!(file.text(), "typed dirty body\n", "the draft is not lost");
        assert!(file.is_dirty());
        assert_eq!(file.conflict(), FileConflict::Changed);
        assert!(file.access_refused(), "so take theirs has nothing to take");
    }

    #[test]
    fn a_held_record_refuses_every_write_and_a_later_hydration_settles_it() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let held = back.files()[0].id();
        let typed = [EditOp::Insert {
            pos_u16: 0,
            text: "x".into(),
        }];
        assert_eq!(back.save(&io, held), Err(SaveError::PendingHydration));
        assert_eq!(
            back.save_as(&io, held, Path::new("/elsewhere.txt")),
            Err(SaveError::PendingHydration)
        );
        assert!(!back.apply_ops(held, &typed, 9_000));
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/clean.txt")],
            b"clean body\n".to_vec(),
            "an empty buffer never reached the file"
        );

        // Asked again while the read is still refused: still held.
        assert_eq!(back.hydrate_one(&io, held, None).fate, HydrationFate::Held);

        // The grant comes back, and the same question settles it. The
        // mark goes with the first read that succeeds.
        io.allow("/clean.txt");
        let outcome = back.hydrate_one(&io, held, None);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        let file = back.file(held).unwrap();
        assert!(!file.pending_hydration());
        assert!(!file.access_refused());
        assert_eq!(file.text(), "clean body\n");
        assert!(back.apply_ops(held, &typed, 9_000));
    }

    #[test]
    fn a_held_record_that_then_goes_missing_is_dropped_and_named() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let held = back.files()[0].id();
        io.remove("/clean.txt");
        let outcome = back.hydrate_one(&io, held, None);
        assert_eq!(outcome.fate, HydrationFate::Dropped);
        assert_eq!(outcome.notice.unwrap().reason, DroppedReason::Missing);
        assert!(back.file(held).is_none());
    }

    #[test]
    fn a_held_record_goes_back_out_and_is_asked_afresh_at_the_next_launch() {
        // The mark is not persisted. The record is written as the clean
        // identity it is, and the next launch finds out for itself.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        let (held, _notices) = relaunch(&io, &bytes);
        let again = emit(&held, 3_000).bytes;
        io.allow("/clean.txt");
        let (back, notices) = relaunch(&io, &again);
        assert!(notices.is_empty());
        let file = &back.files()[0];
        assert!(!file.pending_hydration());
        assert!(!file.access_refused());
        assert_eq!(file.text(), "clean body\n");
    }

    #[test]
    fn a_held_file_holds_its_path_like_a_settled_one() {
        // A second record's bookmark resolves to the held file's path.
        // The holder has been asked and is staying put, so the answer
        // is a refusal and not a wait that nothing would ever end.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        let (mut back, clean, dirty) = restored_only(&bytes);
        assert_eq!(back.hydrate_one(&io, clean, None).fate, HydrationFate::Held);
        let outcome = back.hydrate_one(&io, dirty, Some(Path::new("/clean.txt")));
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.rebind, PathRebind::Refused);
        assert_eq!(back.file(dirty).unwrap().path(), Path::new("/dirty.txt"));
    }

    #[test]
    fn opening_the_path_of_a_pending_record_is_refused_until_it_is_hydrated() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, clean, _dirty) = restored_only(&bytes);
        // Handing back the pending id would raise a tab over a buffer
        // nobody has read, so the open says the file is busy instead.
        assert_eq!(
            back.open(&io, Path::new("/clean.txt")),
            Err(OpenRefusal::Io(io::ErrorKind::ResourceBusy))
        );
        assert_eq!(back.files().len(), 2, "and it opened no second buffer");
        assert_eq!(back.hydrate_one(&io, clean, None).fate, HydrationFate::Kept);
        assert_eq!(back.open(&io, Path::new("/clean.txt")), Ok(clean));
    }

    // -----------------------------------------------------------------
    // Relocation: the person says where the file is
    // -----------------------------------------------------------------

    #[test]
    fn a_draft_relocated_onto_the_file_it_was_measured_against_stands_with_no_conflict() {
        // Moved while the app was closed, with no bookmark to follow
        // it: the record comes back in a missing conflict, and the
        // person points at the file where it is now.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.rename("/dirty.txt", "/moved/dirty.txt");
        let (mut back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let id = back.files()[1].id();
        assert_eq!(back.file(id).unwrap().conflict(), FileConflict::Missing);

        assert_eq!(
            back.relocate(&io, id, Path::new("/moved/dirty.txt")),
            Ok(None)
        );
        let file = back.file(id).unwrap();
        assert_eq!(file.path(), Path::new("/moved/dirty.txt"));
        assert_eq!(file.conflict(), FileConflict::None, "the same generation");
        assert_eq!(file.text(), "typed dirty body\n", "the draft stands");
        assert!(file.is_dirty());
        assert!(!file.access_refused());

        // Dirtiness is truthful from here: back at the file's own text
        // reads as clean, and the save lands where the file is.
        assert!(back.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 6,
            }],
            50_000,
        ));
        assert!(!back.is_dirty(id));
        assert!(back.apply_ops(
            id,
            &[EditOp::Insert {
                pos_u16: 0,
                text: "again ".into(),
            }],
            51_000,
        ));
        back.save(&io, id).unwrap();
        let files = io.files.lock().unwrap();
        assert_eq!(
            files[Path::new("/moved/dirty.txt")],
            b"again dirty body\r\n".to_vec()
        );
        assert!(!files.contains_key(Path::new("/dirty.txt")));
    }

    #[test]
    fn a_draft_relocated_onto_a_copy_with_the_same_text_stands_with_no_conflict() {
        // A copy is a new file with a new witness. The words are what
        // say it is the text the draft was measured against.
        let (io, mut store, _clean, dirty) = seeded();
        io.remove("/dirty.txt");
        assert_eq!(
            store.refresh_conflict(&io, dirty),
            crate::files::ExternalState::Missing
        );
        assert_eq!(store.file(dirty).unwrap().conflict(), FileConflict::Missing);
        io.put("/copy/dirty.txt", b"dirty body\r\n");

        assert_eq!(
            store.relocate(&io, dirty, Path::new("/copy/dirty.txt")),
            Ok(None)
        );
        let file = store.file(dirty).unwrap();
        assert_eq!(file.conflict(), FileConflict::None);
        assert_eq!(file.text(), "typed dirty body\n");
        assert!(file.is_dirty());
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        store.save(&io, dirty).unwrap();
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/copy/dirty.txt")],
            b"typed dirty body\r\n".to_vec()
        );
    }

    #[test]
    fn a_draft_relocated_onto_a_different_text_stands_in_a_conflict_that_can_be_taken() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/dirty.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let id = back.files()[1].id();
        assert!(back.file(id).unwrap().access_refused());
        // Nothing can be taken while the disk copy cannot be read.
        assert_eq!(
            back.take_theirs(&io, id),
            Err(OpenRefusal::Io(io::ErrorKind::PermissionDenied))
        );

        io.put("/found.txt", b"somebody else wrote this\n");
        assert_eq!(back.relocate(&io, id, Path::new("/found.txt")), Ok(None));
        let file = back.file(id).unwrap();
        assert_eq!(file.path(), Path::new("/found.txt"));
        assert_eq!(file.conflict(), FileConflict::Changed);
        assert!(!file.access_refused(), "the disk copy was read");
        assert_eq!(file.text(), "typed dirty body\n", "the draft stands");
        assert_eq!(back.save(&io, id), Err(SaveError::Conflict));

        // And take theirs now has something to take.
        back.take_theirs(&io, id).unwrap();
        assert_eq!(back.text(id).unwrap(), "somebody else wrote this\n");
        assert!(!back.is_dirty(id));
    }

    #[test]
    fn a_clean_file_relocated_adopts_the_disk_copy() {
        let (io, mut store, clean, _dirty) = seeded();
        // The same file, moved: adopted and nothing to say.
        io.rename("/clean.txt", "/moved/clean.txt");
        assert_eq!(
            store.relocate(&io, clean, Path::new("/moved/clean.txt")),
            Ok(None)
        );
        let file = store.file(clean).unwrap();
        assert_eq!(file.path(), Path::new("/moved/clean.txt"));
        assert_eq!(file.text(), "clean body\n");
        assert!(!file.is_dirty());
        assert!(!file.externally_reloaded(), "a move is not a change");

        // A different text: adopted all the same, and the view moved,
        // so one reload notice is owed.
        io.put("/other.txt", b"another text\n");
        assert_eq!(
            store.relocate(&io, clean, Path::new("/other.txt")),
            Ok(None)
        );
        let file = store.file(clean).unwrap();
        assert_eq!(file.text(), "another text\n");
        assert!(!file.is_dirty());
        assert_eq!(file.conflict(), FileConflict::None);
        assert!(file.externally_reloaded());
    }

    #[test]
    fn a_held_record_is_settled_by_a_relocation() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let held = back.files()[0].id();
        io.rename("/clean.txt", "/granted/clean.txt");
        assert_eq!(
            back.relocate(&io, held, Path::new("/granted/clean.txt")),
            Ok(None)
        );
        let file = back.file(held).unwrap();
        assert!(!file.pending_hydration());
        assert!(!file.access_refused());
        assert_eq!(file.path(), Path::new("/granted/clean.txt"));
        assert_eq!(file.text(), "clean body\n");
        assert!(!file.is_dirty());
        back.save(&io, held).unwrap();
    }

    #[test]
    fn a_relocation_onto_a_path_another_open_file_holds_is_refused() {
        let (io, mut store, clean, dirty) = seeded();
        io.remove("/dirty.txt");
        let _ = store.refresh_conflict(&io, dirty);
        assert_eq!(
            store.relocate(&io, dirty, Path::new("/clean.txt")),
            Err(RelocateRefusal::PathInUse)
        );
        // Both files are exactly where and as they were.
        let file = store.file(dirty).unwrap();
        assert_eq!(file.path(), Path::new("/dirty.txt"));
        assert_eq!(file.conflict(), FileConflict::Missing);
        assert_eq!(file.text(), "typed dirty body\n");
        assert_eq!(store.text(clean).unwrap(), "clean body\n");
    }

    #[test]
    fn a_relocation_onto_a_file_that_will_not_open_leaves_the_record_as_it_was() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/clean.txt");
        io.deny("/dirty.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let held = back.files()[0].id();
        let dirty = back.files()[1].id();
        io.put("/binary.bin", &[0x66, 0x6f, 0xFF, 0xFE]);
        io.put("/huge.txt", &vec![b'a'; crate::files::FILE_SIZE_LIMIT + 1]);

        for id in [held, dirty] {
            assert_eq!(
                back.relocate(&io, id, Path::new("/binary.bin")),
                Err(RelocateRefusal::Open(OpenRefusal::NotUtf8))
            );
            assert_eq!(
                back.relocate(&io, id, Path::new("/huge.txt")),
                Err(RelocateRefusal::Open(OpenRefusal::TooLarge {
                    limit: crate::files::FILE_SIZE_LIMIT
                }))
            );
            assert_eq!(
                back.relocate(&io, id, Path::new("/nowhere.txt")),
                Err(RelocateRefusal::Open(OpenRefusal::Io(
                    io::ErrorKind::NotFound
                )))
            );
        }
        let file = back.file(held).unwrap();
        assert_eq!(file.path(), Path::new("/clean.txt"));
        assert!(file.pending_hydration());
        assert!(file.access_refused());
        let file = back.file(dirty).unwrap();
        assert_eq!(file.path(), Path::new("/dirty.txt"));
        assert_eq!(file.conflict(), FileConflict::Changed);
        assert!(file.access_refused());
        assert_eq!(file.text(), "typed dirty body\n");

        assert_eq!(
            back.relocate(
                &io,
                FileId(crate::files::FILE_ID_TAG | 999),
                Path::new("/x")
            ),
            Err(RelocateRefusal::UnknownFile)
        );
    }

    #[test]
    fn a_relocation_spends_a_standing_keep_mine() {
        // The consent was to overwrite one divergence at one path. A
        // different file at a different path is a new question.
        let (io, mut store, _clean, dirty) = seeded();
        io.put("/dirty.txt", b"somebody else wrote this\r\n");
        let _ = store.refresh_conflict(&io, dirty);
        assert!(store.resolve_keep_mine(&io, dirty));
        io.put("/third.txt", b"a third text\n");
        assert_eq!(
            store.relocate(&io, dirty, Path::new("/third.txt")),
            Ok(None)
        );
        assert_eq!(store.file(dirty).unwrap().conflict(), FileConflict::Changed);
        assert_eq!(store.save(&io, dirty), Err(SaveError::Conflict));
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/third.txt")],
            b"a third text\n".to_vec()
        );
    }

    // -----------------------------------------------------------------
    // The access refused mark on a live file
    // -----------------------------------------------------------------

    #[test]
    fn a_refused_stat_marks_a_live_file_and_the_next_read_that_works_clears_it() {
        let (io, mut store, _clean, dirty) = seeded();
        io.wall_off("/dirty.txt");
        assert_eq!(
            store.refresh_conflict(&io, dirty),
            crate::files::ExternalState::Changed
        );
        let file = store.file(dirty).unwrap();
        assert!(file.access_refused());
        assert_eq!(file.conflict(), FileConflict::Changed);

        // The stat answers again and the read does not, which is the
        // sandbox's own shape: the mark stays, and so does the
        // conflict, though the stat now matches the witness.
        io.walled.lock().unwrap().clear();
        io.deny("/dirty.txt");
        assert_eq!(
            store.refresh_conflict(&io, dirty),
            crate::files::ExternalState::Unchanged
        );
        let file = store.file(dirty).unwrap();
        assert!(file.access_refused());
        assert_eq!(file.conflict(), FileConflict::Changed);
        assert_eq!(store.save(&io, dirty), Err(SaveError::Conflict));

        // The read works again, and the check is what notices.
        io.allow("/dirty.txt");
        assert_eq!(
            store.refresh_conflict(&io, dirty),
            crate::files::ExternalState::Unchanged
        );
        let file = store.file(dirty).unwrap();
        assert!(!file.access_refused());
        assert_eq!(file.conflict(), FileConflict::None);
    }

    #[test]
    fn a_draft_whose_read_the_platform_refused_stays_in_its_conflict_through_every_check() {
        // A relaunch under a sandbox with the grant gone: the stat
        // answers and matches the witness the record carried, and the
        // read is refused. The hydration and the check that follows it
        // on the first activation must say the same thing.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/dirty.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let id = back.files()[1].id();
        assert_eq!(back.file(id).unwrap().conflict(), FileConflict::Changed);

        for _ in 0..2 {
            assert_eq!(
                back.refresh_conflict(&io, id),
                crate::files::ExternalState::Unchanged,
                "the stat is the one the record was measured against"
            );
            let file = back.file(id).unwrap();
            assert!(file.access_refused());
            assert_eq!(file.conflict(), FileConflict::Changed);
            assert_eq!(back.save(&io, id), Err(SaveError::Conflict));
        }
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/dirty.txt")],
            b"dirty body\r\n".to_vec(),
            "nothing was written over a copy nobody read"
        );

        // Keep mine is one of the ways out, and it survives the check
        // the shell makes before the save it licenses.
        assert!(back.resolve_keep_mine(&io, id));
        let _ = back.refresh_conflict(&io, id);
        assert_eq!(back.file(id).unwrap().conflict(), FileConflict::None);
        back.save(&io, id).unwrap();
        assert!(!back.file(id).unwrap().access_refused());
    }

    #[test]
    fn a_read_that_works_again_ends_the_conflict_a_refused_read_began() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.deny("/dirty.txt");
        let (mut back, _notices) = relaunch(&io, &bytes);
        let id = back.files()[1].id();
        io.allow("/dirty.txt");
        let _ = back.refresh_conflict(&io, id);
        let file = back.file(id).unwrap();
        assert!(!file.access_refused());
        assert_eq!(file.conflict(), FileConflict::None);
        assert!(file.is_dirty());
    }

    // -----------------------------------------------------------------
    // The not found mark
    // -----------------------------------------------------------------

    #[test]
    fn a_clean_file_that_goes_missing_is_marked_and_the_mark_goes_when_it_is_found() {
        let (io, mut store, clean, _dirty) = seeded();
        assert!(!store.file(clean).unwrap().not_found());
        io.rename("/clean.txt", "/moved/clean.txt");
        assert_eq!(
            store.refresh_conflict(&io, clean),
            crate::files::ExternalState::Missing
        );
        let file = store.file(clean).unwrap();
        assert!(file.not_found());
        assert_eq!(
            file.conflict(),
            FileConflict::None,
            "a clean file never enters a conflict, so the mark is all there is"
        );

        // Back at its path: the next check clears it.
        io.rename("/moved/clean.txt", "/clean.txt");
        let _ = store.refresh_conflict(&io, clean);
        assert!(!store.file(clean).unwrap().not_found());

        // Gone again, and located somewhere else: the read clears it.
        io.rename("/clean.txt", "/moved/clean.txt");
        let _ = store.refresh_conflict(&io, clean);
        assert!(store.file(clean).unwrap().not_found());
        assert_eq!(
            store.relocate(&io, clean, Path::new("/moved/clean.txt")),
            Ok(None)
        );
        assert!(!store.file(clean).unwrap().not_found());
    }

    #[test]
    fn a_missing_draft_is_marked_beside_its_conflict_and_a_save_clears_the_mark() {
        let (io, mut store, _clean, dirty) = seeded();
        io.remove("/dirty.txt");
        let _ = store.refresh_conflict(&io, dirty);
        let file = store.file(dirty).unwrap();
        assert!(file.not_found());
        assert_eq!(file.conflict(), FileConflict::Missing);
        assert!(store.resolve_keep_mine(&io, dirty));
        let _ = store.refresh_conflict(&io, dirty);
        assert!(store.file(dirty).unwrap().not_found(), "still gone");
        store.save(&io, dirty).unwrap();
        assert!(!store.file(dirty).unwrap().not_found());
    }

    // -----------------------------------------------------------------
    // A save never makes a file where there is none
    // -----------------------------------------------------------------

    #[test]
    fn a_save_of_a_clean_file_that_is_gone_is_refused_and_nothing_is_recreated() {
        // No check ran first. The save looks at the path itself, so a
        // caller that skipped the check is refused the same way.
        let (io, mut store, clean, _dirty) = seeded();
        io.remove("/clean.txt");
        assert_eq!(store.save(&io, clean), Err(SaveError::NotFound));
        assert!(
            !io.files
                .lock()
                .unwrap()
                .contains_key(Path::new("/clean.txt")),
            "the file a person deleted stays deleted"
        );
        let file = store.file(clean).unwrap();
        assert!(file.not_found(), "the refusal leaves the mark standing");
        assert!(!file.access_refused());
        assert_eq!(
            file.conflict(),
            FileConflict::None,
            "a clean file never enters a conflict"
        );
        assert_eq!(file.text(), "clean body\n", "the buffer is as it was");

        // Asked again after a check, the answer is the same one.
        let _ = store.refresh_conflict(&io, clean);
        assert_eq!(store.save(&io, clean), Err(SaveError::NotFound));

        // Back at its path, the save is an ordinary save again.
        io.put("/clean.txt", b"clean body\n");
        store.save(&io, clean).unwrap();
        assert!(!store.file(clean).unwrap().not_found());
    }

    #[test]
    fn a_save_of_a_draft_whose_file_is_gone_is_refused_and_enters_the_missing_conflict() {
        let (io, mut store, _clean, dirty) = seeded();
        io.remove("/dirty.txt");
        // Again with no check first, so the conflict is the save's own
        // finding.
        assert_eq!(store.save(&io, dirty), Err(SaveError::NotFound));
        assert!(
            !io.files
                .lock()
                .unwrap()
                .contains_key(Path::new("/dirty.txt")),
            "nothing was recreated"
        );
        let file = store.file(dirty).unwrap();
        assert!(file.not_found());
        assert!(file.is_dirty(), "the draft stands");
        assert_eq!(file.text(), "typed dirty body\n");
        assert_eq!(file.conflict(), FileConflict::Missing);
        // From here the standing conflict is what refuses.
        assert_eq!(store.save(&io, dirty), Err(SaveError::Conflict));

        // Keep mine is the consent that licenses making the file again,
        // and it licenses exactly one save.
        assert!(store.resolve_keep_mine(&io, dirty));
        store.save(&io, dirty).unwrap();
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/dirty.txt")],
            b"typed dirty body\r\n".to_vec()
        );
        io.remove("/dirty.txt");
        assert_eq!(
            store.save(&io, dirty),
            Err(SaveError::NotFound),
            "the consent was spent on the save it was given for"
        );
    }

    #[test]
    fn a_save_as_still_writes_a_file_that_is_gone_somewhere_new_or_back_where_it_was() {
        // Save as is a destination a person chose, so it is the way
        // out that makes a file, at a new path or at the old one.
        let (io, mut store, clean, _dirty) = seeded();
        io.remove("/clean.txt");
        assert_eq!(store.save(&io, clean), Err(SaveError::NotFound));
        store.save_as(&io, clean, Path::new("/clean.txt")).unwrap();
        assert_eq!(
            io.files.lock().unwrap()[Path::new("/clean.txt")],
            b"clean body\n".to_vec()
        );
        assert!(!store.file(clean).unwrap().not_found());
    }

    #[test]
    fn a_draft_restored_over_a_missing_file_is_marked_not_found() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/dirty.txt");
        let (back, _notices) = relaunch(&io, &bytes);
        let file = &back.files()[1];
        assert_eq!(file.conflict(), FileConflict::Missing);
        assert!(file.not_found());
        assert!(!file.access_refused());
    }

    // -----------------------------------------------------------------
    // A relocation that changes no word keeps the undo history
    // -----------------------------------------------------------------

    #[test]
    fn a_saved_file_that_was_only_moved_keeps_its_undo_history_through_the_rebind() {
        let (io, mut store, _clean, dirty) = seeded();
        store.save(&io, dirty).unwrap();
        assert!(!store.is_dirty(dirty));
        assert!(store.can_undo(dirty), "the typing is still a step");

        io.rename("/dirty.txt", "/moved/dirty.txt");
        let _ = store.refresh_conflict(&io, dirty);
        assert_eq!(
            store.relocate(&io, dirty, Path::new("/moved/dirty.txt")),
            Ok(None)
        );
        let file = store.file(dirty).unwrap();
        assert_eq!(file.path(), Path::new("/moved/dirty.txt"));
        assert!(!file.is_dirty());
        assert!(!file.externally_reloaded());
        assert!(
            store.can_undo(dirty),
            "a move that changed no word must not empty the undo stack"
        );
        assert!(store.undo(dirty).unwrap().applied);
        assert_eq!(store.text(dirty).unwrap(), "dirty body\n");
        assert!(store.is_dirty(dirty), "and dirtiness is still truthful");
    }

    #[test]
    fn a_copy_with_the_same_text_keeps_the_history_and_takes_the_copys_own_line_ending() {
        // A new file with a new witness and the same words, written
        // with the other line ending. The document stands and what
        // describes the disk copy is refreshed.
        let (io, mut store, _clean, dirty) = seeded();
        store.save(&io, dirty).unwrap();
        io.put("/copy.txt", b"typed dirty body\n");
        assert_eq!(store.relocate(&io, dirty, Path::new("/copy.txt")), Ok(None));
        let file = store.file(dirty).unwrap();
        assert_eq!(file.line_ending(), LineEnding::Lf);
        assert!(!file.is_dirty());
        assert!(store.can_undo(dirty));
        // The witness is the copy's, so the next check finds no change.
        assert_eq!(
            store.refresh_conflict(&io, dirty),
            crate::files::ExternalState::Unchanged
        );
    }

    #[test]
    fn the_draft_a_take_theirs_set_aside_is_still_one_undo_away_after_the_file_moves() {
        let (io, mut store, _clean, dirty) = seeded();
        io.put("/dirty.txt", b"theirs\n");
        let _ = store.refresh_conflict(&io, dirty);
        store.take_theirs(&io, dirty).unwrap();
        assert_eq!(store.text(dirty).unwrap(), "theirs\n");
        assert!(!store.is_dirty(dirty));

        io.rename("/dirty.txt", "/moved/dirty.txt");
        assert_eq!(
            store.relocate(&io, dirty, Path::new("/moved/dirty.txt")),
            Ok(None)
        );
        assert!(store.can_undo(dirty));
        assert!(store.undo(dirty).unwrap().applied);
        assert_eq!(
            store.text(dirty).unwrap(),
            "typed dirty body\n",
            "the draft that was set aside comes back"
        );
        assert!(
            store.is_dirty(dirty),
            "and it is a draft again, over the copy that was taken"
        );
    }

    #[test]
    fn a_clean_file_relocated_onto_a_different_text_still_starts_a_fresh_document() {
        let (io, mut store, _clean, dirty) = seeded();
        store.save(&io, dirty).unwrap();
        io.put("/other.txt", b"another text\n");
        assert_eq!(
            store.relocate(&io, dirty, Path::new("/other.txt")),
            Ok(None)
        );
        assert_eq!(store.text(dirty).unwrap(), "another text\n");
        assert!(
            !store.can_undo(dirty),
            "the old steps are not steps of this text"
        );
    }

    #[test]
    fn a_refused_reload_marks_a_clean_file_and_absence_is_the_other_state() {
        let (io, mut store, clean, _dirty) = seeded();
        io.deny("/clean.txt");
        assert_eq!(
            store.reload(&io, clean),
            Err(OpenRefusal::Io(io::ErrorKind::PermissionDenied))
        );
        let file = store.file(clean).unwrap();
        assert!(file.access_refused());
        assert_eq!(file.text(), "clean body\n", "the buffer is as it was");

        // Gone is not access refused: it is missing, and says so instead.
        io.remove("/clean.txt");
        assert_eq!(
            store.refresh_conflict(&io, clean),
            crate::files::ExternalState::Missing
        );
        assert!(!store.file(clean).unwrap().access_refused());

        // Bytes that were reached and will not open are not a failure
        // to reach them either.
        io.allow("/clean.txt");
        io.put("/clean.txt", &[0x66, 0x6f, 0xFF, 0xFE]);
        assert_eq!(store.reload(&io, clean), Err(OpenRefusal::NotUtf8));
        assert!(!store.file(clean).unwrap().access_refused());
    }

    #[test]
    fn a_save_clears_the_mark() {
        let (io, mut store, _clean, dirty) = seeded();
        io.deny("/dirty.txt");
        assert!(store.take_theirs(&io, dirty).is_err());
        assert!(store.file(dirty).unwrap().access_refused());
        store.save(&io, dirty).unwrap();
        assert!(!store.file(dirty).unwrap().access_refused());
    }

    #[test]
    fn the_loop_over_every_pending_file_gathers_the_same_notices() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/clean.txt");
        let mut back = FileStore::new();
        restore(&mut back, &bytes, 2_000).unwrap();
        let notices = back.hydrate_restored(&io);
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].reason, DroppedReason::Missing);
        assert_eq!(back.files().len(), 1);
        assert!(!back.files()[0].pending_hydration());
        // A second pass finds nothing pending and says nothing.
        assert!(back.hydrate_restored(&io).is_empty());
    }

    #[test]
    fn a_pending_record_goes_back_out_exactly_as_it_came_in() {
        // A drafts save between the restore and the hydration, which a
        // key rotation can cause. Nothing may be lost to it, and the
        // record whose draft was too large must not come back as an
        // empty draft.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let stripped = strip_the_dirty_snapshot(&bytes);
        let (pending, _clean, _dirty) = restored_only(&stripped);
        let again = emit(&pending, 3_000);
        assert!(again.oversized.is_empty(), "the hydration owes that notice");

        let (back, notices) = relaunch(&io, &again.bytes);
        assert_eq!(back.files().len(), 2);
        assert_eq!(back.files()[1].text(), "dirty body\n");
        assert!(!back.files()[1].is_dirty());
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].reason, DroppedReason::DraftTooLarge);

        // And an ordinary pending draft survives the same round trip.
        let (pending, _clean, _dirty) = restored_only(&bytes);
        let (back, notices) = relaunch(&io, &emit(&pending, 3_000).bytes);
        assert!(notices.is_empty());
        assert_eq!(back.files()[1].text(), "typed dirty body\n");
        assert!(back.files()[1].is_dirty());
    }

    #[test]
    fn a_clean_file_that_did_not_change_comes_back_filled_and_quiet() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (back, notices) = relaunch(&io, &bytes);
        let file = &back.files()[0];
        assert_eq!(file.path(), Path::new("/clean.txt"));
        assert_eq!(file.text(), "clean body\n", "filled from disk");
        assert!(!file.is_dirty());
        assert!(!file.externally_reloaded(), "nothing to say about it");
        assert!(
            file.restored_from_draft(),
            "the tab still came from a draft"
        );
        assert!(notices.is_empty());
    }

    #[test]
    fn a_clean_file_that_changed_is_reloaded_and_says_so_once() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.put("/clean.txt", b"somebody else wrote this\n");
        let (mut back, notices) = relaunch(&io, &bytes);
        let id = back.files()[0].id();
        let file = back.file(id).unwrap();
        assert_eq!(file.text(), "somebody else wrote this\n");
        assert!(!file.is_dirty(), "a clean copy reloads without asking");
        assert_eq!(file.conflict(), crate::files::FileConflict::None);
        assert!(file.externally_reloaded(), "the shell owes one notice");
        assert!(notices.is_empty(), "a reload is not a dropped file");

        // Sticky: reading the roster twice does not lose it.
        assert!(back.file(id).unwrap().externally_reloaded());
        assert!(back.clear_reload_notice(id));
        assert!(!back.file(id).unwrap().externally_reloaded());
    }

    #[test]
    fn a_clean_file_that_went_away_is_dropped_and_named() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/clean.txt");
        let (back, notices) = relaunch(&io, &bytes);
        assert_eq!(back.files().len(), 1, "the dirty file came back regardless");
        assert_eq!(back.files()[0].path(), Path::new("/dirty.txt"));
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].name, "clean.txt");
        assert_eq!(notices[0].path, "/clean.txt");
        assert_eq!(notices[0].reason, DroppedReason::Missing);
    }

    #[test]
    fn a_clean_file_this_build_will_not_open_is_dropped_and_named() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.put("/clean.txt", &[0x66, 0x6f, 0xFF, 0xFE]);
        let (back, notices) = relaunch(&io, &bytes);
        assert_eq!(back.files().len(), 1);
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].name, "clean.txt");
        assert_eq!(notices[0].reason, DroppedReason::Unreadable);
    }

    #[test]
    fn a_dirty_file_over_an_unchanged_disk_copy_measures_itself_truthfully() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let (mut back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let id = back.files()[1].id();
        let file = back.file(id).unwrap();
        assert_eq!(file.text(), "typed dirty body\n", "the draft stands");
        assert!(file.is_dirty());
        assert_eq!(file.conflict(), crate::files::FileConflict::None);
        assert_eq!(file.line_ending(), LineEnding::Crlf);
        assert_eq!(file.last_edited_at(), 42, "the draft's own age survived");

        // The saved text is known now, so stepping the draft back to
        // what the file holds reads as clean rather than staying dirty.
        assert!(back.apply_ops(
            id,
            &[EditOp::Delete {
                pos_u16: 0,
                len_u16: 6,
            }],
            50_000,
        ));
        assert_eq!(back.text(id).unwrap(), "dirty body\n");
        assert!(!back.is_dirty(id), "back at the file's own text is clean");
    }

    #[test]
    fn a_dirty_file_over_a_changed_disk_copy_stands_in_a_conflict() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.put("/dirty.txt", b"somebody else wrote this\r\n");
        let (mut back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let id = back.files()[1].id();
        assert_eq!(back.text(id).unwrap(), "typed dirty body\n");
        assert!(back.is_dirty(id));
        assert_eq!(
            back.file(id).unwrap().conflict(),
            crate::files::FileConflict::Changed
        );
        assert_eq!(back.save(&io, id), Err(crate::files::SaveError::Conflict));
        // And the three resolutions still work from here.
        assert!(back.resolve_keep_mine(&io, id));
        back.save(&io, id).unwrap();
    }

    #[test]
    fn a_dirty_file_whose_file_went_away_keeps_its_draft() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/dirty.txt");
        let (back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty(), "a draft is never dropped silently");
        let file = &back.files()[1];
        assert_eq!(file.text(), "typed dirty body\n");
        assert!(file.is_dirty());
        assert_eq!(file.conflict(), crate::files::FileConflict::Missing);
    }

    #[test]
    fn a_dirty_file_this_build_will_not_open_keeps_its_draft() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.put("/dirty.txt", &[0xFF, 0xFE, 0x00]);
        let (back, notices) = relaunch(&io, &bytes);
        assert!(notices.is_empty());
        let file = &back.files()[1];
        assert_eq!(file.text(), "typed dirty body\n");
        assert!(file.is_dirty());
        assert_eq!(
            file.conflict(),
            crate::files::FileConflict::Changed,
            "take theirs is not on offer, so keep mine or save as it is"
        );
    }

    #[test]
    fn one_unreadable_file_never_fails_the_restore_whole() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        io.remove("/clean.txt");
        io.remove("/dirty.txt");
        let (back, notices) = relaunch(&io, &bytes);
        // The clean one is gone from the roster, the dirty one stands
        // in a conflict, and neither took the other down.
        assert_eq!(back.files().len(), 1);
        assert_eq!(back.files()[0].path(), Path::new("/dirty.txt"));
        assert_eq!(notices.len(), 1);
    }

    #[test]
    fn hydration_leaves_a_file_that_was_never_restored_alone() {
        let (io, mut store, clean, _dirty) = seeded();
        let notices = store.hydrate_restored(&io);
        assert!(notices.is_empty());
        assert_eq!(store.files().len(), 2);
        assert_eq!(store.text(clean).unwrap(), "clean body\n");
    }

    // -----------------------------------------------------------------
    // The drafts size bound
    // -----------------------------------------------------------------

    #[test]
    fn the_bound_is_four_times_the_file_size_limit() {
        assert_eq!(
            crate::files::DRAFT_SNAPSHOT_LIMIT,
            4 * crate::files::FILE_SIZE_LIMIT
        );
    }

    #[test]
    fn a_draft_over_the_bound_is_left_out_and_the_file_still_comes_back() {
        // Editing a file long enough grows its operation log past the
        // bound even though the file itself is far under the size
        // limit: a snapshot is history, not text. Rather than build a
        // 16 MiB log, the property is exercised through the one place
        // the bound is read.
        let (io, store, _clean, dirty) = seeded();
        assert!(
            matches!(store.draft_body(dirty), DraftBody::Snapshot(_)),
            "an ordinary draft is well under the bound"
        );

        // Emit with the bound in force, then hand the restore a record
        // shaped exactly as an over-bound draft leaves one: dirty, and
        // carrying no snapshot.
        let bytes = emit(&store, 1_000).bytes;
        let stripped = strip_the_dirty_snapshot(&bytes);
        let (back, notices) = relaunch(&io, &stripped);

        assert_eq!(back.files().len(), 2, "the file itself still came back");
        let file = &back.files()[1];
        assert_eq!(file.path(), Path::new("/dirty.txt"));
        assert_eq!(file.text(), "dirty body\n", "filled from disk instead");
        assert!(!file.is_dirty(), "there is no draft to be dirty against");
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].name, "dirty.txt");
        assert_eq!(notices[0].reason, DroppedReason::DraftTooLarge);
    }

    #[test]
    fn a_held_record_whose_draft_was_left_out_still_reads_dirty_and_holds_nothing() {
        // The one way a held file reads dirty: its draft was over the
        // bound, so the record is dirty and carries no snapshot, and
        // the platform then refuses the read. The flag is kept because
        // the record must go back out as it came. The shell is what
        // has to know there is no draft behind it, and this is the
        // state it is told about.
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let stripped = strip_the_dirty_snapshot(&bytes);
        io.deny("/dirty.txt");
        let (mut back, notices) = relaunch(&io, &stripped);
        assert!(notices.is_empty(), "nothing is said until the file is read");
        let id = back.files()[1].id();
        let held = back.file(id).unwrap();
        assert!(held.pending_hydration());
        assert!(held.access_refused());
        assert!(held.is_dirty(), "dirty in name only");
        assert_eq!(held.text(), "", "there is no draft in the buffer");
        assert_eq!(held.conflict(), FileConflict::None);
        assert_eq!(back.save(&io, id), Err(SaveError::PendingHydration));

        // Once it can be read it settles clean, and the notice for the
        // draft that was left out is said then.
        io.allow("/dirty.txt");
        let outcome = back.hydrate_one(&io, id, None);
        assert_eq!(outcome.fate, HydrationFate::Kept);
        assert_eq!(outcome.notice.unwrap().reason, DroppedReason::DraftTooLarge);
        let file = back.file(id).unwrap();
        assert!(!file.is_dirty());
        assert_eq!(file.text(), "dirty body\n");
    }

    /// Rewrite the second record with its snapshot slot emptied and the
    /// dirty flag left standing: what emit writes for a draft it would
    /// not carry.
    fn strip_the_dirty_snapshot(bytes: &[u8]) -> Vec<u8> {
        let head = MAGIC.len() + 8 + 8;
        let first_len = u64::from_le_bytes(bytes[head..head + 8].try_into().unwrap()) as usize;
        let second = head + 8 + first_len;
        let second_len = u64::from_le_bytes(bytes[second..second + 8].try_into().unwrap()) as usize;
        let body = &bytes[second + 8..second + 8 + second_len];
        // Walk the fixed fields to find the flag rather than guess it.
        let mut reader = Reader { buf: body, pos: 0 };
        reader.bytes().unwrap(); // bookmark
        reader.bytes().unwrap(); // path
        reader.u8().unwrap(); // has_witness
        reader.u64().unwrap(); // dev
        reader.u64().unwrap(); // ino
        reader.u64().unwrap(); // size
        reader.bytes().unwrap(); // mtime
        reader.u8().unwrap(); // line ending
        reader.u8().unwrap(); // bom
        reader.u8().unwrap(); // dirty
        reader.u64().unwrap(); // last edited
        let flag_at = reader.pos;

        let mut trimmed = body[..flag_at].to_vec();
        trimmed.push(0);
        let mut out = Vec::new();
        out.extend_from_slice(&bytes[..second]);
        out.extend_from_slice(&(trimmed.len() as u64).to_le_bytes());
        out.extend_from_slice(&trimmed);
        out.extend_from_slice(&bytes[second + 8 + second_len..]);
        out
    }

    #[test]
    fn a_sheet_id_never_reaches_a_restored_file() {
        // The store hands out tagged ids and nothing else, on the
        // restore path as much as on the open path, which is what keeps
        // a page id from ever addressing a file.
        let (_io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1).bytes;
        let mut back = FileStore::new();
        restore(&mut back, &bytes, 1).unwrap();
        assert!(back.files().iter().all(|f| FileId::is_tagged(f.id().raw())));
        for untagged in [0, 1, 2, u64::MAX >> 1] {
            assert!(back.file(FileId(untagged)).is_none());
            assert!(!back.is_dirty(FileId(untagged)));
        }
    }
}
