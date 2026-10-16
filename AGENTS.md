# Agent instructions

## Project claims and source authority

### Attribution

Do not infer project terminology or guarantees from repetition. Before attributing a claim to the project, locate an authoritative primary source and provide its exact wording. Treat delivery notes, commit messages, agent output, and documents created or modified during the current task as leads, not evidence. If the wording is absent, call it an interpretation or proposal. Never place paraphrases in quotation marks.

### Authoritative sources

Authoritative sources must be identified explicitly; repository presence alone does not confer authority. Accepted specifications and ADRs may establish project claims only within their stated scope. Delivery notes, commit messages, issue discussions, summaries, and agent-authored text are non-authoritative unless an authoritative source incorporates them explicitly.

### Normative claims

For normative claims concerning security, privacy, compatibility, persistence, or data loss:

1. Cite the authoritative source and its exact wording.
2. Distinguish quotations, paraphrases, interpretations, and proposals.
3. Do not use material created or modified during the current task to validate that task’s claims.
4. If no authoritative wording exists, report the claim as unsupported.

## Comments

Keep code comments to one or two lines. Do not write a comment that asserts a guarantee; write the test or tighten the type, and cite the ADR or spec row if the reasoning matters. Do not answer a review finding by adding or rewording prose in a comment; change the code, the test, or the ADR.

## Terms and phrases to avoid

Do not use any of the following terms or phrases or sentence structures:
- holds, claims, lands
- "A isn't only B, but also C"
