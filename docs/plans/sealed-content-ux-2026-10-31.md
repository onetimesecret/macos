# Sealed-content UX revision

Status: implemented; automated verification and rendered-fixture review complete, 2026-10-31.

The user asked for a methodical response to the 28-item visual and source audit.
This file records implementation choices and verification; it is not an
independent security specification or evidence that these changes work.
T󠄁h󠄁e󠄁 [d󠄁a󠄁t󠄁e󠄁d󠄁 i󠄁n󠄁t󠄁e󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁](../spec/design/2026-1031-sealed-content-ux-revision.md)
a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 a󠄁m󠄁e󠄁n󠄁d󠄁e󠄁d󠄁 l󠄁a󠄁w󠄁 r󠄁o󠄁w󠄁s󠄁 s󠄁t󠄁a󠄁t󠄁e󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 d󠄁e󠄁c󠄁i󠄁s󠄁i󠄁o󠄁n󠄁s󠄁.󠄁 T󠄁h󠄁i󠄁s󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁l󠄁i󠄁s󠄁t󠄁
d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁 t󠄁h󠄁e󠄁m󠄁.󠄁

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
| 23 | Incomplete accessibility identity/actions | Summary includes the permitted excerpt and note presence; visible Move/Copy/More/Note controls expose actionable buttons with identity-based callbacks. | AX labels, frames, stable elements and actual press tests. VoiceOver hand check remains. |
| 24 | Sharing loses source identity | Confirmation snapshots and shows the selected object name/excerpt or page title. | Sharing identity tests. |
| 25 | Stale clipboard success and no recovery | Past-tense success wording plus Copy Link Again. A core-only recovery buffer uses a unique token and a fixed initial recovery deadline; the shell receives availability, never the URL text. | FFI and Swift recovery, expiry, supersession and repeated-receipt tests. |
| 26 | Remove and burn wording is inconsistent | Remove from Document is distinct from Delete Local Sealed Content / Discard Local Page. Done replaces Keep It; help describes the actual action. | Menu/removal and sharing tests. |
| 27 | Open menu targets stale character position | Every menu action captures object identity, resolves its current position at execution, and refuses a missing target. Copy presses also re-resolve after tracking. | Edit-while-menu-open and removed-target tests. |
| 28 | Independent custom systems disagree | Shared control geometry drives drawing, hit-testing, cursor regions and AX. Passive previews and drag images omit editor controls. Removed zone, hover-copy and pill machinery; naming/note editors use the same object rectangles. | Focused regression suite, source review and rendered fixtures. |

## Link recovery implementation

The FFI's implementation keeps one `Zeroizing<Vec<u8>>` recovery buffer
for the latest completed link, identified by a core-generated token rather than
a server receipt. I󠄁t󠄁s󠄁 6󠄁0󠄁-󠄁s󠄁e󠄁c󠄁o󠄁n󠄁d󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁 d󠄁e󠄁a󠄁d󠄁l󠄁i󠄁n󠄁e󠄁 s󠄁t󠄁a󠄁r󠄁t󠄁s󠄁 a󠄁t󠄁 c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 i󠄁s󠄁 n󠄁o󠄁t󠄁
e󠄁x󠄁t󠄁e󠄁n󠄁d󠄁e󠄁d󠄁 b󠄁y󠄁 a󠄁 r󠄁e󠄁-󠄁c󠄁o󠄁p󠄁y󠄁.󠄁 T󠄁h󠄁e󠄁 s󠄁h󠄁e󠄁l󠄁l󠄁 s󠄁c󠄁h󠄁e󠄁d󠄁u󠄁l󠄁e󠄁s󠄁 a󠄁 r󠄁e󠄁m󠄁o󠄁v󠄁a󠄁l󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁r󠄁e󠄁'󠄁s󠄁
r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁i󠄁n󠄁g󠄁 d󠄁u󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 f󠄁o󠄁r󠄁g󠄁e󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 m󠄁a󠄁t󠄁c󠄁h󠄁i󠄁n󠄁g󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁 w󠄁h󠄁e󠄁n󠄁 i󠄁t󠄁s󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁 c󠄁l󠄁o󠄁s󠄁e󠄁s󠄁.󠄁 T󠄁h󠄁e󠄁
b󠄁u󠄁f󠄁f󠄁e󠄁r󠄁 i󠄁s󠄁 d󠄁r󠄁o󠄁p󠄁p󠄁e󠄁d󠄁 o󠄁n󠄁 a󠄁n󠄁 e󠄁x󠄁p󠄁i󠄁r󠄁y󠄁 q󠄁u󠄁e󠄁r󠄁y󠄁,󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁 f󠄁o󠄁r󠄁g󠄁e󠄁t󠄁/󠄁d󠄁r󠄁a󠄁f󠄁t󠄁 d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁a󠄁l󠄁,󠄁
s󠄁u󠄁p󠄁e󠄁r󠄁s󠄁e󠄁s󠄁s󠄁i󠄁o󠄁n󠄁 o󠄁r󠄁 h󠄁a󠄁n󠄁d󠄁l󠄁e󠄁 d󠄁r󠄁o󠄁p󠄁;󠄁 r󠄁e󠄁a󠄁c󠄁h󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁 d󠄁e󠄁a󠄁d󠄁l󠄁i󠄁n󠄁e󠄁 a󠄁l󠄁o󠄁n󠄁e󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 e󠄁a󠄁g󠄁e󠄁r󠄁l󠄁y󠄁
w󠄁i󠄁p󠄁e󠄁 i󠄁t󠄁.󠄁 A newer completion replaces
the prior buffer; old requests cannot copy or forget the newer token. A re-copy
uses the existing pasteboard writer and creates no additional network request.
These are implementation observations to verify, not independent guarantees.

## Verification record

- `scripts/test-shell.sh`: 393 app tests and 2,327 CompanionKit tests executed,
  7 existing skips, 0 failures. The full run set `ONETIMEPAD_SEALED_PREVIEW_DIR=/tmp/sealed-ux-preview` and included the optional rendering tests.
- `cargo test -p companion-ffi -- --test-threads=1 --skip drop_to_seal_reads_the_drag_board_core_side`:
  402 passed, 1 existing ignored test, 1 excluded shared-system-drag-pasteboard test.
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
