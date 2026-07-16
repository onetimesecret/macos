# docs/spec/feature/byoe/local-service.md
---

# Feature Assessment: CompanionApp as a Local BYOE Encryption Service

Status: **draft**, for review · 2026-07-16
Companion to: [`README.md`](README.md) (the in-process create-path spec).
Protocol source of truth: the `byoe/1` spec in the `byoe-proxy` repository
(`docs/byoe-protocol.md`). This document assesses a second topology — the
running app **serving** the `byoe/1` HTTP surface on loopback so other
local clients (the OTS web app in a browser, CLIs, scripts) can use the
customer's master key — and records feedback on the protocol itself that
the topology surfaces.

## Relationship to the existing BYOE spec

The create-path spec rejected the *proxy-client* topology (the app POSTing
plaintext to a remote proxy). This is the third topology — the app **is**
the proxy — and it is additive, not a replacement:

- The app's own promotions keep the in-process path: `promote` calls
  `byoe::seal` directly. No loopback round trip for ourselves.
- The service is a thin HTTP skin over the **same** `crates/byoe`
  construction, for clients that are not this app. Nothing forks.

What it buys: a customer who runs the companion gets BYOE in the **web
create flow** (and any local tooling) without deploying and operating a
`byoe-proxy` instance. The Keychain-held master key becomes usable by
every surface on the machine, which is exactly the "browser cannot safely
hold a long-lived master key" gap the proxy exists to fill — solved with
software the user already runs.

What it costs: the app grows an **inbound network surface** for the first
time. Most of this document is about paying that cost honestly.

## Proposed shape in this codebase

Three layers, following the sans-IO discipline `ots-client` +
`crates/transport` already model:

1. **`crates/byoe`** (unchanged from the create-path spec). The pure
   `byoe/1` construction: `seal(master_key, kid, plaintext) →
   (envelope_json, link_key)`, plus `open` if decrypt is ever served.
   `ring` for HKDF/CSPRNG, RustCrypto `chacha20poly1305` for XChaCha.
   Both topologies call this crate; the vectors test it once.

2. **`crates/byoe-service`** (new, sans-IO). A pure request handler,
   `handle(&self, HttpRequest) → HttpResponse`, implementing the
   `byoe/1` routes: the well-known manifest, `/v1/handshake`,
   `/v1/encrypt`, and a health probe. Keys arrive through the existing
   `CredentialStore` trait (`crates/credentials`), so the crate builds
   and tests on Linux with `InMemoryCredentialStore` and never opens a
   socket in CI. All request/response bodies that can carry plaintext
   live in `Zeroizing` buffers, mirroring `ConcealPayload`.

3. **A loopback listener** (new, the only crate that binds). A small
   synchronous HTTP/1.1 server on `127.0.0.1` only — never `0.0.0.0`.
   `tiny_http` (MIT) is the candidate dependency; hand-rolling HTTP
   parsing is the kind of code the `unsafe_code = deny` posture cannot
   protect us from getting subtly wrong, so a small audited dependency
   beats artisanal parsing here (the opposite call from `base64.rs`,
   deliberately). One accept thread, a small bounded pool, strict caps:
   body size (~1 MiB), header count, read/write timeouts, connection
   limit. Every limit refuses loudly rather than degrading.

FFI seam and shell:

- `companion_byoe_service_start(handle, requested_port) → bound_port`
  (0 on failure), `companion_byoe_service_stop(handle)`,
  `companion_byoe_service_status_json(handle)`. The service is **off by
  default** and starts only on an explicit Settings toggle — the enable
  gesture is also the right moment for the Keychain ACL prompt
  (ADR-0004's concern), so a background web request never provokes a
  surprise dialog.
- Settings (`shell/Sources/CompanionApp/SettingsWindow.swift`): the
  toggle, the bound port, and the same master-key/`kid` provisioning
  surface the create-path spec already needs.

Posture bookkeeping this forces:

- **The one-outbound-destination invariant survives untouched** — the
  guard in `crates/transport` governs outbound requests, and the service
  makes none. But doc 05's "Network at rest: zero connections" line and
  the frugality budget need an amendment: *zero outbound at rest; inbound
  loopback listener only while the user has the service enabled*.
- If the App Sandbox lands (doc 06 §13), the listener needs the
  `com.apple.security.network.server` entitlement. Worth deciding
  sandbox-or-not before shipping this, since retrofitting entitlements
  churns notarization.

## The threat model of a loopback listener

This is where the create-path spec's conclusions invert, and the most
important content of this assessment.

### Server impersonation (port squatting) — the local killer

Any process running as any user can bind `127.0.0.1:<port>` first. The
web page then POSTs **plaintext** to whatever answered. A remote proxy is
authenticated by TLS + its domain name; localhost has neither. So the
Ed25519 identity and `/v1/handshake`, which the create-path spec dropped
as "proves nothing for an in-process encryptor", come **back** for this
topology — a local service needs them *more* than a remote proxy does:

- The app holds an Ed25519 identity key in the Keychain (a third account
  alongside the master key and `kid`).
- The public key is registered with the OTS account/domain config (the
  manifest flow the protocol already defines for remote proxies).
- The web client sends a challenge nonce and verifies the signature
  **before any plaintext leaves the page**. A squatter binds the port and
  wins nothing.

See protocol feedback №5 for what the handshake needs to sign for this to
be sound.

### Browser reachability and cross-origin hygiene

- Modern browsers treat `http://127.0.0.1` as a potentially-trustworthy
  origin, so an HTTPS OTS page may fetch it without mixed-content
  blocking. Chrome's Local/Private Network Access additionally requires
  the preflight response to grant it
  (`Access-Control-Allow-Private-Network: true`); the handler must
  implement that preflight.
- CORS allowlist is **exactly** the configured connection's origins (the
  server URL and its share domains) — never `*`, never credentials.
- Reject any request whose `Host` is not the bound loopback address
  (kills DNS-rebinding, where `evil.example` resolves to `127.0.0.1` and
  the browser happily sends a same-"site" request).

### The oracle problem — why this stays encrypt-only

CORS constrains **browsers only**. Any native process running as the user
can POST to the socket directly; no loopback design changes that. So the
question is what the worst local caller can extract:

- **`/v1/encrypt`**: they can create envelopes under the master key.
  That leaks nothing and forges nothing (envelopes carry no authenticity
  claim — anyone with the key material could always mint one). Modest
  exposure, acceptable.
- **`/v1/decrypt`**: a **decryption oracle**. Any code running as the
  user, holding an envelope + link (say, scraped from a Slack message on
  the same machine), decrypts without touching the Keychain. That
  collapses BYOE's two-key story on this machine to "can reach a socket".
  The create-path spec's create-only scope is therefore not just a scope
  cut — for the local service it is a security requirement. **v1 serves
  no `/v1/decrypt`.** If reveal-via-companion is ever wanted, each
  decrypt needs an explicit per-request user approval in the app UI
  (and/or paired, scoped client tokens), which is a different feature
  with its own spec.

### Plaintext transits the loopback

The in-process path never puts plaintext on a socket; this path puts it
on loopback HTTP. That is invisible to other users' processes but it does
mean plaintext enters the listener's buffers. Disciplines: `Zeroizing`
request bodies end-to-end, no request/response logging beyond status +
route, size caps, and uniform error bodies that never echo input.

## Incremental plan

1. **Phase 0 — `crates/byoe`** with reference vectors (already the
   create-path spec's first step; shared by both topologies).
2. **Phase 1 — in-process create path** (the existing spec, unchanged).
   Ships value to app users as soon as the server accepts
   `encryption_mode:"byoe"`.
3. **Phase 2 — `crates/byoe-service` + listener + FFI + Settings.**
   Requires the handshake/identity work and, on the OTS side, the web
   create flow learning to discover and call a local encryptor. The
   sans-IO handler can be built and vector-tested well before the web
   side exists.

Phase 2's honest blocker mirrors the create path's: it delivers nothing
until the **web app** knows how to find, verify, and call the local
service. That is a protocol + web-client work item, not a companion one,
and it should land in the `byoe/1` spec rather than be invented here
(feedback №5–6).

## Feedback on the `byoe/1` protocol

Read through this repo's rendering of the protocol (the create-path spec;
the `byoe-proxy` repo is not in this session's scope — happy to re-check
against `docs/byoe-protocol.md` directly).

**What is right and worth keeping:**

- The layered KDF is sound: a fresh random 128-bit `link_key` as HKDF
  salt plus `pid`-scoped info yields a unique `data_key` per secret, so
  the random 24-byte XChaCha nonce is belt-and-braces rather than
  load-bearing — nonce misuse is structurally off the table.
- AAD as a fixed-order byte string instead of canonical JSON avoids the
  entire canonicalization swamp, and binding `kid`/`pid` into it blocks
  header swapping cheaply.
- The split-capability model (master key never leaves the operator,
  link key never touches storage) is a genuine two-key design: the OTS
  store alone yields nothing; a leaked link alone yields nothing.
- Self-describing envelopes (`v`, `alg`, `kid`) make rotation additive.

**Issues and suggestions, roughly by severity:**

1. **AAD delimiter injection.** The AAD concatenates operator-influenced
   strings (`kid`, and `pid` if a client is buggy) with `;` and `=` as
   structure. If `kid` may contain those bytes, distinct `(kid, pid)`
   pairs can serialize to identical AAD (e.g. `kid = "a;pid=b"`). The
   spec should constrain `kid` and `pid` to a safe alphabet
   (`[A-Za-z0-9._-]`, length-capped) and require encryptors *and*
   decryptors to reject violations. Cheap fix, closes a real class.
2. **Handshake should be client-verifiable, not only OTS-verifiable.**
   The identity/handshake exists so a proxy can prove itself to OTS. The
   local-service topology shows the client side matters more: any
   deployment where plaintext is POSTed to an encryptor needs the
   *client* to verify the encryptor before sending, and localhost has no
   TLS to lean on. Define the handshake as challenge-response the calling
   page can verify — signature over (client nonce ‖ intended origin ‖
   endpoint address), so a signature can't be replayed or relayed from a
   different port or origin. One mechanism then serves remote and local
   deployments.
3. **`/v1/decrypt` deployment guidance.** The endpoint is a decryption
   oracle for anyone who can reach it. The spec should say so and
   require access control by deployment class: network ACL / auth for
   remote proxies; **disabled or per-request-consented** for anything
   listening on a workstation's loopback. Also: uniform error responses
   on decrypt failure (bad tag vs bad `kid` vs malformed envelope should
   be indistinguishable to the caller) — costs nothing, removes a
   probing dimension.
4. **Consider a derive-only mode (`byoe/1.1`).** `/v1/encrypt` moves
   plaintext into the service. An optional key-issuance endpoint — client
   sends `pid` (and receives `link_key` + `data_key`, or sends its own
   `link_key` and receives `data_key`) — lets the *client* run the AEAD
   locally, so plaintext never crosses HTTP and never resides in the
   service. The trust boundary is identical (the service holds the master
   key either way); what shrinks is the plaintext handling surface, which
   is most valuable exactly in the local topology. Cost: web clients need
   XChaCha20-Poly1305, which WebCrypto lacks — a vetted JS/WASM
   implementation is required, so this is a companion endpoint, not a
   replacement.
5. **Declare passphrase layering as "outside".** Server-side passphrase
   gating of the opaque envelope is the only option that keeps the
   envelope opaque, keeps the reference decrypt path working, and needs
   no protocol change. Declaring it would unblock this app's open
   question №3 (the UI currently gates the two features against each
   other purely because the protocol is silent).
6. **Length leakage.** Ciphertext length reveals plaintext length to OTS
   and to anyone holding the envelope; secret lengths can identify
   formats (API-key families, password policies). Worth an explicit
   threat-model note now, and an optional padding scheme (bucketed, or
   Padmé) in a future profile.
7. **Versioning and validation discipline.** The envelope carries both
   `v: 1` and the full `alg` string; the spec should state which gates
   parsing (suggest: `v` selects the envelope schema, `alg` must match a
   registry entry, anything unknown is a refusal, never a fallback). Two
   implementer footguns worth spelling out: the decoded nonce must be
   exactly 24 bytes, and `pid` is a uniqueness/binding token only — it
   authorizes nothing and decryptors must not treat it as a check that
   something external "matches".
8. **Minor.** 16-byte `link_key` (128-bit capability) is adequate and
   keeps links short; if the fragment encoding is ever revisited,
   base64url would shave ~25% off the fragment versus hex — not worth
   churn on its own.

## Open questions (this topology's own)

1. **Port strategy.** A fixed registered default port (simplest for the
   web client to probe) vs dynamic port + discovery. Leaning fixed
   default, user-configurable, with the manifest endpoint confirming
   identity and available `kid`s.
2. **Non-browser clients.** CLIs bypass CORS naturally and today would be
   trusted implicitly (same-user processes). Is that acceptable for
   encrypt-only (leaning yes, per the oracle analysis), or does v1 want
   paired tokens from the start?
3. **Sandbox decision ordering.** The `network.server` entitlement
   question (doc 06 §13) should be settled before this ships.
4. **Web-side ownership.** Discovery, handshake verification, and the
   encrypt call in the OTS web app are protocol/web work items — where do
   they get specced and tracked?
