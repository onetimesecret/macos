---
documentation_status: needs-review
---

# ADR-0036: Editing presentations are mutually exclusive

- **Status:** accepted
- **Date:** 2026-10-01
- **Supersedes in part:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), specifically simultaneous visibility, the non-owner glance, and switching consequences that keep both content windows open.
- **Depends on:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md) for the distinct window roles, ownership boundary and activation routes.

## Context

ADR-0033 permits an editor window and ambient panel to remain visible together,
with the non-owner showing a glance. The maintainer's use of that arrangement
found the additional window and resting desktop representation confusing: each
appeared to be another place to edit the same content. The requested interaction
is one visible editing presentation with explicit commands to switch its form.

This changes visibility and switching, while retaining an ordinary activating
editor window and a separate nonactivating ambient panel over one shared model.
The decision is recorded alongside its implementation in
[PR #227](https://github.com/onetimesecret/macos/pull/227).

## Decision

Show at most one content presentation at a time: the primary editor window or
the ambient panel, including the panel's resting desktop and pinned forms.
Settings, About and modal dialogs are companion windows, not content
presentations, and may coexist with the selected presentation.

- Opening the primary editor window hides the entire ambient panel. Pin and
  ambient preference changes must not reveal it while the editor window is open.
- Every raise of the enabled ambient panel closes an open primary editor window
  before the raise grants panel ownership and publishes the raised stance.
  Resting the panel afterward does not reopen the editor window.
- A non-owner content window shows no glance. Existing exclusive ownership and
  the single mounted editor boundary remain in force.
- Dock activation, reopen and Command-Tab select the primary editor window.
  The global hotkey and status item retain the ambient route when enabled;
  when disabled they select the primary editor window.
- Provide explicit Open in Window and Show Ambient Panel commands in the Window
  menu and the Dock and status item context menus. The panel header also offers
  Open in Window. The ambient command is disabled when the feature is disabled.
- The ambient feature remains a persistent preference, default on. Enabling it
  makes the panel available; it does not display a second presentation beside
  an open primary editor window.

This supersedes ADR-0033's non-owner glance, summon with an open editor window,
rest returning ownership to that still-open window, and pinned card floating
above that window. Its other decisions remain unchanged.

## Consequences

- Switching chooses a presentation explicitly, and the former presentation
  disappears. A resting or pinned panel no longer remains behind the editor.
- Closing the primary editor reveals the ambient panel when enabled. Closing
  or resting a presentation does not quit the application.
- Returning from the panel recreates the primary editor window. Caret,
  selection and scroll handoffs must continue through the shared model.
- The simultaneous glance is no longer available. Companion windows continue
  to use the existing ownership and focus rules.

The manual checks live in
[One visible editing presentation](../qa/verification-procedures/spaces-and-cmd-tab.md#one-visible-editing-presentation).

## Eject triggers

- Maintainer testing identifies a recurring workflow that requires viewing the
  panel and primary editor together; reconsider simultaneous visibility before
  adding a second visible content presentation.
- Repeated switches lose the caret, selection or scroll position despite fixes
  to the shared handoff; reconsider closing and recreating the editor window.

## Decision history

- 2026-10-01: Recorded the maintainer's accepted presentation switch for PR #227;
  supersedes the named visibility and switching clauses of ADR-0033.
