# Proposal: capacity must not prevent writing Today

**Status:** proposal from product review on 2026-09-04, implemented
2026-09-06 (issue #158). The tab cap was removed from the core, `⌘1` to `⌘9`
stayed as shortcuts to the first nine visible targets, the strip scrolls to
hold the rest, and ⌘N on today's page makes a second page. The change is
recorded in the decision history of
[ADR-0017](../../../adr/0017-durable-tabs-expiring-pages.md); the proposed
time-tabs decision ([ADR-0020](../../../adr/0020-a-day-is-a-projection-of-live-pages.md))
is still proposed. The open discussion below, whether empty tabs are ever
removed automatically, stays open and was not needed: the cap's removal made
the question moot for creation.

## Problem observed

In time-tabs mode, clicking the empty Today region can attempt to create
today's page. That attempt can be refused when nine durable tabs already
exist, including tabs that the time-tabs projection does not display. The user
must turn time tabs off, find a tab in the horizontal strip, close it, and
return before they can write today's note.

The current implementation sets the cap at nine because it is the limit of the
`⌘1`–`⌘9` page-selection map; `⌘0` is assigned to the ledger
(`crates/core/src/store.rs`). ADR-0017 deliberately retains empty tabs and
states: "Empty Tabs remain visible and count toward the nine-Tab cap. Users may
need to close empty Tabs before creating more."

## Agreed direction

1. **Today is always creatable.** A user must not be refused when trying to
   start today's note solely because existing tab state has reached a
   keyboard-driven cap.
2. **Keyboard shortcuts and capacity are separate concerns.** `⌘1`–`⌘9` may
   remain shortcuts for the first nine visible targets, but they must not set
   the maximum number of notes or tabs.
3. **Any retained capacity is visible and manageable in the active mode.** The
   time-tabs view must not strand a user behind tab state it hides.
4. **Changing the implementation must preserve the user-facing purpose of
   tabs.** In particular, it must not silently repurpose an arbitrary named
   empty tab for today's note.

## Open discussion

Whether the product should automatically remove durable empty tabs remains
open. It is a retention and navigation-policy change, not an implementation
detail of making Today creatable. Any proposal to do so must explicitly
re-evaluate ADR-0017's reason for retaining tab identity, order, and
user-entered names after a page expires; it must not be introduced as silent
cleanup.

## Follow-up design work

Before implementation, decide:

- whether tabs/pages become unbounded or receive a new, user-meaningful
  capacity policy;
- how overflow is navigated while preserving `⌘1`–`⌘9` as optional shortcuts;
- how time-tabs exposes all state that can affect creation; and
- the migration and testing consequences for durable-tab and time-tabs
  behavior.
