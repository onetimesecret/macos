# docs/spec/feature/textarea/textkit2.md
---

ADR-0013 decided architecture 3 (Loro core, ops across the seam) on 2026-08-07. TextKit 2 appears only in its Consequences section, as a prediction about what that choice implies:

▎ docs/adr/0013-...md:445 — "The view layer wants TextKit 2. If the core owns blocks, flat TextKit 1 storage fights it at every step... The chip blocker that forced TextKit 1 dissolves in the same move... The maturity tax on TextKit 2 is real and includes silent fallbacks to TextKit 1."

That is a consequence nobody executed. No ADR supersedes it, no migration commit exists, and the shipped code says so in its own comment at InkEditorView.swift:36: "Explicit TextKit 1 stack."

What pins it to TextKit 1 today

InkEditorView.makeNSView()
  :45  NSLayoutManager()                    ← TK1 by construction
  :46  NSTextContainer(size:)               ← shared, but wired to the LM
  :57  storage.addLayoutManager(lm)         ← TK1 assembly
  :64  NSTextView(frame:textContainer:)     ← this init IS the TK1 opt-in

InkEditorView.updateNSView()
  :175 layoutManager.replaceTextStorage()   ← ADR-0006's page swap, TK1 only
                                              (TK2: swap the content manager)

Coordinator.documentHeight()
  :299 layoutManager.ensureLayout(for:)     ← glyph-era API
  :300 layoutManager.usedRect(for:)

Coordinator.repositionBlockLabels()
  :951 glyphRange(forCharacterRange:)       ← glyph-era API
  :961 lineFragmentUsedRect(forGlyphAt:)

ChipAttachment / ChipCell
  :1105 attachmentCell = ChipCell(...)      ← NSTextAttachmentCell
                                              TK2 has no attachment cells;
                                              touching one forces the fallback

Five separate load-bearing call sites, not one flag. And the fallback is silent: even if we built the view TextKit 2, the first textView.layoutManager access in documentHeight or repositionBlockLabels would quietly demote it, so we would pay the migration and keep TextKit 1 behavior.

What changes in the answer I just gave

Nothing about find and replace or word wrap. NSTextFinder, usesFindBar, and container width work identically in both stacks. My recommendation stands unchanged.

What TextKit 2 actually buys is the ADR-0013 work, not the editing verbs:

- NSTextAttachmentViewProvider replaces ChipCell, so a chip becomes a real NSView: hover, accessibility, and the chip menu stop being hand drawn in draw(withFrame:in:).
- NSTextLayoutFragment subclassing draws the provenance label inside the fragment, which deletes updateBlockLabelViews and repositionBlockLabels and the whole pool of NSTextField subviews (roughly 60 lines, plus the paragraphSpacingBefore and top-inset hack at :790).
- A custom NSTextContentManager vends NSTextParagraph elements backed by core blocks, which is the one thing that would make blocks.rs and the view layer agree on what a block is instead of the view re-deriving it by counting paragraphs in blockRange at :809.

In Short

Migrating to TextKit 2 is a rewrite of the chip renderer, the block label layer, and ADR-0006's storage swap, and it earns its keep against block identity. If we want it, it needs its own ADR that supersedes the replaceTextStorage invariant, because ADR-0006 currently states that invariant in TextKit 1 terms.


---

> QUESTION:  If we want to implement word wrap toggle etc, is that specific to TextKit 1? Like we'd need to do it again for TextKit2?

Word wrap is stack agnostic. Nothing you write for it would need doing again.

The three knobs all live above the layout manager:

NSText          isHorizontallyResizable, minSize, maxSize   ← shared
NSTextContainer size.width, widthTracksTextView             ← shared class,
                                                              TK1 and TK2 both use it
NSScrollView    hasHorizontalScroller                       ← not TextKit at all

NSTextContainer is the one piece of the stack Apple did not fork. A TextKit 2 NSTextLayoutManager takes the same container object with the same widthTracksTextView semantics. The toggle is roughly:

container.widthTracksTextView = wrap
container.size.width = wrap ? 0 : .greatestFiniteMagnitude
textView.isHorizontallyResizable = !wrap
textView.maxSize.width = .greatestFiniteMagnitude   // already set
scroll.hasHorizontalScroller = !wrap

That code compiles and behaves identically under either stack.

What actually pins you to TextKit 1

InkEditorView.swift                          TK2 migration cost
─────────────────────────────────────────────────────────────────────
:45  NSLayoutManager()                       rewrite  NSTextLayoutManager
:175 replaceTextStorage(incoming)            rewrite  no equivalent; you
     ADR-0006 page swap                               swap textContentManager
:56  shedLayoutManagers                      rewrite  different ownership model
:1098 ChipAttachment + NSTextAttachmentCell  REWRITE  TK2 has no cell path;
:1117 ChipCell.draw(withFrame:)                       NSTextAttachmentViewProvider
:667 textView(_:clickedOn:in:at:)            REWRITE  cell-click delegate is TK1 only
:299 ensureLayout / usedRect(for:)           rewrite  usageBoundsForTextContainer
:951 glyphRange(forCharacterRange:)          rewrite  no glyphs in TK2;
:961 lineFragmentUsedRect(forGlyphAt:)                enumerateTextLayoutFragments
─────────────────────────────────────────────────────────────────────
:398 NSTextStorage didProcessEditing         SURVIVES NSTextContentStorage wraps
     the op emission point                            a real NSTextStorage
:71  usesFindPanel / NSTextFinder            SURVIVES both stacks
     wrap toggle, spellcheck, undo           SURVIVES

Two of those are not ports, they are rewrites: chips and the block provenance labels. Chips are NSTextAttachmentCell, which TextKit 2 dropped entirely in favour of view providers, and every geometry call in repositionBlockLabels and documentHeight is a glyph query, and TextKit 2 has no glyphs.

Also worth knowing: NSTextView silently falls back to TextKit 1 the moment anything touches .layoutManager. makeNSView constructs the layout manager by hand at line 45, so this editor is TextKit 1 by construction and cannot drift into TextKit 2 by accident. There is no half state to worry about.
