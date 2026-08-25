# ADR-0020: A day is a projection of live pages

- **Status:** proposed
- **Date:** 2026-08-24
- **Depends on:** [ADR-0006](0006-persistent-editor-storage-swap.md) (one
  persistent editor, whose invariant the contiguous roll must keep
  literally rather than argue around),
  [ADR-0016](0016-content-persists-across-restart.md) (the TTL is the
  only mechanism that destroys staged content the user did not ask to
  destroy, ADR-0016:86) and
  [ADR-0017](0017-durable-tabs-expiring-pages.md) (durable tabs,
  expiring pages, and the eject trigger this decision has to answer).

## Context

Issue #79 asks for a page per unit of time, with the tabs turned down
the side of the card and labelled relative to now — Today, -1d, -3d. The
issue is labelled `decision` as much as `prototype`, and the decision
underneath it is prior to any pixel: what is a unit of time made of.

Two answers are available and they lead to different applications.

The durable answer makes a day an object the app creates, names, orders
and reaps. Every version of it trips something already settled. A
tab-per-day meets `DEFAULT_SHEET_CAP = 9`
(crates/core/src/store.rs:31), which is refuse-don't-evict by design and
which `restore` enforces on the way in as well, refusing a file that
claims more tabs than the cap as `Malformed`
(crates/core/src/persist.rs:252), and it makes the calendar a second
lifetime mechanism for a durable slot — the condition
ADR-0017 names in as many words as its own eject trigger, which reopens
that ADR and ADR-0016 or does not ship. A persisted day object needs a
field in the snapshot, and the framing rule buys only *appended,
tolerantly read* fields; the module header says outright that a field
which moved, changed width or changed meaning is outside what the rule
buys (crates/core/src/persist.rs:62-74), and a new magic refuses every
existing sealed file.

The derived answer makes a day a query over the pages that already
exist. It costs no format byte, creates no object, and is exactly
reversible, which is what makes a mode toggle safe in both directions
without any content-loss engineering at all.

Two further constraints bound the mechanism rather than the model. Doc
05's frugality budget targets ~0% idle CPU with no periodic wakeups and
expiry scheduled rather than polled, and the shell arms exactly one
timer, from `companion_next_event_ms`
(shell/Sources/CompanionKit/PageModel.swift:2345), which folds page
deadlines and hold lapses and nothing else; a relative label that
changes at local midnight must therefore not become a second timer or a
new arm on the first. And doc 05 commits to `prefers-reduced-motion` swapping animation
for stepped states, with no parallax and no bounce, which the issue's
word "autoscroll" has to be read against.

The only calendar arithmetic in the tree today is `placeholder_title`
(crates/core/src/sheet.rs:712-721), which buckets a wall stamp by the
store's own UTC offset at crates/core/src/sheet.rs:715. There is no
notion of a day anywhere else in core.

## Decision

**A unit of time is a projection over live pages, not an object.** A day
is a bucket over `Sheet::created_wall_ms` folded through the store's
`local_offset_seconds`, recomputed on every read, never persisted, never
named, never a Tab. Nothing durable is created, and the projection is a
read that calls no core mutator.

The specifics, stated here rather than in a footnote, because each one
is a thing a reviewer will otherwise have to infer:

**The page's stamp, not the tab's.** `Tab::created_wall_ms` is the
slot's birthday. `open_page` mints today's page into slots that are days
old, and `new_tab` always stamps `clock.wall_ms()`, so core offers no
back-dated tab; a tab stamp would label a page typed this morning "Day
-5". The page's stamp is honest, and it dies with the page, which is the
issue's own rule: no page, no unit.

**The core answers, and it answers relatively.** `summary_json` gains
`page_day_offset` — 0 for today, -1 for yesterday, null for a slot
holding no page — and `page_has_content`. `local_offset_seconds` stays
off the ABI and no `Foundation.TimeZone` is used anywhere, so the tab's
`MMDD-HHmm` label and the day it is bucketed into cannot disagree at a
DST change. Shipping the *relative* offset rather than a day index is
what removes the shell's need to know what "today" is.

**No calendar arm and no second timer.** Because `page_day_offset` is
recomputed on every `companion_tabs_json`, the cosmetic redraw the app
already runs re-reads the summaries and the labels roll over on their
own (shell/Sources/CompanionKit/PageModel.swift:2338, at 1 Hz raised and
every 30 s at rest, shell/Sources/OnetimePad/BackdropStance.swift:182-187).
`SheetStore::next_event` is untouched, `companion_expire_due` gains no
new reason to fire, and no `Timer` is added.

**Content is the ledger's bar.** A unit is listed when one of its pages
holds non-whitespace ink or at least one chip — the exact predicate
`entomb` already applies to decide whether a dying page did anything
worth recording (crates/core/src/store.rs:1364-1371), extracted as
`Sheet::has_content()` and called by both. A day therefore gets a row
exactly when its page would leave a mark in the ledger. Two exemptions:
today's unit is always listed, and the unit holding the selected page is
always listed, so the region under the caret does not pop into existence
on the first typed character. The answer crosses the seam as a bool,
never as text.

**Displayed is not minted.** Day 0 is a place at the top of the roll
that always exists and always has a rail row; it holds a page only when
a gesture put one there. Entering the mode mints nothing, launching
mints nothing, `refresh()` mints nothing, and the rail never mints on
selection. Minting stays what ADR-0017 narrowed it to: three selection
gestures plus the Return grant.

**Labels are relative, and a vanished day leaves no mark.** When a
middle day's page expires the unit is absent and the perforation joins
its neighbours, carrying the surviving label. There is no placeholder
row and no renumbering, because a row for a day whose pages are gone is
durable state remembering a deletion — a tombstone (ADR-0009) and an
archive-shaped record (doc 03 §1). Underneath, the tab stays standing,
named and empty, exactly as `expire_due` leaves it.

**Nothing durable, and the format does not move.** No `Day` type, no
per-day TTL, no day index in the snapshot, no new field, no new magic.
`OTSSNAP4` is byte-for-byte what it was. The mode's only durable trace
is one `UserDefaults` boolean, `showsTimeUnits`, default false.

The full argument, the three answers the issue asked for and the change
map are in
[`../spec/feature/vertical-time-tabs/README.md`](../spec/feature/vertical-time-tabs/README.md).

## Required work

None of the following existed when this decision was written. Items 1 to
4 are the model and run under `cargo test` on Linux, which is where the
risk is meant to be retired; the rest is shell work that only builds on
macOS.

**Landed 2026-08-25.** Items 1 to 6 are in the tree. The day arithmetic
is one function with two callers and the content bar is one predicate
with two callers, which is what makes the agreements this decision rests
on structural rather than a habit; the tab summary carries both answers
and nothing a user can see moved. A summary's keys are now the fifteen
that were always there plus these two, and a test holds the whole set
still, so the addition cannot quietly become a rename.

**Landed 2026-08-25, second pass.** Items 7 to 10 are in the tree, and
still nothing a user can see: the projection, the flag, the mode-aware
targets and `openToday()` landed together with no Settings row and no
rail, deliberately, so that a branch merged on its own can never show a
control that does nothing. The model's every law is now argued in tests
that build no window, and the identity that protects horizontal mode —
the target list with the mode off equals the strip element for element —
is an assertion rather than a promise. Items 11 onward are still work.

**Landed 2026-08-25, third pass.** Item 11 is in the tree, and it is the
one item in this list whose whole claim is that nothing happened: the
editor's building and its page swap now have names and callers of their
own, and horizontal mode does not know. The evidence is the shape of the
change — no existing test needed a line — and it is worth pressing on in
review, because a flag dropped out of the editor's construction is
invisible until the day it matters. Items 12 onward are still work.

**Landed 2026-08-25, fourth pass.** Item 12 is in the tree, and it is
the first thing in this decision a user can see: the rail, the card's
branch and the Settings row that turns them on. The mode is now
judgeable on navigation and toggle safety alone, which is why the rail
was put before the roll — the biggest engineering is still ahead and
can be reverted without taking the mode with it. The rail carries none
of the strip's four verbs and says so in its own caption, which is the
honest cost of shipping this half first. Items 13 and 14 are still
work.

1. `pub fn local_day(wall_ms: u64, utc_offset_seconds: i32) -> i64`,
   hoisted out of the arithmetic already inside `placeholder_title`
   (crates/core/src/sheet.rs:712-721, the
   `local_seconds.div_euclid(86_400)` line at :715), with
   `placeholder_title` calling it and re-exported from
   crates/core/src/lib.rs to satisfy `missing_docs`. Its doc comment
   states that the offset is read at render time, so a stamp within an
   hour of local midnight can bucket differently after a DST change —
   the property `placeholder_title` already has and its tests already
   pin (crates/core/src/sheet.rs:1170-1185).

   **Landed.** The conversion to local seconds both readings need came
   out with it, as a private `local_seconds` beside it, so the day and
   the clock face on a label are read out of one line rather than two
   copies of it.
2. `Sheet::has_content()`, holding the predicate that is inline in
   `entomb` today (crates/core/src/store.rs:1364-1371): any
   `Segment::Ink` that is not whitespace, or a non-empty chip vector.
   `entomb` calls it, so there is one predicate with two callers rather
   than two definitions that can drift. A `Sheet::local_day` convenience
   joins it for the FFI's use.

   **Landed.** `entomb` asks the page rather than walking it, and a
   test in the store puts the two readers over the same matrix of
   pages: the predicate before the page dies, the ledger after.
3. `SheetStore::wall_ms()` beside `now()` (crates/core/src/store.rs:450)
   and `local_offset_seconds()` (:402), because computing a *relative*
   offset needs today's stamp as well as the page's. **Landed.**
4. `summary_json` (crates/ffi/src/lib.rs:2385) takes the current wall
   stamp and gains exactly two keys, `page_day_offset` and
   `page_has_content`, with JSON null for the first when the slot holds
   no page, matching `page_id`'s established null.
   `companion_tabs_json` (crates/ffi/src/lib.rs:978) reads the stamp
   once per call and passes it down. No new FFI symbol, no new route.

   **Landed.** The stamp is read before the walk starts, so every row
   of one answer is measured against one reading of today and two pages
   born a minute apart cannot straddle a midnight that passed halfway
   down the strip.
5. The header's field-contract block for `companion_tabs_json`
   (crates/ffi/include/companion_ffi.h:213-235) gains the two fields in
   the same commit as the fields themselves: that the offset is
   relative, computed with the store's own UTC offset, recomputed on
   every call rather than cached, and null exactly when `has_page` is
   false. The header is hand-maintained (ADR-0003), so it is the
   contract document as well as the declaration. **Landed**, in that
   commit.
6. `TabSummary` (shell/Sources/CompanionKit/CompanionClient.swift:26)
   decodes both fields, each with a doc comment saying why the stamp is
   the page's and not the tab's. **Landed**, with a contract test
   decoding both off a live core, including the null offset on a slot
   whose page has expired.
7. A pure `TimeUnitProjection` over the summaries, in a new
   shell/Sources/CompanionKit/TimeUnits.swift, holding every law of the
   model in one place: a bucket is present when any of its pages has
   content, or it is bucket 0, or it holds the selected page; pages
   inside a bucket keep strip order; a unit's gauge comes from its
   soonest-dying page; and a count of the live pages the projection
   drops. `TimeUnit` is an enum with one case, `.day`.

   **Landed**, in shell/Sources/CompanionKit/TimeUnits.swift, over
   value types with no AppKit in the file, so the whole model is under
   XCTest without a window or a running core. One law was written down
   that this list had left open: a day the projection draws draws every
   page on it, filtering by day and never by page, so a page cannot
   quietly disappear out of a day that is on screen and the hidden
   count stays a count of days nobody can reach.
8. `showsTimeUnits` on `PageModel`, in the `wrapsLines` pattern
   (shell/Sources/CompanionKit/PageModel.swift:333-336, seeded at :634),
   writing only to the injected `UserDefaults`. It deliberately does not
   call `markDirty()`, which would take the sudden-termination hold and
   arm a debounced ciphertext write, buying a fresh sealed generation
   for a presentation preference.

   **Landed.** A test flips it both ways across an edit and asserts the
   strip, the two emptiness predicates, the selection, the save status
   and the arming counter are all where they were.
9. `select(index:)` (shell/Sources/CompanionKit/PageModel.swift:1394)
   and `step(_:)` (:1401) route through a mode-aware list of targets
   whose value with the mode off equals the strip element for element,
   pinned by a dedicated test. That test is the evidence for "horizontal
   mode is unchanged".

   **Landed.** `step` gave up its copy of `select`'s ledger-and-focus
   ceremony and calls `select` instead of repeating it, so the rule
   lives in one place; the existing focus-law suite, which pins that a
   walk leaving the ledger and minting asks for the keys exactly once,
   passes unedited.
10. `openToday()`: select today's tab when a live page is there, else go
    through the shipped create path (`newPage()`,
    shell/Sources/CompanionKit/PageModel.swift:1673, and
    `createPageAndFocus(in:)`, :1716) unchanged, with the cap refusal
    naming the Settings toggle in this mode. The `.pageNew` arm
    (shell/Sources/CompanionKit/Keymap/KeymapRegistry.swift:27-28)
    branches on the mode. No new `CommandID`, no keymap row.

    **Landed**, through `newPage()`. The refusal is the shipped one with
    its sentence widened in this mode (`PageModel.capRefusal`), so the
    words the strip has always shown are unchanged and a test holds both
    of them still.
11. The editor factoring: building the one persistent `InkTextView`
    separates from wrapping it in a scroll view
    (shell/Sources/CompanionKit/InkEditorView.swift:35, and
    `scrollStack(for:)` at :141 whose unbounded `maxSize` is
    load-bearing), and the page-swap ceremony separates from
    `updateNSView` (:248-303) so a second surface can mount the same
    editor without forking it. The contract comments move with the code
    they guard, `shedLayoutManagers` still runs at mount (:58), and the
    existing suite passes unedited.

    **Landed.** The building is
    `InkEditorView.makeInkTextView(model:sheetID:coordinator:)`
    (shell/Sources/CompanionKit/InkEditorView.swift:107, with the mount's
    shed at :121) and the swap is
    `Coordinator.moveEditor(_:to:storage:restoringScrollIn:)` (:370-397),
    statement for statement and in the order they were in, with the
    contract comments carried across beside the code they guard.
    `makeNSView` (:35) and `updateNSView` (:283-310) are thin callers and
    `scrollStack(for:)` (:176) did not move a character. The line numbers
    in the paragraph above name the tree this decision was written
    against, before the factoring moved them.

    Two things came out of the work that the item had not named. Editing
    stays with the mount rather than with the building, because
    `readOnly` is the backdrop's stance and not a property of the editor
    — `updateNSView` re-gates it on every pass — so the factory sets no
    `isEditable` and takes no `readOnly`. And `saveViewState` and
    `restoreViewState` now take an optional scroll view: a caret belongs
    to the page wherever the page is mounted, an offset belongs to the
    clip the page sits in, so a mount with no scroller of its own runs
    the caret leg and skips the scroll leg. That is the leg the roll will
    take, since one scroller over several days has an offset belonging to
    the roll rather than to any page in it.
12. The rail: a new `TimeRailView` reusing `GaugeBar`
    (shell/Sources/CompanionKit/TabStripView.swift:435) and `EmptyRule`
    (:416) where they stand, so TabStripView.swift takes no diff; the
    card's content row branching as a whole expression
    (shell/Sources/OnetimePad/Views/BackdropRootView.swift:99-115, with
    the strip row at :112-114 absent while the mode is on); and the
    toggle in `ConnectionSettingsView`
    (shell/Sources/CompanionKit/SettingsSections.swift:114-119), not in
    `BackdropSettingsView`'s Surface form, whose hard-coded
    `.frame(height: 120)`
    (shell/Sources/OnetimePad/BackdropSettingsWindow.swift:81) clips new
    rows silently.

    **Landed**, in shell/Sources/CompanionKit/TimeRailView.swift.
    `TabStripView.swift` did take no diff: `GaugeBar` is still at :435
    and `EmptyRule` at :416, used from a second file in the same module.
    The card branches at
    shell/Sources/OnetimePad/Views/BackdropRootView.swift:114 with the
    strip row at :139, and the toggle sits at
    shell/Sources/CompanionKit/SettingsSections.swift:122 — the Surface
    form's `.frame(height: 120)` is still at
    shell/Sources/OnetimePad/BackdropSettingsWindow.swift:81, untouched
    and unraised, because nothing was added to it. The line numbers in
    the paragraph above name the tree this decision was written against.

    Three things came out of the work that the item had not named.
    First, `TimeUnitProjection.Unit` gained `spokenRemaining`
    (shell/Sources/CompanionKit/TimeUnits.swift:134): the rail carries
    `SheetTab`'s accessibility triple and the third of those had no
    source, and looking it up in the summaries would have let a row
    speak one page's clock while drawing another's — the gauge already
    comes from the day's soonest-dying page, and now so do both readings
    of its countdown. Second, which row is lit is a decision and not a
    drawing, so it is a pure function too (`selectedBucket`): the mark
    follows the selected page's day rather than the row last clicked, and
    an empty Today takes it only when no other day has it. Third, the
    card's two content rows are written out in full rather than sharing
    one wrapped row, so the off path is identical by inspection; the cost
    is that flipping the mode is an identity change that remounts the
    editor, which is what a deliberate flip should cost and what a
    keystroke never pays.
13. The roll: one scroll view over a flipped stack, with the live editor
    as a **permanent child** whose frame origin moves and on which
    `removeFromSuperview` is never called, and every other visible page a
    non-focusable rendering over its **own** `NSTextStorage` seeded from
    `documentRuns(sheet:)`
    (shell/Sources/CompanionKit/CompanionClient.swift:672). The quiet
    renderings never enter `storages`
    (shell/Sources/CompanionKit/PageModel.swift:429) or `undoManagers`
    (:439), and are pruned in `refresh()` (:1234) on the same live-page
    set. `PageContentView` gains one branch
    (shell/Sources/CompanionKit/PageSurface.swift:39-47) with the
    ADR-0006 contract comment about the absent `.id(page)` intact. Every
    path that moves the editor between day regions goes through the
    focus law's refocus (:1576, private today).
14. A hardware procedure under docs/qa/verification-procedures/, in the
    shape of the existing ones: midnight arriving while the card rests, a
    middle day expiring, summoning after scrolling into history, undo
    after clicking into an older day, toggling both ways with content on
    screen, VoiceOver down the rail, and reduced motion on.

## Consequences

The strip's model survives intact. A tab's identity, name, rung and
position are untouched by the calendar, and the two modes read the same
`tabs` array, so a user who flips the toggle sees the same content
arranged two ways rather than two stores.

**Stated cost, one.** The mode materializes a plaintext rendering of
every visible day at mount, where horizontal mode holds one storage per
page the user actually visits. This is not a new class of exposure — the
core already holds every live page's plaintext, and horizontal mode
reaches the same nine storages once the user has visited nine tabs — only
an earlier one, and it sits inside ADR-0012's threat boundary rather than
crossing it. It is bounded by the cap, released on mode flip and on
unmount, and it is not lazily materialized: the bound is nine, and the
cost is written here rather than engineered around.

**Stated cost, two.** A label can be up to 30 s stale at local midnight
while the card rests, and up to a second while it is raised. That is the
price of adding no timer, and it is the direct consequence of choosing a
relative offset over a scheduled rollover.

An expired day and a blank day are indistinguishable in the rail. That is
the issue's own example, and it is the price of refusing a tombstone.

Rows appear and disappear as pages expire, which will read to somebody as
tabs being destroyed. Nothing is: the rail never offers close, the tab
stands underneath, and the strip shows it again the moment the toggle
goes off. This ADR is proposed rather than accepted precisely so that
reading gets tested in review before the prototype is trusted.

The mode shows only the days the rungs let live. The backdrop opens tabs
at the 7d rung (shell/Sources/CompanionKit/FormFactor.swift:229), so Day
-1 through Day -6 are reachable out of the box, but a pad re-rung to 8h
shows only Day 0 and can read as broken rather than as empty. A
mode-specific default rung is refused: that would be the mode reaching
into core state, which is the one thing this design will not do.

Nine slots can fill with blank old pages that the content predicate
hides, making today unreachable with no visible cause. The rail's footer
counts them and its tooltip names the toggle; the refusal names the
toggle too. Nothing is auto-discarded, because auto-reaping blank pages
is a lifetime mechanism the user did not name.

The quiet regions are the nearest this tree has come to firing ADR-0006's
second eject trigger, "a future feature needs per-sheet view instances".
The claim made here is that it does not fire: there is one editor, one
`activeEditor`, one `performSealedPaste` and one first-responder
candidate in the card, and the quiet regions are renderings over private
storages that the model's maps never learn about. If that claim fails on
hardware, the design that fails with it is the roll, not the projection.

Two interaction models now exist behind one boolean, which doc 03 §4
would not thank us for indefinitely. The toggle is the prototype's
instrument rather than a feature: if the vertical mode wins, the
follow-up is an amendment to doc 04 and one model, not a setting kept
forever out of politeness.

Nothing in this decision is reachable by the panel form factor, which is
archived (ADR-0014), and nothing in it is reachable by a user who leaves
the toggle alone.

## Eject triggers

- Anyone proposes a durable `Day`, a per-day TTL, a day index in the
  snapshot, or a calendar arm on `SheetStore::next_event`. Any of those
  is the durable answer this ADR declined; it reopens ADR-0016 and
  ADR-0017 or it does not ship.
- The nine cap is hit in this mode while live pages sit on fewer than
  eight distinct days. Then the cap is counting something the mode made
  invisible, and either the predicate or the cap gets revisited, not the
  projection.
- The TTL ceiling rises above 7d. That reprices the eight-day arithmetic
  in the spec's cap section, and the claim that eight rows fit under nine
  slots has to be recomputed before it is repeated.
- Rows appearing and vanishing reads to a dogfooder as tabs being
  destroyed. Then either the labels or the model are wrong, and the fix
  is in the surface's vocabulary, not in giving days a lifetime.
- The rail's hidden-blank-pages count is routinely non-zero. That is the
  instrument for the content predicate: a bar that hides pages people
  think they have is the wrong bar.
- Dogfood shows users flipping to horizontal to reach a verb the mode
  does not carry. Then the day-header gutter is not enough and either the
  rail carries the verbs or the modes are less exclusive than this design
  assumes.
- The toggle is found to have moved core state in either direction — a
  changed tab, a changed selection the user did not make, a fresh sealed
  generation, or a rotation. That falsifies the property the whole
  two-way safety argument rests on.

## Deferred

1. **Any unit but the day.** The bucketing is parameterised where
   retrofitting would be expensive and the core field is day-relative,
   but only the day is built and only the day is tested. A week needs a
   week-start policy — Sunday or Monday, locale or fixed — and probably a
   second core field, and a prototype has no basis to guess either.
2. **Amending docs/spec/design/04-interaction-model.md.** The tab law
   there describes the horizontal strip, which is unchanged. It is
   amended only if this ADR is accepted after the dogfood window, and
   then in a named section in the open rather than by editing the
   standing claim.
3. **Markdown styling parity on quiet regions.** A quiet day renders in
   the base ink font with chips as their non-secret face. The flatness
   against the live day is a stated gap, cheap to close if it grates, and
   deliberately not paid for before anyone has looked at the roll.
4. **Whether both modes survive.** See the Consequences above; that is a
   question for the dogfood window and its answer belongs in this ADR's
   next revision, with Consequences rewritten against what was observed
   and any eject trigger that fired marked and answered.

## See also

[`../spec/feature/vertical-time-tabs/README.md`](../spec/feature/vertical-time-tabs/README.md),
which carries the full argument, the three answers, the change map and
the open questions. [ADR-0017](0017-durable-tabs-expiring-pages.md) for
the tab/page split whose eject trigger this decision has to answer, and
[ADR-0009](0009-chip-deletion-deliberate-final.md) for why a day whose
page expired leaves no marker behind it.
