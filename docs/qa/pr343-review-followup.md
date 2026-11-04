# PR 343 review follow-up

This delivery record tracks [PR 343](https://github.com/onetimesecret/macos/pull/343).
It is not project authority. The initial review and CI snapshot below applies
only to `f71aa52f73be3a2e730b57d9799e99f6e48d8e24`; later revisions need their own
checks. A proposed or unverified fix remains Pending here.

## Sources and baseline

- [Claude's completed review][claude] contains twelve sections with several
  independent subpoints. It was a static review on a Linux runner.
- [Greptile's inline finding][greptile] and [summary][greptile-summary] report
  the documentation variation selectors. Its formal review is COMMENTED.
- [Copilot's inline finding][copilot] and [formal review][copilot-review]
  report the same selectors. Its formal review is COMMENTED.
- [Codex's summary][codex] reports a completed review of `f71aa52` with no
  findings. This is not a formal approval.
- The audit found two formal reviews, two unresolved and current inline
  threads, and three conversation comments. No human review or formal
  CHANGES_REQUESTED submission was present. The earlier Greptile missing-label
  notice was superseded after `greptile-review` and `claude-review` were added;
  the reviews subsequently completed.

At this baseline, all six jobs in [CI run 41735375190][ci] passed. The separate
[Claude review workflow][claude-run] also completed successfully. No completed
CI failure required a code fix in this snapshot.

| Job | Result at f71aa52 | Evidence |
| --- | --- | --- |
| logic (ubuntu) | Success | [job 126263105046](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263105046) |
| platform (macos) | Success | [job 126263105091](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263105091) |
| shell (macos) | Success | [job 126263105060](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263105060) |
| release packaging (macos) | Success | [job 126263105286](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263105286) |
| ADR conventions | Success | [job 126263105218](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263105218) |
| secret scan | Success | [job 126263104688](https://github.com/onetimesecret/macos/actions/runs/41735375190/job/126263104688) |
| Claude Code Review | Success | [run 41735374996][claude-run] |

## Complete finding ledger

The C identifiers follow Claude's section numbers. Letter suffixes separate
independent suggestions in the same section. G1 and CP1 are the two inline
threads. Pending means that verification or native evidence is still owed;
it does not mean the point has been silently dropped.

| ID and source | Finding | Disposition and evidence |
| --- | --- | --- |
| C1a / G1 / CP1 — [Claude][claude], [Greptile][greptile], [Copilot][copilot] | Interleaved U+E0101 selectors affect literal searches and copied text in both documentation files. | Retained by the maintainer's explicit 2026-11-03 decision to preserve TextProv markers. Literal-search and copy limitations remain. Both inline threads were resolved by Delano after that decision was recorded in the PR description; resolution is not a removal of the selectors or a correction of those limits. |
| C1b — [Claude][claude] | Selectors also occur in the stored maintainer quotation. | Retained by the same explicit marker decision. The original 2026-11-03 chat instruction is identified directly as the primary source; the amendment is not independent evidence. Stored selector-interleaved text is not described as a byte-identical copy of the message. |
| C1c — [Claude][claude] | Add a repository-wide guard rejecting several broad Unicode ranges. | Not adopted. A blanket ban is separate scope and conflicts with the requested provenance markers. This PR does not establish a repository-wide Unicode policy. |
| C2 — [Claude][claude] | The menu's captured flag assumes item-action delivery precedes return from `NSMenu.popUp`. | Addressed locally: presentation is deferred from the action, and `testNewPadMenuDefersPresentationUntilTheActionReturns` passed in the 30-test pad-picker subset. The original native ordering concern was not an observed failure. |
| C3a — [Claude][claude] | The shortcut gate applies to every key-window field editor, while the test name and contract mention creation only. | Addressed in the earlier revision: Law 0007 named the general field-editor rule and `testPadShortcutsYieldWhileAnyFieldEditorIsEditing`. Third-review routing coverage replaces that predicate-only test with `testClaimedPadDigitsAreConsumedDuringFieldEditingWithoutSwitchingPads`; event-window precedence remains covered by `testPadShortcutFieldDetectionUsesTheEventWindowBeforeItsKeyWindowFallback`. R3-1/2 record the stronger event-consumption behavior. |
| C3b — [Claude][claude] | The default `isEditingField = false` makes omitted context easy. | Addressed locally: the helper requires the field-editor argument and callers provide it explicitly. The 30-test pad-picker subset passed. |
| C4 — [Claude][claude] | Return over an initially empty draft does not explain the refusal. | Addressed: attempted submission supplies `pad.name.empty`, and passive dismissal or Cancel clears stale attempted/failure feedback. `testEmptyReturnExplainsTheMissingNameAndCancelClearsTheFeedback` and the native empty-Return case passed in the final 37-test run. |
| C5 — [Claude][claude] | The retention test changes a struct Boolean rather than dismissing a real presentation. | Addressed at native-fixture scope: `testNativeOutsideDismissalRetainsTheDraftForReopening` sends an outside click, reopens the shared form and checks retained text plus whole-draft selection. It passed in the final run. Full card/editor/Settings integration and focus handoff remain manual scope. |
| C6 — [Claude][claude] | Resting or deactivating the card might leave a visible disabled form. | Addressed: the initial isolated fixture confirmed a visible disabled name field. The production form now passively dismisses when disabled, retains its draft and cancels stale focus work. `testDisablingThePresenterDismissesTheFormAndRetainsItsDraft` passed, including restored text and whole-draft selection after re-enabling. Actual card-rest/app-deactivation routing remains manual scope. |
| C7a — [Claude][claude] | Cancel's keyboard shortcut and `onExitCommand` duplicate explicit Escape handling. | Retained intentionally: both explicit Escape routes are idempotent fallbacks. Native field-focused Escape passed; removing a fallback solely as a style change is not required by an observed defect. |
| C7b — [Claude][claude] | Native popover Escape might bypass explicit cancellation and retain the draft. | Not reproduced on the field-focused route: `testNativeEscapeClearsTheDraftAndDismissesTheForm` passed and confirmed a cleared draft plus closed native popover. Button-focused Escape and full app entry surfaces remain manual scope. |
| C8 — [Claude][claude] | A second click on Settings' anchor might dismiss and immediately reopen the popover. | Not reproduced in the native fixture: `testNativeAnchorClickClosesTheExistingForm` passed, closing the existing form and retaining its draft without reopening. No speculative toggle fix was applied. Actual Settings integration remains a manual check. |
| C9 — [Claude][claude] | Prefer trailing, adjacent Cancel/Create buttons. | Retained product choice. The current grouping follows the approved visual proposal. ADR-0055 concerns wording and is not evidence for button placement. The layout is not changed solely to follow the bot's preference. |
| C10 — [Claude][claude] | Conditional feedback changes popover height and might clip text. | Manual geometry/appearance scope remains. No clipping was proven. The optional geometry observer was unreliable and removed; its failure is neither a product defect nor a successful pixel-layout result. The longest failure message, minimum width and both appearances remain in the hand checklist. |
| C11a — [Claude][claude] | The failure test disables pads, which removes the real creation UI. | Addressed locally: the test now creates a dirty synthetic file, enters pending-file-close state, verifies refusal without pad changes, resolves that decision and retries. The 30-test pad-picker subset passed. |
| C11b — [Claude][claude] | The test name says activation happens once but its assertions count created pads. | Addressed locally: it is named `testCreationTrimsTheNameCreatesOnePadAndClearsTheForm` and passed in the 30-test pad-picker subset. No activation-call count is inferred from its assertions. |
| C11c — [Claude][claude] | Creation tests and their helper lack a clear section. | Addressed locally: Creation and Shared model fixtures sections separate these tests from rename-only tests. |
| C12a — [Claude][claude] | Creation and rename trim at different layers. | Addressed locally: creation trims before calling `createPad`, and the trimmed-name regression test passed in the 30-test pad-picker subset. |
| C12b — [Claude][claude] | Reopening a retained creation draft does not explicitly select it whole. | Addressed: selection uses the actual form field's window. Native outside-dismissal/reopening and disabled-presenter/reopening tests passed while checking whole-draft selection. |
| C12c — [Claude][claude] | The creation field lacks an explicit one-line limit. | Addressed locally: the creation field now uses `.lineLimit(1)`. Native layout checks remain separate. |
| C12d — [Claude][claude] | Confirm caption casing, colon use and the visible label's accessibility relationship. | Retained wording and explicit descriptive spoken label: visible Name and accessible Pad name identify the same purpose. No observed labeling defect or project colon requirement was established. Full VoiceOver and app-surface accessibility verification remain manual scope. |
| C12e — [Claude][claude] | The source list points back to the same task's amendment. | Addressed in documentation: the source now identifies the maintainer's original 2026-11-03 chat instruction directly. This delivery record and the edited law are not offered as independent authority for that instruction. |

## Review refresh at 0118d18e

A complete feedback refresh at 2026-11-03 23:15 UTC confirmed live PR head
`0118d18eda1e8005ff494d275f777c8a9ab6042e`. No new completed-review finding
appeared beyond the original ledger above:

- [Codex's summary][codex] completed review of this exact head with no
  findings at 2026-11-03 23:14:02 UTC.
- [Claude's sticky comment][claude] had changed from its initial completed
  twelve-section review to an in-progress checklist for
  [run 41737339145](https://github.com/onetimesecret/macos/actions/runs/41737339145).
  Its earlier findings remain recorded above; the new checklist is not a
  completed review of the fix push.
- [Greptile's summary][greptile-summary] still identified `f71aa52` as its
  last reviewed commit. Its original COMMENTED review and marker thread were
  unchanged; its old confidence score is not a current-head review result.
- [Copilot's COMMENTED review][copilot-review] also remained attached to
  `f71aa52`, with the same single marker suggestion and no additional finding.
- The two original marker threads remained unresolved and current. Their
  content is unchanged, and the maintainer's explicit marker-retention
  decision remains the disposition. There were still two formal reviews,
  two inline threads and three conversation comments, with no formal
  CHANGES_REQUESTED submission.

This is one snapshot, not a continuing watch or final merge-readiness
assessment. The pending Claude review and later pushed heads require fresh
checks; no new completed finding does not mean every review finished.


## Completed second review of 0118d18e

[Claude's sticky comment][claude] subsequently completed the second review
for `0118d18eda1e8005ff494d275f777c8a9ab6042e` in
[run 41737339145](https://github.com/onetimesecret/macos/actions/runs/41737339145).
The comment was updated at 2026-11-03 23:18:13 UTC. This section supplements
the original twelve-section ledger; it does not replace those findings or
the preceding in-progress snapshot.

The two original [Greptile][greptile] and [Copilot][copilot] marker threads
are now resolved by Delano after the PR description recorded the explicit
decision to preserve TextProv markers. This is resolution by maintainer
decision, not removal of the selectors or a repair of their search/copy
effects. Two formal COMMENTED reviews and three conversation comments remain;
there is no formal CHANGES_REQUESTED review. Greptile and Copilot still refer
to `f71aa52`; Codex's completed no-findings result refers to `0118d18e`.

All R2 findings below come from [this completed Claude review][claude].
It remains a static review: Claude did not rerun the Swift suite or
localization lint, and its body still cites the earlier 28-test PR report.

| ID | Finding or smaller point | Disposition and evidence |
| --- | --- | --- |
| R2-1 | The outer `onExitCommand` and native popover Escape may take different ending paths; move the handler to the field or track dismissal intent. | Not reproduced on the field-focused native route: Escape cleared the draft and dismissed the popover in the final passing suite. The dual idempotent Escape fallbacks are retained intentionally. Button-focused Escape and full app entry-surface routing remain manual scope. |
| R2-2a | The shortcut monitor uses the app key window instead of the keyboard event's window. | Addressed: the monitor checks `event.window ?? fallbackWindow`. `testPadShortcutFieldDetectionUsesTheEventWindowBeforeItsKeyWindowFallback` passed, including event-window precedence and fallback for an event without a window. |
| R2-2b | Whole-draft selection also depends on the global key window. | Addressed: the form selects through the actual name-field anchor's window rather than the global key window. Native reopening tests passed while verifying whole-draft selection after outside dismissal and presenter disable/re-enable. |
| R2-3 | The field-editor gate changes pad switching in every text field. | Retained deliberately. The general rule is now explicit in Law 0007 and the renamed regression test; it is not described as creation-only behavior. |
| R2-4 | An attempted-submit or failure message survives automatic dismissal even though only draft retention is intended. | Addressed non-blocker: setting `isPresented` false clears stale submitted/failure state while retaining the draft. Empty-Return and failure/retry tests cover cleared feedback on reopening; retained text and proactive validation of an invalid draft remain distinct. |
| R2-5 | Cancel and Create remain separated rather than grouped at the trailing edge. | Retained approved-proposal layout. The review calls this a judgment question; the existing code comment it cites is not project authority for placement. ADR-0055 concerns wording. |
| R2-6a | Add a comment explaining deferred menu presentation, or move deferral to the caller. | Comment-only correction not adopted under AGENTS.md's instruction to address findings through code, tests or an ADR. The deferred-action regression test records the tested behavior. Moving the deferral remains optional cleanup rather than a demonstrated defect. |
| R2-6b | The explicit spoken Pad name label is not associated with the visible Name caption. | Retained explicit descriptive spoken label and visible field label. No observed mismatch of purpose was established. Full VoiceOver and caption-association verification remain manual scope rather than an unverified code failure. |
| R2-6c | Creation trims input that the catalog also trims. | No further action: the reviewer explicitly describes the duplication as harmless and accepts the existing trimming test. |
| R2-6d | The generic creation-failure string describes a pending file decision even though disabled pads or catalog-load failure can also return nil. | Deferred as pre-existing and ordinarily unreachable through the visible creation form, as the reviewer notes. This does not broaden the PR into catalog-error-copy changes. |
| R2-6e | The shared model fixture still uses a pad-rename suite prefix. | Addressed: the shared model fixture now uses the `pad-picker-` suite prefix. UUID isolation and `isolatedModel(defaults:)` are unchanged. |
| R2-7 | Interleaved provenance selectors break literal search, and removing them is a maintainer choice about the repository convention. | Retained by the maintainer's explicit Preserve TextProv markers decision. Search/copy limitations remain acknowledged. Earlier research cited by the reviewer is not used here to establish that literal search works for interleaved marks. |


## Completed third review of 96d459c3

[Claude's sticky comment][claude] completed a third static review of
`96d459c3b32c6b2aa4bacf5929f0b9a2a4be62f7` in
[run 41739871281](https://github.com/onetimesecret/macos/actions/runs/41739871281),
updated at 2026-11-03 23:37:11 UTC. This section supplements both earlier
reviews. A successful review workflow means the review completed; its two
medium findings still required follow-up before merge.

All six jobs in [CI run 41739871435](https://github.com/onetimesecret/macos/actions/runs/41739871435)
passed on this head. The [shell job](https://github.com/onetimesecret/macos/actions/runs/41739871435/job/126278411730)
completed its `swift test` step, which runs the complete shell suite through
`scripts/test-shell.sh`. [Greptile's summary][greptile-summary] reviewed
this exact head at 23:35:31 UTC, reported 5/5 and no new actionable issue.
[Codex's summary][codex] reported no findings on this exact head at
23:33:05 UTC. Those summaries do not replace Claude's distinct findings.

There remain two formal COMMENTED reviews, both on `f71aa52`, two resolved
marker threads, and three conversation comments. No formal CHANGES_REQUESTED
review was present. All R3 rows below refer to [Claude's completed review][claude];
its Linux checkout could not run the AppKit or Swift tests.

| ID, severity and location | Finding or smaller point | Disposition and evidence |
| --- | --- | --- |
| R3-1, medium, `PadShortcutMonitor` | A creation form can remain open with a button focused, so the field-editor predicate alone does not suspend pad switching. | Addressed and verified in the final 40-test local run: each shared form registers a stable UUID with PageModel's transient presentation set and unregisters on dismissal/disappearance. The model test checks independent IDs and permits activation only after the last unregisters. `testNativeFormSuspendsPadShortcutsAfterTheNameFieldResignsFocus` checks real shared-form registration. Actual button-focused app integrations remain manual scope. |
| R3-2, medium, `PadShortcutMonitor`, `PageKeyboardMap`, `PageModel.perform` | Returning a suspended pad-owned digit can allow the hidden SwiftUI `pageSelectN` shortcut to receive it. Predicate-only tests do not establish event routing. | Addressed and verified: production monitor dispatch uses the tested `handle` route. It recognizes configured pad-owned digits before the suspension gate and returns nil while a creation form or field editor is active. Passing handler tests verify consumed events leave the pad unchanged, final unregister permits activation, and remapped/explicitly unbound digits return the original event. This establishes the monitor's disposition; full app shortcut delivery remains a separate manual integration check. |
| R3-3, low-medium, `PadCreateForm.task(id: isEnabled)` | Move disabled-presenter dismissal from presented content to the presenter; deferred menu presentation might otherwise appear and immediately dismiss. | Retained intentional shared-form policy. The earlier native fixture observed the disabled visible field, and the resulting dismissal regression passed. The proposed stale deferred-callback failure has not been observed. Moving the same policy into multiple presenters is not required by the evidence. |
| R3-4, low, `PadCreateForm` focus selection | Selecting the whole draft on every focus gain can overwrite a click's intended caret position. | Implemented as one-shot selection per opening. The proposed native raw-responder refocus test passed even when the one-shot guards were temporarily removed, so that counterfactual rejected its sensitivity; the method/helper were removed. Do not treat its earlier passing result as caret proof. Pointer/keyboard refocus and caret preservation remain manual validation gaps. Existing reopening tests cover initial whole-draft selection only. |
| R3-5, low, anchor helper names | `PadMenuAnchor` and `PadMenuAnchorView` also locate the creation field's window. | Addressed: helpers are now `PadViewAnchor` and `PadViewAnchorView`, with documentation for menu placement and scoped field selection. Old helper names are absent from source/tests; the changed source compiled in the passing local run. |
| R3-6a, low, form caption | The separate visible Name caption duplicates the explicitly named field in the accessibility tree. | Addressed in source: the decorative Name caption uses `accessibilityHidden(true)` while the field retains its explicit descriptive label. The form compiled and passed its native regressions. Spoken VoiceOver output remains a manual check; a source modifier is not speech verification. |
| R3-6b, low, validation accessibility | A newly visible validation message may not be announced. | Manual verification gap. No native spoken-output observation establishes an announcement defect or validates a proposed announcement. The QA procedure records this check without promising speech. |
| R3-6c, low, button-focused empty Return | The disabled default-action button may not report an empty name when Return starts from button focus; only field submission has native coverage. | Manual verification gap, distinct from the passing field-focused empty-Return test. Record the actual button-focus result before deciding whether another route is needed. |
| R3-7a, low, `PadCreateFormTests.click(_:in:)` | An immediate dequeue can silently skip a posted click and report a later dismissal timeout. | Addressed and verified: each posted mouse phase has a bounded one-second dequeue and explicit XCTUnwrap diagnostic identifying an undelivered mouse-down or mouse-up. All seven native cases passed in the final 40-test local run. Next-head CI remains pending. |
| R3-7b, low, native fixture CI | The native tests require a real window server and should pass on CI as well as locally. | Addressed for the reviewed head: the complete shell suite's `swift test` step passed in the linked macOS CI job. Revised tests still require their own current-head validation. |
| R3-8a, low, QA run record | A `/private/tmp` log is not durable reviewer-accessible evidence. | Addressed in the QA procedure and verification table: the path is identified as an ephemeral local execution artifact, with the successful exact-head CI job linked separately. It does not establish project authority. |
| R3-8b, low, PR description count | The review snapshot cited a 30-versus-31 PadPickerTests mismatch. | Superseded metadata snapshot. The PR description had already been updated to the combined 37-test scope, comprising 31 PadPickerTests and six native cases. A later count needs its own update after execution. |
| R3-9, informational, documentation markers | Repeat the literal-search and copied-text costs of interleaved selectors. | Retained under the maintainer's explicit Preserve TextProv markers decision. Both original threads remain resolved by that decision; search/copy limits remain acknowledged. No removal or repository-wide Unicode ban is proposed. |

## Completed fourth review of 3c5584d6

[Claude's sticky comment][claude] completed its static review of
`3c5584d6b17d83b786964442c3bb43e74446df39` at 2026-11-03 23:55:04 UTC in
[run 41742284138](https://github.com/onetimesecret/macos/actions/runs/41742284138).
All six jobs in [CI run 41742284267](https://github.com/onetimesecret/macos/actions/runs/41742284267)
succeeded on that head. [Codex][codex] reported no findings and
[Greptile][greptile-summary] reported 5/5 with no new actionable issue on the
same SHA. The two original COMMENTED reviews, two resolved marker threads
and three conversation comments remain the complete review surfaces.

The six rows below refer to [this completed Claude review][claude]. Its Linux
runner did not execute AppKit tests. Subsequent isolated native diagnosis
confirmed the window-close registration issue recorded in R4-1.

| ID | Finding | Disposition at this snapshot |
| --- | --- | --- |
| R4-1, medium | A creation UUID might survive if presented-content teardown callbacks are skipped when its window closes or host is removed. | Confirmed before the fix: closing the fixture window hid the popover but left suppression active; host removal already cleaned up. Addressed and verified in the final 45-test run: the registry weakly references each anchor, prunes expired references, and counts only anchors in visible windows. Closed/detached/expired presentations cease suppressing digits without relying on teardown callbacks. Direct tests verify route restoration, late attachment/detachment and expired anchors; both native teardown cases passed. This proves observable suppression recovery, not physical deletion of every live-but-hidden entry. |
| R4-2, low-medium | Creation-wide suspension also consumes pad digits from another window before the surface-owner check. | Retained intentional model-wide pad gate, including independent presentations and both surfaces. R3-1/2 and the tested route record this scope. The separate event-window field-editor check remains deliberately narrower. |
| R4-3, low | Selection still uses a guarded, uncancellable main-queue dispatch. | No demonstrated defect: the reviewer explicitly says the guard makes a late callback inert. Combining focus and selection tasks is optional cleanup, with pointer/keyboard caret behavior still manual scope. |
| R4-4, low | A disabled presenter could request a form that immediately dismisses itself. | No currently reachable failure shown. The review calls the present route unreachable and discusses a future section-disable change; R3-3 already records the intentional shared-form policy and tested disabled-presenter dismissal. |
| R4-5, low | The native click helper could dequeue a mouse event belonging to another fixture window. | Addressed and verified: the helper asserts that each dequeued mouse event targets the fixture window before dispatching it, retaining bounded dequeue and phase-specific diagnostics. All nine native cases passed in the final 45-test local run. |
| R4-6, nit | The PR description supposedly still reports 37 tests, six native cases and head 96d459c3. | Rejected by live metadata: the PR description already reports head 3c5584d6, 40 tests comprising 33 picker and seven native cases, the current ledger link and manual limits. The criticism uses an obsolete description snapshot. |

## Completed fifth review of 0f27529f

[Claude's static review][claude] completed at 2026-11-04 00:11:42 UTC on
`0f27529f8b9cf5019599a41c1552092369ee959f` in
[run 41744165272](https://github.com/onetimesecret/macos/actions/runs/41744165272).
All six jobs in [CI run 41744165278](https://github.com/onetimesecret/macos/actions/runs/41744165278)
passed. [Codex][codex] completed with no findings on this SHA; Greptile's
summary still refers to `3c5584d6`, so it is not current-head evidence.
A [fresh Greptile attempt failed](https://github.com/onetimesecret/macos/pull/343#issuecomment-6618863452)
at 00:13:39 UTC with service reference `8382cbc7-87fc-454c-a124-cb3a2917878c`.
This is review-service availability, not a source finding. The complete surfaces
now comprise two COMMENTED reviews, two resolved marker threads and four
conversation comments, with no additional pages.

| ID | Finding | Disposition at this snapshot |
| --- | --- | --- |
| R5-1, medium | A retained presentation binding might reopen the form after conditional presenter removal/reinsertion. | Not reproduced in the final 47-test native run, without a production binding change. Conditional presenter removal cleared the flag, hid the form and preserved the draft; restoring the control did not reopen it, and explicit opening restored the draft. Host removal also checks the presentation flag. `testRemovingAndRestoringThePresenterDoesNotReopenTheNativeForm` preserves this fixture coverage; full app entry-surface observations remain manual scope. |
| R5-2, low-medium | A registered anchor can initially lack a visible native window, leaving an alleged startup shortcut race. | Unproven interleaving. The late-attachment test establishes the predicate's values, and polling establishes eventual readiness; neither demonstrates delivery of a shortcut between a visible form and anchor attachment. Visibility-bounded suppression remains intentional after the reproduced stale-window fix. |
| R5-3, low | The shortcut-path getter prunes weak registry entries as a side effect. | Addressed: the getter now only queries live visible anchors; expired-entry pruning runs during registration/unregistration. The existing lifetime and route-restoration regressions passed in the final 47-test run. |
| R5-4, low | Add rationale prose for consuming a recognized digit with no corresponding pad. | Comment-only correction not adopted under AGENTS.md. `testReservedDigitWithoutAPadIsConsumedOutsideFieldEditing` directly verifies the recognized missing-pad digit is consumed and changes neither the active pad nor selected page; it passed in the final run. |
| R5-5a, low | The command-digit fixture varies characters but uses the keycode for 1 throughout. | Addressed: the fixture supplies the native keycode corresponding to each digit and keeps characters consistent. The complete 37-test picker subset passed. |
| R5-5b, low | Native fixtures depend on a window server and need current-head CI. | Addressed for the reviewed SHA: its complete macOS shell suite and all six CI jobs passed. Later source/test changes need fresh checks. |
| R5-5c, low | Field-editor suspension applies generally rather than only to creation. | Retained deliberate behavior, already recorded in R2-3/R3-2 and Law 0007. Remapped and explicitly unbound digits keep their configured routes. |
| R5-6, positive checks | State ordering, trimming, remaps, menu deferral, removed references and locale inventory read correctly. | No finding to fix. These checks do not broaden the Linux static review into runtime validation. |

## Completed sixth review and CI failure at 53def43b

[Claude's static review][claude] completed at 2026-11-04 00:27:01 UTC on
`53def43b22397153f37fa3d48b13c4f87db0aa9c` in
[run 41746167285](https://github.com/onetimesecret/macos/actions/runs/41746167285).
[Codex][codex] reported no findings; [Greptile][greptile-summary] refreshed to
this exact SHA at 00:26:21 UTC with 5/5 and no new issues. Its earlier service-error
comment was removed after that successful refresh. The current complete surfaces
are two COMMENTED reviews on `f71aa52`, two resolved marker threads and three
conversation comments, with no additional pages.

| ID | Finding | Disposition |
| --- | --- | --- |
| R6-1, medium | General field-editor suppression extends beyond New Pad. | Retained deliberate behavior already recorded in R2-3/R3-2 and Law 0007. The configured-remap/unbound exception remains tested; the review provides no new runtime defect. |
| R6-2, low-medium | Sheet/modal and non-owner routing still pass recognized digits through. | Pre-existing routing retained. A non-owner monitor must permit the owning route to process the event; active native sheet/modal responder delivery is distinct from demonstrated page fallthrough. No native failure under a sheet was observed. |
| R6-3a, low-medium | Initial selection has one deferred attempt and no retry if the field editor is not ready. | Unproven timing hypothesis. Local reopening tests verify whole-draft selection; the current CI failures below occur before a popover opens and do not establish a selection failure. No retry policy is added without such evidence. |
| R6-3b, low-medium | The selection closure captures an enabled-environment snapshot while other state reads remain live. | The reviewer explicitly describes this as harmless today. Existing presentation/focus guards and disabled-presenter behavior remain; no new observed defect establishes a correction. |
| R6-4, low | Leaving and returning to Settings might reopen the form. | Repeats R5-1, which did not reproduce in the permanent native conditional-removal/restoration test without a production binding change. Full app entry-surface observations remain manual scope. |
| R6-5, informational | The borderless nonactivating card's popover focus is not established by a titled-window fixture. | Known manual validation gap. The ordinary-window fixture does not prove raised-card focus; it also does not demonstrate a card defect. The existing QA procedure keeps actual card/editor/Settings integrations separate. |
| R6-6a, low | Empty Return from button focus may give no feedback with Create disabled. | Existing manual gap from R3-6c. Field submission and actual button-focused delivery remain distinct; the CI empty-Return case failed while opening, before submission could be exercised. |
| R6-6b, low | Fixed width may not accommodate larger accessibility text. | Manual geometry/accessibility-size gap. No clipping was observed or measured; the approved form layout is not changed on this static possibility alone. |
| R6-6c, low | Validation feedback may not be announced by VoiceOver. | Existing manual spoken-output gap from R3-6b. Source labels and conditional text do not establish an announcement result. |
| R6-6d, low | Expired weak entries are pruned only during register/unregister. | The review explicitly calls the accumulation harmless rather than a correctness issue; expired or hidden anchors do not contribute to the query. No further change. |
| R6-6e, low | Add a comment explaining deferred menu presentation. | Comment-only correction not adopted under AGENTS.md. The deferred-menu action test already exercises the behavior. |
| R6-6f, low | Synthetic event fixtures may be unreliable on shared CI. | Fixture-only correction implemented and locally verified: mouse events go directly to the owned window after visible-anchor/layout readiness; click acknowledgement and popover visibility have separate lazy timeout diagnostics. No app activation/policy requirement remains. All 47 New Pad tests passed both focused and within the final broader run. Fresh full-shell CI is pending; broader unrelated local failures remain recorded separately. |
| R6-7, markers | The review says selector-interleaved identifiers in Law 0007 prevent navigation to tests. | Rejected mechanically: all 100 inline test-identifier spans contain zero variation selectors, and literal search finds the new restoration identifier. General prose search/copy limitations remain acknowledged under the maintainer's explicit marker-preservation decision. |
| R6-8, validation scope | Claude could not execute Swift, ADR or documentation checks on its Linux runner. | Recorded limitation, not a new defect. Its workflow success is completion of static review; actual local and CI execution results remain separate. |

The [shell CI job 126299589555](https://github.com/onetimesecret/macos/actions/runs/41746166953/job/126299589555)
failed on this head. The suite reported 2,859 tests, 17 skips and six failure
records: three initial-popover wait failures and three corresponding thrown
errors. The affected methods were
`testClosingThePresenterWindowDismissesAndUnregistersTheNativeForm`,
`testDisablingThePresenterDismissesTheFormAndRetainsItsDraft` and
`testNativeEmptyReturnExplainsTheMissingNameWithoutDismissing`.
Their initial native button clicks did not produce a visible popover. The other
seven native cases and all 37 picker cases passed. The other five CI jobs,
including release packaging, passed. These observations established fixture
opening failures; they did not establish a product defect. Later local attempts
and fixture corrections are recorded below.

## Completed seventh review of aa321bd5

[Claude's static review][claude] completed at 2026-11-04 00:52:02 UTC on
`aa321bd50c8d7790e9a395eb299ea91544589ff5` in
[run 41749262985](https://github.com/onetimesecret/macos/actions/runs/41749262985).
All six jobs in [CI run 41749262950](https://github.com/onetimesecret/macos/actions/runs/41749262950)
passed, including [the shell job](https://github.com/onetimesecret/macos/actions/runs/41749262950/job/126309962999).
[Codex][codex] reported no findings on this SHA. Greptile's latest summary still
refers to `53def43b`, so it is not current-head review evidence.

R7 supersedes earlier iteration dispositions retaining general field-editor
consumption. Those rows describe their dated heads. Final suppression is scoped
to visible New Pad presentations; unrelated fields retain their baseline route.

| ID | Finding | Disposition |
| --- | --- | --- |
| R7-1 | Early consumption bypasses the app-modal/sheet passthrough guard. | Addressed and verified in the final 50-test run: modal/sheet passthrough precedes New Pad consumption. Both inverse regressions use a live visible creation anchor, assert original-event identity and leave pad/page selection unchanged. |
| R7-2a | General field-editor suppression changes unrelated field shortcuts. | Final scope changed and verified: the general field-editor helper/gate and its event-window fallback were removed. Visible New Pad registration protects the name field and buttons; `testOtherFieldEditorsKeepExistingPadShortcutActivation` verifies the prior unrelated-field route. Earlier broad-gate dispositions are superseded. |
| R7-2b | The law describes branch-introduced field-editor behavior as existing. | Corrected attribution: the earlier broad gate was new in this PR and is now superseded. The anchored-form approval is not used as authority for that earlier shortcut decision. |
| R7-3 | A titled-window fixture does not establish focus/rest behavior on a borderless nonactivating card. | Both representative isolated interactive borderless nonactivating-panel probes passed: focus/Return creation, and rest/disable dismissal with retained-draft reopening. Their configuration matches the relevant panel shape; actual production-controller handoff remains manual scope. The earlier sheet already used SwiftUI-managed presentation, so no new architectural approval is inferred. |
| R7-4 | Shared state wording can suggest one global retained draft. | Clarified in the law: the shared component/type is reused, while each presenter owns an independent `PadCreation` value and draft. The distinction does not establish one global creation instance. |
| R7-5 | Expired registry entries remain until another register/unregister. | Safe residue already recorded in R6-6d. Nil/hidden anchors do not suppress digits, and lifetime tests establish observable recovery. No further query mutation or registry redesign. |
| R7-6 | Validation lacks associated field accessibility feedback. | Field accessibility hint metadata now uses the current message and compiled in the passing run. Automatic VoiceOver announcement and spoken-output behavior remain manual; the static assertion that sibling text is unreachable is not native proof. |
| R7-7 | Manage Pads is synchronous while New Pad presentation is deferred. | Pre-existing AppKit Settings-window route retained. A native window action and SwiftUI popover state are different paths; no observed Manage Pads failure justifies changing this route. |
| R7-8 | The real picker anchor opens an NSMenu while its form light-dismisses. | Added the combination to manual QA. The existing Settings-style anchor test does not prove the real picker/menu event ordering. |
| R7-9 | The application event queue could supply a foreign matching mouse event. | Current exact-head CI passed all six jobs. Owned-window delivery and explicit mismatch diagnostics remain; no retry/drain or window-server skip is added to hide a future failure. |
| R7-10a | Stray blank line before the native test class ends. | Addressed: the stray closing blank line was removed during the representative-panel test additions. |
| R7-10b | New Pad heading and Create Pad wording are redundant. | Approved wording retained. ADR-0055's title-case rule does not independently require the proposed shorter label. |
| R7-10c | State initialization allocates a reference before SwiftUI preserves its stored instance. | Harmless pre-existing pattern; no new identity defect is shown. |
| R7-11 | Prose contains preserved provenance selectors. | Retained under the maintainer's explicit decision; prose search/copy limits remain acknowledged. This does not revive the rejected claim that inline test identifiers are marked. |
| R7-12 | Local log paths are weak authoritative evidence. | Kept explicitly as ephemeral execution artifacts, not project authority. Result summaries, public CI links and the limits of local runs remain separate. |

## Completed eighth review and CI failure at 746777c6

[Claude's static review][claude] completed at 2026-11-04 01:08:07 UTC on
`746777c6ac586a2e46ff74aedf9def6cf9580aa1` in
[run 41751323891](https://github.com/onetimesecret/macos/actions/runs/41751323891).
It reports no blocking defect and confirms the final modal ordering and current
law/QA test references. [Codex][codex] reported no findings on this SHA.
Greptile's summary still refers to `53def43b`; its 00:56:06 UTC service-error
comment predates this head and does not establish a current-head review result.

| ID | Finding | Disposition |
| --- | --- | --- |
| R8-1 | Extract the native-anchor registry into a dedicated type. | Optional architecture cleanup; the reviewer explicitly calls the current code correct. No extraction is required for the feature or observed failures. |
| R8-2 | Any visible New Pad form suppresses reserved digits across windows. | Retained shared-model scope, already recorded in R4-2. Actual Settings/editor focus-transition behavior remains a manual integration check; no new surviving-popover defect was observed. |
| R8-3 | Selection uses the popover's current field editor and an escaping State-backed closure. | Correct for the current single-field form, as the reviewer notes. A future second field could require tighter targeting; no present defect or comment-only correction is established. |
| R8-4 | Accessibility hint is help metadata rather than a reliable spoken-error channel. | Metadata scope remains explicit. Automatic speech was never verified or promised; alternate notification/value behavior remains manual/accessibility follow-up. |
| R8-5 | Fixed width may crowd at larger text sizes. | Existing manual layout gap. No new clipping observation or geometry measurement is supplied. |
| R8-6 | Deferral proves action-return ordering more directly than the end of tracking. | The tested boundary is after the menu action returns. PR wording can use that narrower boundary; no comment-only source correction or stronger lifecycle guarantee is added. |
| R8-7 | Synthetic native clicks and short waits can be unreliable on CI. | Fixture-only correction passed all 50 focused tests: the hosting view accepts first mouse; geometry anchors do not hit-test and also accept first mouse. Normal application event delivery is restored for popover outside-click monitoring, with window-number checks, readiness and action acknowledgement retained. No activation/policy changes, retries, skips or product changes were introduced. Next-head CI remains pending. |
| R8-8 | Whitespace-only input shows validation while typing. | Pre-existing sheet behavior retained; the reviewer identifies no regression. |
| R8-9, minor checks | Approved button wording, single-locale inventory and anchor renaming. | Wording retained; locale and reference checks are positive rather than new defects. |
| R8-10, provenance | Marker tooling cost persists. | Explicit marker-preservation decision remains. General prose costs are acknowledged; current law/QA identifiers resolve, and superseded names remain only in dated ledger rows. |
| R8-11, verification | The review's closing paragraph cites 47 tests and aa321bd5 as current body evidence. | Rejected as stale metadata: the live body reports 50 tests and head 746777c6, with prior-head CI and current pending checks distinguished. The static reviewer did not execute the suites. |

The [shell job 126316827272](https://github.com/onetimesecret/macos/actions/runs/41751323841/job/126316827272)
failed on this head: 2,862 tests, 17 skips and four failure records, comprising
two initial-click wait failures and their two thrown errors.
`testNativeFormSuspendsPadShortcutsAfterTheNameFieldResignsFocus` and
`testNativeNameFieldFocusAndReturnCreateThePad` did not request presentation.
Diagnostics show an inactive app, non-key visible window, prohibited activation
policy, a visible attached 78-by-24 anchor, false presentation state and no form
window. The other ten native cases, including both representative panel cases,
and all 38 picker cases passed. The other five CI jobs passed. This establishes
a fixture-click failure; no product defect or later pass is inferred.

## CI fixture-host follow-up at 7082889a

[Claude's current static review][claude] completed at 2026-11-04 01:26:17 UTC
with no merge-blocking defect. Its suggested foreign-event cause is not the
observed failure: the explicit mismatch diagnostic did not fire.

The [shell job 126323252468](https://github.com/onetimesecret/macos/actions/runs/41753269711/job/126323252468)
failed two initial clicks: `testClosingThePresenterWindowDismissesAndUnregistersTheNativeForm`
and `testNativeEmptyReturnExplainsTheMissingNameWithoutDismissing`. The app was
inactive/prohibited and the healthy, visible titled host was not key; the click
never requested presentation. All other ten native cases, including both borderless
representative panel cases, and all 38 picker cases passed. The full suite reported
2,862 tests, 17 skips and four records (two waits plus two throws); the other five
CI jobs passed.

An unshipped titled-panel/hard-key experiment was not adopted. The final component
fixture opens through production `PadSettingsRoutes.beginCreating()` on a stable,
unconditional presenter. A separate conditional surface exercises only removal
and restoration. Entry-click and OS-activation coverage remain manual; product code,
app activation/policy, retries and skip policy are unchanged.

## Verification rounds

| Stage | Head or scope | Result |
| --- | --- | --- |
| Initial implementation | `f71aa52` | The recorded local pad-picker run passed 28 tests. The six CI jobs and Claude workflow above passed. Native placement, focus, endings, dismissal and appearance checks remained pending. |
| First follow-up | `0118d18eda1e8005ff494d275f777c8a9ab6042e` | Pushed at `0118d18e`. PadPickerTests passed 30 tests. The initial combined native-fixture attempt failed during harness correction, so that early attempt is not reported as a full pass. All six jobs in [CI run 41737339144](https://github.com/onetimesecret/macos/actions/runs/41737339144) and [Claude run 41737339145](https://github.com/onetimesecret/macos/actions/runs/41737339145) subsequently succeeded on this head. |
| Second follow-up | `96d459c3b32c6b2aa4bacf5929f0b9a2a4be62f7` | The local combined run passed 37 tests: 31 PadPickerTests and six PadCreateFormTests, with zero failures. `/private/tmp/pr343-final-focused-tests.log` is an ephemeral local execution artifact. Durable exact-head evidence is the successful [shell CI job](https://github.com/onetimesecret/macos/actions/runs/41739871435/job/126278411730); all six CI jobs and Claude's workflow passed. Codex reported no findings and Greptile 5/5 on this head. Claude's third review nevertheless identified the R3 follow-ups above. |
| Third follow-up | `3c5584d6b17d83b786964442c3bb43e74446df39` | The final local run at 2026-11-03 23:48:46 UTC passed 40 tests: 33 PadPickerTests and seven PadCreateFormTests, zero failures. The earlier 41-test pass included an insensitive caret-refocus test: it also passed after temporarily removing the one-shot guards, so that test/helper were removed and its result is not caret proof. The first compile attempt exposed non-Sendable NSEvent crossing `MainActor.assumeIsolated`; the callback now returns a consumed Bool across that boundary and selects event/nil outside it. `/private/tmp/pr343-third-round-tests.log` is an ephemeral local execution artifact. All six jobs in [CI run 41742284267](https://github.com/onetimesecret/macos/actions/runs/41742284267) and [Claude run 41742284138](https://github.com/onetimesecret/macos/actions/runs/41742284138) succeeded on this head; Codex reported no findings and Greptile 5/5. Claude's distinct R4 follow-ups are recorded above. |
| Fourth follow-up | `0f27529f8b9cf5019599a41c1552092369ee959f` | The final local run at 2026-11-04 00:03:24 UTC passed 45 tests: 36 PadPickerTests and nine PadCreateFormTests, zero failures. `/private/tmp/pr343-lifetime-fixed-tests.log` is an ephemeral local execution artifact. The earlier split diagnosis reproduced stale window-close suppression; the weak-anchor/visible-window correction now passes native close and host-removal cases plus direct route-restoration/lifetime tests. The click helper checks event-window identity. All six jobs in [CI run 41744165278](https://github.com/onetimesecret/macos/actions/runs/41744165278) and [Claude run 41744165272](https://github.com/onetimesecret/macos/actions/runs/41744165272) passed on this head; Codex reported no findings. Greptile's summary still refers to 3c5584d6. Claude's distinct R5 follow-ups are recorded above. |
| Fifth follow-up | `53def43b22397153f37fa3d48b13c4f87db0aa9c` | The final local run at 2026-11-04 00:18:54 UTC passed 47 tests: 37 PadPickerTests and ten PadCreateFormTests, zero failures. `/private/tmp/pr343-presenter-restoration-tests.log` is an ephemeral execution artifact. The conditional-removal/reinsertion hypothesis did not reproduce, so no production presentation-flag change was made. An earlier fixture attempt failed during programmatic reopening; the fixture now opens through its actual New Pad button and locates the popover through its own weak native anchor, avoiding process-wide window discovery. Getter purity, digit keycode fidelity and missing-pad consumption coverage are complete. Subsequent CI failed in three native initial-opening cases as recorded above; the other five CI jobs passed. Claude completed, Codex reported no findings and Greptile reported 5/5 on this exact head. The local focused pass does not replace the failed full-shell gate. |
| Sixth candidate full run | Working revision after `53def43b` | A candidate full local attempt failed: 435 OnetimePadTests reported two failures, and 2,424 CompanionKitTests reported 22 failure records, including 20 records from ten native readiness failures. The strict app/key-window precondition was invalid for the CLI fixture. Four earlier unrelated records were CommandPaletteControllerTests:935, SavePanelIdentity:61 and DayScrollTests:3017/3044, before the new native fixture ran; no unrelated production fix is inferred. At that stage, owned-window delivery and focused validation were pending; later candidate results are separate below. This full attempt failed. |
| Sixth follow-up | `aa321bd50c8d7790e9a395eb299ea91544589ff5` | Focused New Pad tests passed 47/47 at 2026-11-04 00:40:00 UTC. After a diagnostic-only refactor, the final broader CompanionKit run ended at 00:42:34 UTC with 2,424 tests, ten skips and two failure records in unchanged `testThePassARailClickPublishesLeavesItsJumpTravelling` (DayScroll lines 3017/3044), before New Pad fixtures. All ten native and 37 picker cases passed in that broader run. CI at 53def43b skipped that animation test for Reduce Motion, so it is not a remote pass of the local failing case. `/private/tmp/pr343-window-delivery-tests.log` and `/private/tmp/pr343-companion-kit-tests.log` are ephemeral execution artifacts. The local broader suite remained failing. Subsequent exact-head [CI run 41749262950](https://github.com/onetimesecret/macos/actions/runs/41749262950) passed all six jobs, including the full shell suite. Claude completed and Codex reported no findings; R7 records the remaining review dispositions. |
| Seventh follow-up | `746777c6ac586a2e46ff74aedf9def6cf9580aa1` | The final local combined run at 2026-11-04 00:57:39 UTC passed 50 tests: 38 PadPickerTests and twelve PadCreateFormTests, zero failures. `/private/tmp/pr343-modal-panel-tests.log` is an ephemeral execution artifact. Modal/sheet precedence, prior unrelated-field activation, creation-only suppression and both representative panel cases passed. Accessibility hint metadata compiled; speech and actual production-controller handoff remain manual. The earlier broader-suite failures remain historical limits. Subsequent CI failed in two initial-click fixture cases as recorded above; the other five jobs passed. Claude found no blocker and Codex reported no findings. Relevant modal/scope and both representative panel cases passed remotely; the full shell gate remains failed. |
| Eighth follow-up | `7082889aa6aeba0ea581378053cb5a2f93239f12` | The final focused run at 2026-11-04 01:14:34 UTC passed 50 tests: 38 PadPickerTests and twelve PadCreateFormTests, zero failures. `/private/tmp/pr343-first-mouse-tests.log` is an ephemeral execution artifact. The fixture now explicitly accepts inactive-window first mouse, keeps geometry anchors out of hit-testing and uses normal application event dispatch. Product code is unchanged; relevant routing and representative panel cases had already passed on the failed prior CI head. Subsequent CI still failed two initial-click titled-host cases as recorded above; first-mouse acceptance alone did not make the inactive CLI host key-eligible. The other native/routing cases passed; no global green result is asserted. |
| Ninth follow-up | Working revision after `7082889a` | The final focused run at 2026-11-04 01:36:07 UTC passed 50 tests: 38 PadPickerTests and twelve native form cases, zero failures. `/private/tmp/pr343-production-route-tests.log` is an ephemeral execution artifact. Component opening uses the production creation route on an unconditional presenter; conditional removal/restoration has its own fixture. Entry-click and OS activation remain manual. The unshipped hard-key host experiment was not retained. Product code is unchanged; next-head CI/reviews remain pending. |

The [native QA procedure](verification-procedures/rename-in-place.md) keeps the
remaining observations separate from automated state tests. Existing TextProv
markers are preserved under the maintainer's explicit decision. No installed
application is used as a disposable test fixture.

[Apple's first-mouse reference](https://developer.apple.com/documentation/appkit/nsview/acceptsfirstmouse%28for%3A%29)
describes click-through as allowing a user to “click on a view in an inactive window”.
The fixture opts into that behavior; no production first-mouse policy is changed.

[claude]: https://github.com/onetimesecret/macos/pull/343#issuecomment-6617637755
[greptile]: https://github.com/onetimesecret/macos/pull/343#discussion_r4461522073
[greptile-summary]: https://github.com/onetimesecret/macos/pull/343#issuecomment-6617746379
[copilot]: https://github.com/onetimesecret/macos/pull/343#discussion_r4461536610
[copilot-review]: https://github.com/onetimesecret/macos/pull/343#pullrequestreview-5760766947
[codex]: https://github.com/onetimesecret/macos/pull/343#issuecomment-6617636500
[ci]: https://github.com/onetimesecret/macos/actions/runs/41735375190
[claude-run]: https://github.com/onetimesecret/macos/actions/runs/41735374996
