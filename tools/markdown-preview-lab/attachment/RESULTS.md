# Attachment-cell / VoiceOver research results

## Status

**Local automated checks: 127/127 passed. External AX: blocked by TCC.
Manual VoiceOver: OPEN, not performed.**

This is research evidence, not an accepted product specification or a shipping
compatibility guarantee. This task wrote only this lab and made no commits.

## Execution and evidence

Repository HEAD at task start: `54d38a549b597f9fd5a664e48db05a293bccbb5d`;
HEAD at final scope inspection: `103eef0270843173c3acbf9f3013bd421f602dd6`.
Repository activity outside this task changed HEAD during the session. Lab
sources are uncommitted and independent of repository code; their final hashes
identify the tested inputs rather than either repository commit.
Tested on Apple Silicon, macOS 27.2 (26B5101f), Swift 6.4
(`swiftlang-6.4.0.34.1`), using Swift 5 language mode and the installed Xcode SDK.
The host clock recorded these runs on 2026-10-17 UTC (2026-10-16 locally).

**Execution notice:** the following commands are historical records, not
approval to rerun. They open a visible synthetic-fixture macOS app and start
AXClient to inspect/attempt accessibility actions. Loading is simulated and
makes no network request. The app exits within its configured duration. Explain
the launch and obtain operator approval before another run; do not grant
accessibility permission or enable VoiceOver implicitly.

Final source build and automated run:

```sh
python3 tools/markdown-preview-lab/attachment/repro.py
```

- [Automated run](runs/20261017T032134Z/run.json): app exit 0; AX client exit 3
  (explicit TCC-blocked result).
- [127 checks and app-side snapshots](runs/20261017T032134Z/app-report.json).
- [External AX error evidence](runs/20261017T032134Z/external-ax.json).
- [Separated outcome](runs/20261017T032134Z/outcome.json).

Fresh GUI-only run of the same binaries:

```sh
python3 tools/markdown-preview-lab/attachment/repro.py --no-build --gui --duration 15
```

- [GUI run](runs/20261017T032150Z/run.json): window opened and exited normally;
  no self-test executed; the external client skipped attachment-target presses
    but still attempted an application-level press after an API-disabled read.
- [GUI state](runs/20261017T032150Z/app-ready-report.json).
- [App-content raster](runs/20261017T032150Z/fixture.png): AppKit-rendered view
  contents, not evidence of VoiceOver speech or a hardware-input test.

Both app-console logs were empty. The Python runner and compiled Swift processes
all finished within their bounds. `validation.json` records final source hashes.

## Inputs read before design

- [`AGENTS.md`](../../../AGENTS.md).
- [`MarkdownPreviewView.swift`](../../../shell/Sources/CompanionKit/MarkdownPreviewView.swift):
  explicit TextKit1 construction, promotion path, link delegate, table rendering,
  image-alt handling, and object-token emission.
- [`InkEditorView.swift`](../../../shell/Sources/CompanionKit/InkEditorView.swift):
  `SealedBlockCell` initialization, sizing/drawing, `accessibilityLabel()`, cell
  click delegate, and the supplemental handle-element construction.
- Accepted [ADR-0023](../../../docs/adr/0023-hybrid-link-affordance-cmd-click-opens.md),
  Decision, exact wording: “Every click on a link is claimed by the delegate:
  with ⌘ held the target opens in the default browser; without it the caret is
  placed where the click fell and nothing else happens.”
- Accepted [ADR-0030](../../../docs/adr/0030-visible-pages-share-preview-rendering.md),
  Consequences, exact wording: “Quiet pages remain noneditable and
  nonselectable; clicking one still promotes it into the single editor.”

Interpretation for this experiment: selection and action should be separate,
and a quiet-page gesture should promote before a subsequent load action.
The ADRs do not specify image load buttons or a VoiceOver activation grammar.
Those behaviors in this lab are proposals, not attributed requirements.
The existing cell label override is code evidence only; it does not establish
that VoiceOver has been manually verified in the shipping app.

## Findings

### AX-01 — default attachment cells expose no load press locally

**Evidence level: reproduced through AppKit's in-process accessibility APIs.**

At `baseline/child/7`, the stock image-backed `NSTextAttachmentCell` becomes an
`NSAccessibilityReparentingCellProxy` with role `AXImage`, no label, and legacy
`accessibilityActionNames == []`. At `baseline/child/0`, the hand-drawn,
label-only cell becomes the same proxy type with role `AXStaticText`, label
`Mountain image`, and actions `[]`. Both direct default press calls returned
false. Native attachment positions and sizes were populated by the proxies;
querying the cell objects themselves returned zero frames.

**Consequence:** setting a cell label alone did not create a default load action
in the app-side bridge on this OS. External action exposure is unverified due
to AX-05. Do not infer an action from `isAccessibilitySelectorAllowed`: that
inherited method returned true even for the default cells with no actions.

**Disposition:** research result; no shipping change.

### AX-02 — a cell-level override is forwarded by the native proxy

**Evidence level: reproduced through the in-process native proxy.**

At `baseline/child/8`, the `CellPressProbe` proxy advertised `["AXPress"]`.
Invoking its legacy `accessibilityPerformAction:"AXPress"` dispatched to the
cell's `accessibilityPerformPress()` override. The counter changed from 1
(after a direct control call) to 2 (after proxy dispatch). Tests also exercised
that handler on a quiet page: first action promoted with load count 0; the
separate second action produced load count 1.

The cell object's own legacy action list was still `[]`. Inspecting only that
object would have missed the proxy's action. The proxy class name is recorded
for diagnosis; the prototype does not instantiate that private AppKit class.

**Consequence / proposal:** test a cell-level press override with an owner/page
callback before adopting additional image action children. This may avoid the
duplicate-node problem in AX-03. External AX and VoiceOver are still required
before accepting that design.

**Disposition:** promising local result; external confirmation OPEN.

### AX-03 — supplementary elements work locally but duplicate native nodes

**Evidence level: reproduced in-process; external reachability unresolved.**

`LoadElement`, a retained `NSAccessibilityElement` subclass, reported role
`AXButton`, exact label `Load image (simulated): Mountain image; count 0`, and
named custom action `Load image (simulated)`. Direct default press and the actual
`NSAccessibilityCustomAction.handler` both incremented the intended counter.
Screen-space frames were nonempty; hit testing returned the same element.
Frames for the painted attachments matched their glyph bounding rectangles,
including those in the text table. Element identity survived selection/action
mutations. Sealed supplementary elements reported `AXStaticText`, refused press,
and had no named load action.

The native baseline had 10 children (9 attachment proxies + 1 link). Custom
views had 19 (the same native children + 9 supplementary elements). App-side
legacy action enumeration on the supplementary elements returned `[]`, while
the modern press method and named handler executed. That legacy result does not
settle what the out-of-process modern AX bridge advertises.

**Consequence:** direct-call success is insufficient to select this approach.
VoiceOver reading order, repeated image/sealed labels, Actions menu exposure,
focus retention, and announcements after promotion remain unknown. A production
version would need a deliberate native/supplement integration strategy; this
experiment intentionally leaves native children visible for comparison.

**Disposition:** implemented and locally tested; not validated for adoption.

### INPUT-01 — selection and action are separate in custom routing

**Evidence level: reproduced with synthetic AppKit input and native commands.**

| Scenario | Expected | Observed |
| --- | --- | --- |
| Custom plain/Command click, every attachment | Select exactly one object; no load/link intent | Passed for all 9 attachments |
| Native Shift-Right at an attachment | Select its one UTF-16 object character | Passed on baseline and custom views |
| Native Right | Move past the object; no load | Passed |
| Space then Return on selected image | One increment per key action | Count 1, then 2 |
| Space on sealed alt object | Refuse load | Count 0 |
| Quiet click | Promote only | Selected page, count 0, range unchanged |
| Second quiet click, then separate Space | Select only, then load | Count 0, then 1 |
| Quiet supplementary press twice | Promote only, then load | Count 0, then 1 |
| Quiet cell-level press twice | Promote only, then load | Count 0, then 1 |
| Quiet link delegate | Promote without link intent or load | Passed |
| Linked-image custom action | Load image counter, no outer-link intent | Passed |

Native baseline `mouseDown` with a queued mouse-up left selection at `{0, 0}`
for the stock and label-only controls, with no load. This is an observation of
that synthetic delivery path, not a conclusion about physical mouse/window
routing. The custom handler explicitly selects the attachment instead.

**Disposition:** local routes tested; physical pointer/key and VoiceOver behavior
remain in the manual protocol.

### FIXTURE-01 — nested stand-ins survive the proposed display arrangement

**Evidence level: reproduced on hand-built attributed text.**

The table image and sealed object used actual `NSTextTableBlock` paragraph
attributes, produced nonzero geometry, and retained separate actions/labels.
The sealed alt object remained a separate attachment and supplementary static
text node before the image. Simulated loading left the attributed text's string
unchanged. No network fetch or browser-open implementation exists in the lab;
all actions use counters/local drawing.

**Limitation:** this does not exercise `swift-markdown`, the shipping renderer,
Rust, sealed-object authorization, copy/export, source mapping, or expiry. The
alt layout is one proposed representation, not a parser round-trip test.

**Disposition:** fixture coverage complete for this isolated experiment.

### AX-05 — external inspection and actions blocked by TCC

**Evidence level: reproduced in a separate AX client process.**

Both recorded final runs observed:

- `AXIsProcessTrusted() == false`.
- `AXUIElementCopyAttributeValue(application, AXWindows) == -25211`
  (`kAXErrorAPIDisabled`).
- External attribute/child/action enumeration returned the same error.
- A press attempt on the already-denied application element returned `-25211`.
- No attachment/custom target was reachable; **zero target actions were
  externally performed**. The single empty application record is not an
  inspected attachment tree.

The operator reported a permission request and declined access pending context.
The machine evidence establishes denied operations, not absence of a prompt.
No permission grant or global settings change was recorded. The runner preserves
the denied result rather than reporting external success. Any retry needs
advance explanation and operator approval; granting access is not required to
read or retain this evidence. With access, the client would walk the tree,
invoke target presses, and check corresponding app-side effects.

**Disposition:** unresolved environment blocker. Both native-cell and custom
external-AX exposure remain OPEN.

### VO-01 — manual VoiceOver integration remains open

**Evidence level: read-only platform state observation only.**

`NSWorkspace.shared.isVoiceOverEnabled` was false at the ready and final
snapshots. VoiceOver was not enabled by the agent. No VoiceOver commands,
spoken labels, rotor/Actions-menu contents, or cursor movement were observed.
The GUI launch and app-side AX tests are not manual VoiceOver verification.

**Disposition:** OPEN. Follow the expected-versus-observed protocol in
[README.md](README.md), with a
fresh GUI session and an operator-controlled VoiceOver setup.

## Narrow conclusion

On this macOS build, the default native attachment proxies lacked a load action,
while a cell-level press override was advertised and dispatched by AppKit's
in-process proxy. The supplementary-element alternative has working local
handlers and geometry but adds duplicate nodes. These results justify a
permission-enabled external AX retry and a real VoiceOver session; they do not
establish shipping accessibility support or cross-version behavior.

No shipping source or `docs/spec/design/2026-1016-markdown-dialects-and-preview.md`
was modified. No unrelated test suite or shipping app build was run.
