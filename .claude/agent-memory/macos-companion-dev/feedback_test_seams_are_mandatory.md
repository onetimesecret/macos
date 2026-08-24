---
name: feedback-test-seams-are-mandatory
description: Swift tests must always build PageModel with injected Seams (temp stateDirectory plus ephemeral client); a default-seam model erased the installed app's real ledger.sealed
metadata:
  type: feedback
---

Every Swift test that constructs `PageModel` must pass
`seams: .init(stateDirectory: <temp dir>, client: .ephemeral(tag:))`, even when
the test believes it never loads or writes state.

**Why:** on 2026-08-23 a coverage suite (`MutationArmingTests`) built the model
on shipping seams because its only file interaction was thought to be gated by
the save licence. It was not: `clearLedger` calls `persistErase` on a path with
no licence in the way, so `swift test` overwrote, truncated and unlinked the
installed backdrop's real ledger.sealed under
`Application Support/com.onetimesecret.companion.backdrop.noindex/`, the one
file ADR-0012 says only the user's own Clear may end. The data was
unrecoverable. The default client is also scoped to the shipping Keychain
service.

**How to apply:** when reviewing or writing any test that touches a model,
check the construction first, before the assertions. "This test only reads" is
not a reason to skip the seams: erase and quit-flush paths bypass the licence
guard. `LedgerAppendArmingTests`, `CaptureOptOutTests`, `DocumentOpsTests` and
`WrapTests` still use default seams (no erase path today, so not destructive,
but they do reach the shipping Keychain service). Related:
[[project_adr0018_gated_seams]], [[project_issue53_pagemodel_seams]].
