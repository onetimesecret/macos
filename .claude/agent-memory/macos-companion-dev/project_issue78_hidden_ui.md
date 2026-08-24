---
name: issue78-hidden-ui
description: Issue #78 (2026-08-24) hides four UI elements behind HiddenUI flags; the hide is temporary and undecided, so do not delete the code behind it
metadata:
  type: project
---

Four affordances are built and deliberately not drawn, gated by
`HiddenUI` in CompanionKit: the ledger's entry points (its dashed tab,
the cmd-0 default binding, the Settings clear button), the promote
button in the tab strip, the resize glyph in the card's bottom corner,
and the ember dot in the header. Landed on `feature/78-hide-ui`,
2026-08-24, stacked on the keymap work of #76/#77.

**Why:** dogfood triage judged them not worth their space. The user's
framing was explicit that this is a hide and not a delete: some of the
four come back in a different shape, some get removed for good, and
which is which is not decided yet.

**How to apply:**

- Do not "clean up" the code behind a `HiddenUI` flag as dead. It is
  parked, not abandoned; deleting it settles a question the user has
  left open.
- `ledger::Show` stays a legal `CommandID` with a working dispatch arm
  even though the bundled keymap no longer binds it. That is
  deliberate, so a user's own keymap can reach the ledger. See
  [[keymap-76-77]].
- `docs/hardware-verification.md` carries a suspension note at the top:
  its ledger checks and its cmd-0 check cannot be run as written while
  this stands. Lift the note in the same change that restores the entry
  points.
- The hidden elements' model verbs (`toggleLedger`, `clearLedger`,
  `beginPromotion`) still have tests driving them through the model,
  and those tests are the reason the hide stays honest.
