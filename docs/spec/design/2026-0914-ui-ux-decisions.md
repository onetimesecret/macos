---
id: 2026-0914-ui-ux-decisions
title: UI/UX decisions for the background surface
status: superseded   # draft → accepted → superseded
dated: 2026-09-14
supersedes: docs/design-brief.md (Tokens and parameters)
superseded-by: docs/spec/design/2026-0915-ui-ux-decisions.md
reviewed: 2026-09-15
surfaces: OnetimePad (background surface)
sources:
  - docs/spec/design/03-design-principles.md
  - docs/spec/design/04-interaction-model.md
  - docs/spec/design/05-technical-direction.md
  - docs/spec/feature/background-surface/README.md
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

Superseded by `docs/spec/design/2026-0915-ui-ux-decisions.md` (2026-09-15).

What the shipping surface looks like, what each visible decision is, and
what a build has to satisfy before the decision counts as honoured. The
illustrated companion (mockups with callouts) lives with the design
record; the shipping surface sets `sharingType = .none` and cannot be
screenshotted, so every visual is a recreation from this source tree.

## 0 · Pipeline and status

1. This file lives at `docs/spec/design/2026-0914-ui-ux-decisions.md`.
   Filenames are immutable once pushed.
2. The front matter above stays at the top. `status` is the only field
   that changes after the first push.
3. A decision that changes gets a **new** dated document. The old one is
   edited only to set `status: superseded` and to name its successor.
4. Link the record from the ADR or issue that consumed it. An accepted
   record and a contradicting build are a bug report, not a
   disagreement.

Status vocabulary — **draft**: proposed, do not build against ·
**accepted**: the build owes this · **superseded**: history, kept for
the argument.

## 1 · The card and its two stances

Resting: one window level above the desktop, mouse-transparent,
`canBecomeKey` false, repaint every 30 s, contents at 0.72. Raised:
`.floating`, clickable, may become key, 1 Hz tick, full strength.
Raising and resting change **opacity only** — nothing reflows, resizes
or moves.

Header 32 tall, padded 12 horizontally; tab strip 32; everything between
is the page. Resizing grows the page, never the chrome.

- **D-01 (fixed)** A resting surface never takes a keystroke. The
  keyboard map is mounted only while raised.
  *Acceptance:* typing with the card resting reaches the frontmost app
  and nothing else.
- **D-02 (fixed)** The stance change is opacity 0.72 → 1.0 over ~160 ms.
  *Acceptance:* both stances diff to within a pixel; under
  `prefers-reduced-motion` the transition is 0 ms and the end state
  identical.
- **D-03 (fixed)** Ember (`#DC4A22`) is a fill and geometry colour,
  never text, never the only carrier of state. Ember text uses the
  darkened `--ember-text`.
  *Acceptance:* greyscale the surface and read every state; ember text
  clears 4.5:1 on page and card, light and dark.
- **D-04 (open)** Is the resting card opaque or translucent? The
  background-surface spec says transparent for both stances; the design
  system applies material to the raised stance only.
  *Needs a call:* if the card recedes, `.ultraThinMaterial` in
  `BackdropRootView` becomes stance-dependent. Either way Reduce
  Transparency must land on a solid system fill.

The 1.5px ember keyline at 80% shows exactly while the surface **holds
the keyboard** — raised and keyed are distinct facts. The persistence
word (`saving` · `saved` · `save failed` · `not saving`) is words, not a
glyph, and absent until a write is owed. The pin is a real `Toggle` so
VoiceOver announces on/off, and it is workable only while raised.

## 2 · The page: ink, markdown, fenced code

Monospaced, System Monospaced 13pt by default, user-settable 8–40.
Headings are proportions of the base (17/13, 15/13, 14/13 at semibold).
Chip labels are base − 2 at medium weight.

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
  ≥4.5:1 on the fence wash in both appearances.
- **D-07 (fixed)** One editor persists across page switches; storage is
  swapped underneath it and the view carries no identity.
  *Acceptance:* caret, scroll and undo survive a tab change; font sizes
  8–40 reflow without clipping the heading ramp.

## 3 · Sealed content and the conceal flow

Sealed content is an **atomic block attachment** — like an image or an
embedded file in a rich-text editor — and it leaves the app only through
an action that names what crosses the boundary. One rule settles most of
what follows:

> A sealed item occupies one position in the document, but its plaintext
> is not part of the document's ambient text.

Every operation on a sealed item is one of two kinds, and that
distinction is the whole design.

- **Structural** — move, select, cut, paste within the app, duplicate,
  delete, expire. They act on the object, never on its payload, and they
  are undoable.
- **Declassification** — copy decrypted contents, decrypted drag from
  the handle, promote to a one-time link, plaintext export. Plaintext
  crosses the boundary, the action names it, and the write is always
  core-side.

There is no reveal affordance at any privilege, so no label may imply
one.

### The block

Full measure, 8px radius, hairline border, padded 8 × 12. A tracked
`SEALED CONTENT` label with a lock over the mechanical excerpt, and the
size right-aligned as metadata. A move handle appears on hover or
selection and never otherwise; beside it, visually distinct, the
decrypted-drag handle — the one place on the card where a drag carries
plaintext. Selected, the block takes a focus outline. Contents never
preview, in any state.

### Sealing a selection after the fact

With plaintext selected: **Seal Selection** in the context menu,
**Edit → Seal Selected Content** in the menu bar, and optionally the
same action in the command palette. It replaces the selection in place,
keeps the surrounding whitespace, and selects the new object so the
transformation is visible. Sealed objects do not nest, so a selection
containing one is refused. No confirmation dialog — the visible collapse
is the feedback.

**Sealing is one-way in the editor**, and it is the single exemption
from the reversibility rule. An Undo that restored the plaintext would
be the one reveal path that names nothing — it fails Legibility — and it
would force the shell to keep the plaintext alive in its undo stack,
which is the opposite of "from this point forward". ⌘Z after sealing is
not offered; the content comes back only through *Copy decrypted
contents*. Removing a sealed object stays undoable, because removal is
structural.

Honest scope: sealing protects the selection **from this point forward**.
Autosave is already written under the boot-bound key, and the undo stack
never held the plaintext, so the real residuals are narrow — the shell's
layout and glyph caches, and whatever the user pasted from. The copy
names those and never implies historical erasure.

### The sealed-object contract

`ambient` reads the object without reading its payload.

| Interaction | Kind | Expected behaviour |
| --- | --- | --- |
| arrow keys | ambient | the caret crosses the object as one indivisible unit |
| click | structural | selects the whole object; never places a caret inside it |
| shift-selection | structural | includes the whole object or none of it |
| select all | structural | includes the object structurally, not its plaintext |
| copy — object or whole page | structural | writes the chip's UUID in the private type plus the placeholder in plain text; no payload, no ciphertext |
| cut | structural | writes the UUID, then detaches the chip from the page; a detached chip shows in the app's own clipboard slot and dies by its own TTL if never pasted. Never an invisible limbo |
| paste, inside OnetimePad | structural | the core reattaches the chip by id at the new position; a paste after copy — or a second paste of a cut — is a core-side clone with a new UUID, same TTL and payload |
| paste, another app | ambient | the destination gets the placeholder `[sealed content · small]`. Never plaintext |
| drag, inside the document | structural | moves the object atomically with a clear insertion line; contents never preview |
| ⌥-drag | structural | a core-side clone, following the macOS copy-drag convention; no pasteboard involvement |
| plain drag, outside | ambient | exposes only the placeholder |
| decrypted drag, from the handle | declassify | an explicit affordance on the card — a distinct handle, or a modifier-drag the card labels while held. Plaintext is supplied lazily through `NSPasteboardItemDataProvider`, so the core writes it only when a destination asks. A successful drop never deletes the chip |
| backspace beside it | structural | the first press selects the object, the second removes it |
| backspace, selected | structural | removes it immediately, with undo available |
| find, word count | ambient | do not inspect the plaintext; optionally count one protected object |
| expiry | structural | a chip has its own TTL, which may be shorter than the page's. When it elapses the page shows an *expired* placeholder in place, visibly distinct from a removed one, and not undoable because nothing remains to restore. A page's expiry takes its chips with it. Both hold at rest with the app not running — boot-bound key, refuse-to-reveal at next open |
| export, print, share | ambient | emit the placeholder by default; a decrypting export is a separately named action |
| promote the whole page | declassify | includes sealed payloads; that is the product. The confirmation says so — `includes 2 sealed items`. The local copy is offered up to burn, never burned automatically |

### Pasteboard model

`NSPasteboard` lets one item advertise several representations and a
receiving app takes the one it understands. A sealed object writes:

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
devices. The core already owns the bytes and identifies chips by UUID,
so cut detaches, paste reattaches by id, and a duplicate is a core-side
clone. Nothing about the secret ever leaves the process.

**The detached state.** A cut chip leaves the page, shows in the app's
own clipboard slot, and is reattached by the next paste. Nothing waits
forever: an orphaned cut chip dies by its own TTL, and a reference whose
chip is gone resolves to *expired*, so the paste inserts the expired
placeholder rather than failing. Quitting between cut and paste is
survivable, because the detached chip and its id live in the content
store, not on the pasteboard.

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
interval the core actually enforces —
`decrypted contents copied · clipboard clears in 60 seconds`. The core
clears on every pasteboard egress, so the real number is stated; a clear
the app does not perform is never promised.

The ADR names one egress (send). This record makes it three, and the ADR
should say so rather than let it drift: **copy decrypted**, **decrypted
drag**, **promotion**. All three are core-side writes, so the Swift
shell still never holds plaintext.

They are not equally safe, and the card's affordances reflect that. Copy
decrypted goes through the general pasteboard — clipboard managers,
Universal Clipboard, polling apps — the channel the landscape document
calls the existential risk. A decrypted drag goes through the drag
pasteboard, never enters clipboard history or Universal Clipboard, and
matches the ergonomic the product already teaches: drag in, drag out.
The decrypted-drag handle is the recommended way to get a secret into a
form field; copy decrypted is the fallback for destinations that take no
drop.

The plain-text placeholder therefore carries a **size class**, not a
length: `[sealed content · small]`. An exact character count is
precisely what the ledger reduces to a class (`SizeClass`,
`crates/core/src/ledger.rs`), and it would sit in clipboard history
forever. The private type's UUID is the same random id the ledger
already records in plain — same exposure as the ledger, stated the same
way.

### The rubric for any new interaction

- **Atomicity** — does the sealed item behave as one object?
- **Non-disclosure** — can this ordinary action reveal plaintext
  unexpectedly?
- **Fidelity** — can the object move through trusted app operations
  without losing its payload?
- **Legibility** — does the action name what crosses the boundary?
- **Reversibility** — can structural edits be undone? Sealing is the one
  exemption: it is one-way in the editor, because an unnamed Undo that
  revealed plaintext would breach Legibility.
- **Safe fallback** — when a destination cannot understand the object,
  does it get a placeholder rather than plaintext or nothing?

- **D-08 (fixed)** No plaintext, ever, in the UI — no reveal, no eye
  toggle, no copy-to-see-it. ⇧⌘V over a line already holding a chip
  refuses: `already sealed — a chip has no plaintext to seal`.
  (The core's own vocabulary still says "chip"; the UI says nothing at
  all about the shape, so the internal name can stay.)
  *Acceptance:* find cannot match a chip; ⌘E over a selection holding
  one refuses; a chip leaves only by an act aimed at the chip.
- **D-09 (fixed)** Concealing is discoverable on every chip, prominent
  on none, never a side effect. The confirming click is the network
  boundary and the destination is always named.
  *Acceptance:* inline sheet, no modal, no focus theft; the link's TTL
  is never seeded from the page's remaining time; failure is inline text
  and the button becomes Retry.
- **D-10 (fixed)** Hover reveals affordances, never content, and the
  affordance keeps its seat whether visible or not (~120 ms opacity,
  0 ms under Reduce Motion).
  *Acceptance:* every hover action is also in the row's context menu
  (copy out, ↗ conceal, remove); the row is not a focusable control and
  a click only places the caret.
- **D-27 (fixed)** Sealed content is a full-measure block, not an inline
  pill: 8px radius, hairline border, a tracked `SEALED CONTENT` label
  with a lock over the mechanical excerpt, the size right-aligned as
  metadata, and nothing that reads as pressable.
  *Owed:* this overrules the shipping treatment. `ChipCell` in
  `InkEditorView.swift` draws `[ excerpt · size ]` at intrinsic width and
  the design system's `SealedChip` mirrors it; both follow this record.
- **D-28 (fixed)** A sealed item is one object in the document and its
  plaintext is not part of the document's ambient text. Structural
  operations act on the whole object; the caret never lands inside it
  and sealed objects never nest.
  *Acceptance:* the contract table is the test list.
- **D-29 (fixed)** Declassification is always an explicit, separately
  named action — *Copy decrypted contents*, *Create one-time link…*, a
  decrypted drag from the handle, a plaintext export — in the object's
  own menu or on its own handle, never on the ordinary copy path. Every
  other destination gets `[sealed content · small]`: a size class, never
  an exact length.
  *Acceptance:* a plain drag outside the app exposes the placeholder
  only; the decrypted-drag handle is visually distinct from the move
  handle; the confirmation names the interval the core enforces; no
  ordinary copy path offers plaintext.
- **D-30 (fixed)** Sealing an existing selection replaces it in place,
  keeps the surrounding whitespace and selects the new object, and is
  **one-way**: ⌘Z does not restore the plaintext. No confirmation
  dialog.
  *Acceptance:* nothing in the undo stack holds the plaintext, and the
  content returns only through *Copy decrypted contents*; removing a
  sealed object is still undoable; the copy protects the selection "from
  this point forward", naming the real residuals — layout and glyph
  caches, and whatever the user pasted from.
- **D-31 (fixed)** The in-app pasteboard type carries the chip's UUID,
  never its payload. Clipboard managers and Universal Clipboard archive
  every representation they are offered, so ciphertext on the pasteboard
  is ciphertext in a history file on another device.
  *Acceptance:* cut, quit, relaunch, paste still works, because the
  detached chip lives in the content store; a reference whose chip is
  gone resolves to *expired* and inserts the expired placeholder rather
  than failing; no secret byte is written to any pasteboard except at a
  named declassification.
- **D-32 (fixed)** Three egress points, not one: copy decrypted,
  decrypted drag, promotion. The decrypted drag is the recommended path
  into a form field; copy decrypted, on the general pasteboard, is the
  riskier fallback.
  *Owed:* ADR amendment. All three are core-side writes, so the shell
  holds no plaintext at any point; the clear-on-egress interval the ADR
  already mandates is stated as the number the core uses, not hedged.
- **D-33 (fixed)** A cut chip is detached, not orphaned: it leaves the
  page, shows in the app's own clipboard slot, and dies by its own TTL
  if never pasted. A chip's TTL may be shorter than its page's; when it
  elapses the page shows an *expired* placeholder in place, visibly
  distinct from a removed one.
  *Acceptance:* expiry is not undoable and the copy does not offer undo;
  a page's expiry takes its chips with it; both hold at rest with the
  app not running, under the boot-bound key.

## 4 · How pages are organized, and where they live

**Two settings, not one.** The build flips both with a single switch
today, which is why the surface had to be described in code names
("the strip", "the rail") that mean nothing to a person. What a tab *is*
and where navigation *sits* are independent:

- **Organize pages by** — Slots · Days (time tabs)
- **Show pages** — Along the bottom · Down the side

All four combinations are supported states. Slots, bottom: the
spreadsheet idiom, today's shipping default. Slots, side: titles that
are sentences read down a column untruncated. Days, side: chronology is
vertical, and the intended default. Days, bottom: a left-to-right
timeline that keeps the page's full width.

Metrics do not change with the choice. Along the bottom: 32 tall,
padded 6 × 4, 2 between tabs, title row 18, gauge 3, capped 140 wide,
`+` pinned right, groups `FILES` then `PAD`. Down the side: 96 wide,
rows padded 4 vertically, blank count at the foot in words. The two
orientations are exclusive.

Dash vocabulary — `2 3` a slot holding no page · `3 2` clock held for an
hour · `7 2` hold topped up to 24h · `2 1.5` ember and hatched, under
one hour · `4` on a border, ledger residue. A gauge at zero is never
used for "empty".

- **D-11 (fixed)** Time is geometry that drains, not animation and not a
  ticking number. Gauges are per tab and short; the full-width page-edge
  bar was removed in dogfooding for impersonating a scroll bar.
  *Acceptance:* every gauge speaks rounded words ("about 7 hours
  remaining"); held is dash *and* a ⏸ chip; last hour is hatch *and*
  ember.
- **D-12 (fixed)** A tab's title is the page's first typed line with
  markup stripped, "untitled" if none. A file is a navigation peer, not
  a slot: an unsaved ember dot sits where a page draws its gauge.
  *Acceptance:* strip and rail speak a file identically; the row says
  "unsaved" in words; the tooltip is the last known path.
- **D-13 (open)** Days is gated on parity: renaming, holding,
  shortening and closing must live on each day's own gutter before it is
  a peer of slots. Until they do, Days ships labelled a prototype and
  the shipping default stays Slots + bottom, even though Days + side is
  where the default is headed. Cap behaviour is separately unsettled:
  refuse-don't-evict is fixed, what "refuse" looks like on screen is not.
  *Needs a call:* the gutter's verb set, and whether the ceiling of 12
  reads as a wall or a nudge.
- **D-26 (fixed)** Two settings, four combinations, as above. The single
  switch that flips grouping and orientation together is the defect this
  replaces — it pushed code names into user-facing copy and left one
  axis unreachable. "Strip" and "rail" stay code names and never appear
  in the UI.
  *Acceptance:* each setting persists independently and every
  combination is a supported state; a mode flip moves no content and
  writes nothing new to disk; each caption says what the choice costs as
  well as what it does; time-related settings sit under the Days choice.

## 5 · Status lines and notices

12 × 4 padding, `.caption` monospaced, ember only for what needs acting
on, absent unless they have something to say — the layout reserves no
room. Precedence, in draw order: content-restore failure · ledger
failure · sync standing sentence · remote-edit line · pasteboard offer ·
notice · conceal sheet.

- **D-14 (fixed)** No modals, no interrupting dialogs, no notifications,
  badges, bounce or count chips. Destructive Settings actions are the
  one exception and use the platform confirmation.
  *Acceptance:* every interaction completes without the surface becoming
  key unless the user deliberately raised it.
- **D-15 (fixed)** Copy register: lower-case sentences, third person, em
  dash and middle dot doing real work, no exclamation marks, `…` as one
  character. Second person only in tooltips and a11y labels.
  *Banned:* "3 items expiring soon", "Are you sure?" on expiry,
  onboarding or celebratory copy, "your secrets are safe with us", and
  any label implying content can be revealed.
- **D-16 (fixed)** The empty state is one calm sentence — "Empty is the
  resting state." — over a hint naming the gesture that works on this
  surface and stance. No illustration.

## 6 · Files and the unsaved state

A file replaces what the surface was showing and puts its own identity
where the product name stands: name · unsaved dot + word · draft stamp
`Thu 14:32` when restored from drafts · `UTF-8 · Markdown` (+ `· CRLF`).

- **D-17 (fixed)** A conflict refuses the save, never the typing. Three
  actions in reading order, named by what they keep, with Save As last
  and under the return key.
  *Acceptance:* the sentence is a pure function of conflict and
  filename, testable as words.
- **D-18 (fixed)** Two "saved" words never show at once: a file's word
  replaces the session's. Render mode is session state and never
  encoded with the file or its draft.
  *Acceptance:* a render-mode change leaves the bytes identical.
- **D-19 (fixed)** No save sheet on quit; the draft's age in the header
  is what the app owes instead.
  *Acceptance:* the stamp shows only for a draft-restored buffer, in
  `EEE HH:mm` with a 24-hour clock whatever the locale.

## 7 · The sync surface

Off by default; off is silence. On, sync speaks in two places: one
lower-case header word chosen by the core's gate, and one standing
sentence under the page.

| word | tone | when |
| --- | --- | --- |
| *(nothing)* | — | off, or on with no relay configured |
| synced | quiet | attached; the chosen pages travel |
| sync waiting | plain | enrolled pages, no other device awake |
| reaching | plain | signed in, attaching to the relay |
| sync signed out | plain | on and signed out; the pad is unaffected |
| signing in | plain | waiting on the browser |
| sync offline | loud | relay unreachable; edits stay local, retrying |
| sync refused | loud | the account refused the sign-in |
| sync behind | loud | behind a key rotation; outranks the gate |

- **D-20 (fixed)** Off is indistinguishable from sync not existing. A
  working channel is not news, so the settled state is quiet; the two
  states a user must act on are loud.
  *Acceptance:* the word table is derived from the gate and unit
  testable without a window; "synced" is never shown with no peer awake.
- **D-21 (fixed)** A comparison that cannot fail verifies nothing:
  "They don't match" is always offered beside "They match". A device
  nothing vouches for reads *attached, never paired*, in words.
  *Acceptance:* a browser sign-in trip always offers "Give up", drawn
  only while a trip exists; every revoke and sign-out states what it
  does and does not touch.
- **D-22 (fixed)** A remote edit is a word, never a dialog — "another
  device is editing this page" — and it sits with the page's status
  lines, not in the header.

## 8 · Settings

One small window, four grouped forms. Every section carries a caption
that says what the switch does **and what it costs**. General and Code
save on each flip; Connection holds fields in draft until Save.

- **D-23 (fixed)** Native and plain: SwiftUI `Form`, grouped style,
  system font for captions, monospace only for app-written status.
  *Acceptance:* Increase Contrast, Reduce Transparency, Dynamic Type and
  full keyboard access come from the platform.
- **D-24 (fixed)** The API token field is write-only; the placeholder
  only says one is held. A refused setting shows the system's actual
  state, never a wish as a fact.
  *Acceptance:* Test saves first so it tests what will be kept; a
  refused URL says `refused: the server URL must be https://…`.
- **D-25 (fixed)** A control appears only where it can work: the capture
  opt-out in a debug build or a release launched with
  `COMPANION_ALLOW_CAPTURE`; the ledger clear only while the surface is
  telling the user to come and use it.
  *Acceptance:* while the opt-out is on the header flies the camera
  indicator, and the opt-out is never persisted across a quit.

## 9 · Acceptance bar, whole-surface

A build that fails any row fails the design, whatever it looks like.

1. Colour is never the only carrier — greyscale it and read every state.
2. Every visual signal has a text equivalent; remaining life in rounded
   words, ledger stamps absolute.
3. Reduce Motion: all transitions 0 ms, nothing becomes unreadable.
4. Increase Contrast / Reduce Transparency: surfaces degrade to solid
   system fills.
5. Contrast: every text-carrying token ≥4.5:1 in light and dark.
6. Focus: nothing makes the surface key but a deliberate raise; resting
   cannot take a keystroke.
7. Dynamic Type and user font size 8–40: the ramp keeps its proportion,
   chrome stays 32/32, the page absorbs the difference.
8. Light and dark are both acceptance criteria.

Iconography: SF Symbols by name in Swift (`plus`, `xmark`, `pause.fill`,
`arrow.up.right`, `pin`/`pin.fill`, `camera.fill`, `circle.dashed`). SF
Symbols cannot be redistributed, so web mockups substitute matching
Unicode characters. Never an icon font, an SVG sprite, or PNG icons.
