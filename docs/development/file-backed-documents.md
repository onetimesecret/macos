---
# docs/development/file-backed-documents.md
---

# File-backed document implementation

A file backed document is a file on disk that the pad edits. It is a
peer to a page, not a page: both are first class content, and a file
has no TTL, no gauge, no day, no slot on the strip and no path to the
sync relay. The decision is
[ADR-0028](../adr/0028-file-backed-documents-are-a-peer-content-class.md),
still proposed; the behaviour is the
[file backed documents specification](../spec/feature/file-editing/README.md).
How a sandboxed build reaches a person's file is
[ADR-0035](../adr/0035-sandboxed-file-access-holds-a-scope-around-core-io.md),
also proposed.
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
                                 the access brackets, the staging
                                 directory
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
and the hydration that follows a restore fills it from disk (see
"Restore is two steps" below).

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

## The access brackets

A build signed with `scripts/Companion.entitlements` is sandboxed, and
the template declares `com.apple.security.files.user-selected.read-write`
for the files a person chooses. A build signed without a provisioning
profile gets no entitlements and is not sandboxed. One code path serves
both: nothing in the shell or the core asks which it is running in.

Under the sandbox the core can read, stat or write a person's file only
while a security scope on that file is open, and only the shell can
open one. So every call that makes the core touch such a file runs
inside a bracket, and the brackets all live in `FileCoordinator`:

- `withAccess(toBookmark:)` resolves a bookmark with
  `.withSecurityScope`, starts the scope, runs the body and stops the
  scope. Resolution and access are one function, so no caller can take
  the first and forget the second. A bookmark that will not resolve as
  a scoped one is tried again as a plain one, which is what every
  record written before this change holds; the body then runs with no
  scope. Nil means nothing resolved and the body did not run. Both
  resolutions pass `.withoutUI` and `.withoutMounting`, so a file on a
  volume that is not mounted reads as missing. That is decided
  (ADR-0035): a launch or an activation must not raise a dialog or
  mount a volume by itself.
- `withAccess(to:)` brackets a URL a panel or a drop handed over.
- `withStagingDirectory(for:)` hands the body a directory to stage a
  save in and removes it afterwards.
- `bookmark(for:)` makes a security scoped bookmark and throws when it
  cannot. It must be called while access to the file is open.

The start and stop go through the `SecurityScoping` protocol, which the
coordinator takes at init. The stop is made only for a start that
answered true. `FileAccessTests.swift` injects a recording pair and
asserts, per operation, that the core's call happened between a start
and its stop.

`PageModel` reaches the brackets five ways:

- `withFileAccess(_:_:)` is the helper for an open file. It fetches the
  file's bookmark from the core, brackets the body, and renews a
  bookmark that resolved stale. The body is handed the URL the bookmark
  resolved to. With no bookmark, or one that resolves to nothing, the
  body runs unbracketed and is handed nil. `saveFile(_:)`,
  `checkOpenFilesOnActivate()` and the keep mine and take theirs arms
  of `resolveConflict(_:)` go through it. `applyCheck(for:resolved:)`
  opens no bracket of its own; both of its callers hold one and pass
  that URL on.
- `openFile(at:)` uses the panel bracket around the core's read and the
  first bookmark.
- `saveActiveFileAs()` uses the panel bracket around the write and the
  new bookmark. Choosing the file's own name there, while something is
  at that path, calls `saveFile(_:)` inside the panel bracket, so two
  brackets nest and each closes what it opened. With nothing at the
  path it goes on as a save as and writes the file.
- `locateFile(_:)` uses the panel bracket around the core's relocation
  and the bookmark that replaces the old one.
- `hydrateRestoredFile(_:)` brackets each restored file at launch, and
  each held file again on activation.

**A new call that makes the core read, stat or write a person's file
must go through one of these.** Nothing enforces it but review and the
counting tests, and outside a sandbox a missing bracket changes
nothing you can see.

Every `NSOpenPanel` and `NSSavePanel` lives in `FileCoordinator` too,
behind the `FilePanels` protocol, and the default under the test runner
is `RefusingFilePanels`: a modal panel reached by a suite that never
meant to raise one does not fail the run, it hangs it.

### The bookmark is made again after every save

A save replaces the file with a new one at the same path, and the
measurements in ADR-0035 found that a bookmark made before the save
stops resolving once the file is moved. So `saveFile(_:)` and
`saveActiveFileAs()` each make a fresh bookmark inside the bracket,
after the write, and hand it to the core. After a save the bookmark is
made from the URL the scope is on when that is the path the core wrote,
and from the roster path otherwise.

When a bookmark cannot be made, at open or after a save, the operation
stands and `bookmarkFailureNotice(name:)` is flashed: "X may not reopen
after a relaunch, because access to it could not be kept." The keymap
file is exempt (`owesBookmark(path:)`), because it sits in the app's
own configuration directory. A renewal that fails during a restore or
inside `withFileAccess` is logged and not flashed.

A failed renewal normally leaves the file holding its old bookmark.
The exception is when the old bookmark no longer names the file at the
core's path: after a Save As, after a Locate, and after a save that
wrote at the recorded path while the bookmark resolved somewhere else.
There the old bookmark is cleared
(`renewBookmark(for:from:orphansHeld:)`), because the next launch would
otherwise follow it and bind the tab back to the file the person left.

A bookmark renewed outside a save, at restore or because it resolved
stale inside `withFileAccess`, marks the drafts file as owed a write
through `markDraftsRecordMoved()`. That helper arms the save and
nothing else: it does not count as a mutation since load and takes no
termination hold.

## Restore is two steps

`companion_drafts_restore` opens the drafts file and puts the records
back. It reads no file of the person's. Every row it leaves carries
`pendingHydration`, and the core refuses an edit, a save, a Save As, a
reload and both conflict resolutions on a pending file
(`SaveError::PendingHydration` for the saves). Reading or setting the
bookmark, relocating the file and closing it still work.

`companion_file_hydrate` is the second step, once per pending file, and
it is the step that reads the disk. `FileStore::hydrate_one` in
`crates/core/src/files.rs` holds the case table, which is the six
outcomes of ADR-0028 and two more for a read the platform refused. The
steps are separate because only the shell can open the scope each read
needs.

`PageModel.restoreDrafts()` does both before it publishes the roster.
The one pending row a surface can then draw is a held file (see "Held
files and Locate" below). For each pending row,
`hydrateRestoredFile(_:)`:

1. resolves the file's bookmark and opens its bracket;
2. calls hydrate with the path the bookmark resolved to. A path that
   differs from the recorded one rebinds the file before the read, so a
   file moved while the app was closed is found where it is now. A
   bookmark that resolves inside a Trash (`FileCoordinator.isInTrash`)
   is not followed: hydrate is called with nil, the recorded path is
   read, and the file is missing in the ordinary way;
3. renews the bookmark inside the bracket when it came back stale, was
   a plain one, or the file moved, and only when the roster row's path
   now equals the resolved path.

The last condition is how the shell hears about a refused rebind. The
core refuses to rebind onto a path another settled or held file holds,
hydrates at the recorded path instead, and returns the same bool either
way; the unchanged roster path is the only signal.

A hydration can also wait. When the resolved path is the recorded path
of a file that is still pending, the core decides nothing
(`HydrationFate::Deferred`): it returns true and the row stays
`pendingHydration`. That file may have been moved off the path, and a
refusal would make the outcome depend on roster order. `restoreDrafts()`
therefore runs in passes over the rows still waiting, and a pass that
settles none, which is files that traded names, is ended by
`settleCrossedFiles(_:)`: every file still waiting is hydrated at its
recorded path with nil, inside the brackets of all of their bookmarks
at once. Each file's bookmark leads to where its file went, which is
another waiting file's recorded path, so the scope that lets a file be
read at its own recorded path is some other file's. One forced file
would send the rest to their recorded paths anyway, and read one
bracket at a time every one of them would be refused under the sandbox.
Each file that settles is then given a bookmark made from the URL whose
scope is on its path; if that cannot be made the old one is kept, and
the next launch ends the same crossing the same way.

When the restore leaves the roster different from the drafts file (a
file dropped, rebound, given a new bookmark, read again from a changed
disk copy, or a draft reported too large), `restoreDrafts()` leaves
`draftsDirty` set and arms a save. Otherwise the next launch would
repeat the work and the notices, and a bookmark the system called stale
would never be replaced on disk.

A file with no bookmark, or one that resolves to nothing, is hydrated
with a nil path and no scope. Outside a sandbox that reads the recorded
path. Inside one the read is refused, which the core marks as access
refused: a clean record is held and a dirty one keeps its draft in a
`changed` conflict with `accessRefused` set. Read
`companion_drafts_notices_json` after every hydration has run, not
straight after the restore.

`FileStore::hydrate_restored` remains as a loop over `hydrate_one` with
no resolved path, for a caller with no bookmarks to resolve. The key
rotation does not hydrate: it re-emits the store, and a pending dirty
record whose draft was left out for size goes back out as it came in
(`DraftBody::AlreadyDropped`).

An open never lands on a pending row. `openFile(at:)` hydrates any
pending row at the path first, inside the panel bracket, and then
opens. The core is the backstop: `companion_file_open` on a path a
pending row holds returns 0 with an `io` error.

## Held files and Locate

The core keeps one more fact per open file: `accessRefused`
(`OpenFile::access_refused()` in the core, `FileSummary.accessRefused`
in Swift), in the roster row and never in the drafts file. It is set
when the platform refuses a read or a stat for any reason other than
the file's absence (`refusal_is_unreachable` in
`crates/core/src/files.rs`). It is cleared by the next read that
succeeds, by a look that finds nothing at the path, and by a save.
While it stands, `companion_file_check` follows a stat that answers
with one probe read, because a sandbox lets an ungranted path be
statted and not read.

Two words that never mean each other. `accessRefused` is the standing
mark above, for a file the platform would not let the core reach.
`unreadable` is a drafts notice reason (`DroppedReason::Unreadable`,
`DraftNoticeReason.unreadable`), for a clean record dropped at launch
because its bytes were read and will not open: not UTF-8, binary
looking, or past the size limit. Only a platform refusal holds a clean
record. The comment on the last arm of `FileStore::hydrate_one` says
why: bytes that will not open would be refused wherever the file was
pointed, so a hold would give the person nothing to do.

A **held** file is a restored record with no draft to show whose read
the platform refused (`HydrationFate::Held`). `companion_file_hydrate`
returns true and the row keeps `pendingHydration` and gains
`accessRefused`; Swift reads the pair as `FileSummary.isHeld`. Its
buffer is empty, the core refuses every edit and save, the editor is
mounted read only, and `FileUnavailableBanner` says "NAME cannot be
read at PATH" with Locate… and Close. A save or a Save As asked of it
flashes `heldFileNotice(name:)`.

A held row is neither saved nor unsaved. `FileHeaderState.derive`
gives it the word `not read` (`FileHeaderState.notReadWord`) with no
dot, no draft stamp and no format facts, and `FileRowLabel` says the
same word. Its record can still read dirty, when the draft was too
large to seal and was left out, so everything that asks whether a row
holds typing reads `FileSummary.holdsUnsavedEdits` (`isDirty` and not
`isHeld`) and not `isDirty`: `closeFile`, `closeActiveFile`, the
pending close withdrawal, the unsaved dots on the strip and the rail,
and the sentences about drafts lost at quit or at risk. A held row
therefore closes at once and never raises the dirty close decision.

`checkOpenFilesOnActivate()` hydrates each
held row again (`retryHeldFile(_:)`), so a grant or a permission that
came back is noticed without a gesture, and a held file that has since
gone from its path is dropped and named.

The roster row carries a second mark, `notFound`: the core's last look
at the path found nothing there. A check sets it on a clean row as on a
dirty one, a refused save sets it too (see "A save never makes a file"
below), and the next stat or read that finds something, or a save that
writes, clears it. A clean file never enters a conflict, so `notFound` is what
keeps `FileUnavailableBanner` up for a clean file that is gone, saying
"NAME is no longer at PATH" with Locate… and Close. The banner stands
for `FileSummary.isUnavailable`: no conflict, and either mark. That
includes a dirty file after keep mine, where the conflict is answered
and the file still cannot be reached. `applyCheck` says "is no longer
at its path" once, when the file is first found gone; while the mark
stands the banner is saying it and later activations stay quiet.

A dirty file that is `accessRefused` stays in the `changed` conflict
through every check (`refresh_conflict`), even when the stat matches
the witness, until a read succeeds or keep mine, Save As or Locate
answers it. That is what makes the conflict hydration sets for a
refused read last past the first activation.

`FileSummary` derives what the surface offers: `offersLocate` for a
missing conflict, a `notFound` row or an `accessRefused` file, and
`offersTakeTheirs` for a file that is neither `accessRefused` nor in
the missing conflict. `FileConflictBanner.actions(for:)` is the pure
list:

| the file | the actions, in order |
| --- | --- |
| changed | Keep mine, Take theirs, Save As |
| missing | Locate…, Keep mine, Save As |
| `accessRefused`, in a conflict | Locate…, Keep mine, Save As |

The accepted UI record counts three actions and two sentence inputs
(D-17 in `docs/spec/design/2026-0915-ui-ux-decisions.md`). The
amendment that would cover Locate, the unavailable banner and the held
header is a draft awaiting ratification,
[2026-0930-file-conflict-locate.md](../spec/design/2026-0930-file-conflict-locate.md).

A take theirs the core refuses restates the roster before it returns,
because the refused read may have just set `accessRefused` or
`notFound` and the banner has to stop offering the action that failed.

`locateFile(_:)` raises the panel through
`FileCoordinator.chooseFileToLocate(recordedPath:)`, which starts in
the recorded path's directory and puts the name in the panel's message,
since an open panel has no name field. Everything after the panel runs
inside `withAccess(to:)` on the chosen URL:

1. a path another open file holds is refused with
   `locateHeldNotice(name:holder:)`, asked of the roster before the
   core is. When that holder is itself held, it is hydrated first
   (`settleHeldHolder(_:at:)`): the panel's grant is on its path, which
   is what it was missing, so it settles and is given a bookmark from
   the panel's URL, and the refusal is said afterwards;
2. `companion_file_relocate` binds the file to the path, reads it and
   settles it through the routine hydration uses (`settle_over`). A
   file with no draft adopts the disk copy, with one exception: a live
   file whose disk copy holds the text it already holds keeps its
   document, so a file that was only moved keeps its undo history,
   including the step a take theirs left. A draft stands, with no
   conflict when the witness or the text matches what it was measured
   against and in a `changed` conflict otherwise. A standing keep mine
   is spent. False leaves the file exactly as it was, and a file that
   would not open is explained by `companion_file_open_error_json`;
3. the bookmark is made again from the chosen URL, and the old one is
   dropped if a new one cannot be made.

A cancel changes nothing. A Locate that succeeds says nothing, even
when a clean file's text changed: the reload flag is cleared without a
sentence because the person asked for that file.

`applyCheck(for:resolved:)` uses the same relocation with no panel.
When the check reports missing and the bracket's bookmark resolved to a
different path that is not in a Trash, the file is relocated there
inside the scope the caller holds (`settleRelocation(of:at:orphansHeld:)`),
the drafts file is marked as owed a write, and nothing is reported
missing. Unlike Locate, this route posts the reload notice when a clean
file's text differs. When the core refuses, the file is reported
missing as before.

`checkOpenFilesOnActivate()` does nothing while a file panel gesture is
under way or a `ModalSession` bracket is open. The main queue drains
while a panel is up, so the app can be activated underneath it, and the
check could then drop a held row or rebind a moved file that the
gesture is about. The check is recorded as owed and
`duringFilePanel(_:)`, which wraps `openFile()`, `saveActiveFileAs()`
and `locateFile(_:)`, makes it once the gesture has finished. Both
gestures that keep a row across the panel read it again when the panel
returns.

## A save never makes a file

`FileStore::save` stats the path itself, after the pending and conflict
refusals and before the write. When the stat answers not found and no
keep mine stands (`overwrite_next_save`), it writes nothing, clears
`access_refused`, sets `not_found`, puts a dirty file into
`FileConflict::Missing`, and returns `SaveError::NotFound`. The check
is in the core so a caller that skipped `companion_file_check` is
refused the same way. A stat error other than not found does not
refuse: the write goes ahead and reports for itself. `save_as` has no
such check.

A keep mine is bound to what it answered. `resolve_keep_mine` records
whether the path held a copy or nothing when the choice was made
(`keep_mine_over_absence`), and `withdraw_stale_consent`, called by
`save` and by `refresh_conflict`, drops the consent when the path is
found in the other state:

| the consent was given over | the path now holds | what happens |
| --- | --- | --- |
| a copy | a copy, the same or another | the save writes, as before |
| a copy | nothing | consent withdrawn, `SaveError::NotFound`, missing conflict |
| nothing | nothing | the save writes the file, once |
| nothing | a copy | consent withdrawn, `SaveError::Conflict`, changed conflict |

`resettle_dirty` also drops the consent whenever the buffer settles
clean, by an undo or by typing back to the saved text, so a file with
no unsaved edits is never made again on the strength of an old choice.
And `resolve_keep_mine` asked on a missing conflict whose file is back
at its path records no consent: it puts the file in the state a check
would find and returns false when that is a changed conflict.

A keep mine over a copy that changed cannot settle clean that way.
`resolve_keep_mine` refreshes the witness to the copy now on disk, and
when that copy is not the one the witness described it also sets
`saved_text` to `None` and the file dirty. The saved text was the
generation the disk no longer holds, so a buffer undone back to it is
not what is on disk, and measuring against it would call the file saved
while every check answered unchanged. With no saved text
`resettle_dirty` leaves the flag alone, as it does for a draft restored
beside a file that changed under it, so the file reads unsaved,
whatever it is edited or undone to, until the save the consent was
given for writes a baseline of its own. A keep mine over a missing file
keeps its saved text, and so does one given while the witness still
matched.

`companion_file_save` and `companion_file_save_as` return one bool, and
the core keeps the reason for a false until the next save.
`companion_file_save_error_json` reads it:

```json
{"error": "pendingHydration" | "conflict" | "notFound" | "pathInUse" | "unknownFile" | "write",
 "detail": "present only for write: the kind of I/O failure"}
```

It answers null when the last save wrote, when none has been asked for,
and when the save was refused for an argument the core could not read.
`CompanionClient.saveFileRefusal()` decodes it into `FileSaveRefusal`,
and `saveFile(_:)` asks for it straight after a false, before it
refreshes the roster. `PageModel.saveRefusalNotice(_:for:)` chooses the
sentence from the reason:

| the reason | the sentence |
| --- | --- |
| `conflict` | `unresolvedConflictNotice(for:)`, for the conflict the row is now in |
| `notFound`, row in the missing conflict | `unresolvedConflictNotice(for:)`, which offers keep mine |
| `notFound`, row in no conflict | `saveNotFoundNotice(name:)`: "NAME is no longer at its path, so it was not saved. Choose Locate to find it, or Save As to write it somewhere." |
| `pendingHydration` | `heldFileNotice(name:)` |
| `write`, any other reason, or none | `writeRefusalNotice(name:)`: "NAME could not be written." |

The row is read only to word the conflict, never to decide which
refusal it was. A row that is `notFound`, in no conflict and licensed by
a keep mine looks the same after a failed write as one refused for
being not found, and the reason is what tells them apart.

A save as chooses the same way through
`saveAsRefusalNotice(_:file:target:holder:)`: `pathInUse` is
`pathInUseNotice(name:)` naming the tab that holds the path,
`pendingHydration` is `heldFileNotice(name:)`, and anything else is
`writeRefusalNotice(name:)` for the chosen name. The shell no longer
looks for the holding tab before it asks; the core refuses, and the
roster is read afterwards only for the holder's name.

Before the core is asked, `saveFile(_:)` refuses a row standing in the
changed conflict from the roster, and runs `applyCheck` for every other
row, a row in the missing conflict included: a file that another tool
put back is then judged as the file it is, saved when it is the copy
the draft was measured against and put in the changed conflict when it
is not. When the check leaves the row in a conflict the save is refused
with `unresolvedConflictNotice(for:)`, whether the check found the
conflict or only confirmed it.

In `saveActiveFileAsThroughPanel`, choosing the file's own name is
routed to `saveFile(_:)` only while `FileManager.fileExists` finds
something at the path. With nothing there the choice stays a save as,
so Save As back onto the old path writes the file.

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

- A save rewrites the file through a temporary file and a rename
  (`write_atomic_preserving_mode` in `crates/ffi/src/files.rs`). The
  shell passes a staging directory to `companion_file_save` and
  `companion_file_save_as`, obtained from
  `FileCoordinator.withStagingDirectory(for:)`, and the temp file is
  made there, because a sandboxed process may not create a file beside
  a document it was granted. The shell passes nil only when no such
  directory can be had, and the temp file is then made beside the
  target, which is also what a caller with no shell gets. The core
  never falls back from one to the other: a staging directory that is
  missing, not writable or on another volume fails the save, the temp
  file is removed, and the shell flashes "X could not be written." with
  no retry.
- The temp file is given the mode of the file already there through
  its open descriptor (`carry_identity`), so the umask does not strip a
  bit, and a mode that will not set fails the save. The group is put
  back best effort. A target that does not exist yet has no group to
  carry, so the temp file is given the group a file created in the
  target's directory would take, also best effort. The new file
  is a new inode, so a second hard link keeps the old text and extended
  attributes do not survive.
- A read is bracketed by two stats and retried when they disagree, so a
  file rewritten mid read is refused rather than opened half old.
- A buffer holds one line ending style, so saving a file with mixed line
  endings makes it uniform. This is a real change the person did not
  ask for, and it is documented on the line ending type.
- `FileStore` holds a second copy of every open file's text, bounded per
  file by `FILE_SIZE_LIMIT` and unbounded in the number of open files.
  Nothing caps how many files may be open, and since issue #158 nothing
  caps how many pages may be either.
- Tests derive every path from the seamed state directory and never
  spell it. Do not write a test that touches the installed state
  directory.
