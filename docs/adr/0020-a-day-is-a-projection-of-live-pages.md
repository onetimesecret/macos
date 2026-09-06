---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0020: A day is a projection of live pages

- **Status:** proposed
- **Date:** 2026-08-24
- **Depends on:** [ADR-0006](0006-persistent-editor-storage-swap.md), [ADR-0016](0016-content-persists-across-restart.md), and [ADR-0017](0017-durable-tabs-expiring-pages.md).

## Context

The vertical-time-tabs prototype groups pages by relative day. Persisting Day
objects would add another lifetime mechanism, take slots on the strip, and
require persistence-format policy for state that can instead be derived from
existing live Pages.

The mode must preserve ADR-0006's single persistent editor, add no periodic timer
for midnight, and leave the horizontal Tab model unchanged when disabled.

Product behavior, interaction details, implementation mapping, and open questions
belong in the [vertical-time-tabs specification](../spec/feature/vertical-time-tabs/README.md).
The original implementation chronology is preserved in its
[decision background](../spec/feature/vertical-time-tabs/decision-background.md),
which also carries the required-work, deferred and see-also material this
record shed in the split.
Hardware checks live in the
[vertical-time-tabs verification procedure](../qa/verification-procedures/vertical-time-tabs.md).

## Decision

Represent a day as a read-only projection over live Pages, never as a persisted
object or Tab. Bucket each Page by its own creation timestamp using the core's
current local offset. Recompute a relative day offset on every summary read.

List a day when it contains a Page with non-whitespace ink or a chip. Always list
today and the selected Page's day so the active region does not appear only after
the first edit. A day with no remaining Page leaves no placeholder or tombstone.

Add no calendar timer. Existing cosmetic refreshes may leave a relative label
stale for up to 30 seconds while resting and one second while raised.

Displaying, entering, restoring, or refreshing the mode mints nothing. Existing
Page-creation gestures remain the only creation paths. The only durable trace of
the mode is a `UserDefaults` presentation preference.

Preserve one editable text view. The active Page uses the permanent editor;
other visible days are non-focusable renderings over separate transient storage.
Moving between days repositions the one editor rather than creating an editor per
Page.

## Consequences

- Toggling modes is reversible without migrating or mutating content.
- Tab identity, order, names, rungs, Page expiry, and the snapshot format remain
  unchanged.
- Relative labels can be briefly stale at midnight because no timer is added.
- Expired and never-populated days are indistinguishable; no deletion marker is
  retained.
- The vertical mode materializes plaintext renderings for visible live Pages
  earlier than horizontal mode would, bounded by the number of live Pages and
  released when the mode unmounts.
- Blank old Pages may stand hidden by the content predicate; the surface must
  disclose that hidden count rather than auto-delete. Since the cap's removal
  (issue #158, ADR-0017's history) they cost nothing but their slot.
- The prototype introduces a second interaction model. Acceptance requires
  dogfood evidence that it should replace or coexist with the horizontal model.

## Eject triggers

- A durable Day, per-day TTL, persisted day index, or calendar event is required.
- A capacity limit of any kind is reached while the projection hides Pages
  users need to reach. The nine-Tab cap did exactly this and was removed on
  2026-09-06 (issue #158), so the trigger now guards against a new one.
- The TTL ceiling changes enough to invalidate the mode's expected visible range.
- Users interpret appearing or disappearing rows as Tabs being destroyed.
- Users routinely leave the mode to reach actions unavailable in the time rail.
- Toggling the mode mutates core state, selection without a user gesture, sealed
  persistence, or key rotation.
- Hardware testing demonstrates that the single-editor invariant does not hold.

## Decision history

- **2026-08-25:** The prototype implementation and verification procedure landed.
  The decision remains proposed pending its dogfood window.
- **2026-09-02:** The record was split into this ADR and the linked decision
  background, which now carries the required-work, deferred and see-also
  material.
