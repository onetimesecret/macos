# Operational notebook: transition from the baseline

## Status

Design-transition proposal prepared under the maintainer's
[recorded direction](README.md#status-and-scope-of-approval). This document maps
questions; it does not amend an accepted law, authorize a data migration, or
certify existing behavior.

## Historical baseline

| Item | Recorded value |
| --- | --- |
| Baseline commit | `832fc8505bbf80d51c9794deaf7972c13e81195b` |
| Baseline tag | `baseline/pre-operational-notebook-2026-11-14` |
| Branch at tagging | `main`, clean working tree |
| Application version at baseline | `0.48.0` |
| Application version for design preparation | `0.50.0` |
| Design home | `docs/spec/design/operational-notebook/` |

The baseline includes the maintainer's initial design stub. The annotated tag
precedes the version bump and dossier. It is not a release tag or a passing-test
marker. The baseline was inspected, not rebuilt or runtime-tested for this task.

The marketing version changes in
[OnetimePad-Info.plist](../../../../shell/OnetimePad-Info.plist).
Build numbering, bundle identity, and runtime behavior are not changed by the
version edit. No `v0.50.0` release tag is created by this preparation.

## Existing contracts and design questions

The authoritative source for the quotations in this section is accepted
[Law 0001](../../../law/0001-sealed-object.md), within its sealed-object scope.
The questions and interpretations are proposals, not implications that shared
identity already exists.

### Ambient text boundary

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

Interpretation: document composition is a suitable starting point. Cross-page
credential identity requires a separate decision about the relationship between
a sealed item and its occurrences.

### Reveal

> There
> is no reveal affordance at any privilege, so no label may imply one (D-08).

The initial notebook proposal excludes temporary reveal. No amendment to this
rule is proposed by this dossier.

### Removal and lifetime

> Removal
> detaches rather than destroys and remains undoable (D-30).

> **Destruction/lifecycle**: page expiry and explicit burn destroy payload
> bytes and are not undoable (D-33).

Question: what owns the lifetime of a value referenced from two pages with
different deadlines? Removing an occurrence, closing navigation, expiring a page,
destroying a version, and deleting an identity need explicit semantics. Shared
references do not by themselves answer these questions.

### Copy and reuse

The law's contract table, row `paste, inside OnetimePad`, includes:

> the first paste of a cut reattaches all cut objects, while a paste after copy or a later paste of a cut clones every live reference core-side

Interpretation: the existing reference transport is not a specification for
persistent aliases. The new design needs an explicit reuse operation and a
policy for page duplication, cross-notebook transfer, and external export.

### Named value egress

> **Declassification/egress**: copy decrypted contents (from the explicit
> control, menu or unquoted assignment action), decrypted drag, promotion to a one-time
> link and plaintext export send the complete payload through a named
> consequence. Payload writes remain core-side (D-29, D-32).

Proposal: retain named operations rather than interpolate values into ambient
instructions. A different output mechanism needs its own boundary review;
a hidden reveal button does not make copied plaintext inaccessible to its recipient.

## Decision register

These IDs identify design questions, not accepted ADRs. Each decision record
must cite the affected existing contracts and name any amendment precisely.

| ID | Decision needed | Gate |
| --- | --- | --- |
| ON-D01 | Credential identity, ownership, occurrence semantics, and explicit reuse versus clone | Before functional shared-reference slice |
| ON-D02 | Page expiry, occurrence removal, version destruction, identity deletion, and undo | Before shared values persist or expire |
| ON-D03 | Local/imported/locator/connected provenance, retrieval, caching, offline access, and failure behavior | Before real external retrieval; mock sources first |
| ON-D04 | Default version resolution, candidate designation, retention, and rotation completion evidence | Before version updates affect shared references |
| ON-D05 | Context binding, missing binding, visible environment, and context-switch behavior | Before reusable procedure slice |
| ON-D06 | Same-notebook copy, cross-notebook transfer, export metadata, and recipient resolution | Before those paths handle shared references |
| ON-D07 | Existing-data migration, storage format, sync, mixed-version operation, recovery, and downgrade handling | Before changing persisted data or sync messages |
| ON-D08 | Page/credential access composition and metadata visibility for shared workspaces | Deferred with shared-workspace scope |

No shared-value retention, migration, recovery, or compatibility policy is
established by this proposal. Each requires acceptance criteria and evidence
before implementation is described as conforming.

## Existing data and implementation preparation

Proposed migration investigation:

- Inventory the existing object IDs, page ownership, clone behavior, serialization,
  and sync representation against the pinned baseline.
- Identify which identities can be preserved without guessing that equal names
  or equal values mean the same credential.
- Decide whether legacy sealed objects remain page-local until explicit reuse.
- Specify interruption, unavailable source, page-expiry, concurrent-edit, and
  mixed-version cases before writing a migration.
- Use synthetic fixtures derived from supported formats; do not run conversion
  experiments on a person's saved state.

This is a work list, not a completed implementation audit. The
[plan](../../../plans/operational-notebook.md) sequences it after the interaction
prototype and before persisted shared references.

## Documentation transition

The [design overview](README.md) is the home of the new working thesis.
[Purpose](../../../purpose-aspirations-and-peers.md) identifies the new direction
and distinguishes it from the historical staging rationale. Existing tenets are
not rewritten merely to make them sound like the proposal; changes to their
substance need review.

The timeline-tabs design remains available under
[its own index](../timeline-tabs/README.md). This design does not blanket-supersede
that corpus or existing ADRs. Only a decision with an explicit replacement scope
changes an accepted contract.

The [roadmap](../../../ROADMAP.md) links the new execution track while keeping
older dated status distinguishable from current tracking. No prior issue is
closed merely because the product direction changes.
