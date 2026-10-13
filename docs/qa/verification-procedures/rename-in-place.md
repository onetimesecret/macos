# Rename in place: the SwiftUI fields and the keyboard's way back

**Applies to:** OnetimePad, panel and editor window; the gutter
(Timeline), the strip (Tabs), the pad list and a sealed object's name.
**Raised by:** review of epic 252 Track A (issues #248, #249, #250) on
`feature/editing-seals`, 2026-10-13; the sealed name's checks by issue
#245.
**Governs:** [Law 0007](../../law/0007-edit-in-place.md), whose strip,
pad and sealed name rows cite this procedure for what the runner
cannot drive.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Why by hand

The strip's field and the pad cell's field are SwiftUI `TextField`s.
Their state lives in `TabRename.Field` and `PadRename`, which the tests
drive, but focus, the selection on focus, what Return and Escape do to
focus, and what a popover does around them happen inside SwiftUI and
AppKit, and the test runner turns no event loop for them. The gutter's
field is AppKit and is driven by `DayScrollTests`; the checks below
that touch it are about a real key window, which the tests do not
have. A sealed object's name field is AppKit too, driven by
`SealedNameFieldTests`; its checks are the double click's timing and
the keys in a real key window. The slot rail is not drawn by any
layout since ADR-0037, so it has no check here.

Quit any running instance first (`swift build` re-signs in place and
SIGKILLs a live one), then `scripts/dev.sh`.

## Checks

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
- [ ] **Strip, the field selects whole.** *Tabs.* Choose *Rename tab…*
      from a tab's menu. **Pass:** the field opens in the tab on its
      title, selected whole, and typing replaces it. Escape leaves the
      title as it was; a double click on a tab still holds the clock.
      **Fail:** the caret lands at the end with nothing selected, or
      the double click opens the field.
- [ ] **Pad cell, opening.** Open the pad list and choose *Rename pad…*
      on a pad. **Pass:** the pad's name becomes a field in its own
      cell, selected whole, and the list stays open; no sheet appears.
      **Fail:** a sheet or a panel asks for the name, or the list
      closes.
- [ ] **Pad cell, an empty Return.** In the open field, delete the
      name and press Return. **Pass:** the line under the page reads
      "Enter a pad name.", the line is visible while the list is open,
      and the field stays open with the keys in it; typing a name the
      pad can take clears the line, and Return renames. **Fail:** the
      field closes, the keys leave it, or the line cannot be seen
      beside the list.
- [ ] **Pad cell, Escape.** Open the field, type a new name and press
      Escape. **Pass:** the pad keeps its old name. Record whether the
      list stays open or closes; either keeps the name. **Fail:** the
      new name is saved.
- [ ] **Sealed name, the double click.** Seal a line with ⌘↩, then
      double click the block's bottom row. **Pass:** a field opens where
      a name would stand, placeholder `NAME`, with the keys in it and
      the excerpt to its right. Type `MY_API_KEY` and press Return: the
      row reads `MY_API_KEY=<excerpt>`. Click the name once: the line
      reads `copied the name.`. Double click the name: the field opens
      on the name, selected whole. Double click the excerpt: the line
      says the decrypted contents were copied, once, and no field
      opens. **Fail:** a first click opens the field, a double click on
      the excerpt opens it or copies twice, or the draft is not
      selected.
- [ ] **Sealed name, a refusal and the keys.** Open the field, type
      `my.key` and press Return. **Pass:** the line under the page asks
      for letters A to Z, digits and underscores, the field stays open
      with the keys in it, and neither ⌘Z nor Edit → Undo from the menu
      bar changes anything on the page; typing
      `MY_KEY` clears the line and Return names the object. Then open
      the field again, press Escape and type a character. **Pass:** the
      name is unchanged and the character lands in the page. **Fail:**
      the field closes on the refusal, the page steps back, or the
      character goes nowhere.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one that failed.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | gutter, a click on the time | | |
| | | gutter, the keys come back to the page | | |
| | | strip, the field selects whole | | |
| | | pad cell, opening | | |
| | | pad cell, an empty Return | | |
| | | pad cell, Escape | | record whether the list stayed open |
| | | sealed name, the double click | | |
| | | sealed name, a refusal and the keys | | |
