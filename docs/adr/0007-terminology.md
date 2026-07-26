# ADR-0007: Terminology and positioning

- **Status:** proposed
- **Date:** 2026-07-15

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
   open source plus a reproducible build, so anyone can read the code
   and confirm the behavior.
3. **Call it a safer clipboard, not a store.** Terminology sets the
   comparison class: a store gets judged against vaults and their
   guarantees, a safer clipboard against the system clipboard, a
   comparison it wins.
4. **Lead with claims that are architectural facts**: the secret never
   enters a browser (no form field, autofill, extension, page memory,
   or tab), and its time on the system clipboard is bounded and ends
   the moment you stage it. These are checkable statements about what
   the code does, truer and a stronger sell than "verifiably forgets."

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

- **Status:** accepted, implemented 2026-07-25 (seal-from-pasteboard
  clears the board in the same locked operation and reports a failed
  clear; summoning the panel offers to take what is on the board)
- **Date:** 2026-07-24

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
