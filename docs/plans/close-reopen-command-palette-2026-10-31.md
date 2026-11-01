# Close, reopen and command palette

## Confirmed scope

The maintainer confirmed on 2026-10-31: “Yes—close hides it; reopen restores it”.
This applies to Timeline and Tabs. Close Window stays separate. No change to
expiry policy was decided. Source: side conversation
`01a1942c-9584-7c91-9500-84b09f73a49a`, relayed with explicit user authorization.

The requested palette uses Command-Shift-P through JSON. Application commands
precede current page/tab and selection commands. Requested examples are Open
Timeline, Switch to Tabs View and Re-open Dated Tabs.

## Existing authority and implementation proposal

[ADR-0017](../adr/0017-durable-tabs-expiring-pages.md) states: “Expiry, restore,
refresh, and merely displaying an empty Tab mint nothing.” Keep that rule.
The confirmed direction changes the prior UI close/removal behavior only; other
lifetime decisions are outside this work. This plan does not establish new
persistence, compatibility or retention guarantees.

1. Keep the full core/model tab roster for saving, expiry and pad ownership.
   Record hidden UUID order in local presentation metadata. Filter navigation
   and continuous projections, including inactive pads. Save edits before hiding;
   a save refusal keeps the page visible.
2. Reopen the existing saved item, preserving its identity. The picker uses the
   active pad and newest-close order. Reopening an expired slot does not mint a
   page; show that slot in Tabs with an expiry notice.
3. Add explicit palette/layout/reopen IDs to the existing command registry. Bind
   Command-Shift-P in default-keymap.json and resolve displayed shortcuts from
   the merged keymap, including overrides and unbinding.
4. Use a native searchable overlay in the current window. Arrow keys navigate,
   Return runs, Escape restores focus. Re-open Dated Tabs opens a searchable
   list of closed saved items. Preserve selection/context before search takes
   focus and restore the responder before shared editor dispatch. Refuse stale
   editor targets. Settle valid variable-name edits before opening.

[Zed's palette](https://zed.dev/docs/command-palette) and
[key-binding documentation](https://zed.dev/docs/key-bindings) are interaction
references, not authority for OnetimePad storage behavior.

## Verification plan

Use temporary state and ephemeral in-memory credentials. Cover both layouts,
close-all saving, restart, same-item reopen, expiry, active-pad scope, no Discarded
event from Close, JSON remap/unbind, command scope/search, keyboard navigation,
selection/focus restoration and stale-target refusal. Swift runs only through
scripts/test-shell.sh. No person's app is launched, quit, replaced or reset.

Implementation and test results will be recorded after verification.


## Implemented and verified

Implemented local UUID-based close/reopen, full-roster saving and expiry,
active-pad closed-item selection, hidden-slot reorder translation, registry
commands, JSON shortcuts and a native searchable palette. Close Window uses
its existing separate route. Current variable-name edits are settled before
palette opening; shared field editors return to their originating controls.
Captured editor actions are refused after storage edits or target changes.

The full isolated Swift run passed 401 app tests and 2,325 CompanionKit tests,
with seven existing skips and no failures. After final palette row-layout
changes, the focused run passed nine app tests and 18 CompanionKit tests;
the last native inset/resize correction passed all nine controller tests.
All runs used scripts/test-shell.sh with test-util core and isolated seams.
ADR lint passed 54 records, English string syntax and diff checks passed.
Four synthetic wide/narrow command and closed-item renders were generated and
inspected. No Rust source, content snapshot format or expiry policy changed.

Manual VoiceOver navigation and physical-display/keyboard inspection remain
unperformed. This work does not install or replace the person's application.
