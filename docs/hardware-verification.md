# Hardware-session runbook — rev C (the "for realsies" session)

The part only a person at the machine can run. Everything below assumes
the rev C window (issue #12, merged) over the rev C core (issue #10):
sheets of ink and sealed chips, gesture-only sealing, the pausable
countdown, bottom tabs, the ledger. Do it on the Mac you'll ship
against.

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
   (no `--dev-scaffolding` needed; rev C has no dev-seed path).
3. `cd shell && swift build && swift test && swift run CompanionApp`
4. The window summons with **⌥Space** or from the menu-bar item.

## §0 — The prototype walk

Open `docs/Airlock Prototype/Airlock Prototype.dc.html` in a browser
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
- [ ] ⌥⌘N new page; ⌥⌘←/→ walk pages; ⌘1–⌘9 jump in visible tab
      order; ⌘0 opens the ledger.
- [ ] Drag a tab to reorder; confirm the ⌘-number map follows the new
      visible order.
- [ ] ✕ closes a page; it appears in the ledger as dimmed ink.
- [ ] Markdown: `#`/`##`/`###` headings render styled with markup
      visible; the bytes on the page never change.

## §A — Boundary-lawful ingest, live

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

- [ ] Store a credential via the Keychain path, read it back, delete
      it — on a real login keychain, confirming prompt/ACL behaviour.
      (CI uses the in-memory fallback; this is the only place the real
      path runs.)

## §D — Rev C time, felt

- [ ] **The pause:** double-click a tab's gauge — holds 1h; again —
      tops up to 24h; confirm the hold lapses back into countdown.
      Does the bounded top-up feel right (docs/spec/06 q8)?
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

The budget is < 25 MB resident idle **with pages loaded**, near-zero
idle CPU; 22 MB at 0 cells (rev A panel) is the baseline. Materially
over and unrecoverable is an ADR-0002 eject trigger.

- [ ] With 5 pages of mixed ink and chips: `footprint` / `top`
      resident memory, window hidden, after a minute idle.
- [ ] Same at the 9-page wall.
- [ ] Idle CPU ~0.0% with the window hidden (the 1 Hz redraw must not
      run while not visible).

## Recording results

Append findings to this file under a dated `## Results — YYYY-MM-DD`
heading: pass/fail per section, felt-default notes for §D verbatim,
and the §E numbers. §B outcomes (either way) get recorded in
ADR-0002 — it accepted the shell with §B open as verification, and
its eject triggers name the failure modes.
