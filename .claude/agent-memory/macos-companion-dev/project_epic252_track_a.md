---
name: epic252-track-a
description: Epic 252 on feature/editing-seals, Track A (#248, #250, #249) and the phase 4 close at app 0.35.0 on 2026-10-14; where the SwiftUI fields' state lives, the held notice #245 must reuse, where the owed hand checks are written, what the close left open, that sync carries no sealed object, where the editor strips U+FFFC, why a drag test must never reach drop to seal, why the next event asks is_due, the find, name, Share and Writing Tools gates, why a ballot always advances with an empty frame for a page it cannot give out, why a board's text inherits the attachment before it, where a page's own U+FFFC leaves outside undo, the look up and speech gates, why a trap under xctest hangs, and AskingTextView with Law 0001's AppKit text routes table, where every new AppKit reader or rewrite is sorted
metadata:
  type: project
---

Track A of epic 252 landed on feature/editing-seals on 2026-10-13, app
0.27.0 (#248), 0.27.1 (#250) and 0.28.0 (#249), then 0.28.1 and 0.28.2
for review fixes; shell only.

- The gutter's day and time are `DayHeaderView.Words`; a typed name sits
  between them and is part of the time's seat, so a click on the name or
  the time opens the field (Law 0007 review amendment). The label is the
  tab's name and outlives its page (ADR-0017), so a page minted into a
  named slot reads it; that is recorded, not a bug.
- `beginRename` must never remember a field editor as the responder to
  give the keys back to (`keyboardToReturn`): that editor belongs to the
  field the click is about to end.
- SwiftUI rename fields cannot be driven under xctest, so their state
  lives in plain types the views call: `TabRename.Field` (strip and slot
  rail), `PadRename` (pad cell) and `PadPickerRoutes` (whether the list,
  the create sheet or a cell's field is up). Test those, not the views.
- `PageModel.holdNotice` / `releaseNotice` keep a refusal in the line
  under the page: a flash stands in front of it for its dwell and gives
  it back, and every model clear goes through `clearNotice`, which
  returns to it. Never write `notice = nil` inside PageModel. #245's
  sealed name field needs exactly this; do not build a second mechanism.
  A field holds its refusal through `PageModel.HeldRefusal`, which
  re-holds only on new words via `holdNotice(_:replacing:)`, so a
  keystroke never cuts a flash in front (fixed 2026-10-13, app 0.31.5).
- The pad list's popover height is `PadListLayout.maxHeight`, fed by
  `PageStatusStack`'s top through `keepsThePadListAboveTheNoticeLine()`
  on both roots; a root without it leaves the list 620 points tall.
- A pad cell's ending passes its pad id to `PadRename.keep`, because the
  cell a field left loses focus after the field has moved to another.

- The phase's last issues, #170 and #247 (the sealed fragment and the
  name and note in it), finished on the same branch at app 0.34.0; see
  [[issue170-247-sealed-fragment-core]]. Every new editor route stands
  aside on `answersChords` while a rename field or the note holds the
  keys (ADR-0046). None of the epic's hand procedures (rename in place,
  sealed zones and note, sealed fragment) has been run.

- Phase 4 (security review F1 to F3, critic W01 to W26) closed on
  2026-10-14 at app 0.35.0, companion-core 0.32.0, companion-ffi 0.40.0,
  with ADR-0052 to ADR-0054. Every unrun hand check in a law row reads
  `owed: hand check, [procedure]`; keep that form. Still open at the
  close: the Linux CI lane was audited by reading only (ring needs a
  Linux C compiler here; `cargo clippy --target x86_64-unknown-linux-gnu
  -p companion-core` passes), the yank defect in [[w03-removal-routes]],
  the sync controller's `onRemoteChange` mark is counted by no suite,
  and the PR body owes "closes #170, #240 to #252".
- Phase 5 unit 1 (2026-10-14): sync carries no sealed object. No
  envelope holds one and `apply_remote_update` refuses a batch standing
  a sentinel the page does not own, so a page holding an object stops
  reaching its peers (client protocol 10.31, Law 0001 sync move
  amendment); the `TwoPages` tests in store.rs pin it and must change
  when objects travel. The ADR-0052 gate now covers sync:
  `export_document_updates`, `perform_ceremony` and `ceremony_due` read
  through `readable_sheet`, the sweep withdraws a due or gone page's
  unsealed ops, a device stays out of a ballot for its due page. The
  seam's store runs on the system clock and a restore (`age_by`) drops a
  deferred ceremony, so test a due page's ceremony in the core.
- Phase 5 unit 2 (2026-10-14): no U+FFFC enters a page or a note as
  ink. The shell strips it in `Coordinator.textStorage(_:willProcessEditing:)`,
  the only hook that sees attributes: `shouldChangeTextInRanges` gets
  plain strings, and ⌃T carries a real `ChipAttachment` through it, so
  stripping there removed the object. AppKit puts the caret right after
  a willProcessEditing strip on its own. The core refuses ops and the
  recovery mirror holding it, strips pasted envelopes, and files keep
  it. Object routes' expired line asks `pageHolding(chip)` after the
  settle (`settleRefusal(chip:otherwise:)`).
- Phase 5 unit 3 (2026-10-14): a drop names a `draggingSource` only
  inside this app, so `dropRoute` sends any drag with one to its
  ordinary route and never `.seal`; `.seal` makes the core read
  `SystemPasteboard::drag()` even under the memory pasteboard seam, so a
  drag test must check `dropRoute == .ink` before any
  `performDragOperation`. `SealedFragment.anyBuildsItem` knows the
  release and debug type for the own copy check and the drop; reading
  an envelope stays per build. ADR-0055 records the handle's open hand.
  `citecheck.py` resolves relative citations such as
  `(../../shell/...swift:N)` since phase 6 unit 2.
- Phase 6 unit 1 (2026-10-14): `Sheet::next_event` answers now once
  `Sheet::is_due` holds, since the shell settles only when
  `nextEventMs() == 0`; never restate the due predicate in a scheduler.
  `hold_register` rounds its frozen life up (`millis_up`);
  `expiry_policy` still truncates, which only shortens. `enrol_page`
  refuses a due page, and a restore resets every page's ceremony to
  immediate, so a test that ages enrolled pages enrols before `age_by`
  and again after. `staged_envelopes` in the sync_driver tests opens a
  publish as a peer would. Unswept ink of a due page is held by the
  core's export gate; the sweep's own check is a second gate. The auto
  mode classifier refused a mutation of `export_document_updates`'s
  gate but allowed ones in sync_driver.rs.
- Phase 6 unit 2 (2026-10-14): Use Selection for Find, Copy name and
  the name field's editor (`SealedNameTextView`) ask the page first;
  pages, notes and name fields offer no Share… or Writing Tools
  (`TextOffers`), files keep both. There is no Use Selection for
  Replace: `NSTextFinder.Action` has no such case and SwiftUI's
  MainMenu.loctable lists none. A field editor's
  `setUpFieldEditorAttributes` resets `writingToolsBehavior` to
  `.limited`, so refuse after super. AppKit builds Share… under xctest,
  so a file view is the control; `InkTextView.coordinator` is weak,
  so keep a test's coordinator alive or `menu(for:)` runs without one.
  A field editor writes only `NSStringPboardType`, so `.string` writes
  fail. `isolatedModel`'s ambient board is the general one; copy tests
  belong in `SealedFragmentEditorTests`' unique board fixture. An
  object refusal asks `chipStands` (ungated) before and after the
  settle. Still ungated and undecided: Look Up, Translate and Speech
  on the page's text menu, whose titles carry the selection.
- Phase 7 unit 1 (2026-10-14): a confirmed ballot always advances the
  chain; `SyncSession::commit_advance` is the one path for ballot and
  solo, and only the store's rebuild decides whether the frame holds
  the page. A page the store will not rebuild (due, gone, not
  deferred) seals an empty frame, because if every member reads the
  last accept past the deadline and none PUTs a frame, the relay stays
  an epoch behind and 409s every publish (client protocol 4.4). Solo
  keeps the store's refusal. `JoinedBallot` in the sync_session tests
  builds two devices with both accepts on the stream. Phase 8 closed
  the seal refusal: `KeyFrame` carries its sealing epoch,
  `sync_driver::stage_frame` drops a stale one, solo reports no commit,
  and `GopKeyChain::refuse_next_seal` (cfg(test)) reaches the refusal.
  Still open, same class: a resent in-flight batch is labelled with the
  chain's epoch over blobs sealed at the old one (client protocol
  10.13), and after a solo seal refusal the device stands an epoch
  ahead of the relay until a rejoin, which is not built. A peer's unmarked U+FFFC imports as ink; the shell
  must take it out as an edit, but `sync_document` (the recovery
  mirror) refuses such ink, and undoing the removal would stand it
  again. ADR-0025's delivery note keeps line citations current by
  digits plus a decision history entry, not by rewriting its text.
- Phase 7 unit 2 (2026-10-14): a board's plain text (a service's
  answer, a drop, the tests' paste) goes through
  `readSelection(from:type:)`, which writes the storage directly, not
  the view's `replaceCharacters`, and the new characters inherit the
  attributes of the one before them; AppKit strips `.attachment` from
  non U+FFFC characters only after `willProcessEditing`. So
  `strayObjectCharacters` drops a U+FFFC whose attachment run holds
  other characters, an object's second index, and every U+FFFC while
  `readingBoard` runs. Typing attributes never carry `.attachment`.
  `runs(of:)` and `editOps` give one position per character, so a
  doubled face breaks parity. A page's own U+FFFC (peer, earlier
  build) leaves at `PageModel.pageRuns` through
  `companion_sheet_take_out_object_characters`, committed under
  `UNRECORDED_ORIGIN`, which the Loro undo manager excludes; the core
  now has a `test-util` feature (its first seam,
  `ink_below_the_guard`). A peer's change never restates a mounted
  storage (onRemoteChange only refreshes), so the take out waits for
  the next restate. Look Up and Translate are `_rvMenuItemAction`
  items; the file menu control in the test guards that predicate.
  ⌃⌘D is a system shortcut no test can send; its route is a hand
  check, read from the page standing aside under its note. Never run a
  mutation that lets a speech or look up gate pass: it speaks or looks
  up on the machine running the suite.
- Phase 8 unit 2 (2026-10-14): every AppKit reader of a page's, a
  note's or a name's text asks `AskingTextView.mayReadOut`
  (TextOffers.swift), the base of InkTextView and SealedNameTextView;
  add a new one there and a row to Law 0001's AppKit text routes
  table. Probed facts: continuous spelling and grammar, text
  replacement (on by default on a page), smart quotes and Substitutions'
  replace actions all enter `checkText(in:types:options:)`;
  `checkSpelling:` does not; `complete:` reaches
  `completions(forPartialWordRange:)`; `updateCandidates` runs on every
  selection change even with no Touch Bar, so never ask there. Over a
  misspelled word AppKit's menu adds `_changeSpellingFromMenu:`,
  `_invokeProofreadingFeedbackThumbsUp:`/`Down:`,
  `_ignoreSpellingFromMenu:`, `_learnSpellingFromMenu:` and
  `_searchWithGoogleFromMenu:`. AppleSpell treats U+FFFC as a word
  boundary. `replaceQuotesInSelection:` changes nothing under xctest
  even on a plain view; use dashes. Rewrites (`rewritingInk`) make the
  delegate refuse every ask while AppKit's action runs and make them
  after, stretch by stretch; `asOneEdit` holds an action's ops and its
  textDidChange for one batch. AppKit's uppercaseWord: over several
  ranges asks per range in order. Never let `complete:` or
  `orderFrontSharingServicePicker:` run in a test: their windows would
  hold the run loop. `storage(for:)` now takes a peer's U+FFFC out of a
  kept storage and restates it; a peer's change still never restates a
  mounted one.
- Test traps: any Swift trap (assert, precondition) under xctest stops
  the process at `_assertionFailure` with no output until killed;
  `assertProjectionParity` now writes its line and exits instead, so a
  parity break ends the run at once. Run other mutation checks under
  `timeout`. `ageForTests`
  re-mints the store and drops every undo stack; reach a refused note
  batch on a due page through a stand in client. The Edit tool turns a
  JSON style `\uXXXX` in its input into the literal character; write
  `\u{FFFC}` with braces or interpolate a char.
- An earlier re-aim sweep shifted document.rs citations by a fixed
  offset without reading them back, so five were wrong for weeks. Read
  each cited line back against what it read when its doc line was
  written (git blame the doc line, git show that commit's file).

**Why:** these are the non-obvious seams; the focus, selection and
popover behaviour of the SwiftUI fields was reasoned, not seen.

**How to apply:** before touching any rename field, reuse these types.
The owed hardware checks are written in
docs/qa/verification-procedures/rename-in-place.md, which Law 0007's
rows cite; add a check there rather than writing "checked by hand" in a
law row. Version bumps for shell only work go in the plist, not
crates/ffi, whatever a workflow prompt says ([[two-version-numbers]]).
