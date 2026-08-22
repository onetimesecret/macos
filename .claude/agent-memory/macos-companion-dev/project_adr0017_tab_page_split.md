---
name: adr0017-tab-page-split
description: ADR-0017 durable tabs and expiring pages, what landed when, and the two predicates that must never be wired backwards
metadata:
  type: project
---

ADR-0017 splits one object into a durable Tab (identity, creation stamp, optional user name, rung, at most one Page) and an expiring Page (document, blocks, chips, clock). Landed in two passes on the ledr1 worktree:

- **Core (PR #59, merge fae0a6e):** `SheetStore.tabs: Vec<Tab>`, `open_page`, `expire_due` leaves the tab standing, `holds_no_page`/`has_no_tabs`, `next_event` skips pageless tabs, `OTSSNAP4` layout with tab records framing page bodies, no derived title on disk.
- **Seam and shell (2026-08-22, branch feature/61-ledger-superseded-disposal):** tab-addressed C routes (`companion_tab_new/_open_page/_close/_move/_set_title/_set_rung/_cycle_rung/_pause_press`, `companion_tabs_json`, `companion_store_emptiness`) against unchanged page-addressed ones; core `new_tab` returns `(TabId, SheetId)`; `TabSummary` in Swift with `id`/`hasPage`/`pageID`; `PageModel.sheets` became `tabs`, `selection` is a tab id.

**Why:** the strip was nine independent deadlines and the user's arrangement was destroyed by countdowns rather than by the user (docs/dogfood/ABERRATIONS.md:67). The user visible outcome to protect: after expiry the tab stays on the strip, empty and named, and relaunch after an overnight expiry does not mint a fresh page.

**How to apply:**
- The two emptiness predicates are not interchangeable and the shell derives neither. `holds_no_page` fires `companion_persist_rotate_and_save` (`rotatesContentKey(loaded:contentLicence:holdsNoPage:noTabsRemain:)`); `has_no_tabs` is the only thing that drops `state.sealed` (`erasesContentFile(noTabsRemain:)`). Feeding the first to the drop destroys tabs an expiry left standing; feeding the second to the rotation leaves the install on one content key forever.
- The rotate-plus-reseal landed 2026-08-22 in the same pass as the adversarial review fixes: `saveState` is a three way branch (drop / rotate and reseal / plain save), rotation fires on the empty state rather than on the transition into it (a latch would be a second source of truth about disk), and a rotation that cannot erase the file half cancels the write and arms the retry.
- Burning a promoted page goes through `companion_page_discard` (page addressed), never `close`: only an explicit close and the cap end a tab.
- Selecting mints, so a double-click on an empty slot would mint and then hold; `PageModel.holdWouldStrikeItsOwnMint` refuses a hold that lands on the page the preceding tap minted. The refusal lives in the model because SwiftUI re-makes the strip's recognizers as the view re-renders.
- Minting is gesture-only: click, cmd-1..9, opt-cmd-arrows, and Return. Never `refresh()`, never expiry, never restore. `loadStateIfNeeded` mints only when `hasNoTabs`.
- `storages`/`undoManagers`/editor view state are keyed by page identity (`pageID`), pruned on the live page id set; keyed by tab they would hand a reused slot's new page a dead chip's undo stack (ADR-0009).
- The cap message must not say "let one expire": an expiry empties a slot and never frees it, so only closing moves the wall.

See [[adr0018-gated-seams]] for `companion_test_age_ms`, the seam that makes the post-expiry states testable from Swift.
