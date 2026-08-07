# shell/ — the Swift/AppKit shells

Form factors are sibling executable targets over the one core
(ADR-0010): `Sources/CompanionApp` is the panel this document
describes; `Sources/CompanionBackdrop` is the background-surface
exploration (docs/spec/feature/background-surface), packaged by
`scripts/build-backdrop.sh`. Siblings never modify each other's
sources.

## The panel (CompanionApp)

The shell selected by ADR-0002 (accepted 2026-07-13): Swift/AppKit over
the Rust core, driven end-to-end through the C-ABI seam (`crates/ffi`,
mechanism: ADR-0003). Graduated from `spikes/swift-panel`, where it was
built and measured as one arm of the two-way spike — 22 MB resident /
0.0% CPU idle, non-activating confirmed. The Tauri arm is retired; its
measurements are preserved in the ADR.

## Build (macOS only)

```sh
./scripts/build-core.sh   # cargo → universal libcompanion_ffi.a → bindings/CompanionCore.xcframework
cd shell
swift build && swift test
swift run CompanionApp
```

`swift run` is the edit-compile loop, but the bare binary has no
`CFBundleIdentifier`, so macOS can't address it — TCC grants don't
stick, and per-app screen-capture pickers can't list it. When the app
needs to be a citizen of the permission system, build the bundle:

```sh
./scripts/build-app.sh    # → dist/CompanionApp.app (ad-hoc signed; --debug for a debug build)
open dist/CompanionApp.app
```

The bundle id is `com.onetimesecret.companion` (reserved in
docs/spec/07); the version is stamped from `crates/ffi`'s
`CARGO_PKG_VERSION`, the source the About panel's string is baked from
(rebuild the core to keep them in step). Ad-hoc signing changes the
code identity on every rebuild — TCC grants reset and the Keychain
re-confirms access to stored items (the API token, the state key); set
`CODESIGN_IDENTITY` to a real certificate for an identity that
persists.

The rev C surfaces make dev scaffolding unnecessary: type a line and
⌘↩ seals it. The old dev-seed shim is gone from the packaged core, so
no shipped library exports an entry point that carries plaintext into
the seam.

## Honest status

- **This is the rev C window** (issue #12, docs/spec/04): a movable,
  resizable, non-activating window; one page of ink and sealed chips in
  an `NSTextView`-backed editor; bottom-edge tabs with per-tab gauges,
  pause on double-click, drag-to-reorder, ✕ to close; the ledger on the
  dashed ◌ tab; the full keyboard map (⌥Space, ⌘1–9, ⌘0, ⌥⌘←/→, ⌥⌘N,
  ⇧⌘V, ⌘↩, Esc). Markdown headings render styled with their markup
  kept visible; the bytes of the page never change.
- Every gesture route is boundary-lawful: sealed paste reads
  `NSPasteboard.general` core-side; **drop-to-seal reads the drag
  pasteboard core-side** (`companion_sheet_seal_from_drag`) — no
  dropped byte transits Swift; copy-out writes the board core-side. The
  editor mirrors its document over `sync_document`, which is
  authoritative for chip liveness (⌫ on a chip zeroizes in the core).
- The focus law holds: the window accepts the keyboard by deliberate
  act only (click into the page, or ⌥Space), shows an ember border
  while it holds keys, and Esc hands them back. Opening it never
  deactivates the frontmost app.
- Expiry is scheduled (one timer at the core's next event — page expiry
  or pause-hold lapse), and the 1 Hz countdown redraw runs only while
  the window is visible — keep it that way; the frugality budget
  (< 25 MB idle, near-zero idle CPU) is a review bar, not a wish. 22 MB
  at 0 cells is the baseline to regress against.
- VoiceOver operability awaits the hardware runbook
  (docs/hardware-verification.md §B); its failure modes are ADR-0002
  eject triggers. Promotion (↗ link / ↗ page) and the Settings window
  are the remaining slices.

## The boundary law (hard form, rev C)

Sealed bytes never reach this package — they have no display form at
all. This package sees ids, titles, mechanical excerpts, and booleans;
the sealed paste *and* copy-out happen inside the core. The one
plaintext-in call is `sealText` (⌘↩): its argument is visible ink the
editor already holds, and after the call the editor deletes its copy.
If a change here needs sealed bytes, the change is wrong.
