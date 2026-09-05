# Feature: block revisions, checkpoints, and variants

Status: **draft** · 2026-08-28
Scope: what a block's memory should do for the person iterating on
wording (a prompt, an email, a hard sentence), stated as capabilities
first, before operational constraints are applied. The mechanism and
the retention argument live in the ADR; this document is the bar the
mechanism has to clear.
Governs against:
[`docs/tenets.md`](../../../tenets.md) (№1 losing work is
unforgivable, №3 do not wag the dog),
[ADR-0013](../../../adr/0013-bounded-document-history-and-block-metadata.md)
(the editable-surface rule and document-history model),
[ADR-0009](../../../adr/0009-chip-deletion-deliberate-final.md)
(deliberate creation and deletion as the shape of kept things), and
[ADR-0021](../../../adr/0021-multi-device-sync-over-a-blind-relay.md)
(the join-at-key-frame law).
Decision:
[ADR-0025](../../../adr/0025-block-revision-history.md) (proposed).
Side doc:
[`2026-0828-where-kept-things-live.md`](2026-0828-where-kept-things-live.md)
(the keep-gesture design space and each candidate's disposition),
[`2026-0828-research-reconciliation.md`](2026-0828-research-reconciliation.md)
(the research corpus compared against this concept, with
dispositions),
[`2026-0829-loro-reconciliation.md`](2026-0829-loro-reconciliation.md)
(the Loro concepts report verified against the pinned crate and the
core's actual usage, with dispositions),
[`2026-0828-page-lens.md`](2026-0828-page-lens.md)
(page history as a second projection of the same log; concept only,
unscheduled),
[`2026-0901-pause-boundaries.md`](2026-0901-pause-boundaries.md)
(the keystroke-logging pause research weighed surface by surface, with
adopt or reject on each and the rule of thumb that decides them).
Issue: not yet filed. Origin: docs/dogfood/DOGFOOD.md, commit `2e58158`.

## Why now

The block metadata display just shipped: every block narrates its own
life as a created and modified stamp. The dogfood wish is the obvious
next step, make that stamp the doorway to the block's prior texts.
And the wish has a sharp use case: wording work. You rewrite a
sentence five times, and the phrasing you want back is the one from
an hour ago that you edited away.

The wider market says this is not a nice-to-have. Version history is
what note products charge for (Notion gates retention by plan tier)
and what users of the products without it beg for (note revision
history is a standing top request in Bear's community; Apple Notes
forums are full of unanswerable "I deleted text and undo is dead"
threads, with Time Machine surgery as the accepted workaround). An
app whose thesis is forgetting does not get an exemption from that
instinct; per tenet №1 it gets held to a higher bar.

## The capabilities

Stated without operational constraints. Each one is a claim about the
experience; none of them names a data structure.

### 1. A block never loses a state by accident

Any text a block has ever shown can be gotten back whole, with no
forethought: no prior gesture, no snapshot discipline. In particular
the state just before a destructive edit (a select-all typed over, a
bad paste, a deletion noticed too late) is always reachable. Rescue
is the number-one reason people open version history in every app
surveyed, and it is the case that must never fall between the cracks
of whatever granularity the mechanism chooses.

### 2. The stamp is the doorway

The created and modified stamp already narrates the block's life;
interacting with it opens that life. No menu, no mode, no separate
window to find.

### 3. Time travel happens in place

Scrubbing shows the block's past text in the block's own position,
with the rest of the page intact around it, because wording is judged
in context: a sentence reads differently above its neighboring
paragraph than in a detached preview pane. Release to bail, confirm
to take. A list of states may accompany the scrub, but the scrub is
primary. (This is the muscle memory of Simplenote's history slider
and macOS's Browse All Versions, applied to one block instead of a
whole document.)

### 4. Change is shown, not inferred

Word-level deltas between adjacent states, and between any state and
now. Nobody reads old versions; they read differences (Google Docs'
colored diffs, Obsidian's Show changes toggle, Scrivener's Compare).
This is first-class, not a later phase: a list of near-identical
paragraph texts without highlighted deltas reads as broken to anyone
arriving from those apps.

### 5. Taking back never costs the present

Restore is nondestructive in both directions: the current text
becomes just another recoverable state the moment it is replaced.
There is no move on this surface that loses work. (This is also the
standing complaint about whole-document restore in Docs and Notion,
where reverting the page sacrifices everything changed since;
block-granular restore is the wish granted, and it must not
reintroduce the trap at block scale.)

### 6. Deliberate checkpoints

Mid-iteration, "this one works, now let me try something looser" is
one cheap gesture, optionally named ("formal", "short", "the one with
the joke"). Checkpoints outrank automatic states in the display. This
is Scrivener's snapshot reflex, the closest existing workflow to
prompt and email wording, and the reflex its users will arrive with.

### 7. Variants, not only history

Wording work is branching, not linear. A block can hold two or three
live candidates, flip which one is showing, judge each in context,
and settle. History is what you get for free because you did not
think to fork; variants are what you were actually doing. Every
incumbent approximates this badly (duplicate the doc, park a copy at
the bottom, snapshot and diff); none has it natively at the paragraph
grain.

### 8. The bounds are legible

Whatever retention turns out to be, the surface states what is
reachable and why. Absence reads as policy, never as loss. Every
incumbent burns users with surprise retention limits ("older version
history is gone" is a standing support-forum genre); tenet №1 says
forgetting is only trustworthy when it is visibly on schedule.

### 9. History follows the page (recorded as the want that lost)

The unconstrained want includes revisions made on the laptop being
visible on the desktop. ADR-0021's join-at-key-frame law structurally
forbids it, for ratified reasons that have nothing to do with UI
convenience: a joining device never receives the ops behind the
current key frame, which is what makes sync safe to offer at all.
This capability is recorded so the want is on the books, and it loses
to that law unless the argument is reopened in ADR-0021's terms.

## Boundaries this surface must respect

- **The editable-surface rule (ADR-0013).** Everything here is a
  read-only projection over the in-order sheet. An in-place preview
  suspends editing while it is showing; taking a state is an ordinary
  edit at the block's real position, undoable like any edit.
- **Content stays off content-free surfaces.** Revision text is
  content. It may cross to the editor the way the page's own text
  does, and nowhere else: never the ledger, never the blocks JSON,
  never an origin message alongside.
- **Kept things are deliberate things.** Anything that outlives the
  automatic memory (a checkpoint, a variant) exists because of a
  gesture, is visible on demand, and dies with its page. The app
  already has this shape: chips (ADR-0009).

## What already exists

The op log already remembers everything this spec asks capability 1
to recover: per-change timestamps with merging disabled, provenance
derived from ops, persistence proving the history survives restart
(ADR-0013 as implemented). The open questions are not whether the
memory exists but when it dies and what gestures sit on top of it;
that argument is ADR-0025's.
