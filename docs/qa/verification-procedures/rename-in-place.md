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

- [ ] **N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁,󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁.󠄁** O󠄁p󠄁e󠄁n󠄁 N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁d󠄁 s󠄁w󠄁i󠄁t󠄁c󠄁h󠄁e󠄁r󠄁
      i󠄁n󠄁 b󠄁o󠄁t󠄁h󠄁 t󠄁h󠄁e󠄁 c󠄁a󠄁r󠄁d󠄁 a󠄁n󠄁d󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁,󠄁 t󠄁h󠄁e󠄁n󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 P󠄁a󠄁d󠄁s󠄁 t󠄁a󠄁b󠄁 i󠄁n󠄁 S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁.󠄁
      **P󠄁a󠄁s󠄁s󠄁:󠄁** a󠄁 c󠄁o󠄁m󠄁p󠄁a󠄁c󠄁t󠄁 f󠄁o󠄁r󠄁m󠄁 o󠄁p󠄁e󠄁n󠄁s󠄁 b󠄁e󠄁l󠄁o󠄁w󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁i󠄁t󠄁i󠄁a󠄁t󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁 w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁
      d󠄁i󠄁m󠄁m󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁;󠄁 t󠄁h󠄁e󠄁 n󠄁a󠄁m󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁e󠄁s󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁.󠄁 B󠄁l󠄁a󠄁n󠄁k󠄁,󠄁 w󠄁h󠄁i󠄁t󠄁e󠄁s󠄁p󠄁a󠄁c󠄁e󠄁-󠄁o󠄁n󠄁l󠄁y󠄁
      a󠄁n󠄁d󠄁 o󠄁v󠄁e󠄁r󠄁l󠄁o󠄁n󠄁g󠄁 n󠄁a󠄁m󠄁e󠄁s󠄁 c󠄁a󠄁n󠄁n󠄁o󠄁t󠄁 b󠄁e󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁d󠄁.󠄁 A󠄁 v󠄁a󠄁l󠄁i󠄁d󠄁 R󠄁e󠄁t󠄁u󠄁r󠄁n󠄁 o󠄁r󠄁 C󠄁r󠄁e󠄁a󠄁t󠄁e󠄁 P󠄁a󠄁d󠄁
      c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁 a󠄁c󠄁t󠄁i󠄁v󠄁a󠄁t󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 n󠄁a󠄁m󠄁e󠄁d󠄁 p󠄁a󠄁d󠄁.󠄁 E󠄁s󠄁c󠄁a󠄁p󠄁e󠄁 a󠄁n󠄁d󠄁 C󠄁a󠄁n󠄁c󠄁e󠄁l󠄁 c󠄁l󠄁o󠄁s󠄁e󠄁 t󠄁h󠄁e󠄁 f󠄁o󠄁r󠄁m󠄁
      w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁n󠄁g󠄁 a󠄁 p󠄁a󠄁d󠄁 a󠄁n󠄁d󠄁 c󠄁l󠄁e󠄁a󠄁r󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁.󠄁 C󠄁l󠄁i󠄁c󠄁k󠄁i󠄁n󠄁g󠄁 o󠄁u󠄁t󠄁s󠄁i󠄁d󠄁e󠄁 c󠄁l󠄁o󠄁s󠄁e󠄁s󠄁 i󠄁t󠄁;󠄁
      r󠄁e󠄁o󠄁p󠄁e󠄁n󠄁i󠄁n󠄁g󠄁 r󠄁e󠄁s󠄁t󠄁o󠄁r󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁.󠄁 R󠄁e󠄁p󠄁e󠄁a󠄁t󠄁 a󠄁t󠄁 t󠄁h󠄁e󠄁 m󠄁i󠄁n󠄁i󠄁m󠄁u󠄁m󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 s󠄁i󠄁z󠄁e󠄁 a󠄁n󠄁d󠄁 i󠄁n󠄁
      l󠄁i󠄁g󠄁h󠄁t󠄁 a󠄁n󠄁d󠄁 d󠄁a󠄁r󠄁k󠄁 a󠄁p󠄁p󠄁e󠄁a󠄁r󠄁a󠄁n󠄁c󠄁e󠄁s󠄁.󠄁 **F󠄁a󠄁i󠄁l󠄁:󠄁** a󠄁 c󠄁e󠄁n󠄁t󠄁e󠄁r󠄁e󠄁d󠄁 s󠄁h󠄁e󠄁e󠄁t󠄁 o󠄁p󠄁e󠄁n󠄁s󠄁,󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁 g󠄁o󠄁e󠄁s󠄁
      t󠄁o󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁g󠄁e󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁y󠄁p󠄁i󠄁n󠄁g󠄁,󠄁 a󠄁 p󠄁a󠄁d󠄁 s󠄁h󠄁o󠄁r󠄁t󠄁c󠄁u󠄁t󠄁 s󠄁w󠄁i󠄁t󠄁c󠄁h󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁d󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 n󠄁a󠄁m󠄁e󠄁
      f󠄁i󠄁e󠄁l󠄁d󠄁,󠄁 o󠄁r󠄁 t󠄁h󠄁e󠄁 f󠄁o󠄁r󠄁m󠄁'󠄁s󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁s󠄁 o󠄁r󠄁 v󠄁a󠄁l󠄁i󠄁d󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 t󠄁e󠄁x󠄁t󠄁 a󠄁r󠄁e󠄁 c󠄁l󠄁i󠄁p󠄁p󠄁e󠄁d󠄁.󠄁
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

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one that failed.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | N󠄁e󠄁w󠄁 P󠄁a󠄁d󠄁,󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 | | c󠄁a󠄁r󠄁d󠄁,󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 a󠄁n󠄁d󠄁 S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁;󠄁 b󠄁o󠄁t󠄁h󠄁 a󠄁p󠄁p󠄁e󠄁a󠄁r󠄁a󠄁n󠄁c󠄁e󠄁s󠄁 |
| | | gutter, a click on the time | | |
| | | gutter, the keys come back to the page | | |
| | | strip, the field selects whole | | |
| | | pad row, opening | | |
| | | pad row, an empty Return | | |
| | | pad row, Escape | | |
| | | the page's keys stand aside for every field | | record each of the two fields |
| | | sealed variable name, explicit opening and endings | | |
| | | sealed variable name, local refusal and keys | | |
