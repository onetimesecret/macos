# Feature: source-language detection

Status: **proposed** · 2026-09-12  
Scope: recognize visible pasted code, suggest a rendering language for opened
text files, and suggest a language for unlabeled Markdown fences. No
implementation or dependency change is included in this specification.

- [ADR-0029: Betlang source-language detection behind the existing C ABI](../../../adr/0029-betlang-source-language-detection-behind-the-existing-c-abi.md) — accepted architecture, dependency pin, artifact record, attribution, and policy boundaries.
- [Implementation plan](plan.md) — ordered work, integration points, tests, and
  release gates.
- [2026-09-14 threshold evaluation](evaluation-2026-09-14.md) and
  [execution checklist](evaluation-checklist.md) — failed holdout evidence; no
  production threshold freeze.

All requirements below are proposals, not existing project guarantees, except
where they restate the accepted boundaries in ADR-0029. Current behavior is
identified separately.

## Purpose

People paste source code into notes and open source or configuration files to
read them. Offer an appropriate code presentation without requiring a filename
extension, an existing fence label, or a collection of language-guessing regexes.
Rust supplies a best-effort language label; Swift chooses whether to suggest,
style, or perform an explicitly enabled edit.

Detection is not parsing, syntax highlighting, a binary-file detector, or proof
that text is code. Betlang's 48 output labels do not include a plain-text class.
A confident top label alone cannot establish that ordinary prose should become
a fenced block. The evaluation gate in the plan is required before automatic
paste conversion ships.

## Existing constraints and proposed changes

Authoritative project sources for the architecture and editing policy are the
accepted ADRs below, within their stated scope:

- [ADR-0001, Decision](../../../adr/0001-rust-core-thin-shell.md):
  “All state and logic live in pure-Rust crates with no UI or platform
  dependencies (`companion-core`, `ots-client`); platform FFI is isolated
  in `companion-pasteboard`; whatever shell wins ADR-0002 is a thin layer
  that renders state and forwards intents.”
- [ADR-0024, Decision](../../../adr/0024-caret-only-automation-and-display-only-color.md):
  “Automation may insert or remove text only on the caret's line, or the
  line the keystroke creates, only in direct response to that keystroke,
  and never anywhere else in the document.”
- [ADR-0030, Decision](../../../adr/0030-visible-pages-share-preview-rendering.md)
  partially supersedes the old editable-page-only boundary: “A manually
  accepted or inferred rendering language is page-owned display state, not
  coordinator-owned focus state.” It may therefore reach a visible quiet roll
  page under **All pages**, without rewriting a bare fence.

ADR-0029 provides the narrowly scoped amendment for inferred bare-fence
coloring, whole-file Source mode, fixed-width code regions, explicit
wrap/insert-label actions, and opt-in paste replacements. ADR-0030 extends only
the display surface for accepted language state. The remaining ADR-0024 and
ADR-0029 decisions still govern automation, inference and display-only styling. The
[file-editing spec](../file-editing/README.md) describes a related implementation
but identifies its own decision as proposed; it is context, not authority here.

Observed source behavior, not additional policy:

- Ordinary `paste(_:)` calls `pasteAsPlainText`. Quote substitution, dash
  substitution, and spelling correction are already disabled across the editor.
- The default font is monospaced, but a custom font may be proportional.
- `CodeInk` colors 12 languages using explicit fence labels. Detection of 48
  labels will not create 48 highlighters.
- File reading currently accepts UTF-8, handles an initial UTF-8 BOM, normalizes
  CRLF, and imposes a 4 MiB limit. Drop acceptance is narrower than file reading.

Concrete source locations are in the [plan](plan.md#integration-map).

## 1. Pasted-code recognition

### Setting and default

Add **Automatically fence pasted code** to General settings. Proposed initial
factory default: **off**. Store the user's choice using the existing settings
pattern. Enabling it authorizes fence insertion on eligible future paste actions;
changing it never rescans or rewrites existing content. Manual detection remains
available while the setting is off. A future default-on change requires its own
review of false-positive results, not merely a dependency upgrade.

### Automatic path when enabled

1. Read the ordinary plain-text paste payload once. Do not inspect unrelated
   clipboard items or intercept the sealed-paste gesture.
2. Consider only a single insertion/replacement at whole-line boundaries in a
   Markdown-capable note or file, outside existing code fences, list/quote
   containers, chip attachments, and marked-text composition. Inline pastes and
   partial-line selections remain plain paste in v1.
3. Skip whitespace-only text, already fenced Markdown, and a `markdown` result.
   Require the evaluated Rust acceptance gate to return a label. Structural
   checks choose where fencing is valid; they do not guess a source language.
4. Insert an opening fence with the canonical label, the unchanged paste payload,
   and a closing fence as one normal replacement and one core undo step. Use
   at least three backticks and a run longer than any backtick run in the
   payload. Add only the newlines required to put the rules on separate lines;
   do not trim, indent, normalize, or repair the payload.
5. Place the caret after the inserted block. Undo restores the replaced text and
   original selection; redo restores the complete block without another inference.

Automatic classification must resolve before that single replacement. Use a
bounded background request carrying document identity, revision, and selection.
If text or selection changes while waiting, abandon conversion and use ordinary
paste only if the original document is still active and editable, at its current
selection. If the document switches, closes, or becomes read-only, cancel the
pending paste without inserting into another document and show a brief notice.
Never edit a stale range. Do not insert plain text and silently add fences later. If latency makes this design
unacceptable, ship suggestions/manual conversion only until it is resolved.

A persistent **Paste Without Detection** menu action provides a one-paste bypass
without changing the setting. Do not reuse the sealed-paste shortcut.

### On-demand detection

Expose **Detect Code Language…** in the editor context menu and an ordinary
menu so it is keyboard-accessible. Target, in order:

- A nonempty visible-text selection outside fences: show the suggestion and an
  explicit **Wrap as <Language> Code** action. Preview the affected range; v1
  requires a whole-line selection and never expands it silently.
- An unlabeled fence containing the caret: use the fence behavior below.
- A source-mode file with no selection: use whole-file language selection below.

Disable the action for read-only content, attachments/sealed chips, ambiguous
multi-selections, or a selection crossing existing fence boundaries. No eligible
target means no implicit whole-note scan. A declined or unavailable result leaves
text unchanged. Offer a manual language picker even when detection abstains.

## 2. Open any supported text file, then suggest rendering

The requested direction is extension-independent opening: do not reject a file
merely because its suffix is unknown or missing. Panel, drop, and reopen paths
should share the same core content validation. A detector result is never the
admission test.

“Any non-binary file” needs an encoding definition. Proposed first increment:
any regular file that passes strict UTF-8 decoding and a separately specified
binary-content check, subject to the existing 4 MiB limit. This does **not** mean
all non-binary encodings are supported. UTF-16 and legacy encodings require a
follow-up encoding/round-trip design; do not silently decode with replacement
characters.

The proposed binary-content rule runs only after strict UTF-8 decoding. Reject
content containing any NUL scalar. Otherwise, count all Unicode scalars and reject
only when at least two scalars are controls other than tab, line feed, carriage
return, or form feed, and those disallowed controls are more than ten percent of
all scalars. Exactly ten percent is accepted. File signatures do not participate
in admission: invalid UTF-8 remains an unsupported-encoding refusal even when its
bytes identify a common binary format, while UTF-8 text is judged only by the NUL
and control-density rules.

This deliberately permits some UTF-8 binary payloads and can reject legitimate
control-rich UTF-8 text. For example, compact text containing multiple ANSI escape
sequences can cross the density threshold. That is an acknowledged false rejection
of this first increment rather than evidence that the text has an invalid encoding.

After successful open, offer a nonmodal **Do you want to render as <Language>?**
with **Use <Language>**, **Keep Plain Text**, and **Choose Language…**. Opening
and editing remain possible if inference fails or yields no suggestion.

Proposed precedence: explicit user selection > recognized filename hint >
accepted content detection > Plain Text. For a strong filename/content conflict,
show both in the picker rather than silently changing mode. Markdown files stay
Markdown unless the user chooses otherwise. Manual detection can reconsider a
filename-based suggestion but does not override an explicit choice.

Modes are **Plain Text**, **Markdown**, and **Source(<label>)**. Source mode
colors the complete buffer without adding fences or interpreting Markdown
headings/lists. Plain Text suppresses Markdown styling/automation. Rendering
choices do not create edit operations, mark the file dirty, or write the disk
file. These are proposed acceptance requirements, not claims about current
behavior. The existing decode/save path is unchanged by language selection.

Keep mode and dismissal state in memory per open file for v1; closing/relaunching
resets them. No new document metadata or persisted language field. Recompute
unaccepted suggestions after an external reload or Save As; retain explicit
session choices. On restoring a draft, classify the displayed draft rather than
stale disk content. Dismissal prevents repeat prompts for the same revision.

## 3. Suggest a language for a bare Markdown fence

An empty opening info string makes a fence eligible; an unknown but explicit
label does not. Detect only the fence body, not surrounding prose, and never
replace a user-written label automatically.

After a paste into a bare fence, fence closure, or an explicit Detect action,
offer **Use <Language> for Highlighting** and **Insert <label> in Fence**.
The first is display-only and session-local. The second is an explicit,
single-undo edit to the opening rule, with revision/range validation. A manual
picker can replace an incorrect suggestion. No detection on every keystroke;
a body edit invalidates the previous inference and stale suggestions disappear.

For an unterminated fence, automatic suggestions wait for closure; on-demand
detection may use the body through end-of-document and must not insert a closing
rule. Existing labels always take precedence, including unsupported labels.

## Presentation and fallbacks

- Fenced code and Source mode use a fixed-width font at the chosen text size,
  even when prose uses a proportional custom family. Measure wrapping and caret
  geometry with the actual code font; do not assume the prose cell width.
- Keep the existing disabled quote/dash substitutions and spelling correction;
  this feature does not turn them on for prose. Verify typing, paste, IME,
  selection, and returning from code to prose.
- Reuse `CodeInk` for supported labels. For other detected labels, show the label
  and fixed-width code presentation without token colors. Do not substitute an
  unrelated highlighter. Expanding the grammar set is a separate scope.
- Suggestions have accessible names and keyboard actions and never depend on
  token color alone. Detection does not move focus.
- Keep chips, the ledger, the minimap, and other recognition surfaces outside
  this feature. A visible quiet roll page may use an accepted language for
  display-only highlighting under **All pages** (ADR-0030); it remains
  noninteractive and the choice remains page-owned session state.

## Proposed processing boundaries

Process only visible text supplied for the requested action, on device, without
network inference, model downloads, source logging, or content telemetry. Keep
results and request buffers short-lived; do not persist source samples or
content-derived hashes. Exclude sealed-paste, chip-copy, conceal, and background
clipboard monitoring paths.

These are new design requirements, not a verified privacy or zeroization
guarantee. In particular, upstream runtime scratch buffers need review; an
embedded model and `OnceLock` do not establish that derived input data is erased.
The plan makes that review a release gate.

## Non-goals

Natural-language detection, binary/file-format identification by Betlang,
execution or validation of pasted code, model training, a Dioxus UI, a grammar
engine replacement, automatic refactoring/reindentation, remote classification,
scanning sealed content, and persistent inferred document metadata.
