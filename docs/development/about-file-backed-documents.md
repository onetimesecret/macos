# docs/development/about-file-backed-documents.md
---

A file backed document is a file on disk that the pad edits. It is a
peer to a page, not a page: both are first class content, and a file
has no TTL, no gauge, no day, no place in the nine page cap and no path
to the sync relay. The decision is
[ADR-0028](../adr/0028-file-backed-documents-are-a-peer-content-class.md),
still proposed; the behaviour is the
[file backed documents specification](../spec/feature/file-editing/README.md).
This note is the map for whoever next touches the code.

## The pieces, and where they live

```
crates/core/src/files.rs         FileStore, FileId, FILE_ID_TAG,
                                 FILE_SIZE_LIMIT, DRAFT_SNAPSHOT_LIMIT
crates/core/src/file_persist.rs  OTSDRFT1 emit and restore
crates/ffi/src/files.rs          the C entry points, RealFileIo,
                                 drafts sealing, reseal and erase
crates/ffi/include/companion_ffi.h  the declarations and their prose

shell/Sources/CompanionKit/FileCoordinator.swift  panels, bookmarks,
                                 the access bracket, the two alerts
shell/Sources/CompanionKit/CompanionClient.swift  the wrappers
shell/Sources/CompanionKit/FormFactor.swift       draftsFileURL
shell/Sources/CompanionKit/PageModel.swift        routing and actions
shell/Sources/CompanionKit/FileSurface.swift      the pure view logic
shell/Sources/CompanionKit/Keymap/CommandID.swift the two new ids
shell/Sources/OnetimePad/BackdropApp.swift        the File menu
```

## The tagged id

`FileId` is a `u64` with the high bit set: `FILE_ID_TAG = 1 << 63` in
`crates/core/src/files.rs`. Swift mirrors that constant once, in
`CompanionClient.swift`, with a comment on both sides pointing at the
other.

One number therefore says which store owns it, which is what makes the
routing a branch rather than a lookup. Every `companion_sheet_*` entry
point refuses a tagged id and returns its failure value, and there is a
Rust test that passes one down every page route. That guard is the
reason a file can never become a page by accident, and it is the first
thing to re-run if you add a page route.

It is also why the sync exclusion needs no code. Exactly one function
turns store state into relay payload, it reads `SheetStore`, and a file
lives in `FileStore`. There is no exclusion line to write and therefore
none to forget. Do not "helpfully" make files reachable from the sheet
store.

## drafts.sealed

A third sealed file beside `state.sealed` and `ledger.sealed`, with its
own plaintext magic `OTSDRFT1` and its own envelope magic, sealed under
the same content key as the page state. `crates/core/src/file_persist.rs`
uses the same framed encoder and the same strict envelope rule as the
content snapshot, so a drafts file handed to the state restore fails
authentication and the reverse fails too.

One record per open file: bookmark blob, last known path, witness, line
ending, byte order mark flag, dirty flag, last edit stamp, and for a
dirty file the document snapshot. A clean file records identity only,
and the restore fills it from disk.

The name is spelled in two places: `FormFactor.draftsFileURL(in:)` in
Swift, which owns it, and `DRAFTS_FILE_NAME` in `crates/ffi/src/files.rs`,
which is read by exactly one caller. That caller is the key rotation,
which is handed the state path and has to find the drafts file beside
it. **If you rename the file in Swift, rename it in Rust too, or the
rotation stops finding it and drafts quietly become unreadable.**

### Resealing on rotation and erase

Both rotation routes rewrite the drafts under the new halves in the same
operation, before the state write, and both are in `crates/ffi/src/lib.rs`:

- the explicit rotate and save always reseals;
- the content erase branches on the roster. An empty roster drops the
  drafts file. Any file open and it reseals instead.

That branch is load bearing. The erase fires automatically when the last
page tab goes, which is a page lifecycle event, and a person can be
holding a dirty file tab at that moment. The unconditional discard is a
different door, `companion_drafts_erase`, which is what the shell calls
when a person asks to discard.

A ledger clear arrives at the same erase entry point and must leave
drafts alone. The content file predicate on the outside of both branches
is what keeps that true.

There is no ordering that keeps drafts readable across the instant the
old key half is erased, because the new key does not exist until the old
one is gone. What the ordering decides is which file survives a crash in
that window, and drafts are written first on purpose.

## The access bracket

The app is not sandboxed. Its only entitlement is keychain access
groups, so bookmarks are plain URL bookmarks, which already track
renames and moves.

`FileCoordinator.withAccess(toBookmark:)` is resolution and the access
bracket in one function, so no caller can take the first and forget the
second. When the sandbox arrives with TestFlight, the security scoped
variant is a change inside that one function and nowhere else. Every
`NSOpenPanel` and `NSSavePanel` lives in `FileCoordinator` too, behind
the `FilePanels` protocol, and the default under the test runner is
`RefusingFilePanels`: a modal panel reached by a suite that never meant
to raise one does not fail the run, it hangs it.

## Routing in PageModel

`runs(of:)` is the single branch on the tag. `storage(for:)` and
`restateStorage` both go through it, so a storage built from one store
cannot be restated from the other. `applyOps`, `undoEdit`, `redoEdit`
and `syncDocument` route at the top, and `fileStep(_:_:)` sits beside
`step(sheet:)`.

Block metadata stamps are gated off for a tagged id in
`InkEditorView.restyle`, so the page's block query is never called with
a file id. A file has no block history and the pad is not inventing one.

The activation check is `checkOpenFilesOnActivate()`, called from both
activation routes in `BackdropApp.swift`, `applicationDidBecomeActive`
and `applicationShouldHandleReopen`, so one gesture cannot mean two
things depending on which it arrived at. The same check runs inside
`saveFile(_:)` before every write.

Undo and redo availability branches on the tag too:
`PageModel.canUndoEdit` and `canRedoEdit` call the file route for a
tagged id, so the Edit menu items grey themselves out correctly on a
file.

Drafts ride the same debounce and the same force save as the sealed
state, and the drafts leg runs before the content leg, so whatever a
rotation or an erase decides about them stands. `markFilesDirty` does
not go through `markDirty`, deliberately: the state licence stands down
when this session may not write the sealed page file, and that answer is
right for yesterday's pages and wrong for a file the person opened by
hand in this session.

## The keymap second readings

No new context. All four bindings are in `Editor`, in
`shell/Sources/CompanionKit/Resources/default-keymap.json`.

- `state::SaveNow` (cmd-s) writes the file when the active target is a
  file, and flushes sealed page state otherwise.
- `page::Close` (cmd-w) closes the file when the active target is a
  file, and closes the tab otherwise.
- `file::Open` (cmd-o) and `file::SaveAs` (cmd-shift-s) are the only new
  ids.

The raw strings of the first two are published contract, which is why
they gained a second reading instead of a second id. Both readings are
chosen by `PageModel.activeTarget`, so a person who rebinds either chord
keeps both meanings. The arms are in `KeymapRegistry.swift`, which is one
exhaustive switch: a new id without an arm does not build.

`BackdropApp.swift` gained the app's first `CommandMenu`, the File menu,
reading its chords from the keymap rather than spelling them.
`BundledKeymapTests.swift` holds a literal chord to command table that a
new binding must join.

## Two more places the tag decides something

Neither is in the routing section above, and both are easy to break
without noticing.

- **The day chord labels on the time rail.** `visibleTargets` draws
  files first in both modes and `select(index:)` indexes that array, so
  a day's chord is its own position offset by the number of open files.
  One pure function computes that offset, in `TimeRailView.swift`, and
  `indexOfSelection` applies the same offset in `PageModel.swift`.
  Numbering the days from zero would print command 1 beside today while
  command 1 selected the first file. If you change the draw order,
  change both.
- **A file is exempt from the storage prune.** The refresh drops the
  storage of every id that is not a live page, and a file is not one.
  The filter keeps a tagged id explicitly. Without that exemption the
  first refresh after a file opens drops the storage the one persistent
  text view is still laying out, every restate path then guards on a
  map entry that is gone and does nothing, and a take theirs reports
  the file was read again while the editor still shows the discarded
  draft. A file's storage is dropped by exactly one place, the close.

## Other things worth knowing before you change something

- A save rewrites the file through a temporary file in the same
  directory and a rename, taking the mode of the file already there. The
  new file is a new inode, so a second hard link keeps the old text and
  extended attributes do not survive.
- A read is bracketed by two stats and retried when they disagree, so a
  file rewritten mid read is refused rather than opened half old.
- A buffer holds one line ending style, so saving a file with mixed line
  endings makes it uniform. This is a real change the person did not
  ask for, and it is documented on the line ending type.
- `FileStore` holds a second copy of every open file's text, bounded per
  file by `FILE_SIZE_LIMIT` and unbounded in the number of open files,
  because a file is deliberately not counted against the nine page cap.
  Nothing caps how many files may be open.
- Tests derive every path from the seamed state directory and never
  spell it. Do not write a test that touches the installed state
  directory.
