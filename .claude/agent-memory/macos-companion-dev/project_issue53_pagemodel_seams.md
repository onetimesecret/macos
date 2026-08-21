---
name: issue53-pagemodel-seams
description: Issue #53 persistence seams landed on refactor/53-pagemodel-seams, verified green 2026-08-20, uncommitted
metadata:
  type: project
---

Issue #53 is implemented on branch `refactor/53-pagemodel-seams` as unstaged working-tree edits (per task constraint: no commits). All five verification commands pass (Rust 12 suites ok, Swift 200 tests).

**Why:** the Swift persistence lifecycle ran unexercised in CI; the seams are test-only injections whose defaults resolve to the exact shipping values.

**How to apply:** `PageModel.init` gained `stateDirectory: URL? = nil`, `client: CompanionClient? = nil`, `saveDebounce: TimeInterval = PageModel.saveDebounce` (that static had to become public: Swift refuses private symbols in public default arguments). The credential seam is `companion_new_ephemeral(tag)` (companion-ffi 0.10.0): in-memory credential store, memoized per tag so two handles share keys like two launches share a Keychain; Swift side is `CompanionClient.ephemeral(tag:)`. Adding any FFI export requires rerunning `scripts/build-core.sh` before `swift build` sees it. Integration tests live in `shell/Tests/CompanionKitTests/PersistenceRoundTripTests.swift`; note the fixture-method pattern there (setUp overrides are nonisolated on a @MainActor XCTestCase).
