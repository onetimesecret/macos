# shell/ — the Swift/AppKit shell

The shell selected by ADR-0002 (accepted 2026-07-13): Swift/AppKit over
the Rust core, driven end-to-end through the C-ABI seam (`crates/ffi`,
mechanism: ADR-0003). Graduated from `spikes/swift-panel`, where it was
built and measured as one arm of the two-way spike — 22 MB resident /
0.0% CPU idle, non-activating confirmed. The Tauri arm is retired; its
measurements are preserved in the ADR.

## Build (macOS only)

```sh
./scripts/build-core.sh --dev-scaffolding   # cargo → universal libcompanion_ffi.a → bindings/CompanionCore.xcframework
cd shell
swift build && swift test
swift run CompanionPanel
```

The `--dev-scaffolding` flag compiles in `companion_dev_seed_pasteboard`
(off by default in the seam): the "seal a sample (dev)" footer routes
through it. It goes away when drop-to-seal gets its boundary-lawful
design (core reading `NSDraggingInfo.draggingPasteboard` directly — see
docs/hardware-verification.md).

## Honest status

- **The core speaks rev C; this surface is transitional** (issue #10).
  The seam and everything behind it is the rev C model — sheets with a
  pausable countdown, gesture-only sealing (⇧⌘V, drop, seal-text),
  mechanical excerpts, the ledger, cap 9 — but the panel still wears the
  spike's shape: a menu-bar item opening a docked list of pages, not
  the rev C window (movable, resizable, bottom tabs, the ink editor).
  Building that window is the next slice; ADR-0002 records why rev C
  strengthens rather than reopens the shell choice.
- Sealed paste is real: the core binds `NSPasteboard.general` itself and
  reads the clipboard on the gesture — the shell asks, the core takes.
  Drop-to-seal interim route: the drop handler hands text to the core's
  seal-text entry (the ⌘↩ call); the lawful end state is the core
  reading the drag pasteboard itself.
- Expiry is scheduled (one timer at the core's next event — page expiry
  or pause-hold lapse), and the 1 Hz countdown redraw runs only while
  the panel is visible — keep it that way; the frugality budget
  (< 25 MB idle, near-zero idle CPU) is a review bar, not a wish. 22 MB
  at 0 cells is the baseline to regress against.
- VoiceOver operability awaits the hardware runbook
  (docs/hardware-verification.md §B); its failure modes are ADR-0002
  eject triggers.

## The boundary law (hard form, rev C)

Sealed bytes never reach this package — they have no display form at
all. This package sees ids, titles, mechanical excerpts, and booleans;
the sealed paste *and* copy-out happen inside the core. The one
plaintext-in call is `sealText` (⌘↩): its argument is visible ink the
editor already holds, and after the call the editor deletes its copy.
If a change here needs sealed bytes, the change is wrong.
