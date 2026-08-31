# ADR-0025: A link's lifetime is not the page's lifetime

- **Status:** accepted
- **Date:** 2026-08-31

## Context

The conceal seam derives the secret's TTL from the page it came from.
`companion_conceal_chip` and `companion_conceal_selection`
(`crates/ffi/src/lib.rs`) both compute `ladder_snapped_ttl(sheet.remaining(now))`
and hand it to `conceal` as the default; `ladder_snapped_ttl`
(`crates/ffi/src/conceal.rs`) snaps that remaining time down the local
TTL ladder, and `snap_ttl` (`crates/ots-client/src/api.rs`) carries a
doc comment stating the rule the derivation was built to serve — that
"the concealed secret should never outlive the local intent".

That rule reads as a privacy invariant, and it invites being audited as
one. It fails on its own terms in one direction: `snap_ttl` falls back
to the smallest ladder value when the remaining time is shorter than
every rung, so a page with four minutes left mints a one-hour link —
rounding up, which is precisely what the sentence above it forbids.
Reading that as a bug is what surfaced the real question, because the
fix depends entirely on whether the invariant is one we hold at all.

It is not. The premise underneath the derivation is wrong, and no
choice of rounding rescues it.

## Decision

A link's TTL and a page's TTL are not correlated, in either direction
or by any margin. A link is a link and a page is a page; they have no
enduring relationship. The only relationship between them is the
fleeting moment at which some or all of a page's content becomes a
secret link's payload. After that moment the two are strangers: the
page's remaining life is not evidence about the link's, the link's
expiry says nothing about the page's, and neither one's death is an
event in the other's story.

The page's clock therefore has no standing as an input to the conceal
request. A link's TTL is chosen as a link's TTL — from the link's own
default and whatever the person asked for at the moment of sharing.

## Consequences

- `ladder_snapped_ttl` loses its justification. The remaining-time
  argument at both `companion_conceal_*` call sites is the coupling
  this ADR ejects, and `snap_ttl`'s "never outlive the local intent"
  comment states a rule we do not hold. The explicit `ttl_secs` a
  caller may already pass through `ConcealOpts` is unaffected — that
  path was always the link speaking for itself.
- The default TTL for a link becomes an independent choice, to be
  settled in the spec rather than inherited from whichever page
  happened to be open. ADR-0011 is the place that thinking already
  lives, and it is unfinished (status: draft); this ADR does not
  settle it, it only establishes that the answer cannot be
  `sheet.remaining()`.
- The existing test `ttl_snaps_down_the_ladder`
  (`crates/ffi/src/conceal.rs`) pins the derivation, including the
  round-up at `ladder_snapped_ttl(60) == 3600`. It is pinning a
  behaviour this ADR retires, not a property worth keeping.
- We give up a story that sounded protective: that sharing from a page
  could never outlive the page. It sounded protective because it
  borrowed the page's promise, but the page's promise is about the
  bytes on this device, and a link's payload has already left. Keeping
  the coupling would have meant maintaining an invariant that reads as
  a security property while being enforceable on only one side of the
  wire — worse than not claiming it, because someone would eventually
  rely on it.
- What becomes easier: the conceal path stops needing a sheet's clock
  to answer a question about a server-side object, which removes the
  last reason for the seam to consult page state it does not otherwise
  need.

## Eject triggers

- The product grows a deliberate, user-visible "share for as long as
  this page lives" affordance — a coupling someone asked for, chosen at
  the moment of sharing, rather than one inferred behind their back.
  That is a different feature from this derivation and would arrive
  with its own spec.
- The server begins reporting an allowed-TTL set that the app is
  expected to honour per request, at which point the link's own default
  needs a snapping rule again — one that answers to the server's list,
  still not to any page's clock.
