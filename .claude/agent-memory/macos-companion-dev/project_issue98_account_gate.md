---
name: issue98-account-gate
description: ADR-0027 settles sync account auth; the gate is seven named tokens the core reports, and three server side facts await maintainer ratification
metadata:
  type: project
---

Issue #98 landed on branch `feature/98-account-auth` (pushed 2026-09-01, no PR opened) as ADR-0027, `docs/adr/0027-account-auth-gates-the-sync-channel.md`, status proposed.

**Most of #98's client half already existed** before the ADR: PRs #119 and #121 built the PKCE ceremony, loopback listener, `TokenKeeper`, `BearerAuth` and the driver, spec first in `docs/spec/feature/sync/account-auth.md`. The ADR promotes that spec to a decision. Audit before designing in this area: specs here are sometimes written and built from ahead of the ADR that governs them.

**The gate vocabulary is fixed and #102 must reuse it.** Seven tokens the core reports (`gate` in the sync status JSON, and `companion_sync_gate`): `off`, `signed_out`, `signing_in`, `refused`, `unreachable`, `ready`, `attached`. `refused` and `signed_out` are deliberately different facts with the same posture, and the fault is in memory only, so a relaunch after a refusal reads `signed_out`. Falling behind a key rotation is *not* a gate state; it is ADR-0021 amendment 1's axis and stays Swift side as `Trouble.behind`.

**Why:** the shell used to infer the account's standing from refusal strings, an inference that can disagree with the core.

**How to apply:** when building #102's Settings surface, switch on `SyncStatus.gate` and `SyncController.reconciled(trouble:gate:)`; do not reintroduce string sniffing. Do not add a durable record of *why* a token is gone.

**Three items flagged for maintainer ratification, all server side facts:**

1. Whether rodauth-oauth honours RFC 8252 §7.3 (any port for a loopback redirect). If it matches the registered port strictly, `AuthCeremony::begin` must bind from a fixed registered list.
2. The refresh policy and idle window the server sets. The client now tolerates both rotation and no rotation.
3. The scope the client should request. It currently requests none, so the server's default applies; a leaked sync token is therefore as wide as the account until a relay scope exists server side.

Related: [[relay-hosting-and-auth-decision]], [[sync-relay-design-direction]].
