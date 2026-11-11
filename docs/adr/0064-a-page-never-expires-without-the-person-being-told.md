---
documentation_status: needs-review
---

# ADR-0064: A page never expires without the person being told

- **Status:** proposed
- **Date:** 2026-11-10
- **Depends on:** [ADR-0017](0017-durable-tabs-expiring-pages.md), [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

A page expires on its countdown. Before this record the shell settled an
expiry and showed nothing: the sentence `this page has expired.` appeared only
when a person acted on a page that was already gone. The ledger recorded each
expiry, and its entry points (the tab, `cmd-0` and the Settings clear) were
compiled off under issue #78.

[Tenet 1](../tenets.md#1-losing-work-is-unforgivable-even-here) reads:
"Forgetting is only trustworthy when it is visibly on schedule and never by
accident." A person who was away when a page went had no way to see that the
schedule, and nothing else, took it.

Three earlier records say the opposite of what this one proposes, and they
are quoted here so the conflict is on the page:

- The [interaction model](../spec/design/2026-0707-interaction-model.md) has a
  bullet that opens "Expiry is silent".
- The [design principles](../spec/design/2026-0707-design-principles.md),
  section 1, settle the question of a warning before expiry with "No
  notification by default; the draining cue *is* the warning, and the user
  chose the TTL."
- D-14 of the [UI/UX decisions](../spec/design/2026-0915-ui-ux-decisions.md),
  marked fixed, opens "No modals, no interrupting dialogs, no notifications,
  badges, bounce or count chips." That record is superseded, and the
  [sealed-content revision](../spec/design/2026-1031-sealed-content-ux-revision.md)
  that replaced it incorporates D-14 unchanged.

The draining cue is on the tab, and the tab is not in front of a person whose
app is in the background or not running.

## Decision

The app tells the person about an expiry in three ways, and none of them is a
dialog.

1. **A standing line for pages that expired while nobody was attending.** The
   shell keeps the pages that expired since a person last typed in a page or
   dismissed the line, by title and time. Titles are the ones the ledger
   already stores; content is never kept. The line stands under the page with
   two actions, Show Ledger and Dismiss. Raising or activating the surface
   does not clear it. It is not persisted: at launch it is rebuilt from the
   expiry records the restore itself wrote for the time away.
2. **The ledger is reachable.** Its tab is drawn, `cmd-0` is bound to
   `ledger::Show` in the bundled keymap, the View menu and the command palette
   list Show Ledger, and Settings draws Clear the Ledger. With multiple pads
   enabled, the pad layer still gives `cmd-0` to Scratch as ADR-0039 decided.
3. **A last-hour warning while the app is not active.** When a page with
   content enters its last hour and the app is not frontmost, the shell posts
   one local notification per page per deadline. It asks for provisional
   authorization, which the system grants without a permission dialog and
   delivers quietly. A page whose clock is restarted or shortened may warn
   again for its new deadline. A page that enters its last hour while the app
   is active is not posted about.

This would replace the three statements quoted in Context for expiry only.
Everything else D-14 forbids stays forbidden: no modal, no badge, no bounce,
no count chip.

## Consequences

- The notification names no page. A title is often the label of a secret, and
  Notification Center is outside the app's own windows, so the person opens
  the pad to see which page it is.
- The time in the line for a page that came due while the app was not running
  is the time of the launch that settled it, because that is the time the
  ledger records.
- The shell's one event timer now also fires when a page crosses into its last
  hour. That fire refreshes and settles nothing.
- The ledger tab, a menu item and a chord are back on a surface that issue #78
  cleared of them.

## Eject triggers

- Dogfood evidence that the last-hour notification is noise: a person turns
  the app's notifications off, or reports the warning as unwanted.
- macOS ends provisional authorization for local notifications, or starts
  showing a dialog for it.

## Decision history

- 2026-11-10: Proposed, with its implementation in the same change. Acceptance
  is the maintainer's; until then the three records quoted in Context stand as
  written. The interaction model and the design principles each have a notice
  pointing here. D-14 has none: its record is superseded and its successor
  reads it from a fixed commit.
