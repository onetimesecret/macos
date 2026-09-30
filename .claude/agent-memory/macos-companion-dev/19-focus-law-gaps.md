# Issue #19 — Focus law gaps: empty-state keyboard, page-switch caret/focus

GitHub: https://github.com/onetimesecret/macos/issues/19
Diagnosed 2026-07-14 from real use of the bundled .app; both root causes adversarially verified against source (high confidence). Suggested branch: `feature/19-focus-law-gaps`.

## Verified mechanisms (with evidence)

### A. Empty state cannot accept the keyboard

- `WindowController.swift:32` styleMask `[.nonactivatingPanel, .titled, .resizable, .fullSizeContentView]`; `:49` `becomesKeyOnlyIfNeeded = true`.
- AppKit semantics: with `becomesKeyOnlyIfNeeded`, a click makes the panel key only if the clicked view's `needsPanelToBecomeKey` is true. NSTextView/NSTextField: true. Plain views, SwiftUI hosting background, buttons: false. (Caveat: NSHostingView not overriding this is undocumented but consistent with NSView default and observed behavior.)
- Empty state (`WindowRootView.swift:135-145`) renders only `Text` → no click ever grants key status → keystrokes continue to the previously key app underneath. `show()` uses `orderFrontRegardless` (`WindowController.swift:104`) — visible but never key.
- `summon()` (`WindowController.swift:121-132`): `makeKeyAndOrderFront` then `makeFirstResponder(editor)` **nil-guarded on `model.activeEditor`** — nil in empty state → panel key, typing beeps, Enter does nothing (keyboardMap has only `.cancelAction`, no `.defaultAction`; `WindowRootView.swift:152-186`).
- Page creation paths are exactly: `newPage()` via hidden ⌥⌘N button (`WindowRootView.swift:163`), the `+` tab (`TabStripView.swift:68-78`), `loadStateIfNeeded()`'s newSheet-on-empty-restore (`App.swift:349-351`). **No type-to-create anywhere; not specced either.**
- Grep-verified: no other `makeKey*`/`makeFirstResponder`/`keyDown`/NSEvent monitor/`.onKeyPress`/`.focusable` in shell/Sources. The only other `.defaultAction` is in SettingsWindow.swift:113 (separate window, irrelevant).

### B. Page switch destroys caret, scroll, focus, undo

- `WindowRootView.swift:133`: `InkEditorView(model:sheetID:).id(selection)` — identity changes per selection → SwiftUI tears down + re-runs `makeNSView` (fresh NSScrollView + InkTextView + Coordinator).
- Caret/scroll are view state → reset to {0,0}/top. Content survives only because `WindowModel.storages` caches `NSTextStorage` per sheet (`App.swift:413-429`).
- First responder: removing the focused editor makes the *window* first responder; nothing re-focuses the new editor. Sole `makeFirstResponder(editor)`: `summon()` (`WindowController.swift:128-129`). `select(_:)`/`select(index:)`/`step(_:)` (`App.swift:433-451`) mutate selection only.
- **Misleading signal:** `holdsKeys` tracks key-*window* status (`WindowController.swift:201-207`), so the ember border stays lit after a switch while typing dead-ends at the window (beeps).
- **Dead code:** `updateNSView`'s `coordinator.currentSheet != sheetID` → `replaceTextStorage` branch (`InkEditorView.swift:77-83`) is unreachable under `.id()`. Source comments contradict: `:23-26` claims storage-swap design, `:32-34` admits recreation ("detach layout managers a torn-down editor left behind").
- Undo history lost per switch (fresh view; `:82` also clears it deliberately on the swap path).
- No restoration path exists: grep for `FocusState|focused|firstResponder|scrollRangeToVisible|becomeFirstResponder|selectedRange` — only seal-gesture `setSelectedRange` calls (`InkEditorView.swift:141,178,201`).

### C. Stale promotion in empty state (bonus, found by verifier)

- `PromotionView` renders whenever `model.promotion != nil && !model.showingLedger` (`WindowRootView.swift:26-30`), independent of `selection`. `close()`/`closeCurrent()` (`App.swift:507-521`) never clear `promotion`. Close the last page with a confirmation open → empty state still shows PromotionView; its "Create link" has `.keyboardShortcut(.defaultAction)` (`PromotionView.swift:135`) → Enter (once key) fires `confirmPromotion` from a pageless window. Its TextField/SecureField are also the one empty-state surface whose click WOULD make the panel key.

## Spec position (sweep of docs/spec, CHANGELOG, shell/README)

- Focus law (`docs/spec/04-interaction-model.md:84-89`): keyboard "by deliberate act only — click into the page, or summon with ⌥Space"; never key for chrome interactions. Also `03:36-39` ("Should the window take keyboard focus on drop? — No").
- Empty state specced only as tone: "a single calm sentence" (`03:127-128`); "Empty is its natural, healthy state" (`01:130-132`). **No specced keyboard grant for a pageless window** — genuine spec gap.
- Type-to-create: absent everywhere. "First typed line" is naming only (`04:179-181`).
- Page-switch caret/focus behavior: unspecced (keyboard map entries are bare; `06-open-questions.md` silent).

## Fix design

1. **Empty state = click-to-create.** Make the empty content area a click target: create page, then focus. Creating puts an `InkEditorView` on screen; focus needs the panel key first — click on a plain SwiftUI view won't grant it, so after `newPage()` call through to the controller: `panel.makeKeyAndOrderFront(nil)` + `makeFirstResponder(editor)` (mirrors `summon()`, and a click IS the deliberate act, so the focus law holds). Needs a model→controller hook like `onFocusEditor` (pattern: existing `onHandBackKeys`/`onOpenSettings`, `App.swift:293-297`). Editor is created by SwiftUI async — either focus after a runloop turn or have `makeNSView` self-focus when a "pendingFocus" flag is set on the model.
2. **`summon()` guarantees a page:** after `loadStateIfNeeded()`, if `client.sheets().isEmpty` → `newPage()`. Covers the all-pages-closed-later case (loadStateIfNeeded only guards first reveal).
3. **Single persistent editor:** drop `.id(selection)` from `WindowRootView.swift:133` so the `replaceTextStorage` path finally runs. First responder + key status survive switches for free. Fix the stale comment at `InkEditorView.swift:32-34` (the detach-stale-layout-managers loop stays harmless — keep as belt-and-braces or delete).
   - **Caret/scroll:** in the coordinator, before `replaceTextStorage`, save `textView.selectedRange()` + visible rect keyed by outgoing `currentSheet` (dictionary on WindowModel or coordinator; prune with `storages`); after swap + `restyle()`, clamp saved range to `storage.length` and `setSelectedRange` + `scrollRangeToVisible`. Clamp matters: content can change core-side (chip zeroized) while another page shows.
   - Keep `undoManager?.removeAllActions()` on swap (already there; cross-page undo would be wrong anyway).
4. **Clear stale promotion:** in `close(_:)` (or `refresh()`), if the promotion's target page/chip no longer lives, `promotion = nil`. Careful: promotion target can be `.chip(id)` on the current sheet — clear when its *sheet* dies.
5. **Spec touch-up:** add the empty-state grant to `04-interaction-model.md` focus-law section ("click on the empty window creates a page and is the deliberate act").

## Trade-offs considered

- `becomesKeyOnlyIfNeeded = false` would "fix" empty-state clicks but breaks the focus law (chrome clicks would take keys). Rejected.
- Type-to-create without prior key status is impossible without a global event tap (Accessibility permission, surveillance-adjacent — rejected outright for this product).
- Keeping `.id(selection)` + save/restore per page would also work but keeps two competing mechanisms and re-fights the first-responder race every switch; the storage-swap design was the original intent (comment at `InkEditorView.swift:23-26`) and is strictly simpler.

## Verification notes

- Test on the **bundled app** (`scripts/build-app.sh`, `open dist/CompanionApp.app`), not `swift run` — TCC/key-window behavior differs without a bundle id. Quit the running instance first (`scripts/quit-app.sh`) — `swift build` SIGKILLs a live instance.
- Manual matrix: empty-state click → caret; empty-state ⌥Space → caret; type in page A at offset N → ⌘2 → ⌘1 → caret at N, still focused; tab-click switch while NOT key → window still not key (focus law); Esc → keys handed back; close last page with promotion open → confirmation gone.
