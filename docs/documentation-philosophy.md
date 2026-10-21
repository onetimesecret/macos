This is a stable body of knowledge in the field; here's the practical taxonomy:

## Decision records

- **ADRs (Architecture Decision Records)** — short, numbered docs: context → options considered → decision → consequences. Immutable; superseded by new ADRs. Great for API contracts, storage choices, tech stack.
- **RFCs / Design Docs** — Google/Amazon-style long-form docs circulated for review before implementation. Cover problem, scope, non-goals, alternatives, rollout plan. Amazon's variant is the **PR/FAQ** (write the press release first).
- **Decision logs** in Confluence/Notion for smaller calls that don't merit an ADR.

## Product behavior laws & specs

- **Product Requirement Docs (PRDs)** — the canonical spec: user stories, acceptance criteria, edge cases, analytics events, non-functional requirements. In high-PM-coordination orgs, acceptance criteria are written as **Given/When/Then** scenarios so QA and eng share one vocabulary.
- **Specs-as-code** — increasingly the norm: specs live in the repo (`docs/` or a `/spec` folder) as markdown, versioned with the code, reviewed in PRs (e.g., "spec PR" precedes "implementation PR"). Rust RFCs and Go proposals are the classic open-source models.
- **Behavior-driven specs** (Cucumber/Gherkin) for flows where executable verification matters — payment flows, permissions, onboarding.
- **Feature flags config** — often the de facto source of truth for what's actually shipped to whom; the flag registry + ownership metadata becomes a live spec.

## UX laws & design tenets

- **Design system documentation** — component specs, tokens (color/spacing/typography), interaction states, accessibility requirements. Hosted as Storybook, Zeroheight, or in-repo markdown. This is where "UI laws" (e.g., "every destructive action requires confirmation") live as enforceable component behavior.
- **Product principles/tenets** — one page, e.g., "progressive disclosure over modal walls," "never lose user input." Used as tie-breakers in disputes; referenced by ADRs and PRDs.
- **Interaction/UX guidelines** — pattern library with when-to-use rules ("use toasts for transient feedback, banners for persistent state").

## How they interlock in practice (high-coordination orgs)

| Artifact         | Owner              | Cadence      | Change mechanism                       |
| ---------------- | ------------------ | ------------ | -------------------------------------- |
| Product tenets   | Product leadership | Rarely       | Explicit revision, leadership sign-off |
| PRD              | PM, eng review     | Per feature  | Versioned, edits before build          |
| ADR / design doc | Eng (PM consulted) | Per decision | Superseded, never edited               |
| Design system    | Design + eng       | Continuous   | PRs like code                          |
| Spec-as-code     | Eng + PM           | Per feature  | Pull request                           |

Key patterns that make this work:

1. **Single source of truth per layer** — don't duplicate UX rules in both the design system and PRDs; PRDs reference the system and only record exceptions.
2. **Everything versioned and linkable** — a PRD that says "per tenet #3" and links to it.
3. **Decisions are immutable, specs are living** — ADRs record _why_, PRDs record _what_, and they update independently.
4. **Executable where possible** — Gherkin scenarios, design tokens in code, linters for accessibility rules. Rules that CI enforces don't rot; rules in Confluence do.

The common failure mode: laws written in wiki pages nobody reads. The strong orgs push everything toward "in the repo, reviewed like code, or enforced by tooling."

## User-directed corrections: documentation workflow

Use [AGENTS.md](../AGENTS.md) for project source-authority requirements and
[ADR conventions](adr/README.md#metadata-and-relationships) for decision status.
This workflow adds no behavior law or architectural decision.

- Record the user's recommendation/proposal and its implementation scope in the
  feature spec. Quote only actual verbatim user wording, never a delegated
  summary presented as user wording; otherwise paraphrase without quotation
  marks. Distinguish a recommendation/proposal being implemented, its contract,
  implementation observations, and formal approval. If formal approval status
  is not independently recorded, say so; do not invent an approver, event, or date.
- Preserve a dated amendment when correcting an earlier draft. Verify commit
  content, authorship, and dates before describing its origin. Agent-authored
  drafts, implementation commits, delivery prose, and passing tests are not
  independent human approval. A later human-authored edit alone does not prove
  approval of an earlier restriction.
- Attribute an app-specific interaction to the user direction when that is its
  source; do not present it as an external convention. Keep the correction in
  the feature spec and relevant QA procedure without expanding a separate ADR
  or changing its status.
- Before introducing a future editor restriction, document the concrete
  constraint that requires it, the alternatives considered, and why less
  restrictive alternatives are insufficient. Obtain explicit human approval
  for that specific restriction before implementation, and record the actual
  approval wording and scope. Agent recommendations, implementation prose,
  existing code, and passing tests do not constitute approval. This prospective
  requirement does not invent a historical approval event for this correction.
- Separate required outcomes from executed verification. Hardware checks remain
  pending until a recorded session supplies results; agent prose and automated
  tests do not substitute for that session or for formal approval.

Example: the [wrapping and horizontal-scrolling amendment](spec/feature/vertical-time-tabs/README.md#amendment-user-directed-wrapping-and-horizontal-scrolling-2026-10-16)
records a user recommendation/proposal being implemented within a draft feature
specification while
ADR-0020 remains proposed. Its [QA case 12](qa/verification-procedures/vertical-time-tabs.md#case-12-user-controlled-wrapping-and-shared-horizontal-scrolling)
is pending hardware verification, not a passed result.
