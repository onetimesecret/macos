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
