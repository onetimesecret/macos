---
id: NNNN-slug
title: Title
status: draft     # draft → accepted → superseded
dated: YYYY-MM-DD
governs: The rule in one sentence.
decisions: D-NN, D-NN (the record ids in the cluster, with the record they come from)
consumed-by:
  - docs/adr/NNNN-slug.md
  - docs/spec/design/YYYY-MMDD-record.md
sources:
  - the spec, ADR, record, source or test files the law is built from
---

# Law NNNN: Title

Read [behaviour law conventions](README.md) before filing or changing a law.

## The rule

The governing rule, quoted, and one paragraph on what it answers on its own.

## Why this rule

The patterns it combines, the failure it prevents, and the tenet it serves.
Link the spec sections and decisions that apply.

## Operation classes

The classes the rule sorts every interaction into, with what each class may
touch and whether it is reversible. Name every exemption here, once.

## The contract

The table is the test list. One row per interaction; the last column names
the test that pins the row by file and function, or what the row is owed by.

| Interaction | Class | Expected behaviour | Pinned by |
| --- | --- | --- | --- |
| | | | `File.swift` `testName`, or owed: issue NNN |

## What the rule forbids

The affordances, labels and paths that may not exist, so a reviewer can
refuse them without deriving the rule again.

## The rubric for a new interaction

The questions every new interaction is judged by, each with the class it
tests for.

## Acceptance and tests

The suites and functions that hold the contract, grouped by layer (core,
seam, shell), and the tests that pin a contradicting build and are rewritten
when the owed work lands.

## Amendments

- YYYY-MM-DD: what changed, which rows, and the issue or PR that changed it.
