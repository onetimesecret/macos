# Sealed Content Design

OnetimePad · Design note, consolidated · September 2026 · Upstream of an ADR

Status: historical. Superseded for governing behaviour by `docs/law/0001-sealed-object.md`; `docs/spec/design/2026-0915-ui-ux-decisions.md` section 3 applies that law to the surface. The rationale below is preserved, but its two-class taxonomy, ticket model, shell-plaintext claim, lifecycle and drag guarantees are not current requirements.

A sealed item is the editor-side face of a chip. The shell never receives the complete sealed payload from the core; it may hold visible ink before sealing and the policy-approved mechanical excerpt afterward. This note fixes how such an item behaves inside a page, on the pasteboard, and at the moment its contents cross the protection boundary. It combines two established patterns: the **atomic attachment** (an image, mention, or embedded file in a rich-text editor) and **explicit declassification** (protected plaintext leaves only through an action that names that consequence).

A sealed item occupies one position in the document, but its plaintext is not part of the document’s ambient text.

*The governing law. It answers most interaction questions on its own.*

This historical draft grouped operations under two headings; Law 0001 replaces them with five classes:

#### Structural

- Move, select, cut, paste within the app, duplicate, delete, expire
- Act on the object; never touch its payload
- Undoable

#### Declassification

- Copy decrypted contents, decrypted drag from the handle, promote to a one-time link, plaintext export
- Plaintext crosses the boundary; the action names it
- Always explicit, always core-side

## Sealing retroactively

When plaintext is selected, offer **Seal Selection** in the context menu, **Edit → Seal Selected Content** in the menu bar, and optionally the same action in the command palette. Invoking it replaces the selection in place with one sealed object, preserves position and surrounding whitespace, selects the new object so the transformation is visible, and rejects selections that already contain a sealed object (sealed objects do not nest). No confirmation dialog for the ordinary case; the visible collapse into a card is the feedback.

Sealing is one-way in the editor (successor record D-30). An earlier draft offered **Unseal** as a named declassification and had ⌘Z invoke it as *Undo Seal Selection*; the record withdrew it, because an Undo that restored plaintext would be the one reveal path that names nothing. ⌘Z after sealing is not offered, and the content comes back only through *Copy decrypted contents*.

> **Honest scope.** Retroactive sealing protects the selection *from this point forward*. In artifact terms: after the next debounced write the stored page no longer contains the plaintext, and earlier file generations are covered by the boot-bound key. What remains is the shell’s layout and glyph caches and whatever the user pasted from. Never imply historical erasure.

## The sealed-object contract

This historical table used `structural`, `declassify`, and `ambient`; Law 0001 replaces them with five operation classes.

| Interaction                      | Kind                                  | Expected behaviour                                                                                                                                                                                                                                                                                                                                                |
|----------------------------------|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Arrow keys                       | `ambient`    | The caret crosses the object as one indivisible unit.                                                                                                                                                                                                                                                                                                             |
| Click                            | `structural` | Selects the whole object; never places a caret inside it.                                                                                                                                                                                                                                                                                                         |
| Shift-selection                  | `structural` | Includes the whole object or none of it.                                                                                                                                                                                                                                                                                                                          |
| Select All                       | `structural` | Includes the object structurally, not its plaintext.                                                                                                                                                                                                                                                                                                              |
| Copy (object or whole page)      | `structural` | Writes a versioned ordered fragment of visible ink runs and UUID references plus placeholders in plain text. No payload, no ciphertext.                                                                                                                                                                                                                          |
| Cut                              | `structural` | Writes the same fragment, then moves every referenced chip to the *detached* state, where the fragment shows in the app’s own clipboard slot and every chip retains the page’s clock (no per object TTL; successor record D-33). Never an invisible limbo.                                                                                                         |
| Paste inside OnetimePad          | `structural` | The core resolves each UUID reference. The first paste of a cut fragment reattaches its chips atomically; a copied fragment or later paste of a cut fragment clones live chips with new UUIDs and the same payload, on the page’s clock.                                                                                                                              |
| Paste into another app           | `ambient`    | The destination gets the placeholder `[sealed content · <size class>]` (successor record D-29). Never plaintext.                                                                                                                                                                                                                                                                                        |
| Drag within the document         | `structural` | Moves the object atomically with a clear insertion line. Contents never preview.                                                                                                                                                                                                                                                                                  |
| Option-drag                      | `structural` | Core-side clone, following the macOS copy-drag convention. No pasteboard involvement.                                                                                                                                                                                                                                                                             |
| Plain drag outside OnetimePad    | `ambient`    | Exposes only the placeholder.                                                                                                                                                                                                                                                                                                                                     |
| Decrypted drag (from the handle) | `declassify` | An explicit affordance on the card (a distinct handle, or a modifier-drag the card labels while held). Plaintext is supplied lazily via `NSPasteboardItemDataProvider`, so the core writes it only when a destination asks. A successful drop never deletes the chip.                                                                                             |
| Backspace beside it              | `structural` | First press selects the object; second press removes it.                                                                                                                                                                                                                                                                                                          |
| Backspace while selected         | `structural` | Removes it immediately, with Undo available.                                                                                                                                                                                                                                                                                                                      |
| Search and word count            | `ambient`    | Do not inspect the plaintext; optionally count one protected object.                                                                                                                                                                                                                                                                                              |
| Expiry                           | `structural` | A page’s expiry takes its sealed objects with it, detached ones included; there is no per object TTL (successor record D-33, maintainer decision 2026-08-07). A pasted reference whose object is gone resolves to an *expired* placeholder in place, visibly distinct from a removed one, and not undoable because nothing remains to restore. All of it holds at rest with the app not running (boot-bound key, refuse-to-reveal at next open). |
| Export, print, share             | `ambient`    | Emit the placeholder by default. Decrypting export is a separately named action.                                                                                                                                                                                                                                                                                  |
| Promote whole page               | `declassify` | Includes sealed payloads; that is the product. The confirmation says so: “includes 2 sealed items”. The local copy is offered up to burn, never burned automatically.                                                                                                                                                                                             |

## The card

The full-width card is an **atomic block attachment**, not an oversized button. A small drag handle appears on hover or selection; the decrypted-drag handle is visually distinct from it. While dragging, the whole card moves and its contents never preview. Once selected the object has a clear focus outline and deletes normally. Two-stage Backspace follows attachment conventions while preventing a nearby text-editing gesture from silently destroying protected content.

The object menu:

    Copy decrypted contents        ⇧⌘C
    Create one-time link…
    ────────────────────────
    Remove protected content

After a decrypted copy, confirm the boundary crossing with the core's interval: `copied decrypted contents — small. the clipboard clears in 60 seconds.` At that interval the core attempts a change-count-guarded clear and leaves the general pasteboard alone if another write replaced its own. This does not bound copies retained by clipboard managers. (Menu wording, chord and the line follow the 2026-09-15 stream navigator record, D-41 to D-43.)

## Pasteboard model

`NSPasteboard` lets one item advertise several representations, and receiving apps choose the one they understand (the same mechanism that supplies image, rich-text, and plain-text forms of a single copy). A sealed object writes:

- a private type, `com.onetimesecret.onetimepad.sealed-fragment` (with the `.debug` suffix on development builds), whose versioned payload is an ordered sequence of visible ink runs and sealed-object UUID references;
- the plain-text placeholder `[sealed content · <size class>]` (successor record D-29);
- a public URL representation *only* as the direct result of “Create one-time link”, never on an ordinary copy. A one-time link is itself a declassification: the first reader burns it, and a pasteboard-polling app is a reader.

Clipboard managers and Universal Clipboard do not pick a representation; they archive all of them and sync them to other devices. That is why the private type carries references and never a chip payload or ciphertext. D-31 specifies UUID references because the ledger already records the same random identifiers in plain. Mixed ink and multiple objects require the ordered fragment rather than a single UUID.

### Rejected ticket proposal

An earlier draft proposed minting a per-copy ticket and persisting a ticket-to-chip table in the content store. D-31 rejected that model. The governing design persists no ticket table: a fragment contains ordered visible ink runs and UUID references, while detach/reattach state remains in the core-owned content store.

The drag pasteboard uses the same multi-representation API, so decrypted drag is the same code path under a different pasteboard name, with the plaintext type present only when the drag starts from the explicit handle.

## Egress points

The successor record defines three complete-payload egresses: **copy decrypted** to the general pasteboard, **decrypted drag** to the drag pasteboard, and **promotion**. Complete-payload writes remain core-side. OnetimePad does not write decrypted drag data to the general pasteboard; no broader clipboard-history, observability, or end-of-drag erasure guarantee is made.

## Residual exposure

The placeholder carries a size class from `SizeClass` (`crates/core/src/ledger.rs`) and never a length, and it will sit in clipboard history under that label. Same exposure as the ledger, stated the same way. The size class replaces the earlier `· 51 characters` form, which leaked an exact length the ledger deliberately reduces to a class; an intermediate draft carried the page title instead, which the successor record D-29 retired.

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
Can structural edits be undone? (Sealing is the one exemption: it is one-way in the editor, per the successor record D-30.)

Safe fallback  
When a destination cannot understand the object, does it receive a placeholder rather than plaintext or nothing?

## Against the tenets

1\. Losing work is unforgivable, even here  
Sealing is one-way, so the copy names what it protects and from when (successor record D-30). A cut chip is visible in the clipboard slot, never orphaned. Expiry is on schedule and shown in place. A drop or promotion never deletes; burn is a separate act.

2\. The artifact transcends the application  
The governing design records attached and detached object state in the content store. Pasteboard fragments contain ordered visible-ink runs and UUID references, never a persisted ticket table, payload, or ciphertext. The page clock is enforced at rest as well as by the running process.

3\. Do not wag the dog  
Every departure from the ADR above (three egress points, decrypted drag as preferred path) is argued on merits, not citation, and is a candidate ADR amendment.

## Changes from the first draft

- **Undo of sealing** was “restore the plaintext”, then the named Unseal command. The successor record withdrew Unseal too: sealing is one-way, ⌘Z is not offered, and the undo stack holds no plaintext.
- **Paste inside OnetimePad** was “restores the complete sealed object, including its protected payload”. The private type carries a reference (the chip's UUID, per the successor record D-31); the core owns the payload throughout.
- **Drag outside OnetimePad** was placeholder-only with a vague exception for destinations that understand the format. It is now placeholder by default plus an explicit decrypted-drag handle, because the drag pasteboard is the safer declassification channel.
- **Placeholder** was `[sealed content · 51 characters]`, then `[sealed: <title>]`. It is now `[sealed content · <size class>]` (successor record D-29).
- **Cut** now defines the detached state instead of leaving an unpasted chip undefined.
- **Expiry** and **whole-page promotion** rows were added to the contract.
- **Retroactive sealing’s caveat** is restated in artifact terms; autosave is already under the boot-bound key, so undo history is not in the residual list once sealing is one-way.
