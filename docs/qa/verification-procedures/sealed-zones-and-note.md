# Sealed zones and the note: what the pointer and the raised card do

**Applies to:** OnetimePad, the raised card and the editor window; a
sealed object's bottom row and its note.
**Raised by:** issues #244 and #246 on `feature/editing-seals`,
2026-10-13.
**Governs:** [Law 0001](../../law/0001-sealed-object.md), whose zone and
note rows cite this procedure for what the runner cannot drive.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Why by hand

`SealedBlockTests`, `SealedCapsuleTests` and `SealedNoteTests` drive the
zones' geometry, their clicks through `mouseDown`, the note's routes and
its open and close routes against an offscreen window. They cannot see
the pill follow a real pointer, the beat fade on a display, or what the
raised card's outside click monitor and key handling do around a note
that takes the keys in a real key window. The note is drawn inside the
card's own window, so a press in it should never reach the monitor,
which sees only presses in other apps; that is the claim to check.

Quit any running instance first (`swift build` re-signs in place and
SIGKILLs a live one), then `scripts/dev.sh`.

## Checks

- [ ] **Zones under the pointer.** Seal a line with ⌘↩, name it
      `MY_API_KEY`, then move the pointer across the bottom row.
      **Pass:** a pill sits under the name, under the whole line over
      `=`, and under the excerpt, and the seat reads `copies the name`,
      `copies name=value, decrypted` and `copies the value, decrypted`
      in turn; nothing on the row moves. **Fail:** the row shifts, the
      seat's words overrun the excerpt, or a pill lingers after the
      pointer leaves.
- [ ] **The beat.** Click the excerpt once. **Pass:** the excerpt's
      pill wears ember for about a second while the seat reads
      `copied`, then the row rests; with Reduce Motion on, the ember
      comes and goes without a fade. The line under the page says what
      was copied. **Fail:** the beat sticks, flickers, or lights
      another block.
- [ ] **The note on the raised card.** Raise the card, open the
      object's menu and choose *Note…*, then type a line and click
      inside the note twice. **Pass:** the note opens under the block
      with its arrow under the seat, the keys are in it, and the card
      stays raised through both clicks. **Fail:** a click in the note
      rests the card, or the keys stay in the page.
- [ ] **Expand, contract, close.** In the open note press ⇧Esc, then
      Esc, then Esc. **Pass:** the note grows to the card's content
      area, comes back under the block, then closes, and a character
      typed next lands in the page at the caret it had before the note
      opened. Repeat with the arrows at the note's bottom right.
      **Fail:** Esc closes an expanded note outright, or the page's
      caret moved.
- [ ] **The note's undo is its own.** Type in the page, open the note,
      type in it, press ⌘Z twice, close it, press ⌘Z. **Pass:** the
      two ⌘Z in the note take back the note's typing only; the ⌘Z
      after closing takes back the page's. **Fail:** either reaches the
      other's text.
- [ ] **Scrolling and a narrow card.** With the note open, scroll the
      page, then narrow the card to its least width. **Pass:** the note
      stays under its block as the page scrolls, and on the narrow card
      it spans the card's content width. **Fail:** the note stays where
      it was while the block scrolls away, or it overhangs the card.
- [ ] **A drop from another app.** Select a word in TextEdit. With the
      note open, drag the word onto the note's text, then onto the page
      below the note. Then open the name field on a block and drag the
      word onto the field. **Pass:** the cursor offers nothing over the
      note or the field and nothing lands in either, while the drop on
      the page becomes a sealed block (ADR-0044). **Fail:** the word
      appears in the note or the field, or the drop on the page lands
      as plain ink.
- [ ] **The page's own surface in the note.** Open a note and type
      `# Rotate`, Return, `- monthly`, Return, then
      `see https://example.com`, then a fence with ```` ```swift ````,
      a line of Swift and ```` ``` ````. Click the URL, then ⌘-click it.
      Copy a word in TextEdit and choose Edit, Paste Without Detection.
      **Pass:** the heading, the list's marker, the link and the fence's
      slab and colours read as the same lines would on the page; the
      Return after `- monthly` starts `- `; the plain click puts the
      caret in the URL and the ⌘-click opens it in the browser
      (ADR-0023, ADR-0045); the word lands in the note at its caret and
      the page is unchanged. **Fail:** the note reads as plain text, the
      list does not continue, a plain click opens the link, or the paste
      lands on the page.
- [ ] **VoiceOver reads the block inside the page.** Turn VoiceOver on
      (⌘F5), put the caret in a page holding a sealed block named
      `MY_API_KEY` and an unnamed one, and move the VoiceOver cursor
      through the page's text with VO-Right and the arrow keys.
      **Pass:** on each block VoiceOver says `sealed content`, then the
      name where there is one, then the size class, as
      `sealed content, MY_API_KEY, small`, and never the block's
      plaintext or excerpt. **Fail:** VoiceOver says nothing on the
      block, reads an attachment character, or reads its contents.
- [ ] **A named image.** Copy an image in Preview and press ⇧⌘V on the
      page, then choose the block's *Name*, type `LOGO` and press
      Return, then move the pointer across `=` and
      open the object's menu. **Pass:** the row reads `LOGO=` and the
      image's excerpt, `=` shows no pill and the seat keeps its size
      class, and the menu has *Copy Name* but no *Copy Name=Value,
      Decrypted*. **Fail:** the seat offers name=value, or the menu
      item is there.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one that failed.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | zones under the pointer | | |
| | | the beat | | record Reduce Motion on and off |
| | | the note on the raised card | | |
| | | expand, contract, close | | |
| | | the note's undo is its own | | |
| | | scrolling and a narrow card | | |
| | | a drop from another app | | |
| | | the page's own surface in the note | | |
| | | VoiceOver reads the block inside the page | | record the macOS version |
| | | a named image | | |
