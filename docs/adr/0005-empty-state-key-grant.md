---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0005: Empty-state key grant — a click into emptiness is a deliberate act

- **Status:** proposed
- **Date:** 2026-07-14

## Context

The panel honours the focus law (docs/spec/04, "Focus: accept, never
take") through `becomesKeyOnlyIfNeeded = true`: a click grants key
status only when the clicked view answers `needsPanelToBecomeKey`. The
law enumerates exactly two keyboard grants — click into the page, or
summon with ⌥Space.

A pageless window has neither. Its empty state is static `Text`, so no
click can ever make the panel key, and keystrokes fall through to the
app underneath. ⌥Space half-works: `summon()` makes the panel key, but
its `makeFirstResponder(editor)` is nil-guarded and no editor exists,
so typing beeps. The law never considered a window with no page to
click into — a spec gap, not only a code bug (issue #19).

## Decision

A click in the empty content area is itself the deliberate act the
focus law requires: it creates a page and focuses its editor. `summon()`
creates a page when none exists, so ⌥Space always lands on a ready
editor. A fourth grant rides on the other three: while the window
already holds the keys, Enter on the empty state creates a page and
focuses its editor, the muscle memory of starting a new thought. It
spends key status an earlier grant conferred, never takes it, so the
accept-never-take invariant is untouched. Keyed emptiness is therefore
a legal state: closing or expiring the last page while key keeps the
keyboard, the empty state's catcher takes first responder, and Esc
remains the way to hand the keyboard back. The focus law now names
four grants. Type-to-create in an unkeyed window stays out of scope;
it would demand key status the window was never given.

## Consequences

- The empty state stops swallowing keystrokes, and a click that lands
  nowhere no longer leaves the user typing into the app underneath.
- The law's invariant survives intact: key status is still only ever
  *accepted* in response to a deliberate act, never taken. Chrome —
  tabs, header, pin — still never becomes key.
- The fix is timing-sensitive, not a straight-line call: SwiftUI mounts
  the new editor a render pass after `selection` changes, so
  `activeEditor` is nil synchronously and the focus call must defer to
  the next runloop turn. Anyone inlining `makeFirstResponder` at the
  create site reintroduces the beep.
- docs/spec/design/04-interaction-model.md must name the third and fourth
  grants, or spec and behaviour diverge again the moment someone reads
  the law as exhaustive.
- We give up type-to-create only where the window is unkeyed: a
  keystroke into an unkeyed empty window still goes to the app
  underneath, and the click (or ⌥Space) remains the price of entry, by
  design. A keyed empty window honours Enter, so the ember over
  emptiness is honest: a keystroke lands somewhere.

## Eject triggers

- A future affordance needs type-to-create in an unkeyed window (key
  status before any deliberate act), collapsing the premise this
  decision rests on.
- The empty state gains a real content control that focuses itself,
  beyond the key-grant catcher, making the synthetic create-on-click
  redundant.
- A macOS release changes `becomesKeyOnlyIfNeeded` semantics such that
  static views can accept key, observed as the empty state going key
  without the new grant path.
