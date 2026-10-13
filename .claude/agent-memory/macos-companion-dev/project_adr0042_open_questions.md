---
name: adr0042-open-questions
description: ADR-0042 (epic 252, #240) was accepted 2026-10-13 with four open questions; the same day they were settled by adopting their recommendations, and only the popover minimum's value is still #246's to set
metadata:
  type: project
---

ADR-0042 (`docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md`) records #240's eight answers and makes the mockup authoritative only for the surface details it lists. Four details had no value in the mockup. On 2026-10-13 (commit bdc23e2) they moved out of Open questions into a list after point 8's menu, marked as decided in the record rather than drawn from the mockup: the line after *Copy name* is `copied the name.` with no clear armed; the ember beat lasts one second, without a fade under Reduce Motion; the popover's minimum width is one named shell constant; an unnamed object's note header is `NOTE`.

**Why:** #240 point 8 claimed the line after Copy name was in the mockup; it is not, and AGENTS.md forbids presenting an unsourced detail as decided, so the record says these four are its own decisions.

**How to apply:** #244 (zones, menu, line) and #246 (popover) build to that list. #246 must still pick the minimum width's value, name the constant, and add a dated decision history entry to ADR-0042 saying what it is. D-42's line governs the decrypted copies; the mockup's middle dot rendering of it is not the source. Related: [[issue241-243-sealed-name-note-core]].
