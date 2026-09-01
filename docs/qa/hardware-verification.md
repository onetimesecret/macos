# Hardware-session runbook — rev C (the "for realsies" session)

The part only a person at the machine can run. Everything below assumes
the rev C window (issue #12, merged) over the rev C core (issue #10):
sheets of ink and sealed chips, gesture-only sealing, the pausable
countdown, bottom tabs, the ledger. Do it on the Mac you'll ship
against.

**Suspended while issue #78 stands.** Four affordances are built and
deliberately not drawn: the ledger's entry points (its tab, ⌘0, and the
Settings clear), the ↗ page button, the resize glyph in the bottom
corner, and the ember dot in the header. Every check below that reaches
the ledger through the UI, and the one that presses ⌘0, cannot be run as
written; bind `ledger::Show` in your own keymap if you need to reach the
ledger for a check, or skip it and say so in the session notes. What the
resize glyph advertised is still true, so the resize checks stand as
they are.

Two prior results stand and are not re-run here:

- **Headless ingest proof (rev A, 2026-07-09):** the core bound to the
  real `NSPasteboard.general` ingested a `pbcopy`'d token and the raw
  bytes never crossed the seam. The mechanism is unchanged in rev C;
  §A verifies it through the live gestures instead.
- **Spike measurements (ADR-0002):** 22 MB resident / 0.0% idle CPU,
  non-activating confirmed via `lsappinfo` polling. §E re-measures
  against the rev C window with pages loaded.

## Build + run

1. **Full Xcode active:** `xcode-select -p` prints an
   `Xcode*.app/Contents/Developer` path; if not,
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
2. `./scripts/build-core.sh` → `bindings/CompanionCore.xcframework`
   (it takes no arguments; rev C has no dev-seed path).
3. `cd shell && swift build && swift test && swift run CompanionApp`
4. The window summons with **⌥Space** or from the menu-bar item.

## §0 — The prototype walk

**Owner:** delano.

Open `docs/archive/airlock-prototype/Airlock Prototype.dc.html` in a
browser
beside the app. The
prototype is the script; the app is under test. Walk every gesture in
both and note any divergence in feel, not just function:

- [ ] ⌥Space summons; ⌥Space again dismisses; Esc hands keys back
      without hiding the window.
- [ ] ⌘V pastes visible ink, exactly like any text editor.
- [ ] ⇧⌘V pastes sealed: a chip appears, masked, with the mechanical
      excerpt — never the bytes.
- [ ] Type a line, ⌘↩ seals it; select a fragment, ⌘↩ seals just the
      selection.
- [ ] ⌫ on a chip removes it (and zeroizes core-side — no visible
      check here; the contract test covers it).
- [ ] ⌘N new page; ⌥⌘←/→ walk pages; ⌘1–⌘9 jump in visible tab
      order; ⌘0 opens the ledger.
- [ ] Drag a tab to reorder; confirm the ⌘-number map follows the new
      visible order.
- [ ] ✕ closes a page; it appears in the ledger as dimmed ink.
- [ ] Markdown: `#`/`##`/`###` headings render styled with markup
      visible; the bytes on the page never change.

## §A — Boundary-lawful ingest, live

**Owner:** delano.

- [ ] **Cross-app text drag** (the one open drag verification): drag
      selected text from another app onto the page. It seals; the
      *general clipboard is untouched* (`pbpaste` before/after
      matches). The core read the drag pasteboard itself —
      `companion_sheet_seal_from_drag` — no byte transited Swift.
- [ ] **Image drag:** drop an image; confirm the app's behaviour
      (accept-and-seal or refuse) matches the spec's current text-first
      posture, and nothing crashes or renders raw data.
- [ ] **Copy-out:** copy from a chip; paste elsewhere and confirm the
      round-trip; confirm a clipboard manager (if present) shows the
      transient/concealed marking or skips it.
- [ ] ⇧⌘V with a secret on the clipboard: the chip's excerpt is
      mechanical (head…tail) — never enough to reconstruct the value.

## §B — VoiceOver operability (THE go/no-go)

**Owner:** delano.

The premise under test: native AppKit gives first-class VoiceOver for
free. Failure that native APIs cannot reach is an ADR-0002 **eject
trigger**. VoiceOver on (⌘F5); keyboard only.

- [ ] Summon the window with ⌥Space under VO; the window is reachable.
- [ ] Focus a **tab**: hear its title and its remaining life in words
      (the `spoken_remaining` string — "about 7 hours remaining"), not
      a colour or a gauge.
- [ ] Focus the **countdown**: hear the same in words; its hint offers
      cycling the ladder.
- [ ] Cycle the rung from the keyboard; hear the new life announced.
- [ ] Focus a **sealed chip** in the page: it announces as sealed with
      its excerpt — never reads sealed content (there is none to read).
- [ ] Open the **ledger** (⌘0) under VO; entries read as dimmed/dead
      pages with counts.
- [ ] Close a page from the keyboard under VO.
- [ ] Throughout: the **frontmost app never changes** (`lsappinfo
      front` before/after). The focus law is an accessibility rule,
      not etiquette.
- [ ] Reduce Motion on: remaining life still legible without the
      gauge animation.

## §C — Keychain round-trip (`companion-credentials`)

**Owner:** delano.

- [ ] Store a credential via the Keychain path, read it back, delete
      it — on a real login keychain, confirming prompt/ACL behaviour.
      (CI uses the in-memory fallback; this is the only place the real
      path runs.)

## §D — Rev C time, felt

**Owner:** delano.

- [ ] **The pause:** double-click a tab's gauge — holds 1h; again —
      tops up to 24h; a third — releases, and the countdown resumes
      where it froze. Confirm an unreleased hold also lapses back into
      countdown. The tab's chip must track the tier (⏸1h → ⏸24h →
      gone) without shoving the title around, and the bounded top-up
      should still feel right (docs/spec/06 q8).
- [ ] **Countdown through a closed lid:** note a page's remaining
      time, sleep the Mac past a meaningful chunk of it, wake.
      Remaining time must reflect wall-clock sleep (the core clocks
      sleep-monotonic); an expiry that came due during sleep fires on
      wake and the page lands in the ledger.
- [ ] **The keyboard wall:** fill to 9 pages; the 10th is refused, not
      evicted. Wall or nudge (docs/spec/06 q4)?
- [ ] **Default rung:** does 8h feel right as the landing rung when
      you cycle (docs/spec/06 q1)?
- [ ] **Expiry, watched:** let one short-rung page expire while the
      window is open. Silent removal to the ledger — is silence the
      right promise (docs/spec/06)?

## §E — Frugality, re-measured

**Owner:** delano.

The budget is < 25 MB resident idle **with pages loaded**, near-zero
idle CPU; 22 MB at 0 cells (rev A panel) is the baseline. Materially
over and unrecoverable is an ADR-0002 eject trigger.

- [ ] With 5 pages of mixed ink and chips: `footprint` / `top`
      resident memory, window hidden, after a minute idle.
- [ ] Same at the 9-page wall.
- [ ] Idle CPU ~0.0% with the window hidden (the 1 Hz redraw must not
      run while not visible).

## §F: Focus law for the #22 regressions and the invariants

**Owner:** delano.

Issue #22 was a freshly conjured page that mounted with nothing
focused: the window held the keys, yet the first keystroke beeped
instead of typing. The unit tests fix which page ends up selected; the
focus itself is AppKit first-responder timing across a torn-down and
rebuilt editor, and only a person at the machine can see it land. Do
this on the bundled app. Unless a step says otherwise the window is
**key** (summon with ⌥Space first). The expected result for every item
in §F.1 and §F.2 is the same: **the editor is focused and the first
keystroke types, with no beep.**

### §F.1: The regressions (must now hold)

- [ ] Viewing a page, press ⌘N: the new page mounts focused; type at
      once.
- [ ] Click the **+** tab: the new page mounts focused; type at once.
- [ ] From a keyed empty window (close the last page so the keys stay
      and the calm sentence shows), press ⌘N: the conjured page mounts
      focused; type at once.
- [ ] Click an **empty slot** on the strip (one whose page expired, or
      shorten a page to the bottom rung and wait it out): selecting it
      opens a page into it, and that page mounts focused; type at once.
      ⌘1 through ⌘9 onto such a slot is the same path and must do the
      same.
- [ ] ⌥⌘←/→ onto an **empty slot**: the walk opens a page into the slot
      it lands on, and that page mounts focused; type at once.

The last two are the ADR-0017 mint paths, which arrived after the
original three and go through the same teardown: the empty state's
catcher gives way to a freshly built editor, and first responder leaves
with the catcher.

### §F.2: The paths that must still work (no regression)

- [ ] ⌘0 to the ledger, then Esc back to the page: focused, type at
      once. (Esc here leaves the ledger; it does not hand the keys
      back.)
- [ ] ⌘0 to the ledger, then ⌘0 again back to the page: focused, type
      at once.
- [ ] The same round trip several times in quick succession, ⌘0 ⌘0 ⌘0
      ⌘0: every return lands focused. Speed is the point, not
      thoroughness. The outgoing editor's teardown and the incoming
      one's mount overlap here, and telling those two apart is what the
      hand-off has to get right (issue #23).
- [ ] Plain switch ⌘1 through ⌘9 across several pages: each lands
      focused; type at once.
- [ ] ⌥⌘←/→ walk across the pages: each lands focused; type at once.

### §F.3: Accept, never take (the invariant that outranks §F.1)

The law only ever accepts keys an earlier deliberate act conferred; it
never seizes them. An **unkeyed** window must stay unkeyed through
every path in §F.1, so bring another app frontmost first (`lsappinfo
front` names it) and leave this window visible but not key.

- [ ] Click the **+** tab on the unkeyed window: a page is created, but
      the panel does **not** become key, the editor is **not** focused,
      and keystrokes still land in the front app. `lsappinfo front` is
      unchanged.
- [ ] Click a page **tab** and the **countdown** label on the unkeyed
      window: chrome clicks never grant keys, so the front app keeps
      them (`needsPanelToBecomeKey` is false for chrome; the empty
      content area and a real editor are the only key-granting
      surfaces, and those are the lawful third and fourth grants of
      ADR-0005, not violations of this invariant).
- [ ] Click an **empty slot** on the unkeyed window: a page is opened
      into it, and the keyboard still belongs to the front app. This is
      the one the mint paths make worth re-checking, since they now ask
      for focus where they used not to; the ask is refused for an
      unkeyed surface, and the refusal is what this line is about.

## Separate procedures, in their own documents

The runbook above is one session. These are standalone procedures, each
with its own owner and its own dated results, under
`docs/qa/verification-procedures/`. Which ADR-0016 lifecycle case each
one closes, and what the automated tests already cover for that case,
is indexed in [`recovery-matrix.md`](recovery-matrix.md):

- [`reboot.md`](verification-procedures/reboot.md). Owner: delano.
  A real reboot with a live pad; a reboot with the pad emptied first,
  confirming key rotation ran; a reboot with a page held, confirming it
  returns held. ADR-0016 section 10, case 3.
- [`force-termination.md`](verification-procedures/force-termination.md).
  Owner: delano. A `kill -9` inside the debounce window and a second one
  after a settled write, then the Force Quit dialog and a rebuild over a
  live instance as the same death by other routes. ADR-0016 section 10,
  case 2.
- [`power-loss.md`](verification-procedures/power-loss.md). Owner:
  delano. A hard power cut mid session, then the stranded
  `state.sealed.<hex>.tmp` artifacts and the sweep launch runs over
  them. ADR-0016 section 1 and section 10.
- [`re-signed-bundle.md`](verification-procedures/re-signed-bundle.md).
  Owner: delano. Re-signing with a different identity refuses without
  erasing, and the `.debug` bundle id keeps its state directory separate
  from the release one. ADR-0016 section 10, case 4.
- [`locked-keychain.md`](verification-procedures/locked-keychain.md).
  Owner: delano. A locked keychain at load, and a denied ACL prompt,
  each refusing with no erase and no overwrite. ADR-0016 section 10,
  case 6. §C above covers the round trip; this covers the refusals.
- [`clock-step-back.md`](verification-procedures/clock-step-back.md).
  Owner: delano. The machine clock stepped back a day with a live pad,
  across a relaunch and again mid session, confirming a page ages by
  zero rather than gaining life. ADR-0016 section 4 and section 10,
  case 7.
- [`raised-card-drag-tracking.md`](verification-procedures/raised-card-drag-tracking.md).
  Owner: delano. Drag and resize tracking on the raised card. Not an
  ADR-0016 case.
- [`pinned-over-fullscreen.md`](verification-procedures/pinned-over-fullscreen.md).
  Owner: delano. A pinned card and another app's full-screen Space:
  whether the card is visible there, and, either way, that clicks reach
  the full-screen app rather than the pad (issue #73). Not an ADR-0016
  case.
- [`spaces-and-cmd-tab.md`](verification-procedures/spaces-and-cmd-tab.md).
  Owner: delano. ⌘Tab back landing where the user is rather than on
  Desktop 1, the shape of any flicker on return, and the edge drag that
  ADR-0019 decides against rather than fixes (issue #74). Not an
  ADR-0016 case.

- [`sync-enrolment.md`](verification-procedures/sync-enrolment.md).
  Owner: delano. Two Macs, a real browser trip and a real relay: that
  sync off reaches nothing, that a browser trip can be given up, that
  the six digits can be failed on purpose, that a page travels and
  carries the mark while another device writes on it, and that a
  revoke stops new edits without reaching across to the other
  machine's records (issue #102, ADR-0027 section 5, ADR-0021 section
  3). Blocked on the relay. Not an ADR-0016 case.

Whether any of them has been run is recorded in each file's own Status
line and Results table, which is the one place a run belongs. A tally
kept here as well would only be a second copy to go stale.

## Results

One row per section of the runbook above, filled in as a session
reaches it. The rows stay; a re-run adds a row rather than replacing
one. Record §D's felt-default answers verbatim in the notes and §E's
numbers as measured, since both are inputs to open spec questions
rather than pass or fail. §B outcomes, either way, are also recorded in
ADR-0002, which accepted the shell with §B open as verification and
whose eject triggers name the failure modes.

| Date | Machine and macOS | Section | Pass or fail | Notes |
|---|---|---|---|---|
| | | §0 | not yet run | |
| | | §A | not yet run | |
| | | §B | not yet run | The ADR-0002 go/no-go. |
| | | §C | not yet run | The only place the real login keychain runs; CI uses the in-memory store. |
| | | §D | not yet run | |
| | | §E | not yet run | |
| | | §F | not yet run | |
