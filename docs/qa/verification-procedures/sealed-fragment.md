# The sealed fragment: what other apps and a real drag receive

**Applies to:** OnetimePad's copy, cut, paste and drags of a selection
holding a sealed object and a service's request for it, the decrypted
drag from its handle, the
two presses that remove an object and the line's Undo after them, the
sealed paste and its offer over this app's own copy, a menu bar
with no Print…, text menus with no Share…, Writing Tools, Look Up,
Translate, Speech, Spelling and Grammar or Search With Google, the
route a real look up takes to the page's gate, Transformations and
Substitutions over an object, inline predictions and a Touch Bar's
typing suggestions, a link's ⌘-click, menu and drag, the spelling
panel and data detectors, and
text holding U+FFFC landing beside an object.
**Raised by:** issues #170 and #247 on `feature/editing-seals`,
2026-10-13.
**Governs:** [Law 0001](../../law/0001-sealed-object.md), whose copy,
paste, drag and decrypted drag rows cite this procedure for what the
runner cannot drive, and whose expiry, copy and cut rows hold the
deadline gate and the envelope's caps;
[ADR-0045](../../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md)
and [ADR-0046](../../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md),
both accepted; the
[sealed row spec](../../spec/feature/sealed-content/sealed-row-note-and-handles.md)'s
decrypted drag handle.
**Owner:** delano.
**Status:** open; not yet run. The editor's copy and cut write the
fragment, its paste reads it, the slot's button places a cut, two
presses remove an object with Undo on the line, the page drags its
selection as the fragment, and the block's handle starts the decrypted
drag, so every check can run. The two handles check, added 2026-10-16
with the move handle (issue #255), is owed with the rest.

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
- [ ] **A service over an object.** Select the same three again, then
      open OnetimePad > Services. **Pass:** a service that takes text
      without answering, such as a new note or a web search, receives
      `before [sealed content · tiny] after`; no service that rewrites
      the selection in place, such as a case change, is offered.
      **Fail:** any service receives the sealed word, or `￼` where the
      object stood, or a service rewrites the selection over the object.
- [ ] **No Share… or Writing Tools over a page, a note or a name**
      (Law 0001, share and Writing Tools amendment). On a Mac with
      Apple Intelligence on, select ink on a page and Control click it;
      do the same in an object's note and in its name field while it is
      open. Then, with each holding the keys, open Edit in the menu bar.
      Then open a regular text file and Control click a selection there.
      **Pass:** the page's, the note's and the name field's menus hold
      no Share…, Show Writing Tools, Proofread or Rewrite and no doubled
      separator; Edit's Writing Tools items, where the system adds them,
      are unavailable over all three, and no Writing Tools button or
      panel appears beside a selection there; the file's menu still
      offers Share… and Writing Tools. **Fail:** any of these shows over
      a page, a note or a name, or the file's menu has lost them.
- [ ] **No Look Up, Translate or Speech over a page, a note or a name**
      (Law 0001, share and Writing Tools amendment). Control click a
      selection on a page, in a note and in a name field, then in a
      regular text file. **Pass:** the first three menus hold no
      `Look Up “…”`, no `Translate “…”` and no Speech submenu; the
      file's menu holds all three. **Fail:** any of them shows over a
      page, a note or a name, or the file's menu has lost one.
- [ ] **Look Up reaches the page's gate** (Law 0001, expiry row; Law
      0007, keys row). The
      tests refuse look up past a deadline through the routes AppKit
      documents, but cannot send ⌃⌘D, a system shortcut, or a real
      force click, and a page past its deadline settles at the wake
      before a person can try either. So check the route on a standing
      page, where the page stands aside while its note holds the keys.
      Seal a word on a page that also holds plain words, open the
      object's note and type a word in it. With the note holding the
      keys, point at a plain word on the page outside the note and
      press ⌃⌘D, then force click the same word (or tap it with three
      fingers). Then do both over the word in the note, and over a
      plain word in a regular text file. **Pass:** nothing appears for
      the page's word; the note's word and the file's word each show a
      definition. **Fail:** a definition, a Dictionary window or a
      translation of the page's word appears; record which gesture
      reached it, since that route is not gated.
- [ ] **No Spelling and Grammar or Search With Google over a page, a
      note or a name** (Law 0001, AppKit text routes amendment). On a
      page, choose Edit > Spelling and Grammar > Check Spelling While
      Typing, type `wrnog`, and Control click the underlined word; do the
      same in an object's note and in its name field while it is open,
      then in a regular text file. **Pass:** the page's, the note's and
      the name's menus hold no Spelling and Grammar submenu, no guesses,
      no Provide Feedback, no Ignore Spelling, no Learn Spelling and no
      Search With Google;
      the file's menu holds them. **Fail:** any of them shows over a
      page, a note or a name, or the file's menu has lost one.
- [ ] **Transformations and Substitutions keep every object** (Law
      0001, the rewrite row). On a page type `say -- hi`, seal `hi`,
      type ` -- end` after it, and select the whole line. Choose Edit >
      Transformations > Make Upper Case, then ⌘Z; then Edit >
      Substitutions > Show Substitutions and press Replace in Selection
      with Smart Dashes ticked, then ⌘Z. **Pass:** the ink changes case
      and both dashes become `—`, the object standing in place each
      time with no removal line, and each ⌘Z takes back its change
      whole. **Fail:** the object goes, the line says sealed content
      removed, or one ⌘Z takes back only part of a change.
- [ ] **No inline predictions or typing suggestions over a page**
      (Law 0001, AppKit text routes amendment). With System Settings >
      Keyboard > Text Input's inline predictive text on, type the start
      of a common phrase, such as `see you`, on a page, in a note and in
      a regular text file; on a Mac with a Touch Bar, watch it as you
      type. **Pass:** no gray prediction follows the caret and the Touch
      Bar shows no typing suggestions over the page or the note; the
      file shows them. **Fail:** a prediction or a suggestion shows over
      the page or the note.
- [ ] **A link opens only through the page** (Law 0001, link and
      spelling panel amendment, Edit Link amendment). On a page type
      `[docs](https://example.com/?t=1)`. ⌘-click the link; then Control
      click it and choose Open Link, then Copy Link, and paste in
      TextEdit. Seal a word on the page, open its note, type the same
      link in the note and repeat there. Last, open a Markdown file
      holding the link and Control click it. **Pass:** on the page and
      in the note, a plain click only moves the caret, ⌘-click and Open
      Link each open the browser at the URL, Copy Link pastes the URL,
      and the menu holds no Open With and no Edit Link…; the file's menu
      holds Open With and Edit Link…, and its Open Link opens the
      browser. **Fail:** Open With or Edit Link… shows over the page or
      the note, a plain click opens the link, or Open Link does nothing
      anywhere.
- [ ] **A link dragged off a page** (Law 0001, the link rows). Press and
      hold on the page's link without moving, then drag it into
      TextEdit. **Pass:** TextEdit receives
      `[docs](https://example.com/?t=1)`, the page's own drag of that
      ink, and the page keeps it. **Fail:** no drag starts, or TextEdit
      receives anything else.
- [ ] **No spelling panel over a page, a note or a name** (Law 0001,
      link and spelling panel amendment). Click into a page and open
      Edit > Spelling and Grammar; do the same in a note and in a name
      field while it is open, then in a regular text file. In the file,
      choose Show Spelling and Grammar to open the panel, click into the
      page after typing `wrnog` there, and press the panel's Find Next,
      then ⌘;. **Pass:** Show Spelling and Grammar is unavailable over
      the page, the note and the name and available over the file; with
      the panel up, Find Next and ⌘; on the page leave the panel showing
      no word of the page and select nothing. **Fail:** the panel opens
      over a page, a note or a name, or shows `wrnog` from the page.
- [ ] **No data detectors over a page** (Law 0001, data detectors row).
      Control click a page's text and choose Substitutions > Data
      Detectors, type `lunch tomorrow at 1 Infinite Loop`, then do the
      same in a regular text file. **Pass:** the page's item stays
      unticked and nothing on the page is marked as a date or a place;
      the file's ticks and marks them. **Fail:** the page marks a date
      or a place.
- [ ] **Cut and paste in place.** Cut the selection, note the slot's
      line under the page, then paste further down. **Pass:** the line
      names the cut object by its face and goes when the paste lands;
      the object returns with its name, and ⌘Z takes the paste back.
      **Fail:** the line stays, or the object returns as a clone with
      a fresh face.
- [ ] **The slot's button on the raised card.** Name a sealed object,
      select it with some ink and cut with ⌘X. Switch to another page,
      put the caret at its end and click the slot's `Place Here`
      button under the page, then type a letter. **Pass:** the line
      named the object by its name and size class and showed nothing
      of the sealed word; the card stays raised through the click; the
      object and the ink land at the caret with the name; the line
      goes; the letter lands on the page; ⌘Z takes the place back.
      **Fail:** the card rests on the click, the letter goes to another
      app, or the line shows any part of the word.
- [ ] **A paste over several stretches.** Copy a selection holding a
      sealed object. Select two words of ink apart from each other by
      dragging the second with ⌘ held, and press ⌘V. Then cut a sealed
      object, select two words the same way, and click the slot's
      `place here`. **Pass:** each time the line under the page reads
      `sealed objects paste into one selection, not several.` and both
      words stay as they were. **Fail:** either word is replaced, or
      nothing is said.
- [ ] **Several stretches copied, cut or dragged.** Copy a word in
      TextEdit. On the page, select a sealed object with some ink, then
      add a word of ink further down by dragging over it with ⌘ held.
      Press ⌘C, then ⌘X, then drag the selection. Then select two words
      of ink alone the same way and press ⌘C. **Pass:** the lines read
      `sealed objects copy from one selection, not several.`, `sealed
      objects cut from one selection, not several.` and `sealed objects
      drag from one selection, not several.`; no drag starts; the page
      is unchanged and ⌘V in TextEdit still pastes its own word. The two
      words of ink alone copy as plain text. **Fail:** any of the three
      writes the clipboard, changes the page or says nothing.
- [ ] **The slot's line with many objects.** On a card at its default
      width, name eight sealed objects with long names, select them all
      with the ink between and cut. **Pass:** the slot's line stays one
      line and ends in an ellipsis, `place here` stays whole at its end
      and places all eight, and no part of a sealed word shows.
      **Fail:** the line wraps, pushes the button off the card, or shows
      any part of a sealed word.
- [ ] **The Edit menu while a field holds the keys.** Copy a selection
      holding a sealed object. Open a tab's name field with *Rename
      tab…*, open the Edit menu, then choose Paste; do the same in an
      object's name field. Then, in an object's name field holding a
      name, select part of it and choose Edit > Cut; open the object's
      note, select a word and choose Edit > Cut. **Pass:** with a field
      open, Seal Selected Content and Paste Without Detection are
      greyed; Paste puts plain text into the field, the tab's field
      taking `[sealed content · tiny]` with the ink and the sealed name
      field saying why it will not take it; each Cut takes its text out
      of the field or the note, and `osascript -e 'clipboard info'`
      lists plain text with no private type; the page, its objects and
      the ledger are unchanged and no slot's line appears. **Fail:** a
      paste or a cut acts on the page, a clone or a slot's line appears,
      or the ledger gains a record.
- [ ] **⇧⌘V over this app's own copy.** Copy a selection holding a
      sealed object, rest the card and summon it again with ⌃⌥Space,
      then press ⇧⌘V at a caret on the page. Do the same after a cut.
      **Pass:** no `seal it (⇧⌘V)` row shows after the summon; the line
      reads `nothing to seal: the clipboard holds this app's own copy,
      which ⌘V pastes.`; no new object appears; `osascript -e
      'clipboard info'` still lists the private type; ⌘V then pastes
      the copy, or places the cut. **Fail:** the row shows, an object
      appears, or the clipboard is cleared.
- [ ] **The offer's button while a name is written.** Copy a word in
      TextEdit and summon the card so the `seal it (⇧⌘V)` row shows.
      Open an object's name field, type a letter, and click the row's
      button; then do the same with the object's note open. **Pass:**
      the line reads `a name or note is being written, so the clipboard
      was not sealed.`, no object appears, the field or note keeps its
      draft and the row stays; once both are closed the button seals
      the word. **Fail:** an object appears while either is open.
- [ ] **No print.** With a page holding the keys, open each menu in the
      menu bar and the page's context menu, then press ⌘P. **Pass:** no
      menu holds Print… or Page Setup…, and ⌘P opens no print panel.
      **Fail:** either item shows, or a print panel opens.
- [ ] **A cut across a relaunch.** Cut a sealed object, quit with ⌘Q,
      relaunch, paste. **Pass:** the slot's line is back before the
      paste and the object returns. **Fail:** the paste places
      `[sealed content · unavailable]`.
- [ ] **A cut that outlives its page's deadline** (Law 0001, expiry
      row). On a one
      hour page, seal a word and cut it. Sleep the Mac for more than an
      hour, wake it, and paste onto another page at once. **Pass:** the
      paste places `[sealed content · expired]`, the first page's tab
      stands empty, the slot's line is gone, and the ledger shows the
      object expired. **Fail:** the object returns, or the first page
      still shows its ink after the paste.
- [ ] **A page that comes due asleep** (Law 0001, expiry row). On the
      raised card,
      open a one hour page, seal a word and write a note on it. Sleep the
      Mac for more than an hour, wake it, and look at the card before
      touching anything. **Pass:** the page has gone at the wake: its tab
      stands empty, the ledger shows it expired, and
      `osascript -e 'clipboard info'` shows nothing new. **Fail:** the
      page's ink, its block or its note still shows after the wake.
- [ ] **A selection past an envelope cap** (Law 0001, copy and cut
      rows). Put more than
      8 MiB of text on a page, for example by pasting the output of
      `head -c 9000000 /dev/zero | tr '\0' x | pbcopy`, seal a word in
      it, select all, then try ⌘C, ⌘X, a drag and a service that takes
      text (the app menu's Services, New TextEdit Window Containing
      Selection). **Pass:** each leaves
      the line `a selection holding sealed objects can be at most 8 MiB,
      so nothing was copied.`, ending `nothing was cut.` for the cut and
      `the drag did not start.` for the drag; the service opens no
      window holding the selection; the general pasteboard, the
      page, the slot's line and the ledger stand as they were; selecting
      the ink alone still copies it as plain text. **Fail:** anything
      reaches the pasteboard, the page changes, or no line shows.
- [ ] **A fragment pasted into a note.** Copy a sealed object with some
      ink, open another object's note and paste with ⌘V. **Pass:** the
      note shows the ink with `[sealed content · tiny]` where the object
      stood, and the page is unchanged. **Fail:** the note shows the
      sealed word or a block, or the paste lands on the page.
- [ ] **A paste with automatic fencing on.** In Settings, turn on
      *Automatically fence detected code*. Copy a selection holding a
      sealed object between two lines of code such as `let x = 1`, and
      press ⌘V lower on the page. Then copy code from TextEdit and paste
      it. **Pass:** the run lands as copied, the object as its block with
      its name and no fence around the run, and ⌘Z takes the whole paste
      back in one step; the code from TextEdit is fenced as before.
      **Fail:** a fence wraps the run, the object lands as
      `[sealed content · tiny]` text, or ⌘Z takes back only part of it.
- [ ] **Two presses and the removal's Undo.** On the raised card, type
      `before`, seal a word, type `after`, put the caret just after the
      object and press ⌫ once. Press ⌫ again, then click the line's
      `Undo` button, then type a letter. **Pass:** the first ⌫ selects
      the object and removes nothing; the second removes it and the
      line under the page reads `sealed content removed.` with
      `Undo`; the click keeps the card raised and stands the same
      object again, selected, with its face and name; the letter lands
      on the page. The same holds for ⌦ with the caret just before the
      object. **Fail:** one press removes the object, the line has no
      `Undo`, the card rests on the click, or the letter goes elsewhere.
- [ ] **Every other deletion.** On the raised card, with `before`, a
      sealed word and `after` on one line and the caret just after the
      object, press ⌥⌫ once, then again. Repeat with ⌘⌫, and with ⌃K
      and ⌥⌦ from just before the object. Then select the object and
      choose Edit > Delete; select it again and type a letter; select it
      again and press Return. Then put the caret before `before` and
      press ⌃K. **Pass:** each first press at a caret selects the object
      and removes nothing, and each second press removes it; every
      removal, the last ⌃K's whole line included, shows `protected
      content removed.` with `Undo`, and the click stands the same
      object again with its name, with the line's ink for the ⌃K; while
      a name field is open, none of these keys changes the page.
      **Fail:** a first press removes the object, a
      removal shows no line or no `Undo`, the `Undo` takes back more
      than the removal, or the page changes under the name field.
- [ ] **⌃Y after ⌃K over an object** (Law 0001, object character
      amendment). On the raised card, with `before`, a sealed word and
      `after` on one line, put the caret before `before`, press ⌃K, then
      ⌃Y. Then open the Character Viewer (⌃⌘Space), search for `object
      replacement`, and insert U+FFFC into the page and into a note.
      **Pass:** the ⌃Y brings back `before  after` with no object, no
      box glyph and the caret after `after`; the inserted U+FFFC leaves
      nothing; ⌘Z takes the ⌃Y back as one step. **Fail:** a box or an
      object face appears, the caret lands anywhere else, or the page
      reloads whole.
- [ ] **Text holding U+FFFC right after an object** (Law 0001,
      inherited attachment amendment). Open a regular text file, insert
      `x`, U+FFFC from the Character Viewer and `y`, select the three
      and copy. On a page holding `ab`, a sealed word, ` cd`, a second
      sealed word and ` ef`, click right after the first object and
      press ⌘V; then drag the same three characters from the file and
      drop them right after the first object, right before the second,
      and between two objects sealed side by side. After each, backspace
      the `d` of `cd`. **Pass:** each landing reads `xy` with no second
      object face, both objects stand, the backspace takes only the `d`
      with no removal line, and a relaunch shows the page as it was
      left. **Fail:** a face appears twice, an object goes or loses its
      face, the removal line shows, or the relaunch differs.
- [ ] **The removal's Undo after the page moves on.** Remove an object
      with two presses, then type a letter before the line clears.
      **Pass:** the `Undo` button leaves the line at once, and ⌘Z
      takes the letter back first and the removal on the next press.
      **Fail:** the button stays, or pressing it takes the letter back.
- [ ] **The removal's Undo on another surface.** On the raised card,
      remove an object with two presses. Before the line clears, click
      the Dock tile so the editor window opens on the same page, and
      click the line's `Undo` there. Then remove an object again, go
      the same way to the editor window, and type a letter on the page.
      With `ledger::Show` bound in your own keymap, as
      [hardware verification](../hardware-verification.md) says, do
      both again on the card alone, opening the ledger and pressing Esc
      in place of the Dock tile. Last, remove an object, open the
      ledger, and choose another page's tab. **Pass:** each click
      stands the same object again, selected, with its name; after each
      letter the `Undo` leaves the line at once; on the other page the
      line offers no `Undo`. **Fail:** a click does nothing, the line
      loses its `Undo` when the surface changes on the same page, after
      a letter the button stays or takes the letter back, or the other
      page's line offers an `Undo` that steps the first page.
- [ ] **The removal's Undo while a name is written.** Remove an object
      with two presses. Before the line clears, open another object's
      name field, type a letter, and click the line's `Undo`. **Pass:**
      the line reads `a name or note is being written, so the removal
      was not undone.`, the object stays off the page and the field
      keeps its draft. **Fail:** the object comes back while the field
      is open, or the draft is lost.
- [ ] **Remove Sealed Content and its Undo.** Choose *Remove
      Sealed Content* from a named object's `···` menu, then click
      the line's `Undo`. Remove it the same way again and press ⌘Z.
      **Pass:** each removal shows `sealed content removed.` with
      `Undo`; the click and ⌘Z each stand the same object again with its
      name and note, and the ledger gains no record for either removal.
      **Fail:** the object returns as a fresh seal or without its name
      or note, or the line offers no `Undo`.
- [ ] **A drag inside the page.** Name a sealed object and give it a
      note. Select `before`, the object and `after`, then drag the
      selection to the end of the page and drop it. **Pass:** while
      dragging, an insertion line shows where the run will land, and the
      drag image shows the ink and the block with `SEALED CONTENT`, its
      name and its size class, and no part of the sealed word; the run
      lands there with the object's name and note; ⌘Z puts the whole run
      back in one step. Dropping the selection onto itself changes
      nothing. **Fail:** no insertion line, the object returns without
      its name or note, the image shows any of the sealed word, an `=`
      after the name, or ⌘Z takes back only part of it.
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
      editor window and the card), click into the first page so its
      window holds the keys, then drag a selection holding a named
      object with a note from it to the other page (Law 0001, drag
      row). Do it
      once from the card to the editor window and once back. **Pass:**
      the run lands on the second page with the object's name and note,
      leaves the first, and the ledger gains no `sealed`; ⌘Z on the
      first page brings nothing back, and ⌘Z on the second takes the
      run off it. With ⌥ held, the cursor shows a copy, the first page
      keeps its run and the ledger gains one `sealed`. **Fail:** the
      line `a name or note is being written, so the drop was not
      placed.` shows, the drop seals the text `[sealed content · tiny]`
      as a new object, the first page keeps its run after a plain drop,
      or ⌘Z on the first page stands the object again.
- [ ] **A drop on a tab** (Law 0001, drag and ⌥ drag rows; issue 254).
      First, whether a drag reaches a tab at all: the tab's drop target
      (`TabDropTarget`) answers nil from `hitTest`, so the tab's clicks
      stay SwiftUI's, and every test drives its destination calls
      directly; only a real drag can show that AppKit delivers one to a
      view whose `hitTest` returns nil. With two pages in the strip on
      the raised card, select a run of plain ink on the first page and
      drag it over the second page's tab, watching for the cursor to
      change, then release. Then select a run with a named object and
      its note on the first page and drag it onto the second page's
      tab. Then drag a run onto the first page's own tab, and with ⌥
      down onto the second's. Last, drag a word from TextEdit onto the
      second page's tab. **Pass:** over a tab the cursor shows a move
      (⌥: a copy) and the released run is placed, the run stands at the
      end of the second page with the object's name and note and leaves
      the first, the own tab's drop moves the run to the end of its
      page, ⌥ leaves the first page's run and the ledger gains one
      `sealed`, the TextEdit word stands at the end of the second page
      as a new sealed object, and the tab still selects on a click,
      pauses its clock on a double click and reorders from its handle.
      **Fail:** the cursor never changes over a tab or the released run
      returns to the first page (AppKit delivered no drag to the
      target; the feature rests on this), the run stands anywhere but
      the end, the object returns without its name or note, the first
      page keeps its run after a plain drop, the TextEdit word is
      placed as ink, or a tab stops answering its clicks or its handle.
- [ ] **A drop on a resting card's tab** (Law 0001, drag row; ADR-0015;
      issue 254). Pin the card and let it rest, so its window takes the
      mouse, then drag a word from TextEdit over one of its tabs and
      release. **Pass:** the cursor shows no operation over the resting
      card's tab, nothing is placed and no line shows; after a raise
      the same drag seals at the end of the tab's page. **Fail:**
      anything is placed on the resting card's page, or a line shows.
- [ ] **A drop on an empty tab** (Law 0001, expiry row; issue 254).
      Let a page expire at its one hour rung so its slot stands empty,
      then drag a selection from another page onto that slot, and a
      word from TextEdit onto it. **Pass:** the cursor shows no
      operation over the slot, nothing is placed, no line shows, and
      the source keeps its run. **Fail:** a page is minted, anything is
      placed, or the source loses its run.
- [ ] **Ink between pages and from the note.** With both windows
      showing pages, drag a word of plain ink from one page to the
      other, then open an object's note, type a word, select it and
      drag it onto its own page and onto the other window's page. Then
      select two words of plain ink on one page with ⌘ held and drag
      them to the other window's page.
      **Pass:** each word lands as ink where dropped; the page's single
      word leaves its page, the two words and the note's word stay where
      they were as well (Law 0001, several stretches drag amendment), and
      no new object or `sealed` appears. **Fail:** any drop becomes a
      sealed object, or
      the note's drop shows the line that a name or note is being
      written.
- [ ] **A drag while a name is written.** On the card, open an object's
      name field and type a letter. Press on a selected run of the same
      page and drag it lower. Then, with the field open again, drag a
      selection holding an object from the editor window's page onto the
      card's page. **Pass:** the page never changes while the field still
      shows its draft: the press either closes the field first, after
      which the run moves as in *A drag inside the page*, or starts no
      drag; a drop arriving while the draft shows lands nowhere and the
      line reads `a name or note is being written, so the drop was not
      placed.` **Fail:** a run moves or lands while the field still
      shows its draft, or the draft is lost without the field closing.
- [ ] **A page's drag onto a rename field.** Choose *Rename Tab* from
      a tab's menu, then drag a selection holding an object from the
      page onto the tab's field; repeat on the gutter's field (*Timeline*,
      click a page's time) and on a pad's field (*Rename* on a pad's row
      in the Pads tab of Settings). **Pass:** each field takes
      `[sealed content · tiny]` and the ink around it as plain text, and
      the page keeps its run. **Fail:** the field takes any of the
      sealed word, or the run leaves the page.
- [ ] **A field's text dragged onto a page.** Open the tab's rename
      field, type a word, select it and drag it onto the page. Repeat
      from the gutter's field, a pad's field in the pad list, an
      object's name field and a field in Settings. **Pass:** each word
      lands as ink where dropped, the field keeps its text, and no new
      object or `sealed` appears. **Fail:** any drop becomes a sealed
      object, or a drop from the field that holds the keys shows the
      line that a name or note is being written.
- [ ] **Plain drag out.** Drag the selection into TextEdit, then drag it
      onto the Trash in the Dock. **Pass:** while it passes over TextEdit
      the image shows no part of the sealed word, TextEdit receives the
      same placeholder text as the copy did, the page keeps its run both
      times, and the Trash takes nothing. **Fail:** the image or the drop
      shows the sealed word, or the run leaves the page.
- [ ] **The decrypted drag's handle.** On a card at least as wide as
      the default, point at a sealed object, then move away, then click
      the object once. **Pass:** while pointed at or selected, the top
      row shows `drag decrypted` in an ember outline just before `···`,
      and nothing else on the block moves when it appears; it goes when
      the pointer leaves an unselected block. Over the drawn handle the
      pointer is an open hand, and off it the text cursor again. A click
      on the handle that does not move selects the object. Narrow the
      card until the handle would meet `SEALED CONTENT`: it is no longer
      drawn, and the pointer there stays the text cursor. Switch the Mac
      to the Dark appearance and point at the object again: the outline
      and `drag decrypted` read as clearly as in Light. **Fail:** the
      block's contents shift, the handle overlaps the classification,
      the pointer does not change over the handle or stays an open hand
      off it, a still click starts a drag, or the handle is hard to read
      in either appearance.
- [ ] **The two handles side by side** (D-29's acceptance; Law 0001,
      move drag row). On a card at least as wide as the default, point
      at a sealed object. **Pass:** the top row shows `⠿` in the quiet
      grey of `SEALED CONTENT`, then a gap, then `drag decrypted` in its
      ember outline, then `···`; the two handles do not touch, the
      glyph wears no outline and no words, and nothing else on the
      block moves when they appear. Over `⠿` the pointer is an open
      hand, and off it the text cursor again. Press `⠿` and release
      without moving: the object is selected and nothing is dragged.
      Press `⠿` and drag: the pointer closes, the image is the block's
      face with no excerpt, and a drop lower on the same page moves the
      object there, the page keeping one object; a drop on the other
      page where two show at once moves it there. Open the ledger
      afterwards. Switch the Mac to the Dark appearance and point at the
      object again: the glyph reads as clearly as in Light, and still
      apart from the ember handle. Narrow the card until the row has no
      room for both: `⠿` goes first, `drag decrypted` stays, and narrower
      still `drag decrypted` goes with `⠿` never coming back into its
      place. With VoiceOver on, move the cursor over the block: the two
      handles read as *Move* and *Drag decrypted*, and the VoiceOver
      cursor box is drawn around each handle's seat on the top row, not
      lower on the block. In both appearances, `⠿` reads at the weight
      of the ember handle's words and sits centred on the row beside it.
      **Fail:** the two
      handles overlap or read alike, `⠿` is drawn in ember or wears
      words, the block's contents shift, a still press drags, the
      dragged image shows the sealed word, a drop from `⠿` puts the
      word anywhere or the ledger gains a `sent`, `drag decrypted`
      goes before `⠿` on a narrow card, `⠿` returns once the ember
      handle is gone, VoiceOver names neither handle or draws its box
      away from a handle's seat, or `⠿` reads faint or off the row.
- [ ] **Decrypted drag into a form field.** Drag from the object's
      decrypted handle into a browser's text field; repeat in Safari and
      in one Chromium browser. **Pass:** the drag image shows only the
      handle, the field receives the sealed word, the object stays on
      the page, the ledger gains one `sent` to `drag`, and
      `osascript -e 'clipboard info'` shows the general pasteboard
      unchanged. **Fail:** the drop is empty, the image shows the
      excerpt, the object leaves, or the general pasteboard holds the
      word. An empty drop is the last eject trigger of ADR-0045.
- [ ] **A cancelled decrypted drag.** Start the decrypted drag and press
      Esc before releasing, then wait a minute and start an ordinary
      drag in another app. **Pass:** the ledger gains no `sent`, since no
      destination asked. **Fail:** a `sent` lands for a drag no
      destination took.
- [ ] **A decrypted drag dropped on the app** (Law 0001, decrypted drag
      row). Drag from the
      handle and hover, then release, over: the same page below the
      object; the other page where two show at once; an open note; a
      tab's name field; the pad list's name field; a Settings field; and
      the window's own edge. **Pass:** the pointer shows no drop over
      each, nothing lands anywhere, nothing is sealed, the ledger gains
      no `sent`, and the app answers at once afterwards. **Fail:** any
      field shows the sealed word, a new object appears, a `sent` lands,
      or the app stops answering.
- [ ] **The handle while a name is written.** Open an object's name
      field, then point at the handle of another object, and press and
      drag from it. **Pass:** the pointer over the handle stays the text
      cursor, no drag starts and the line under the page reads
      `a name or note is being written, so the drag did not start.`
      **Fail:** an open hand shows, a drag starts, or the name field
      loses its draft.
- [ ] **A decrypted drag onto the desktop.** Drag from the handle onto
      Finder's desktop. **Pass:** Finder's answer is another app's drop:
      the object stays and the ledger gains one `sent` to `drag`. Note
      whether Finder wrote a clipping file, which would hold the sealed
      word on disk until deleted. **Fail:** the object leaves.

## Drops on the side Timeline's page nodes (issue #267)

**Status, 2026-10-21:** not run on hardware. Build `main` at or after
the merge of PR 269 (1b0ecb9d, app 0.40.0) with `scripts/dev.sh`, and
record the commit with the results.
The mounted view tests in `TabDropTests` drive each node's target
through its destination calls; they run no AppKit drag session and no
pointer (Law 0001, drag row, 2026-10-20 Timeline node amendment).

Choose Timeline in Settings under Page layout. The card and the
primary editor window then draw the Timeline down the side, so normal
controls reach every check and no harness is needed. Run each surface
twice: with the pads experiment off (Settings, *Multiple pads and
context associations · experiment*), which draws the stream navigator,
and with it on, which draws the pads rail.

- [ ] **A drop on a Timeline page node** (Law 0001, drag, ⌥ drag and
      decrypted drag rows; issue 267). Repeat **A drop on a tab** with
      the page nodes as the tabs: a run of plain ink, a run with a named
      object and its note, a run onto the source page's own node, an ⌥
      copy and a word from TextEdit. With two pages on one day, drop
      onto the second page's node. Drag from an object's decrypted
      handle over a node. Then click each node you dropped on.
      **Pass:** over a page node of the raised owner the cursor shows a
      move (⌥: a copy), the run stands at the end of the page a click
      on that node selects with the object's name and note, the second
      page of a day takes the drop meant for it, the TextEdit word
      stands there as a new sealed object, the decrypted drag shows no
      operation and places nothing, and afterwards a click on the node
      still selects its page and scrolls the roll to it, a VoiceOver
      press on the node does what the click does, the node's hover
      fill and tooltip show as before, and in the stream navigator a
      click on the bare track still scrolls and a drag along the
      column still scrubs. **Fail:** the cursor never changes over a node (AppKit
      delivered no drag to a target whose `hitTest` answers nil), the
      run goes to another page or anywhere but the end, the decrypted
      drag places anything, a node stops answering its click, its
      scroll or its tooltip, or the VoiceOver press does anything but
      what the click does.
- [ ] **A drop on a resting card's Timeline node** (Law 0001, drag
      row; ADR-0015; issue 267). Pin the card and let it rest, drag a
      word from TextEdit over a page node and release; then raise the
      card and repeat. **Pass:** the resting card's node offers no
      operation, nothing is placed and no line shows; after the raise
      the word seals at the end of the node's page. **Fail:** anything
      is placed on a resting card, or a line shows.
- [ ] **A drop on a node in the window that does not own** (Law 0001,
      drag row; ADR-0033). Ordinary switches hide the window that does
      not own (ADR-0036), so this runs only if that window shows at
      all. **Pass:** its node offers no operation and places nothing.
      **Fail:** anything is placed through it.
- [ ] **A drop on today's empty node** (Law 0001, drag row; ADR-0017).
      While today has no page, its node is a dashed ring in the stream
      navigator and a *New page…* row in the pads rail. Drag a run from
      a page and a word from TextEdit over it and release. **Pass:** the
      cursor shows no operation, nothing is placed, no page is made and
      the source keeps its run; a click on the node still takes the
      create path. **Fail:** a page is made or
      anything is placed.
- [ ] **A drop on a rail too dense to fit** (Law 0001, drag row;
      issue 277). In the stream navigator, make pages until its top
      rows are drawn above the column, over the *Pad* heading. Drag a
      run from a page over a row drawn above the column and release;
      then drag it over a row inside the column and release. **Pass:**
      the drop over the row above the column offers no operation and
      leaves the text in place in its source, and the drop over the row
      inside the column moves the run to the end of that row's page.
      **Fail:** the drop above the column places the run anywhere, or
      the row inside the column takes no drop.
- [ ] **A drop on a pads rail node below the fold** (Law 0001, drag
      row). The pads rail scrolls instead of packing, and nothing in
      this change scrolls it during a drag. With pads on, make pages
      until a node sits below the rail's visible bottom. Drag a run
      from a page to the rail's lower edge, hold for two seconds, and
      write down whether the rail scrolls. Release over the last node
      in view. **Pass:** the run moves to the end of the page of the
      node under the pointer, whether or not the rail scrolled.
      **Fail:** the run goes to any other page.

| Surface | AppKit drag delivery and cursor | Move, ⌥ copy, TextEdit drop, decrypted drag | Node click, VoiceOver press, roll scroll, tooltip | Resting card | Window that does not own | Today's empty node | Rail too dense to fit (stream navigator) or a node below the fold (pads rail) |
|---|---|---|---|---|---|---|---|
| Card, stream navigator (pads off) | Not run | Not run | Not run | Not run | Not run | Not run | Not run |
| Card, pads rail (pads on) | Not run | Not run | Not run | Not run | Not run | Not run | Not run |
| Primary editor window, stream navigator (pads off) | Not run | Not run | Not run | n/a: no resting stance | Not run | Not run | Not run |
| Primary editor window, pads rail (pads on) | Not run | Not run | Not run | n/a: no resting stance | Not run | Not run | Not run |
