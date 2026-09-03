# ADR conventions

This directory holds numbered Architecture Decision Records: durable arguments for
choices that constrain later work. Each new ADR takes the next free number and
is named `NNNN-slug.md`.

An ADR records what was decided, why it was reasonable under the constraints at
the time, what it costs, and what evidence would reopen it. It is not a work
tracker or a replacement for an issue, plan, test record, or feature spec.

Start from [template.md](template.md).

`scripts/lint-adrs.py` checks the structural half of this guide: frontmatter
carries one valid `documentation_status`, the record carries one canonical
`Status` and a `Date`, every metadata key is one this guide names,
`Decision history` is a section rather than metadata, the four required
sections are present, relationship fields link ADRs, whole and partial
supersession agree with `Status` and are claimed from both records, and local
links resolve. A link that carries a `#fragment` into a Markdown file in this
repository, or a fragment written on its own, must match a heading in the file
it points at; fragments into other file types and into paths outside the
repository are not checked. It reads metadata only from the block between the
title and the first `## ` heading, so a `Status` line written anywhere later
is invisible to it, and a passing run proves nothing about content, length,
style, or whether the argument recorded is sound. CI runs it on every pull
request; run it locally with `python3 scripts/lint-adrs.py docs/adr`.

## Scope

One ADR owns one decision that can be accepted or rejected, then revisited or,
if accepted, superseded as a unit. It may include the evidence and alternatives
necessary to understand that decision; there is no target word count.

Make a new ADR rather than extending an existing one when the proposed change:

- can be accepted or rejected independently;
- has different consequences or eject triggers;
- applies to a narrower component or concern; or
- would otherwise rewrite an accepted decision.

A closely coupled format break or architectural boundary may need a long ADR.
Do not split such a record merely to make it shorter.

Keep evolving delivery material in its canonical document and link to it from
the ADR:

- implementation sequence and issue work: `docs/plans/` and GitHub issues;
- test inventories and hardware procedures: `docs/qa/`;
- product exploration and interaction details: `docs/spec/`;
- component-level implementation notes: `docs/development/`.

## Metadata and relationships

Use these canonical `Status` values exactly: `proposed`, `accepted`, `rejected`,
or `superseded`. This is the ADR's architectural status.

For a proposed ADR, `Date` is the date it first enters `proposed` status. On
acceptance, replace it with the acceptance date. Do not change it for review,
implementation, rejection, or supersession; record those events in `Decision
history` instead.

`Decision history` is a dated Markdown section, not metadata. If present, name
it exactly `## Decision history` and use dated bullets for lifecycle events.
`Ratified` is optional metadata only for the date a separate formal governance
act ratified an already accepted decision; it is not a review or implementation
date and does not change `Status` or `Date`.

Use `Supersedes`, `Superseded by`, `Superseded in part by`, and `Depends on`
when they help a reader navigate the decision graph. `Superseded by: ADR-NNNN`
is required when `Status` is `superseded`; `Supersedes` belongs on the
successor. A partial replacement uses `Superseded in part by` and does not
change the predecessor's `Status`. A successor may supersede only a named
decision or section of an earlier ADR. Describe that relationship in prose and
link to both records.

`documentation_status` records document maintenance independently of the ADR's
architectural status:

- `draft`: still being written and not ready for review.
- `needs-review`: ready for document review, but review is pending.
- `reviewed`: document review found it accurate and usable at that time; this is
  not architectural acceptance or ratification.
- `stale`: known changes, gaps, or aging references require document review;
  this does not by itself reopen or change the decision.

A proposed ADR may be `reviewed`, and an accepted ADR may be `draft` or `stale`.
Use eject triggers and successor ADRs, not `documentation_status`, for a changed
architectural decision.

## Lifecycle

### Proposed

A proposed ADR is working design material. Its body may be edited as evidence
changes. It must make unresolved questions visible and must not present a
recommendation as an accepted decision.

### Accepted

When a decision is accepted, its `Context`, `Decision`, `Consequences`, and
`Eject triggers` become the historical record. Do not rewrite them to reflect
later implementation, results, or a new conclusion.

Use a short, dated `Decision history` section for lifecycle events, with links
to their canonical records:

```md
## Decision history

- 2026-08-28: Proposed.
- 2026-09-01: Accepted.
- 2026-09-12: Implemented in PR #123.
- 2026-10-03: Superseded in part by ADR-0042, which replaces the link-default
  policy only.
```

Use an appended, dated `Erratum` only to correct a factual error in the record.
State the correction and why it matters; leave the original statement intact.

### Rejected

A rejected ADR is terminal. It records a proposal that was considered and not
adopted; do not later change it to `accepted` or `superseded`. A materially new
proposal requires a new ADR that links to the rejected record when useful.

### Superseded

A superseded ADR remains the historical record of its accepted decision. Set
`Status` to `superseded` and add `Superseded by: ADR-NNNN` only when the whole
decision has been replaced. The successor uses `Supersedes` to link back.

When a successor replaces only a named decision or section, retain the
predecessor's existing `Status`, add `Superseded in part by`, and identify the
replaced and still-standing portions in `Decision history`.

A changed decision, changed trade-off, or new scope requires a successor ADR.
Do not silently update an accepted ADR in place.

This rule applies going forward. Existing ADRs remain records of their own
writing and amendment history; do not rewrite them solely to conform to this
guide.

## Eject triggers and enforcement

Eject triggers are observable conditions that reopen a decision: a measured
budget breach, a changed platform capability, a new workload, or user evidence
that falsifies an assumption. Name the observation and threshold or decision
owner when practical.

A violation of an existing rule is not an eject trigger. Keep non-negotiable
rules in a short `Enforcement` section when needed; a violation is corrected,
not treated as evidence that the original decision should change.
