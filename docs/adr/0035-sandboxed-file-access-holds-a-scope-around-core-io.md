---
documentation_status: needs-review # draft | reviewed | stale
---

# ADR-0035: Sandboxed file access holds a scope in the shell around IO done in the core

- **Status:** proposed
- **Date:** 2026-09-30
- **Supersedes in part:** [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md), which keeps every clause except the plain bookmarks clause and the same directory sentence of its explicit save clause.
- **Depends on:** [ADR-0001](0001-rust-core-thin-shell.md) and [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md).

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The App Store lane signs the app with `com.apple.security.app-sandbox`
([entitlements template](../../scripts/Companion.entitlements),
[packaging script](../../scripts/package-app.sh)). File backed documents
were built before that lane existed and assumed ordinary filesystem
access. ADR-0028, itself still proposed, deferred the question in one
clause:

> Creating and resolving bookmarks and opening the panels live in one
> shell function, so the security scoped variant is a small change
> rather than a search.

and set one requirement on the deferred work:

> when the sandbox arrives, the scope must be started and stopped in
> that one function around a write performed in the core, and a write
> attempted outside it must fail loudly rather than truncate a person's
> file.

The requirement holds. The prediction of a small change does not. Set
against the measurements below, the implementation that clause
described could not have edited a file under the sandbox at all, for
four separate reasons:

1. The entitlements declared no file access, and the bookmarks were
   plain ones made and resolved with no options, with no scope ever
   started.
2. The core's atomic write made its temp file beside the target. A
   grant on a document does not cover its directory (E3 below), so
   every save would have been refused.
3. `companion_drafts_restore` read every open file before the shell had
   resolved any bookmark, so no file could have been read at launch,
   and the core never learned where a moved file had gone.
4. The bookmark was made at open and at Save As only. A save replaces
   the file, and a bookmark made before the save stops finding the file
   once it moves (E8 below).

### Evidence

Measured on 2026-09-30 on one Mac running macOS 27.0 (build 26A428),
with a small app signed ad hoc in four variants: the sandbox alone
(`none`), the sandbox with
`com.apple.security.files.user-selected.read-write` (`rw`), those two
with `com.apple.security.files.bookmarks.app-scope` (`rwbm`), and no
entitlements at all (`unsandboxed`). Files were handed to it through
LaunchServices, which grants access without a panel. The probe is
checked in as
[sandbox-file-access-probe.swift](../../scripts/sandbox-file-access-probe.swift)
with its runner
[sandbox-file-access-probe.sh](../../scripts/sandbox-file-access-probe.sh).

The table rests on the output of the checked in probe, run through its
runner in all four variants at 02:00 PDT that day. That output is
checked in under
[docs/qa/probe-runs/2026-0930-sandbox-file-access](../qa/probe-runs/2026-0930-sandbox-file-access/README.md),
one file per variant, with the digests of the probe and the runner that
produced it. The lines quoted under the table are copied from it. A row
marked "output" was read in it when this record was written; `rwbm`
gave the same lines as `rw` apart from inode numbers and temp names.
The files sat under `/tmp`, not under the home folder.

| | Observation | Basis |
| --- | --- | --- |
| E1 | `stat` succeeds on a path with no grant. Opening that file for reading fails `EPERM`. Opening the directory of a granted file fails `EPERM`. | output |
| E1a | `realpath` succeeds on a path with no grant. | notes of an earlier run; the output shows `realpath` on a granted path only |
| E2 | With a grant, whether from LaunchServices or from a started scope, the file can be read, and it can be appended to in place. | output, Q1 |
| E3 | With a grant on the file, creating a temp file beside it fails `EPERM`. | output |
| E4 | A temp file created in the item replacement directory, which was inside the app's container, can be renamed onto the granted file. The file has a new inode afterwards. | output |
| E4a | The file had group id 0 before the staged rename and group id 20 after it, in every variant, the unsandboxed one included. | output, Q2 |
| E5 | With the sandbox and `files.user-selected.read-write`, a security scoped bookmark can be made for a granted file. `files.bookmarks.app-scope` changed nothing. | output |
| E5a | Without `files.user-selected.read-write`, making a security scoped bookmark fails with Cocoa error 256. | output, Q3 |
| E6 | After a relaunch the recorded path cannot be read (`EPERM`). Resolving the scoped bookmark with `.withSecurityScope` and starting the scope gives read, staged write and a fresh bookmark. After the scope is stopped the read fails `EPERM` again. The last of these is shown only by the relaunch after the move (see the reading notes below). | output |
| E7 | A plain bookmark does not resolve with `.withSecurityScope`: Cocoa error 259 in `rw`, `rwbm` and `unsandboxed`, and error 256 in `none`. It resolves with no options. | output, Q4 |
| E7a | In every sandboxed variant, resolving the plain bookmark with no options in the first relaunch left the file readable with no scope started, in the same boot. This is treated as an accident of the system and nothing depends on it. | output |
| E7b | A start that answers true is not proof of access. In `none`, after the move, the plain bookmark resolved to the new path, the start answered true, and the read still failed `EPERM`. | output, Q5 |
| E8 | After a second staged write replaced the file and the file was then moved to another directory, the plain bookmark, which was made before that write, failed to resolve. The scoped bookmark made again inside the scope after the write resolved to the new path, and access through it worked. | output, Q6 |
| E8a | That first resolution after the move reported the bookmark as stale. | output, Q6 |
| E9 | In a process with no sandbox, making a security scoped bookmark, resolving it, and starting and stopping the scope all succeed. | output, Q7 |

The quoted lines, from `rw` unless another variant is named:

- **Q1.** `[granted] append in place: ok`
- **Q2.** `[granted] stat: ok ino=567247035 size=18 gid=0` and, after
  the rename, `[granted] stat after: ok ino=567247044 size=41 gid=20`.
  In `unsandboxed`:
  `[granted] stat: ok ino=567247286 size=18 gid=0` and
  `[granted] stat after: ok ino=567247351 size=41 gid=20`.
- **Q3.** In `none`:
  `scoped bookmark create: FAIL Error Domain=NSCocoaErrorDomain Code=256 "ScopedBookmarksAgent did not return error domain during creation"`
- **Q4.**
  `[plain/scope] resolve FAIL Error Domain=NSCocoaErrorDomain Code=259 "The file couldn’t be opened because it isn’t in the correct format."`
  In `none`:
  `[plain/scope] resolve FAIL Error Domain=NSCocoaErrorDomain Code=256 "ScopedBookmarksAgent did not return error domain during resolution"`
- **Q5.** In `none`, in the relaunch after the move:
  `[plain/[]] resolved /private/tmp/sandbox-file-access-probe.WAhVn9/sub/renamed.txt stale=true`,
  `[plain/[]] startAccessing=true`,
  `[plain/[]] read FAIL errno=1 Operation not permitted`
- **Q6.** In the relaunch after the move:
  `[plain/[]] resolve FAIL Error Domain=NSCocoaErrorDomain Code=4 "The file doesn’t exist."`,
  `[scoped/scope] resolved /private/tmp/sandbox-file-access-probe.cCZdlV/sub/renamed.txt stale=true`,
  `[scoped/scope] before start: read FAIL errno=1 Operation not permitted`,
  `[scoped/scope] read: ok 46 bytes`,
  `[scoped/scope] after stop: read FAIL errno=1 Operation not permitted`
- **Q7.** In `unsandboxed`: `scoped bookmark create: ok 664 bytes`,
  `[scoped/scope] resolved /private/tmp/sandbox-file-access-probe.bNpZni/doc.txt stale=false`,
  `[scoped/scope] startAccessing=true`

Reading notes, which are interpretation and not output:

- E4a says what the group was before and after. That the new group is
  the staging directory's is an inference; the probe does not print the
  staging directory's group.
- In the first relaunch the four resolutions share one process, so
  access that the plain resolution left open (E7a) is still open when
  the later ones run. Only the relaunch after the move shows a scope
  opening and closing access by itself, which is why E6 cites it.
- For E8, the two bookmarks in `rw` differ in kind as well as in when
  they were made. The `none` variant separates the two: it has no
  scoped bookmark, so it makes no second staged write, and there the
  plain bookmark followed the move (Q5). The plain bookmark failed only
  where a staged write came after it was made.
- E8a has a second half that no retained output shows. The lead's
  observation of an earlier run on 2026-09-30 is that the launch after
  the one in Q6, resolving the bookmark made again in Q6's scope,
  answered `stale=false`.

Not measured, because each needs a person or a real signature: a URL
from `NSOpenPanel` or `NSSavePanel`, which includes the Locate panel, a
rename onto a save panel destination that does not exist yet, a drop,
persistence across a reboot, a file under the home folder or on another
volume, a bookmark following a file moved while the process holding it
is still running, resolution with `.withoutUI` and `.withoutMounting`,
and a Developer ID or App Store signature. No Apple documentation was
consulted for
this record, and nothing here should be read as a statement of what the
platform documents. The
[hardware procedure](../qa/verification-procedures/sandbox-file-access.md)
holds the checks that close these gaps.

## Decision

The shell holds a security scope, taken from the file's own scoped
bookmark or from the URL a panel handed over, around every call that
makes the core read, stat or write a person's file, and the core's save
and restore are shaped so that each can run inside that scope.

The clauses that fix the boundary:

- **One entitlement.** The template declares
  `com.apple.security.files.user-selected.read-write`. It does not
  declare `com.apple.security.files.bookmarks.app-scope`, which E5
  found unnecessary. The packaging script refuses an App Store build
  whose final signature lacks the first.
- **One code path for every lane.** Bookmarks are made with
  `.withSecurityScope` and resolved with it whether or not the process
  is sandboxed, and nothing asks which lane is running (E9).
- **Resolving a bookmark raises no UI and mounts nothing.** Both
  resolutions pass `.withoutUI` and `.withoutMounting` beside
  `.withSecurityScope`. A launch or an activation must not raise an
  authentication dialog or mount a network volume by itself. A file on
  a volume that is not mounted therefore reads as missing, and for a
  file still open the way back is Locate, or mounting the volume and
  activating the app again.
- **Every file operation is inside a bracket.** Open, save, Save As,
  the check on activation and the reload it may lead to, keep mine,
  take theirs and Locate each run between a start and a stop. A save holds one
  bracket around its check, its write and its fresh bookmark. The stop
  is made only for a start that answered true, on the same URL. Every
  start and stop goes through one injectable pair so a test can count
  them.
- **The save stages outside the document's directory.** The shell asks
  the system for an item replacement directory for the target, hands
  its path to the core, and removes it afterwards. The core creates its
  temp file there, writes and syncs it, gives it the mode of the file
  it replaces, restores that file's group when it can, and renames it
  onto the target (E3, E4). A target that does not exist yet is given
  the group a file created in its own directory would take, when the
  user can give it. A temp file that cannot be renamed is
  removed and the save fails. The core never falls back to a temp file
  beside the target on its own, and the shell does not retry a failed
  staged save beside the target either: there is one write route in
  every lane, and a refusal is said out loud. With no staging directory
  given, which is what a caller with no shell passes, the temp file is
  made beside the target as before. The mode and the group are carried
  on both routes.
- **The bookmark is made again after every save and every Save As**,
  inside the scope, and handed to the core (E8). When it cannot be
  made, the save or the open stands and the person is told in one
  sentence that the file may not reopen after a relaunch. The old
  bookmark is kept when it still names the file at the recorded path
  and dropped when it does not, as after a Save As, so a relaunch never
  follows it back to the file the person saved away from. A bookmark
  renewed at restore or on activation is written to the drafts file
  without waiting for an edit.
- **A restore is two steps.** `companion_drafts_restore` puts the
  records back and reads no file of the person's. Every restored file
  is pending until `companion_file_hydrate` settles it, and the core
  refuses an edit, a save, a Save As, a reload and both conflict
  resolutions on a pending file. The shell hydrates each file inside
  its own scope and passes the path its bookmark resolved to. A path
  that differs rebinds the file before it is read, unless another open
  file that has itself been hydrated, or is held (below), already holds
  that path, in which case the recorded path is kept. When the holder
  is still waiting on its own hydration the hydration waits and is
  asked again after the holder has settled, so
  the outcome does not depend on roster order. Files that wait on each
  other, which is files that traded names, are ended by hydrating each
  at its recorded path with every one of their bookmarks' scopes open
  at once: the grant on a file's recorded path is then the bookmark of
  the file that now sits there, not its own. Each that settles is given
  a bookmark for the path it rests at. Reading across scopes this way
  has been tested for order and balance only, and has not been run
  under a sandbox. A
  bookmark that resolves inside a Trash is not followed, and the
  recorded path is read instead. One file failing affects no other.
  An open never lands on a pending file: the shell hydrates a pending
  file at that path first, inside the bracket of the URL being opened,
  and the core refuses the open while the file is still pending. When
  the restore leaves a file different from its record, the drafts file
  is written again without waiting for an edit. The six restore
  outcomes ADR-0028 lists stand and are now decided per file. A read
  the platform refused is a case that list does not name, and the next
  clause decides it.
- **A file that cannot be reached is kept, and the person can say where
  it is.** The core marks an open file `accessRefused` when the
  platform refuses a read or a stat of it for any reason other than the
  file's absence. The mark is cleared by the next read that succeeds,
  by a look that finds nothing at the path, and by a save. It is in the
  roster row and is not written to the drafts file. At restore, a clean
  record whose read the platform refused is held: it stays in the
  roster, still pending, with an empty buffer that the core refuses to
  edit or save, and it is hydrated again on every activation. Only a
  refusal by the platform holds a clean record. One that is not found,
  or whose bytes were read and are not UTF-8, look binary or pass the
  size limit, is dropped with a notice as before: a hold exists so a
  person can say where the file is or let it be read again, and neither
  would change bytes that will not open wherever the file is pointed.
  The notice reason for such a drop is `unreadable`, which is a
  different word from the `accessRefused` mark and never stands for it.
  A held file is neither saved nor unsaved. Its header reads `not read`
  where the save word stands, with no unsaved dot, and it closes at
  once with no close decision, even when its record came back marked
  dirty after a draft too large to keep. A dirty record keeps its
  draft in every case. A dirty file that is `accessRefused` stands in a
  changed conflict, and stays in it through every later check, whatever
  the stat says, until a read succeeds or keep mine, Save As or Locate
  answers it; a stat that matches the witness says nothing about
  whether this process has ever read the copy. The core also marks an
  open file `notFound` when a check, a read or a save finds nothing at
  its path, and clears the mark on the next look that finds something
  and on a save that writes. A clean file never enters a conflict, so
  that mark is what keeps a banner up for a clean file that is gone.
  Where a file is `accessRefused` or is missing, with or without
  unsaved edits, the surface offers Locate, which raises an open panel
  that starts in the recorded path's directory and names the file.
  Inside the scope of the URL the person chose,
  `companion_file_relocate` binds the file to that path, reads it and
  settles it as a hydration does: a file with no draft takes the disk
  copy, except that a live file whose disk copy holds the text it
  already holds keeps its buffer and its undo history; a draft stands, with no conflict when the disk copy is the one
  it was measured against and in a changed conflict otherwise, where
  take theirs now has a copy to take. A fresh scoped bookmark is made
  inside that scope and replaces the old one, which is dropped when no
  new one can be made. Locate is refused, and the file left exactly as
  it was, when another open file holds the chosen path or when the
  chosen file would not open. When the file holding the chosen path is
  itself held, it is hydrated first inside the panel's scope, which is
  the grant it was missing, and the refusal is said afterwards. A
  cancel changes nothing. Take theirs is not drawn while a file is
  `accessRefused` or in the missing conflict, since there is no copy
  to take. The check an activation asks for is put off
  while a file panel is up and made once the gesture that raised the
  panel has finished, so it cannot drop or rebind the file the panel is
  about.
- **A save never makes a file where there is none.** The core stats
  the path itself before every save, whether or not the shell checked
  first. When nothing is there and no keep mine stands, it writes
  nothing, marks the file `notFound`, puts a file with unsaved edits
  into the missing conflict, and refuses. A stat the platform refused
  is not an answer about absence, so that save goes on and the write
  reports for itself. Keep mine over a missing file licenses one save
  at the empty path, as it did before. The consent is bound to what it
  answered: one given while a copy was at the path is withdrawn when
  the file is later found gone, one given over an empty path is
  withdrawn when a file has since appeared there, and either is
  withdrawn when the buffer settles back to clean. A keep mine over a
  copy that changed gives up the saved text the buffer was measured
  against, since the disk no longer holds it, so that file reads
  unsaved until the save the consent was given for and cannot settle
  clean by an undo to a text the disk does not hold. A standing missing
  conflict is checked again before a save is refused for it, so a file
  that is back is judged as it now is. Save As is not refused this
  way, onto the file's own recorded path included, because the person
  chose that destination in a panel. The shell says which refusal it
  was, from the reason the core gives
  (`companion_file_save_error_json`): a file with no unsaved edits is
  told it was not saved and offered Locate and Save As, one with
  unsaved edits is told what its conflict banner offers, and a write
  the platform refused is said as a write that failed. This follows the file editing
  specification's sentence under External changes, "The pad does not
  recreate a file at a path a person deleted.", which describes
  ADR-0028's proposed decision and is not an accepted record.
- **A file moved while the app is running is followed.** When a check
  finds nothing at the recorded path and the file's bookmark has
  resolved to a different path that is not inside a Trash, the shell
  relocates the file to that path inside the scope it already holds,
  through the same core call Locate uses, and makes the bookmark again.
  A clean file follows without a word unless its text differs, which is
  said as a reload. A draft stands, and a save lands at the new path.
  When the core refuses the new path, the file is reported missing.
- **A record with a plain bookmark is still honoured.** A bookmark that
  does not resolve as a scoped one is resolved plainly and the
  operation runs with no scope. Outside a sandbox that is enough, and
  the bookmark is replaced with a scoped one once the file has been
  read. Inside a sandbox the read is refused for that file alone: a
  clean record is held and a dirty record keeps its draft in a
  conflict, and either can be located.

ADR-0028 is replaced in two places and stands everywhere else. Its
clause headed "Plain bookmarks now, security scoped later" is replaced
by the clauses above. In its clause headed "Explicit save only", the
sentence that describes the write as "a temporary file in the same
directory, flushed, then renamed over the target" is replaced by the
staging clause; the rest of that clause, that the pad writes a file
only when asked and that the write is atomic, stands.

### Open questions

This record is proposed, and these are not settled by it:

- **The accepted design record counts three conflict actions.** D-17
  in
  [the UI/UX decision record](../spec/design/2026-0915-ui-ux-decisions.md)
  reads "Three actions in reading order, named by what they keep, with
  Save As (the one that destroys nothing) last and under the return
  key", and its acceptance reads "the sentence is a pure function of
  conflict and filename". Locate is a fourth kind of action, placed
  first with Save As still last, and the banner's sentence also depends
  on the `accessRefused` mark. The amendment is written as a draft
  record,
  [2026-0930-file-conflict-locate.md](../spec/design/2026-0930-file-conflict-locate.md),
  which the maintainer has not ratified. Until it is accepted, D-17
  stands and the surface this record describes differs from it.
- **The untested parts of decided clauses.** Resolution with
  `.withoutUI` and `.withoutMounting` has not been run under a sandbox.
  The item replacement directory was observed for one volume only; if
  it is ever on another volume than the target the rename fails and the
  save is refused, in an unsandboxed build as well. Following a file
  moved while the app runs rests on the bookmark resolving to the new
  path in the running process, which the probe measured across a
  relaunch only. Reading files that traded names with all of their
  scopes open has been tested for order and balance and not under a
  sandbox. Whether a sandboxed build sees the state an earlier
  unsandboxed build wrote under the same bundle id has not been
  measured. The held file's header word and the banners have not been
  looked at on screen.

## Consequences

- A sandboxed build can open, edit, save and reopen a person's file,
  subject to the hardware checks that have not been run.
- The access scope is not held in one function, as ADR-0028 expected.
  It is held in one type, `FileCoordinator`, and entered from one
  helper in `PageModel`, the panel routes (open, Save As and Locate)
  and the restore. A new call that
  makes the core touch a person's file must go through one of them, and
  nothing but review and the counting tests enforces that.
- Every lane stages its saves, so the builds a developer runs exercise
  the route the sandboxed build depends on. The cost is that a save now
  depends on the system providing a staging directory on the right
  volume.
- A save still replaces the inode. The mode is kept, and a mode that
  cannot be set now fails the save. The group is restored when the user
  is able to. Hard links and extended attributes are lost as before.
  Destination-directory inherited ACLs are not preserved: a temp file
  created in a separate staging directory inherits from that directory,
  not the destination's. Carrying mode and group does not reproduce
  those ACLs, so replacement can change effective access in managed or
  shared directories. This is a limitation of the staged-save implementation,
  not a completed hardware-verification result.
  The mode and group handling applies to the temp file beside the
  target as well, so a save with no staging directory also behaves
  differently than it did: a group writable file keeps that bit.
- Launch does more work in the shell: one bookmark resolution and one
  scope per open file before the roster is published. The C ABI grows
  `companion_file_hydrate`, `companion_file_relocate` and
  `companion_file_save_error_json`, the two save calls take a staging
  directory argument, and the roster row gains `pendingHydration`,
  `accessRefused` and `notFound`.
- The refused rebind at restore has no signal of its own. The shell
  infers it from the roster row's path being unchanged.
- A save no longer writes at a path where nothing is. The ways to put
  the text somewhere are Locate, Save As, and keep mine for a file with
  unsaved edits. `companion_file_save` still answers with one bool, and
  the core keeps the reason for a false until the next save, so the
  shell tells this refusal from a failed write by asking
  `companion_file_save_error_json` and not by reading the roster row.
- A file kept over a changed disk copy reads unsaved until it is saved,
  even when its text is undone or typed back to what it held before the
  edit. The alternative read saved over a disk that held the other
  copy.
- A caller that restores and never hydrates leaves every file unusable
  rather than silently stale. That is deliberate: a pending file's
  buffer is empty, and saving it would put an empty buffer over the
  file.
- A pending file can now be on screen. A held file is published with
  no text and an editor that takes no typing, and a save or a Save As
  asked of it is refused with a sentence.
- The conflict banner has a fourth kind of action, Locate, which
  stands where take theirs does not in two of its states, and a second
  banner exists for a file that cannot be reached with no conflict
  standing.
- Drafts written by an earlier build carry plain bookmarks. Under the
  sandbox those files cannot be read at launch. A person who moves from
  an unsandboxed build to a sandboxed one, if the sandboxed build sees
  the earlier state at all, finds the clean tabs held and the dirty
  ones in conflict, and has to locate each file once.

## Eject triggers

- A hardware run under a real sandboxed signature shows any operation
  in the [procedure](../qa/verification-procedures/sandbox-file-access.md)
  refused inside its bracket. That reopens the bracket design, or, if
  no bracket held in Swift can cover a write done in the core, where
  file IO lives (the trigger ADR-0028 names).
- The item replacement directory is observed on a different volume
  from the target, or unavailable, in ordinary use. That reopens the
  no fallback rule and the choice of staging directory.
- A bookmark made after a save is observed failing to resolve after a
  move, or a sandbox extension is observed surviving the stop in a way
  the design comes to depend on. Either falsifies E6 or E8.
- The log shows scopes started and not stopped, or a stop with no
  start, in a run of the procedure.
- App review or a platform change requires
  `com.apple.security.files.bookmarks.app-scope`, or stops accepting
  `files.user-selected.read-write` as sufficient for scoped bookmarks.
- Locate is observed failing to give back access under a real sandbox:
  the panel's URL does not let the core read the file, or the bookmark
  made from it does not reopen the file after a relaunch.
- A file moved while the app runs is observed bound to the wrong file,
  or followed into a place the person did not move it to.

## Decision history

- **2026-09-30:** Proposed, with the implementation on
  `feature/sandbox-file-access`. Implementation notes are in
  [file-backed document implementation](../development/file-backed-documents.md).
  No hardware run under a sandboxed signature has been made.
