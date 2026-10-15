---
id: 0003-paste
title: Paste
status: draft
dated: 2026-10-01
governs: An explicit transfer gesture imports offered content into a stable named destination under its selected paste mode.
decisions: []
consumed-by:
  - docs/adr/0038-explicit-clipboard-operations.md
  - docs/adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md (proposed; an unreadable envelope pastes its public text rather than declining)
sources:
  - maintainer instructions in the 2026-10-01 design conversation (primary scope constraint)
  - docs/law/0001-sealed-object.md (accepted, sealed-object scope)
  - shell/Sources/CompanionKit/InkEditorView.swift (implementation observation only)
  - shell/Tests/CompanionKitTests/LanguageDetectionPasteIntegrationTests.swift (limited test evidence)
---

# Law 0003: Paste

Complete draft for review under [behaviour law conventions](README.md); do not
build against it as an accepted law. [ADR-0038](../adr/0038-explicit-clipboard-operations.md)
consumes this proposed rule. No numbered accepted record currently incorporates
the broader paste contract, so the decision list is empty. The rows sit in a
draft law rather than in ADR-0038 because they form a contract table in which
each row names its test or its debt, which an ADR does not hold; decisions join
the front matter as a dated record numbers them.

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
| Paste sealed or mixed private fragment | sealed insertion / structural editing | Resolve references core-side in order and in one transaction; use cause-specific placeholders for terminal/unknown references; over several selected stretches, place nothing and say so before anything changes; ⌘V is its paste, and a named sealed paste of it takes nothing | accepted authority: Law 0001; the core: `crates/core/src/transfer.rs` `a_mixed_paste_keeps_its_order_with_each_cause_in_position`, `a_paste_the_body_refuses_partway_changes_nothing_on_any_page` ([ADR-0045](../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md) point 4, proposed); the editor's paste: `SealedFragmentEditorTests.swift` `testACutsFirstPasteReattachesItsObjectsAndALaterOneClonesThem`, `testAPasteAfterACopyClonesEveryObjectAsOneStep`, `testAGoneReferencePastesItsPlaceholderWhereTheObjectStood`; several stretches: `testAFragmentPastesIntoOneSelectionNotSeveral`; a named sealed paste of it: `testThisAppsOwnCopyOnTheBoardOffersNothingToSeal` |
| Named sealed paste | sealed insertion | Preserve the named classification route; refuse nesting over an existing sealed object; a board on which an item carries the app's private fragment type, as any build names it, holds nothing to seal: make no summon offer, and take nothing, leave the board and the destination as they are and say that ⌘V pastes it | `DocumentOpsTests.swift` `testSealedPasteOverAChipIsRefused`; the app's own copy or cut: `SealedFragmentEditorTests.swift` `testThisAppsOwnCopyOnTheBoardOffersNothingToSeal`, another build's `testAnotherBuildsCopyOnTheBoardOffersNothingToSeal`; broader access/destination coverage owed: no issue yet |
| Denied, unavailable, malformed, or unsupported offered data | any insertion | Explain or decline without changing the destination; valid Law 0001 reference placeholders are successful results | a fragment the core cannot read places the item's public text and reports it unreadable for the editor to explain, by [ADR-0045](../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md) point 3, proposed: `crates/core/src/transfer.rs` `an_unreadable_envelope_pastes_its_public_text_and_says_so`; the explanation: `SealedFragmentEditorTests.swift` `testAnUnreadableEnvelopePastesItsPublicTextAndSaysSo`, and for an item naming the private type whose data cannot be read, `testAnItemWhoseFragmentCannotBeReadPastesItsPublicTextAndSaysSo`; other representations, owed: no issue yet, representation/failure tests |
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
- 2026-10-13: Sealed rows (issue 170, the core's half). The fragment row
  cites the core tests draft ADR-0047 built it with. The malformed row
  records that the draft, then marked accepted, places an
  unreadable fragment's public text rather than declining, since declining
  would lose the ink copied, and reports it so the editor explains; the
  explanation is owed with the editor's paste.
- 2026-10-14: Sealed rows (issue 170, the editor's half, following Law
  0001's paste amendments of this date). The fragment row cites the
  editor's paste tests and adds that a fragment over several selected
  stretches places nothing and says so before anything changes, as
  Law 0001's copy, cut and drag refuse several stretches. The
  malformed row cites the editor's line for an unreadable envelope and
  for an item that names the private type but gives no data under it,
  which now pastes as an unreadable envelope rather than through
  AppKit's paste with no line.
- 2026-10-14: Own copy (issue 170, following Law 0001's own copy
  amendment of this date). The named sealed paste row adds that a board
  carrying the app's private fragment type holds nothing to seal: no
  summon offer is made, and ⇧⌘V or the offer's button takes nothing,
  leaves the board and the page as they are and points at ⌘V. It
  had sealed the fragment's placeholder text and cleared the board. The
  fragment row says that ⌘V is its paste, and both cite the editor's
  test.
- 2026-10-14: Drafts withdrawn (following Law 0001's drafts withdrawn
  amendment of this date). Draft ADR-0047, which the fragment and
  malformed rows cited, was withdrawn without ratification. The
  fragment row now cites
  [ADR-0045](../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md)
  point 4 and the malformed row its point 3, both proposed, so the
  malformed row's placing of an unreadable fragment's public text rests
  on a proposal, as Law 0001's paste row does. ADR-0045 links this law,
  so `consumed-by` lists it. No behaviour changes.
