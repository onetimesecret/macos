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
height follows the identity font. The primary row shows the variable name,
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

The accessibility summary includes the existing excerpt and note presence.
Visible controls expose named actions that resolve the object's identity at
execution. The object menu is:

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
any invalid remainder. Escape and Cancel discard the draft. A removed or
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
continues to mean structural removal.

The implementation p󠄁e󠄁r󠄁m󠄁i󠄁t󠄁s󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 l󠄁a󠄁t󠄁e󠄁s󠄁t󠄁 c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁e󠄁d󠄁 l󠄁i󠄁n󠄁k󠄁 d󠄁u󠄁r󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁
i󠄁n󠄁i󠄁t󠄁i󠄁a󠄁l󠄁 6󠄁0󠄁-󠄁s󠄁e󠄁c󠄁o󠄁n󠄁d󠄁 r󠄁e󠄁c󠄁o󠄁v󠄁e󠄁r󠄁y󠄁 p󠄁e󠄁r󠄁i󠄁o󠄁d󠄁,󠄁 u󠄁s󠄁i󠄁n󠄁g󠄁 a󠄁 c󠄁o󠄁r󠄁e󠄁-󠄁s󠄁i󠄁d󠄁e󠄁 b󠄁u󠄁f󠄁f󠄁e󠄁r󠄁 a󠄁n󠄁d󠄁 u󠄁n󠄁i󠄁q󠄁u󠄁e󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁.󠄁
R󠄁e󠄁-󠄁c󠄁o󠄁p󠄁y󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 e󠄁x󠄁t󠄁e󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁 d󠄁e󠄁a󠄁d󠄁l󠄁i󠄁n󠄁e󠄁 o󠄁r󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁 a󠄁n󠄁o󠄁t󠄁h󠄁e󠄁r󠄁 n󠄁e󠄁t󠄁w󠄁o󠄁r󠄁k󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁.󠄁
A󠄁n󠄁 e󠄁x󠄁p󠄁i󠄁r󠄁y󠄁 q󠄁u󠄁e󠄁r󠄁y󠄁,󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁 f󠄁o󠄁r󠄁g󠄁e󠄁t󠄁/󠄁d󠄁r󠄁a󠄁f󠄁t󠄁 d󠄁i󠄁s󠄁m󠄁i󠄁s󠄁s󠄁a󠄁l󠄁,󠄁 s󠄁u󠄁p󠄁e󠄁r󠄁s󠄁e󠄁s󠄁s󠄁i󠄁o󠄁n󠄁 o󠄁r󠄁 h󠄁a󠄁n󠄁d󠄁l󠄁e󠄁 d󠄁r󠄁o󠄁p󠄁
r󠄁e󠄁m󠄁o󠄁v󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 b󠄁u󠄁f󠄁f󠄁e󠄁r󠄁.󠄁 T󠄁h󠄁e󠄁 U󠄁I󠄁 t󠄁i󠄁m󠄁e󠄁r󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁s󠄁 r󠄁e󠄁m󠄁o󠄁v󠄁a󠄁l󠄁 w󠄁h󠄁e󠄁n󠄁 i󠄁t󠄁s󠄁 r󠄁e󠄁c󠄁o󠄁v󠄁e󠄁r󠄁y󠄁 p󠄁e󠄁r󠄁i󠄁o󠄁d󠄁
e󠄁n󠄁d󠄁s󠄁;󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁r󠄁e󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁 d󠄁e󠄁a󠄁d󠄁l󠄁i󠄁n󠄁e󠄁 a󠄁l󠄁o󠄁n󠄁e󠄁 i󠄁s󠄁 n󠄁o󠄁t󠄁 a󠄁n󠄁 e󠄁a󠄁g󠄁e󠄁r󠄁 p󠄁h󠄁y󠄁s󠄁i󠄁c󠄁a󠄁l󠄁 w󠄁i󠄁p󠄁e󠄁.󠄁 T󠄁h󠄁e󠄁s󠄁e󠄁 a󠄁r󠄁e󠄁
i󠄁m󠄁p󠄁l󠄁e󠄁m󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 c󠄁o󠄁n󠄁s󠄁t󠄁r󠄁a󠄁i󠄁n󠄁t󠄁s󠄁;󠄁 t󠄁h󠄁i󠄁s󠄁 n󠄁e󠄁w󠄁l󠄁y󠄁 w󠄁r󠄁i󠄁t󠄁t󠄁e󠄁n󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁 i󠄁s󠄁 n󠄁o󠄁t󠄁 e󠄁v󠄁i󠄁d󠄁e󠄁n󠄁c󠄁e󠄁 o󠄁f󠄁
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
copy/edit/seal replacement route. This revision adds no contents editor.
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
