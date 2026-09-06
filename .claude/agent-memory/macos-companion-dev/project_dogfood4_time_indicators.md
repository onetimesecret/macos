---
name: dogfood4-time-indicators
description: Dogfood phase 4 items 3 and 6 (2026-09-05): the strip's tab gauge is withdrawn, the header countdown yields only in day mode because the day gutter exists only there, PageStatusStack's bottom edge gauge is still open; parallel lanes share one scratchpad dir
metadata:
  type: project
---

The per tab GaugeBar came out of the strip on 2026-09-05 (dogfood phase 4
item 3, issue #156) because a thin bar on the card's bottom edge reads as a
horizontal scroll bar. The header CountdownButton was kept in strip mode and
removed only in day mode (item 6), narrowing the item as written.

**Why:** the "duplicate" countdown the item cited lives in DayScrollView's
day gutter, and PageContentView mounts DayScrollView only while
`showsTimeUnits` is on, which is off by default and exclusive with the strip.
Removing the header copy unconditionally would have left the default mode
with no worded countdown at all. `BackdropRootView.showsHeaderCountdown`
holds the rule.

**How to apply:** any future indicator must not be a thin horizontal bar on
the bottom edge. PageStatusStack still draws a 4 pt GaugeBar along the page's
bottom edge directly above the strip; it carries the same misread and was
left for a separate call, so expect it to come up. When a task says "X is
already shown in the gutter", check which mode mounts the gutter first.

Also learned on this run: parallel workflow lanes share one scratchpad
directory. Another lane overwrote `commit1.txt` seconds after I committed
from it. Name scratch files with a lane prefix and confirm `head -1` before
`git commit -F`.
