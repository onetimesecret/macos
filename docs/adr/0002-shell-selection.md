# ADR-0002: Shell selection

- **Status:** proposed — spike complete, decision deferred
- **Date:** 2026-07-08

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

Not yet made — reserved for issue #4's hardware session, per explicit
instruction that this spike does not decide it unilaterally. The
evidence above: swift-panel meets every non-activating/drag target
measured here with native APIs and no workarounds, and sits at 88% of
its idle-memory budget before cells exist; tauri-panel meets the same
functional bar but only by bypassing Tauri's own visibility API and
moving drag handling into JS, and is already at 103% of its idle-memory
budget before cells exist. Both need the 5-cell case actually measured,
not assumed, before either number is final.

## Consequences

—

## Eject triggers

—
