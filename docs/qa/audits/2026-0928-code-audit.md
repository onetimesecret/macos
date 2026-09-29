# 2026-09-28: automated code audit at 2d73af4

Produced by a multi-agent audit workflow run on 2026-09-28 against `main` at
commit 2d73af4. One recon agent profiled the repository and five finder
agents each covered one dimension: security, correctness, test coverage,
dead code, and dependency risk. Three verifier agents then tried to refute
each candidate finding, and a finding was kept only if at least two of
the three could not refute it. The finders proposed 33 candidates and 16
survived.

This is agent output. Under [AGENTS.md](../../../AGENTS.md) it is a lead,
not an authoritative source: it establishes no project claim, and each
finding should be confirmed against the code before it is acted on. The
body below is the workflow's synthesis, unedited apart from its title.

A separate manual review in the same session found three issues that are
not in this report:

- A panic inside most FFI exports aborts the process, because only
  `companion_detect_source_language` wraps its body in `catch_unwind`.
  Abort skips `Drop`, so zeroize-on-drop does not run. That contradicts
  the rationale for `panic = "unwind"` in the workspace `Cargo.toml`.
- `UreqTransport` in `crates/transport/src/lib.rs` sets no connect or
  read timeouts, so a half-open connection hangs a conceal or sync call.
- CONTRIBUTING.md, `docs/spec/design/07-repo-skeleton.md` and
  `docs/spec/design/05-technical-direction.md` disagree with the code
  and with each other on where `unsafe` may appear, on persistence
  across restart, and on content inspection.

---

**Headline:** 16 verified findings (1 high, 6 medium, 9 low). The most serious is that a single undecryptable sync proposal permanently spends the device's one-shot key package, which stalls sync until the app is relaunched. The second is that ureq's default redirect-following bypasses the transport's host allowlist and HTTPS-only check.

> **Note on sources.** These findings come from an adversarial multi-verifier pass. They were not re-checked against the source for this synthesis. Where a finding refers to project wording (code comments, doc-05, Cargo.toml, deny.toml, THIRD_PARTY_NOTICES.md), the verifiers reported that wording. Under AGENTS.md, it is a lead to confirm against the primary source, not a confirmed project claim. The license-obligation readings under Dependency risk are the verifiers' interpretation, not legal advice.

## Severity summary

| Dimension       | High | Medium | Low | Total |
|-----------------|-----:|-------:|----:|------:|
| Security        | 0    | 1      | 2   | 3     |
| Correctness     | 0    | 1      | 2   | 3     |
| Test coverage   | 1    | 2      | 1   | 4     |
| Dead code       | 0    | 0      | 4   | 4     |
| Dependency risk | 0    | 2      | 0   | 2     |
| **Total**       | **1**| **6**  | **9**| **16** |

**Cross-cutting root cause.** Correctness (medium) `sync_session.rs:198`, Test coverage (high) `sync_session.rs:922` and Correctness (low) `sync_driver.rs:620` describe the same key-package lifecycle defect from three angles. A single fix makes `open_entropy` non-destructive on failure, re-mints the package after a failure, and swaps the keeper only after attach succeeds. That fix should close all three.

---

## Security

### [Medium] Redirects bypass the host allowlist and the TLS-only rule
- **Location:** `crates/transport/src/lib.rs:39` (the `send` check is at lines 72-90)
- **Category:** insecure-defaults / network-boundary-bypass
- **Why it matters:** `UreqTransport::send` rejects non-https URLs and hosts outside the allowlist, but it checks only the first request. The agent is built with ureq 3.3.0 defaults, which the verifiers report as `max_redirects: 10` and `https_only: false`. A 3xx from an allowed host can therefore send the follow-up GET (and a POST downgraded to GET) to any host, including over plain `http://`. The Authorization header is dropped, and 307/308 with a body are not followed, so the bearer token and the conceal plaintext do not leak. However, a response from an untrusted, possibly cleartext origin is then parsed as relay or OTS data: the attach roster and key packages, token-endpoint JSON, and the conceal `share_link`. An open redirect on, or a compromise of, either allowed host is enough to move traffic onto an on-path attacker.
- **Suggested fix:** Build the agent with `.https_only(true)` and `.max_redirects(0)`, and treat any 3xx as `TransportError`. If redirects are ever needed, re-run the https and allowlist check on every hop. Add a test that a 302 to a third host is refused.
- **Consensus:** 3/3 verifiers

### [Low] Conceal request body leaves unwiped plaintext copies
- **Location:** `crates/ots-client/src/api.rs:73`
- **Category:** plaintext-hygiene / zeroize-posture
- **Why it matters:** `post_conceal` builds the body with `serde_json::to_vec(&serde_json::json!({ "secret": payload }))`. This produces a `Value::String` copy of the secret and passphrase that is dropped without zeroizing. `to_vec` also grows a plain `Vec` by reallocation, which frees intermediate plaintext buffers without wiping them. Only the final buffer goes into `Zeroizing`. Elsewhere the codebase avoids this pattern (`core/src/persist.rs:194-216`, `core/src/store.rs:1652-1664`, `ffi/src/persist.rs:646-652`). This path is where the whole page plaintext leaves the core.
- **Suggested fix:** Serialize a `#[derive(Serialize)]` wrapper (`{ secret: &ConcealPayload }`) directly. Size it first with a counting writer, then write into a `Zeroizing<Vec<u8>>` preallocated to that exact size. Remove the `json!` intermediate, and add a test that the body is produced without reallocation.
- **Consensus:** 2/3 verifiers

### [Low] `read_once` reads the whole file before checking the size limit
- **Location:** `crates/core/src/files.rs:1343`
- **Category:** missing-input-validation / resource-exhaustion
- **Why it matters:** `read_once` stats the file, reads all of it (`ffi/src/files.rs:146-147` preallocates `metadata.len()`), and only then compares against `FILE_SIZE_LIMIT` at line 1350. A multi-gigabyte file that comes from the open panel, a drag-and-drop, or a stale drafts record is fully allocated, read and wiped before it is refused. On a machine with little memory, that can crash the process that holds every sealed page.
- **Suggested fix:** Return `OpenRefusal::TooLarge` when `before.size > FILE_SIZE_LIMIT` before calling `io.read`. Also have `read_regular_file` read through `file.take(limit + 1)`, so a file that grows between the stat and the read is still bounded.
- **Consensus:** 3/3 verifiers

---

## Correctness

### [Medium] A failed `open_entropy` spends the key package, and nothing re-mints it
- **Location:** `crates/ffi/src/sync_session.rs:198`
- **Category:** logic-error / liveness
- **Why it matters:** `KeyPackageKeeper::open_entropy` calls `self.private.take()?` before the agreement and the AEAD open. When the open fails, the private half is gone. The only re-mint happens in `sync_driver::ensure_engine` (lines 615-620) through `attach()`, and `pump` calls `attach()` only after a ceremony has committed (`sync_driver.rs:1174`). No attacker is needed to reach this. Rosters refresh only at attach, so after a ceremony the first device to re-attach still holds the peer's previous package. When it proposes, it seals to that stale package, and the follower's open fails and spends its current key. Every retry then fails too, and the channel loops on 413 `ceremony_required` until the app relaunches. `dispatch_control` also spends the key before `propose_ceremony` can refuse (line 930).
- **Suggested fix:** Make a failed open recoverable. Have `open_entropy` report a distinct failure outcome that triggers `attach()` (re-mint and republish), or let the keeper re-mint itself immediately. Refresh the roster before `propose_ceremony`. Consider a reusable static secret, so a failed open does not spend the key at all.
- **Consensus:** 3/3 verifiers

### [Low] Re-attach replaces the local key package before the relay accepts the new one
- **Location:** `crates/ffi/src/sync_driver.rs:620`
- **Category:** state-machine / ordering
- **Why it matters:** `ensure_engine` assigns the newly minted keeper to `engine.packages` before the attach request is sent. If the attach is unreachable or refused, the relay keeps advertising the old package, but its private half has already been dropped. Proposals sealed to the advertised package then fail to open, and because of the finding above, that failure also spends the new key.
- **Suggested fix:** Mint into a local variable and swap it into `engine.packages` only when `absorb_attach` returns `Ok(())`. On failure, keep the old keeper.
- **Consensus:** 2/3 verifiers

### [Low] Key-half and state-file reads follow symlinks and block on a FIFO
- **Location:** `crates/ffi/src/persist.rs:595`; also `lib.rs:1973` and `lib.rs:2316`
- **Category:** resource-hazard / consistency
- **Why it matters:** `read_half`, `companion_persist_restore` and the ledger restore use a plain `std::fs::read`. The erase path (`open_for_erase`, `holds_content_envelope`) and `files.rs::read_regular_file` open the same directory with `O_NOFOLLOW | O_NONBLOCK` to avoid exactly these hazards. A FIFO planted at the key-half or state path blocks save or restore while the shared handle `Mutex` is held, which wedges every FFI call at launch. A symlink silently sources the key half from somewhere else.
- **Suggested fix:** Open these files with `custom_flags(O_NOFOLLOW | O_NONBLOCK)` and check `metadata().file_type().is_file()` before `read_to_end`. Treat any non-regular file as absent or refused.
- **Consensus:** 2/3 verifiers

---

## Test coverage

### [High] No test covers the Propose failure branch that spends the key package
- **Location:** `crates/ffi/src/sync_session.rs:922`
- **Category:** error-branch-untested
- **Why it matters:** `dispatch_control` calls `open_entropy` for any `Propose` that names this device. A payload that fails to open (garbage, the wrong ephemeral key, or a replay against an older package) consumes the private half. The comment above the call states an intent (resolve everything before the one-shot key is spent) that this branch does not meet. Any peer that holds the current key, or a relay replaying an old proposal, can burn the package with one bogus proposal. After that, this device silently never accepts the genuine ballot. The existing tests (`key_packages_verify_seal_and_spend_once`, `a_proposal_for_a_page_this_device_does_not_hold_spends_nothing`) cover only the success path and the early returns.
- **Suggested fix:** Add a test that publishes a `Propose` whose `entropy_sealed["fp-b"]` is random bytes, drains it on B, and then asserts that a valid `open_entropy` still succeeds and no `Accept` was queued. Make it pass with the fix for the Correctness finding above.
- **Consensus:** 2/3 verifiers

### [Medium] A slow or silent stray loopback connection defeats the sign-in deadline and the cancel
- **Location:** `crates/sync/src/loopback.rs:99`
- **Category:** error-branch-untested
- **Why it matters:** `serve` loops on 5 s read timeouts until it sees CRLF or has read 8 KiB. The timeout applies per read, so a client that trickles one byte every few seconds keeps `serve` running indefinitely, and a silent client blocks it for 5 s. `serve` checks neither `deadline` nor `abandoned`. Any local process can therefore hold up the OAuth redirect wait and ignore the user's cancel. The only stray-connection test sends a complete request line immediately.
- **Suggested fix:** Add tests for a silent client with `abandoned` set after 100 ms (expect `None` well under 5 s) and for a client sending one byte every 200 ms (expect the wait not to exceed `patience`). Bound the total time spent in `serve` by the outer deadline, check `abandoned` between reads, and shorten the read timeout.
- **Consensus:** 2/3 verifiers

### [Medium] CI never executes the raw `SecItem*` unsafe calls
- **Location:** `crates/credentials/src/lib.rs:757` (the `secitem` module spans roughly lines 695-829)
- **Category:** security-untested
- **Why it matters:** `add_or_update`, `update`, `copy_secret`, `delete` and `attributes_status` are the crate's only `unsafe` code and the only path that touches real credentials. The only test that drives them (`data_protection_items_are_invisible_to_the_login_keychain`, line 1303) is `#[ignore]`d. The other macOS tests only inspect the dictionaries that are built, and the ffi tests use `InMemoryCredentialStore`. None of the following is exercised: the duplicate-to-update path, the success-with-null branch, `wrap_under_create_rule` ownership of the returned CFData, or deleting a missing item. An ownership regression, such as a double release or a leak of the secret CFData, would ship unnoticed.
- **Suggested fix:** Create a scratch keychain in the macOS CI lane and run the ignored test there with `--ignored`. Alternatively, add an env-gated test (e.g. `COMPANION_KEYCHAIN_TESTS=1`) that round-trips `KeychainStore` through add, duplicate-update, load, exists, delete and delete-of-absent.
- **Consensus:** 2/3 verifiers

### [Low] No test checks that `harden_process` sets RLIMIT_CORE to zero
- **Location:** `crates/core/src/harden.rs:15`
- **Category:** security-untested
- **Why it matters:** `harden_process` disables core dumps so that a crash does not write mlocked pages to disk. It deliberately ignores the `setrlimit` result and has no test. A wrong resource id, swapped limits or a cfg mistake would leave core dumps enabled without anything failing.
- **Suggested fix:** Add a `#[cfg(unix)]` test that calls `harden_process()` and asserts that `getrlimit(RLIMIT_CORE)` returns 0 for both the soft and hard limits. Skip it if the hard limit was already 0 before the call.
- **Consensus:** 2/3 verifiers

---

## Dead code

### [Low] `RelayApi::parse_publish_frame` is never called
- **Location:** `crates/sync/src/relay.rs:258`
- **Category:** unused-export
- **Why it matters:** The function has no callers. `sync_driver.rs:1202` repeats its status check inline (`status == 409 || 2xx`), so the documented mapping of 409 to `EpochConflict` never runs, and the two copies can drift apart.
- **Suggested fix:** Call `parse_publish_frame` from `sync_driver.rs:1202` and match on `RelayRefusal::EpochConflict`, or delete the function.
- **Consensus:** 3/3 verifiers

### [Low] `LONG_POLL_WAIT_S` is defined but never read
- **Location:** `crates/ffi/src/sync_session.rs:48`
- **Category:** stale-constant
- **Why it matters:** The actual wait comes from a hardcoded `25` in `shell/Sources/CompanionKit/SyncController.swift:459`. The constant documents a value that nothing enforces, and the two can silently diverge.
- **Suggested fix:** Remove the constant, or make it the single source of truth: have the FFI default or clamp to it, or expose it through the header for Swift to read.
- **Consensus:** 3/3 verifiers

### [Low] The deprecated `CompanionClient.version` alias is unused
- **Location:** `shell/Sources/CompanionKit/CompanionClient.swift:1501`
- **Category:** unused-export
- **Why it matters:** The alias is kept for CompanionKit clients, but the only clients are in-repo targets, and none of them reference it. It is the Swift counterpart of the dead `companion_version` C alias.
- **Suggested fix:** Remove the deprecated accessor.
- **Consensus:** 3/3 verifiers

### [Low] `PageModel.stopRedraw(from:)` has no production caller
- **Location:** `shell/Sources/CompanionKit/PageModel.swift:5013`
- **Category:** unused-export
- **Why it matters:** Only tests reference it. It served the archived panel form factor. The backdrop is always on screen, and the timer is torn down elsewhere (`PageModel.swift:2296`).
- **Suggested fix:** Remove the method and its tests, or document it as a deliberately retained seam.
- **Consensus:** 3/3 verifiers

---

## Dependency risk

### [Medium] Shipped third-party notices cover about 2 of ~179 crates
- **Location:** `THIRD_PARTY_NOTICES.md:4`
- **Category:** license
- **Why it matters:** The verifiers report that this file covers only Betlang, its model and `fearless_simd`, and that the file itself says it does not replace other components' notices. It is the only notice artifact. `scripts/build-core.sh:96` and `scripts/package-app.sh:187` ship it, and CI (`ci.yml:143-144, 193-194`) checks that it ships byte-for-byte. The release graph (~179 packages) includes MIT, Apache-2.0, BSD, MPL-2.0 (im, bitmaps, sized-chunks), BSL-1.0, Unicode-3.0 and CDLA-Permissive-2.0 (webpki-roots) components. In the verifiers' reading, their attribution obligations, and for MPL-2.0 its source-availability notice, are not met, and nothing in the scripts or CI generates or checks them.
- **Suggested fix:** Generate the notices from the lockfile at build time (e.g. `cargo about generate` with an allowlist matching `deny.toml`), and add a CI step that fails when the generated output drifts from the committed file. Include an MPL-2.0 source-availability statement. Update the MPL comment in `deny.toml` (lines 37-59).
- **Consensus:** 3/3 verifiers

### [Medium] ureq's `rustls` feature bakes in the Mozilla root store instead of using the macOS trust store
- **Location:** `crates/transport/Cargo.toml:18` (the agent is built at `crates/transport/src/lib.rs:39`)
- **Category:** transitive-dependency
- **Why it matters:** In ureq 3.3.0, `features = ["rustls"]` pulls in `rustls-webpki-roots`, so TLS to the OTS server and the relay is verified against the compiled-in webpki-roots 1.0.8 bundle. As a result:
  1. CA changes reach users only through app releases.
  2. Self-hosted instances behind a private or enterprise CA fail with no override. This conflicts with the self-hosting goal the verifiers cite from `docs/spec/design/05-technical-direction.md:146-148`, whose wording should be confirmed there.
  3. Keychain trust settings and macOS revocation/CT policy are bypassed.
- **Suggested fix:** Switch to `features = ["rustls-no-provider", "platform-verifier"]` with the ring provider, set the verifier in the agent config, and then drop webpki-roots and the CDLA allowance from `deny.toml`. If pinned roots are intentional, record that decision and its consequence for self-hosted CAs in an ADR, and add a test that asserts which verifier is in use.
- **Consensus:** 3/3 verifiers
