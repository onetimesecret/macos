---
documentation_status: draft
---

# Multiple pads: folder-scoped contexts

> Historical design exploration, 2026-09-18. This proposal is retained for
> comparison; the [2026-10-01 one-pad-picker decision record](one-pad-picker-design.md)
> describes the later mockup. Its one-folder model and shortcut recommendation
> are not the current mockup direction. Neither exploration is an accepted
> architecture decision. The SVGs are wireframes, not implementation specifications.

The timeline sidebar intentionally approximates the real implementation;
its behaviour is outside the focus of this exploration.

## Recommendation

Treat a **pad** as a durable, optionally folder-bound context that scopes the
existing expiring-page timeline and Files shelf. Keep one active pad in a
window. Put its identity in a switcher at the top of the sidebar, where it is
always visible but consumes only one row.

Keep the persistent Timeline above the variable Files list. Opening more files
should extend the list below the timeline rather than push the timeline down.
This layout reflects the user’s requested ordering for these proposed mockups.

The resulting hierarchy is deliberately shallow:

```text
OnetimePad window
└── active pad (for example, “major-loon”)
    ├── timeline (the existing projection of live expiring pages)
    └── files (plain files; their artifacts remain on disk)
```

A pad can be:

- **Personal**, with no folder binding, for the present general-purpose pad;
- **folder-bound**, created with **New Pad from Folder…** and named initially
  from that folder; or
- renamed by the user without changing its folder binding.

For git worktrees, the folder is the durable identity. A live branch name can
be shown as secondary context, but it must not identify the pad: branches can
be renamed, switched, or detached. Pad metadata belongs to the app, not in a
hidden file committed to or copied with the worktree.

## Why this shape

Apple defines a sidebar as navigation between “areas of your app or top-level
collections of content.” It also recommends no more than two hierarchy levels
in a sidebar and a split view when the hierarchy is deeper. A permanent
Pads → Files/Days → Entries tree would either exceed that depth or compress the
time rail that is already doing useful work. A one-row context switcher keeps
the visible hierarchy at Timeline + Files.

Apple also recommends persistently highlighting the selection in every split
view pane that leads to the detail. The proposed header does that for the pad;
the existing highlighted file or time block does it for the content.

The interaction follows the useful part of Panic Nova’s model: a local project
is based on a folder, its documents are scoped to its workspace, and additional
projects can use windows or window tabs. OnetimePad does not need Nova’s full
launcher. A compact searchable switcher is proportional to a utility app, with
**Open Pad in New Window** available later as an explicit multitasking option.

## Relevant macOS precedents

| Precedent | Pattern | Lesson for OnetimePad |
| --- | --- | --- |
| Apple Notes | Accounts and folders remain visible in a resizable, hideable sidebar; the selected collection drives the note list and detail. | A sidebar is the right place for durable collections, but copying Notes' permanent extra list would be heavy for a compact writing surface. |
| Xcode | A workspace is the window-level context; its navigator is scoped to the projects and files inside it. | Keep the active work context above files, not beside individual documents. |
| Panic Nova | A local project is tied to a folder and opens in a workspace; users choose whether additional projects use windows or tabs. | Folder binding maps directly to worktrees. Preserve context by default and make another window an option. |
| Finder | Sidebar selections are durable places; content changes in the detail area while the selected place stays highlighted. | The pad name should remain persistently selected and visually separate from volatile page content. |

Sources:

- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple HIG: Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Apple HIG: Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Nova: Quick Tour](https://help.nova.app/welcome/quick-tour/)
- [Nova: Workspace settings](https://help.nova.app/settings/workspace/)

## Relationship to current project decisions

Accepted ADR-0017 says: “Split the object into a durable **Tab** and an
optional, expiring **Page**.” It also says that when a page expires, “it is
dropped whole and its Tab remains empty and reusable.” A pad context should
therefore group tabs without becoming another content lifetime.

ADR-0028 is **proposed**, not accepted. Within its stated file-editing scope it
says: “File backed documents are an additional content class, a peer to pages,”
and “no mechanism in the pad ever destroys or expires its contents.” This
proposal preserves that boundary: a pad associates a file bookmark with a
context; it does not take ownership of the file or make the file expire.

The vertical-time-tabs feature is also a draft prototype. It describes the day
as a query over live pages rather than a durable object. This proposal scopes
that query to the active pad; it does not persist days.

## Interaction contract proposed for dogfood

1. The existing installation starts with one unbound pad named **Personal**.
2. **New Pad from Folder…** creates a folder-bound pad through the standard open
   panel. It does not create or modify a file in that folder.
3. Switching pads restores that pad’s last selected file or live page, editor
   scroll position, and timeline position.
4. Files opened from a folder-bound pad appear in that pad’s Files section.
   A file remains a normal disk file and retains the existing explicit-save
   behavior.
5. When a file opened externally falls under exactly one known pad root, route
   it to that pad. With nested roots, the most-specific root wins. Otherwise,
   open it in the active pad.
6. Keep `Command-1` through `Command-9` for the existing first-nine-tab
   shortcuts. Expose **Switch Pad…** as a command whose key binding can be
   chosen through the project keymap rather than assigning a conflicting chord
   in the design.
7. Sidebar header menu: Rename Pad, Reveal Root in Finder, Open Pad in New
   Window, and Remove Pad. Removal is disabled while a dirty file needs a
   decision. Removing a pad never deletes its folder or plain files; the fate
   of live pages needs an explicit product decision before this ships.
8. In narrow windows, collapse the sidebar but keep the active pad name in the
   title/toolbar. Use the standard View menu and toolbar affordance to restore
   the sidebar.

## What not to do

- Do not put pad tabs beside file/page tabs. Two meanings of “tab” in one strip
  have weak information scent and make keyboard behavior ambiguous.
- Do not show every pad’s full time rail simultaneously. It spends width and
  attention on inactive contexts.
- Do not create `what.txt`, `.onetimepad`, or another worktree file
  automatically. Creating a folder-bound pad is an organizational action, not
  permission to modify that checkout.
- Do not make one window per pad the default. Apple recommends new windows when
  they preserve context, but warns that excessive windows create clutter.
  Offer a new window explicitly for side-by-side work.
- Do not key pad identity to a branch name or repository remote.

## Wireframes

- [`01-active-pad.svg`](01-active-pad.svg) — recommended wide-window hierarchy
- [`02-switch-pad.svg`](02-switch-pad.svg) — searchable, anchored pad switcher
- [`03-compact-window.svg`](03-compact-window.svg) — sidebar hidden at a narrow
  width while pad identity remains visible
