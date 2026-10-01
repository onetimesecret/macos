---
name: swiftc-default-target-refused-by-launchservices
description: A bare swiftc under Xcode-beta on macOS 27.0 stamps minos 28.0; a bundle built that way will not launch through open (LaunchServices error -10825)
metadata:
  type: project
---

On this machine (macOS 27.0, Xcode-beta, SDK 26.0) a `swiftc` call with no `-target` produces a binary whose `LC_BUILD_VERSION` says `minos 28.0`. Seen 2026-09-30 with `vtool -show-build`.

**Why it matters:** a command line tool run from a shell starts anyway (dist/window-order-probe carries the same stamp and works), but an app bundle launched with `open` is refused: `_LSOpenURLsWithCompletionHandler() failed ... with error -10825`. The first sandbox probe runs failed exactly this way.

**How to apply:** any script that compiles a bundle meant to be launched through LaunchServices passes `-target "$(uname -m)-apple-macosx13.0"` (the shell package's floor, the same value scripts/verify-release-core.sh uses). Also give `open -a` an absolute path; a relative one is read as an application name and answers "Unable to find application named".

Related: [[project_bookmark_resolution_facts]]
