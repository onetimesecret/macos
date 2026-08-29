# ADR-0025: Block revision history is a projection of the op log

- **Status:** proposed
- **Date:** 2026-08-28

## Context

The dogfood wish (DOGFOOD.md, commit `2e58158`): the created and
modified stamp above a block should be a clickable element that
reveals the block's prior versions. The motivating workflow is
wording work, iterating on a prompt or the text of an email, where
the thing you want back is a phrasing you had an hour ago and edited
away.

Everything this feature needs to read already exists, and the reason
it exists is ADR-0013. The document is a Loro op log with change
merging disabled, so every commit is its own change with its own
timestamp; created and modified are derived from the ops
(`SheetDocument::span_provenance`), not stored. The log is bounded by
the compaction ceremony: at every accepted rung transition and hold
top-up the block summaries graduate to materialized fields, the
document is reborn from its runs under a fresh peer identity, and the
trail dies (`Sheet::compact`, `SheetDocument::compact`). With peers
attached the ceremony defers to the sync channel and runs as a
coordinated event (issue #101, ADR-0021).

So the tension is not whether prior versions are recoverable. Inside
the horizon they already are; the device remembers them today,
invisibly. The tension is that a prior version of a block is exactly
the "reconstructible record of deleted content" that ADR-0013's
security claim promises does not exist past the compaction boundary.
Any design that stores version snapshots outside the op log, to make
history survive the ceremony, is the retention smuggling ADR-0013
warns about: a second, weaker retention story that quietly breaks the
claim. The feature is only honest if it shows what the op log holds
and nothing else.

## Decision

Block revision history is a read-time projection of the operation
log, bounded by the compaction horizon, storing nothing. The stamp
above a block opens a read-only panel of that block's prior texts,
derived on demand from the ops. Recovery is an ordinary edit.
History that the ceremony has destroyed is gone from the panel too;
that is the design, not a gap.

Concretely:

**A revision is a distinct past text of the block at a quiet
moment.** Candidate boundaries are idle gaps in the page's change
log: successive changes separated by more than a gap threshold close
one revision and open the next. At each boundary the block's text is
reconstructed by forking the document at that frontier
(`LoroDoc::fork_at`) and resolving the block's anchor in the fork;
consecutive identical texts collapse into one revision, so a boundary
that did not touch this block contributes nothing. A frontier where
the anchor does not resolve predates the block, and the list simply
starts later. The gap threshold is a display parameter applied at
read time, not recorded anywhere, so it can be tuned freely without
touching stored state.

**Derivation is read-time and click-driven.** Nothing is computed or
cached while typing. Opening the panel walks the log once and forks
per candidate boundary; the cost lands on the click, scales with the
number of revisions, and evaporates when the panel closes.

**The panel is a read-only projection** in the sense of ADR-0013's
editable-surface rule, the same tier as search results or an
importance lens. It lists revisions newest first, each under its
`DDD HH:mm` stamp. Two actions, both ordinary edits performed on the
in-order sheet, both undoable, both stamping modified now:

- **Restore** replaces the block's current text with the revision's
  text, as one commit. A restore is a new edit whose content happens
  to be old. It does not rewind stamps or rewrite history; like a
  manual retype, it replaces every character, so the block's derived
  created stamp moves to the restore until compaction graduates the
  summary. The materialized created, once graduated, is unaffected.
- **Insert below** lands the revision's text as a new block after the
  current one, for holding two phrasings side by side. This is the
  compare workflow: the sheet is where variants live, visibly, not a
  hidden slot.

**No pinning, no keep gesture.** A "keep this version" affordance
that survives compaction would be a hidden durable copy of deleted
content, precisely what the ceremony exists to destroy. The product
already has a keeping mechanism: the page. A phrasing worth keeping
is worth a visible paragraph (insert below); everything else is
subject to the clockwork like all content.

**History is per-device and never syncs.** ADR-0021's broadcast rules
already decide this: a joining peer starts at the current key frame
and structurally never receives the ops behind it, so a second device
can only ever show revisions since its own join. Peer edits that
arrive as deltas enter the local log with their own changes and
timestamps and appear in the panel like any others. The panel makes
no cross-device claim and requests nothing from anywhere.

**Version content crosses one new read surface, deliberately.** The
blocks JSON stays content-free (identities, stamps, paragraph spans,
per ADR-0013). Revision text is content and reaches the shell through
its own FFI call, the same trust domain as the editor's text itself:
vended to the panel, never persisted, never in the ledger, buffers
zeroized like every other content path. Origin messages do not ride
along; ADR-0013 is explicit that origin crosses no read surface, and
a revision panel does not change that.

## The panel is the honest window

A side effect worth naming: today the op log's memory is invisible,
and the compaction ceremony destroys something the user never saw.
The panel makes the retention story legible. What it shows is exactly
what the device remembers, which is exactly what ADR-0013 already
committed to remembering; when the ceremony runs, the panel visibly
empties back to the boundary. The horizon stops being doctrine and
becomes observable product behavior. Nothing about the threat model
changes, because no new data exists, but the standing history is now
one click away instead of forensic, so the pad's existing conceal
behavior (blur and drop at backdrop, panel dies with focus) is
load-bearing for this surface exactly as it is for the sheet.

## Consequences

- The core gains a revision derivation (`fork_at` walk, anchor
  resolution in forks, distinct-text collapse) and one FFI read call,
  roughly `block_revisions(sheet, block) -> [{stamp_s, text}]`. No
  new stored state, no migration, no snapshot format change.
- The shell's stamp labels (`InkEditorView.Coordinator.restyle()`
  positions non-interactive `NSTextField`s today) become clickable,
  and a panel view appears. The panel is display; restore and insert
  below go through the ordinary edit path and need nothing new from
  the model.
- The wording workflow gets what it actually needs: see the phrasing
  from an hour ago, take it back whole, or park it beside the current
  attempt. Multi-day archaeology is out of scope by doctrine; an
  intervening ceremony sheds it, and the stamp still answers from the
  materialized summary.
- Restore's effect on the derived created stamp (it moves, until the
  graduated summary answers) is inherited from derivation, not
  introduced here; a manual retype does the same today.
- Deferred ceremonies (peers attached) mean history can outlive a
  rung transition until the coordinated ceremony completes, so the
  panel may show more on a synced page than on a solo one. No special
  handling; the panel shows the log, and the log is what it is.

## What would settle this

- The gap threshold. Something in the minutes (5 to 30) matches how
  wording work actually pauses; since it is a read-time parameter,
  dogfood can tune it by feel with no migration.
- Measured fork cost on a real page. `fork_at` per boundary is
  assumed cheap at handful-of-revisions scale; measure on a page with
  a day of typing before committing to derive-on-click with no cache.
- Whether the panel wants a word-level diff between adjacent
  revisions. For wording work the delta is often the value. Display
  styling only, phase 2 if the plain list proves insufficient.
- Whether restore should be refused on a block whose text equals the
  revision (a no-op edit that would still move modified), or simply
  allowed as harmless.

## Eject triggers

- Loro's `fork_at` or cursor resolution in forks proves unable to
  reconstruct block extents reliably, which would force either stored
  revision markers (a retention decision this ADR refuses) or
  shelving the feature.
- A user-facing want for history past the ceremony appears and
  survives the doctrine argument, which would reopen ADR-0013's
  horizon as a product question, not a UI one.
- Sync grows a requirement for cross-device history, which would
  contradict ADR-0021's join-at-key-frame law and must be argued
  there first.
