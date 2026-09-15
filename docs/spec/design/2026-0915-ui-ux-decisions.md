---
id: 2026-0915-ui-ux-decisions
title: UI/UX decisions for the background surface
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
supersedes: docs/spec/design/2026-0914-ui-ux-decisions.md; docs/design-brief.md (Tokens and parameters)
superseded-by:
reviewed: 2026-09-15
surfaces: OnetimePad (background surface)
sources:
  - docs/spec/design/03-design-principles.md
  - docs/spec/design/04-interaction-model.md
  - docs/spec/design/05-technical-direction.md
  - docs/spec/feature/background-surface/README.md
  - docs/spec/feature/sealed-content/sealed-content.md
  - docs/adr/0009-chip-deletion-deliberate-final.md
  - docs/adr/0012-framing-threat-boundary-and-persistence-model.md
  - docs/adr/0028-file-backed-documents-are-a-peer-content-class.md
  - shell/Sources/OnetimePad/BackdropStance.swift
  - shell/Sources/OnetimePad/Views/BackdropRootView.swift
  - shell/Sources/CompanionKit/PageSurface.swift
  - shell/Sources/CompanionKit/InkEditorView.swift
  - shell/Sources/CompanionKit/FileSurface.swift
  - shell/Sources/CompanionKit/SyncController.swift
  - shell/Sources/CompanionKit/SyncSettingsSection.swift
  - shell/Sources/CompanionKit/SettingsSections.swift
  - shell/Sources/CompanionKit/TimeRailView.swift
  - shell/Sources/CompanionKit/Theme.swift
---

# UI/UX decisions for the background surface

Supersedes `docs/spec/design/2026-0914-ui-ux-decisions.md` in full; section
10 lists what changed.

What the shipping surface looks like, what each visible decision is, and
what a build has to satisfy before the decision counts as honoured. The
illustrated companion (mockups with callouts) is the committed bundle
`docs/spec/design/UI-UX Decision Record - Sealed Content.html` beside this
record; it covers D-01 to D-33 despite its filename. The shipping surface
sets `sharingType = .none` and cannot be screenshotted, so every visual is
a recreation from this source tree.

## 0 · Pipeline and status

1. This file lives at `docs/spec/design/2026-0915-ui-ux-decisions.md`.
   Filenames are immutable once pushed.
2. The front matter above stays at the top. `status` and `superseded-by`
   are the only fields that change after the first push.
3. A decision that changes gets a **new** dated document. The old one is
   edited only to set `status: superseded` and to name its successor in
   `superseded-by`.
4. Pure errata (a wrong path, a wrong number, a misnamed symbol) with no
   decision content may be corrected in place with a dated note beside
   the correction. The 0914 text was silent on this; the rule is now
   stated.
5. Link the record from the ADR or issue that consumed it. An accepted
   record and a contradicting build are a bug report, not a
   disagreement.

Status vocabulary: **draft**: proposed, do not build against ·
**accepted**: the build owes this · **superseded**: history, kept for
the argument.

## 1 · The card and its two stances

Resting: one window level above the desktop, mouse-transparent,
`canBecomeKey` false, repaint every 30 s, contents at 0.72. Raised:
`.floating`, clickable, may become key, 1 Hz tick, full strength.
Raising and resting change **opacity only**: nothing reflows, resizes
or moves.

Header 32 tall, padded 12 horizontally; tab strip 32 at the bottom;
everything between is the page. Resizing grows the page, never the
chrome.

- **D-01 (fixed)** A resting surface never takes a keystroke. The
  keyboard map is mounted only while raised; a background surface that
  could silently receive keystrokes would be a keylogger-shaped bug.
  *Acceptance:* typing with the card resting reaches the frontmost app
  and nothing else; the keyboard map is not even mounted
  (`BackdropRootView` mounts `PageKeyboardMap` only when raised).
- **D-02 (fixed)** The stance change is opacity 0.72 → 1.0 over ~160 ms.
  No layout differs between the two stances; the same editor over the
  same storage, editing refused.
  *Acceptance:* both stances diff to within a pixel; under
  `prefers-reduced-motion` the transition is 0 ms and the end state
  identical.
- **D-03 (fixed)** Ember (`#DC4A22`) is a fill and geometry colour,
  never text, never the only carrier of state. Every ember signal is
  paired with a word, a texture, or a shape. Ember text uses the
  darkened `--ember-text`; `Theme.swift` carries `#DC4A22` and an
  `emberText` token. The header draft stamp and format facts draw
  `.secondary`, not `.tertiary`, since the stamp carries the age of
  unsaved typing and is text the app owes.
  *Acceptance:* greyscale the surface and read every state (keyline
  present or absent, hatch, dot beside a word); ember text clears 4.5:1
  on page and card, light and dark.
- **D-04 (open)** Is the resting card opaque or translucent? Today both
  stances share one material: `.ultraThinMaterial` in `BackdropRootView`
  (`BackdropRootView.swift:169`); the resting look is that material
  with contents at 0.72. The background-surface spec says transparent
  for both stances; the working copy's "resting: opaque fill" callout
  is a mockup artefact, not a decision. Whichever way this closes,
  Reduce Transparency lands on a solid system fill in either stance.
  *Acceptance:* under Reduce Transparency both stances draw a solid
  system fill.

The 1.5px ember keyline at 80% shows exactly while the surface **holds
the keyboard**. Raised and keyed are distinct facts: a card the user
⌘Tabbed away from is raised, unkeyed and unlit. The persistence word
(`saving` · `saved` · `save failed` · `not saving`) is words, not a
glyph, and absent until a write is owed. The pin is a real `Toggle` so
VoiceOver announces on/off. It sets the resting altitude, and it is
workable only while raised.

## 2 · The page: ink, markdown, fenced code

Monospaced, System Monospaced 13pt by default, user-settable 8 to 40.
The prose face is user settable to any installed family; only the code
family must be fixed pitch. Headings are proportions of the base (17/13,
15/13, 14/13 at semibold). Chip labels are base minus 2 at medium, never
below 8.

- **D-05 (fixed)** Markdown is styled, never rewritten: `### ` renders
  at heading weight with the hashes on screen, dimmed; fences keep their
  backtick rules; links keep brackets and parens.
  *Acceptance:* select-all-copy returns exactly what was typed. A
  renderer that hides markup is a specification breach.
- **D-06 (fixed)** Colour appears inside a fence and nowhere else, and
  only when the opening rule names a language (purple keywords, red
  strings, secondary comments, blue numbers). Highlighting off keeps the
  code font and the fence.
  *Acceptance:* the four token colours are the darkened ramp, each
  ≥4.5:1 on the fence wash in both appearances; the raw `NSColor`
  values stay available for a native build.
- **D-07 (fixed)** One editor persists across page switches; storage is
  swapped underneath it and the view carries no identity. Re-adding one
  would discard caret, scroll and undo on every tab change.
  *Acceptance:* caret, scroll and undo survive a tab change; Dynamic
  Type and a user font size from 8 to 40 reflow without clipping the
  heading ramp.

## 3 · Sealed content and the conceal flow

The governing model (atomic attachment plus explicit declassification,
structural versus declassification operations) is written out in the
behaviour law `docs/law/0001-sealed-object.md`; this section applies it
to the surface.

Sealed content is an **atomic block attachment**, like an image or an
embedded file in a rich-text editor, and it leaves the app only through
an action that names what crosses the boundary. One rule settles most of
what follows:

> A sealed item occupies one position in the document, but its plaintext
> is not part of the document's ambient text.

Every operation on a sealed item is one of two kinds, and that
distinction is the whole design.

- **Structural**: move, select, cut, paste within the app, duplicate,
  delete, expire. They act on the object, never on its payload. They are
  undoable (D-30).
- **Declassification**: copy decrypted contents, decrypted drag from
  the handle, promote to a one-time link, plaintext export. Plaintext
  crosses the boundary, the action names it, and the write is always
  core-side.

There is no reveal affordance at any privilege, so no label may imply
one.

### The block

Full measure, 8px radius, hairline border, padded 8 × 12. A tracked
`SEALED CONTENT` label with a lock over the mechanical excerpt, and the
size class right-aligned as metadata, never a count. The mechanical
excerpt is head…tail, at most 24 plaintext characters and never more
than a third of the content, computed by the core (`text_face` in
`crates/core/src/sheet.rs`; a multi-line secret shows the head of its
first line only). It is the one plaintext the block shows, and it only
has to be recognised by the person who pasted it. Nothing beyond the
mechanical excerpt is ever drawn, in any state. A move handle (⠿)
appears on hover or selection and never otherwise; beside it, visually
distinct and labelled *drag decrypted*, the decrypted-drag handle: the
one place on the card where a drag carries plaintext. Selected, the
block takes a focus outline.

### Sealing a selection after the fact

With plaintext selected: **Seal Selection** in the context menu,
**Edit → Seal Selected Content** in the menu bar, and optionally the
same action in the command palette. It replaces the selection in place
with one sealed object, keeps the surrounding whitespace, and selects
the new object so the transformation is visible. Sealed objects do not
nest, so a selection containing one is refused. No confirmation dialog;
the visible collapse is the feedback.

**Sealing is one-way in the editor**, and it is the single exemption
from the reversibility rule that structural edits share. An Undo that
restored the plaintext would be the one reveal path that names nothing
(it fails Legibility) and it would force the shell to keep the plaintext
alive in its undo stack, which is the opposite of "from this point
forward". ⌘Z after sealing is not offered; the content comes back only
through *Copy decrypted contents*. Removing a sealed object is
structural and undoable (D-30); sealing is the only one-way edit.

Honest scope: sealing protects the selection **from this point forward**.
Autosave is already written under the boot-bound key, and the undo stack
never held the plaintext because sealing is one-way, so the real
residuals are narrow: the shell's layout and glyph caches, and whatever
the user pasted from. The copy names those and never implies historical
erasure.

### The sealed-object contract

`ambient` reads the object without reading its payload: the page's
ordinary text machinery, which must treat the chip as one opaque unit.

| Interaction | Kind | Expected behaviour |
| --- | --- | --- |
| arrow keys | ambient | the caret crosses the object as one indivisible unit |
| click | structural | selects the whole object; never places a caret inside it |
| shift-selection | structural | includes the whole object or none of it |
| select all | structural | includes the object structurally, not its plaintext |
| copy, object or whole page | structural | writes the chip's UUID in the private type plus the placeholder in plain text; no payload, no ciphertext |
| cut | structural | writes the UUID, then detaches the chip from the page; a detached chip shows in the app's own clipboard slot, on the page's clock. Never an invisible limbo |
| paste, inside OnetimePad | structural | the core reattaches the chip by id at the new position; a paste after copy, or a second paste of a cut, is a core-side clone with a new UUID and the same payload, on the page's clock. A reference whose chip is gone resolves to the *expired* placeholder in place, never a resurrection |
| paste, another app | ambient | the destination gets the placeholder `[sealed content · small]`. Never plaintext |
| drag, inside the document | structural | moves the object atomically with a clear insertion line; contents never preview |
| ⌥-drag | structural | a core-side clone, following the macOS copy-drag convention; no pasteboard involvement, and no second copy of the bytes outside the core |
| plain drag, outside | ambient | exposes only the placeholder |
| decrypted drag, from the handle | declassify | an explicit affordance on the card: a distinct handle, or a modifier-drag the card labels while held. Plaintext is supplied lazily through `NSPasteboardItemDataProvider`, so the core writes it only when a destination asks. A successful drop never deletes the chip |
| backspace beside it | structural | the first press selects the object, the second removes it; the removal is undoable |
| backspace, selected | structural | removes it immediately, with undo available; the core keeps the bytes, so ⌘Z restores the object, never plaintext in the shell |
| find, word count | ambient | do not inspect the plaintext; optionally count one protected object |
| expiry | structural | a page's expiry takes its sealed objects with it, detached ones included. A detached object and its id live in the content store on the page's clock and die when the page expires; there is no per object TTL (doc 04 :155, maintainer decision 2026-08-07). A pasted reference whose object is gone resolves to an *expired* placeholder in place, visibly distinct from a removed one, and not undoable because nothing remains to restore. All of it holds at rest with the app not running: boot-bound key, refuse-to-reveal at next open |
| export, print, share | ambient | emit the placeholder by default; a decrypting export is a separately named action |
| promote the whole page | declassify | includes sealed payloads; that is the product. The confirmation says so: `includes 2 sealed items`. The local copy is offered up to burn, never burned automatically |

### Pasteboard model

`NSPasteboard` lets one item advertise several representations and a
receiving app takes the one it understands, the same mechanism that
supplies image, rich-text and plain-text forms of a single copy. A
sealed object writes:

- a private type, `com.onetimesecret.onetimepad.sealed-ref` (with the
  `.debug` suffix on dev builds, so dev and prod cannot resolve each
  other's references), carrying the **chip's UUID and nothing else**;
- the plain-text placeholder `[sealed content · small]`;
- a public URL representation *only* as the direct result of Create
  one-time link, never on an ordinary copy. A one-time link is itself a
  declassification: the first reader burns it, and a pasteboard-polling
  app is a reader.

Never the payload. "Restores the complete sealed object, including its
protected payload" would put ciphertext on `NSPasteboard`, where every
clipboard manager archives it and Universal Clipboard syncs it to other
devices. The UUID is the same random id the ledger already records in
plain: the same exposure as the ledger, stated the same way, and the
record chose it over a minted per copy reference because that would
buy a map in the core and a staleness path for no exposure the ledger
does not already carry. The core owns the bytes and identifies
chips by UUID, so cut detaches, paste reattaches by id, and a duplicate
is a core-side clone. Nothing about the secret ever leaves the process.

**The detached state.** A cut chip is detached, not destroyed. It leaves
the page, shows in the app's own clipboard slot, and is reattached by
the next paste. A detached object takes its page's clock: it dies when
the page expires, and a reference whose chip is gone resolves to
*expired*, so the paste inserts the expired placeholder rather than
failing. Quitting between cut and paste is survivable, because the
detached chip and its id live in the content store, not on the
pasteboard.

The drag pasteboard uses the same multi-representation API, so decrypted
drag is the same code path under a different pasteboard name, with the
plaintext type present only when the drag starts from the explicit
handle.

### Declassification, and the three egress points

The object's own menu is where plaintext is offered by name:

```text
Copy decrypted contents
Create one-time link…
────────────────────────
Remove protected content
```

After a decrypted copy, one line confirms the boundary crossing with the
interval the core enforces:
`decrypted contents copied · clipboard clears in 60 seconds`. The
interval is one core constant, `CLIPBOARD_CLEAR_SECONDS` (60) in
`crates/ffi`, read by the shell through the stateless seam
`companion_clipboard_clear_seconds`; the model arms the clear on every
pasteboard egress (`PageModel.swift` `armClipboardClear`), and the
confirmation states that number. A clear the app does not perform is
never promised.

ADR-0012 named one egress (send) at line 103. This record makes it
three, **copy decrypted**, **decrypted drag**, **promotion**, and the
ADR's Amendment 1 (2026-09-15) adopts them. All three are core-side
writes, so the Swift shell still never holds plaintext.

They are not equally safe, and the card's affordances reflect that. Copy
decrypted goes through the general pasteboard (clipboard managers,
Universal Clipboard, polling apps), the channel ADR-0012 calls the
existential risk. A decrypted drag goes through the drag pasteboard,
never enters clipboard history or Universal Clipboard, and matches the
ergonomic the product already teaches: drag in, drag out. The
decrypted-drag handle is the recommended way to get a secret into a
form field; copy decrypted is the fallback for destinations that take no
drop.

The plain-text placeholder therefore carries a **size class**, not a
length: `[sealed content · small]`. An exact character count is
precisely what the ledger reduces to a class (`SizeClass`,
`crates/core/src/ledger.rs`), and it would sit in clipboard history
forever. The private type's UUID is the same random id the ledger
already records in plain: the same exposure as the ledger, stated the
same way.

### The rubric for any new interaction

- **Atomicity**: does the sealed item behave as one object?
- **Non-disclosure**: can this ordinary action reveal plaintext
  unexpectedly?
- **Fidelity**: can the object move through trusted app operations
  without losing its payload?
- **Legibility**: does the action name what crosses the boundary?
- **Reversibility**: can structural edits be undone? One exemption:
  sealing is one-way in the editor, because an unnamed Undo that
  revealed plaintext would breach Legibility.
- **Safe fallback**: when a destination cannot understand the object,
  does it get a placeholder rather than plaintext or nothing?

- **D-08 (fixed)** No plaintext, ever, in the UI: no reveal, no eye
  toggle, no copy-to-see-it. The bytes are not available to draw. ⇧⌘V
  over a line already holding a chip refuses: `already sealed · a chip
  has no plaintext to seal`. (The core's own vocabulary still says
  "chip"; the UI says nothing at all about the shape, so the internal
  name can stay.)
  *Errata 2026-09-15:* the refusal line above was quoted with an em
  dash; the shipping string joins its two halves with a middle dot,
  as the copy register (D-15) asks, and the quote now matches it.
  *Acceptance:* find cannot match a chip; ⌘E over a selection holding
  one refuses; a chip leaves only by an act aimed at the chip.
- **D-09 (fixed)** Concealing is the app's one outbound action:
  discoverable on every chip, prominent on none. Never a hero button,
  never a side effect. The confirming click is the network boundary and
  the destination is always named. The confirmation is inline and never
  a modal: the boundary named, then the clipboard line and **Burn local
  copy**. On a page target the sheet says how many sealed items travel
  (`includes 2 sealed items`).
  *Acceptance:* inline sheet, no modal, no focus theft; the link's TTL
  is never seeded from the page's remaining time; failure is inline text
  and the button becomes Retry; the local copy is offered up to burn and
  never burned automatically.
- **D-10 (fixed)** Hover reveals affordances, never content, and the
  affordance keeps its seat whether visible or not (~120 ms opacity,
  0 ms under Reduce Motion): revealing it never nudges the ink or
  reflows the row.
  *Acceptance:* every hover action is also in the row's context menu
  (copy out, ↗ conceal, remove), so a pointer is never required; the
  row is not a focusable control and a click only places the caret.
- **D-27 (fixed)** Sealed content is a full-measure block, not an inline
  pill: 8px radius, hairline border, a tracked `SEALED CONTENT` label
  with a lock over the mechanical excerpt, the size class right-aligned
  as metadata (never a count), and nothing that reads as pressable. The
  pill shape invited a press that nothing answers. The excerpt still
  only has to be recognised by the person who pasted it.
  *Owed:* this overrules the shipping treatment, `ChipCell` in
  `shell/Sources/CompanionKit/InkEditorView.swift`, which draws
  `[ excerpt · size ]` at intrinsic width; the archived Airlock canvases
  drew an inline pill and are history. There is no design system
  component to follow; the only `SealedChip` in the tree is the Rust
  type. Tracked as "Sealed block: full-measure attachment replaces
  ChipCell (D-27)" (issue 169).
- **D-28 (fixed)** A sealed item is one object in the document and its
  plaintext is not part of the document's ambient text. Structural
  operations act on the whole object; the caret never lands inside it
  and sealed objects never nest.
  *Acceptance:* the contract table is the test list.
- **D-29 (fixed)** Declassification is always an explicit, separately
  named action (*Copy decrypted contents*, *Create one-time link…*, a
  decrypted drag from the handle, a plaintext export) in the object's
  own menu or on its own handle, never on the ordinary copy path. Every
  other destination gets `[sealed content · small]`: a size class, never
  an exact length.
  *Acceptance:* a plain drag outside the app exposes the placeholder
  only; the decrypted-drag handle is visually distinct from the move
  handle; the confirmation names the interval the core enforces; no
  ordinary copy path (object, page, or select-all) offers plaintext.
  The 60 second clear is implemented: one core constant,
  `CLIPBOARD_CLEAR_SECONDS` in `crates/ffi`, read by the shell through
  the stateless seam `companion_clipboard_clear_seconds`, and armed by
  the model on every pasteboard egress.
- **D-30 (fixed)** Sealing an existing selection replaces it in place,
  keeps the surrounding whitespace and selects the new object, and is
  **one-way**: ⌘Z does not restore the plaintext. No confirmation
  dialog. Removing a sealed object is **structural and undoable**: the
  first backspace beside it selects, the second removes, and ⌘Z puts
  the object back. The core owns the bytes throughout, so undo restores
  a reference and the shell never holds plaintext for it. ADR-0009's
  non undoable removal clause is superseded on this point; its Decision
  history says so.
  *Owed:* the core zeroizes a chip the moment a synced document stops
  referencing it (`store.rs` `sync_document`, per ADR-0009's context),
  so a removed chip cannot yet come back; the detached state the
  pasteboard model defines (D-33) is what undo restores from, and the
  build owes it under issue 170.
  *Acceptance:* nothing in the undo stack holds the plaintext, and the
  content returns only through *Copy decrypted contents*; removing a
  sealed object is undoable; the copy protects the selection "from
  this point forward", naming the real residuals: layout and glyph
  caches, and whatever the user pasted from.
- **D-31 (fixed)** The in-app pasteboard type carries the chip's UUID,
  never its payload. Clipboard managers and Universal Clipboard archive
  every representation they are offered, so ciphertext on the
  pasteboard is ciphertext in a history file on another device. The
  UUID is the random id the ledger already records in plain, so the
  pasteboard adds no exposure the ledger does not carry, and a minted
  per copy reference would buy a map in the core for nothing. Tracked
  with D-33 as "Sealed object pasteboard model: private type,
  placeholder, detach on cut, reattach on paste, lazy decrypted drag
  (D-29, D-31, D-33)" (issue 170).
  *Acceptance:* cut, quit, relaunch, paste still works, because the
  detached chip lives in the content store; a reference whose chip is
  gone resolves to *expired* and inserts the expired placeholder rather
  than failing; no secret byte is written to any pasteboard except at a
  named declassification.
- **D-32 (fixed)** Three egress points, not one: copy decrypted,
  decrypted drag, promotion. The decrypted drag is the recommended path
  into a form field; copy decrypted, on the general pasteboard, is the
  riskier fallback. The clear-on-egress interval ADR-0012 already
  mandates (line 104, unnumbered there) is the number the core uses: 60
  seconds, owned as one core constant. ADR-0012's Amendment 1
  (2026-09-15) adopts the three egress points in place of the one at
  line 103. All three are core-side writes, so the shell holds no
  plaintext at any point.
- **D-33 (fixed)** A cut chip is detached, not destroyed: it leaves the
  page, shows in the app's own clipboard slot, and is reattached by the
  next paste. A detached object takes its page's clock; there is no per
  object TTL. When the page expires, its sealed objects go with it,
  attached or detached, and a reference pasted afterwards resolves to
  an *expired* placeholder, visibly distinct from a removed one.
  *Acceptance:* expiry is not undoable and the copy does not offer undo;
  a page's expiry takes its chips with it, detached ones included; both
  hold at rest with the app not running, under the boot-bound key; no
  timer exists per chip.
  *Note 2026-09-15:* the 0914 record gave each chip its own TTL. That
  clause is dropped, the one deliberate deviation from the record: the
  core forbids per chip timers (`sheet.rs` :292, doc 04 :155) and the
  maintainer rejected per block TTL on 2026-08-07.

### Amended since the first draft

The working copy carried this list; it is kept as the argument's
history. One of its sentences (an unpasted chip dying by its own TTL)
was dropped on 2026-09-15; D-33 and section 10 have the current
reading.

Sealing is one-way. "Allow Undo to restore the plaintext" is withdrawn:
it was the one reveal path that named nothing, and it kept the
plaintext in the shell's undo stack. Sealing is exempt from the
reversibility rule; removal stays undoable.

The in-app pasteboard type carries the chip's UUID, not "the complete
sealed object, including its protected payload". Cut detaches, paste
reattaches by id, ⌥-drag clones core-side, and an unpasted chip dies by
its own TTL.

Drag-out was backwards. A decrypted drag never touches clipboard history
or Universal Clipboard, so it is the safer declassification and now the
recommended path into a form field; copy decrypted is the riskier
fallback. Plain drag stays placeholder-only.

The placeholder was `[sealed content · 51 characters]`, an exact length
the ledger deliberately reduces to a class. It is now
`[sealed content · small]`.

Three egress points (copy decrypted, decrypted drag, promotion) are
named here for the ADR to adopt, all core-side. Whole-page promotion
joined the contract as the one operation that includes sealed payloads,
and expiry and the detached cut state are defined rather than left
open.

## 4 · How pages are organized, and where they live

**Two settings, not one.** The build flips both with a single switch
today, which is why the surface had to be described in code names
("the strip", "the rail") that mean nothing to a person. What a tab *is*
and where navigation *sits* are independent:

- **Organize pages by**: Slots · Days (time tabs)
- **Show pages**: Along the bottom · Down the side

Slots are pages you name and close yourself; days group live pages by
the day they were written, newest first, and move no content.

All four combinations are supported states. Slots, bottom: the
spreadsheet idiom, today's shipping default. Slots, side: titles that
are sentences read down a column untruncated. Days, side: chronology is
vertical, and the intended default. Days, bottom: a left-to-right
timeline that keeps the page's full width.

Metrics do not change with the choice. Along the bottom: 32 tall,
padded 6 × 4, 2 between tabs, title row 18, gauge 3, capped 140 wide,
`+` pinned right, groups `FILES` then `PAD`. Down the side: 96 wide,
eating into the page's column and never into the header, rows padded 4
vertically, blank count at the foot in words. The two orientations are
exclusive: a side column of days with a bottom strip underneath would
be the same slots counted twice.

Dash vocabulary: `2 3` a slot holding no page · `3 2` clock held for an
hour · `7 2` hold topped up to 24h · `2 1.5` ember and hatched, under
one hour · `4` on a border, ledger residue · draining: solid, the
remaining fraction. A gauge at zero is never used for "empty"; it would
read as a page an instant from death rather than a slot standing ready.

- **D-11 (fixed)** Time is geometry that drains, not animation and not a
  ticking number. Gauges are per tab and short; the full-width page-edge
  bar was removed in dogfooding for impersonating a scroll bar.
  *Acceptance:* every gauge speaks rounded words ("about 7 hours
  remaining"); held is dash *and* a ⏸ chip; last hour is hatch *and*
  ember; Reduce Motion changes nothing about what is readable; the
  spoken forms are "clock held" for a held tab, "empty slot" for a
  blank slot and "no page" for a blank day.
- **D-12 (fixed)** A tab's title is the page's first typed line with
  markup stripped, "untitled" if none. A file is a navigation peer, not
  a slot: an unsaved ember dot sits where a page draws its gauge,
  because a countdown on a file would promise an expiry that never
  comes.
  *Acceptance:* strip and rail speak a file identically; the row says
  "unsaved" in words and the dot is never the only cue; the tooltip is
  the last known path.
- **D-13 (open)** Days is gated on parity with slots: renaming,
  holding, shortening, closing and sync enrolment on each day's own
  gutter. The gutter carries all five today (`DayScrollView.swift`,
  the day context menu). Days still ships labelled a prototype and the
  shipping default stays Slots + bottom, even though Days + side is
  where the default is headed; the default does not flip before D-26's
  two settings exist, or Days + side would ship as the only
  alternative. There is no page cap to design for: the core has had
  none since issue #158 (`PageModel.swift:3373`), so no refusal is
  drawn. What remains open is when the prototype label comes off and
  the default flips.
- **D-26 (fixed)** Two settings, four combinations, as above. The single
  switch that flips grouping and orientation together is the defect this
  replaces: it pushed code names into user-facing copy and left one
  axis unreachable. "Strip" and "rail" stay code names and never appear
  in the UI. Tracked as "Split the Days switch into Organize pages by
  and Show pages (D-26)" (issue 171).
  *Acceptance:* each setting persists independently and every
  combination is a supported state; a mode flip moves no content and
  writes nothing new to disk; each caption says what the choice costs as
  well as what it does; time-related settings sit under the Days choice.

## 5 · Status lines and notices

12 × 4 padding, `.caption` monospaced, ember only for what needs acting
on, absent unless they have something to say; the layout reserves no
room. Everything sits between the page and the tabs. A standing
condition persists for the session; a notice is transient. Precedence,
in draw order: content-restore failure · ledger failure · sync standing
sentence · remote-edit line · pasteboard offer · notice · conceal sheet.

- **D-14 (fixed)** No modals, no interrupting dialogs, no notifications,
  badges, bounce or count chips. A condition speaks in a line under the
  page; the one confirmation the app asks for is inline. Destructive
  Settings actions are the one exception and use the platform
  confirmation. `NSOpenPanel` and `NSSavePanel` are platform file
  pickers the user asked for, not app dialogs. The build's four
  dialogs (the quit alert, the close review of a dirty file, the Take
  theirs confirmation and the tab rename alert) are defects against
  this decision, tracked as "Replace the four interrupting dialogs with
  inline surfaces (D-14, D-19)" (issue 172).
  *Acceptance:* every interaction completes without the surface becoming
  key unless the user deliberately raised it. An unexpected focus change
  is destructive for assistive tech, so this is an a11y rule, not
  etiquette.
- **D-15 (fixed)** Copy register: lower-case sentences, third person, em
  dash and middle dot doing real work, no exclamation marks, `…` as one
  character. Second person only in tooltips and a11y labels.
  *Banned:* "3 items expiring soon", "Are you sure?" on expiry,
  onboarding or celebratory copy, "your secrets are safe with us", and
  any label implying content can be revealed.
- **D-16 (fixed)** The empty state is one calm sentence ("Empty is the
  resting state.") over a hint naming the gesture that works on this
  surface and stance. No illustration, no onboarding flow.
  *Acceptance:* raised: "click, ⌃⌥Space, or ↩ for a page" · pinned rest:
  "click or ⌃⌥Space raises the surface" · unpinned rest: "⌃⌥Space raises
  the surface".

## 6 · Files and the unsaved state

A file replaces what the surface was showing and puts its own identity
where the product name stands: name · unsaved dot + word · draft stamp
`Thu 14:32` when restored from drafts · `UTF-8 · Markdown` (+ `· CRLF`).
The question the header answers on a file surface is which file this is
and whether it is on disk. Spoken as one sentence: "runbook.md, unsaved,
last edited Thu 14:32".

Two banners can stand above the editor. The conflict banner:
"runbook.md changed on disk and this copy has unsaved edits. saving is
refused until one copy is chosen." with **Keep mine** · **Take theirs**
· **Save As**. The render suggestion banner: "render as ruby?" with
**Use Ruby** · **Keep Plain Text** · **Choose Language…** · **Dismiss**.
Both banners: 12 × 5 padding, above the editor, nonmodal, editing never
blocked while they stand (status lines stay 12 × 4).

- **D-17 (fixed)** A conflict refuses the save, never the typing. Three
  actions in reading order, named by what they keep, with Save As (the
  one that destroys nothing) last and under the return key.
  *Acceptance:* the sentence is a pure function of conflict and
  filename; the two conflict kinds are testable as words rather than as
  a drawn banner.
- **D-18 (fixed)** Two "saved" words never show at once: a file's word
  replaces the session's. Render mode is session state and never
  encoded with the file or its draft.
  *Acceptance:* a render-mode change leaves the bytes identical; the
  suggestion banner never edits text storage.
- **D-19 (fixed)** No save sheet on quit; the draft's age in the header
  is what the app owes instead, so a person can judge how old the typing
  is before pressing the save chord. The build's Quit Anyway / Cancel
  alert is a defect against this decision, tracked with D-14's three
  others as issue 172.
  *Acceptance:* the stamp shows only for a draft-restored buffer, in
  `EEE HH:mm` with a 24-hour clock whatever the locale; quitting with
  dirty files asks nothing.

## 7 · The sync surface

Off by default; off is silence. On, sync speaks in two places: one
lower-case header word chosen by the gate the core reports (the shell
infers nothing), and one standing sentence under the page.

| word | tone | when |
| --- | --- | --- |
| *(nothing)* | none | off, or on with no relay configured |
| synced | quiet | attached; the chosen pages travel |
| sync waiting | plain | enrolled pages, no other device awake |
| reaching | plain | signed in, attaching to the relay |
| sync signed out | plain | on and signed out; the pad is unaffected |
| signing in | plain | waiting on the browser |
| sync offline | loud | relay unreachable; edits stay local, retrying |
| sync refused | loud | the account refused the sign-in |
| sync behind | loud | behind a key rotation; outranks the gate |

The Sync settings section is titled "Sync between your devices" and its
caption reads: "Off by default, and off means nothing: no account, no
network, no change. On, pages you choose travel sealed between devices
you pair yourself by comparing six digits on both screens." Pairing
shows six digits under the prompt "Compare with the other device's
screen. Continue only on a match." with **They match** and **They
don't match** side by side. Device rows carry a short id, a name, a
last-seen stamp and a state word (attached · away · attached, never
paired).

- **D-20 (fixed)** Off is indistinguishable from sync not existing: no
  word, no sentence, no section beyond the switch itself. A working
  channel is not news, so the settled state is quiet; the two states a
  user must act on are loud.
  *Acceptance:* the word table is derived from the gate and unit
  testable without a window; "synced" is never shown with no peer awake.
- **D-21 (fixed)** A comparison that cannot fail verifies nothing:
  "They don't match" is always offered beside "They match". A device
  nothing vouches for reads *attached, never paired*, in ember and in
  words.
  *Acceptance:* a browser sign-in trip always offers "Give up", drawn
  only while a trip exists; every revoke and sign-out states what it
  does and does not touch.
- **D-22 (fixed)** A remote edit is a word, never a dialog ("another
  device is editing this page"), and it sits with the page's status
  lines, not in the header, because the edits are already merging and
  there is nothing to decide.
  *Acceptance:* it is a fact about this page, not about the channel.

## 8 · Settings

One small window, four grouped forms: General · Code · Connection ·
Sync. Every section carries a caption that says what the switch does
**and what it costs**; a toggle whose caption promised only the good
half is the kind of setting a user flips once and then distrusts.
General and Code save on each flip; Connection holds fields in draft
until Save, because a half-typed server URL is not a setting anyone
wants applied.

Copy the forms carry:

- Font (General), default System Monospaced 13: "The page's face and
  size. Name a family as the system does (Menlo, JetBrains Mono); leave
  it empty for the system monospaced font. Sizes run from 8 to 40
  points. Headings scale with the size."
- Deadline rounding, a toggle under the Days choice: "Round a page's
  deadline up to the hour, or to midnight", captioned "A rung names a
  duration; this lets the deadline land where the clock does. Under a
  day it rounds up to the next whole hour, from a day up to the next
  midnight, and never by more than a day. Pages already counting down
  keep the deadline they have."
- Capture opt-out: "Allow screenshots of the surface", captioned "Shown
  because this app was launched with COMPANION_ALLOW_CAPTURE. It lifts
  the screen-capture exclusion until the app quits, and an ordinary
  launch offers no such switch."
- API token (Connection): placeholder `•••• stored in the Keychain`,
  captioned "The token goes straight to the Keychain and is never shown
  again."

- **D-23 (fixed)** Native and plain: SwiftUI `Form`, grouped style,
  system font for captions, monospace only for app-written status. No
  custom controls, no invented switch art.
  *Acceptance:* Increase Contrast, Reduce Transparency, Dynamic Type and
  full keyboard access come from the platform and are not
  re-implemented.
- **D-24 (fixed)** The API token field is write-only; what is stored can
  never be read back into the UI, and the placeholder only says one is
  held. A refused setting shows the system's actual state, never a wish
  as a fact.
  *Acceptance:* Test saves first so it tests what will be kept; a
  refused URL says `refused: the server URL must be https://…`.
- **D-25 (fixed)** A control appears only where it can work: the capture
  opt-out in a debug build or a release launched with
  `COMPANION_ALLOW_CAPTURE`; the ledger clear only while the surface is
  telling the user to come and use it. A button whose instruction has
  no button is a dead end.
  *Acceptance:* while the opt-out is on the header flies the camera
  indicator, and the opt-out is never persisted across a quit.

## 9 · Acceptance bar, whole-surface

Accessibility is the acceptance bar, not a polish pass. A build that
fails any row fails the design, whatever it looks like. Run these
against both appearances before a surface change is called done.

1. Colour is never the only carrier: greyscale it and every state is
   still readable through a word, a texture, or a shape.
2. Every visual signal has a text equivalent; remaining life in rounded
   words, ledger stamps absolute, never relative, because the ledger
   outlives a reboot.
3. Reduce Motion: all transitions 0 ms, nothing becomes unreadable,
   because no signal was animation-only to begin with.
4. Increase Contrast / Reduce Transparency: surfaces degrade to solid
   system fills, drawn from the system palette rather than hand-picked.
5. Contrast: every text-carrying token ≥4.5:1 in light and dark. Ember
   is a fill; ember text is the darkened value.
6. Focus: nothing makes the surface key but a deliberate raise; resting
   cannot take a keystroke.
7. Dynamic Type and user font size 8 to 40: the ramp keeps its
   proportion, chrome stays 32 top and bottom, the page absorbs the
   difference.
8. Light and dark are both acceptance criteria; this is not a
   light-first design with a dark skin.

Iconography: SF Symbols by name in Swift (`plus`, `xmark`, `pause.fill`,
`arrow.up.right`, `pin`/`pin.fill`, `camera.fill`, `circle.dashed`,
`doc`, `checkmark.circle`, `arrow.up.left.and.arrow.down.right`). SF
Symbols cannot be redistributed, so web mockups substitute matching
Unicode characters. Never an icon font, an SVG sprite, or PNG icons.

## 10 · Amended since 2026-0914

One line per substantive change from the 0914 record. Corrections of
fact and absorbed working-copy sentences are not listed unless they
moved a decision.

- Section 0: `superseded-by` joins `status` as a mutable field; pure
  errata may be corrected in place with a dated note.
- Intro: the illustrated companion is named as the committed bundle
  beside this record, not "with the design record".
- Section 3: the governing model is named as living in the behaviour
  law `docs/law/0001-sealed-object.md`.
- D-03: `Theme.swift` is aligned to `#DC4A22` with an `emberText`
  token; the header draft stamp and format facts draw `.secondary`.
- D-04: stays open, restated with the shipping fact that both stances
  share `.ultraThinMaterial`.
- D-13: stays open. The cap paragraph is struck; no cap exists since
  issue #158. Sync enrolment joins the gutter verb set, and the gutter
  carries all five verbs today.
- D-14 and D-19: unchanged in substance. The build's four dialogs are
  named as defects and tracked as issue 172.
- D-20: unchanged; the acceptance line stands as the 0914 record wrote
  it, and the code is fixed to match.
- D-27: the "design system's `SealedChip`" clause is removed; no such
  component exists, the only `SealedChip` is the Rust type. Metadata is
  the size class, never a count; the mechanical excerpt is defined from
  `sheet.rs`.
- D-30, the structural list, the contract's backspace rows and the
  rubric: removal of a sealed object stays structural and undoable, as
  the 0914 record had it; the two-stage backspace is written into the
  contract rows. ADR-0009's non undoable removal clause is superseded
  on that point and its Decision history records it.
- D-31, the contract's copy, cut and paste rows and the pasteboard
  model: unchanged, the private type carries the chip's UUID; the
  reason it was chosen over a minted per copy reference is now written
  down.
- D-29, D-32 and the confirmation paragraph: ADR-0012 is named (line
  103 for the one egress, line 104 for the unnumbered interval); the
  interval is 60 seconds as one core constant, `CLIPBOARD_CLEAR_SECONDS`,
  implemented and armed on every pasteboard egress; ADR-0012's
  Amendment 1 adopts the three egress points.
- D-33, the contract's cut, paste and expiry rows and the detached
  state: every per object or per chip TTL is removed. A detached object
  takes its page's clock and the expired placeholder appears when the
  page expires (maintainer decision 2026-08-07); the dated note under
  D-33 records the deviation.
- D-09: the conceal confirmation names its button, Burn local copy.
- The feature-scale items are linked by issue: the sealed block (D-27,
  issue 169), the pasteboard model (D-29, D-31, D-33, issue 170), the
  split Days setting (D-26, issue 171) and the four dialogs (D-14,
  D-19, issue 172).
