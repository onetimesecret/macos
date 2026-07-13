# Hardware-session runbook — the VoiceOver go/no-go (issue #4)

> **Rev C note (issue #10, 2026-07-13):** the core now speaks
> interaction-model rev C — sheets, gesture-only sealing, mechanical
> excerpts, the pausable countdown, the ledger; detection is deleted and
> the cap is 9 pages. Sections A and D below were written against the
> rev A code and read as history; the *checks* still stand with the
> vocabulary shifted (capture → sealed paste, cell → page, recognition
> line → excerpt). Section B's go/no-go is unchanged and still open.

Everything that can be verified without a display, VoiceOver, and full
Xcode is done and on-branch. This is the part only a person at the machine
can run: the VoiceOver operability proof that is issue #4's reason to
exist. Do it on the Mac you'll ship against, with VoiceOver **on**.

The build/test chain that Command Line Tools couldn't run is green as of
2026-07-09 (Xcode 26.0): the universal `.xcframework` builds, `swift build`
links against it, and `swift test` passes. What remains below is the
human-in-the-loop verification, not tooling.

## Build + run

1. **Full Xcode active** (not just Command Line Tools):
   `xcode-select -p` should print an `Xcode*.app/Contents/Developer` path.
   If it points at Command Line Tools, repoint:
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
   (note the full `/Contents/Developer` suffix), then `xcodebuild -version`.
2. **Build the core** → `bindings/CompanionCore.xcframework`
   (git-ignored build artifact, universal arm64 + x86_64):
   `./scripts/build-core.sh --dev-scaffolding` (the shell still links
   the dev-seed symbol for drop staging)
3. **Build + test the shell:**
   `cd shell && swift build && swift test`
4. **Run the menu-bar app:** `swift run` (or open `Package.swift` in
   Xcode and run). It appears as a status-bar item — click the icon to
   open the panel; there is no Dock icon or window.

## A — Real ingest on device (already verified headless; confirm in UI)

Headless proof: `pbcopy` a token-shaped string → the production
`companion_new` (bound to the real `NSPasteboard.general`) ingested it,
detected "GitHub token", masked it (`••••`), and the raw secret never
appeared in the summary JSON. Confirm the same through the live panel:

- [ ] Copy a secret-shaped string elsewhere (`Cmd-C` a fake token).
- [ ] Trigger capture (menu-bar → panel → **Capture**). A cell appears.
- [ ] Its recognition line is **masked**, not the raw value.
- [ ] The "sample cell" button still works (it now seeds the *real*
      clipboard, so it will replace your clipboard contents — expected).

## B — VoiceOver operability (THE go/no-go)

This is the determination issue #4 exists to make and the one still-open
input to ADR-0002's reserved shell decision. The premise under test:
native AppKit gives first-class VoiceOver for free (docs/spec/05, the
"VoiceOver-legible" cell requirement; docs/spec/02). Turn VoiceOver on
(`Cmd-F5`); drive the panel from the keyboard only.

- [ ] **Focus the cell** with VO navigation. It is reachable.
- [ ] **Hear its remaining life in words** — the `spoken_remaining`
      string ("about 7 hours remaining"), not a colour or a bare number.
      The text label is the load-bearing equivalent of the visual ring
      (origin: docs/archive/00-problem-space.md, "VoiceOver announces
      remaining life in words"); verify it reads without the ring.
- [ ] **Cycle the TTL** from the keyboard; hear the new life announced.
- [ ] **Dismiss/discard** the cell from the keyboard.
- [ ] Throughout, confirm the **frontmost app never changes** — the panel
      does not steal focus (docs/spec/03 design principle; docs/spec/04
      "Non-activating"). This is an accessibility rule, not etiquette.
      `lsappinfo front` in a terminal before/after is a cheap cross-check.
- [ ] Reduce Motion on: the draining ring's text equivalent still conveys
      remaining life (the animation is not the only signal).

**If any of B fails and can't be reached with native AppKit APIs, the
native-shell premise is wrong — that is the finding, and it feeds
ADR-0002's still-reserved shell decision.**

## C — Keychain round-trip on device (`companion-credentials`)

The macOS Keychain path (`security-framework`, cfg-gated) compiles; it
needs a real device to round-trip (the CI/dev fallback is in-memory):

- [ ] Store a credential via the Keychain path, read it back, delete it —
      on a real login keychain, confirming the prompt/ACL behaviour.

## D — Open defaults, as felt in the live UI (docs/spec/06)

Not blockers for the spike; note what the live UI reveals so the defaults
get decided from felt experience, not a spreadsheet. Current code values:

- **Default TTL:** 8h (ladder 1h→3h→8h→24h→3d→7d; docs/spec/04,
  docs/spec/06 open question 1). Does 8h feel right as the landing rung
  when you cycle?
- **Capacity:** 9 pages (was 12 cells in rev A), **refuse-don't-evict**
  (docs/spec/06 open question 4). Does hitting the keyboard wall feel
  like a wall or a nudge?
- **Eviction:** none — pages leave only by expiry or explicit close.
  Watch whether that matches intuition when the tab strip fills.
- **The pause** (rev C): double-click holds 1h, again tops up to 24h.
  Does the top-up ceiling feel bounded enough (docs/spec/06 open
  question 8)?

## Boundary-law note that surfaced during this work (drag ingest)

The **capture-from-clipboard** path is lawful and real: the core reads
`NSPasteboard.general` itself, no plaintext through Swift (the boundary
law, docs/spec/05 and ADR-0001). The **drag** path has an unresolved
wrinkle worth a decision before it ships: dragged text arrives in Swift's
drop handler (`NSDraggingInfo`) — not on the general clipboard — so the
current spike routes it via the dev-seed → the general clipboard, which
(a) means Swift briefly holds the dropped text and (b) clobbers the user's
clipboard on every drop. The lawful production design is the core reading
`NSDraggingInfo.draggingPasteboard` directly (Swift hands the core a
reference/trigger, not the bytes). Left as a documented hardware-session
decision rather than guessed, since it can't be verified without a live
drag.
