# OTSCache — the Swift/SwiftUI shell

The Apple-only UI for OTS Cache. It links the Rust trust core through
`bindings/OtsCore.xcframework` and **holds no secret itself** (docs/01 §7): the
core reads the pasteboard, owns the bytes, and hands Swift only ids, non-secret
summaries, and share links.

Builds on **macOS only** (needs the Apple SDK and the generated xcframework).

## Build & test

```sh
scripts/build-core.sh                      # produce bindings/OtsCore.xcframework
cd apps/OTSCache && swift build && swift test
```

## What's here

- `Sources/OTSCache/OtsCoreClient.swift` — the safe wrapper over the C ABI in
  `crates/ots-ffi/include/ots_ffi.h`. Decodes non-secret summaries; never sees
  plaintext.
- `App.swift` — the `MenuBarExtra` resident presence and the view model.
- `PanelController.swift` — the edge-docked, **non-activating** `NSPanel` that
  never steals keyboard focus (docs/00 §5.4, §8).
- `Views/` — the panel and the SleeperCell, with the draining-ring countdown and
  its always-present text equivalent for VoiceOver (docs/00 §6.2, §8).

## Status

This is the vertical-slice scaffold (docs/01 §10 step 7). The riskiest screen —
one live SleeperCell driven by the core through the seam — is here to be
exercised under VoiceOver on real hardware, which is the go/no-go on the hybrid
architecture. The `NSPasteboard`-backed reader and the wired share button follow
in that spike.
