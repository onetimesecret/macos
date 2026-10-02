# File drafts: what a crash must not cost, and what a page erase must not take

**Applies to:** OnetimePad, the dev bundle from `scripts/dev.sh`, built
from `feature/regular-text-files` or later. Case 2 empties the pad of
pages, so it must not be run against the installed copy: the dev bundle
runs as `dev.onetimesecret.pad.debug`, which gives it its own state directory and
its own Keychain service (ADR-0012), and the pages it loses are the
scratch pad's. Nothing here is release-specific, so a confirming run on
the installed copy is worth doing once on a pad you are willing to
lose, but it is not what this procedure asks for.
**Required by:**
[ADR-0028](../../adr/0028-file-backed-documents-are-a-peer-content-class.md),
the staged drafts clause and the resealing clause, and the
[file backed documents specification](../../spec/feature/file-editing/README.md).
Two claims in those records cannot be reached by any test in this
repository. A `kill -9` delivers no signal the app can handle, so no
in-process test can watch the draft survive it. And the automatic
content erase fires when the last page tab goes, which a headless suite
reaches only by calling the rotation directly rather than by the
predicate that fires it in the app.
**Owner:** delano.
**Status:** cases 1 and 2 passed on hardware 2026-09-05. Case 3's
former modal path passed then; rerun cases 2 through 5 for issue #172's
nonmodal interactions, with case 5 on its rewritten criteria (PR 180: a
clean buffer withdraws the close decision and keeps the tab). Re-run all cases when the drafts file's format
changes, when the content erase predicate moves, or before a release
that touches either.

This is the file side of
[`force-termination.md`](force-termination.md). That procedure asks what
a SIGKILL costs a page. This one asks what it costs a file the person
was editing but had not saved, and then asks whether emptying the pad of
pages takes that draft with it.

## Prerequisite: rebuild the dev bundle

The drafts file is new, so an older copy writes none.

```sh
pgrep -fl "\.build/.*OnetimePad"   # nothing should be running from .build/
scripts/dev.sh
```

The dev lane builds the core with the test seams in it (ADR-0018), which
is what `swift test` links against and is nothing this procedure
depends on either way. Before packaging a release afterwards, run
`scripts/install.sh`, which builds without the feature and refuses the
binary if a seam survived.

## Where to look

```sh
STATE=~/Library/Application\ Support/dev.onetimesecret.pad.debug.noindex
ls -la "$STATE"
```

Use `dev.onetimesecret.pad.noindex` in that path instead if you are
taking the confirming run on the installed copy.

Beside `state.sealed` and `ledger.sealed` there is now `drafts.sealed`
(`shell/Sources/CompanionKit/FormFactor.swift`, and its Rust counterpart
in `crates/ffi/src/files.rs`). It is written through the same temporary
file and rename as the others.

Prepare a scratch file outside the state directory:

```sh
printf 'line one\nline two\n' > /tmp/qa-draft.txt
```

Log lines reach the unified log the same way as elsewhere:

```sh
log show --last 30m --style compact --predicate \
  'subsystem == "dev.onetimesecret.pad.debug" && (category == "core" || category == "persistence")'
```

The subsystem is the running bundle id, so it is the dev lane's exactly
as the state directory is.

## Case 1: a kill with a dirty file open

1. Launch `dist/OnetimePad Debug.app`. Open `/tmp/qa-draft.txt` through File >
   Open. Confirm the tab appears in the FILES group, that it carries no
   countdown gauge, and that the header reads saved.
2. Type a distinctive line into the file, for example
   `DRAFT BEFORE THE KILL`. Confirm the orange unsaved dot appears on
   the file's tab and the header reads unsaved. Do not save.
3. Wait ten seconds so the debounce has landed, and confirm
   `drafts.sealed` exists and has a recent mtime.
4. Note the wall clock time. This is the draft's last edit time, and
   step 6 checks it.
5. `pkill -9 -f 'dist/OnetimePad Debug\.app'`, then `ls -la "$STATE"` and
   record every
   file present, in particular anything matching `*.[0-9a-f]*.tmp`.
6. Launch the app.

**Pass:** the file tab is back in the FILES group, the buffer holds the
line typed in step 2, the unsaved dot is still on the tab, and the
header states a last edit time matching step 4 rather than the launch
time. `cat /tmp/qa-draft.txt` shows the file on disk unchanged: two
lines, no `DRAFT BEFORE THE KILL`. Any temp file recorded in step 5 is
gone after launch.

**Fail:** the tab missing; the buffer back to the file's text with the
draft gone; the dot absent while the buffer differs from the file; a
last edit time stamped at launch, which would mean the age the header
reports is not the draft's; the file on disk written without a save,
which is the one thing this feature must never do; or a temp file still
present after launch.

## Case 2: emptying the pad of pages must not take the draft

The case the automatic content erase reaches. It fires when no tab holds
a page, which is a page lifecycle event, and a person can be holding a
dirty file tab at that moment.

The pages this case closes are gone afterwards. On the dev bundle they
are the dev pad's, which is the reason this procedure runs there; put a
page or two on it first so there is something for step 1 to close.

1. From case 1's state, with the dirty file still open and still
   unsaved, close every page tab until none remains.
2. Confirm from the log or from `ls -la "$STATE"` that the content erase
   ran: the key half file changes, and `drafts.sealed` is rewritten at
   the same time rather than removed.
3. Quit the app normally. Confirm no alert, sheet or notification
   appears, then relaunch it.

**Pass:** quit asks nothing; `drafts.sealed` is still present after
step 2; the file tab comes back after step 3; and the draft from case 1
is still in it with its unsaved dot. The pages are gone, which is what
closing them asked for.

**Fail:** `drafts.sealed` removed in step 2; the file tab returning
empty or clean; or the file tab absent entirely, which would mean a page
lifecycle event destroyed a person's unsaved file edits.

## Case 3: the draft ends when the tab does

The control for cases 1 and 2. A draft that survives everything would be
a different bug.

1. With the dirty file open, press cmd-w. Confirm a banner appears above
   the editor saying `qa-draft.txt has unsaved changes` and offering
   **Save file**, **Discard changes** and **Keep editing**, in that order.
   Confirm the editor remains usable while the banner stands and Keep
   editing is the default action.
2. Choose **Keep editing**. Confirm the banner goes away, the tab stays
   open and dirty, and no alert or modal session appeared.
3. Press cmd-w again and choose **Discard changes**.
4. Reopen `/tmp/qa-draft.txt`.

**Pass:** the reopened file holds the two lines on disk and nothing
else. The draft is gone, the header reads saved, and every close choice
was inline.

**Fail:** an alert or sheet; editing blocked while the choice stands;
the wrong action order or default; the tab closing after Keep editing;
or the discarded draft coming back, which would let a later cmd-s write
typing from a session the person had ended.

## Case 4: Take theirs is immediate and undoable

1. With `/tmp/qa-draft.txt` open, type `MINE` at the start and do not
   save.
2. In Terminal, replace the disk copy:

   ```sh
   printf 'THEIRS\n' > /tmp/qa-draft.txt
   ```

3. Activate OnetimePad. Confirm the conflict banner appears, then choose
   **Take theirs**.
4. Press cmd-z, then cmd-shift-z.

**Pass:** Take theirs presents no confirmation and immediately shows
`THEIRS`. Undo restores the buffer containing `MINE`; Redo shows
`THEIRS` again. The conflict is cleared after Take theirs.

**Fail:** any alert or confirmation; Take theirs leaving the old buffer
visible; Undo failing to restore it; Redo failing to reapply the disk
copy; or the conflict remaining after the replacement succeeds.

## Case 5: a clean buffer withdraws the banner and keeps the tab

The banner from case 3 offers three actions, and only those three close
the tab; a second cmd-w while it stands does nothing. Making the buffer
match the file by any
other route (saving, undoing back to the saved text, taking theirs on a
conflict) withdraws the decision instead, because the question it asked
no longer applies, and the tab stays open with its undo history intact.
Closing is the one step that cannot be undone, so nothing automatic may
take it. This case exists so a hardware pass reads the banner going
away with the tab still open as intended rather than as a stranded
decision. It is pinned by
`testSavingWhileADirtyCloseDecisionStandsWithdrawsTheDecisionAndKeepsTheTab`,
`testUndoingAPendingCloseBackToSavedTextWithdrawsTheDecisionAndKeepsRedo`,
`testTakingTheirsWhileADirtyCloseDecisionStandsWithdrawsTheDecisionAndKeepsUndo`
and
`testACleanFileWithAPendingCloseStaysOpenWithNoDecisionAndTheSideTablesPruned`
(`shell/Tests/CompanionKitTests/FileDocumentTests.swift`).

1. With `/tmp/qa-draft.txt` open, type a distinctive line and do not
   save. Press cmd-w and confirm the banner from case 3 appears.
2. Without touching the banner, press cmd-s.
3. In the same tab, type one distinctive line, press cmd-w to raise the
   banner again, and then press cmd-z until the buffer is back to the
   text on disk.
4. In the same tab, type `MINE` at the start and do not save.
   In Terminal, `printf 'THEIRS\n' > /tmp/qa-draft.txt`. Activate
   OnetimePad so the conflict banner appears, press cmd-w so the close
   banner stands alongside it, then choose **Take theirs**.

**Pass:** in each of steps 2, 3 and 4 the banner goes away and the tab
stays open with the file clean. After step 2, `cat /tmp/qa-draft.txt`
shows the line typed in step 1, because a save was asked for. After
step 3 the file on disk is unchanged and cmd-shift-z brings the typed
line back (Redo survived). After step 4, `THEIRS` is the only line on
disk, the conflict banner is gone, and cmd-z restores the buffer
containing `MINE` (Undo survived). In each step, a further cmd-w on the
clean tab closes it at once with no banner and no alert.

**Fail:** the tab closing on its own in any of the three steps; the
banner still standing after the buffer matches the file; Redo dead
after step 3 or Undo dead after step 4; step 3 or step 4 writing the
file; the conflict remaining after step 4; the further cmd-w raising a
banner on a clean tab or not closing it; or an alert or sheet anywhere
in the case.

## Results

First run 2026-09-05, on the dev bundle at `fb5e798`, all three original
cases passed. The two claims no test in this repository can reach were
therefore checked: a draft survives a `kill -9`, and emptying the pad of
pages reseals the drafts rather than taking them. The issue #172 manual
checks added to cases 2 and 3, and new cases 4 and 5, have not yet been
run.

| Date | Machine and macOS | Case | Pass or fail | What was lost | Notes |
|---|---|---|---|---|---|
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 1 | pass | nothing | Draft, unsaved dot and last edit time all came back after the kill. `/tmp/qa-draft.txt` still two lines: the file on disk was never written. |
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 2 | pass | the two scratch pages, as asked | `drafts.sealed` rewritten and not removed by the content erase. File tab and its draft returned after a normal quit and relaunch. |
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 3 | pass | the draft, as asked | Discard in the close review ended it. The reopened file held the two lines on disk and nothing else. |
