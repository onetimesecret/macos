---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0012: OTS macOS staging companion — framing, threat boundary, and persistence model

- **Status:** proposed
- **Date:** 2026-07-15
- **Revised:** 2026-08-06 — incorporates external review and implementation
  findings.
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

Superseded: the **Staged content** subsection headed at line 34, running to line 51, except lines 47 and 49, which stand; including the crypto-erasure claim at line 41, the deterministic boot-UUID backstop at line 43, the does-not-claim paragraph at line 45, and the boot-versus-user-session paragraph at line 51. Also line 63's monotonic rule as it applies to staged content, and consequences 98, 100 and 101. ADR-0016 sections 3, 4 and 8 carry the replacements.

Still standing, unamended: the framing at lines 22 to 27, item identity at line 32, keychain tiering at lines 47 and 49, the write policy at lines 53 to 59, the title derivation, its 80 character cap and the documented exception at lines 70 and 74, the entire ledger subsection at lines 76 to 85, and supporting decisions at lines 88 to 93. Line 63's live-timer requirement and its load-path backstop also stand; only the clock the load path ages by changes.

[ADR-0017](0017-durable-tabs-expiring-pages.md) carries the object graph change, the durable Tab versus expiring Page split, which rides the same one-time format break as ADR-0016.

ADR-0017 also amends the titles subsection: line 68's title as a property of the page and line 72's user-set title become properties of the durable Tab, `title_is_user_set` disappears, and line 71's `MMDD-HHmm` placeholder renders from the Tab's creation stamp. Line 70's derivation and cap and line 74's documented exception stand, page-side.

The body above is left as written, because an ADR is a record of a decision taken. Line references from other ADRs address this file's own line numbers directly.

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

## Decision history

- **2026-07-15:** This remains the proposed base record; its 2026-08-06 revision did not change that status.
- **2026-08-20:** [ADR-0016](0016-content-persists-across-restart.md) superseded the named staged-content lifecycle and related consequences portions; [ADR-0017](0017-durable-tabs-expiring-pages.md) superseded the named object-graph and title-ownership portions. See [Supersession](#supersession) for scope.
- **2026-08-20 onward:** The portions named as still standing in [Supersession](#supersession) remain in force.
