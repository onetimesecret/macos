# Operational notebook: scenarios

## Status and reading guide

These are **proposed acceptance scenarios**, not executed tests or reports of shipped behavior. Full design-change preparation is approved; detailed architectural and policy decisions are not. Every expected future outcome below is an acceptance target, subject to the identified decision gates.

Navigation: [Overview](README.md) · [Conceptual model](conceptual-model.md) · [Transition](transition.md) · [Plan](../../../plans/operational-notebook.md).

All names, locations, identities, and version labels here are synthetic fixtures. `demo-current-v1` and `demo-candidate-v2` are version labels, not real credentials. No scenario requires a real account, provider mutation, or command execution.

**Contract baseline:** the accepted law's paste row, quoted in the [transition record](transition.md#copy-and-reuse), specifies cloning on paste after copy. Shared identity reuse in these scenarios is proposed, not an existing capability.

**Authoritative boundary:** accepted [Law 0001, lines 69–125](../../../law/0001-sealed-object.md) states:

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

The same source states:

> There
> is no reveal affordance at any privilege, so no label may imply one (D-08).

**Proposal scope:** procedures describe work; they do not execute commands. Reveal and shared team authentication are excluded from initial scope. Recorded external outcomes are evidence supplied to the notebook, not operations performed by it.

## ON-S01 — Troubleshoot from a working page

**Synthetic setup:** `Demo delivery investigation` contains diagnostic notes and a credential occurrence for `Demo delivery access`. A manual locator points to `vault.example.invalid/demo/delivery`.

**Proposed interaction:** the person starts with the incident page, adds the locator beside the relevant step, and identifies the credential role without first configuring a registry. An imported fixture value is recorded later as a copy with provenance.

**Acceptance targets:**
- The page presents the procedure, occurrence, and locator together without forcing its organization to mirror source folders.
- Manual location, imported version, and retrieval evidence are distinguishable; import alone leaves freshness unknown.
- The person can record an externally observed diagnostic result without the notebook executing the step or presenting a reveal control.

**Decision gate:** the representation and lifetime of freshness evidence need approval; this scenario supplies no provider-verification guarantee.

## ON-S02 — Reuse one identity on two pages

**Synthetic setup:** `Demo delivery investigation` and `Demo deployment checklist` need the same `Demo delivery access` identity, but use different local annotations.

**Proposed interaction:** the person explicitly reuses that identity on the second page and edits its page-local annotation.

**Acceptance targets:**
- Both occurrences visibly reference the same identity while preserving distinct page-local annotations.
- The reference view lists both documented occurrences; it does not assert discovery of all runtime users.
- Explicit reuse is distinguishable from native paste after copy, which the baseline contract specifies clones every live reference core-side rather than creating an alias.
- A new candidate version can be recorded without implying that both pages or their consumers automatically adopted it.

**Decision gate:** default version selection, migration from clones, and the exact reuse interaction need approval. Equal labels or equal values do not establish an approved identity-merging rule.

## ON-S03 — One procedure, two explicit contexts

**Synthetic setup:** `Demo release check` requires the role `delivery access`. `Demo staging` binds it to `Demo staging access`; `Demo production` binds it to `Demo production access`.

**Proposed interaction:** the person chooses an environment and inspects its binding. A second fixture omits the production binding.

**Acceptance targets:**
- The selected environment and its bound identity are observable alongside the procedure.
- Switching contexts changes the displayed binding without rewriting the reusable procedure or implying shared credential values.
- The missing-binding fixture remains visibly unresolved; it does not silently use the staging identity.
- Roles and environments can be introduced after a simple page exists, rather than as mandatory initial registry configuration.

**Decision gate:** binding precedence and version-selection policy need approval. This scenario is not an authorization or execution test.

## ON-S04 — Record a partial rotation

**Synthetic setup:** a rotation attempt for `Demo delivery access` relates `demo-current-v1` and `demo-candidate-v2`. Documented consumers are `Demo sender A` and `Demo sender B`.

**Proposed interaction:** the person records candidate adoption and successful external verification for A, failed verification or no observation for B, and unknown provider revocation for the current version.

**Acceptance targets:**
- A and B display different adoption and verification records in the same attempt.
- Current and candidate remain identifiable; a candidate entry is not presented as universal deployment success.
- Provider revocation remains independently unknown even when A has verified the candidate.
- A later synthetic provider-revocation record does not rewrite B's missing or failed verification as success.
- The attempt view exposes incomplete evidence rather than compressing the situation into a linear global state.

**Decision gate:** current-version promotion, retry, abandonment, concurrent attempts, and completion criteria need approval. No provider rotation or revocation is performed by this scenario.

## ON-S05 — External source unavailable

**Synthetic setup:** a connected external source has a simulated unavailable retrieval outcome. A separate imported fixture copy has provenance but no evidence of present freshness.

**Proposed interaction:** the person opens the relevant occurrence and inspects source, version, retrieval outcome, and any previously recorded evidence separately.

**Acceptance targets:**
- Unavailability is visible as a retrieval observation, not conflated with identity deletion or provider revocation.
- The imported copy is distinguishable from the connected source and is not labeled current merely because it exists locally.
- Missing freshness evidence is observable; the page does not imply that retrieval succeeded.

**Decision gate:** retry, cached-value access, offline behavior, connector authentication, and fallback policy remain unresolved. This scenario does not authorize automatic fallback or establish retention behavior.

## ON-S06 — Remove an occurrence or expire a page

**Synthetic setup:** two pages reference one proposed identity. One page is removed from the working context or reaches an expiry condition; the other remains relevant.

**Accepted source:** [Law 0001](../../../law/0001-sealed-object.md), lines 110–112, states:

> **Structural editing**: move, select, reference-only copy, cut, in-app
> paste, clone and remove-from-page act on document structure. Removal
> detaches rather than destroys and remains undoable (D-30).

Lines 119–120 state:

> **Destruction/lifecycle**: page expiry and explicit burn destroy payload
> bytes and are not undoable (D-33).

**Proposed interaction:** design review distinguishes removing one occurrence, page expiry, version destruction, and identity deletion, including effects on the other page.

**Decision-gated acceptance target:** an approved policy and any necessary law amendment define each effect, undo behavior, and surviving reference presentation before shared-identity expiry is implemented. A synthetic acceptance test can then observe both pages and the affected version against that policy.

**Unresolved:** does page expiry destroy a shared version, detach an occurrence, or require a different lifecycle model? This proposal selects none of these outcomes and does not supersede accepted law.

## ON-S07 — Copy or export a page with references

**Synthetic setup:** a page contains local annotations, one proposed shared-identity occurrence, and one manual locator. Destinations are another page and a synthetic external document.

**Proposed interaction:** design review separates native clone, explicit reuse, reference transfer, and named plaintext export rather than treating all of them as one copy action.

**Accepted source:** [Law 0001](../../../law/0001-sealed-object.md), lines 115–118, states:

> **Declassification/egress**: copy decrypted contents (from the explicit
> control, menu or unquoted assignment action), decrypted drag, promotion to a one-time
> link and plaintext export send the complete payload through a named
> consequence. Payload writes remain core-side (D-29, D-32).

**Decision-gated acceptance targets:** after policy approval, synthetic copy/export fixtures expose whether the result is a clone, a reference, or a snapshot, which version it represents, and how unresolved references appear to a recipient. Native clone behavior is not silently changed to aliasing. Any proposed plaintext path remains a named consequence under the quoted law, not an ambient export assumption.

**Unresolved:** same-notebook versus cross-notebook identity, recipient resolution, metadata inclusion, expired references, and export version selection need explicit decisions. No new export or compatibility guarantee is established by this scenario.
