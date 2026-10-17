---
documentation_status: needs-review
---

# Issue #257: sealed-object sync review and implementation boundary

**Status: design proposal; not an accepted spec or ADR.**
Review baseline: `origin/main` / `bc1bc4e4238d6e61a17938e1ad9bbf7447ffaff5`.
Worktree C: `tmp/worktrees/issue-257`, branch `design/257-sealed-object-sync`.
Reviewed 2026-10-16. [ADR-0058](../adr/0058-a-sealed-object-never-stalls-a-pages-sync.md)
remains proposed. No Rust/Swift implementation is authorized by this plan.
No law or accepted ADR is changed. No push, PR or merge is part of this task.

## 1. Authority ledger

The following exact quotations are from existing accepted records. Each applies
only within the named source's scope. Implementation observations below are not
new normative authority.

| Source and status | Exact wording | Scope for this review |
| --- | --- | --- |
| [ADR conventions, Proposed](../adr/README.md#proposed), repository governance | “It must make unresolved questions visible and must not present a recommendation as an accepted decision.” | Review cannot accept ADR-0058. |
| [ADR-0021, Decision](../adr/0021-multi-device-sync-over-a-blind-relay.md#decision), accepted | “The relay never receives a content key, transport key, or pairing secret.” | Keep relay/key separation. |
| ADR-0021, Decision, accepted | “A joining device starts at the current key frame and receives no prior history.” | Review both delta import and frame adoption; avoid depending on a pre-frame metadata log. |
| [ADR-0021, Decision history](../adr/0021-multi-device-sync-over-a-blind-relay.md#decision-history), accepted | “The protocol specification is the authoritative message-shape record.” | Relay protocol governs message shapes; the draft client description does not. |
| [Relay protocol §3](../spec/feature/sync/relay-protocol.md#3-the-storage-contract), message-shape/storage authority delegated by ADR-0021 | “**The delta buffer is capped**: 8 MiB or 4096 blobs, whichever comes first.” | Channel cap, not permission to allocate a full unbounded roster per update. |
| [ADR-0043, Decision](../adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md#decision), accepted | “A sealed object's name and note are fields of its chip, not ink in the page's document, not on the tab and not in the ledger.” | Keep metadata out of page-body history and ordinary ledger content. |
| ADR-0043, Decision point 4, accepted | “The note persists as its text, not its operation log, and restores with an empty undo stack, as a page's undo starts empty after a relaunch.” | A local `Note` is not yet a restart-stable shared note CRDT. |
| [ADR-0046, Decision point 2](../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md#decision), accepted | “Only a page's death and the explicit burn destroy payload.” | A reversible removal is not burn authorization. |
| [ADR-0016, Decision](../adr/0016-content-persists-across-restart.md#decision), accepted | “A failed restore withholds the save licence and leaves the prior file untouched.” | Older-reader refusal must preserve the new file. |
| ADR-0016, Consequences, accepted | “Crash and force termination can still lose mutations inside the accepted two-second write window; refused writes can extend that window and must remain visible to the user.” | Tests must not assert a new zero-loss crash window. |
| [ADR-0012, Amendment 1](../adr/0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval), accepted amendment | “All three complete-payload writes are core-side. The Swift shell asks the core to write to a named destination and never receives the sealed payload.” | No new Swift-visible payload or sync payload export. |
| [Law 0001, The rule](../law/0001-sealed-object.md#the-rule), accepted | “A sealed item occupies one position in the document, but its plaintext is not part of the document's ambient text.” | Placement decisions need coordination with A, not a C-side law edit. |
| [Law 0001, Sealed-fragment representation](../law/0001-sealed-object.md#sealed-fragment-representation), accepted | “The envelope never contains a sealed payload or ciphertext.” | Peer transfers remain references, not value transfer. |
| Law 0001, Sealed-fragment representation, accepted | “Multi-object detach, reattach and clone are core transactions: an unexpected failure commits none of the structural or payload-state changes.” | Preserve whole-transaction transfer behavior. |

Additional source classifications:

- Root `AGENTS.md`: “Treat delivery notes, commit messages, agent output, and
  documents created or modified during the current task as leads, not evidence.”
  Neither this plan nor the revised ADR validates its own privacy, persistence
  or compatibility proposals.
- [#257](https://github.com/onetimesecret/macos/issues/257), maintainer design
  input, **not normative authority**: “A batch never fails to sync because of a
  sealed object or chip.” Also: “Where a technical limit or a product detail
  keeps that metadata from syncing, the batch still syncs.” And: “The value
  itself does not sync.” No note-loss acceptance follows from these statements.
- [Client protocol](../spec/feature/sync/client-protocol.md), exact status:
  “draft, not accepted”; row 10.31 is descriptive evidence of the defect.
- [Sealed-row note](../spec/feature/sealed-content/sealed-row-note-and-handles.md):
  “Nothing in this file has been ratified.” Use it as a UI inventory, not approval
  of the new peer face or note sync.
- [Law 0004](../law/0004-secret-plaintext-never-reallocates.md), exact instruction:
  “do not build against it as an accepted law.” #256 owns the resolution,
  not this task.
- [ADR-0057](../adr/0057-moved-content-lives-as-long-as-the-page-it-lands-on.md)
  is proposed. Do not treat its moved-content lifetime recommendation as
  accepted by repetition. A owns placement wording and related integration.

No accepted source located in this review specifies peer-only persistence,
metadata wire budgets, note LWW, sealer-signed object burns or mixed-version
negotiation. Those choices below are **proposals**, not existing guarantees.

## 2. Findings at the pinned implementation

### Review disposition

All findings are material to the design. “Addressed” below means the revised
proposal exposes the risk, recommends a concrete treatment and names any
acceptance gate; it does not mean the implementation exists or is approved.

| ID | Finding | Disposition and evidence | Verification |
| --- | --- | --- | --- |
| C1 | Full metadata tables can block ops even with a per-note cap. | Addressed in ADR Decision 2 and plan §3: independent lane, aggregate budgets, bounded cache and partial-frame semantics. | Compared with the all-or-nothing seal loop and channel cap; byte/failure test scenarios in §6. |
| C2 | Empty-byte peer encoding can restore as a local payload in older readers. | Addressed in ADR Decision 1/6 and plan §3: tagged format, nondestructive legacy reader, older-reader refusal; Q4 awaits acceptance. | Compared `emit_chip`/`read_chip`, core magic and FFI restore refusal; older-reader/save-gate tests in §6 remain owed. |
| C3 | Absorbing burn plus a payload-device exception cannot converge; ordinary ledger evidence lacks remote provenance. | Addressed in ADR Decision 5 and plan §4: signed origin/evidence, uniform transition, durable tombstones and explicit incomplete-join limit; Q3 awaits acceptance. | Compared `delete_chip`, `terminal_cause` and page-terminal verification; replay/order/restart tests in §6. |
| C4 | Per-field Lamport ties require the winning writer, clear semantics and restart rules. | Addressed in ADR Decision 3 and plan §3 field merge rules. | Total-order examples, forwarded versions and invalid equal-tuple scenario enumerated in §6. |
| C5 | UUID-preserving transfer alone does not settle duplicate validation, page ownership or durable cut consumption. | Addressed in ADR Decision 1/6 and plan §5: separate validation domains and explicit A/maintainer placement gate Q5. | Compared transfer resolver, restore invariants and both-order regression fixture; no unaccepted owner/clock rule selected. |
| C6 | Note LWW would lose text without accepted product approval. | Addressed in ADR Decision 4 and Q2: recommend no note sync initially; retain CRDT/conflict-preserving/LWW alternatives and explicit loss question. | Compared accepted ADR-0043 text-only restore and local `Note`; no loss acceptance attributed to issue direction. |
| C7 | Authority, acceptance and #256 edit boundary must remain explicit. | Addressed in §1, §7–§9 and ADR status/history; no law or accepted ADR edited. | Local links, exact quotations, ADR linter and changed-path checks in the design handoff. |

### Implementation observations

| Area | Observation and design consequence |
| --- | --- |
| `crates/core/src/document.rs:718–747` | `import_update` forks, imports, rejects pending history and then rejects unknown UUIDs or duplicates. Change unknown-ID admission without bypassing trial validation or making a half-import. Concurrent duplicate projection needs a distinct policy. |
| `crates/core/src/store.rs:1008–1045` | Both `apply_remote_update` and `adopt_key_frame` pass `owned_uuids` and settle afterwards. Both need the same transactional peer-record creation path. |
| `crates/core/src/sheet.rs:237–250` | Every `SealedChip` requires `SecretBuffer`, exact `ChipMeta`, excerpt and size string. An empty buffer is currently a real local text/image record, not a peer-only state. |
| `crates/core/src/persist.rs:453–483, 878–930` | The writer puts payload before trailing name/note; the reader invokes `text_with_uuid`/`image_with_uuid`. Appending a flag after empty bytes is not a safe older-reader discriminator. |
| `crates/core/src/persist.rs:788–827` | Restore checks per-page UUID uniqueness and one-to-one marks/attached records. Terminal projection and cross-page transitional references need explicit restore invariants. |
| `crates/core/src/transfer.rs:422–510` | `resolve` can clone every live record through `duplicate`; `terminal_cause` consults the ordinary ledger. Both need typed peer/terminal handling, not just a new face string. |
| `crates/core/src/store.rs:1404–1474` | Copy/name=value directly expose local bytes; `delete_chip` removes the sentinel and records local `Discarded`. A peer route must refuse payload operations in core, and a received burn must not pretend this local action occurred. |
| `crates/core/src/store.rs:4921–4987` | The move/cut fixtures first reject the seal, then reject dependent source and destination updates, then reject a later destination edit. Invert the entire sequence, not only the final face. |
| `crates/sync/src/envelope.rs` | Envelopes are independent JSON blobs. `ByteBlob` is a plain vector at this baseline. Names and future notes are content-bearing even if called metadata. Reuse #256's replacement. |
| `crates/ffi/src/sync_session.rs:651–678` | All queued envelopes seal through one `collect::<Option<Vec<_>>>()`; any seal failure currently prevents the entire request. A new optional lane must not inherit that coupling. |
| `crates/ffi/src/sync_session.rs:1116–1155, 1218–1243` | Frame production seals a raw page rebuild; frame adoption imports that plaintext as document bytes. A metadata wrapper needs a versioned frame reader/writer, not bytes appended to a Loro export. |
| `shell/Sources/CompanionKit/CompanionClient.swift:461–491` | `ChipInfo` assumes kind/excerpt/size; it has no availability/capability discriminator. Every hit zone, command, drag provider and conceal route needs review, not menu removal alone. |

These observations are a read-only inspection, not a test run or a complete
sync audit. Existing composite-frame/rejoin gaps are recorded in the draft
client protocol. Do not silently expand #257 into fixing all of them, or label
an uncalled frame-adoption helper as an end-to-end working join.

## 3. Proposed concrete representation

All schemas here are design notation, not Rust/Swift implementation.

### Core and at rest

```text
ObjectRecord = {
  uuid: ItemId,                         # stable across devices/restart/moves
  availability:
    LocalPayload { secret, exact_meta, excerpt, receipt? }
    | PeerOnly { kind?: text|image, size_class?: coarse_enum },
  name: Unknown | Known { value: name|null, version: Version },
  local_note: Note?,                    # not replicated in recommended v1
  origin: Unknown | VerifiedOrigin,
  replication: { pending_generation, field_versions, pending_evidence }
}
Version = { counter: u64, writer: fingerprint_bytes[32] }
BurnEvidence = { uuid, origin_digest, event_id, reason, at_wall_ms,
                 signer, signature }
```

- Terminal evidence is separate from a live `ObjectRecord`. A page's projection
  resolves a sentinel to live-local, live-peer or terminal-reference. A terminal
  reference can satisfy roster validation without a live payload record.
- A lookup/index by UUID prevents making a second local payload merely because
  the destination page's update arrives first. Process-local `ChipId` is never
  the replicated identity and is re-minted after restore.
- Encode availability before any payload bytes under a **new inner snapshot
  magic/version**. Reserve neither an empty text payload nor an unknown legacy
  kind tag as a peer encoding. Suggest the next unused content version only
  after rechecking #256's integrated format; do not assume its numeric value now.
- New reader: explicitly parse legacy `OTSSNAP4` local records without dropping
  unexpired content; parse new tagged records; reject invalid tags/lengths and
  conflicting local-payload identities transactionally. New writer: new version.
  Old reader: `UnknownFormat`, no state replacement, file preserved and save
  disabled through the enclosing restore path. Test this; do not infer it from
  `Reader::framed` or merely from the new magic.
- Persist name's winning writer/counter, metadata pending generations, origin,
  burn evidence and active cut in the same content snapshot as the body. After
  restart re-advertise current state; in-memory acknowledgments are insufficient.
  Use #256's integrated serializer and classification for every content buffer.
- Page-owned object placement/clock remains separate from availability. A UUID
  index is not an ownership rule. A must agree the transfer/placement schema
  before vectors, catalog layout or clock reconciliation change.

### Optional wire lane and frames

```text
object_metadata_v1 = {
  kind: "object_metadata_v1", page: page_uuid,
  entries: [{ uuid, fields: { name?: { version, value: name|null } },
              descriptor?: VerifiedOrigin,
              burn?: BurnEvidence }]
}
frame_vNext = {
  pages: [{ page, document_rebuild, optional_metadata_subset }],
  metadata_complete: false
}
```

UUID encoding should match existing sync page IDs (32 lowercase hex); fingerprint
ordering uses decoded bytes, never display strings. Kind/size can be hints until
an origin descriptor is verified; hints cannot authorize a burn or a value route.
Unknown field/version means skip the optional item. No note text in recommended
v1. Descriptors and burns are immutable evidence, not mutable registers.

Transport each metadata envelope under the same GOP key/padding policy as ops,
**not necessarily the same ciphertext blob**. Validate individual fields/entries;
rejecting one optional item does not reject the document update or overwrite a
valid field. Do not parse an attacker-supplied unlimited array into a full
owned vector before checking limits. Metadata absent from a chunk is not a
roster deletion, note deletion, terminal reset or acknowledgment.

Proposed limits: 16 KiB encoded JSON / 128 entries per metadata envelope;
64 KiB optional metadata JSON per request or composite frame; pending unmatched
cache at most 256 entries / 64 KiB encoded content, with deterministic eviction.
Include allocator overhead in measurement rather than equating encoded size
with resident memory. Effective available transport budget can reduce these
limits to zero. Measure padding, AEAD, base64 and JSON wrapper overhead against
both transport and channel limits. Do not use the 8 MiB channel cap as the target
size for an individual optional table.

Maintain bounded fair iteration over current entries, including detached objects
and terminal evidence. Changes get a metadata generation; a send acknowledgment
advances only the generations included in that send. Echoes do not mint edits.
Restart/reconnect/new epoch restate current entries. Never move the ops cursor
because metadata queued or failed; never mark omitted metadata delivered. Expired
pages withdraw unsent content metadata as well as ops, using #256's wipe path.
Terminal evidence scheduling follows the separately accepted page-end policy.

Optional metadata in a frame uses the same aggregate budget; the document
rebuild remains decodable without it. This plan does not promise an unbounded
base document fits every transport limit: any pre-existing document-size failure
needs separate evidence. It prevents *optional* object metadata from causing an
otherwise sendable frame/ops request to fail.

### Field merge rules

- Unknown is not version zero containing a clear. A locally created field starts
  at counter 1 with a writer; an explicit clear is versioned null.
- Compare `(counter, writer_bytes)` lexicographically. Independent fields do not
  overwrite each other. Receive a greater valid tuple: adopt both value and tuple.
  Forward it unchanged; do not substitute the forwarding device's fingerprint.
- Local edit after any received field uses checked increment of the maximum
  valid counter known for that field. Counter exhaustion affects that metadata
  edit only. Persist before a later restart can reuse an old tuple.
- Equal tuples/equal values are idempotent. Equal tuples/different values are
  protocol corruption/equivocation: preserve the known field, flag a content-free
  diagnostic, and require a new revision. Do not advertise convergence for that
  invalid case or stall body sync.
- Notes require Q2. If later accepted as whole-text snapshots, propose a separate
  4 KiB UTF-8 note-text limit plus the aggregate encoded-byte checks; oversized
  text is omitted with an unsynced status, never truncated or interpreted as a
  clear. This number and lossy merge behavior are **not accepted**.

## 4. Remote burn evidence and convergence proposal

Recommend an immutable sealer-signed descriptor over a canonical encoding of:
protocol version, object UUID, sealer public-key fingerprint, kind and coarse
size class. Use a new signature domain, not the page-terminal signature domain.
The origin descriptor is bound to a verified pairing key; its digest is not a
hash of the payload. A bare metadata UUID cannot prove origin. Conflicting
origins are a protocol error, not a highest-clock contest.

Recommend burn evidence signed by that sealer over another canonical,
domain-separated encoding: protocol version, object UUID, origin descriptor
digest, burn event UUID, explicit-burn reason and timestamp. Timestamp is for
reporting, not winner selection. Verify the binding and signature before the
terminal transition; a shared GOP key alone is insufficient provenance.

All devices apply verified evidence uniformly. If a stale local payload exists,
its value-dependent routes stop and its bytes are dropped through the local
payload destruction path. The publisher's durable tombstone and local mutation
are one transaction. The sender also applies its echoed evidence idempotently.
A metadata-only peer cannot mint a burn. Burn-before-origin may be pending in a
bounded cache; otherwise drop and await re-advertisement. Unverified evidence
must not displace a valid origin or destroy payload.

Receiving a burn does not call `delete_chip` and invent a local `Discarded`
ledger event. Store source fingerprint/event/time and verification evidence in
protocol state; a future ledger display may say remote burn after that UI/event
schema is accepted. Retention and the user-facing cause cannot depend solely on
an ordinary ledger row that can expire or be imported independently.

The raw CRDT graph can still contain a burned sentinel. Retain a terminal
projection keyed by UUID, allow subsequent dependent updates, and suppress stale
reattachment without changing it into an empty live object. Local cut resolution
checks verified terminal evidence before considering peer references.

Tombstones are not LWW and not evictable unmatched hints. Restate them in bounded
chunks and keep unsent evidence durable across ceremonies/restarts. A partial
frame can omit them; a joining device then has incomplete knowledge until an
awake peer restates evidence. Eventual terminal convergence requires an awake
peer with the evidence and fair successful delivery. Immediate complete knowledge
with all peers asleep is **unsupported by this proposal**. Do not advertise it.
If required, design a complete bounded checkpoint/recovery representation before
remote burns, without allowing metadata size to block ops.

Unresolved acceptance details: legacy unsigned objects (recommend no authoritative
burn publication until a verified origin exists; do not auto-attest remote
records), key revocation versus historical evidence (recommend evaluate the
origin's established trust, not relay attach order; security review required),
page-end cleanup and evidence retention. A source page ending is not a signed
explicit burn of an object moved elsewhere. These questions block remote burn
implementation; a narrower accepted increment could omit remote burn replication
without pretending the terminal design is complete.

## 5. Transfer, duplicates and restart scenarios

A peer-only object is eligible for reference-preserving structural movement, not
payload cloning. Core capability checks, not hidden UI alone, enforce this.
Copy/later paste/option-drag of a peer-only reference produces the proposed
unavailable result without a fresh sealed UUID, a `sealed` ledger event or an
empty `SecretBuffer`. Preserve current fragment caps and duplicate-reference
validation before cut/paste changes any state. A rejected copy/cut leaves an
earlier active cut unchanged.

Same-page move and cut/first paste preserve UUID, versions, local note and
origin/evidence. Cross-page transfer preserves those fields and consumes the cut
in the same durable snapshot as source/destination state. Restart after a
successful persisted cut must allow exactly its first paste to reattach; restart
after the persisted paste must not reattach the same cut a second time.
Before-save crash tests use ADR-0016's existing write window, not a new guarantee.

For a move performed on a metadata-only device, the payload device can receive
the destination insertion before the source deletion. Keeping a destination
peer record while the source payload remains detached can assign two clocks to
one identity and destroy the value when the wrong page ends. Neither arrival
order nor UUID preservation resolves this. **Integration gate with A:** agree a
stable transfer/placement identity, owner transition and concurrent-move rule,
then move/rebind the one local payload record only under that rule. Include
source-expiry/destination-live in review; do not copy bytes to manufacture another
object. This plan intentionally does not select an unaccepted lifetime rule.

Duplicate validation has three different domains:

1. Crafted fragment naming a UUID twice: existing whole-fragment refusal before
   mutation remains.
2. Inconsistent snapshot/live roster: reject transactionally; no two distinct
   local payload records may be restored for one UUID.
3. Remote merge producing duplicate occurrences from valid edits: rejecting the
   graph can stall every following dependent op. Recommend deterministic
   projection by a stable Loro occurrence identity, preserving graph history,
   never cloning value. Prove that the chosen occurrence key survives export,
   restore and compaction, or choose a different reviewed normalization. Do not
   use receiver-local `ChipId`, discovery order or arrival order. Agreement with
   A and a maintainer decision are required before remote duplicate code changes.

## 6. Test matrix to implement after the gates

These are required scenarios for the proposed choices, **not existing passing
tests**. Tests should assert document frontier/projection, identities, payload
availability, metadata, cut state and disk behavior rather than only a label.

| Group | Scenarios and expected assertions |
| --- | --- |
| Admission | Seal on enrolled page; unknown marked UUID with no metadata; metadata before/after ops; omitted/invalid/unknown-version metadata; ops import and a later dependent ink edit both succeed. Import refusal for malformed bytes or true missing history remains distinguishable. |
| Existing regressions | Invert both `sync_carries_no_object_so_*` tests including the initially sealed batch and later destination edit; deliver source/destination in both orders. Split `sync_rejects_foreign_and_duplicate_chips` only after the duplicate policy is agreed. |
| Roster | Unknown UUID allocates exactly one typed peer record; echo/repeated updates allocate none extra; remove/undo detaches/reattaches; metadata alone cannot attach or create an unlimited detached roster. |
| Duplicates | Crafted duplicate fragment is rejected before mutation; duplicate snapshot refuses without replacing store; two valid concurrent reattachments delivered in either order continue sync and produce the same single active occurrence under the accepted policy. |
| Budgets | Many tiny records, many detached records/tombstones, a huge local note, multibyte/escaped JSON, exact byte/count caps and one over. Assert bounded allocations/work per sweep and that ops/control requests still publish; cap optional frame metadata without delaying frame/epoch publication. |
| Independent failure | Inject metadata serializer/validator/seal failure; ops lane still publishes and acknowledges only its actual frontier. No oversized optional head blocks retries. Metadata-only name edit emits an entry; restart/reconnect/epoch retries omit nothing accidentally and never acknowledge unsent generations. |
| Versions | Same counter/different fingerprints in both delivery orders; independent field edits; stale/duplicate and forwarded winners; explicit clear versus absent; local edit after remote high counter; persisted writer/counter and next increment after restart; overflow affects metadata only; equal tuple/different value diagnostic, no ops failure. |
| Notes | Recommended v1: no note-text field in deltas/frames, no incoming patch replaces local note/undo, local editing remains unbounded. If another policy is accepted, add offline conflict, empty-clear, oversize omission, undo/redo, restart and compaction tests before enabling it. |
| Payload boundary | Unique text/image payload markers absent from metadata/frame extras and every peer FFI result; no excerpt/exact sizes/receipt leakage; peer copy/name=value/decrypted drag/chip conceal refuse in core with no write/event. Whole-page conceal with a standing peer-only object refuses with a reason; detached-only peer object does not affect included content. |
| Transfer | Mixed ink/local/peer references; cut/first paste and move preserve UUID/versions; later cut paste/copy/option-drag cannot clone peer payload; a failed multi-object stand rolls back all placements, cut and ledger. Source/destination and metadata reordered; payload device sees peer move; concurrent moves; source expiry before/after destination import under A's accepted placement rule. |
| Restart | Persisted attached/detached peer, real empty local payload, name-clear version, pending metadata, origin/tombstone, active cut. Re-minted handles still resolve stable UUIDs; post-cut restart reattaches once; post-paste restart cannot consume twice. Before-save crash remains within the existing write window. |
| Burn provenance | Wrong signer, wrong UUID/origin digest/domain, unsigned boolean, unknown origin, burn before origin, sealer echo, stale metadata after burn, copied stale local payload, replay after restart/ceremony. Only accepted evidence becomes terminal; every device then agrees, no resurrection or fabricated local discard. |
| Burn/placement | Burn and move race; burn and note/name edits race; source-page expiry is not global explicit burn; page-end cleanup/evidence lifetime follows accepted placement rules. Replayed old sentinels import history and render terminal. |
| Frame/version | Versioned frame with/without metadata and with terminal references; frame-only join reports incomplete metadata honestly; later chunks fill it. Old sync build gets an upgrade/capability outcome before receiving incompatible ops. Do not call helper-only tests end-to-end relay recovery. |
| Older reader | New reader reads legacy state nondestructively; old-reader fixture refuses new state, leaves content file and key material unchanged, and cannot save over it. Damaged new-format record refuses transactionally. Include FFI/shell save gating, not only core parse. |
| UI/seam | Explicit local/peer/terminal capabilities over #256's chosen output; unknown kind; value/= hit zones, keyboard commands, menu, lazy drag and stale callbacks all refuse peer values. Rename/local note and structural removal remain available as accepted; copy/name routes obey the owning page deadline. |

## 7. Acceptance questions and recommended choices

| Gate | Specific maintainer decision | Recommendation |
| --- | --- | --- |
| Q1 | Which fields, byte/count budgets, partial-frame delivery and visible omissions are acceptable? | Kind/coarse size/name only, bounded independent patches; no unlimited roster snapshots. |
| Q2 | Local-only notes initially, conflict-preserving sync, CRDT, or explicitly lossy whole-text LWW? | Local-only first; require separate acceptance for note sync, especially whole-text loss and undo treatment. |
| Q3 | Who can burn; what evidence; does a verified burn affect a stale local payload; acceptable join delay; legacy/revoked origin behavior; retention and remote ledger presentation? | Sealer-signed evidence, same terminal rule on every device, no synthetic local discard. Defer remote burn code if evidence/checkpoint policy is not accepted. |
| Q4 | New snapshot version with nondestructive legacy reader, older-reader refusal, and minimum sync capability? Which ADR-0043 clause does the format change replace? | Explicit tagged format; never encode peer state as empty local bytes; preserve old state on refusal. Do not add a new destructive migration implicitly. |
| Q5 | Placement/ownership after peer moves, concurrent moves and duplicates; exception for malformed input versus valid concurrent duplicate graph? | A defines placement with maintainer approval; import valid graphs, deterministic single active occurrence, no payload clone. |
| Q6 | Who accepts ADR-0058 and any scoped successor/law/spec revisions? | Maintainer only. Leave ADR-0021 and ADR-0043/0046 unchanged until actual acceptance and exact replacement scope are recorded. |

## 8. Safe sequence after #256

1. **Stop boundary now:** documentation only. Do not edit Rust, Swift, laws,
   accepted ADR bodies or shared interface documents before #256 integration.
   Do not infer readiness from an issue inventory or a draft law status.
2. **Verify foundations:** parent confirms #256 integrated; record its actual
   commit and inspect the resulting sync byte owner, encoder/decoder, FFI output
   ownership/free path, Swift consumption and withdrawal tests. Read the final
   accepted security classification rather than this baseline's plain `ByteBlob`.
   Recheck snapshot/frame versions and changed symbols. Do not overwrite #256.
3. **Resolve acceptance/ownership:** obtain answers to Q1–Q6 and A's placement
   contract. Narrow the first implementation explicitly if notes/burns/placement
   need more design. Keep independent proposed choices visibly unresolved;
   a doc-review pass does not accept the architecture.
4. **Core types and format first:** typed availability, core capability refusals,
   transactional peer/terminal roster, UUID lookup, legacy reader/new writer and
   restart/old-reader tests. Agree data layout with A before touching overlapping
   `sheet.rs`, `document.rs`, `store.rs`, `persist.rs` and `transfer.rs`.
5. **Admission and structural transfer:** common delta/frame import path; invert
   regressions; implement the agreed duplicate and move reconciliation; prove
   cut/undo/rollback/restart behavior before adding optional metadata traffic.
6. **Bounded protocol state:** field tuples, pending generations, origin/terminal
   evidence if accepted, optional envelope/frame versions and independent
   scheduling. Use #256's owners and serializers, not fresh `String`/`Vec`/JSON
   intermediates copied from this baseline. Test failure injection, reordering,
   acknowledgments, withdrawal and budget boundaries.
7. **Thin shell projection:** add explicit availability/capabilities through
   #256's final FFI path, then face/menu/zones/commands/drag/conceal behavior.
   Unknown availability fails value-dependent routes; local zero-byte payload
   remains distinct. UI hiding is not the core security boundary.
8. **Validate and document built behavior:** targeted core/persistence/transfer,
   sync-envelope/session/driver and seam/UI tests first; broader workspace and
   shell suites next. Update the core interface, relay shapes and descriptive
   client protocol 10.31 only for implemented behavior. A updates Law 0001's
   placement wording; law/ADR acceptance remains the maintainer's action. Relay
   recovery and hardware-only checks are reported separately if unavailable.

Shared paths after #256 include `crates/sync/src/envelope.rs`,
`crates/ffi/src/lib.rs`, `crates/ffi/src/sync_driver.rs`,
`crates/ffi/src/sync_session.rs`, `crates/core/src/persist.rs`,
`crates/core/src/transfer.rs` and
`shell/Sources/CompanionKit/CompanionClient.swift`. Parent must reconcile actual
foundation changes before assigning these edits. `docs/law/0001-sealed-object.md`
and every other law remain outside C's edit boundary.

## 9. Validation scope for this design-only task

Design review coverage: C1–C7 addressed as proposal documentation; none rejected
or omitted. Q1–Q6 remain architecture/implementation gates, not accepted answers.

Validation performed on 2026-10-16:

- `python3 scripts/lint-adrs.py docs/adr`: `51 ADRs OK`.
- `git diff --check`: passed. A separate Python whitespace check covered the
  new plan before staging, since Git's ordinary diff excludes untracked files.
- A read-only Python check reused `scripts/lint-adrs.py`'s link/heading rules:
  all 30 local links/anchors in the two changed documents resolved. It also
  checked both documents for prohibited prose; an initial filename-only match
  was excluded from the prose check, without renaming the existing source.
- A read-only quotation check compared 33 quoted passages with unchanged `HEAD`
  source files or the fetched #257 body, normalizing whitespace only: passed.
  Source authority classifications were reviewed separately, not inferred by
  string matching.
- `gh issue view 257 --repo onetimesecret/macos --comments` and the corresponding
  #256 read succeeded. The sole external Markdown target in these documents is
  #257; it was verified separately from local links. No issue was edited.
- Diff/path review found only ADR-0058 and this plan changed; no Rust, Swift,
  law, accepted ADR or other worktree edits. ADR-0058 remains `proposed` and its
  original proposal date is unchanged.

Limits: no Rust/Swift tests, runtime injection, old-binary restore, relay
exchange, allocation instrumentation or rendered UI/hardware check was run.
Implementation tests above are owed after the gates, not completed by writing
this matrix. These checks establish documentation structure, links, source
quotation fidelity and edit scope, not runtime behavior or security.
