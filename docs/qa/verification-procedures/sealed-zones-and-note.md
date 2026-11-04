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
      note presence. C󠄁o󠄁p󠄁y󠄁/󠄁M󠄁o󠄁r󠄁e󠄁/󠄁N󠄁o󠄁t󠄁e󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁s󠄁 h󠄁a󠄁v󠄁e󠄁 u󠄁s󠄁e󠄁f󠄁u󠄁l󠄁 n󠄁a󠄁m󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 p󠄁r󠄁e󠄁s󠄁s󠄁
      a󠄁c󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 t󠄁a󠄁r󠄁g󠄁e󠄁t󠄁 t󠄁h󠄁a󠄁t󠄁 o󠄁b󠄁j󠄁e󠄁c󠄁t󠄁 a󠄁f󠄁t󠄁e󠄁r󠄁 t󠄁e󠄁x󠄁t󠄁 i󠄁s󠄁 i󠄁n󠄁s󠄁e󠄁r󠄁t󠄁e󠄁d󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 i󠄁t󠄁.󠄁 N󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 t󠄁e󠄁x󠄁t󠄁
      s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 C󠄁u󠄁t󠄁/󠄁P󠄁a󠄁s󠄁t󠄁e󠄁 p󠄁r󠄁o󠄁v󠄁i󠄁d󠄁e󠄁 m󠄁o󠄁v󠄁e󠄁m󠄁e󠄁n󠄁t󠄁;󠄁 t󠄁h󠄁e󠄁 p󠄁o󠄁i󠄁n󠄁t󠄁e󠄁r󠄁 M󠄁o󠄁v󠄁e󠄁 h󠄁a󠄁n󠄁d󠄁l󠄁e󠄁 a󠄁d󠄁d󠄁s󠄁
      n󠄁o󠄁 d󠄁u󠄁p󠄁l󠄁i󠄁c󠄁a󠄁t󠄁e󠄁 a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁i󠄁b󠄁i󠄁l󠄁i󠄁t󠄁y󠄁 c󠄁h󠄁i󠄁l󠄁d󠄁.󠄁 **F󠄁a󠄁i󠄁l󠄁:󠄁** c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁s󠄁 a󠄁r󠄁e󠄁 u󠄁n󠄁n󠄁a󠄁m󠄁e󠄁d󠄁,󠄁 t󠄁a󠄁r󠄁g󠄁e󠄁t󠄁
      a󠄁n󠄁o󠄁t󠄁h󠄁e󠄁r󠄁 o󠄁b󠄁j󠄁e󠄁c󠄁t󠄁 o󠄁r󠄁 r󠄁e󠄁a󠄁d󠄁 b󠄁e󠄁y󠄁o󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 p󠄁e󠄁r󠄁m󠄁i󠄁t󠄁t󠄁e󠄁d󠄁 f󠄁a󠄁c󠄁e󠄁.󠄁 R󠄁e󠄁c󠄁o󠄁r󠄁d󠄁 a󠄁c󠄁t󠄁u󠄁a󠄁l󠄁
      V󠄁o󠄁i󠄁c󠄁e󠄁O󠄁v󠄁e󠄁r󠄁 n󠄁a󠄁v󠄁i󠄁g󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁l󠄁y󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 k󠄁e󠄁y󠄁b󠄁o󠄁a󠄁r󠄁d󠄁 r󠄁e󠄁g󠄁r󠄁e󠄁s󠄁s󠄁i󠄁o󠄁n󠄁.󠄁
- [ ] **V󠄁i󠄁s󠄁i󠄁b󠄁l󠄁e󠄁 s󠄁e󠄁a󠄁l󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁s󠄁e󠄁q󠄁u󠄁e󠄁n󠄁c󠄁e󠄁.󠄁** O󠄁p󠄁e󠄁n󠄁 t󠄁h󠄁e󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁'󠄁s󠄁 c󠄁o󠄁n󠄁t󠄁e󠄁x󠄁t󠄁 m󠄁e󠄁n󠄁u󠄁 w󠄁i󠄁t󠄁h󠄁
      V󠄁o󠄁i󠄁c󠄁e󠄁O󠄁v󠄁e󠄁r󠄁.󠄁 **P󠄁a󠄁s󠄁s󠄁:󠄁** t󠄁h󠄁e󠄁 n󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 n󠄁o󠄁n󠄁i󠄁n󠄁t󠄁e󠄁r󠄁a󠄁c󠄁t󠄁i󠄁v󠄁e󠄁 h󠄁e󠄁a󠄁d󠄁e󠄁r󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 S󠄁e󠄁a󠄁l󠄁
      S󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 o󠄁n󠄁 m󠄁a󠄁c󠄁O󠄁S󠄁 1󠄁4󠄁+󠄁,󠄁 o󠄁r󠄁 i󠄁n󠄁f󠄁o󠄁r󠄁m󠄁a󠄁t󠄁i󠄁o󠄁n󠄁a󠄁l󠄁 f󠄁a󠄁l󠄁l󠄁b󠄁a󠄁c󠄁k󠄁 o󠄁n󠄁 m󠄁a󠄁c󠄁O󠄁S󠄁 1󠄁3󠄁,󠄁 c󠄁o󠄁n󠄁v󠄁e󠄁y󠄁s󠄁
      t󠄁h󠄁a󠄁t󠄁 s󠄁e󠄁a󠄁l󠄁i󠄁n󠄁g󠄁 c󠄁a󠄁n󠄁n󠄁o󠄁t󠄁 b󠄁e󠄁 u󠄁n󠄁d󠄁o󠄁n󠄁e󠄁;󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁p󠄁l󠄁a󠄁n󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 i󠄁s󠄁 n󠄁o󠄁t󠄁 t󠄁o󠄁o󠄁l󠄁t󠄁i󠄁p󠄁-󠄁o󠄁n󠄁l󠄁y󠄁.󠄁
      **F󠄁a󠄁i󠄁l󠄁:󠄁** i󠄁t󠄁 i󠄁s󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁e󠄁d󠄁 a󠄁s󠄁 a󠄁n󠄁o󠄁t󠄁h󠄁e󠄁r󠄁 a󠄁c󠄁t󠄁i󠄁o󠄁n󠄁a󠄁b󠄁l󠄁e󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁 o󠄁r󠄁 i󠄁s󠄁 m󠄁i󠄁s󠄁s󠄁e󠄁d󠄁
      d󠄁u󠄁r󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 t󠄁e󠄁s󠄁t󠄁e󠄁d󠄁 a󠄁s󠄁s󠄁i󠄁s󠄁t󠄁i󠄁v󠄁e󠄁-󠄁t󠄁e󠄁c󠄁h󠄁n󠄁o󠄁l󠄁o󠄁g󠄁y󠄁 n󠄁a󠄁v󠄁i󠄁g󠄁a󠄁t󠄁i󠄁o󠄁n󠄁.󠄁
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
| | | v󠄁i󠄁s󠄁i󠄁b󠄁l󠄁e󠄁 s󠄁e󠄁a󠄁l󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁s󠄁e󠄁q󠄁u󠄁e󠄁n󠄁c󠄁e󠄁 | | r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁 m󠄁a󠄁c󠄁O󠄁S󠄁 v󠄁e󠄁r󠄁s󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 V󠄁o󠄁i󠄁c󠄁e󠄁O󠄁v󠄁e󠄁r󠄁 n󠄁a󠄁v󠄁i󠄁g󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 |
