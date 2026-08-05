# ADR-0012: OTS macOS staging companion — framing, threat boundary, and persistence model

Status: Proposed (revised)
Date: 2026-07-15, revised 2026-08-05

## Context

A macOS menu-bar companion for Onetime Secret that stages content in transition between an origin and a destination via a small, edge-docked window. The original pitch was "verifiably forgets."

"Verifiably forgets" is not deliverable on macOS as stated, and it mislabels the product's actual value.

Constraints that break the literal claim:

- No runtime proof of erasure. Pages are compressed and swapped. Under FileVault, swap is encrypted, so the honest claim is "encrypted under a key that dies at shutdown," not "gone." Rendered content lives in the window server and is exposed to screenshots, screen sharing, and screen recording.
- Swift `String` cannot be reliably zeroed: immutable, ARC-copied, backing store scattered.
- The system pasteboard is the existential risk. Copy/paste writes to `NSPasteboard` (system-wide, persistent, scraped by clipboard managers, synced off-device via Universal Clipboard). If content arrives by paste, the "forgets" claim is already false before staging begins.

The first implementation also revealed a persistence defect: the entire store was sealed in a single write at quit. `applicationWillTerminate` is not guaranteed (sudden termination at logout/shutdown, force quit, crash, power loss), so the design persisted exactly when nothing went wrong and lost everything in the cases persistence exists for. It also extended content lifetime indefinitely across OS restarts without acknowledging the disk artifact.

## Decision

### Framing (unchanged from original)

1. Reframe from "verifiable erasure" to **auditable discipline**: open source plus a reproducible pre-signature artifact. Codesigning timestamps and stapled notarization tickets make the shipped .app non-bit-identical, so the precise claim is: reproducible unsigned build with a published hash, plus instructions to verify the shipped binary's unsigned payload against it. Drop any language implying runtime attestation of erasure or bit-identical shipped binaries.
2. Reframe the product from a *store* to a **safer clipboard**: bounded lifetime, non-swappable while live, self-zeroing, never on the system pasteboard.
3. **Lead with the real win**: the secret never enters a browser (no form field, autofill, extension, page memory, or tab) and never touches the system clipboard.

### Persistence model

The store splits into two files with different keys, lifetimes, and write policies. The module that writes staged content to disk is the only code path that touches secret ciphertext, and it is small enough to audit in one sitting.

**Staged content — bounded to the boot session.**

Key derivation: the content wrapping key is `HKDF(keychain_half, boot_half)`.

- `keychain_half`: random secret in the **data protection keychain** (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), ACL-bound to the signed app, lock-gated. Rotated (old item deleted, new generated) on first launch after a new boot session.
- `boot_half`: random secret generated at first launch after boot, stored only in the per-user temp directory (`_CS_DARWIN_USER_TEMP_DIR`, mode 0600).

Neither half alone unwraps content. **Crypto-erasure at reboot is the primary mechanism**: the temp dir is cleared at boot (observed empirically: on a test machine whose temp directory itself predated the boot by 90+ days, zero of 637 entries predated the current boot — a consistent but undocumented heuristic, hence the backstop below), so the derived key is unrecoverable after reboot without the app ever running. The keychain half exists so that a same-session process running as the user, reading the 0600 temp file, still gets nothing without passing the keychain ACL. **Deterministic backstop (policy)**: the sealed record embeds `kern.bootsessionuuid` — opaque and stable for the whole boot session, unlike `kern.boottime`, which the kernel re-derives when the calendar clock steps and which would spuriously discard content mid-session — and a mismatch at load discards the file and rotates both key halves unconditionally.

Boot session is the chosen bound, considered against the user session: staged content therefore survives logout/login and fast user switching within a boot. The keychain half is lock-gated (`WhenUnlocked`), which covers the locked/switched-away window; binding to the login session was rejected as adding a second lifetime mechanism for marginal benefit. OS crash takes the identical path as restart: new boot session UUID, dead boot half, clean slate. No special case.

Write policy:

- Encrypted on every mutation, debounced, written atomically: seal to temp file, fsync, `rename(2)` on the same APFS volume. The debounce interval is a stated tradeoff, not free: shorter shrinks the crash-loss window but multiplies on-disk ciphertext generations (each rename unlinks, not erases, the prior generation, and APFS local snapshots can capture them). Default ~2 s; revisit with data.
- The staging directory is named with a `.noindex` suffix and marked `isExcludedFromBackupKey` to keep Spotlight and Time Machine snapshots away from ciphertext generations.
- While the in-memory buffer is dirty, hold `ProcessInfo.disableSuddenTermination()`; re-enable after a successful write. Without this, the quit-time flush is unreachable at logout/shutdown — exactly the guarantee the Context section says we cannot otherwise have. Quit flushes pending writes as an optimization; the debounced mutation write is the mechanism.

TTL:

- Each item carries a TTL enforced primarily by a **live timer** in the resident process (a menu-bar app can stay up for weeks; a load-path-only check would never fire). The load path is the backstop for TTLs that elapsed while the process was not running. Expiry math uses the monotonic clock (with the existing sleep-aware handling), not wall clock, so stepping the system clock back does not extend an item's life.
- On expiry, send, or discard: delete the file (overwrite-then-truncate best effort, not claimed as erasure — crypto-erasure via key rotation is the real mechanism), `zeroize` the in-memory buffer.

**Ledger — long-lived, metadata-only, compliance-adjacent.**

- The ledger never contains content. It records events — item created, sealed, sent, expired, discarded — with timestamps, size class, and destination class. The correlation digest covers **the item's random identifier, never content or anything derived from content**, salted per install with the salt stored alongside the ledger key. This sentence is what makes "content-free by construction" structural: a digest over content would make low-entropy secrets brute-forceable from the ledger.
- Sealed under its own long-lived key in the data protection keychain (same attributes as above, separate item).
- Same write discipline: on mutation, debounced, atomic replace.

**Settings** remain in `UserDefaults` (never secrets).

### Supporting decisions

- All store paths, defaults domains, and keychain service strings derive from `Bundle.main.bundleIdentifier`; dev builds use a `.debug` bundle-id suffix per configuration, splitting Application Support, defaults, and keychain items structurally. Note: changing the bundle id changes keychain ACL identity, so existing dev keychain items become inaccessible — accepted as a one-time dev-only reset; no migration code.
- Application Support directory named by bundle identifier per the File System Programming Guide convention (also preserves automatic container migration if App Sandbox is adopted).
- Raw key material lives solely in the Rust core (`zeroize`/`secrecy`, opaque handles across FFI); Swift never holds secret bytes in `String`/`Data`.
- Input path unchanged: direct entry or drop target, not paste; concealed-type + clear on any pasteboard egress; mlock'd buffers while live; `explicit_bzero` on send, timeout, and quit.

## Consequences

- A ciphertext artifact for staged content exists on disk during a boot session, plus unlinked prior generations until APFS reclaims them. Acknowledged, bounded residual exposure: unreadable without both key halves; both dead or rotated after reboot.
- Crash-survival is a delivered feature; the loss window is the debounce interval.
- The audit story is concrete: one small module writes secret ciphertext; its lifetime bound is one derivation (two key halves) and two mechanical checks (boot session UUID, TTL) an auditor can read in minutes; the ledger is provably content-free by construction (digest-of-identifier rule).
- Accepted residual exposure (documented, not claimed away): swap under FileVault key, window-server capture surfaces, memory not provably zeroed at the language level, per-boot ciphertext and its unlinked generations as above, content surviving logout within a boot session (lock-gated).
- Brand tension resolved as before: a bounded, non-persistent-beyond-boot safer clipboard stays strictly better than current user behavior while keeping "in transition between origin and destination" as marketing rather than a security guarantee.
