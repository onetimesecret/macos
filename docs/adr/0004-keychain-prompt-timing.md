---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0004: Keychain prompt timing — presence is not readability

- **Status:** accepted
- **Date:** 2026-07-13

## Context

The API token lives in the macOS Keychain (docs/spec/05, credential
storage) behind an ACL: the first read from a given binary provokes the
system confirmation prompt. The shell renders Settings from
`companion_connection_json`, whose `has_token` field was computed as
`load(TOKEN_ACCOUNT).is_ok()` — a decrypting read. `WindowModel.init()`
calls it at launch, so the panel greeted the user with a Keychain prompt
before they had asked for anything.

The constraint is legibility of intent: a security prompt should appear
at the moment the user can attribute it to something they did. "The app
started" is not that moment. "I concealed a draft into a link" is.

## Decision

The Keychain ACL prompt is allowed to appear only when a secret is
actually used, a conceal reading the token, never for a presence
check. Status surfaces (launch, Settings) may ask *whether* a token is
stored, and that question must be answerable without decrypting.

`CredentialStore` gains `exists(account) -> Result<bool>` to carry the
policy: on macOS an attributes-only Keychain query (no `load_data`), which
matches the item without asking the Keychain to decrypt it and so stays
below the ACL prompt. `has_token` in the connection JSON means "a token
is stored", not "we can read it right now".

## Consequences

- No prompt at launch or when opening Settings; the prompt lands on the
  conceal that spends the token, where the user can name the cause.
- `exists()` and `load().is_ok()` deliberately diverge: `exists()`
  returns `true` for an item the process is not (yet) authorized to
  decrypt. Anyone "simplifying" `exists()` back into a `load` reverts
  this decision by accident — the trait doc, the FFI rustdoc, and the C
  header all state the semantics so the divergence is contract, not
  quirk.
- `has_token: true` no longer promises the next read will succeed; a
  conceal can still hit a denied or failed read and must surface that
  itself.
- A backend error in the presence check degrades to `has_token: false`
  (Settings must never wedge on the Keychain) — a broken Keychain is
  briefly indistinguishable from "no token".
- Per the repo convention (crates/credentials `tests`), the real-Keychain
  path — including that the attributes-only query truly stays below the
  prompt — is validated on-device, not in CI; CI's platform lane only
  compiles it.

## Eject triggers

- A status surface comes to need *readability*, not presence — e.g.
  detecting a revoked-but-still-stored token at launch — collapsing the
  distinction this ADR rests on.
- A macOS release or `security-framework` change makes attributes-only
  queries trip the ACL prompt anyway, observed as a prompt at launch on
  a hardware session.
- A credential backend appears (Phase 2 PASETO flows, docs/spec/05, or a
  non-Keychain store) where existence-without-decrypt is unavailable or
  no cheaper than a read.
