# docs/spec/feature/lists-and-highlighting/README.md
---

# Feature: list automation and code highlighting on the page

Status: **landed**, all five phases · 2026-08-27
Scope: two additions to the ink editor, independent of each other and
shippable separately. One, automatic list behaviour: Return continues a
list item, Return on an empty item ends the list, Tab and Shift-Tab
nudge an item's depth. Two, syntax highlighting inside fenced code
blocks, driven by the fence's info string. Both live entirely in the
Swift shell (`InkEditorView.swift` and one new file); the core, the
block model, the FFI seam and the sealed format are untouched.
Governs against:
[`../../design/03-design-principles.md`](../../design/03-design-principles.md)
(§3 content plays second fiddle, §4 frugal, amendment B),
[`../../design/04-interaction-model.md`](../../design/04-interaction-model.md)
("Markdown: styled, never rewritten"),
[ADR-0013](../../../adr/0013-document-provenance-and-block-metadata.md)
(the editable-surface rule) and
[ADR-0022](../../../adr/0022-fence-regions-coalesce-stamps-in-display.md)
(a fence region is one display unit).
Decision:
[ADR-0024](../../../adr/0024-caret-only-automation-and-display-only-color.md)
(the caret-only automation law, and amendment C's display-only color).
Issue: not yet filed.

## Why now

Dogfooding put real notes and real code on the page, and two gaps became
the friction:

- **Lists have zero support.** No `insertNewline` override, no marker
  logic anywhere in the editor. People are trained by Slack, Teams, mail
  clients and GitHub: type `- `, press Return, expect the next bullet.
  The page gives them a bare newline.
- **Code blocks read as prose with a wash.** The whole page is already
  monospaced (`InkStyle.baseFont`), so a fenced block differed from a
  paragraph only by the slab the layout manager paints
  (`InkStyle.codeBackground`). The styling switch for a code line did
  nothing at all: `case .code` was a comment and a `break`. The
  `FenceScanner` already parsed the info string (`swift` in
  ` ```swift `, `fenceRun`), and `classify` already read it once, to
  refuse a closing rule that carries text. What it discarded was the
  language on the opening rule. The field existed and had a caller; the
  language it carried had none.

One prior confusion to close: colored code seen in screenshots of other
tools is theirs, not ours, and nothing colored can arrive by paste
because ⌘V is forced plain (`paste(_:)` at `InkEditorView.swift:1791`).
That stays.

## Doctrine: what has to be argued before code

### The principle scope, written down (amendment C to doc 03 §3)

§3 says "no rich previews, no syntax highlighting, no image zoom.
Recognition, not consumption." Read in context that rule governs the
recognition surfaces: chips, the ledger, anything that shows a page
without being the page. Amendment B already carved the editable page out of
§3's absolutism for headings (display-only, markup-preserving), and
ADR-0013's editable-surface rule states the license plainly: "A text
file with syntax highlighting is still a text file."

Phase 1 adds **amendment C** to doc 03: syntax coloring inside fenced
blocks on the editable page is display-only styling under amendment B's
contract. The bytes never change, select-all-copy returns exactly what
was typed, and chips, the ledger and the roll's quiet renderings remain
uncolored. The resting glance is not among them: it mounts the editable
page itself, read only (ADR-0006), so it carries this color exactly as
it has carried heading weight since amendment B. `docs/design-brief.md:32` is left as written; the principles
doc is where amendments are recorded, per its own header.

### The caret-only automation law (ADR-0024)

List automation is a genuinely new category: the first time the editor
writes ink the user did not type. Headings, fences and links are all
display-only; this inserts bytes. The law that keeps it honest, to be
recorded as ADR-0024:

**Automation may insert or remove text only on the caret's line (or the
line the keystroke creates), only in direct response to that keystroke,
and never anywhere else in the document.**

Consequences, each deliberate:

- **No renumbering.** Inserting an item mid-list does not rewrite the
  numbers below it. Continuation inserts previous + 1 and stops. Lines
  the user typed stand as typed; "styled, never rewritten" keeps its
  meaning for every line the caret is not on. A list whose numbers
  repeat is the user's to fix, exactly as in a plain text file.
- **One keystroke, one undo step.** A continuation (newline + marker)
  is a single undo group; ⌘Z after Return puts the caret back where it
  was with no orphaned marker.
- **Every inserted character travels the ordinary edit route**
  (`insertText` → `shouldChangeText`/`didChangeText`), so the core sees
  ordinary ops and ADR-0013's provenance holds without a special case.

ADR-0024 carries both clauses: the caret-only law for automation, and
the amendment C scope for coloring.

## Part 1: list automation

### What a list item is

A **body** line (never a line inside a fence: `- x` there is a flag,
not a bullet, issue #75) matching:

```
^(indent)(marker)(space)(content)
indent  = spaces and tabs, possibly empty
marker  = "-" | "*" | "+"                      bullet
        | digits "." | digits ")"              ordered
        | "-" " " "[" (" "|"x"|"X") "]"        task box (bullet variant)
space   = one space
```

Recognition is a pure, nonisolated static parser
(`InkStyle.listMarker(of:)`, mirroring `headingMarker(of:)` at
`InkEditorView.swift:2237`), returning indent, marker kind and marker
length, testable without a view.

### Behaviour

- **Return on an item with content**: insert newline, then the same
  indent and the successor marker. Bullets repeat themselves (`-` stays
  `-`). Ordered items increment and keep their delimiter (`3.` → `4.`,
  `3)` → `4)`). A task item continues unchecked (`- [x] done` →
  `- [ ] `). Caret lands after the marker's trailing space.
- **Return on an empty item** (marker and nothing after its space):
  remove the marker from the line, leaving a plain empty line. One
  Return ends the list, the Slack reading. No newline is inserted by
  this branch.
- **Return mid-line** splits as it always did; the new line gets the
  successor marker only when the caret sat at end of line. A split in
  the middle of an item's content yields a plain continuation line, not
  a surprise bullet. (Slack continues here too; splitting an item into
  two items rewrites the reading of text to the caret's right, which
  leans against the automation law's spirit. Start strict; loosen later
  if dogfooding asks.)
- **Tab with the caret at or inside the marker**: insert two spaces at
  line start (deepen). **Shift-Tab**: remove up to two leading spaces
  (or one leading tab). Elsewhere on the line, Tab remains a literal
  tab character. No marker restyling on depth change; a nested `-` is
  still `-`.
- **⇧Return** (`insertLineBreak`) stays a plain line break: the escape
  hatch for a hard wrap inside an item.

Gates: the readOnly stance never reaches these paths (`isEditable` is
already false). During IME composition (`hasMarkedText()`), no
automation. Inside a fence, no automation: the decision consults the
same classification `restyle` computed, so the two can never disagree.

### Display

- A new `LineKind` case, `.list(markerLength: Int)`, produced by
  `FenceScanner.classify` for body lines that parse as items
  (`InkEditorView.swift:2566`). Additive; existing cases untouched.
- `styleParagraph` (`InkEditorView.swift:1226`) gives `.list` a hanging
  indent: `headIndent` set so wrapped lines align under the content, not
  under the marker. Monospaced page makes the width exact: (indent +
  marker + space) × the base font's advancement.
- The marker keeps full `labelColor`. Heading hashes dim because the
  heading text gains weight in compensation; a list marker **is** the
  bullet the eye scans for, and dimming it would bury the structure the
  user typed. No glyph substitution: `-` renders as `-`, never `•`.

### Where it hooks

`InkTextView` (`InkEditorView.swift:1708`) already owns the keyboard
seam (`keyDown`, `performKeyEquivalent`, `insertText`). Add:

- `override func insertNewline(_:)`: read the caret's paragraph, ask the
  coordinator for its cached `LineKind` and the pure parser for the
  marker; branch continue / exit / plain per the behaviour table; wrap
  continuation in one undo group; insert via `insertText`.
- `override func insertTab(_:)` / `insertBacktab(_:)`: the depth nudge,
  gated to list lines with the caret in the marker region; otherwise
  defer to super.
- Coordinator: retain the per-paragraph kinds the last `restyle` walk
  computed (it already builds them at `InkEditorView.swift:1031`; today
  they are consumed and dropped), keyed by paragraph range, so the
  keystroke path reads classification instead of re-scanning the page.

## Part 2: syntax highlighting in fences

### Language capture

- `FenceScanner.open` grows the info string it already parses:
  `(marker, length, language: String?)`. The language is the first
  whitespace-delimited token of the info string, lowercased, mapped
  through an alias table (`js` → `javascript`, `py` → `python`,
  `yml` → `yaml`, `sh`/`zsh`/`bash` → `shell`, …).
- `LineKind.code` becomes `.code(language: String?)`. The opening
  `fenceRule` is where the language enters; every `.code` line until the
  closing rule carries it. `Equatable` conformance stays derived;
  `MarkdownFenceTests` updates mechanically.

### The tokenizer

One new file, `shell/Sources/CompanionKit/CodeInk.swift`, no
dependencies. §4 (frugal) rules out a third-party highlighter: a
grammar engine is megabytes and a supply chain for four colors.

- `LanguageSpec`: a value per language: keyword set, line-comment
  prefixes, block-comment pair (optional), string delimiters,
  multiline-string delimiters (optional), whether `#`-style or
  `//`-style numbers rules apply. Languages are table entries, not
  code; adding one is adding a literal.
- v1 table: `swift`, `rust`, `python`, `ruby`, `javascript`,
  `typescript`, `go`, `shell`, `sql`, `json`, `yaml`, `toml`.
- `CodeInk.Tokenizer`: a `struct` scanned line by line **with state
  carried across lines**, exactly the `FenceScanner` pattern and for
  the same reason: a `/* comment` or an open `"""` means the next line
  is not what it locally looks like. State: inside block comment,
  inside multiline string. The tokenizer resets at each opening fence
  rule and never leaks across regions.
- Output per line: `[(range: NSRange, kind: TokenKind)]` with
  `TokenKind` = `keyword | string | comment | number`. Four kinds is
  the ceiling; types, attributes and interpolation are recognition
  beyond what a little text file owes.
- Unknown language, unlisted language, or a bare ` ``` ` fence: zero
  tokens. The block renders exactly as today. Guessing a language is
  worse than plain ink, the same position the link spec took.

### Colors

In `InkStyle`, semantic and theme-adaptive by construction:

| kind    | color                        |
| ------- | ---------------------------- |
| keyword | `NSColor.systemPurple`       |
| string  | `NSColor.systemRed`          |
| comment | `NSColor.secondaryLabelColor`|
| number  | `NSColor.systemBlue`         |

Fixed in one place so tests can assert them and dark mode costs
nothing. Font never changes: color only, on `baseFont`, so metrics,
wrapping and the wash geometry (`slabRect`,
`InkEditorView.swift:1687`) are untouched.

### Where it hooks

- Pass 1 of `restyle` (`InkEditorView.swift:1031`) already walks lines
  in document order with the scanner; the tokenizer runs beside it,
  attaching each paragraph's tokens to the walk tuple. Cross-line
  tokenizer state lives where cross-line fence state already lives.
- `styleParagraph`'s `case .code` (`InkEditorView.swift:1302`) stops
  being `break`: after the base attributes, lay each token's
  `foregroundColor` down. Fence rules stay dimmed
  `tertiaryLabelColor`; the info string on the opening rule is part of
  the rule and stays dimmed with it.
- Restyle already runs on every change over the whole page; the page is
  a little text file and the tokenizer is one linear scan, so no
  incremental machinery. If a profile ever disagrees, the fence regions
  are already ranges and the scan can narrow to the edited region then,
  not now.

## Phases

Each phase compiles, tests and ships alone. 2 and 4 are independent of
each other.

1. **Doctrine.** Draft ADR-0024 (caret-only automation, amendment C
   scope). Add amendment C to doc 03. Extend doc 04's "Markdown:
   styled, never rewritten" with a lists paragraph and a highlighting
   sentence; the fence-interior sentence ("`- x` is a flag, not a
   bullet") stands. Re-verify every path:line cited here against the
   tree at commit time (citation drift is real).
2. **Lists.** `listMarker(of:)` parser; `LineKind.list` + classify;
   hanging indent in `styleParagraph`; `insertNewline` continue/exit
   with undo grouping; coordinator kind cache. Tests first for the
   pure parser and classify.
3. **List depth.** `insertTab`/`insertBacktab` nudge. Small and
   separable; lands only after 2 has survived a few days of dogfood.
4. **Highlighting.** Scanner language capture + `LineKind.code(language:)`
   (touches `MarkdownFenceTests`); `CodeInk.swift` with the v1 table;
   `InkStyle` colors; restyle wiring. Tests first for the tokenizer.
5. **Version.** Bump the crate and shell versions with the features as
   they land, CHANGELOG entries per phase.

## Test plan

- **Pure, no view** (the `classify(lines:)` pattern,
  `MarkdownFenceTests`): marker parsing table (every marker kind,
  indents, tabs, false positives like `-x`, `1.5`, `*emphasis*`);
  successor computation (`3.` → `4.`, `3)` → `4)`, task reset to
  unchecked); classify yields `.list` outside fences and `.code` inside
  (issue #75 regression); language alias mapping; tokenizer goldens per
  v1 language (line comments, block comments spanning lines, strings
  with escapes, multiline strings, numbers, keyword boundaries such as
  `format` not matching `for`); unknown language yields zero tokens;
  tokenizer state resets between regions.
- **View-level** (the `EditorFactoryTests` pattern, and always with
  injected Seams: default Seams under xctest resolve the installed
  backdrop's state): Return continues and the storage byte count grows
  by exactly newline + marker; Return on an empty item removes the
  marker; one ⌘Z reverses a continuation completely; no automation
  inside a fence; no automation during marked text; ops reach the core
  as ordinary insert/delete batches (the `DocumentOpsTests` seam).
- **Unchanged by construction, asserted anyway**: select-all-copy
  returns bytes exactly as typed with a colored fence on screen; ⌘V
  stays plain; sealing a list line seals the markup.

## What landed differently from this plan

Written down because the next reader of this file will otherwise
believe the plan rather than the code.

- **Amendment C's scope was wrong about the resting glance.** The plan
  said chips, the ledger and the resting glance stay uncolored. The
  resting card mounts the editable page itself, read only (ADR-0006),
  so it carries fenced color exactly as it has carried heading weight
  and link color since amendment B. The docs now say where color
  really stops: chips, the ledger and the roll's quiet renderings,
  each of which renders a page rather than mounts one.
- **`LineKind.list` carries only the marker length.** The marker itself
  comes from the pure parser at the moment a keystroke needs it, which
  keeps the enum something a reader can hold in view.
- **Tokens ride in a named struct, not in the walk tuple.** Adding a
  third element to the tuple would have changed `fenceRegions(of:)`'s
  pure signature and its tests. The styling pass maps back down to the
  pair, so a `BlockWalk` means what it always meant.
- **A fresh tokenizer at each opening rule, rather than `reset()`.** An
  opening rule can change the language, and a reset keeps the old one.
- **The classification cache is stamped with a count of edits, not
  with a measurement of the page.** A backtick typed over a letter
  above the caret opens a fence and changes what the caret's line means
  without moving a character, so a length stamp calls that page
  unchanged; so does a string hash, which reads ninety six characters
  and the length however long the page is. A counter bumped on every
  character edit is exact at any size.
- **Three cases the behaviour table did not name**, each settled in
  code and in a test: Return over a selection splits plainly, Return at
  the head of a bare marker splits plainly (only the end of a line is
  about the list at all), and an ordered successor is clamped to the
  nine digits the parser reads rather than writing a marker nothing can
  read back.
- **Shift-Tab is gated to the marker region and swallowed when there is
  nothing to outdent**, because AppKit's backtab otherwise walks the
  key view loop and pulls focus off the page.

## Out of scope, deliberately

- Renumbering or any rewrite of lines the caret is not on (the law).
- Rendering `•` for `-`, hiding markers, or any glyph substitution.
- Clickable task boxes. A click that flips `[ ]` to `[x]` writes bytes
  from a mouse gesture and needs its own argument; candidate for a
  later rev, listed in doc 06 when phase 1 lands.
- Inline emphasis, still deferred (doc 06).
- Inline code spans (single backticks): recognition without a fence is
  a different scanner problem; not in this rev.
- Highlighting anywhere outside a fence region, and any coloring on
  chips, the ledger, or the resting glance (amendment C's boundary).
- Language auto-detection for bare fences. The info string is the only
  signal.

## Open questions

- Whether `+` as a bullet is worth recognizing (GitHub accepts it;
  nobody types it). Kept in the parser for one table row; drop it if it
  ever false-positives on diff-style paste.
- Whether the v1 language table wants `c`/`cpp` and `html`/`css` on
  day one. The table makes this a follow-up commit, not a design
  question; start with the twelve above and let dogfood vote.
