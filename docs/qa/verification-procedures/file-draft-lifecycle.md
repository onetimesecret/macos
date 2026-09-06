# File drafts: what a crash must not cost, and what a page erase must not take

**Applies to:** OnetimePad, the dev bundle from `scripts/dev.sh`, built
from `feature/regular-text-files` or later. Case 2 empties the pad of
pages, so it must not be run against the installed copy: the dev bundle
runs as `dev.onetimesecret.pad`, which gives it its own state directory and
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
**Status:** passed on hardware 2026-09-05, all three cases. Re-run when
the drafts file's format changes, when the content erase predicate
moves, or before a release that touches either.

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
STATE=~/Library/Application\ Support/dev.onetimesecret.pad.noindex
ls -la "$STATE"
```

Use `com.onetimesecret.pad.noindex` in that path instead if you are
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
  'subsystem == "dev.onetimesecret.pad" && (category == "core" || category == "persistence")'
```

The subsystem is the running bundle id, so it is the dev lane's exactly
as the state directory is.

## Case 1: a kill with a dirty file open

1. Launch `dist/OnetimePad.app`. Open `/tmp/qa-draft.txt` through File >
   Open. Confirm the tab appears in the FILES group, that it carries no
   countdown gauge, and that the header reads saved.
2. Type a distinctive line into the file, for example
   `DRAFT BEFORE THE KILL`. Confirm the orange unsaved dot appears on
   the file's tab and the header reads unsaved. Do not save.
3. Wait ten seconds so the debounce has landed, and confirm
   `drafts.sealed` exists and has a recent mtime.
4. Note the wall clock time. This is the draft's last edit time, and
   step 6 checks it.
5. `pkill -9 -f 'dist/OnetimePad\.app'`, then `ls -la "$STATE"` and
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
3. Quit the app normally and relaunch it.

**Pass:** `drafts.sealed` is still present after step 2, the file tab
comes back after step 3, and the draft from case 1 is still in it with
its unsaved dot. The pages are gone, which is what closing them asked
for.

**Fail:** `drafts.sealed` removed in step 2; the file tab returning
empty or clean; or the file tab absent entirely, which would mean a page
lifecycle event destroyed a person's unsaved file edits.

## Case 3: the draft ends when the tab does

The control for cases 1 and 2. A draft that survives everything would be
a different bug.

1. With the dirty file open, press cmd-w. Confirm the review appears
   offering Save, Discard and Cancel.
2. Choose Discard.
3. Reopen `/tmp/qa-draft.txt`.

**Pass:** the reopened file holds the two lines on disk and nothing
else. The draft is gone, and the header reads saved.

**Fail:** the discarded draft coming back, which would let a later cmd-s
write typing from a session the person had ended.

## Results

First run 2026-09-05, on the dev bundle at `fb5e798`, all three cases
pass. The two claims no test in this repository can reach are therefore
checked: a draft survives a `kill -9`, and emptying the pad of pages
reseals the drafts rather than taking them.

| Date | Machine and macOS | Case | Pass or fail | What was lost | Notes |
|---|---|---|---|---|---|
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 1 | pass | nothing | Draft, unsaved dot and last edit time all came back after the kill. `/tmp/qa-draft.txt` still two lines: the file on disk was never written. |
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 2 | pass | the two scratch pages, as asked | `drafts.sealed` rewritten and not removed by the content erase. File tab and its draft returned after a normal quit and relaunch. |
| 2026-09-05 | Apple M2 Max, macOS 27.0 (26A5421a) | 3 | pass | the draft, as asked | Discard in the close review ended it. The reopened file held the two lines on disk and nothing else. |
