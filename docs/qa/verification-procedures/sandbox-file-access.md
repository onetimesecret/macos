# Sandbox file access: a person's file, opened, saved and found again

**Applies to:** OnetimePad in a sandboxed build. That is the TestFlight
build from `scripts/package-app.sh --app-store`, which is the one that
decides a release, or a dev bundle signed with a provisioning profile,
which gets the same entitlements template. A bundle signed without a
profile carries no entitlements, is not sandboxed, and proves nothing
here; case 0 tells them apart.
**Required by:**
[ADR-0035](../../adr/0035-sandboxed-file-access-holds-a-scope-around-core-io.md),
proposed. Its evidence came from an ad hoc signed probe handed files by
LaunchServices. It did not run this app, a panel, a drop, a reboot, a
file moved under a running process or a distribution signature, and no test in this repository runs under a
sandbox: the suites exercise the same code unsandboxed, where a missing
scope changes nothing. Everything below is therefore unverified until a
person runs it.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

Re-run all cases when `scripts/Companion.entitlements` changes, when
`FileCoordinator` or the core's file write changes, and on the first
build of each new major macOS.

Use disposable files. Several cases overwrite, move and delete them.

## Validation expectations for the PR #222 follow-up

**Status: pending.** The outcomes in this section are proposed validation
criteria for the implementation, not observed hardware results or accepted
project guarantees. Unit tests run without the sandbox do not satisfy these
checks. Use disposable data and keep copies outside the test directory.

### Record evidence before judging the result

For each run, record the commit, app version, macOS version, machine
architecture, signing/distribution lane, and case 0 entitlement readback.
For volume cases, also record filesystem format, mount type, and whether
the destination is on the boot volume. Record the exact steps, notice text,
header/banner state, destination contents before and after, and relevant
sandbox or filesystem errors. Remove file contents and identifying paths
from shared evidence when they are not needed to explain the result.

Use separate outcomes: **pass**, **fail**, **blocked**, or **not exercised**.
A denial case is not exercised unless the app actually encounters the
intended denial; changing permissions or seeing no log output alone is not
proof. An unavailable volume, signing lane, or denial mechanism is blocked,
not a pass. A successful unsandboxed run cannot substitute for case 0.

### V1: saves on non-boot volumes

Extend cases 1, 4, 5 and 13a to a writable local external volume, a writable
exFAT volume, and a writable network share. Record unsupported or unavailable
configurations rather than treating all non-boot volumes as equivalent.
On each available volume:

1. Open an existing file through the panel, edit, and save twice.
2. Save As to a new name, then to an existing disposable destination.
3. Quit and relaunch. Confirm the selected file and text reopen.
4. Move the saved file in Finder while the app is closed, then relaunch
   and save again. Check that the old path is not recreated.
5. Record the replacement-directory location if observable and compare
   its filesystem with the destination's. Check for leftover temporary
   files on both volumes, not only in the app container.

**Expected:** ordinary saves to authorized, writable destinations succeed;
the written text, subsequent save, relaunch, and moved-file recovery agree.
A blanket non-boot-volume refusal is a failure to investigate, not an
accepted outcome. If staging cannot be provided on the destination's
filesystem, expect an explicit refusal with the original destination and
edits retained; record this as a failed save, not successful volume support.
The cross-filesystem guard is not evidence that a real external-volume save
works. Do not force a cross-volume copying fallback to obtain a pass.

### V2: newly denied reads and recovery

Open two files and leave one clean and one with unsaved edits. While the app
is inactive, remove read permission from those disposable files without
changing their contents; activate the app. Restore permissions and activate
again. Separately repeat with a reproducible sandbox-access denial, if one
is available; record its mechanism and errors. Mode changes exercise
filesystem permissions, not security-scope revocation. Never revoke access
to real customer or production files to manufacture a result.

**Expected after confirmed denial:** the first activation publishes the
unavailable state even when content timestamps/size still match. The clean
file retains its loaded text; this is not the unread, empty held state of
case 16. The dirty file retains its draft and offers recovery actions
without Take theirs while the other copy cannot be read. No typing is lost
and no file is written merely because the app activates. After access is
restored, the unavailable indication clears; differing disk contents must
still follow the conflict/reload behavior in the existing cases.

Record activation responsiveness with a large file inside the app's open
size limit. The implementation uses a one-byte readability probe; this is
not a latency guarantee. A slow activation needs profiling that separates
that probe from legitimate full reloads after content changes. Hardware
timing alone cannot prove how many bytes the probe read.

### V3: write-only refusal

Use a disposable directory whose permissions or ACLs allow reading its
existing file but deny the app's atomic replacement. Record the permissions,
ACLs, staging location, and actual error; keep a separate recovery copy and
restore the test permissions afterwards. Do not assume that making the
file read-only denies replacement when its parent remains writable.

**Expected:** a permission-denied save reports failure, retains the edits,
and leaves destination contents unchanged. The immediate post-save surface
reflects the core's access-refused mark. A later successful readability
probe may clear that mark even if writing is still denied; the mark is not
a persistent test of writability. Repeated saves must not claim success.
After permissions are repaired, an explicitly requested save succeeds.
Disk-full and cross-device failures must not be interpreted as proof that
read access was lost. A failed Save As elsewhere must not mark the original
file inaccessible solely because that new destination was denied.

### V4: modal completion and panel-answer ordering

With a file open, activate the app while a non-file modal is up, and change
the file externally during that modal. Dismiss the modal without another
activation or file-panel gesture. Repeat with Open, Save As, and Locate
panels, including cancellation and a deliberately refused choice.

**Expected:** the owed file check runs once the modal and any enclosing
file-panel gesture have finished; another activation is not required.
Panel answers are processed before that check. Record whether any notice
from the answer is replaced by a meaningful external-file notice or by a
redundant check. Nested modals must not cause an early or duplicate check.
Real AppKit focus/notification ordering must be observed; unit tests alone
do not establish it.

### V5: inherited ACLs

On a disposable managed/shared-style directory, record the directory's
inheritable ACL and the existing file's effective access (`ls -le` is useful
on macOS). Save a replacement through the app and record the replacement's
ACL and effective access. Where safe and available, check access as the
other account or group that the original ACL authorized.

**Expected implementation limitation:** separately staged replacements do
not reproduce destination-directory inherited ACLs. Mode/group preservation
is not ACL preservation. Record lost or changed effective access as a
limitation requiring a maintainer decision, not as an unexplained successful
save. This procedure does not approve that limitation or establish that the
implementation meets a shared-directory deployment's requirements.

### V6: held-header accessibility and roster-sized scope use

Repeat case 16 with a file recorded as CRLF before it becomes unreadable.
Inspect the header visually and with VoiceOver: record the actual spoken
text and available actions. **Expected:** the held header communicates that
the file has not been read, without a saved/unsaved claim or encoding/line
ending facts. No empty encoding label should occupy visual space. Locate
and Close remain available; Keep mine and Take theirs must not act on an
unloaded copy.

Extend case 20 with a documented, disposable roster size representative of
actual use. Record that size, launch responsiveness, recovery behavior, and
any scoped-resource errors. **Expected:** files remain distinct, drafts are
retained, and scopes do not accumulate across repeated restore/activation
cycles. The recursive helper has no fixed cap; a successful small roster
does not validate arbitrary roster sizes. Use instrumented scope counts
when available rather than inferring balance from the absence of errors.

### Completion record and separate design decision

Attach one result per case/configuration with evidence references and a
reason for each blocked or unexercised path. Keep the overall status open
while required hardware configurations have no result; document any scope
reduction explicitly rather than silently marking validation complete.

Hardware results cannot ratify the design amendment. The accepted D-17 in
[the UI/UX decision record](../../spec/design/2026-0915-ui-ux-decisions.md)
states: "the sentence is a pure function of conflict and filename".
Record the maintainer's decision on the draft Locate amendment separately;
do not use these proposed criteria or passing test results to establish
that acceptance.

## Implementation note: crossed-file scope bound

`PageModel.settleCrossedFiles` uses `withAccessToBookmarks` to nest the
crossed files' access brackets. At most one bracket per file in that
roster subset is open simultaneously; the bound is the open-file roster
size, not a fixed limit enforced by the helper. This describes the code,
not hardware validation that the roster fits macOS's scoped-resource limit.

## Prerequisite: the files

```sh
mkdir -p ~/Documents/qa-sandbox/moved
printf 'line one\nline two\n' > ~/Documents/qa-sandbox/a.txt
printf 'line one\nline two\n' > ~/Documents/qa-sandbox/b.txt
chmod 664 ~/Documents/qa-sandbox/a.txt
ls -ln ~/Documents/qa-sandbox
```

Record the mode, owner and group of `a.txt`. The directory is under the
home folder on purpose: `/tmp` would do for the probe, but a person's
files live here.

## Where to look

Sandbox refusals. This predicate is the usual one and was not checked
on this system when the procedure was written; if it shows nothing
during a case that visibly failed, find the right one and correct this
file.

```sh
log stream --style compact --predicate \
  'sender == "Sandbox" && eventMessage CONTAINS "OnetimePad"'
```

The app's own lines, with the subsystem of the build under test:

```sh
log show --last 30m --style compact --predicate \
  'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"} && category == "persistence"'
```

A line reading `a file bookmark could not be made` there is a failure
of the case it appears in.

Leftover staging directories. The probe saw the item replacement
directory inside the container, under `Data/tmp/TemporaryItems`. Set
the bundle id of the build under test:

```sh
BUNDLE=com.onetimesecret.pad
ls ~/Library/Containers/$BUNDLE/Data/tmp/TemporaryItems 2>/dev/null
```

Nothing named `NSIRD_*` should remain after a save has finished.

Leave the sandbox `log stream` running in a second terminal for the
whole session. Case 12 reads it.

## Case 0: the build is the sandboxed one

```sh
codesign -d --entitlements - --xml /Applications/OnetimePad.app
```

Use the path of the bundle under test.

**Pass:** `com.apple.security.app-sandbox` is true,
`com.apple.security.files.user-selected.read-write` is true, and
`com.apple.security.files.bookmarks.app-scope` is absent. With the app
running, Activity Monitor's Sandbox column reads Yes for it.

**Fail:** any of those otherwise. Stop; no later case means anything on
an unsandboxed build.

## Case 1: open, edit, save

1. File > Open, choose `a.txt`. Confirm the text appears.
2. Type a line. Press cmd-s.
3. `cat ~/Documents/qa-sandbox/a.txt` and `ls -ln ~/Documents/qa-sandbox`.
4. Type another line and press cmd-s again.

**Pass:** both saves land and the header reads saved. The mode is still
664 and the owner and group are what the prerequisite recorded. No
`a.txt.*.tmp` sits beside the file, and no `NSIRD_*` directory remains.
No sentence about reopening after a relaunch appears.

**Fail:** "a.txt could not be written."; a changed mode or group; a
temp file left in either place; or "a.txt may not reopen after a
relaunch, because access to it could not be kept."

## Case 2: drop

1. Drag `b.txt` from Finder onto the pad.
2. Edit it and press cmd-s.

**Pass:** the file opens in its own tab and the save lands, as in
case 1.

**Fail:** the file refused with "could not be read", or the save
refused. A drop is the one way in that does not go through a panel.

## Case 3: Save As, to a new name and over an existing file

1. With `a.txt` selected, File > Save As. Choose a name that does not
   exist, `c.txt`, in the same directory.
2. Edit and press cmd-s.
3. Save As again, this time choosing `b.txt` after closing its tab, and
   confirm the panel's replace question.
4. Edit and press cmd-s.

**Pass:** `c.txt` is created with the buffer's text and `a.txt` is left
as it was. The tab follows each new file and the cmd-s after each Save
As lands on it. No bookmark sentence appears.

**Fail:** either Save As refused; the later cmd-s refused, which would
mean the grant from the save panel did not outlive the panel; or a
bookmark sentence.

## Case 4: relaunch, clean and dirty

1. Leave one file open and saved, and another open with an unsaved
   edit. Quit and relaunch.
2. Press cmd-s on the dirty file. Edit the clean file and press cmd-s.

**Pass:** both tabs return. The clean one shows the text on disk. The
dirty one shows its draft and the unsaved dot, and the file on disk is
unchanged until step 2. Both saves land.

**Fail:** a launch notice that a file "could not be read" or "is no
longer at its path" for a file that is where it was; a tab missing; or
a save refused after the relaunch, which would mean the scope from the
bookmark allows the read and not the write.

## Case 5: moved and renamed while the app was closed

Run this straight after a save in the same session, because the
bookmark made after a save is the one under test.

1. Open `a.txt`, edit, save. Leave it open. Open `c.txt` and leave an
   unsaved edit in it. Quit.
2. In Terminal:

   ```sh
   mv ~/Documents/qa-sandbox/a.txt ~/Documents/qa-sandbox/moved/a-renamed.txt
   mv ~/Documents/qa-sandbox/c.txt ~/Documents/qa-sandbox/moved/c.txt
   ```

3. Relaunch. Save both files.

**Pass:** both tabs return under their new names or paths. The dirty
one keeps its draft with no conflict. Both saves land at the new paths,
and nothing is created at the old ones.

**Fail:** either file reported as no longer at its path; the dirty one
in a missing conflict; or a save that recreates the file at its old
path.

## Case 6: changed by something else, then activated

1. With `a.txt` open and clean, switch to Terminal and
   `printf 'THEIRS\n' >> ` the file at its current path. Switch back.
2. With the file open and clean again, replace it the way an editor
   does:

   ```sh
   F=~/Documents/qa-sandbox/moved/a-renamed.txt
   printf 'REPLACED\n' > "$F.new" && mv "$F.new" "$F"
   ```

   Switch back. Then edit and press cmd-s.

**Pass:** step 1 reloads the file and says it changed on disk and was
read again. Step 2 does the same, and the save after it lands.

**Fail:** "could not be read" on either activation. For step 2 also
record whether the file still reopens after a quit and relaunch: the
file was replaced by another program, so the app's bookmark was made
from a file that no longer exists. Whatever happens, write it in the
notes; ADR-0035 did not measure this.

## Case 7: the conflict, three ways

For each of the three, open a file, type `MINE` without saving, then in
Terminal `printf 'THEIRS\n' > ` the file, and switch back so the
conflict banner appears.

1. **Keep mine**, then cmd-s.
2. **Take theirs**, then cmd-z.
3. **Save As** to a new name.

**Pass:** keep mine clears the banner and the save overwrites the disk
copy with the buffer. Take theirs shows `THEIRS` at once and undo
brings `MINE` back. Save As writes the new file and leaves the changed
one alone.

**Fail:** any of the three refused, or "could not be read" after take
theirs.

## Case 8: deleted

1. With one file open and clean and another open and dirty, delete both
   in Terminal. Switch back.
2. Quit and relaunch.

**Pass:** on activation the files are reported as no longer at their
paths, and the dirty one stands in a missing conflict with its draft.
Its banner offers Locate…, Keep mine and Save As, in that order, and no
Take theirs, since there is no copy to take. The clean one keeps its
text and shows a banner reading "NAME is no longer at PATH" with
Locate… and Close. Switching away and back a second time leaves both
banners up and does not repeat the sentence. After the relaunch the clean tab is gone with a notice naming
it, and the dirty tab is back with its draft and the same banner, where
Save As writes it out.

**Fail:** the draft lost; a crash; or a file recreated at the deleted
path without a save being asked for.

## Case 9: another volume

Needs an external disk or a disk image. ADR-0035 measured the home
volume only, and the save depends on the staging directory being on the
file's own volume.

1. Open a file on the other volume. Edit and save. Save As to a new
   name on that volume.
2. Quit, relaunch, edit and save.
3. With the file open and clean, eject the volume and switch back to
   the app. Mount it again and switch back again.
4. Quit with the file open, eject the volume, and relaunch.

**Pass for steps 1 and 2:** every save lands. Record in the notes where
the `NSIRD_*` directory was made during a save, if it can be seen.

**Fail for steps 1 and 2:** "could not be written." on a volume the
person can write. That is the cross volume rename the staging clause
does not retry, and it fires an ADR-0035 eject trigger.

**Steps 3 and 4 are observations.** Record what the app says with the
volume away, whether it mounts anything by itself (it should not), and
whether the file is usable again once the volume is back. No claim has
been made about these.

## Case 10: the keymap file

1. Open the keymap file from the app's menu. Edit and save it.

**Pass:** it opens and saves, and no sentence about reopening after a
relaunch appears. The file is inside the app's own container and needs
no grant.

**Fail:** the bookmark sentence, or a refused save.

## Case 11: repeated access

1. With two files open, save one of them fifty times with an edit
   between each.
2. Switch away from the app and back fifty times.
3. Save once more, and run the `ls` from "Where to look".

**Pass:** the last save lands as the first did, the app's memory in
Activity Monitor has not grown without bound, and no `NSIRD_*`
directory remains.

**Fail:** a save or a check that starts being refused partway, which is
what a scope started and never stopped would be expected to look like
eventually; or staging directories piling up. The counting tests in
`shell/Tests/CompanionKitTests/FileAccessTests.swift` are what pin the
balance. This case looks only for a symptom they cannot see.

## Case 12: the sandbox log

Read the `log stream` that has been running since the start.

**Pass:** no `deny` line naming a path under `~/Documents/qa-sandbox`
or the other volume.

**Fail:** any such line, even when the case it fell in appeared to
pass. Record the line and the case. A denial with no visible failure is
a call the app makes outside a bracket and then ignores.

## Case 13: reboot

1. Leave one clean and one dirty file open. Quit. Restart the Mac.
2. Launch the app. Save both.

**Pass:** as case 4. This is the run that shows the bookmark carries
the grant by itself: the probe saw files stay readable after a relaunch
within one boot with no scope started, so only a reboot rules that out.

**Fail:** as case 4.

## Case 13a: Save As staging failure on a network share or exFAT volume

Run separately with a writable network share and a writable exFAT removable
volume, using disposable destinations. Record macOS and app versions, the
volume format and mount type, and the exact destination and visible notice.

1. Confirm case 0, then leave unsaved edits in an open disposable file.
2. Choose Save As and select a new destination on the test volume. Repeat
   with an existing disposable destination whose contents were recorded.
3. Record whether an item replacement directory can be created for the
   target or its parent. If both attempts fail, record the target-adjacent
   staging fallback and any sandbox denial from the running log stream.
4. Compare both destinations and the original file with their recorded
   contents. Check the tab's edits and any leftover staging files.

**Record either outcome:** a successful save with the requested text and
no leftover staging file, or an explicit "NAME could not be written."
refusal with the original file and existing destination unchanged and the
unsaved edits still available. Record that the bare refusal provides no
staging-specific guidance; do not count it as a successful Save As.

**Fail:** a saved header despite a failed write, lost edits, an original or
existing destination modified on refusal, or leftover staging files.
If neither volume triggers both directory-creation failures, mark that
failure path **not exercised**, not validated. Do not alter real data or
production share permissions to force it.

## Case 14: state from an unsandboxed build

Only if the Mac has files open in an earlier, unsandboxed build under
the same bundle id.

**Unmeasured, and the first thing to record:** whether the sandboxed
build sees the state the unsandboxed build wrote at all. Nothing in
ADR-0035 or the suites answers it. Before launching the sandboxed
build, note the file tabs the unsandboxed build had open and which held
unsaved edits. After launching it, record whether those tabs are there.
If none are, write that in the notes, with whether the pages came back,
and stop: the rest of this case does not apply, and a person upgrading
would find their file tabs and any unsaved edits in them gone, which is
a finding of its own. If the tabs are there, the open files carry plain
bookmarks, and the steps below apply.

1. Launch the sandboxed build and look at each file tab.
2. On a clean one, choose Locate… and pick the same file in the panel.
   Edit and press cmd-s.
3. On a dirty one, choose Locate… and pick the same file. Press cmd-s.
4. Quit and relaunch.

**Expected from the code, not yet seen:** a clean file comes back held:
its tab is there with no text, the editor takes no typing, and a banner
reads "NAME cannot be read at PATH" with Locate… and Close. A dirty one
comes back with its draft and a banner reading "NAME cannot be read at
its path and this copy has unsaved edits · saving is refused until one
copy is chosen" with Locate…, Keep mine and Save As. Take theirs is not
drawn. Switching to another app and back leaves that banner exactly as
it was, and cmd-s on the tab is still refused with "NAME cannot be read
at its path. Choose Locate, keep mine, or Save As before saving."

**Pass:** step 2 fills the tab with the file's text and the save lands.
Step 3 clears the banner with the draft still in place, if the file has
not changed since the draft was made, and the save lands. After step 4
every located file reopens as in case 4, with no banner.

**Fail:** a draft lost; a file written without a save being asked for;
the dirty tab's banner changing to the two action one, or its save
going through, after a switch away and back with nothing located;
a clean tab dropped at launch when its file is where it was; Locate
leaving the banner up after the file itself was chosen; or a located
file held again after the relaunch, which would mean the bookmark made
from the Locate panel does not carry the grant.

## Case 15: moved to the Trash while the app was closed

A bookmark follows a file into the Trash. An unsandboxed run on
2026-09-30 (macOS 27.0) resolved a scoped bookmark to the file's path
under `~/.Trash` after `FileManager.trashItem`, with the stale flag
set. The app treats a bookmark that resolves there as one that resolves
to nothing and reads the recorded path. No test can exercise the real
Trash, and the sandboxed behaviour has not been seen.

1. Open one file and leave it saved. Open another and leave an unsaved
   edit in it. Quit.
2. In Finder, move both files to the Trash. Relaunch.
3. On the dirty tab, choose keep mine and press cmd-s.
4. Quit and relaunch once more without touching anything.

**Pass:** the clean tab is gone with a notice that the file is no
longer at its path. The dirty tab is back with its draft in a missing
conflict, still named by its original path. The save in step 3 creates
the file at the original path, or is refused out loud under the
sandbox; record which. Nothing in the Trash is modified. Step 4 does
not repeat the notice from step 2.

**Fail:** either file back as an ordinary tab whose path is inside the
Trash; a save that writes to the copy in the Trash; or the draft lost.

Also record here, for case 5, whether a second relaunch after a move
repeats nothing: the moved file's new path and fresh bookmark should be
written to the drafts file by the first relaunch without any edit.

## Case 16: a held file, and Locate on it

A file the system will not let the app read is held, not dropped. The
suites stand in for that with a mode 000 file, and so does this case;
case 14 is the one that reaches it through the sandbox itself.

1. Make the file, open it and leave it saved. Quit. Then copy it and
   take its permissions away:

   ```sh
   printf 'line one\nline two\n' > ~/Documents/qa-sandbox/held.txt
   # open held.txt in the app, then quit, then:
   cp ~/Documents/qa-sandbox/held.txt ~/Documents/qa-sandbox/moved/held-copy.txt
   chmod 000 ~/Documents/qa-sandbox/held.txt
   ```

2. Relaunch. Select the `held.txt` tab, try to type, and press cmd-s.
3. `chmod 664 ~/Documents/qa-sandbox/held.txt`, switch to another app
   and back.
4. Quit, `chmod 000` the file again, relaunch. Choose Locate… and
   cancel the panel. Choose Locate… again and pick `held.txt` itself.
5. Choose Locate… once more and pick `moved/held-copy.txt`. Edit and
   press cmd-s. Quit and relaunch.

**Pass:** in step 2 the tab is back with no text and no launch notice
about it, the header reads "not read" beside the name with no dot and
no encoding or format, the banner reads "held.txt cannot be read at"
followed by its path, with Locate… and Close, typing does nothing, and
cmd-s says
"held.txt has not been read, so there is nothing to save. Locate the
file or close the tab." In step 3 the text appears and the banner goes,
with no gesture but the activation. In step 4 the panel opens in
`~/Documents/qa-sandbox` with the prompt Locate and the message "Choose
where held.txt is now."; the cancel changes nothing, and picking the
unreadable file says "held.txt could not be read, so it was not
opened." and leaves the tab held. In step 5 the tab takes the copy's
name and text, the save lands on `moved/held-copy.txt`, `held.txt` is
untouched, and after the relaunch the tab reopens on the copy with no
banner.

**Fail:** the held tab dropped at launch; text shown that is not the
file's; the header reading "saved" or "unsaved" on the held tab; a save
that writes an empty file; the banner staying up after the file became
readable; or the located file not reopening after the relaunch.

Record how "not read" looks in the header beside the banner. The word
has not been seen on screen.

Then, as a separate run of steps 1 and 2, press cmd-w on the held tab.

**Pass:** the tab closes at once with no "has unsaved changes" banner,
and `held.txt` is untouched.

**Fail:** the close decision raised for a tab that holds no typing.

## Case 17: Locate from a conflict

1. Make three files and open all three:

   ```sh
   for f in loc-x loc-y loc-z; do
     printf 'line one\nline two\n' > ~/Documents/qa-sandbox/$f.txt
   done
   ```

   Type `MINE` into `loc-x.txt` and into `loc-y.txt` without saving.
   Leave `loc-z.txt` untouched. Then in Terminal:

   ```sh
   cd ~/Documents/qa-sandbox
   cp loc-x.txt moved/loc-x-same.txt && rm loc-x.txt
   printf 'OTHER\n' > moved/loc-y-other.txt && rm loc-y.txt
   ```

   Switch back to the app.
2. On `loc-x.txt`, press cmd-s. Choose Locate… and cancel. Choose
   Locate… and pick `loc-z.txt`.
3. On `loc-x.txt`, choose Locate… and pick `moved/loc-x-same.txt`.
   Press cmd-s.
4. On `loc-y.txt`, choose Locate… and pick `moved/loc-y-other.txt`.
   Choose Take theirs, then press cmd-z.
5. Quit and relaunch.

**Pass:** after step 1 each dirty tab's banner reads "NAME is no longer
at its path and this copy has unsaved edits · saving is refused until
one copy is chosen" with Locate…, Keep mine and Save As, and no Take
theirs. In step 2 the save is refused with "loc-x.txt is no longer at its path.
Choose Locate, keep mine, or Save As before saving.", the cancel
changes nothing, and the Locate onto the open file is refused with
"loc-z.txt is already open, so loc-x.txt was not pointed at it. Close
it first, or choose another file."; the tab is unchanged after all
three. In step 3 the banner goes, the draft is still on screen and
unsaved, and the save writes it into `moved/loc-x-same.txt`. In step 4
the tab is bound to `loc-y-other.txt`, the draft is still on screen,
and the banner now says the file changed on disk, with Keep mine, Take
theirs and Save As and no Locate; Take theirs shows `OTHER` and undo
brings the draft back. Nothing is created at either old path. After
step 5 both tabs reopen on the files they were pointed at.

**Fail:** a draft lost or replaced by anything but Take theirs; a save
landing at a deleted path; Locate onto the open file succeeding; or
"could not be read" after picking a file in the panel, which would mean
the panel's grant did not reach the core's read.

## Case 18: moved while the app is running

A bookmark follows its file, and the check on activation and before a
save binds the open tab to where the file went. The probe measured a
bookmark following a move across a relaunch only, so this case is the
first look at it in a running process under the sandbox.

1. Make three files and open all three:

   ```sh
   for f in live-a live-c live-t; do
     printf 'line one\nline two\n' > ~/Documents/qa-sandbox/$f.txt
   done
   ```

   Leave `live-a.txt` and `live-t.txt` untouched and type an unsaved
   edit into `live-c.txt`. Then in Terminal:

   ```sh
   cd ~/Documents/qa-sandbox && mkdir -p live
   mv live-a.txt live/live-a.txt
   mv live-c.txt live/live-c-renamed.txt
   ```

   Switch back to the app.
2. Press cmd-s on the dirty tab. Edit the clean one and press cmd-s.
3. Move `live-t.txt` to the Trash in Finder and switch back.
4. Quit and relaunch.

**Pass:** after step 1 neither moved file is reported as no longer at
its path and no conflict banner appears. The tabs show the new name and
path (the tooltip on a row is its path). Both saves in step 2 land at
the new paths and nothing is created at the old ones. In step 3
`live-t.txt` is reported as no longer at its path and its tab is not
bound to anything inside the Trash. After step 4 the two moved files
reopen at their new paths with no notice about them, and the trashed
one is gone with a notice, as in case 15.

**Fail:** a missing report or a missing conflict for a file that was
only moved; a save that recreates the file at its old path; a tab bound
to a path in the Trash; or a moved file not found after the relaunch.

## Case 19: a save never makes a file where there is none

A save writes a file back. It does not put one at a path a person
deleted or moved their file from. The core refuses, and the suites
cover it outside a sandbox; this case looks at it under one, where the
stat the refusal rests on is made on a path the app may have no grant
for. ADR-0035's probe saw a stat of an ungranted path answer under the
sandbox.

1. Make two files and open both:

   ```sh
   for f in gone-clean gone-dirty; do
     printf 'line one\nline two\n' > ~/Documents/qa-sandbox/$f.txt
   done
   ```

   Leave `gone-clean.txt` untouched and type `MINE` into
   `gone-dirty.txt` without saving. Then in Terminal delete both, and
   switch back to the app:

   ```sh
   rm ~/Documents/qa-sandbox/gone-clean.txt ~/Documents/qa-sandbox/gone-dirty.txt
   ```

2. On `gone-clean.txt`, press cmd-s. `ls ~/Documents/qa-sandbox`.
3. On `gone-dirty.txt`, press cmd-s. `ls` again.
4. On `gone-dirty.txt`, choose Keep mine and press cmd-s. `ls` again.
5. On `gone-clean.txt`, choose File > Save As, and in the panel choose
   the same directory and the same name, `gone-clean.txt`.

**Pass:** after step 1 both banners stand, as in case 8. In step 2
nothing is written, the sentence reads "gone-clean.txt is no longer at
its path, so it was not saved. Choose Locate to find it, or Save As to
write it somewhere.", and the banner "gone-clean.txt is no longer at"
followed by its path still stands with Locate… and Close. In step 3
nothing is written, the tab still stands in the missing conflict with
Locate…, Keep mine and Save As, the draft is still on screen, and the
sentence reads "gone-dirty.txt is no longer at its path. Choose Locate,
keep mine, or Save As before saving." In step 4 the save creates
`gone-dirty.txt` with
the draft's text, or is refused out loud under the sandbox for want of
a grant on a path with no file; record which. In step 5 the file is
written at its old path, the banner goes, and a later cmd-s lands.

**Fail:** a file recreated in step 2 or step 3; the draft lost; "could
not be written." in step 2 or step 3, which would mean the stat was
refused and the write was tried; or Save As in step 5 refused or ending
with nothing written.

## Case 20: files that traded names while the app was closed

Two open files that swap names leave each record's bookmark pointing at
the other's recorded path. The app ends that by reading each file at
its recorded path with both bookmarks' scopes open at once. The suites
check the order and the balance of the scopes outside a sandbox, where
a scope changes nothing. Whether the read is allowed under a sandbox
has not been seen.

1. Make two files with different text, open both and leave both saved.
   Quit.

   ```sh
   printf 'text of x\n' > ~/Documents/qa-sandbox/cross-x.txt
   printf 'text of y\n' > ~/Documents/qa-sandbox/cross-y.txt
   ```

2. Swap the names, then relaunch:

   ```sh
   cd ~/Documents/qa-sandbox
   mv cross-x.txt cross-tmp.txt
   mv cross-y.txt cross-x.txt
   mv cross-tmp.txt cross-y.txt
   ```

3. Edit each tab and press cmd-s on each.
4. Quit and relaunch.
5. Repeat steps 1 to 4 with an unsaved edit left in one of the two
   files before the quit in step 1.

**Pass:** after step 2 both tabs are back, each under its own name,
each showing the text that is now in the file of that name, and
neither is held, dropped or reported as no longer at its path. Record
what notice, if any, the launch gives. In step 3 each save lands on the
file its tab names and the other file is untouched. After step 4 both
reopen as in case 4 with no notice. In step 5 the draft is kept; record
whether its tab opens in a conflict and what the banner offers.

**Fail:** either tab held with "cannot be read at" its path, which
would mean the read across scopes was refused; a tab dropped; two tabs
bound to one file; a save landing on the other file; a draft lost; or
the same crossing repeated at step 4, which would mean the bookmarks
made at step 2 do not carry the grant.

## Case 21: keep mine over a changed file, then the file is deleted

A keep mine answers the question it was asked. One given while a copy
was at the path is consent to overwrite that copy, and is not consent
to make the file again after somebody deleted it. The core withdraws
it, and the suites cover that outside a sandbox.

1. Make a file, open it and type `MINE` at the start without saving:

   ```sh
   printf 'line one\nline two\n' > ~/Documents/qa-sandbox/kept.txt
   ```

2. In Terminal, write another copy over it, and switch back to the app:

   ```sh
   printf 'THEIRS\n' > ~/Documents/qa-sandbox/kept.txt
   ```

3. Choose Keep mine. Do not save.
4. In Terminal, delete the file, and switch back to the app:

   ```sh
   rm ~/Documents/qa-sandbox/kept.txt
   ```

5. Press cmd-s. `ls ~/Documents/qa-sandbox`.
6. Choose Keep mine again and press cmd-s. `ls` again.

**Pass:** after step 2 the conflict banner stands with Keep mine, Take
theirs and Save As, and step 3 clears it. After step 4 the app says
"kept.txt is no longer at its path." and the banner is back, now
offering Locate…, Keep mine and Save As, and no Take theirs. In step 5
nothing is written, `kept.txt` is not in the listing, the draft is
still on screen, the banner still stands, and the sentence reads
"kept.txt is no longer at its path. Choose Locate, keep mine, or Save
As before saving." In step 6 the save creates `kept.txt` with the
draft's text, or is refused out loud under the sandbox for want of a
grant on a path with no file; record which.

**Fail:** `kept.txt` recreated in step 5, which would mean the first
keep mine was spent on a deletion nobody was shown; the draft lost; no
banner after step 4; or "could not be written." in step 5.

## Case 22: a file put back while a missing conflict stands

A missing conflict says nothing is at the path. That stops being true
when the file comes back, and a save is judged against the file as it
now is: saved when it is the copy the draft was measured against, and
put in the changed conflict when it is another.

1. Make a file, open it and type `MINE` at the start without saving:

   ```sh
   printf 'line one\nline two\n' > ~/Documents/qa-sandbox/back.txt
   ```

2. In Finder, move `back.txt` to the Trash, and switch back to the app.
3. In Finder, open the Trash, choose Put Back on `back.txt`, and switch
   back to the app. Press cmd-s. `cat ~/Documents/qa-sandbox/back.txt`.
4. Type `MORE` without saving. In Terminal delete the file, and switch
   back to the app:

   ```sh
   rm ~/Documents/qa-sandbox/back.txt
   ```

5. In Terminal, write a different file at the path, and switch back to
   the app. Press cmd-s. `cat` the file again.

   ```sh
   printf 'SOMEBODY ELSE\n' > ~/Documents/qa-sandbox/back.txt
   ```

**Pass:** after step 2 the app says "back.txt is no longer at its
path." and the banner offers Locate…, Keep mine and Save As; the tab is
still named by its original path and not by one in the Trash. In step 3
the banner comes down, on the switch back or at the save, the save
lands with no sentence, and the file holds the draft's text. After step
4 the missing conflict stands again. In step 5 the banner changes to
the changed conflict, offering Keep mine, Take theirs and Save As,
nothing is written, the file still reads `SOMEBODY ELSE`, and the
sentence reads "back.txt changed on disk. Choose keep mine, take
theirs, or Save As before saving."

**Fail:** the save in step 3 refused with the missing sentence while
the file is there; the file in step 5 overwritten; the banner in step 5
still saying the file is gone; or the draft lost at any step. Record
separately if step 2 leaves the tab following the file into the Trash,
which case 15 also looks for.

## Case 23: keep mine, then undo back to the old text

After keep mine over a changed file the disk holds the other copy. The
text the tab goes back to on undo is the copy the disk no longer holds,
so the header must go on reading unsaved until the save. The suites
cover the flag; this case is the header and the dot on screen.

1. Make a file, open it and type `MINE` at the start without saving:

   ```sh
   printf 'line one\nline two\n' > ~/Documents/qa-sandbox/undone.txt
   ```

2. In Terminal, write another copy over it, switch back to the app and
   choose Keep mine:

   ```sh
   printf 'THEIRS\n' > ~/Documents/qa-sandbox/undone.txt
   ```

3. Press cmd-z until the text reads `line one`, `line two` with no
   `MINE`. Read the header.
4. Switch to another app and back. Read the header again, and `cat` the
   file.
5. Press cmd-s. Read the header, and `cat` the file.
6. Type `X`, then press cmd-z. Read the header.

**Pass:** in step 3 and step 4 the header reads unsaved with its dot,
no banner stands, and the file still reads `THEIRS`. In step 5 the save
lands with no sentence, the file reads `line one`, `line two`, and the
header reads saved. In step 6 the header reads unsaved after the `X`
and saved again after the undo.

**Fail:** the header reading saved in step 3 or step 4 while the file
holds `THEIRS`; a conflict banner returning in step 4; the save in step
5 refused; or the header still reading unsaved after step 5.

## Results

| Date | Machine and macOS | Build and signature | Case | Pass or fail | Notes |
|---|---|---|---|---|---|
| | | | 0 | not yet run | |
| | | | 1 | not yet run | |
| | | | 2 | not yet run | |
| | | | 3 | not yet run | |
| | | | 4 | not yet run | |
| | | | 5 | not yet run | |
| | | | 6 | not yet run | |
| | | | 7 | not yet run | |
| | | | 8 | not yet run | |
| | | | 9 | not yet run | |
| | | | 10 | not yet run | |
| | | | 11 | not yet run | |
| | | | 12 | not yet run | |
| | | | 13 | not yet run | |
| | | | 14 | not yet run | |
| | | | 15 | not yet run | |
| | | | 16 | not yet run | |
| | | | 17 | not yet run | |
| | | | 18 | not yet run | |
| | | | 19 | not yet run | |
| | | | 20 | not yet run | |
| | | | 21 | not yet run | |
| | | | 22 | not yet run | |
| | | | 23 | not yet run | |
