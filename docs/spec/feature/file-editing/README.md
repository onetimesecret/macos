# File-backed document layout exploration

Status: **concept only** · 2026-09-04

These mockups explore file-backed plain-text and Markdown documents as a separate content class from expiring Pad pages. They do not establish product behavior or an implementation decision.

## Horizontal tabs

![Horizontal file and Pad tabs](mockups/horizontal-file-tabs.svg)

- Open files and Pad pages share the bottom navigation surface but remain visibly grouped.
- A file tab uses its filename and document icon. It has no TTL gauge.
- Pad tabs keep their existing names, gauges, `+` action, and nine-page cap.
- The active file's identity and save state appear in the header.

## Vertical time tabs

![Vertical file shelf and time rail](mockups/vertical-file-shelf.svg)

- Open files occupy a fixed **Files** section above the temporal **Pad** section.
- Files are not assigned to days and never enter the continuous time roll.
- Selecting a file would replace the roll with that file alone; selecting a day would return to the roll.
- With no files open, the existing time-rail layout can remain unchanged.

## Marker vocabulary

- A small orange dot on a file row means that file has unsaved changes.
- A file row never shows a countdown gauge.
- Pad rows and tabs retain their existing countdown gauges.
