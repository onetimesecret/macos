---
documentation_status: draft
---

# ADR-0057: Moved content lives as long as the page it lands on

- **Status:** proposed
- **Date:** 2026-10-14
- **Depends on:** [ADR-0017](0017-durable-tabs-expiring-pages.md), whose pages carry the lifetime.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

Content has no lifetime of its own. The
[document history background](../spec/feature/document-history/decision-background.md)
records the answer of 2026-08-07 that per-block TTL is not wanted: "TTL is
legible only at the granularity the user already reasons about, the page and
the onetime link, so blocks never carry rungs of their own".

Two gestures move content between pages: a drag from one page to another,
and since cd1a3bad a Timeline ⌘N, which moves the text after the caret onto
a page created now. A tail split from a page with an hour left therefore
lands on a page with its full lifetime ahead of it. The 2026-10-14 review of
cd1a3bad asked whether that is allowed.

The maintainer's answer, the same day:

> Moved text inherits the lifetime of where it arrives to. Moving it is a
> deliberate action which indicates the content has value. That value should
> be protected by extending its lifetime appropriately.

## Decision

Content moved to another page lives as long as that page, whether that is
longer or shorter than the page it left. This holds for ink and sealed
objects alike, and for every deliberate move: a drag between pages and the
checkpoint split.

Rejected: keeping the source's deadline, or the shorter of the two, which
both need a deadline per stretch of text; refusing a move onto a page that
outlives its source.

## Consequences

- A move can extend how long content lives, up to a full page lifetime, and
  asks nothing first.
- Only a deliberate move may do this. A gesture that names a place, such as
  the empty Today region, must not move content (ce6e49a9).
- For sealed objects the rule is pinned by `transfer.rs`
  `a_moved_object_ends_with_the_page_it_landed_on`. No test yet pins the
  split's ink to the new page's deadline.

## Eject triggers

- A person loses content they moved onto a page that was about to end, or
  reports content outliving the page it came from as a surprise.
- Per-block or per-range lifetimes are proposed again.

## Decision history

- 2026-10-14: Proposed from the maintainer's answer on the review of
  cd1a3bad.
