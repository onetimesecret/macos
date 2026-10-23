# docs/spec/feature/primary-editor/README.md
---

# Feature Spec: the primary editor window

Status: **draft**, for review · 2026-09-19
Structure decision:
[ADR-0033](../../../adr/0033-separate-the-primary-editor-from-the-ambient-panel.md)
(accepted 2026-09-18), which supersedes in part
[ADR-0010](../../../adr/0010-form-factors-as-sibling-targets.md)
Amendment 1 (except its login launch clause),
[ADR-0019](../../../adr/0019-the-pad-is-on-every-space.md) (its reach
beyond the ambient panel) and
[ADR-0032](../../../adr/0032-inactive-raised-surfaces-follow-normal-app-stacking.md)
(its return switch consequence and its companion window rule's reach
over the editor). Sibling spec:
[background-surface](../background-surface/README.md), which now
describes the ambient panel only.

## Application launch and return

[ADR-0059](../../../adr/0059-appkit-owns-window-presentation.md) replaces ADR-0033's unconditional editor selection. An initial foreground open selects the editor. A background launch does not. Cmd-Tab preserves AppKit's focus and window ordering, including a return to Settings or another ordinary window. A Dock reopen uses a visible ordinary window when available; otherwise it opens or deminiaturizes the editor without moving the current page or scroll position. The ambient panel does not prevent this reopen.

Settings opens only through an explicit Settings action. AppKit owns the application lifecycle and menus; SwiftUI renders content within its windows.

## Summary

OnetimePad has two window roles over one in-process document model.
This spec is the **primary editor window**: a plain activating
`NSWindow` with the conventional macOS editing behaviour a person
expects from a document application. It is a second window role of the
OnetimePad form factor under ADR-0010, not a new form factor.

The ambient panel keeps its stance model, its all Spaces membership,
its outside click rule and its hotkey and status item summons. The
editor window gains the responsibilities the panel could not carry
without contradiction: ⌘Tab membership, ordinary Space membership, key
and main status, participation in the Window menu, Mission Control,
Stage Manager and AppKit's own full screen.

Both windows present the same document model in turn, not side by
side, and are not sibling applications with stores that can diverge.
Exactly one window owns the live page content at a time; the owner
mounts the editor on the page's storage and holds the presentation
state (`activeEditor`, sealed paste, today anchor, roll geometry,
`holdsKeys`, the redraw cadence, the pasteboard offer and the keyboard
map). The window that does not own shows a glance built from private
storages, or nothing (ADR-0006, ADR-0020).

## Window chrome and role

- **Class.** Ordinary activating `NSWindow`, titled, resizable, at
  normal window level. Not an `NSPanel`; not `nonactivatingPanel`; not
  a floating level; no all Spaces membership. Its window role and
  behaviour are AppKit's defaults for a document application, and this
  spec restates them only where the panel's answer used to differ.
- **Title.** The application's name and nothing else. The title is
  published to the Window menu, Mission Control and the system window
  list, none of which are covered by capture exclusion, so no page
  title or page content appears there (ADR-0033 Restoration).
- **Traffic light buttons.** Standard. The green button enters full
  screen; the yellow minimises to the Dock; the red closes the window
  (⇧⌘W closes the window; ⌘W is `page::Close` here and closes the
  window only in Settings, Send Feedback and About, which show no page;
  see Commands).
- **Minimize.** A miniaturized editor window is open for ownership and
  not on screen for the keyboard (`BackdropModel.editorWindowOpen`,
  `editorWindowOnScreen`). It keeps the page while the panel rests, so
  the resting card draws a glance of a page nobody can see, and no
  keys are sent to a window in the Dock: a rest in an active app hands
  the activation back instead (`restHandsBackActivation`), and the
  window reports its own keys on its way out of the Dock. The two facts
  are kept apart because ADR-0033 keeps them apart: the owner is
  resolved from open and closed, and the rule that the deactivation on
  rest does not fire is stated for a visible editor window.
- **Frame autosave.** The window keeps `setFrameAutosaveName`. Nothing
  else about the window's identity is restored.
- **`isRestorable = false`.** AppKit's Saved Application State writes
  window state and snapshots that ADR-0012's persistence model has no
  place for, so restoration is off (ADR-0033 Restoration).
- **`sharingType = .none`** under the same capture opt out the panel
  observes; togglable to `.readOnly` under the same rule that governs
  the panel's screen sharing gate.
- **Space membership.** Ordinary. The editor window belongs to the
  desktop it was opened on, and ⌘Tab from another desktop carries the
  person to that desktop as it does for any document application. This
  is not issue #74 returning: the ADR records it as expected, and the
  panel's `.canJoinAllSpaces` membership stands for the panel alone
  (ADR-0033 Consequences).
- **Full screen.** AppKit's rules govern entering and leaving full
  screen. The editor window enters and leaves full screen from the
  green traffic light or the View menu's Enter Full Screen item. The
  app's keymap has no full screen command. The hand check for this
  lives in [`docs/qa/verification-procedures/spaces-and-cmd-tab.md`](../../../qa/verification-procedures/spaces-and-cmd-tab.md).

## Ownership as the person sees it

Ownership is explicit, exclusive and transferable. The rule is a
function of two facts: the panel owns while it is raised or while the
editor window is closed, and the editor window owns otherwise. The
rule the person sees:

- With the editor window closed, the panel owns whether resting or
  raised. Everything works as it does today.
- A summon (the hotkey, the status item, a click on the resting card)
  raises the panel and gives it ownership. If the editor window is
  open, it shows a glance while the summon is up.
- The editor window taking the keyboard rests a raised panel and
  brings ownership back to the editor window.
- The panel resting while the editor window is open returns
  ownership to the editor window; the keyboard returns with it only
  if the application is active.

The panel may edit while it owns. A read only panel is a policy
restriction on the same model (never grant the panel ownership), not a
different architecture; the ownership model is built transferable
either way. The model already takes that policy as one input
(`BackdropModel.panelMayOwn`, which only tests set), but shipping it
as a setting is more than a switch. The code names three gaps: Esc
does not reach a panel that never owns, the hotkey would only ever
raise such a panel and never put it away, and a raised card would stay
raised beside an editor window the person has gone to type in.

Key status passing to Settings, About, a modal panel or another
application moves nothing. Ownership follows only the two content
windows.

## The hand off gesture, as a person sees it

The person does not name a window as they type. They type into the
window with the keyboard, and where the keyboard is decides where the
hand off has already run. Concretely:

- **From panel to editor.** Use Open in Window, the header's expand control, or a Dock reopen when no ordinary window is visible. A person's initial foreground open also selects the editor. With the ambient panel off, the hotkey and status item select it. Cmd-Tab leaves focus to AppKit and does not change presentation. The explicit switch closes the panel's editing presentation before the editor takes the keyboard (ADR-0036). The editor shows the same page at the caret and scroll position left in the panel; both presentations use the model's existing page and view state.
- **From editor to panel.** Summon the panel (⌃⌥Space, the status
  item, a click on the resting card). The editor window drops out of
  key without closing; the panel takes the keys. Typing lands in the
  panel until it rests.
- **Rest the panel.** The keys go back to the editor window if it is
  open, on screen and the application is active; if the app is not
  active, nothing takes the keys and the panel is simply down. If the
  window is in the Dock, the rest hands the activation back and the
  window takes the keys on its way out.
- **Close the editor window (⇧⌘W).** The panel owns, resting or
  raised, and the activation is handed back to the app the person was
  in if no other window of ours can take keys.

Caret and scroll live on the model rather than the coordinator, so a
hand off keeps the person's place. Undo is the core's stack and
survives a hand off untouched.

## The glance

The window that does not own shows a **glance** and nothing editable:
a rendering built from `PageModel.QuietRendering`'s private storages,
the same pattern ADR-0020 uses for the roll's quiet days. A glance
never mounts an editor on a live storage, read only or otherwise;
ADR-0006's one layout manager per storage rule stands, and the glance
is why the rule survived the two window design without reopening
ADR-0006.

- **The resting card as a glance while the editor owns.** The card
  keeps its resting stance and its ambient posture; what it draws is
  the glance of the editor's page. The card's interaction does not
  change: it refuses the keyboard, lets the mouse through while
  unpinned, and takes a click as a summon while pinned. The redraw
  cadence does change, because it belongs to the owner: while the
  editor window is open and owns, the countdowns redraw every second
  (`BackdropModel.retime`), not on the resting card's 30 s tick.
- **The editor window as a glance while a summoned panel owns.** The
  editor window keeps its window chrome and its participation, and
  its content area draws the panel's glance. A press on the editor
  window's content while the panel owns hands ownership back to the
  editor window.

## Preference: the ambient panel

The ambient panel is a **persistent preference, default on**. It is
not a transient mode. Turning it off leaves the primary editor window
as the app's only window; the hotkey and the status item select the
editor window under that setting.

The preference sits behind a code boundary that lets the panel be
removed without touching the editor window or the shared document
model. The preference is local window state beside Pin and geometry,
as ADR-0032's keep above preference is; it never enters the page
model, the core, the state file or the sync protocol.

ADR-0033 leaves whether the panel keeps its editing role to the
dogfood evidence its first three eject triggers name. That the
preference helps gather some of that evidence, since a person who
turns the panel off is one sign that it is not used, is this spec's
reading and not something the ADR says.

## Commands, menus and keys

- **Model commands** act on the shared model from either window: new
  page, close page, select, open, save, Settings, About.
- **First responder commands** belong to the owner's editor: text
  editing, find, cut, copy, paste, sealed paste, spell.
- **Menu enablement** reads the owner's editor, so a menu item cannot
  be enabled by one editor and answered by the other. While Settings,
  About or a modal panel holds the keyboard, enablement still reads
  the owner, which is today's behaviour with one window.
- **⌘W stays `page::Close`.** The page strip is a tab strip, and
  Safari and Terminal close the tab on ⌘W.
  Note, 2026-10-21 (issue #201): ⌘W closes what the key window shows.
  While the panel, its key relay or the editor window is key it stays
  `page::Close`. While Settings, About or Send Feedback is key there is
  no page target, and the chord sends `performClose:` to that window;
  before, it beeped with a page showing and closed the file behind that
  window with a file showing. While a sheet, a save panel or an alert is
  key, or no window is, the File menu's item dims and the chord closes
  nothing, so for this item enablement does not read the owner.
- **⇧⌘W closes the window** (`window::Close`). ADR-0033 recorded
  that the default keymap left ⇧⌘W free; B5 bound it there
  (`"cmd-shift-w": "window::Close"` in
  `shell/Sources/CompanionKit/Resources/default-keymap.json`). The
  Window menu's Close Window item carries the chord, and a keymap
  override that unbinds it leaves the item in place without a
  shortcut.
- **The Window menu.** The editor window participates. The panel does
  not appear in the Window menu.
- **The Help menu.** The product's help item sits above the diagnostics
  items, first among the app's own (`app::Help`, issue #294), titled
  with the product name, on ⌘? from the keymap
  (`"cmd-?": "app::Help"`). It opens
  https://docs.onetimesecret.dev/macos in the browser through the
  model's external link route. A keymap override that unbinds the chord
  leaves the item without a shortcut. AppKit registers the Help menu
  when installing the application menus.

## Activation routing

[ADR-0059](../../../adr/0059-appkit-owns-window-presentation.md) governs these routes:

- **Initial foreground open:** AppKit's untitled-open event selects the editor as a summon, anchoring on today. It waits for model startup when necessary.
- **Ordinary activation and Cmd-Tab:** leave focus and window ordering to AppKit, without selecting a presentation or moving the roll.
- **Dock reopen:** delegates to AppKit when an ordinary window is visible. Otherwise it opens or deminiaturizes the editor without anchoring on today. The ambient panel is excluded from the visible-window check.
- **Background launch:** starts the configured ambient presentation without opening an editor.
- **Settings:** explicit commands open one AppKit Settings window. There is no SwiftUI Settings scene or window-attachment redirect.
- **A modal return and a cancelled quit** go back to the owner. A
  cancelled quit asks the routing table every time. A modal return is
  judged twice, and both readings agree: `modalSessionEnded` routes
  `.modalReturn` a turn after the modal is over, but only over a
  raised panel, which always owns, so what it does is raise that
  panel again; and the key turn itself (`BackdropModel.keyTurn`)
  reads an editor window keyed on the way back from Settings, About
  or a modal as a return and not as a claim, so a raised, owning panel
  is keyed again instead of rested and the page does not move. Over
  an owning editor window no route runs, and the keyboard comes back
  to it by AppKit's own key restoration.
- **`NSApp.deactivate()` on panel rest** does not fire while the
  editor window is visible; the keys return to the editor window
  instead.
- **The hotkey, the status item and the resting card click** stay
  with the panel and do not activate the app while the ambient panel
  is on. With it off, the hotkey and the status item open the editor
  window as an activation, without anchoring the roll.

## Restoration and persistence

The editor window carries no state of its own beyond its frame. The
document model, page storages, the core's Loro CRDT documents and the
sealed state file are all singular per install and window agnostic.
The panel's persistence and Keychain scope stand unchanged (ADR-0004,
ADR-0012, ADR-0016).

Closing the editor window does not quit the application. With the
panel preference on, the app keeps running as the ambient surface;
with the panel off, closing the editor window follows AppKit's usual
document application idiom for a person launched app.

## Out of scope

- **The two live presentations of one page.** Not available under
  ADR-0006 without reopening it. If a supported requirement ever needs
  the same page live in both windows at once, a new ADR reopens
  ADR-0006 (eject trigger 5 below).
- **Visual chrome and typography of the editor window's content
  area.** This spec fixes the window role, not what the page looks
  like inside it. Chrome, typography and page affordances are the
  page level, and are covered by the existing feature specs
  (`textarea`, `block-revisions`, `lists-and-highlighting`, `sealed-content`).
- **The ambient panel's final interaction affordances.** The panel's
  editing role, its glance-only variant and its removal are dogfood
  questions, not design work this spec settles.
- **Multiple editor windows.** Out of scope; the editor window is
  singular. Reopening this belongs to a future ADR.

## Eject triggers

These are ADR-0033's eject triggers, quoted from its Eject triggers
section. The ADR lists them as bullets; the numbers are this spec's,
for reference. They are the conditions under which this spec would be
reopened rather than adjusted.

1. > Dogfood evidence shows that the ambient surface is not used once a
   > conventional editor exists; remove the second surface and retain only the
   > primary window.
2. > Dogfood evidence shows that the conventional editor is not used and that the
   > product is understood and preferred as an ambient utility; reject or
   > supersede this decision in favour of the single-panel architecture.
3. > Dogfood evidence shows that the panel is summoned to read and not to type;
   > restrict it to a glance by policy and keep the ownership model.
4. > Exclusive ownership produces recurring hand off defects (a lost caret or
   > scroll position, a stale glance, a window left without an owner, a command
   > answered by the wrong window) that cannot be removed behind the one ownership
   > model; restrict the panel to a glance first, and reconsider two windows only
   > if the defects survive that.
5. > A supported requirement needs the same page live in both windows at once.
   > That reopens ADR-0006 and needs its own ADR.
6. > A future AppKit API supplies one supported window role that can change between
   > conventional primary-window and nonactivating ambient semantics without
   > recreating either behavior manually; reassess the two-window boundary.

## References

- Structure decision:
  [ADR-0033](../../../adr/0033-separate-the-primary-editor-from-the-ambient-panel.md).
- Sibling spec: [background-surface](../background-surface/README.md).
- Implementation sequence:
  [`docs/plans/window-roles.md`](../../../plans/window-roles.md),
  Track B.
- Hardware procedures:
  [`docs/qa/verification-procedures/spaces-and-cmd-tab.md`](../../../qa/verification-procedures/spaces-and-cmd-tab.md)
  covers ⌘Tab, Spaces, full screen, Stage Manager and Mission Control
  for both windows.
