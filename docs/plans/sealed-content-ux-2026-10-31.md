# Sealed-content UX revision

Status: implemented; automated verification and rendered-fixture review complete, 2026-10-31.

The user asked for a methodical response to the 28-item visual and source audit.
This file records implementation choices and verification; it is not an
independent security specification or evidence that these changes work.
The [dated interface record](../spec/design/2026-1031-sealed-content-ux-revision.md)
and the amended law rows state the presentation decisions. This checklist
does not replace them.

## Existing decisions and scope

The quotations below link to the unchanged source revision before this task.

The accepted [sealed-object law](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/law/0001-sealed-object.md), under **The rule**, says:

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

The accepted [design record](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/spec/design/2026-0915-ui-ux-decisions.md),
under **Sealing a selection after the fact**, says:

> ⌘Z after sealing is not offered; the content comes back only through *Copy decrypted contents*.

[ADR-0042](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/adr/0042-a-sealed-name-is-a-shell-identifier.md), **Decision**, says:

> A sealed name is 1 to 64 characters matching `[A-Za-z_][A-Za-z0-9_]*`,
> its case kept as typed.

[ADR-0047](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/adr/0047-name-value-copies-the-value-unquoted.md), **Decision**, specifies:

> no quotes, no escapes, no added space.

This revision retains those decisions. It changes the interface around them:
explicit copy controls, precise variable-name wording, visible consequences
before sealing, and a documented copy/edit/seal replacement route. It does not
add a reveal editor, a second name field, or a broader excerpt. The shortened
excerpt remains the core's existing head/tail representation; useful identity
comes from its prominence, the variable name and the note, rather than further
plaintext disclosure.

## The 28 dispositions

| # | Audit issue | Change or explicit disposition | Verification |
| --- | --- | --- | --- |
| 1 | Edited badge collides with block | Both compact and expanded metadata labels must fit beside the first line; otherwise the overlay is omitted. | Metadata geometry and block tests; rendered fixtures. |
| 2 | Short object becomes full-width slab | Natural compact width, bounded by the viewport; longer identity can use more room. | Live TextKit and width tests. |
| 3 | Classification outranks identity | Name and excerpt occupy the primary row; sentence-case classification is secondary. | Light/dark rendered fixtures. |
| 4 | Mechanical URL/token excerpt is a poor identifier | Excerpt gets the primary row and no hover-text reservation; full permitted face is available to accessibility/help. Naming guidance explains identification. Existing excerpt policy remains. | Identity fitting and accessibility tests. |
| 5 | Size and hidden hover reservation consume space | Size moves to object help/accessibility. No width is reserved for hover instructions. | Layout tests; rendered fixtures. |
| 6 | Competing selection treatments | Native selection with matching selected foreground replaces orange border/halo, including mixed selections and passive previews. | Selected fixtures in both appearances. |
| 7 | Lock lacks selected contrast treatment | Lock and secondary text use the selected foreground when selected. | Selected fixtures; physical-display check remains manual. |
| 8 | Fixed height clips large type | Height follows the selected font's line metrics across the supported 8–40pt range. | Font-range geometry tests and 40pt fixtures. |
| 9 | Naming changes a click into copying | Identity text selects the object whether named or unnamed. | Click and copy-counter tests. |
| 10 | Same click depends on hover history | Copy has its own visible control and does not use cached hover state. | First-press and cursor tests. |
| 11 | Rename double-click copies first | Text has no copy action or rename gesture; explicit Set/Edit Variable Name opens the field. | Selection tests; name menu tests. |
| 12 | Tiny equals copy target | Removed text copy zones and their pills. Assignment copy is a named menu action. | Interaction tests and source review. |
| 13 | Decrypted drag looks clickable but selects | Copy decrypted clicks to copy, drags outward to copy to another app, and explains both in help. | Actual mouse press and drag-source tests. |
| 14 | Narrow width silently loses all controls | More stays visible; its menu includes every applicable action. Copy and Move yield space independently. Structural face dragging also remains available. | Narrow geometry and menu tests. |
| 15 | Invisible More target | More is always drawn at the same rectangle used for hit-testing. | Geometry, AX and menu presenter tests. |
| 16 | Several indistinguishable copy meanings | Copy decrypted is explicit; menu names Sealed Reference, Variable Name and NAME=Value (Unquoted) separately. Reference copy help explains its use. | Menu and clipboard-route tests. |
| 17 | Metadata seat changes meanings and hides note | Stable Note doorway; feedback appears on Copy decrypted as Copied. | Note/control geometry and copy tests. |
| 18 | Generic Name actually means shell identifier | Set/Edit Variable Name, API_KEY example, format guidance and local errors. Existing identifier rule remains. | Naming validation and local-error tests. |
| 19 | Raw assignment resembles shell formatting help | Copy NAME=Value (Unquoted), with help stating there are no quotes or escapes. Existing raw format remains. | Menu and core copy-route tests. |
| 20 | Naming loses valid draft on blur | Valid blur, pad switches and editor handoffs save. Save/Cancel and Return/Esc are visible. Invalid blur drafts stay open; explicit teardown closes them. | Focus-loss, commit and cancel tests. |
| 21 | Name refusal appears far away | Error stays beside the field and is exposed through accessibility help. | Local-error tests. |
| 22 | No direct contents editor and unclear commitment | One-way sealing remains explicit: visible pre-seal explanation, menu/help, and copy/edit/seal replacement instructions. No silent unseal or new contents editor. | Selection-menu and clipboard-offer tests; existing seal tests. |
| 23 | Incomplete accessibility identity/actions | Summary includes the permitted excerpt and note presence. Copy/More/Note expose actionable buttons with distinct guidance and identity context. Native selection and Cut/Paste provide keyboard movement; the pointer Move handle adds no redundant AX button. | AX labels/help, frames, stable elements, actual press and narrow Cut/Paste tests. VoiceOver hand check remains. |
| 24 | Sharing loses source identity | Confirmation snapshots and shows the selected object name/excerpt or page title. | Sharing identity tests. |
| 25 | Stale clipboard success and no recovery | Past-tense success wording plus Copy Link Again. A core-only recovery buffer uses a unique token and a fixed initial recovery deadline; the shell receives availability, never the URL text. | FFI and Swift recovery, expiry, supersession and repeated-receipt tests. |
| 26 | Remove and burn wording is inconsistent | Remove from Document is distinct from Delete Local Sealed Content / Discard Local Page. Done replaces Keep It; help describes the actual action. | Menu/removal and sharing tests. |
| 27 | Open menu targets stale character position | Every menu action captures object identity, resolves its current position at execution, and refuses a missing target. Copy presses also re-resolve after tracking. | Edit-while-menu-open and removed-target tests. |
| 28 | Independent custom systems disagree | Shared control geometry drives drawing, hit-testing, cursor regions and AX. Passive previews and drag images omit editor controls. Removed zone, hover-copy and pill machinery; naming/note editors use the same object rectangles. | Focused regression suite, source review and rendered fixtures. |

## Link recovery implementation

The FFI's implementation keeps one `Zeroizing<Vec<u8>>` recovery buffer
for the latest completed link, identified by a core-generated token rather than
a server receipt. Its 60-second access deadline starts at completion and is not
extended by a re-copy. The shell schedules a removal request from the core's
remaining duration and forgets the matching token when its draft closes. The
buffer is dropped on an expiry query, explicit forget/draft dismissal,
supersession or handle drop; reaching the access deadline alone does not eagerly
wipe it. A newer completion replaces
the prior buffer; old requests cannot copy or forget the newer token. A re-copy
uses the existing pasteboard writer and creates no additional network request.
These are implementation observations to verify, not independent guarantees.

## Verification record

- `scripts/test-shell.sh`: 393 app tests and 2,339 CompanionKit tests executed,
  7 existing skips, 0 failures. The full run set `ONETIMEPAD_SEALED_PREVIEW_DIR=/tmp/sealed-ux-preview` and included the optional rendering tests.
- `cargo test -p companion-ffi -- --test-threads=1 --skip drop_to_seal_reads_the_drag_board_core_side`:
  403 passed, 1 existing ignored test, 1 excluded shared-system-drag-pasteboard test.
- `cargo clippy -p companion-ffi --all-targets --features test-util -- -D warnings`:
  passed.
- `cargo fmt --check`, `git diff --check`, and `scripts/lint-adrs.py docs/adr`:
  passed.
- Inspected 32 synthetic rendered fixtures covering light/dark appearance,
  selected/resting objects, 13/40pt text, narrow/wide layouts, Note, local naming
  validation and sharing form/success states. The renders exposed a clipped
  keyboard hint and expiry help; both were corrected and rendered again.
- Independent source review found stale targeting during presses and auxiliary
  editor changes, plus inconsistent read-only control eligibility. Those paths
  were corrected; integration tests exercise shifted/removed targets, read-only
  refusal, and live remeasurement in standalone/continuous projections. A fresh
  final review also found passive previews drawing inert controls and valid name
  drafts cancelled during pad/ownership transitions; both have regression coverage.
- The shifted-target tracking tests inject synthetic release events instead of
  depending on the system event queue. Separate mouse-click/drag tests dispatch `NSEvent` objects through the text
  view and check the resulting selection, copy and drag routes.

Manual VoiceOver navigation/rotor and physical-display inspection remain
unperformed. The accepted excerpt algorithm, ASCII variable-name rule, raw
assignment copy and one-way sealing are explicit retained decisions, rather than
new contents-editing or general-purpose labeling features.

Automated fixtures use temporary state and an in-memory credential client.
Rendered examples contain synthetic values. No running personal app is launched,
quit, reset or replaced for these checks.

## Documentation review dispositions

This ledger records the documentation review only; it does not establish
security properties or replace the operative records.

| ID | Material issue | Disposition and final location | Verification |
| --- | --- | --- | --- |
| DOC-01 | Law 0001 described text copy zones and old menu/handle behavior. | Addressed in its operative contract and presentation rows, with a dated 2026-10-31 amendment. | Current named test references checked against the source tree; local links checked. |
| DOC-02 | Law 0007 contradicted sealed-field blur, refusal and teardown behavior. | Addressed in its operation classes and sealed-field rows; stale held-refusal source references removed. Older amendments remain history. | Current named test references checked against the source tree; local links checked. |
| DOC-03 | A dated record was edited in place instead of superseded whole. | Addressed by the [dated successor](../spec/design/2026-1031-sealed-content-ux-revision.md), with immutable incorporation and scoped revisions. Earlier dated bodies remain unchanged. | Prior bodies compared with commit `367a65c6f4d051ffdc87ac8ebb43f154e9b97783`; status/successor fields checked. |
| DOC-04 | The implementation plan was presented as authority and historical sharing copy remained ambiguous. | Addressed by direct successor links, operative law amendments and superseded status on the former records. Linked manual checks now exercise explicit controls. | Local link and scope review; manual checks remain unperformed. |
| COPY-01 | Revised native labels and instructional guidance conflicted with D-15/ADR-0055. | Addressed by the successor's scoped copy-register decision and ADR-0055 amendment. | Labels compared with the revised source; ADR structural lint checked. |
| DOC-05 | Successor metadata replaced the earlier scoped and intermediate relationships. | Addressed by structured superseded-by entries preserving ADR-0060 and the stream-to-clear-interval chain alongside the new successor; the successor explains whole-record status and immutable incorporation. ADR-0055 retains its accepted body with a dated history pointer. | YAML metadata, referenced paths, unchanged historical bodies and documentation conventions checked. |

## Code-review followups

The PR review also prompted these changes:

- Localized variable-name guidance, sealed actions/status and sharing recovery.
- Made the accessibility selection action say Select Sealed Content.
- Separated the recovery access interval and its test seam from clipboard clearing;
  corrected the buffer-retention description in F16.
- Returned refused-name actions to the field and used neutral save-failure wording.
- Removed inert controls from read-only editors, refreshed cursor/AX/drawing state
  when editability changes, and returned typing focus after a saved owned draft.
- Reused unused row measure, removed the dead height metric, named identity/status
  rows directly, and cached measurements until the face or typeface changes.
- Restored live-core size-class and TextKit proposal tests; optional render tests
  explicitly skip when their output environment is absent. Gesture tests inject
  their event sequence into the actual mouse handler for deterministic CI behavior.

The visibility predicate remains an explicit shared guard for the current editor
state. The note/name helper uses the existing page-overlay approach; the dated
successor records that presentation choice. Actual VoiceOver and physical-pointer
checks remain unperformed.


## Final external-review dispositions

| ID | Finding | Disposition and verification |
| --- | --- | --- |
| REV-01 | Native `Instant` pauses during macOS sleep. | Recovery creation and public copy/availability queries now use the existing page-store clock. Public-entry tests set a controlled deadline and exercise refusal, remaining time and re-copy without extending it. Physical system sleep was not simulated. |
| REV-02 | A model could close without forgetting its recovery token. | Teardown forgets the mirrored token while the client may remain alive. Asynchronous creation explicitly retains its model through outcome handling, then teardown requests guarded clipboard clearing and forgets the recovery token. Both lifecycle paths have regression tests. |
| REV-03 | Re-copy did not have a second-clear assertion. | The Swift regression compares the synthetic URL on the in-memory pasteboard, waits for its initial clear, re-copies it, and checks the second clear. Its test-only getter refuses a system pasteboard. |
| REV-04 | Redundant Move accessibility button. | Removed the selection-only child. Native selection and Cut/Paste remain available at narrow widths; the new editor regression checks movement and object identity. |
| REV-05 | Child accessibility help repeated the object summary. | Copy/More/Note combine their own localized action guidance with object identity. A regression checks distinct help and the shared context. |
| REV-06 | Pre-seal wording bypassed localization and drifted between surfaces. | The visible explanation and tooltip share the CompanionKit resource string. Clipboard offer text and accessibility label also use its bundle. Recovery timing is visible below the buttons, including after disablement. `%u` remains paired with its `UInt32` argument. |
| REV-07 | Unused helper APIs and duplicate tracking state. | Removed the uncalled notice-hold API and its obsolete tests, the naming wrapper, hardcoded AX labels, unused status coordinate and no-op rectangle lookup. The resolved handle is passed into press tracking. Notice lifecycle coverage checks clearing and action replacement. |
| REV-08 | Prior successor metadata was overwritten. | Restored the earlier edges as structured entries. Whole-record status follows the dated-record rule; unchanged decisions remain incorporated by immutable reference. The accepted ADR body is preserved, with the scoped revision in dated history. |
| REV-09 | Helper buttons could escape very narrow bounds. | The helper wraps text and stacks buttons to fit its available width, including longer translated titles. Bounds tests cover very narrow widths. The live block uses `preferredHeight(identityLineHeight:)`; 52 points is its minimum and the geometry helper's fallback, not the live font-derived height. |


## Review of revision 128d16d3

The automated review supplied leads for another source and visual pass; it is
not authority for product decisions or security properties. The dispositions
below distinguish adopted fixes from retained behavior and refuted findings.
The final 74-test focused UI run and full Swift suite recorded above passed
these fixes and the menu-header improvement. The 32 synthetic renders were
regenerated and inspected; manual VoiceOver and physical-display checks remain
unperformed.

| ID | Review topic | Disposition and evidence | Verification scope |
| --- | --- | --- | --- |
| R128-01 | Long translated control labels can overrun their bounds. | Addressed: fit labels within their allocated controls, preserving complete action guidance. | `SealedBlockTests.testControlTitlesFitTheirBoundsWithLongTranslatedCopyFeedbackAndNotes` and `testLongControlTitlesDoNotPaintOutsideTheirButtons` passed, including raster bounds checks. |
| R128-02 | An invalid blur can leave the name field without the keyboard. | Addressed: keep the invalid draft and local error, and restore field focus. | `SealedNameFieldTests.testInvalidBlurDefersRefocusAndKeepsTheDraftEditable`, `testCancelInvalidatesPendingInvalidDraftRefocus`, `testWindowTeardownInvalidatesPendingInvalidDraftRefocus` and `testWindowTeardownSavesAValidPendingDraft` passed; naming renders regenerated and inspected. |
| R128-03 | Note, More and control boundaries need clearer action treatments. | Addressed: clarify the visible targets and their border contrast. | `ThemeContrastTests.testRestingSealedControlTextAndBordersContrastWithTheirActualSurfaces` and `testSelectedSealedControlsKeepTextAndBorderContrastOnTheirFill` passed. Refreshed light/dark and narrow/wide renders inspected; physical-display check remains manual. |
| R128-04 | Destructive sharing action competes with Copy/Done. | Addressed: place deletion/discard in its own row below a divider. | `ConcealRecoveryTests.testRenderSharingPreviewsWhenRequested` passed; refreshed light/dark, narrow/wide sharing renders inspected. |
| R128-05 | Discarded pages remain readable to link recovery. | Refuted by source: [discard_page](../../crates/core/src/store.rs) removes the page with `tab.page.take()` and entombs it; only the slot survives. [cached_link](../../crates/ffi/src/lib.rs) requires that source page in `readable_sheets()`. UI dismissal also explicitly forgets its token. | Owning source inspected; no page-content-equality invariant added. This is source evidence, not a new security guarantee. |
| R128-06 | Restore a separate Move accessibility child. | Not adopted: the redundant selection-only child was deliberately removed. Native text selection and Cut/Paste are the intended keyboard/VoiceOver movement route. | `testNarrowObjectsMoveThroughNativeCutAndPasteActions` checks keyboard movement and identity. Actual VoiceOver navigation remains unperformed. |
| R128-07 | A 52-point floor and fixed action type imply broken font scaling. | Clarified: 52 points is the minimum/fallback; live height follows identity line metrics. Fixed 12-point system action chrome is distinct from the user's writing font. | Existing font-range geometry covers the live identity row; the successor records this intent. |
| R128-08 | Recovery deadline implies an eager physical wipe. | Not adopted: the access deadline and lazy buffer removal are already distinguished in the recovery implementation section. | No new retention or erasure guarantee. |
| R128-09 | Replace strong creation-task ownership with a weak capture. | Not adopted: `confirmConceal` deliberately retains its model through outcome handling and cleanup. | `testInFlightCreationFinishesCleanupBeforeReleasingItsModel` covers the lifetime path; no weak capture reintroduced. |
| R128-10 | Validate a variable name on every edit before any refusal. | Not adopted: errors update after the first refused save/blur attempt. This is the Refusing context, rather than premature feedback while initially typing. | `ChipRename.edit` and the existing local-refusal regression inspected; successor wording clarified. |
| R128-11 | Remove the visible pre-seal explanatory line. | Visible consequence retained and presentation improved: native noninteractive section header before Seal Selection on macOS 14+, disabled informational fallback on macOS 13. A tooltip alone is insufficient. | `DocumentOpsWiringTests.testTheContextMenuOffersSealSelectionOverInkOnly` passed in the full suite. macOS 13 fallback inspected in source; actual VoiceOver announcement remains a manual check. |
| R128-12 | Smaller unused-parameter and performance suggestions. | Deferred as optional cleanup where no correctness defect was established. | Nonmaterial to this UI correction; no additional behavior change recorded. |
| R128-13 | Remove Unicode provenance marks. | Rejected: a review suggestion is not user authorization to remove attribution. Existing marks remain. | Supported TextProv document editing preserves the exact original marks while marking changed prose. |


## Requested Claude and Greptile review rounds

Round one reviewed `6fb40ab6`. Reviewer assessments are opinions rather than
product authority. Each topic below was checked against the owning source.

| ID | Review topic | Disposition |
| --- | --- | --- |
| ROUND1-01 | Greptile: helper covers the draft in short windows. | Constrain the helper outside the block; scroll its contents. Test draft click access and reachable Save/Cancel. |
| ROUND1-02 | Claude 1: missing narrow-block note indication. | Preserve visible note presence when the Note control or status text cannot fit. |
| ROUND1-03 | Claude 2: fixed localized Copy width. | Measure Copy and feedback titles for shared action geometry. |
| ROUND1-04 | Claude 3: fixed action font. | Retain system-font action chrome separate from writing metrics; see R128-07. |
| ROUND1-05 | Claude 4: tests use fallback height. | Use live preferred height in the cited fixture frames. |
| ROUND1-06 | Claude 5: weaken request ownership. | Retain explicit ownership through outcome and cleanup; see REV-02/R128-09. Forgetting an orphan token alone omits clipboard-cleanup ownership. |
| ROUND1-07 | Claude 6: label lookup scans pages; label is snapshotted. | Defer optional lookup optimization. Snapshot identifies source at form opening; no new correctness defect established. |
| ROUND1-08 | Claude 7: untranslated reference feedback. | Use the CompanionKit string bundle. |
| ROUND1-09 | Claude 8: clipboard clear should end recovery. | Retain independent policies. Regression exercises re-copy after clipboard clearing within the initial recovery interval. F16 distinguishes access expiry from later cleanup. |
| ROUND1-10 | Claude 9: token may imply secret authorization. | Counter distinguishes successive results within a handle; it is not an authorization secret. No random-capability property is asserted. |
| ROUND1-11 | Claude 10: add pasteboard-flag commentary. | Retain initial completion's pasteboard options; no added comment needed. |
| ROUND1-12 | Claude 11: tracking outlives its interaction context. | Cancel on context changes without an arbitrary long-press timeout. |
| ROUND1-13 | Claude 12: TextKit sizing assumes main actor. | Retain current main-thread layout. Background-layout support needs a separate actor/measurement audit. |
| ROUND1-14 | Claude 13: More lacks hit slop. | Share expanded geometry bounded by the block and disjoint from adjacent actions. |
| ROUND1-15 | Claude 14: single-object menu collapses mixed selection. | Retain single-object action target; native selection-wide commands remain separate. |
| ROUND1-16 | Claude: dead geometry and duplicate padding. | Remove unused metadata helpers/face enum and share horizontal padding. Retain test-used row geometry; defer policy/radius renaming. |
| ROUND1-17 | Claude: invalid-name focus, historical names and menu case. | Retain already recorded scoped decisions and historical entries; no new defect established. |
| ROUND1-18 | Claude: strip provenance marks. | Preserve existing attribution; automated feedback does not authorize its removal. See R128-13. |


Round-one verification: the full isolated Swift suite passed 393 app tests and
2,346 CompanionKit tests, with seven existing skips and no failures. The seven
new regressions cover short-window helper placement, visible narrow-note status,
localized Copy sizing, More hit geometry, note-popover anchoring, detached-editor
press cancellation and read-only press cancellation. Synthetic previews were
regenerated; the narrow naming-error render was inspected. ADR lint, English
string syntax and diff checks passed. Rust sources did not change in this round.


Round two reviewed `99accb26`. Greptile found no concrete remaining defects
and rated confidence 5/5. Claude verified the first-round fixes and supplied
the following new topics. These assessments are review evidence, not authority.

| ID | Claude round-two topic | Disposition |
| --- | --- | --- |
| ROUND2-01 | Source index still describes two VoiceOver handles. | Correct the current source index to Copy/More/Note actions and native selection/Cut/Paste movement; preserve historical amendment entries. |
| ROUND2-02 | Unknown content kinds are described as text. | Use the existing neutral classification fallback for an unknown kind. |
| ROUND2-03 | Severely constrained helper hides its error/actions. | Add a compact error-first fallback and test tighter viewports than the first-round case. |
| ROUND2-04 | Unused name-floor constant. | Use the named constant in measurement. |
| ROUND2-05 | More geometry constants and optional dead geometry cleanup. | Defer broader cosmetic restructuring. The current floor/test helper remains explicit; no new user-visible defect established. |
| ROUND2-06 | Note and Copy measure through different helpers. | Measure both with the same control font and padding policy. |
| ROUND2-07 | Note placement and status truncation use different widths. | The existing nonintersection guard avoids collision. Preserve the full-status basis; no new defect established. |
| ROUND2-08 | Note-specific indicator clearance. | Clearance reserves the note indicator when its text/control cannot fit; ordinary status remains optional under width constraints. |
| ROUND2-09 | Activation itself cancels a press. | Permit promotion to active/key context, then cancel any subsequent loss. Test these state transitions without activating a person's app. |
| ROUND2-10 | Decoded outcome token is mutable. | Make the decoded token immutable while retaining convenience initialization with an absent token. |
| ROUND2-11 | Recovery caption repeatedly queries a constant. | Cache the localized interval text. |
| ROUND2-12 | Recovery caption remains after disablement. | Hide interval guidance after recovery becomes unavailable and update disabled-button help. |
| ROUND2-13 | Action preparation closes a note before checking chord ownership. | Retain intentional focus handoff: the page becomes the responder before checking its chord route. No independent premature-refusal defect established. |
| ROUND2-14 | Selected-state contrast lacks increased-contrast coverage. | Add those appearances to the selected-state contrast check. |
| ROUND2-15 | Strip existing attribution marks. | Not adopted; see R128-13 and ROUND1-18. |


Round-two verification: the full isolated Swift suite passed 393 app tests and
2,352 CompanionKit tests, with seven existing skips and no failures. The six
new tests exercise activation promotion/loss, neutral unknown-kind status,
shared Note measurement, compact error/action visibility, and extreme-height
bounds/Escape. Selected controls also pass both increased-contrast appearances.
Synthetic previews were regenerated. Rust sources did not change in either
requested review round. Actual VoiceOver and physical-display checks remain
unperformed.
