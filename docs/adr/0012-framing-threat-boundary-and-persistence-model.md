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

The first implementation also revealed a persistence defect: the entire store (staged content + ledger + settings context) was sealed in a single write at quit. `applicationWillTerminate` is not guaranteed (sudden termination at logout/shutdown, force quit, crash, power loss), so the design persisted exactly when nothing went wrong and lost everything in the cases persistence exists for. It also extended content lifetime indefinitely across OS restarts, in tension with the "in transition" framing, without acknowledging the disk artifact in the residual-exposure list.

## Decision

### Framing (unchanged from original)

1. Reframe from "verifiable erasure" to **auditable discipline**: open source plus reproducible build. Someone can read the code and confirm the behavior. Drop any language implying runtime attestation of erasure.
2. Reframe the product from a *store* to a **safer clipboard**: bounded lifetime, non-swappable while live, self-zeroing, never on the system pasteboard.
3. **Lead with the real win**: the secret never enters a browser (no form field, autofill, extension, page memory, or tab) and never touches the system clipboard.

### Persistence model (new)

The store splits into two files with different keys, lifetimes, and write policies. The module that writes staged content to disk is the only code path that touches secret bytes at rest, and it is small enough to audit in one sitting.

**Staged content — bounded to the boot session.**

- Encrypted on every mutation, debounced (~1–2 s), written atomically: seal to temp file, fsync, `rename(2)` on the same APFS volume. Never a quit-time-only save. Quit still flushes any pending debounce, but quit is an optimization, not the mechanism.
- Survives application crash, quit, and relaunch within the same OS boot session.
- **Clean slate on OS restart, by crypto-erasure plus policy check.** The content file is sealed under an ephemeral wrapping key generated at first launch after boot and stored only in the per-user temp directory (`_CS_DARWIN_USER_TEMP_DIR`, mode 0600), which does not survive reboot. Belt-and-suspenders: the sealed record also embeds the boot session identity (`sysctl kern.boottime`); at load, a mismatch discards the file unconditionally, even if the temp dir survived (temp cleanup is a heuristic, not a guarantee — the boot-time check is the deterministic bound). OS crash takes the identical path: new boot time, key gone, clean slate. No special case.
- The record additionally carries a per-item TTL enforced in the load path, so content self-expires within a boot session too.
- On expiry, send, or discard: overwrite-then-truncate the on-disk region best-effort, delete the file, `zeroize` the in-memory buffer. (Overwrite on APFS/SSD is not a guarantee and is not claimed as one; crypto-erasure via the dead wrapping key is the real mechanism.)

**Ledger — long-lived, metadata-only, compliance-adjacent.**

- The ledger never contains content. It records events: item created, sealed, sent, expired, discarded — with timestamps, size class, destination class, and a salted digest for correlation. When staged content dies, the ledger entry is already metadata; nothing degrades because nothing sensitive was ever in it. "Degrades to metadata" is achieved structurally, not by redaction.
- Sealed under a separate long-lived key in the **data protection keychain** (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), not the legacy file-based login keychain.
- Same write discipline: on mutation, debounced, atomic replace.

**Settings** remain in `UserDefaults` (never secrets).

### Supporting decisions

- All store paths, defaults domains, and keychain service strings derive from `Bundle.main.bundleIdentifier`; dev builds use a `.debug` bundle-id suffix per configuration, which splits Application Support, defaults, and keychain items structurally rather than by convention.
- Application Support directory is named by bundle identifier per the File System Programming Guide convention (also preserves automatic container migration if App Sandbox is adopted).
- Raw key material lives solely in the Rust core (`zeroize`/`secrecy`, opaque handles across FFI); Swift never holds secret bytes in `String`/`Data`.
- Input path unchanged from original ADR: direct entry or drop target, not paste; concealed-type + clear on any pasteboard egress; mlock'd buffers while live; `explicit_bzero` on send, timeout, and quit.

## Consequences

- A ciphertext artifact for staged content exists on disk during a boot session. This is now an acknowledged, bounded residual exposure: readable only with the per-boot wrapping key, dead at reboot.
- Crash-survival is a delivered feature, not an accident of quit timing; loss windows shrink to the debounce interval.
- The audit story is concrete: one small module writes secret ciphertext, its lifetime bound is two mechanical checks (boot identity, TTL) an auditor can read in minutes; the ledger is provably content-free by construction.
- Accepted residual exposure (documented, not claimed away): swap under FileVault key, window-server capture surfaces, memory not provably zeroed at the language level, per-boot ciphertext file as above.
- Brand tension resolved as before: a bounded, non-persistent-beyond-boot safer clipboard stays strictly better than current user behavior while keeping "in transition between origin and destination" as marketing rather than a security guarantee.
