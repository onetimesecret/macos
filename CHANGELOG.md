# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Pages persist across relaunch, sealed at rest** — quit is the one
  moment state touches disk: `applicationShouldTerminate` asks the core
  to snapshot the whole store (live pages, chips, the ledger, clocks)
  into an exact-size zeroizing buffer (`companion-core::persist`,
  format `OTSSNAP1`), seal it with ChaCha20-Poly1305 under a 32-byte
  key resting in the Keychain (`state-key`, same service as the API
  token), and write only ciphertext to
  `Application Support/CompanionApp/state.sealed` (0600, atomic
  temp-file rename). The window's first reveal is the mirror — not
  launch, so starting at login never raises a Keychain prompt for a
  window nobody asked to see: decrypt, restore, then drain the
  wall-clock time the app was closed — countdowns keep ticking while
  away, holds absorb time-away first, and pages that didn't survive
  the gap expire into the ledger before the window opens. A session
  whose window never showed never saves, so it cannot overwrite
  yesterday's file with an empty store. The file is useless without
  the Keychain item and vice versa;
  deleting either forgets everything. Tampering anywhere in the file
  (or a bare bit flip) fails authentication and reads as a fresh
  start. New seam: `companion_persist_save` / `companion_persist_restore`
  / `companion_sheet_document_json` (the last replays a restored
  page's ink and chip faces so the editor rebuilds pixel-identical —
  sealed bytes still never cross into Swift).

- **The shell packages as a real .app bundle** — `scripts/build-app.sh`
  assembles `dist/CompanionApp.app` (bundle id
  `com.onetimesecret.companion`, reserved in docs/spec/07) from the
  Swift build, stamps the bundle version from `crates/ffi`'s
  `CARGO_PKG_VERSION` (the same string the About panel shows), and
  ad-hoc signs it (`CODESIGN_IDENTITY` overrides). A bare `swift run`
  binary has no `CFBundleIdentifier`, so TCC grants and per-app
  screen-capture pickers cannot address it; the bundle makes the app a
  citizen of the permission system. `LSUIElement` in the checked-in
  `shell/Info.plist` declares the accessory nature at the bundle level.
  CI assembles the bundle in the shell lane so the packaging cannot rot.

- **ADR-0004 accepted: Keychain prompt timing** — the ACL prompt may
  appear only when a secret is used (a promotion reading the token),
  never for a presence check. `CredentialStore::exists` answers "is a
  token stored?" via an attributes-only Keychain query that never
  decrypts; `has_token` in the connection JSON now means stored, not
  readable, so launch and Settings no longer greet the user with a
  Keychain prompt. See docs/adr/0004-keychain-prompt-timing.md.
- **Clear stored token** in Settings → Connection: removes the token
  from the Keychain through the existing seam (empty token → delete),
  behind an inline confirm — the destructive-act guard the rest of the
  surface uses.
- **The promotion flow** (issue #16, docs/spec/04) — the exit ramp, and
  the app's only network action. Two affordances: **↗** on a chip's
  hover actions and **↗ page** in the footer, both opening an inline,
  in-place confirmation (never a modal) with the destination named, the
  TTL seeded from the page's remaining time snapped *down* the ladder,
  and optional passphrase/recipient — the network boundary is the one
  confirming click. On success the share link is on the clipboard
  (written core-side, transient-marked), only the receipt id stays on
  the chip, and the confirmation offers **Burn local copy** (a chip
  leaves the document and zeroizes; a page closes into the ledger).
  Failure is inline with retry; content never leaves the sheet.
  - **The seam stays lawful**: `companion_chip_promote` /
    `companion_sheet_promote` move the sealed bytes core → `ots-client`
    → transport directly — they never enter Swift. Page promotion
    refuses image chips (the v3 payload is text-shaped, open question
    №3). The core mutex is released for the network round-trip, so a
    slow server never blocks a summon; both routes (and the Settings
    test) block their own thread and are called off the main actor.
  - **Connection config** (`companion_connection_configure` /
    `_json` / `_test`): server URL (refused unless `https://` — the
    TLS-only boundary enforced at config, not the socket), share
    domain, org `extid` as non-secret config; the **API token goes
    straight through the seam to the Keychain**
    (`companion-credentials`) and is never retained in config, echoed
    back in any JSON, or readable from the Settings UI again. Auth is
    Basic (extid + token) when configured, the guest conceal route
    otherwise — promotion works with zero setup against the default
    server.
  - **Settings → Connection** (right-click the menu-bar item): server
    URL, share domain, extid, a write-only token field, and a test
    button (`GET /api/v3/status`). Unlike the main window, Settings
    activates normally — deliberate act, needs the keyboard.
  - Tested sans-network: the conceal call is generic over the
    transport, so Rust unit tests drive it with a mock (auth route
    selection, guest fallback, TTL snapping, error shaping) and the
    Swift contract test covers config round-trip and offline refusals;
    CI never opens a socket, and the seam tests never write a real
    Keychain.

### Changed

- **The shell is CompanionApp now** — package, product, executable,
  targets, source and test directories, and every doc reference;
  renamed wholesale, no aliases kept. A companion app named
  CompanionApp, in the proud naming tradition of *Scary Movie*.
- **The menu-bar glyph is a template image now** — the maruhi drawn
  monochrome (㊙ with the text-presentation selector) onto an
  `isTemplate` image, so the system tints it like every other status
  item: dark in light mode, light in dark mode, dimmed when inactive.
  The colour emoji title never got any of that.
- **The About panel earns its keep** — the colour ㊙️ at icon size
  (colour is the point there; the menu bar keeps the template), the
  app's name, and the core's version via `companion_version()`. A bare
  SwiftPM executable has no Info.plist, so the standard panel had
  nothing to say before.
- **Tabs drag to reorder** — grab a page tab and slide it, spreadsheet
  style; the ⌘-number map follows the visible order. The previous
  item-provider drag never started inside a non-activating panel, so
  the affordance is now a plain mouse drag with midpoint-based
  reordering.
- **⌘W closes what's showing** — the macOS convention: a page goes to
  rest in the ledger; the ledger view steps aside.
- **Transient notices dismiss themselves** — "the link is on the
  clipboard" and friends clear after a few seconds instead of lingering
  until the next action; a newer notice restarts the clock.

### Fixed

- **The window no longer hovers over fullscreen apps, pinned or not**
  — `.canJoinAllSpaces` turned out to be the culprit: for an accessory
  app it joins fullscreen Spaces too, and AppKit has no combination
  that means "every desktop, but never fullscreen". The window now
  lives on one Space and comes when called (`.moveToActiveSpace`):
  summoning brings it to the desktop you're on, switching Spaces
  leaves it where it was, and a fullscreen Space only ever sees it by
  deliberate summon — menu-bar click or ⌥Space — never by drifting in.
  The pin still decides only the altitude among ordinary windows:
  pinned floats above them, unpinned is a normal window others can
  cover.
- **⌥-click on the menu-bar item reliably opens Settings** — the check
  reads the live hardware modifier state instead of the delivered
  event's flags, which the status bar can misreport (and which go stale
  under an accessibility press).
- **The blank strip above the header is gone** — the transparent
  titlebar's safe-area inset was doubling the top bar; the hosting view
  now ignores it.
- **The ledger tab toggles** — click ◌ to visit the ledger, click it
  again to return to the page; before, it only opened.
- **A tab's hover ✕ no longer shifts the title** — the close button
  keeps its space reserved and reveals by opacity, the browser-tab
  convention, instead of inserting itself on hover.
- **Esc no longer blinks the window** — handing the keyboard back used
  to reorder the window out and front again (a non-activating panel
  has no "resign key" verb), a round trip that showed as a visible
  hide-and-reappear over a fullscreen Space. Key status now passes
  through an invisible one-pixel relay panel that takes the keys and
  immediately orders out — the window server returns the keyboard to
  the active app while the window never leaves the screen.
- **The sealed-state temp file can no longer be raced or redirected** —
  saves used to write through a predictable `state.sealed.tmp` opened
  create-and-truncate, which a crash leftover, a planted symlink, or a
  second running instance could subvert. Each save now writes through
  its own random-named temp file opened create-new (never following
  what's already there), and cleans up after a failed rename as well
  as a failed write.
- **A state file that fails to restore is no longer overwritten at
  quit** — a denied or missing Keychain key used to hand the session a
  fresh page and, with it, the licence to save that empty store over
  yesterday's file. The save licence is now withheld when an existing
  file refuses to restore: the session still gets a working page, but
  the old sealed state stays on disk for a later, luckier launch.
- **A refused quit-save is no longer silent** — the one write of the
  session used to discard its result, exiting cleanly with nothing
  saved. The save now happens in `applicationShouldTerminate`, where a
  refusal logs itself and asks — Quit Anyway or Cancel — before the
  session's pages are lost.

## [0.1.0] - 2026-07-13

The first tagged milestone. The rev C surface ran its first live
hardware session on real hardware: summoned, typed on, sealed, and —
confirmed by the session itself — excluded from capture (screenshots of
the window come out blank; the session had to be photographed with a
phone). Rough edges noted for follow-up; the core loop works.

### Added

- **The rev C window** (issue #12, docs/spec/04) — the shell sheds the
  spike's transitional docked list and becomes the window the spec
  describes: movable by its title bar, resizable from any edge,
  double-click-stretch to full working height, frame persisted across
  summons, still a non-activating accessory excluded from capture. One
  page shows at a time in an `NSTextView`-backed **ink editor**: typed
  ink, sealed chips as atomic inline attachments (arrows step over, one
  ⌫ removes whole — the sync mirror zeroizes core-side), markdown
  headings styled display-only with the markup kept visible. Bottom-edge
  Excel-anchored tabs carry live titles and per-tab gauges (dashed when
  held, hatched ember in the last hour), pause on double-click, close on
  ✕, drag to reorder; the dashed ◌ tab is the ledger — dead pages as
  dimmed read-only ink, tombstones struck through and labelled
  "zeroized". The keyboard map is complete: ⌥Space summon (Carbon
  hotkey, the app's one global claim), ⌘1–9, ⌘0, ⌥⌘←/→, ⌥⌘N, ⇧⌘V, ⌘↩,
  Esc hands the keyboard back (an ember border shows while the page
  holds it). Focus law unchanged: keys by deliberate act only.
- **Drop-to-seal is boundary-lawful**: `companion_sheet_seal_from_drag`
  reads the **drag pasteboard** core-side (`NSPasteboard(name: .drag)`,
  a new `SystemPasteboard::drag()` binding) while the drop handler is
  still inside the drag session — the shell hands over only the page id,
  no dropped byte transits Swift, the general clipboard is untouched.
  This closes the drag-ingest decision the hardware runbook had left
  open; what remains there is live-drag verification, not design.
- **The Rust↔Swift JSON contract test** (deferred from PR #11):
  `CoreContractTests` drives the live core through `CompanionClient` —
  sheet lifecycle, seal, document sync, title derivation, the pause, the
  ledger tombstone, the cap refusal — so a drifting field name fails in
  CI instead of rendering as an empty window. Deliberately avoids the
  pasteboard routes, so tests never touch a developer's real clipboard.

### Changed

- **The core speaks interaction-model rev C** (issue #10): sheets of
  ink and sealed chips replace the SleeperCell stack, and **detection
  is deleted outright** — `detect.rs`, `secret_shape`, `detected_as`,
  the concealed-hint plumbing, and every reference; masking is by
  gesture, never by content and never by origin. The new model:
  - `SheetStore`: up to **9 pages** (the keyboard wall; was 12 cells),
    refuse-don't-evict unchanged; drag-to-reorder; one **pausable
    countdown per page** (double-click holds 1h, again tops up to 24h
    from now — never cumulative; a hold freezes remaining life and
    lapses on its own, and cumulative held time is tracked for open
    question №8). Chips carry the **mechanical excerpt**, computed once
    at seal time (single line `min(24, ⌊n/3⌋)` split 60/40 head–tail;
    multi-line first line ≤17 chars + line count; images metadata-only
    — magic-byte sniff, never a decode, and excluded from `mlock` per
    doc 05). Tab titles derive core-side from the first typed line,
    heading markup stripped.
  - **The ledger**: dead pages (expired or closed) rest in a
    session-bound, read-only, newest-dozen record — dimmed ink plus
    chip tombstones (excerpt only; sealed bytes zeroized at death,
    exactly as before). Empty pages leave no record.
  - **The synced document**: the shell's editor owns live ink and
    mirrors its structure (`ink`/`chip` runs) into the core, which is
    authoritative for chip liveness — a snapshot that omits a chip
    zeroizes it (⌫ removes whole; undo never un-seals).
  - **The seam is rev C**: `companion_sheet_*` (new/close/move/
    cycle_rung/set_rung/pause_press/sync_document), the two seal routes
    — `companion_sheet_seal_from_pasteboard` (⇧⌘V: the core reads the
    board itself) and `companion_sheet_seal_text` (⌘↩: the seam's one
    deliberate plaintext-**in** entry — the argument is visible ink the
    shell already holds; the gesture moves it into custody) —
    `companion_chip_copy_out` (always transient + concealed) /
    `companion_chip_delete`, `companion_sheets_json` /
    `companion_ledger_json`, and `companion_next_event_ms`, which folds
    **pause-hold lapses** into the one armed timer (no polling,
    unchanged). `companion_ingest_pasteboard` and the
    `companion_cell_*` family are gone: a plain ⌘V is visible ink and
    never reaches the core. The boundary law is recorded in its rev C
    hard form — sealed bytes never reach the UI layer at all — and the
    boundary test now seals through every route and asserts the bytes
    appear in no output.
  - The shell is ported as a **transitional surface** (still the docked
    panel, now listing pages with their gauges, pause state, and the
    seal gestures); the real rev C window is the next slice. The demo
    REPL walks the full rev C lifecycle headless. ADR-0001's
    "rendering vs residence" consequence is annotated as superseded by
    the hard law; the hardware runbook carries a rev C note.
  - An adversarial review pass hardened the slice: `SystemClock` now
    anchors to a **sleep-inclusive OS clock** (`CLOCK_MONOTONIC` on
    Darwin, `CLOCK_BOOTTIME` on Linux), so countdowns and pause-holds
    keep draining while the machine sleeps — an 8h page no longer gains
    a weekend of life from a closed lid. Cycling or setting the rung of
    a due-but-unreaped page now refuses instead of resurrecting it
    (zero means zeroized, matching the pause's own refusal); the sealed
    paste zeroizes its transit copy of the clipboard string; page
    payloads preallocate exactly, so reallocation strands no sealed
    bytes in freed heap; and the Swift ⌘↩ wrapper refuses text with an
    interior NUL rather than sealing a silent truncation.
- **The shell graduated**: `spikes/swift-panel` is now `shell/`, per
  ADR-0002's consequences — the Swift package is unchanged apart from
  the xcframework path and its comments losing the spike framing.
  `spikes/tauri-panel` (and `spikes/` itself) is retired; the ADR
  preserves its measurements. CI gains a `shell (macos)` lane that
  builds the seam's universal xcframework (`scripts/build-core.sh
  --dev-scaffolding`) and runs `swift build && swift test` — the first
  time the Swift package is compiled by CI rather than by hand.

- **ADR-0002 accepted: the shell is Swift/AppKit** over the Rust core,
  across the C-ABI seam (ADR-0003). Decided on the two-way spike's
  evidence: native non-activating/drag semantics with no workarounds and
  22 MB idle vs. Tauri's bypassed visibility API, JS-side drag handling,
  and 61.6 MB (already over budget at 0 cells). The VoiceOver hardware
  runbook (docs/hardware-verification.md §B) stays open as verification;
  its failure modes are recorded as eject triggers, not gates.
  Consequences: swift-panel graduates to `shell/`, tauri-panel retires.

### Added

- Real pasteboard **ingest** across the C-ABI seam (issue #4): on macOS
  `companion_new` now binds the real `NSPasteboard.general` via the
  `SystemPasteboard` adapter (WS2) instead of the in-process stand-in, so
  the core reads the system clipboard itself — the shell asks, the core
  takes. Off macOS and in the FFI unit tests the in-process
  `MemoryPasteboard` stays, chosen once in `companion_new` behind an
  internal `Board` enum and invisible above the seam; the tests build a
  seeded in-memory handle directly so they never read or clobber a real
  clipboard. Verified end to end: a token-shaped string placed on the real
  clipboard with `pbcopy` is ingested, detected ("GitHub token"), masked
  in the summary JSON (`••••`), and the raw secret never appears — the
  boundary law holds through the live path. The `.xcframework` packaging
  and `swift build`/`swift test` remain to be run on a machine with full
  Xcode (this environment has Command Line Tools only); the Rust core
  builds clean in release for both Apple arches. See
  docs/adr/0003-binding-mechanism.md for the seam's binding decision.
- `spikes/tauri-panel`: the Tauri arm of the ADR-0002 two-way spike —
  Rust-native (links `companion-core`/`companion-pasteboard` directly, no
  C-ABI seam needed), non-activating edge-docked panel achieved by
  bypassing Tauri's own `show()`/`set_visible()` (which unconditionally
  calls `makeKeyAndOrderFront`) with a direct objc2 side-door onto the
  raw `NSWindow`; text-drag receiving via the WebKit/HTML5 DnD layer
  (Tauri's native `DragDropEvent` is file-paths-only); scheduled expiry
  via `tauri::async_runtime` + `tokio::time::sleep`; menu-bar tray icon.
  Verified non-activating via `lsappinfo` polling; measured 61.6 MB
  resident / 0.0% idle CPU across all 4 processes (main + 3 WebKit XPC
  helpers) — already over docs/spec/05's 60 MB Tauri budget at 0 cells.
  See docs/adr/0002-shell-selection.md for the full comparison against
  swift-panel (issue #3, workstream 1).
- `companion-transport`: `UreqTransport`, the one concrete HTTP
  transport this workspace ships for `ots-client` (`ureq` + `rustls`,
  default-features off — no gzip/cookies/charset). Refuses a non-`https`
  URL before any socket opens (the network boundary, docs/spec/05).
  `ots-client` itself stays sans-IO; this crate is the integrator's one
  choice, made once, here.
- `companion-core`'s demo gains `send`/`login`/`logout`: `send` performs
  a real `POST` through `UreqTransport` — authenticated (Keychain-or-dev
  credentials from `companion-credentials`, set via `login`) when
  available, the guest route otherwise — lands the returned share link
  on the clipboard (`SystemPasteboard` on macOS), and retains only the
  receipt id on the cell. `promote` is unchanged (still a dry run);
  `send` is the live path. Verified live against the guest route on
  `eu.onetimesecret.com`: a real secret was concealed, the share link
  round-tripped onto the real clipboard, only the receipt id was kept
  (issue #3, workstream 3 — closes the promotion loop end to end).
- `companion-pasteboard`: the real `NSPasteboard` adapter
  (`SystemPasteboard`, macOS-gated, `objc2`/`objc2-app-kit`), meeting the
  hygiene contract already tested against `MemoryPasteboard` — outbound
  writes carry `TransientType` always and `ConcealedType` when secret,
  inbound `ConcealedType` is reported, clear-after-copy is
  change-count-guarded. Verified against the real system clipboard: both
  marks land as written and are visible to any pasteboard observer
  (issue #3, workstream 2).
- Harvested from the parallel skeleton prototype (PR #5), adapted to
  this crate layout:
  - `companion-core`: `SecretBuffer` (page-locked via `mlock`, zeroized
    on drop, compile-time proofs it cannot be cloned, logged, or
    serialized) now backs every cell's content; `harden_process()`
    disables core dumps before any secret is held.
  - `companion-credentials`: the `CredentialStore` contract with a
    macOS Keychain implementation (`security-framework`, cfg-gated) and
    an in-memory dev fallback. The API token never lives in config.
  - `companion-ffi`: the C-ABI seam for a non-Rust shell — opaque
    handles and non-secret JSON only, with a test asserting plaintext
    never crosses. Adds what the prototype's seam lacked: copy-out (the
    core writes the pasteboard itself, transient/concealed-marked, with
    a change-count-guarded clear) and `next_deadline_ms` so the shell
    arms one timer instead of polling. The temporary plaintext-ingest
    dev shim is gated behind an off-by-default `dev-scaffolding`
    feature, so a normal build exports no entry point that moves
    plaintext across the seam. `scripts/build-core.sh` packages it as a
    universal `.xcframework` (`--dev-scaffolding` opts the spike in).
  - `spikes/swift-panel`: the Swift/AppKit arm of the ADR-0002 spike —
    menu-bar panel, non-activating edge-docked `NSPanel`
    (`sharingType = .none`), draining ring with Reduce Motion fallback
    and VoiceOver text equivalents, drag receiving via
    `.onDrop(of: [.plainText])`, bound to the seam through
    `PanelController` as the app's real entry point. Verified
    non-activating and measured (~22 MB idle, 0.0% CPU) via `lsappinfo`
    polling and `footprint`/`top` — see docs/adr/0002-shell-selection.md.
    VoiceOver operability itself awaits the issue #4 hardware session.
  - CI: a full-history gitleaks secret-scan job. The binary is
    version-pinned and checksum-verified; intentionally fake test
    fixtures are allowlisted by exact fingerprint in `.gitleaksignore`,
    and PAT-shaped samples are assembled at runtime so no token-shaped
    literal sits in the source text.
- Repository skeleton per the spec's initialization prescription
  (docs/spec/07): Cargo workspace, CI lanes, ADR practice, governance
  files.
- `companion-core`: zeroizing cell store, TTL ladder
  (1h → 3h → 8h → 24h → 3d → 7d, default 8h), scheduled expiry (no
  polling), cap-refusal at twelve cells, conservative secret-shape
  heuristics, lifecycle states.
- `ots-client`: sans-IO client for the Onetime Secret v3 API — conceal
  (authenticated + guest routes), auth as a swappable strategy (HTTP
  Basic now, PASETO later), downward TTL snapping, share-link assembly.
- `companion-pasteboard`: the pasteboard hygiene contract
  (`ConcealedType`, transient marking, change-count-guarded
  clear-after-copy) with an in-memory implementation for tests, the
  demo, and non-macOS hosts.
- A headless demo of the SleeperCell lifecycle:
  `cargo run -p companion-core --example demo`.
