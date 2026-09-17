---
name: client-fakes-need-subclass
description: CompanionClient was final, so any test that must see a refused or counted core call needs it non-final plus a subclass in the test target
metadata:
  type: project
---

There is no protocol behind `CompanionClient`, and `PageModel.Seams.client`
takes the concrete class. Faking a core answer therefore means subclassing,
which meant dropping `final` from the class (2026-09-16, branch
chore/cleanup-tickets). The test subclass lives in
`shell/Tests/CompanionKitTests/EphemeralClient.swift` beside
`ephemeral(tag:)`, which was split so a subclass can take the same gated
handle.

**Why:** the core grants a close for any file it holds, so a refusal and a
call count are unreachable through the real client, and two correctness
fixes in the file close path survived mutation without them.

**How to apply:** when a fix in `PageModel` can only be observed as "the
core was asked once" or "the core said no", reach for a subclass of
`CompanionClient` rather than inventing a parallel fake or a new FFI seam.
Related: [[project_adr0018_gated_seams]], [[feedback_test_seams_are_mandatory]].
