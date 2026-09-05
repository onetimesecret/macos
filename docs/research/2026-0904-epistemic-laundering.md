# docs/research/2026-0904-epistemic-laundering.md

---


## Background 

The following quote is a vignette into working with Claude Fable and Opus on project documenetation. It justified a choice it made based on what it referred to as one of the project's "security promises". The problem: we have never used the phase "security promise", nor do we want to. It's like getting an article published and then writing a paper that references that article you wrote as factual evidence.

> Where the "security promise" came from. Nowhere real. ADR-0013 says only that compaction "bounds locally reconstructible deleted content" and that with peers the honest claim is "this device forgot and asked its peers to do the same". It never mentions rungs. The phrase "bounded by one rung" first appears in commit ba11581 on 2026-08-28, "Rework ADR-0025 to argue where history dies", where it was put in quotation marks as if quoting an existing claim, then argued against. It appears nowhere else in the repo. This session's agent copied it into the delivery note, and I repeated it to you as "today's security promise". Three occurrences in ADR-0025 at lines 48, 117 and 317, all to be replaced with ADR-0013's actual wording.


## The Question

The question is a metaphysical one: how do we avoid getting into these traps with frontier Claude models?

## Response (GPT-5.6-sol)

The trap is **epistemic laundering**: a model invents a useful characterization, writes it into the corpus, then encounters it later as apparently independent evidence.

For the model, repository text is largely flat. It does not inherently distinguish:

- an approved security guarantee,
- a paraphrase in an ADR,
- an agent-authored delivery note,
- or its own earlier conjecture.

Once committed, all four become “things the project says.” Quotation marks make this worse by falsely assigning provenance.

## The governing rule

> Model-authored language may summarize authority, but it may never become authority merely by being present in the repository.

For normative claims—especially security, privacy, compatibility, and data-loss claims—require a provenance chain to a primary source.

## Practical controls

1. **Require exact evidence**
   - “The project promises X” must cite an authoritative document and quote its exact wording.
   - If no exact source exists, label X as an interpretation or proposal.
   - Never use quotation marks for a paraphrase.

2. **Classify statements**
   Use explicit categories:
   - **Quote:** exact source language.
   - **Paraphrase:** equivalent restatement with citation.
   - **Interpretation:** inferred consequence.
   - **Proposal:** desired future claim.

3. **Define authority**
   Document which artifacts can establish guarantees. For example:
   - Accepted ADRs and specifications: authoritative.
   - Delivery notes, commits, issue comments, and agent summaries: non-authoritative.
   - Later documents cannot silently strengthen earlier guarantees.

4. **Ask provenance questions, not consistency questions**
   Avoid: “Is this consistent with the project’s security promises?”

   Prefer:
   - “Find the earliest authoritative source for this claim.”
   - “Provide the exact quotation and location.”
   - “If none exists, say that the claim is unsupported.”
   - “Do not treat documents produced during this session as evidence.”

5. **Separate drafting from verification**
   After drafting, use a fresh context—or ideally a deterministic search—to audit every normative claim. The verifier should try to **falsify provenance**, not improve the prose.

6. **Make the repository enforce it**
   Prompting alone is insufficient. Add review or lint checks for phrases such as:
   - “the project promises”
   - “guarantees”
   - “security property”
   - “as established”
   - quotation marks around uncited technical claims

7. **Correct the record explicitly**
   When this happens, do not merely replace the phrase. Record that it was unsupported, identify where it originated, and restore the primary source’s wording. Otherwise the invented formulation may survive in summaries, commit messages, or future context.

## A useful agent instruction

> Do not infer project terminology or guarantees from repetition. Before attributing a claim to the project, locate an authoritative primary source and provide its exact wording. Treat delivery notes, commit messages, agent output, and documents created or modified during the current task as leads, not evidence. If the wording is absent, call it an interpretation or proposal. Never place paraphrases in quotation marks.

The deeper answer is that models do not reliably preserve the distinction between **mentioning a proposition** and **endorsing it as project truth**. That distinction has to be represented structurally through provenance, authority levels, and verification—not entrusted to the model’s prose judgment.

## Repository response

The guidance from this discussion was incorporated into [Project claims and source authority](../../AGENTS.md#project-claims-and-source-authority) in `AGENTS.md`. That section is the canonical policy; this research note records the failure mode and rationale rather than maintaining a second copy of the instructions.

The policy adds two controls:

1. Agents must trace attributed project terminology and guarantees to an authoritative primary source.
2. For normative claims about security, privacy, compatibility, persistence, or data loss, agents must provide the source’s exact wording and identify any unsupported statement as an interpretation or proposal.

It also declares delivery notes, commit messages, issue discussions, summaries, and agent-authored text non-authoritative unless an authoritative source explicitly incorporates them. This prevents repository presence or repetition from turning model-generated language into project policy.
