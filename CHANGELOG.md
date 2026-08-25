# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **The word for the exit ramp is conceal** (issue #105). "Promotion"
  was never the project's word for turning staged content into a
  one-time link. The API route has always been
  `POST /api/v3/secret/conceal`, `crates/ots-client` has always called
  it that, and everything above the client had drifted into a second
  vocabulary for the same act, with "reveal" left with no counterpart to
  answer to. The code now says conceal everywhere: the module is
  `crates/ffi/src/conceal.rs`, the view is `ConcealView`, the chip's
  wire flag is `concealed`, and the core keeps a `Conceal` record on a
  chip that has travelled. **This renames two exported C symbols**,
  `companion_chip_promote` to `companion_chip_conceal` and
  `companion_sheet_promote` to `companion_sheet_conceal`, so any caller
  outside this repository has to move with it; `crates/ffi` and
  `crates/core` go to 0.14.0 for it. The chip face's JSON key changes
  from `promoted` to `concealed` on both sides of the seam in the same
  pass, since a mismatch there would have failed at runtime and not at
  compile time. `crates/pasteboard` kept the one legitimate other
  meaning: `org.nspasteboard.ConcealedType` and its `CONCEALED_TYPE`
  constant are Apple and community convention, not ours, so the UTI
  stays exactly as it was and only the struct fields that carried it
  were renamed to `nspasteboard_concealed`, which takes that crate to
  0.3.0. An unqualified "conceal" in this tree now means the one thing.
  Retired along the way: the claim that this is the app's only network
  action, which the C header and the Swift seam both made. Both now say
  what the action is instead, an explicit one the user takes.

- **What the network rule actually protects** (issue #92). The design
  documents said the app has exactly one outbound destination and that
  reaching the network is never a side effect. That conflated two
  different things: how many places content can go, and whether the
  user knew and chose. Only the second is a principle worth keeping. The
  anti-goal is now "not a general sync service", scoped against Dropbox,
  iCloud Drive and Notion rather than against replication itself, and
  principle 6 forbids unaccounted traffic rather than automatic traffic:
  no destination the user did not enroll, no payload the app would not
  show them, no retention on a relay beyond the page's own expiry. The
  network boundary in doc 05 now names at most two destinations and says
  plainly that the second one is not built, and `crates/transport` keeps
  enforcing the boundary either way. Nothing about sync ships here; what
  ships is a rule that will still be true when it does. The open
  decisions and their prior art are open question 19 in doc 06,
  headed for ADR-0021.

- **The version moves when the app moves** (issue #89). About and the
  tray menu now say 0.13.0, which is this app after milestone 2: ⌘N
  makes a page, the keyboard is a file you can edit, four affordances
  that had not earned their place are hidden, and the pad follows you
  between Spaces. None of that touched a crate, and the version users
  see was the `companion-ffi` crate's, so under the old rule the number
  would have sat at 0.12.0 through all of it while two invisible changes
  to the seam in August had moved it twice. The app's version was a fact
  about the Rust library rather than about the product. It is now the
  product's own number, held in `shell/OnetimePad-Info.plist` as
  `CFBundleShortVersionString` and edited by hand when work a user can
  touch lands, the same way `crates/ffi/Cargo.toml` is edited when the
  seam changes. The packaging script reads it from there, refuses the
  placeholder rather than shipping 0.0.0, and still stamps
  `CFBundleVersion` as that version plus the short commit, so About
  reads "Version 0.13.0 (0.13.0+ab12cd3)": the product first, the exact
  build behind it. The core keeps its own version and keeps speaking for
  itself through `companion_version()`. The tray line names both from
  here on, where it used to hide the core whenever the two strings
  matched: with one source a difference could only mean a stale
  xcframework, and with two sources it usually means the app shipped
  something and the seam did not.

- **Four things stopped showing up** (issue #78). Dogfooding turned up
  affordances that were on the card without earning their place, and
  they are now hidden: the ledger's every way in (the dashed tab at the
  end of the strip, the ⌘0 binding in the bundled keymap, and the clear
  button in Settings), the ↗ page button that promoted the visible page
  to a link, the resize glyph drawn in the bottom corner, and the
  coloured dot beside the app's name in the header. This is a hide and
  not a removal. Nothing was deleted: the ledger still records and still
  survives restarts, promotion still works from everywhere else it
  worked, and the card still resizes from all eight of its edges and
  corners, which never needed the glyph to be draggable. Each suppressed
  site is one flag in `HiddenUI`, so a build that wants any of them back
  gets it back in one line while the decision to keep them or drop them
  is still being made. `ledger::Show` remains a legal command id, so a
  keymap of your own can still put the ledger on a chord. The clear
  button has one deliberate exception, because a hide must not end a
  recovery route: when the audit trail will not open, the surface puts
  up a standing line telling you to clear the ledger in Settings, and
  for as long as that line stands the Settings section it names is
  there. Clearing takes the line down and the section with it.

- **⌘N makes a new page** (issue #77). It was ⌥⌘N, which existed
  because ⌘N looked spoken for, and it is not: the pad has no document
  model, so AppKit never installs the stock New item that would have
  claimed it. The pad now puts a new thing on the same key every other
  app does. **⌥⌘N is retired**, deliberately: one command with two
  default chords is how a keymap turns into a pile of accommodations,
  and the point of the file is that it reads as a list of decisions.
  If ⌥⌘N is what your hands know, it is one line in your own keymap at
  `~/Library/Application Support/com.onetimesecret.companion.backdrop/keymap.json`,
  and the bundled default carries the line to copy:

  ```json5
  [{ "context": "Editor", "bindings": { "cmd-alt-n": "page::New" } }]
  ```

  This is the first binding to move through the keymap rather than
  through Swift, which is what the keymap was for.

### Added

- **A page a day, with the tabs down the side** (issue #79,
  `docs/spec/feature/vertical-time-tabs/README.md`,
  `docs/adr/0020-a-day-is-a-projection-of-live-pages.md`). A prototype
  mode, off by default and turned on in Settings, that stands the strip
  on its side and gives each day a row: Today at the top, then -1d, -3d,
  back through whatever is still alive. The decision underneath it
  landed first, because it is the part that could have gone wrong
  quietly. A unit of time is not something the app creates, names,
  orders or reaps. It is a bucket over the page's own creation stamp,
  computed fresh every time the surface asks and stored nowhere, so
  nothing about a tab changes: the calendar creates no tab, closes none,
  re-dates none, re-orders none and re-labels none, and a day leaves the
  rail only because the page keyed to it expired under the countdown it
  always had. The labels are relative rather than dated, which is what
  lets local midnight roll them over on the repaint the app already runs,
  with no new timer, no midnight alarm, and the sealed file's format did
  not move by a byte. The core now says, on each tab it already
  describes, which day that tab's page was born on relative to today and
  whether anything is on it, which is two more fields on a reading the
  app already takes and no new call, no renamed field and no change to
  what is stored. Both fields are additive, so no caller outside this
  repository has to move, but `crates/ffi` and `crates/core` go to
  0.15.0 for the new reading. Above that seam the days are one pure
  function over the tabs the app already reads, and every rule the mode
  has lives in it: a
  day is shown when a page on it has something on it, or it is today, or
  it holds the page under the caret; today has a row whether or not
  anything is standing on it; several pages made on one day are grouped
  rather than policed; and the number of live pages the grouping is not
  showing is carried along beside it, so a pad that is full of old blank
  pages can say so instead of looking broken. ⌘1 to ⌘9 and ⌥⌘←/→ count
  days while the mode is on and slots while it is off, through one list
  whose value with the mode off is the strip element for element, and ⌘N
  goes to today's page: it selects the one that is there, and when there
  is none it makes one down the same path it always used. No new chord
  and no new command name, so a keymap of your own keeps working under
  either arrangement. Turning the mode on or off moves no content and
  writes no new sealed generation: it is one boolean in `UserDefaults`,
  and the tabs, their names and their rungs are the same underneath
  either way you look at them. With it off, the horizontal strip is
  exactly what it was.

  The switch is in Settings, under **A page a day, with time tabs down
  the side**, and it is off until you ask for it. On, the days stand in
  a narrow column on the left of the card (Today at the top, each row
  with the countdown of the page on it that runs out soonest), and the
  strip along the bottom is gone while they are there. Clicking a row
  goes to that day; clicking Today when nothing has been written yet
  starts today's page, which is the one click on the rail that makes
  anything. The rail is for getting about and nothing else: it will not
  rename a day, close one, hold its clock, shorten its countdown or let
  you drag one somewhere else, because a day is not a slot and the order
  of the days is not yours to shuffle. If it is holding pages back (live
  pages with nothing written on them, which get no day of their own), it
  says how many at the foot of the column and points at this
  toggle, rather than letting a full pad look broken.

  Beside that column the days read as one page torn along a
  perforation. Today is at the top and time runs downward: your writing
  from today, then a labelled tear, then yesterday's, and so on back
  through whatever is still alive, all in one scroll rather than one
  page at a time. The tear is drawn and never typed: nothing separating
  two days is a character in anybody's document, so scrolling past a day
  cannot change it. A second page written on the same day sits
  under a plain hairline rather than a tear, because that is one day's
  writing and not a jump in time. Beside each tear is the day's own
  gutter: what the page is called, how long it has left, and a
  right-click menu with rename, hold the clock, shorten the countdown and
  close, aimed at that page's own slot. That is where the four verbs the
  strip used to carry now live, which is also why a day holding two
  pages can still say which of them you meant. Clicking into an older
  day takes you there with the caret where you clicked. Only the day you
  are on can be typed into; the others are there to read. Opening the pad
  and every summon put you back on today, instantly and with nothing
  animating anywhere, and between those moments the scroll is yours,
  including when a new day arrives above what you are reading, which
  moves the page under you by exactly nothing. Long lines wrap while the
  mode is on, whatever ⌥Z last decided, and ⌥Z goes back to deciding it
  the moment the mode is off.

  Underneath, nothing about a page moved. The sealed file's format did
  not change by a byte, no new call was added to the seam, and the one
  editor the app has ever had is still the only thing on screen you can
  type into: it is carried between the days rather than rebuilt for
  them, so the caret, a half-finished input-method composition and each
  page's own undo history all survive crossing a tear, and ⌘Z after
  clicking into an older day rewrites that day and cannot reach the one
  above it. **What the mode deliberately does not do:** it will not
  reorder anything, it will not rename or close a day from the column
  beside it, it will not police one page per day, it will not create
  today's page for you, and it leaves no marker where a day whose page
  ran out used to be: the labels are relative, so the jump from -1d to
  -3d says it by itself.

- **The keyboard is a file now** (issue #76,
  `docs/development/about-the-keymap.md`). What each chord does used to
  be spelled in Swift, in two places, and moving one was a code change
  nobody could review as a list. It is now a bundled keymap in the Zed
  editor's format, read with the two JSON5 tolerances a hand written
  file cannot do without, comments and trailing commas, and the app
  installs what the file says. The bundled default reproduces exactly
  what the surface and the page have always answered, and a test holds
  the whole table still so an edit to the file has to change the table
  in the same commit. One behaviour did change, and for the better:
  caps lock no longer breaks ⇧⌘V or ⌥Z. The old code compared the
  event's whole device-independent flag set against the chord, so the
  caps lock bit riding along made both gestures dead until the light
  went off; the reading now takes the four modifiers a binding can name
  and drops the rest, caps lock, function and numeric pad alike.
  You can lay your own keymap over it at
  `~/Library/Application Support/com.onetimesecret.companion.backdrop/keymap.json`,
  where a chord you name wins and a chord you set to `null` goes away.
  Every binding is validated before it is installed: an unparseable
  chord, an unknown command or a context that does not exist costs that
  line and is written to the log, and a file that is wrong about its own
  shape is refused whole, leaving the bundled default standing. A typo
  in your keymap costs you your customisation, never your app. Shift is
  bindable over a letter (`cmd-shift-v`) and over a named key, and
  refused over anything else: `cmd-shift-1` would fire on one surface
  and be dead on the other, so it is refused out loud instead. The chord
  itself is not lost, only that spelling of it: write `cmd-!`, the glyph
  the shift produces, and it works on both.

- **A restore failure and a withheld save are now impossible to miss**
  (issue #49, ADR-0016 sections 2 and 7). When an existing state file
  refuses to open at launch, the session still gets its working page,
  but the surface now says what the log alone used to: a standing
  banner reports that nothing in this session is being saved, and
  carries the one recovery action, a discard that deletes the
  unreadable file, re-grants the save licence and reseals the current
  session in its place. The unreadable ledger gets its own standing
  line pointing at the Settings clear that already existed. The header
  gained a small persistence word, saving, saved or save failed, driven
  by the write lifecycle itself, and quit now warns in two shapes
  rather than one: a refused write, as before, and a settled flush over
  a withheld licence when the session accumulated work since launch,
  so accepting the loss is always a choice made knowingly. A failed
  restore still never overwrites the prior file; the discard is the
  user's instruction, never the app's.
- **⌘S force-saves, on the same status surface** (issue #46, ADR-0016
  section 2). It calls the same synchronous write the debounce timer
  and the quit path already made, so a press asks for nothing the write
  lifecycle does not already do on its own, only for it now rather than
  at the debounce's far end. A press with nothing owed still lands on
  "saved", which is the reassurance the shortcut exists to give; a
  press over a withheld save licence leaves that banner in place rather
  than showing a contradictory "saved".
- **Every recovery case now has something that asserts it, and a
  document that says which** (issue #48, on the seams from issue #53,
  ADR-0016 section 10). `docs/qa/recovery-matrix.md` is the index: one
  row per lifecycle case, the guarantee with the ADR section that
  decides it, the Rust and Swift tests that assert it, the hardware
  procedure for what no test can reach, its owner, and when it last
  ran. Filling it in took the coverage with it. `PageModel` gained
  injectable seams for its state directory, its client and its save
  debounce (#53), which is what let the Swift suite drive a real sealed
  file at last: the quit flush is now pinned to a write the debounce
  still holds, a genuinely refused write and the window it opens are
  exercised rather than assumed, a damaged snapshot is distinguished
  from an unavailable key, every mutation site is asserted to arm a
  write, and the bundle-identifier guards that keep a dev rebuild off
  the installed copy's state are reachable by a test for the first
  time. Building a model without those seams is now refused outright
  under the test runner, since the unseamed construction resolves to the
  installed app's own pages, ledger and Keychain items. CI gained the
  packaged plist's sudden-termination key, the
  test-util seams on macOS, and a release packaging job, so the checks
  that used to run only when a human packaged a release run on every
  change. Two procedures that ADR-0016 named but nobody had written,
  force termination and the clock stepped back, now exist with owners
  and dated Results tables, and the runbook they sit beside gained an
  owner per section and somewhere to record a result.

### Changed

- **Two routes and a restored page read against its own rung**
  (`companion-core` 0.13.0, `companion-ffi` 0.13.0). Minor on both,
  pre-1.0, and additive: what compiled against 0.12.0 still compiles.
  `companion_page_discard` and `companion_persist_rotate_and_save` are
  the two new routes. The entry below narrates them as part of the tab
  and page split they belong to, and they landed after the bump that
  entry names, so the bump for them belongs here. The core's restore
  side moved with them. A page that comes back from a sealed file has
  its remaining life read against its tab's rung, a restored hold is
  read against the ceiling the pause gesture itself imposes so a file
  cannot hand back a hold longer than a press could make, the key
  rotation trigger is pinned to the state the pad is in rather than the
  transition that reached it, and a content key half that was zeroed
  but whose unlink was refused counts as the forgetting it already is.
  An unavailable key travels the seam as itself rather than collapsing
  into a damaged snapshot, which is what lets the surface tell a
  missing key from a corrupt file in the banner it now raises (issue
  #49).

- **A tab outlives every page it holds, so an expiry empties a slot
  instead of closing it** (`companion-core` 0.12.0, `companion-ffi`
  0.12.0, ADR-0017). The strip stopped being nine deadlines: when a
  page's countdown reaches zero the page drops whole, sealed bytes
  zeroized as before, and the tab stays exactly where the user dragged
  it, keeping its name, its rung, its position and its place in the
  ⌘-number map. Selecting an empty tab, by click, by ⌘1 through ⌘9, by
  ⌥⌘←/→ or by Return, opens a fresh page into it at that tab's own
  rung. Nothing else mints: a page that expires under the cursor leaves
  an empty tab rather than a silent new countdown, and the morning
  after an overnight expiry the app opens on the strip the user left
  rather than on a page nobody asked for.

  The C ABI changes shape with the object graph, which is what the
  minor bump prices. The routes divide into tab addressed
  (`companion_tab_new`, `_open_page`, `_close`, `_move`, `_set_title`,
  `_set_rung`, `_cycle_rung`, `_pause_press`, `companion_tabs_json`)
  and page addressed (the sealing, document, meta, blocks and promotion
  routes, unchanged). The summaries move from
  `companion_sheets_json` to `companion_tabs_json`, one entry per slot
  rather than per live page, and each carries `has_page` and both ids:
  the tab's `id`, which the keyboard and the selection address, and
  `page_id`, which the document routes and the shell's per-page text
  storage and undo stacks are keyed by, null when the slot is empty.
  Neither id can do the other's job, and the shell's maps are keyed by
  page identity so a reused tab cannot hand its next page a dead one's
  undo stack, which is how a zeroized chip's glyph would come back
  under ⌘Z (ADR-0009).

  Emptying the pad became two questions and `companion_store_emptiness`
  answers both in one call, because the shell may derive neither. No
  tab holding a page is a key rotation trigger and therefore a security
  decision (ADR-0016 section 6); no tabs remaining is the only
  condition that drops `state.sealed`, which now carries tab names,
  rungs and strip order. A strip of empty slots is resealed rather than
  unlinked, so emptying the pad writes a file where it used to remove
  one.

  Each question has its own write. `companion_persist_rotate_and_save`,
  which arrived in 0.13.0, takes the first: when the last page expires
  and tabs remain, both content key halves are rotated and the surviving
  names, rungs and order are resealed under new ones, so every
  ciphertext generation the pages lived in, the unlinked ones included,
  stops being decryptable at that moment. `companion_persist_erase`
  keeps the second and still drops the file when no tabs are left. A
  rotation that finds a file half it cannot even zero cancels the write
  and says so rather than sealing a fresh generation under a key that
  may still open every old one; a half that was zeroed but whose unlink
  was refused is already a forgetting, so the reseal proceeds and a
  false from the call means only that the new write did not land. What this costs is a window between the
  erase and the write in which the strip exists only in memory: a crash
  inside it loses the tab names, rungs and order, and nothing else,
  because there is no page content left in the file by then.

  The strip's gestures follow the slot's state. A double-click on a slot
  whose page expired mints a page with its first tap and does not hold
  that page's clock with its second, so the user who double-clicks an
  empty slot gets a page counting down rather than a page already
  frozen. The tab menu's hold item is disabled where there is no clock
  to hold, and its rung item says it shortens the next page's countdown
  when the slot holds no page, which is what it does.

  Burning the local copy after a promotion stopped taking the slot with
  it. `companion_page_discard`, also 0.13.0, is page addressed where
  close is tab addressed: it entombs the page, records the same
  discard, and leaves the slot standing, named and empty, the way an
  expiry leaves one. An explicit close and the cap are still the only
  two things that end a tab.

  A name is the user's or the tab has none. `Tab.name` is set only by
  the rename gesture, capped at 80 characters as before, and never
  derived: the label resolves to the typed name, else the live page's
  derived title, else `MMDD-HHmm` from the tab's own creation stamp, so
  an expiry falls the label back a step instead of freezing a string
  the app invented onto a durable object. The residual exposure is
  unchanged in kind and longer in life: a secret typed into the rename
  field now lives as long as the tab, and the prompt says so.

- **A superseded ledger file is dropped on first launch instead of
  refusing forever** (`companion-core` 0.11.0, `companion-ffi` 0.11.1,
  ADR-0016 section 9, closes issue #61). The ledger's envelope and key
  did not change at the break below, so an `OTSLEDR1` file opened like
  a current one and was refused one layer down, inside the core, which
  left it on disk withholding the ledger licence on every launch until
  the user found Clear in Settings. The audit trail silently stopped
  recording, on every install that had ever written one. The core now
  names that refusal (`RestoreError::Superseded`, for the one entry of
  `SUPERSEDED_LEDGER_MAGICS`) and the seam erases the file with the
  same zero, truncate, sync, unlink discipline as a superseded
  `state.sealed`, so the probe finds no file and the session records a
  fresh trail. The ledger key is not rotated and nothing is written
  about the records dropped. `OTSLEDR0` and every other unknown payload
  are still refused and left where they lie.

- **Staged content survives a restart, and the sealed envelope breaks
  once to make that true** (`companion-ffi` 0.11.0, ADR-0016, closes
  issue #51). Accepting a system update used to cost the user
  everything on the pad, which is the report that opened the milestone.
  The content key's second half moves out of `_CS_DARWIN_USER_TEMP_DIR`,
  which macOS clears at boot, and into the state directory beside
  `state.sealed` at mode 0600, where it inherits that directory's
  `.noindex` naming and its exclusion from Time Machine; its name stops
  folding `kern.bootsessionuuid` and the derivation is otherwise
  untouched, so two form factors still land on two different files. The
  envelope goes `OTSSEAL2` to `OTSSEAL3` and its header goes from
  `magic ‖ boot_uuid ‖ wall_ms ‖ mono_ns` to `magic ‖ sealed_wall_ms`.
  The whole header is the AEAD's associated data, so every existing
  `state.sealed` fails authentication: there is no migration, none is
  possible, and the loss is announced in `DOGFOOD.md` the way the
  previous break was. A file carrying the one superseded magic is
  erased with the full discipline and the save licence granted, so the
  first launch after the update does not present as an install that has
  permanently stopped saving; `OTSSEAL1` and anything else are still
  refused and left where they lie, because disposal is a promise about
  this app's own past output.

  Time away is now the wall-clock gap between the sealed stamp and the
  restore, which is the one interval no running process was there to
  observe; every interval a session does observe stays on the
  sleep-inclusive monotonic clock. The monotonic stamp had to leave the
  header for a reason worth stating: two readings of that clock are
  comparable only inside one boot session, so after a restart the
  subtraction underflowed, charged `u64::MAX` milliseconds away, and
  drained every countdown the instant the surface opened, while
  reporting success. A clock stepped backwards now freezes a countdown
  for the length of the gap and can never rewind one, which ADR-0016
  section 4 prices and accepts.

  What the two halves buy shrinks, and is stated rather than carried
  forward: with both halves durable the split is an ACL gate and a
  separation of backup domains, and it bounds nothing in time.
  Crypto-erasure stops being a scheduled event and becomes the
  finishing step of a deletion the user asked for, so the halves rotate
  when the content file is dropped, which today means when the pad goes
  empty. A page expiring beside pages that remain rotates nothing and
  cannot: the file is re-sealed under the same halves, because the
  survivors are in it.

  Rotation itself changed shape. It erases the file half, found by
  scanning the state directory for its filename prefix, with the same
  zero, truncate, sync, unlink discipline the ciphertext gets, and then
  deletes the Keychain item for hygiene. It no longer reads the
  Keychain at all: the read was the call that can raise the ACL prompt,
  on the quit path and under a background debounce, which is where
  ADR-0004 says a prompt has no business being, and a Keychain that
  would not answer that read used to skip the erase entirely and leave
  both halves alive. Since both halves are needed to derive the key,
  erasing the file half is the whole of the forgetting, and a refused
  Keychain delete now leaves an item that opens nothing rather than a
  live key. A file half that cannot be erased cancels the drop: the
  sealed file stays, the shell is told the write failed, and the retry
  comes back to it, rather than the ciphertext being unlinked while the
  half that opens it sits beside it. Whether a drop rotates is decided
  from the path, its name first and its envelope magic second, never
  from which caller asked, because the same entry point drops the
  ledger file on a user's Clear and that gesture asked nothing about
  pages.

  Launch also sweeps the stranded `*.tmp` generations a death mid-write
  leaves behind: they hold whole sealed generations and whole key
  halves, and nothing ever clears the state directory.

  Issue #51 is closed by deletion rather than by repair. A transient
  `sysctlbyname` failure substituted a per-process sentinel that no
  file could match, so the live session's own valid file read as
  another boot session's and was rotated and erased; the defect was
  that "fail closed" had been written as "destroy the input". The arm
  that did the destroying no longer exists, and nothing in the restore
  path deletes a file it could not open.

### Fixed

- **Markdown inside a fenced code block is inert** (issue #75). The page
  read every line on its own, so a `# comment` pasted inside a fence
  rendered at heading weight with its hashes dimmed, which reads as the
  app misunderstanding the code rather than styling the page. The
  restyle pass now carries a fence scanner down the whole page, because
  a fence is the one piece of markup whose meaning is not local: after
  an opening rule every line is literally what was typed, hashes,
  dashes and stars included, until a rule of the same character and at
  least the same length closes the block. The fence's own lines are
  dimmed the way a heading's hashes are and the block takes a faint
  wash, so code reads as code while the bytes of the page still never
  change, which is the display only, markup preserving rule the
  headings already followed. An unterminated fence holds its lines to
  the end of the page rather than guessing, an inline code span opens
  nothing, and the first line below the closing rule is prose again.
- **⌘Tab back lands where the user is, not on Desktop 1** (issue #74,
  ADR-0019). The resting surface claimed no place on Spaces other than
  the one it was created on, and the window server switches desktops to
  reveal an app's windows when the app is activated, so every activation
  carried the user home to Desktop 1. Every posture now claims every
  desktop, and holds that membership through raises, rests and the pin,
  which is also half of the flicker: changing the membership bits is
  what asks the window server to move a window between Spaces, and they
  changed on every raise, including the raise over an already raised
  surface that a ⌘Tab back performs. The composite collection behaviour
  is still rewritten when a stance changes, since what the window does
  once it is on a Space does vary by posture; it is the membership
  subset that is now constant, which is why the rewrite no longer asks
  for anything. The other half was the summon's order-out round
  trip, a literal blink, which a window present on every desktop no
  longer reaches on a return between desktops; it stays as a tested
  safety net, since being wrong about a window stranded off-Space would
  cost keystrokes, and it still fires from another app's full-screen
  Space, which an unpinned rest declines to join, where the blink is the
  card arriving where the user is. Settings and the About panel, the
  app's two ordinary windows, take `.moveToActiveSpace` for the same
  reason from the other side: each is built once and shown many times,
  so either used to anchor the app to the desktop it was first opened
  on. The app menu's About item is repointed at the same route the tray
  uses, since the one SwiftUI synthesizes goes straight to AppKit and
  the panel it puts up would carry no such bit. What is *not*
  fixed is dragging the card to another desktop by the screen edge, and
  ADR-0019 says why it will not be: the card's place is the app's own
  state clamped to the primary screen, the window server never sees a
  window drag, and a surface present on every desktop has nowhere else
  to be moved to. Whether any flicker survives, and of what shape, is
  for `docs/qa/verification-procedures/spaces-and-cmd-tab.md`, which
  names the remaining candidate and the change it would take.

- **A pinned card that cannot be seen no longer takes the click**
  (issue #73, ADR-0015). Pinned, with another app full screen on the
  active Space, the card was invisible and yet presses meant for that
  app landed in the pad and were acted on: the window server had kept
  the surface in the hit-test path without ever compositing it. The
  surface now follows the exposure the server reports, Space membership
  and occlusion, and refuses the mouse whenever either says it is out of
  sight, in every posture and either pin state. Whether that report is
  honest for a window held in the hit-test path without being composited
  is the question the hardware procedure exists to settle, and it is the
  same question as the one below. The rule is a one-way valve, so
  nothing here hands a click to the unpinned rest, which stays
  transparent by ADR-0015; and the reading is taken a turn after a
  stance is applied, where it may open the gate but not close it on a
  card the stance puts in front, since a raise outruns the occlusion
  state by a frame and a gate closed in that gap would pass the user's
  next click to the application underneath. A Space switch is read twice
  for the mirror-image reason: the answer given mid-transition describes
  the desktop being left, and a card present on every Space has no later
  edge to reopen a gate wrongly closed on it, so the prompt reading is
  taken as the guess it is and only the settled one may take the clicks
  off a raised card. That refusal has a price of its own: for the
  second or so before the settled reading lands, a raised card the
  server is not showing goes on taking presses aimed past it, which is
  the worse of the two faults by this code's own ranking. It is
  accepted because it ends of its own accord, while a gate wrongly shut
  has nothing that would ever reopen it. Every posture change, a stance
  applied and the pin toggled alike, takes a late reading of its own,
  because a card put in front while it was already wholly covered reads
  occluded before the change and occluded after it: no change is posted,
  no edge arrives, and without that reading the gate held open over a
  surface nobody can see would stay open for the life of the raise. A
  scheduled reading is asked again, when it fires, whether it still
  deserves the authority it was scheduled with: a desktop change while
  it waited puts it back inside a transition, where every reading is a
  guess and only the transition's own settled one decides. Waking the
  displays, returning from another user, and clearing the lock screen
  are read the same way a Space switch is, so a card does not come back
  from any of them refusing every click. The unlock comes off the
  distributed centre, because an ordinary lock switches no session and
  need not sleep the displays, so nothing the workspace publishes
  mentions it. The pinned rest also stopped carrying `.stationary`, a flag it had
  inherited from the wallpaper recipe the unpinned rest is built from,
  leaving the overlay recipe AppKit actually documents. Whether that
  second change makes the card visible over a full-screen Space is a
  question only hardware can answer, and
  `docs/qa/verification-procedures/pinned-over-fullscreen.md` is where
  it gets asked; the refusal to act on invisible presses holds either
  way.

- **A fast ledger round trip no longer strands the keyboard** (issue
  #23, ADR-0005, ADR-0006). Returning from the ledger rebuilds the
  editor the ledger stood in for, and the model hands the rebuilt
  editor the keys once it appears. It holds that editor weakly, and
  weak says whether the view still exists rather than whether it is
  still mounted: the editor torn out of the window on the way to the
  ledger keeps answering for as long as it takes the runtime to let go
  of it, which is at least the rest of the turn. A hand-off landing
  there settled on a view with no window, focused nothing, and stopped
  waiting for the editor that was genuinely on its way, so the surface
  came back from the ledger with the ember lit and the first keystroke
  beeping. The hand-off now accepts only an editor inside a window, and
  the teardown retires the model's handle on the way out, so a severed
  editor is never offered at all.

- **A page opened by selecting an empty slot now takes the keyboard**
  (issue #22, ADR-0005, ADR-0017). Clicking a slot whose page had
  expired, jumping to one with ⌘1 through ⌘9, or walking onto one with
  ⌥⌘←/→ opens a page into that slot, and the page arrived with nothing
  focused: the surface kept the keys, the ember stayed lit to promise
  that keystrokes would land, and every keystroke beeped against the
  window instead. These paths mint, and a mint rebuilds the mount
  rather than swapping a storage under the one persistent editor, since
  the empty state's catcher is a different view from the editor that
  replaces it and first responder leaves with the catcher. ⌥⌘N and the
  + tab already handed the keys on; the two paths the tab and page
  split added did not, and now do. A plain page to page switch still
  asks for nothing, because it keeps its editor and never lost focus,
  and an unkeyed surface still opens its page and still leaves the
  keyboard where the user put it: the law accepts keys an earlier
  deliberate act conferred and never seizes them.

- **The app's own menus no longer put the card away** (issue #41). A
  raised surface rests on any press the global mouse monitor sees, on
  the reasoning that a press the card's window never received belongs
  to somebody else. Menus broke that reasoning: they track in windows
  the window server owns, so clicking our own menu bar looked exactly
  like clicking into another application. The card fell to the desktop,
  the app deactivated, and the menu was torn down before an item could
  be chosen, which is why Edit then Find could never fire although ⌘F
  always did. Menu tracking sessions are now recorded as intervals on
  the same clock the press is stamped on
  (`NSEvent.timestamp` and `ProcessInfo.systemUptime` share a base) and
  each press is judged by its own moment, so the answer no longer
  depends on whether the menu happens to still be up when the deferred
  handler runs, which for a nested tracking loop it usually is not. The
  press that opens a menu arrives fractionally before the session it
  causes, so a short grace counts it as the opening press rather than as
  a dismissal. The observation covers every menu in the process, the
  main menu bar, the status item's menu and the chip context menu
  alike. A session whose end never posts expires after thirty seconds
  rather than claiming presses forever, since the record is fed by
  notifications that are assumed to come in pairs and an exception that
  never lapsed would silently retire the outside click rule for the rest
  of the session. Nothing else about the rule moves: a press in another
  application still rests the surface without being consumed, Esc still
  rests, the status item's left click still puts a keyed surface away,
  and Settings and About are still outside by this rule.

### Added

- **The shell's persistence lifecycle now runs in CI**
  (`companion_new_ephemeral`, companion-ffi 0.10.0): no Swift test had
  ever constructed a `PageModel`, let the save debounce fire, and read
  the sealed file back, because neither the state directory nor the
  credential store could be pointed anywhere but at the real ones.
  `PageModel.init` now takes a `Seams` struct gathering a state
  directory, a core client, and a debounce interval, each optional and
  resolving to exactly the shipping value when left nil, and the seam
  gained
  `companion_new_ephemeral`: a handle whose keys rest in process memory
  and die with it, shared by tag so a second handle can open what a
  first one sealed. The first integration test drives load, mutation,
  the real timer, and a relaunch inside a temporary directory it owns,
  and never touches the login Keychain. The seam sits behind the
  off-by-default `test-util` cargo feature (ADR-0018): the dev
  xcframework (`scripts/build-core.sh --test-util`) exports it for the
  Swift suite, release artifacts omit it, and the release packaging
  path checks the shipped binary's symbol table to prove it.

- **Find in the page (⌘F), and line wrapping you can turn off (⌥Z)**:
  the editor is an `NSTextView`, so the machine's own find machinery was
  already under it and switched off at one line. It is on now, as the
  docked find bar rather than the floating panel, with the standard Edit
  menu route the app had never asked for (`TextEditingCommands`) —
  without those items nothing sends `performFindPanelAction:` and ⌘F
  lands nowhere. Replacing cannot reach a sealed chip: the finder only
  replaces ranges it matched, and no search string can hold the
  attachment character a chip occupies. ⌘E is the one route that could,
  since it loads the selection rather than a match, and it refuses a
  selection holding a chip (ADR-0009: a chip leaves only by an act aimed
  at the chip). Wrapping is now a setting rather than a weld: ⌥Z flips
  it while you write, Settings holds the same switch, and the choice
  sticks across launches. Unwrapped, the page sizes itself to its
  longest line and scrolls sideways, with a width floor that keeps a
  page of short lines as wide as the card so a click beside the text
  still places a caret. ⌥Z is scoped to the page rather than claimed as
  a menu equivalent, because ⌥Z is a character the find bar and the
  Settings fields have every right to receive.

- **The core's refusals reach the unified log, so a launch you cannot
  reproduce still leaves a trail** (`companion_set_diagnostic_sink`,
  companion-ffi 0.8.0): the core wrote its persistence diagnostics to
  stderr, and an app macOS launches for you has no stderr, so every
  line written for whoever is debugging a failed launch was discarded
  before that launch happened. Reading them meant running the binary
  from a terminal, which is the one launch that reproduces least: a
  different keychain posture, a different environment, a different
  signature check from the launch that failed. The seam now takes a
  sink, the shell registers one before its first call into the core,
  and each line lands in the unified log under the `core` category
  beside the shell's own `persistence` trail. One registration covers
  the credentials crate's keychain tier notice too. With no sink
  registered the lines still go to stderr, so `cargo test` and a
  terminal launch read as they always did, and the shell's sink also
  echoes to stderr when there is a terminal attached. What crosses is
  metadata: which step refused and the backend's own error text, never
  ink, a chip, or key material. Logged `.public` for that reason, since
  a line redacted to `<private>` in the field is a line nobody can act
  on.

- **The screen-capture opt-out is reachable in a release build, by
  launch variable only**: the Settings switch that lifts the surface's
  `sharingType = .none` exclusion used to be compiled out of release
  entirely, which left the installed app impossible to screenshot for
  diagnosis. It now ships in every build, but a release build shows it
  only when the app was launched with `COMPANION_ALLOW_CAPTURE` set
  (`open --env COMPANION_ALLOW_CAPTURE=1 /Applications/OnetimePad.app`),
  which also seeds it on. An ordinary double-click of the installed app
  shows no such switch, and the controller installs no observer that
  could write `sharingType`, so the exclusion set at window creation
  holds for the life of the window. The opt-out is still never
  persisted and still fails closed at every launch, and the header's
  camera indicator now stands in release too, where the surface being
  screenshot-able matters most. The rule is a pure function on the two
  facts a launch knows, so the release branch is covered by tests from
  a debug binary.

- **A multi-line paste is one block, with one stamp above it
  (ADR-0013)**: text pasted with newlines inside it now lands as a
  single block rather than one block per line, so the page shows one
  `DDD HH:mm` label above the paste's first line instead of the same
  time repeated down its margin. A typed Enter still starts a new
  block, and so does a paste that ends on a newline, so what the reader
  types after a paste is stamped as their own. Nothing has to be told
  which gesture happened: an insert op carrying its own newlines is a
  paste, a typed newline arrives alone, and `BlockIndex::note_insert`
  reads exactly that. A block is therefore one or more paragraphs now,
  which moves the index's self-check from equality with the paragraph
  widths to coverage that ends on paragraph boundaries, gives the
  blocks JSON a `paragraphs` field (structure, not content: still no
  text, no sizes, no origin) for the editor to walk the page by, and
  puts the grouping in the snapshot, since a restore rebuilds the index
  from a document that knows only paragraphs. Persisted spans are
  refused whole unless they account for exactly the paragraphs the
  restored page has; a refusal, or a file written before this change,
  leaves the per-paragraph rebuild standing.

- **Created and modified render above each block (ADR-0013,
  editable-surface rule)**: the editor now shows a small `DDD HH:mm`
  label above every paragraph that has been committed, or
  `DDD HH:mm → DDD HH:mm` once a block has been edited past its first
  commit. A blank line is spacing rather than writing, so it shows no
  label and reserves no gap, and a page with room to breathe no longer
  stacks a column of repeated identical times down its margin. The
  label is a non-interactive subview drawn in the gap immediately
  above the block's own first line, measured from where its glyphs
  begin: a line fragment rect absorbs the space reserved above it, so
  measuring from there set the label down on the preceding
  paragraph's last line. Labels are repositioned by geometry on
  every layout pass with no core round trip, so a resize never
  re-queries the core; content changes still pull fresh stamps from
  `client.blocks(sheet:)`. The top block's gap comes from the text
  container inset instead, TextKit having no space before the first
  paragraph to reserve. This is a display
  instance of the editable-surface rule, not a new read surface: the
  label styles the text without touching how it edits, and origin
  never appears in it.

- **The document history is compacted at rung transitions (ADR-0013,
  stage 6)**: cycling or setting a page's rung, and topping up a
  pause, now run the compaction ceremony. Each block's derived
  provenance (created, modified, and the origin of the change that
  introduced its text) graduates into a materialized summary while the
  ops still exist to prove it; then the document is reborn from its
  live runs under a freshly minted peer identity and the trail behind
  the boundary is discarded. Deleted text, edit history, commit
  messages, and the old actor id do not survive the boundary, and
  tests byte-scan the new export to hold that claim. This is the right
  to erasure applied to the page's own memory: what was written here
  and thought better of is forgotten on the same clockwork that bounds
  every page, on schedule and without a new timer, and the actor
  identities on either side of a boundary cannot be linked across it.
  The materialized summaries persist in the sealed content file's
  reserved slot, keyed by block identity and validated on restore
  (anchors must still resolve, stamps are clamped to sane values)
  rather than trusted; origin URLs remain content, living in the
  sealed file only and never in the ledger. Chips and their sealed
  bytes pass through the ceremony untouched, and due pages refuse the
  gestures that trigger it, so compaction can never race a reap.

- **Blocks acquire identity and pastes acquire provenance (ADR-0013,
  stage 5)**: the core now maintains a per-sheet block index over the
  flat body, one record per paragraph, following Notion's convention
  under edits: a typed newline splits and the fragment holding the
  pre-split start keeps the paragraph's identity, deleting a separating
  newline merges and the absorbing paragraph keeps its name while the
  absorbed one dies. Anchors are stable document cursors re-taken after
  every settled mutation, with the first block anchored at the
  container start. Created and modified stamps are derived from the
  operation log rather than stored: earliest and latest change over a
  block's span, the newest change for the page, with commit merging
  disabled so every commit stays its own provenance unit. Two new read
  surfaces, `companion_sheet_meta_json` and
  `companion_sheet_blocks_json`, return identities and stamps only.
  Pastes now carry their origin: the pasteboard read captures the
  `public.url` flavor in the same core-side pass (the shell still never
  touches the board, ADR-0007 Amendment 1), and a URL-bearing seal
  persists `{"origin": url}` as its commit's message inside the
  encrypted snapshot. Origin URLs are content and appear in no JSON
  surface, no summary, and no ledger record; restore rebuilds the block
  index from the imported document and recomputes anchors rather than
  trusting anything persisted.

- **Edits cross the seam as range operations, not snapshots (ADR-0013,
  stage 3)**: `companion_sheet_apply_ops` carries an ordered JSON batch
  of `ins`/`del`/`chip` operations, every position and length a UTF-16
  code unit, parsed reject-whole and applied atomically or not at all;
  `companion_sheet_sync_document` survives as the recovery path that
  restates a page whole. All three seal gestures (sealed paste, drop
  to seal, and the seal-selection ⌘↩) now hand the core the selection
  range they replace, and the core deletes that range, stands the
  chip's sentinel, and commits inside the one locked seal call, so the
  seal and the deletion cannot come apart. Shell-side the editor stops
  mirroring the whole document per keystroke: the coordinator listens
  to `NSTextStorage` edits and emits one replace per edit, marked text
  is gated so an abandoned IME composition produces zero operations,
  programmatic projection writes are suppressed behind a guard, and a
  rejected batch recovers by one legacy mirror plus a cleared undo
  stack, never a crash. Undo stays `NSTextView` native; an undo that
  would resurrect a dead chip is refused by the core and the glyph is
  stripped silently, because undo never un-seals (ADR-0009).

- **The sheet body becomes an operation-logged document (ADR-0013,
  accepted)**: the core adopts Loro behind a crate-private
  `SheetDocument` wrapper in `crates/core/src/document.rs`, the one
  module allowed to speak the library's API. One text container holds
  the body; a chip is a sentinel character carrying its identity as a
  non-expanding mark; every offset at the wrapper's edge is a UTF-16
  code unit, so Loro's unicode-scalar-indexed methods never see wire
  offsets. Commits record timestamps and persisted messages, snapshots
  export into zeroizing buffers, and a spike test guards the
  shallow-export truth the compaction ceremony will depend on: a
  StateOnly export sheds deleted text but keeps the authoring peer id,
  so compaction must mint a fresh document rather than trust the blob.
  The dependency is pinned exactly (`=1.13.9`) because loro declares
  no MSRV while our toolchain is pinned in `rust-toolchain.toml`;
  bumps stay deliberate, reviewed events. Default features stay off,
  keeping the unused counter container and logging out of the build.

- **A second form factor: the background surface (exploration)**.
  `CompanionBackdrop`, a sibling executable target over the same Rust
  core (ADR-0010: form factors are sibling shell targets; the panel
  app's sources are untouched). An ambient pane resting at the window
  server's desktop level (above the wallpaper, below the icons and
  every normal window, mouse-transparent, refusing the keyboard by
  construction), raised to a floating, non-activating editor by
  ⌃⌥Space, the menu-bar item, ⌘Tab, or the Dock icon (the backdrop is
  a regular app by an argued spec amendment: alternating between the
  work window and the surface is the core loop, and ⌘Tab is the
  reflex), and rested again with Esc. A summon focuses before it
  dismisses (raised-but-keyboard-less re-keys rather than rests), and
  a raised surface joins the user's active Space, full-screen apps
  included: a surface that holds the keyboard is visible where the
  user is looking. v0 is one page
  of visible ink on the standard TTL ladder: no chips, no persistence,
  no Keychain, no network; exploration targets start with less
  authority, and each arrives only by an argued spec amendment.
  Capture exclusion is doubly load-bearing on an always-visible
  surface and holds in both stances; frugality holds by cadence (a
  30 s repaint at rest, 1 Hz only while raised; expiry stays
  scheduled, never polled). Spec:
  docs/spec/feature/background-surface/ (with the underlying macOS
  research as research.md); packaging: scripts/build-backdrop.sh →
  dist/CompanionBackdrop.app (`com.onetimesecret.companion.backdrop`).

- **Pages persist across relaunch, sealed at rest**: quit is the one
  moment state touches disk. `applicationShouldTerminate` asks the core
  to snapshot the whole store (live pages, chips, the ledger, clocks)
  into an exact-size zeroizing buffer (`companion-core::persist`,
  format `OTSSNAP1`), seal it with ChaCha20-Poly1305 under a 32-byte
  key resting in the Keychain (`state-key`, same service as the API
  token), and write only ciphertext to
  `Application Support/CompanionApp/state.sealed` (0600, atomic
  temp-file rename). The window's first reveal is the mirror, not
  launch, so starting at login never raises a Keychain prompt for a
  window nobody asked to see: decrypt, restore, then drain the
  wall-clock time the app was closed. Countdowns keep ticking while
  away, holds absorb time-away first, and pages that didn't survive
  the gap expire into the ledger before the window opens. A session
  whose window never showed never saves, so it cannot overwrite
  yesterday's file with an empty store. The file is useless without
  the Keychain item and vice versa;
  deleting either forgets everything. Tampering anywhere in the file
  (or a bare bit flip) fails authentication and reads as a fresh
  start. New seam: `companion_persist_save` / `companion_persist_restore`
  / `companion_sheet_document_json` (the last replays a restored
  page's ink and chip faces so the editor rebuilds pixel-identical;
  sealed bytes still never cross into Swift).

- **The shell packages as a real .app bundle**: `scripts/build-app.sh`
  assembles `dist/CompanionApp.app` (bundle id
  `com.onetimesecret.companion`, reserved in docs/spec/07) from the
  Swift build, stamps the bundle version from `crates/ffi`'s
  `CARGO_PKG_VERSION` (the same string the About panel shows), and
  ad-hoc signs it (`CODESIGN_IDENTITY` overrides). A bare `swift run`
  binary has no `CFBundleIdentifier`, so TCC grants and per-app
  screen-capture pickers cannot address it; the bundle makes the app a
  citizen of the permission system. `LSUIElement` in the checked-in
  `shell/Info.plist` declares the accessory nature at the bundle level.
  CI assembles the bundle in the shell lane so the packaging cannot rot.

- **ADR-0004 accepted: Keychain prompt timing**. The ACL prompt may
  appear only when a secret is used (a promotion reading the token),
  never for a presence check. `CredentialStore::exists` answers "is a
  token stored?" via an attributes-only Keychain query that never
  decrypts; `has_token` in the connection JSON now means stored, not
  readable, so launch and Settings no longer greet the user with a
  Keychain prompt. See docs/adr/0004-keychain-prompt-timing.md.
- **Clear stored token** in Settings → Connection: removes the token
  from the Keychain through the existing seam (empty token → delete),
  behind an inline confirm, the destructive-act guard the rest of the
  surface uses.
- **The promotion flow** (issue #16, docs/spec/04): the exit ramp, and
  the app's only network action. Two affordances: **↗** on a chip's
  hover actions and **↗ page** in the footer, both opening an inline,
  in-place confirmation (never a modal) with the destination named, the
  TTL seeded from the page's remaining time snapped *down* the ladder,
  and optional passphrase/recipient; the network boundary is the one
  confirming click. On success the share link is on the clipboard
  (written core-side, transient-marked), only the receipt id stays on
  the chip, and the confirmation offers **Burn local copy** (a chip
  leaves the document and zeroizes; a page closes into the ledger).
  Failure is inline with retry; content never leaves the sheet.
  - **The seam stays lawful**: `companion_chip_promote` /
    `companion_sheet_promote` move the sealed bytes core → `ots-client`
    → transport directly; they never enter Swift. Page promotion
    refuses image chips (the v3 payload is text-shaped, open question
    №3). The core mutex is released for the network round-trip, so a
    slow server never blocks a summon; both routes (and the Settings
    test) block their own thread and are called off the main actor.
  - **Connection config** (`companion_connection_configure` /
    `_json` / `_test`): server URL (refused unless `https://`, the
    TLS-only boundary enforced at config, not the socket), share
    domain, org `extid` as non-secret config; the **API token goes
    straight through the seam to the Keychain**
    (`companion-credentials`) and is never retained in config, echoed
    back in any JSON, or readable from the Settings UI again. Auth is
    Basic (extid + token) when configured, the guest conceal route
    otherwise; promotion works with zero setup against the default
    server.
  - **Settings → Connection** (right-click the menu-bar item): server
    URL, share domain, extid, a write-only token field, and a test
    button (`GET /api/v3/status`). Unlike the main window, Settings
    activates normally: deliberate act, needs the keyboard.
  - Tested sans-network: the conceal call is generic over the
    transport, so Rust unit tests drive it with a mock (auth route
    selection, guest fallback, TTL snapping, error shaping) and the
    Swift contract test covers config round-trip and offline refusals;
    CI never opens a socket, and the seam tests never write a real
    Keychain.

### Changed

- **Every repeated record in the two sealed files states its own length,
  and both formats break once to get there** (`companion-core` 0.10.0,
  issue #54, ADR-0016 section 9). The records were positional: a reader
  that met a field it did not know could not step over it, so every
  field added later cost a version byte, and a version byte costs
  whoever is holding staged content. Four record kinds now write their
  own byte length in front of their fields, and a reader takes the
  fields it knows and then reaches the next record by that length
  instead of by wherever its own field walk stopped. The four are the
  page record, the chip records inside it, the materialized block
  record, and the ledger record. Chips were taken in deliberately, so
  the module carries one encoding rule rather than two and a later
  per-chip field costs nothing either. A file written by a build that
  added a trailing field still reads here, minus the field this build
  has never heard of, and one test per record kind holds that. The rule
  buys that and no more: a field that moved, changed width or changed
  meaning still costs a new magic, and so does anything outside a
  record, meaning the magics, the counts, and the sections that trail a
  record list.

  **Two losses, taken once.** The content snapshot's magic goes
  `OTSSNAP3` to `OTSSNAP4`. That is the break ADR-0016 and ADR-0017 had
  already scheduled and #54 simply took it first, so it costs one break
  and not two; there is no v3 reader and no downgrade writer, and pages
  staged by an earlier build are gone. The ledger is a second loss and a
  new one. It has its own envelope and its own long-lived key, so it
  would have come through the content break untouched, and framing its
  records is what takes it: `OTSLEDR1` goes to `OTSLEDR2` and the
  retained audit trail, the capped titles and the event records back to
  the ninety day window, is destroyed here, once. The first launch after
  this update drops the old ledger file and starts a new trail; see the
  `OTSLEDR1` entry above. Pages are not involved in it.

- **A third double-click releases the hold, so the pause is reversible**
  (`companion-core` 0.9.0, docs/spec/04). The gesture held a page's
  clock for an hour, then topped the hold up to 24 hours, and then had
  nowhere left to go: every further double-click bought another day and
  nothing gave one back. It reads as a toggle and behaved as a ratchet,
  so a stray double-click on a held tab extended a page's life by a day
  with no way to undo it, and the context menu could only offer to top
  the hold up again. The press after the top-up now releases the hold:
  the countdown resumes from exactly where it froze, and the held span
  lands in `total_held` exactly as a lapse would leave it — the two ways
  a hold can end are indistinguishable afterwards, which is what keeps
  the release from being a life extension in disguise. Re-topping-up
  costs two presses (hold, then top up), which is the price of the
  reversibility; the 24-hour ceiling per press is unchanged, so
  docs/spec/06 Q8 is unaffected.

  The tier is on the tab, since the tab is where all three presses
  happen: a held page carries a chip reading ⏸ and the span the last
  press bought, `1h` or `24h`. The pause mark leads because `24h` is
  also a rung label and the chip is about the hold, not the countdown.
  The gauge's dash grows longer when a hold is topped up as well (7/2
  rather than 3/2, the same language it already speaks for urgency),
  which is what carries the tier on the page's own gauge where no tab
  is in view; the tooltip and the context menu name the next press in
  words ("Release the hold", "Top the hold up to 24h"). The summary JSON
  gains `hold_topped_up` (`companion-ffi` 0.9.0) and the snapshot gains
  a second held-clock tag, since a hold that came back from a relaunch
  as a first hold would answer the release with another 24 hours; an
  older build refuses the newer snapshot rather than misreading it.

- **Clicking the countdown shortens it, one rung at a time**
  (`companion-core` 0.7.0, docs/spec/06 Q1 answered). The TTL wheel
  used to step up the ladder and wrap `7d → 1h`, which put a
  168-hour-to-1-hour drop under a single stray click on deliberately
  staged content, and made the backdrop's 7d default the worst place
  to click. The click now steps one rung shorter, `7d → 3d → 24h → 8h
  → 3h → 1h`, wrapping back to `7d` at the bottom. The wheel is still
  one affordance and the wrap survives; it now sits at the end where a
  single click costs nothing, and reaching the most precarious rung is
  five deliberate clicks. `Ttl::next`/`Ttl::prev` are renamed
  `Ttl::longer`/`Ttl::shorter`, so the direction is named by what it
  does to the page's life rather than by array order.
  `companion_sheet_cycle_rung()` keeps its signature and its rung
  codes; only the rung it returns changes.

- **The sealed content file carries the Loro document, and the format
  break is clean** (`companion-core` 0.4.0, ADR-0013 stage 4). The
  plaintext content snapshot bumps its magic to `OTSSNAP3`: each sheet
  keeps its identity, title, rung, clock and chip records exactly as
  v2 wrote them, and replaces the segments section with the sheet's
  full Loro snapshot blob, history and tombstones included, plus an
  empty length-prefixed materialized-metadata slot the compaction
  ceremony (stage 6) will fill without a v4. The blob is exported once
  per sheet into a zeroizing buffer both write passes copy from, and
  on restore it is imported into a fresh document whose chip marks
  must match the chip records one to one; a dangling mark, an orphan
  record or a duplicate rejects the whole snapshot with the store
  untouched. There is deliberately no v2 reader and no downgrade
  writer: v1, v2 and unknown magics all refuse as unknown format, so
  existing dogfood state files will not load after this change. The
  ledger format `OTSLEDR1` is untouched, and the blob, tombstones and
  peer identity included, never reaches it.
  (`companion-core` 0.3.0, ADR-0013). Every sheet now owns a
  `SheetDocument`, and the `segments` list demotes to a cached
  projection rebuilt from the document's runs after every mutation, so
  the existing readers (title derivation, page payloads, the persist
  format, the document JSON at the seam) keep their shape unchanged.
  Edits gain an operation path: `SheetStore::apply_ops` takes a batch
  of `EditOp`s (insert, delete, chip placement, every offset a UTF-16
  code unit count), validates the whole batch against a simulated
  intra-batch state so the shell's coalesced edits (a delete and
  insert at one position, a delete spanning a chip followed by its
  re-insert) validate, rejects atomically when any op misses, commits
  once per batch, and reaps chips whose sentinels are gone with the
  same `Discarded` record the snapshot path writes. `sync_document`
  survives as a transitional wipe-and-retype adapter through which
  provenance means nothing, kept as the recovery route; restore
  rebuilds each page's document from the decoded segments.
- **The dev-seed shim is gone from the core** (`companion-ffi` 0.3.0).
  The off-by-default `dev-scaffolding` cargo feature, the
  `companion_dev_seed_pasteboard` entry point behind it, and the
  `COMPANION_DEV_SCAFFOLDING` block in the packaged header are all
  removed. Real pasteboard ingest landed long ago and the rev C
  surfaces seal what you type, so nothing has called the plaintext
  shim in a while; what the feature still bought was a flag someone
  could turn back on. `scripts/build-core.sh` now takes no arguments
  and rejects any it is handed, and CI calls it bare.
- **The keychain access group follows the bundle id**.
  `scripts/Companion.entitlements` is a template rather than a
  finished file: `@BUNDLE_IDENTIFIER@` is filled in at sign time from
  the assembled bundle's own `CFBundleIdentifier`, read back after the
  debug lane has applied its `.debug` suffix. The hardcoded
  `com.onetimesecret.companion` had been putting the panel, the
  backdrop and both debug variants into one group, and a shared group
  is a shared keychain, which is the separation ADR-0010 rests on.
  There are four ids to authorize now, so a development profile has to
  be minted against a wildcard App ID; scripts/local.env.example says
  why rather than treating the wildcard as a convenience.
- **`scripts/quit-app.sh` knows both apps**: no argument quits every
  running instance of CompanionApp and CompanionBackdrop, and one name
  quits just that one. It asks AppleScript at the running copy's
  bundle path rather than at the app's name, because the backdrop's
  bundle name is OnetimePad and `tell application "CompanionBackdrop"`
  asks LaunchServices to resolve a name that no longer exists. A bare
  `swift run` binary has no bundle to address, so the script says the
  polite path is unavailable instead of implying it tried, and an
  osascript failure is reported as itself so a denied Automation
  consent is not blamed on the app.
- **`scripts/build-app.sh` builds only its own product**, passing
  `--product CompanionApp`, so packaging the panel no longer compiles
  the backdrop's sources first. `scripts/build-backdrop.sh` already
  scoped its build this way.
- **`FormFactor.displayName` is gone.** Nothing read it: what an app
  calls itself to the user is a per-target `productName`, kept next to
  the `CFBundleName` it has to agree with, and the shared model never
  needed a second copy of it.

- **The background surface is called OnetimePad**. The user-facing
  name only: `CFBundleName` and `CFBundleDisplayName`, the card's own
  header, the About panel, the tray menu and the status item's
  accessibility label. The bundle id, executable, SwiftPM target and
  `.app` filename all stay `CompanionBackdrop`, because the id is what
  the Keychain service, the state directory and every TCC grant key
  on; renaming it would strand a user's stored pages and re-prompt for
  every permission the app has been given. The panel app keeps its own
  name.
- **The shell is CompanionApp now**: package, product, executable,
  targets, source and test directories, and every doc reference;
  renamed wholesale, no aliases kept. A companion app named
  CompanionApp, in the proud naming tradition of *Scary Movie*.
- **The menu-bar glyph is a template image now**: the maruhi drawn
  monochrome (㊙ with the text-presentation selector) onto an
  `isTemplate` image, so the system tints it like every other status
  item: dark in light mode, light in dark mode, dimmed when inactive.
  The colour emoji title never got any of that.
- **The About panel earns its keep**: the colour ㊙️ at icon size
  (colour is the point there; the menu bar keeps the template), the
  app's name, and the core's version via `companion_version()`. A bare
  SwiftPM executable has no Info.plist, so the standard panel had
  nothing to say before.
- **Tabs drag to reorder**: grab a page tab and slide it, spreadsheet
  style; the ⌘-number map follows the visible order. The previous
  item-provider drag never started inside a non-activating panel, so
  the affordance is now a plain mouse drag with midpoint-based
  reordering.
- **⌘W closes what's showing**, per the macOS convention: a page goes
  to rest in the ledger; the ledger view steps aside.
- **Transient notices dismiss themselves**: "the link is on the
  clipboard" and friends clear after a few seconds instead of lingering
  until the next action; a newer notice restarts the clock.

### Fixed

- **Pages survive a quit again: key material is read from both
  keychains, not just the one this build cannot write to**: an
  installed build with no `keychain-access-groups` entitlement wrote
  its key halves to the login keychain (the documented ADR-0012
  fallback) while reading them back from the data protection keychain,
  where nothing was ever written. The split came from the entitlement
  probe, which reads an account that is never written: a read of a
  missing item answers `errSecItemNotFound` whether or not the
  keychain is reachable, so only writes ever demoted, and the probe
  reported a tier the build did not have. Every restore then failed on
  a key half that read as absent, and a restore that fails over an
  existing state file withholds the save licence for the session, so
  the app quietly stopped writing state at all. The visible symptom
  was an app that opened on an empty page with a date-based title
  after every launch, reinstall, or rebuild, having lost everything
  typed into the session before. Reads and existence checks now fall
  through to the login keychain before concluding absence, and deletes
  reach both keychains so a rotation cannot report a forgetting that
  left a live half behind in the other one.

- **The persistence path says why it refused**: a state file that will
  not open, a key half that will not load, and a key rotation the
  keychain refused were all silent, and all three produce the same
  symptom of an app that has stopped remembering. Each now names
  itself, in metadata only: which step refused, and what the
  consequence is for the session. They reach the unified log under the
  `core` category through the sink above, beside the shell's own
  `persistence` trail (see DOGFOOD.md).

- **A click beside the raised card reaches the app you clicked**: the
  raised surface used to span the whole screen and catch outside
  clicks with a transparent pane, which rested the card but ate the
  press: the app under the pointer never activated, so the keyboard
  fell back to whatever happened to be frontmost and the next
  keystrokes landed somewhere the user was not looking. The raise now
  hugs the card the way a pinned rest already did, and resting on an
  outside click is a passive global mouse monitor's job: it observes
  the press and consumes nothing, so the click goes on to its target
  and macOS activates that app in the ordinary way. Since the raised
  window is now the card itself, the header drag and the eight resize
  grips measure against the screen rather than a SwiftUI coordinate
  space that would travel with the card, and the card's live position
  moves the window instead of redrawing inside a stationary pane.
- **The window no longer hovers over fullscreen apps, pinned or not**.
  `.canJoinAllSpaces` turned out to be the culprit: for an accessory
  app it joins fullscreen Spaces too, and AppKit has no combination
  that means "every desktop, but never fullscreen". The window now
  lives on one Space and comes when called (`.moveToActiveSpace`):
  summoning brings it to the desktop you're on, switching Spaces
  leaves it where it was, and a fullscreen Space only ever sees it by
  deliberate summon (menu-bar click or ⌥Space), never by drifting in.
  The pin still decides only the altitude among ordinary windows:
  pinned floats above them, unpinned is a normal window others can
  cover.
- **⌥-click on the menu-bar item reliably opens Settings**: the check
  reads the live hardware modifier state instead of the delivered
  event's flags, which the status bar can misreport (and which go stale
  under an accessibility press).
- **The blank strip above the header is gone**: the transparent
  titlebar's safe-area inset was doubling the top bar; the hosting view
  now ignores it.
- **The ledger tab toggles**: click ◌ to visit the ledger, click it
  again to return to the page; before, it only opened.
- **A tab's hover ✕ no longer shifts the title**: the close button
  keeps its space reserved and reveals by opacity, the browser-tab
  convention, instead of inserting itself on hover.
- **Esc no longer blinks the window**: handing the keyboard back used
  to reorder the window out and front again (a non-activating panel
  has no "resign key" verb), a round trip that showed as a visible
  hide-and-reappear over a fullscreen Space. Key status now passes
  through an invisible one-pixel relay panel that takes the keys and
  immediately orders out: the window server returns the keyboard to
  the active app while the window never leaves the screen.
- **The sealed-state temp file can no longer be raced or redirected**:
  saves used to write through a predictable `state.sealed.tmp` opened
  create-and-truncate, which a crash leftover, a planted symlink, or a
  second running instance could subvert. Each save now writes through
  its own random-named temp file opened create-new (never following
  what's already there), and cleans up after a failed rename as well
  as a failed write.
- **A state file that fails to restore is no longer overwritten at
  quit**: a denied or missing Keychain key used to hand the session a
  fresh page and, with it, the licence to save that empty store over
  yesterday's file. The save licence is now withheld when an existing
  file refuses to restore: the session still gets a working page, but
  the old sealed state stays on disk for a later, luckier launch.
- **A refused quit-save is no longer silent**: the one write of the
  session used to discard its result, exiting cleanly with nothing
  saved. The save now happens in `applicationShouldTerminate`, where a
  refusal logs itself and asks (Quit Anyway or Cancel) before the
  session's pages are lost.

## [0.1.0] - 2026-07-13

The first tagged milestone. The rev C surface ran its first live
hardware session on real hardware: summoned, typed on, sealed, and
(confirmed by the session itself) excluded from capture (screenshots of
the window come out blank; the session had to be photographed with a
phone). Rough edges noted for follow-up; the core loop works.

### Added

- **The rev C window** (issue #12, docs/spec/04): the shell sheds the
  spike's transitional docked list and becomes the window the spec
  describes: movable by its title bar, resizable from any edge,
  double-click-stretch to full working height, frame persisted across
  summons, still a non-activating accessory excluded from capture. One
  page shows at a time in an `NSTextView`-backed **ink editor**: typed
  ink, sealed chips as atomic inline attachments (arrows step over, one
  ⌫ removes whole; the sync mirror zeroizes core-side), markdown
  headings styled display-only with the markup kept visible. Bottom-edge
  Excel-anchored tabs carry live titles and per-tab gauges (dashed when
  held, hatched ember in the last hour), pause on double-click, close on
  ✕, drag to reorder; the dashed ◌ tab is the ledger: dead pages as
  dimmed read-only ink, tombstones struck through and labelled
  "zeroized". The keyboard map is complete: ⌥Space summon (Carbon
  hotkey, the app's one global claim), ⌘1–9, ⌘0, ⌥⌘←/→, ⌥⌘N, ⇧⌘V, ⌘↩,
  Esc hands the keyboard back (an ember border shows while the page
  holds it). Focus law unchanged: keys by deliberate act only.
- **Drop-to-seal is boundary-lawful**: `companion_sheet_seal_from_drag`
  reads the **drag pasteboard** core-side (`NSPasteboard(name: .drag)`,
  a new `SystemPasteboard::drag()` binding) while the drop handler is
  still inside the drag session; the shell hands over only the page id,
  no dropped byte transits Swift, the general clipboard is untouched.
  This closes the drag-ingest decision the hardware runbook had left
  open; what remains there is live-drag verification, not design.
- **The Rust↔Swift JSON contract test** (deferred from PR #11):
  `CoreContractTests` drives the live core through `CompanionClient`
  (sheet lifecycle, seal, document sync, title derivation, the pause,
  the ledger tombstone, the cap refusal), so a drifting field name
  fails in CI instead of rendering as an empty window. Deliberately
  avoids the pasteboard routes, so tests never touch a developer's
  real clipboard.

### Changed

- **The core speaks interaction-model rev C** (issue #10): sheets of
  ink and sealed chips replace the SleeperCell stack, and **detection
  is deleted outright**: `detect.rs`, `secret_shape`, `detected_as`,
  the concealed-hint plumbing, and every reference; masking is by
  gesture, never by content and never by origin. The new model:
  - `SheetStore`: up to **9 pages** (the keyboard wall; was 12 cells),
    refuse-don't-evict unchanged; drag-to-reorder; one **pausable
    countdown per page** (double-click holds 1h, again tops up to 24h
    from now, never cumulative; a hold freezes remaining life and
    lapses on its own, and cumulative held time is tracked for open
    question №8). Chips carry the **mechanical excerpt**, computed once
    at seal time (single line `min(24, ⌊n/3⌋)` split 60/40 head–tail;
    multi-line first line ≤17 chars + line count; images metadata-only:
    magic-byte sniff, never a decode, and excluded from `mlock` per
    doc 05). Tab titles derive core-side from the first typed line,
    heading markup stripped.
  - **The ledger**: dead pages (expired or closed) rest in a
    session-bound, read-only, newest-dozen record: dimmed ink plus
    chip tombstones (excerpt only; sealed bytes zeroized at death,
    exactly as before). Empty pages leave no record.
  - **The synced document**: the shell's editor owns live ink and
    mirrors its structure (`ink`/`chip` runs) into the core, which is
    authoritative for chip liveness: a snapshot that omits a chip
    zeroizes it (⌫ removes whole; undo never un-seals).
  - **The seam is rev C**: `companion_sheet_*` (new/close/move/
    cycle_rung/set_rung/pause_press/sync_document), the two seal routes
    (`companion_sheet_seal_from_pasteboard`, ⇧⌘V: the core reads the
    board itself; and `companion_sheet_seal_text`, ⌘↩: the seam's one
    deliberate plaintext-**in** entry, where the argument is visible
    ink the shell already holds and the gesture moves it into custody),
    `companion_chip_copy_out` (always transient + concealed) /
    `companion_chip_delete`, `companion_sheets_json` /
    `companion_ledger_json`, and `companion_next_event_ms`, which folds
    **pause-hold lapses** into the one armed timer (no polling,
    unchanged). `companion_ingest_pasteboard` and the
    `companion_cell_*` family are gone: a plain ⌘V is visible ink and
    never reaches the core. The boundary law is recorded in its rev C
    hard form (sealed bytes never reach the UI layer at all), and the
    boundary test now seals through every route and asserts the bytes
    appear in no output.
  - The shell is ported as a **transitional surface** (still the docked
    panel, now listing pages with their gauges, pause state, and the
    seal gestures); the real rev C window is the next slice. The demo
    REPL walks the full rev C lifecycle headless. ADR-0001's
    "rendering vs residence" consequence is annotated as superseded by
    the hard law; the hardware runbook carries a rev C note.
  - An adversarial review pass hardened the slice: `SystemClock` now
    anchors to a **sleep-inclusive OS clock** (`CLOCK_MONOTONIC` on
    Darwin, `CLOCK_BOOTTIME` on Linux), so countdowns and pause-holds
    keep draining while the machine sleeps; an 8h page no longer gains
    a weekend of life from a closed lid. Cycling or setting the rung of
    a due-but-unreaped page now refuses instead of resurrecting it
    (zero means zeroized, matching the pause's own refusal); the sealed
    paste zeroizes its transit copy of the clipboard string; page
    payloads preallocate exactly, so reallocation strands no sealed
    bytes in freed heap; and the Swift ⌘↩ wrapper refuses text with an
    interior NUL rather than sealing a silent truncation.
- **The shell graduated**: `spikes/swift-panel` is now `shell/`, per
  ADR-0002's consequences; the Swift package is unchanged apart from
  the xcframework path and its comments losing the spike framing.
  `spikes/tauri-panel` (and `spikes/` itself) is retired; the ADR
  preserves its measurements. CI gains a `shell (macos)` lane that
  builds the seam's universal xcframework (`scripts/build-core.sh
  --dev-scaffolding`) and runs `swift build && swift test`, the first
  time the Swift package is compiled by CI rather than by hand.

- **ADR-0002 accepted: the shell is Swift/AppKit** over the Rust core,
  across the C-ABI seam (ADR-0003). Decided on the two-way spike's
  evidence: native non-activating/drag semantics with no workarounds and
  22 MB idle vs. Tauri's bypassed visibility API, JS-side drag handling,
  and 61.6 MB (already over budget at 0 cells). The VoiceOver hardware
  runbook (docs/hardware-verification.md §B) stays open as verification;
  its failure modes are recorded as eject triggers, not gates.
  Consequences: swift-panel graduates to `shell/`, tauri-panel retires.

### Added

- Real pasteboard **ingest** across the C-ABI seam (issue #4): on macOS
  `companion_new` now binds the real `NSPasteboard.general` via the
  `SystemPasteboard` adapter (WS2) instead of the in-process stand-in, so
  the core reads the system clipboard itself: the shell asks, the core
  takes. Off macOS and in the FFI unit tests the in-process
  `MemoryPasteboard` stays, chosen once in `companion_new` behind an
  internal `Board` enum and invisible above the seam; the tests build a
  seeded in-memory handle directly so they never read or clobber a real
  clipboard. Verified end to end: a token-shaped string placed on the real
  clipboard with `pbcopy` is ingested, detected ("GitHub token"), masked
  in the summary JSON (`••••`), and the raw secret never appears; the
  boundary law holds through the live path. The `.xcframework` packaging
  and `swift build`/`swift test` remain to be run on a machine with full
  Xcode (this environment has Command Line Tools only); the Rust core
  builds clean in release for both Apple arches. See
  docs/adr/0003-binding-mechanism.md for the seam's binding decision.
- `spikes/tauri-panel`: the Tauri arm of the ADR-0002 two-way spike.
  Rust-native (links `companion-core`/`companion-pasteboard` directly, no
  C-ABI seam needed), non-activating edge-docked panel achieved by
  bypassing Tauri's own `show()`/`set_visible()` (which unconditionally
  calls `makeKeyAndOrderFront`) with a direct objc2 side-door onto the
  raw `NSWindow`; text-drag receiving via the WebKit/HTML5 DnD layer
  (Tauri's native `DragDropEvent` is file-paths-only); scheduled expiry
  via `tauri::async_runtime` + `tokio::time::sleep`; menu-bar tray icon.
  Verified non-activating via `lsappinfo` polling; measured 61.6 MB
  resident / 0.0% idle CPU across all 4 processes (main + 3 WebKit XPC
  helpers), already over docs/spec/05's 60 MB Tauri budget at 0 cells.
  See docs/adr/0002-shell-selection.md for the full comparison against
  swift-panel (issue #3, workstream 1).
- `companion-transport`: `UreqTransport`, the one concrete HTTP
  transport this workspace ships for `ots-client` (`ureq` + `rustls`,
  default-features off, no gzip/cookies/charset). Refuses a non-`https`
  URL before any socket opens (the network boundary, docs/spec/05).
  `ots-client` itself stays sans-IO; this crate is the integrator's one
  choice, made once, here.
- `companion-core`'s demo gains `send`/`login`/`logout`: `send` performs
  a real `POST` through `UreqTransport` (authenticated with Keychain-or-dev
  credentials from `companion-credentials`, set via `login`, when
  available; the guest route otherwise), lands the returned share link
  on the clipboard (`SystemPasteboard` on macOS), and retains only the
  receipt id on the cell. `promote` is unchanged (still a dry run);
  `send` is the live path. Verified live against the guest route on
  `eu.onetimesecret.com`: a real secret was concealed, the share link
  round-tripped onto the real clipboard, only the receipt id was kept
  (issue #3, workstream 3; closes the promotion loop end to end).
- `companion-pasteboard`: the real `NSPasteboard` adapter
  (`SystemPasteboard`, macOS-gated, `objc2`/`objc2-app-kit`), meeting the
  hygiene contract already tested against `MemoryPasteboard`: outbound
  writes carry `TransientType` always and `ConcealedType` when secret,
  inbound `ConcealedType` is reported, clear-after-copy is
  change-count-guarded. Verified against the real system clipboard: both
  marks land as written and are visible to any pasteboard observer
  (issue #3, workstream 2).
- Harvested from the parallel skeleton prototype (PR #5), adapted to
  this crate layout:
  - `companion-core`: `SecretBuffer` (page-locked via `mlock`, zeroized
    on drop, compile-time proofs it cannot be cloned, logged, or
    serialized) now backs every cell's content; `harden_process()`
    disables core dumps before any secret is held.
  - `companion-credentials`: the `CredentialStore` contract with a
    macOS Keychain implementation (`security-framework`, cfg-gated) and
    an in-memory dev fallback. The API token never lives in config.
  - `companion-ffi`: the C-ABI seam for a non-Rust shell: opaque
    handles and non-secret JSON only, with a test asserting plaintext
    never crosses. Adds what the prototype's seam lacked: copy-out (the
    core writes the pasteboard itself, transient/concealed-marked, with
    a change-count-guarded clear) and `next_deadline_ms` so the shell
    arms one timer instead of polling. The temporary plaintext-ingest
    dev shim is gated behind an off-by-default `dev-scaffolding`
    feature, so a normal build exports no entry point that moves
    plaintext across the seam. `scripts/build-core.sh` packages it as a
    universal `.xcframework` (`--dev-scaffolding` opts the spike in).
  - `spikes/swift-panel`: the Swift/AppKit arm of the ADR-0002 spike.
    Menu-bar panel, non-activating edge-docked `NSPanel`
    (`sharingType = .none`), draining ring with Reduce Motion fallback
    and VoiceOver text equivalents, drag receiving via
    `.onDrop(of: [.plainText])`, bound to the seam through
    `PanelController` as the app's real entry point. Verified
    non-activating and measured (~22 MB idle, 0.0% CPU) via `lsappinfo`
    polling and `footprint`/`top`; see docs/adr/0002-shell-selection.md.
    VoiceOver operability itself awaits the issue #4 hardware session.
  - CI: a full-history gitleaks secret-scan job. The binary is
    version-pinned and checksum-verified; intentionally fake test
    fixtures are allowlisted by exact fingerprint in `.gitleaksignore`,
    and PAT-shaped samples are assembled at runtime so no token-shaped
    literal sits in the source text.
- Repository skeleton per the spec's initialization prescription
  (docs/spec/07): Cargo workspace, CI lanes, ADR practice, governance
  files.
- `companion-core`: zeroizing cell store, TTL ladder
  (1h → 3h → 8h → 24h → 3d → 7d, default 8h), scheduled expiry (no
  polling), cap-refusal at twelve cells, conservative secret-shape
  heuristics, lifecycle states.
- `ots-client`: sans-IO client for the Onetime Secret v3 API: conceal
  (authenticated + guest routes), auth as a swappable strategy (HTTP
  Basic now, PASETO later), downward TTL snapping, share-link assembly.
- `companion-pasteboard`: the pasteboard hygiene contract
  (`ConcealedType`, transient marking, change-count-guarded
  clear-after-copy) with an in-memory implementation for tests, the
  demo, and non-macOS hosts.
- A headless demo of the SleeperCell lifecycle:
  `cargo run -p companion-core --example demo`.
