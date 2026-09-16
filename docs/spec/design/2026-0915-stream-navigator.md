---
id: 2026-0915-stream-navigator
title: The stream navigator and the sealed capsule's actions
status: accepted     # draft → accepted → superseded
dated: 2026-09-15
supersedes: docs/spec/design/2026-0915-ui-ux-decisions.md, on D-26's side metrics, D-27's block, D-29's confirmation line, the object menu's removal item and the clear interval only
superseded-by:
reviewed: 2026-09-15
surfaces: OnetimePad (background surface), Days + side
sources:
  - claude.ai/design project ec4e1925-a907-418a-8020-270fb6353d23, "Stream Navigator (Sol feedback).html" and stream-navigator-sol.jsx (the maintainer's interactive design)
  - docs/spec/design/2026-0915-ui-ux-decisions.md
  - docs/law/0001-sealed-object.md
  - shell/Sources/CompanionKit/StreamNavigator.swift
  - shell/Sources/CompanionKit/TimeRailView.swift
  - shell/Sources/CompanionKit/RollGeometry.swift
  - shell/Sources/CompanionKit/DayScrollView.swift
  - shell/Sources/CompanionKit/InkEditorView.swift
  - shell/Sources/CompanionKit/PageModel.swift
  - crates/ffi/src/lib.rs
---

# The stream navigator and the sealed capsule's actions

The maintainer's interactive design of 2026-09-15 ("Stream Navigator,
Sol feedback") redraws the Days + side presentation as one track of
checkpoints, and redraws the sealed object's actions and the lines that
follow them. This record is what the build owes for it. It amends the
2026-0915 record in the places section 4 names and leaves everything
else in that record standing; the 2026-0915 record carries a dated note
at each amended passage pointing here.

The design's own headline, kept as the argument: *the capsule always
on, + on the PAD heading, retention words instead of countdowns, ember
spent on three things only.*

## 1 · The navigator

Every live page is a node on one vertical track down the rail, in the
roll's order, newest at the top. A day's first page carries the day's
words ("Today", "Yesterday", "2 days ago"); every page carries the
minute it was made, "0914-1139", the same "MMDD-HHmm" shape the core's
placeholder title takes. Today with no page is a node with no minute
and a dashed dot, and the one node whose click takes the create path.

- **D-34 (fixed)** The node is the page. It stands where the page's
  share of the roll falls, pushed apart from its neighbours only as far
  as its words need, and the map from the document to the rail runs
  through the nodes as placed, so the viewport band and the line
  slivers are level with the nodes and not with the roll's raw
  proportions. This replaces the day rows and the faint minimap behind
  them (issue #131), which did not line up with each other and were
  never meant to.
  *Acceptance:* `StreamNavigatorTests` pins the order, the day words on
  a day's first page, the minute on every page, the packing, the map's
  round trip and the band; `DayScrollTests` pins one extent per page,
  read off the roll's own frames.
- **D-35 (fixed)** Geometry, never glyphs. The roll hands the rail each
  page's span and each laid-out line as a rectangle (where it begins,
  what share of the wrap width it used) and nothing else. The slivers
  beside the track say a page has a long line and never what the line
  says. This is issue #131's rule restated for the navigator, and the
  reason no text type crosses `RollGeometry`.
  *Acceptance:* `RollGeometry.LineMark` carries two numbers;
  `DayScrollTests.testTheRollMeasuresEachPagesLinesAsRectangles`.
- **D-36 (fixed)** Ember is spent on three things on the rail: the
  active node with its stretch of track, the bar beside the viewport
  band, and the plus. The active node is the selected page's, not a
  scroll probe's: the selection is the app's one notion of where the
  surface stands, the caret is there, and the band already says where
  the reader is scrolled. Each ember mark is paired with a shape or a
  word (D-03).
- **D-37 (fixed)** Retention words instead of countdowns. A page past
  the seven day window (the ladder's longest rung) reads "7d+ ·
  retained" under a dashed stretch of track, with the window's end
  marked "7d"; days with no drawn page between two nodes are noted
  where they fall, "2 empty days". The gauge stays, on the active node
  and on every page's gutter, because time as geometry is D-11 and the
  gauge speaks its rounded words to VoiceOver.
- **D-38 (fixed)** A click on a node selects its page and scrolls the
  roll to its gutter; a click on bare track scrolls the roll to the
  stretch clicked and selects nothing; a wheel over the rail scrolls
  the roll as if it had turned over the page. The jump takes the
  stance's 160 ms and nothing at all under Reduce Motion (D-02). The
  hover preview is the platform tooltip: the day, the minute, the
  chord when one is bound, and the page's title on a second line, the
  one line the gutter already shows. A floating card was not built;
  the tooltip carries the same facts without a second surface.
- **D-39 (fixed)** The plus sits on the PAD heading, in ember text, and
  not on today's node. A page is minted with the clock's reading of
  now whatever the rail is showing, and a plus beside a day would
  promise a page on that day. Along the bottom the plus stays on
  today's tab, where the strip has always kept it.
- **D-26, amended** Down the side is **110 wide**, up from 96, the
  design's floor: the track, a node's dot, the day's words beside it
  and the gauge under them. The rest of D-26 stands.

The band is absent when the whole roll is on screen. The design draws
it always; a band around everything marks nothing, and it is the
scrolled reader the band exists for. This is the one place the build
narrows the design on the rail.

### The gutter

Each page's gutter on the roll reads the day and the minute, "today ·
0914-1139", on every page and not only a day's first, because the
minute is what tells two pages on one day apart and the day is what
the minute is read against; the perforation above still says where the
day changed. The strip's own gauge stands where the countdown text
stood, with its rounded words as the tooltip; a page past the window
reads "7d+ · retained" there instead. The selected page's gutter is
underlined in ember, with its words in ink rather than faint. The
design's "clear section" hover button is not built: Close page is on
the gutter's menu already, and D-10 asks that every hover action also
be in the menu, not that every menu action also be on hover.

## 2 · The sealed capsule's actions

State first, identity second, actions third. The block keeps D-27's
shape: the lock and the tracked `SEALED CONTENT` label on the top row,
the mechanical excerpt and the size class on the row under them.

- **D-40 (fixed)** The capsule is its own actions. A plain click selects
  the whole object (D-28) without opening its menu. Return or Space over
  the selected object opens the menu where the block's words begin,
  instead of typing a newline or a space over it; the secondary click
  opens it too. Three dots (`···`) in the block's top trailing corner are
  the visible affordance and open the menu when clicked. They are drawn
  while the pointer is over the block or the block is selected and keep
  their seat whether drawn or not (D-10). The block is still not a
  button: nothing happens until an explicit menu route is used and an
  item is chosen. A selected
  block wears the ember keyline and its tint, paired with the selection
  itself. Return and Space are the object's own keys and not chords, so
  they are not the keymap's; ⌘↩ stays the seal.
  *Acceptance:* `SealedCapsuleTests.testTheRowsLockAndActionsUseFlippedTextViewCoordinates`
  and `testReturnAndSpaceOpenTheObjectsMenuAndNothingElseDoes`;
  `ChipCell.actionsRect(in:)` is the one seat the drawing reads;
  `Coordinator.openChipMenu(at:from:in:)` is the one menu all three
  routes open.
- **D-41 (fixed)** The menu, in the design's words and order:

  ```text
  Copy decrypted contents        ⇧⌘C
  Create one-time link…
  ────────────────────────
  Remove protected content
  ```

  The removal item is *Remove protected content*, set apart by the
  separator and styled by AppKit. The chord beside the first verb is the keymap's: `chip::
  CopyDecrypted`, bound to `cmd-shift-c` in the bundled default, acts
  on exactly one selected sealed object and is declined anywhere else,
  so it can never reach a payload nobody pointed at. A keymap that
  moves the chord moves the menu's hint; one that unbinds it leaves the
  verb alone. This replaces the 2026-0915 record's *Remove from page*
  wording; the removal stays structural and undoable (D-30).
  *Acceptance:* `DocumentOpsTests.testTheChipMenuOffersPlaintextByName`,
  `SealedCapsuleTests.testTheMenuExposesTheNamedActionsAndAdvertisesTheCopyChord`,
  `BundledKeymapTests`.
- **D-42 (fixed)** The lines, in the design's words:

  - after a decrypted copy: `copied decrypted contents — small. the
    clipboard clears in 60 seconds.` The size is the object's own size
    class, the one its block shows, never a count (D-29); the number is
    the core's constant read through the seam. The timer makes a guarded
    clear attempt only if the general pasteboard still holds that write.
  - after a one-time link: `the link is on the clipboard — paste it
    where it needs to go.`
  - after a removal: `protected content removed.` with **Undo** beside
    it. Undo is owed to issue 170: today the core zeroizes an object
    the moment the document stops referencing it, so an Undo would put
    back a reference to nothing. The line ships now; the button is
    gated on one constant (`PageModel.offersRemovalUndo`) and appears
    the moment the detached state exists to reattach from (D-30, D-33).
    A notice that carries an action stays twelve seconds; one that only
    reports stays four.
  *Acceptance:* `SealedCapsuleTests.testTheLinesReadAsTheDesignWroteThem`,
  `PasteboardOfferTests.testACopyOutArmsTheClearAndFlashesTheInterval`.
- **D-43 (fixed)** The clear attempt after copy uses the core's
  **60-second** constant, `CLIPBOARD_CLEAR_SECONDS` in
  `crates/ffi/src/lib.rs`, read by the shell through
  `companion_clipboard_clear_seconds`. At that interval the core clears
  only if the general pasteboard still holds its write; this does not
  bound copies retained elsewhere. *Acceptance:* the FFI test pins 60,
  and `PasteboardOfferTests` reads it through the seam and verifies the
  guarded clear.

The 2026-0915 record's D-10 acceptance says a plain click only selects
the attachment. Menu presentation requires the explicit actions glyph,
Return, Space, or a secondary click, so selection does not put decrypted
copy first under an ordinary click.

## 3 · What this record does not change

Everything in the 2026-0915 record outside the passages named in the
front matter. In particular: the five operation classes and the
contract table (Law 0001), sealing one-way (D-30), the versioned
fragment (D-31), the three egress points (D-32), the page-owned clock
and no per object TTL (D-33), and the size class in every placeholder
and label.

## 4 · Amended in the 2026-0915 record

One line per passage, each of which carries a dated note pointing here.

- Section 4, metrics: down the side is 110 wide, not 96 (D-26).
- Section 3, the object's menu: the removal item reads *Remove
  protected content*, with the chord beside the first verb (D-41).
- Section 3, the confirmation line: the design's words and the guarded
  60-second clear attempt (D-42, D-43).
- D-29's acceptance: the interval comes from the core and clearing is
  conditional on the general pasteboard still holding the app's write.
- Section 10's summary line for D-29, D-32: the interval is 60 seconds.
