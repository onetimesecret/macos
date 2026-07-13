# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
