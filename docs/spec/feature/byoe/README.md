# docs/spec/feature/byoe/README.md
---

# Feature Spec: Bring Your Own Encryption on Create

Status: **draft**, for review · 2026-07-15
Scope: the **create/conceal path only** (the encrypt half). Reveal is a
recipient concern and is explicitly out of scope (see Non-goals).
Governs against: [`../../design/05-technical-direction.md`](../../design/05-technical-direction.md)
(concealing, security posture) and
[`../../design/04-interaction-model.md`](../../design/04-interaction-model.md)
(the conceal gesture). Protocol source of truth: the `byoe/1` spec in
the `byoe-proxy` repository (`docs/byoe-protocol.md`).

## Summary

BYOE lets the companion encrypt a secret **locally, under a customer-held
master key**, before it is concealed to Onetime Secret. OTS stores an
opaque envelope it can never open. Decryption at reveal needs two
independent keys: the **master key** (held only by the app, in the
Keychain) and a per-secret **link key** (minted fresh per conceal,
carried only in the share URL fragment). Neither key alone opens
anything; the OTS store holds only ciphertext.

This spec adapts the `byoe/1` protocol to a native app. The protocol was
written around a small **proxy** the customer runs, because a browser
cannot safely hold a long-lived master key. A native macOS app with
Keychain is precisely the environment where it can, so the proxy
collapses into the app: no second outbound host, no CORS surface, the
"OTS is the only conceal destination" invariant
(`crates/ffi/src/conceal.rs`)
stays intact.

## Non-goals

- **Reveal / decrypt.** The recipient reveals via the web or a proxy, not
  via this app. The app never implements `/v1/decrypt`. Create-only is
  coherent: the app produces envelopes, other surfaces open them.
- **The proxy topology.** No `/v1/encrypt` round trip to a customer
  service. The construction runs in-process.
- **Proxy identity.** The Ed25519 identity keypair, `/v1/handshake`, and
  the `/.well-known` manifest exist so a remote proxy can prove itself to
  OTS. An in-process encryptor proves nothing to anyone, so these are
  dropped from scope.
- **Passphrase + BYOE together.** Layering order is unresolved in the
  protocol. v1 of this feature gates the two against each other in the UI
  (a chip is BYOE-encrypted **or** passphrase-gated, not both).
- **Image chips.** BYOE is a text-envelope construction; image chips are
  already refused on conceal (`crates/ffi/src/lib.rs`, chip-conceal).

## The one decision: local master key, no proxy

Two topologies were considered; this feature takes the first.

1. **Local master key (chosen).** The app holds the 32-byte master key in
   the Keychain and runs the construction itself. One outbound
   destination preserved, no proxy to deploy, testable without a network.
2. **Proxy client (rejected for v1).** The app POSTs plaintext to the
   customer's proxy `/v1/encrypt`, then conceals the returned envelope. A
   second TLS/auth/CORS surface and a second host the conceal path must
   reach. It buys nothing a native app needs, since the reason the proxy
   holds the key (an untrustworthy browser) does not apply here.

## Cryptographic construction (`byoe/1`)

The profile is fixed at `xchacha20poly1305-hkdf-sha256`. The recipient
decrypts via the reference proxy or the web, so the envelope must be
**bit-exact `byoe/1`**. The profile is not negotiable from this side.

Inputs:

- `master_key`: 32 bytes, customer-generated, hex in the Keychain,
  identified by `kid` for rotation.
- `link_key`: 16 bytes, CSPRNG per secret, hex in the URL fragment
  (`#k=<hex>`), never stored server-side anywhere.
- `pid`: payload id, UUIDv4 minted at compose time. Binds the envelope to
  one payload before the OTS secret id exists.

Derivation and seal:

```
data_key = HKDF-SHA256(ikm  = master_key,
                       salt = link_key,
                       info = "ots/byoe/v1|" + pid)          // 32 bytes
nonce    = random(24)
aad      = "v=1;alg=xchacha20poly1305-hkdf-sha256;kid=<kid>;pid=<pid>"
ct       = XChaCha20-Poly1305.Seal(data_key, nonce, plaintext, aad)
```

The AAD is a fixed-order semicolon string, byte-for-byte, not canonical
JSON. Any header tampering (a swapped `kid`, a replayed `pid`) fails the
tag.

Envelope (what OTS stores as the secret value, opaque):

```json
{
  "v": 1,
  "alg": "xchacha20poly1305-hkdf-sha256",
  "kid": "2026-07-primary",
  "pid": "0d1f2c9a-…",
  "n":  "<base64 24-byte nonce>",
  "ct": "<base64 ciphertext+tag>"
}
```

## The crypto gap this introduces

The only crypto crate in the tree is `ring` 0.17 (state-file sealing,
`crates/ffi/src/persist.rs`). Everything the construction needs is
already covered **except the AEAD**:

| Need | Source |
| --- | --- |
| HKDF-SHA256 (salt, info) | `ring::hkdf` (present) |
| CSPRNG (link_key, nonce) | `ring::rand::SystemRandom` (present) |
| base64 (std, padded) | `crates/ots-client/src/base64.rs` (present) |
| UUIDv4 (`pid`) | minted from 16 random bytes + version/variant bits, no crate |
| **XChaCha20-Poly1305 seal** | **new dependency** |

`ring` implements ChaCha20-Poly1305 with a **12-byte** nonce, not the
**24-byte** XChaCha variant the profile mandates, and exposes no HChaCha
primitive to build it from. Add the RustCrypto **`chacha20poly1305`**
crate (its `XChaCha20Poly1305`): MIT/Apache (clears `deny.toml`), one
focused dependency. The workspace `unsafe_code = deny` lint is per member
crate and does not reach dependencies, so the crate's internal SIMD is
fine.

## Change map

Grounded in the current create path
(`companion_chip_conceal` / `companion_sheet_conceal` →
`conceal::conceal` → `ots_client::Client::conceal` → `ureq`).

- **New logic crate `crates/byoe`.** No macOS deps, Linux-testable,
  matching existing crate hygiene (`Cargo.toml` workspace). One pure
  entry point: `seal(master_key, kid, plaintext) -> (envelope_json,
  link_key)`. The whole construction and its round-trip tests live here.
  Depends on `ring` (HKDF, RNG) and `chacha20poly1305`.
- **`crates/credentials`.** Two new Keychain accounts alongside the
  existing `state-key` precedent (`crates/ffi/src/persist.rs`): the master
  key and the `kid`. Same `SERVICE` scope
  (`com.onetimesecret.companion`). No contract change; the
  `CredentialStore` methods already cover it.
- **`crates/ots-client/src/types.rs`.** Add an `encryption_mode` field to
  `ConcealPayload` and its hand-written `Serialize` impl, so the wire body
  carries `"encryption_mode":"byoe"` and `secret` = the envelope string.
- **`crates/ffi/src/conceal.rs` (`conceal`).** When BYOE is enabled for
  the connection, seal the staged payload into the envelope, swap it into
  `ConcealPayload`, and thread the returned `link_key` out through
  `Concealed`.
- **`crates/ots-client/src/api.rs` (`share_link`) and
  `crates/ffi/src/lib.rs` (`finish_conceal`).** Append `#k=<hex
  link_key>` to the clipboard link. The `link_key` is the sensitive half
  and today nothing flows it out of `conceal`; this is real (small)
  plumbing. The fragment rides in the URL and is never written to the
  chip.
- **Shell / Settings (`shell/Sources/CompanionApp/SettingsWindow.swift`).**
  Per-connection BYOE toggle plus master-key provisioning (generate or
  import) and `kid`. Gate against the passphrase chip.

## Key custody and rotation

- The master key rests in the Keychain under the app's `SERVICE`, wrapped
  in `Zeroizing` on load like every other secret in the tree. It never
  touches disk in plaintext and never crosses the FFI seam outward.
- The app is **create-only**, so rotation is unconstrained from its side:
  a new master key means a new `kid` and new envelopes. It never needs to
  retain old keys, because it never decrypts. Outstanding links stay
  valid only as long as whatever decrypts them (proxy/web) still holds the
  matching `kid` key. That retention is the operator's concern, not the
  app's.
- One master key per **connection** (server + org), not one global key, so
  a customer with two workspaces cannot cross-decrypt. (Open question 2.)

## Security posture

- Plaintext is sealed in-process and the envelope replaces it in the
  payload before any socket opens; on failure nothing has left the sheet,
  matching the existing conceal contract.
- The clipboard now carries the decryption half in the fragment. The link
  write is already transient-marked (`WriteOptions`), but BYOE raises the
  stakes: the link is now sufficient (with proxy reach) to reveal. Note it
  in the UI so the user treats the link as the secret.
- Error strings carry no key or plaintext material, unchanged from
  `conceal`.
- No new outbound destination; the network boundary
  (`crates/transport`, TLS-only, single host) is untouched.

## The external dependency (the honest blocker)

The encrypt half is inert until **two server-side things exist**:

1. V3 `conceal` accepts `encryption_mode:"byoe"` and stores the envelope
   opaque (normal storage pipeline, no special casing).
2. The reveal path decrypts (web reveal calling a proxy, or equivalent).

Until both land, a BYOE secret created by the app is **un-revealable**:
the recipient sees envelope JSON with no way to open it. The app can
build, unit-test, and vector-test the create path in isolation, but it
delivers zero end-to-end value ahead of the server and reveal work. This
is the same surface the protocol names under "What V3 needs".

The app must also **know** whether a given server supports BYOE before
offering it. Options (open question 4): a capability probe against the
status/manifest endpoint, or an explicit per-connection opt-in with a
refuse-vs-fallback policy when unsupported.

## Test plan

- **`crates/byoe` round trip against reference vectors.** Seal in the
  crate, decrypt with the `byoe-proxy` reference `/v1/decrypt` (or its
  test vectors), proving bit-exact `byoe/1`. This is the piece with real
  cryptographic risk and it needs no OTS server.
- **Tamper tests.** A flipped bit anywhere in the envelope, and a swapped
  `kid`/`pid`, must fail the tag (mirrors `persist.rs` tamper tests).
- **Wire shape.** `conceal` with BYOE on produces `encryption_mode:"byoe"`
  and an envelope-valued `secret`, asserted through the existing
  `MockTransport` in `conceal.rs`.
- **Link assembly.** The clipboard link ends in `#k=<hex>` and the chip
  retains only the receipt id (no link, no key).
- **Off-macOS.** The crate and wire changes build and test on Linux; the
  Keychain custody path is exercised on device, per existing practice.

## Open questions

1. **Master-key provisioning UX.** Generate in-app (app is the root of
   trust) or import (operator controls the key across surfaces)? Is `kid`
   user-set or derived?
2. **Key granularity.** One key per connection (leaning) vs one global
   key. Per-connection prevents cross-workspace decryption; global is
   simpler.
3. **Passphrase layering.** Undecided in the protocol. v1 gates them
   mutually exclusive; revisit once the protocol decides inside vs
   outside.
4. **Server capability discovery and fallback.** How the app learns a
   server accepts BYOE, and what it does when it does not (block vs plain
   conceal). Mirror the protocol's unreachable-proxy policy.
5. **Clipboard stakes.** The fragment now carries a decryption capability.
   Is transient-marking enough, or does BYOE warrant a distinct
   copy-out affordance or warning?
6. **`context.domain` binding.** The protocol leaves domain out of the KDF
   in v1. If a later profile binds it, the app follows; nothing to decide
   now beyond tracking it.

## Effort estimate

Roughly **2 to 3 days** of Rust for `crates/byoe`, the wire field, and the
conceal/plumbing changes, plus a modest Settings surface for key custody.
The work is fully testable against the reference proxy without an OTS
server, but ships no user-visible value until the server and reveal sides
exist.

## References

- `byoe/1` protocol spec: `byoe-proxy` repo, `docs/byoe-protocol.md`.
- Reference implementation and test vectors: `byoe-proxy` repo.
- Conceal architecture: [`../../design/05-technical-direction.md`](../../design/05-technical-direction.md),
  `crates/ffi/src/conceal.rs`, `crates/ffi/src/lib.rs`.
- State-file crypto precedent (`ring`, Keychain custody):
  `crates/ffi/src/persist.rs`.
