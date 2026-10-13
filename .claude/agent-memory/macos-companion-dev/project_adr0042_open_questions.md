---
name: adr0042-open-questions
description: ADR-0042 (epic 252, #240) accepted 2026-10-13 with four open questions the mockup could not answer; #244 and #246 must settle them, not invent them silently
metadata:
  type: project
---

ADR-0042 (`docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md`) records #240's eight answers and makes the mockup authoritative only for the surface details it lists. Four details had no value in the mockup and stay open with recommendations: the page's line after *Copy name*, the ember beat's length, the note popover's minimum width (point 7's threshold), and an unnamed object's note header.

**Why:** #240 point 8 claimed the line after Copy name was in the mockup; it is not, and AGENTS.md forbids presenting an unsourced detail as decided. The menu order was also added to ADR-0042 from the mockup, beyond point 8's list, because Law 0001's fixed menu needed one.

**How to apply:** when building #244 (zones, menu, line) or #246 (popover), read ADR-0042's Open questions first and get the recommendation ratified (or record the build's choice in a follow up ADR) rather than picking silently. D-42's line governs the decrypted copies; the mockup's middle dot rendering of it is not the source.
