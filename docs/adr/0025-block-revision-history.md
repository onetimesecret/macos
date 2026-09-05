---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0025: Block revisions, and history dies with its page

- **Status:** proposed
- **Date:** 2026-08-28

Serves the capability spec at
`docs/spec/feature/block-revisions/README.md`. This ADR decides the
mechanism behind the automatic memory, the retention class of the
deliberate objects (checkpoints, variants), and, the load-bearing
part, where history dies. That last decision amends accepted
ADR-0013 and waits on a measurement before anything ships.

**Part 2, "The page is history's retention unit (amends ADR-0013)",
stays open.** It cannot be decided until real pages show what
per-page history costs: op-log growth and compaction cost measured on
a page with a day of real typing, which is also ADR-0013's own eject
trigger. Nothing in part 2 ships before that measurement exists and
the decision is recorded here.

## Context

The spec asks that a block never lose a state by accident
(capability 1) and that no move on the revision surface lose work
(capability 5), citing tenet №1: losing work is unforgivable, even
here. The op log already remembers what those capabilities need.
Every commit lands as its own change with its own timestamp (the
merge interval is zero; same-second commits sharing a message still
coalesce, far below any boundary this ADR derives), provenance is
derived from ops
(`SheetDocument::span_provenance`), and the history survives restart
inside the sealed snapshot. The memory exists; the questions are when
it dies and what sits on top of it.

ADR-0013 answered the first question for an invisible memory: the
compaction ceremony graduates block summaries and destroys the trail,
"on the same clockwork as everything else, at rung transitions." Two
things have changed since that answer was given.

First, the delivered bound was never really a rung of wall time. The
ceremony's production triggers are all user gestures: cycling or
setting the TTL rung (`SheetStore::cycle_rung`,
`SheetStore::set_rung`) and the hold top-up, plus the coordinated
ceremony those gestures mark due when peers are attached
(issue #101). No timer compacts. A page whose TTL is never touched
carries its full history to the grave already; a page whose owner
fiddles with the rung sheds repeatedly. ADR-0013 promises only that
compaction bounds locally reconstructible deleted content. With rung
gestures as the boundaries, the bound is whatever the owner's TTL
habits happen to make it, which is no bound at all.

Second, the memory is about to become visible. Once the stamp opens a
revision surface, shedding history as a side effect of an unrelated
gesture becomes a trap: choosing a longer TTL, or pausing a page,
would silently destroy the very states the panel taught the user to
rely on. Pausing a page is a gesture of keeping; having it destroy
the block's memory is exactly tenet №1's "one misunderstanding away
from feeling like loss." An invisible memory could afford an
incidental schedule. A visible one cannot.

## Decision

Three parts, plus the undo rules the same memory is edited through
(part 4), which are recorded here rather than decided here.

### 1. Automatic history is a projection of the op log

Revisions are derived at read time and stored nowhere. Opening a
block's history walks the log once: candidate boundaries are idle
gaps between changes, plus a forced boundary immediately before any
change whose deletion exceeds a threshold, so the state just ahead of
a destructive edit is always reachable (the rescue case, spec
capability 1). At each boundary the block's text is reconstructed in a
scratch copy of the document: fork once, check the fork out
read-only at the boundary's frontier, and resolve the block's anchor
there (`LoroDoc::fork` and `checkout`, both verified in the pinned
loro 1.13.9; `fork_at` per boundary is ruled out, each call being a
full snapshot export and re-import); consecutive identical texts
collapse. Both thresholds
are read-time display parameters, tunable with no migration.

The surface follows the spec: in-place preview by scrubbing (a
read-only projection under ADR-0013's editable-surface rule, editing
suspended while showing), word-level deltas rendered first-class, and
taking a state back as one ordinary commit at the block's real
position, undoable, stamping modified now. The current text becomes
the newest recoverable state the moment it is replaced, so restore is
nondestructive by construction. Revision text is content and crosses
one deliberate read surface to the editor, the same trust domain as
the page's own text: never the ledger, never the blocks JSON, origin
messages never alongside.

### 2. The page is history's retention unit (amends ADR-0013)

A block's history lives exactly as long as its page and dies with it:
at TTL expiry, at deliberate page deletion, and at no other automatic
moment. Rung transitions and hold top-ups stop being compaction
boundaries. The ceremony itself, graduate then discard
(`Sheet::compact`), is unchanged; what changes is its schedule. It
runs on:

- **A deliberate shed.** The revision surface offers "shed history
  now" for the page. This is the control the rung side effect only
  pretended to give: forgetting on purpose, at the moment the user
  means it, one gesture from the place where they can see what will
  be forgotten. Like the seal gestures it is deliberate and not
  undoable, and the surface says so.
- **A size budget.** Op-log growth crossing a measured budget on a
  real page triggers a ceremony, the remedy ADR-0013 already named in
  its eject triggers. This bounds the sealed file, not the user's
  memory of their own words.
- **The coordinated sync ceremony**, where ADR-0021's mechanics
  require one, exactly as issue #101 built it. Join-at-key-frame is
  untouched: a peer still never receives ops behind the current key
  frame, so history still never crosses devices (the spec records
  cross-device history as the want that lost).

ADR-0013's bound on locally reconstructible deleted content becomes:
**a block's history never outlives its page and never survives a
shed.** A key frame is a shed, so nothing behind one exists anywhere
afterwards; ADR-0021 owns what a joining peer receives. The honesty
section below is what that trades away.

### 3. Checkpoints and variants are deliberate content, not history

A checkpoint ("this one works", optionally named) and a variant (two
or three live candidates of one block, flip which shows, settle) are
created by gesture, visible on demand, and die with their page. They
are chip-shaped: identity-bearing objects sealed beside the document,
deliberate to create and deliberate to delete (ADR-0009), not part of
the automatic memory and therefore unaffected by a shed. This is not
the retention smuggling ADR-0013 warns about, because that warning
targets automatic, invisible retention; a checkpoint is the user
keeping something, in a different slot than the visible stream, the
way a chip already keeps sealed bytes. Their surface details (where a
variant's non-showing text may appear, how flipping commits) belong
to the spec's follow-on design, under the same rule as everything
else: kept things are deliberate things.

### 4. Undo is core owned, local only, and forgotten where a step would lie

Recorded from the reconciliation note, which remains the source and
the fuller argument:
[`2026-0829-loro-reconciliation.md`](../spec/feature/block-revisions/2026-0829-loro-reconciliation.md#the-undomanager-switch-decided-direction-2026-08-29)
and its delivered section
[What the switch decided](../spec/feature/block-revisions/2026-0829-loro-reconciliation.md#what-the-switch-decided-delivered-2026-09-01-issue-132).
These rules bind this ADR because they govern the same op log part 1
projects, and because a step that stood a dead sentinel again would be
the one document shape the restore path calls damage (ADR-0009).

- **Undo lives in the core, bound to the document, and reverts only
  this peer's operations.** A shell level stack could revert another
  device's text once remote ops land in live pages; the core's cannot.
- **The stack does not survive relaunch, deliberately.** It is bound
  where the document is constructed, so a restore and the ceremony
  both rebind, and both re-mint the peer id. A carried stack would
  point at operations that no longer exist. The compaction path clears
  explicitly as well.
- **The step boundary is a two second merge interval**, the same
  number part 1's idle gap threshold was seeded from, argued at
  [`2026-0901-pause-boundaries.md`](../spec/feature/block-revisions/2026-0901-pause-boundaries.md).
  It groups local operations only; ADR-0021 section 4's clock batching
  is untouched.
- **The stack is forgotten wherever a step would be a lie**: the two
  ceremonies, a wholesale restate, a seal, a chip burned out of the
  page, any settle that reaps a chip, and any batch standing a
  sentinel through the operation path. Undo never un-seals and never
  resurrects (ADR-0009). A peer's chip deletion therefore costs this
  device its steps, which is the intended reading of the rule.
- **Forgetting drops, it does not zeroize.** `forget_undo` is a
  correctness valve standing between undo and a document shape that
  must not exist. The memory guarantee stays where it always was, on
  the ceremony (ADR-0007).
- **The caret rides the step.** Push and pop hooks record and return a
  Loro cursor rather than a bare offset, so a peer's operations
  arriving while the step waits move it correctly.

## What this trades away, said plainly

Under the old schedule's intent, deleted content inside a live page
was recoverable only until the next rung event. Under this decision
it is recoverable until the page dies or the user sheds, which for a
seven-day page can be seven days. Mitigations, in order of weight:

- At rest the history was always inside the sealed file, under the
  same keychain-bound encryption and crypto erasure as the content it
  describes (ADR-0012). The at-rest story does not change at all.
- The memory becomes visible instead of forensic. The panel is the
  honest window: what it shows is what the device remembers, and the
  shed gesture stands right next to it. Before this ADR the same
  history sat invisibly in the op log with no way to inspect it and
  only accidental ways to destroy it.
- Secrets have a vehicle that never enters the op log's plain text:
  chips. A pasted secret that should not linger belongs in a chip or
  behind a shed, and the surface can say so.
- The bound that mattered to sync, one GOP at the relay and nothing
  behind the key frame for a joiner, is a property of ADR-0021's
  protocol, not of local compaction, and stands unchanged.

## Consequences

- Part 1 is additive: a derivation walk and one FFI read call,
  roughly `block_revisions(sheet, block) -> [{stamp_s, text}]`, plus
  the shell surface (the stamp labels in
  `InkEditorView.Coordinator.restyle()` become interactive). No
  stored state, no migration, no snapshot format change.
- Part 2 removes the `compact_or_defer` calls from the rung and
  top-up paths in `store.rs` and adds the shed entry point and the
  size trigger. The ceremony code, the deferred state machine, and
  the graduation all survive as-is. ADR-0013's Decision section needs
  an amendment note pointing here if part 2 is accepted.
- Part 3 is new design work (object model beside chips, panel
  treatment) and can land after parts 1 and 2; nothing in them
  forecloses it.
- The panel carries the legibility footer (spec capability 8): what
  is reachable, and that history sheds with the page, on shed, or
  over budget.
- ADR-0011 (TTL rungs) is untouched; rungs keep governing page life.
  What they stop governing is the memory inside a living page.

## What would settle this

- Part 2, once op-log growth and compaction cost have been measured on
  real pages. It amends accepted ADR-0013 and restates its bound, and
  the measurement is what decides whether per-page history is
  affordable; there is nothing to ratify before it exists.
- The two derivation thresholds (idle gap, destructive deletion
  size), tuned by dogfood feel; both read-time, no migration.
- Measured cost of the fork-then-checkout walk on a page with a day
  of real typing, before committing to derive-on-click with no cache
  (`fork_at` per boundary is already ruled out: each call is a full
  snapshot round trip).
- Verification in the #95/#96 work that key-frame emission never
  forces a local discard, so a synced page's history keeps page
  lifetime too; if the mechanics disagree, the sync case falls back
  to ceremony-bounded history and the panel's footer says so for
  synced pages. **Answered against the delivered mechanics, and the
  answer is no** (see the delivery note below): every path that stages
  a frame goes through `gop::ceremony_commit`, whose first half is the
  local compaction. What is not settled is whether that costs anything
  under part 2, since part 2 also removes the rung and top-up triggers
  that make a ceremony due. **Unverified; no test exercises a key
  frame emitted without a compaction**, because the delivered code has
  no such path to exercise.
- Whether shed is ever wanted at block grain rather than page grain.
  Per-block retention knobs were rejected once already (per-block TTL,
  ADR-0013); the default answer is no, one shed for the page.

## Decision history

- **2026-08-28:** Proposed in PR #134.
- **2026-09-01:** The undo rules now recorded as part 4 were decided
  and delivered for issue #132 in PR #142.
- **2026-09-04:** Delivery note added below. Status stays `proposed`:
  part 2 waits on op-log growth and compaction cost measured on real
  pages.

## Delivery note (2026-09-04)

Issue #132, "Adopt Loro's UndoManager before remote ops land in live
documents", delivered against this record in PR #142, "Move undo into
the core before another device's ops can land in a page" (merged
2026-09-02, milestone "Editing rhythm and the time rail"). It carried
the undo decisions the reconciliation note held; they are summarized
as part 4 above.

Settle list, as of this date:

- **Part 2.** Open, and not decidable yet: no measurement of op-log
  growth or compaction cost on a real page exists. Nothing else here
  changes that.
- **The two derivation thresholds.** Open. Part 1 is not built: no
  `block_revisions` seam exists in `crates/`. The two second figure
  the idle gap would start from is at least settled and in the code
  (`crates/core/src/document.rs:42`), argued at
  [`2026-0901-pause-boundaries.md`](../spec/feature/block-revisions/2026-0901-pause-boundaries.md).
- **Measured cost of the fork then checkout walk.** Open, and
  unmeasured. Nothing in the tree performs the walk.
- **Key-frame emission and local discard.** Determined, and against
  the hoped-for answer. Emission and compaction are one event by
  construction: both sites that stage a frame call
  `gop::ceremony_commit` (`crates/ffi/src/sync_session.rs:981` for a
  confirmed ballot and `crates/ffi/src/sync_session.rs:1088` for the
  empty room case), and that function's first step is
  `SheetStore::perform_ceremony`, which compacts
  (`crates/ffi/src/gop.rs:179`, `crates/core/src/store.rs:1265`).
  Held by `the_ceremony_rotates_and_rebuilds_as_one_event_or_not_at_all`
  (`crates/ffi/src/gop.rs:277`) and
  `a_deferred_page_keeps_its_history_until_the_ceremony_performs`
  (`crates/core/src/store.rs:4901`). The joining side discards too, by
  a separate rule: a frame lands only on a pristine page
  (`crates/core/src/store.rs:4577`), so a device carrying
  pre-ceremony history drops it and rejoins empty
  (`crates/core/src/store.rs:4513`). **Unverified; no test exercises
  a key frame emitted without a local discard**, and no code path
  offers one. Whether part 2's schedule change removes the occasion
  rather than the coupling is the question left standing.
- **Shed at block grain.** Open, default still no.

Delivered by #132 and holding part 4:

- Local only step, peer's operations left standing:
  `crates/core/src/document.rs:1402`, `crates/core/src/store.rs:5268`.
- Nothing to step back through after a restore or a ceremony:
  `crates/core/src/document.rs:1363`, `crates/core/src/document.rs:1384`,
  `crates/core/src/store.rs:5195`.
- The stack forgotten where a step would lie: a seal
  (`crates/core/src/store.rs:5032`), a deleted chip
  (`crates/core/src/store.rs:5150`), a wholesale restate
  (`crates/core/src/store.rs:5176`), a peer's chip deletion
  (`crates/core/src/store.rs:5226`).
- Two second merge interval and the automation's own step:
  `crates/core/src/document.rs:1315`, `crates/core/src/document.rs:1347`.
- The caret across the seam: `crates/core/src/document.rs:1298`,
  `crates/ffi/src/lib.rs:4260`.

**Part 2, "The page is history's retention unit (amends ADR-0013)",
stays open.** The question it asks is whether rung transitions and
hold top-ups stop being compaction boundaries, so a block's history
lives as long as its page and dies only at expiry, at deliberate page
deletion, at a deliberate shed, over the size budget, or at the
coordinated sync ceremony. That cannot be answered until op-log growth
and compaction cost are measured on real pages. If the measurement
supports it, accepting part 2 restates ADR-0013's bound on locally
reconstructible deleted content as "never outlives its page, never
survives a shed" and obliges an amendment note in ADR-0013's Decision
section.

## Eject triggers

- The size budget fires often on real pages, meaning page-lifetime
  history does not fit the sealed-file envelope in practice, which
  would force the schedule argument to reopen with data.
- Provenance appears in a threat model as an asset in its own right
  (carried forward from ADR-0013), which would argue the schedule
  back toward aggressive shedding.
- Loro's checkout or anchor resolution in forks proves unable to
  reconstruct block extents reliably, which would force either stored
  revision markers (a retention decision this ADR refuses) or
  shelving the projection design.
- Sync's mechanics turn out to require local discard at GOP
  boundaries after all, which would make part 2's claim unkeepable
  for synced pages and demand an amendment, not a quiet exception.
