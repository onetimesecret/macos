---
documentation_status: needs-review
---

# Feature proposal: pad contexts

Status: experimental proposal, default off. The maintainer requested a native
implementation attempt after reviewing the 2026-10-01
[one-pad-picker design](../../../mockups/multiple-pads/one-pad-picker-design.md).
That design owns the interaction detail and rejected alternatives;
[ADR-0039](../../../adr/0039-pad-selection-and-associations.md) owns the proposed
association model and shortcut decision. Neither establishes release acceptance.

## Experimental contract

Enable **Multiple pads and context associations · experiment** in General
settings to expose a shared picker on both editing surfaces. Existing tabs
start in Scratch. Creating or selecting a pad does not itself mint a page;
deliberate writing/new-page gestures use the existing page lifecycle.

One directory root belongs to one pad; several roots can belong to that pad.
Scratch has no directory bindings. Explicit file-open context uses the longest
component-boundary root match. No directory scan or permission grant follows
from a binding. Application associations use regular running app identities,
select among the active/recent pads when enabled, and yield to explicit file
context and unresolved modal/confirmation operations. Header icons deliberately
activate an associated running app.

The picker contains per-pad binding controls, rename/removal actions, and global
application/full-path options. Removing a named pad rehomes its existing pages
and files to Scratch; it does not delete their content. The closed header uses
a folder tally. Command-0 selects Scratch and
Command-1…9 select named pads in roster order while enabled, preserving explicit
user keymap overrides. Timeline precedes Files; day direction and checkpoint
direction within each date are independent display preferences.

Accepted [ADR-0017](../../../adr/0017-durable-tabs-expiring-pages.md) states:
“When a Page expires, it is dropped whole and its Tab remains empty and reusable.”
This proposal groups those tabs; it introduces no pad lifetime or expiring link.
The existing slot shortcut and newest-first day-policy conflicts are recorded
in the linked design and ADR and require successor acceptance before becoming
release defaults.

## Implementation and evidence

[Native implementation notes](../../../development/pad-context-experiment.md)
record the actual storage/routing choices, test observations, and limitations.
The catalog is unencrypted local context metadata, separate from note content.
It is not synced. Explicitly supplied paths use symlink resolution and available
filesystem metadata to compare directory aliases, with a documented fallback
when that metadata is unavailable. Folder relocation tracking and project
window recognition are outside this attempt. Clipboard transfers remain the
separate [ADR-0038](../../../adr/0038-explicit-clipboard-operations.md) proposal.

[Native verification](../../../qa/pad-context-experiment.md) lists signed-app,
activation, accessibility, and release checks still owed. Passing unit tests
does not establish those outcomes or a supported macOS release promise.
