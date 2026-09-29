---
name: issue207-test-waits
description: Issue #207 (2026-09-28) retired every fixed-interval RunLoop spin in shell/Tests; which waits are order based, which are published state, and the four negative windows that must stay clock based
metadata:
  type: project
---

Issue #207 replaced the eight per-file `spinRunLoop`/`pump` helpers. Three wait shapes now exist in the test targets: `drainMainQueue` (order on the main queue), `waitUntil(publisher) { }` in `CompanionKitTests/StateWait.swift` (an expectation fulfilled by a `@Published` change, used for the save debounce via `$saveStatus`, conceal round trips via `$concealDraft`, and detection results via `$fileRenderSuggestions`), and `letElapse(_:)` for the four negative debounce windows (PersistenceRoundTrip 1.2 s and 0.3 s, RestoreFailure 0.3 s and 0.4 s).

**Why:** a negative claim ("nothing wrote inside the window") cannot be waited on by order; the window has to pass. `letElapse` measures it with an `asyncAfter` block on the main queue (the PasteboardOfferTests precedent) so the window's own hops land before the assertion, but it is still a fixed window by necessity. The detection tests in FileDocumentTests use `worker.sync {}` then a drain, which only works because the service's `workerQueue` is injectable and serial.

**How to apply:** never reintroduce `RunLoop.main.run(until:)` in a test; pick the shape by what the waited-for hop is. `ListAutomationTests.settleUndo`'s `RunLoop.current.run(until: Date())` is a zero-duration turn that closes NSUndoManager's event group, not a wait, and the issue's list of it as a "pump helper" was wrong; leave it. OnetimePadTests has its own copy of `drainMainQueue` because test targets cannot share helpers.
