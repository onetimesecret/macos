# The sealed fragment: what other apps and a real drag receive

**Applies to:** OnetimePad's copy, cut, paste and drags of a selection
holding a sealed object and a service's request for it, the decrypted
drag from its handle, and the
two presses that remove an object and the line's Undo after them.
**Raised by:** issues #170 and #247 on `feature/editing-seals`,
2026-10-13.
**Governs:** [Law 0001](../../law/0001-sealed-object.md), whose copy,
paste, drag and decrypted drag rows cite this procedure for what the
runner cannot drive; [ADR-0047](../../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md);
[ADR-0048](../../adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md);
[ADR-0050](../../adr/0050-a-decrypted-drag-lands-only-in-another-app.md);
[ADR-0051](../../adr/0051-the-decrypted-drag-handle-sits-before-the-actions-glyph.md).
**Owner:** delano.
**Status:** open; not yet run. The editor's copy and cut write the
fragment, its paste reads it, the slot's button places a cut, two
presses remove an object with Undo on the line, the page drags its
selection as the fragment, and the block's handle starts the decrypted
drag, so every check can run.

## Why by hand

The core and seam tests drive the envelope, its public text, every
resolution, and the decrypted drag's write into a pasteboard item made
in the test. They cannot see what another process receives: a paste in
TextEdit, a drop in a browser's form field, the lazy provider being
asked by a real destination, or what a clipboard manager archives.

Quit any running instance first (`swift build` re-signs in place and
SIGKILLs a live one), then `scripts/dev.sh`.

## Checks

- [ ] **Copy into another app.** Type `before`, seal a word with ⌘↩,
      type `after`, select all three and copy. Paste in TextEdit.
      **Pass:** TextEdit shows `before [sealed content · tiny] after`
      and nothing of the sealed word. **Fail:** the word, or any part
      of it, appears.
- [ ] **What the pasteboard holds.** After the copy above, run
      `osascript -e 'clipboard info'` in Terminal. **Pass:** it lists
      the plain text and `com.onetimesecret.onetimepad.sealed-fragment.debug`,
      and no other type carries the word. **Fail:** a rich text or other
      type carries it.
- [ ] **A service and Share over an object.** Select the same three
      again, then open OnetimePad > Services, and the Share submenu of
      the page's context menu over the ink. **Pass:** a service that
      takes text without answering, such as a new note or a web
      search, receives `before [sealed content · tiny] after`; no
      service that rewrites the selection in place, such as a case
      change, is offered; a Share destination receives the same text,
      or Share offers nothing. **Fail:** any service or Share
      destination receives the sealed word, or `￼` where the object
      stood, or a service rewrites the selection over the object.
- [ ] **Cut and paste in place.** Cut the selection, note the slot's
      line under the page, then paste further down. **Pass:** the line
      names the cut object by its face and goes when the paste lands;
      the object returns with its name, and ⌘Z takes the paste back.
      **Fail:** the line stays, or the object returns as a clone with
      a fresh face.
- [ ] **The slot's button on the raised card.** Name a sealed object,
      select it with some ink and cut with ⌘X. Switch to another page,
      put the caret at its end and click the slot's `place here`
      button under the page, then type a letter. **Pass:** the line
      named the object by its name and size class and showed nothing
      of the sealed word; the card stays raised through the click; the
      object and the ink land at the caret with the name; the line
      goes; the letter lands on the page; ⌘Z takes the place back.
      **Fail:** the card rests on the click, the letter goes to another
      app, or the line shows any part of the word.
- [ ] **A cut across a relaunch.** Cut a sealed object, quit with ⌘Q,
      relaunch, paste. **Pass:** the slot's line is back before the
      paste and the object returns. **Fail:** the paste places
      `[sealed content · unavailable]`.
- [ ] **A cut that outlives its page's deadline** (ADR-0048). On a one
      hour page, seal a word and cut it. Sleep the Mac for more than an
      hour, wake it, and paste onto another page at once. **Pass:** the
      paste places `[sealed content · expired]`, the first page's tab
      stands empty, the slot's line is gone, and the ledger shows the
      object expired. **Fail:** the object returns, or the first page
      still shows its ink after the paste.
- [ ] **A fragment pasted into a note.** Copy a sealed object with some
      ink, open another object's note and paste with ⌘V. **Pass:** the
      note shows the ink with `[sealed content · tiny]` where the object
      stood, and the page is unchanged. **Fail:** the note shows the
      sealed word or a block, or the paste lands on the page.
- [ ] **Two presses and the removal's Undo.** On the raised card, type
      `before`, seal a word, type `after`, put the caret just after the
      object and press ⌫ once. Press ⌫ again, then click the line's
      `Undo` button, then type a letter. **Pass:** the first ⌫ selects
      the object and removes nothing; the second removes it and the
      line under the page reads `protected content removed.` with
      `Undo`; the click keeps the card raised and stands the same
      object again, selected, with its face and name; the letter lands
      on the page. The same holds for ⌦ with the caret just before the
      object. **Fail:** one press removes the object, the line has no
      `Undo`, the card rests on the click, or the letter goes elsewhere.
- [ ] **The removal's Undo after the page moves on.** Remove an object
      with two presses, then type a letter before the line clears.
      **Pass:** the `Undo` button leaves the line at once, and ⌘Z
      takes the letter back first and the removal on the next press.
      **Fail:** the button stays, or pressing it takes the letter back.
- [ ] **A drag inside the page.** Name a sealed object and give it a
      note. Select `before`, the object and `after`, then drag the
      selection to the end of the page and drop it. **Pass:** while
      dragging, an insertion line shows where the run will land, and the
      drag image shows the block as the page draws it and nothing more
      of the sealed word; the run lands there with the object's name and
      note; ⌘Z puts the whole run back in one step. Dropping the
      selection onto itself changes nothing. **Fail:** no insertion
      line, the object returns without its name or note, the image
      shows more than the block does, or ⌘Z takes back only part of it.
- [ ] **A drag that starts on the object.** Click a sealed object once
      so it is selected, then drag it from its block and drop it lower
      on the page. **Pass:** the object moves with its name and nothing
      else changes. **Fail:** nothing drags, or the drop seals new
      content.
- [ ] **⌥ drag.** Select the object with some ink, start the drag, hold
      ⌥ and drop below. **Pass:** the cursor shows a copy, a copy of the
      run lands with the object's name, the original stays, and the
      ledger gains one `sealed`; ⌘Z takes the copy back. **Fail:** the
      original moves, or the copy lands as placeholder text.
- [ ] **A drag between pages.** Where two pages show at once (the
      editor window and the card), drag a selection holding an object
      from one page to the other (ADR-0054; needs issue 170's shell
      half to wire the drop). **Pass:** the run lands on the second
      page with the object's name and note, leaves the first, and the
      ledger gains no `sealed`; ⌘Z on the first page brings nothing
      back, and ⌘Z on the second takes the run off it. With ⌥ held, the
      first page keeps its run and the ledger gains one `sealed`.
      **Fail:** the drop seals the text `[sealed content · tiny]` as a
      new object, the first page keeps its run after a plain drop, or
      ⌘Z on the first page stands the object again.
- [ ] **Plain drag out.** Drag the selection into TextEdit, then drag it
      onto the Trash in the Dock. **Pass:** TextEdit receives the same
      placeholder text as the copy did, the page keeps its run both
      times, and the Trash takes nothing. **Fail:** the sealed word
      arrives, or the run leaves the page.
- [ ] **The decrypted drag's handle.** On a card at least as wide as
      the default, point at a sealed object, then move away, then click
      the object once. **Pass:** while pointed at or selected, the top
      row shows `drag decrypted` in an ember outline just before `···`,
      and nothing else on the block moves when it appears; it goes when
      the pointer leaves an unselected block. A click on the handle that
      does not move selects the object. Narrow the card until the handle
      would meet `SEALED CONTENT`: it is no longer drawn. **Fail:** the
      block's contents shift, the handle overlaps the classification, or
      a still click starts a drag.
- [ ] **Decrypted drag into a form field.** Drag from the object's
      decrypted handle into a browser's text field; repeat in Safari and
      in one Chromium browser. **Pass:** the drag image shows only the
      handle, the field receives the sealed word, the object stays on
      the page, the ledger gains one `sent` to `drag`, and
      `osascript -e 'clipboard info'` shows the general pasteboard
      unchanged. **Fail:** the drop is empty, the image shows the
      excerpt, the object leaves, or the general pasteboard holds the
      word. An empty drop is the third eject trigger of ADR-0050.
- [ ] **A cancelled decrypted drag.** Start the decrypted drag and press
      Esc before releasing, then wait a minute and start an ordinary
      drag in another app. **Pass:** the ledger gains no `sent`, since no
      destination asked. **Fail:** a `sent` lands for a drag no
      destination took.
- [ ] **A decrypted drag dropped on the app** (ADR-0050). Drag from the
      handle and hover, then release, over: the same page below the
      object; the other page where two show at once; an open note; a
      tab's name field; the pad list's name field; a Settings field; and
      the window's own edge. **Pass:** the pointer shows no drop over
      each, nothing lands anywhere, nothing is sealed, the ledger gains
      no `sent`, and the app answers at once afterwards. **Fail:** any
      field shows the sealed word, a new object appears, a `sent` lands,
      or the app stops answering.
- [ ] **The handle while a name is written.** Open an object's name
      field, then press and drag from the handle of another object.
      **Pass:** no drag starts and the line under the page reads
      `a name or note is being written, so the drag did not start.`
      **Fail:** a drag starts, or the name field loses its draft.
- [ ] **A decrypted drag onto the desktop.** Drag from the handle onto
      Finder's desktop. **Pass:** Finder's answer is another app's drop:
      the object stays and the ledger gains one `sent` to `drag`. Note
      whether Finder wrote a clipping file, which would hold the sealed
      word on disk until deleted. **Fail:** the object leaves.
