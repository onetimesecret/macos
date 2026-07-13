# swift-panel — the Swift/AppKit arm of the ADR-0002 spike

A menu-bar panel showing live SleeperCells, driven end-to-end by the
Rust core through the C-ABI seam (`crates/ffi`). Harvested from the
parallel skeleton prototype (PR #5) and rebound to this repository's
crates. **A spike, not the shell**: it lives in `spikes/`, outside the
workspace and outside CI, and graduates to `shell/` only if ADR-0002
lands on Swift.

## What it exists to answer (issue #4)

Run this under **VoiceOver on real hardware** and measure what ADR-0002
needs: is one live cell — countdown draining, TTL cyclable, copy-out and
dismiss from the keyboard — fully operable and legible, with the panel
never stealing focus? Note memory footprint and idle wakeups against the
frugality budget (docs/spec/05) while it sits open and closed.

## Build (macOS only)

```sh
./scripts/build-core.sh --dev-scaffolding   # cargo → universal libcompanion_ffi.a → bindings/CompanionCore.xcframework
cd spikes/swift-panel
swift build && swift test
swift run CompanionPanel
```

The `--dev-scaffolding` flag compiles in `companion_dev_seed_pasteboard`
(off by default in the seam) — the spike needs it to stage a sample cell
until the `NSPasteboard` adapter lands.

## Honest status

- Written and reviewed on Linux; it has **not** been compiled by a Swift
  toolchain yet. Expect first-build friction; fix forward, it's a spike.
- The core still reads an **in-process pasteboard stand-in** — the real
  `NSPasteboard` adapter is issue #3's work. Until it lands, the
  "stage a sample cell (dev)" footer and
  `companion_dev_seed_pasteboard` exist so a live cell can be staged;
  both are deleted with the stand-in.
- Expiry is scheduled (one timer at the core's next deadline), and the
  1 Hz countdown redraw runs only while the panel is visible — keep it
  that way; the frugality budget is a review bar, not a wish.

## The boundary law (adopted from PR #5)

Plaintext secret bytes live only in the Rust core. This package sees
ids, masked recognition lines, and booleans; ingest *and* copy-out
happen inside the core. If a change here needs the bytes, the change is
wrong.
