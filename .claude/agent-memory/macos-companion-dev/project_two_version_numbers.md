---
name: two-version-numbers
description: Since issue #89 the app's marketing version lives in shell/OnetimePad-Info.plist and is bumped by hand for user visible work; crates/ffi keeps its own crate version for the seam
metadata:
  type: project
---

The app ships two independent version numbers. `CFBundleShortVersionString`
in `shell/OnetimePad-Info.plist` is the marketing version (0.13.0 as of
milestone 2), edited by hand when work a user can touch lands.
`crates/ffi/Cargo.toml` keeps the seam's crate version and still answers
`companion_version()`. `scripts/package-app.sh` reads the plist, refuses
the `0.0.0` placeholder, and stamps `CFBundleVersion` as short version
plus short SHA.

**Why:** the packaged version used to come from `crates/ffi`, so milestone 2
(PRs #80 to #88) changed every keystroke a user makes and would not have
moved the number, while two invisible seam changes moved it twice.

**How to apply:** when landing user visible work, bump the plist as well as
any crate bump, unasked, the way [[bump-version-with-features]] describes
for `crates/ffi`. Expect the tray line ("build X, core Y") and About to show
two different numbers; that is health, not a stale xcframework.
