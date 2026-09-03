# Trustworthy persistence

**GitHub milestone:** [Trustworthy persistence](https://github.com/onetimesecret/macos/milestone/1)  
**Status:** Active  
**Source of execution status:** GitHub issues, not this document.

## Goal

A user can treat OnetimePad as a safe place to paste information: unexpired content is not silently lost, its persistence state is visible, and recovery failures do not destroy prior persisted state.

The lifetime boundary is decided. [ADR-0016](../adr/0016-content-persists-across-restart.md) supersedes the boot-session bound in [ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md): staged content survives every ordinary process and machine lifecycle event, and its TTL is the only mechanism that destroys it. [ADR-0017](../adr/0017-durable-tabs-expiring-pages.md) splits the durable Tab from the expiring Page and rides the same one-time snapshot format break, so users pay that loss once rather than twice.

## Completion criteria

- The supported lifecycle and recovery contract is documented in an ADR.
- Persistence writes occur without relying solely on clean termination.
- The user can see whether current state is saved or has failed to save.
- Restore failure cannot replace prior persisted state with empty state.
- Supported lifecycle and failure paths have automated tests or documented manual verification.

## Pass 1: establish the contract (complete)

**Tracking:** [#44](https://github.com/onetimesecret/macos/issues/44)

Delivered as [ADR-0016](../adr/0016-content-persists-across-restart.md) and [ADR-0017](../adr/0017-durable-tabs-expiring-pages.md). ADR-0016 section 1 holds the lifecycle table, section 2 the loss window, section 7 the recovery guarantees, and section 9 the migration break.

Decided and documented:

- Which events preserve unexpired content: clean quit, crash, force termination, macOS restart, app update, logout, and fast user switching.
- How the chosen security boundary, encrypted snapshot, and key availability interact.
- The loss window, if any, and its explicit tradeoff.
- Recovery behavior for unavailable keys and damaged snapshots.
- The conditions under which expiration or deliberate discard destroys content.

## Pass 2: make data loss impossible to miss (complete)

**Tracking:** [#49](https://github.com/onetimesecret/macos/issues/49), [#46](https://github.com/onetimesecret/macos/issues/46)

- Surface a persistent, actionable restore-failure state.
- Repeat the warning before quit when the current session cannot be saved.
- Add `Cmd+S` as a supported force-save command once its action exists.
- Show non-content-bearing states: saving, saved, and save failed.

## Pass 3: implement the chosen durability model

**Tracking:** [#47](https://github.com/onetimesecret/macos/issues/47), [#51](https://github.com/onetimesecret/macos/issues/51), [#52](https://github.com/onetimesecret/macos/issues/52), [#54](https://github.com/onetimesecret/macos/issues/54)

- Keep the mutation-driven write schedule and make every mutation site reach it. ADR-0016 section 2 settles the debounce window at 2 seconds from the first mutation of a burst and does not move the number; the work is the sites that never arm a write.
- A failed restore never replaces prior persisted state with empty state, through the withheld save licence. ADR-0016 section 7 decides against a last-known-good generation and requires the content-side Clear instead.
- Age pages on two clocks per ADR-0016 section 4: monotonic within a session, the wall-clock gap between the last save and the next restore across one. The `drained_ms` field that section first specified was not built, and section 4's 2026-08-23 amendment records why: the page record still carries the span of life that is left, which no restore lengthens, bounded on the way in by the tab's rung and by the ceiling the pause gesture sets.
- Keep secret content out of status messages, logs, and long-lived metadata. ADR-0017 extends that to the durable Tab, which carries a name the user typed or no name at all.
- Take the format break once. ADR-0016 section 9 bumps the envelope magic and ADR-0017 bumps the snapshot magic in the same break, and a known superseded magic is erased with the licence granted rather than left as a permanent refusal.
- Close #54 in the same break: the persisted records are positional, so a trailing field forces a version bump that refuses every existing file (`crates/core/src/persist.rs`). Length-prefix all three repeated records, the page record, the per-block materialized record and the ledger record, and define a skip-unknown-tail rule, so the next added field costs no break. This is what releases ADR-0013's interaction count from the break entirely. The envelope stays strict.
- Close #51: a transient `sysctl` failure must not destroy the live session's staged content. ADR-0016 section 6 deletes the `BootMismatch` arm that makes it reachable.
- Close #52: clipboard copy-out must arm a write, so its `sent` record cannot be lost.

## Pass 4: verify the recovery matrix

**Tracking:** [#48](https://github.com/onetimesecret/macos/issues/48), [#53](https://github.com/onetimesecret/macos/issues/53)

#53 landed, so cases 1 and 5 are reachable from a test: `PageModel.Seams` injects the state directory, the client and the save debounce (`shell/Sources/CompanionKit/PageModel.swift`), and `CompanionClient.ephemeral(tag:)` gives the suite an in-process credential store instead of the login Keychain. ADR-0016 section 10 maps every case to the coverage it owes; [`docs/qa/recovery-matrix.md`](../qa/recovery-matrix.md) records the coverage each one has, the procedure that covers what CI cannot reach, and when that procedure last ran.

Verify the contract for:

1. Clean quit.
2. Crash or force termination.
3. macOS restart.
4. App update or development rebuild.
5. Damaged snapshot.
6. Unavailable encryption key.
7. TTL expiration.

Each supported case needs an automated regression test where practical. Otherwise, record a repeatable manual procedure, its rationale and its owner in `docs/qa/verification-procedures/`, and index it from the [recovery matrix](../qa/recovery-matrix.md). The GitHub issue tracks the work; the procedure and the matrix are where it is written down.

Some paths cannot be reached from CI at all. ADR-0016 section 10 requires hardware procedures under `docs/qa/verification-procedures/`, and all six exist: force termination, reboot, power loss, a re-signed bundle, a locked keychain, and the clock stepped back. Each names an owner and carries a dated Results table. Only `reboot.md` has a recorded run so far.

## Dogfood loop

Keep new observations in [ABERRATIONS.md](../dogfood/ABERRATIONS.md). Graduate each one to an ADR, GitHub issue, plan, or [DOGFOOD.md](../dogfood/DOGFOOD.md) guidance once it is understood. Link the destination from the original observation.
