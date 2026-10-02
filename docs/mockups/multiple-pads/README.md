---
documentation_status: needs-review
---

# Multiple pads mockups

The current exploration is the **one pad picker**, reviewed with the user on
2026-10-01. It is a working browser prototype of the proposed interactions,
not evidence that the native application implements them.

- [Design and decision record](one-pad-picker-design.md): the agreed mockup,
  implemented interactions, rejected approaches, and remaining native decisions.
- [Standalone mockup](one-pad-picker.html): open in a browser or serve this
  directory with `python3 -m http.server 8765`, then visit
  `http://localhost:8765/one-pad-picker.html`.
- [Editable visualization fragment](one-pad-picker.fragment.html): authored
  content used by the visualization host, without the standalone wrapper.
- [Published version](https://onetimepad-one-pad-picker.blush-morel-9019.chatgpt.site/):
  the live prototype at review time. The link may stop working; the checked-in
  HTML is the snapshot for this record.
- [Proposed ADR-0038](../../adr/0038-pad-selection-and-associations.md): pad
  selection and the distinction between folder routing and app hints.
- [Initial folder-scoped exploration](initial-folder-scoped-exploration.md):
  earlier proposal, retained with its reasoning and references.

The standalone file is copied unchanged from the published output. It retains
that output's `sandbox="allow-scripts"` iframe and Content Security Policy.
Opening the standalone file runs third-party scripts: the framed document loads
Floating UI and Lucide from unpkg.com at pinned versions, without Subresource
Integrity attributes, and its policy allows `'unsafe-inline'` and
`'unsafe-eval'`. Without network access the icons and Floating UI tooltips may
not render. The fragment
is easier to read and edit;
regenerate the standalone output through the visualization workflow after a
change instead of stripping its wrapper. The prototype uses sample locations
and content. It does not read the local filesystem or activate another app.

The timeline sidebar intentionally approximates the real implementation.
Its detailed rendering and selection behavior are outside the focus of this
exploration; independent day/checkpoint sorting is the interaction explored
here. Timeline remains above the variable Files list.

## Earlier wireframes

These remain historical comparisons, not the latest picker specification.
On 2026-10-01 each was edited only to place Timeline above Files: the original
elements are wrapped in translated groups, and the one description naming the
order was updated. The
[initial exploration](initial-folder-scoped-exploration.md) records the change.

- [01-active-pad.svg](01-active-pad.svg)
- [02-switch-pad.svg](02-switch-pad.svg)
- [03-compact-window.svg](03-compact-window.svg)
