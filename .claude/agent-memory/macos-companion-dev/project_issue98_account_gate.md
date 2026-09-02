---
name: issue98-account-gate
description: ADR-0027 settles sync account auth; the gate is seven named tokens the core reports, and the three server side facts are settled: portless loopback registration, a server owned idle window, one scope named sync
metadata:
  type: project
---

Issue #98 landed on branch `feature/98-account-auth` (pushed 2026-09-01, PR #141) as ADR-0027, `docs/adr/0027-account-auth-gates-the-sync-channel.md`, accepted 2026-09-01 once the maintainer tested the three server side facts.

**Most of #98's client half already existed** before the ADR: PRs #119 and #121 built the PKCE ceremony, loopback listener, `TokenKeeper`, `BearerAuth` and the driver, spec first in `docs/spec/feature/sync/account-auth.md`. The ADR promotes that spec to a decision. Audit before designing in this area: specs here are sometimes written and built from ahead of the ADR that governs them.

**The gate vocabulary is fixed and #102 must reuse it.** Seven tokens the core reports (`gate` in the sync status JSON, and `companion_sync_gate`): `off`, `signed_out`, `signing_in`, `refused`, `unreachable`, `ready`, `attached`. `refused` and `signed_out` are deliberately different facts with the same posture, and the fault is in memory only, so a relaunch after a refusal reads `signed_out`. Falling behind a key rotation is *not* a gate state; it is ADR-0021 amendment 1's axis and stays Swift side as `Trouble.behind`.

**Why:** the shell used to infer the account's standing from refusal strings, an inference that can disagree with the core.

**How to apply:** when building #102's Settings surface, switch on `SyncStatus.gate` and `SyncController.reconciled(trouble:gate:)`; do not reintroduce string sniffing. Do not add a durable record of *why* a token is gone.

**Three server side facts, tested by the maintainer against rodauth-oauth on 2026-09-01 and recorded in the ADR:**

1. RFC 8252 §7.3 any port loopback holds only when the client is registered with a portless redirect (`http://127.0.0.1/<path>`); a registration carrying a port rejects every other port. Register portless, never `localhost`.
2. Refresh rotation is on and a stale token is rejected, but a replay does not revoke the family, and the configured expiry is a sliding idle window from the last refresh with no absolute cap. The client adds no expiry of its own; only `invalid_grant` means the grant is dead.
3. The application registration is the only scope ceiling, several scopes on one endpoint are an OR, and an empty scope token is refused at every scoped endpoint. The client sends `scope=sync` explicitly and the registration holds nothing else.

Related: [[relay-hosting-and-auth-decision]], [[sync-relay-design-direction]].
