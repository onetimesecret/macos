ABERRATIONS

Informal but tracked. This started as a local ABERRATIONS.txt, which
the *.txt rule in .gitignore kept out of the repo; it is now a markdown
file committed alongside the rest of the docs, so what goes in it is
readable by anyone with the repo. Write accordingly: no secrets, no
page content, no key material.

A running log of surprising or non-obvious runtime behavior found while
building or dogfooding the app: things a naive mental model gets wrong.
Still not a bug tracker and not a spec, and entries are not expected to
be tidy. When one of these turns out to be structural, graduate it: an
ADR if it is a decision, DOGFOOD.md if it is operational guidance other
people need, an issue if it should be fixed.

---

2026-07-25: persistence only survives a clean quit

CompanionApp saves state exactly once: applicationShouldTerminate,
which calls model.saveState() (App.swift). Restore runs once too, on
first window reveal (loadStateIfNeeded). Between those two points,
nothing touches disk.

What that means in practice:

- Cmd+Q, the Quit menu item, or an AppleScript "quit" all go through
  applicationShouldTerminate and are safe.
- Force quit, a crash, or kill -9 skip it entirely. Whatever is in
  memory at that moment is gone, by design (already covered in
  README's "Force close" section and scripts/quit-app.sh's comments).
- The dev-loop version of the same problem: swift build re-signs the
  binary in .build/ in place, and the kernel SIGKILLs a running
  process whose signature just changed under it. Same loss as a force
  quit, easy to trigger by accident mid-edit. quit-app.sh exists
  specifically to get a clean exit before that happens.

The one new wrinkle, not written down anywhere else yet: if restore
fails over a state file that does exist (denied or missing Keychain
key, a damaged snapshot), the session withholds its own save licence
(grantsSaveLicence in App.swift) so a bad restore cannot overwrite
yesterday's good file with today's empty one. That is the right
tradeoff, but it is silent: nothing tells the person at the moment it
happens, only a Logger.error line under the "persistence" category in
the unified log. Anyone dogfooding who hits this loses a session's
worth of new pages with no on-screen signal, only

  log stream --predicate 'subsystem == "com.onetimesecret.companion" && category == "persistence"'

after the fact explains why.

Candidate fix if this ever surfaces on hardware: surface the withheld
licence the same way applicationShouldTerminate surfaces a failed
save, an alert at quit time ("this session will not be saved because
the previous state could not be restored") rather than only a log
line nobody is watching.



---

August 19, 2026

DOGFOOD

- When writing a list (Enter, dash, space), it creates a new block for each list item. We may want to treat lists in a special way but within the same block (for example, there is no need for the timestamps to appear inbetween list items)
- Still quirky behaviour when cmd-tab away and cmd-tab back
  - When pinned is enabled, on fullscreen in Zed editor, the window wasn't visible by clicks intended for Zed were captured and actioned on by OnetimePad.
  - Can't move to another desktop by dragging to the edge of the screen
  - When tabbing back, it always goes to Desktop 1 instead of to the most Desktop it was active in.
  - When tabbing back, the window flickers in the same way every time.

- Multiple tabs, each with TTLs is a lot to think about.
  - Perhaps separate the notion of the tab-page-ttl as all one time. The tab could be separate and long-lived structure; the page-ttl stay together so the page clears on expiry, but not the tab. This would affect the objects; some Page metadata moves to a Tab object.
  - Perhaps there should be a separate visual treatment for the first line / tab title.
- Markdown hybrid rendering is not working or not implemented. e.g. a comment in a codeblock is treated as an h1 header.



As a user, if I'm going to trust this pad as a safe place to paste things, I also don't want to accidentally information b/c we the developers decided to make sure the application was "secure" at all costs, even usability. IOW, we do not to build an application that is secure to the point of unusability. This speaks to how we deal with persisting to encrypted file on Quit or crash? Even on operating system restart. I lost a whole bunch of stuff b/c I accepted a system update without considering onetime pad.
   - If we already have the TTL expiration, we don't gain much by flushing everything upon restart. We just make it annoying to use.

- Should be able to sort blocks by created or modified, forwards and backwards. But it needs to be easy, like the kind of muscle memory that gets activated when flipping between two pages in a collated pile. Or like how an artist creates a flipbook animation. If I forget I'm adding notes to the top or to the bottom and end up pasting in the middle, they can all be sorted out so no worries.
- The modifed time should display as relative (5 mins ago) etc.

- Improve the "clipboard holds content" and seal it CTA button. It should be integrated and more visible, also just clearing the clipboard.
  - I notice that after sealing it, it doesnt appear again until focus goes away and comes back on the app. Would it be possible to allow auto-pasting? So that I can have a streamlined workflow when putting a bunch of text together.

- cmd-s should provide reassuring feedback that we're not going to lose data. It could for example add a "key frame" (forgot the term for the text input library) and persist the encrypted file. It should be clear visually when the current state is saved (just like Google docs, Word etc).

- The hotkey for new tab should be cmd-n and not cmd-opt-n. Let's get ahead of the curve and establish the JSON keymap file so we can easily change the shortcuts. Use Zed Editor keymap file format.


---

2026-08-19: triage index (additive; the notes above remain the record)

- **Graduate to ADR / decision:** reboot persistence versus the current
  boot-session security boundary (graduated 2026-08-20, from the "I
  lost a whole bunch of stuff" note: [ADR-0016](../adr/0016-content-persists-across-restart.md));
  separating durable tabs from expiring pages (graduated 2026-08-20, from
  the "multiple tabs, each with TTLs" note:
  [ADR-0017](../adr/0017-durable-tabs-expiring-pages.md), which defers
  the separate visual treatment for the first line and the tab title);
  list continuation as a single block; block-sorting interaction.
- **File as reproducible defects:** pinned surface receiving clicks while
  invisible/off-Space; returning to Desktop 1; markdown parsing within
  fenced code blocks; restore failure withholding saves without an
  in-app warning.
- **Prototype before deciding:** clearer page-title/TTL hierarchy;
  relative modification times; a read-only chronological block lens;
  more visible clipboard offer plus an explicit user-triggered re-check.
- **Implement as workflow improvements:** `Cmd+S` as a force-save with a
  non-content-bearing save status; `Cmd+N` as the default new-page
  command if it has no AppKit conflict.
- **Keymap direction:** use a project-owned, Zed-compatible JSON5
  keymap as the authoritative source. Keep a versioned schema for the
  bundled default and user overrides; validate before registering AppKit
  commands, report invalid bindings, and fall back safely to the last
  valid/default map.

The app keymap should use that structure directly, with an intentionally small supported surface:

```json
[
  {
    "context": "Editor",
    "use_key_equivalents": true,
    "bindings": {
      "cmd-n": "page::New",
      "cmd-w": "page::Close",
      "cmd-1": "page::Select1",
      "cmd-2": "page::Select2",
      "cmd-0": "ledger::Toggle",
      "cmd-shift-v": "clipboard::Seal",
      "cmd-s": "state::SaveNow"
    }
  }
]
```

For OnetimePad:

- `context` selects the target surface, initially `Editor`, `TabStrip`, and `Ledger`.
- `use_key_equivalents: true` means bindings participate in AppKit menu key equivalents where appropriate.
- `bindings` maps Zed-style keystrokes to stable internal command IDs.
- Context matching can initially support only simple identifiers and `&&` / `!`, then expand only when a real need arises.
- Commands without a current native implementation, such as `state::SaveNow`, should not appear until their action exists.

---

2026-09-05: the page edge gauge reads as a scroll bar, and the header clock was a duplicate

Dogfood phase 4, items 3 and 6. Two of the remaining-time indicators
came out.

The page edge gauge. `PageStatusStack` drew a four point `GaugeBar`
across the full width of the page, directly above the strip, in both
modes (the page's remaining life as a draining bar, dashed while held,
ember and hatched in the last hour). The design spec
(docs/spec/design/04) asked for exactly that: the page's bottom edge
drains continuously. What a developer or power user actually reads,
though, is a thin horizontal bar running the width of a text surface
at its bottom edge, which is where every editor puts its horizontal
scroll bar for long unwrapped lines. They reach for it to scroll and
it does nothing. The misread is positional and does not go away with
familiarity: the bar is the right shape in the right place to be the
wrong thing.

- The bar is out. Nothing is drawn along the page's bottom edge now,
  in either mode.
- The per tab gauge stays. Each tab on the bottom strip draws a three
  point `GaugeBar` under its title and an empty slot draws a dashed
  `EmptyRule` in the same seat, as the spec's tab sketch shows. The
  first pass took that bar out as well, on the theory that both bars
  carried the misread; the maintainer's call is that the short bar,
  framed by its tab and repeated once per tab, is not what anyone
  takes for a scroll bar, and that the strip would otherwise lose its
  one picture of how long each page has left. It is back exactly as it
  was: the tab is two rows, the file tab keeps the gauge's seat with
  its unsaved dot in it, and `SheetTab.rowHeight` is gone with the one
  row layout.
- `GaugeBar` and `EmptyRule` also still draw on the time rail, per
  day, down the card's side.
- Whatever replaces the page edge gauge, if anything does, must not be
  a thin horizontal bar running the full width of the bottom edge. The
  follow up is tracked as a GitHub issue (#156).
- No accepted ADR asserts the page edge gauge. ADR-0017 splits tabs
  from pages and says nothing about how the surface draws time;
  ADR-0011 names a gauge denominator as an input to a future paradigm
  decision; ADR-0028 says only that a file draws no gauge. So there is
  no ADR amendment, only this note, the code comments on `SheetTab`
  and in `PageStatusStack`, and the issue. The design spec's gauge
  bullet carries a dated superseded note on the page edge alone.

The header countdown. The card header showed a `CountdownButton` for
the selected page (remaining time, rung label, click to shorten). In
the day mode the page prints the same countdown in its own day gutter,
top right, so the header's copy was two clocks for one page, and two
clocks confused more than they informed. The header yields it in the
day mode.

- It is kept in the strip mode, and this is a deliberate narrowing of
  the item as written. The gutter belongs to `DayScrollView`, which is
  mounted only while `showsTimeUnits` is on; that mode is off by
  default and exclusive with the strip. With the tab gauge gone, the
  header button is the only place the strip mode writes the page's
  remaining time as a number. Removing it there would have left the
  default mode with no countdown at all, now that the bottom edge bar
  is gone as well. `BackdropRootView.showsHeaderCountdown` holds the
  rule and the `HeaderCountdownTests` pin it.
- The rung still cycles from the tab's context menu in both modes and
  from the gutter's menu in the day mode.
