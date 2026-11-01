---
id: 2026-1031-sealed-content-ux-revision
title: Sealed-content interface revision
status: accepted     # draft → accepted → superseded
dated: 2026-10-31
supersedes: docs/spec/design/2026-0915-ui-ux-decisions.md; docs/spec/design/2026-0916-clipboard-clear-interval.md
superseded-by:
surfaces: OnetimePad sealed objects, naming and one-time-link confirmation
sources:
  - the maintainer's sealed-content UX instruction, 2026-10-31, quoted below
  - docs/law/0001-sealed-object.md
  - docs/law/0007-edit-in-place.md
  - docs/adr/0042-a-sealed-name-is-a-shell-identifier.md
  - docs/adr/0047-name-value-copies-the-value-unquoted.md
  - docs/adr/0055-menus-and-buttons-use-the-platforms-wording.md
  - docs/adr/0060-shared-pad-timeline-navigation.md
---

# Sealed-content interface revision

The maintainer authorized the 28-item presentation revision on 2026-10-31:

> Please go ahead, methodically addressing each of the 28 items.

This record states the interface decisions within that request. The
[28-item checklist](../../plans/sealed-content-ux-2026-10-31.md) is a review
and verification aid, not a source of authority for these decisions or their
security properties.

## Whole-record succession

This record supersedes both the former [UI/UX record](2026-0915-ui-ux-decisions.md)
and the [clear-interval record](2026-0916-clipboard-clear-interval.md) in full.
It incorporates their unchanged decisions from the immutable versions at
`367a65c6f4d051ffdc87ac8ebb43f154e9b97783`:

- [UI/UX decisions, including D-01 through D-33](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/spec/design/2026-0915-ui-ux-decisions.md).
- [Clear interval, including its incorporation of D-34 through D-41 and
  replacement of D-42/D-43](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/spec/design/2026-0916-clipboard-clear-interval.md).

Only the passages enumerated below change. The accepted scoped successors
already identified by those records, including [ADR-0060](../../adr/0060-shared-pad-timeline-navigation.md)
for Timeline navigation, retain their scope. The old stream record's
one-time-link success sentence is historical; the D-09/D-42 revision below
replaces that sentence as incorporated by the former clear-interval record.

The full `superseded` status follows the dated-record rule in the
[behaviour law conventions](../../law/README.md): a dated record
“is superseded whole when any of them changes.” Unchanged behavior is
incorporated above rather than removed. This differs from an ADR's partial
replacement, which retains the ADR's accepted status under the
[ADR conventions](../../adr/README.md#metadata-and-relationships).

The predecessors' structured `superseded-by` entries retain their earlier
relationships as well as the new successor: the UI/UX record's scoped
ADR-0060 edge remains explicit, and the stream record's whole-record path
through the clear-interval record remains explicit. The new record is the
whole-record successor of the UI/UX and clear-interval snapshots, and the
stream record's successor through that existing chain. No earlier edge or
scoped behavior is withdrawn by this metadata update.

## Revised decisions

### The block, D-10 and D-27 through D-29: identity and explicit controls

The object uses a compact natural width within the editor's measure. Its
height follows the identity font, with 52 points as a minimum rather than a
fixed live height. Fixed 12-point system action chrome is distinct from the
user-selected writing font. Writing-font changes resize the identity row;
control labels fit their allocated bounds, including long translations.
The primary row shows the variable name,
when present, then a middle dot and the existing excerpt. The excerpt
algorithm is unchanged. The secondary row contains the quiet classification,
a stable Note action when a note exists, and explicit Move, Copy decrypted
and More controls where space permits. More remains available at narrow widths;
its menu exposes the applicable copy, naming, note and removal actions.

The name and excerpt select the object on single or repeated clicks. Neither
text nor a separator copies, and no hover state changes click semantics.
Copy decrypted copies on a click and starts an outward decrypted drag when
dragged. Move uses the structural drag. Help distinguishes the two. These
controls remain visible in the editable document; passive previews and drag
images omit editor controls. Native selection supplies the selected treatment.
The lock and text follow the selected foreground. Edited metadata appears
beside a line only when there is room for it.

Note and More use recognizable action treatments, and control borders remain
distinguishable from the surrounding block. Rendered fixtures and geometry
checks assess these treatments; physical-display inspection remains separate.

The accessibility summary includes the existing excerpt and note presence.
Copy, More and Note expose named actions that resolve the object's identity at
execution. The pointer Move handle has no duplicate selection-only accessibility
child. Native text selection followed by Cut/Paste is the intended keyboard and
VoiceOver movement route. Keyboard regression coverage checks movement and
object identity; actual VoiceOver navigation remains unperformed. The object
menu is:

```text
Copy Sealed Reference
Copy Variable Name
Copy Decrypted Contents
Copy NAME=Value (Unquoted)
Create One-Time Link…
────────────────────────
Edit Variable Name…
Edit Note…
────────────────────────
Remove from Document
```

An unnamed object omits the name copies and uses Set Variable Name….
An object without a note uses Add Note…. Assignment copy is offered for
named text objects only. Payload actions are absent when the value is on
another device. The copy-decrypted chord remains the user's keymap binding.

### Law 0007: variable-name editing

Set/Edit Variable Name… opens the inline field with an API_KEY example,
format guidance, local validation and Save/Cancel controls. Return and Save
commit. A valid focus loss also saves, including a pad switch or editor
handoff. An invalid blur leaves the draft open for correction; teardown closes
any invalid remainder. A refused blur returns the keyboard to the field.
Validation is shown after a save or blur attempt refuses the draft, then updates
as that draft changes. Escape and Cancel discard the draft. A removed or
expired source does not rename a replacement object. Naming is an explicit
action; repeated clicks on identity text remain selection gestures.

### D-09 and D-42: one-time-link confirmation and completion

The inline confirmation displays the source object's name/excerpt or page
name, the destination and the existing expiry/passphrase/recipient fields.
Create Link remains the confirming network action. Failure stays inline with
Retry. Completion uses past-tense wording, rather than asserting the clipboard
still contains the link. Copy Link Again is available during the initial
recovery period. Done dismisses the confirmation. Delete Local Sealed Content
and Discard Local Page name separate destructive actions; Remove from Document
continues to mean structural removal. The destructive action is visually
separated below a divider from Copy Link Again and Done in the primary row.

The creation task retains its model through outcome handling so that a response
still receives clipboard/recovery cleanup if the view disappears. This lifetime
choice is distinct from the task's later UI-state staleness checks. In the
implementation, `discard_page` removes the page while its slot survives;
`cached_link` requires a readable source page, and UI dismissal explicitly
forgets the matching token. No content-equality condition is added to recovery.
These are implementation observations, not new persistence or erasure
guarantees.

The implementation permits access to the latest completed link during an
initial 60-second recovery period, using a core-side buffer and unique token.
Re-copy does not extend the access deadline or create another network request.
An expiry query, explicit forget/draft dismissal, supersession or handle drop
removes the buffer. The UI timer requests removal when its recovery period
ends; the core access deadline alone is not an eager physical wipe. These are
implementation constraints; this newly written record is not evidence of
retention or erasure properties.
The unchanged D-43 guarded-clear semantics come from the immutable
clear-interval record incorporated above.

### D-15 and ADR-0055: copy register for the revised interface

Menu items and ordinary buttons retain title case. The compact block labels
use sentence case: Sealed text, Sealed image, Copy decrypted and Copied.
Field guidance, validation and the pre-seal explanation use ordinary sentence
case and may directly instruct the reader. Existing footer notices keep the
lower-case status register. Exclamation marks and reveal-implying labels remain
excluded. The ellipsis on Set/Edit Variable Name… is a scoped exception to
ADR-0055 point 2: this action opens the field together with its auxiliary
instructions and controls. Other in-place name fields retain their wording.

## Unchanged boundary decisions

The accepted pre-task [UI/UX record, sealing paragraph](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/spec/design/2026-0915-ui-ux-decisions.md#sealing-a-selection-after-the-fact)
states:

> ⌘Z after sealing is not offered; the content comes back only through *Copy decrypted contents*.

The pre-seal interface makes that consequence visible and explains the
copy/edit/seal replacement route. On macOS 14 and later the context menu places
the consequence in a native noninteractive section header before Seal Selection;
macOS 13 uses a disabled informational fallback. The explanation is visible
without waiting for a tooltip. Its announcement in assistive technology remains
a manual check. This revision adds no contents editor.
The variable-name rule remains the accepted [ADR-0042 Decision](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/adr/0042-a-sealed-name-is-a-shell-identifier.md#decision):

> A sealed name is 1 to 64 characters matching `[A-Za-z_][A-Za-z0-9_]*`,
> its case kept as typed.

Assignment copy retains [ADR-0047's exact format](https://github.com/onetimesecret/macos/blob/367a65c6f4d051ffdc87ac8ebb43f154e9b97783/docs/adr/0047-name-value-copies-the-value-unquoted.md#decision):

> no quotes, no escapes, no added space.

These immutable sources establish the pre-existing decisions. The implementation
and tests remain separate evidence of behavior; this revision does not validate
its own security, privacy, persistence or data-loss properties.

## Acceptance

[Laws 0001](../../law/0001-sealed-object.md) and
[0007](../../law/0007-edit-in-place.md) contain the operative interaction rows
and their named regression tests. The [28-item checklist](../../plans/sealed-content-ux-2026-10-31.md)
records the executed checks and remaining manual VoiceOver and display checks.
