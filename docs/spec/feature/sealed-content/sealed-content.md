# Sealed Content Design

OnetimePad · Design note, consolidated · September 2026 · Upstream of an ADR

A sealed item is the editor-side face of a chip: a Rust-core-owned secret that the Swift/AppKit shell never holds in plaintext. This note fixes how such an item behaves inside a page, on the pasteboard, and at the moment its contents cross the protection boundary. It combines two established patterns: the **atomic attachment** (an image, mention, or embedded file in a rich-text editor) and **explicit declassification** (protected plaintext leaves only through an action that names that consequence).

A sealed item occupies one position in the document, but its plaintext is not part of the document’s ambient text.

*The governing law. It answers most interaction questions on its own.*

Every operation on a sealed item is one of two kinds, and the distinction is the whole design:

#### Structural

- Move, select, cut, paste within the app, duplicate, delete, expire
- Act on the object; never touch its payload
- Undoable

#### Declassification

- Copy decrypted contents, decrypted drag from the handle, unseal, promote to a one-time link, plaintext export
- Plaintext crosses the boundary; the action names it
- Always explicit, always core-side

## Sealing retroactively

When plaintext is selected, offer **Seal Selection** in the context menu, **Edit → Seal Selected Content** in the menu bar, and optionally the same action in the command palette. Invoking it replaces the selection in place with one sealed object, preserves position and surrounding whitespace, selects the new object so the transformation is visible, and rejects selections that already contain a sealed object (sealed objects do not nest). No confirmation dialog for the ordinary case; the visible collapse into a card is the feedback.

Sealing is reversible through **Unseal**, a named declassification on the object menu that restores the plaintext in place. ⌘Z immediately after sealing invokes exactly that command and is labelled *Undo Seal Selection* in the Edit menu. The undo record holds only the chip id and the range; the plaintext returns from the core through the same ingress in reverse, so the shell’s undo stack never contains a secret.

> **Honest scope.** Retroactive sealing protects the selection *from this point forward*. In artifact terms: after the next debounced write the stored page no longer contains the plaintext, and earlier file generations are covered by the boot-bound key. What remains is the shell’s layout and glyph caches and whatever the user pasted from. Never imply historical erasure.

## The sealed-object contract

`structural``declassify``ambient` reads the object without reading its payload

| Interaction                      | Kind                                  | Expected behaviour                                                                                                                                                                                                                                                                                                                                                |
|----------------------------------|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Arrow keys                       | `ambient`    | The caret crosses the object as one indivisible unit.                                                                                                                                                                                                                                                                                                             |
| Click                            | `structural` | Selects the whole object; never places a caret inside it.                                                                                                                                                                                                                                                                                                         |
| Shift-selection                  | `structural` | Includes the whole object or none of it.                                                                                                                                                                                                                                                                                                                          |
| Select All                       | `structural` | Includes the object structurally, not its plaintext.                                                                                                                                                                                                                                                                                                              |
| Copy (object or whole page)      | `structural` | Writes a copy-ticket in the private type plus the placeholder in plain text. No payload, no ciphertext.                                                                                                                                                                                                                                                           |
| Cut                              | `structural` | Writes a cut-ticket, then moves the chip to the *detached* state, where it shows in the app’s own clipboard slot on its own TTL. Never an invisible limbo.                                                                                                                                                                                                        |
| Paste inside OnetimePad          | `structural` | The core resolves the ticket. A cut-ticket reattaches the chip at the new position and is consumed; a copy-ticket (or a second paste of a cut-ticket) clones the chip with a new UUID, same TTL and payload.                                                                                                                                                      |
| Paste into another app           | `ambient`    | The destination gets the placeholder `[sealed: ]`. Never plaintext.                                                                                                                                                                                                                                                                                        |
| Drag within the document         | `structural` | Moves the object atomically with a clear insertion line. Contents never preview.                                                                                                                                                                                                                                                                                  |
| Option-drag                      | `structural` | Core-side clone, following the macOS copy-drag convention. No pasteboard involvement.                                                                                                                                                                                                                                                                             |
| Plain drag outside OnetimePad    | `ambient`    | Exposes only the placeholder.                                                                                                                                                                                                                                                                                                                                     |
| Decrypted drag (from the handle) | `declassify` | An explicit affordance on the card (a distinct handle, or a modifier-drag the card labels while held). Plaintext is supplied lazily via `NSPasteboardItemDataProvider`, so the core writes it only when a destination asks. A successful drop never deletes the chip.                                                                                             |
| Backspace beside it              | `structural` | First press selects the object; second press removes it.                                                                                                                                                                                                                                                                                                          |
| Backspace while selected         | `structural` | Removes it immediately, with Undo available.                                                                                                                                                                                                                                                                                                                      |
| Search and word count            | `ambient`    | Do not inspect the plaintext; optionally count one protected object.                                                                                                                                                                                                                                                                                              |
| Expiry                           | `structural` | A chip has its own TTL, which may be shorter than the page’s. When it elapses the page shows an *expired* placeholder in place, visibly distinct from a removed one, and not undoable because nothing remains to restore. When the page expires its chips go with it. Both hold at rest with the app not running (boot-bound key, refuse-to-reveal at next open). |
| Export, print, share             | `ambient`    | Emit the placeholder by default. Decrypting export is a separately named action.                                                                                                                                                                                                                                                                                  |
| Promote whole page               | `declassify` | Includes sealed payloads; that is the product. The confirmation says so: “includes 2 sealed items”. The local copy is offered up to burn, never burned automatically.                                                                                                                                                                                             |

## The card

The full-width card is an **atomic block attachment**, not an oversized button. A small drag handle appears on hover or selection; the decrypted-drag handle is visually distinct from it. While dragging, the whole card moves and its contents never preview. Once selected the object has a clear focus outline and deletes normally. Two-stage Backspace follows attachment conventions while preventing a nearby text-editing gesture from silently destroying protected content.

The object menu:

    Copy decrypted contents
    Create one-time link…
    Unseal
    ────────────────────────
    Remove protected content

After a decrypted copy, confirm the boundary crossing with the interval the core actually enforces, for example `Decrypted contents copied · clipboard clears in 60 seconds`. The core already clears on every pasteboard egress, so state the real number; never promise a clear the app does not perform.

## Pasteboard model

`NSPasteboard` lets one item advertise several representations, and receiving apps choose the one they understand (the same mechanism that supplies image, rich-text, and plain-text forms of a single copy). A sealed object writes:

- a private type, `com.onetimesecret.onetimepad.sealed-ref` (with the `.debug` suffix on dev builds, so dev and prod cannot resolve each other’s tickets), whose payload is a **ticket**;
- the plain-text placeholder `[sealed: ]`;
- a public URL representation *only* as the direct result of “Create one-time link”, never on an ordinary copy. A one-time link is itself a declassification: the first reader burns it, and a pasteboard-polling app is a reader.

Clipboard managers and Universal Clipboard do not pick a representation; they archive all of them and sync them to other devices. That is why the private type carries a ticket and not the chip: a ticket is content-free and linkage-free, whereas the chip’s stable UUID (already in the ledger) would let a history entry be linked to a ledger record forever.

### Tickets

A ticket is a fresh random 128-bit value the core mints per copy or cut and maps internally to `{chip id, operation, pasteboard changeCount at issue}`. Tickets persist in the content store alongside the chips, so quitting between cut and paste and relaunching still pastes. On paste the core checks `changeCount`; a ticket issued under an older count is stale, and pasting it is a no-op with a one-line notice, never a resurrection. Across a reboot the chip is gone by crypto-erasure, so the ticket resolves to *expired* and the paste inserts the expired placeholder, which is the honest answer rather than a failure.

The drag pasteboard uses the same multi-representation API, so decrypted drag is the same code path under a different pasteboard name, with the plaintext type present only when the drag starts from the explicit handle.

## Egress points

The ADR names one egress (send). This design makes it three, and the ADR should say so rather than drift: **copy decrypted** to the general pasteboard (concealed type, cleared on the core’s interval), **decrypted drag** to the drag pasteboard (never enters clipboard history or Universal Clipboard, which makes it the safer of the two and the recommended way to get a secret into a form field), and **promotion**. All three are core-side writes; the Swift shell still never holds plaintext.

## Residual exposure

The placeholder carries the title, the ADR’s one accepted content-derived field, and it will sit in clipboard history under that label. Same exposure as the ledger, stated the same way. The title replaces the earlier `· 51 characters` form, which leaked an exact length the ledger deliberately reduces to a size class and was less useful to whoever received it.

## The rubric

Evaluate every new interaction against these six questions.

Atomicity  
Does the sealed item behave as one object?

Non-disclosure  
Can this ordinary action reveal plaintext unexpectedly?

Fidelity  
Can the object move through trusted app operations without losing its payload?

Legibility  
Does the action name what crosses the protection boundary?

Reversibility  
Can structural edits be undone? (Unseal is the one declassification that also serves as undo, and it is named as such.)

Safe fallback  
When a destination cannot understand the object, does it receive a placeholder rather than plaintext or nothing?

## Against the tenets

1\. Losing work is unforgivable, even here  
Unseal exists so a mis-sealed paragraph is not lost to friction. A cut chip is visible in the clipboard slot, never orphaned. Expiry is on schedule and shown in place. A drop or promotion never deletes; burn is a separate act.

2\. The artifact transcends the application  
The artifact records chip attachment state (on page X, or detached) and the ticket table, so reopen restores exactly the interrupted state. Chip and page TTLs are artifact properties enforced at rest by the key lifecycle, not by a running process.

3\. Do not wag the dog  
Every departure from the ADR above (three egress points, decrypted drag as preferred path) is argued on merits, not citation, and is a candidate ADR amendment.

## Changes from the first draft

- **Undo of sealing** was “restore the plaintext”. It is now the named Unseal command, so ⌘Z is not an unlabelled reveal and the undo stack holds no plaintext.
- **Paste inside OnetimePad** was “restores the complete sealed object, including its protected payload”. The private type now carries a ticket; the core owns the payload throughout.
- **Drag outside OnetimePad** was placeholder-only with a vague exception for destinations that understand the format. It is now placeholder by default plus an explicit decrypted-drag handle, because the drag pasteboard is the safer declassification channel.
- **Placeholder** was `[sealed content · 51 characters]`. It is now `[sealed: ]`.
- **Cut** now defines the detached state instead of leaving an unpasted chip undefined.
- **Expiry** and **whole-page promotion** rows were added to the contract.
- **Retroactive sealing’s caveat** is restated in artifact terms; autosave is already under the boot-bound key, so undo history is not in the residual list once Unseal routes through the core.
