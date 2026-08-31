# The research against the concept: reconciliation

Side doc to [`README.md`](README.md) · 2026-08-28.
Compares the research corpus
([`2026-0828-undo-that-survives.html`](../../../research/2026-0828-undo-that-survives.html),
[`2026-incumbents.md`](../../../research/2026-incumbents.md),
[`2026-0828-line-diffing.md`](../../../research/2026-0828-line-diffing.md))
against the concept as it stands: the capability spec, ADR-0025
(proposed), and the keep-gesture side doc. Each divergence carries a
disposition. Findings and opportunities are cited by the numbers the
research report uses.

## Verdict in one paragraph

The concept survives the research intact and comes out better
positioned than it went in. Nothing in the corpus argues against the
projection mechanism, the page-lifetime retention rework, or the
deliberate-keep shape; several findings independently validate
choices the concept made before the research existed (append-only
restore, word-level diffs, in-place variants, legible bounds). The
corrections run the other way: one capability is framed too
pessimistically (№9, cross-device), one settle-item gets sharper
numbers (the gap threshold), and three small affordances should be
pulled forward or added (change-size rows, Copy in the first cut,
sibling arrows as the variant surface). One loss category the
research ranks second, durable drafts, is already served by
machinery the spec does not bother to claim credit for.

## Where the research confirms the concept

- **Restore semantics (finding 03, opportunity "Say what restore
  does").** The research names three verbs (destructive rollback,
  append, copy-out) and takes append as the only defensible one:
  Figma writes two checkpoints per restore so the timeline never
  loses a frame. ADR-0025's restore is append by construction, and
  stronger than Figma's: both states are already projections of the
  log, so nothing needs writing at all. Spec capability 5 is the
  design position the research arrives at independently.
- **Diff-first display (finding 07).** Store character-level, render
  word-level, and never line-diff short prose (measured 0.5:1,
  worse than full copies). The op log is the character-level store;
  capability 4 already makes word-level deltas first-class. The
  line-diffing note confirms Loro deletes reference the removed
  characters' op ids, which is what span-level reconstruction rides
  on.
- **Variants in place, tree underneath (finding 05, the
  "branch on edit" family).** Users reject tree UIs and mourn the
  sibling arrows; the demand is variants in place. Capability 7 and
  ADR-0025 part 3 are exactly this. Roam's block versions behind a
  sibling counter are the closest shipped precedent to the whole
  feature.
- **Legible bounds (finding 01's retention half, capability 8).**
  Surprise retention limits are a standing support-forum genre. The
  page-lifetime rework in ADR-0025 part 2 is the strong form of the
  fix: retention equals the lifetime the user already reasons about,
  and absence reads as policy.
- **Deliberate checkpoints (capability 6).** The agentic editors
  (Cursor, Windsurf, Claude Code) have made "checkpoint before the
  risky thing" muscle memory, and Scrivener's snapshot reflex is the
  closest workflow to wording iteration. The reflex arrives trained.
- **The storage arithmetic (finding 06).** History for short-form
  text is measured in phone photos per year; plan gating is
  segmentation, not cost recovery. This defuses the one quantitative
  worry in ADR-0025 part 2: the size budget is a fence expected to
  stay quiet, and the eject trigger watching it should rarely fire.
  Tenet №1's "unlimited history is what products charge for" now has
  numbers behind it (roughly $0.0004 per user per month at
  Notion-Business retention).
- **Positioning.** The research's family map has a hole shaped like
  this feature. The scratchpad neighbors (Tot, Antinote) protect the
  whole store, not the phrasing of one thing; the no-history club
  includes Apple Notes, Bear, Heynote, and every email client; and
  below-document restore ships in five places, none of them note
  apps. Block-grain history in a temporary-text tool is unserved.

## Where the research changes or sharpens the concept

### 1. Capability 9 is framed too pessimistically

**The research:** sync overwrite is the dominant loss story (finding
01, about 13 distinct sources: a note silently reverting to another
device's older copy, noticed days later), and most shipped history is
device-local, which is exactly where it cannot help (finding 02).

**The concept:** capability 9 records cross-device history wholesale
as "the want that lost" to ADR-0021's join-at-key-frame law.

**The reconciliation:** the loss story the market suffers is a
file-sync failure, last-write-wins clobbering divergent copies. This
product structurally cannot produce it: within a GOP, ops merge
rather than overwrite, and ADR-0021 is explicit that an adopting
device's unpublished local edits are re-entered as new operations or
preserved for explicit recovery, never dropped ("convergence without
silent loss"). The number-one reason users want cross-device history
is a wound this architecture does not inflict.

And the want is partially granted already. Peer deltas enter the
local op log as ordinary changes with their own actors and
timestamps, so on a synced page the panel naturally shows revisions
authored on the other device since this device joined. What cannot
travel is history from behind a key frame, which is precisely the
history a joiner never receives.

**Disposition: respec capability 9.** From "the want that lost" to
three honest clauses: the loss the want guards against cannot occur
here; live-window history is cross-device by construction; only
pre-join history stays home, per the ratified law. A panel
distinguishing which device authored a revision (the research's "the
phone's copy won" question) is derivable from actor ids and worth
considering in the #102 surface work, noting that mapping actors to
device names needs pairing metadata the panel does not otherwise
touch.

### 2. The gap threshold gets numbers, and the read-time advantage gets named

**The research:** six version-birth heuristics ship today (finding
04); the keystroke-logging literature puts the cognitively
meaningful pause at about 2 seconds, lengthening at sentence and
paragraph boundaries, and no tool uses it. The report's recommended
snapshotter: idle at least 2 s at a sentence or paragraph boundary,
a 20 s fallback anywhere, hard triggers on paste, select-all-delete,
and send.

**The concept:** an idle-gap threshold "in the minutes," plus the
forced boundary before any large deletion, both read-time
parameters.

**The reconciliation:** every surveyed product must answer "when is
a version" at write time and live with the loss inside its answer.
The projection design does not: the log is keystroke-grained, so
every heuristic in the research's table is available retroactively,
and the choice is about display legibility, not about what is
recoverable. Capability 1 is satisfied before any threshold is
picked. That structural advantage should be stated in the spec,
because it is the feature's cleanest differentiation from all
ninety-odd products surveyed.

**Disposition: sharpen ADR-0025's settle-item.** Seed the dogfood
defaults from the literature rather than feel alone: cluster on
idle gaps of roughly 20 s to 2 min (the 2 s cognitive pause is too
fine for a list; the minutes-scale first guess is likely too
coarse), prefer boundaries where the reconstructed text ends at a
sentence or paragraph edge (checkable at read time, since the fork
yields the text), and keep the forced pre-deletion boundary already
decided. One research trigger does not map: "send." The seal
gestures are reads and leave no ops, so a seal cannot be a derived
boundary; making it one would mean recording an event outside the
log, a small retention decision that should be argued on its own if
dogfood misses it, not adopted by default.

### 3. Restore and the undo stack

**The research:** whatever the semantics, restore has to seal the
undo stack; Zed shipped a bug where undo after a restore wiped the
buffer because the restore was the last undoable action.

**The concept:** restore is an ordinary commit, undoable like any
edit.

**The reconciliation:** these disagree only on the surface. The
sealed-stack rule is a remedy for systems where the pre-restore
state exists nowhere once undone. Here both endpoints of a restore
are projections of the log; undoing a restore lands on text that is
itself the newest recoverable state. Undoable-restore is safe
precisely because of part 1, and the Zed failure cannot occur.

**Disposition: keep the concept; add one test obligation.** The
follow-on design should carry an explicit case: undo immediately
after restore, then reopen the panel, and both texts are present.
That is the property the research's rule is protecting, proven
rather than enforced.

### 4. Change-size signal per revision row

**The research:** nobody shows a change-size signal in a version
list; Wikipedia's byte delta is the model; "plus 14 / minus 9 words,
2 sentences" lets the user find the big rewrite without opening
anything (finding 07, opportunity "Diff-first history").

**Disposition: adopt into capability 4.** The panel's list rows
carry a word-level delta summary beside the `DDD HH:mm` stamp. Cheap
at read time (the texts are already reconstructed), and it converts
the list from near-identical paragraphs into a scannable timeline.

### 5. Copy belongs in the first cut

**The research:** "select all, copy, then try the edit" is the
universal folk workaround, documented since 2008 and still in use;
honoring the habit beats trying to break it.

**The concept:** the keep-gesture side doc parks Copy (candidate 5)
as a complement and leaves "whether it lands in the first cut" open.

**Disposition: close the question, first cut.** One button per
revision row. The clipboard is a governed boundary here (core-side
pasteboard, the sealed-paste contract), so it is a small feature
rather than a footnote, exactly as the side doc says; the research
removes the doubt about whether it earns its place.

### 6. The variant surface has a shipped grammar

**The research:** the sibling counter (`< 2/3 >`) is "the smallest
version UI in existence" and its removal is the most-mourned change
in OpenAI's forum this year; users reject branching UIs as harder to
compare; Langfuse's movable-label model makes flipping a re-point
where nothing is copied or deleted.

**The concept:** part 3 leaves the variant surface to follow-on
design; the side doc's leading answer for a non-showing variant is
candidate 1's dimmed in-context region.

**Disposition: feed the follow-on design, two concrete inputs.** The
flip affordance should be the sibling counter on the block, since
two years of AI chat trained that expectation; and flipping should
commit as a re-point of which candidate shows (Langfuse's shape),
with the dimmed region remaining the candidate answer for showing a
non-active variant's text in context when asked. Neither is decided
here; both go in with the arrows as the presumptive default.

### 7. Durable drafts: claim the credit

**The research:** the second-largest loss job (9 sources) is not
history at all: it is text surviving submit, close, and crash. The
recommended remedies (snapshot on dismiss, hot exit) are the Zulip
and Sublime patterns.

**The reconciliation:** the concept never mentions this because the
product solved it before the feature existed: the op log persists
inside the sealed snapshot across quit and relaunch (ADR-0016), so
hot exit is the resting state, not a feature. The spec's "what
already exists" section should say so, because it means the revision
panel's floor at reopen is the full pre-quit history, which no
surveyed scratchpad app offers.

**Disposition: one paragraph in the spec's "what already exists."**

### 8. The provenance layer stays a recorded divergence

**The research:** per-span authorship (iA Writer, Linear) and
selective undo are an emerging layer, answering "who wrote this"
rather than "what was this before" (finding 08).

**The reconciliation:** for a single-author pad the axis mostly
collapses to self versus paste, and the paste's origin is content
that crosses no read surface (ADR-0013, restated in ADR-0025). This
is a deliberate divergence, not a gap: the product forgoes the
authorship layer because its one interesting datum is a URL that can
carry a token. The device-attribution sliver that survives sync is
covered under item 1.

**Disposition: no change; noted so the divergence is on the record.**

## What the research does not touch

The retention argument itself. Nothing in the corpus surveys a
product that forgets on purpose; every incumbent treats more
retention as strictly better, bounded only by plan tier. The
concept's central trade, page-lifetime memory with a deliberate
shed, has no market comparable, which cuts both ways: no evidence
against it, and no cover from precedent. The ratification ask in
ADR-0025 part 2 stands on the doctrine argument alone.
