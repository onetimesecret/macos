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


##

<details><summary>Thinking</summary>

I now have a good picture. The term appears in several distinct recent uses:

1. **Theodore Kalaitzidis (AI & Society, 2026)** — the most formalized theoretical framework: epistemic laundering is how knowledge systems metabolize contradiction rather than collapse; generative AI implements it through (a) architectural choices embedding contestable philosophical commitments while concealing the embedding, and (b) institutional discourse naturalizing the result as technical achievement. Mechanism of "double concealment": misrecognizing one's own constructions as reality while concealing the substitution as natural progress. Synthesizes Latour, Bourdieu, Foucault.

2. **Rodrigues (The Apt Curation Model, Philosophy & Technology 2026)** — epistemic laundering related to responsibility laundering in complex organizations; tasks distributed across a hierarchy make it hard to assign blame; similarly, in AI-mediated knowledge, the provenance/authorship gets obscured (destabilizes academic integrity, plagiarism distinction).

3. **Genealogical undermining for conspiracy theories (Staudigl? philarchive 2023)** — epistemic laundering: conspiracy theorists exploit the reliability of genuine epistemic sources by "moving around" the self-correcting procedures of that source, thereby securing its epistemic reliability while deriving misleading conclusions. Like money laundering: dirty content passes through a legitimate institution and comes out looking clean. It's possible but highly non-trivial.

4. **Anonymous NOUSWS (2026)** — systematic obscuring of provenance in knowledge production: structure enters, disappears during processing, re-emerges at output misattributed as discovery.

5. **Popular/usage in AI discourse**: fabricated citations that look real; concealment of human editorial choices behind machine-generated objectivity; etc.

The common core across all uses: laundering metaphor — taking something epistemically tainted (unreliable origin, contestable commitments, hidden human choices, fabricated content) and running it through a process whose output carries the appearance of legitimacy/cleanliness (objective, scientific, machine-neutral, reliable), so the tainted provenance is obscured.
</details>

**Epistemic laundering** is the epistemological analogue of money laundering: content or commitments with a tainted, unreliable, or contestable origin are passed through a process that lends them the appearance of legitimacy, so the questionable provenance is hidden by the time the claim reaches its audience. The term is recent and not standardized — several authors have introduced it independently for closely related mechanisms:

- **Obscured provenance.** The most common core meaning: structure enters a system at one point, disappears from view during processing, and re-emerges at output misattributed as discovery — the systematic obscuring of where a knowledge claim actually came from [^3]. In AI contexts this covers things like fabricated legal citations that look real [^4], or human editorial choices (framing, coverage, perspective) concealed behind the appearance of machine-generated objectivity.

- **Kalaitzidis (2026, *AI & Society*).** The most developed theoretical framework. Knowledge systems rarely collapse under contradiction; they metabolize it. Epistemic laundering is the recursive mechanism by which systems designed for knowledge production naturalize their drift into self-stabilizing closure, operating through *double concealment*: the system misrecognizes its own constructions as reality while concealing that substitution as natural progress. He argues generative AI implements this on two layers — architectural choices that embed contestable philosophical commitments while concealing the embedding, and institutional discourse (e.g., around "AGI") that naturalizes the result as technical achievement [^1].

- **Conspiracy theory genealogy.** A different, earlier use: laundering requires exploiting a genuinely reliable epistemic source while "moving around" its self-correcting procedures — you keep the source's overall reliability but route around the safeguards that would catch your distortion. The trade-off is that the more radical the conspiracy theory, the harder this is to pull off, which is why the author treats laundering as possible but "highly non-trivial".

- **Responsibility laundering parallel.** Rodrigues (2026) connects it to responsibility laundering in complex organizations: when tasks are distributed across a hierarchy, blame becomes unassignable to any individual; likewise, when knowledge production is distributed across an AI pipeline, authorship and accountability become obscured, destabilizing distinctions like original work vs. plagiarism [^2].

In short: regardless of variant, the mechanism is the same — dirty inputs, clean-looking outputs, and an illegible middle where the provenance gets lost.

**References**

[^1]: [Epistemic laundering: generative AI and the naturalization of misrecognition | AI & SOCIETY | Springer Nature Link](https://link.springer.com/article/10.1007/s00146-026-03068-9) (49%)
[^2]: [The Apt Curation Model: An Epistemic Virtue Theory of AI ...](https://link.springer.com/article/10.1007/s13347-026-01038-z) (27%)
[^3]: [(anonymous)](https://philarchive.org/archive/NOUSWS) (18%)
[^4]: [Epistemic AI: Why Your LLM Doesn't Know What It ...](https://medium.com/@roanmonteiro/epistemic-ai-why-your-llm-doesnt-know-what-it-doesn-t-know-and-how-to-fix-it-d3d2a9686ec5) (6%)
