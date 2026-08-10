---
name: adr0013-stage-progress
description: ADR-0013 staged implementation on feature/adr-0013-provenance-core, all six stages landed (stage 6 05dfc26 is the compaction ceremony); gotchas later work inherits
metadata:
  type: project
---

ADR-0013 (ops-based document, Loro) landed in stages on branch
`feature/adr-0013-provenance-core`: stage 1 aa96e8c (Loro wrapper),
stage 2 9bed6ef (document as source of truth in core), stage 3 4d66486
(range ops across the seam, range-taking seal gestures, shell op
emitter), stage 4 9f7b8f2 (OTSSNAP3: sealed content file carries the
per-sheet Loro blob plus an empty materialized-metadata slot; clean
format break, no v2 reader), stage 5 f29ac2b (block identity +
provenance: BlockIndex per sheet, Notion split/merge convention,
derived created/modified, origin URLs as the seal commit's message,
companion_sheet_meta_json / _blocks_json), stage 6 05dfc26 (the
compaction ceremony: SheetDocument::compact rebuilds from runs under
a fresh peer id, BlockIndex::graduate/adopt, materialized summaries
persisted in the stage 4 slot, hooks in cycle_rung/set_rung/pause
top-up). ADR fully implemented; remaining work is product follow-on
(importance counts, margin-drag reorder, sync), not staged ADR work.

**Why:** each stage ran in a fresh conversation with only the spec
for its own stage; the landed shape and its non-obvious constraints
are what later work builds against.

**How to apply:** gotchas later work inherits. Stage 6: the discard is
rebuild-from-runs, never a StateOnly export (the stage 1 spike proved
StateOnly keeps the authoring peer id); the rebuild commit is stamped
timestamp(0) and both `span_provenance` and `latest_timestamp` skip
nonpositive stamps, so re-typed characters do not vote and the
materialized summary answers for a compacted page
(`Sheet::modified_s` merges latest_timestamp with
`max_materialized_modified`). The pause hook is the top-up arm only:
a first press keeps the trail (tested). Restore clamps materialized
stamps to a ceiling of wall_s + STAMP_SLACK_S (2 s) because loro's
recorder rounds to the nearest second while wall truncation floors;
records whose anchor no longer resolves to a block start are dropped
whole, and an adopted record restores the persisted block id. The
materialized slot encodes empty as the empty slice so a compacted
file differs from a stage 4 file only by slot contents. Stage 5:
`SheetDocument::new` keeps `set_change_merge_interval(0)` (loro
merges same-peer changes within 1000 s keeping the EARLIER stamp);
origin rides the seal's own commit via `seal_*_at_with_origin`, never
set_next_commit_message. Block 0's anchor is a hand-built
`Cursor::new(None, container, Side::Left, 0)`; get_cursor(0, Left)
would drift. Loro cursors are unicode indexed; document.rs converts
wire UTF-16 via `LoroText::convert_pos`. Stage 3/4: delegate needs
@preconcurrency; seal routes REQUIRE a valid UTF-16 range; restore
requires chip marks and records to match one to one; peer-id absence
can only be asserted of the ledger, the content blob names it.
