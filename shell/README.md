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
(off by default in the seam): the shell still routes dropped text and
the "stage a sample cell (dev)" footer through it. It goes away when
drop-to-seal gets its boundary-lawful design (core reading
`NSDraggingInfo.draggingPasteboard` directly — see
docs/hardware-verification.md).

## Honest status

- **This is the rev A surface**: a menu-bar item opening an edge-docked,
  non-activating panel of SleeperCells. The spec has since moved to
  interaction-model rev C (docs/spec/04) — a real movable, resizable,
  non-activating window with sheets of ink, sealed chips, and bottom
  tabs. Rebuilding this surface to rev C is the next milestone; ADR-0002
  records why that strengthens rather than reopens the shell choice.
- Ingest is real: the core binds `NSPasteboard.general` itself and reads
  the clipboard on request — the shell asks, the core takes.
- Expiry is scheduled (one timer at the core's next deadline), and the
  1 Hz countdown redraw runs only while the panel is visible — keep it
  that way; the frugality budget (< 25 MB idle, near-zero idle CPU) is a
  review bar, not a wish. 22 MB at 0 cells is the baseline to regress
  against.
- VoiceOver operability awaits the hardware runbook
  (docs/hardware-verification.md §B); its failure modes are ADR-0002
  eject triggers.

## The boundary law

Plaintext secret bytes live only in the Rust core. This package sees
ids, masked recognition lines, and booleans; ingest *and* copy-out
happen inside the core. If a change here needs the bytes, the change is
wrong.
