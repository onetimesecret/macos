---
documentation_status: needs-review
---

# ADR-0058: A sealed object never stalls a page's sync

- **Status:** proposed
- **Date:** 2026-10-16
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md), [ADR-0043](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md), [ADR-0046](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md).

Read [ADR conventions](README.md) before filing or changing an ADR.

**Review proposal, not acceptance.** Every choice under Decision is a
recommendation for maintainer review. In particular, neither note replication
nor lossy whole-note last-writer-wins (LWW) has been accepted. Implementation
waits for #256's integrated buffer/FFI foundations and the decisions listed in
the [design and implementation plan](../plans/issue-257-sealed-object-sync.md).

## Context

At review baseline `bc1bc4e4`, `SheetDocument::import_update` trials an update
on a fork and refuses both an unknown chip identity and a duplicate sentinel
with `ChipRoster`. The page's attached and detached chip records are the
roster. `DeltaEnvelope::Ops` transports only document bytes, not those records.
An unknown object's insertion is therefore rejected, and later dependent
updates can fail with `MissingHistory`. The two move/cut sync tests in
`crates/core/src/store.rs` reproduce this behavior; they are implementation
evidence, not acceptance authority.

### Accepted sources and their scope

These are existing authoritative records, not evidence created by this review:

- [ADR-0021, Decision](0021-multi-device-sync-over-a-blind-relay.md#decision),
  accepted: “The relay never receives a content key, transport key, or pairing
  secret.” Also: “A joining device starts at the current key frame and receives
  no prior history.” The relay and key model remain in scope here.
- [ADR-0021, Decision history](0021-multi-device-sync-over-a-blind-relay.md#decision-history):
  “The protocol specification is the authoritative message-shape record.” The
  [relay protocol §3](../spec/feature/sync/relay-protocol.md#3-the-storage-contract)
  specifies: “**The delta buffer is capped**: 8 MiB or 4096 blobs, whichever comes
  first.” This is a channel storage bound, not a metadata allocation budget.
- [ADR-0043, Decision](0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md#decision),
  accepted: “A sealed object's name and note are fields of its chip, not ink in
  the page's document, not on the tab and not in the ledger.” Point 4:
  “The note persists as its text, not its operation log, and restores with an
  empty undo stack, as a page's undo starts empty after a relaunch.” Its sync
  open question explicitly decides nothing about sync.
- [ADR-0046, Decision](0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md#decision),
  accepted: “A page keeps the sealed objects its body no longer shows, on its own
  clock, until the page ends or the object is burned.” Point 2:
  “Only a page's death and the explicit burn destroy payload.” Its sync
  open question remains open.
- [ADR-0016, Decision](0016-content-persists-across-restart.md#decision),
  accepted: “A failed restore withholds the save licence and leaves the prior
  file untouched.” Its older format-break decision does not authorize a new
  destructive format break for #257.
- [ADR-0012, accepted Amendment 1](0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval):
  “All three complete-payload writes are core-side. The Swift shell asks the
  core to write to a named destination and never receives the sealed payload.”
  Metadata sync is not permission to add a payload egress.

[Law 0001](../law/0001-sealed-object.md), accepted, supplies the existing
placement/fragment behavior; it is not edited here. Its exact relevant wording
is quoted in the plan. Placement wording is worktree A's responsibility.
[Law 0004](../law/0004-secret-plaintext-never-reallocates.md) is **draft**, not
an accepted authority; #256 owns its resolution. The
[client protocol](../spec/feature/sync/client-protocol.md) calls itself
“draft, not accepted”; its limits and row 10.31 describe the build, not a
normative exception allowing sync to stall. The sealed-row interaction note
also says nothing in it has been ratified.

### Design input, not normative authority

[Issue #257](https://github.com/onetimesecret/macos/issues/257) records the
maintainer's direction of 2026-10-14:

> - A batch never fails to sync because of a sealed object or chip.
> - The object's name, note and other metadata, everything except its value, can be synced. Can, not must.
> - Where a technical limit or a product detail keeps that metadata from syncing, the batch still syncs.
> - The value itself does not sync.

Under root `AGENTS.md`, the issue is design input, not itself normative
supersession. No accepted wording excluding all chip metadata from sync was
located in ADR-0021. Treat this as the requested successor/extension proposal;
do not invent a partial-supersession relationship to an absent exclusion.
Acceptance must identify any actual accepted decision being replaced and add
reciprocal ADR relationships then, if applicable. Do not change accepted ADRs
or laws during this review.

## Decision

### 1. Separate payload availability from object identity and placement

Propose an object record with stable `ItemId` UUID and a sum type:
`LocalPayload { SecretBuffer, exact_meta, excerpt, receipt }` or
`PeerOnly { optional kind, optional size_class }`. Name, local note, field
revisions and origin evidence belong to the common record. Attachment versus
detachment is placement, not payload availability. A terminal reference has a
separate evidence record and cannot become either live variant by metadata.

No peer variant contains an empty payload buffer, a fabricated `ChipMeta`, an
excerpt or a receipt. A legitimate zero-length local payload remains local.
An absent kind is unknown, not text. A peer face says `value not on this device`
(proposed copy): no owner/device-online assertion is possible from a bare UUID.

Import document history independently of optional metadata. Discover previously
unknown UUIDs on the trial document and prepare peer records before committing
the import and projection. A metadata-only entry never attaches an object or
creates an unlimited detached roster; bind it to an existing record, or keep
it in a bounded, evictable cache until its sentinel arrives. Missing, malformed,
oversized or unknown-version optional metadata cannot prevent valid ops from
being imported or advance the ops export cursor prematurely.

Keep duplicate validation in local transactions, fragments and snapshots. The
existing remote whole-batch duplicate refusal needs a separate decision:
concurrent valid edits can also stand a UUID twice. Recommended resolution is
to import the dependency graph and deterministically project one active
occurrence, with an inert diagnostic for extras, not clone payload or silently
choose by arrival order. Its stable occurrence key and interaction with A's
placement work must be agreed before changing `document.rs`. Continuing to
reject valid concurrent duplicates would retain a chip-induced sync stall.
Corrupt encoding and genuine missing history remain distinct errors.

### 2. Optional metadata has a bounded, independent delivery lane

Replace the full-roster snapshot on every edit with versioned, bounded patches.
Recommend kind, coarse size class and name for the first increment; omit note
text until question Q2 is accepted. Never export payload, payload-derived
excerpt, exact length/line counts, receipt or note undo/history.

Proposed initial budgets (not accepted protocol constants): at most 16 KiB of
encoded metadata JSON and 128 entries per metadata envelope; at most 64 KiB of
optional metadata JSON per publish request or composite frame. Count escaped
UTF-8 JSON, then check padding, seal overhead, base64 and complete transport
size. Reduce or omit optional entries whenever the effective request/frame
budget is smaller. A count cap alone is insufficient. Apply inbound limits
before allocating entries or decoding large field strings. Bound pending
metadata cache by both 256 entries and 64 KiB of encoded content.

Schedule ops and policy/control independently; an optional metadata serialization,
validation, seal or size failure drops/defers that lane, never the ops lane.
Do not retain a rejected oversized metadata envelope as a permanently retried
head of the ops queue. Metadata-only edits publish without body edits. Use fair,
bounded roster slices for anti-entropy, with separate metadata acknowledgments,
and repeat current fields after restart, reconnect and ceremony. Omission means
unknown/unchanged, never clear or deletion. Key-frame metadata can be partial;
joining ops do not wait for its completion. These limits do not cap local note
editing or impose a new object-count limit on an otherwise valid document.

### 3. Per-field versions are fully ordered and durable

For each replicated mutable field propose `Version(counter: u64,
writer: 32-byte device fingerprint)` and a distinct unknown state. Order versions
lexicographically by counter, then unsigned fingerprint bytes; greater wins.
A clear name is `value: null` with a version, not an absent field. Local edits
use checked `1 + max(local counter, highest valid received counter for that
object/field)` and the local fingerprint. Persist the winning writer and counter,
not just the counter. Forward another writer's version unchanged. Restart and
moves keep versions; a new clone starts a new identity and new versions.

Equal complete versions with different values are protocol conflicts, not
last-arrival-wins. Retain the known field, report a content-free conflict and
request a fresh local revision; do not block ops. The sealer's signed immutable
kind/size descriptor, if accepted for Q3, is not an editable LWW field.
Counters do not wrap; exhaustion refuses the metadata edit, not document sync.

### 4. Note synchronization requires its own explicit choice

Do **not** silently replace a local note with received text. Recommended first
increment: notes remain local, visibly described as not synced on this build;
the metadata schema has no note-text field. This is permitted by the issue's
“Can, not must” design input, not an already accepted product choice.

If note sync is required now, choose separately between a chip-owned note CRDT
with a reviewed restart/compaction format, a conflict-preserving register with
resolution UI and retention, or whole-text LWW with explicit loss acceptance.
Whole-text LWW discards one entire offline edit; replacing text outside undo can
make it unrecoverable. An accepted per-field version order for names would not
accept that loss for notes. A future bounded note snapshot must omit, not
truncate, text beyond its byte budget, distinguish omission from an explicit
empty note and show that it has not synced. These are review proposals only.

### 5. Burns need origin evidence and one terminal rule

The earlier proposal's absorbing burn combined with a payload device ignoring
remote burns is withdrawn. A shared GOP seal establishes channel access; it
does not establish which device sealed or burned an object. Structural removal
is reversible, so the ability to remove a sentinel does not justify authority
to irreversibly destroy payload.

Recommend sealer-authorized explicit burns: a signed origin descriptor binds
object UUID to its sealer's verified device key, and a domain-separated signed
burn binds object UUID, origin descriptor digest, event identity, reason and
reporting timestamp to that same key. Full proposed fields are in the plan.
Unknown origin or invalid signatures leave the object nonterminal and unavailable
where appropriate; bounded pending evidence cannot delay ops. A metadata-only
device offers removal, not burn. Existing objects without origin evidence need
an explicit migration policy before they can publish authoritative burns.

Once verified, the same burn evidence is terminal on **every** device, including
one with a local payload. No payload-device exception. Persist the tombstone
and provenance atomically with the local mutation; suppress value-dependent
routes and retain a typed terminal projection for any remaining sentinel.
Do not generate unrelated document deletions on each receiver or refuse a later
stale insertion: absorb its history and project terminal. Replays are idempotent;
a stale live metadata patch cannot recreate payload or erase evidence.

Terminal evidence is a durable protocol fact, not an evictable metadata cache
entry or a synthetic local `discarded` ledger action. Retain it on the live
owning page, include it in bounded re-advertisement and frame metadata when it
fits, and keep the durable remainder due for later publication. A partial frame
alone cannot establish complete terminal knowledge; a join can temporarily lack
evidence until an awake peer restates it. Do not promise immediate burn
convergence from a frame that omitted evidence. If that delay is unacceptable,
Q3 requires a complete bounded checkpoint design before shipping remote burns.
Page expiry is still a page fact; it is not evidence that an object moved to
another live page was explicitly burned. Retention, page-end cleanup and ledger
presentation require the maintainer/A coordination recorded in Q3 and Q5.

### 6. Persistence and transfer are explicit boundaries

Use a new inner content-snapshot version with a tagged object record, not a
trailing availability flag after legacy payload bytes. Recommend a one-way,
nondestructive reader for the previous snapshot version. Earlier builds must
refuse the new version and retain the existing file/save-licence gate; do not
add the previous content format to a destructive superseded-format list. Verify
the enclosing FFI/shell path with an older-reader fixture. This new format and
migration need maintainer acceptance; ADR-0043's append-only name/note detail
would need an explicit scoped successor relationship, not silent editing.

Persist UUIDs, availability tags, field versions, origin/burn evidence, metadata
delivery state and the active cut. Re-mint process-local `ChipId` handles after
restore. No peer restore calls a local sealing constructor with empty bytes.

Cut/first paste, same-page move and cross-page move preserve UUID, metadata and
revisions without requiring a value. Copy/later-cut-paste/option-drag cannot
clone a peer-only payload: recommend a cause-specific unavailable placeholder
and outcome, without minting a fake sealed object. Keep fragment duplicate and
size validation before any mutation. Source/destination transfer plus active-cut
consumption must remain transactional and restart-durable under the existing
save window, not a new stronger crash guarantee.

Cross-page updates can arrive in either order, including a move performed on a
peer while the payload remains on the original device. UUID preservation alone
does not migrate page ownership or its clock. Placement reconciliation and
concurrent move policy are an explicit integration gate with A; no metadata
patch may copy payload or decide ownership by arrival order.

## Consequences

- Proposed behavior: unknown objects no longer prevent ordinary valid document
  updates from being applied; missing optional metadata produces a typed face.
- Optional metadata uses bounded buffers and transport capacity. Local data can
  remain unsynced and the UI must disclose that distinction. Padding does not
  erase metadata's traffic-size contribution; measure it against ADR-0021's
  existing admission before release.
- Notes remain unsynced under the recommended first increment. This avoids
  introducing silent whole-note loss; it is not acceptance of a final note policy.
- Tagged persistence prevents the proposed peer representation from being read
  as an empty local secret. Older builds cannot edit new-format state; new builds
  must demonstrate preservation rather than assume length framing provides it.
- Signed terminal evidence adds key verification, durable protocol state and a
  migration question. This proposal cannot establish global terminal convergence
  by unsigned booleans or ordinary ledger records.
- Mixed sync builds remain incompatible: skipping an unknown metadata envelope
  does not teach an old build to import an unknown sentinel. Require an explicit
  protocol/capability gate with an upgrade outcome before enrollment/attachment,
  not silent send-and-drop. Exact negotiation is a pre-release decision.
- Accepted records, Law 0001 and draft Law 0004 are unchanged by this review.
  The implementation/test inventory belongs in the linked plan, not this ADR.

## Alternatives

- **Full unbounded roster tables:** not recommended. Many small entries, detached
  records or tombstones can exceed limits even if each note is capped.
- **Empty bytes plus trailing peer flag:** not recommended. The current reader
  rebuilds a local text/image chip before interpreting any future trailing flag.
- **Unsigned absorbing burn with a payload-device exception:** not recommended.
  It both lacks origin authorization and makes terminal results device-dependent.
- **Whole-note LWW now:** remains an unaccepted alternative, with explicit text
  loss and undo consequences; no inferred approval from name LWW or #257.
- **Chip-owned note CRDT:** viable for later review. It need not put note ink into
  the page body, but ADR-0043's text-only restore means shared causal identity
  across restart and compaction needs design before reuse of the local `Note`.
- **Import only the non-chip part of a Loro delta:** not recommended; removing
  operations from its dependency graph can reproduce `MissingHistory`.
- **No optional metadata in the first increment:** a valid narrower proposal if
  the maintainer prefers it. Typed peer records still allow document progress.

## Open questions

These require maintainer acceptance; the plan gives concrete choices and tests.

1. **Q1 — Metadata and budgets:** accept kind/size/name patches, the proposed
   byte/count budgets, partial frame semantics and independent delivery, or
   start with bare peer records?
2. **Q2 — Notes:** accept local-only notes for the first increment (recommended),
   or require CRDT/conflict preservation now? Lossy LWW requires separate,
   explicit acceptance of whole-text loss and its undo behavior.
3. **Q3 — Burns:** accept sealer-signed origin/burn evidence and uniform terminal
   treatment, with delayed knowledge after a partial frame? Decide legacy
   objects, revoked sealer keys, retention/page-end cleanup and remote-event
   presentation. Otherwise defer remote burn replication, explicitly.
4. **Q4 — At rest and mixed versions:** accept nondestructive format migration,
   older-reader refusal and a negotiated minimum sync capability? Confirm the
   scoped relationship to ADR-0043 on acceptance.
5. **Q5 — Placement and duplicates:** agree with A on cross-page reconciliation,
   concurrent moves and stable-occurrence duplicate projection before imports
   change. Is refusing malformed duplicate input an intended exception to the
   direction, distinct from duplicates produced by valid concurrent edits?
6. **Q6 — Authority:** who accepts this ADR and any related law/spec amendments,
   and which exact accepted clauses, if any, does it supersede? This review
   makes no acceptance or supersession edit.

## Eject triggers

- Measured metadata overhead cannot fit the proposed independent budgets at the
  normal sync cadence; reconsider the metadata set or encoding.
- Product requirements need note edits on every device immediately; reopen Q2
  rather than enabling lossy LWW implicitly.
- Payload transfer between devices is proposed; re-review origin authorization,
  placement and terminal evidence for multiple local payload copies.
- The product requires complete burn knowledge at frame-only join with all peers
  asleep; partial metadata frames are insufficient and Q3 must be reopened.

## Decision history

- 2026-10-16: Proposed.
- 2026-10-16: Design-only review at `bc1bc4e4`; revised recommendations for bounded
  optional metadata, typed peer persistence, terminal evidence, field versions
  and explicit note-policy acceptance. No architectural acceptance; no Rust,
  Swift, accepted-record or law changes. Implementation remains gated on #256.
