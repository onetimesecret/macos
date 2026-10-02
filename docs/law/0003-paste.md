---
id: 0003-paste
title: Paste
status: draft
dated: 2026-10-01
governs: An explicit transfer gesture imports offered content into a stable named destination under its selected paste mode.
decisions: []
consumed-by:
  - docs/adr/0037-explicit-clipboard-operations.md
sources:
  - maintainer instructions in the 2026-10-01 design conversation (primary scope constraint)
  - docs/law/0001-sealed-object.md (accepted, sealed-object scope)
  - shell/Sources/CompanionKit/InkEditorView.swift (implementation observation only)
  - shell/Tests/CompanionKitTests/LanguageDetectionPasteIntegrationTests.swift (limited test evidence)
---

# Law 0003: Paste

Complete draft for review under [behaviour law conventions](README.md); do not
build against it as an accepted law. [ADR-0037](../adr/0037-explicit-clipboard-operations.md)
consumes this proposed rule. No numbered accepted record currently incorporates
the broader paste contract.

## The rule

Proposed governing wording:

> An explicit transfer gesture imports offered content into a stable named
> destination under its selected paste mode.

The destination is the pad/page or file receiving the command, or the location
receiving a deliberate drop. Capture that identity and the selected mode when
the transfer starts. A context hint cannot redirect pending insertion. If the
destination disappears or editing ownership is lost, cancel rather than insert
into the newly active destination. Selection changes within that same document
require the mode's defined revalidation behavior.

## Why this rule

The maintainer agreed in the 2026-10-01 conversation to this wording, exactly:

> design around explicit paste and validate the supported macOS releases before making compatibility promises.

The same conversation excludes background collection. Those are task constraints,
not proof that all existing routes enforce them. Accepted
[Law 0001](0001-sealed-object.md#sealed-fragment-representation) supplies the
existing structural-paste requirement, exactly:

> Multi-object detach, reattach and clone are core transactions: an unexpected failure commits none of the structural or payload-state changes.

That authority covers sealed-fragment operations. Broader transfer modes and
failure guarantees below are proposals that still owe coverage.

## Operation classes

- **Ordinary insertion:** an explicit paste into the chosen editable destination.
  Plain-text mode inserts supplied text; a configured code-fencing transformation
  may run as part of this deliberate paste. It does not authorize earlier reads.
- **Selected conversion:** a separately defined mode for converting an offered
  rich representation. Its priority, loss, and fallback must be documented before
  the command exists. Rich conversion is not adopted by this draft.
- **Sealed insertion:** an explicitly named sealed-paste operation or a structural
  paste of an existing private fragment, governed within its scope by Law 0001.
- **Explicit contextual transfer:** a deliberate drop, file/folder handoff, or
  invoked Service. Use the content supplied by that interaction and its receiver;
  do not use it to scan another app or to start collecting the general clipboard.
  Such routes require their own contracts before being exposed.

Application identity and pasteboard type identifiers are context, not proof of
app/window/path provenance. A pasted URL is offered data, not blanket authority
to enumerate a directory or open unrelated resources.

## The contract

Rows marked owed lack dedicated coverage. Test citations are implementation
observations of the named scenario, not acceptance of this law or OS guarantees.

| Interaction | Class | Proposed behavior | Pinned by |
| --- | --- | --- | --- |
| Ordinary explicit paste | ordinary insertion | Read for the gesture; insert once in its destination under its selected mode | `LanguageDetectionPasteIntegrationTests.swift` `testOrdinaryPasteRemainsImmediatePlainAndRunsExactlyOnce`; broader access coverage owed: no issue yet |
| Configured code-fencing paste / bypass | ordinary insertion | Transform within the explicit paste, or bypass once; do not make a background read | `LanguageDetectionPasteIntegrationTests.swift` `testAutomaticPasteFencingAppliesOneDetectedReplacement`, `testAutomaticPasteBypassUsesImmediatePlainPasteWithoutDetection` |
| Change document while a transfer is pending | any insertion | Cancel; do not insert in a replacement pad/page or file | automatic-fencing path: `LanguageDetectionPasteIntegrationTests.swift` `testDocumentSwitchCancelsPendingAutomaticPasteWithoutInsertion`; other routes owed: no issue yet |
| Edit or move selection during conversion | ordinary / selected conversion | Revalidate within the same destination according to the defined mode; never redirect to another document | current fencing behavior: `LanguageDetectionPasteIntegrationTests.swift` `testEditDuringAutomaticDetectionFallsBackAtCurrentSelection`, `testSelectionChangeDuringAutomaticDetectionFallsBackAtCurrentSelection`; broader modes owed: no issue yet |
| Paste sealed or mixed private fragment | sealed insertion / structural editing | Resolve references core-side in order and in one transaction; use cause-specific placeholders for terminal/unknown references | accepted authority: Law 0001; owed: issue 170 |
| Named sealed paste | sealed insertion | Preserve the named classification route; refuse nesting over an existing sealed object | `DocumentOpsTests.swift` `testSealedPasteOverAChipIsRefused`; broader access/destination coverage owed: no issue yet |
| Denied, unavailable, malformed, or unsupported offered data | any insertion | Explain or decline without changing the destination; valid Law 0001 reference placeholders are successful results | owed: no issue yet, representation/failure tests |
| Deliberate drop or invoked Service | explicit contextual transfer | Use the supplied interaction pasteboard and receiver; do not substitute a background general-board read | owed: no issue yet, when each route is introduced |
| Activate app, change pad, inspect association, hover picker, sort | no transfer | Read no clipboard content, make no automatic copy, and perform no paste | owed: no issue yet, clipboard-access instrumentation |
| Selected rich conversion | selected conversion | Use only its documented representation priority and conversion behavior | owed: no issue yet; no rich-conversion mode adopted |

## What the rule forbids

- Clipboard collection, preview reads on activation or hover, or polling to
  discover new clipboard contents.
- Treating an app suggestion as paste authorization or source provenance.
- Redirecting an in-flight transfer to the pad chosen by an association.
- Conversion outside the invoked or configured mode, and silent fallback from
  sealed paste into visible insertion.
- Describing a shortcut, type name, or API availability annotation as proof that
  all supported OS releases allow the same access behavior.

## The rubric for a new interaction

Name the authorizing gesture, destination identity, editing ownership, and mode.
Which offered representations will it request, in what order, and with what
conversion loss? What happens if the provider delays, access is denied, the
selection changes, or the destination closes? Is a URL being inserted as data or
used for a separately authorized resource operation? Identify the contract row
and test for each answer.

## Acceptance and tests

Core coverage must pin sealed-fragment atomicity and expected reference
placeholders under Law 0001. Seam coverage must pin payload routes, modes,
representation parsing, and no-mutation failure. Shell coverage must pin command
routing, content-read timing, cancellation, editing ownership, and stable
destination identity across pad/page/file changes.

Ordinary paste's plain-text route and configured fencing are source observations;
those tests do not validate OS privacy prompts. Type-availability checks need
separate evidence that they do not acquire content. Multi-item input, lazy
providers, malformed private fragments, input limits, file access, rich conversion,
and Services remain owed for whichever modes are actually introduced.

Before compatibility wording, exercise every shipped command route on exact
supported macOS versions/builds, including the minimum supported release. Record
signing/sandbox configuration, access setting, gesture origin, requested types,
and successful, denied, cancelled, and malformed outcomes. No such runtime matrix
was produced by the mockup work. This law changes no page/link TTL semantics.

## Amendments

- 2026-10-01: Completed the initial draft with explicit transfer classes, stable
  destination rules, configured-transformation treatment, and coverage debts.
