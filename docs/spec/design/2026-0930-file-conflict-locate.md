---
id: 2026-0930-file-conflict-locate
title: Locate on the file banners, and a file that cannot be reached
status: draft        # draft → accepted → superseded
dated: 2026-09-30
supersedes: docs/spec/design/2026-0915-ui-ux-decisions.md, on D-17's count of actions and the inputs of its sentence only, and on section 6's list of header words and banners only. Takes effect only if this record is accepted.
superseded-by:
reviewed:
surfaces: OnetimePad (file surface)
sources:
  - docs/spec/design/2026-0915-ui-ux-decisions.md
  - docs/spec/feature/file-editing/README.md
  - docs/adr/0028-file-backed-documents-are-a-peer-content-class.md
  - docs/adr/0035-sandboxed-file-access-holds-a-scope-around-core-io.md
  - shell/Sources/CompanionKit/FileSurface.swift
  - shell/Sources/CompanionKit/CompanionClient.swift
  - shell/Sources/CompanionKit/PageModel.swift
  - shell/Sources/CompanionKit/PageSurface.swift
  - crates/core/src/files.rs
---

# Locate on the file banners, and a file that cannot be reached

**This record is a proposal.** Its status is draft, and it awaits the
maintainer's ratification in the pull request that carries
`feature/sandbox-file-access`. Until it is accepted, the 2026-0915
record states what the build owes, and nothing below is a decision the
project has made. Every decision here is marked *proposed* for that
reason.

The build on that branch already does what this record describes. That
is the reason to ratify or reject it before the branch merges, since
the 2026-0915 record says of itself that "An accepted record and a
contradicting build are a bug report, not a disagreement."

## 1 · What the accepted record says

D-17 in
[2026-0915-ui-ux-decisions.md](2026-0915-ui-ux-decisions.md), accepted,
reads:

> A conflict refuses the save, never the typing. Three actions in
> reading order, named by what they keep, with Save As (the one that
> destroys nothing) last and under the return key.

and its acceptance reads:

> the sentence is a pure function of conflict and filename; the two
> conflict kinds are testable as words rather than as a drawn banner.

Section 6 of the same record names two banners above the editor, the
conflict banner and the render suggestion banner, and gives the header
two save words.

## 2 · Why it is reopened

Under the App Sandbox a file can be out of reach in a way the 2026-0915
record did not have to describe: the file is there and the system
refuses the read. The working brief for this branch says the maintainer
asked on 2026-09-30 for a way to point the app at such a file. That
brief is not an accepted record, and this one is where the request
would become a decision.

The mechanism is [ADR-0035](../../adr/0035-sandboxed-file-access-holds-a-scope-around-core-io.md),
which is itself proposed. This record covers only what a person sees.

Two facts about an open file come from the core in its roster row and
are used below. `accessRefused`: the system refused the last read or
stat of the file for a reason other than the file's absence.
`notFound`: the last look at the path found nothing there.

## 3 · What is proposed

- **D-49 (proposed)** The conflict banner's actions depend on whether
  the other copy can be reached. Keep mine and Save As are always
  offered. **Locate…** is offered in front of them when the file is in
  the missing conflict, is marked `notFound`, or is marked
  `accessRefused`. **Take theirs** is offered unless the file is in the
  missing conflict or is marked `accessRefused`, since there is then no
  copy to take. The order is fixed: Locate…, Keep mine, Take theirs,
  Save As. Save As stays last.

  | the file, with unsaved edits | the actions, in order |
  | --- | --- |
  | changed on disk | Keep mine · Take theirs · Save As |
  | no longer at its path | Locate… · Keep mine · Save As |
  | cannot be read at its path | Locate… · Keep mine · Save As |

  Locate does not choose between the copies. It finds the one that is
  out of reach, and if the two then differ the banner becomes the first
  row. It asks no confirmation and has no chord, and cancelling its
  panel changes nothing. The panel is the platform open panel, which
  D-14 already sets apart from an app dialog.

  This amends D-17's "Three actions". It does not change D-17's clause
  about the return key. The build binds no key to Save As in the
  banner, which differs from that clause, and this record neither
  adopts nor settles that difference.

  *Acceptance:* `FileConflictBanner.actions(for:)` is the pure list;
  `FileSurfaceTests.testTheConflictBannerOffersLocateOnlyWhenTheOtherCopyCannotBeReached`.
- **D-50 (proposed)** The conflict banner's sentence is a pure function
  of three inputs: the conflict, the filename and the `accessRefused`
  mark. D-17's acceptance names the first two. The three sentences:

  - changed: `NAME changed on disk and this copy has unsaved edits ·
    saving is refused until one copy is chosen`
  - missing: `NAME is no longer at its path and this copy has unsaved
    edits · saving is refused until one copy is chosen`
  - `accessRefused`, in either conflict: `NAME cannot be read at its
    path and this copy has unsaved edits · saving is refused until one
    copy is chosen`

  The third is said in place of "changed on disk" because the core puts
  a draft whose file it cannot read into the changed conflict, and what
  is known is only that the file cannot be read.

  *Acceptance:* `FileConflictBanner.sentence(for:)`;
  `FileSurfaceTests.testTheConflictBannerNamesTheFileAndSaysSavingIsRefused`
  and `testAnAccessRefusedConflictSaysTheFileCannotBeReadRatherThanThatItChanged`.
- **D-51 (proposed)** A third banner, the unavailable banner, stands
  above the editor when no conflict stands and the file is marked
  `accessRefused` or `notFound`. It has the conflict banner's metrics
  and is nonmodal. Its sentence is a pure function of the filename, the
  path and the two marks:

  - `NAME cannot be read at PATH`
  - `NAME is no longer at PATH`, when the file is `notFound` and not
    `accessRefused`

  Its actions are **Locate…** and **Close**, in that order. It stands
  for three kinds of file: one the launch is holding because nothing of
  it could be read, a file with no unsaved edits that has gone or
  cannot be read, and a file with unsaved edits whose conflict keep
  mine has already answered. The conflict banner and the unavailable
  banner never stand together.

  This amends section 6's "Two banners can stand above the editor".

  *Acceptance:* `FileUnavailableBanner.stands(for:)` and
  `sentence(for:)`;
  `FileSurfaceTests.testTheUnavailableBannerStandsForAFileThatCannotBeReadAndIsInNoConflict`
  and `testTheUnavailableBannerStandsForACleanFileThatIsNoLongerAtItsPath`.
- **D-52 (proposed)** A held file is neither saved nor unsaved. A held
  file is one restored at launch whose read the system refused, so that
  nothing of it is in the buffer. Its header reads `not read` where the
  save word stands, with no dot, no draft stamp and no format facts.
  Spoken: "NAME, not read, this file cannot be read at its path". Its
  row is spoken "file, NAME, not read, cannot be read at its path". It
  closes at once, and the dirty close decision is never raised for it,
  because it holds no typing to save, discard or keep.

  This amends section 6's header, which gives the save state as
  unsaved or saved only. The word `not read` has not been looked at on
  screen.

  *Acceptance:* `FileHeaderState.derive(from:renderMode:)` and
  `FileRowLabel.spoken(for:)`;
  `FileSurfaceTests.testAHeldFileReadsAsNotReadAndNeverAsSavedOrUnsaved`;
  `FileAccessTests.testClosingAHeldFileWhoseRecordReadsDirtyNeverAsksTheDirtyCloseDecision`.
- **D-53 (proposed)** A save can be refused with no conflict standing,
  in two cases, each said in one sentence as a notice:

  - a file with no unsaved edits and nothing at its path: `NAME is no
    longer at its path, so it was not saved. Choose Locate to find it,
    or Save As to write it somewhere.`
  - a held file: `NAME has not been read, so there is nothing to save.
    Locate the file or close the tab.`

  A save refused inside a conflict names the actions the banner is
  drawing: `NAME is no longer at its path. Choose Locate, keep mine, or
  Save As before saving.` and `NAME cannot be read at its path. Choose
  Locate, keep mine, or Save As before saving.`, beside the existing
  `NAME changed on disk. Choose keep mine, take theirs, or Save As
  before saving.`

  The first case follows the file editing specification, External
  changes, which reads "The pad does not recreate a file at a path a
  person deleted." That specification describes a proposed decision
  (ADR-0028) and is not an accepted record.

  *Acceptance:* `PageModel.saveNotFoundNotice(name:)`,
  `heldFileNotice(name:)` and `unresolvedConflictNotice(for:)`;
  `FileSurfaceTests.testASaveOfAFileThatIsGoneNamesLocateAndSaveAs` and
  `testARefusedSaveNamesTheActionsTheBannerActuallyOffers`.

## 4 · What this record does not change

Everything in the 2026-0915 record outside D-17's count of actions, the
inputs of its sentence, and section 6's list of header words and
banners. In particular: a conflict refuses the save and never the
typing (D-17), no modals (D-14), the copy register (D-15), two "saved"
words never show at once (D-18), and no save sheet on quit (D-19).

The illustrated companion, `UI-UX Decision Record - Sealed Content.html`,
carries D-17's text and is not edited by this record.

## 5 · Noted in the 2026-0915 record

One dated note, at D-17, pointing here and saying that the amendment is
proposed and not ratified.

## 6 · What has not been seen

No banner, header word or sentence in this record has been looked at on
screen, under a sandbox or outside one. The words are asserted by the
tests named above, which run without a window. The hardware procedure
is
[sandbox-file-access.md](../../qa/verification-procedures/sandbox-file-access.md).
