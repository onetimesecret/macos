---
name: adr0018-gated-seams
description: ADR-0018 test-util gate implementation realities, SwiftPM does not dead-strip and nm cannot read the thin-LTO .a
metadata:
  type: project
---

ADR-0018 landed on refactor/53-pagemodel-seams: `companion_new_ephemeral` sits behind companion-ffi's off-by-default `test-util` feature; `scripts/build-core.sh --test-util` builds the dev xcframework and stamps the feature set in `bindings/CompanionCore.features` so `--if-stale` distinguishes dev from release; `package-app.sh` release path fails if the linked binary exports the seam.

**Why the Swift reference had to move:** SwiftPM does not pass `-dead_strip`, so ANY reference to a gated C symbol anywhere in CompanionKit breaks the release app link (undefined `_companion_new_ephemeral`), not just `swift test`. `ephemeral(tag:)` therefore lives as a `CompanionClient` extension in `Tests/CompanionKitTests/EphemeralClient.swift` (test target depends on CompanionCore directly; `init(adopting:)` went private to internal for it).

**nm pitfall:** the xcframework's `libcompanion_ffi.a` members are thin-LTO bitcode (`lto = "thin"` in the workspace profile) that Xcode's nm cannot parse ("Unknown attribute kind" per member). Verify exports on a linked Mach-O instead: the cdylib `target/<triple>/release/libcompanion_ffi.dylib`, the app binary, or the test bundle.

**How to apply:** any future gated seam repeats this whole shape, gate the Rust export AND keep every Swift reference in a test target, never in CompanionKit or an executable target. See [[issue53-pagemodel-seams]].
