# spikes/

Disposable by construction, excluded from the Cargo workspace. Evidence
for ADR-0002 lives here so it is visibly not product code.

The two-way spike prototypes the make-or-break surface — a
non-activating, edge-docked panel that receives drags without stealing
focus — in both candidate stacks (macOS hardware required):

- `tauri-panel/` — Tauri 2.x, with `objc2` side-doors for NSPanel
  behaviour, `sharingType`, and pasteboard types.
- `swift-panel/` — Swift/AppKit shell over the same Rust core.

Score against docs/spec/05: panel semantics, resident memory, idle CPU
and wakeups, a11y (VoiceOver on the cell anatomy), and the
rendering-vs-residence discipline.
