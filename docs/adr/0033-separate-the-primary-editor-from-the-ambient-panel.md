---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0033: Separate the primary editor from the ambient panel

- **Status:** proposed
- **Date:** 2026-09-17

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

OnetimePad currently asks one window to serve three different roles: desktop
furniture while resting, a floating nonactivating panel when summoned, and the
application's primary editor once it has the keyboard. Those roles want
different macOS window semantics.

A nonactivating `NSPanel` is the conventional foundation for a palette, HUD,
Spotlight-like surface, or drop-down terminal. It can be summoned without
activating its application, temporarily take input, float above other work, and
recede when dismissed. A primary editor conventionally does the opposite: its
window activates the application, becomes key and main, participates in normal
application ordering and window cycling, stays at normal level when another
application activates, and delegates Mission Control, Stage Manager, full
screen, and focus restoration to AppKit.

`NSPanel` is itself an `NSWindow` subclass. Replacing the class name alone would
therefore decide nothing. The tension comes from the surrounding policy:
nonactivating style, refusal to become main, floating level, all-Spaces
membership, and custom raise and rest transitions. As the panel is made to
imitate a primary application window, each ordinary behavior has to be
reconstructed as another transition in that policy. Fixing one symptom leaves
the same question at Settings, open panels, window cycling, Spaces, Stage
Manager, and focus restoration.

[ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md) records
a narrower response to one such symptom: a raised but keyless surface uses
normal app stacking by default while the nonactivating-panel architecture
remains intact. This proposal asks the broader question that ADR-0032 leaves
open: which window role should be the foundation of the primary editor?

Three architectures are available:

1. Keep one nonactivating panel and embrace an ambient utility interaction,
   without promising ordinary editor conventions.
2. Replace the ambient posture with one conventional activating editor window.
3. Give the conventional editor and the ambient utility separate windows over
   one in-process document model.

The third option preserves both product ideas without requiring one window to
hold contradictory identities. It also reopens part of the reasoning in
[ADR-0010](0010-form-factors-as-sibling-targets.md), whose first amendment
rejects one app with two windows for the former panel and backdrop form factors.
If this proposal is accepted, its precise supersession relationship with that
amendment, with ADR-0032, and with
[ADR-0019](0019-the-pad-is-on-every-space.md)'s all-Spaces rule must be recorded
in both directions rather than inferred.

## Decision

Make an ordinary activating `NSWindow` the primary editing surface. It uses
normal window level, may become both key and main, and follows the standard
macOS application ordering, switching, cycling, full-screen, and restoration
model.

Keep ambient behavior, if the product retains it, in a separate nonactivating
`NSPanel` that projects the same in-process document model. The ambient panel is
not the primary application window and owns no independent document or
persistence lifecycle. Do not continue expanding one nonactivating panel to act
as both the ambient surface and the conventional primary editor.

This decision concerns window roles and activation semantics. It does not
choose the conventional window's visual chrome, the ambient panel's final
interaction affordances, or whether the ambient panel is enabled by default.

## Consequences

- Command-Tab, application activation, key/main status, ordinary window
  ordering, the Window menu, Mission Control, Stage Manager, and full screen can
  follow AppKit's primary-window conventions instead of a growing custom state
  machine.
- The nonstandard behavior is isolated to the surface whose purpose requires
  it. The ambient panel may still use special levels, Space membership, mouse
  transparency, and nonactivating focus without making those policies the
  editor's foundation.
- The document model and persistence lifecycle remain singular inside one
  process. The two windows are presentations of the same state, not sibling
  applications with stores that can diverge.
- A hotkey that summons the ambient panel and a Command-Tab that selects the
  application become distinct gestures with distinct, explainable outcomes.
- The application must coordinate two windows: visibility, selection, first
  responder, commands, restoration, and transitions between the ambient and
  conventional presentations need explicit ownership.
- Supporting two surfaces costs more UI plumbing than choosing either an
  ambient-only utility or a conventional-only editor. That cost is accepted to
  avoid embedding both interaction models in one window.
- Existing tests and hardware procedures that assume every raised editor is the
  all-Spaces panel must be divided between primary-window behavior and
  ambient-panel behavior.
- Acceptance would require explicit follow-up amendments or successor
  relationships for earlier decisions that assign one posture, Space policy,
  or process boundary to the whole application.

## Open questions

- Is the ambient panel read-only until it hands off to the primary editor, or
  may it still accept temporary editing without activating the application?
- Does launch show the conventional editor, the ambient panel, or whichever
  presentation the person last used?
- Which commands operate on the shared model when both windows are visible, and
  which window owns first-responder-dependent commands?
- Is the ambient panel a persistent preference, a transient presentation mode,
  or an optional feature that can be removed independently?
- Exactly which clauses of ADR-0010 Amendment 1, ADR-0019, and ADR-0032 would
  this decision supersede if accepted?

## Eject triggers

- Dogfood evidence shows that the ambient surface is not used once a
  conventional editor exists; remove the second surface and retain only the
  primary window.
- Dogfood evidence shows that the conventional editor is not used and that the
  product is understood and preferred as an ambient utility; reject or
  supersede this decision in favour of the single-panel architecture.
- Coordinating two live presentations produces recurring document-selection,
  command-routing, or first-responder defects that cannot be removed behind one
  explicit ownership model; reconsider whether both presentations should be
  simultaneously live.
- A future AppKit API supplies one supported window role that can change between
  conventional primary-window and nonactivating ambient semantics without
  recreating either behavior manually; reassess the two-window boundary.

## Decision history

- 2026-09-17: Proposed.
