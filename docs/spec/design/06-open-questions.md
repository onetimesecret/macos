# docs/spec/design/06-open-questions.md
---

# Open Questions

Updated for interaction-model revision C (doc 04). Questions the design
rounds settled are recorded first — with their resolutions, so the
reasoning stays auditable — then everything still genuinely open, each
with a current leaning where one exists.

## Settled since rev A

- **Secret-shape detection** (was Q7). Settled in the opposite direction
  of the old leaning: detection is **deleted**. Masking is decided by
  gesture, never by content or origin; excerpts are mechanical; the app
  never reads what you paste. (v10 round; doc 04.)
- **The switcher.** Tabs won, on the window's bottom edge,
  Excel-anchored, drag-to-reorder, with the ⌘-number map.
- **The seal gesture.** ⌘↩ — seals the selection, or the current line if
  it holds content. (Was proposed as ⌥⌘S.)
- **Sealed paste.** ⇧⌘V, rekeyed from ⌥⌘V under OS-collision audit; ⌥V
  held as the fallback candidate if "paste and match style" proves too
  contested in practice.
- **Capacity** (was Q3). 9 sheets — the keyboard-map wall (⌘0 belongs to
  the ledger). Refuse-don't-evict unchanged. Whether 9 is too generous
  remains open (below).
- **Default TTL** (was Q1). 8h stands; it survived three design rounds
  without a challenger.
- **Expiry undo** (was Q5). Expiry stays silent; the ledger is the
  answer for ink (the typed context is what a tombstone was for), and
  sealed bytes get no tombstone of any kind.
- **Reveal-on-hold.** Gone with detection: a sealed chip is never
  revealable, at any privilege. Hover shows actions, never content.
- **Multi-display / dock edges** (was Q14). Mooted as framed: the panel
  became a free-floating window that remembers its own position.

## Product

1. **Does the TTL ladder wrap?** ~~Carried from rev A, still
   unaddressed in rev C: `…→ 7d → 1h` wrap is one-affordance-clean but
   makes "one click past max" a 168→1 hour cliff on deliberately staged
   content.~~ Answered 2026-08-08 by living with it: the wrap stays,
   and the click direction inverts. Clicking now steps one rung
   *shorter* (`7d → 3d → 24h → 8h → 3h → 1h`, wrapping back to `7d`),
   so the cliff sits where it costs nothing. Reaching the most
   precarious rung from a fresh page is five deliberate clicks, and the
   one-click jump is the recovery, not the hazard.
2. **Drop semantics.** Drop = sealed is the proposal (dragging content
   to a secrecy tool is already the "stage this" gesture); the
   alternative mirrors paste (visible by default, modifier to seal).
   Decide by living with it.
3. **Images.** Always sealed, metadata only — settled at the interaction
   level. Still open at the technical level (was Q6): images fight the
   memory-hygiene story (size, `mlock` exclusion) and the v3 conceal
   payload is text-shaped. Ship text-first with images close behind, or
   together?
4. **Is the 9-sheet cap too generous?** The keyboard map is the wall,
   but a window that comfortably holds nine long-lived pages starts to
   look like storage. Watch real working-set sizes.
5. **Undo across a seal.** Proposed: ⌘Z removes the chip without
   restoring the text (undo never un-seals). Needs a felt test.
6. **Dark appearance.** Still unexplored; the ember/hatching urgency
   cues need checking against dark materials.
7. **The name.** "Airlock" collided with Airlock Digital and was retired
   in favour of the deliberately generic working title "CompanionApp".
   Shortlist and trademark pass still needed before any public artifact.
8. **Pause abuse.** Serial top-ups can hold a page alive indefinitely,
   one deliberate double-click at a time. Is a cumulative ceiling (say,
   7d of total held time) needed, or is requiring presence-per-24h
   discipline enough?
9. **Markdown scope.** Headings only for now. Inline emphasis
   (**bold**, `code`) is cheap to add and easy to regret — the page
   should read like a text file, not a wiki. Revisit with use.
10. **Ledger retention.** Session-bound today. Should it also age out on
    a fixed window (e.g. 24h) even within a long-running session?
11. **Persistence across restart.** v1 leaning unchanged: none — quit is
    amnesia, and rev C's ledger deliberately follows the same law
    (in-memory, session-bound). But the "overnight hold" moment (doc 01)
    still collides with an OS update reboot, and the pause feature
    sharpens it: a paused page the user meant to keep dies with the
    process. If ever added: encrypted spill keyed via Keychain/Secure
    Enclave, off by default, ink-only (sealed bytes never persist), and
    it must not soften the expiry contract.

## Platform & technical

12. **Shell decision.** Tauri 2.x vs Swift-shell-Rust-core (doc 05).
    Requires the two-way spike on the non-activating window — the one
    surface that can disqualify a framework. Rev C raises the bar: the
    window must move, resize, and stretch like a real window while never
    activating, and the boundary law hardened from "UI renders
    transiently" to "UI never receives sealed bytes" (doc 05) — a
    discipline any shell can meet, so it's a scoring criterion, not a
    gate. Either way, "Rust-based" honestly means "Rust-cored".
13. **Sandbox + capture exclusion.** Verify App Sandbox coexists with
    `sharingType = .none` and the pasteboard patterns we need; sandboxing
    is worth real effort but not worth losing capture exclusion.
14. **Distribution.** Direct download + Homebrew cask (leaning), or also
    Mac App Store (sandbox implications, review friction vs reach)?
15. **Guest-mode prominence.** Where servers allow guest conceal, does
    promotion work with zero configuration out of the box (great for
    self-hosters, but link provenance/trust questions for
    onetimesecret.com defaults)?
16. **TTL semantics across promotion.** Snap sheet-remaining time to
    server-allowed TTLs — up, down, or nearest? Down is the conservative
    (never outlive intent) leaning.
17. **Global shortcut collisions.** ⇧⌘V is "paste and match style" in
    many editors; inside our own window that claim is ours, but the
    muscle-memory collision is real (⌥V is the held fallback). ⌘1–9/⌘0
    are browser-tab shortcuts — irrelevant in a native window, but the
    prototype had to fall back to ⌃-equivalents, a reminder to re-audit
    on real hardware.
18. **Copy-source attribution.** Investigated from a dogfood ask: can a
    pasted-in secret show which app it came from? `NSPasteboard` has no
    source-app API. The one lead is the opt-in `org.nspasteboard.source`
    convention — same family as `CONCEALED_TYPE`/`TRANSIENT_TYPE`, which
    the pasteboard crate already speaks — but it is only honoured by
    clipboard-manager-aware apps, so coverage would be inconsistent.
    General attribution (any copy, from any app) means correlating
    `NSWorkspace` frontmost-app tracking against `NSPasteboard`'s
    `changeCount`, and `changeCount` has no push notification —
    ADR-0007 Amendment 1 already names that gap ("macOS provides no
    notification for pasteboard changes, so clipboard managers poll
    changeCount") as an exposure, not a technique to adopt. Doing so
    would also break `WindowController`'s "each reveal looks at the
    board once, never a poll." A poll-free approximation exists for the
    narrower case the ask actually described (⌘Tab away, copy, ⌘Tab
    back): read `NSWorkspace.shared.frontmostApplication` once, at the
    moment `summon()` begins and before this app takes activation — a
    single point-in-time read, no timer, and since it is cosmetic UI
    metadata rather than secret content it never needs to cross the FFI
    boundary into the core. It only answers "app active immediately
    before this summon," not "app that performed the copy" (wrong if a
    third app was visited in between). Leaning: skip general
    attribution; the narrow poll-free version is cheap enough to build
    if the dogfood keeps missing it.

## Ecosystem

18. **Windows/Linux siblings.** The core-crate split keeps the door
    open; naming it "macOS companion" closes it rhetorically. Decide
    posture before announcing.
19. **Relationship to future v3 PASETO work.** The desktop app is a real
    first consumer of v3 auth — should its needs (long-lived org tokens,
    device-ish identity, offline grace) feed back into that design now,
    while it's unbuilt?
