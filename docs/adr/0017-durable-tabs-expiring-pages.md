---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0017: Durable tabs, expiring pages

- **Status:** accepted
- **Date:** 2026-08-20
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md). The object-graph change shipped in the same persistence format break.

## Context

A tab and its page were one object. When a page expired, its navigation slot,
position, label, and keyboard target disappeared with it. This made a strip of
up to nine tabs also a strip of independent deadlines and destroyed the layout
the user had arranged.

The split must preserve the no-tombstone rule for sealed content, avoid retaining
content-derived labels indefinitely, and keep expiry as a property of content
rather than navigation.

The implementation inventory and field-by-field analysis are preserved in
[the durable-tabs decision background](../plans/durable-tabs-decision-background.md).
Milestone status belongs in the [trustworthy persistence plan](../plans/trustworthy-persistence.md).

## Decision

Split the object into a durable **Tab** and an optional, expiring **Page**.

A Tab owns its identity, creation time, optional user-entered name, strip order,
and birth rung. It holds at most one Page. A Page owns its own identity,
document, blocks, chips, derived title, countdown, and hold state. When a Page
expires, it is dropped whole and its Tab remains empty and reusable.

The rung is a Tab preference, not a Tab TTL. It determines the initial lifetime
of replacement pages but has no clock or deadline while the Tab is empty.

Resolve a tab label in this order: user-entered Tab name, live Page-derived title,
then a placeholder based on the Tab's creation time. Content-derived titles never
persist on the Tab and die with the Page.

An empty Tab mints a Page only after a deliberate user action: selecting that Tab
through the supported selection gestures or using the Return create action.
Expiry, restore, refresh, and merely displaying an empty Tab mint nothing.

Treat “no tab holds a page” and “no tabs remain” as separate core predicates. The
first rotates the content key and reseals surviving Tab metadata; the second
removes the state file.

## Consequences

- Tab identity, order, name, and keyboard position survive every Page that lived
  in the slot.
- Expiry still destroys the Page, chips, undo history, and content-derived title
  as one unit; no content tombstone is introduced.
- Shell editor storage and undo state must be keyed by Page identity, not Tab
  identity, so a replacement Page cannot resurrect content from its predecessor.
- Empty Tabs remain visible and count toward the nine-Tab cap. Users may need to
  close empty Tabs before creating more.
- A user-entered Tab name can outlive all Pages in that Tab and can remain in the
  ledger for its retention window. The app must not derive such durable text
  without the user's action.
- Selecting an empty Tab creates an empty Page, starts its countdown, and records
  creation; expiry itself does not create a replacement.
- The persistence object graph changed, but it shared ADR-0016's one-time format
  break rather than causing a second loss.

## Eject triggers

- Users routinely hit the nine-Tab cap while several Tabs are empty.
- Durable Tab names are repeatedly used for secrets, making the accepted label
  exposure unsafe in practice.
- Tab rename usage is near zero and placeholder labels fail to preserve useful
  slot identity.
- A second automatic Tab lifetime mechanism is required; that reopens both this
  decision and ADR-0016.
- The stored rung is consistently misunderstood or implemented as a Tab TTL.

## Decision history

- **2026-08-20:** Accepted to ship with ADR-0016's persistence format break.
- Implementation sequencing and completed work are recorded in the linked plan
  and decision background, not in this ADR.
