# Version-history research: incumbent set

Reference list of every product and source examined in the "Undo That Survives Closing" outing (29 Aug 2026), for reuse in follow-up research. "Cited for" is the behaviour relied on; "unverified" means not confirmed from documentation.

## From the original notes (not re-researched)
- Obsidian — File Recovery 5 min / 7 days; Time Machine community plugin
- Craft — automatic backups, browse-and-restore
- Ulysses — automatic backups, browse-and-restore
- Google Docs — continuous revision timeline, named versions, colored diffs
- Simplenote — history slider
- Notion — page history 7 / 30 / 90 / unlimited days by plan
- Drafts — automatic version list per draft
- Scrivener — deliberate titled snapshots, Compare, Roll Back
- Apple Notes — no history
- Bear — no history

## Notes and scratchpad apps
- Standard Notes — session history ≥5 min apart; $0 / $90 / $120 tiers; restore or restore-as-copy; conflict diff (2024)
- Joplin — 10-min interval, stored as text diffs, 90-day default, lowest device setting wins, copy-only restore
- UpNote — 50 versions per note per device, local only
- NotePlan — local SQLite versions.db, unsynced, trimmed
- Reflect — continuous; restore-to-new-note only
- Mem — unlimited, not gated, inline diff, append on restore
- Anytype — CRDT-based, char-level diff, Ctrl+H
- Evernote — history free since Feb 2024, desktop/web only
- Google Keep — web only, download .txt, no in-app restore
- Logseq — git auto-commit ≤600 s, bak/ folder, Sync page history ≤1 year
- Roam Research — block versions (Ctrl-,), no page history (issue #64), transaction-log forensics
- Tana — none; "Future Consideration" (18 votes)
- Capacities — none found (unverified)
- Agenda — stores full history, no UI
- Tot — hourly whole-state JSON backup, kept "past few days"
- Antinote — 1–100 whole-DB backups on 10 min–1 month schedule; auto-expiring notes
- Heynote — none; backup request closed "not planned"
- Zettlr — autosave only
- iA Writer — macOS Versions (needs iCloud); Authorship provenance annotations
- Typora — macOS Versions; Win/Linux 5-min draft file
- Byword — presumed macOS Versions (unverified)
- Bike Outliner — presumed macOS Versions (unverified)
- Paper (paper.pro) — nothing stated (unverified)

## Long-form and AI writing
- Novlr — snapshot on pause, word count per version
- Dabble 3 — timeline scrub, "Bring Forward" single document
- Novelcrafter — 3-min buckets, per-field revisions
- Sudowrite — backup list (details unverified)
- Lex — manual save-a-version

## Collaborative and office
- Dropbox Paper — version if ≥30 min old and >500 chars changed; destructive rollback; 30/180/365 days
- HackMD — every 10 min + named; free 10 versions; side-by-side compare
- Etherpad — Timeslider, per-changeset, playback speed
- Draftback — Google Docs keystroke replay (Chrome extension)
- Microsoft Word — AutoRecover 10 min; UnsavedFiles 4 days; OneDrive 25 / SharePoint 500 versions
- Apple Pages / macOS Versions (NSDocument) — hourly, copy text out of old version, Option-restore copy
- SharePoint — automatic version thinning

## Code editors and agentic tools
- VS Code Local History — 10 s merge window, 50 entries, 256 KB
- JetBrains Local History — 5 working days, labels, history for selection
- Xcode — macOS Versions only
- Sublime Text — hot exit
- Zed — hot exit; undo-wipes-restored-buffer bug #21846
- Cursor — checkpoints; restore destroys redo (2025)
- Windsurf / Cascade — irreversible reverts, named checkpoints
- Claude Code — /rewind, 100 checkpoints, 30 days, restore-and-refill
- Vim — :earlier 10m, undofile, undotree plugin
- Emacs undo-tree — branching undo, visualizer, persistence

## AI chat and prompt tools
- ChatGPT — < 1/2 > sibling navigator; 2026 removal complaints; Canvas versions
- Claude.ai — hidden branch on edit
- Langfuse — immutable prompt versions, movable labels
- PromptLayer — diff before save
- Humanloop — version + environments (unverified)
- TypingMind — no versioning found (unverified)

## Email and chat
- Gmail — no draft history; cross-device revert threads
- Outlook — no draft history; drafts recoverable as deleted items
- Apple Mail, Superhuman — no draft history
- Zulip — draft saved on close (≥3 chars); edit history
- Slack, Discord, Telegram — "edited" label only
- iMessage — 5 edits within 15 min, tap "Edited" for history

## Design, spreadsheets, trackers, wikis
- Figma — 30-min checkpoints; 30 days on Starter; two checkpoints on restore
- Canva — 1,000 versions, paid only
- Sketch — (unverified)
- Google Sheets — cell edit history
- Airtable — record revisions 2 wk / 1 yr / 2 yr / 3 yr
- Linear — description history; per-span author attribution (Jul 2026)
- GitHub — comment edit history dropdown
- Stack Overflow — post revisions with diffs
- Wikipedia / MediaWiki — byte delta per revision; wikidiff2 move detection

## Browser, clipboard, OS, photo
- Lazarus Form Recovery (defunct), Typio Form Recovery, Textarea Cache, Form History Control
- Firefox session restore (form data)
- Windows Win+V, Raycast clipboard history, Maccy
- Time Machine — tiered retention
- Photos — revert to original only
- Lightroom — linear history + snapshots
- Photoshop — 50 history states, non-linear option, snapshots
- Procreate — 250 undo steps

## Technology and research
- Yjs — UndoManager 500 ms captureTimeout, gc, snapshots
- Automerge — columnar encoding ~1 B/op, v3 memory
- Loro — checkout/time travel, shallow snapshots, Eg-walker
- Peritext — rich-text CRDT
- jsdiff, diff-match-patch, wikidiff2 — diff libraries
- Inputlog / ScriptLog pause research — Wengelin 2006; Hall, Baaijen & Galbraith 2022; Van Waes & Leijten 2015
- Azurite — Yoon & Myers, ICSE 2015 (regional undo)
- CRDT selective undo — Yu, Elvinger & Ignat, DAIS 2015
