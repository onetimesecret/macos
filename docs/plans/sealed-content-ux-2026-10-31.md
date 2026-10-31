# Sealed-content UX revision

Status: implemented; automated verification and rendered-fixture review complete, 2026-10-31.

The user asked for a methodical response to the 28-item visual and source audit.
This file records implementation choices and verification; it is not an
independent security specification or evidence that these changes work.

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
| 6 | Competing selection treatments | Native selection with matching selected foreground replaces orange border/halo. | Selected fixtures in both appearances. |
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
| 20 | Naming loses valid draft on blur | Valid blur saves; Save/Cancel and Return/Esc are visible. Invalid drafts stay open for correction. | Focus-loss, commit and cancel tests. |
| 21 | Name refusal appears far away | Error stays beside the field and is exposed through accessibility help. | Local-error tests. |
| 22 | No direct contents editor and unclear commitment | One-way sealing remains explicit: visible pre-seal explanation, menu/help, and copy/edit/seal replacement instructions. No silent unseal or new contents editor. | Selection-menu and clipboard-offer tests; existing seal tests. |
| 23 | Incomplete accessibility identity/actions | Summary includes the permitted excerpt and note presence; visible Move/Copy/More/Note controls expose actionable buttons with identity-based callbacks. | AX labels, frames, stable elements and actual press tests. VoiceOver hand check remains. |
| 24 | Sharing loses source identity | Confirmation snapshots and shows the selected object name/excerpt or page title. | Sharing identity tests. |
| 25 | Stale clipboard success and no recovery | Past-tense success wording plus Copy Link Again. A core-only recovery buffer uses a unique token and a fixed initial recovery deadline; the shell receives availability, never the URL text. | FFI and Swift recovery, expiry, supersession and repeated-receipt tests. |
| 26 | Remove and burn wording is inconsistent | Remove from Document is distinct from Delete Local Sealed Content / Discard Local Page. Done replaces Keep It; help describes the actual action. | Menu/removal and sharing tests. |
| 27 | Open menu targets stale character position | Every menu action captures object identity, resolves its current position at execution, and refuses a missing target. Copy presses also re-resolve after tracking. | Edit-while-menu-open and removed-target tests. |
| 28 | Independent custom systems disagree | Shared control geometry drives drawing, hit-testing, cursor regions and AX. Removed zone, hover-copy and pill machinery; naming/note editors use the same object rectangles. | Focused regression suite, source review and rendered fixtures. |

## Link recovery implementation

The FFI's current implementation keeps one `Zeroizing<Vec<u8>>` recovery buffer
for the latest completed link, identified by a core-generated token rather than
a server receipt. The recovery deadline starts at completion and is not extended
by a re-copy. The shell schedules expiry from the core's remaining duration and
forgets the matching token when its draft closes. A newer completion replaces
the prior buffer; old requests cannot copy or forget the newer token. A re-copy
uses the existing pasteboard writer and creates no additional network request.
These are implementation observations to verify, not independent guarantees.

## Verification record

- `scripts/test-shell.sh`: 393 app tests and 2,311 CompanionKit tests executed,
  7 existing skips, 0 failures. The full run included the optional rendering tests.
- `cargo test -p companion-ffi -- --test-threads=1 --skip drop_to_seal_reads_the_drag_board_core_side`:
  401 passed, 1 existing ignored test, 1 excluded shared-system-drag-pasteboard test.
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
  refusal, and live remeasurement in standalone/continuous projections.

Manual VoiceOver navigation/rotor and physical-display inspection remain
unperformed. The accepted excerpt algorithm, ASCII variable-name rule, raw
assignment copy and one-way sealing are explicit retained decisions, rather than
new contents-editing or general-purpose labeling features.

Automated fixtures use temporary state and an in-memory credential client.
Rendered examples contain synthetic values. No running personal app is launched,
quit, reset or replaced for these checks.
