# docs/spec/design/05-technical-direction.md
---

# Technical Direction (draft — survey, not decisions)

Milestone-1 supporting material. Records the option space and provisional
leanings so milestone 2 can make decisions against something written down.

## Architecture shape (held constant across all options)

A UI-agnostic core crate plus a thin shell:

```
┌─────────────────────────────────────────────┐
│ shell (one of the options below)            │
│   panel window · tray · drag-drop · a11y    │
├─────────────────────────────────────────────┤
│ core crate (pure Rust, no UI deps)          │
│   sheet store (ink + sealed bytes,          │
│     memory-only, zeroizing)                 │
│   TTL scheduler (timer wheel, no polling)   │
│   pasteboard adapter (NSPasteboard, kinds,  │
│     ConcealedType/transient write)          │
│   ots-client (v3 API, auth strategies)      │
└─────────────────────────────────────────────┘
```

The core crate is testable headless and survives a shell swap — which is
exactly the hedge the framework question needs.

## Shell options (Rust, macOS, 2026)

| Option | What it is | For | Against |
| --- | --- | --- | --- |
| **Tauri 2.x** | System-WebKit shell, Rust backend | Mature tray + window APIs; tiny bundle vs Electron; a11y inherits WebKit/ARIA (strong); huge ecosystem; team's web skills (Vue/TS in this repo) transfer to the panel UI | Webview memory floor (~tens of MB); NSPanel non-activating behaviour needs objc2 side-door; JS layer to keep honest with the frugality principle |
| **Swift/AppKit shell + Rust core (UniFFI/swift-bridge)** | Native shell, Rust logic | Best-in-class NSPanel, menu bar, drag-drop, VoiceOver — the exact surfaces this app lives on; smallest resident footprint | Two languages/toolchains; contributors need both; "Rust-based" becomes "Rust-cored"; more release engineering |
| **gpui** | Zed's GPU-native Rust UI | Truly native-feeling Rust UI, proven at Zed scale; excellent perf | Young as a third-party dependency; a11y story still maturing; menu-bar/panel patterns less trodden |
| **egui/eframe + AccessKit** | Immediate-mode Rust UI | Simple, small, AccessKit gives real a11y; fast to prototype | Non-native look (fights "furniture" goal); immediate-mode repaint vs near-zero idle CPU needs care |
| **Slint / Dioxus native** | Declarative Rust UI | Clean component model; Slint has decent a11y | Neither is battle-tested for menu-bar utility UX on macOS |

**Provisional leaning:** Tauri 2.x shell with `objc2` for the few native
behaviours it lacks (non-activating NSPanel, `sharingType`,
pasteboard types), on the strength of maturity + a11y + contributor
accessibility — with the Swift-shell option kept live as the
better-native fallback, made cheap by the core-crate architecture.
Decision belongs to milestone 2 after a two-way spike: the window
experience (non-activating accessory, accept-never-take focus, drag-in)
is the make-or-break surface to prototype in both.

Non-negotiables regardless of shell: signed + notarized, universal binary
(arm64 first), sandboxed if feasible (pasteboard and network entitlements
are compatible; verify against capture-exclusion APIs), single-digit MB
download as a target, no always-resident helper processes.

## Security posture

The claims in docs 02–03, made implementable:

- **Memory-only by default.** Sheets live in RAM; process exit is total
  amnesia — including the ledger, which is session-bound by design (v1
  behaviour; persistence across restart is an open question). Sealed
  buffers zeroized on expiry/discard (`zeroize`), `mlock` where practical
  for small sealed payloads; large images excluded from `mlock` and
  documented as such.
- **Zeroization is why the core is Rust.** Swift is memory-safe but not
  memory-hygienic: `String`/`Data` are copy-on-write, ARC/autorelease and
  `NSString` bridging create uncontrolled copies, and there is no blessed
  way to zeroize a `String`. Rust ownership makes the wipe deterministic.
  Platform security APIs (Keychain, CryptoKit, `sharingType`, Sandbox)
  are equally reachable from any shell and don't differentiate; buffer
  lifecycle does.
- **Sealed bytes never reach the UI layer.** *(Amended by rev C — this
  was previously the softer "rendering vs residence" rule, which allowed
  the UI transient plaintext for display.)* Rev C's gesture-only masking
  makes the hard law affordable: sealed content has **no display form at
  all** — the UI receives only the mechanical excerpt and counts, so it
  can never draw the bytes, and no reveal affordance can exist. Visible
  ink is ordinary text the user chose to keep readable; it transits the
  UI like any editor's buffer. Copy-out and concealing of sealed bytes go
  core → pasteboard / core → network client directly, never through the
  UI layer. This upgrades the webview-residual-copy concern from a
  scoring criterion to a solved case for sealed content.
- **No content inspection.** The v10 round deleted secret-shape
  detection entirely: the core never parses, classifies, or scores what
  arrives. Excerpts are fixed-budget substrings; metadata comes from the
  clipboard's own declarations. Less security-sensitive code to audit,
  and "we never read what you paste" stays literally true.
- **Pasteboard hygiene.** Outbound copies marked
  `org.nspasteboard.ConcealedType` + transient. *(Amended by rev C:
  inbound `ConcealedType` no longer drives masking — masking is decided
  by the user's gesture alone, doc 04.)* Optional clear-after-copy
  (clear the system clipboard N seconds after a copy-out, only if the
  clipboard still holds our change-count).
- **Capture exclusion.** Window `NSWindow.sharingType = .none` by
  default. *(Amended by rev C: the on-surface "excluded from screen
  capture" caption is gone — the setting toggle is the honest surface.)*
- **Runtime memory dumping.** Unlike Linux (`ptrace`, `/proc/pid/mem` —
  trivial with same UID), macOS blocks `task_for_pid` against a Hardened
  Runtime binary without `get-task-allow` — even for root, unless SIP is
  disabled via Recovery. Hardened Runtime is already required for
  notarization; the discipline is shipping **zero** weakening
  entitlements (`allow-jit`, `disable-library-validation`, …). Tauri
  clears this where Electron can't: JS runs out-of-process in Apple's
  SIP-protected `WebContent`, so the binary holding resident secrets can
  be fully hardened. Note this guarantee is macOS-specific — it does not
  transfer to a Linux/Windows sibling (doc 06 §15).
- **Network boundary.** At most two outbound destinations, TLS-only,
  and no others: the configured OTS server, reached only on an explicit
  conceal, and the sync relay, reached only for a page the user has
  shared to their own enrolled devices (ADR-0021, issue #93; the client
  is built, the server side rides onetimesecret#4303). The relay sees
  ciphertext only, is opt-in per page, and is bounded by key rotation:
  an expired page's sealed deltas can outlive the page in the relay's
  buffer until the next ceremony's rotation orphans them
  (relay-protocol.md §3), which is the honest per-page bound. No
  telemetry, no update pings beyond a launch-time check against the
  release feed. `crates/transport` is where the
  boundary is enforced, and the enforcement stays: its allowlist widens
  from one entry to two rather than being removed.
- **Credential storage.** API token in the macOS Keychain, never in
  config files.
- **Threat honesty.** Out of scope and said so: a compromised local user
  account, kernel-level attackers, machines with SIP disabled (common on
  dev boxes — the anti-dumping guarantee above evaporates there), and
  other apps with screen-recording + accessibility permissions granted. The app hardens the common cases
  (shoulder surfing, screen sharing, clipboard-manager retention, swap,
  crash dumps) and does not pretend to be an enclave.

## Onetime Secret v3 API integration

Grounded in the current repo (`apps/api/v3/routes.txt`,
`src/schemas/api/v3/`):

- **Conceal** → `POST /api/v3/secret/conceal` with
  `{ kind: "conceal", secret, ttl, share_domain, passphrase?, recipient? }`.
  The sheet's remaining TTL seeds `ttl`, snapped to server-permitted
  values; entitlement rejections (cf. `secret_ttl_entitlement_spec.rb`)
  surface inline with the nearest allowed value offered. Sealed bytes are
  composed into the request core-side (see the boundary law above).
- **Auth, phase 1:** HTTP Basic (`basicauth` strategy — API key + secret
  pair, configured alongside the organization `extid`), stored in
  Keychain. **Phase 2:** PASETO bearer tokens when v3 auth ships; the
  `ots-client` crate isolates auth as a strategy trait so the swap is
  additive.
- **Guest mode:** where the server enables guest route gating,
  `POST /api/v3/guest/secret/conceal` allows a guest conceal with no
  account, worth supporting so the open-source app is fully useful against
  self-hosted instances with zero setup.
- **After a conceal:** store only the receipt identifier on the live
  sheet (for a "burn remote" affordance there alone). No receipt
  browsing, no local history of concealed secrets (doc 03 §5).
- **Server config:** `GET /api/v3/status` + config endpoints at
  connection-test time to learn allowed TTLs and share domains, cached in
  memory only.

## Accessibility commitments

Category-defying per doc 02 §8; committed now because retrofits fail:

- **Keyboard-complete.** Every operation in doc 04's keyboard map has a
  binding; ⌥Space summons the window for full keyboard operation, esc
  hands it back.
- **VoiceOver-legible.** A sealed chip is one accessibility element with
  a composed label built from its excerpt and count ("Sealed, ghp_4kQ9…,
  40 characters"); the countdown label is an adjustable control
  (VO-arrows step the ladder); each tab announces its name and remaining
  time; the draining gauge mirrors into an accessibility value that
  announces at coarse thresholds only (no chatter).
- **Not colour-only.** Urgency encoded in gauge texture (hatching) +
  label text, not hue alone; WCAG 2.2 AA contrast against both system
  materials.
- **Motion-respectful.** `prefers-reduced-motion` swaps the draining
  animation for stepped states; no parallax, no bounce.
- **Text scaling.** The sheet is a text view and tabs a single strip, so
  reflow with system text size is layout-cheap if honoured from the
  first sketch.

## Frugality budget (v1 targets, measured in CI once real)

| Metric | Target |
| --- | --- |
| Download size | < 10 MB |
| Resident memory, idle w/ 5 sheets | < 60 MB (Tauri) / < 25 MB (native shell) |
| Idle CPU | ~0% (no timers ticking; TTL expiry scheduled) |
| Wakeups | No periodic wakeups while panel hidden |
| Network at rest | Zero connections |
| Cold launch to usable panel | < 300 ms |
