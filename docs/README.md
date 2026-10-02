# docs/

A map of this tree: what lives in each directory now, and what belongs
there in future. The status of record for execution is GitHub issues and
milestones; these documents are the reasoning around that status, not a
replacement for it.

## Identity documents (this directory)

- [ROADMAP.md](ROADMAP.md): where the product is going, milestone by milestone.
- [tenets.md](tenets.md): the commitments that decide arguments when two good options conflict.
- [purpose-aspirations-and-peers.md](purpose-aspirations-and-peers.md): why the app exists and which software it wants to be measured against.
- [design-brief.md](design-brief.md): the original panel-era brief; tokens superseded by the design record.

Read these first, and amend them rather than fork them when the shape of
the product changes.

## adr/

Numbered architecture decision records, ADR-0001 upward, plus the
[template](adr/template.md) and [ADR conventions](adr/README.md). One
decision per file, named `NNNN-slug.md`. An ADR is an argument with a
context and consequences, not a veto: an idea that cuts against one
reopens it rather than being cancelled by it. New decisions take the next
free number.

## law/

Numbered behaviour laws, 0001 upward, plus the [template](law/template.md)
and [behaviour law conventions](law/README.md). One governing rule per
file, named `NNNN-slug.md`, with the cluster of decisions that follow from
it and a contract table that is the test list. An ADR decides one thing; a
dated decision record snapshots many at a date; a law holds the rule they
share across the core, the shell and the UI. A law is amended in place, and
a build that contradicts an accepted law is a bug report.

## archive/

Superseded documents kept for the record, not to build from. The
pre-milestone-1 spec lives here, and so does `airlock-prototype/`, the
design canvas from the Airlock era with its artboards, design system
bundle, and screenshots. Documents move here when they are replaced.

## development/

Implementation and operator notes on specific parts, written for whoever
next touches one: [file-backed documents](development/file-backed-documents.md),
[encryption export compliance](development/encryption-export-compliance.md),
the [keymap](development/keymap-format-and-dispatch.md), the
[menu bar status item](development/menu-bar-status-item.md), the
[text editor](development/text-editor-capabilities.md), and
[signing assets and credentials](development/handling-signing-assets-and-credentials.md).
For the local and dev lanes' profiles, use
[Creating development profiles](development/development-profiles.md).
For account setup, packaging, uploading, and beta testing, use
[Distributing OnetimePad through TestFlight](development/testflight-distribution.md).
One file per subject, named for its purpose. The how of a shipped part goes
here; the why goes in an ADR.

## dogfood/

[DOGFOOD.md](dogfood/DOGFOOD.md) is the guide to running OnetimePad as a
real daily tool rather than a dev build.
[ABERRATIONS.md](dogfood/ABERRATIONS.md) is the running log of raw,
surprising, or unresolved observations from doing so. An observation
starts in ABERRATIONS and graduates into DOGFOOD, an issue, or an ADR
once it is understood.

## mockups/

Inspectable design explorations and their interaction records. The
[one-pad-picker mockup](mockups/multiple-pads/README.md) includes the reviewed
browser prototype, folder and application association proposals, and approaches
removed during review. Browser behavior and simulated native actions are
identified separately; a mockup is not evidence of a shipped contract.

The opt-in native attempt is defined in the [pad-context feature proposal](spec/feature/pad-context/README.md),
with [implementation notes](development/pad-context-experiment.md) and a
[native verification runbook](qa/pad-context-experiment.md). The
[PR #232 follow-up checklist](qa/pr232-review-followup.md) records each review
observation and its implementation resolution.

## plans/

Routes to a milestone: what has to happen, in what order, to get
somewhere specific. Some are milestone plans, some are scoped to a
single issue and its review. A plan is superseded by the work landing,
so plans age out to archive rather than being kept current.

## qa/

Verification runbooks for what CI cannot reach. The
[recovery matrix](qa/recovery-matrix.md) inventories the lifecycle cases
and what covers each one,
[hardware-verification.md](qa/hardware-verification.md) is the session
runbook, and `verification-procedures/` holds one procedure per
scenario, each written to be run by hand and reported against.
`audits/` holds dated code-audit reports, named `YYYY-MMDD-slug.md`.
Each is agent or reviewer output kept as written: a lead to confirm
against the code, not a source of project claims.

## research/

Dated reports on the external landscape and on techniques the app might
adopt: what other software does, what a technique costs, what is true
rather than assumed. Findings feed specs and ADRs; a report stays as
written and is not edited to match a later conclusion.

For application identity, supplied paths, pasteboard representations, and
explicit transfer validation, see
[macOS application context and deliberate paste](research/2026-1001-macos-context-and-pasteboard.md).

## soto/

State of the Onion notes: dated snapshots of what shipped, what is in
flight, and what is coming. One file per entry, and a later entry
corrects an earlier one rather than editing it in place. See
[soto/README.md](soto/README.md) for the convention.

## spec/

The design work. `spec/design/` is the numbered milestone-1 series, from
problem space through to open questions. `spec/feature/` holds one
directory per feature, each with a README and whatever side documents
the design needed. `spec/icon/` covers icon and identity work. A feature
directory is the home for a design in progress; conclusions firm enough
to constrain later work move into an ADR.

## Conventions

- Kebab-case filenames for new documents.
- Dated prefixes, `YYYY-MMDD`, for research reports and for side documents inside a feature spec. SOTO entries use `YYYY-MM-DD` per their own convention.
- Archive rather than delete. A superseded document keeps its history and its links.
- ADRs follow [the template](adr/template.md) and [ADR conventions](adr/README.md); they can be reopened by a good argument.
- Relative links between documents, so the tree reads the same on disk and on GitHub.
