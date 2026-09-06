---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0028: File backed documents are a peer content class

- **Status:** proposed
- **Date:** 2026-09-04
- **Depends on:** [ADR-0001](0001-rust-core-thin-shell.md), [ADR-0010](0010-form-factors-as-sibling-targets.md), [ADR-0016](0016-content-persists-across-restart.md), [ADR-0017](0017-durable-tabs-expiring-pages.md), [ADR-0020](0020-a-day-is-a-projection-of-live-pages.md), and [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md).

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

Dogfooding puts two kinds of text in front of the same person: staged
notes that are useful now and gone on schedule, and files that already
exist on disk and are expected to outlive the app. The pad serves only
the first. Opening the second means leaving the pad, which keeps it from
being the place a person's text lives.

The constraint is that the pad's existing model has no slack for a
document without a deadline. ADR-0017 makes expiry a property of the
page, ADR-0020 buckets days by live pages, ADR-0016 ties key rotation to
predicates over pages and tabs, and ADR-0021 defines a relay channel
that carries page key frames and page deltas. A document with no TTL
does not fit any of those, and forcing it in adds a branch to each.

Tenet 2 supplies the shape of the answer. For a page the artifact is the
sealed state file the pad owns. For a file the artifact is the file on
disk, which other programs write and whose lifetime nobody asked the pad
to manage. These are different artifacts, so they are different classes.

Tenet 1 supplies the constraint on the answer. Explicit saving means a
person can be several minutes of typing ahead of the file on disk, and
that typing must survive a crash, a force quit and a restart without the
app writing to a file it was not asked to write.

Product behaviour, interaction detail, layout and open questions belong
in the
[file backed documents specification](../spec/feature/file-editing/README.md).

## Decision

File backed documents are an additional content class, a peer to pages,
and both are first class features of the pad: the file on disk is the
artifact, the pad is an editing interface over it, and no mechanism in
the pad ever destroys or expires its contents.

The clauses that fix the boundary:

- **No TTL, no gauge, no day, no cap.** A file has no countdown, no
  rung, no hold, and no chips. It never enters the ADR-0020 day
  projection and is never counted against the nine page cap. Expiry
  remains a property of pages alone.
- **No sync.** Nothing about a file crosses the ADR-0021 relay: not its
  contents, not its draft, not its name, path or bookmark. The relay's
  scope is pages and this decision does not widen it.
- **Explicit save only.** The pad writes a file when the person asks,
  through Save or Save As, and at no other time. The write is atomic:
  a temporary file in the same directory, flushed, then renamed over the
  target.
- **Staged drafts for crash safety, for exactly as long as the tab.**
  Unsaved edits are sealed into the app's own state, keyed by the file's
  bookmark, and restored at the next launch. A draft is never written to
  the file until the person saves. It is destroyed by a save, by an
  explicit discard, or by an erase of the app's state, and by nothing
  else. Closing a dirty file's tab raises the standard macOS review of
  Save, Discard or Cancel, so a draft never outlives its tab and
  reopening a file never resurrects earlier edits. A restored dirty
  file shows the time of its last edit beside the unsaved marker.
- **Drafts live in a third sealed file.** They are not a new section in
  the page snapshot and not a field on the Tab record. They are their
  own sealed file, with its own plaintext magic and its own envelope
  magic, sealed under the same content key as the page state. Whenever
  that key rotates, the drafts file is rewritten under the new key in
  the same operation. That includes the automatic content erase which
  fires when no tab holds a page: with any file open it reseals the
  drafts rather than dropping them, so a page lifecycle event never
  destroys a person's unsaved file edits. Only an empty roster lets the
  drafts file go. Rotation predicates that ask whether any tab holds a
  page are neither triggered nor blocked by drafts.
- **Drafts are bounded, and the bound is a live path.** A draft is the
  editing history rather than the file's text, so it can outgrow the
  file. Above four times the file size limit, that file's record is
  written as identity only and a notice names the file. The other open
  files' drafts are unaffected. A refusal at open time could not make
  this unreachable, because the bound depends on editing that has not
  happened yet.
- **The Rust core owns file IO.** Reading, encoding validation, size
  refusal, change detection, atomic writing and draft staging live in
  the core behind one trait, so sibling form factors get the same
  behaviour from the same code (ADR-0001, ADR-0010). Paths cross the
  FFI; file bytes do not.
- **The Swift shell owns the platform surface.** Open and save panels,
  bookmarks, the File menu, the tab and shelf views, and the conflict
  presentation are the shell's.
- **Files are not pages to persistence.** A file backed document does
  not enter the page snapshot object graph, does not participate in the
  no tab holds a page or no tabs remain predicates, and produces no
  ledger entries. Drafts are stored as file drafts, outside that graph.

- **No new keymap context, and no rebinding.** The two existing command
  ids `state::SaveNow` and `page::Close` each gain a second reading on a
  file target, as the registry already does elsewhere for one intent
  that means two things on two surfaces. Their raw ids are published
  contract and do not change. Only Open and Save As are new ids. All of
  them live in the `Editor` context. The app gains its first File menu,
  which reads its chords from the keymap file.
- **Plain bookmarks now, security scoped later.** The app is not
  sandboxed today; its only entitlement is keychain access groups. So
  files are reopened through plain URL bookmarks, which already track
  renames and moves. Creating and resolving bookmarks and opening the
  panels live in one shell function, so the security scoped variant is a
  small change rather than a search. This decision is therefore coupled
  to the sandbox that App Store distribution will require: when the
  sandbox arrives, the scope must be started and stopped in that one
  function around a write performed in the core, and a write attempted
  outside it must fail loudly rather than truncate a person's file.

- **A restore reads the files, and settles each tab on its own.** The
  drafts file records a clean file's identity and not its text, so
  launch reads each file from disk and settles into one of six states:
  clean and unchanged, clean and changed with a reload notice, clean and
  missing which drops the tab with a notice, dirty and unchanged which
  keeps the draft and learns the saved text so undo can reach clean
  again, dirty and changed which opens in conflict, and dirty and
  missing which also opens in conflict. One unreadable file costs its
  own tab and no other.
- **Only regular files are opened, and symlinks are followed once.**
  A directory, a device node or a named pipe is refused rather than
  read. A symlink is resolved at open, so a save lands on the real file
  and the link stays a link, and two paths that resolve to one file are
  one open file.
- **Keep mine licenses exactly one save.** Choosing it takes a fresh
  reading of the file being overwritten and sets a consent that the
  before save check honours and that the save spends.
- **Save As onto a path another open file holds is refused**, before
  anything is written.

Scope for the first release: plain text and Markdown, UTF-8 only, files
up to 4 MiB, one file per tab.

Why the drafts file is separate rather than folded into what already
exists. Adding a top level files section to the page snapshot would be a
format break, and a format break discards every user's pages once. The
alternative that breaks nothing is a trailing field on the Tab record,
and it is rejected for a different reason: it would make a file's draft
a property of a Tab. The Tab is the object the nine tab cap counts, the
object ADR-0017 gives strip order and a rung, and the object the key
rotation predicates walk. Every clause above about what a file is not
would become a rule a future reader must remember instead of a fact the
format enforces, and open files would be capped at nine by accident,
which nobody decided. A third sealed file keeps the two classes apart
structurally and extends a pattern the module already uses twice.

## Alternatives considered

**A page with an infinite TTL.** The smallest change on paper and the
largest in practice. Every place that reads a countdown, draws a gauge,
buckets a day or decides a rotation predicate would grow a case for
content that never ages. It also makes the pad's forgetting a
suggestion: a reader could no longer tell by looking whether what is on
screen is on a clock. Rejected because it dilutes the one property the
pad is built around in order to avoid naming a peer class.

**Autosave in place, as `NSDocument` does.** Familiar on macOS and wrong
here. It means the pad writes to a person's file without being asked,
including files under version control and files other programs are
watching. It also removes the saved and unsaved distinction that makes
the orange dot meaningful. Rejected because the pad should never modify
an artifact it does not own except on request.

**Drafts held only in memory.** Simple, and it fails tenet 1 exactly
where the tenet is sharpest. With explicit saving, a person can be far
ahead of the file, and a crash or a force quit would take all of it.
Rejected because a class of content that can lose work is not a class
this project ships.

**Drafts that outlive their tab.** An earlier draft of the
specification kept a draft after its tab closed, so reopening a file
restored unsaved edits. It reads as the tenet 1 answer and is in fact a
trap: a person reopens a file, sees text they do not recognise as old,
presses Cmd S, and overwrites the file with typing from an unknown
earlier session. Rejected in favour of the standard macOS review at
close, which asks the question at the moment the person still has the
context to answer it.

**Files as synced pages.** Attractive because the sync machinery already
moves documents between a person's devices. It fails on two counts. It
would put a person's own file contents through the relay, widening what
the relay handles from staged pages to arbitrary user files, which is a
different privacy conversation than ADR-0021 had. And the file already
has a synchronisation story the person chose: their own git repository,
their own file sync, their own backups. Rejected as both out of scope
and redundant.

## Consequences

- The pad becomes usable for durable text without any page acquiring an
  exemption from expiry. Pages, gauges, days, the cap, the sealed format
  and the relay are unchanged.
- The app now owns a write path to files outside its own state
  directory. That is new risk surface, and it grows again at the
  sandbox boundary, where the access scope will be held in Swift around
  a write performed in the core. The atomic write and the before save
  change check bound the first part; the single shell function bounds
  the second.
- Two content classes means two of several things in the interface: two
  tab groups, two save models, two meanings for closing a tab. The
  specification's job is to keep the difference legible rather than
  hidden.
- The app's state directory grows a third sealed file, with its own
  restore path, its own strict envelope check and its own place in every
  rotation and erase operation. Drafts cannot accumulate without bound,
  since each one lives only as long as its tab.
- Closing a dirty file tab is now a question the person must answer.
  That is a modal in a product that avoids them, accepted here because
  it is the moment at which the person still knows what the edits were.
- Deferring encodings other than UTF-8, and refusing above 4 MiB, means
  some files simply cannot be opened. Both refusals are explicit and
  name the reason.
- The pad's promise about forgetting now needs a sentence about files
  whenever it is stated publicly, since files are content the pad holds
  and does not forget. That sentence is owed anywhere the claim appears.
- Choosing no relay for files means a person editing the same file on
  two Macs gets no help from the pad. That is deliberate.

## Eject triggers

- The change check and atomic write are observed losing or corrupting a
  person's file. That reopens the write path, not the class split.
- Users routinely open files that are not valid UTF-8, or routinely hit
  the 4 MiB refusal, making either a common dead end rather than a rare
  one.
- A draft is observed reattaching to the wrong file, or surviving an
  operation that should have destroyed it.
- The drafts bound fires in ordinary use rather than rarely, so people
  lose editing history they expected to come back.
- The sandbox arrives and the single shell function cannot hold the
  access scope around a write performed in the core. That reopens where
  file IO lives, not the class split.
- Users ask for the same file on two devices often enough that the no
  sync clause, rather than a client side file sync of their own, is what
  is blocking them.
- The two class model is consistently misread in dogfooding, for example
  people expecting a file to expire or expecting a page to be on disk.
- A sibling form factor arrives and cannot use the core's file IO,
  which would mean the ADR-0001 and ADR-0010 rationale for placing it
  there did not hold.
- A second automatic lifetime mechanism is proposed for files; that
  reopens this decision together with ADR-0016 and ADR-0017.

## Decision history

- **2026-09-04:** Proposed, alongside the
  [file backed documents specification](../spec/feature/file-editing/README.md).
- **2026-09-05:** Implemented on `feature/regular-text-files`. The
  record was corrected in two places against the code: the automatic
  content erase reseals drafts rather than dropping them when any file
  is open, and the app has no Clear or Empty confirmation that could
  name discarded drafts. The drafts bound, the restore branches, the
  regular file and symlink rules, the keep mine consent and the Save As
  refusal were added. The decision remains proposed. Implementation
  notes are in
  [about file backed documents](../development/about-file-backed-documents.md).
- **2026-09-05:** The quit behaviour question is closed by the
  maintainer: a quit with a dirty file open now says so and names the
  files, rather than going silently. It is a notice and not a save or
  discard sheet, with Quit Anyway and Cancel and no third button,
  because the draft survives the quit and a Discard would create the
  loss path the feature otherwise does not have (`QuitPrompt`).
- **2026-09-05:** The two clauses no test in this repository can reach,
  the staged drafts clause across a `kill -9` and the resealing clause
  across the automatic content erase, were verified on hardware. All
  three cases of
  [the draft lifecycle procedure](../qa/verification-procedures/file-draft-lifecycle.md)
  pass.
