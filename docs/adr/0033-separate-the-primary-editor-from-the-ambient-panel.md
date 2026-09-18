---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# ADR-0033: Separate the primary editor from the ambient panel

- **Status:** accepted
- **Date:** 2026-09-18
- **Supersedes in part:** [ADR-0010](0010-form-factors-as-sibling-targets.md), specifically Amendment 1 except its login launch clause; [ADR-0019](0019-the-pad-is-on-every-space.md), specifically the reach of its all Spaces rule over the whole application, which now covers the ambient panel only; and [ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md), specifically its return switch consequence and the reach of its companion window rule over the primary editor. Their remaining decisions stand.
- **Depends on:** [ADR-0006](0006-persistent-editor-storage-swap.md) for the one layout manager per storage rule, and [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md) with [ADR-0016](0016-content-persists-across-restart.md) for the persistence model that bounds window restoration.

Read [ADR conventions](README.md) before filing or changing an ADR.

The decision issue is [#191](https://github.com/onetimesecret/macos/issues/191).
The implementation sequence lives in the
[window roles workplan](../plans/window-roles.md), Track B.

## Context

OnetimePad currently asks one window to serve three different roles: desktop
furniture while resting, a floating nonactivating panel when summoned, and the
application's primary editor once it has the keyboard. Those roles want
different macOS window semantics.

A nonactivating `NSPanel` is the conventional foundation for a palette, HUD,
Spotlight-like surface, or drop-down terminal. It can be summoned without
activating its application, temporarily take input, float above other work, and
recede when dismissed. A primary editor conventionally does the opposite: its
window activates the application, becomes key and main, participates in normal
application ordering and window cycling, stays at normal level when another
application activates, and delegates Mission Control, Stage Manager, full
screen, and focus restoration to AppKit.

`NSPanel` is itself an `NSWindow` subclass. Replacing the class name alone would
therefore decide nothing. The tension comes from the surrounding policy:
nonactivating style, refusal to become main, floating level, all-Spaces
membership, and custom raise and rest transitions. As the panel is made to
imitate a primary application window, each ordinary behavior has to be
reconstructed as another transition in that policy. Fixing one symptom leaves
the same question at Settings, open panels, window cycling, Spaces, Stage
Manager, and focus restoration.

[ADR-0032](0032-inactive-raised-surfaces-follow-normal-app-stacking.md) records
a narrower response to one such symptom: a raised but keyless surface uses
normal app stacking by default while the nonactivating-panel architecture
remains intact. Its fourth eject trigger names the broader question and asks
for a separate ADR to answer it. This record is that ADR: which window role
should be the foundation of the primary editor?

Three architectures are available:

1. Keep one nonactivating panel and embrace an ambient utility interaction,
   without promising ordinary editor conventions.
2. Replace the ambient posture with one conventional activating editor window.
3. Give the conventional editor and the ambient utility separate windows over
   one in-process document model.

The third option preserves both product ideas without requiring one window to
hold contradictory identities. In this record the ambient panel means
OnetimePad's existing background surface panel, not the panel form factor that
[ADR-0014](0014-archive-the-panel-form-factor.md) archived.

Four facts from the code and the accepted record bound the decision.

First, a page has one `NSTextStorage` with exactly one layout manager.
[ADR-0006](0006-persistent-editor-storage-swap.md) rests on that rule and
`Coordinator.shedLayoutManagers` in `InkEditorView.swift` enforces it at every
mount and swap. A mount sheds every layout manager already on the storage, so a
second editor on the same page would take the first editor's layout manager
away. The resting card mounts that same editor read only, so a read only second
window collides as well. Two live presentations of one page are therefore not
available without reopening ADR-0006.
[ADR-0020](0020-a-day-is-a-projection-of-live-pages.md) already shows the
sanctioned way to draw a page the editor is not on: a rendering that cannot
take focus, over private storage (`PageModel.QuietRendering`).

Second, the third option reopens
[ADR-0010](0010-form-factors-as-sibling-targets.md) Amendment 1, which rejects
one app with two windows for the former panel and backdrop form factors. Since
ADR-0014 the process is `.regular`, there is one bundle id and there is one
store. Of the amendment's four arguments only the launch story still describes
something that exists.

Third, persistence, Keychain scope and `FormFactor` are already single and do
not know which window is showing. One document model needs no new work there.
The presentation state is the opposite: `PageModel` holds about twenty
presentation fields that mount sites write last writer wins, and menu
enablement reads `activeEditor` while menu actions go to the key window's first
responder.

Fourth, Track A of epic [#192](https://github.com/onetimesecret/macos/issues/192)
implemented ADR-0032 and met the pattern described above once more. The raised
panel takes part in other applications' full screen Spaces
(`.fullScreenAuxiliary` in `BackdropStance`), and a preliminary hardware probe
saw the normal level keyless card still drawn above another application's full
screen content after ⌘Tab. The hand check is pending under
[#190](https://github.com/onetimesecret/macos/issues/190). Whatever its verdict,
full screen participation is one more policy the panel has to derive for itself
and an ordinary window receives from AppKit.

## Decision

Make an ordinary activating `NSWindow` the primary editing surface. It uses
normal window level, may become both key and main, has ordinary Space
membership, and follows the standard macOS application ordering, switching,
cycling and full screen model.

Keep the ambient behavior in a separate nonactivating `NSPanel`, the existing
background surface, over the same in-process document model. The ambient panel
is not the primary application window and owns no independent document or
persistence lifecycle. Do not continue expanding one nonactivating panel to act
as both the ambient surface and the conventional primary editor. The editor
window is a second window role of the OnetimePad form factor, not a new form
factor under ADR-0010.

**One owner.** Exactly one of the two windows owns the live page content at a
time. The owner mounts the editor on the page's storage and holds the
presentation state that has no owner today: the active editor, the sealed paste
route, the today anchor, the roll geometry, key ownership, the redraw cadence,
the pasteboard offer and the keyboard map. The window that does not own shows a
glance built from private storages, or nothing. It never mounts a second editor
on a live storage, read only or otherwise. ADR-0006's one layout manager per
storage rule stands unchanged.

Ownership is explicit, exclusive and transferable. It moves when the other
content window takes the keyboard. Key status passing to Settings, About, a
modal panel or another application moves nothing. The resulting rule is a
function of two facts: the panel owns while it is raised or while the editor
window is closed, and the editor window owns otherwise.

- With the editor window closed the panel owns, resting or raised, as it does
  today.
- A summon raises the panel and gives it ownership. The editor window, if
  open, shows a glance.
- When the editor window takes the keyboard, a raised panel rests.
- When the panel rests while the editor window is open, ownership returns to
  the editor window. The keyboard returns with it only if the application is
  active.

The ambient panel may edit while it owns. A read only panel is a policy
restriction on this model (never grant the panel ownership), not a different
architecture, so the model is built transferable either way. Whether the panel
keeps its editing role is left to the dogfood evidence the first three eject
triggers name.

**Launch and activation are decided by route, never by last use.** A login
launch, or any launch the system performs without activating the application,
shows the ambient panel only and never opens the editor window. A launch the
person performs, a Dock click, a reopen and ⌘Tab select the editor window,
opening it when it is closed, because an active application with no key window
strands the keyboard. The global hotkey, the status item and a click on the
resting card stay with the panel and do not activate the application. A modal
return and a cancelled quit go back to the owner. `NSApp.deactivate()` on rest
does not fire while the editor window is visible.

**Commands.** Commands on the model (new page, close page, select, open, save,
Settings) act on the shared model from either window. Commands that depend on
the first responder belong to the owner's editor, and menu enablement reads the
owner's editor, so a menu item cannot be enabled by one editor and answered by
the other. While Settings, About or a modal panel holds the keyboard,
enablement still reads the owner, which is today's behavior with one window.
⌘W stays `page::Close`: the page strip is a tab strip, and Safari and Terminal
close the tab on ⌘W. ⇧⌘W closes the window. The default keymap leaves ⇧⌘W
free.

**The ambient panel is a persistent preference, default on.** It is not a
transient mode. It sits behind a code boundary that lets the panel be removed
without touching the editor window or the shared model. The preference is local
window state beside Pin and geometry, as ADR-0032's preference is, and never
enters the page model, the core, the state file or the sync protocol. With the
panel off, the hotkey and the status item select the editor window.

**Restoration is limited.** The editor window keeps frame autosave and nothing
else. It sets `isRestorable = false`, so AppKit writes no window state or
snapshot to Saved Application State, which the persistence model of ADR-0012
and ADR-0016 has no place for. It sets `sharingType = .none` under the same
capture opt out the panel observes. Its title names the application and never
page content, because a window title is published to the Window menu, Mission
Control and the system window list, none of which capture exclusion covers.

This decision concerns window roles, ownership and activation semantics. It
does not choose the conventional window's visual chrome or the ambient panel's
final interaction affordances.

## Consequences

- ⌘Tab, application activation, key and main status, ordinary window
  ordering, the Window menu, Mission Control, Stage Manager, and full screen can
  follow AppKit's primary-window conventions instead of a growing custom state
  machine.
- The nonstandard behavior is isolated to the surface whose purpose requires
  it. The ambient panel may still use special levels, Space membership, mouse
  transparency, and nonactivating focus without making those policies the
  editor's foundation.
- The document model and persistence lifecycle remain singular inside one
  process. The two windows present the same state in turn, not side by side,
  and are not sibling applications with stores that can diverge.
- A hotkey that summons the ambient panel and a ⌘Tab that selects the
  application become distinct gestures with distinct, explainable outcomes.
- Presentation ownership in `PageModel` has to be built before both windows
  can be trusted together. This is the expensive part of the work. Mount sites
  check ownership instead of writing last.
- Caret and scroll are saved per editor coordinator today. A hand off between
  windows must carry them through the model, or every owner change loses the
  person's place. Undo is the core's stack and survives a hand off untouched.
- The editor window has a desktop. ⌘Tab from another desktop can carry the
  person to the desktop the editor window is on, as it does for any document
  application. ADR-0019's promise that activation never changes the desktop now
  holds only while the editor window is closed. Settings and About keep
  `.moveToActiveSpace`.
- A raised panel no longer survives the return ⌘Tab. The return selects the
  editor window and the panel rests. The selected page survives because the
  model is shared, and an activation still never anchors the roll on today. The
  panel reaches raised and keyless only from a hotkey or status item summon, so
  ADR-0032's keep above preference matters in fewer situations.
- The editor window never takes floating altitude. A pinned card floats above
  it as it floats above every other normal window, which is what Pin means.
- Closing the editor window does not quit the application. With the panel on,
  the application keeps running as the ambient surface.
- Supporting two surfaces costs more UI plumbing than choosing either an
  ambient-only utility or a conventional-only editor. That cost is accepted to
  avoid embedding both interaction models in one window.
- Existing tests and hardware procedures that assume every raised editor is the
  all-Spaces panel must be divided between primary-window behavior and
  ambient-panel behavior.

## Relationship to earlier decisions

**ADR-0010 Amendment 1 is superseded except its login launch clause.** The
amendment's heading, "two apps, not one app with two windows", and three of its
four arguments are replaced. "Activation policy is per process" no longer
divides anything: both window roles want the `.regular` policy the process
already holds. "The permission system addresses bundle ids" and "Lifecycles are
independent" described two apps, and ADR-0014 left one. The closing prediction
is replaced as well:

> And if state sharing ever fires the last eject trigger above, the
> likely answer is still two shells over a core-side store or daemon, not
> one app.

What stands is the first sentence of its launch clause:

> The backdrop exists by being at the desktop from login; the panel is
> summoned when wanted.

Its conclusion that "a merged app imposes one story on both surfaces" is
answered by deciding launch by route. ADR-0010's decision that form factors are
sibling targets stands, and its fourth eject trigger does not fire, because the
two window roles are one form factor over one store.

**ADR-0019 is scoped to the ambient panel.** Its decision stands for the panel
word for word:

> The pad's Space membership is `.canJoinAllSpaces`, in every posture and
> either pin state, and it never changes.

The editor window has ordinary Space membership, so this consequence is
replaced for the application as a whole and holds only while the editor window
is closed:

> Activating the pad never changes the user's desktop, because there is
> nothing of the app to reveal elsewhere.

"The pad is furniture, not a document window" remains true of the panel. The
editor window is the document window.

**ADR-0032 stays in force for the panel, with a narrower reach.** The three
fact model, the altitude table, the keep above preference, the outside click
rule and the panel's Space membership stand. Two clauses are replaced. The
first consequence's promise that "OnetimePad retains the raised page and
editing context for the return switch" gives way to the return ⌘Tab selecting
the editor window and resting the panel. The companion window rule, "When
Settings or another ordinary window of OnetimePad takes the keyboard, its level
must be compatible with the surface's resulting inactive altitude", continues
to govern Settings and About and does not govern the editor window, which stays
at normal level. ADR-0032's fourth eject trigger fired and this record is its
answer:

> A supported requirement needs conventional main-window behavior such as
> title-bar movement, standard window cycling, per-Space placement, or ordinary
> activation for every summon.

**ADR-0006 is not superseded.** "One `NSTextView` persists across page↔page
switches" now reads per window: each window keeps one persistent editor and
swaps storages into it. Across windows the rule is one owner per page. Its
second eject trigger, "A future feature needs per-sheet view instances", was
tested by this proposal and did not fire. Exclusive ownership is what keeps it
from firing: there is still one mounted editor, one `activeEditor`, one sealed
paste route and one first responder candidate at a time.

ADR-0020's single editor invariant is kept the same way, and its private
storage renderings are the precedent for the glance.

## Resolved questions

The proposal carried five open questions. Each is answered in the Decision.

- Is the ambient panel read only until it hands off? No. It may edit while it
  owns, and a read only panel remains available as a policy on the same model.
- What does launch show? The route decides. Login shows the panel only. A
  person's launch selects the editor window.
- Which window owns commands? Model commands act from either window. First
  responder commands and menu enablement belong to the owner's editor. ⌘W
  closes the page and ⇧⌘W closes the window.
- Is the ambient panel a preference, a mode or a removable feature? A
  persistent preference, default on, behind a boundary that allows removal.
- Which clauses are superseded? See Relationship to earlier decisions.

## Eject triggers

- Dogfood evidence shows that the ambient surface is not used once a
  conventional editor exists; remove the second surface and retain only the
  primary window.
- Dogfood evidence shows that the conventional editor is not used and that the
  product is understood and preferred as an ambient utility; reject or
  supersede this decision in favour of the single-panel architecture.
- Dogfood evidence shows that the panel is summoned to read and not to type;
  restrict it to a glance by policy and keep the ownership model.
- Exclusive ownership produces recurring hand off defects (a lost caret or
  scroll position, a stale glance, a window left without an owner, a command
  answered by the wrong window) that cannot be removed behind the one ownership
  model; restrict the panel to a glance first, and reconsider two windows only
  if the defects survive that.
- A supported requirement needs the same page live in both windows at once.
  That reopens ADR-0006 and needs its own ADR.
- A future AppKit API supplies one supported window role that can change between
  conventional primary-window and nonactivating ambient semantics without
  recreating either behavior manually; reassess the two-window boundary.

## Decision history

- 2026-09-17: Proposed.
- 2026-09-18: Accepted, narrowed, under decision issue
  [#191](https://github.com/onetimesecret/macos/issues/191). "Two live
  presentations" became one owner at a time, the five open questions were
  answered in the Decision, restoration was limited to frame autosave, and the
  third eject trigger was reworded to match. Supersedes in part ADR-0010
  (Amendment 1 except its login launch clause), ADR-0019 (its reach beyond the
  ambient panel) and ADR-0032 (its return switch consequence and its companion
  window rule's reach over the editor window). ADR-0006 stands and its second
  eject trigger did not fire.
