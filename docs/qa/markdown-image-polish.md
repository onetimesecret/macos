# Markdown image interaction follow-up

This record describes implementation and validation after PR #336. It does not
establish additional product guarantees.

## Presentation decisions

- Buttons keep the action at the beginning and truncate the destination at the
  end. Where the full label does not fit, the visible title becomes Load image,
  Cancel image, Retry image, or Unload image. The accessibility label retains
  the action, full hostname, and alt text; help retains the complete URL.
- A table containing an image uses stacked cells when equal column widths
  leave insufficient room for the widest localized compact control. Cells
  remain in row order. The entire table becomes stacked paragraphs, including
  text-only cells; native column structure and table-block semantics are absent
  in that narrow presentation. Widening restores the original table styles.
  This changes paragraph presentation without inserting or removing characters.
- Image display size divides decoded pixel dimensions by the current window's
  backing scale before applying the available-width and 400-point-height caps.
  A 240-by-120-pixel image therefore occupies 120-by-60 points on a 2x display.
  Moving between backing scales schedules another presentation.
- Updating an action posts an accessibility title-change notification on the
  existing button. Loading, cancelling, retrying, and unloading reuse that button.

## Automated coverage

`PreviewImageControlsTests` covers narrow/wide/narrow table convergence, action
visibility, complete destination accessibility metadata, button source order,
keyboard focus across load/unload, unchanged compact titles across resize and
discard, Retina size calculations, and unchanged copy/selection behavior. The fixtures use temporary state and in-memory clients.

The first focused run passed all 33 image-control tests, including the new
table, label/focus, and Retina calculations. A later unchanged-title regression
was added and is included in the final validation record.

## Human walkthrough

Spoken VoiceOver and rotor behavior require a human walkthrough. No spoken
result is inferred from accessibility metadata, action calls, or focus tests.
Use an isolated test-owned window to check:

1. Read image alt text, then navigate to its control. Confirm action, hostname,
   state changes, and full-destination help are understandable.
2. Exercise Load/Cancel, failure/Retry, and Load/Unload with keyboard and
   VoiceOver. Confirm focus remains on the control and reading resumes nearby.
3. Check empty alt text, disabled destinations, multiple images, and image copy.
4. Narrow a many-column table until cells stack, then widen it. Confirm control
   order and reading order remain useful, with no hidden action words.
5. Inspect small and large images on 1x and 2x displays, including a window moved
   between displays. Confirm image size and sharpness are acceptable.

## Keyboard traversal correction

The isolated host initially traversed image controls in reverse source order.
AppKit had calculated its automatic key loop while the buttons had zero frames.
When control geometry changes, layout now asks the owning window to recalculate
its native key loop. The regression starts with that stale layout and checks
forward/backward source order, disabled-control skipping, and exit to an
external sibling. All 35 image-control tests pass. Spoken behavior remains a
separate human check.

## Expanded validation

At code commit `afbee4ac6d1e9dae88d23ebd5fc595f88dd75052`, all 41
image-control tests pass. A separate background probe passed 866 checks with
zero failures/skips across 24 width/font/appearance cycles and the actual font
Settings route. It generated 36 bitmap specimens. Its loader used synthetic
raster images and controlled continuations; the parser and UI were the current
implementation. Source and linked-binary hashes are in its JSON report.

The probe reproduced loaded-image loss after repeated resize on a page with a
sealed object in image alt text. Fresh attachment instances had equal complete
`ChipInfo` values but failed attributed-string identity comparison. The fix
compares exact UTF-16 text, complete chip metadata, and the other attributes.
Mounted regressions cover loaded pixels, button identity, request count, copy
identity and selection through repeated narrow/wide updates. Changed chip
metadata still refreshes the face and requires another explicit image load.

Routing text is available in the hover tooltip and accessibility help. A sighted
keyboard user who tabs and immediately presses Space has no visible consent
sentence or first-click dialog. That disclosure limit remains explicit.
Spoken output, rotor behavior, and physical-display size/sharpness remain
unverified; metadata and bitmap inspection do not certify those observations.

The process-only `AppleKeyboardUIMode` argument-domain experiment did not
change AppKit's reported keyboard-navigation state: values 0 and 3 both
reported enabled on this host. CI retains the explicit preference-dependent
traversal skips; local native traversal and unconditional metadata checks pass.
