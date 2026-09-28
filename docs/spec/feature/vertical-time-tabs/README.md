# docs/spec/feature/vertical-time-tabs/README.md
---

# Feature: vertical time tabs, a page per unit of time

Status: **draft**, prototype complete · 2026-08-25
Scope: a prototype mode on the backdrop, behind a Settings toggle that
is off by default. Horizontal tabs keep their behaviour and their
pixels. The sealed format, the tab model, the TTL ladder and the cap are
untouched.
Governs against:
[`../../design/03-design-principles.md`](../../design/03-design-principles.md)
(§1 comfortable being temporary, §4 frugal),
[`../../design/04-interaction-model.md`](../../design/04-interaction-model.md)
("Sheets, several: tabs at the bottom", and the keyboard map),
[`../../design/05-technical-direction.md`](../../design/05-technical-direction.md)
(the accessibility commitments and the frugality budget),
[ADR-0006](../../../adr/0006-persistent-editor-storage-swap.md) (one
persistent editor),
[ADR-0016](../../../adr/0016-content-persists-across-restart.md) (the
TTL is the only lifetime mechanism the user did not ask for) and
[ADR-0017](../../../adr/0017-durable-tabs-expiring-pages.md) (durable
tabs, expiring pages).
Decision: [ADR-0020](../../../adr/0020-a-day-is-a-projection-of-live-pages.md),
**proposed**.
Issue: #79, labelled `decision` and `prototype`, milestone "Dogfood
fixes".
Refined by: #131 (the rail says the day in words, and its background
became a faint minimap of the roll), milestone "Editing rhythm and the
time rail".
Side docs:
[`2026-0828-paradigms.md`](2026-0828-paradigms.md)
(paradigms, the duration the UI optimizes for; concept only,
unscheduled, though its TTL-ladder section graduated into ADR-0011,
accepted 2026-09-01), and
[`2026-0904-capacity-and-today-proposal.md`](2026-0904-capacity-and-today-proposal.md)
(the agreed proposal that the tab cap must not prevent writing Today's note;
implemented 2026-09-06 by removing the cap, recorded in ADR-0017's history).

## The shape #79 asks for

Turn the strip on its side and let each tab be a unit of time rather
than a slot. Today at the top, yesterday under it, the days before that
below, each labelled relative to now (~~Today, -1d, -3d~~ Today,
Yesterday, 2 days ago on the rail since issue #131; the short form stays
in the roll's day gutter), so the labels stay true without anyone
rewriting them. One page per unit. The unit is
configurable and the first one is the day. Day 0 is always displayed,
whether or not anything is on it. A unit gets a tab only if its page has
content. The days read as one contiguous scroll, anchored on the current
day when the pad is opened or summoned. Horizontal tabs keep working
exactly as they do; the two modes are exclusive, chosen by a Settings
toggle, and flipping it either way loses nothing.

Three questions came with the request and are answered below rather than
left for the code to decide by accident: what a middle day's expiry does
to the scroll, what "content" means, and where Day 0 sits when the
surface opens.

One convention, stated once so that nobody has to guess it per citation.
The line numbers in the argument sections (everything above "Change
map") name the tree each was **written against**, and the six branches
have moved most of them since; the symbol beside each one is what to
grep for. The change map, the "what the prototype answered" sections and
the test plan describe the landed state, and their citations are
refreshed against the tree as it stands. Where a file has proved it will
keep moving, they name the type or the function and no number at all.

## The model: a day is a query, not an object

A unit of time is not a thing the app creates. It is a bucket over the
page's own birth stamp, computed on every read and stored nowhere.

`Sheet::created_wall_ms` is the page's birthday in Unix milliseconds
(`crates/core/src/sheet.rs`, the field split of ADR-0017). Fold it
through the store's own UTC offset (the same offset the tab's
`MMDD-HHmm` placeholder renders from) and a page has a local day index.
That fold used to be one line inside `placeholder_title`; branch 2
hoisted it into `local_day` (`crates/core/src/sheet.rs`, the
`local_seconds(…).div_euclid(86_400)`), which
`placeholder_title` now calls, so the label and the day are read out of
one line rather than two copies of it. Subtract today's index from the
page's and the answer is a small relative integer: 0 for a page born
today, -1 for one born yesterday. That integer, and one boolean saying
whether the page holds anything, are the only two facts the seam gains
(`crates/ffi/src/lib.rs`, `summary_json`).

Everything follows from that arithmetic and nothing else exists:

- **Nothing durable.** No `Day` type, no day index in the snapshot, no
  day name, no day that survives its pages. `OTSSNAP4` gains no byte and
  the magic does not move; the framing rule that makes an appended field
  cheap (`crates/core/src/persist.rs`) is not spent, because there
  is nothing to append.
- **The page's stamp, not the tab's.** `Tab::created_wall_ms` is the
  slot's birthday, and `open_page` mints today's page into slots that are
  days old. A tab stamp would label a page typed this morning "Day -5".
  The page stamp is honest, and it dies with the page, which is the
  issue's own rule restated: no page, no unit.
- **The core answers, not the shell.** A shell-side `Foundation.TimeZone`
  would disagree with the core's offset at a DST change, so a page could
  read "0824" on its tab and "Yesterday" on the rail. Hoisting the one line of
  arithmetic into a shared `local_day` and calling it from both places
  makes agreement structural. It also puts the whole model under
  `cargo test` on Linux, where the risk is meant to be retired, rather
  than behind a macOS-only Swift suite.
- **Relative, so midnight needs nothing.** Because the offset is
  recomputed on every `companion_tabs_json`, the cosmetic redraw the app
  already runs re-reads it and the labels roll over on their own
  (`shell/Sources/CompanionKit/PageModel.swift`, at 1 Hz raised and
  every 30 s at rest, `shell/Sources/OnetimePad/BackdropStance.swift`).
  `next_event` gains no calendar arm, `companion_expire_due` gains no new
  reason to fire, and the shell adds no second timer. The honest cost is
  a label up to 30 s stale at local midnight while the card rests, and it
  is written down rather than engineered away.
- **The offset is read now, not stored.** A stamp within an hour of local
  midnight can bucket differently after a DST change or a flight. That is
  the property `placeholder_title` already has and its tests already pin
  (`crates/core/src/sheet.rs`); the day inherits it rather than
  inventing a second, disagreeing answer. Fixing it would mean storing a
  day index, which is a durable field this prototype has not earned.

## Why this needs no new lifetime mechanism

ADR-0017 names its own eject trigger: a second lifetime mechanism
proposed for tabs reopens it and ADR-0016 or it does not ship. A rail of
rows that appear and vanish looks exactly like that, so the distinction
is worth stating flatly.

Nothing about a tab changes. The calendar creates no tab, closes none,
re-dates none, re-orders none and re-labels none. A tab's id, name, rung
and strip position are what they were, and the mode never offers close.
A unit disappears from the rail for one reason: the live page keyed to
it expired under its TTL, which is the one mechanism ADR-0016 allows to
destroy content the user did not ask to destroy (ADR-0016).
Underneath the rail the tab is still standing, still named, still empty,
exactly as `expire_due` leaves it, and it is visible again the moment the
toggle goes off.

The reverse holds too, and it is what makes the toggle safe in both
directions without any content-loss engineering: the projection is a
read. It calls no core mutator, and the mode flag lives in `UserDefaults`
beside `wrapsLines` rather than in the sealed file. Flipping it moves no
core state, so there is nothing to lose and nothing to migrate.

## Why there is no cap

Until 2026-09-06 the store refused a tenth tab, on the reasoning that
nine was the keyboard map's natural limit and that a seven-day ceiling
could fill at most eight days. The arithmetic held; the refusal did not
survive this mode (issue #158). Nine slots full of blank old pages are
hidden by the content predicate, so a person was refused today's page
with no visible cause, and the only remedy was to leave the mode, find a
tab in the strip, close it and come back. A cap that a mode can make
invisible is not a cap a person can manage.

So the cap is gone, in the core and not only here
(`crates/core/src/store.rs`). `new_tab` cannot refuse, the restore path
no longer treats a wider strip as malformed, and nothing at the seam
answers a new page with a wall. Refuse-don't-evict stays in the only
form that still means anything: eviction is by the TTL the user chose,
and nothing is auto-discarded to make room, because nothing needs making
room for. Auto-reaping blank pages is precisely the second lifetime
mechanism the ADRs forbid, and removing the cap is what lets the
retention decision in ADR-0017 stand untouched.

⌘1 to ⌘9 keep their meaning as shortcuts to the first nine visible
targets in either mode. They set no maximum: a tenth day, or a tenth
slot on the strip, simply has no chord and is reached by a click. The
strip scrolls sideways to hold the slots that no longer fit across the
card, and follows the selection so a page minted past the edge is on
screen the moment it exists.

The rail's footer still shows a dimmed count of the live pages the
projection is not showing, with the Settings toggle named in its
tooltip, so nothing the mode hides is unreachable. The count is now
purely an instrument: if it is routinely non-zero in dogfood, the
content predicate is wrong.

## Day 0 is a place, not a page

"Day 0 is always displayed" is satisfied by rendering, never by minting.
Bucket 0 is a place at the top of the roll that always exists and always
has a rail row. It holds a page only when a gesture put one there.

ADR-0017 narrowed minting to three selection gestures plus the Return
grant precisely so that a page expiring under the cursor cannot start a
countdown on nothing, and `reconciledSelection` deliberately never mints.
Entering the mode mints nothing. Launching mints nothing. `refresh()`
mints nothing. The rail mints nothing on selection. An empty Day 0 shows
the empty state the app already ships, with its Return grant intact
(`shell/Sources/CompanionKit/PageSurface.swift`, `EmptyStateKeyGrant`).

Because every mint stamps `wall_ms()`, which is now, every page the
user creates lands in Day 0 by construction. The gesture-only rule and
the day shape turn out to want the same thing: a day may hold several
pages, and the projection lists them under that day in strip order, but
every one of them was minted on that day by a gesture.

⌘N in this mode has three readings, and all of them are `openToday()`
(issue #158). When today holds a page and the selection is elsewhere,
it goes there. When today holds none, it creates one. When the person
is already on today's page, it creates a second page beside the first:
first press jumps, second press creates, blank or written on, exactly
as on the strip. The rail's Today row carries the strip's + button for
the same action, with the strip's tooltip, and it mints outright the
way the strip's does.

The gestures that name today as a place rather than ask for a page take
`startToday()` instead: the roll's empty Today region and the `.today`
target, which exists only while today holds no page. Those go to today's
page when it exists and create it when it does not, and never a second
one, because a grant can fire again after the page it made has appeared
and a place that made a page a moment ago must find that page.

None of this is a new mint policy: every arm either selects an occupied
tab, which cannot mint, or goes through the shipped create path
unchanged. No mint-target heuristic, no reuse of an arbitrary named
empty tab: flipping back to horizontal must never reveal that a tab the
user named now holds today's page.

## The three answers

### TTL expiry of a middle day: the scroll closes up

It closes up, and the gap lives in the labels rather than in the layout.
When Day -2's page expires the unit is simply absent: the rail reads
Today, Yesterday, 3 days ago, and one perforation joins Yesterday to
3 days ago, carrying that day's gutter label, "-3d". Nothing marks the
place where "-2d" was.

This is not tidiness; it is the only choice the model can make honestly.
A day exists because a live page with content is keyed to it. When that
page expires there is nothing left to key on, and holding the gap open
would need durable state remembering that a day once had content. That
is a tombstone for dead content, which ADR-0009 forbids for sealed bytes
and doc 03 §1 calls the safety net that quietly becomes an archive. It
would also have to live somewhere, and no content-derived or app-derived
string may reach the durable Tab, ADR-0017's load-bearing refusal.
Renumbering the survivors to 1st, 2nd, 3rd would lie about time. Relative
labels give the gap for free, which is the strongest argument for the
issue's own choice of relative labels, and the issue's own example
already reads this way.

Underneath, nothing changes: the tab stays standing, named and empty
exactly as ADR-0017 requires, and reappears in the strip the moment the
toggle goes off.

Note deliberately that an expired day and a blank day are
indistinguishable in the rail. That is the issue's example, where Day -2
is missing because it was blank.

### What "content" means: non-whitespace ink, or one chip

Non-whitespace ink, or at least one sealed chip, answered core-side,
never inferred from the shell.

It is not a new predicate. It is the one `SheetStore::entomb` already
applies to decide whether a dying page did anything worth recording
(`crates/core/src/store.rs`). The work extracts it as
`Sheet::has_content()`, rewires `entomb` to call it, and exposes it as a
single boolean, `page_has_content`, on the tab summary, with a test
asserting the two agree over a matrix of pages. The property that buys is
worth stating: **a day gets a row exactly when its page would leave a
mark in the ledger.**

"Any bytes" is rejected on two grounds. A page holding one stray newline
would manufacture a day and hold a rail row for as long as the page
lives. And there is no existing core definition of it, so it would be a
second emptiness predicate in a codebase that already carries two
security-load-bearing ones: `holds_no_page` fires key rotation and
`has_no_tabs` is the only condition that unlinks the sealed file, and the
header warns in as many words against recomputing either shell-side
(`crates/ffi/include/companion_ffi.h`).

The answer crosses the seam as a bool, never as text, so the boundary law
holds and `companion_sheet_document_json` is never used as a content
probe.

Two exemptions keep the surface honest rather than clever: today's unit
is always listed, and the unit holding the selected page is always
listed. Without them the region under the caret would pop into existence
on the first typed character.

### The anchor on open and on summon: Day 0 is the top

Day 0 is the top of the document. Time runs downward: today at offset
zero, yesterday below it behind a perforation, and so on back through
whatever is still alive.

On launch, on entering the mode, and on every summon, the clip goes to
the origin, instantly, unanimated, with no per-session scroll memory to
persist or restore. That makes "Day 0 is always displayed" structural
rather than enforced: there is no anchoring state that can be wrong, and
it matches the order the issue itself writes the rail in.

Between those moments the scroll is free. A user can sit in Day -3 as
long as they like, and the next summon re-anchors, because the pad is
furniture (doc 03 §2) and a pad untouched since yesterday should present
today. Nothing else ever moves the roll: refresh, expiry and midnight
rollover leave the offset alone, and when a rollover inserts rows above
the viewport the clip origin is adjusted by the inserted height so
nothing moves under a reader.

Anchoring moves the scroll and, when Day 0 holds a live page, the
selection. It never mints: a summon onto an empty Day 0 lands on the
shipped empty state with its Return grant intact, which is exactly the
state ADR-0017 describes for a selected tab whose page expired.

"Autoscroll" is read as *one contiguous scroll*, not a surface that
scrolls itself. A self-scrolling surface would violate doc 05's motion
commitments and the idle-CPU budget.

Stated cost: within a day text reads downward, while across days downward
is older. The labelled perforation is the mark that says the direction
changed, and a long Day 0 wants a scroll after each summon.

## The rail and the roll

**The rail** is a fixed ~~56pt~~ 96pt column on the leading edge of the
content row, one row per visible unit, newest at the top. A row carries
the relative label, the shipped `GaugeBar`
(`shell/Sources/CompanionKit/TabStripView.swift`) fed from the unit's
soonest-dying page, or `EmptyRule` when it holds none, and the
same accessibility triple `SheetTab` uses: a spoken label, a spoken
remaining value, and the selected trait. ~~Abbreviated labels ("-3d")
ride the rail while the full phrase rides the tooltip and the
accessibility label, which is what doc 05's no-abbreviation-only rule
asks for.~~ Issue #131 widened the column and put the phrase itself on
the rail: the rows read Today, Yesterday, 2 days ago, and doc 05's rule
is answered where a reader is looking rather than one hover away. The
short form survives in the roll's day gutter, where the day shares a
line with a page's title and its countdown and the reason for it still
holds. Under the rows, a faint minimap of the roll, described below.

The rail is navigation and nothing else. It offers no rename, no close,
no rung, no hold and no drag-reorder. Days have an order the user does
not shuffle and a label the user does not type, and a rail that could
close a day would be exactly the misreading ADR-0017's eject trigger is
about. `TabFramesKey` and its midX reorder test are never touched, so the
two modes never contend over one preference key's semantics.

**What shipped, as of branch 5.** The labels and the 56pt width recorded
below are branch 5's; issue #131 superseded both, and "What #131 added to
the rail" further down carries the current values. The rail lives in
`shell/Sources/CompanionKit/TimeRailView.swift`: a `VStack(spacing: 2)`
of `TimeUnitTab` over `model.timeUnits.units`, 56pt wide, with the
strip's background and the strip's selected fill. Four decisions were kept out of the drawing and
are pure functions with tests of their own, in the idiom
`TabStripView.newPageHelp` set:

- `TimeUnitTab.target(for:)`, where a tap lands. It maps a
  unit to its first slot in strip order, and to `.today` only where a
  day answers to no slot at all, which is exactly what
  `PageModel.visibleTargets` does with the same units. A click on the
  second row and ⌘2 therefore cannot disagree about where the second day
  is, and a test asserts the two lists element for element.
- `TimeRailView.selectedBucket(projection:selection:)`, which
  row is lit. It follows the selected page's day rather than the row
  last clicked, so a selection the keyboard moved, or one that fell onto
  another day after an expiry, moves the mark too. A selection standing
  where the rail draws no row (an empty slot, or a blank old page the
  content bar is holding back) lights nothing at all, because what is
  on screen is then not on the rail. An empty Today answers to no slot,
  so it takes the mark only by elimination: on the pad where no drawn
  day holds a page, and today is where the next page would land.
- `TimeRailView.chord(forRowAt:keymap:)`, which chord a
  tooltip may name, asked of the keymap rather than spelled into the
  view, so a user who moved ⌘2 moves the tooltip with it and a user who
  unbound it gets a tooltip that says only what the row does. A tenth
  row has no chord: the shortcuts count to nine and the strip does not,
  so the row is reached by a click.
- `TimeRailView.hiddenPagesLine(count:)` and `hiddenPagesHelp(count:)`, the footer. The short form fits the 56pt column and
  the sentence behind it names the toggle, which is what doc 05's
  no-abbreviation-only rule asks for. It is absent entirely at zero: a
  line reading "0 blank" would be chrome measuring the absence of a
  problem.

`TimeUnitProjection.Unit` gained one field for the rail,
`spokenRemaining` (`shell/Sources/CompanionKit/TimeUnits.swift`),
taken from the same soonest-dying page as the gauge. A view reaching
back into the summaries for the spoken half could have picked a
different page from the one the bar is drawn from, and the row would
then have said one thing and shown another.

What the rail deliberately does not carry, restated now that it exists:
no rename, no close, no rung, no hold, no reorder, and no row at all for
a tab holding no page. The tab is standing underneath, named and empty,
and the strip shows it again the moment the mode goes off. Nothing on
the rail mints by being drawn; the one click that makes anything is an
empty Today's, which takes the shipped create path and says so in its
tooltip.

**What #131 added to the rail.** Two refinements, written here rather
than folded into the paragraphs above so the rail as branch 5 shipped it
and the rail as it stands can be read side by side.

The first is the words. `TimeUnit.railLabel(bucket:)` is
`spokenLabel(bucket:)` with its first letter raised, and nothing else:
one table of phrases, so the row, its tooltip and what VoiceOver reads
cannot drift apart, and a reader who hears "3 days ago" is looking at
those words rather than translating them from "-3d". Only the first
letter is raised, because `capitalized` renders "2 Days Ago", a title
for something that is not a name. The column went from 56pt to 96pt to
hold the longest phrase the rail can realistically be asked for, "10
days ago" from a page held past its rung, with tail truncation as the
net rather than the plan.

The second is the background, which was a flat `Color.panelBackground`
and is now a faint reading of the roll: a bar per day, as tall a share
of the column as that day is of the document, and a band over the part
the reader can see, which follows the clip as it scrolls.

It is a scaled impression of the roll in its own coordinate space, and
not a diagram of the rail. The whole document is mapped onto the whole
column, in proportion to content, while the rows above are packed from
the top and pushed apart by a spacer, so a bar and the row for the same
day do not line up and are not meant to: a day holding most of the roll
takes most of the column whatever height its row happens to have. What
the two do share is a count and an order, one shape per drawn day,
newest at the top of both. A bar is always ink somebody can see: a
column with no two points left for a day drops that day's bar rather
than keeping it at no height, which takes far more days than a card can
draw rows for and is why a row without a bar reads as a fault. Anyone
who wants the bars to sit beside their rows is asking for a different
feature, one where the rail's rows are laid out by content rather than
packed, and that is a layout change and not a drawing one.

Four things about it are load-bearing.

- **Geometry, never glyphs.** `RollGeometry` carries a day's top and
  height, the document's height and the clip's window, and nothing else
  crosses it. A minimap drawn from scaled text would be a second surface
  rendering page content: it would have to answer for how a concealed
  block draws on it, it would cost a second layout pass or a layer
  snapshot per quiet day, and it would invite an argument about whether
  two point glyphs are legible. Rectangles cannot leak a word, so there
  is no argument to have. No per-block and no per-line rendering either:
  the finest thing the rail draws is a day.
- **Faint is a requirement.** The nodes, their words and gauges are the
  rail's content, and a background that competed with them would turn a
  navigation column into a chart. `StreamNavigatorView.slivers(_:)` and
  `viewportBand(_:width:)` keep the roll geometry behind those nodes;
  their opacity values are what the dogfood window is meant to argue
  with.
- **One measurement, read off the frames.** The extents come from
  `DayStackView.relayout`, the pass that has just placed every region,
  so the navigator and the pages under the reader's eye cannot disagree
  about how much page each node holds: the proportions are the roll's
  own and not a second estimate of them. A day holding two pages is two
  extents and two nodes, mapped by `StreamNavigator.layout`.
- **Published on a hop, and off the model.** `relayout` runs inside
  `updateNSView`, so writing observed state there would be writing it
  during a render pass; the measurement goes to its own
  `RollGeometryModel` through a coalescing hop on the main actor, and
  the minimap is the only view observing it. A scroll therefore redraws
  a few rectangles rather than the header, the status stack and the
  page. The roll watches the clip's **bounds** as well as its frame for
  this, since scrolling moves no frame and nothing had needed to notice
  it before. The model answers to one roll at a time: a mount claims it,
  and a roll that no longer holds the claim is met with silence, because
  SwiftUI may build and lay out a replacement before dismantling what it
  replaces and the outgoing surface's parting reset would otherwise
  blank a minimap that had just been measured honestly.

The mapping into the rail's coordinates is the pure
`StreamNavigator.layout(nodes:geometry:height:width:)` function, in the
idiom `selectedBucket` and `chord(forRowAt:)` set. The edges it decides
are the ones a drawing cannot be squinted at for: an unmeasured roll
packs nodes in order without inventing proportions; missing extents are
interpolated without reversing anchors; line fragments that land on one
point collapse to one sliver; elastic overscroll clamps into the column;
and a roll that fits in the card gets no band at all, because a band
around everything marks nothing.

Everything the rail already did is untouched by both: the tap targets,
⌘1 to ⌘9, the selection mark, the gauges, the empty rule, the hidden
pages footer, the tooltips and the accessibility triple. The minimap
takes no clicks and is hidden from VoiceOver, which has the rows
themselves.

**The roll** is one `NSScrollView` over a flipped stack laid out top-down
by frame. Perforations are chrome: a hairline drawn between regions in
`EmptyRule`'s dash vocabulary, plus the unit's label in the leading
gutter. Nothing is ever inserted into a text storage to separate two
days, because anything inserted into a storage travels across the seam as
an insert op.

The single persistent editor survives intact, which is the invariant this
design is built around. The live `InkTextView` is a permanent child of
the stack; when the selected day changes, only its frame origin moves and
`removeFromSuperview` is never called on it, so nothing resigns first
responder and focus, marked text and per-page undo survive a day switch,
the exact class of bug issues #19, #22 and #23 closed. Every other
visible page is a quiet region: a non-editable, non-selectable text view
that refuses first responder, over its **own** `NSTextStorage` seeded
from `client.documentRuns(sheet:)`
(`shell/Sources/CompanionKit/CompanionClient.swift`). Private
storages keep the roll entirely out of the model's `storages`,
`undoManagers`, `shedLayoutManagers(from:keeping:)` and
`assertProjectionParity`: each storage in the app still has exactly one
layout manager because each has exactly one view.

ADR-0006's second eject trigger names "a future feature needs per-sheet
view instances". This is the nearest the tree has come to firing it, and
the claim made here is that it does not: there is still exactly one
*editor*, one `activeEditor`, one `performSealedPaste` and one
first-responder candidate in the card. The quiet regions are renderings,
not editors, and they are the thing a reviewer should press on hardest.

Concatenating the days into one storage is refused outright. `apply_ops`
offsets are UTF-16 units within one page's Loro document, parity is
checked one-to-one per page, a delete could span a page boundary, and two
adjacent pages in one storage would need a separator *character* to read
as separate. Merging documents would also destroy the per-page TTL
granularity ADR-0017 records as settled.

**No animation anywhere in the mode.** The open and summon anchors are
instant clip moves, the rail's jump is instant, and rows appearing and
disappearing do not animate. Doc 05 requires `prefers-reduced-motion` to
swap animation for stepped states and forbids parallax and bounce;
shipping no animation means there is nothing to reduce and no conditional
branch to get wrong.

## The toggle

`showsTimeUnits` is a `@Published` boolean on `PageModel` whose `didSet`
writes to the injected `UserDefaults` and is seeded in `init`, following the
`wrapsLines` pattern (`shell/Sources/CompanionKit/PageModel.swift`), and defaults to false. Its row goes in `GeneralSettingsView`
(`shell/Sources/CompanionKit/SettingsSections.swift`; it was
`ConnectionSettingsView` until Settings grew its toolbar tabs in
dogfood phase 4), not in
`BackdropSettingsView`'s Surface form, whose hard-coded
`.frame(height: 120)`
(`shell/Sources/OnetimePad/BackdropSettingsWindow.swift`) clips new
rows silently.

`HiddenUI` is the wrong tool and deliberately so: its flags are
build-time `static let` values chosen so that nothing at runtime can flip
them, and this is a mode a user chooses.

The toggle never calls `markDirty()`. That would take the
sudden-termination hold and arm a debounced ciphertext write, so a
presentation preference that moves no core state would buy a fresh sealed
generation on every flip. The test that pins this flips the toggle both
ways across an edit and asserts `client.tabs()`, `client.emptiness()`,
the selection and the save status are unchanged.

The keyboard gains no new chord. `CommandID` raw values are published
contract (a user's own `keymap.json` names them), and a binding placed
in `.tabStrip` would validate, log `contextNotConsulted` and do nothing,
because `KeymapContext.isConsulted` is true only for `.editor`
(`shell/Sources/CompanionKit/Keymap/CommandID.swift`). Instead
⌘1 to ⌘9 and ⌥⌘←/→ route through a mode-aware list of targets whose value
with the mode off equals the strip element for element, pinned by a
dedicated test, and ⌘N branches to `openToday()` while the mode is on
(`shell/Sources/CompanionKit/Keymap/KeymapRegistry.swift`).

The strip's verbs are not dropped, they move to the page. Each page's
day-header gutter inside the roll carries its title, its countdown and a
context menu with rename, hold, rung and close, reusing the shipped
`promptForRename`, `pause`, `cycleRung` and `close`. Putting them on the
page rather than on the rail keeps them unambiguous when a day holds more
than one page, and keeps the rail honest about being a projection you
cannot rename or reorder.

Several pages born on one day are grouped under one day header in strip
order, separated by a hairline rather than a tear, and not policed.
Enforcing one page per day would mean refusing a shipped gesture or
merging documents, and both are opinionated where the issue asked for
unopinionated. Grouping also renders correctly for a user who moves
between the two modes with existing history, which is every dogfooder on
day one.

## Change map, branch by branch

Six stacked branches, each targeting the one below it, bottom-up into
main. All six are in the tree as of 2026-08-25: the decision, the seam,
the projection with its flag, the editor factoring, the rail with its
Settings toggle, and the roll. The first four moved no pixel at all,
deliberately; branch 5 is the first that a user can see and turn on, and
branch 6 is the one the stack exists for. Nothing is outstanding except
the dogfood window ADR-0020 waits on.

1. **The spec and the decision** (this document and ADR-0020). Docs only.
   `docs/spec/design/04-interaction-model.md` is deliberately **not**
   amended: a prototype behind a default-off toggle has not earned an
   amendment to the standing interaction model, and the ADR carries its
   own acceptance gate and eject triggers instead.
2. **The seam says which day a page was born on.** `local_day`
   (`crates/core/src/sheet.rs`) hoisted out of `placeholder_title`,
   which is now one of its two callers; `Sheet::has_content()` extracted from `entomb` (`crates/core/src/store.rs`);
   `SheetStore::wall_ms()` (`crates/core/src/store.rs`) beside
   `now()`; two additive keys on `summary_json`
   (`crates/ffi/src/lib.rs`) with the header's field contract
   extended in the same commit
   (`crates/ffi/include/companion_ffi.h`), and the two fields
   decoded onto `TabSummary`. No new FFI symbol and nothing a user can
   see.
3. **The projection.** A pure `TimeUnitProjection` over the tab
   summaries, the `showsTimeUnits` flag, mode-aware selection targets and
   `openToday()`. No new pixel anywhere, deliberately: a toggle that
   shows nothing must not reach main, so no Settings row lands until
   branch 5.
4. **The editor factoring.** Separate building the one persistent editor
   from wrapping it in a scroll view, and the page-swap ceremony from
   `updateNSView`. **Landed**, as
   `InkEditorView.makeInkTextView(model:sheetID:coordinator:)`
   (`shell/Sources/CompanionKit/InkEditorView.swift`) and
   `Coordinator.moveEditor(_:to:storage:restoringScrollIn:)`,
   with `makeNSView`, `updateNSView` and
   `scrollStack(for:)` as they were. The review evidence for
   that branch is the sentence "behaviour does not change on this
   branch", backed by the existing suite unedited.
5. **The rail.** `TimeRailView`, the Settings toggle, the mode-aware
   selection wired up, and the hidden-blank-pages footer. **Landed**, in
   `shell/Sources/CompanionKit/TimeRailView.swift`, with the card's
   content row branching as a whole expression
   (`shell/Sources/OnetimePad/Views/BackdropRootView.swift`) and the
   off-path view tree written out identically to today's rather than
   wrapped, so "pixel-identical when the toggle is off" is structural and
   not a hope. The strip row is simply absent while the mode is
   on. The toggle is one row in `GeneralSettingsView`
   (`shell/Sources/CompanionKit/SettingsSections.swift`) whose
   caption says all three things: prototype, moves no content, and which
   verbs it costs while it is on.
6. **The perforated roll.** The contiguous scroll, the day headers and
   their verbs, the quiet regions, the anchor rule, and the hardware
   procedure that answers the issue's three questions on a real machine.
   This is where the engineering goes and the branch that can be reverted
   without losing the mode. **Landed**, in
   `shell/Sources/CompanionKit/DayScrollView.swift`: `DayScrollView` over
   `DayStackView`, with `DayHeaderView`, `QuietPageView` and
   `EmptyTodayView`. Type names rather than line numbers for that file,
   and deliberately: it is the file this stack rewrote most, its numbers
   went stale twice inside the branch that wrote them, and a name is
   `grep`-able where a number is only ever a claim about a moment.
   `PageContentView` branches at
   `shell/Sources/CompanionKit/PageSurface.swift`; the renderings, the
   invalidation every mutation site now calls and the liveness prune are
   `PageModel.quietRendering(for:)`, `invalidateQuietRendering(for:)` and
   the filter inside `refresh()`; and the summon's re-anchor is
   `PageModel.anchorOnToday()`, reached from `BackdropModel.raise(_:)`
   only for a `BackdropRaise.summon` (see the anchor section below). The
   hardware procedure is
   [`docs/qa/verification-procedures/vertical-time-tabs.md`](../../../qa/verification-procedures/vertical-time-tabs.md).

The limit branch 5 shipped with is closed: rename, hold, rung and close
are on each page's own gutter inside the roll, addressed to that page's
slot, and the Settings caption says where they are rather than
apologising for their absence.

7. **The rail's stream navigator** (issue #131), after the six.
   `TimeUnit.railLabel(bucket:)` and the wider column
   (`TimeRailView.width`); `RollGeometry` and `RollGeometryModel` in
   `shell/Sources/CompanionKit/RollGeometry.swift`; `StreamNavigator` in
   `shell/Sources/CompanionKit/StreamNavigator.swift`;
   `DayStackView.measuredGeometry` and the clip's bounds observation;
   and `StreamNavigatorView` under the rail's heading. Type names rather
   than line numbers, for the reason branch 6 gives. Nothing in the core,
   at the seam, in the projection's laws or in horizontal mode moved:
   `TabStripView.swift` takes no diff on this one either.

## Test plan

The model is Rust and pure Swift on purpose, because Swift builds and
tests only on macOS CI while the crates test on Linux. The more of the
decision that is Rust, the more of it is validated before a PR exists.

- **Core.** A page born before local midnight is a different day from one
  born after; the day index follows the offset the clock reports,
  including a negative one; whitespace alone is not content; a chip with
  no ink is content; the placeholder stamp did not move
  (`the_placeholder_stamp_did_not_move`, `crates/core/src/sheet.rs`,
  re-asserting every case the label's own tests pin); the
  content
  predicate is the one the ledger already used, over a matrix of pages;
  and an expiring page still leaves its tab standing in place.
- **Seam.** The summary says which day the page was born on, read
  against a reading of today a day later and six days later. Not by
  ageing the page: the ageing seam is a snapshot restored at a later
  wall stamp, and a restore carries every creation stamp through
  untouched (`crates/core/src/persist.rs` asserts exactly
  that), so the far side of a local midnight is reached by moving today
  and never by moving the page. An empty slot reports no day and no
  content; the fifteen existing summary keys are unchanged; and the
  standing boundary-law test (seal a secret through every route, assert
  the bytes appear in no JSON output) still passes untouched, because an
  integer and a bool carry no ink.
- **Projection (pure Swift, no AppKit).** Today is a unit with or without
  a page; a day whose only page is whitespace is absent; a day whose page
  holds a chip and no ink is present; an expired middle day leaves a
  numbering gap and no row; the selected page's day is present even when
  blank; ordering is newest first; two pages born the same day land in one
  unit in strip order; the hidden count counts the live pages the
  projection drops; and the label tables for 0, -1, -7 and a positive
  bucket, since a skewed clock must not invent a future day. A page
  stamped ahead of now is *filed* under today as well as labelled it, so
  that "Today" names exactly one row and the lookups that ask for today
  by its bucket cannot find an empty one standing above a peopled one.
- **The load-bearing identity.** With the mode off, the mode-aware target
  list equals the strip element for element. This is what makes
  "horizontal mode is unchanged" an assertion rather than a promise.
- **The toggle.** Flipping it both ways writes only the injected defaults
  and leaves the tabs, the emptiness predicates, the selection and the
  save status byte-identical; nothing is marked dirty; the termination
  latch never moves.
- **The rail, without a window.** The rows are the projection's days in
  the projection's order; a row's tap target is its day's first slot and
  `.today` only where a day answers to no slot; the row targets equal
  `visibleTargets` element for element on a live pad in the mode; Today
  has a row with and without a page and its tooltip says which; a
  tooltip names the chord the keymap bound and degrades to the plain
  description when nothing is; the footer's line appears exactly when
  the hidden count is non-zero; and each row reads its distance and its
  clock out loud.
- **The words, and the minimap's map** (issue #131, pure Swift). The
  rail's label table at the edges (today, yesterday, the counted form,
  and a bucket from a clock that went backwards), and the law that it is
  the spoken phrase and not a second table: lower-cased, the two are
  equal for every bucket asked. Then the mapping, which is where the
  minimap's whole argument is: an unmeasured roll and a rail with no
  height draw nothing; one day that is the whole roll fills the column;
  several days keep their order, their share and their place inside it;
  a day a fraction of a point tall draws a hairline; the last day stops
  at the foot of the rail; a column with no room left runs out in the
  order the days come in and keeps no bar it cannot draw; the band is absent when the whole roll is on
  screen, follows the clip when it is not, and clamps into the column at
  both ends of an elastic overscroll; and two pages of one day fold into
  one bar.
- **The measurement, in a real window** (the `DayScrollTests` idiom).
  One extent per day in document order, each running from the top of its
  header to the bottom of its page, read against the frames the pass
  actually set; a day holding more writing measuring taller than a day
  holding a line; two pages of one day measuring as one extent; the
  viewport following the clip down a roll that outgrows the card; and a
  teardown arriving after the replacement roll has already measured
  itself leaving that measurement standing.
- **The hop, and who is allowed to take it**
  (`RollGeometryModelTests`, no window at either end). A mount clears
  what the last roll left behind; a replaced roll can neither reset nor
  publish; the last roll going away leaves the rail with nothing to
  draw; a measurement the rail is already drawing is not published at
  all; and a burst of them inside one turn of the loop lands as one
  redraw, on the last measurement rather than the first.
- **The chords, pressed.** ⌘1 in the mode lands on today and takes the
  create path when today is empty, and a second press is a jump; ⌘2 and
  ⌥⌘→ count days rather than slots, asserted as the contrast between the
  two modes on a pad written in one sitting, because no Swift test can
  move a page across a local midnight; and with the mode off all three
  land on the strip exactly where they always did.
- **Geometry, in a real window and TextKit stack** (the `PageScrollTests`
  idiom, never a mock): the stack's height is the sum of its parts; Day 0
  sits at document offset 0 and re-anchoring leaves the clip at the
  origin; the roll outgrows one cardful with the editor mounted mid-roll;
  a row inserted above the viewport moves nothing under the reader; two
  identical passes rebuild no subviews; every storage carries exactly one
  layout manager; switching days moves the editor's frame and leaves the
  same instance first responder; a quiet region refuses first responder;
  and a click in a quiet region promotes its page and lands the caret
  where it was clicked.
- **The no-ops.** Mounting the roll emits no ops to any page (identical
  document runs before and after, which is what makes "perforations are
  chrome" an assertion), and undo after the editor moves cannot cross a
  page boundary.
- **Hardware** (branch 6, `docs/qa/verification-procedures/`): local
  midnight arriving while the card rests, with no timer firing; a middle
  day expiring; summon after scrolling into history; typing at the bottom
  of a long Day 0; toggling both ways with content on screen and a page
  held; VoiceOver down the rail; reduced motion on. Stage content across
  at least three days at the 7d rung before judging the mode: it shows
  only the days the rungs let live.

## What the prototype does not do

- **No change to what a Tab is or how long it lives.** No calendar-driven
  creation, closing, hiding, re-dating, re-ordering or re-labelling.
  ADR-0016 and ADR-0017 are not reopened.
- **No durable day.** No persisted day index, no day name, no day that
  survives its pages, no new snapshot field, no new magic, not even a
  trailing appended one. The mode's only durable trace is a `UserDefaults`
  boolean.
- **No calendar arm on `next_event`**, no new reason for
  `companion_expire_due` to fire, no midnight one-shot, and no second
  shell timer.
- **No runtime setting inside the core.** `SheetStore` learns nothing
  about modes, which is what keeps the toggle from moving core state in
  either direction.
- **No change to the ladder, the 7d ceiling or any default rung**,
  including a mode-specific default rung, which would be the mode
  reaching into core state. The cap's removal (issue #158) is not the
  mode reaching in: it took the cap out of the core for both modes.
- **No change to horizontal mode's behaviour or pixels.** `GaugeBar` is
  public and `EmptyRule` and `HoldChip` are module-internal, so the rail
  reuses them where they stand rather than moving them. ~~`TabStripView.swift`
  takes no diff at all.~~ It takes exactly one, on branch 6: the rename
  prompt moved out of `SheetTab`'s private method into a shared
  `TabRenamePrompt`, because the roll offers the same verb and the alert
  states a rule about what a tab name *is*. Same words, same buttons,
  same empty-field meaning, two callers.
- **No auto-minting of Day 0**, at launch, on restore, on the toggle, in
  `refresh()`, from the rail, or when the selected page expires under the
  cursor.
- **No policing of one page per day**, no merging of days into one
  document, and no visible gap, ghost row or marker for a day whose page
  expired.
- **No drag-reorder, no rename on the rail**, and no rail affordance for a
  tab holding no page.
- **No text anywhere in the minimap**, at any size the rail can take, and
  no per-block or per-line rendering on it either: the finest thing it
  draws is a day, and the day is a rectangle. It is also not a control.
  It takes no clicks and offers no drag: the reader jumps by the row
  drawn over it, and scrolls by the roll.
- **No text selection, copy-out or chip interaction inside a quiet
  region.** Click it and it becomes the editor, which already has all
  four.
- **Preview rendering is scoped.** Under the default **All pages** scope, a
  quiet day carries the mounted page's Markdown structure, fence wash and
  syntax color without its block labels. **Focused page only** keeps quiet
  days in base ink, and **Never** makes mounted and quiet pages plain. Chips
  retain their non-secret faces in every scope (ADR-0030).
- **No unwrapped lines in the mode.** Wrap is forced on and ⌥Z changes
  nothing while the mode is on: the dispatch refuses it and says so
  (`PageModel.wrapIsFixedNotice`) rather than leaving a dead key. The
  stored `wrapsLines` preference is untouched and resumes when the mode
  is off, which is why the refusal is the whole of the behaviour. A
  preference written blind under a surface that ignores it would hand
  horizontal mode back unwrapped.
- **No per-page scroll memory in the mode.** The roll owns one offset.
- **No animation, and therefore no `prefers-reduced-motion` branch.**
- **No new `CommandID`, no keymap row, no `BundledKeymapTests` churn**;
  `KeymapContext.tabStrip.isConsulted` stays false.
- **No new `test-util` seam**, and therefore no addition to the `nm -gU`
  denylist in `scripts/package-app.sh`.
- **No unit but the day.** The bucketing is parameterised where
  retrofitting would be expensive and the core field is day-relative, but
  only the day is tested. A week needs a week-start policy nobody has
  designed.
- **No search, jump-to-date, day pinning, day colouring, per-day counts,
  or any day awareness in the ledger.** Doc 01's anti-goals decline
  organization and retention features by default.
- **No form factor but the backdrop.** The panel is archived (ADR-0014)
  and gets no rail.

## What the prototype answered

Written after the six branches landed, in the background-surface house
style: appended rather than edited into the three answers above, so the
argument as it was made and the thing as it was built can be read side
by side. Where building it moved an answer, the superseded sentence is
struck through here rather than deleted up there.

### The middle day: it closes up, and it costs nothing to keep it that way

Built exactly as argued, and cheaper than expected. A day is a bucket
that a live page falls into; when the page expires the bucket is
computed and nothing is in it, so the row is simply not there on the
next read. There is no removal path, no tombstone, and no code that
knows a day ever existed, which is the strongest form of the argument
the answer above makes from principle. What the roll adds is the
mechanical half: the regions are laid out top-down by frame in one pass
over the projection, so a bucket that stops appearing closes the layout
up with no animation and nothing to reconcile.

One thing had to be decided that the answer did not name: **a day
holding two pages needed a second kind of mark.** A tear between the
two would have said "a day passed" and lied. It renders as a plain
hairline instead (`DayHeaderView.Mark.hairline`, chosen by a pure
function with a test), so the vocabulary is now three marks: nothing
above the roll's first header, a dashed tear at a day boundary, and a
hairline between two pages of one day.

### "Content": non-whitespace ink or one chip, and the shell never guesses

Built as argued and unchanged by building it. The predicate is
`Sheet::has_content()`, the bar `entomb` already applied, with one
definition and two callers; it crosses the seam as `page_has_content`,
a boolean, so no document is ever read out to decide whether a day
exists. The two exemptions (today is always a place, and the selected
page's day is always drawn) turned out to be load-bearing in a way the
answer only implied: because the selected page's day is always present,
the roll can rely on the selected page always having a region to stand
in, and the editor never has to be mounted over a day the projection is
not drawing.

The one number nobody can produce from here is whether the bar is set
right. That is what the rail's hidden-pages count is for, and the QA
procedure asks for it to be written down.

### The anchor: Day 0 is the top, and a summon goes back to it

Built as argued, and one clause of it is now more specific.
~~"On launch, on entering the mode, and on every summon, the clip goes
to the origin."~~ On mount and on every summon, and *not* on a ⌘Tab
return: re-keying the card is not a summon, and moving the roll under
someone who came back to the sentence they were writing would be the
opposite of what the anchor is for.

Which meant `BackdropModel.raise` could not be the one caller after all,
because it is also what `applicationDidBecomeActive` calls: a ⌘Tab
return is a raise over an already-raised card, and hanging the anchor on
the raise gave that return the summon's behaviour. So the raise takes
its reason, `BackdropRaise.summon` or `.activation`, and
`BackdropModel.anchorsOnToday(raise:)` is the whole of the boundary, in
one pure function with a test rather than in four call sites. The
gestures that name **this surface** anchor: ⌃⌥Space, the menu-bar item,
and a click on the resting card. The gestures that name **the app** do
not: ⌘Tab, the app switcher, and the Dock icon. The pasteboard offer is
deliberately not split this way: an offer is about what is on the board
now, and coming forward is when it is worth making however the user got
there.

The Dock icon is the judgement call, and it is filed as an activation on
this ground: clicked while the app is inactive it arrives as
`applicationDidBecomeActive` and while it is active as
`applicationShouldHandleReopen`, so filing the two differently would
give one gesture two meanings decided by a state the user cannot see.

Since ADR-0033 the gestures that name the app select the editor window
rather than re-keying the card: `applicationDidBecomeActive` and
`applicationShouldHandleReopen` go through `ActivationRouter`, which
carries the same `BackdropRaise` reason to whichever window it opens.
`anchorsOnToday(raise:)` is asked on that route too and only a summon
anchors. One case changed with the ambient panel preference: with the
panel off there is no surface to name, and ⌃⌥Space and the menu-bar
item select the editor window as an activation, so they no longer
anchor.

Two mechanisms the answer named in passing turned out to matter enough
to have tests of their own. The first is that the anchor moves the
selection as well as the scroll when today holds a page, and that it
cannot mint: it selects an occupied slot or does nothing, so a summon
onto an empty Day 0 lands on the empty state with its Return grant
intact. The second is the prepend rule
(`DayStackView.offsetAfterPrepending`), which has an edge the answer did
not: a reader **at the origin** is deliberately not moved when a new day
arrives above them, because the origin is where the new day now is, and
holding them still there would hide the very thing "Day 0 is always
displayed" promises. A reader scrolled into history is moved by exactly
the height that arrived, so nothing shifts under a sentence being read.

### What building it cost that the argument did not price

- **A rendering cache.** Quiet days render from
  `PageModel.quietRendering(for:)`, built once per page and pruned on
  the same live-page set as the storages. It needs one invalidation the
  design did not name: the entry is dropped when the editor moves onto
  that page, or a day the user has just written on would come back
  reading as it did before they arrived.
- **A parked editor.** When no live page is visible at all the editor
  cannot be re-parented (it is a permanent child) and must not keep
  showing the page that expired. It is handed a fresh empty storage,
  given no height, and the model's weak handle is dropped, the same
  thing a dismantle does, without the dismantle.
- **One diff to `TabStripView.swift`**, for the rename prompt, which the
  "no diff at all" claim above now records as spent.
- **A flip that costs undo.** The card's two content rows are distinct
  structural identities, so flipping the mode remounts the editor and
  spends every page's undo history and the caret within the page.
  Nothing is lost from the document or from disk. It is what a
  deliberate flip in Settings costs and what no keystroke pays.

## Open questions

1. **Does reinterpreting ⌘1 to ⌘9 and ⌘N confuse the hands?** In the mode
   the numbers address days rather than slots, and ⌘N goes to today
   before it makes another page. *Leaning:* acceptable, because the
   modes are exclusive, the mode is off by default, and no user keymap
   changes meaning. If dogfood finds people pressing ⌘3 expecting their
   third tab, the answer is probably to stop mapping numbers at all in
   this mode rather than to add a second set of chords.
2. **Does the card want a wider floor while the mode is on?** The rail
   eats ~~56pt~~ 96pt of a 360pt minimum since #131 put the words on it,
   and `BackdropGeometry.minWidth` is deliberately still not moved, so
   its clamp and its test stay as they are. *Leaning:* leave it, and
   watch for the countdown header wrapping at the floor. A
   mode-conditional minimum is a second geometry story, and this one is
   already tested. The question is sharper than it was, though: a
   quarter of the narrowest card is now rail, and if the floor reads as
   cramped the answer is more likely to be a narrower rail than a wider
   minimum.
3. **Is a day the right unit, and is anything else worth building?** The
   issue says configurable, starting with the day. *Leaning:* a day, and
   nothing else until someone asks for a week and can say what a week
   starts on. A week needs a week-start policy (Sunday or Monday, locale
   or fixed) and probably a second core field.
4. **Is "an expired day and a blank day look the same" a problem?**
   *Leaning:* no. It is the issue's own example, and the alternative is a
   tombstone. But it is the first thing a dogfooder is likely to report as
   a bug, which is why the labels are relative and never renumbered.
5. **Is the ledger's content bar the bar people mean?** A day appears
   exactly when its page would leave a mark in the ledger. *Leaning:* yes,
   because it is the only definition in the tree with a test behind it.
   The rail's hidden-blank-pages count is the instrument: routinely
   non-zero means the predicate is wrong.
6. **Do people flip to horizontal to reach a verb the mode does not
   carry?** Rename, hold, rung and close live on the page's day-header
   gutter, not on the rail. *Leaning:* the gutter is enough. If the flip
   is what people actually do, either the rail carries the verbs after all
   or the two modes are less exclusive than this design assumes.
7. **Is a label up to 30 s stale at local midnight acceptable?** It is the
   price of adding no timer. *Leaning:* yes, and it is nearly invisible in
   practice, since a card that anyone is looking at is either raised (1 Hz)
   or about to be summoned (which re-reads). A second timer against a
   ~0% idle-CPU budget is a poor trade for it.
8. **Does the mode read as broken on a pad whose rungs make history
   invisible?** The backdrop opens tabs at the 7d rung
   (`shell/Sources/CompanionKit/FormFactor.swift`), so Day -1 through
   Day -6 are reachable out of the box, but a pad re-rung to 8h shows only
   Day 0. *Leaning:* say it rather than paper over it, in the spec and in
   the QA procedure. A mode-specific default rung is refused: that is the
   mode reaching into core state.
9. **Resolved by ADR-0030: does a flat quiet day read as a rendering bug?**
   Yes under the default scope. **All pages** keeps visible pages styled as
   the editor moves; **Focused page only** retains the flat quiet roll for
   readers who prefer it, and **Never** is the plain-ink override.
10. **If the mode wins, do two modes survive?** A permanent toggle is two
    interaction models to maintain, test and document, which doc 03 §4
    would not thank us for. *Leaning:* the toggle is the prototype's
    instrument rather than a feature. If the vertical mode wins outright,
    the follow-up is an amendment to doc 04 and one model, not a setting
    kept forever out of politeness.
11. **How faint should the navigator's roll marks be, and does the band
    read as the viewport?** (issue #131)
    `StreamNavigatorView.slivers(_:)` draws out-of-view lines at 0.15 of
    the secondary colour and `viewportBand(_:width:)` draws its wash at
    0.08 of the primary colour, values not yet measured against a real
    card. *Leaning:* they are a starting point and the dogfood window is
    the instrument. Two failure modes to watch for, in opposite
    directions: a background loud enough to compete with the nodes and
    gauges, and one so faint that a scrolled reader gets no sense of
    place from it at all, in which case the honest answer is to drop the
    band rather than to darken it.
12. **Should the roll's day gutter say the day in words too?** (issue
    #131) The rail says "2 days ago" and the perforation beside it says
    "-2d", which is two vocabularies for one fact on one card.
    *Leaning:* leave it until someone reports the mismatch. The gutter's
    reason for the short form did not dissolve the way the rail's did:
    the day shares that line with the page's title and its countdown,
    and the header already speaks the phrase to VoiceOver, so nothing
    there is abbreviation-only either.

## Effort estimate

Roughly a week of focused work across the six branches, unevenly
distributed. Branches 2 and 3 are about a day together and carry most of
the model, all of it testable on Linux or without AppKit. Branch 4 is
half a day of factoring with no behaviour change. Branch 5 is a day and
produces something judgeable. Branch 6 is the rest: hand-laid AppKit
geometry, a live editor riding inside a stack, and the hardware pass. If
the geometry misbehaves, the documented fallback is to give the editor
its own inner scroller sized to content, with elasticity off so it cannot
swallow the wheel: same view, same responder, same coordinator, one
extra clip.

## References

- Issue #79, and [ADR-0020](../../../adr/0020-a-day-is-a-projection-of-live-pages.md),
  the decision this spec argues for.
- [ADR-0017](../../../adr/0017-durable-tabs-expiring-pages.md) for the
  tab/page split, the minting rule, and the cap's removal in its history.
- [ADR-0016](../../../adr/0016-content-persists-across-restart.md) for
  the TTL as the only lifetime mechanism the user did not ask for.
- [ADR-0006](../../../adr/0006-persistent-editor-storage-swap.md) for the
  one-editor invariant the roll is built around.
- [ADR-0009](../../../adr/0009-chip-deletion-deliberate-final.md) for why
  a dead day leaves no marker.
