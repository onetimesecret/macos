# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

  The tier is visible without being literal: a topped-up hold draws the
  gauge's dash longer (7/2 rather than 3/2), the same language the gauge
  already speaks for urgency, and the tab's tooltip and context menu
  name it in words ("Release the hold", "Top the hold up to 24h") so the
  gesture always says what the next double-click does. The summary JSON
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
