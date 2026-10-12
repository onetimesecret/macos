---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0040: A key rotation reseals drafts before the strip

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md) and [ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/ffi/src/lib.rs`, `companion_persist_rotate_and_save`, and
`crates/ffi/src/files.rs`, `reseal_drafts_beside`). Those comments are
non-authoritative provenance; this record proposes the decision they describe.

[ADR-0016](0016-content-persists-across-restart.md) (accepted) decides when the
content key rotates: "Rotate them when no tab holds a page and when the user
explicitly clears state. If tabs remain after pages expire, rotate and reseal
the tab metadata; remove the state file only when no tabs remain."

ADR-0016's Context states that its numbered sections "now live in that
persistence decision background rather than in this record". Section 6 of
[that background](../plans/trustworthy-persistence-decision-background.md#6-key-rotation-once-bootmismatch-is-gone)
fixes the order of erase and reseal: "The rotation has to complete before the
reseal, so that the generation left behind is already undecryptable when it is
unlinked."

[ADR-0028](0028-file-backed-documents-are-a-peer-content-class.md) (proposed)
adds a second file under the same key: "Whenever that key rotates, the drafts
file is rewritten under the new key in the same operation."

So after the old halves are erased, two files rest under a key that no longer
exists and both must be rewritten under the new one. Neither can stay readable
across the erasure, because the new key is minted only after the old halves are
gone. The order of the two writes decides which file survives a crash or a
refused write inside that window. The state file holds tab names, rungs and
strip order and, because the rotation fires only when no tab holds a page, no
page content. The drafts file holds unsaved edits to open files.

## Decision

`companion_persist_rotate_and_save` rewrites the drafts file under the new key
before it reseals the state file.

Both writes are attempted whatever the first one returns, and the call reports
false if either fails. A rotation with no drafts file on disk and no open file
writes no drafts file.

## Consequences

- A crash between the two writes leaves the drafts readable under the new key
  and the state file sealed under halves that no longer exist. That state file
  then fails to open, and ADR-0016's refusal path applies until the user clears
  it. The tab arrangement is lost; unsaved typing is not.
- The reverse order would put a person's unsaved file edits at risk to protect
  tab names, rungs and order, which carry no page content at this point.
- The window grows by the time a drafts write takes. Drafts are bounded
  (ADR-0028), so the growth is bounded too.
- No test pins the order of the two writes. `a_rotation_leaves_the_drafts_readable_under_the_new_key`
  (`crates/ffi/src/files.rs`) pins only that both end up under the new key.

## Eject triggers

- ADR-0028 is rejected or its drafts file stops sharing the content key, which
  removes the second file this order ranks.
- A rotation becomes able to mint and write under the new key before the old
  halves are erased without leaving two live keys, which closes the window
  this order ranks losses in.
- Field reports show strip layouts lost in this window often enough that
  losing the arrangement is no longer the cheaper failure.
