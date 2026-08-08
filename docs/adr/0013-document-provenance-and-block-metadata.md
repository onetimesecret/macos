# ADR-0013: Document provenance and per-block metadata

- **Status:** undecided
- **Date:** 2026-08-05

## Context

Pages want metadata: created, modified, and an origin URL for content
that arrived from somewhere. Blocks want the same, so that a paragraph
can say when it appeared and where it came from. Prior art is
everywhere (Vivaldi Notes shows exactly these three fields on a note),
and the request is ordinary.

The document model cannot answer it. `syncDocument` mirrors the page to
the core as an ordered list of runs, contiguous ink between chips, on
every edit. Ink is anonymous by construction: the core receives strings
and cannot know that the third run is the same third run it saw a
moment ago. Chips are the only thing with identity, and that identity
is minted by a gesture. Nothing else in the page has a name.

An early framing split typed text from pasted text, giving identity to
pastes only. That is the wrong axis and is recorded here as rejected.
No collaborative document system draws that line, because provenance is
a property of edits against a structured document, not of the gesture
that produced the characters. Enter and paste are the same kind of
event.

### The reframe: provenance is retention

Every architecture that can say when a paragraph was created is an
architecture that remembers something after the user stopped looking at
it. The strongest ones remember deleted text too, because a
reconstructible timeline is what makes the answer exact.

This product's thesis is forgetting: TTL rungs (ADR-0011), crypto
erasure and bounded retention (ADR-0012), chips that die by omission
from the sync. So the honest statement of this feature is not "add
fields to a page." The document acquires a memory, and that memory has
to be bounded by the same clockwork that bounds everything else. Any
option below that cannot answer "when does the metadata die" is
smuggling a retention decision in as a UI affordance.

## The three architectures

### 1. Block-tree document

The document is a list or tree of block objects; text lives inside
them. Identity is trivial because Enter is not a character, it is a
structural operation that creates a block. Prior art: Notion, whose API
contract is the reference shape (`id`, `created_time`,
`last_edited_time`, `created_by`, `last_edited_by`, with settled split
and merge conventions); ProseMirror and TipTap, which reach the same
result in a flat editor by stamping node attributes as transactions
create nodes, keeping positions honest through `tr.mapping`.

Cost here: the document stops being "a little text file of ink" and
becomes a block editor, which is a product change, not only a technical
one. The metadata is stored and maintained rather than derived, so
every mutation site is an update site that can be forgotten.

### 2. Annotated runs over a flat stream

Identity as attribute spans over an otherwise flat text stream. Deep
prior art in OOXML: every run carries an RSID stamping the editing
session that produced it, and tracked changes are metadata elements
wrapped around runs, carrying author and date. Approximate and
session-granular, and it has carried per-range provenance in production
for decades.

In this codebase this is the TextKit 1 route: a paragraph-id attribute
maintained by structure diffing in
`NSTextStorageDelegate.textStorage(_:willProcessEditing:range:changeInLength:)`,
applying Notion's split and merge conventions by hand, with
`Coordinator.runs(of:)` extended to carry ids because it already
enumerates attributes. Undo comes out well, since `NSTextView` restores
attributed strings and ids resurrect with their text.

Cost: the id maintenance code is ours forever, with a long tail of
`editedRange` edge cases, and it exists to reconstruct information the
edit already contained and the transport discarded.

### 3. Operation log or CRDT

No metadata stored on the text at all. Every insertion has intrinsic
identity (actor plus logical clock), and provenance is derived from the
op history. Prior art: Google Docs deriving per-range editors from its
revision log; Peritext (Ink and Switch) for rich text with anchors and
marks that survive concurrent editing; Automerge, which implements
Peritext marks and carries actor, timestamp and message on every
change; yrs, the Rust Yjs port, faster and shipping an `UndoManager`
with origin scoping; Loro, the youngest of the three Rust CRDTs, whose
commits carry optional timestamps and metadata, whose rich text is
Peritext-informed, and whose shallow-snapshot export truncates history
at a frontier while keeping current state.

Within this architecture the rich-text merge semantics are not
interchangeable. Automerge and Loro ship Peritext-derived marks;
Y.Text's attribute model has known concurrent-formatting anomalies
(bold expanding over concurrently inserted text, mark boundary drift).
If per-paragraph metadata and annotations are the feature, mark
behavior under concurrency is a selection criterion, not a footnote.

Cost: the shell and core seam inverts. Edits flow core-ward as
operations instead of documents flowing shell-ward as snapshots, and
the core becomes the document's source of truth with `NSTextStorage`
demoted to a projection.

## Decision

Undecided.

The leaning is architecture 3, for three reasons worth recording even
before the decision lands.

First, it removes work rather than adding it. The full-document resync
per keystroke is the step that destroys identity; sending operations
instead of snapshots is a fix to an existing weak seam, and provenance
falls out of it rather than being bolted on. All three candidate
libraries carry stable position types that survive edits underneath
them (Automerge and Loro cursors, yrs sticky indices), which would
delete the clamping and forced-layout machinery in
`InkEditorView.Coordinator.restoreViewState` outright.

Second, it puts the record on the correct side of the security
boundary. A provenance log is sensitive: it records what someone wrote
and when, including what they thought better of. The core is where
zeroizing and crypto erasure already live (ADR-0012). Keeping the
record anywhere else creates a second, weaker retention story.

Third, the metadata can become correct by construction. Created is the
earliest op touching a block, modified is the latest, with no update
site to forget and no drift. The origin URL rides on the change that
introduced the text rather than on the characters, since a paste is one
change: provenance attaches to the event, where editing cannot erode
it. The core would read `public.url` and the HTML flavor's source
metadata during its own pasteboard read, so the sealed-paste contract
in ADR-0007 Amendment 1 holds unchanged and the shell still never
touches the pasteboard.

That third reason is conditional, and the condition is the library, not
the architecture. It requires change-level metadata: Automerge changes
carry actor, timestamp and message, and Loro commits carry optional
timestamps and metadata, so both deliver it. yrs carries none, so under
yrs created, modified and origin all revert to stored fields that
mutation sites must maintain, which is architecture 2's weakness
wearing architecture 3's shell. Choosing yrs therefore costs this
reason outright, and the leaning below is a leaning toward
architecture 3 as implemented by a library with change metadata.

Block identity remains policy under any option. The CRDT gives
characters intrinsic identity, but split keeping the original id and
merge killing the absorbed one is a convention adopted from Notion, not
a property of the data structure.

### The compaction ceremony

This is the open design work that architecture 3 requires and that no
prior art supplies, because nothing in the prior art is trying to
forget.

A CRDT keeps tombstones. Deleted text stays in the op log, which is
exactly what makes the timeline honest and exactly what this product
cannot ship indefinitely. For a locally authoritative document the rule
that sync requires can be broken: snapshot the current state, birth a
fresh document from it with a new actor id, discard the history. The
text survives; the record of everything it used to be does not.

Run it on the same clockwork as everything else, at rung transitions.
At that moment metadata graduates: values that were derived from ops
become materialized fields on the block, because the ops that proved
them are being destroyed. Provenance is derived while it is young and
cheap to recompute, then frozen into a summary the instant its evidence
expires.

That yields a defensible claim for the security model, scoped to a
locally authoritative document: full provenance within the compaction
horizon, a materialized summary beyond it, and no reconstructible
record of deleted content past that boundary on this device. Bounded
memory, matching bounded pages. The scope qualifier is load-bearing and
the unqualified version of this sentence must not travel; the next
section is why.

### What collaboration does to forgetting

The claims above are exact only while the document is locally
authoritative. The moment a second peer exists, garbage collection and
compaction stop being erasure. Deleted content was encoded into update
messages and broadcast the moment it was typed; every peer that
persisted incremental updates, and every relay that stored them, holds
the history regardless of what the local document has since discarded.
End-to-end encryption sharpens this rather than softening it: if
updates are encrypted before transport, the relay cannot merge or
compact, only store and forward, which makes it precisely the kind of
durable op-log archive the compaction ceremony exists to destroy.

Library-level tombstone GC (yrs collects deleted content by default,
keeping only the delete set; Automerge retains it; Loro discards it at
a shallow-snapshot frontier) is therefore a difference in local
hygiene, not in the security claim. Under any CRDT, the honest
statement once peers exist is "this device forgot, and peers were
asked to," never "the document forgot."

The language worth borrowing is GDPR's right to erasure: the things
pasted here have a right to be forgotten, and the product's job is to
honor it. That framing is honest by construction in exactly the way
"verifiably forgets" was not (ADR-0007), because a right describes an
obligation, not a state of the world. Article 17 has the same shape:
a controller must erase what it holds and take reasonable steps to
inform others processing the data, and it never promises that every
copy in the world died. Locally the right is honored on schedule by
the TTL clockwork; across peers it is discharged and propagated,
never attested.

The consequence is that forgetting and compaction are the same
ceremony, and under collaboration it is a coordinated protocol event,
not a local one: all peers drop and resync from a fresh document (new
actor identity, no inherited history), and the relay purges its stored
updates. The TTL clock can propose the ceremony; it cannot execute it
silently. This is a product-truth question that belongs in the
security model before the library choice does.

## Consequences

If architecture 3 is chosen:

- Undo moves out of the shell regardless. `NSTextView` gives it away
  today; with an authoritative core the per-sheet `UndoManager` wiring
  is replaced either by the library's own undo manager (yrs and Loro
  both ship one, origin-scoped) or, under Automerge, by inverse patches
  scoped per page that we build and own. So this is a large cost only
  under Automerge, and it is that option's main liability. Under the
  leading option the largest costs are Loro's youth and the TextKit 2
  maturity tax below, which is where estimation effort should go.
- The view layer wants TextKit 2. If the core owns blocks, flat TextKit
  1 storage fights it at every step, whereas `NSTextContentStorage`
  vends paragraph elements and a custom content manager can back them
  with core blocks. The chip blocker that forced TextKit 1 dissolves in
  the same move: `NSTextAttachmentViewProvider` replaces
  `NSTextAttachmentCell` with real views, a straight upgrade for hover,
  accessibility and the chip menu. A chip becomes a block whose content
  is a handle, which is what it always was conceptually and never was
  structurally. The maturity tax on TextKit 2 is real and includes
  silent fallbacks to TextKit 1.
- IME needs an explicit rule: marked text must produce no ops until
  composition commits, or an abandoned composition leaves phantom
  operations in the log. ADR-0006 already treats IME as a boundary
  hazard; this makes the rule load-bearing rather than defensive.
- ADR-0006's `replaceTextStorage` swap is restated as content-manager
  swapping. The invariant it protects (exactly one authority per page)
  survives; the mechanism does not.
- Multi-device sync arrives whether or not it is wanted, as a
  configuration question rather than a rewrite. Compaction is what
  constrains it, since discarding history is precisely what a syncing
  peer cannot tolerate. That conflict is better settled deliberately
  now than discovered later.
- Library choice is a three-way call, and the Swift binding situation
  weighs more than feature tables suggest for a macOS-native app.
  Automerge: change objects carry actor, timestamp and message
  natively, marks are Peritext, the history API is the provenance
  query surface, and automerge-swift is the actively polished Apple
  binding — but no shipped undo, and history retention is what the
  compaction ceremony must fight. yrs: fastest, free origin-scoped
  undo, and the TipTap/ProseMirror ecosystem if a web client ever
  matters — but no timestamps or change metadata anywhere (created,
  modified and origin all become stored fields), no history API, and
  yswift is an experimental binding that lags yrs releases, so
  choosing yrs means budgeting to own a UniFFI binding. Loro: commit
  timestamps and metadata recover the provenance-rides-the-change
  property, Peritext-informed marks, a shipped undo manager, a native
  tree type for blocks, first-party Swift bindings, and shallow
  snapshots that are very nearly the compaction ceremony as a library
  primitive — the cost is the smallest community, the youngest sync
  story, and no editor-binding ecosystem. Ranked against this ADR's
  criteria (provenance, forgetting, Swift-native, collaboration at
  handful-of-peers scale rather than Docs scale): Loro, then
  Automerge, then yrs — with the explicit caveat that Loro's youth is
  the bet, and that yrs moves to the front only if a web client
  becomes load-bearing.

Under any architecture, page-level created and modified are cheap: the
mutation sites that already route through `markDirty` are exactly the
modified-stamp sites. The origin URL is not cheap under any of them,
because it is content (reset links, URLs carrying tokens in the query
string) and therefore belongs in the sealed file only, never in the
ledger, whose content-free claim survives timestamps but not URLs.

## What would settle this

- A product answer on what forgetting means once a second device or
  peer exists. If the claim must survive collaboration, the
  coordinated forgetting ceremony above is a requirement and shapes
  what a relay is allowed to be; if the claim is scoped per-device,
  the library choice relaxes considerably.
- A product answer on multi-device. If sync is on the horizon,
  architecture 3 is the only option that does not get rewritten, and
  the compaction horizon becomes a negotiated constraint rather than a
  free choice. If sync is explicitly off the table forever, the case
  for 3 rests on provenance exactness alone and 2 becomes defensible.
- A product answer on whether the page stays "a little text file."
  Architecture 1 is a block editor and changes what the product is.
- Verified mark behavior under concurrency for the shortlisted
  libraries. The selection criterion is stated above but rests on
  reputation rather than measurement. Two concurrent edits against one
  annotated paragraph, checked for boundary drift and for annotations
  expanding over text inserted concurrently, would either confirm the
  Peritext-derived candidates or move the ranking. Assume nothing here;
  it is the criterion most likely to be wrong by the time it matters.
- A measured cost for owning undo, if Automerge is in contention.
  Building inverse-patch undo for one page, against the real gestures
  (including the seal gestures, which are already deliberately not
  undoable), would price that option's main liability. Under yrs or
  Loro the equivalent question is whether their undo managers respect
  the seal gestures' non-undoable rule without a fight.
- Whether per-block TTL is wanted. Blocks with rungs of their own are
  natural under 3, awkward under 2, and would tip the decision on their
  own.

## Eject triggers

Once decided, this ADR gets revisited when:

- Apple ships block identity in TextKit 2 as a first-class contract,
  removing the reason to own paragraph bookkeeping under architecture 2.
- Any of the three ships true history truncation with sync-compatible
  semantics, which would make the compaction ceremony redundant and
  change the retention argument. Loro's shallow snapshot is already
  most of this primitive; what remains open is whether its sync
  protocol lets peers adopt a truncated frontier without a full
  resync, which should be verified rather than assumed.
- yswift graduates to a maintained, release-tracking binding, or
  automerge-swift ships undo, either of which reshuffles the library
  ranking above.
- Provenance data appears in a threat model as an asset in its own
  right, rather than as metadata about assets, which would move the
  compaction horizon from a convenience to a requirement.
- Document size or op-log growth crosses a budget on real pages,
  measured rather than assumed.
