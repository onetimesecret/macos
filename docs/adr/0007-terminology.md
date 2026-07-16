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
   or tab) and never touches the system clipboard. These are checkable
   statements about what the code does, truer and a stronger sell than
   "verifiably forgets."

## Consequences

- Every public statement gets an adversarial reading before it ships:
  if someone with a debugger can make the sentence false, it does not
  ship.
- Residual exposures (swap under the FileVault key, screen capture,
  memory not provably zeroed at the language level) are documented
  plainly rather than claimed away. Documenting them is consistent with
  the posture; denying them is not.
- The engineering discipline that motivated the original pitch (locked
  buffers, zeroization on egress, refusing ordinary paste for ingest,
  pasteboard hygiene) continues unchanged. It is recorded in the spec
  as practice, not advertised as a guarantee.
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
