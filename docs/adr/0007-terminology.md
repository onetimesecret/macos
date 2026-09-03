---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0007: Terminology and positioning

- **Status:** proposed
- **Date:** 2026-07-15
- **Superseded in part by:**
  [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md),
  which owns the persistence model and restates Decision 2 in the
  narrower form recorded in Amendment 2 below. Everything else here
  stands.

## Context

The product is a macOS menu-bar companion for Onetime Secret that stages
content in transition between an origin and a destination via a small,
edge-docked window. The proposed pitch was "verifiably forgets."

The problem with that pitch is posture, not implementation. A product
that leads with a security claim is a self-proclaimed secure
application: every gap becomes a standing invitation to refute it.
And "verifiably forgets" is not adequately defensible. macOS offers no runtime proof of erasure, and
content is exposed on surfaces the application does not control (swap,
screen capture, the system pasteboard if content ever crosses it). The
claim would be false in edge cases we cannot close, and the brand takes
the hit each time someone demonstrates one.

A handy application that happens to also be secure carries no such
exposure. Its security properties are things a reader can check, not
promises a critic can break.

## Decision

Choose terminology by what is defensible, not by what is aspirational:

1. **Position as a handy application that happens to also be secure.**
   Security is a property of the product, not its headline.
2. **Drop "verifiably forgets"** and any language implying runtime
   attestation of erasure. The defensible form is auditable discipline:
   open source plus a reproducible *unsigned* build, so anyone can read
   the code and rebuild what it produces. The shipped `.app` is not
   bit-identical to anyone else's: codesigning writes a timestamp into
   the signature and stapling adds a notarization ticket, and neither
   comes from the source. So the claim stops one step earlier, at the
   artifact that does come from the source. Each build script hashes
   the assembled bundle before `codesign` touches it and writes
   `dist/<name>.presig.sha256`; the recipe for reproducing that digest,
   and the list of what it does and does not cover, is "Verifying a
   build" in `SECURITY.md`. Do not claim bit-identical shipped binaries,
   and do not claim the digest says anything about what happens in
   memory at runtime.
3. **Call it a safer clipboard, not a store.** Terminology sets the
   comparison class: a store gets judged against vaults and their
   guarantees, a safer clipboard against the system clipboard, a
   comparison it wins.
4. **Lead with claims that are architectural facts**: the secret never
   enters a browser (no form field, autofill, extension, page memory,
   or tab), and its time on the system clipboard is bounded and ends
   the moment you stage it. These are checkable statements about what
   the code does, truer and a stronger sell than "verifiably forgets."
5. **Name the exit ramp `conceal`, and reserve `reveal` for the ingress
   that does not exist yet.** Concealing is the act of turning staged
   content into a one-time link, the same verb the server uses
   (`POST /api/v3/secret/conceal`). Revealing is its corollary, opening
   such a link, and the pad has no referent for it today. "Promotion"
   is not the project's word and is not to be used. Amendment 3 records
   the full definitions and the one collision to watch.

## Consequences

- Every public statement gets an adversarial reading before it ships:
  if someone with a debugger can make the sentence false, it does not
  ship.
- Residual exposures (swap under the FileVault key, screen capture,
  memory not provably zeroed at the language level, and for content
  that arrives by paste, the interval it spent on the system
  pasteboard between the user's copy and the stage) are documented
  plainly rather than claimed away. Documenting them is consistent with
  the posture; denying them is not.
- Accept content via paste, drop target, or direct entry. On paste,
  read the pasteboard, hand the bytes to the core, and clear the
  pasteboard in the same operation.
- The engineering discipline that motivated the original pitch (locked
  buffers, zeroization on egress, pasteboard hygiene) continues
  unchanged. It is recorded in the spec as practice, not advertised as
  a guarantee.
- Brand tension resolves: an endpoint buffer is the shape of the thing
  OTS exists to avoid, but a bounded, non-persistent safer clipboard is
  strictly better than current user behavior, and "in transition
  between origin and destination" stays as framing rather than a
  security guarantee.

## Eject triggers

- Adoption evidence shows the security story is the primary reason
  people use the product and the understated framing is costing it.
  Whether to lead with security gets revisited; the claims themselves
  stay bounded by what is defensible.
- Marketing copy ships anywhere with erasure-attestation language. That
  is a violation of this decision, not a drift to accommodate.
- A shipped claim is publicly refuted. That means this ADR failed at
  its one job; the response is to tighten the claim, not to defend it.

## Amendment 1: paste is a supported ingress path

- **Status:** accepted
- **Date:** 2026-07-24

Implemented on 2026-07-25: seal-from-pasteboard clears the board in the same
locked operation and reports a failed clear; summoning the panel offers to take
what is on the board.

Folded into this ADR rather than filed separately. The ADR is still
proposed, so the changes are applied in place above and recorded here;
there is nothing to supersede.

### What changed

Decision 4 read "and never touches the system clipboard." It now reads
"and its time on the system clipboard is bounded and ends the moment
you stage it."

Consequences listed "refusing ordinary paste for ingest" in the
engineering discipline. That entry is removed, and a new bullet is
added: accept content via paste, drop target, or direct entry, and on
paste, read the pasteboard, hand the bytes to the core, and clear the
pasteboard in the same operation.

Residual exposures gain an entry: content that arrives by paste was on
the system pasteboard for the interval between the user's copy and the
stage, an interval the app shortens but does not control.

### Rationale

This ADR established that if content arrives by paste, "verifiably
forgets" is already false before staging begins. That is correct. The
error was the remedy. Falsifying a claim about erasure is a reason to
fix the claim, which Decisions 1 and 2 already did. It is not a reason
to refuse the input. The original text applied two remedies to one
problem, and the second one costs adoption without buying security.

The counterfactual makes this concrete. The secret originates
somewhere: terminal output, a generated credential, a reveal field, a
message from a colleague. The user copies it. `NSPasteboard` now holds
it, and that happened before the app was in the picture and regardless
of whether it exists. From that state, refusing paste does not un-copy
anything. It leaves the bytes on the pasteboard until something else
overwrites them, available to every clipboard manager on the machine
and to Universal Clipboard, and it sends the user to paste into
whatever window is already open. Accepting paste and clearing
immediately takes the same bytes and collapses pasteboard dwell from
indefinite to seconds. The app is not a source of pasteboard exposure
on this path. It is the only thing terminating one.

The original text also applied an asymmetric standard to the same
surface. Egress already writes the secret to `NSPasteboard`, marks it
concealed, and clears it, and that was accepted as a bounded cost.
Ingress is the identical transaction in the other direction with
identical exposure characteristics. There is no threat-model basis for
tolerating the pasteboard as an exit and disqualifying it as an
entrance.

Drag ingress is not a substitute, because it is frequently unavailable
rather than merely slower. The highest-sensitivity origins are the
ones that offer a copy button and nothing draggable: password manager
reveal fields, one-time tokens shown once, generated credentials in a
web UI. Text drag is also unreliable across terminals and Electron
apps. Direct typing is not an option for anything machine-generated.
Making drag the only path means the app is absent from a substantial
share of the moments it exists for, and absence at the moment of need
is the failure this project cannot afford.

That connects to the competitive position in the working notes: the
opponent is non-consumption, and adoption is a habit-formation
problem. Refusing paste puts the largest available friction increment
on the most habituated gesture in the operating system, at the exact
instant the user is holding a secret and looking for somewhere to put
it. Every one of those moments that the app declines is a moment
handed to an untitled Notes window that remembers forever and syncs. A
purist ingress path that goes unused protects nothing.

The stronger framing is that the app drains the pasteboard rather than
avoiding it. That is a real, differentiating behavior, it is auditable
in the way Decision 2 asks for, and unlike "never touches the
clipboard" it survives contact with how people actually acquire
secrets.

### Consequences

Paste becomes a first-class ingress path, not a tolerated one. The
panel accepts ⌘V, and summoning the panel offers to take what is on
the pasteboard directly, so that the habit being formed is one
keystroke from "secret in hand" to "secret in a chip with a TTL and
off the clipboard."

On accept, in one operation: read the pasteboard, copy into the core's
zeroizing buffer, `clearContents()`. No intermediate Swift `String`
retained by the shell, consistent with the memory discipline recorded
in the spec. If the clear fails, surface it, because a paste that
leaves the secret on the pasteboard is the failure case the amendment
exists to prevent.

Drag ingress remains and stays preferred where the origin supports it,
since it never involves the pasteboard at all. It is no longer
load-bearing.

### What this does not claim

Clearing the pasteboard bounds future exposure. It does not retract
past exposure. macOS provides no notification for pasteboard changes,
so clipboard managers poll `changeCount`, and a poll that lands inside
the window between copy and stage has already captured the content.
Universal Clipboard may likewise have propagated it off-device before
the app saw it. Nothing the app does afterward reaches those copies.

So the honest statement is that the app shortens the exposure it
inherits and creates none of its own. It does not make the origin copy
safe retroactively, and the documentation should not imply otherwise.

### Open item for the dogfood

Record whether drag ingress is ever chosen while paste is available.
If it is not, drag ergonomics do not warrant further build cost beyond
what already exists, and that finding belongs here.

## Amendment 2: the reproducibility claim is scoped to the unsigned artifact

- **Status:** accepted
- **Date:** 2026-08-05

Implemented on 2026-08-05: `scripts/build-app.sh` and
`scripts/build-backdrop.sh` emit `dist/<name>.presig.sha256` before signing, and
CI fails if the file is empty.

Folded in here rather than filed separately, as with Amendment 1. The
decision text above is edited in place; this section records what
changed and why.

### What changed

Decision 2 read "open source plus a reproducible build." It now reads
"open source plus a reproducible *unsigned* build," names the
pre-signature digest as the artifact the claim points at, and forbids
any statement that a shipped binary is bit-identical.

ADR-0012 states the same narrowing as part of its framing section and
is the authority on it. This ADR keeps the sentence people actually
quote, so it must not be the version that is wrong.

### Rationale

"Reproducible build" was a claim about the file a user downloads, and
that file cannot satisfy it. `codesign` embeds a signing timestamp,
and a stapled notarization ticket arrives from Apple after the fact.
Two builds of the same commit therefore differ, and the difference is
in the part of the bundle nobody can derive from source. A claim that
is refuted by running the shipping pipeline twice is exactly the kind
of claim the Consequences section above says does not ship.

The bundle as assembled, before any signature touches it, is a
function of the source and the toolchain. Hashing it costs one line in
each build script, and it is the strongest honest version of the
sentence: read the code, rebuild at the same commit, compare a digest
we published.

### What this does not claim

The digest covers the unsigned payload. It says nothing about erasure,
zeroization, or anything else that happens while the app runs; those
claims are covered by the code and by the scope note in `SECURITY.md`,
and no hash can carry them.

It is also not a way to check a downloaded `.app` byte for byte. The
signature is embedded inside the Mach-O rather than sitting beside it,
so there is no reversible path from a signed bundle back to the bytes
that were hashed. Verifying a download means checking the signature and
the notarization; verifying the source means rebuilding and comparing
the digest. Those are two separate checks and the documentation should
not blur them.

## Amendment 3: conceal and reveal are the vocabulary; "promotion" is retired

- **Status:** accepted
- **Date:** 2026-08-24

Folded in here rather than filed separately, as with Amendments 1 and 2.
The decision text above is edited in place; this section records what
changed and why.

### What changed

The Decision list gains item 5. This ADR is the terminology ADR and it
never defined the words for the app's own exit ramp, which is how an
agent came to invent one. The definitions are:

- **conceal**: the act of turning staged content into a one-time link.
  It matches the v3 API verb, `POST /api/v3/secret/conceal`, so the
  client and the server say the same thing about the same operation.
  This is the app's exit ramp: the noun for the step, the verb for the
  action, and the word the UI, the code and the docs all use.
- **reveal**: the corollary, opening a one-time link. In the pad it
  currently has no referent, because the pad conceals but does not
  reveal. The word is reserved for a future ingress path, pasting a
  link and opening it in the pad, rather than spent on anything else.
  In particular it is not a name for unmasking a chip, which does not
  exist and must not (doc 04: chips are never revealable).
- **"promotion" is retired.** It was invented by an agent, was never
  the project's word, and is not to be reintroduced. Neither is
  "promote", "promoted" or "promote-to-link" in this sense. Where an
  identifier carried it, it is renamed:
  `companion_chip_promote` → `companion_chip_conceal`,
  `companion_sheet_promote` → `companion_sheet_conceal`,
  `crates/ffi/src/promotion.rs` → `crates/ffi/src/conceal.rs`,
  the outcome type `Promoted` → `Concealed`,
  `PromoteOpts` → `ConcealOpts`,
  `finish_promotion` → `finish_conceal`,
  `mark_chip_promoted` → `mark_chip_concealed`,
  `PromotionView` → `ConcealView`,
  and the chip JSON field `promoted` → `concealed`.

### The one collision

`conceal` is also the pasteboard hygiene vocabulary: macOS clipboard
managers honour `org.nspasteboard.ConcealedType`, an unrelated
community convention meaning "do not record this item."

Unqualified `conceal` and `concealed` mean the Onetime Secret action.
The pasteboard flag keeps its constant name, `CONCEALED_TYPE` holding
`org.nspasteboard.ConcealedType`, because that is Apple and community
convention and renaming it would break the only thing that makes it
legible. Its struct fields are spelled `nspasteboard_concealed`
(`crates/pasteboard/src/lib.rs`) so a reader can tell the two meanings
apart at the point of use without chasing a type.

### Rationale

Two words were in circulation for one operation, and the one in the
docs was not the one on the wire. That is the failure mode this ADR
exists to prevent: terminology chosen for how it sounds rather than for
what it names. Matching the server verb costs nothing and removes a
translation step from every conversation, every bug report and every
future API doc.

Reserving `reveal` is the same discipline applied ahead of time. It is
the obvious name for exactly one future feature, and spending it on a
different meaning now would leave that feature unnameable later.

### What this does not claim

Naming the operation says nothing about what it protects. The security
properties of a conceal live in ADR-0012 and in doc 05, not in the
word.

## Decision history

- **2026-07-15:** This remains the proposed base record.
- **2026-07-24:** [Amendment 1](#amendment-1-paste-is-a-supported-ingress-path) was accepted. Each amendment is accepted independently, and none of them changes the base record's proposed status.
- **2026-07-25:** [Amendment 1](#amendment-1-paste-is-a-supported-ingress-path) was implemented: seal-from-pasteboard clears the board in the same locked operation.
- **2026-08-05:** [Amendment 2](#amendment-2-the-reproducibility-claim-is-scoped-to-the-unsigned-artifact) was accepted, then implemented: the build scripts emit a pre-signature digest and CI checks it.
- **2026-08-05:** [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md) supersedes this record in part: it owns the persistence model and the authoritative narrowing of Decision 2. All other portions remain in force.
- **2026-08-24:** [Amendment 3](#amendment-3-conceal-and-reveal-are-the-vocabulary-promotion-is-retired) was accepted.
