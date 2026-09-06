---
name: dogfood4-time-indicators
description: Dogfood phase 4 items 3 and 6 (2026-09-05): both bottom edge gauges are gone (tab gauge and PageStatusStack's page gauge), the header countdown yields only in day mode because the day gutter exists only there; the login item launch posture and the post modal re-key are open decisions for the maintainer; parallel lanes share one scratchpad dir
metadata:
  type: project
---

The per tab GaugeBar came out of the strip on 2026-09-05 (dogfood phase 4
item 3, issue #156) because a thin bar on the card's bottom edge reads as a
horizontal scroll bar. The review pass then took out the second bar too: the
4 pt GaugeBar PageStatusStack drew across the page's bottom edge, since in
day mode the strip is not mounted and that bar was the only one on the
bottom edge anyone in that mode could have meant. GaugeBar now draws only
on TimeRailView. The header CountdownButton was kept in strip mode and
removed only in day mode (item 6), narrowing the item as written.

**Why:** the "duplicate" countdown the item cited lives in DayScrollView's
day gutter, and PageContentView mounts DayScrollView only while
`showsTimeUnits` is on, which is off by default and exclusive with the strip.
With both gauges gone the header button is the strip mode's only countdown,
so removing it there would leave the default mode with none at all.
`BackdropRootView.showsHeaderCountdown` holds the rule.

**How to apply:** any future indicator must not be a thin horizontal bar on
the bottom edge (constraint recorded in ABERRATIONS, the SheetTab comment,
design spec 04's superseded note and issue #156). When a task says "X is
already shown in the gutter", check which mode mounts the gutter first. Two
phase 4 questions were left for the maintainer rather than fixed: whether a
login item launch should still rest instead of raising, and whether the post
modal re-raise in `modalSessionEnded` should be gated on `NSApp.isActive`.

Also learned on this run: parallel workflow lanes share one scratchpad
directory. Another lane overwrote `commit1.txt` seconds after I committed
from it. Name scratch files with a lane prefix and confirm `head -1` before
`git commit -F`.
