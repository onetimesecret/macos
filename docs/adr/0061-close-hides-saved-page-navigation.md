---
documentation_status: needs-review
---

# ADR-0061: Close hides saved page navigation

- **Status:** accepted
- **Date:** 2026-10-31
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md), [ADR-0017](0017-durable-tabs-expiring-pages.md).
- **Supersedes in part:** [ADR-0017](0017-durable-tabs-expiring-pages.md), its consequence that Close removes the durable tab, for user-facing page/tab Close actions only.

## Context

The maintainer confirmed the requested behavior in conversation
`01a1942c-9584-7c91-9500-84b09f73a49a`: “Yes—close hides it; reopen restores it”.
The authorized relay specifies both Timeline and Tabs and separates Close Window.
It explicitly leaves expiry policy undecided and unchanged by this work.

The old UI close route called the destructive tab-removal operation. Hiding a
page must instead leave the existing saved item available for reopening under
its existing lifetime rules.

## Decision

User-facing Close dismisses the existing page/tab from navigation in both
Timeline and Tabs. Reopen selects that same saved item rather than duplicating
it. Close Window remains a separate command. Close does not change a page's
expiry schedule or pause its clock.

Retain the full tab roster in the content store. Track closed navigation UUIDs
as local presentation metadata and filter visible navigation only. Save current
edits before hiding; refuse Close when the save is refused. Reopening a slot
whose page expired shows the existing empty slot without creating a new page.

## Consequences

- Closing every visible page leaves the saved roster available to reopen.
- Hidden pages still participate in existing save, expiry and pad ownership paths.
- Closed navigation state is local; this decision adds no cross-device UI-state synchronization.
- Reopen Last Closed and Re-open Dated Tabs provide explicit discovery routes.
- Existing destructive discard operations remain separate from Close.

The [implementation plan](../plans/close-reopen-command-palette-2026-10-31.md)
records tasks and verification. This decision is not evidence that a particular
build passed persistence or UI tests.

Additional consequences of the revised Close route:

- Expired empty slots remain in the saved roster. Repeated creation and closing
  can increase roster size; a separate removal or compaction policy is deferred.
- Close no longer supplies the old tab-removal trigger for ledger discard events
  or empty-roster cleanup. Explicit discard and state-clear routes remain separate.
- Saving before hiding currently performs a synchronous full-state save. Large
  rosters may make Close slower; changing that ordering needs separate validation.
- When restore has not completed or writing is unavailable for the session,
  Close refuses with a distinct unavailable-state message rather than implying
  that an attempted write failed.

- Closing a page retains its editor storage, caret state and cached rendered text
  while the page remains in the full roster. Expiry and existing cleanup paths,
  rather than Close, remove those entries.
- Reopening an expired slot from Timeline switches the saved layout preference
  to Tabs so the original empty slot is visible. The notice identifies the switch;
  a later launch continues in Tabs until the user chooses Timeline again.

- The implementation commits a valid variable-name draft before attempting the
  Close save. A refused save leaves that local edit in place and keeps an open
  note editor available for correction or retry.

## Eject triggers

- Closed navigation state needs cross-device synchronization.
- A change to expiry behavior is requested independently.
- Save refusal or restoration cannot be explained clearly through the UI.

## Decision history

- **2026-10-31:** The maintainer confirmed hide/reopen behavior for both layouts.
  Architecture implements that direction without changing content-store format.
