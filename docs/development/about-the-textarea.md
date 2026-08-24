# docs/development/about-the-textarea.md
---


> QUESTION: Based on the current implementation, what kind of common text editing functionality is available that we are not utilizing yet? For example like word wrap toggle, find and replace, etc. Or is it a clean slate that we need to implement ourselves? Please answer with the aide of an ascii visual showing where that code lives in SwiftUI and/or Rust.

Not a clean slate. We are sitting on NSTextView (TextKit 1, explicit stack), so most of macOS's text editing machinery is already in the box. One line turns the biggest piece off.

Where the editing surface actually lives

```bash
┌─ SWIFT SHELL ─────────────────────────────────────────────────────────────┐
│                                                                           │
│  PageSurface.swift:190  PageKeyboardMap                                   │
│    ⌘1..9 ⌘0 ⌥⌘N ⌥⌘← ⌥⌘→ ⌘W ⌘, esc      ← app-level map, no text verbs    │
│                                                                           │
│  InkEditorView.swift                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ makeNSView():64..96   THE SWITCHBOARD                               │  │
│  │   :68  isRichText            = true    (chips need attachments)     │  │
│  │   :70  allowsUndo            = true    ✓ per-page undo (:358)      │  │
│  │   :71  usesFindPanel         = false   ✗ ⌘F is dead here           │  │
│  │   :72  quote substitution    = false   ✗ deliberate                 │  │
│  │   :73  dash substitution     = false   ✗ deliberate                 │  │
│  │   :74  spelling correction   = false   ✗ deliberate                 │  │
│  │        (continuous spellcheck, grammar, text replacement, ruler,    │  │
│  │         link detection, incremental search: never mentioned)        │  │
│  ├─────────────────────────────────────────────────────────────────────┤  │
│  │ scrollStack():113   WRAP IS WELDED ON                               │  │
│  │   :49  container.widthTracksTextView = true                         │  │
│  │   :118 isHorizontallyResizable       = false                        │  │
│  │   :125 hasVerticalScroller           = true   (no horizontal)       │  │
│  ├─────────────────────────────────────────────────────────────────────┤  │
│  │ InkTextView:980   key routing                                       │  │
│  │   :991 performKeyEquivalent  → ⇧⌘V seal, ⌘↩ seal line             │  │
│  │   :1009 paste()              → forced pasteAsPlainText              │  │
│  │   :1019 setMarkedText        → IME gate                             │  │
│  ├─────────────────────────────────────────────────────────────────────┤  │
│  │ restyle():736   display-only markdown                               │  │
│  │   headings by weight, markers dimmed in place (:1194)               │  │
│  │   fenced blocks read literally, markup inert (issue #75)            │  │
│  │   block provenance labels laid out as NSTextField subviews          │  │
│  └────────────────────────┬────────────────────────────────────────────┘  │
│                           │                                               │
│  THE EMISSION POINT  textStorage(_:didProcessEditing:):398                │
│  every character edit AppKit makes, from any source, becomes ops (:486)   │
└───────────────────────────┼───────────────────────────────────────────────┘
                            │ companion_sheet_apply_ops   [ins | del | chip]
┌─ RUST CORE ───────────────▼───────────────────────────────────────────────┐
│  store.rs:514  apply_ops        document.rs  runs + marks                 │
│  blocks.rs     BlockIndex: split mints an id, merge kills one,            │
│                created/modified derived from op timestamps                │
│  NO text-editing verbs at all: no search, no transform, no line ops.      │
│  The core is a provenance ledger over text, not an editor.                │
└───────────────────────────────────────────────────────────────────────────┘
```

What that buys you, and what it costs

Already working, unclaimed: undo/redo per page, select all, cut/copy, word and paragraph motion, option-arrow word jump, emoji picker (⌃⌘Space), Services menu, dictation, macOS text selection semantics, autoscroll, drag-to-move within the page.

Free, switched off at line 71: find, find and replace, find next/previous, use selection for find, jump to selection. Flipping usesFindPanel = true plus usesFindBar = true gives you NSTextFinder with an inline find bar and replace all, no core work whatsoever. Search reads storage.string, which the shell already holds; Rust never needs to know.

One flag each, but each is a policy call: continuous spell checking, grammar, smart insert/delete, automatic text replacement, data detectors, ruler with tab stops. These were left off by omission, not by an ADR.

Genuinely absent, real work: word wrap toggle (rewire container width, isHorizontallyResizable, add a horizontal scroller), line numbers (NSRulerView client), go to line, word/character count, move line up/down, duplicate line, sort lines, case transforms, auto-indent, list continuation, inline emphasis styling (deferred on purpose, InkEditorView.swift:1192). AppKit gives you none of these; every one is shell-side and each mutating one emits ops for free through the delegate at :398.

The two things that make this not a pure switch flip

1. Chips are one character. A Replace All whose range crosses a chip emits del over the attachment, and the core reaps the sealed bytes with no confirmation. That contradicts ADR-0009 (chip deletion is deliberate and final). Coordinator.containsChip at :650 already exists as the guard the seal path uses; find/replace would need the same refusal.
2. Bulk edits restamp provenance. blocks.rs derives created/modified from op timestamps, and a merge kills the absorbed block id. Replace All across ten blocks restamps ten blocks, which is arguably correct. Sort lines or move line up/down is not correct: it destroys block identity wholesale. Those two belong behind an ADR-0013 conversation, not behind a keyboard shortcut.

What I would do

Enable the find bar. It is the highest value per line of code in the whole list, it needs zero Rust, and the only work is a chip guard on replace. Word wrap toggle is second and cheap. Line reordering and sorting I would leave alone until block identity has an answer.
