# Shared pad timeline verification

Required behavior is recorded in [ADR-0040](../adr/0040-shared-pad-timeline-navigation.md).
This is a procedure, not evidence of completion. Record the build, macOS version,
window dimensions, fixture, result, and any deviations for each manual run.

| Case | Procedure | Expected observation | Manual result |
| --- | --- | --- | --- |
| Sort directions | Use newest/oldest day order and newest/oldest checkpoint order, all four combinations. Include an empty day gap and retained pages. | Sidebar and roll share order; gap count and retained boundary follow chronology correctly. | Partial: all four combinations match through AX; gap/retained visuals pending |
| Long pages | Use several pages longer than the viewport. Click and drag the minimap, then use the wheel. | Viewport band tracks the visible text; scrubbing reaches both ends without selecting an unrelated checkpoint. | Partial: accessible adjustment verified; pointer/band/wheel pending |
| Many checkpoints | Add more checkpoints than labels can fit. Select checkpoints at the start, middle, and end. | Compact marks retain the minimap; the checkpoint list scrolls and every checkpoint can be reached. | Partial: 61 buttons, endpoint/middle selection and independent list scrolling verified; visual fit pending |
| Minimum window height | Resize to the supported minimum with dense checkpoints and long pages; repeat at larger text size. | Pad/sort/file controls remain reachable, labels do not overlap controls, and the active checkpoint can be revealed. | Not run |
| Pad switching | Give two pads distinct reading positions inside long pages and switch back and forth. | Each pad returns to its remembered page/anchor after geometry is available. | Passed through AX scroll-position comparison; visible-character inspection pending |
| Drag invalidation | Switch pad or sort during a drag; resize/wrap while scrubbing. | The old drag stops; the next drag uses the current geometry. | Not run |
| Missing position | Leave a pad, remove/expire its remembered page, then return. Also test an empty pad. | Restoration uses an available selected page or Today; no stale position or jump into another pad. | Partial: empty pad observed; removal/expiry not run manually |
| File/Ledger | Enter each view after scrolling Timeline, attempt minimap interaction, then return. | Timeline scrolling is hidden or disabled outside Timeline; returning retains the previous Timeline anchor. | Passed through AX: control absent in each view and Timeline scroll position restored |
| Presentation ownership | Move between the primary editor and ambient presentation while scrubbing. | Only the presentation owning the roll scrolls it; the former drag is cancelled. | Partial: primary/ambient transfer observed; transfer during drag pending |
| Keyboard/VoiceOver | Navigate all dense-list checkpoints and activate them. | Checkpoints expose readable labels and selection actions; selection reveals the corresponding page. | Partial: accessible labels/actions verified; full keyboard and VoiceOver run pending |

Automated checks can establish projection, geometry mapping, invalidation, and
anchor fallback behavior. They do not establish native pointer interactions,
visual fit, or VoiceOver behavior for these manual cases.

## Automated evidence — 2026-10-03

The focused Swift/AppKit run passed 258 tests with zero failures on macOS 27.2.
The run included DayScrollTests, PageViewStateTests, PadModelTests,
PadPickerTests, StreamNavigatorTests, TimeRailTests, RollGeometryModelTests,
FileSurfaceTests, EditorHandoffTests, PresentationGuardTests,
DayScrollProjectionTests, and FocusLawTests.

| Coverage | Evidence |
| --- | --- |
| Both ordering directions | Native long-page day/checkpoint reordering preserves the visible character; navigator gap and retained-boundary tests cover reversed chronology. |
| Long pages and dense checkpoints | A 60-checkpoint, 300,000-point document maps into a 72-point minimap in both orders, including subpixel interpolation and the document endpoint. |
| Minimum height | A dense navigator is hosted at 180 points; native reading fixtures use a 120-point viewport. These checks are not a visual-fit assertion. |
| Pad switching | Two populated pads retain different page/character anchors across repeated switches; empty pads and rapid catalog changes have separate regressions. || Passed through AX scroll-position comparison; visible-character inspection pending |
| Missing anchors | Closed, other-pad, and live-but-omitted page anchors are rejected; unavailable positions fall back to Today. Detached nil measurements preserve an existing position. |
| File/Ledger | Native teardown/remount restores the Timeline position, file selection cannot overwrite another pad's position, and inactive geometry draws no band or slivers. || Passed through AX: control absent in each view and Timeline scroll position restored |

Command: `swift test --package-path shell --disable-sandbox --filter 'DayScrollTests|PageViewStateTests|PadModelTests|PadPickerTests|StreamNavigatorTests|TimeRailTests|RollGeometryModelTests|FileSurfaceTests|EditorHandoffTests|PresentationGuardTests|DayScrollProjectionTests|FocusLawTests'`.
The run used the test-util core framework and macOS desktop services.
ADR structure validation also passed: `40 ADRs OK`.
## Manual run — 2026-10-03 (in progress)

Build: worktree `dist/OnetimePad Debug.app`, About reports
`0.26.0 (0.26.0+6a4f3cf.dirty)`, FFI 0.33.0, Core 0.25.0, macOS 27.2.
The packaged pre-signature digest is
`05e17f2315792f5bcb37151dff49ce685b977b0f1d983586a63ca8abbf829fdc`.
The debug process executable was checked against this worktree path.
The installed Local and production apps were not replaced.

Fixture: named pad `QA Timeline A 1003`, 60 pages. Page 1 contains 160
numbered lines, pages 2–3 contain 120 lines each, and the remaining pages
contain short checkpoint text. Existing Scratch content was not edited.
Timeline and the multiple-pad experiment were enabled in the debug app.
Original debug settings were Tabs, multiple pads off, prose size 13,
ambient enabled, and screenshot capture off.

Observed through manual accessibility-tree and keyboard interaction:

- All 60 named checkpoint Buttons are present in the sidebar tree.
- Checkpoint sorting changed from page 1→12 to page 12→1; the roll headers
  changed to the same order. Native context-menu activation needed keyboard
  input after the initial accessibility click left the menu open.
- Day order changed from Newest first to Oldest first. This named fixture
  currently contains only Today, so it does not establish multi-day ordering.
- The accessible reading-position control exposed Increment/Decrement.
  Decrement moved the long page from 100% to 88%; the native scroll bar
  changed to approximately 0.884. Selection was unchanged.

## Manual continuation — 2026-10-04

The same signed debug build was reopened with Timeline and multiple pads
still enabled. Window dimensions were not measured; capture remains excluded.
Pad A now has 61 pages across Yesterday and Today, including a new 80-line
Today fixture. Pad `QA Timeline B 1004` contains a separate 180-line page.

Observed through native accessibility and keyboard operations:

- All four day/checkpoint sort combinations produced matching sidebar order
  and roll headers across Yesterday and Today.
- Checkpoint selection reached page 1, page 30, and page 60.
- Pad A's native roll scrollbar returned to `0.9543728555` after switching
  to B and back; B returned to `0.2014525647`. Selection stayed with each
  pad's intended page. This establishes the measured UI result for this run,
  not a durable-storage guarantee.
- Opening `/private/tmp/onetimepad-timeline-qa.txt` hid the Timeline reading
  control. Closing File returned B to approximately `0.20154335` (20%).
- Ledger also hid the Timeline reading control. Closing Ledger restored A
  from `0.9553423197` to `0.9553347041` (95%). A temporary Cmd-Shift-L Ledger
  binding was saved for this run, then its keymap text was restored to the
  original commented default. The temporary in-memory binding lasts until
  the next app restart.
- The primary editor exposed enabled pad/editor controls after presentation
  transfer; the resting ambient presentation exposed disabled/read-only ones.
- Scrolling the dense checkpoint list through its native Scroll Up action
  changed its scrollbar from `0.9895219384` to `0.4413883432`, while the roll
  scrollbar remained exactly `0.9553347041` and the reading control remained
  95%. This checks list/document scroll independence through accessibility.

The manual matrix is incomplete. A screenshot-permission request remains
pending; the excluded blank screenshot is not evidence of a rendering defect.
Minimum-height visual fit, larger text, pointer scrubbing, viewport-band
alignment, retained/gap decoration, full VoiceOver, and drag invalidation
remain pending. The UI control API exposes an atomic drag, so changing pad,
sort, or presentation while the pointer stays held requires a different
supported input capability or a human-assisted run. No remembered page was
removed or expired in the manual fixture.

Existing Scratch content was not edited. The QA pads, text fixture, and
Timeline/multiple-pad preferences remain available for continuing the run.
