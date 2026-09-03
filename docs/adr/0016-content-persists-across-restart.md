---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0016: Staged content persists across restart

- **Status:** accepted
- **Date:** 2026-08-20
- **Supersedes in part:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md), specifically its boot-session lifetime and staged-content monotonic-aging rules.
- **Depends on:** [ADR-0017](0017-durable-tabs-expiring-pages.md) for the durable Tab/expiring Page object graph shipped in the same format break.

## Context

Binding staged content to the boot session caused unexpired work to disappear
after restart or update, even though the selected TTL could be seven days. The
implementation also did not consistently rotate both key halves at a boot
boundary, so the usability cost did not buy the security claim the prior design
made.

The decision must preserve unexpired content through normal process and machine
lifecycle events, never overwrite a snapshot that failed to restore, and never
allow restore to increase a page's remaining life.

The implementation chronology and detailed evidence are preserved in
[the persistence decision background](../plans/trustworthy-persistence-decision-background.md).
Numbered sections of this ADR cited elsewhere in the tree, such as "ADR-0016
section 3" or "section 4", now live in that persistence decision background
rather than in this record.
Execution status belongs in the [trustworthy persistence plan](../plans/trustworthy-persistence.md),
and coverage belongs in the [recovery matrix](../qa/recovery-matrix.md).

## Decision

Unexpired staged content survives ordinary process termination, crash, force
termination, logout, restart, shutdown, and compatible app updates. A page's TTL
is the only mechanism that destroys staged content without an explicit user
request.

Remove the boot-session bound. Keep both content-key halves durable across
restarts: one behind the Keychain ACL and one in the app-support state directory.
Rotate them when no tab holds a page and when the user explicitly clears state.
If tabs remain after pages expire, rotate and reseal the tab metadata; remove the
state file only when no tabs remain.

Use two clocks. A sleep-inclusive monotonic clock measures intervals observed by
a running process. On restore, wall time measures only the unobserved gap since
the last sealed write. Persist remaining life and subtract the non-negative gap,
clamped to the tab's rung and hold ceiling. Restore may shorten or preserve life,
never extend it.

A failed restore withholds the save licence and leaves the prior file untouched.
The user may explicitly discard unreadable state to regain the licence. Do not
keep a last-known-good ciphertext generation.

Accept one deliberate, non-migrating format break for this change and ADR-0017.
Known superseded formats are securely discarded so they do not leave an install
permanently unable to save; unknown or damaged formats continue to fail closed.

## Consequences

- Restart and system update no longer discard unexpired work.
- Crash and force termination can still lose mutations inside the accepted
  two-second write window; refused writes can extend that window and must remain
  visible to the user.
- Both key halves persist across boots. Crypto-erasure now completes expiry,
  emptying, or explicit clear; reboot alone no longer provides it.
- A copied ciphertext plus both copied halves can remain decryptable after the
  live app rotates its copies. APFS snapshots and rollback of an older authentic
  state file remain accepted residual exposures.
- A system clock moved backward across a restart can freeze aging for that gap,
  but restore still grants no additional life beyond what the file carried.
- Restore refusal favors preservation over availability: the app remains usable,
  but persistence stays disabled until the user clears the unreadable state.
- Existing staged content and ledger history were lost once at the format break.

## Eject triggers

- A threat model requires scheduled crypto-erasure sooner than the selected TTL.
- The TTL ceiling rises above seven days, repricing durable key and ciphertext
  exposure.
- A valid authenticated snapshot is observed being rejected by the core; that
  reopens the decision against a last-known-good generation.
- Measurements show the accepted write window causing material user data loss.
- A practical anti-rollback mechanism becomes available without a Keychain write
  on every save.

## Decision history

- **2026-08-22:** The envelope, key placement, clock, disposal, rotation, and
  hardware-procedure work landed across PRs #60 and #62.
- **2026-08-23:** Remaining-life persistence was retained instead of adding a
  `drained_ms` field; the same never-extend invariant is enforced by subtraction
  and clamping.
- **2026-09-02:** The record was split into this ADR and the linked persistence
  decision background, which now carries the numbered sections other documents
  cite.
