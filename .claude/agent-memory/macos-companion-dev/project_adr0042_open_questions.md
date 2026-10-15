---
name: adr0042-open-questions
description: ADR-0042 (epic 252, #240) was accepted 2026-10-13 with four open questions; their answers and every shell detail #244/#246 settled live in ADR-0044, and ADR-0042 reads as accepted again
metadata:
  type: project
---

ADR-0042 (`docs/adr/0042-sealed-names-copy-zones-and-rename-seats.md`) records #240's eight answers and makes the mockup authoritative only for the surface details point 8 lists. It was accepted with four Open questions. Commit bdc23e2 moved them into its Decision and later commits wrote #244/#246 choices into its history; a review (F6) found that breaks docs/adr/README.md ("Do not silently update an accepted ADR in place"). On 2026-10-13 the Open questions were restored verbatim and everything settled moved to ADR-0044 (`docs/adr/0044-sealed-row-and-note-details.md`): the four answers (`copied the name.`, one second beat, `NotePopoverLayout.minimumWidth` = 320, `NOTE` header), the light fills, fades, zone band, truncation order, hover before click, the in-window popover, a named non-text object's `=` being no zone, and no drop from elsewhere into the note or name field.

**Why:** the lint passes either way, so nothing machine-checks that an accepted ADR's Context, Decision, Consequences and Eject triggers stay as accepted.

**How to apply:** a new sealed-surface decision goes into ADR-0044's successor or a new ADR, never into ADR-0042 or ADR-0044's sections after acceptance; a history bullet is a dated pointer only. Cite ADR-0044 (not "ADR-0042's history") in comments and law rows. Related: [[issue244-246-sealed-shell]], [[issue241-243-sealed-name-note-core]].
