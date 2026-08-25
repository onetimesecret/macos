# ADR-0017: Durable tabs, expiring pages

- **Status:** accepted
- **Date:** 2026-08-20
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md). This
  ADR's object-graph change rides the same format break and does not ship
  without it, and the residual exposure argued below assumes ADR-0016's
  durable key. Inside that break this split lands first, before ADR-0016
  section 4's `drained_ms`; required work item 2 states why.

## Context

Today a tab and a page are the same object. `TabStripView` renders one
`SheetTab` per live `SheetSummary` (shell/Sources/CompanionKit/TabStripView.swift:27-46),
and the store holds `sheets: Vec<Sheet>` in visible tab order
(crates/core/src/store.rs:142, :349). There is no Tab type anywhere in
the tree. When a page's countdown reaches zero, `expire_due` partitions
it out of the vector and drops it (crates/core/src/store.rs:1260-1274),
`refresh()` reconciles selection to whatever is left
(shell/Sources/CompanionKit/PageModel.swift:1155-1166, :1213-1216), and the
tab vanishes from the strip.

The maintainer's complaint, docs/dogfood/ABERRATIONS.md:67-68:

> Multiple tabs, each with TTLs is a lot to think about. Perhaps
> separate the notion of the tab-page-ttl as all one time. The tab could
> be separate and long-lived structure; the page-ttl stay together so
> the page clears on expiry, but not the tab. This would affect the
> objects; some Page metadata moves to a Tab object.

The cognitive load is real and it comes from one place: a tab is both
the thing you navigate with and the thing that dies. Nine slots each
carrying an independent countdown means the strip is nine deadlines, and
the arrangement the user built by dragging tabs into an order
(crates/core/src/store.rs:332-340) is destroyed by the countdowns rather
than by the user. ⌘3 means a different page every day, and eventually
nothing, because the keyboard map indexes the live array
(shell/Sources/CompanionKit/PageModel.swift:1302-1339).

Three constraints bound the answer.

**ADR-0016 is taking the format break.** Staged content survives macOS
restart, TTL becomes the only lifetime mechanism, and `FILE_MAGIC` bumps
with no migration path. Every existing sealed file is refused. Users
lose whatever is staged, once. The durable-Tab versus expiring-Page
split changes the persisted object graph, so it rides the same break:
`OTSSNAP3` (crates/core/src/persist.rs:102) goes to `OTSSNAP4` in the
same commit range as `OTSSEAL2`'s bump. Two breaks cost users twice,
which is the reasoning recorded at docs/plans/44-ground-truth.md:100.

**ADR-0012:74 admits exactly one content-derived field and bounds it.**
The page title is derived from the first non-blank ink line
(crates/core/src/sheet.rs:574-592), and ADR-0012:79 carries it into the
ledger as "the single content-derived field". ADR-0012:82 bounds that
exposure with a rolling ninety day window, and says why in as many
words: the title is the ledger's one residual exposure and a time bound
is the only retention policy that shrinks it. That eviction actually
runs, on load (crates/core/src/persist.rs:350) and on the debounced
write path (crates/ffi/src/lib.rs:1791), through `evict_ledger`
(crates/core/src/store.rs:1296-1315).
Anything durable this ADR creates is measured against that standard.

**ADR-0009 forbids tombstones for sealed bytes.** A chip the document
no longer references is zeroized on the spot inside `settle_document`
(crates/core/src/store.rs:826-844); sealed bytes get no tombstone of any
kind (ADR-0009:20-21), and removal is final (ADR-0009:54-55). Nothing
durable may hold a chip, a chip identity, or anything derived from one.

## Decision

Split the object in two. A **Tab** is a durable slot: an identity, a
creation stamp, an optional user-typed name, a birth rung, and at most
one Page. A **Page** is everything that expires: the document, the
blocks, the chips, the clock. On expiry the Page is dropped whole and
the Tab stays where it is, empty and reusable.

### The field split

Fields on the durable **Tab**:

| Field | Source today | Note |
|---|---|---|
| `uuid: ItemId` | new | A tab identity, distinct from the page's. No ledger record names it. |
| `created_wall_ms: u64` | crates/core/src/sheet.rs:307-310 | The stamp the `MMDD-HHmm` placeholder renders from (crates/core/src/sheet.rs:596-605). The page keeps a separate stamp of its own. |
| `name: Option<String>` | replaces `title` + `title_is_user_set` (crates/core/src/sheet.rs:303, :306) | `Some` means the user typed it. `None` means the tab has no name. Never derived from content. |
| `rung: Ttl` | crates/core/src/sheet.rs:323 | The rung pages born in this slot start at. Not a countdown. See below. |
| `page: Option<Page>` | new | `None` is an expired or never-used tab. |
| `id: TabId` | new, mirrors `SheetId` (crates/core/src/sheet.rs:298) | In-process counter, never persisted, re-minted densely at restore under the rule already stated at crates/core/src/persist.rs:35-40. |

Order is the tab's index in the vector, as it already is for sheets
(crates/core/src/store.rs:142, :332-340).

Fields staying on the expiring **Page**:

| Field | Where | Why it cannot move |
|---|---|---|
| `uuid: ItemId` | crates/core/src/sheet.rs:299 | The item identity the ledger records (crates/core/src/store.rs:1374). A replacement page in a reused tab is a new item with a fresh uuid. |
| `created_wall_ms: u64` | crates/core/src/sheet.rs:307-310 | The page's own birth, now distinct from the tab's. |
| `document`, `segments`, `blocks` | crates/core/src/sheet.rs:311-321 | Content and everything projected from it. |
| `chips: Vec<SealedChip>` | crates/core/src/sheet.rs:322 | ADR-0009:20-21's no-tombstone contract requires expiry to stay a total drop of the vector, so the zeroize-on-drop path at crates/core/src/store.rs:1380 is untouched. |
| `clock: SheetClock`, `total_held` | crates/core/src/sheet.rs:324, :327 | The countdown, the pause state and the hold accounting. `remaining`, `is_held`, `fraction_remaining`, `hold_topped_up` (crates/core/src/sheet.rs:451-529) and `last_hour` (crates/core/src/sheet.rs:534-537) all stay page-side and all read as absent when the tab holds no page. |
| `derived_title: Option<String>` | crates/core/src/sheet.rs:574-592, re-derived at crates/core/src/store.rs:818-823 | `None` is a page with no ink to derive from. Dies with the page. See the title decision. |

`title_is_user_set` disappears entirely, collapsed into the tab's
`Option<String>`.

### The rung is a tab property and is not a TTL

The rung moves to the Tab. This is the observation's actual payload: the
countdown length stops being per-page bookkeeping the user re-sets after
every expiry and becomes a property of the slot, set once. `set_rung`
keeps its current behavior of resetting the live page's clock
(crates/core/src/store.rs:1113-1135) when the tab holds a page.

On a tab that holds no page the gesture succeeds and stores the value.
There is no clock to reset and no document to compact, so those two
steps are skipped rather than made to fail, and the call returns the
rung it set. A page that is due still refuses
(crates/core/src/store.rs:1124-1126); an empty tab is not a due page.
`cycle_rung` (crates/core/src/store.rs:1082-1109) behaves the same way and
is in scope, because it is the gesture actually wired to the tab context
menu (shell/Sources/CompanionKit/TabStripView.swift:228).

A stored rung is not a TTL, and the difference is mechanical. A TTL is a
number plus a clock plus a deadline. A stored rung is the number alone:
the Tab has no `SheetClock`, no `deadline` and no `remaining`, so there
is nothing for the timer path to read and nothing for it to schedule.
Required work item 8's skip is what enforces that. `next_event` reads
`s.clock` on every element today (crates/core/src/store.rs:1226-1233)
and must walk tabs and skip the ones holding no page, so a tab
contributes nothing to `companion_next_event_ms`
(crates/ffi/src/lib.rs:1284), which is what arms the shell's one timer
(shell/Sources/CompanionKit/PageModel.swift:2214). Nothing about a tab
expires. The objection worth answering is that a rung sitting on the
durable object looks like a TTL on the durable object; the answer is
that a rung with no clock cannot end anything, and the alternative (each
replacement page born at the store's `default_rung`,
crates/core/src/store.rs:210, which the backdrop sets to seven days at
shell/Sources/CompanionKit/FormFactor.swift:200) throws away most of
what the observation asked for. Take the rung on the tab. This ADR does
not leave that open; the Eject trigger below states the one condition
that would move the rung back to the Page.

### TTL granularity stays page and link only, settled

A Tab has no TTL. Neither does a block, and ADR-0013's per-paragraph
identities do not change that. TTL granularity is the page and the
concealed link, and this ADR records that as settled rather than as a
position taken today. ADR-0011's ladder is unchanged, including the 7d
ceiling (crates/core/src/ttl.rs:26-33, :45-46).

### Titles: a tab is named by the user or not at all

Three strings, two objects.

- `Tab.name: Option<String>` is set only by the rename gesture that
  exists today (crates/core/src/store.rs:859-878 core-side,
  shell/Sources/CompanionKit/TabStripView.swift:220-221, :292-314 and
  shell/Sources/CompanionKit/PageModel.swift:1782-1783 shell-side),
  capped at 80 characters, never derived, durable.
- `Page.derived_title: Option<String>` is `derive_title`'s segment walk
  (crates/core/src/sheet.rs:574-592), re-derived on edit at the site that
  does it today (crates/core/src/store.rs:818-823), and dies with the
  page.
- The `MMDD-HHmm` placeholder (crates/core/src/sheet.rs:596-605) renders
  from `Tab.created_wall_ms`, and `Tab::label` is its only caller.

The tab label resolves in order: the tab's name if the user set one;
else the live page's derived title; else the placeholder from the tab's
creation stamp. On expiry the middle term vanishes and the label falls
back one step, to the user's name if there is one and to the placeholder
otherwise.

That third step is reachable only because `derive_title` returns
`Option<String>` rather than falling back to the placeholder itself
(crates/core/src/sheet.rs:588-591). With the fallback left inside
`derive_title`, an unnamed tab renders a stamp taken from the page's
birth while a page lives and a stamp taken from the tab's birth the
instant that page expires, so the label changes under a user who did
nothing. The placeholder belongs to `Tab::label`, which is where the
tab's stamp is in hand.

That resolution is core-side, in the summary the strip reads:
required work item 8 widens `summary_json`
(crates/ffi/src/lib.rs:2371-2394) to emit `title` from the tab rather
than from `sheet.title()` (crates/ffi/src/lib.rs:2375), so a tab with no
page still carries a label.

The ledger records that same label, resolved the same three ways. The
resolution belongs at all eight of `record`'s call sites
(crates/core/src/store.rs:262, :472, :503, :843, :938, :969, :996, :1372),
`entomb`'s among them, rather than at the death record alone, or a named
tab produces records under two labels: the name on the death record and
the page's derived title on the `Created`, `Sealed`, `Sent` and chip
`Discarded` records before it. `entomb` consumes the page and holds no
tab, so it takes the label as a parameter instead of reading
`sheet.title` (crates/core/src/store.rs:1358, :1375). No new field, no
new record type; required work item 7 is widened to say so.

**A content-derived string never reaches the Tab object and never
survives its page.** This is the load-bearing refusal, and it is worth
stating why, because keeping the derived title on the durable tab is the
obvious shortcut. Required work item 3a is what enforces it in the one
code path that would otherwise defeat it.

ADR-0012:74 makes the content-derived title a single documented
exception, and ADR-0012:82 bounds it to a rolling ninety days precisely
because it is the ledger's one residual exposure. A durable tab that
keeps "prod DB credentials" after its page expired breaks that bound
three ways. It moves a content-derived string out of the ledger, where
eviction reaches it (crates/core/src/store.rs:1296-1315), into the
sealed content file, where nothing evicts anything. It converts a
rolling exception into a permanent one, since a tab's life is bounded by
the user and not by a clock. And under ADR-0016 that string now sits in
a file that survives reboot under a key that survives reboot, which is
the case ADR-0012:98 covered with "both dead or rotated after reboot"
and no longer can. The auditor sentence at ADR-0012:100, content-free by
construction except the capped user-visible title field, survives
verbatim only if the durable half of the object graph carries no string
the app derived on its own.

Falling back to the placeholder is what an unnamed tab does and it is
the default, but it cannot be the only answer. `placeholder_title` was
written for a page nobody has typed in yet
(crates/core/src/sheet.rs:594-605), not as a durable name for a slot. A
user who has arranged nine tabs by purpose watches all nine collapse to
a row of near-identical four-digit stamps the first morning after a 7d
rung elapses, and the arrangement stops meaning anything. A durable tab
is only worth having if it can be identified, and the cap of nine
(crates/core/src/store.rs:25-31) keeps the naming problem small enough
that asking for an explicit name is reasonable.

The explicit name costs nothing new. It is the same path `set_title`'s
user-set branch already takes (crates/core/src/store.rs:875), the
same 80 character cap (crates/core/src/sheet.rs:566), and the same
context-menu gesture already shipped
(shell/Sources/CompanionKit/TabStripView.swift:220-221, :292-314).
ADR-0012:74's exception is about derivation, not about the field
existing. A label the user typed is the same class of artifact as a
filename.

The net effect on the sealed file is a reduction. `OTSSNAP3` stores an
80 character content-derived string for every sheet
(crates/core/src/persist.rs:380). `OTSSNAP4` stores none: only names the
user typed, and only for tabs where they typed one. Required work: the
derived title stops being written and is recomputed at restore from the
restored segments, the same discipline that already refuses to store a
chip's excerpt and size label (crates/core/src/persist.rs:50-53).

### What an expired tab looks like

Empty and reusable, immediately, and marked as empty. Not tombstoned,
not auto-closed, never removed from the strip.

The tab keeps its slot and its label. It shows no gauge, because it has
no clock: `GaugeBar`
(shell/Sources/CompanionKit/TabStripView.swift:181-186) is replaced for
that tab by the dashed treatment the ledger tab already uses
(`circle.dashed`, shell/Sources/CompanionKit/TabStripView.swift:114-117).
No countdown, no hold chip, no remaining label.

Selecting an empty tab mints a fresh page into it at the tab's rung,
immediately on selection rather than lazily on first keystroke. The
reason is ADR-0006:40-42: the empty branch renders no `InkEditorView`,
so a selected tab with no page would unmount the editor and re-mount it
on the first keystroke, turning every expiry into an editor teardown and
putting ADR-0005's Return-to-create grant
(shell/Sources/CompanionKit/PageModel.swift:1621-1625) in competition
with the tab's own selection path. Minting on selection keeps one editor
mounted and keeps `storages` and `undoManagers` keyed to a live page
(shell/Sources/CompanionKit/PageModel.swift:1155-1165).

**Which selections mint: a user gesture, and nothing else.** The
gestures are exactly three. A click on the tab
(shell/Sources/CompanionKit/TabStripView.swift:214, into `select(_:)` at
shell/Sources/CompanionKit/PageModel.swift:1294-1299). ⌘1 through ⌘9
(`select(index:)`, shell/Sources/CompanionKit/PageModel.swift:1305-1308).
⌥⌘←/→ (`step`, shell/Sources/CompanionKit/PageModel.swift:1312-1339). A
restored selection never mints, and neither does the selection
`refresh()` reconciles. Return is the one other way a page comes into
being and it is not a selection at all; it arrives through ADR-0005's
create grant, which required work item 11 rewrites.

Narrowing to the gesture is what settles the live-expiry case, and
without it the rule contradicts itself. `refresh()` reconciles selection
on every reload, through `reconciledSelection`
(shell/Sources/CompanionKit/PageModel.swift:1166, :1214-1216), so a rule
that minted on any selection would mint whenever the selected tab's page
expired under the user's cursor. That is the same silent countdown on
nothing that the expiry paragraph below refuses for the closed-app case,
and it would fire while the user watches.

So: when the selected tab's page expires in place, the tab stays
selected and the surface renders the empty tab state described above,
dashed rather than gauged, the label fallen back one step, no countdown
and no mounted editor. Nothing is minted. The user's next deliberate
action mints, either one of the three gestures landing on that tab or
Return.

The editor unmounts in that moment, which is the teardown the selection
rule above is written to avoid. It is unavoidable here and it is
accepted: the page is gone, there is nothing left to render, and the
only way to keep the editor mounted would be to mint a page the user did
not ask for. What the selection rule buys is that the remount happens on
a deliberate gesture rather than on a keystroke.

Two accepted costs, stated rather than engineered around. Clicking
through an empty tab writes a `Created` ledger record and starts a
countdown on an empty page (crates/core/src/store.rs:254-269). That is
exactly what `newPage()` does today. The resulting empty page leaves no
`Expired` record when it dies, because `entomb` returns early for a page
with no ink and no chips (crates/core/src/store.rs:1363-1365), so the
cost is `Created` volume, not death noise.

Expiry does not mint the replacement. A tab whose page expired at 03:00
while the app was closed must not silently start a fresh 7d countdown on
nothing. The honest state at the 09:00 relaunch is an empty tab.

At launch with every tab empty, the app opens on a populated strip and
the existing empty state, and Return mints into the previously selected
tab, or the first tab when there is none. The empty state's predicate
stops meaning "the sheet list is empty" and starts meaning "no live page
is selected". That is required work, listed below.

### A tab outlives every page it held

Yes, without qualification. That is the point of the split, and it is
what the maintainer asked for at docs/dogfood/ABERRATIONS.md:68: "The
tab could be separate and long-lived structure; the page-ttl stay
together so the page clears on expiry, but not the tab." It is the same
instinct they applied to restart survival at :74-75:

> If we already have the TTL expiration, we don't gain much by flushing
> everything upon restart. We just make it annoying to use.

A tab is bounded by the user, by exactly two things.

First, explicit close. The hover ✕
(shell/Sources/CompanionKit/TabStripView.swift:166-176) calls what is
today `close_sheet` (crates/core/src/store.rs:284-294) and becomes
`close_tab`: it entombs the live page if there is one, exactly as today,
and removes the tab. That is already a deliberate gesture in the
ADR-0009 sense.

Second, the cap. Nine tabs (crates/core/src/store.rs:25-31), refused at
the wall with a message rather than evicted
(crates/core/src/store.rs:200-202,
shell/Sources/CompanionKit/PageModel.swift:1544-1550). A durable tab
that never expires cannot accumulate, because the ceiling never moves:
reaching it forces the user to close one. The cap was already written as
the anti-eviction bound, since "silent eviction of deliberately placed
content would break trust" (crates/core/src/store.rs:27-28), and under
the split it becomes the tab's lifetime bound as well.

Being a lifetime bound makes it a restore-path check. The writer never
emits more tabs than the cap, so a file claiming more is damage or a
hand edit, and the tab count refuses it as `Malformed`
(crates/core/src/persist.rs:247, where `count` already bounds a claimed
number against the bytes actually remaining, :723-730). The refusal
lands before any tab is built and therefore before the store is touched
(crates/core/src/persist.rs:280), like every other damage the restore
path meets.

An empty tab is a uuid, a creation stamp, an optional name and a rung.
No document, no blocks, no chips, no clock. Nine of them are inert.

There is no TTL on the tab, no idle-close after N days, no auto-reap. A
rule like "empty for 30 days, close it" would be a second lifetime
mechanism, which is the thing ADR-0012:51 declined when it rejected
binding to the login session, and ADR-0016 makes TTL the only lifetime
mechanism. An empty tab holds nothing that needs forgetting except a
name the user typed, and the user closes that themselves.

### Emptying the pad is two predicates, not one

This is the seam with ADR-0016 and it has to be stated the same way on
both sides.

ADR-0016 section 6 makes an emptied store the first of the two events
that rotate both key halves, and ADR-0016 section 8 dates the ciphertext
artifact from the first save until the last tab is closed. Both readings
depart from the shipped drop-on-empty path, which keys on a single
predicate today:
`erasesContentFile` (shell/Sources/CompanionKit/PageModel.swift:789-827)
is called with `client.sheets().isEmpty`
(shell/Sources/CompanionKit/PageModel.swift:1015-1030), and the core's
`is_empty` is the page vector's own
(crates/core/src/store.rs:279-280). This ADR makes the sealed file also
carry tab names, rungs and strip order, so an empty page set stops being
an empty file and that one predicate stops meaning what the trigger
needs.

**"Empties" means no tab holds a page. It does not mean no tabs
remain.** On that transition both halves rotate and the surviving tab
metadata is resealed under the new ones. A rotate plus a reseal, not a
drop. The file is dropped outright, as today, only when no tabs remain
at all.

Rotating on the no-page transition is what keeps the forgetting claim
true. Every prior ciphertext generation becomes undecryptable at the
moment the pad holds no content, including the unlinked ones that
ADR-0016 section 8 says nothing sweeps. The rotation argument itself is
ADR-0016 section 6's and is not restated here; what this ADR decides is
which predicate fires it.

Rejected: defining "empties" as "no tabs remain". It is the simpler
reading and it is the one the shipped code already computes. It fails
because rotation would then almost never fire for a user who keeps tabs
around, so the pad could hold one content key for the life of the
install and ADR-0016's claim that an emptied pad is a forgetting would
quietly stop being true.

The cost, stated rather than engineered around: the reseal writes a new
ciphertext generation under the new halves. It contains tab names, rungs
and strip order, and no page content.

### Required work

All of the following is work this ADR requires. None of it exists today
except the magic bump in item 1, which issue #54 has already taken.

1. `MAGIC` goes `OTSSNAP3` to `OTSSNAP4`
   (crates/core/src/persist.rs:102), in the same break as ADR-0016's
   envelope bump. This is the one item already taken: #54 landed the
   bump first and this ADR rides it rather than spending a second
   version byte (ADR-0016 section 9). The refusal path for an unknown
   or superseded magic exists and is exercised
   (crates/core/src/persist.rs:2391).
2. `emit` changes shape (crates/core/src/persist.rs:423-437). After
   `wall_ms`, write a tab count, then per tab in strip order:
   `uuid[16]`, `created_wall_ms` u64, `name` as an optional (a u8
   present flag plus length-prefixed bytes, mirroring the conceal
   encoding at crates/core/src/persist.rs:539-545), rung seconds u64, a
   u8 page-present flag, then the per-page body as ADR-0016 section 4
   leaves it, with `drained_ms` in place of the running span at
   crates/core/src/persist.rs:488-492. Both records are written under
   #54's framing rule from the start (`framed`,
   crates/core/src/persist.rs:405-421): the tab record states its own
   byte length, and so does the page body inside it, so a trailing field
   on either costs no version byte later. The chip records inside the
   page stay framed as they already are
   (crates/core/src/persist.rs:516).

   The home this item promises `drained_ms` is the inner framed page
   body, not the tab record, and this split lands before ADR-0016
   section 4 writes it. The split relocates record boundaries and leaves
   the clock encoding alone, so `drained_ms` afterwards is one arm of
   `emit_sheet` (crates/core/src/persist.rs:488-492) and its counterpart
   in `read_page`. The reverse order makes whoever implements section 4
   re-derive their record layout once this lands. Framing does not
   rescue the reverse order: `drained_ms` replaces a field rather than
   appending one, and the module header already says that a field which
   moved, changed width or changed meaning is outside what the rule buys
   (crates/core/src/persist.rs:69-74).
3. Fields leave the page record: `rung`
   (crates/core/src/persist.rs:467) moves to the tab; `title`
   (crates/core/src/persist.rs:380) is deleted outright and recomputed
   at restore by `derive_title` (crates/core/src/sheet.rs:574-592);
   `title_is_user_set` (crates/core/src/persist.rs:381) disappears.

   `derive_title` returns `Option<String>`: the segment walk, or
   nothing. Its internal fallback to `placeholder_title` goes
   (crates/core/src/sheet.rs:588-591), and `Tab::label` applies the
   placeholder instead, from the tab's own creation stamp, so the three
   step resolution above has a reachable third step. One consequence is
   the restore path's: recomputing the derived title takes segments and
   nothing else, so no UTC offset threads into restore. Rendering a
   local-time stamp stops being `derive_title`'s business.

   **3a.** `set_title` splits with the object
   (crates/core/src/store.rs:859-878). The non-empty branch writes
   `Tab.name = Some(trimmed)`, capped at `TITLE_CAP` as today
   (:875). The empty branch writes `Tab.name = None` and does
   **not** call `derive_title` (:872-874): clearing the name falls the
   label back to the live page's derived title, which is a read of the
   page, never a write to the tab. That branch is the only place in the
   tree that writes a derived string into what becomes the durable
   field, so changing it is what makes "never derived" true rather than
   aspirational.
4. `read_sheet` splits into `read_tab` plus `read_page`
   (crates/core/src/persist.rs:810), each reading from its own framed
   sub-reader (crates/core/src/persist.rs:709-714) and with the page arm
   skipped on the absent flag. A third counter, `next_tab_id`, joins
   `next_sheet_id` and `next_chip_id`
   (crates/core/src/persist.rs:257-258), re-minted densely in read
   order.

   The 80 character re-cap the title takes on the way in
   (crates/core/src/persist.rs:756-772) moves to the tab's `name` and
   stays there. It exists so a hand-edited file cannot smuggle a label
   longer than the strip and the ledger agreed to carry
   (`TITLE_CAP`, crates/core/src/sheet.rs:564-566), and after this split
   that string is durable and reaches the ledger through every `record`
   site. It is more load bearing than it was, not less.

   A page with no tab is unrepresentable rather than rejected. The page
   body sits inside the tab's frame, so no byte sequence encodes an
   orphan and there is no check to write. That is a property of the
   layout and the module doc states it as one.
5. `SheetStore.sheets: Vec<Sheet>` becomes `tabs: Vec<Tab>` with
   `Tab.page: Option<Sheet>` (crates/core/src/store.rs:142). Every
   reader of `self.sheets` follows. Thirteen sit in the store:
   `sheets()` (:349), `sheet()` (:355), `sheet_mut` (:375-376), `len`
   (:407-408), `is_empty` (:279-280, deleted rather than ported, see
   6a), `move_sheet` (:332-340),
   `new_sheet` (:199-217), `close_sheet` (:284-294), `expire_due`
   (:1260-1274), `chip_home` (:884-886), the normalize passes in
   `delete_chip` (:905) and `mark_chip_concealed` (:1010), and
   `next_event` (:1226-1228). The persistence seam holds the rest: the
   two per-sheet export passes in `snapshot`
   (crates/core/src/persist.rs:189-198) and `emit`'s own pass
   (crates/core/src/persist.rs:440-446), which item 2 already reshapes.

   **5a.** `open_page(TabId) -> Option<SheetId>` is new, and it is what
   every mint into an existing tab calls: the three selection gestures
   and the Return grant named above, and nothing else. It mints at the
   tab's rung rather than at the store's `default_rung`
   (crates/core/src/store.rs:210), which is what makes the rung a
   property of the slot in practice rather than only in the field split.
   It records one `Created` event, on the same terms `new_sheet` records
   one today (crates/core/src/store.rs:262-269), and it starts the
   clock. It returns `None` for an unknown tab and for a tab that
   already holds a page: a tab holds at most one Page, and replacing a
   live one here would drop a page nobody closed.
6. `expire_due` stops partitioning the vector
   (crates/core/src/store.rs:1260-1274). It walks tabs, takes the page
   out of each tab whose page has zero remaining, entombs it
   (crates/core/src/store.rs:1281), and leaves the tab standing. The
   Sheet still drops whole, so the zeroize-on-drop path at
   crates/core/src/store.rs:1380 and ADR-0009's no-tombstone contract
   are untouched.

   **6a.** The emptiness predicate splits in two. Neither half is
   `is_empty` as it stands (crates/core/src/store.rs:279-280), read
   shell-side as `client.sheets().isEmpty`
   (shell/Sources/CompanionKit/PageModel.swift:931), because the sealed
   file now carries tab names, rungs and strip order. The core owns both
   halves, as `holds_no_page()` and `has_no_tabs()`, and one FFI export
   carries both across the seam beside the summaries
   (crates/ffi/src/lib.rs:978-996).

   The shell derives neither. `holds_no_page` is ADR-0016 section 6's
   key rotation trigger, which makes it a security decision rather than
   a rendering convenience, and a predicate the shell recomputes from
   the summary array is a predicate that can drift from the one the
   rotation uses. `is_empty` is deleted rather than redefined:
   redefining it leaves every existing caller compiling while silently
   answering a different question, and deleting it forces each caller to
   say which of the two it meant. The compiler is the only thing that
   will enforce that choice.

   - **No tab holds a page.** Every tab's `page` is `None`. This is
     ADR-0016 section 6's first rotation trigger: rotate both halves and
     reseal the surviving tab metadata under the new ones. See the
     Emptying subsection above and ADR-0016 section 6 for why rotation
     fires here.
   - **No tabs remain.** The tab vector is empty. This is the drop.
     `erasesContentFile`'s `storeEmpty` argument
     (shell/Sources/CompanionKit/PageModel.swift:789-827, :1015-1030)
     takes this predicate and only this one, so the file is unlinked
     only when there is nothing left to reseal.

   Wiring them backwards fails in both directions, which is why they are
   named separately here rather than left to the implementer. Feeding
   the first to `erasesContentFile` destroys the tabs an expiry was
   supposed to leave standing. Feeding the second to the rotation
   trigger leaves the install on one content key for as long as any tab
   exists.
7. `record` takes the tab's label, resolved the three ways above, at all
   eight of its call sites
   (crates/core/src/store.rs:262, :472, :503, :843, :938, :969, :996,
   :1372), so every record a page produces carries one label rather than
   two. The eighth site is inside `entomb`
   (crates/core/src/store.rs:1358-1381), which consumes the page and has
   no tab in hand, so `entomb` gains a label parameter and stops reading
   `sheet.title` (:1375); both of its callers
   (crates/core/src/store.rs:291, :1281) pass the tab's label. The field
   is the one `record` already fills
   (crates/core/src/store.rs:1331, :1375). No change to `LedgerRecord`.
   `OTSLEDR1` is a different matter: issue #54 framed the ledger record
   and bumped the payload magic to `OTSLEDR2`
   (crates/core/src/persist.rs:111, :620-624), a break ADR-0016 section
   9 prices. This item neither causes that break nor changes the
   record's shape.
8. `summary_json` takes the tab rather than the sheet
   (crates/ffi/src/lib.rs:2368) and gains `has_page: bool`
   (crates/ffi/src/lib.rs:2371-2394); every clock field is meaningful
   only when it is true. `title` stops reading `sheet.title()`
   (crates/ffi/src/lib.rs:2375) and carries the three-step resolution
   above, so a tab with no page still has a label.

   The summary carries two ids, not one. The tab's id addresses the
   slot: that is what `id` (crates/ffi/src/lib.rs:2372) becomes, because
   item 10's keyboard gestures have to land on a slot that may hold
   nothing. A second id addresses the content, because item 9's storage
   maps have to be keyed to something that must not survive its page.
   Neither id can do both jobs. Page identity across the seam is
   `SheetId`, not `ItemId`: the counter never repeats inside a session,
   the maps it keys are per-session, and a 36 character string
   (crates/core/src/sheet.rs:63-67) has no business on the keystroke
   path.

   The routes split the same way. Tab addressed: new, close, move,
   set_title, set_rung, cycle_rung, pause_press. Page addressed: seal,
   sync, apply_ops, document_json, meta_json, blocks_json, conceal.
   `companion_ffi.h` is hand maintained
   (crates/ffi/include/companion_ffi.h:15-16), so it follows in the same
   commit as the routes it describes. `SheetSummary` follows
   (shell/Sources/CompanionKit/CompanionClient.swift:26-78), and
   `SheetTab` renders the dashed empty treatment instead of `GaugeBar`
   when it is false
   (shell/Sources/CompanionKit/TabStripView.swift:153-186).
   `companion_next_event_ms` itself needs no change
   (crates/ffi/src/lib.rs:1284), but `SheetStore::next_event` does: it
   maps over every element of `self.sheets` and reads `s.clock`
   unconditionally (crates/core/src/store.rs:1226-1233), so it must walk
   tabs and skip the ones holding no page. That skip is the mechanism
   that makes "nothing about a tab expires" true, not the shim.
9. `PageModel.storages` and `PageModel.undoManagers` must be re-keyed
   from tab id to page identity
   (shell/Sources/CompanionKit/PageModel.swift:1155-1165). This is the
   split's one real correctness trap. A reused tab holds a new page, and
   inheriting the dead page's `NSTextStorage` or undo stack would let a
   later ⌘Z re-insert a dead chip's attachment character, which is the
   exact hazard ADR-0009:15-21 describes and ADR-0009:34-42 closed. The
   pruning predicate that today
   filters on the live sheet id set must filter on the live page
   identity set.
10. ⌘1 through ⌘9 and ⌥⌘←/→ index into `model.sheets`
    (shell/Sources/CompanionKit/PageModel.swift:1302-1339). They must
    index tab slots, so ⌘3 on an empty tab opens a page into it through
    item 5a rather than being a no-op.
11. `shouldOfferEnterCreate`'s `sheetsEmpty` predicate
    (shell/Sources/CompanionKit/PageModel.swift:1621-1625, fed at
    shell/Sources/CompanionKit/PageSurface.swift:61) becomes "the
    selected tab holds no page". It follows the selection, not the
    strip: a selected empty tab offers the create surface while another
    tab holds a page, which is the state the expiry paragraph above
    describes as no live page being selected. Neither of item 6a's two
    predicates is this one: both of those are store-wide and this one is
    per selection, so feeding either here hides the create surface
    exactly when a user is looking at an empty tab. The Return grant's
    own `if sheets.isEmpty { newPage() }` inside `createPageAndFocus`
    (shell/Sources/CompanionKit/PageModel.swift:1584-1589, reached only
    from shell/Sources/CompanionKit/PageSurface.swift:62) opens a page
    into the selected tab through item 5a, and mints a tab only when no
    tabs remain.

    `loadStateIfNeeded` is the third reader of `client.sheets().isEmpty`
    in the shell and it is the one that would make restore mint: it
    calls `newSheet()` whenever the store comes back empty and then
    seats the selection on the first entry
    (shell/Sources/CompanionKit/PageModel.swift:707-711). It takes item
    6a's second predicate, no tabs remain, not the first. Otherwise
    every launch after an overnight expiry mints into a tab the user
    never selected and starts a fresh countdown on nothing, which is the
    outcome the expiry paragraph refuses.
12. ADR-0013's interaction count is a Page field, and it needs no
    reservation here. ADR-0013:168-175 declares the count a stored field
    from birth, maintained at its interaction sites and carried across
    compaction by persistence; nothing implements it, as recorded at
    docs/plans/44-ground-truth.md:100. An earlier draft of this ADR
    reserved a zero u64 per materialized block so the count would not
    have to buy a second break. That reservation is withdrawn. Issue #54
    has already made every repeated record in the snapshot payload
    self-describing, the per-block materialized record among them
    (crates/core/src/persist.rs:589-606 writes it inside its frame,
    :997-1006 reads it back inside the same frame), so the count is
    appended whenever ADR-0013 is implemented and costs no break at all. Reserving a field for it now
    would be guessing at a shape nobody has designed.

    What this ADR does decide is where the count lives. It is a block
    field, so it is a Page field, and it dies with the page. No
    page-level or tab-level count ships: ADR-0013:168's "ordering pages
    in a switcher" is dropped, because a manually ordered strip of at
    most nine tabs has nothing for a count to sort. A count that
    outlived its page would also be a durable per-tab record of how
    often the user touched content that is gone, which is the kind of
    residue the split exists to remove.

## Consequences

- The strip stops being nine deadlines. A tab's identity, position and
  name survive every page that lived in it, so ⌘3 means the same slot
  next week, and the arrangement the user built by dragging is destroyed
  only by the user.
- Users pay one format loss, not two. Whatever is staged when ADR-0016
  and this ADR ship together is refused once, by the same magic bump
  (crates/core/src/persist.rs:102).
- The sealed file gets less content-derived, not more. `OTSSNAP3` writes
  an 80 character derived title for every sheet
  (crates/core/src/persist.rs:380); `OTSSNAP4` writes none, and
  recomputes the derived title at restore.
- Emptying the pad now writes a file instead of removing one. When the
  last page expires and tabs remain, ADR-0016 section 6's rotation runs
  and the tab names, rungs and order are resealed under the new halves,
  so there is a fresh ciphertext generation on disk holding no page
  content. Only closing every tab removes the file
  (shell/Sources/CompanionKit/PageModel.swift:789-827).
- **Residual exposure, stated plainly and not claimed away.** A user can
  type "prod DB credentials" into the rename field, and under ADR-0016
  that string is durable across reboot, under a long-lived key, with no
  TTL and no eviction while the tab exists. Closing the tab does not end
  it either: the same string was copied into a ledger record for every
  page that lived in that tab (crates/core/src/store.rs:1375), where it
  stays for the ninety day window (ADR-0012:82) measured from the last
  of those records. The user-facing bound is therefore the tab's life
  plus ninety days. What this ADR forbids is the app manufacturing such
  a string from the body without being asked; it does not stop the user
  from typing one. The rename prompt already says so
  (shell/Sources/CompanionKit/TabStripView.swift:296-299), as does the
  FFI (crates/ffi/src/lib.rs:532-535), and both warnings now have a
  longer lifetime behind them.
- A ledger record's title can now come from either object depending on
  whether the user named the tab, and the ledger view gives no signal
  which. The field, its 80 character cap and its ninety day window are
  unchanged (crates/core/src/store.rs:1375, ADR-0012:82), and a
  user-typed label is a different class of artifact from a derived one,
  not a smaller one. The ledger's exposure is unchanged in size and
  changes only in who chose the string: a user-typed label can be more
  sensitive than a derived first line, and what the split buys is that
  no such string reaches the durable object without the user typing it.
- Clicking through an empty tab writes a `Created` record and starts a
  countdown on nothing (crates/core/src/store.rs:254-269). Ledger
  `Created` volume goes up with the number of tab selections on empty
  slots.
- The reuse path is where a chip could come back from the dead. A tab
  that keeps its shell-side `NSTextStorage` or `UndoManager` across a
  page replacement puts an attachment character for a zeroized chip
  within reach of ⌘Z, which is what ADR-0009:34-42 closed. The re-key at
  shell/Sources/CompanionKit/PageModel.swift:1155-1165 is the whole
  mitigation, and it needs a test that mints into a reused tab and
  presses undo past the page boundary.
- The core's page vector stops being the strip. Every reader that
  assumed `sheets` is what the user sees has to say which of the two it
  wants, and the compiler will not catch the ones that are merely wrong
  about intent.
- Nine empty tabs still occupy nine slots, so a user who never closes
  anything reaches the cap and is refused
  (crates/core/src/store.rs:200-202). That is the intended bound, and it
  will read as a bug to someone whose nine tabs are all empty.
- The empty state stops meaning what it meant. `shouldOfferEnterCreate`
  was written for an empty sheet list
  (shell/Sources/CompanionKit/PageModel.swift:1621-1625); under the
  split the strip can be full while nothing is live, which is a state
  nothing in the shell renders today.

## Eject triggers

- The nine cap starts being hit by empty tabs. If dogfood shows users
  refused at the wall while several slots hold no page, the cap is
  counting the wrong thing and either the cap or the close gesture gets
  revisited, not the split.
- A durable tab name shows up in a support transcript, a screenshot or a
  bug report as an actual secret rather than a label. That is the
  residual exposure above landing, and the response is to bound the name
  (a length cut, a warning at the rename field, or a TTL on the name
  alone), not to derive titles again.
- Users rename tabs at a rate near zero over a dogfood month. Then the
  strip is nine placeholder stamps in practice, the identification
  argument above has failed, and the tab label needs a different
  affordance.
- A second lifetime mechanism gets proposed for tabs (idle-close,
  auto-reap, a tab TTL). That proposal contradicts this ADR and
  ADR-0016; it reopens both or it does not ship.
- The rung on the durable Tab starts being read as a TTL on the Tab. A
  stored rung is a number with no clock and no deadline, and nothing
  about a tab expires; if that stops being legible to a reader of the
  code or to an auditor, the rung goes back on the Page and every
  replacement page is born at the store's `default_rung`
  (crates/core/src/store.rs:210), at the cost the Decision already
  names.
- Issue #54 slips out of this break while item 12 still assumes it.
  **Discharged.** #54 landed first and took the `OTSSNAP4` bump
  (crates/core/src/persist.rs:102, :405-421), so the interaction count
  has a self-describing record to append to. The check that remains is
  the mirror of it: this split lands under `OTSSNAP4` too, or it buys a
  second break with users' staged content.

## Deferred

Two things this ADR does not settle. Both get issues.

1. **A separate visual treatment for the first line and the tab title**,
   the second half of the observation at
   docs/dogfood/ABERRATIONS.md:69. The tab label still reads the
   derived title as its middle fallback, so the first line remains the
   naming affordance for an unnamed tab and the request is still live.
   It is a UI decision with no object-graph cost, so it does not belong
   in a format-break ADR.
2. **Whether the ledger view distinguishes a tab name from a derived
   title.** The record format is unchanged and carries no flag
   (crates/core/src/store.rs:1375,
   crates/core/src/persist.rs:111), so adding one is itself a format
   change and would have to wait for the next break or be inferred at
   read time. Whether the distinction is worth surfacing at all is a
   question for the ledger view, not for this split.
