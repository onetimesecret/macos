# docs/spec/design/04-interaction-model.md
---

# Interaction Model (revision C — the window)

Supporting material for milestone 1 — the concrete model the principles in
doc 03 are argued against. This is **revision C**, replacing the rev A
text that previously lived in this file. It consolidates two design
rounds so it reads self-contained:

- **Rev A** (the previous text of this doc): a stack of "SleeperCells",
  each with its own TTL, masked by content detection.
- **Rev B** (*the sheet*, design rounds v7–v10 — never landed in this
  repo): the stack became a single page of freely typed **ink** holding
  opaque **sealed chips**; one countdown per sheet; content detection was
  deleted outright.
- **Rev C** (*the window*, 12 Jul 2026 decision rounds): the panel became
  a real window, tabs moved to the bottom edge and gained a keyboard map,
  the clock learned to pause, dead pages got the ledger, and the page
  learned to read markdown without rewriting it.

Sources: `docs/archive/airlock-prototype/Airlock Spec.dc.html` (rev C,
authoritative
for conflicts), the design rounds v7–v10 in the same folder, and the
working prototype
`docs/archive/airlock-prototype/Airlock Prototype.dc.html`.
Where this document contradicts rev A or rev B, this document governs.
The product frame is unchanged: a chamber things pass through, never a
place they live.

## The shape of the thing

A menu-bar resident summons a non-activating window. The window shows one
sheet; the sheet holds **ink** (visible text) and **sealed chips** (opaque
tokens for deliberately masked content). One countdown governs the page;
zero means zeroized, silently. Sheets multiply as bottom-edge tabs,
Excel-anchored, each tab carrying its own gauge. A permanent dashed tab at
the strip's right end is the ledger.

```
┌ CompanionApp ································· 8h ✈ ┐
│                                                     │
│  ### deploy friday                  ← styled, markup│
│  in order —                           kept visible  │
│  [ ghp_4kQ9wXbG…e0H5jK · 40 ch ]    ← sealed chip   │
│                                                     │
│  ████████████████████░░░░           ← the gauge     │
│                                            ↗ page   │
├──────┬─────────┬────┬───────────────────────────────┤
│deploy│⏸ errands│ +  │                        ◌ 1    │
└──────┴─────────┴────┴───────────────────────────────┘
```

Tabs hang from the bottom edge like Excel's; each carries its own gauge;
⏸ marks a paused clock; the dashed ◌ tab is the ledger.

## Surfaces

### Menu bar item

The app's only permanent presence. Monochrome template icon, no badge, no
count. Click toggles the window; drag-hover onto the icon opens it to
receive the drop. The menu (right-click) carries the boring necessities:
Settings, About, Quit — not features.

### The window

Rev B's fixed edge-docked panel is now a window in the ordinary macOS
sense, while remaining a **non-activating accessory**:

- **Moves** by its title bar; **resizes** from any edge or corner (the
  page grows; chrome stays constant).
- **Double-clicking the title bar stretches it vertically** to full
  working height — double-click again to return.
- **Position and size persist** across summons.
- **Excluded from capture.** Invisible to screen sharing and screenshots
  by default (`sharingType = .none`). Rev C removed the "excluded from
  screen capture" caption from the surface — the surface should be quiet
  about its own plumbing; the exclusion itself is unchanged and lives in
  settings.

### Focus: accept, never take

None of the window behaviour changes the focus law. The window accepts
the keyboard by deliberate act only (click into the page, click into
the emptiness where a page would be, or summon with ⌥Space) and never
becomes the key window for chrome interactions. A click into emptiness
creates the page it lands in; ⌥Space creates one when none exists, so
summon always lands on a ready editor (ADR-0005). While the window
holds the keys, Enter on emptiness creates a page too: the muscle
memory of starting a new thought. Typing into an unkeyed empty window
still falls through; the click or ⌥Space is the price of entry, by
design. Esc hands the keyboard back. An ember border shows while the
window holds keys. Opening the window never deactivates the user's
frontmost app.

## The sheet: ink and sealed chips

A sheet reads like a little text file. **Ink** is anything typed —
visible, editable, ordinary text. A **sealed chip** is an opaque token
standing in for content that was deliberately masked; its bytes route
core-side and never render.

Masking is decided by **gesture, not by content and not by origin**. The
app never parses, classifies, or scores what arrives — the v10 round
deleted the regex bank on the argument that *"we never read what you
paste" is a stronger position than "we read it to protect you"*. Excerpts
are mechanical; counts are counts; detection never returns.

## Getting content in

| Route | Lands as | Why |
| --- | --- | --- |
| Typing | visible ink | You wrote it; you see it |
| ⌘V | visible ink | Paste behaves like every text editor on the machine — plain text, no surprises |
| ⇧⌘V | sealed chip | The masked paste — consent expressed by the gesture; bytes route core-side, never render. Rekeyed from ⌥⌘V (OS collision: Finder's "Move Item Here"); ⌥V held as fallback candidate |
| Drop onto the window | sealed chip | Dragging content to a secrecy tool is already the "stage this" gesture (doc 06) |
| ⌘↩ / select → seal | sealed chip | The retrofit — seals the selection, or with no selection the current line, if the line holds content |
| Images, any route | sealed chip | An image has no inline-text form; the chip shows clipboard metadata only |

The **paste-flip guarantee**: nothing is sealed without your gesture, and
nothing sealed ever renders.

No dialog, no naming step, no confirmation on any route. The author's own
typed line above a chip does the naming — "dsn for the migration" says
more than a detected "POSTGRES URL" label ever did.

### Sealing by keyboard — ⌘↩

The seal shortcut is **⌘↩ (Command-Return)**, replacing rev B's proposed
⌥⌘S. Semantics: with a selection, seal the selection; with a bare caret,
seal the **current line**, if the line holds content. A line already
holding a chip refuses with an explanation; an empty line does nothing.
⌘↩ is the natural "commit this line" gesture, it has no OS-level claim
inside a text view, and it makes the common case — paste a secret, seal
it — a two-keystroke sequence with the hands never leaving home row. The
floating on-selection affordance remains the discoverable path and
teaches ⌘↩.

## The sealed chip

- **The excerpt rule is mechanical.** Single line: reveal budget
  `min(24, ⌊n/3⌋)` characters, split 60/40 head–tail, middle hidden.
  Multi-line: first line only, ≤ 17 characters, with the count shown in
  lines. Images and files: clipboard metadata only (kind, dimensions,
  byte size, filename) — read without opening the contents. The excerpt
  only has to be *recognized by the person who pasted it*, not identified
  by a stranger.
- **Never revealable.** No reveal affordance exists, at any privilege.
- **Atomic under the caret.** Arrows step over it, one ⌫ removes it
  whole, selection cannot reach inside it.
- **Hover reveals actions, never content:** copy-out (marked transient +
  concealed on the pasteboard, non-consuming — multi-paste is a core
  moment) and ↗ link (conceal).
- **No per-chip timers, ever.** Time belongs to the sheet.

## Time: the ladder, the gauge, and the pause

- **One countdown per sheet.** The ladder runs `1h · 3h · 8h · 24h · 3d
  · 7d`; the core default is **8h** and the backdrop opens pages at
  **7d**. Click the header label to step one rung **shorter**; each
  click resets the clock to the shown rung. The ladder tapers, `7d → 3d
  → 24h → 8h → 3h → 1h`, and wraps back to `7d` at the bottom. Decided
  2026-08-08 (doc 06 Q1): the wheel stays one affordance, but the
  single-click cliff now sits at the safe end. Cycling upward put a
  168h→1h drop under a stray click on deliberately staged content;
  shortening is the direction that costs something, so it costs five
  clicks.
- **The gauge.** The page's bottom edge drains continuously; each tab
  carries its own gauge, so cross-sheet urgency reads as geometry. Under
  one hour it turns ember with a hatched texture — urgency is never
  colour-only.
  *(Superseded in part, 2026-09-05, dogfood phase 4 item 3: the
  page's bottom edge no longer drains. The full width gauge along it
  read as a horizontal scroll bar for long unwrapped lines and was
  withdrawn; any replacement must not be a thin full width bar along
  the bottom edge. The per tab gauge in the sketch above stays as
  drawn, and the gauge also survives on the time rail, down the
  card's side. docs/dogfood/ABERRATIONS.md and issue #156 hold the
  reasoning. The pause below is unchanged.)*
- **The pause.** Double-click a tab to hold that page's clock: the
  gesture is a three-state cycle. The first double-click holds it for
  **1 hour**; a second tops the hold up to **24 hours from now**; a
  third **releases** it and the countdown resumes from exactly where it
  froze. While held, the tab carries a chip — ⏸ and the span the last
  press bought, `1h` or `24h` — the gauge freezes with a dashed fill
  (longer dashes once topped up, which is the tier where the tab strip
  is out of view), and remaining life does not drain. The tooltip and
  the context menu name the next press in words. The ⏸ stays in front
  of the number because `24h` is also a rung label, and the chip is
  about the hold, not the countdown.
  An unreleased hold lapses on its own, to the same effect as a
  release: the page is simply a regular page again — no notification,
  no state to clean up. A pause holds the clock; it never extends the
  rung. The honest tension — pausing is a lever against ephemerality —
  is bounded by the top-up ceiling (24h per press, never cumulative)
  and logged in doc 06.

  The release was added 2026-08-10, after the two-state form shipped:
  the gesture reads as a toggle, so a stray double-click on a held tab
  silently bought a page another day with no way to give it back. A
  gesture that only ever adds life is the wrong shape for this app.
  Re-topping-up after a release costs two presses (hold, then top up),
  which is the right price for the reversibility.
- **Expiry is silent** — no notification, no badge. The dead page's ink
  rests in the ledger; its sealed bytes are zeroized at expiry.

## Sheets, several: tabs at the bottom

Tabs won the switcher question, and they sit on the window's bottom
edge, Excel-anchored — below the content they name, out of the title
bar's way, exactly where a spreadsheet hand already knows to look.

- **Names are live.** A tab is named by its sheet's first typed line,
  with markdown markup stripped for the title only (`### deploy friday`
  → "deploy friday"); a page with no typed line is "untitled".
- **No cap; never evict.** Rev C set a cap of 9 sheets as the natural
  limit of the keyboard map, with the app declining the tenth and saying
  so. The cap was removed on 2026-09-06 (issue #158, ADR-0017's history):
  ⌘1 to ⌘9 stay shortcuts to the first nine slots, the strip scrolls to
  hold the rest, and a tenth slot simply has no chord. What survives is
  the half that mattered: silent eviction of deliberately placed content
  would break trust (doc 03 §5). Eviction is by the TTL the user chose,
  never LRU surprise.
- **Drag to reorder**, live; the ⌘-number map follows the visible order.
- **Close** is an ✕ on tab hover; a closed page rests in the ledger like
  an expired one. New page: the + affordance, or ⌘N.

## The ledger — ⌘0

Rev B's law read "no retention: no history, no archive, no trash, no
recently-expired". Lived experience overruled the absolutism: a page that
expires mid-thought takes typed context with it — the errand list around
the secret, not just the secret. The **ledger** is the narrow amendment
(recorded in docs 03 and 05): a permanent dashed tab at the strip's right
end (⌘0) showing expired and closed pages as a list of **dimmed ink**.
The boundary holds where it matters:

- **Ink only.** Sealed bytes are zeroized at death exactly as before; a
  chip appears in the ledger as its excerpt struck through with
  "zeroized". Nothing sealed survives, ever, anywhere.
- **Dimmed and read-only.** Ledger entries are records, not pages — no
  editing, no resurrection, no re-opening. Copy of visible ink is
  allowed; it was never secret.
- **Session-bound.** The ledger lives in memory and clears when the app
  quits. Nothing is written to disk. Capacity is bounded (newest dozen);
  older records fall off silently.
- **Visually apart.** The dashed border and dimmed type say "this is
  residue, not storage" before any copy does.

## Markdown: styled, never rewritten

The page reads markdown the way a person does, without pretending to be
a rich-text editor. A line beginning `### ` renders at heading weight and
size — and the `### ` itself stays on screen, dimmed, exactly where it
was typed. **Display-only, markup-preserving:** the bytes of the page
never change; select-all-copy returns exactly what was typed; sealing a
heading line seals the markup too. Scope for rev C is headings (#, ##,
### and deeper) and fenced code blocks; inline emphasis is deliberately
deferred (doc 06). Tab titles strip the markup because a title is a
name, not a document.

**Inside a fence, markup is inert** (issue #75). A line of three or more
backticks or tildes opens a block that runs until a rule of the same
character, at least as long, closes it, and everything between the two
is read literally: a `#` line there is a comment, a `-` line is a flag,
and neither is styled as a heading or a list. The fence's own lines
carry the dimming a heading's hashes do and the block takes a faint
wash, so it reads as one slab of code. The wash is one rectangle per
fence region — opening rule through closing rule, at the full width of
the page's text column — painted behind the text rather than attached
to it, so no stripes appear at paragraph seams and the slab's edges do
not hug the glyph runs. The dimmed rules stay on screen inside the
wash: the markup remains visible, as everywhere else. An unterminated
fence holds to the last line of the page, which is the reading a writer
mid-paste would expect.

**A fence region stamps once** (ADR-0022). A fence typed line by line is
one core block per line — the block model (ADR-0013) is untouched — but
the display treats the run of blocks from the opening rule to the rule
that answers it as one labeled unit: a single created/modified stamp
above the opening rule, spanning the earliest creation and the latest
touch across the blocks the region covers, and no label gap above the
interior lines, so the slab renders contiguous. An unterminated fence
carries the region to the end of the page, the same reading the styling
gives its lines.

**Links: ⌘-click opens, a plain click edits** (ADR-0023). A bare
http(s) URL in body ink, and a markdown `[text](url)` whose target is
http(s), render as links — link color, underlined — with the markdown
syntax (the brackets, the parens, the URL between them) dimmed in place
like a fence's rules: visible, never hidden, still exactly the bytes
that were typed. Opening is an aimed gesture: ⌘-click opens the target
in the default browser; a plain click is editing and only places the
caret, so the URL's own text stays as reachable by mouse as any other
ink. Nothing inside a fence is a link — a URL there is code — and the
system's automatic link detection is off: what counts as a link is the
restyle pass's one conservative reading, not the OS's.

**Lists continue themselves, and nothing else** (ADR-0024). Return at the
end of a list item starts the next one: the same indent, a bullet
repeating itself, an ordered marker incremented with its delimiter kept
(`3.` becomes `4.`, `3)` becomes `4)`), a task box continuing unchecked.
Return on an item that is empty strips the marker and leaves a plain
line, the one keystroke every chat client has trained people to expect
for ending a list. Tab and Shift-Tab nudge an item's depth while the
caret sits in the marker; anywhere else on the line Tab is still a tab.
What the page never does is renumber: inserting an item mid-list leaves
every number below it exactly as typed, because automation may write only
on the caret's line, or the line the keystroke creates, and never
anywhere else in the document. Nor is any glyph substituted: a `-` stays
a `-` on screen, at full weight, because the marker is the thing the eye
scans for. Inside a fence none of it happens, and it is the same walk
that decides the styling which decides the automation, so the two can
never read a line differently.

**Fenced code carries color, and only color** (ADR-0024, recorded as
amendment C to doc 03 §3). A fence whose opening rule names a language
colors four kinds of token inside the block: keywords, strings, comments
and numbers. The language comes from that info string and from nowhere
else, so an unknown language, an unlisted one, or a bare ` ``` ` renders
exactly as it does today; a guessed language is worse than plain ink.
Nothing but the foreground color moves. Same font, same metrics, same
wash, and the bytes are untouched, so select-all-copy still returns
exactly what was typed and sealing a colored line seals the markup. The
color lives where the page itself lives. Chips, the ledger and the roll's
quiet renderings stay uncolored, because each of them renders a page
rather than mounts one; the resting glance mounts the page, read only,
and so carries color exactly as it already carries heading weight. The fence boundary holds in both directions,
which is what keeps the reading above true: automation stops at it going
in, and color stops at it coming out.

## The keyboard map, complete

| Keys | Action |
| --- | --- |
| ⌥Space | summon / dismiss the window |
| ⌘V | paste, visible |
| ⇧⌘V | paste, sealed (⌥V held as alternative candidate) |
| ⌘↩ | seal the selection, or the current line if it holds content |
| ⌘1 – ⌘9 | jump to page 1–9, in visible tab order |
| ⌘0 | the ledger — expired & closed pages, dimmed |
| ⌥⌘← / ⌥⌘→ | previous / next page |
| ⌘N or ⌘T | new page, default rung (⌥⌘N until issue #77; ⌘T joined in dogfood phase 4 because a tab is what the pad opens; the bindings live in the keymap now, docs/development/about-the-keymap.md) |
| ⌘F / ⌘G / ⇧⌘G | find in the page, next match, previous — the docked find bar, not the floating panel |
| ⌥⌘F | find and replace in the page |
| ⌘E | use the selection for find; refuses a selection holding a chip, which has no text to search for |
| ⌥Z | wrap long lines, or let them run and scroll sideways; sticks, and Settings holds the same switch |
| esc | hand the keyboard back (also leaves the ledger) |
| ⌫ on a chip | removes it whole; arrows step over it |

Pointer-only gestures, for completeness: click the countdown to shorten
it one rung · drag tabs to reorder · double-click a tab to pause its clock
(1h → 24h → release) · ✕ on tab hover to close · drag the title bar to
move · drag any edge to resize · double-click the title bar to stretch
vertically · drop content onto the page to seal it.

## Conceal flow (secondary interaction)

Unchanged in role: the app's explicit network action, and the single
place it ever mentions accounts. Two affordances: **↗ link** on a chip's
hover actions (conceal that sealed content) and **↗ page** in the footer
(conceal the sheet).

1. If no account is configured, an inline hint links to Settings →
   Connection, plus a guest-mode option where the server allows it.
2. An inline, in-place confirmation (not a modal): destination
   (`share_domain`), TTL (the link's own default of seven days per
   ADR-0011 section 5, or a value chosen here; the sheet's remaining
   time is not an input, per ADR-0026), optional passphrase, optional
   recipient. One confirming click. The network boundary is explicit.
3. `POST /api/v3/secret/conceal` (Basic auth: org `extid` + API token,
   until PASETO lands). Sealed bytes travel core → client directly, never
   through the UI layer. On success the link is on the clipboard and the
   confirmation offers **Burn local copy**.
4. Failure is inline (offline, auth, entitlement/TTL rejection) with a
   retry; content never leaves the sheet on failure.

Deliberately absent from v1: browsing receipts, burning remote secrets
from the window, secret generation. A staging area with an exit ramp, not
an API console.

## Settings (one small window)

Connection (server URL, org `extid` + API token, share domain, test
button), default TTL rung, summon hotkey, clipboard clear-after-copy
timing, screen-capture exclusion toggle, deadline rounding toggle,
launch at login. Rounding is on unless you turn it off: a rung names a
duration, and with rounding on the deadline lands on the next clock
boundary past that duration, a whole local hour under a day and a local
midnight from a day up, never extended by more than the rung or a day,
whichever is smaller. Off, a rung is exact. Either way the switch is
read when a rung is applied, so pages already counting down keep the
deadline they were given (ADR-0011 section 4). That's the
whole list; growth here is a smell. (Rev C deleted "dock edge" — the
window remembers its own position.)

## Change ledger, rev A → rev C

| Surface | Rev A (previously this doc) | Rev C |
| --- | --- | --- |
| The unit | a stack of SleeperCells | sheets of ink + sealed chips |
| Time | per-cell TTL | one countdown per sheet; pausable (double-click tab: 1h → 24h → release) |
| Masking | detection (`ConcealedType`, key/token regex), reveal-on-hold | gesture only (⇧⌘V, drop, ⌘↩); chips never revealable; detection deleted |
| The container | fixed edge-docked panel | a real window — move, resize, double-click-stretch; still non-activating |
| Capacity | soft cap ~12 cells | 9 sheets at rev C, the keyboard wall; no cap since 2026-09-06 (issue #158); never evict unchanged |
| Keyboard nav | per-cell bindings, no global map | full map: ⌘1–9, ⌘0, ⌥⌘←/→, ⌥⌘N, ⇧⌘V, ⌘↩ |
| After death | nothing — no retention of any kind | the ledger (⌘0): dimmed ink, session-only; sealed bytes still zeroized |
| Rendering | plain snippet + kind glyph | markdown headings styled, markup kept visible; tab titles strip markup |
| Capture caption | visible indicator on the surface | removed from the surface; the exclusion unchanged, in settings |
