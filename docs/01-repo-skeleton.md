# 01 — A prescription for initializing the app and repo skeleton

> **Status:** prescriptive. This document specifies *how the repository and the
> application skeleton should be stood up* — the layout, the crates, the trust
> boundary, the toolchain, and the ordered steps. It does not yet build the
> product; it makes sure the first line of product code lands in a structure
> that already enforces the project's security and accessibility commitments.
>
> Read [`00-problem-space.md`](00-problem-space.md) first — this document
> assumes its principles as constraints.

---

## 1. Decisions this skeleton assumes

The skeleton is not architecture-neutral. It bakes in four decisions that the
discussion leading up to this document settled. They are recorded here as
premises so a future reader can see *what the shape depends on* and reopen it if
a premise changes.

| # | Decision | Why | Reversibility |
|---|----------|-----|---------------|
| D1 | **Rust core for anything that touches secret bytes.** | Rust makes buffer lifecycle deterministic: one owner, `zeroize`-on-drop, `mlock` on the page, accidental copies rejected at compile time. Swift's `String`/`Data` are copy-on-write value types; ARC/autorelease and `NSString`/`NSPasteboard` bridging leave duplicates you don't control, and there is no CryptoKit-blessed way to zeroize a `String`. The guarantee is *structural* in Rust and only *approximated by hand* in Swift. | One-way door. |
| D2 | **Native Swift/SwiftUI for the UI shell.** | First-class VoiceOver (the Stage-1 accessibility gate, satisfied for free), native menu-bar `NSStatusItem`, edge-docked `NSPanel`, Keychain/Secure Enclave, and OS-native motion/contrast settings — none of which a pure-Rust GUI stack matches today, and all of which a WebView (Tauri) compromises on the hygiene axis. | Two-way door (the UI can be re-skinned without touching the core). |
| D3 | **A hard FFI boundary: plaintext secret bytes never enter Swift-managed memory.** | This is the whole reason for the split. See §3 — it is a law, not a guideline. | One-way door. |
| D4 | **macOS-first, but the core is portable.** | The Rust core carries no Apple assumptions, so a future Windows/Linux companion — or reuse by other OTS tooling — reuses one audited core. | The core stays portable by construction; the UI is deliberately Apple-only. |

> The GUI-framework *gate* framework from the technology-selection discussion
> still applies to any future reconsideration. What this document does is commit
> to the **Rust-core + Swift-UI hybrid** as the working direction so the skeleton
> can be concrete. If the accessibility spike (§10) invalidates a premise, this
> doc changes with it.

---

## 2. Repository layout

```
macos/
├─ Cargo.toml                 # Rust workspace manifest
├─ rust-toolchain.toml        # pinned toolchain
├─ deny.toml                  # cargo-deny: licenses + advisories
├─ crates/
│  ├─ ots-core/              # THE TRUST CORE — secrets, TTL, crypto, keychain, API
│  │  ├─ Cargo.toml
│  │  └─ src/
│  │     ├─ lib.rs
│  │     ├─ secret.rs         # SecretBuffer: owns bytes, mlock, zeroize-on-drop
│  │     ├─ cell.rs           # SleeperCell, TTL ladder, eviction policy
│  │     ├─ store.rs          # bounded, in-memory set of cells (the "cache")
│  │     ├─ crypto.rs         # primitives; PASETO later
│  │     ├─ keychain.rs       # credential storage via security-framework
│  │     └─ api/              # Onetime Secret v3 client (conceal)
│  │        ├─ mod.rs
│  │        └─ conceal.rs
│  └─ ots-ffi/               # THE ONLY crate exposed to Swift; thin; no secret egress
│     ├─ Cargo.toml
│     └─ src/lib.rs
├─ apps/
│  └─ OTSCache/              # Swift/SwiftUI application shell
│     ├─ Package.swift        # (or OTSCache.xcodeproj — see §7)
│     ├─ Sources/OTSCache/
│     │  ├─ App.swift
│     │  ├─ MenuBarController.swift
│     │  ├─ PanelController.swift
│     │  └─ Views/
│     └─ Resources/
├─ bindings/                  # generated Swift <-> Rust glue (built artifact)
├─ scripts/
│  ├─ bootstrap.sh            # one-command dev setup
│  ├─ build-core.sh           # cargo build -> .xcframework
│  └─ check.sh                # fmt + clippy + tests + deny, locally
├─ .github/workflows/ci.yml
├─ docs/
│  ├─ 00-problem-space.md
│  └─ 01-repo-skeleton.md     # this file
├─ .gitignore
├─ LICENSE
└─ README.md
```

**Why three top-level code homes.** `crates/` is portable Rust; `apps/` is
Apple-only Swift; `bindings/` is the generated seam between them. Keeping the
seam in its own directory makes the trust boundary *visible in the file tree* —
you can see exactly what crosses.

---

## 3. The boundary law (D3, expanded)

> **Plaintext secret bytes live only in `ots-core`, in memory that core owns,
> locks, and wipes. They never cross the FFI into Swift.**

Concretely, the FFI surface (`ots-ffi`) may hand Swift only:

- **Opaque handles** — a `CellId` (a `u64` or UUID) identifying a SleeperCell,
  never its contents.
- **Non-secret metadata** — TTL remaining, cell kind (text/image), byte length,
  a redacted preview *if and only if* the core computed it under the same
  lock/zeroize discipline and it is explicitly non-sensitive.
- **Results of an action** — after a successful conceal, the **share URL** and
  receipt (these are *outputs*, not the secret; the plaintext was consumed in
  the core and wiped).
- **Status/error enums** — never error strings that embed secret material.

The core reads the pasteboard itself (via a small platform hook), so even the
*ingest* path keeps plaintext in Rust from the first byte. Swift asks the core
"take what's on the pasteboard into a new cell" and gets back a `CellId`.

**Invariants enforced in `ots-core::secret`:**

- `SecretBuffer` owns a heap allocation, `mlock`s its page(s) so it cannot swap
  to disk, and `zeroize`s on `Drop`.
- It does **not** derive `Clone`, `Copy`, `Debug`, `Display`, `Serialize`, or
  `Deserialize`. It cannot be accidentally duplicated, logged, or serialized.
- The process disables core dumps at startup (`setrlimit(RLIMIT_CORE, 0)`), so a
  crash cannot spill a locked page to a dump.

These invariants are the reason the split exists; a violation is a security bug,
not a style nit.

---

## 4. The Rust workspace

`Cargo.toml` (workspace root):

```toml
[workspace]
resolver = "2"
members = ["crates/ots-core", "crates/ots-ffi"]

[workspace.package]
edition = "2021"
license = "MIT"
rust-version = "1.83"   # pin a real floor; bump deliberately

[workspace.lints.rust]
unsafe_code = "warn"    # allowed only in secret.rs / ffi, and justified inline

[workspace.lints.clippy]
all = "deny"
```

**`ots-core` dependencies (the security-relevant ones are not optional):**

| Concern | Crate | Note |
|---------|-------|------|
| Wipe secrets | `zeroize` (+ `secrecy` for wrapper types) | zeroize-on-drop |
| Lock pages | `libc` (`mlock`/`munlock`, `setrlimit`) or `memsec` | no swap, no core dump |
| Symmetric crypto | RustCrypto (`chacha20poly1305` / `aes-gcm`) or `ring` | audited primitives only |
| PASETO (later) | `pasetors` (pure Rust) or `rusty-paseto` | staged after Basic auth |
| HTTP | `reqwest` with **`rustls-tls`** | avoid pulling secrets through extra native buffers |
| Keychain | `security-framework` | credentials at rest, never plaintext config |
| Serde | `serde`, `serde_json` | **never** applied to `SecretBuffer` |
| Errors | `thiserror` | error types must not embed secret bytes |
| Time | `std` / `web-time`-free | TTL math; no wall-clock surprises in tests |

`ots-ffi` depends on `ots-core` plus the binding generator (§5) and nothing that
would let a secret leak across the seam.

---

## 5. The FFI seam

**Recommended default: `swift-bridge`** (lean, Swift-native type mapping,
keeps the surface small), with **UniFFI** as the proven fallback if we want
Mozilla-maintained codegen and don't mind its marshalling. Either is acceptable
*because secrets never cross* — the marshalling-copies concern that would
normally matter is moot on this boundary, so the choice is about ergonomics, not
safety. **Confirm the pick in the accessibility/vertical-slice spike (§10)**
rather than treating it as settled here.

The seam produces an **`.xcframework`** (static lib + generated Swift) via
`scripts/build-core.sh`, which the Swift app consumes as a binary dependency.
Build both `arm64` and `x86_64` slices; universal by default.

The exported surface stays tiny and auditable. Illustrative shape:

```
// what ots-ffi exposes — handles and outputs only, never plaintext
fn cache_ingest_pasteboard() -> CellId          // core reads pasteboard itself
fn cache_list() -> [CellSummary]                 // id, kind, ttl_remaining, len
fn cell_reset_ttl(id: CellId, rung: TtlRung)     // 7d/3d/24h/8h/3h/1h ladder
fn cell_evict(id: CellId)
fn cell_conceal(id: CellId, opts: ConcealOpts) -> Result<ShareLink, ConcealError>
```

`ShareLink` carries the URL and receipt — outputs, not the secret.

---

## 6. Toolchain pinning

- **`rust-toolchain.toml`** pins the channel and components so every machine and
  CI runner is identical:

  ```toml
  [toolchain]
  channel = "1.83.0"
  components = ["rustfmt", "clippy"]
  targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
  ```

- **Xcode / Swift** version is pinned in `README` and CI (`macos-14`+ runner,
  Swift 6). Record the minimum macOS deployment target in `Package.swift`.
- Commit `Cargo.lock` (this is an application, not a library).

---

## 7. The Swift app

- **SwiftUI + AppKit hooks.** `MenuBarExtra` for the status item; an
  `NSPanel` (non-activating, `.nonactivatingPanel`) for the edge-docked shelf so
  it **never steals focus** (a `00-problem-space` requirement).
- **Consumes `ots-core` only through the `.xcframework`.** No Swift code holds a
  secret; the pasteboard is read *by the core*, not by Swift.
- **Structure:** start as a SwiftPM package (`Package.swift`) for
  CI-friendliness; graduate to an `.xcodeproj` only when signing, entitlements,
  and app packaging require it. Note the crossover in the doc when it happens.
- **Accessibility is not deferred.** Every control ships with an accessibility
  label; the TTL countdown exposes its remaining time as an accessibility value
  and a live-region announcement, not colour/motion alone.

---

## 8. `.gitignore`

Replace the stock Node template with one that ignores Rust, Xcode, and — most
importantly — anything that could carry a secret:

```gitignore
# Rust
/target/
**/*.rs.bk

# Xcode / Swift
.build/
DerivedData/
*.xcuserstate
xcuserdata/
*.xcframework/          # generated by build-core.sh

# Secrets & local credentials — never commit
.env
.env.*
!.env.example
*.pem
*.p12
*.token
secrets/
```

`.env.example` is committed (documents variable *names*, never values). Real
credentials live in the macOS Keychain, per `00-problem-space`.

---

## 9. Quality & security gates (from commit one)

`scripts/check.sh` and `.github/workflows/ci.yml` run the same set:

1. `cargo fmt --check`
2. `cargo clippy --all-targets -- -D warnings`
3. `cargo test` (unit tests for TTL ladder, eviction, and — critically — a test
   that a dropped `SecretBuffer` leaves zeroed memory)
4. `cargo deny check` (license compliance + RUSTSEC advisories)
5. Swift: `swift build` + `swift test`, `swift-format --lint`
6. **Secret scanning** (e.g. `gitleaks`) on every push — a backstop for the
   "never commit a secret" rule.

CI runs on a `macos` runner because the core links `security-framework`.

---

## 10. The bootstrap sequence (ordered)

Do these in order; each step leaves the repo green.

1. **Fix `.gitignore`** (§8) — before any build artifact can be added by accident.
2. **Create the Rust workspace** — root `Cargo.toml`, `rust-toolchain.toml`,
   empty `ots-core` and `ots-ffi` crates that compile.
3. **Land `SecretBuffer` first** — the security core before any feature. Ship it
   with the zeroize-on-drop test. Nothing that handles secrets predates it.
4. **`SleeperCell` + bounded store** — the TTL ladder (`7d/3d/24h/8h/3h/1h`),
   eviction, capacity. Pure Rust, fully unit-tested, no UI.
5. **Keychain + v3 conceal client** — credential storage and the Basic-auth
   `conceal` call, behind the core's API. (PASETO deferred, per `00`.)
6. **Stand up `ots-ffi` + `build-core.sh`** — produce the `.xcframework`; assert
   the exported surface exposes no plaintext (a review checklist item).
7. **Vertical-slice spike** — the single riskiest screen: one SleeperCell in the
   menu-bar panel with a live countdown, driven by the core through the seam.
   **Test it under VoiceOver on real hardware.** This validates D2/D3 and the
   binding choice (§5) before the architecture sets.
8. **Wire CI** (§9) — turn the gates on so regressions can't merge.

Steps 1–2 are pure scaffolding; 3 is where the security posture becomes real; 7
is the go/no-go on the whole hybrid.

---

## 11. Definition of done (skeleton milestone)

- [ ] Repo builds green: `cargo build` and `swift build` both succeed from a
      clean clone via `scripts/bootstrap.sh`.
- [ ] `SecretBuffer` exists, is `mlock`+`zeroize`-backed, and its wipe-on-drop is
      proven by a test.
- [ ] The FFI surface is enumerated and reviewed to expose **no** plaintext
      secret path.
- [ ] `.gitignore` blocks build products and every secret-bearing file type.
- [ ] CI runs fmt, clippy, tests, `cargo deny`, Swift build/test, and secret
      scanning on every push.
- [ ] The vertical-slice spike runs and has been exercised under VoiceOver.

Only when these hold is the skeleton "initialized" — meaning the *next*
contributor can add a feature without having to re-decide any of §1's premises or
re-establish the boundary of §3.

---

## 12. Deferred (not part of the skeleton)

- PASETO auth (Basic auth first, per `00-problem-space`).
- The image → one-time-link path (blocked on the text-only `conceal` endpoint;
  tracked as an open question in `00`).
- App signing, notarization, and distribution.
- Any cross-platform UI. The core stays portable; a second UI is a later
  milestone, not this skeleton.
