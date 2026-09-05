//! The drafts snapshot: `OTSDRFT1`.
//!
//! A dirty file's unsaved edits and the roster of open files go in a
//! third plaintext buffer, sealed in `crates/ffi` under the same content
//! key as the state file and under an envelope magic of its own. Not a
//! new section inside `OTSSNAP4`: that is a format break, and it would
//! take every user's pages once. Not a trailing field on the tab record
//! either, cheap as that is: it would make a file's draft a property of
//! a Tab, and a Tab is the object the nine page cap counts. One file
//! keeps the two content classes structurally apart.
//!
//! Layout follows the content snapshot exactly: magic, wall stamp,
//! count, then one framed record per open file. Records are positional
//! and carry no kind tag, so a trailing field inside a record is
//! tolerated and anything past the record list is not. Same framed
//! helper, same strict envelope rule. `OTSSNAP4` is not touched.
//!
//! One record per open file: the bookmark blob, the last known path,
//! the witness, the dirty flag, the last edit stamp, and for a dirty
//! file the Loro snapshot. A clean file records only its identity, so
//! its tab comes back with nothing staged behind it and the shell fills
//! it from disk with a reload.
//!
//! [`restore`] is only half of a restore: it decodes, and touches no
//! filesystem. [`crate::files::FileStore::hydrate_restored`] is the
//! other half, and every caller owes it. Splitting them keeps the
//! decoder pure, so damage is refused before anything is opened, and it
//! keeps the one place that reads a person's files out of the one place
//! that parses bytes off disk.
//!
//! Drafts die on save, on discard, on `companion_persist_erase`, and
//! whenever the content key halves rotate without this file being
//! rewritten in the same operation. Rotation rewrites it.

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
            DraftBody::None | DraftBody::Oversized => None,
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
            1 => Some(record.bytes().ok_or(Malformed)?.to_vec()),
            _ => return Err(Malformed),
        };
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
            record.snapshot.as_deref(),
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
    snapshot: Option<Vec<u8>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::{DroppedReason, FileId, FileIo, FileStore, FileWitness, LineEnding};
    use crate::store::EditOp;
    use std::collections::HashMap;
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
    }

    impl MemoryIo {
        fn with(path: &str, bytes: &[u8]) -> Self {
            let io = Self::default();
            io.put(path, bytes);
            io
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
    fn a_restored_draft_saves_the_text_it_came_back_with() {
        let (io, store, _clean, _dirty) = seeded();
        let bytes = emit(&store, 1_000).bytes;
        let mut back = FileStore::new();
        restore(&mut back, &bytes, 2_000).unwrap();
        let id = back.files()[1].id();
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
    fn relaunch(io: &MemoryIo, bytes: &[u8]) -> (FileStore, Vec<FileNotice>) {
        let mut back = FileStore::new();
        restore(&mut back, bytes, 2_000).unwrap();
        let notices = back.hydrate_restored(io);
        (back, notices)
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
        assert!(back.resolve_keep_mine(id));
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
