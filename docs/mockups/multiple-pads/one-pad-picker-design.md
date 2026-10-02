---
documentation_status: needs-review
---

# One pad picker: mockup decisions, 2026-10-01

This records the interactions developed and reviewed in this conversation.
The user requested an implementation attempt after reviewing the final mockup.
It is a design record and a browser implementation inventory, not an accepted
project specification or evidence of native functionality. The
[standalone HTML](one-pad-picker.html) and
[editable fragment](one-pad-picker.fragment.html) preserve the reviewed version.

## Purpose and vocabulary

The picker answers **which pad am I writing in?** Folder associations and app
associations support that choice; they are not separate navigation systems.
The sample names are Scratch, Familia, Otto, TextProv, and Dog Jokes.

The user describes a pad as a continuing roll of butcher paper whose older
pages are removed as their lifetimes expire. This exploration adds organization
around that existing model; it proposes no pad deadline or expiring share link.
Accepted [ADR-0017](../../adr/0017-durable-tabs-expiring-pages.md), within its
Tab/Page scope, states: “When a Page expires, it is dropped whole and its Tab
remains empty and reusable.” Accepted
[ADR-0026](../../adr/0026-link-lifetime-is-independent-of-page-lifetime.md) states:
“A link's TTL and a page's TTL are not correlated, in either direction or by any
margin.” These are the authoritative lifetime statements relevant here.
The mockup performs no expiry, restart, or storage validation.

## Defined and implemented in the browser mockup

| Area | Reviewed interaction | What the mockup actually does |
| --- | --- | --- |
| Single picker | One pad name and one dropdown arrow select the active pad. | Selecting a pad updates the header, sample notes, Files list, and timeline selection; it closes the menu. |
| Compact header | Replace folder names with a folder icon and tally. | Non-Scratch pads show `0 folders`, `1 folder`, or the relevant count beside the name. Scratch has no folder tally. |
| Whole pad cell | Hover highlights the name, associated folders, and add CTA together. | CSS highlights the enclosing cell on hover and keyboard focus. Clicking the name or unoccupied cell area selects the pad. |
| Folder labels | An individual folder label has no click action. | Labels are spans, not buttons. Clicking a label neither selects the pad nor opens a change dialog. |
| Folder controls | Add and remove associations within the relevant pad cell. | `+ Add folder…` opens a chooser of sample locations. `×` removes that association. These actions do not switch the active pad. Unbound pads show `No folder linked` plus the add CTA. |
| Folder cardinality | Several directories may associate with one pad; one specific path has one owner. | Sample locations already linked to any pad are disabled in the chooser and name their owner. Removing a link makes that location available. |
| Scratch | Scratch supports no directory associations. | It has neither folder controls nor `No folder linked`. The clear-on-close control has been removed. Its static helper says `Usual page expiry across restarts.` |
| Global options | The menu footer contains options for the whole application. | `App associations` and `Show full paths` are working toggles. Full paths replaces basenames in menu rows. These are not pad-specific actions. |
| Associated apps | Show associated application icons horizontally at the header's right edge. Clicking one should switch to that app. | When app associations are enabled, a fixed sample mapping renders icons. Clicking reports `Switch to … · simulated in this mockup`; it does not activate a process. |
| Shortcuts | Holding Command reveals each pad's shortcut. Scratch always owns `⌘0`; the sample remaining pads use `⌘1`–`⌘4`. | A window key listener reveals labels and switches pads when it receives these chords. It works with the menu closed, within the focused mockup frame; it is suspended while the folder chooser is open. The browser or OS can intercept chords. |
| Writing surface | Start directly at the first checkpoint rule. | The repeated `pad · Today` heading, `Latest` CTA, and invented remaining-lifetime countdowns are removed. Checkpoint timestamps remain. |
| Day order | A direction button beside `TIMELINE` sorts days chronologically or in reverse. | The sample Today/Yesterday groups reorder without changing their checkpoint order. Initial day order is newest first. |
| Checkpoint order | Each day has its own direction button. | Sorting a day changes only that day's checkpoint order, including the writing surface when that day is selected. Initial checkpoint order is oldest first. A day can run in the opposite direction from another day or the overall timeline. |
| Sidebar structure | Persistent Timeline precedes the variable Files list. | Sample files appear below Timeline. The timeline graphics, minimaps, and detailed selection behavior are intentional approximations. |

The prototype remembers its state through the visualization host's optional
widget-state API. That is mockup state, not a demonstration of OnetimePad's
storage guarantees. Selection positions are sampled per pad; day selection and
the two sample day sort directions are shared in this version. Per-pad native
restoration and sort-preference persistence remain implementation decisions.

The chooser contains six predefined paths. It is not an `NSOpenPanel` and does
not grant filesystem access. Some internal replacement-dialog code remains
from the previous revision, but the reviewed UI exposes add/remove only.
There is no app-association editor, incoming app hint, automatic path routing,
window-ID recognition, native keyboard dispatcher, or clipboard operation in
this mockup.

## Folder routing and app hints: proposed native meaning

The proposed distinction is **folder binding** versus **app hint**, replacing
the exploratory terms hard and soft association. A supplied path may identify
one pad even when that pad is not in the active/recent picker. An application
hint may suggest only an already active/recent pad; when several qualify,
most recently active is the proposed tie-breaker. This model is recorded in
[proposed ADR-0038](../../adr/0038-pad-selection-and-associations.md), not
implemented by the HTML.

An app hint adds value only when a broad application identity reduces the
choice: for example, a browser can suggest reading notes, or Zed can suggest a
recent coding pad. It does not identify which of two Zed projects is active.
The latest mockup demonstrates app launch affordances separately from incoming
hints. Clicking a header icon is a deliberate outgoing action, not proof of
where the user came from.

The user explicitly limited the exploration:

> we are not interested in background clipboard collection, or any automatic copying of information that is not readily available in the given context. Paths, applications, and what NSPasteboard/UTI can afford.

This is a task constraint; it does not establish that the current native build
enforces it. The intended implementation uses deliberately supplied paths and
limited app identity, rather than probing another app's project or document.
The [macOS research](../../research/2026-1001-macos-context-and-pasteboard.md)
describes the platform limitations and validation still required. The
[explicit clipboard ADR](../../adr/0037-explicit-clipboard-operations.md),
[copy law](../../law/0002-copy.md), and [paste law](../../law/0003-paste.md)
govern the separate proposed transfer work.

## Approaches that did not work

| Earlier approach | Why it was removed or limited | Current direction |
| --- | --- | --- |
| Parallel project/pad picker and directory dropdown | It read as two competing navigation systems; it was unclear whether folders belonged to the project or were independently selected. | One pad picker; directories are that pad's associations. |
| Folder detail next to the selected pad, then folder names beneath it | Adjacent detail still looked confusing; an expanded list also spent header height on information needed mainly during selection. | Compact tally in the closed header; folder names within the open menu. |
| `Current pad` actions in a detached footer section | Actions were separated from the pad they affected. | Add/remove belongs inside each pad cell; footer contains global options. |
| Clicking a folder to change its binding | The latest request gives existing folder rows no action besides removing an association. | Inert labels, explicit add CTA, and `×` removal. |
| Highlighting only the pad-name row | The highlight excluded the associated folders and CTA, visually splitting one pad into unrelated parts. | Highlight the whole cell. |
| One directory per pad | It excluded useful related roots such as a source checkout and supporting notes. | Many directories per pad, with one owner for each specific path. |
| Generic `Project notes` and `Release notes` | These obscured which real context a choice represented. | Familia, Otto, TextProv, and Dog Jokes distinguish the sample contexts. |
| `No folder linked` for Scratch | It implied an unsupported operation was available or missing. | Scratch has no folder-association UI. |
| Scratch clear-on-close switch | The latest review removed it as inconsistent with the global options and redundant with the usual-expiry helper. | Normal page behavior in the proposal; no special close lifecycle in this mockup. |
| `Stay in Project notes` beside `Project notes` | It named the same destination without clearly explaining a distinct action. It was intended as dismissing an incoming hint while keeping the current pad. | The latest mockup omits this hint popup. It does not settle a future hint-dismissal design. |
| Redundant content heading and `Latest` CTA | They occupied prime writing space. | Start at the checkpoint rule; put sorting beside the timeline and each day. |
| Repeated `5h 50m remaining` | The values were invented and irrelevant to the interaction under review. | Omit countdowns here. This does not abolish lifetime indicators elsewhere in the app. |
| An app-switch journal | A retained chronological history of app changes was explanatory research language, not an agreed feature. | No activity-history feature in this exploration. |
| Background clipboard collection or copying inferred context | Explicitly excluded by the user's scope. | Transfers require the deliberate actions addressed in the clipboard records. |

## Decisions still needed before a native contract

**Keyboard ownership needs a successor decision.** Accepted
[ADR-0017](../../adr/0017-durable-tabs-expiring-pages.md) states:
“⌘1 to ⌘9 are shortcuts to the first nine slots and the rest have no chord
(issue #158).” The mockup assigns those digits to pads. ADR-0038 proposes the
replacement within its scope; its acceptance and the predecessor's reciprocal
supersession record are still required. The accepted ADR has not been rewritten
to make the mockup appear compliant.

**Day-order policy needs a successor design decision.** The accepted
[2026-09-15 UI/UX decision record](../../spec/design/2026-0915-ui-ux-decisions.md#4--how-pages-are-organized-and-where-they-live)
states: “days group live pages by the day they were written, newest first, and
move no content.” Selectable ascending order is the new mockup proposal. The
underlying day grouping and content ownership remain distinct from display
order; an accepted successor must name the order policy it replaces.

**Path identity needs native rules.** The sample chooser enforces exact
predefined-path exclusivity. It does not settle case sensitivity, symbolic
links, security-scoped bookmarks, inaccessible/moved folders, or ownership of
nested roots. A directory binding is context metadata, not permission to scan
that directory. Longest-root routing and failure handling are implementation
proposals requiring explicit tests.

**App hints need discovery and ambiguity rules.** Associations can be plural;
the prototype's lists are fixed. Native add/remove UI, a bounded recent-pad
definition, app activation failures, an on/off default, and whether to suppress
a hint when a folder has already identified the pad remain to be settled.
The user suggested that suppressing such a hint might avoid redundant UI;
the mockup does not test it.

**Window identity remains unproven.** An ephemeral window identifier might
remember a prior manual selection without exposing document contents, but no
stable supported window-context mechanism is demonstrated here. The app-only
baseline cannot promise to distinguish projects inside two windows of the
same application. Do not persist a speculative window-to-pad binding as if it
were confirmed provenance.

## Review checklist for the prototype

1. Open the picker; hover a pad and confirm one highlight contains all its rows.
2. Add a folder to an inactive pad, confirm the active pad does not change,
   and confirm that location is unavailable to other pads until removed.
3. Click a folder name and confirm it does nothing; click `×` to unlink it.
4. Toggle full paths, then app associations; confirm each changes its own UI.
5. Hold Command to reveal shortcuts; exercise `⌘0` and `⌘1`–`⌘4` where the
   browser delivers them. Check Scratch has no folder controls or close toggle.
6. Confirm the closed header shows a tally and horizontal app icons, and that
   icon clicks explicitly report a simulation.
7. Reverse days, then reverse checkpoints in just one day; verify these are
   independent and the selected day's paper follows its checkpoint direction.
8. Confirm Timeline remains above Files, paper starts at a checkpoint rule,
   and no invented countdown or `Latest` control appears.

These checks validate browser interactions only. Native persistence,
filesystem authorization, app activation, clipboard behavior, and supported
macOS releases require their own evidence.
