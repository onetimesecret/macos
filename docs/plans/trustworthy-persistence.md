# Trustworthy persistence

**GitHub milestone:** [Trustworthy persistence](https://github.com/onetimesecret/macos/milestone/1)  
**Status:** Active  
**Source of execution status:** GitHub issues, not this document.

## Goal

A user can treat OnetimePad as a safe place to paste information: unexpired content is not silently lost, its persistence state is visible, and recovery failures do not destroy the last known good state.

The exact lifetime boundary remains a security decision. [ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md) currently specifies boot-session-bound staged content. Any change to persistence across restart must amend or supersede that decision before implementation.

## Completion criteria

- The supported lifecycle and recovery contract is documented in an ADR.
- Persistence writes occur without relying solely on clean termination.
- The user can see whether current state is saved or has failed to save.
- Restore failure cannot replace prior persisted state with empty state.
- Supported lifecycle and failure paths have automated tests or documented manual verification.

## Pass 1 — establish the contract

**Tracking:** [#44](https://github.com/onetimesecret/macos/issues/44)

Decide and document:

- Which events preserve unexpired content: clean quit, crash, force termination, macOS restart, app update, logout, and fast user switching.
- How the chosen security boundary, encrypted snapshot, and key availability interact.
- The loss window, if any, and its explicit tradeoff.
- Recovery behavior for unavailable keys and damaged snapshots.
- The conditions under which expiration or deliberate discard destroys content.

## Pass 2 — make data loss impossible to miss

**Tracking:** [#49](https://github.com/onetimesecret/macos/issues/49), [#46](https://github.com/onetimesecret/macos/issues/46)

- Surface a persistent, actionable restore-failure state.
- Repeat the warning before quit when the current session cannot be saved.
- Add `Cmd+S` as a supported force-save command once its action exists.
- Show non-content-bearing states: saving, saved, and save failed.

## Pass 3 — implement the chosen durability model

**Tracking:** [#47](https://github.com/onetimesecret/macos/issues/47)

- Persist encrypted snapshots on the agreed mutation schedule rather than only at termination.
- Preserve a last-known-good snapshot through failed restore or failed save paths.
- Apply TTL expiry consistently on restore and during a live session.
- Keep secret content out of status messages, logs, and long-lived metadata.

## Pass 4 — verify the recovery matrix

**Tracking:** [#48](https://github.com/onetimesecret/macos/issues/48)

Verify the contract for:

1. Clean quit.
2. Crash or force termination.
3. macOS restart.
4. App update or development rebuild.
5. Damaged snapshot.
6. Unavailable encryption key.
7. TTL expiration.

Each supported case needs an automated regression test where practical. Otherwise, record a repeatable manual procedure, rationale, and owner in its GitHub issue.

## Dogfood loop

Keep new observations in [ABERRATIONS.md](../dogfood/ABERRATIONS.md). Promote each one to an ADR, GitHub issue, plan, or [DOGFOOD.md](../dogfood/DOGFOOD.md) guidance once it is understood. Link the destination from the original observation.
