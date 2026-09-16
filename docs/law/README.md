# Behaviour law conventions

This directory holds numbered behaviour laws: one governing rule each, with
the cluster of decisions that follow from it and the contract that pins that
behaviour across the core, the shell and the UI. Each new law takes the next
free number and is named `NNNN-slug.md`, kebab case, from 0001 onward.

A law is the third kind of record in this tree, and it exists because the
other two cannot hold a cluster:

- An ADR (`docs/adr/`) decides one thing and argues it: context, decision,
  consequences, eject triggers. It is accepted or rejected as a unit.
- A dated decision record (`docs/spec/design/`) snapshots many decisions at
  one date and is superseded whole when any of them changes.
- A law states one governing rule and the decisions that follow from it,
  with a contract table that is the test list. It names the operation
  classes the rule sorts every interaction into, what the rule forbids, and
  the rubric a new interaction is judged by.

"Law" is already this repo's word for such a thing: the focus law
(`FocusLawTests`), the boundary law (ADR-0002, ADR-0021), the governing law
of the sealed object. This track gives those clusters a home and a shape.

Start from [template.md](template.md).

## Scope

One law owns one rule that answers most interaction questions on its own.
The decisions in its cluster are numbered decisions from a dated record
(`D-NN`), listed in the front matter; the law is where their shared rule and
their shared tests live, and the record is where each decision's surface
detail lives. A law does not restate a decision's pixels, copy strings or
acceptance lines; it links them.

Make a new law rather than extending an existing one when the proposed rule
answers a different question, sorts interactions into different classes, or
would be tested by a different suite. A rule that only sharpens an existing
one is an amendment.

## Metadata and status

Front matter carries `id`, `title`, `status`, `dated`, `governs` (the rule
in one sentence), `decisions` (the record ids in the cluster), `consumed-by`
(the ADRs and records that link this law) and `sources`.

Use these `status` values exactly: `draft` (proposed, do not build against),
`accepted` (the build owes this), `superseded` (history, kept for the
argument; name the successor law). `dated` is the acceptance date, or the
date a draft first entered the tree.

## Pipeline

1. A law is amended in place. A cluster evolves as the build meets it, so a
   changed row, a new operation class or a sharpened rule is a dated entry
   under `## Amendments`, the way an ADR keeps `Decision history`. The rule
   itself changing is a new law that supersedes this one.
2. The ADR or decision record that consumed a law links it by number
   (`docs/law/0001-sealed-object.md`), and the law lists them under
   `consumed-by`, so the graph reads from both ends.
3. A build that contradicts an accepted law is a bug report, not a
   disagreement. File the issue against the contract row it breaks.
4. Every contract row names the test that pins it, by file and function, or
   says what it is owed by (`owed: issue NNN`). A row with neither is a gap
   the law is honest about, not a row to delete.
5. `scripts/lint-adrs.py` does not read this directory. Keep links relative
   and check them by hand.

## Index

The source of truth is the list the files in this directory.
