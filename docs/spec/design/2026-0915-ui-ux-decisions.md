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

The governing model (atomic attachment, explicit declassification and the
five operation classes) is written out in the behaviour law `docs/law/0001-sealed-object.md`; this section applies it
to the surface.

Sealed content is an **atomic block attachment**, like an image or an
embedded file in a rich-text editor, and it leaves the app only through
an action that names what crosses the boundary. One rule settles most of
what follows:

> A sealed item occupies one position in the document, but its plaintext
> is not part of the document's ambient text.

Every interaction involving a sealed item belongs to one of five classes:

- **Ambient observation**: caret movement, find, word count and public
  fallback representations inspect the document without reading payloads.
- **Structural editing**: move, select, reference-only copy, cut, in-app
  paste, clone and remove-from-page act on document structure.
- **Classification**: sealing turns visible ink into a sealed object and is
  one-way in the editor.
- **Declassification/egress**: copy decrypted contents, decrypted drag,
  promotion to a one-time link and plaintext export send the complete
  payload through a named consequence. Payload writes remain core-side.
- **Destruction/lifecycle**: page expiry and explicit burn destroy payload
  bytes and are not undoable.

`refused` is an outcome, not an operation class.

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

With visible ink selected: **Seal Selection** in the context menu,
**Edit → Seal Selected Content** in the menu bar, and optionally the
same action in the command palette. It replaces the selection in place
with one sealed object, keeps the surrounding whitespace, and selects
the new object so the transformation is visible. Sealed objects do not
nest, so a selection containing one is refused. No confirmation dialog;
the visible collapse is the feedback.

**Sealing is one-way in the editor.** It is classification rather than a
structural edit, so the reversibility rule for structural editing does not
apply. An Undo that
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

`ambient observation` reads the object without reading its payload: the
page's ordinary text machinery treats each sealed object as one opaque unit.

| Interaction | Kind | Expected behaviour |
| --- | --- | --- |
| arrow keys | ambient observation | the caret crosses each object as one indivisible unit |
| click, shift-selection, select all | structural editing | selects whole objects, never a caret or partial selection inside one |
| copy, object or mixed selection | structural editing | writes a versioned ordered fragment of ink runs and UUID references; its public text preserves ink and substitutes one size-class placeholder per reference; neither form carries payload or ciphertext |
| cut | structural editing | writes the same fragment, then detaches all referenced objects in one core transaction and shows them together in the app clipboard slot |
| paste, inside OnetimePad | structural editing | inserts the fragment as one undoable transaction; a first cut paste reattaches all cut objects, and later or copied pastes clone live references core-side; terminal and unknown references become cause-specific placeholders in position |
| paste, another app | ambient observation | receives ordered ink and size-class placeholders, never payloads |
| drag, inside the document | structural editing | moves the selected objects and ink atomically; contents never preview |
| ⌥-drag | structural editing | clones all selected objects core-side as one operation |
| plain drag, outside | ambient observation | exposes only ordered ink and placeholders |
| decrypted drag, from the handle | declassification/egress | the core supplies the complete payload lazily when a destination asks; a successful drop never deletes the object |
| backspace | structural editing | first selects, then removes from the page; selected objects are removed immediately; removal remains undoable |
| find, word count | ambient observation | does not inspect payloads; may count one protected object |
| expiry | destruction/lifecycle | destroys all attached and detached payloads on the page; references resolve to expired only while expiry evidence remains |
| explicit burn | destruction/lifecycle | destroys named local payloads; references resolve to burned only while burn evidence remains |
| export, print, share | ambient observation | emits placeholders by default; plaintext export is separately named declassification/egress |
| promote the whole page | declassification/egress | includes sealed payloads; the confirmation says so; the local copy is offered up to burn and is never burned automatically |
| seal a selection | classification | replaces visible ink in place and cannot be undone back to plaintext; sealing over an object has a refused outcome |

### Pasteboard model

`NSPasteboard` lets one item advertise several representations and a
receiving app takes the one it understands, the same mechanism that
supplies image, rich-text and plain-text forms of a single copy. A
copied selection writes:

- a private type, `com.onetimesecret.onetimepad.sealed-fragment` (with the
  `.debug` suffix on development builds), carrying a versioned ordered
  sequence of visible ink runs and sealed-object UUID references;
- a plain-text representation preserving the ink and substituting
  `[sealed content · <size class>]` for every live reference;
- a public URL representation *only* as the direct result of Create
  one-time link, never on an ordinary copy.

A single-object copy is a one-reference fragment. Neither representation
contains a sealed payload or ciphertext. The sequence preserves a selection
such as `ink → object A → ink → object B → ink`; cut, paste and clone apply
to all referenced objects atomically. An unexpected failure commits none of
the operation. Cause-specific placeholders are expected resolution results,
not partial failures.

**Lifecycle and detached states.** Attached and detached objects retain their
payload on the page's clock. A cut detaches every object in the fragment and
shows the fragment in the app clipboard slot; its first paste reattaches all
of them atomically, and later pastes clone them. Removal from the page also
detaches but does not put the object in that slot: Undo reattaches the
removed instance, while a copied reference clones it. Removal therefore
never produces a removed placeholder.

Expiry and explicit burn destroy payloads. A later reference becomes
`[sealed content · expired]` or `[sealed content · burned]` only while the
ledger retains the UUID, terminal event and timestamp. An explicit burn uses
the ledger's `discarded` event as burn evidence. ADR-0012 defines that
retention as "a rolling 90-day window". After that evidence expires, and for
a UUID from another device or build, paste inserts
`[sealed content · unavailable]`; it does not guess that the object expired.

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
Remove from page
```

*Amended 2026-09-15:* the removal item reads *Remove protected
content*, the first verb carries the keymap's chord (⇧⌘C by default),
and the block reveals an actions glyph on hover that opens this menu;
see [2026-0915-stream-navigator.md](2026-0915-stream-navigator.md)
D-40 and D-41.

After a decrypted copy, one line confirms the boundary crossing with the
core's interval: `copied decrypted contents — small. the clipboard
clears in 60 seconds.` The interval is one core constant,
`CLIPBOARD_CLEAR_SECONDS` (60) in `crates/ffi`, read by the shell through
`companion_clipboard_clear_seconds`. The model arms a timer after each
general-pasteboard egress; when it fires, the core clears only if the
pasteboard still holds that write. This does not bound copies retained
by clipboard managers. See
[2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) D-42 and
D-43.

ADR-0012 named one egress (send) at line 103. This record makes it
three, **copy decrypted**, **decrypted drag**, **promotion**, and the
ADR's Amendment 1 (2026-09-15) adopts them. All three write the complete payload core-side. The shell never receives the
sealed payload from the core, but it may hold visible ink before sealing and
the policy-approved mechanical excerpt afterward (`ChipInfo.excerpt` and
`companion_sheet_document_json`).

They are not equally safe, and the card's affordances reflect that. Copy
decrypted goes through the general pasteboard (clipboard managers,
Universal Clipboard, polling apps), the channel ADR-0012 calls the
existential risk. OnetimePad writes a decrypted drag to the drag pasteboard and not to the
general pasteboard. Apple's [`NSPasteboard` documentation](https://developer.apple.com/documentation/appkit/nspasteboard/)
says, "The drag
pasteboard is used to transfer data that is being dragged by the user," and
that the general pasteboard "automatically participates with the Universal
Clipboard feature." It does not establish exclusion from clipboard history,
non-observability by third-party software or erasure when a drag ends. The
decrypted-drag handle remains the recommended path into a form field; copy
decrypted is the fallback for destinations that take no drop.

The plain-text placeholder therefore carries a **size class**, not a
length: `[sealed content · small]`. An exact character count is
precisely what the ledger reduces to a class (`SizeClass`,
`crates/core/src/ledger.rs`), and it would sit in clipboard history
forever. The private fragment contains only visible ink, its version and UUID
references. The UUIDs are the random identifiers the ledger already records
in plain; the fragment adds order, not payload exposure.

### The rubric for any new interaction

- **Atomicity**: does the sealed item behave as one object?
- **Non-disclosure**: can this ordinary action reveal plaintext
  unexpectedly?
- **Fidelity**: can the object move through trusted app operations
  without losing its payload?
- **Legibility**: does the action name what crosses the boundary?
- **Reversibility**: can structural edits be undone? Classification is a
  separate class; sealing remains one-way because an unnamed Undo that
  revealed plaintext would breach Legibility.
- **Safe fallback**: when a destination cannot understand the object,
  does it get a placeholder rather than plaintext or nothing?

- **D-08 (fixed)** The UI never receives or draws the complete sealed
  payload: no reveal, no eye toggle and no copy-to-see-it. It may hold
  visible ink before sealing and the policy-approved mechanical excerpt
  afterward.
  *Review correction 2026-09-15:* this replaces the earlier absolute “No
  plaintext, ever” wording, which contradicted D-27's excerpt and the visible
  pre-seal ink. The prohibition applies to the complete sealed payload, with
  those two explicit exceptions.
  ⇧⌘V over a line already holding a chip refuses:
  `already sealed · a chip has no plaintext to seal`. (The core's own
  vocabulary still says "chip"; the UI says nothing about the shape.)
  *Errata 2026-09-15:* the refusal line above was quoted with an em
  dash; the shipping string joins its two halves with a middle dot,
  as the copy register (D-15) asks, and the quote now matches it.
  *Acceptance:* find cannot match a chip; ⌘E over a selection holding
  one refuses; a chip leaves only by an act aimed at the chip.
- **D-09 (fixed)** Concealing is the app's one network outbound action:
  discoverable on every chip, prominent on none. Never a hero button,
  never a side effect. The confirming click is the network boundary and
  the destination is always named. This network-action count is distinct
  from D-32's three complete-payload egresses: copy decrypted and decrypted
  drag are local pasteboard writes; promotion is the concealment network
  action.
  *Review correction 2026-09-15:* “one outbound action” is narrowed to “one
  network outbound action”; it does not replace D-32's egress inventory.
  The confirmation is inline and never a modal: the boundary named, then the
  clipboard line and **Burn local copy**. On a page target the sheet says how
  many sealed items travel (`includes 2 sealed items`).
  *Acceptance:* inline sheet, no modal, no focus theft; the link's TTL
  is never seeded from the page's remaining time; failure is inline text
  and the button becomes Retry; the local copy is offered up to burn and
  never burned automatically.
- **D-10 (fixed)** Hover reveals affordances, never content, and the
  affordance keeps its seat whether visible or not (~120 ms opacity,
  0 ms under Reduce Motion): revealing it never nudges the ink or
  reflows the row.
  *Review correction 2026-09-15:* the earlier acceptance line said a click
  only placed the caret. D-28 and the attachment interaction require the
  opposite: a click selects the whole object.
  *Acceptance:* every hover action is also in the row's context menu
  (copy out, ↗ conceal, remove), so a pointer is never required; the
  row is not itself a button, and a click selects the whole attachment
  without placing the caret inside it.
  *Amended 2026-09-15:* the click also opens the object's menu, and
  Return or Space over the selected object opens it too; see
  [2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) D-40.
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
  The guarded 60-second clear attempt is implemented as one core
  constant, `CLIPBOARD_CLEAR_SECONDS` in `crates/ffi`, read by the shell
  through `companion_clipboard_clear_seconds` and armed by the model on
  every general-pasteboard egress. It clears only while that write is
  still current
  ([2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) D-43).
- **D-30 (fixed)** Sealing an existing selection replaces it in place,
  keeps the surrounding whitespace and selects the new object, and is
  **one-way**: ⌘Z does not restore the plaintext. No confirmation
  dialog. Removing a sealed object is **structural and undoable**: the
  first backspace beside it selects, the second removes, and ⌘Z puts
  the object back. The core owns the payload throughout, so undo restores
  a reference without sending the complete payload to the shell. ADR-0009's
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
- **D-31 (fixed)** The in-app pasteboard type carries a versioned sealed
  fragment: ordered visible-ink runs and UUID references, never payload or
  ciphertext. A single object is a one-reference fragment; object and
  whole-page copy use the same representation. Tracked with D-33 under
  issue 170.
  *Acceptance:* mixed ink and multiple objects round-trip in order; cut,
  paste, detach, reattach and clone are atomic across all references; no
  sealed payload byte is written to a pasteboard except at a named
  declassification.
- **D-32 (fixed)** Three complete-payload egress points, not one: copy
  decrypted, decrypted drag and promotion. The decrypted drag is the
  recommended path into a form field because OnetimePad does not write its
  decrypted data to the general pasteboard; copy decrypted does and is the
  riskier fallback. This makes no claim about clipboard history,
  third-party observation or end-of-drag erasure. The general-pasteboard
  clear interval is the core's 60-second constant. Complete payload writes
  remain core-side; Swift may still hold visible ink and the mechanical
  excerpt.
- **D-33 (fixed)** A cut or removed object is detached, not destroyed,
  and retains the page's clock; there is no per-object TTL. Cut objects
  appear together in the app clipboard slot and the first paste reattaches
  them; removed objects do not appear there and Undo reattaches them.
  Expiry and explicit burn destroy. An expired, burned or unavailable
  reference gets a distinct placeholder; a live removed object never gets
  a removed placeholder. Terminal-cause evidence lasts for the ledger's
  rolling 90-day window, then resolves as unavailable.
  *Acceptance:* the lifecycle table in Law 0001 is covered state by state;
  expiry and burn are not undoable; no timer exists per object.
  *Review correction 2026-09-15:* the earlier contract and amendment-history
  wording said an unpasted chip died by “its own TTL.” That wording is
  withdrawn. The page owns the clock for attached and detached objects; no
  chip timer exists (`sheet.rs` :292, doc 04 :155), following the maintainer's
  2026-08-07 decision.

### Amended since the first draft

The working copy carried this list; it is kept as the argument's
history. One of its sentences (an unpasted chip dying by its own TTL)
was dropped on 2026-09-15; D-33 and section 10 have the current
reading.

Sealing is one-way. "Allow Undo to restore the plaintext" is withdrawn:
it was the one reveal path that named nothing, and it kept the
plaintext in the shell's undo stack. Sealing is exempt from the
reversibility rule; removal stays undoable.

The in-app pasteboard type carries a versioned ordered fragment of visible
ink runs and UUID references, not "the complete sealed object, including its
protected payload". Cut detaches all referenced objects atomically, the first
cut paste reattaches them, and later pastes and ⌥-drag clone core-side. All
objects retain the page's clock; none has its own TTL.

Drag-out was backwards. OnetimePad does not write decrypted drag data to
the general pasteboard, so it is the recommended declassification path into
a form field; copy decrypted is the riskier fallback. No exclusion from
clipboard history, third-party observation or end-of-drag retention is
claimed. Plain drag stays placeholder-only.

The placeholder was `[sealed content · 51 characters]`, an exact length
the ledger deliberately reduces to a class. It is now
`[sealed content · small]`.

Three complete-payload egress points (copy decrypted, decrypted drag and
promotion) are named here for the ADR to adopt, all core-side. Whole-page
promotion joins the contract as the one operation that includes all sealed
payloads. The versioned fragment and lifecycle table define multi-object
copy, terminal causes and foreign references.

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
`+` pinned right, groups `FILES` then `PAD`. Down the side: 110 wide,
eating into the page's column and never into the header. Days + side is
the stream navigator rather than day rows. The two orientations are
exclusive: a side column with a bottom strip underneath would count the
same pages twice. See
[2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) section 1.

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
  *Amended 2026-09-16:* a fence's opening and closing rules are markup,
  so a page opening with "```ruby" is titled by the first line inside
  the fence, as typed, and never "ruby"
  ([2026-0916-rail-redundancy.md](2026-0916-rail-redundancy.md), D-48).
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
- **D-16 (fixed)** The empty state is one calm sentence ("No page here
  yet.") over a hint naming the gesture that works on this surface and
  stance. No illustration, no onboarding flow.
  *Acceptance:* raised: "click, ⌃⌥Space, or ↩ to start one" · pinned rest:
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
- D-31, the contract's copy, cut and paste rows and the pasteboard model:
  the private type is a versioned ordered fragment of visible-ink runs and
  UUID references, so mixed and multi-object selections retain structure.
- D-29, D-32 and the confirmation paragraph: ADR-0012 is named; the
  general-pasteboard interval is 60 seconds as one core constant,
  `CLIPBOARD_CLEAR_SECONDS`; ADR-0012's Amendment 1 adopts the three
  complete-payload egress points. The clear is change-count guarded, and
  the drag and retention claims are limited to what the implementation
  and Apple's pasteboard documentation establish
  ([2026-0915-stream-navigator.md](2026-0915-stream-navigator.md) D-43).
- D-33, the contract's cut, paste and expiry rows and the lifecycle table:
  every per-object TTL is removed. Cut and removed objects remain live on
  the page's clock; expiry, burn and unknown references remain distinct
  while the ledger retains terminal-cause evidence.
- D-09: the conceal confirmation names its button, Burn local copy.
- Review corrections 2026-09-15: D-08's boundary is the complete sealed
  payload, with visible pre-seal ink and the mechanical excerpt as explicit
  exceptions; D-10's click selects the attachment rather than merely placing
  the caret; D-09's one outbound action means one network action and does not
  contradict D-32's three egresses; D-33 and the amendment history use the
  page-owned clock and define no per-object TTL. Law 0001's review amendment
  is controlling for D-08 through D-10 and D-31 through D-33.
- The feature-scale items are linked by issue: the sealed block (D-27,
  issue 169), the fragment and lifecycle model (D-29, D-31, D-33, issue 170), the
  split Days setting (D-26, issue 171) and the four dialogs (D-14,
  D-19, issue 172).
