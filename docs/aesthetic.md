# docs/aesthetic.md

---


I’ll ground this in the project’s governing design documentation, then translate it into a concrete macOS visual and interaction direction.

## Aesthetic direction: quiet desktop furniture

Design OnetimePad as a **native macOS utility that belongs to the desktop**, not as a productivity dashboard, notes app, or security control panel.

The governing design principle says: **“The app is furniture. It occupies peripheral vision … never steals focus, never interrupts.”** (`docs/spec/design/03-design-principles.md`)

### Visual character

- **Native AppKit restraint**: system materials, semantic system colors, SF Symbols, standard text metrics, familiar title-bar and tab behavior. Avoid custom-branded chrome, gradients, illustrations, dashboards, and decorative animation.
- **Low visual entropy**: the page is predominantly a small text-file-like canvas. Ink is primary; controls emerge only when needed.
- **Warm but sober**: the specified tone is **“quiet, precise, slightly warm, never cute about deletion.”** Empty states should be one calm sentence, not onboarding art or gamified prompts.
- **Content-first, but not content-forward**: show typed text as ordinary editable ink; represent intentionally sealed material as opaque inline chips. Do not add rich previews, hover-to-reveal, image galleries, or elaborate syntax-editor treatments.

### Window posture is the defining macOS gesture

The app should feel spatially aware rather than screen-dominating:

| Stance | Appearance | Behavior |
|---|---|---|
| **Resting** | A borderless, transparent, shadowless card at desktop level; dimmed but readable | Behind windows, ignores clicks, refuses keyboard input |
| **Raised** | The same card, elevated into a floating editor | Interactive and keyable without disrupting the user’s other app |

The background-surface specification explicitly calls for **“.borderless, transparent, shadowless”** at rest and for the same page to remain visible but editing-refused, avoiding reflow when raised (`docs/spec/feature/background-surface/README.md`).

That creates the central aesthetic: a card that is only as present as the desktop itself, then becomes a focused writing surface through an intentional gesture.

### Information hierarchy

1. **The page** — the main visual field, with little surrounding chrome.
2. **The current lifetime** — clear, compact, and always legible; time is a property of a whole page, not individual objects.
3. **The tab rail** — bottom-anchored, spreadsheet-like tabs that identify pages and show their remaining life geometrically.
4. **Actions on demand** — hover/focus exposes copy and conceal actions for sealed chips; actions should never compete with the page.

The interaction model describes the page as **“a little text file”** and specifies that tabs sit at the bottom edge, “below the content they name, out of the title bar’s way” (`docs/spec/design/04-interaction-model.md`).

### Time should be felt, not shouted

Expiry is the product’s character, so it needs calm, persistent visual expression:

- Use a draining tab gauge as the default temporal signal.
- At under one hour, add the specified ember state and hatching—not color alone—for accessible urgency.
- No badges, banners, countdown alarms, bounce animations, or “items expiring” language.
- Paused pages use a dashed/frozen gauge and a compact `⏸ 1h` / `⏸ 24h` marker.

The design principle is explicit: **“Expiry is the promise, not a limitation to soften.”** It bans default expiry notifications in favor of the visual draining cue (`docs/spec/design/03-design-principles.md`).

### Sealed content should look intentional, not alarming

A sealed chip should read as an inline object—compact, opaque, and mechanically described—rather than a warning or a blacked-out secret:

```text
deploy Friday

[ ghp_4kQ9…e0H5jK · 40 ch ]  ↗
```

Use subdued fill, a clear outline, monospaced excerpt where appropriate, and a compact metadata count. The chip must never look like an invitation to inspect sensitive content: the spec requires hover to reveal **actions, never content**.

### What to avoid

- Sidebar-heavy organization, folders, tags, search, history, or an archive aesthetic.
- Persistent status panels, activity feeds, notification badges, or “security score” indicators.
- Floating glass ornamentation that competes with text legibility.
- Custom iconography where macOS idioms already have clear information scent.
- Bright warning colors except for bounded, accessible time urgency.
- Any UI that makes the application feel like a destination rather than a temporary transfer surface.

In short: **a restrained, text-file-like desktop card with native macOS behavior, minimal chrome, and time made visible through geometry—not interruption.**
