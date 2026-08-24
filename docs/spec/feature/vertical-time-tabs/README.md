# docs/spec/feature/vertical-time-tabs/README.md
---

# Feature: vertical time tabs — a page per unit of time

Status: **draft**, for review · 2026-08-24
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

## The shape #79 asks for

Turn the strip on its side and let each tab be a unit of time rather
than a slot. Today at the top, yesterday under it, the days before that
below, each labelled relative to now — Today, -1d, -3d — so the labels
stay true without anyone rewriting them. One page per unit. The unit is
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

## The model: a day is a query, not an object

A unit of time is not a thing the app creates. It is a bucket over the
page's own birth stamp, computed on every read and stored nowhere.

`Sheet::created_wall_ms` is the page's birthday in Unix milliseconds
(`crates/core/src/sheet.rs`, the field split of ADR-0017). Fold it
through the store's own UTC offset — the same offset the tab's
`MMDD-HHmm` placeholder already renders from
(`crates/core/src/sheet.rs:712-721`, and the bucket is the
`local_seconds.div_euclid(86_400)` line at `:715`) — and a page has a
local day index. Subtract today's index from the page's and the answer
is a small relative integer: 0 for a page born today, -1 for one born
yesterday. That integer, and one boolean saying whether the page holds
anything, are the only two facts the seam gains
(`crates/ffi/src/lib.rs:2385`, `summary_json`).

Everything follows from that arithmetic and nothing else exists:

- **Nothing durable.** No `Day` type, no day index in the snapshot, no
  day name, no day that survives its pages. `OTSSNAP4` gains no byte and
  the magic does not move; the framing rule that makes an appended field
  cheap (`crates/core/src/persist.rs:62-74`) is not spent, because there
  is nothing to append.
- **The page's stamp, not the tab's.** `Tab::created_wall_ms` is the
  slot's birthday, and `open_page` mints today's page into slots that are
  days old. A tab stamp would label a page typed this morning "Day -5".
  The page stamp is honest, and it dies with the page, which is the
  issue's own rule restated: no page, no unit.
- **The core answers, not the shell.** A shell-side `Foundation.TimeZone`
  would disagree with the core's offset at a DST change, so a page could
  read "0824" on its tab and "-1d" on the rail. Hoisting the one line of
  arithmetic into a shared `local_day` and calling it from both places
  makes agreement structural. It also puts the whole model under
  `cargo test` on Linux, where the risk is meant to be retired, rather
  than behind a macOS-only Swift suite.
- **Relative, so midnight needs nothing.** Because the offset is
  recomputed on every `companion_tabs_json`, the cosmetic redraw the app
  already runs re-reads it and the labels roll over on their own
  (`shell/Sources/CompanionKit/PageModel.swift:2338`, at 1 Hz raised and
  every 30 s at rest, `shell/Sources/OnetimePad/BackdropStance.swift:182-187`).
  `next_event` gains no calendar arm, `companion_expire_due` gains no new
  reason to fire, and the shell adds no second timer. The honest cost is
  a label up to 30 s stale at local midnight while the card rests, and it
  is written down rather than engineered away.
- **The offset is read now, not stored.** A stamp within an hour of local
  midnight can bucket differently after a DST change or a flight. That is
  the property `placeholder_title` already has and its tests already pin
  (`crates/core/src/sheet.rs:1170-1185`); the day inherits it rather than
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
destroy content the user did not ask to destroy (ADR-0016:86).
Underneath the rail the tab is still standing, still named, still empty,
exactly as `expire_due` leaves it, and it is visible again the moment the
toggle goes off.

The reverse holds too, and it is what makes the toggle safe in both
directions without any content-loss engineering: the projection is a
read. It calls no core mutator, and the mode flag lives in `UserDefaults`
beside `wrapsLines` rather than in the sealed file. Flipping it moves no
core state, so there is nothing to lose and nothing to migrate.

## Why the cap does not move

`DEFAULT_SHEET_CAP` is nine and stays nine
(`crates/core/src/store.rs:31`). Refuse-don't-evict stays too: doc 04 is
explicit that silent eviction of deliberately placed content would break
trust, and eviction is by the TTL the user chose.

The arithmetic that says nine is enough. A page's countdown runs at most
seven days — the ladder's ceiling, with no forever rung
(`crates/core/src/ttl.rs:26-33`, `:45-46`). A seven-day span, wherever
inside a day it begins, touches at most eight distinct local days: the
day it starts on, six whole days, and the day it ends on. So the pages
alive at any one moment were born on at most eight local days, and eight
rows sit under nine slots with one to spare. In ordinary use the mode
never asks the cap for a tenth tab.

One case escapes that arithmetic, and it is better stated than hidden. A
held page outlives its rung: every further pause press tops the hold up
to twenty-four hours from now, and the store says so in as many words —
repeated pauses are how a page outlives its rung
(`crates/core/src/store.rs:1191-1195`). A page held across a week can be
born nine or ten days back and still be alive, and the rail will show its
day. This costs nothing structurally. The rail's length is bounded by the
number of live pages, which the cap already bounds at nine, plus the
Today place when today holds none. The mode cannot manufacture a slot, so
it cannot manufacture a refusal.

What the mode can do is make an existing refusal harder to read. Nine
slots full of blank old pages are hidden by the content predicate, so a
user could be refused a new page with no visible cause. The answer is
honesty rather than a new mechanism: the rail's footer shows a dimmed
count of the live pages the projection is not showing, its tooltip names
the Settings toggle as the way to reach them, and the refusal message in
this mode names the toggle too. Nothing is auto-discarded — auto-reaping
blank pages to make room is precisely the second lifetime mechanism the
ADRs forbid. The count doubles as an instrument: if it is routinely
non-zero in dogfood, the content predicate is wrong.

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
(`shell/Sources/CompanionKit/PageSurface.swift:281`, `EmptyStateKeyGrant`).

Because every mint stamps `wall_ms()` — which is now — every page the
user creates lands in Day 0 by construction. The gesture-only rule and
the one-page-per-day shape turn out to want the same thing.

⌘N in this mode goes to today's page when one exists and creates it when
none does. That is `openToday()`, and it is deliberately not a new mint
policy: it either selects an occupied tab, which cannot mint, or it goes
through the shipped create path unchanged. No mint-target heuristic, no
reuse of an arbitrary named empty tab — flipping back to horizontal must
never reveal that a tab the user named now holds today's page.

## The three answers

### TTL expiry of a middle day: the scroll closes up

It closes up, and the gap lives in the labels rather than in the layout.
When Day -2's page expires the unit is simply absent: the rail reads
Today, -1d, -3d, and one perforation joins -1d to -3d carrying the -3d
label. Nothing marks the place where -2d was.

This is not tidiness; it is the only choice the model can make honestly.
A day exists because a live page with content is keyed to it. When that
page expires there is nothing left to key on, and holding the gap open
would need durable state remembering that a day once had content. That
is a tombstone for dead content, which ADR-0009 forbids for sealed bytes
and doc 03 §1 calls the safety net that quietly becomes an archive. It
would also have to live somewhere, and no content-derived or app-derived
string may reach the durable Tab — ADR-0017's load-bearing refusal.
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

Non-whitespace ink, or at least one sealed chip — answered core-side,
never inferred from the shell.

It is not a new predicate. It is the one `SheetStore::entomb` already
applies to decide whether a dying page did anything worth recording
(`crates/core/src/store.rs:1364-1371`). The work extracts it as
`Sheet::has_content()`, rewires `entomb` to call it, and exposes it as a
single boolean, `page_has_content`, on the tab summary, with a test
asserting the two agree over a matrix of pages. The property that buys is
worth stating: **a day gets a row exactly when its page would leave a
mark in the ledger.**

"Any bytes" is rejected on two grounds. A page holding one stray newline
would manufacture a day and hold a rail row for as long as the page
lives. And there is no existing core definition of it, so it would be a
second emptiness predicate in a codebase that already carries two
security-load-bearing ones — `holds_no_page` fires key rotation and
`has_no_tabs` is the only condition that unlinks the sealed file, and the
header warns in as many words against recomputing either shell-side
(`crates/ffi/include/companion_ffi.h:237-253`).

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
the origin — instantly, unanimated, with no per-session scroll memory to
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

**The rail** is a fixed 56pt column on the leading edge of the content
row, one row per visible unit, newest at the top. A row carries the
relative label, the shipped `GaugeBar`
(`shell/Sources/CompanionKit/TabStripView.swift:435`) fed from the unit's
soonest-dying page, or `EmptyRule` (`:416`) when it holds none, and the
same accessibility triple `SheetTab` uses: a spoken label, a spoken
remaining value, and the selected trait. Abbreviated labels ("-3d") ride
the rail while the full phrase rides the tooltip and the accessibility
label, which is what doc 05's no-abbreviation-only rule asks for.

The rail is navigation and nothing else. It offers no rename, no close,
no rung, no hold and no drag-reorder. Days have an order the user does
not shuffle and a label the user does not type, and a rail that could
close a day would be exactly the misreading ADR-0017's eject trigger is
about. `TabFramesKey` and its midX reorder test are never touched, so the
two modes never contend over one preference key's semantics.

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
responder and focus, marked text and per-page undo survive a day switch —
the exact class of bug issues #19, #22 and #23 closed. Every other
visible page is a quiet region: a non-editable, non-selectable text view
that refuses first responder, over its **own** `NSTextStorage` seeded
from `client.documentRuns(sheet:)`
(`shell/Sources/CompanionKit/CompanionClient.swift:672`). Private
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
writes to the injected `UserDefaults`, seeded in `init` — the `wrapsLines`
pattern, `shell/Sources/CompanionKit/PageModel.swift:333-336` and `:634`
— default false. Its row goes in `ConnectionSettingsView`
(`shell/Sources/CompanionKit/SettingsSections.swift:114-119`), not in
`BackdropSettingsView`'s Surface form, whose hard-coded
`.frame(height: 120)`
(`shell/Sources/OnetimePad/BackdropSettingsWindow.swift:81`) clips new
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
contract — a user's own `keymap.json` names them — and a binding placed
in `.tabStrip` would validate, log `contextNotConsulted` and do nothing,
because `KeymapContext.isConsulted` is true only for `.editor`
(`shell/Sources/CompanionKit/Keymap/CommandID.swift:105-107`). Instead
⌘1–⌘9 and ⌥⌘←/→ route through a mode-aware list of targets whose value
with the mode off equals the strip element for element, pinned by a
dedicated test, and ⌘N branches to `openToday()` while the mode is on
(`shell/Sources/CompanionKit/Keymap/KeymapRegistry.swift:27-28`).

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
main.

1. **The spec and the decision** (this document and ADR-0020). Docs only.
   `docs/spec/design/04-interaction-model.md` is deliberately **not**
   amended: a prototype behind a default-off toggle has not earned an
   amendment to the standing interaction model, and the ADR carries its
   own acceptance gate and eject triggers instead.
2. **The seam says which day a page was born on.** `local_day` hoisted
   out of `placeholder_title` (`crates/core/src/sheet.rs:712-721`),
   `Sheet::has_content()` extracted from `entomb`
   (`crates/core/src/store.rs:1364-1371`), `SheetStore::wall_ms()` beside
   `now()` (`:450`), two additive keys on `summary_json`
   (`crates/ffi/src/lib.rs:2385`) with the header's field contract
   extended in the same commit
   (`crates/ffi/include/companion_ffi.h:213-235`), and the two fields
   decoded onto `TabSummary`. No new FFI symbol and nothing a user can
   see.
3. **The projection.** A pure `TimeUnitProjection` over the tab
   summaries, the `showsTimeUnits` flag, mode-aware selection targets and
   `openToday()`. No new pixel anywhere, deliberately: a toggle that
   shows nothing must not reach main, so no Settings row lands until
   branch 5.
4. **The editor factoring.** Separate building the one persistent editor
   from wrapping it in a scroll view, and the page-swap ceremony from
   `updateNSView` (`shell/Sources/CompanionKit/InkEditorView.swift:35`,
   `:141`, `:248-303`). The review evidence for this branch is the
   sentence "behaviour does not change on this branch", backed by the
   existing suite unedited.
5. **The rail.** `TimeRailView`, the Settings toggle, the mode-aware
   selection wired up, and the hidden-blank-pages footer. The card's
   content row branches as a whole expression
   (`shell/Sources/OnetimePad/Views/BackdropRootView.swift:99-115`), with
   the off-path view tree written out identically to today's rather than
   wrapped, so "pixel-identical when the toggle is off" is structural and
   not a hope. The strip row (`:112-114`) is simply absent while the mode
   is on.
6. **The perforated roll.** The contiguous scroll, the day headers and
   their verbs, the quiet regions, the anchor rule, and the hardware
   procedure that answers the issue's three questions on a real machine.
   This is where the engineering goes and the branch that can be reverted
   without losing the mode.

A known limit of branch 5, resolved by branch 6: while the mode is on and
the roll has not landed, rename, hold, rung and close are reachable only
by flipping the toggle off.

## Test plan

The model is Rust and pure Swift on purpose, because Swift builds and
tests only on macOS CI while the crates test on Linux. The more of the
decision that is Rust, the more of it is validated before a PR exists.

- **Core.** A page born before local midnight is a different day from one
  born after; the day index follows the offset the clock reports,
  including a negative one; whitespace alone is not content; a chip with
  no ink is content; the placeholder stamp did not move
  (`crates/core/src/sheet.rs:1170-1185` re-asserted); the content
  predicate is the one the ledger already used, over a matrix of pages;
  and an expiring page still leaves its tab standing in place.
- **Seam.** The summary says which day the page was born on, after ageing
  a page past a local midnight; an empty slot reports no day and no
  content; the fifteen existing summary keys are unchanged; and the
  standing boundary-law test — seal a secret through every route, assert
  the bytes appear in no JSON output — still passes untouched, because an
  integer and a bool carry no ink.
- **Projection (pure Swift, no AppKit).** Today is a unit with or without
  a page; a day whose only page is whitespace is absent; a day whose page
  holds a chip and no ink is present; an expired middle day leaves a
  numbering gap and no row; the selected page's day is present even when
  blank; ordering is newest first; two pages born the same day land in one
  unit in strip order; the hidden count counts the live pages the
  projection drops; and the label tables for 0, -1, -7 and a positive
  bucket, since a skewed clock must not invent a future day.
- **The load-bearing identity.** With the mode off, the mode-aware target
  list equals the strip element for element. This is what makes
  "horizontal mode is unchanged" an assertion rather than a promise.
- **The toggle.** Flipping it both ways writes only the injected defaults
  and leaves the tabs, the emptiness predicates, the selection and the
  save status byte-identical; nothing is marked dirty; the termination
  latch never moves.
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
- **The no-ops.** Mounting the roll emits no ops to any page — identical
  document runs before and after, which is what makes "perforations are
  chrome" an assertion — and undo after the editor moves cannot cross a
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
- **No change to the cap, the ladder, the 7d ceiling, the refusal message
  or any default rung** — including a mode-specific default rung, which
  would be the mode reaching into core state.
- **No change to horizontal mode's behaviour or pixels.**
  `TabStripView.swift` takes no diff at all: `GaugeBar` is public and
  `EmptyRule` and `HoldChip` are module-internal, so the rail reuses them
  where they stand.
- **No auto-minting of Day 0**, at launch, on restore, on the toggle, in
  `refresh()`, from the rail, or when the selected page expires under the
  cursor.
- **No policing of one page per day**, no merging of days into one
  document, and no visible gap, ghost row or marker for a day whose page
  expired.
- **No drag-reorder, no rename on the rail**, and no rail affordance for a
  tab holding no page.
- **No text selection, copy-out or chip interaction inside a quiet
  region.** Click it and it becomes the editor, which already has all
  four.
- **No markdown styling parity on quiet regions.** A quiet day renders in
  the base ink font with chips as their non-secret face; the flatness
  against the live day is a stated gap.
- **No unwrapped lines in the mode.** Wrap is forced on and ⌥Z is inert
  while the mode is on; the stored `wrapsLines` preference is untouched
  and resumes when it is off.
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

## Open questions

1. **Does reinterpreting ⌘1–⌘9 and ⌘N confuse the hands?** In the mode
   the numbers address days rather than slots, and ⌘N goes to today
   instead of making a tenth tab. *Leaning:* acceptable, because the
   modes are exclusive, the mode is off by default, and no user keymap
   changes meaning. If dogfood finds people pressing ⌘3 expecting their
   third tab, the answer is probably to stop mapping numbers at all in
   this mode rather than to add a second set of chords.
2. **Does the card want a wider floor while the mode is on?** The rail
   eats 56pt of a 360pt minimum, and `BackdropGeometry.minWidth` is
   deliberately not moved, so its clamp and its test stay as they are.
   *Leaning:* leave it, and watch for the countdown header wrapping at the
   floor. A mode-conditional minimum is a second geometry story, and this
   one is already tested.
3. **Is a day the right unit, and is anything else worth building?** The
   issue says configurable, starting with the day. *Leaning:* a day, and
   nothing else until someone asks for a week and can say what a week
   starts on. A week needs a week-start policy — Sunday or Monday, locale
   or fixed — and probably a second core field.
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
   (`shell/Sources/CompanionKit/FormFactor.swift:229`), so Day -1 through
   Day -6 are reachable out of the box, but a pad re-rung to 8h shows only
   Day 0. *Leaning:* say it rather than paper over it, in the spec and in
   the QA procedure. A mode-specific default rung is refused: that is the
   mode reaching into core state.
9. **Does a flat quiet day read as a rendering bug?** Quiet regions carry
   no markdown styling in this prototype. *Leaning:* acceptable for a
   prototype and cheap to fix if it grates, since the restyle pass already
   exists; it is deliberately not paid for before anyone has looked at the
   roll.
10. **If the mode wins, do two modes survive?** A permanent toggle is two
    interaction models to maintain, test and document, which doc 03 §4
    would not thank us for. *Leaning:* the toggle is the prototype's
    instrument rather than a feature. If the vertical mode wins outright,
    the follow-up is an amendment to doc 04 and one model, not a setting
    kept forever out of politeness.

## Effort estimate

Roughly a week of focused work across the six branches, unevenly
distributed. Branches 2 and 3 are about a day together and carry most of
the model, all of it testable on Linux or without AppKit. Branch 4 is
half a day of factoring with no behaviour change. Branch 5 is a day and
produces something judgeable. Branch 6 is the rest: hand-laid AppKit
geometry, a live editor riding inside a stack, and the hardware pass. If
the geometry misbehaves, the documented fallback is to give the editor
its own inner scroller sized to content, with elasticity off so it cannot
swallow the wheel — same view, same responder, same coordinator, one
extra clip.

## References

- Issue #79, and [ADR-0020](../../../adr/0020-a-day-is-a-projection-of-live-pages.md),
  the decision this spec argues for.
- [ADR-0017](../../../adr/0017-durable-tabs-expiring-pages.md) for the
  tab/page split, the cap argument and the minting rule.
- [ADR-0016](../../../adr/0016-content-persists-across-restart.md) for
  the TTL as the only lifetime mechanism the user did not ask for.
- [ADR-0006](../../../adr/0006-persistent-editor-storage-swap.md) for the
  one-editor invariant the roll is built around.
- [ADR-0009](../../../adr/0009-chip-deletion-deliberate-final.md) for why
  a dead day leaves no marker.
