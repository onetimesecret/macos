# TextKit1 attachment / accessibility lab

Isolated research, not a shipping implementation or an accepted design decision.
Everything in this lab is under `tools/markdown-preview-lab/attachment/`.

## Build and run

**Obtain operator approval before launching.** The default command opens
**Attachment AX Lab**, a visible macOS app, and starts **AXClient** to inspect
and attempt accessibility actions against it. The fixtures are synthetic;
loading is simulated, with no network requests or page data. The app normally
exits after 15 seconds. Accessibility access is broad UI-control permission,
not administrator access; do not grant it or change VoiceOver/settings implicitly.
Use `--build-only` to compile without opening an app or starting AXClient.

From the repository root:

```sh
python3 tools/markdown-preview-lab/attachment/repro.py
```

Requires macOS, Xcode command-line tools, and Python 3.11+. No package download,
Rust framework, Swift package dependency, or real image server is involved.
`swiftc` compiles `Lab.swift` and `AXClient.swift` against AppKit and
ApplicationServices. The module cache and `.app` bundle are in `.build/`.

The default run:

1. Builds `.build/AttachmentLab.app` and the separate `.build/AXClient` process.
2. Opens a real AppKit window with three explicitly constructed TextKit1 graphs:
   `NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView`.
3. Executes bounded in-process assertions and synthetic input delivery.
4. Tries an external AX tree walk and actions against that app's PID.
5. Writes JSON evidence and an app-content raster, then closes after 15 seconds.

Build commands have 120-second limits. The AX subprocess has an 18-second limit;
tree traversal is limited to 400 nodes and depth 14. The runner terminates its
child app on failure. No server or watcher is started.

A successful exit means the requested local checks passed. It does **not** mean
external AX or VoiceOver passed. Read `outcome.json`: `BLOCKED_TCC` is a distinct
outcome, not an external-AX success.

```sh
# Build without launching.
python3 tools/markdown-preview-lab/attachment/repro.py --build-only

# Approved GUI session; skips self-test and attachment-target presses.
python3 tools/markdown-preview-lab/attachment/repro.py --no-build --gui --duration 300
```

GUI duration is bounded to 15–900 seconds. Close the window to finish earlier.
The runner prints the result directory and PID while the app is active.
`ready.pid` is historical evidence after the process exits, not a live PID file.
A generated app can also be opened from Finder after building; its default
lifetime is 300 seconds. Prefer the runner so output goes into a dedicated run.

## What is real, and what is simulated

- Real AppKit window, text storage, TextKit1 layout, attachment drawing,
  `NSTextTableBlock`, native accessibility proxies, custom accessible elements,
  accessibility action handlers, and a separate AX client.
- Three columns: native baseline, selected custom page, initially quiet custom
  page. Each has nine attachments plus a native link node.
- Baseline controls: stock image-backed `NSTextAttachmentCell`, label-only
  hand-drawn cells, and a hand-drawn cell with `accessibilityPerformPress()`.
- Custom strategy: retained `NSAccessibilityElement` children with button roles,
  screen-space frames, hit testing, default press, and a named
  `NSAccessibilityCustomAction`. Native children are retained for comparison.
- Hand-built attributed fixtures, **not Markdown parsing**: image; image inside
  an outer `.link`; image and sealed stand-in inside an actual text table; sealed
  stand-in within alt text, separately represented before its image; and a
  standalone sealed object. The alt arrangement is a proposed display fixture,
  not proof of parser behavior.
- Sealed objects are labels and object characters only. There is no core model,
  ciphertext, decryption, expiry gate, or clipboard integration in this app.
- Load increments an integer and updates the event log. Link intent is logged,
  not opened. Images use local drawing only. No URL loading API is implemented.
- Synthetic mouse delivery calls `mouseDown` with a queued mouse-up for native
  tracking. Custom clicks call the same overridden mouse handler used by the
  GUI. Keyboard selection invokes native NSTextView movement commands; Space
  and Return use constructed key events. This is not hardware-input testing.

## Evidence files

Each `runs/<UTC timestamp>/` includes:

| File | Content |
| --- | --- |
| `app-ready-report.json` | State before external inspection/actions |
| `app-report.json` | Final checks, app-side AX snapshots, and event journal |
| `external-ax.json` | External AX errors, tree, advertised actions, attempted presses |
| `outcome.json` | Separate local, external-AX, and VoiceOver status |
| `run.json` | Exact launch command, duration, PID, exit results |
| `fixture.png` | App-content raster, not a desktop screenshot or VoiceOver capture |
| `app-console.txt`, `ax-console.txt` | Process output; empty app output is normal |

`native` snapshots include both the cells themselves and their native children.
The cell object alone is misleading: the native reparenting proxy can advertise
an action that the cell's legacy action list omits. `pressSelectorAllowed` alone
also does not establish an advertised action; its inherited default is permissive.
The legacy methods are inspected through Objective-C selectors because native
attachment proxies do not adopt the modern Swift accessibility protocol.
Their runtime class names are observations, not API dependencies for shipping.

## Manual VoiceOver protocol — OPEN / not performed

The recorded runs observed `NSWorkspace.shared.isVoiceOverEnabled == false`.
The operator reported a permission request and declined access pending context.
Saved AX errors establish denied operations, not whether macOS displayed a prompt.
VoiceOver was not enabled by the lab; no spoken output or navigation was observed.
No permission grant or settings change was recorded.

If the operator elects to test VoiceOver, use their normal existing setup or
explicitly enable it themselves. `VO` below means their configured VoiceOver
modifier. The app does not change that configuration.

After explaining the launch and obtaining operator approval, start the fresh
300-second GUI command above. Use VoiceOver's normal window and
text-area navigation. Interact with a text area using `VO-Shift-Down Arrow` when
needed; use `VO-Right Arrow` to move through items, `VO-Space` for the default
action, and the Actions menu (`VO-Command-Space`, with standard bindings) for
named actions. Record actual wording and order rather than assuming a particular
VoiceOver verbosity configuration. The exact labels below are AX label targets;
they are not predictions of verbatim speech.

| Step | Exact expected result to check | Observed manual result |
| --- | --- | --- |
| Baseline stock image | Image node exists; no default load action. No simulated load event from merely navigating to it. | NOT TESTED |
| Baseline label-only cell | Label `Mountain image`; no advertised default press. | NOT TESTED |
| Baseline cell press probe | Label `Cell press probe`; default action reaches the cell handler and status shows `cell-level AXPress` / `simulated load 1`. | NOT TESTED |
| Selected custom plain image | Reach label `Load image (simulated): Mountain image; count 0`, button role. `VO-Space` produces count 1 exactly once. | NOT TESTED |
| Named action | Actions menu offers `Load image (simulated)`; choosing it increments that image's count exactly once. | NOT TESTED |
| Quiet custom image | Initial label `Promote page before action: Mountain image`. First `VO-Space` logs `promoted only`, count stays 0. A separate second press logs `simulated load 1`. | NOT TESTED |
| Image inside link | Custom image action increments image count only; native outer link remains separately navigable. No browser opens. Record whether order or repeated nodes are confusing. | NOT TESTED |
| Table image and sealed object | Image action remains reachable at its drawn table position. `Sealed stand-in: Table sealed` has no load action. Record table reading order. | NOT TESTED |
| Object within alt | Separate label `Sealed stand-in: Alt sealed object`, followed by image label `Load image (simulated): Image with object in alt; count 0`. Sealed item has no load action; image has one. | NOT TESTED |
| Pointer vs keyboard | On custom selected page, plain and Command clicks select one object without load. Native Shift-Right from just before an attachment selects it. Right traverses without load; Space/Return on a selected image loads once. | NOT TESTED physically; synthetic routes passed |
| Quiet pointer route | First click only promotes; second click selects; separate Space/Return loads. | NOT TESTED physically; synthetic routes passed |
| Duplicate navigation | Record native attachment node and supplementary node, their order, link duplication, and any unexpected repeats. Proposal acceptance requires resolving unwanted repetition. | NOT TESTED with VoiceOver; 19 app-side children observed |

Save observations in a new file under this directory, including run timestamp,
macOS version, VoiceOver bindings/verbosity, spoken labels, action menu contents,
and expected/actual differences. Do not overwrite the unverified status with a
pass unless a person actually performs and observes these steps.

### Optional external AX retry

Current external attempts failed with `-25211` (`kAXErrorAPIDisabled`). If the
operator chooses to grant accessibility access, use System Settings → Privacy &
Security → Accessibility and approve only the relevant executable/launching app
identified by macOS. No permission change is needed for the local self-test.
Avoid rebuilding after approval when possible; use `--no-build`.

```sh
# Tries external reads and test presses, then verifies app-side effects.
python3 tools/markdown-preview-lab/attachment/repro.py --no-build
```

The external client enumerates attribute/action names, tree positions and sizes,
and parameterized-attribute names. With access, it attempts two presses on the
quiet image, selected linked/table image presses, a sealed-item refusal, and the
native cell-press proxy. GUI mode skips attachment-target presses, but AXClient
still attempts an application-level press after an API-disabled read, recording
the action-side TCC error. Thus the recorded GUI mode is not press-free; the
denied root action did not reach a fixture target.

See [RESULTS.md](RESULTS.md) for the actual observations and remaining blockers.
