# Rename in place: the SwiftUI fields and the keyboard's way back

**Applies to:** OnetimePad, panel and editor window; the gutter
(Timeline), the strip (Tabs), the Pads tab of Settings and a sealed
object's name.
**Raised by:** review of epic 252 Track A (issues #248, #249, #250) on
`feature/editing-seals`, 2026-10-13; the sealed name's checks by issue
#245.
**Governs:** [Law 0007](../../law/0007-edit-in-place.md), whose strip,
pad and sealed name rows cite this procedure for what the runner
cannot drive.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Why by hand

The strip's field and the pad row's field are SwiftUI `TextField`s.
Their state lives in `TabRename.Field` and `PadRename`, which the tests
drive, but focus, the selection on focus, and what Return and Escape do
to focus happen inside SwiftUI and AppKit, and the test runner turns no
event loop for them. The gutter's
field is AppKit and is driven by `DayScrollTests`; the checks below
that touch it are about a real key window, which the tests do not
have. A sealed object's name field is AppKit too, driven by
`SealedNameFieldTests`; its checks cover the explicit opening action,
local validation and keys in a real key window. The slot rail, which no layout drew
since ADR-0037, is deleted (issue 275), so it has no check here.

Use synthetic data in a dedicated fixture with a temporary state directory
and an in-memory credential client. Automated fixtures use
`PageModel.Seams(stateDirectory:client:)`; the test setup follows [AGENTS.md](../../../AGENTS.md).

## Checks

The New Pad cases below distinguish the shared form's native test fixture
from the complete card, editor toolbar and Settings integrations. The fixture
uses `isolatedModel(defaults:)`, a temporary state directory and an in-memory
credential client, then mounts the shared form in its own native window.

The final local focused run at 2026-11-04 01:36:07 UTC passed 50 New Pad
tests: 38 `PadPickerTests` and twelve `PadCreateFormTests`, with zero failures.
`/private/tmp/pr343-production-route-tests.log` is an ephemeral execution artifact.
The [shell CI job on head 7082889a](https://github.com/onetimesecret/macos/actions/runs/41753269711/job/126323252468)
failed in two initial-click fixture cases; the other ten native and all 38 picker
cases passed. The final component fixture opens through production
`PadSettingsRoutes.beginCreating()` on a stable unconditional presenter; a separate
conditional surface tests removal/restoration. Entry-click and OS-activation
coverage remain manual. Product code is unchanged; next-head CI is pending.
Both representative panel cases have passed; actual production-controller handoff,
VoiceOver speech and pointer-caret behavior remain separate manual observations.
Earlier broader local failures and the removed insensitive caret test remain in
the ledger. Native fixture coverage is:

| Fixture interaction | Test |
| --- | --- |
| Focus and valid Return create a pad | `testNativeNameFieldFocusAndReturnCreateThePad` |
| Empty Return explains the refusal and keeps the form open | `testNativeEmptyReturnExplainsTheMissingNameWithoutDismissing` |
| Field-focused Escape clears the draft and dismisses | `testNativeEscapeClearsTheDraftAndDismissesTheForm` |
| Representative raised-card panel focus and Return create a pad | `testRepresentativeRaisedCardPanelFocusAndReturnCreateThePad` |
| Representative card rest dismisses the form and retains its draft for reopening | `testRepresentativeCardRestDismissesTheNativeFormAndRetainsItsDraft` |
| Outside dismissal retains the draft; reopening selects it whole | `testNativeOutsideDismissalRetainsTheDraftForReopening` |
| Disabling the presenter dismisses; reopening restores the draft | `testDisablingThePresenterDismissesTheFormAndRetainsItsDraft` |
| Clicking the anchor closes the existing form without reopening | `testNativeAnchorClickClosesTheExistingForm` |
| Closing the presenter hides the form and releases shortcut suppression | `testClosingThePresenterWindowDismissesAndUnregistersTheNativeForm` |
| Removing the presenter host hides the form and releases shortcut suppression | `testRemovingThePresenterHostDismissesAndUnregistersTheNativeForm` |
| A presented shared form suspends pad digits after its name field resigns focus | `testNativeFormSuspendsPadShortcutsAfterTheNameFieldResignsFocus` |
| Conditional presenter removal preserves the draft; restoring the control does not reopen the form | `testRemovingAndRestoringThePresenterDoesNotReopenTheNativeForm` |

The checkboxes remain open for the actual app entry surfaces, full Cancel
click, button-focused Escape, card-to-toolbar focus handoff, app-deactivation
routing, VoiceOver and long-message geometry in both appearances. A removed
experimental geometry observer did not provide reliable text bounds; it is
not evidence of clipping or successful pixel layout.

- [ ] **New Pad, anchored creation.** Open New Pad from the pad switcher
      in both the card and editor window, then from the Pads tab in Settings.
      **Pass:** a compact form opens below the initiating control without
      dimming the editor; the name field receives focus. Blank, whitespace-only
      and overlong names cannot be created. A valid Return or Create Pad
      creates and activates the named pad. Escape and Cancel close the form
      without creating a pad and clear the draft. Clicking outside closes it;
      reopening restores the draft. Repeat at the minimum window size and in
      light and dark appearances. **Fail:** a centered sheet opens, focus goes
      to the page while typing, a pad shortcut switches the pad from the name
      field, or the form's controls or validation text are clipped.
- [ ] **New Pad, retained draft and focus.** In each presentation, type a
      synthetic name, click outside the form, then reopen it. **Pass:** the
      draft returns, receives focus and is selected whole so typing replaces
      it. Repeat after explicit Cancel and Escape; those openings start blank.
      **Fail:** automatic dismissal loses the draft, selection is partial, or
      explicit cancellation leaves the cancelled draft behind.
- [ ] **New Pad, rest and app deactivation.** Open the form on the raised
      card, type a draft, then rest the card or activate another app. Record
      whether the form dismisses or remains visible. **Pass:** no visible form
      becomes unusable; if it remains, its field and Cancel/Create Pad controls
      remain operable. If it dismisses automatically, reopening retains the
      draft. **Fail:** a visible disabled form remains, or reopening loses the
      automatically dismissed draft. The initial native fixture reproduced a
      visible form with a disabled name field. Its regression now verifies
      passive dismissal and draft restoration after re-enabling. The actual
      card-rest and app-deactivation routes remain manual checks.
- [ ] **New Pad, Settings anchor.** Open the form from New Pad in Settings
      and click that same button again. Record the mouse-down and mouse-up
      result. **Pass:** the form closes once without immediately reopening or
      flickering. **Fail:** the anchor action presents it again after outside
      dismissal. Repeat after typing a retained draft.
- [ ] **New Pad, picker anchor and menu.** On the card and editor toolbar,
      open New Pad through the pad menu, type a synthetic draft, then click the
      pad picker anchor again. Record whether the first click only dismisses the
      form or also opens the NSMenu, and repeat the click. **Pass:** presentation
      ends coherently, any menu opens once and remains usable, and explicit New
      Pad reopening restores the retained draft. **Fail:** a stale or duplicate
      form/menu remains, a pad changes unexpectedly, or the draft is discarded.
- [ ] **New Pad, longest validation message.** At minimum window width in
      both appearances, press Return on an empty name, enter an overlong name,
      then use a synthetic pending-file-close fixture to show `pad.name.failed`.
      **Pass:** each complete message and both buttons fit; no text or control
      is clipped as the message changes. **Fail:** text is truncated, overlaps
      a control, or extends beyond the popover.
- [ ] **New Pad, Escape route.** Press Escape first with the field focused
      and then with a button focused. **Pass:** the form closes and reopening
      starts blank in both cases. Record whether the explicit cancellation
      action or the native popover dismissal ended each presentation.
      **Fail:** either route behaves like automatic draft-retaining dismissal.
- [ ] **New Pad, suspended pad digits.** In each entry surface, open the form
      and press pad-owned Command-digit shortcuts with the name field focused,
      then move focus to Cancel or Create Pad and repeat. **Pass:** while the form
      is visible, a reserved digit changes neither pad nor selected page. After
      dismissal, an unrelated rename/search field keeps its prior configured pad
      route. A modal session or attached sheet takes precedence and receives the
      event unchanged. Verify remapped and explicitly unbound chords separately.
      **Fail:** the visible form permits a pad/page change, an unrelated field
      alone suppresses the prior pad route, or the native modal route is swallowed.
- [ ] **New Pad, click caret after refocus.** Open a retained synthetic draft
      and verify initial whole-draft selection. Move focus to a form button,
      then click within the name. **Pass:** the click's caret position remains
      after the event loop settles. **Fail:** deferred select-all replaces it.
- [ ] **New Pad, spoken labels and feedback.** With VoiceOver, navigate through
      the caption, name field, validation message and buttons. Trigger empty-name
      feedback from the field and separately with a button focused. Record
      whether the message is spoken and whether button-focused Return supplies
      feedback; do not infer speech from the accessibility label alone.
      **Pass:** the field has a clear name without a redundant caption stop,
      and observed feedback behavior is recorded for both focus routes.
- [ ] **Gutter, a click on the time.** *Timeline.* Click a page's time
      in its gutter. **Pass:** a field opens where the time stood, on
      the time, selected whole, and typing replaces it; the time moves
      to the field's right as the draft grows. Return over a new
      label reads `today · <label> · <time>`. Click the label: the
      field opens on the label. **Fail:** the click focuses the page,
      the draft is not selected, or the time is hidden or clipped.
- [ ] **Gutter, the keys come back to the page.** *Timeline.* With the
      caret in the page, click one page's time, then another page's
      time, then press Escape and type a character. Repeat ending with
      Return. **Pass:** the first field closes as the second opens, and
      the character lands in the page after either ending. **Fail:**
      the character lands in a gutter, or nothing receives it.
- [ ] **Strip, the field selects whole.** *Tabs.* Choose *Rename Tab*
      from a tab's menu. **Pass:** the field opens in the tab on its
      title, selected whole, and typing replaces it. Escape leaves the
      title as it was; a double click on a tab still holds the clock.
      **Fail:** the caret lands at the end with nothing selected, or
      the double click opens the field.
- [ ] **Pad row, opening.** Choose *Manage Pads…* from the pad
      switcher's menu, then *Rename* from a pad row's `⋯` menu in the
      Pads tab. **Pass:** Settings opens on the Pads tab, and the pad's
      name becomes a field in its own row, selected whole; no sheet
      appears. **Fail:** a sheet or a panel asks for the name, or
      Settings opens on another tab.
- [ ] **Pad row, an empty Return.** In the open field, delete the name
      and press Return. **Pass:** "Enter a pad name." appears under the
      field in the row, and the field stays open with the keys in it;
      typing a name the pad can take clears it, and Return renames.
      **Fail:** the field closes, the keys leave it, or the refusal is
      said only under a page.
- [ ] **Pad row, Escape.** Open the field, type a new name and press
      Escape. **Pass:** the pad keeps its old name. **Fail:** the new
      name is saved.
- [ ] **The page's keys stand aside for every field.** On a page, type
      `let key = 1` and select it. Open in
      turn the gutter's field (*Timeline*) and the strip's field
      (*Tabs*), and in each type two letters, press ⌘Z,
      ⇧⌘V and ⌘↩, then open the Edit menu. **Pass:** ⌘Z takes back the
      field's letters and nothing on the page; ⇧⌘V and ⌘↩ seal nothing;
      in the Edit menu Seal Selected Content, Detect Code Language,
      Choose Language and Paste Without Detection are greyed while the
      field holds the keys, and come back once it closes (Law 0007,
      keys row).
      **Fail:** the page steps back or seals, or a greyed item is
      enabled and acts on the page.
- [ ] **Sealed variable name, explicit opening and endings.** Seal a
      synthetic line and choose Set Variable Name…. **Pass:** the inline field
      opens selected whole, with an API_KEY example, format guidance and
      Save/Cancel controls. Single and repeated identity clicks select rather
      than copy or rename. Return, Save, a valid blur, a pad switch and an
      editor handoff save the draft; Escape and Cancel discard it. **Fail:** a
      valid draft disappears on navigation, a text click copies, or the helper
      instructions and buttons overlap at a narrow width.
- [ ] **Sealed variable name, local refusal and keys.** Enter `my.key`
      and press Return, then click outside. **Pass:** the draft stays open
      with an error beside it; the page's Undo remains separate. Entering
      `MY_KEY` clears the error and Return saves. Teardown closes an invalid
      remainder; removing the source does not rename another object.
      **Fail:** the error appears only in the footer, a normal blur discards
      the invalid draft, or the page changes under field Undo.

## Results

The app-surface hand checks have not yet run. Native fixture coverage is
recorded separately above. One row per check when a hand session runs it;
a re-run adds a row rather than replacing one that failed.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | New Pad, retained draft and focus | | all three presentations |
| | | New Pad, rest and app deactivation | | record dismissal or continued operability |
| | | New Pad, Settings anchor | | record mouse-down and mouse-up result |
| | | New Pad, longest validation message | | minimum width; both appearances |
| | | New Pad, Escape route | | field focus and button focus; actual ending route |
| | | New Pad, anchored creation | | card, editor window and Settings; both appearances |
| | | gutter, a click on the time | | |
| | | gutter, the keys come back to the page | | |
| | | strip, the field selects whole | | |
| | | pad row, opening | | |
| | | pad row, an empty Return | | |
| | | pad row, Escape | | |
| | | the page's keys stand aside for every field | | record each of the two fields |
| | | sealed variable name, explicit opening and endings | | |
| | | sealed variable name, local refusal and keys | | |
