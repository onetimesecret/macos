# The pause research, weighed surface by surface

Side doc to [`README.md`](README.md) · 2026-09-01.
Issue [#133](https://github.com/onetimesecret/macos/issues/133).
Companion to
[`2026-0828-research-reconciliation.md`](2026-0828-research-reconciliation.md)
item 2, which is where the research first entered this project, and to
[`2026-0829-loro-reconciliation.md`](2026-0829-loro-reconciliation.md),
whose UndoManager section became issue #132 and is delivered alongside
this doc.

## The research in one paragraph

The keystroke-logging literature (Wengelin 2006; Van Waes and Leijten)
puts the cognitively meaningful writing pause at about two seconds, and
finds that pauses lengthen at sentence and paragraph boundaries: a pause
marks the end of a unit of thought, and the strength of the boundary
grades with the linguistic structure it sits at. The research corpus
([`2026-0828-undo-that-survives.html`](../../../research/2026-0828-undo-that-survives.html),
finding 04) surveyed about ninety products and found none using it.
Every incumbent hand-rolls a wall-clock timer. That is an opportunity
and also a warning, which is what this document exists to separate,
surface by surface.

## The rule of thumb

**Pause alignment is welcome wherever it shapes a read-time projection
or a local display. It is suspect wherever it produces an event with an
externally observable clock.**

The reason is ADR-0021 section 4. Sync batches deltas on a fixed clock
precisely so that the cadence of what leaves this machine says nothing
about the cadence of the typing that produced it; the core's
`set_change_merge_interval(0)`
([`crates/core/src/document.rs:172`](../../../../crates/core/src/document.rs))
makes the local op log deliberately chatty, and the protocol's own
timer is what keeps that chattiness from reaching a wire. A behaviour
that fired on linguistic pauses and produced an observable event would
undo that: a relay operator watching packet arrival times, or anyone
who can read a file's modification times, would be reading the writer's
sentence boundaries. The literature is exactly the tool that makes
those timings legible, which is what makes leaking them worse than
leaking an arbitrary timer's.

So the test for each surface below is not "would pause alignment feel
better". It is "does this surface's clock leave the machine".

## The judgments

### Undo step grouping (#132): adopt, at two seconds

**Adopted.** The merge interval is set at
[`crates/core/src/document.rs:59`](../../../../crates/core/src/document.rs)
(`UNDO_MERGE_INTERVAL_MS = 2_000`), applied at
[`crates/core/src/document.rs:810`](../../../../crates/core/src/document.rs).

Loro's default is zero, which makes every commit its own undo step, and
every keystroke is a commit here (see the `set_change_merge_interval`
comment cited above), so an unconfigured stack would take one character
back per ⌘Z. Some number had to be chosen. Two seconds is the research's
number rather than an invented one, and it is the same number ADR-0025's
revision-boundary settle item was seeded from, so the two features grade
history on one scale instead of two.

Two caveats, recorded because both are easy to overstate:

- **The library's rule is a ceiling, not a gap detector.** Loro compares
  now against the time the *current step began*
  (`merge_interval_in_ms` in the vendored `loro-internal` undo module),
  so a step absorbs everything typed within two seconds of its start and
  then a new step begins, whether or not the writer paused. That is not
  the idle-gap boundary the literature describes. What it guarantees is
  the weaker, still useful thing: a step never spans two units of
  thought, though a long fluent run splits into several. Erring toward
  smaller steps is the safe direction for undo, because one ⌘Z taking
  back less than expected is recoverable by pressing it again, and one
  taking back more is the loss tenet №1 forbids.
- **It groups local operations only.** The interval is read inside the
  undo manager and reaches nothing else. Sync cadence is untouched:
  ADR-0021 section 4's clock still batches deltas, and no observable
  event moves because of this number.

One class of edit opts out of the interval entirely: the ones the page
makes on the writer's behalf rather than at their dictation, a
continued list marker or a nudged indent
([`crates/core/src/document.rs:259`](../../../../crates/core/src/document.rs)).
Those arrive a keystroke after the burst they should not join, so they
begin their own step and come off in one press. The lever is the same
constant, dropped to zero across that one commit, because the library
offers no other way to force a boundary: its test compares against the
moment the current step began and nothing can reset that moment except
pushing a step.

A true pause-aligned undo would need the boundary computed here rather
than delegated to the interval, using idle gaps and sentence edges the
way ADR-0025's revision derivation will. That is available later at read
time and is not worth building before the revision panel needs the same
machinery.

### Autosave and persist debounce: reject, and do not touch it

**Rejected.** The debounce stays a wall-clock number:
[`shell/Sources/CompanionKit/PageModel.swift:651`](../../../../shell/Sources/CompanionKit/PageModel.swift)
(`saveDebounce = 2.0`), measured from the first mutation of a burst.

Three reasons, in the order they decide it:

1. **The clock is observable.** Each debounced write is an atomic
   replace of `state.sealed`, and a file's modification time is readable
   by anything with the directory. A flush that fired at sentence and
   paragraph edges would write the writer's linguistic rhythm into the
   filesystem's own timestamps: the ciphertext would still be opaque and
   the *timing* would not be. This is the rule of thumb's first refusal,
   and it is on its own sufficient.
2. **There is nothing to buy.** The debounce already sits at two
   seconds and is already measured from the start of a burst, so it
   already fires about once per unit of thought for prose typed at any
   normal speed. The change would be a rewrite of the trigger to arrive
   at roughly the same cadence.
3. **The tradeoff runs the other way.** ADR-0012 states the debounce as
   a tradeoff rather than a free win: shorter shrinks the crash-loss
   window, longer leaves fewer ciphertext generations unlinked on disk.
   A pause-aligned flush would make the loss window a function of how
   fluently the user writes, which is the wrong thing for it to depend
   on. Durability should not be better for people who pause more.

No code changes on this surface. The judgment is the deliverable.

### Revision boundary derivation (ADR-0025): already adopted, elsewhere

**Adopted, and not here.** The decision lives in ADR-0025's settle item
and was seeded by
[`2026-0828-research-reconciliation.md`](2026-0828-research-reconciliation.md)
item 2: cluster on idle gaps of roughly twenty seconds to two minutes,
prefer boundaries where the reconstructed text ends at a sentence or
paragraph edge, and keep the forced boundary before any large deletion.

This is the surface pause alignment was made for. The boundary is
computed at read time from a keystroke-grained log, so it produces no
event at all: nothing is written, nothing is sent, and the parameters
can be changed after the fact without losing anything, because every
heuristic in the research's table stays available retroactively. Listed
here so the family is linked in one place; nothing about it moves in
this document.

### Stamp and fence display coalescing (ADR-0022): reject, for a different reason

**Rejected**, and not on privacy grounds. The display's coalescing is
already keyed to linguistic structure, just not to a pause: a fence
region stamps as one unit because the fence rules say where it starts
and ends
([`shell/Sources/CompanionKit/InkEditorView.swift:1126`](../../../../shell/Sources/CompanionKit/InkEditorView.swift)),
and the grouping is recomputed in the restyle pass from the text on
screen.

A pause-graded grouping would be a second grouping competing with that
one, and the two would disagree in front of the user: a fence typed
across a long thinking pause would want to split, and two paragraphs
written in one breath would want to join across a fence rule. The
display can carry one story about what belongs together, and the
markup's is the one the eye is already reading. The rule of thumb would
have permitted this surface, since a restyle pass leaves no observable
clock. It is refused for legibility instead.

If the revision panel later wants to show "these three edits were one
sitting", that grouping belongs in the panel, over derived revision
boundaries, and not on the page's stamps.

## What would reopen this

- ADR-0021 section 4's clock batching is replaced by something that
  already publishes edit cadence, at which point the persist debounce's
  first refusal loses its force and only reasons 2 and 3 stand.
- The revision panel ships and its boundary derivation proves that idle
  gaps plus sentence edges are cheap enough to compute continuously, at
  which point the undo grouping could move from the interval to a real
  boundary and the two features would share one derivation.
- Someone measures the undo grouping in dogfood and finds that two
  seconds chops fluent writing into steps that feel arbitrary. The
  number is one constant with one caller, and moving it is a one-line
  change with this document as the argument to update.
