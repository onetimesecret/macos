# ADR-0025: Block revisions, and history dies with its page

- **Status:** proposed
- **Date:** 2026-08-28

Serves the capability spec at
`docs/spec/feature/block-revisions/README.md`. This ADR decides the
mechanism behind the automatic memory, the retention class of the
deliberate objects (checkpoints, variants), and, the load-bearing
part, where history dies. That last decision amends accepted
ADR-0013 and needs maintainer ratification before anything ships.

## Context

The spec asks that a block never lose a state by accident
(capability 1) and that no move on the revision surface lose work
(capability 5), citing tenet №1: losing work is unforgivable, even
here. The op log already remembers what those capabilities need.
Every commit is its own change with its own timestamp (merging
disabled), provenance is derived from ops
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
fiddles with the rung sheds repeatedly. The security claim "what this
device remembers is bounded by one rung" describes the schedule's
intent, not its behavior.

Second, the memory is about to become visible. Once the stamp opens a
revision surface, shedding history as a side effect of an unrelated
gesture becomes a trap: choosing a longer TTL, or pausing a page,
would silently destroy the very states the panel taught the user to
rely on. Pausing a page is a gesture of keeping; having it destroy
the block's memory is exactly tenet №1's "one misunderstanding away
from feeling like loss." An invisible memory could afford an
incidental schedule. A visible one cannot.

## Decision

Three parts.

### 1. Automatic history is a projection of the op log

Revisions are derived at read time and stored nowhere. Opening a
block's history walks the log once: candidate boundaries are idle
gaps between changes, plus a forced boundary immediately before any
change whose deletion exceeds a threshold, so the state just ahead of
a destructive edit is always reachable (the rescue case, spec
capability 1). At each boundary the block's text is reconstructed by
forking the document at that frontier (`LoroDoc::fork_at`, verified
present in the pinned loro 1.13.9) and resolving the block's anchor
in the fork; consecutive identical texts collapse. Both thresholds
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

The security claim rescopes from "bounded by one rung" to: **a
block's history never outlives its page, never survives a shed, and
never crosses a key frame to another device.** The honesty section
below is what that trades away.

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
  the graduation all survive as-is. ADR-0013's ceremony section needs
  an amendment note pointing here once ratified.
- Part 3 is new design work (object model beside chips, panel
  treatment) and can land after parts 1 and 2; nothing in them
  forecloses it.
- The panel carries the legibility footer (spec capability 8): what
  is reachable, and that history sheds with the page, on shed, or
  over budget.
- ADR-0011 (TTL rungs) is untouched; rungs keep governing page life.
  What they stop governing is the memory inside a living page.

## What would settle this

- Maintainer ratification of part 2, since it amends accepted
  ADR-0013 and rescopes a security claim.
- The two derivation thresholds (idle gap, destructive deletion
  size), tuned by dogfood feel; both read-time, no migration.
- Measured `fork_at` cost on a page with a day of real typing, before
  committing to derive-on-click with no cache.
- Verification in the #95/#96 work that key-frame emission never
  forces a local discard, so a synced page's history keeps page
  lifetime too; if the mechanics disagree, the sync case falls back
  to ceremony-bounded history and the panel's footer says so for
  synced pages.
- Whether shed is ever wanted at block grain rather than page grain.
  Per-block retention knobs were rejected once already (per-block TTL,
  ADR-0013); the default answer is no, one shed for the page.

## Eject triggers

- The size budget fires often on real pages, meaning page-lifetime
  history does not fit the sealed-file envelope in practice, which
  would force the schedule argument to reopen with data.
- Provenance appears in a threat model as an asset in its own right
  (carried forward from ADR-0013), which would argue the schedule
  back toward aggressive shedding.
- Loro's `fork_at` or anchor resolution in forks proves unable to
  reconstruct block extents reliably, which would force either stored
  revision markers (a retention decision this ADR refuses) or
  shelving the projection design.
- Sync's mechanics turn out to require local discard at GOP
  boundaries after all, which would make part 2's claim unkeepable
  for synced pages and demand an amendment, not a quiet exception.
