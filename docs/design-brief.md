# Design brief — the menu-bar companion panel

A distillation for a designer picking up the panel. It says what is
**architecturally fixed** (breaching it isn't a design choice — it's a bug
or a leak) versus what is **genuinely open** (where design judgment is
wanted). A designer arriving from web/app work will breach the fixed set
by instinct, so that line is drawn first and explicitly.

Canonical sources, in order of authority: `docs/spec/03` (design
principles), `docs/spec/04` (interaction model), `docs/spec/05` (technical
direction + accessibility), `docs/spec/06` (open questions). This file
distills them; where they disagree, the specs win.

## What this is

A macOS menu-bar resident that parks a secret-shaped snippet in a cell
that **drains over a chosen TTL and deletes itself**. It is furniture:
present in peripheral vision, never centre stage. A cell is a *handle for
content in motion*, not a display of the content. The whole product is a
quiet loop: place, glance, copy back out or conceal into a link, forget.

## Fixed — not up for design (with the reason, so it isn't arbitrary)

- **No plaintext, ever, in the UI.** Secret bytes live only in the Rust
  core; the UI layer never receives them. There can be **no "reveal
  secret" / eye toggle / show-plaintext / copy-to-see-it** affordance —
  the bytes literally aren't available to draw. A cell's vocabulary is
  fixed: kind glyph, a **masked** recognition line (`••••`,
  middle-truncated), time remaining, size/count, a copy button.
  (`docs/spec/05`, the boundary law.)
- **Content plays second fiddle.** Recognition, not consumption. No rich
  previews, no syntax highlighting, no markdown render, no image zoom, no
  in-place editing. **Hover reveals actions, not content** — the panel is
  a shoulder-surfing surface. (`docs/spec/03 §3`.)
- **The panel never steals focus.** It is a non-activating edge shelf. No
  modals, no interrupting dialogs, no auto-focused text fields that grab
  the keyboard. Every interaction must complete without the panel becoming
  the key window; the user's real work stays frontmost. (`§2`,
  `docs/spec/04`.) This is an accessibility rule, not etiquette — an
  unexpected focus change is destructive for assistive-technology users.
- **Excluded from screen capture.** The live panel is invisible to
  screenshots and screen recordings (secret hygiene). Practical
  consequence: you **cannot screenshot the shipping panel** in ordinary
  use, so portfolio, marketing, and QA visuals must be mockups. (A debug
  build always offers a Settings switch that lifts the exclusion until
  quit. A release build offers the same switch only when launched with
  `COMPANION_ALLOW_CAPTURE` set, which is how the installed app is
  diagnosed; an ordinary launch has no way to reach it, and the opt-out
  is never persisted. While it is on, the surface flies a camera
  indicator in its header.)
- **Accessibility is the acceptance bar, not a polish pass.** Every visual
  signal needs a text equivalent — the draining countdown ring **must**
  speak its remaining life in words ("about 7 hours remaining"); colour
  can never be the sole carrier of state. The design must survive **Reduce
  Motion** (animation is never the only signal), **Increase Contrast /
  Reduce Transparency** (surfaces degrade to solid system fills), **Dynamic
  Type**, and both **light and dark** appearance. This is the reason the
  spike exists (`docs/spec/05` a11y).
- **No notifications, badges, bounce, or count chips.** The cell appearing
  *is* the confirmation of a successful drop. Empty state is one calm
  sentence, not an illustration campaign. (`§1`, `§2`, Tone.)
- **Menu-bar resident, no Dock icon.** A fixed-size, edge-docked panel
  (~320×480, docked top-right) and a resident tray glyph — not a resizable
  application window.
- **Native + frugal.** No Electron/webviews, single-digit-MB download, tens
  of MB resident. This rules out heavy illustration or asset campaigns.
  (`§4`.)
- **Concealing is the app's explicit network action, and it is
  deliberately understated**: "discoverable on every cell, prominent on
  none." The conceal-to-link CTA must never read as a hero button, and
  never fire as a side effect. (`§6`.)

## Anti-goals — do not design these

Retention or organisation features: no trash can, no archive, no
"recently expired" bin, no history view, no folders/tags. No account
required to use the core loop. No automatic clipboard capture (deliberate
placement is the privacy model). No onboarding illustration flow. These
are load-bearing exclusions, not omissions. (`docs/spec/01` anti-goals,
`§1`, `§5`.)

## The intended feel

Quiet, precise, slightly warm. The app is furniture — at its best when the
user forgets it exists between uses; attention consumed per transfer is
the metric, minimised. **Never cute about deletion, never guilt-tripping**
("3 items expiring soon!" is explicitly banned). "The app speaks when
spoken to." Existing copy sets the register:

> "No page here yet." · "PRESENT, NOT CENTRAL" · "drop or paste here."

## Tokens and parameters (current values)

Superseded by docs/spec/design/2026-0915-ui-ux-decisions.md; the values
below are history.

- **Accent:** ember `#D45A2A`. The *single* accent colour, used sparingly,
  never as the only carrier of state. (The record's value is `#DC4A22`,
  matching the shipped logo asset, and `Theme.swift` now carries
  `#DC4A22` as well; the value above is the one this brief shipped with.)
- **Surfaces:** drawn from the system palette
  (`windowBackgroundColor` / `controlBackgroundColor`) so Increase Contrast
  and Reduce Transparency degrade them to legible solid fills for free.
- **Type:** monospaced for recognition and status lines; system font for
  prose.
- **TTL ladder:** 1h → 3h → 8h → 24h → 3d → 7d. Default landing rung
  **8h**. Rendered as a draining ring plus a text label (e.g. "8h").
- ~~**Capacity:** 12 cells, **refuse-don't-evict** — cells leave only by
  expiry or explicit discard, never by being pushed out.~~ (No cap since
  issue #158; nothing is evicted but by the countdown.)
- **Cell anatomy (today):** a clickable countdown ring (cycles the TTL) ·
  a caption ("TEXT · 8h · looks like a GitHub token") · the masked
  recognition line · a copy button.
- **Tray glyph:** currently ㊙️ (maruhi, "secret").
- **Panel:** ~320×480, edge-docked top-right, minimal chrome, generous
  whitespace, one accent. (The archived panel form factor, ADR-0014.)

## Where design judgment is wanted (`docs/spec/06` + felt-experience)

These are open, and a designer at the machine is the right person to
settle them:

- **Draining-ring legibility** across the full ladder — does 1h read
  differently from 7d at a glance? Its Reduce-Motion static form.
- ~~**Cap behaviour at 12** — should hitting the ceiling feel like a wall or
  a nudge, and what does "refuse" look like on screen?~~ (Closed: no cap
  since issue #158.)
- **Default landing rung** (8h) — does it feel right as you cycle?
- **Conceal-to-link CTA**: subtle yet discoverable on every cell.
- **Float-on-top affordance** — currently a header pin (`pin.fill` on /
  `pin` off) that toggles whether the panel floats above other apps
  (`.statusBar`) or behaves like a normal window (`.normal`). Right
  metaphor and placement?
- **Tray glyph** and **masking style** (dot count, how much of the
  recognition to reveal).
- Light / dark / high-contrast renderings of all of the above.

---

*This brief tracks the spike. When a value here (TTL ladder, capacity,
accent) diverges from the code, the code and `docs/spec/*` are the source
of truth — update this file to match.*
