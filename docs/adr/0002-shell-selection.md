# ADR-0002: Shell selection

- **Status:** accepted — Swift/AppKit shell over the Rust core
- **Date:** 2026-07-08 (evidence); decided 2026-07-13

## Context

Both arms of the two-way spike are built and measured:
`spikes/swift-panel` (Swift/AppKit shell, bound to the core through the
C-ABI seam in `crates/ffi`) and `spikes/tauri-panel` (Tauri 2 shell,
Rust-native — links `companion-core`/`companion-pasteboard` directly,
no C-ABI needed). Both target the one surface that can disqualify a
framework: a non-activating, edge-docked, drag-receiving panel. Survey
and provisional leaning: docs/spec/05.

Both spikes deliberately stage dropped text through a dev-seed-equivalent
path (`CellStore::stage_text` directly for Tauri; `devSeedPasteboard`
over the C ABI for Swift) rather than wiring the real system pasteboard
for ingest — that's issue #4's scope, not this spike's, and doing it
identically in both keeps the comparison fair.

(Update, issue #4: the C-ABI/Swift path's real ingest has since landed —
`companion_new` now binds `NSPasteboard.general` and the core reads the
real clipboard itself, verified end to end. The Tauri arm still stages
directly; it links `companion-pasteboard` and could swap the same way.
This is spike-completeness, not a selection criterion — the panel-
semantics/memory/CPU comparison below is unchanged.)

Issue #4 defines the hardware session that also covers VoiceOver
operability. This ADR's Decision is **not being set by this spike alone**
— that determination belongs to issue #4, per explicit instruction. What
follows is the spike's evidence.

## Measurements

Both verified non-invasively (no screen recording / Accessibility
automation available in this environment — synthetic Apple Events failed
with `-1743 Not authorized to send Apple events`, and a screen-recording
permission prompt was declined): `lsappinfo` polled every 0.5s while the
panel was shown via a `COMPANION_AUTOSHOW=1` env-var testing hook,
confirming the frontmost app never changed; `footprint`/`top` for
resident memory and idle CPU.

| | swift-panel | tauri-panel |
|---|---|---|
| Process model | single AppKit process | main process + 3 WebKit XPC helpers (Networking, GPU, WebContent) |
| Resident memory, idle, 0 cells | 22 MB | 61.6 MB total (26 MB main + 13/16/6.8 MB helpers) |
| Idle CPU | 0.0% | 0.0% across all 4 processes |
| Frontmost app changes when shown? | No (confirmed) | No (confirmed) |
| `sharingType = .none` (capture exclusion) | yes | yes |
| Drag-receiving path wired | SwiftUI `.onDrop(of: [.plainText])` | WebKit/HTML5 DnD (`dragover`/`drop`, `dataTransfer.getData('text/plain')`) → `invoke('receive_drop')` |
| Live external-drag test performed | no (same tooling gap as above) | no (same tooling gap as above) |

docs/spec/05's frugality budget is **< 25 MB idle w/5 cells** for a
native shell and **< 60 MB** for Tauri. Both numbers above are measured
at **0 cells** — before any cell UI, list rendering, or additional DOM
state — so neither is a true test of the 5-cell target yet: swift-panel
is at 22/25 MB (88% of budget), tauri-panel at 61.6/60 MB (103% —
already over, before cells exist). Five small text cells add only
kilobytes of state either way, so the 5-cell number itself isn't what
tips tauri-panel over; its baseline process cost (4 OS processes vs. 1)
already consumes the whole budget by itself. Both need the 5-cell case
measured for real (issue #4) rather than assumed, but tauri-panel starts
that measurement already past its ceiling and swift-panel does not.

## Findings

- **Non-activating panel is not free in Tauri.** `WebviewWindow::show()`
  / `set_visible(true)` unconditionally calls AppKit's
  `makeKeyAndOrderFront` (confirmed in `tao`'s macOS backend,
  `platform_impl/macos/window.rs::set_visible`), regardless of the
  window's `focused` construction attribute. Tauri's own show/hide API
  is fundamentally incompatible with non-activating semantics and had to
  be bypassed entirely: `spikes/tauri-panel/src/panel.rs` drives the raw
  `NSWindow` directly through objc2 (`orderFrontRegardless()` /
  `orderOut()`, `styleMask |= NonactivatingPanel`, obtained via
  `WebviewWindow::ns_window()`). In swift-panel, this is the intended,
  first-class AppKit primitive (`NSPanel` + `orderFrontRegardless()`) —
  no side door needed. This is a genuine asymmetry, not a cosmetic one.
- **Tauri's native drag events are file-paths-only.** `DragDropEvent`
  (`Enter`/`Over`/`Drop`/`Leave`) carries `paths: Vec<PathBuf>` — no
  arbitrary-text drag payload. An OS-level text drag (e.g. dragging
  selected text from another app) cannot be captured at the Rust level;
  it has to be handled in the WebKit/HTML5 DnD layer instead
  (`ui/index.html`'s JS). This works, but moves a load-bearing behavior
  into JS and out of the Rust core's direct control — an added layer
  swift-panel's native `.onDrop` doesn't have.
- **Integration asymmetry cuts the other way.** tauri-panel links
  `companion-core` and `companion-pasteboard` directly as path
  dependencies — no C-ABI needed, since the shell is already Rust.
  swift-panel must cross the `companion-ffi` C-ABI seam (opaque handles,
  non-secret JSON) because Swift is not Rust. Less surface area to keep
  correct in tauri-panel, at the cost of the drag/focus workarounds
  above.

## Decision

**Swift/AppKit shell over the Rust core**, crossing the C-ABI seam in
`crates/ffi` (mechanism: ADR-0003). Decided 2026-07-13 on the spike
evidence above: swift-panel meets every non-activating/drag target with
first-class AppKit APIs and no workarounds, at 88% of its idle-memory
budget before cells exist; tauri-panel reaches the same functional bar
only by bypassing Tauri's own visibility API (`makeKeyAndOrderFront` in
tao) and moving drag handling into WebKit JS, and is already at 103% of
its idle-memory budget on process baseline alone. Tauri's one advantage
— no C-ABI seam — does not outweigh two load-bearing behaviors living in
workarounds.

Interaction-model revision C (docs/spec/04) replaces the edge-docked
panel with a real movable, resizable, non-activating window plus
bottom-edge tabs. Every finding above applies at least as strongly to
that surface, so rev C strengthens rather than reopens this decision.

The VoiceOver hardware runbook (docs/qa/hardware-verification.md, section
B) remains open as *verification* of the native-a11y premise, not as a
gate: its failure modes are eject triggers below, not blockers to
proceeding.

## Consequences

- `spikes/swift-panel` graduates to `shell/` (the spikes/README
  contract); `spikes/tauri-panel` is retired with the measurements
  preserved here.
- The C-ABI seam (`crates/ffi`, opaque handles, non-secret JSON) is now
  a permanent, load-bearing boundary — and the natural enforcement point
  for the boundary law (sealed bytes never cross into Swift).
- Shell-side work is Swift/SwiftUI/AppKit; the Rust workspace stays free
  of shell concerns. CI needs a macOS lane that builds the xcframework
  and runs `swift build && swift test`.
- The frugality budget for the shell is the native one: < 25 MB idle
  with 5 cells, near-zero idle CPU. 22 MB at 0 cells is the recorded
  baseline to regress against.

## Eject triggers

- VoiceOver operability (runbook section B) fails in a way native
  AppKit APIs cannot reach — this falsifies the premise the decision
  rests on and reopens it outright.
- The 5-cell (or rev-C 9-sheet) resident-memory measurement lands
  materially over the 25 MB native budget and cannot be brought back.
- Rev C's window semantics (movable, resizable, non-activating,
  tabbed) prove unreachable with `NSPanel`/AppKit primitives.
- The C-ABI seam forces a boundary-law breach — any change that needs
  sealed bytes on the Swift side is evidence the seam is misdrawn, and
  two of those is evidence the shell choice is.
