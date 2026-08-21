---
name: issue53-pagemodel-seams
description: Issue #53 persistence seams landed on refactor/53-pagemodel-seams, verified green 2026-08-20, uncommitted
metadata:
  type: project
---

Issue #53 is implemented on branch `refactor/53-pagemodel-seams` (3 commits, plus a follow-up refactor left as unstaged edits per task constraint: no commits). All verification commands pass (Swift 200 tests green 2026-08-20).

**Why:** the Swift persistence lifecycle ran unexercised in CI; the seams are test-only injections whose defaults resolve to the exact shipping values.

**How to apply:** the seams now live in `PageModel.Seams`, a nested public struct with three optional members (`stateDirectory`, `client`, `saveDebounce`), nil meaning shipping value; the init is `init(formFactor:defaults:seams: Seams = Seams())`. Making `saveDebounce` optional and resolving `?? Self.saveDebounce` inside the init body let the static return to private (Swift refuses private symbols in public default arguments, but the rule does not reach function bodies). The credential seam is `companion_new_ephemeral(tag)` (companion-ffi 0.10.0): in-memory credential store, memoized per tag so two handles share keys like two launches share a Keychain; Swift side is `CompanionClient.ephemeral(tag:)`. Adding any FFI export requires rerunning `scripts/build-core.sh` before `swift build` sees it. Integration tests live in `shell/Tests/CompanionKitTests/PersistenceRoundTripTests.swift`; note the fixture-method pattern there (setUp overrides are nonisolated on a @MainActor XCTestCase).
