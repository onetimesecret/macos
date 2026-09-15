---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0012: OTS macOS staging companion — framing, threat boundary, and persistence model

- **Status:** proposed
- **Date:** 2026-07-15
- **Supersedes in part:** [ADR-0007](0007-terminology.md), whose persistence
  model this record owns, and whose Decision 2 it restates in the narrower form
  recorded in that record's Amendment 2. Everything else in ADR-0007 stands.
- **Superseded in part by:** [ADR-0016](0016-content-persists-across-restart.md)
  and [ADR-0017](0017-durable-tabs-expiring-pages.md); see Supersession at
  the end of this file.

## Context

A macOS menu-bar companion for Onetime Secret that stages content in transition between an origin and a destination via a small, edge-docked window. The original pitch was "verifiably forgets."

"Verifiably forgets" is not deliverable on macOS as stated, and it mislabels the product's actual value.

Constraints that break the literal claim:

- No runtime proof of erasure. Pages are compressed and swapped. Under FileVault, swap is encrypted, so the honest claim is "encrypted under a key that dies at shutdown," not "gone." Rendered content lives in the window server and is exposed to screenshots, screen sharing, and screen recording.
- Swift `String` cannot be reliably zeroed: immutable, ARC-copied, backing store scattered.
- The system pasteboard is the existential risk. Copy/paste writes to `NSPasteboard` (system-wide, persistent, scraped by clipboard managers, synced off-device via Universal Clipboard). If content arrives by paste, the "forgets" claim is already false before staging begins.

The first implementation also revealed a persistence defect: the entire store was sealed in a single write at quit. `applicationWillTerminate` is not guaranteed (sudden termination at logout/shutdown, force quit, crash, power loss), so the design persisted exactly when nothing went wrong and lost everything in the cases persistence exists for. It also extended content lifetime indefinitely across OS restarts without acknowledging the disk artifact. Separately, the shipped ledger stored dead-page ink verbatim (`LedgerSegment::Ink`), plaintext head/tail excerpts in tombstones, and ink-derived titles — making the "ledger" an unbounded content archive under a long-lived key.

## Decision

### Framing (unchanged from original)

1. Reframe from "verifiable erasure" to **auditable discipline**: open source plus a reproducible pre-signature artifact. Codesigning timestamps and stapled notarization tickets make the shipped .app non-bit-identical, so the precise claim is: reproducible unsigned build with a published hash, plus instructions to verify the shipped binary's unsigned payload against it. Drop any language implying runtime attestation of erasure or bit-identical shipped binaries.
2. Reframe the product from a *store* to a **safer clipboard**: bounded lifetime, non-swappable while live, self-zeroing, never on the system pasteboard.
3. **Lead with the real win**: the secret never enters a browser (no form field, autofill, extension, page memory, or tab) and never touches the system clipboard.

### Persistence model

The store splits into two files with different keys, lifetimes, and write policies. The module that writes staged content to disk is the only code path that touches secret ciphertext, and it is small enough to audit in one sitting.

**Item identity.** Every sheet/chip gets a random 128-bit identifier (UUIDv4) at creation, minted in the Rust core. The sequential u64 counters may remain for internal ordering but never appear in the ledger or any persisted artifact. The UUID is stored plainly in ledger records — no digest, no salt: a random identifier is content-free by construction, which is simpler and strictly stronger than the previously specified salted digest (a digest over the shipped sequential counters would have been trivially enumerable).

**Staged content — bounded to the boot session.**

Key derivation: the content wrapping key is `HKDF(keychain_half, boot_half)`.

- `keychain_half`: random secret in the **data protection keychain** (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), ACL-bound to the signed app, lock-gated. Rotated (old item deleted, new generated) on first launch after a new boot session.
- `boot_half`: random secret generated at first launch after boot, stored only in the per-user temp directory (`_CS_DARWIN_USER_TEMP_DIR`, mode 0600), **under a filename derived from `HKDF(keychain_half, BOOT_HALF_NAME_SALT ‖ kern.bootsessionuuid)`**. Folding the session identity into the *name* is what makes the boot bind unconditional, and it is the correction to an earlier design in which rotation was the only mechanism.

Neither half alone unwraps content. **Crypto-erasure at reboot is the primary mechanism.** The original design rested on the temp directory being cleared at boot (observed empirically: on a test machine whose temp directory itself predated the boot by 90+ days, zero of 637 entries predated the current boot), but that is a consistent and undocumented heuristic, not a guarantee, and relying on it was a latent defect: rotation ran only from the load path's boot-mismatch arm, which is reachable only when a state file happens to be readable at launch. A user who emptied the store before shutdown erased that file, left both halves alive, and got a byte-identical content key in the next boot session. Deriving the boot half's *filename* from the session UUID removes the dependency entirely: a new boot session cannot find the previous session's half, so it mints a fresh one and derives an unrelated key, with no file needed to trigger it and no keychain access required. The name is an HKDF output keyed by the 32-byte keychain half, so it is one-way and discloses nothing.

The keychain half exists so that a same-session process running as the user, reading the 0600 temp file, still gets nothing without passing the keychain ACL. **Deterministic backstop (policy)**: the sealed record embeds `kern.bootsessionuuid`, which is opaque and stable for the whole boot session, unlike `kern.boottime`, which the kernel re-derives when the calendar clock steps and would therefore spuriously discard content mid-session. A mismatch at load discards the file and rotates the content key halves. Rotation never touches the ledger key. Where the session UUID cannot be read at all, the implementation fails **closed**, substituting a per-process value so the check reports a mismatch rather than silently passing: a backstop that fails open is not a backstop.

Note what this does and does not claim. The session-folded filename guarantees that *the app* can never re-derive a previous session's key. It does not guarantee the previous half's bytes are unreachable on disk if the temp directory was not cleared. An extracted keychain item is useless once its partner is gone, and the partner is gone when the directory was cleared or when rotation ran.

*Keychain availability (implementation constraint).* Two separate things get conflated here, so state them apart. Reaching the data protection keychain does not require *declaring* `keychain-access-groups`: any Team-ID-backed signing identity is granted the implicit `TEAMID.bundleid` group with no entitlement and no profile. Declaring the entitlement is restricted, however. It sits on AMFI's list, so a bundle that claims it must also embed a provisioning profile authorizing the group, or launchd refuses to spawn the app at all (amfid -413, "No matching profile found"). `scripts/build-app.sh` and `scripts/build-backdrop.sh` therefore apply `scripts/Companion.entitlements` only when `PROVISIONING_PROFILE` names one, and substitute the certificate's Team ID and the assembled bundle id into it at sign time. Ad-hoc-signed builds have no team identity and cannot use the data protection keychain. The credentials crate therefore attempts `SecItemAdd` with `kSecUseDataProtectionKeychain: true` (raw SecItem dictionaries; the pinned security-framework 2.11.1 does not expose this option) and on `errSecMissingEntitlement` (-34018) falls back to the file-based login keychain, logging the degradation once. Signed installs (install-app.sh) get the modern store; ad-hoc dev builds degrade gracefully. The fallback store weakens the keychain half only; the boot half and boot-UUID backstop are unaffected.

*Amendment 2026-08-10: the tier a build reaches is decided by writes, and reads must span both keychains.* The implementation added an up-front probe (an attributes-only read of an account that is never written) so the tier could be decided once instead of on every call. That probe cannot answer the question it was asked. A **read** of a missing item answers `errSecItemNotFound` whether or not the process may use the data protection keychain at all; only a write or a delete answers `errSecMissingEntitlement`. So an unentitled build resolves to the data protection tier, its writes demote one by one and land in the login keychain, and its reads keep asking the data protection keychain, where nothing was ever written. Absence there was read as absence everywhere, so every key half read as missing, every sealed file refused to open, and each session then withheld its own save licence: an app that silently stopped persisting anything, on every launch, having written its keys to a keychain it never looked in. Reads and existence checks therefore fall through to the login keychain before concluding absence, and deletes reach both keychains so a rotation cannot report a forgetting that left a live half in the other one. The probe stays as an optimisation; nothing rests on its verdict.

Boot session is the chosen bound, considered against the user session: staged content therefore survives logout/login and fast user switching within a boot. The keychain half is lock-gated (`WhenUnlocked`), which covers the locked/switched-away window; binding to the login session was rejected as adding a second lifetime mechanism for marginal benefit. OS crash takes the identical path as restart: new boot session UUID, dead boot half, clean slate. No special case.

Write policy:

- Encrypted on every mutation, debounced, written atomically: seal to temp file, fsync, `rename(2)` on the same APFS volume. The debounce interval is a stated tradeoff, not free: shorter shrinks the crash-loss window but multiplies on-disk ciphertext generations (each rename unlinks, not erases, the prior generation, and APFS local snapshots can capture them). Default ~2 s; revisit with data.
- The staging directory is named with a `.noindex` suffix and marked `isExcludedFromBackupKey` to keep Spotlight and Time Machine snapshots away from ciphertext generations.
- While the in-memory buffer is dirty, hold `ProcessInfo.disableSuddenTermination()`; re-enable only after the `rename(2)` has landed, never merely after the write is attempted. Without this, the quit-time flush is unreachable at logout/shutdown — exactly the guarantee the Context section says we cannot otherwise have. Quit flushes pending writes as an optimization; the debounced mutation write is the mechanism.
- The hold is only meaningful if the app **opts into sudden termination**: macOS starts the per-process counter at 1, and `NSSupportsSuddenTermination` in Info.plist is what lowers it to 0. Without the key, `disableSuddenTermination()` moves the counter 1 to 2 and the latch guards nothing, leaving this clause satisfied by the accident of never having opted in, and silently becoming a bug the day anyone adds the key. Both bundles declare it. The worst case for a latch bug is then losing a write inside the dirty window, which is bounded by the same debounce interval already accepted as the loss window.
- The debounce is anchored to the **first** mutation of a burst, not the last. A trailing debounce restarted on every keystroke defers the write for as long as the user keeps typing, which makes the loss window unbounded for exactly the case persistence exists for: someone slowly entering a long secret.

TTL:

- Each item carries a TTL enforced primarily by a **live timer** in the resident process (a menu-bar app can stay up for weeks; a load-path-only check would never fire). The load path is the backstop for TTLs that elapsed while the process was not running. Expiry math uses the monotonic clock (with the existing sleep-aware handling), not wall clock, so stepping the system clock back does not extend an item's life.
- On expiry, send, or discard: delete the file (overwrite-then-truncate best effort, not claimed as erasure — crypto-erasure via key rotation is the real mechanism), `zeroize` the in-memory buffer.

**Titles — a page concern, not a ledger concern.**

The title is a property of the page, set in the core at page creation and updated on edit, before any record reaches the ledger:

- Derived from the first non-empty line of content with markdown syntax stripped, capped at 80 characters.
- If the first line is empty (the common case), a placeholder `MMDD-HHmm` from the creation timestamp.
- User-editable; an explicit user title is never overwritten by re-derivation.

A content-derived title carried into the persistent ledger is content-derived data under the long-lived key. This is a deliberate, documented exception: first lines are often the secret's *label* ("prod DB credentials"), which is precisely what makes a ledger useful — but the derivation cap and strip exist so a one-line secret is not swallowed whole, and the exception narrows the ledger claim below.

**Ledger — long-lived, metadata-plus-title, compliance-adjacent.**

- The ledger stores **no content**: no ink, no excerpts, no tombstone head/tail. `LedgerSegment::Ink` and excerpt-bearing tombstones are removed; implementing this ADR deletes that behavior deliberately. If post-death recall of ink is ever wanted as a feature, it belongs in the content store under the boot-bound key with a TTL — never in the ledger.
- A record carries: event type (created, sealed, sent, expired, discarded), timestamps, size class, destination class, the item's random UUID (plain), and the title. The title is the single content-derived field, per the exception above; the honest claim is "content-free by construction, except the capped title."
- Sealed under its own long-lived key in the data protection keychain (same attributes and ad-hoc fallback as above, separate item).
- Same write discipline: on mutation, debounced, atomic replace.
- **Retention is a rolling 90-day window**, not a record cap. The deciding fact is the title field: the ledger's one residual exposure is content-derived titles under a long-lived key, and a time bound is the only retention policy that shrinks that exposure. A record cap does not: 500 records of a light user is years of "prod DB credentials" titles sitting under the long-lived key. A time bound also makes the ledger consistent with every other lifetime in this design (TTL, boot session) and is the bound an auditor can state in one sentence. File size does not argue for a cap either, since records are a few hundred bytes of metadata and even 100 events per day reaches only ~9,000 records in the window.
- Retention keys on the record's **wall-clock timestamp**, a deliberate and documented exception to the monotonic rule above. Ledger records span reboots, so wall-clock time is what they must carry anyway, and the failure mode of a stepped clock here is a metadata record living slightly too long or dying slightly early, never a secret's lifetime being extended. Eviction runs on load and on the existing debounced write path; no separate timer, because expired records in a closed file are inert until the next read.
- Copy-out to the system pasteboard is an auditable `sent` event with destination class `clipboard`. The pasteboard is this design's named existential risk, so egress to it is the single most useful line in the ledger; recording it costs no content, only the fact that it happened.

**Settings** remain in `UserDefaults` (never secrets).

### Supporting decisions

- All store paths, defaults domains, and keychain service strings derive from `Bundle.main.bundleIdentifier`; dev builds use a `.debug` bundle-id suffix per configuration, splitting Application Support, defaults, and keychain items structurally. Note: changing the bundle id changes keychain ACL identity, so existing dev keychain items become inaccessible — accepted as a one-time dev-only reset; no migration code.
  *(Superseded in this detail, 2026-09-05: since 0.19.0 the release id is `com.onetimesecret.pad` and the dev lane is `dev.onetimesecret.pad`, a separate identifier rather than a suffix, recognised by name. The structural split and the no-migration stance stand.)*
- Application Support directory named by bundle identifier per the File System Programming Guide convention (also preserves automatic container migration if App Sandbox is adopted).
- **Secret-handling discipline, scoped.** Staged content never persists in Swift-owned types and crosses the FFI boundary at exactly two documented points: one ingress (plaintext as `const char*`, copied immediately into mlock'd Rust memory) and one egress (send). Transient Swift-side copies created by the input path and the FFI bridge are accepted residual exposure, already covered by the Context section's admission that Swift `String` cannot be zeroed. The API token is a credential, not staged content; its SecureField-bound `String` is platform-conventional and in scope for the keychain, not for the content discipline. Raw key material lives solely in the Rust core (`zeroize`/`secrecy`, opaque handles across FFI).
- Input path unchanged: direct entry or drop target, not paste; concealed-type + clear on any pasteboard egress; mlock'd buffers while live; `explicit_bzero` on send, timeout, and quit.

## Consequences

- Implementing this ADR removes shipped behavior: verbatim ink in the ledger, tombstone excerpts, and ink-derived record titles are deleted, replaced by the page-owned title. This is intentional feature removal, not regression.
- A ciphertext artifact for staged content exists on disk during a boot session, plus unlinked prior generations until APFS reclaims them. Acknowledged, bounded residual exposure: unreadable without both key halves; both dead or rotated after reboot.
- Crash-survival is a delivered feature; the loss window is the debounce interval.
- The audit story is concrete: one small module writes secret ciphertext; its lifetime bound is one derivation (two key halves) and two mechanical checks (boot session UUID, TTL) an auditor can read in minutes; the ledger is content-free by construction except the capped, user-visible title field.
- Accepted residual exposure (documented, not claimed away): swap under FileVault key, window-server capture surfaces, memory not provably zeroed at the language level (including transient Swift copies at the FFI ingress and SecureField), per-boot ciphertext and its unlinked generations, content surviving logout within a boot session (lock-gated), the ledger title as content-derived metadata, and the file-based keychain fallback on ad-hoc dev builds.
- Brand tension resolved as before: a bounded, non-persistent-beyond-boot safer clipboard stays strictly better than current user behavior while keeping "in transition between origin and destination" as marketing rather than a security guarantee.

## Supersession

Superseded in part by [ADR-0016](0016-content-persists-across-restart.md), which removes the boot-session bound on staged content and makes TTL the only mechanism that destroys it.

Superseded: the **Staged content, bounded to the boot session** subsection
in full, except its two keychain-availability paragraphs (*Keychain
availability (implementation constraint)* and *Amendment 2026-08-10*), which
stand. That covers the two-half key derivation and both half bullets, the
crypto-erasure-at-reboot claim, the deterministic boot-UUID backstop and its
fail-closed clause, the "note what this does and does not claim" paragraph,
and the boot-versus-user-session paragraph. Also the monotonic rule in the
TTL bullets as it applies to staged content, and the boot-bound clauses of
three consequences: the ciphertext-exists-during-a-boot-session bullet, the
boot-session UUID check in the audit-story bullet, and
"non-persistent-beyond-boot" in the brand-tension bullet. [ADR-0016](0016-content-persists-across-restart.md)
carries the replacements; the numbered sections that once stated them in detail
now live in the
[persistence decision background](../plans/trustworthy-persistence-decision-background.md).

Still standing, unamended: the **Framing** items, **Item identity**, the two
keychain-availability paragraphs above, the **Write policy** bullets, the
title derivation with its 80 character cap and its documented wall-clock
exception, the entire **Ledger** subsection, and **Supporting decisions**.
The live-timer requirement in the TTL bullets and its load-path backstop also
stand; only the clock the load path ages by changes.

[ADR-0017](0017-durable-tabs-expiring-pages.md) carries the object graph
change, the durable Tab versus expiring Page split, which rides the same
one-time format break as ADR-0016.

ADR-0017 also amends the **Titles** subsection: the title as a property of
the page and the user-set title become properties of the durable Tab,
`title_is_user_set` disappears, and the `MMDD-HHmm` placeholder renders from
the Tab's creation stamp. The derivation, its cap, and the documented
exception stand, page-side.

The body above is left as written, because an ADR is a record of a decision
taken. Successor ADRs name the subsections they replace rather than citing
this file's line numbers.

## Eject triggers

These apply only to the portions this ADR still governs; ADR-0016 and
ADR-0017 own the superseded staged-content and object-graph decisions.

- Reproducible evidence shows that a surviving public framing claim is false
  or materially broader than the implementation can support. The claim must
  be narrowed or moved to a successor ADR.
- A requirement needs the ledger to retain body content, excerpts, or another
  content-derived field beyond the capped title. That is a new retention
  decision and reopens the ledger boundary.
- A supported macOS or Keychain change makes the stated write, key-storage,
  or availability assumptions unavailable. The remaining persistence policy
  must then be re-evaluated against that platform change.

## Amendment 1: three egress points and one clear interval

- **Status:** accepted
- **Date:** 2026-09-15

Appended, not folded in. Unlike the ADR-0007 amendments, this one leaves
the Decision text above as written: the base record already says that
successors name the subsections they replace rather than editing them,
and this section does the same for two bullets of **Supporting
decisions**, the secret-handling discipline bullet and the input path
bullet that follows it.

### What changed

The secret-handling discipline bullet counts "one egress (send)". The
successor design record,
[docs/spec/design/2026-0915-ui-ux-decisions.md](../spec/design/2026-0915-ui-ux-decisions.md),
decision D-32, makes it three, and this amendment adopts that count so
the ADR does not drift from the surface it governs:

1. **Copy decrypted.** The plaintext goes to the general pasteboard.
   This is the riskier path: the channel the Context section names as
   the existential risk (clipboard managers, Universal Clipboard,
   polling apps), kept as the fallback for destinations that take no
   drop.
2. **Decrypted drag.** The plaintext goes to the drag pasteboard, from
   the explicit decrypted-drag handle only, and never enters clipboard
   history or Universal Clipboard. This is the recommended path into a
   form field.
3. **Promotion to a one-time link.** The conceal of ADR-0007 Amendment
   3: plaintext leaves for the server and a link comes back.

All three are core-side writes. The Swift shell asks the core to write
to a named destination and never holds the plaintext, so the inventory
in the discipline bullet stays honest: one ingress, three egresses, each
crossing the FFI at a documented point.

The input path bullet's "clear on any pasteboard egress" gains the
number it lacked. The clear-on-egress interval is one core constant,
60 seconds, exposed through a seam so the confirmation line and the
timer read the same value; the number is provisional until the
maintainer confirms it (D-32 records the call as pending). Nothing in
the tree arms the clear today: `clearClipboardIfOurs`
(`shell/Sources/CompanionKit/CompanionClient.swift:833`) exists and
nothing calls it, so the interval is the number the build owes, not a
description of what it does. The clear applies to the general
pasteboard only; the drag pasteboard is released when the drag session
ends and needs no timer.

The ledger's `sent` record keeps its shape. Its `DestinationClass`
(`crates/core/src/ledger.rs:108`) names `Clipboard` and `OneTimeLink`
today; it gains a `Drag` class when issue 170 (the sealed object
pasteboard model: private type, placeholder, detach on cut, reattach on
paste, lazy decrypted drag) lands, written at the moment the drag's
plaintext is provided, not when the drag starts. Recording the class
costs no content, as the Ledger subsection already argues for
`clipboard`, and it lets the ledger tell the riskier egress from the
recommended one.

### What this does not claim

Three named egresses do not narrow the residual exposure the
Consequences list. A decrypted drag is safer than a copy because of
where the bytes land, not because the bytes are protected in flight;
the destination application holds them from the drop onward, exactly
as it does after a paste.

## Decision history

- **2026-07-15:** This remains the proposed base record.
- **2026-08-06:** Revised to incorporate external review and implementation findings. The revision did not change the proposed status.
- **2026-08-20:** [ADR-0016](0016-content-persists-across-restart.md) superseded the named staged-content lifecycle and related consequences portions; [ADR-0017](0017-durable-tabs-expiring-pages.md) superseded the named object-graph and title-ownership portions. See [Supersession](#supersession) for scope.
- **2026-08-20 onward:** The portions named as still standing in [Supersession](#supersession) remain in force.
- **2026-09-15:** [Amendment 1](#amendment-1-three-egress-points-and-one-clear-interval) was appended, adopting D-32 of the [2026-0915 design record](../spec/design/2026-0915-ui-ux-decisions.md): three egress points in place of one, the clear-on-egress interval as one core constant of 60 seconds (provisional), and the `Drag` destination class owed to issue 170.
