# ADR conventions

This directory holds numbered Architecture Decision Records: durable arguments for
choices that constrain later work. Each new ADR takes the next free number and
is named `NNNN-slug.md`.

An ADR records what was decided, why it was reasonable under the constraints at
the time, what it costs, and what evidence would reopen it. It is not a work
tracker or a replacement for an issue, plan, test record, or feature spec.

Start from [template.md](template.md).

## Scope

One ADR owns one decision that can be accepted, superseded, and revisited as a
unit. It may include the evidence and alternatives necessary to understand that
decision; there is no target word count.

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

Use the template's canonical `Status` value exactly: `proposed`, `accepted`,
or `superseded by ADR-NNNN`. The date is the date of the decision; use separate
metadata such as `Drafted`, `Evidence collected`, `Implemented`, or `Decision
history` for other dates.

Use `Supersedes` and `Depends on` when they help a reader navigate the decision
graph. A successor may supersede only a named decision or section of an earlier
ADR. Describe that relationship in prose and link to both records.

`documentation_status` records the quality and review state of the document; it
does not change the decision's architectural status.

## Lifecycle

### Proposed

A proposed ADR is working design material. Its body may be edited as evidence
changes. It must make unresolved questions visible and must not present a
recommendation as an accepted decision.

### Accepted

When a decision is accepted, its `Context`, `Decision`, `Consequences`, and
`Eject triggers` become the historical record. Do not rewrite them to reflect
later implementation, results, or a new conclusion.

An accepted ADR may gain a short, dated `Decision history` section for lifecycle
events, with links to their canonical records:

```md
## Decision history

- 2026-09-01: Accepted.
- 2026-09-12: Implemented in PR #123.
- 2026-10-03: Superseded in part by ADR-0042, which replaces the link-default
  policy only.
```

Use an appended, dated `Erratum` only to correct a factual error in the record.
State the correction and why it matters; leave the original statement intact.

A changed decision, changed trade-off, or new scope requires a successor ADR.
The successor links back to its predecessor, and the predecessor's status or
Decision history links forward. Do not silently update an accepted ADR in place.

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
