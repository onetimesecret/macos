# The Loro concepts report against the architecture: reconciliation

Side doc to [`README.md`](README.md) · 2026-08-29.
Compares the Loro concepts report
([`2026-0828-loro-concepts.html`](../../../research/2026-0828-loro-concepts.html):
fifteen concept digests, seven findings, seven ranked opportunities)
against the core's actual Loro usage and the concept as it stands
(the capability spec, ADR-0025, the keep-gesture and
research-reconciliation side docs). The report's load-bearing claims
were verified against the Rust sources at the pinned loro 1.13.9,
which is also the newest published release. Findings and
opportunities are cited by the report's own numbers.

## Verdict in one paragraph

The report is sound (one refuted figure, corrected in place) and its
relation to this project splits into three piles. Seven of the
fifteen concepts are already load-bearing in the core; the report's
strongest findings restate ADR-0025's thesis from the library's
side. Two verified facts changed the ADR the same day: the
per-boundary reconstruction primitive (fork once and check out, not
`fork_at` per boundary) and the overstated "merging disabled"
context line. The report's remaining novel uses are inversions:
paths this doctrine deliberately refuses (peer identity as
provenance, shallow snapshots as forgetting, frontiers as durable
bookmarks, write-time session tuning), each already argued somewhere
in the ADR set. One item graduated past reconciliation entirely:
finding F4 turned into a decision to adopt Loro's `UndoManager`
ahead of the sync milestone.

## The report's own accuracy

- **Verified:** all five Document Size benchmark figures, and the
  1000-second change-merge default the report had flagged
  unverified. Rust `set_change_merge_interval` takes plain seconds;
  the JS binding's units differ, which is likely where the hedge
  came from.
- **Refuted:** finding F4's "1000 ms merge" default for
  `UndoManager`. The Rust default is 0, no coalescing: every commit
  is its own undo step until configured. The 100-step cap, the
  local-only semantics, and the cursor save/restore hooks are
  confirmed verbatim.
- **Incomplete:** concept 13 folds redaction into
  delete-then-shallow-export. Loro also ships `loro::json::redact`,
  which blanks op payloads (text becomes U+FFFD) while preserving
  the DAG, timestamps, and convergence with unredacted peers.
- **Missing economics:** `fork_at` is a full snapshot export
  imported into a brand-new document, plus an internal
  checkout-and-back on the source. It is not a light primitive.

The three text fixes are applied to the local copy of the report; if
it is republished they travel with it.

## What the core already uses

Loro enters the codebase through exactly one file,
`crates/core/src/document.rs`, by design. Against the report's
fifteen concepts:

| # | Concept | Standing here |
|---|---------|---------------|
| 1 | CRDTs | Used. One doc per page, a single `"body"` text container plus chip marks; merge behavior left entirely to Loro. |
| 2 | Container | Partial. Text only; no Map, List, Tree, or Counter, no nesting. Chips live beside the document as sealed records; block identity lives outside it in `BlockIndex`. |
| 3 | Attached/detached | Not used. No checkout anywhere; the only second view is a discarded trial `fork()` on the update path. Becomes load-bearing under ADR-0025 part 1. |
| 4 | OpLog/DocState | Partial. The op log is read via version vector, frontiers, and `get_change`; the two version pointers are never distinguished, which is safe only because nothing detaches. |
| 5 | Ops and Changes | Used heavily; the provenance substrate. `span_provenance` reads exactly `ChangeMeta.timestamp` and `.message()` (`document.rs`). |
| 6 | Transactions | Partial. Explicit commit at every mutation boundary; commit messages carry paste origin. |
| 7 | Frontiers | Partial. Read for emptiness and the newest stamp only; nothing ever encodes or stores one. |
| 8 | Version Vector | Used. The opaque sync cursor (`document.rs`), deliberately unreadable above the module. |
| 9 | Cursor | Used twice over: persisted block anchors revalidated on restore, and the per-character op-id probe behind provenance. |
| 10 | Import Status | Partial. Fail-closed on the update path (`UpdateRefusal::MissingHistory`); `import_snapshot` discards the status, benign while snapshots are self-contained sealed bytes. |
| 11 | PeerID | Used, as an anti-linkability asset: random per instance, re-minted at restore and compaction, never persisted (see the inversions below). |
| 12 | Eg-Walker | Not used at the API level; compaction is a re-type from runs, not a replay. |
| 13 | Shallow snapshots | Measured and rejected: the recorded spike (`document.rs`) shows state-only export sheds deleted text but keeps the authoring peer id. |
| 14 | Choosing types | Settled and narrow: text plus marks, UTF-16 normalized at the module boundary, all structure kept outside the CRDT. |
| 15 | When not CRDTs | Practiced. Ledger, chips, TTL clocks, tab metadata, and block grouping all live outside; the relay is the authority shape ADR-0021 chose. |

## Where the report validates the concept

- Finding F1 (the substrate already contains the feature set
  incumbents hand-roll) is ADR-0025 part 1's thesis restated.
- Opportunity 2 (non-destructive restore) is capability 5 by
  construction, the same convergence the research-reconciliation doc
  recorded from the incumbent corpus.
- Opportunity 7 calls selective regional undo research-grade.
  Block-grain take-back is exactly that, delivered as a projection
  plus one ordinary commit; the spec is entitled to claim it.
- Findings F2 and F6 land where the concept already stands: the
  keep-everything arithmetic backs the expectation that ADR-0025's
  size budget stays quiet, and the two warning concepts describe
  boundaries this codebase already draws.

## What it changed, applied to ADR-0025

1. **The reconstruction primitive.** Part 1 read "forking the
   document at that frontier (`LoroDoc::fork_at`)". Verified
   internals: every `fork_at` is a snapshot export and re-import
   plus a checkout-and-back on the live document, so a scrub of N
   boundaries would be N round trips. The ADR now says fork once,
   then check the fork out read-only per boundary; read-only time
   travel is Loro's documented pattern and needs no
   `set_detached_editing`. The measured-cost settle item and the
   matching eject trigger are reworded to match.
2. **"Merging disabled" was overstated.**
   `set_change_merge_interval(0)` (`document.rs`) still
   coalesces same-peer commits sharing a message inside one
   wall-clock second, because the library's test is `<= 0` over
   whole-second stamps. Far below any boundary the ADR derives, so
   harmless to part 1, but the context line now says what is true.
   A paste's origin-carrying commit stays unmerged only because its
   message differs. The comment at `document.rs` deserves the
   same word the next time that file is touched.

## Where the doctrine inverts the report

- **F3 and opportunity 4 (pause-tuned write-time sessions):
  leapfrogged.** The report recommends tuning the change-merge
  window so history units match cognition, the right advice for an
  app that must choose granularity at write time. This design keeps
  keystroke grain and chooses boundaries at read time, the
  structural advantage the research-reconciliation doc already
  names: every write-time heuristic stays available retroactively.
- **Opportunity 3 (AI as a peer, devices as peers): the anti-goal.**
  The report treats PeerID as an attribution asset. Here it is a
  linkability liability: random per document instance, re-minted at
  restore and compaction, forced distinct at the ceremony, never
  persisted, with version bytes kept opaque precisely so a peer id
  cannot be read out of them. The provenance channel is the commit
  message. The device-attribution sliver that survives sync is
  covered by the research-reconciliation doc's capability 9 rework.
- **F5 and opportunity 5 (shallow snapshots as true deletion): the
  right thesis, the wrong mechanism for this product.** The spike
  found shallow-style export keeps the authoring peer id and
  orphans change metadata. The shed destroys strictly more by
  rebuilding from runs into a fresh document, and GOP key rotation
  makes the relay's retained ciphertext undecryptable. The `redact`
  API does not change the analysis: it preserves the op DAG and
  timing, which is precisely the metadata a shed exists to destroy.
- **F7 (frontiers as free bookmarks): would recreate a rejected
  candidate.** A checkpoint stored as frontier plus label is
  candidate 8 of the keep-gesture doc, superseded because a pointer
  into the log dies at every shed and a rebuilt document has no
  history to point into. Checkpoints hold text for that reason; the
  cheapness argument does not survive this retention model.
- **Opportunity 1 (undo that survives closing): the resting state.**
  Already claimed in the research-reconciliation doc's item 7.
- **Opportunity 6 (sync you can see): aimed at a wound this
  architecture does not inflict.** The silent-divergence pains it
  targets are file-sync failures; within a GOP, ops merge rather
  than overwrite, and the hold already surfaces sync state the
  fail-closed way (ADR-0021).

## The UndoManager switch (decided direction, 2026-08-29)

Undo lives in AppKit today and no `UndoManager` exists in the core,
which is workable only while every op is local: once #95 to #98
land remote operations into live documents, a shell-level undo can
revert another device's text, the exact failure Loro's local-only
`UndoManager` exists to prevent. The maintainer's call is to switch
before that point rather than at it.

Boundaries the switch must respect, recorded so the implementation
argument starts honest:

- **Cross-device undo stays out, twice over.** Loro's `UndoManager`
  reverts only the bound peer's operations by design, and ADR-0021's
  key-frame law means a joiner never holds the ops an away-device
  undo would need. What the switch buys is undo that is safe beside
  other devices' edits, not undo that reaches across them.
- **The binding dies at the boundaries this product creates.** The
  peer id is re-minted at every restore and every compaction, and a
  ceremony destroys the ops an undo stack points into. The stack
  must be rebuilt or cleared at both boundaries; whether undo
  survives relaunch at all is a design question the switch has to
  answer explicitly (today AppKit's stack dies with the window,
  which is at least honest).
- **Defaults need setting.** Merge interval 0 means keystroke-grain
  undo steps; a per-gesture feel needs the interval configured. The
  cursor save/restore hooks (`set_on_push`/`set_on_pop`) replace
  AppKit's selection restoration and should land in the same change.

### What the switch decided (delivered, 2026-09-01, issue #132)

- **Undo does not survive relaunch, deliberately.** The manager is
  bound where the document is constructed
  (`document.rs`), which makes every construction path a rebind: a
  restore reads a snapshot into a document minted there, and the
  ceremony rebuilds into one. Both re-mint the peer id, so a stack
  carried across either would point into operations that no longer
  exist. Starting empty is therefore a property of the construction
  rather than a rule to remember, and it matches what AppKit offered,
  a stack that died with the window. The compaction path clears
  explicitly on top of that (`document.rs`), because the rebuild
  is typed in as local operations and would otherwise leave one step
  that undid the whole page.
- **The merge interval is two seconds**
  (`document.rs`), the research's figure, argued in full at
  [`2026-0901-pause-boundaries.md`](2026-0901-pause-boundaries.md)
  along with the caveat that the library's rule is a ceiling on a
  step's growth rather than the idle-gap detector the literature
  describes. It groups local operations only; ADR-0021 section 4's
  clock batching is untouched.
- **The stack is forgotten wherever a step would be a lie.** Beyond
  the two ceremonies: a wholesale restate, a seal, a chip burned out
  of the page, any settle that reaps a chip, and any batch that stands
  a sentinel through the operation path, which is how a drag carrying
  a chip arrives. Undo never un-seals and never resurrects
  (ADR-0009), and a sentinel standing for zeroized bytes is the one
  document shape the restore path calls damage.
- **The edits the page makes for the writer begin their own step**
  (`document.rs`): a continued list marker, a nudged indent. They
  arrive a keystroke after the burst they should not join, so the
  interval is dropped across that one commit and one press takes the
  automation back alone.
- **The menu is the same stack as the chord.** The page's text view
  answers `undo:` and `redo:` itself, and the editor allows no AppKit
  undo at all, so there is no second history of the document for Edit
  then Undo to reach. Both routes refuse a page shown read-only, and
  the guard sits inside the step rather than at each door.

  The greying out is the model's, not the view's. A SwiftUI menu item
  carries SwiftUI's own target and is never offered to
  `validateMenuItem`, so the two items read `PageModel.editSteps`,
  which the model re-asks of the core for the page under the editor.
  The view keeps its own validation for any route that arrives
  nil-targeted. Enablement is display either way: a click with no page
  holding the keyboard reaches nobody, and a read-only page refuses the
  step.
- **A neighbouring device's chip delete costs this device its steps.**
  Chip liveness follows the shared document, so a peer backspacing over
  a sentinel zeroizes the bytes here, and the settle that reaps the
  chip forgets the local stack with them. That is the intended reading
  of the rule rather than an accident: a step standing across that
  moment could stand the sentinel again over nothing, the one document
  shape the restore path calls damage (ADR-0009). It is the only place
  a remote event destroys local state, and it is held by a test.
- **`clear()` drops, it does not zeroize.** Forgetting the stack frees
  the steps without wiping the memory they sat in, and it never touched
  chip bytes in the first place: a chip's plaintext lives in its own
  `Zeroizing` buffer and never enters the document, and the ink a step
  would restore is already in the op log until the ceremony rebuilds
  it. So `forget_undo` is a correctness valve, standing between undo
  and a document shape that must not exist, and not a memory
  guarantee. The memory guarantee rests where it always has, on the
  ceremony (ADR-0007).
- **The cursor hooks carry the caret.** The push hook records where
  the step was authored and the pop hook hands it back, converted to
  UTF-16 only once the document is still again. The position is a
  Loro cursor rather than a bare offset, so a peer's operations
  arriving while the step waits move it correctly.

## Facts recorded for later reference

- `checkout` on a detached document is read-only by default and
  reading while detached is the documented pattern;
  `set_detached_editing` exists only for editing the past, which
  nothing here wants.
- Cursor resolution has a distinct, catchable error when the
  history behind an anchor has been trimmed
  (`CannotFindRelativePosition::HistoryCleared`); relevant only if
  shallow export ever returns from rejection.
- `set_record_timestamp` is runtime configuration that must be
  reapplied per document instance; every construction path here
  already does (`document.rs`).
- `blocks_meta()` already re-derives provenance per character per
  read, so ADR-0025's derivation walk joins a read path that is
  O(document) per refresh, not a newly expensive one.
- The sealed container magic is `OTSSNAP4` (`persist.rs`);
  earlier notes citing `OTSSNAP3` are stale.
