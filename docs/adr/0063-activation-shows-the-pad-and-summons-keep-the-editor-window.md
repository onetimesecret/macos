---
documentation_status: needs-review
---

# ADR-0063: Activation shows the pad, and summons keep the editor window

- **Status:** accepted
- **Date:** 2026-11-11
- **Supersedes in part:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), only the reach of its panel-off rule for the hotkey and the status item, which now also applies while the editor window is open with the panel on; [ADR-0036](0036-editing-presentations-are-mutually-exclusive.md), only the hotkey and status-item summons closing an open primary editor window, their ambient route while that window is open, and their anchor on today in that case; and [ADR-0059](0059-appkit-owns-window-presentation.md), only its rule that ordinary activation creates no editor, its Cmd-Tab return to a minimized editor, and the consequence that a return may show no editor. Their remaining decisions stand.
- **Depends on:** [ADR-0036](0036-editing-presentations-are-mutually-exclusive.md) for one visible content presentation and the explicit switch commands, and [ADR-0059](0059-appkit-owns-window-presentation.md) for AppKit ownership of window presentation and the reopen rule.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0059 states: "Ordinary activation creates no editor and does not change the selected presentation or anchor." Its Consequences add: "Returning to an application with all ordinary windows closed may show no editor." The editor window is released when it closes, and a resting card takes no keys, so Cmd-Tab to the application with the editor closed left the person in an active application with nothing to type into.

ADR-0036 states: "Deliberate selection of the enabled ambient panel closes an open primary editor window before granting panel ownership and publishing the raised stance. This includes hotkey, status-item and card-click summons and the explicit Show Ambient Panel command." With the default settings the global hotkey therefore closed an editor window the person had opened, sized and placed, and replaced it with the panel. With the panel off, a second press of the hotkey over the editor did nothing.

The hotkey and the status item do not name a presentation. Show Ambient Panel and Open in Window do.

## Decision

Every route to the application shows a place to write, and the hotkey and the status item act on the presentation that is current.

- When the application becomes active with no pending explicit command, no companion window request, no modal session, no visible ordinary window and no raised card, the editor window opens or leaves the Dock, as an activation: the selected page, the roll position and the anchor are unchanged. A visible ordinary window, companion windows included, or a raised card leaves focus and ordering to AppKit as before.
- With the editor window open, minimized included, the hotkey and a left click on the status item select it: the application activates and the window leaves the Dock, comes forward and takes the keyboard. They never close it for the panel and do not anchor on today.
- With the editor window key in an active application, the same hotkey or click hides the application.
- With the editor window closed, the hotkey and the status item summon the ambient panel when it is enabled and open the editor window when it is disabled.
- Show Ambient Panel and Open in Window are the only commands that switch presentation. A click on the resting card and a click on the side tab keep their existing routes.
- A summon that anchors on today leaves the selection on a showing file tab.

## Consequences

Cmd-Tab to an application whose only ordinary window is a minimized editor takes that window out of the Dock, which AppKit by itself does not do.

A nondefault launch that activates the application with nothing showing now opens the editor as an activation, without the launch anchor.

The hotkey is a show and hide toggle for whichever presentation is current. Reaching the panel from an open editor window takes the Show Ambient Panel command; the hotkey no longer does it.

Hiding the application hides Settings, About and Send Feedback with the editor window. The next activation shows them again.

The activation rule reads window visibility at the time AppKit reports the application active. Whether a hidden application's windows already read as visible at that time is unverified on hardware; the checks are in [Spaces, ⌘Tab and the pad](../qa/verification-procedures/spaces-and-cmd-tab.md).

## Eject triggers

- Maintainer use finds the editor opening on activations that should show nothing, such as a login launch that activates the application; reconsider the activation rule.
- Hiding on the second press loses a companion window's place or returns the keyboard to the wrong application; reconsider hiding in favour of closing or minimizing the editor window.
- A recurring workflow needs the hotkey to reach the panel while the editor window is open; reconsider a separate chord before restoring the switch.

## Decision history

- 2026-11-10: Recorded alongside its implementation. Supersedes the named clauses of ADR-0033, ADR-0036 and ADR-0059.
- 2026-11-10: Implemented in PR #351.
- 2026-11-11: Accepted by the maintainer.
