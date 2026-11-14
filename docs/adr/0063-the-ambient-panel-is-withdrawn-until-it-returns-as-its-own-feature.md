---
documentation_status: needs-review
---

# ADR-0063: The ambient panel is withdrawn until it returns as its own feature

- **Status:** accepted
- **Date:** 2026-11-11
- **Supersedes in part:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), only the default-on panel preference; [ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md), only the keep above preference's Settings row; [ADR-0036](0036-editing-presentations-are-mutually-exclusive.md), only the disabled ambient command and the default-on preference; [ADR-0062](0062-opt-in-side-tab-summons-the-ambient-panel.md), only the side tab's General Settings controls
- **Depends on:** [ADR-0059](0059-appkit-owns-window-presentation.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0033 states: "The ambient panel is a persistent preference, default on."
ADR-0036 states: "The ambient command is disabled when the feature is
disabled." ADR-0032 adds the keep above preference to Settings, and ADR-0062
states: "General Settings selects a display, left or right edge, and vertical
position."

On 2026-10-31, in a Codex session outside the repository, the maintainer
observed that Cmd-Tab worked with the panel turned off, and wrote: "Maybe a
prudent step at this point is to simplify by leaving ambient off for now and
refocus on it later as its own distinct feature with a proper full treatment."
Work on the primary editor continued with the panel deferred, but the shipped
default stayed on, and Settings still offered the panel, its side tab, and the
card's keep above and reset controls.

On 2026-11-11 the maintainer asked for the panel to default off and for its
setting to be hidden, writing: "The feature is not polished enough and is more
confusing than helpful." [MR !349](https://gitlab.com/onetimesecret/applications/macos/-/merge_requests/349)
records both requests.

## Decision

Withdraw the ambient panel from the shipped application. It is off for every
install, and no Settings row or menu item names it.

- The panel is off whatever preference a person stored under ADR-0033. The
  stored value is left in place, neither read nor rewritten.
- General Settings omits the whole Surface section: the panel toggle, the side
  tab controls, the keep above toggle and the card's reset. Each of those rows
  concerns the ambient card. The login caption names the application instead
  of the surface.
- The Window, status item and Dock menus omit Show Ambient Panel while the panel
  is off, rather than showing it dimmed.
- The hotkey and the status item select the editor window, which is ADR-0033's
  existing routing with the panel off.
- The panel's code, its routing and its tests stay in the tree behind one
  model switch, `offersAmbientPanel`, which ships false. Tests construct the
  model with it true to keep the withdrawn behaviour exercised.

## Consequences

The shipped application has one presentation, the primary editor window, and
Settings no longer offers controls for a surface the person cannot see. The
Cmd-Tab behaviour the maintainer observed with the panel off becomes the
behaviour every install gets.

A launch at login no longer shows anything: ADR-0059's background launch
"starts the configured ambient presentation", and that presentation is now
nothing, so the app waits in the Dock and the menu bar until the person opens
it.

A person who relied on the panel loses it with no way to turn it back on in the
application. Their stored choice survives, so a later return of the feature can
honour it or deliberately ignore it.

The panel code remains a maintenance cost while it is not shipped: changes to
shared presentation and ownership code still have to keep the panel's tests
passing. That is the price of keeping the feature revivable without rebuilding
it.

Returning the panel needs its own decision about its purpose, its interaction
design and its default. Setting `offersAmbientPanel` to true alone restores
ADR-0033's default-on preference, which this record does not endorse.

## Eject triggers

- The maintainer starts the ambient panel as its own feature: record its
  interaction design and default in a successor ADR before offering it again.
- Keeping the withdrawn panel's code and tests passing blocks a change to the
  primary editor: remove the panel code instead of working around it.
- Users of an earlier build report losing the panel as a regression they need:
  reconsider offering it as an explicitly experimental opt-in.

## Decision history

- 2026-11-11: Accepted from the maintainer's request to default the panel off
  and hide its setting.
