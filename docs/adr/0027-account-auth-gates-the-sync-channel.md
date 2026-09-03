---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0027: Account auth gates the sync channel

- **Status:** accepted
- **Date:** 2026-09-01
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md), which separates account admission from device trust.

## Context

The relay needs proof that a client belongs to an account, but that proof must
not grant access to Page content. The desktop app can sleep for days, must remain
fully useful while signed out or offline, and must not lose edits when auth fails
mid-session.

The complete flow, server requirements, response handling, and state-machine
contract belong in the [account-auth specification](../spec/feature/sync/account-auth.md).
Implementation-era analysis is preserved in the
[account-auth decision background](../spec/feature/sync/account-auth-decision-background.md).
Numbered sections of this ADR cited elsewhere in the tree, such as "ADR-0027
section 4", now live in that account-auth decision background rather than in
this record.

This decision leaves [ADR-0004](0004-keychain-prompt-timing.md)'s rule that key
access happens on use rather than at launch standing, and leaves standing
[ADR-0016](0016-content-persists-across-restart.md)'s `ThisDeviceOnly`
protection class: the refresh token takes the same class as every other secret
in that store.

## Decision

Use OAuth 2.0 authorization code with PKCE in the system browser. Return through
a one-shot loopback listener bound to `127.0.0.1` on an ephemeral port. Register
the redirect portlessly as `http://127.0.0.1/callback`, require `S256`, validate
`state`, and request the single `sync` scope explicitly. Do not use a client
secret, device authorization grant, custom URL scheme, embedded web view, or
pasted API token on macOS.

Keep the access token in memory only. Store the refresh token under its own
`sync-oauth-refresh` account in the `ThisDeviceOnly` key-material store, separate
from conceal credentials and the rotating content key. On relaunch, refresh
before the first attach.

Treat server refusal as the token-lifetime authority. On a relay `401`, refresh
once and retry once. Delete the refresh token and sign sync out only when the
token endpoint reports `invalid_grant`; transport failures, rate limits, other
OAuth errors, malformed responses, and server failures leave it in place. Accept
successful refresh responses that do not rotate the refresh token.

Expose one account-gate state: `off`, `signed_out`, `signing_in`, `refused`,
`unreachable`, `ready`, or `attached`. These states affect sync only. Device
pairing and rejoin status remain separate axes.

Advance a Page's export cursor permanently only after relay acknowledgement. If
the auth gate closes and the sync engine dissolves, rewind to the last
acknowledged cursor so queued but unsent edits are republished after re-entry.
Never rewind across a compaction boundary or silently discard unpublished work.

## Consequences

- Sign-in requires a browser and a brief loopback listener; the app never sees an
  account password.
- Waking after a relaunch costs one refresh request before attachment.
- A revoked or expired grant stops sync while the pad remains fully usable.
- The refresh token becomes a durable device-bound secret, independent of Page
  content and conceal credentials.
- Network failure does not invent a sign-out, and a refusal is not treated as
  evidence that refresh-token theft was contained.
- Server registration must remain portless and limited to the `sync` scope; those
  are operational requirements, not optional client preferences.
- Sync disabled remains indistinguishable from the app before sync existed.

## Eject triggers

- The authorization server cannot register a portless loopback redirect.
- Refresh tokens disappear or their idle lifetime becomes too short for an app
  that routinely sleeps for days or weeks.
- The relay stops accepting OTS-issued tokens and requires its own identity
  system.
- Relay endpoints require privileges that cannot safely share the single `sync`
  scope.
- Conceal and sync credentials are required to merge, reopening their independent
  lifecycle and Keychain-tier decisions.
- A user-relevant account condition cannot be represented by the seven gate
  states without inference from unrelated state.

## Decision history

- **2026-09-01:** Accepted after testing the portless loopback registration,
  refresh behavior, and scope behavior against a running `rodauth-oauth` server.
- **2026-09-02:** The record was split into this ADR and the linked account-auth
  decision background, which now carries the numbered sections other documents
  cite.
