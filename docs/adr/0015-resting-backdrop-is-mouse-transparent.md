# ADR-0015: The resting backdrop is mouse transparent, wholly or not at all

- **Status:** accepted
- **Date:** 2026-08-08

## Context

`NSWindow.ignoresMouseEvents` is one boolean for the whole window,
resolved at the window server. A window cannot be transparent over the
empty pane and opaque over the card. The only other lever is window
extent, and shrinking the unpinned rest to the card's rect does not
help: it sits below every application window, so clicks landing on it
would be clicks aimed at a window the user cannot see through.

## Decision

The unpinned resting backdrop sets `ignoresMouseEvents = true` and spans
the pane. Every click over it, including over the card, passes through
to whatever is beneath. On a bare desktop that is the Finder desktop, so
icons deselect and "Click wallpaper to reveal desktop" fires if enabled.

Raising is never a click on the resting card. The summon routes are
⌃⌥Space, the menu bar item, and ⌘Tab or the Dock icon.

The pinned rest is the exception: it floats above other windows, so it
takes the mouse and shrinks to the card's rect. A click there means
raise. Clicks outside the rect route normally.

The rule lives in `BackdropStance.ignoresMouse(pinned:)` and
`spansPane(pinned:)`, both unit tested.

## Consequences

No hit testing, shaped region, or event tap is needed, and the resting
surface can never steal a click.

There is no click-to-raise, so the summon gesture is discoverable only
through the menu bar item and the hotkey. Any resting-state affordance
(copy button, close button, drag handle) is foreclosed; those require
the raised stance.

## Eject triggers

- AppKit or the window server gains per region mouse transparency or a
  supported shaped input region on a borderless window.
- Users are observed clicking the resting card and getting a desktop
  reveal instead.
- macOS makes a pass-through desktop click destructive rather than inert.

## See also

`docs/spec/feature/background-surface/README.md`, stance table.
