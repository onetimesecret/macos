# Sync plaintext buffer foundations (#256)

Implementation and integration notes, not an accepted specification or a
security-policy amendment. No new envelope kinds, scheduling, admission,
withdrawal, retry, epoch, or relay behavior is introduced here.

## Authority read

- [ADR-0001](../../docs/adr/0001-rust-core-thin-shell.md) is accepted. Its
  Context states: “the security posture — deterministic zeroization of secret
  buffers — must not depend on the outcome”. That is the accepted posture
  relevant to this change, not an accepted exact-allocation rule.
- [ADR-0021](../../docs/adr/0021-multi-device-sync-over-a-blind-relay.md) is
  accepted. Its Decision history states: “The protocol specification is the
  authoritative message-shape record.” It links the
  [relay protocol](../../docs/spec/feature/sync/relay-protocol.md).
- [ADR-0012](../../docs/adr/0012-framing-threat-boundary-and-persistence-model.md)
  is proposed, not accepted.
- [Law 0004](../../docs/law/0004-secret-plaintext-never-reallocates.md) is draft,
  not accepted. Exact allocation here implements the requested #256 direction;
  it does not establish that draft as authority or settle its acceptance.
- [ADR-0058](../../docs/adr/0058-a-sealed-object-never-stalls-a-pages-sync.md)
  and the client protocol are proposed/draft, not accepted authority for new
  sync behavior. #257 is not implemented here.

## Interfaces for integration

- `secret_json::to_zeroizing_vec<T: Serialize + ?Sized>(&T)` returns
  `serde_json::Result<Zeroizing<Vec<u8>>>`. The first serialization counts;
  the second writes through a fixed-size slice, not a growable writer.
  Longer or shorter second-pass output returns an error in release builds too.
  Capture any exports or changing values before calling it. It only controls
  the output allocation: custom `Serialize` implementations must manage their
  own scratch. Same-length content changes between passes are not detected.
- `ByteBlob` privately owns `Zeroizing<Vec<u8>>`. Construct with
  `ByteBlob::from(Vec<u8>)`, `ByteBlob::from(&[u8])`, or
  `ByteBlob::from(Zeroizing<Vec<u8>>)`. The last form transfers an existing
  zeroizing allocation without copying. `as_slice()` and `AsRef<[u8]>` borrow
  bytes without exposing vector mutation. `Clone` creates an independent
  zeroizing owner; `Debug` prints `ByteBlob([REDACTED])`. Explicit `Zeroize`
  and the `ZeroizeOnDrop` marker are available.
- `DeltaEnvelope::encode()` now returns
  `serde_json::Result<Zeroizing<Vec<u8>>>` through the generic serializer
  above. When an envelope fails to encode, the publish path in
  `ffi/src/sync_session.rs` raises a diagnostic fault and publishes the
  rest of the batch. A page's ops go back to `ffi/src/sync_driver.rs`, which
  rewinds that page's export cursor to the acknowledged one so the next
  sweep exports the gap again; an expiry, hold or terminal envelope stays
  queued; a ceremony message is dropped.
- `pad::pad(&[u8])` now returns `Zeroizing<Vec<u8>>`, allocated at the bucket
  size before copying plaintext. Prefix, payload, and zero suffix are unchanged.
- These returned `Zeroizing<Vec<u8>>` values still expose vector mutation;
  callers must not grow them after encoding/padding. They are not redacted
  debug types and must not be logged as plaintext.

Existing call sites outside this crate use `ByteBlob::from` and `as_slice()`.
The FFI driver changes are test fixture adaptations only. `gop.rs` is unchanged.

## Buffer inventory (code inspection)

| Buffer | Content | Disposition in this change |
| --- | --- | --- |
| `SyncSession::outbox` ops | Exported page document bytes | Slice copy into an exact-size `ByteBlob`; `retain`, queue clearing and session drop run its zeroizing field's destructor |
| Other `ByteBlob` values | Signed terminal bytes or per-device encrypted ceremony entropy | Same owner type; base64 wire form unchanged |
| Clone of a `ByteBlob` | Same bytes in a separate allocation | Zeroizing ownership, no vector-growth API |
| Encoded envelope JSON | Base64 ops, page identifiers, policy/control | Two passes into an exactly sized zeroizing destination |
| Encoding base64 scratch | Base64 representation of the source blob | Exact-capacity zeroizing string, including during the counting pass |
| Decoding base64 output | Decoded page ops or marker/entropy bytes | Exact-length zeroizing vector before decoding starts; errors discard that owner |
| Decoder's encoded string | Base64 representation of source bytes | Borrow when offered a string slice; immediately wrap an owned string when offered ownership; upstream scratch remains unresolved below |
| Padded envelope | Length prefix, encoded plaintext, zero suffix | Fixed-length zeroizing allocation |
| GOP seal/open work buffers | Padded envelopes and key-frame plaintext | Existing `persist::seal_body`/`open_body` use zeroizing work buffers; inspected, not changed here |
| Published batches / relay request bodies | Ciphertext and public routing fields | Existing handling unchanged; ops do not enter the in-flight `restate` list |

For #257, reuse the serializer, not ordinary `serde_json::to_vec` or a content
`serde_json::Value`. Content-bearing fields need zeroizing owner types and
redacted debug separately; an outer zeroizing JSON result does not fix a
plain `String` field or allocations inside its deserializer.

## Remaining blockers and limits

**SYNC-256-B1 — serde_json escaped-string scratch (code-inspected, unresolved).**
`serde_json` 1.0.150's `Deserializer` has a private ordinary `Vec<u8>` scratch.
`read::SliceRead::parse_str_bytes` and `parse_escape` append decoded escaped
characters to it. A valid escaped base64 value such as `"\/\u0077=="` therefore
still uses unwiped library scratch before `ByteBlob` receives it. Malformed
strings can also exit through this path. There is no public scratch-wiping
hook. A wipe-aware parser or upstream/library change is needed; rejecting
escaped strings would change accepted input and is not done here.
Since #257 a `Metadata` entry's name (base64 in a `ByteBlob`) and a
`NoteOps` envelope's ops decode through the same `DeltaEnvelope::decode`,
so an escaped value in either passes through this scratch too.

**SYNC-256-B2 — Serde tagged-enum intermediates (code-inspected, unresolved).**
`serde` 1.0.228's `private::de::ContentVisitor::visit_str` creates an ordinary
`Content::String`. The internally tagged envelope enums and flattened control
payload can buffer escaped values there. An owned base64 string reaching
`ByteBlob::visit_string` is wrapped and zeroized, but copies on rejection,
unknown fields or borrowed replay are not all under this crate's control.
This is distinct from B1; zeroizing only the JSON reader's scratch would not
remove it. `Metadata` and `NoteOps` are variants of the same internally
tagged `DeltaEnvelope`, so an escaped name nested in a `Metadata` entry
and an escaped `NoteOps` ops value can be buffered there too before a
`ByteBlob` owns them.
A replacement decode path needs compatibility tests for field order,
escapes, ignored fields and malformed input before integration.

**SYNC-256-L1 — ownership boundaries (inspected limitation).** Taking an ordinary
`Vec` into `ByteBlob` does not retroactively wipe allocations it previously
abandoned. Slice inputs remain the caller's responsibility. The serializer does
not manage its source value's storage, and none of these buffers adds page
locking or clears OS/rendering copies. OAuth parsing and other crates' content
processing are not changed or audited by this patch.

**SYNC-256-L2 — erasure verification (untested).** Tests do not read freed
memory or establish OS-level erasure. They check types, independent ownership,
explicit zeroization of a live owner, capacity, bytes, errors and queue effects.
Destructor behavior is inferred from the zeroizing field and the inspected
`zeroize` 1.9.0 implementation, not a post-free memory assertion. No allocator
instrumentation, live relay, Swift UI or deployment probe was run.

B1 and B2 prevent reporting the entire inbound JSON path as zeroizing. They
remain blockers to a blanket sync-plaintext interpretation of draft Law 0004.
This document does not decide whether those residual exposures are acceptable.

## Validation

Run against the code accompanying this note:

- `cargo test -p companion-sync`: **51 passed**, no failures; zero doc tests.
- `cargo test -p companion-ffi sync_session::tests`: **29 passed**, no failures,
  296 filtered out.
- `cargo test -p companion-ffi sync_driver::tests`: **47 passed**, no failures,
  278 filtered out.
- `cargo test -p companion-ffi gop::tests`: **6 passed**, no failures,
  319 filtered out.
- `cargo clippy -p companion-sync -p companion-ffi --all-targets --no-deps -- -D warnings`:
  **passed**.

New checks include literal wire fixtures for all existing envelope variants;
escaped metadata/base64; base64 tails and lengths 0–257; redacted debug and
independent clones; exact JSON/padding capacity; either-pass serialization
errors; longer/shorter second-pass output; and a second seal refusing after the
first succeeded, followed by withdrawal and publication of only the surviving
page. The latter uses real GOP encryption with an injected seal refusal and an
in-memory relay. Existing targeted tests exercise expiry withdrawal, 401 retry,
409 batch discard, stale epochs, and refused frame seals.

An initial FFI compile found one remaining private-field test access; it was
changed to `as_slice()` before the passing commands above. No full workspace
suite or allocator-level erasure test was run.
