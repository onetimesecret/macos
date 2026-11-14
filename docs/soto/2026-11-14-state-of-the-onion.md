# State of the Onion — 2026-11-14

## A full design change

The maintainer authorized preparation for the operational-notebook direction,
with its home under `docs/spec/design/operational-notebook`, rather than a feature
directory. The [design overview](../spec/design/operational-notebook/README.md)
records the exact direction, working thesis, and scope of approval.

The working proposition is a notebook organized around tasks, with reusable
credential references and explicit sources. This snapshot is delivery context,
not independent approval of the detailed model or evidence of runtime behavior.

## Baseline

- Commit: `832fc8505bbf80d51c9794deaf7972c13e81195b`.
- Annotated tag: `baseline/pre-operational-notebook-2026-11-14`.
- `main` was clean at tagging; the commit already included the design stub.
- Baseline application marketing version: `0.48.0`.
- Preparation changes the marketing version to `0.50.0`, not the build number
  or application identity. No `v0.50.0` release tag or distribution is part of
  this work. The baseline tag is local; it has not been pushed in this session.

The tag identifies the source before the dossier and version edit. No baseline
build, automated runtime suite, or manual app session was performed at tagging.

## What the baseline documents describe

Accepted [Law 0001](../law/0001-sealed-object.md) defines the sealed-object rule:

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

Its `paste, inside OnetimePad` contract includes:

> the first paste of a cut reattaches all cut objects, while a paste after copy or a later paste of a cut clones every live reference core-side

These are scoped contract quotations, not a fresh test result. The proposed
shared identity is a different design question from the existing reference
transport. The [transition record](../spec/design/operational-notebook/transition.md)
quotes the relevant lifetime and egress rules and identifies the decisions
required to change their application.

The baseline's latest source history includes the ambient-panel withdrawal;
the editor-window decision is recorded in
[ADR-0063](../adr/0063-the-ambient-panel-is-withdrawn-until-it-returns-as-its-own-feature.md).
This entry does not certify every implementation path against that decision.

## Preparation and remaining work

The dossier includes the thesis, conceptual and rotation diagrams, seven
proposed scenarios, and the transition decision register. The
[plan](../plans/operational-notebook.md) sequences mockup evaluation, identity and
lifecycle decisions, a two-page reference slice, environment binding, and recorded
rotation. [Epic #358](https://github.com/onetimesecret/macos/issues/358) tracks that
work; it is open, and its implementation/verification tasks are not complete.

Ownership and lifetime, migration and sync, source failure behavior, context
binding, version selection, and copy/export semantics remain unresolved. Shared
workspace authorization and execution are outside the initial scope. Existing
accepted decisions are not blanket-superseded by the design direction.

Earlier roadmap issue statuses are dated records, not revalidated here. Prior
work is not declared complete or closed by this pivot. The next concrete step
is P1's synthetic interaction prototype and observation, not a production-data
migration or a replacement of the running app.
