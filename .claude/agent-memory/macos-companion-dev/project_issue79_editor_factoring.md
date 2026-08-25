# Issue #79: the editor factoring (branch 4 of the vertical-time-tabs stack)

Landed 2026-08-25 on `claude/79-4-editor-factoring-ymyi7n`, over the day
projection. ADR-0020 required-work item 11. A pure refactor whose whole
claim is that behaviour did not change: the existing suite
(DocumentOpsTests, EditorHandoffTests, WrapTests, PageScrollTests,
FocusLawTests) is unedited, which is the evidence.

## What exists now, in InkEditorView.swift

- `InkEditorView.makeInkTextView(model:sheetID:coordinator:)`, the one
  editor built without a scroller: TextKit 1 stack, the page's storage
  with `shedLayoutManagers(from:keeping: nil)`, the storage delegate,
  every flag, the delegate wiring, `activeEditor`, `performSealedPaste`.
  `makeNSView` sheds the undo history, calls it, grants editing and
  wraps it in `scrollStack(for:)`.
- `Coordinator.moveEditor(_:to:storage:restoringScrollIn:)`, the swap
  ceremony, statement for statement in its old order: discard the
  composition, save, shed, `replaceTextStorage`, delegate handoff,
  `currentSheet`, restyle, restore. `updateNSView` is a thin caller.

## Two contracts a later branch must not re-decide

- **Editing belongs to the mount, not to the building.** The factory
  sets no `isEditable` and takes no `readOnly`: the stance can move
  without the page moving, and `updateNSView` re-gates it every pass. A
  new mount must grant editing itself or the page is editable while the
  card rests.
- **`saveViewState` and `restoreViewState` take `NSScrollView?`.** A
  caret belongs to the page wherever it is mounted; an offset belongs to
  the clip the page sits in. Passing nil runs the caret leg and skips
  the scroll leg: no main-queue hop is scheduled, and an offset a
  scrolled mount saved is left standing rather than overwritten. That is
  the leg a roll with one scroller over several days takes.

## Testing notes

**`usesFindPanel` cannot be asserted anywhere.** AppKit's two find
switches are one choice: `enableFinding` sets the panel, then the bar,
and the panel then reads back false. The first CI run of this stack
failed on exactly that assertion. Hold a built editor to `usesFindBar`
instead; the source order is the shipped one and must not be reordered
to make a getter agree.

`EditorFactoryTests` builds the editor in a headless window
(PageScrollTests idiom) over `isolatedModel` + an ephemeral core.
`maxSize` is asserted on the composed pair, never on the bare factory
output: `NSTextView`'s own `maxSize` default is its frame, and the
unbounded value is `scrollStack`'s doing. The first editor and its
layout manager are held in locals for the shed test, so the count that
proves the shed is not ARC's doing.
