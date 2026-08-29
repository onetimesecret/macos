# Where kept things live: the keep-gesture design space

Side doc to [`README.md`](README.md) · explored 2026-08-28.
Records the alternatives considered for the keeping problem, the axis
that sorted them, and where each one landed once
[ADR-0025](../../../adr/0025-block-revision-history.md) took its
current shape. The spec's boundary "kept things are deliberate
things" and the ADR's part 3 are the survivors of this exploration;
this doc is the trail.

## The problem as first stated

The first draft of ADR-0025 answered keeping with a refusal: no
pinning, no keep gesture, "a phrasing worth keeping is worth a
visible paragraph." Honest, and hostile to the very workflow the
spec exists for. Someone drafting an email with three candidate
sentences ends up with a sheet full of full-volume clutter, and the
one move the surface offers (insert the old text below) makes the
mess worse the more it is used. The question became: what does a
user-friendly keep look like that does not smuggle retention?

## The axis that sorts the candidates

The doctrinal line was never "no keeping." It is "no *hidden*
keeping." What makes a durable pin dishonest is that content
persists that no surface shows, so the user's mental model ("I
deleted that") goes false. The page is honest because what persists
is what you see. So every candidate below is really an answer to one
question: **where does a kept phrasing visibly live?** Storage is
downstream of that; visibility is the axis.

## The candidates

### 1. Quiet variant text, in place

Keep inserts the phrasing below the block as a marked region
rendered dimmed and collapsed until the caret enters, the existing
conceal-syntax-until-cursor mechanic scaled from a span to a region.
Because the variant is literally characters in the flat stream,
everything comes free: sync as text, page TTL, deletion by ordinary
editing, no new storage or format. Best adjacency for comparison;
this was the exploration's first recommendation.

**Disposition: lost to the chip shape, narrowly.** Its weakness is
that a "kept" thing living as ordinary characters has no identity
and no rank: it cannot outrank automatic states in the display
(spec capability 6), cannot be flipped as a variant (capability 7),
and a shed cannot distinguish it from prose. It survives as prior
art for the variant surface's rendering, where a non-showing
candidate may still want exactly this dimmed in-context treatment;
that question is punted to the follow-on design.

### 2. Keep-to-chip: identity-bearing sealed objects

The kept phrasing becomes a chip-shaped object: identity, sealed
bytes beside the document, deliberate to create and deliberate to
delete (ADR-0009), visible on demand, dies with its page. Compact on
the page, and the app already owns the entire lifecycle. The
objection raised against it: wording work wants to *read* variants,
and an object hides its text behind an interaction; it also
overloads the chip's meaning, which today is "sealed secret."

**Disposition: won, as ADR-0025 part 3.** Checkpoints ("this one
works", optionally named) and variants (two or three live
candidates, flip and settle) are chip-shaped deliberate content, not
part of the automatic memory, unaffected by a shed. The
read-your-variants objection is real and is exactly the surface
question the ADR leaves to this spec's follow-on design; candidate 1
is the leading answer for how a non-showing variant renders. The
overload objection is answered by "chip-shaped", not "chips": same
retention class and lifecycle, its own object.

### 3. Send to another page

Keep moves the phrasing to a scraps page, or a page the user picks.
The working sheet stays clean; the keeping mechanism is still a page
with its own visible tab and TTL (ADR-0017's shape). Weak for
side-by-side comparison since the variant now lives elsewhere, and
it needs cross-page machinery the product does not have.

**Disposition: parked as a second-generation candidate.** Worth
reopening if dogfood shows kept scraps accumulating past what
checkpoints and variants absorb. The underlying gesture (move a
block to another page) is independently useful and would carry this
almost for free if it ever ships.

### 4. Duplicate the page as a draft

Coarser grain: fork the whole page and rewrite in the copy, the way
people actually draft emails. Perfectly legible retention (a whole
visible page, its own TTL, nothing per-block), but the wrong grain
when one sentence is in play.

**Disposition: adjacent problem, not this one.** Page duplication
may want to exist for its own reasons; it is not the block-grain
keep.

### 5. Copy out

The panel offers Copy; the user parks the phrasing anywhere,
including outside the app. Zero new retention, instantly understood.
Not durable keeping, and in this app the clipboard is a governed
boundary (the sealed-paste contract, core-side pasteboard), so it is
a small feature rather than a footnote.

**Disposition: complement, not answer.** Belongs on the revision
surface regardless of everything else here, because it is nearly
free and honest by construction.

### 6. Page-level "remember my edits" toggle

A visible, page-granular control deferring the compaction ceremony,
so the revision panel stays rich until the page dies. The only
candidate that keeps *history* rather than *selected text*. Honest
because visible and page-granular, at the granularity TTL doctrine
already blesses; its trade was weakening the bounded-by-one-rung
claim for that page and adding a mode.

**Disposition: absorbed into ADR-0025 part 2, with the polarity
inverted.** The rework made page-lifetime memory the *default* and
forgetting the gesture: history lives as long as its page, and the
deliberate shed is the control. The toggle's insight (page-granular,
visible, the user decides) survives; the mode does not, because a
default needs no toggle. This absorption also dissolved the original
keeping problem's urgency: keeps no longer exist to survive rung
ceremonies, since rung transitions stopped being compaction
boundaries. What keep is *for* under the current ADR: surviving a
deliberate shed, outranking the automatic pile, and branching.

### 7. Ceremony review

Answer at the boundary instead of before it: compaction surfaces
"these phrasings are about to be forgotten" and the user grabs any
as visible text. Aligned with the doctrine's own framing (ADR-0021
already makes the ceremony proposable, not silent), but it
interrupts, and interruption at a clock-driven moment is wrong for
an ambient pad.

**Disposition: absorbed by the shed's placement.** With no
clock-driven ceremony left inside a page's life, there is no
surprise moment to review. The shed is user-initiated, one gesture
from the surface where the user can see what will be forgotten,
which is this candidate's honesty with the interruption removed. The
size-budget trigger is the one automatic ceremony that remains; if
it fires often in practice (an ADR-0025 eject trigger), a review
moment may deserve reconsideration there.

### 8. Starring within the horizon

A content-free marker (block id plus frontier) making a revision
easy to find again among idle-gap clusters, dying with its referent
at the ceremony. Cheap and doctrinally free.

**Disposition: superseded by checkpoints.** A checkpoint is a star
that survived the rework: deliberate, optionally named, outranking
automatic states (spec capability 6). A marker pointing into the op
log would now be a weaker second mechanism for the same reflex, so
it is not carried forward.

## What this exploration settled, and what it left

Settled: the axis (visibility, not storage), the retention class of
kept things (deliberate, page-lifetime, ADR-0009's shape), and the
inversion that moved the schedule argument from "how do keeps
survive the ceremony" to "the ceremony is the gesture" (ADR-0025
part 2).

Left to the follow-on design, deliberately: where a variant's
non-showing text renders (candidate 1's dimmed in-context region is
the leading answer), how flipping a variant commits, how a
checkpoint's name is displayed against the `DDD HH:mm` stamps, and
whether Copy (candidate 5) lands in the first cut of the panel.
