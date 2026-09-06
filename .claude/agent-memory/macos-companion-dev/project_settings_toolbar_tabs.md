---
name: settings-toolbar-tabs
description: Dogfood phase 4 item 2 turned Settings into NSTabViewController toolbar tabs (General, Connection, Sync); per tab heights and the window resize on tab switch were reasoned, never seen on hardware
metadata:
  type: project
---

Settings became a standard toolbar tab window on 2026-09-05 (branch
worktree-wf_1d83dcc0-b05-3, commits e7b191c and ee95acd): an
NSTabViewController with tabStyle .toolbar, window toolbarStyle
.preference, one NSHostingController per tab with sizingOptions cleared
and a fixed preferredContentSize (480 wide; 560, 360, 380 tall).

**Why:** the one scrolling column did not look like a Mac Settings
window, and the dogfood brief named the System Settings convention.

**How to apply:** the per tab heights and the claim that the window
animates to each tab's preferredContentSize came from AppKit's contract
for the toolbar style, not from a hand check (the lane was build and
test only). The first hardware pass should confirm the window resizes
between tabs, that the title follows the tab, and that General is not
clipped or padded. A refused ledger makes show() land on General
(SettingsTab.landing); that is where the ledger clear moved. The
LaunchAtLogin doc comment still carries a pre-existing em dash.
