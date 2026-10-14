# The sealed fragment: what other apps and a real drag receive

**Applies to:** OnetimePad's copy, cut, paste and drags of a selection
holding a sealed object, and the decrypted drag from its handle.
**Raised by:** issues #170 and #247 on `feature/editing-seals`,
2026-10-13.
**Governs:** [Law 0001](../../law/0001-sealed-object.md), whose copy,
paste, drag and decrypted drag rows cite this procedure for what the
runner cannot drive; [ADR-0047](../../adr/0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md);
[ADR-0048](../../adr/0048-a-transfer-sweeps-due-pages-before-it-resolves.md).
**Owner:** delano.
**Status:** open; not yet run. The editor's copy writes the fragment,
so the first two checks can run; the rest are blocked until the editor
cuts, pastes, drags and offers the decrypted drag handle (issue #170's
shell half).

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
- [ ] **Cut and paste in place.** Cut the selection, note the slot's
      line under the page, then paste further down. **Pass:** the line
      names the cut object by its face and goes when the paste lands;
      the object returns with its name, and ⌘Z takes the paste back.
      **Fail:** the line stays, or the object returns as a clone with
      a fresh face.
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
- [ ] **Plain drag out.** Drag the selection into TextEdit. **Pass:**
      TextEdit receives the same placeholder text as the copy did.
      **Fail:** the sealed word arrives.
- [ ] **Decrypted drag into a form field.** Drag from the object's
      decrypted handle into a browser's text field. **Pass:** the field
      receives the sealed word, the object stays on the page, the ledger
      gains one `sent` to `drag`, and `osascript -e 'clipboard info'`
      shows the general pasteboard unchanged. **Fail:** the drop is
      empty, the object leaves, or the general pasteboard holds the word.
- [ ] **A cancelled decrypted drag.** Start the decrypted drag and press
      Esc before releasing. **Pass:** the ledger gains no `sent`, since
      no destination asked. **Fail:** a `sent` lands for a drag no
      destination took.
