---
documentation_status: needs-review # draft | reviewed | stale
---

# ADR-0031: Restored file dirtiness follows save output

- **Status:** proposed
- **Date:** 2026-09-16
- **Depends on:** [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

The related product sources are the accepted
[UI/UX decision record](../spec/design/2026-0915-ui-ux-decisions.md#6--files-and-the-unsaved-state)
and the proposed
[file backed documents specification](../spec/feature/file-editing/README.md#saving).

## Context

Take theirs adopts the disk copy as a structural edit. During the live session,
Undo restores the prior draft generation and marks it dirty; Redo reapplies the
disk generation and settles it clean. Generation identity matters there even
when the normalized text on both sides is equal, because the undo marker still
makes the two choices reachable.

The drafts restore path does not restore undo history. It can nevertheless
restore the persisted `take_theirs_undone` flag while
`active_take_theirs_generation` is absent. That flag then pins the file dirty
after hydration even when the bytes a save would produce are already the bytes
on disk. No Undo or Redo remains through which the person can observe or change
the generation distinction. The only way to clear the marker is Save or Reload.

Save is available in this state when no external conflict stands. It performs
the normal atomic replacement and settles the file clean. Requiring that write
only to acknowledge lineage that the editor no longer retains is not neutral:
the file specification states that the replacement creates a new inode, that a
second hard link keeps pointing at the old text, and that extended attributes
and ownership the writer cannot set do not survive.

Two authoritative surface rules constrain the answer:

- The accepted UI/UX record says: “The question the header answers on a file
  surface is which file this is and whether it is on disk.”
- The file specification says: “The dot appears on the first edit that changes
  the bytes and clears on a successful write.”

An `unsaved` word, draft-age stamp, dirty-close decision, and ember dot therefore
misstate a restored file whose save output already equals the disk artifact.
Preserving that presentation would require preserving the corresponding undo
history, not only a boolean about history that was discarded.

## Decision

At the relaunch boundary, a Take theirs generation may govern dirty state only
when its associated undo marker and history are restored with it. With the
current restore model, which discards file undo history, hydration classifies an
unchanged readable file by comparing the exact bytes a save would produce with
the bytes on disk.

The boundary is:

- During the live session, retain generation-sensitive dirty behavior while the
  active Take theirs marker remains in undo history. Undo can restore the prior
  generation as dirty and Redo can settle the adopted disk generation clean.
- Retire the override inside the live session too, at the moment the marker
  stops being reachable. A local commit drops the redo stack, so a person who
  undoes Take theirs and then types can never reach the disk generation again.
  From that commit onward the file's dirty state is decided by its baseline
  comparison alone, for the same reason the relaunch boundary refuses an
  orphaned marker: a file cannot read unsaved on the authority of a choice no
  Undo or Redo can show.
- Do not restore `take_theirs_undone` as an active dirty-state override without
  its matching generation and undo history. A persisted field may continue to
  be parsed for format compatibility, but it has no authority by itself.
- After successful hydration against an unchanged disk copy, mark the file
  clean when its save output is byte-identical to disk. Clear the orphaned
  generation override; do not show the unsaved word, dot, restored-draft age, or
  dirty-close decision for that file.
- Keep the file dirty when its save output differs from disk. Clearing the
  generation override must not clear a real restored edit.
- When the disk copy changed, disappeared, or could not be read, retain the
  existing conservative conflict behavior. This decision does not infer byte
  equality across a failed or stale read.
- The live session does not follow save output. It compares the buffer's
  normalized text with the text the buffer was born from, which is the reading
  that answers the surface question "have you changed anything since this was
  last in step with disk". The two readings can differ for one class of file:
  one whose exact bytes the writer cannot reproduce, such as a file with mixed
  line endings, where a save rewrites every ending in the file's classified
  style. Comparing bytes live would open such a file already unsaved with
  nothing typed, contradicting the file specification's "the dot appears on the
  first edit that changes the bytes". Hydration has no such birth moment to
  protect: it has only bytes, so it uses bytes, and where the two readings
  disagree the disagreement falls toward dirty rather than toward a false clean.
- Keep Save available for an active file. Save continues through the normal
  before-save external-change check and conflict refusal; it is not required as
  an acknowledgement step for an otherwise clean restored file.

## Consequences

- The header and navigation marker describe the disk artifact rather than
  inaccessible edit lineage. A byte-identical restored file reads `saved`.
- Relaunch becomes an explicit lifetime boundary for generation-only dirty
  state, matching the existing boundary for file undo history.
- A restored draft whose output differs from disk remains dirty, keeps its age,
  survives in the drafts file, and receives the existing close and conflict
  protections.
- A generation-distinct but byte-identical draft is no longer retained as
  unsaved work after hydration. The application gives up preserving a semantic
  distinction that has no surviving Undo or Redo operation.
- A person who undoes Take theirs, types, and then edits back to the disk text
  sees the file read saved. The generation distinction is given up at the same
  moment the operations that expressed it become unreachable, rather than
  lingering until the next Save, Reload, or Take theirs.
- Take theirs over an empty buffer and an empty disk copy writes no operations
  and therefore offers no Undo. An enabled Undo that does nothing when pressed
  would be a worse account of the state than no step at all.
- The persistence reader may need to accept the old generation field after the
  writer stops relying on it. Existing drafts remain readable without allowing
  an orphaned marker to control the surface.
- Tests that currently pin dirty state for an equal-text undone Take theirs
  after relaunch must instead prove byte equality, clean presentation, absent
  Undo and Redo, and normal Save availability. Tests for unequal restored drafts
  and changed or missing disk copies remain dirty or conflicted.
- Avoiding an acknowledgement-only atomic replacement also avoids triggering
  the replacement effects already documented by the file specification.

## Eject triggers

- File undo history is persisted across relaunch with enough information to
  restore the active Take theirs generation and make Redo reachable. Reconsider
  whether generation-sensitive dirty state should then survive with that
  history.
- The file artifact expands beyond save output bytes to include metadata that
  the editor can read, preserve, and intentionally edit. Replace byte equality
  with an artifact-equivalence definition before applying this decision to that
  metadata.
- A distinct, user-visible “restored decision pending” state is introduced with
  actions other than Save and Reload. Reconsider whether that state should be
  presented separately from `unsaved`, rather than encoded through the dirty
  flag.
- Testing demonstrates a case classified clean in which the bytes produced by
  an immediate Save differ from the bytes read during hydration. Treat that as
  evidence that the equivalence calculation is incomplete and revisit the
  comparison boundary before shipping it.

## Decision history

- 2026-09-16: Proposed after review of the restored undone Take theirs state,
  where generation dirtiness survived but its active generation and undo
  history did not.
- 2026-09-16: Extended after review to retire the live override when a local
  commit makes the marker unreachable, to state why the live path reads
  normalized text rather than save output, and to record that an empty adoption
  over an empty disk copy leaves no undo step. The drafts writer stopped
  emitting the generation field; the reader now steps over it by frame length.
