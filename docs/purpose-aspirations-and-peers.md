# Purpose, aspirations, and software peers

## Design direction

OnetimePad is entering a full product design change toward a notebook for work
that requires secrets. The maintainer authorized the preparation track on
2026-11-14; the exact direction and its scope are recorded in the
[operational-notebook design](spec/design/operational-notebook/README.md).

The working product thesis is:

**OnetimePad brings instructions and the credentials needed to follow them into
one working context, without requiring duplicate secret storage or a single
credential provider.**

This thesis guides design validation. It does not describe an already shipped
shared-reference system, and approval of the track does not accept every
lifecycle, storage, or authorization proposal.

## Purpose

The proposed organizing unit is the work a person needs to perform: an
investigation, recovery, integration setup, or rotation. Documentation explains
why a credential is needed at that point. Reusable references connect the work
to independently identified credentials without requiring source storage to
mirror the document structure.

The intended experience starts with writing a page. Explicit reuse, environment
bindings, and rotation records are introduced when the work needs them, rather
than requiring an initial registry configuration exercise.

## Aspirations to validate

- Reduce repeated retrieval across separate credential items.
- Make the selected environment, source, and freshness evidence understandable.
- Reuse instructions across environments without hiding resolved identities.
- Describe partial rotation honestly: notebook designation, consumer updates,
  and provider revocation are separate observations.
- Remain useful with manual external locators before integrations exist.

These are hypotheses, not measured outcomes. The
[scenario catalogue](spec/design/operational-notebook/scenarios.md) and
[prototype plan](plans/operational-notebook.md) define how to investigate them.

## Adjacent products

Password managers, secrets managers, runbooks, and notebooks are comparison
categories, not deficient substitutes. The proposed emphasis is human working
context across sources. Browser autofill, automated infrastructure management,
and provider-side rotation remain outside the initial scope.

No market research in this design establishes category novelty or superiority.
The product test is whether someone can resume an infrequent sensitive task
without reconstructing its credential context from memory.

## Historical direction and transition

The preceding [timeline-tabs design](spec/design/timeline-tabs/README.md)
explored staging and time-oriented documents. Its source is retained, and the
pre-change code is identified by
`baseline/pre-operational-notebook-2026-11-14` at
`832fc8505bbf80d51c9794deaf7972c13e81195b`.

The [transition record](spec/design/operational-notebook/transition.md) identifies
accepted-contract excerpts and unresolved changes. The [tenets](tenets.md)
remain available; this purpose update does not itself alter their substance or
supersede any accepted law or ADR.
