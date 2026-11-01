# PR #337 review dispositions

This ledger records the first Claude review on `330328ad` and the follow-up
implementation. Review text is input for investigation; test results and source
inspection below determine each disposition. No review reply was posted.

| Item | Disposition |
| --- | --- |
| TextProv marks and routing anchor | Intentional attribution retained. Added an explicit HTML anchor for the routing-policy link; no document-wide attribution or CI-policy removal. |
| Mutable public network fixture | Pinned source commit, exact byte hash, MIME, dimensions and raster comparison. Default platform TLS remains exercised through the real proxy tunnel. A trusted private fixture remains unavailable. |
| Port publication, timeout and termination diagnostics | Atomic port/report publication; bounded socket/process waits; timeout and SIGTERM report checks pass. |
| Deferred threshold literal | Named `deferredRenderingThreshold`; large-fixture sizing derives from it. |
| Loading typography and completion notification | Loading text uses the preview font/color; completion posts a native accessibility value-change notification. Spoken result still needs a human check. |
| Duplicate render finalization/refusal logic | Shared `finishRendering` and `refused` helpers centralize object-count validation and fallback; sync/async block scheduling stays separate. |
| Concurrent Rust bridge coverage | Existing `testParsesOnManyThreadsEqualTheSameParsesInTurn` runs 400 concurrent FFI parses and compares serial results. It passes with the vendored parser. |
| Unconditional timing reads | Clock reads are gated on the optional timing callback. |
| Visibility and native key loop | Hide/show transitions refresh the loop even when frames are unchanged; restored-control and visibility metadata regressions pass. |
| Duplicated compact labels/width work | Typed action mapping shares semantic/compact labels; width cache keys use the actual font and current localized values. |
| Presentation-width duplication | Attachment slots use the calculated `presentationWidth`. Queued resize presentation remains intentional; no extra synchronous layout on every resize. |
| Pixel/point coupling | Image fitting reads bitmap/CGImage pixel dimensions. A 240×120 raster with 120×60 logical size is covered at both backing scales. |
| Blank lines and localization-key preference | Removed extra spacing in edited tests. English fallback keys remain consistent with other existing literal keys; identifier migration was not needed for behavior. |
| Visible consent sentence | Existing tooltip/accessibility-help policy retained. A new first-click dialog is not included. |
| Unchanged rendering identity | Stable model identity is the fast path. Equivalent pending work now uses exact UTF-16 text and complete attachment metadata; generation checks reject superseded output. |
| CI Tab traversal failure | The runner does not enable button keyboard navigation. Native Tab tests now explicitly skip under that preference; local enabled-preference traversal and unconditional metadata checks pass. No global preference is changed. |

The user selected vendoring after the first review. Cargo now uses the patched
0.57.0 runtime crate, all five source-position goals are active, and the old
stock-bug expectation tests are removed. Provenance, patches, source verification,
and the registry-version advisory projection are recorded separately in the
[vendor guide](../../crates/markdown/patches/README.md).

Latest executable evidence is in the [validation record](markdown-followup-validation.md).
PR readiness still requires final-head CI/review and the spoken walkthrough.

## Updated Claude review and expanded checks

The updated comment is [6494393411](https://github.com/onetimesecret/macos/pull/337#issuecomment-6494393411),
reviewing `da171964`. Fixes and expanded checks are committed in `2869caca`.

| ID | Concern and disposition |
| --- | --- |
| R2-01 | Stale PR body: the live body already described vendoring and active goals when fetched again. Final test counts are refreshed with this pass. |
| R2-02 | Possible `offsets.drain` panic: not reproduced; range remains unchanged. Inspection found `add_line` appends input and its offset together. Direct AST regressions and 42,520 bounded dialect cases pass. This is not exhaustive or a panic-free result; coverage-guided fuzzing remains absent (`cargo-fuzz`/nightly were unavailable). A clamp was not added to continue with inconsistent position metadata. |
| R2-03 | Identical pending source restarted: fixed with task reuse and a pending-generation token. Exact UTF-16 equality preserves literal Unicode edits. Actual source/dialect changes retain the loading/read gate; prior rendered content is not newly offered for copy. |
| R2-04 | Current cancellation could leave busy state: completion now clears its own generation/task/state and installs current-source plain fallback. A cancelled predecessor cannot clear a newer request. Regression awaits actual tasks. |
| R2-05 | Window-wide key-loop cost: measured about 3.01 ms per resize in the eight-preview/32-control probe, including native AppKit calls. Coalescing remains a performance follow-up; immediate native traversal behavior remains tested. |
| R2-06 | Retina size: 1x/2x calculations, 2x bitmap specimens and actual font Settings paths pass. The 340-point width and 400-point height caps remain logical-point choices. Human physical-display judgment is pending. |
| R2-07 | Double configure/AX notification: source inspection found the posted semantic label derives from the full action/destination, independently of compact visible title. Its setter/post runs only on semantic-label change. The immediate pass also enables newly mounted controls; removing it previously broke immediate activation. No duplicate spoken-notification result is inferred. |
| R2-08 | Whole-table fallback: image-polish documentation now explicitly describes stacked text-only cells and absence of native column/table-block semantics until widening. |
| R2-09 | Unrecorded archive omissions: all 102 exclusions are inventoried and checked; missing/extra/duplicate/retained exclusions have mutation tests. Oversized download has a distinct error. Root virtual-workspace formatting passes; an explicit package list remains an optional maintenance change. |
| R2-10 | Actor FIFO assumption: removed the parser-call barrier and await the actual superseded task. Native traversal still runs locally with keyboard navigation enabled; runner preference skips are explicit. Tooltip-only routing disclosure and mixed localization-key style remain documented. Intentional TextProv attribution is retained. |
| V-01 | Reproduced sealed-alt resize image loss: fixed by comparing complete attachment metadata and literal source rather than attachment instance identity. Two mounted regressions pass, including changed metadata. |
| V-02 | Alternate numeric IPv4 spellings passed hostname validation: fixed with the platform numeric IPv4 parser. Eight forms, including mixed-base/encoded cases, are rejected before transport. This does not classify DNS answers or connected peers. |
| V-03 | Linux advisory command: the first correction passed local cargo-deny 0.19.9 but failed CI 0.20.2, where `--config` moved to the global options. The pinned Action now receives `--locked --config deny.toml` before `check advisories`. The official 0.20.2 binary and exact Action entrypoint pass locally; final-head CI is separate. |

The human spoken walkthrough and trusted-private-origin network case remain
unverified. Final-head CI and bot review are separate from local execution.

## Review of `31a55012` and final reuse correction

[Claude job 40924079812](https://github.com/onetimesecret/macos/actions/runs/40924079812)
reported no blocking defect. It independently traced the line/offset append
invariant behind R2-02; no vendor clamp/comment change was made. Its output
is review input rather than independent execution evidence.

| ID | Disposition |
| --- | --- |
| R3-01 | Completed no-image page loading flash: fixed in `61ccb43a` by reusing all equivalent completed sources. Typeface snapshot is part of identity; font-size/code-family regressions and output/selection retention pass. |
| R3-02 | Batch timing interpretation: performance record now states that reseed timing covers four views and that completion includes the shared parser queue. Time-based yielding between blocks would not bound a single expensive block. |
| R3-03 | Process-only keyboard-navigation override: tested argument-domain values 0 and 3; both reported AppKit keyboard navigation enabled on the enabled host. No CI force-setting was adopted; the conditional traversal gap remains explicit. |
| R3-04 | Rejected title visibility: vendor guide now explicitly notes comrak link-title/HTML output changes, in addition to source positions. |
| R3-05 | Remaining suggestions: explicit formatter package selection for future root-package changes, additional invariant comments, archive fetch caching/pruning and cosmetic bindings remain optional maintenance items. Current root virtual-workspace formatting and archive checks pass. |

Final application execution is at `61ccb43a`: 2,631 Swift passes/five skips,
30 sanitizer passes, and 866 isolated UI checks. The prior CI head `efcd15fe`
passed all six build/test jobs. Final-head CI/bot review remains separate.

## Review of `efcd15fe`

[Claude job 40925190316](https://github.com/onetimesecret/macos/actions/runs/40925190316)
reported no merge-blocking defect. The sticky comment was overwritten by a
newer run; the completed review body was retrieved from that job's tool log.

| ID | Disposition |
| --- | --- |
| R4-01 | Bridged per-unit source comparison: benchmarked and replaced with Foundation literal string equality in `82c8574f`. Optimized one-million-unit sample improves from 3.94 to 0.026 ms; literal Unicode regressions pass. Dictionary allocation optimization remains unmeasured and unchanged. |
| R4-02 | Mounted test callback replacement: the regression now awaits the real render task and checks resulting view/stack heights, without wrapping the stack-owned callback. |
| R4-03 | First advisory scan could update lock: add `--all-features --locked`; exact pinned cargo-deny 0.20.2 root check passes. |
| R4-04 | Upstream tests omitted from runtime subset: run the patched full archive separately; all 556 default-features-off library tests pass. Normal workspace still uses its corpus and four direct AST regressions. Optional features/doctests remain outside that run. |
| R4-05 | Yield cadence and copy feedback: current between-block scheduling, interim read gate and silent pending copy remain; a single block can exceed a frame. A new scheduler/busy announcement is not added by this validation pass. |
| R4-06 | Archive caching/size-derived cap, formatting documentation, localization identifiers and cosmetic cleanups remain maintenance suggestions. Current exact archive/partition, strings and root-format checks pass. |

The final source, by `afbee4ac`, passes 2,631 Swift tests (five opt-in skips),
30 sanitizer cases and 866 UI checks. Previous head `90e6385a` passed all six
CI build/test jobs; final-head CI/review is separate. No review replies were posted.

## Review of `011544ab`

The completed [Claude run 40929986600](https://github.com/onetimesecret/macos/actions/runs/40929986600)
reported no blocking defects. Its full body was recovered from the job log
because a subsequent review replaced the sticky comment.

| ID | Disposition |
| --- | --- |
| R5-01 | Unsafe formatting recipes: updated the companion agent recipe and content-buffer guide to omit `--all`, preserving the pinned vendor files. The guide identifies the formatting command as updated rather than an exact historical command. |
| R5-02 | Registry projection checked only advisories: run all cargo-deny categories. Add the workspace MIT license metadata to the generated unpublished probe; the full scan initially failed because the probe lacked that metadata. Upstream comrak itself passed. A regression checks the generated metadata. |
| R5-03 | Suggested source-position drain clamp: unchanged. No input that violates the paired content/offset invariant has been reproduced. An arbitrary clamp could continue parsing with inconsistent metadata. The bounded stress and upstream test results are not exhaustive proofs. |
| R5-04 | Finished deferred result discarded after cancellation: remove the extra task-cancellation ternary. The renderer returns nil for cancelled work; the generation guard still rejects superseded requests. |
| R5-05 | Unreachable consent-reuse branch: remove the `preserveConsent` parameter and dead image-descriptor comparison. Equivalent sources retain the existing preview through `reseed`; a changed source rebuilds controls. Destination/range regressions now exercise mounted model updates. |
| R5-06 | Network-fixture log creation ignored failure: use throwing `Data.write(to:)` before opening the log handle. |
| R5-07 | Intentional TextProv attribution: retained; the suggested document-wide removal and rejection test are not applied. |
| R5-08 | Cooperative actor execution, single-block latency and window-wide key-loop cost remain performance follow-ups. Existing measurements do not establish a frame-time bound. Archive caching, lockfile parsing and future publication of the parser crate remain maintenance suggestions. |
| R5-09 | Stale draft wording: distinguish the previous draft checkpoint from the live ready-for-review state. Human spoken VoiceOver/rotor, physical-display judgment and a trusted private-origin fixture remain unverified. |

Validation for these fixes: 50 focused Swift tests passed, with three network
cases skipped by default; all three opt-in network cases passed separately.
All 158 Python script tests passed on an approved rerun after sandbox failures
accessing Xcode caches, Icon Studio services and the signing agent. The 16
vendor-verifier tests, pinned cargo-deny 0.20.2 full registry policy scan,
workspace formatting, local vendor inventory and all 53 ADR checks pass.
The first range-test revision compared loaded presentation slots rather than
semantic output; it was corrected before the successful focused rerun.

Greptile's first automatic review at `011544ab` reported no findings and a
5/5 confidence score. Codex's automatic review also reported no findings.
Claude's ready-for-review run 41168669799 is separate from the completed
review above. No review-trigger comment was published by this agent.

## Ready-for-review follow-up at `011544ab`

[Claude run 41168669799](https://github.com/onetimesecret/macos/actions/runs/41168669799)
identified an additional cancelled-render recovery issue. It reviewed the old
head while the first fixes were being prepared; overlapping runs are tracked
by their commit rather than the overwritten sticky comment.

| ID | Disposition |
| --- | --- |
| R6-01 | Cancelled current work could remain plain text on later identical/equivalent reseeds. A new regression reproduced the missing retry before the fix. Clear cached style markers on a nil result after the generation check, while retaining the source for the layout callback. Both wrapper cases now retry, restore styled output and reuse successful completion. |
| R6-02 | Dead `preserveConsent` path: already removed in `891b168c`. |
| R6-03 | Small-image size changes across backing scales: retained the existing pixel-per-point behavior. Tests already at `011544ab` expect 240×120 pixels to fit at 240×120 points on 1x and 120×60 on 2x. This is observed behavior, not an accepted requirement for stable logical sizing. Physical-display judgment remains unverified. |
| R6-04 | License reproduction: the default verifier now rejects absent or changed COPYING bytes in THIRD_PARTY_NOTICES.md. Mutation tests cover a missing file/block and altered license text. Attribution marks in surrounding prose remain intentional; the license block bytes remain exact. |
| R6-05 | TLS fixture reset: catch ConnectionResetError only around the handshake, alongside SSL errors. Later HTTP reads, timeouts and other OS errors still fail. A temporary controlled probe sent ClientHello, received the server handshake and reset the socket; it recorded rejection with no HTTP. An earlier probe reset before the TLS exchange and failed with EINVAL, so it did not validate this case. |
| R6-06 | IDN refusal wording: mention internationalized hostnames explicitly; address acceptance is unchanged. |
| R6-07 | Drain clamp, attribution removal and performance/maintenance suggestions retain the earlier dispositions. Registry preparation may need network access, as the vendor guide notes. |

Validation: 69 focused Swift tests pass (10 deferred, 41 image controls and
18 loader), plus all three opted-in network tests. All 18 vendor-verifier
tests and the default inventory/license check pass. This round does not
repeat the full Swift/Rust suites or certify the human checks.

## Final hardening after review of `0f8d377d`

[Automatic Claude review 41169557889](https://github.com/onetimesecret/macos/actions/runs/41169557889)
reported no blocking defects. [Requested review 41169573205](https://github.com/onetimesecret/macos/actions/runs/41169573205)
found no correctness regression in the fixes. Greptile completed three rounds,
with 5/5 and no actionable findings on `0f8d377d`; all six CI jobs passed on
that head. The following small batch addresses the remaining verifier and
fixture items; final pushed-head checks remain separate.

| ID | Disposition |
| --- | --- |
| R7-01 | Notice metadata: validate one comrak section's version, Package URL, SHA-256 and published license expression against the pinned source/version. Mutation tests include otherwise-correct values outside the section, which cannot mask drift. Attribution selectors are ignored only for metadata matching; the independent COPYING comparison remains byte-exact. |
| R7-02 | Notice line endings: set THIRD_PARTY_NOTICES.md to text eol=lf. Git reports that setting with core.autocrlf=true. |
| R7-03 | TLS handshake aborts: catch SSL errors and ConnectionError, including resets, broken pipes and aborted connections. Do not classify every OSError as rejection: new tests retain failures for timeouts and generic OS errors. The real controlled handshake-reset probe still passes. |
| R7-04 | Intentional attribution marks: retained. The notice's embedded license bytes are separately checked. No document-wide stripping/rejection rule was added. |
| R7-05 | Cancellation recovery is hardening: current production cancellation sites supersede or destroy the view; a direct current-task cancellation is exercised by the regression. No newly reproduced user-visible production cancellation path is inferred. The suggestion to leave a cancelled preview busy was not adopted. |
| R7-06 | Typeface changes currently reset loaded images. Retaining decoded pixels across a style-only reseed is a UX follow-up; source/style invalidation remains explicit. Named recovery state, transient compact labels, conditional AX notifications, key-loop coalescing and single-block yielding remain follow-ups rather than additional state-machine changes here. |
| R7-07 | Normalize the test's try-await spelling. Existing probe MIT metadata matches the workspace; broad private-package license exemptions and vendor default-feature changes are not added. Default-feature acceptance remains checked by the dependency verifier. |

All 167 Python script tests pass for this batch, including 23 vendor-verifier
tests and two handshake-report tests covering six error types. The default
verification and diff check pass. The final local Swift application validation
remains 69 focused passes plus three real-network passes from the preceding
batch; this batch changes only test spelling on the Swift side.

## UTF-8 follow-up after review of `15108076`

[Claude run 41170455569](https://github.com/onetimesecret/macos/actions/runs/41170455569)
confirmed the preceding fixes, retracted its attribution finding and reported
no blocking defect. Greptile's fourth review found no new actionable defect
at that head. All six CI jobs passed.

| ID | Disposition |
| --- | --- |
| R8-01 | Locale-dependent notice/manifest I/O: use explicit UTF-8 for verifier/test text files and decoded subprocess output. A real CLI regression succeeds with LC_ALL=C, PYTHONCOERCECLOCALE=0 and PYTHONUTF8=0, reading the marked notice. |
| R8-02 | Missing metadata field: main reports LookupError through its concise failure path. A malformed root manifest exits 1 with the workspace field in the message and no traceback. Both new CLI regressions failed against the preceding script. |
| R8-03 | Alleged previous Swift build break: not reproduced. Exact-head shell job 124444355976 on `0f8d377d` reports a warning for await-try, then executes 2,637 tests with 11 skips and zero failures. A separate Swift 6 type-check of that spelling exits 0 with the same warning. The spelling was normalized in `15108076`; the earlier test record remains valid. |
| R8-04 | Drain assertion/comment and formatter cautions: retain the recorded disposition. Reviewers independently traced the paired line/offset invariant; source/patch bytes remain unchanged. |

All 169 script tests pass, including 25 vendor-verifier tests. Final-head CI
and updated reviews are checked separately after pushing this script-only
follow-up; Swift application source is unchanged from `0f8d377d`.

## Reading-position correction after review of `764a69d0`

[Claude run 41171247763](https://github.com/onetimesecret/macos/actions/runs/41171247763)
verified the preceding fixes and identified a new scroll-during-loading path.
Greptile's fifth review was clear at that head; all six CI jobs passed.

| ID | Disposition |
| --- | --- |
| R9-01 | Reproduced loading-label anchor loss: the mounted test's saved index 23,890 (length 48,090) became index 0 in the 18-unit label, then remained 0 after completion instead of rebasing to 23,904. Shared anchor capture now reuses the same page's saved place while rendering, or records page-start when entering a different loading page. It does not derive source positions from the interim label. |
| R9-02 | Explicit navigation: retaining the saved anchor initially overrode an explicit jump to the loading page's start. A second before-fix phase reproduced that result. Explicit scroll-to-destination clears the saved place when the destination is loading. The final regression covers wheel scrolling, navigation away, rail-start intent and editor-to-deferred-preview mapping. |
| R9-03 | Repeated TextProv removal request: declined as intentional attribution, consistent with the prior review's retraction and existing acceptance test. The byte-exact upstream license check is unchanged. |
| R9-04 | Repeated nil-result, key-loop, formatter and registry-warning suggestions retain their recorded dispositions. No additional vendor/feature-policy changes were made. |

The final focused run passes 11 tests with no skips/failures. The full supported
Swift run executes 2,638 tests (393 OnetimePad and 2,245 CompanionKit), with
five opt-in skips and zero failures: 2,633 passes. Logs are
`/tmp/pr337-loading-anchor-{before,rail-before,focused,full}.log`.
The preceding script-only batch passed all 169 Python tests. This batch does
not change those scripts, the Rust source or image transport.

## Document-origin marker after review of `acd98b82`

[Claude run 41172485399](https://github.com/onetimesecret/macos/actions/runs/41172485399)
accepted the previous fixes and dispositions, with no blocking defect. Greptile's
sixth review found no new actionable regression; all six CI jobs passed there.

| ID | Disposition |
| --- | --- |
| R10-01 | Reproduced a stale atTop marker with multipad enabled: after an actual move away from document origin during loading, completion forced y=0 instead of restoring the saved text anchor at about y=505.806. Scroll recording now refreshes that marker from the actual clip origin. Shared capture still preserves the text anchor, and temporary layout clamps do not update the marker. The no-scroll case correctly stays at y=0. |
| R10-02 | Animated-jump capture, row-predicate extraction and diagnostic/consistency suggestions remain non-blocking follow-ups. The ASCII-locale regression specifically covers reading the marked notice; it does not certify arbitrary Unicode diagnostics under an ASCII output stream. No broader output-format policy or verifier refactor is added here. |

The final focused run passes 136 tests, without skips/failures. The full Swift
suite executes 2,639 tests (393 OnetimePad and 2,246 CompanionKit), with five
opt-in skips and zero failures: 2,634 passes. Logs are
`/tmp/pr337-at-top-{before,focused,full}.log`. The 169-test script suite and
image transport remain unchanged from the previously tested batch.

## Horizontal marker after review of `85506506`

[Claude run 41173498156](https://github.com/onetimesecret/macos/actions/runs/41173498156)
confirmed the vertical anchor correction and identified the horizontal counterpart.
Greptile's seventh review was clear at that head; all six CI jobs passed.

| ID | Disposition |
| --- | --- |
| R11-01 | Reproduced horizontal loss in an unwrapped roll: initial loading fallback reported x=0 for actual x=120; after a saved x=120, moving to x=240 retained and restored 120. The fallback now includes the actual x, and non-layout scroll recording refreshes anchor.x alongside atTop. The text anchor stays frozen during loading. |
| R11-02 | The mounted regression also checks a temporary wrapping/layout clamp to x=0: recorded x=240 remains intact and restores after widening and rendering completion. The fallback geometry query is tested before notification recording, independently of actual-scroll capture. |
| R11-03 | Begin-render accessibility notification, removal-key-loop flag and diagnostic/consistency suggestions remain follow-ups. Spoken-output behavior remains unverified; the completion notification is unchanged. The existing fixture error classification and accepted vendor/attribution dispositions remain unchanged. |

All 137 focused DayScroll/deferred tests pass without skips or failures. The
full Swift suite executes 2,640 tests (393 OnetimePad and 2,247 CompanionKit),
with five opt-in skips and zero failures: 2,635 passes. Logs are
`/tmp/pr337-horizontal-{before,focused,full}.log`. The 169-test Python suite
and image transport code remain unchanged from the previously tested batch.

## Zero-distance navigation after review of `c25b6390`

[Claude run 41174659162](https://github.com/onetimesecret/macos/actions/runs/41174659162)
confirmed the marker fixes and identified a zero-distance animated-jump gap.
Greptile's eighth review was clear there; all six CI jobs passed.

| ID | Disposition |
| --- | --- |
| R12-01 | Reproduced a temporary state gap with an owned visible/offscreen window: a zero-distance animated request cleared saved x=240/atTop=true to nil, and wrapping/unwrapping during loading left actual x=0. In the observed run, later render/animation completion recovered x=240; permanent wrong completion was not reproduced. Zero-distance requests now use the existing instant path, immediately recording the intended reset and avoiding the no-event animation dependency. |
| R12-02 | The new mounted regression verifies saved x=240 survives the zero-distance request, temporary clamp and widening. No new animation state or timing seam was introduced. Consistency, key-loop and diagnostic suggestions retain the previous non-blocking dispositions. |

All 138 focused DayScroll/deferred tests pass without skips or failures. The
full Swift suite executes 2,641 tests (393 OnetimePad and 2,248 CompanionKit),
with five opt-in skips and zero failures: 2,636 passes. Logs are
`/tmp/pr337-zero-jump-{before,focused,full}.log`. The preceding 169 Python
script tests and image transport remain unchanged.

## Collapsed-axis preservation after review of `a3e8e4ba`

[Claude run 41175860364](https://github.com/onetimesecret/macos/actions/runs/41175860364)
identified the clamped-axis counterpart to the live marker updates. Greptile's
ninth review found no actionable regression at that head, and all six CI jobs
passed there. These results describe the parent, before this batch.

| ID | Disposition |
| --- | --- |
| R13-01 | Reproduced both axes: a horizontal gesture after the loading body collapsed its height changed a deep saved place to document-top; a vertical gesture after a width clamp overwrote saved x=240 with zero. Non-layout scroll recording now refreshes each marker only while its axis has scrollable extent. The text anchor remains frozen while rendering. |
| R13-02 | Expanded the mounted regression to return to (0,0) in both cases. The origin eligibility guard previously returned nil and erased the saved place before the axis checks. Same-page pending-preview capture now precedes that guard. Explicit navigation still clears the old place before capture. Four combinations cover height/width collapse, with and without returning to origin. |
| R13-03 | Added the notice's recorded upstream revision to the existing scoped metadata comparisons, using the published package's hash-verified .cargo_vcs_info.json. A mutation with the correct revision repeated outside the comrak section remains rejected. All 26 verifier tests and the default 33-file/two-patch verification pass. |
| R13-04 | The proxy fixture publisher and its report reader now specify UTF-8. Both fixture tests and the full 170-test Python suite pass. The handshake classification is unchanged. |
| R13-05 | The continuous-rail versus wheel asymmetry remains a UX follow-up: Claude could not demonstrate user-visible loss. Existing diagnostic, key-loop, spoken VoiceOver/rotor, display-sizing, trusted-private-origin and single-block latency follow-ups retain their recorded scope. No new runtime validation of those items is asserted. |

The final directed run passes all 139 DayScroll/deferred tests without skips
or failures. The full supported Swift run executes 2,642 tests (393 OnetimePad
and 2,249 CompanionKit), with five opt-in skips and zero failures: 2,637 passes.
The regressions use a temporary state directory and an ephemeral credential
client through the existing isolated model helper. Logs are
`/tmp/pr337-cross-axis-{before,origin-before,focused,full}.log` and
`/tmp/pr337-final-upstream-revision-python.log`.

These are local results for this batch. Rust parser bytes and image transport
are unchanged; new-head CI and bot results must be checked after the push.

## Selection restoration and build artifacts after review of `02f2b9e4`

All six [CI jobs](https://github.com/onetimesecret/macos/actions/runs/41177244245)
passed on the parent. Greptile's tenth review found no new actionable defects.
[Claude run 41177244277](https://github.com/onetimesecret/macos/actions/runs/41177244277)
accepted the viewport-marker chain and reported a standalone-build artifact
issue. [Codex's inline selection finding](https://github.com/onetimesecret/macos/pull/337#discussion_r4430837680)
was independently reproduced.

| ID | Disposition |
| --- | --- |
| R14-01 | Fixed selection loss across the interim loading label. A same-text typeface reseed changed range {3362,40} to {18,0}; shorter synchronous and deferred replacements also used the label-clamped range. The preview now saves the preloading ranges across pending generations and passes them to the existing final-storage clamp. The generation check precedes installation, and obsolete completions are tested after a newer selection is made. |
| R14-02 | Fixed standalone vendor build artifacts blocking verification. Cargo.lock is explicitly excluded from the selected upstream files, no Cargo target redirect was configured in the inspected environment, and a fixture target containing a generated symlink reproduced rejection. The verifier now skips only vendor-root target/Cargo.lock entries absent from the pinned inventory roots, without traversing target. Existing source/list/symlink checks remain in place; a nested src/target fixture is still rejected. Scoped Git ignore entries match those generated paths. |
| R14-03 | Retained the direct workspace regression target pointing at vendor/comrak/tests/reference_sourcepos.rs. It is exposed to workspace formatting/lint checks, while its bytes are also verified. Current CI passes; a future concrete toolchain change may require updating the recorded patch and inventory together. This is maintenance work, rather than an unresolvable current failure. No copy or relocation is introduced. |
| R14-04 | The clearEntries key-loop flag remains a non-blocking follow-up: the inspected app uses automatic key-loop recalculation, and the review demonstrated no current failure. The origin-summary comment has a pending-render exception covered by R13. The loading fallback's zero length is benign for its zero character index; the label's length is not a source-text baseline. No additional runtime defect was demonstrated by those notes. |
| R14-05 | Variation-selector-only metadata normalization, registry-projection network access, and unmatched cargo-deny diagnostics retain their prior dispositions. No source-position patch or image-request implementation changed in this batch. Spoken VoiceOver/rotor, display judgment, trusted-private-origin and single-block latency remain separately recorded work. |

The selection-focused run executes 225 tests, with one opt-in profiling skip
and zero failures. The full supported Swift run executes 2,644 tests (393
OnetimePad and 2,251 CompanionKit), with five opt-in skips and zero failures:
2,639 passes. Logs are `/tmp/pr337-selection-{before,focused,full}.log`.

All 28 directed verifier tests and all 172 Python script tests pass, as does
the default verification of 33 files and both patches. The script-suite log
is `/tmp/pr337-vendor-artifacts-python.log`. These are local results for this
batch; CI and bot reviews must be checked again after the push.
