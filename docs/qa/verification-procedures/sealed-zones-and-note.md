# Sealed controls and the note: what the pointer and the raised card do

**Applies to:** OnetimePad, the raised card and the editor window; a
sealed object's explicit controls and its note.
**Raised by:** issues #244 and #246 on `feature/editing-seals`,
2026-10-13.
**Governs:** [Law 0001](../../law/0001-sealed-object.md), whose control and
note rows cite this procedure for what the runner cannot drive.
**Owner:** delano.
**Status:** open. Not yet run on hardware.

## Why by hand

`SealedBlockTests`, `SealedCapsuleTests`, `SealedMoveHandleTests` and
`SealedNoteTests` cover geometry, synthetic pointer actions and note routes.
Hardware checks cover the appearance, VoiceOver navigation and real pointer
behavior in a key window. The [2026-10-31 revision](../../spec/design/2026-1031-sealed-content-ux-revision.md)
replaces the former text zones. These checks remain unperformed.

Use synthetic data in a dedicated fixture with a temporary state directory
and an in-memory credential client. Automated fixtures use
`PageModel.Seams(stateDirectory:client:)`; the test setup follows [AGENTS.md](../../../AGENTS.md).

## Checks

- [ ] **Explicit controls under the pointer.** Seal a synthetic line and
      choose Set Variable Name… to name it `MY_API_KEY`. Move the pointer
      across the identity, Move, Copy decrypted and More. **Pass:** single
      and repeated identity clicks select; the text has no copy zones. Copy
      decrypted clicks once to copy, drags outward, and has help naming both
      actions. More remains visible at narrow widths. **Fail:** a text click
      copies, prior hover changes its meaning, or More has no visible target.
- [ ] **Copy feedback and Note.** Add a note, then click Copy decrypted.
      **Pass:** the control briefly reads Copied, the Note action remains
      visible, and feedback returns to rest, including with Reduce Motion.
      **Fail:** feedback obscures Note, overlaps identity, persists or
      acknowledges another object.
- [ ] **The note on the raised card.** Raise the card, open the
      object's menu and choose *Add Note…*, then type a line and click
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
      the page becomes a sealed block (Law 0001, note and naming rows).
      **Fail:** the word
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
      (ADR-0023, ADR-0044); the word lands in the note at its caret and
      the page is unchanged. **Fail:** the note reads as plain text, the
      list does not continue, a plain click opens the link, or the paste
      lands on the page.
- [ ] **VoiceOver reads identity and explicit actions.** In the fixture,
      navigate named and unnamed objects with VoiceOver and the arrow keys.
      **Pass:** the summary identifies the name, existing excerpt, size and
      note presence. Copy/More/Note controls have useful names and their press
      actions target that object after text is inserted before it. Native text
      selection and Cut/Paste provide movement; the pointer Move handle adds
      no duplicate accessibility child. **Fail:** controls are unnamed, target
      another object or read beyond the permitted face. Record actual
      VoiceOver navigation separately from the existing keyboard regression.
- [ ] **Visible sealing consequence.** Open the selection's context menu with
      VoiceOver. **Pass:** the native noninteractive header before Seal
      Selection on macOS 14+, or informational fallback on macOS 13, conveys
      that sealing cannot be undone; the explanation is not tooltip-only.
      **Fail:** it is presented as another actionable command or is missed
      during the tested assistive-technology navigation.
- [ ] **A named image.** Seal a synthetic image and choose Set Variable
      Name… to enter `LOGO`. **Pass:** identity reads `LOGO · <excerpt>`;
      clicking it selects; the menu offers Copy Variable Name and omits
      Copy NAME=Value (Unquoted). **Fail:** the image offers assignment copy
      or its identity text acts as a copy control.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one that failed.

| Date | Machine and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | explicit controls under the pointer | | |
| | | copy feedback and Note | | record Reduce Motion on and off |
| | | the note on the raised card | | |
| | | expand, contract, close | | |
| | | the note's undo is its own | | |
| | | scrolling and a narrow card | | |
| | | a drop from another app | | |
| | | the page's own surface in the note | | |
| | | VoiceOver reads identity and explicit actions | | record the macOS version |
| | | a named image | | |
| | | visible sealing consequence | | record macOS version and VoiceOver navigation |
